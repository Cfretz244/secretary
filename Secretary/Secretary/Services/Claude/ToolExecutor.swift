import Foundation
import GRDB
import Contacts
import os

/// Routes tool calls to the appropriate service. Port of tools.py _dispatch.
final class ToolExecutor: @unchecked Sendable {
    private let db: DatabaseQueue
    private let calendarService: CalendarService
    private let logger = Logger(subsystem: "Secretary", category: "ToolExecutor")

    /// Called with progress detail strings during long-running tools (sync).
    var onProgress: ((String) -> Void)?

    /// Optional Messages companion service for iMessage/SMS tools.
    var messagesService: MessagesService?

    init(db: DatabaseQueue, calendarService: CalendarService) {
        self.db = db
        self.calendarService = calendarService
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        do {
            return try await dispatch(name: name, args: arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Tool \(name) failed: \(error)")
            return "Error: \(error.localizedDescription)"
        }
    }

    private func dispatch(name: String, args: [String: Any]) async throws -> String {
        switch name {
        case "sync_folder":
            let folder = args["folder"] as? String ?? "INBOX"
            let since = args["since"] as? String
            let progress = onProgress
            let result = try await SyncEngine.syncFolder(db: db, folderName: folder, since: since,
                                                          progress: { folder, done, total in
                if total > 0 {
                    progress?("\(folder): \(done)/\(total) messages")
                } else {
                    progress?("\(folder): connecting...")
                }
            })
            return result.summary

        case "sync_all":
            let since = args["since"] as? String
            let progress = onProgress
            let results = try await SyncEngine.syncAllFolders(db: db, since: since,
                                                               progress: { folder, done, total in
                if total > 0 {
                    progress?("\(folder): \(done)/\(total) messages")
                } else {
                    progress?("\(folder)...")
                }
            })
            let lines = results.map(\.summary)
            return "Synced \(results.count) folders:\n" + lines.joined(separator: "\n")

        case "search_messages":
            let query = args["query"] as? String
            let folder = args["folder"] as? String
            let sender = args["sender"] as? String
            let dateFrom = args["date_from"] as? String
            let dateTo = args["date_to"] as? String
            let flags = args["flags"] as? String
            let unreadOnly = args["unread_only"] as? Bool ?? false
            let page = args["page"] as? Int ?? 1
            let pageSize = args["page_size"] as? Int ?? 20
            let result = try await db.read { db in
                try SearchRepository.searchMessages(
                    db, query: query, folder: folder, sender: sender,
                    dateFrom: dateFrom, dateTo: dateTo, flags: flags,
                    unreadOnly: unreadOnly, page: page, pageSize: pageSize
                )
            }
            return Self.formatSearchResult(result)

        case "get_message":
            let messageId = Self.intArg(args, "message_id")
            let maxBodyChars = args["max_body_chars"] as? Int ?? AppConfig.maxOutputSize
            let msg = try await db.read { db in
                try MessageRepository.getById(db, id: Int64(messageId))
            }
            guard let msg else { return "Message \(messageId) not found" }
            var body = msg.bodyText
            if maxBodyChars > 0 && body.count > maxBodyChars {
                body = String(body.prefix(maxBodyChars)) + "\n\n[Body truncated to \(maxBodyChars) chars out of \(body.count).]"
            }
            return """
                ID: \(msg.id ?? 0)\nFolder: \(msg.folder)\nSubject: \(msg.subject)
                From: \(msg.sender) <\(msg.senderEmail)>\nTo: \(msg.recipients)
                Date: \(msg.date)\nFlags: \(msg.flags)\nSize: \(msg.size) bytes
                \n--- Body ---\n\(body)
                """

        case "get_messages":
            let folder = args["folder"] as? String
            let page = args["page"] as? Int ?? 1
            let pageSize = args["page_size"] as? Int ?? 50
            let sortBy = args["sort_by"] as? String ?? "date_epoch"
            let sortOrder = args["sort_order"] as? String ?? "DESC"
            let result = try await db.read { db in
                try SearchRepository.getMessages(
                    db, folder: folder, page: page, pageSize: pageSize,
                    sortBy: sortBy, sortOrder: sortOrder
                )
            }
            return Self.formatSearchResult(result)

        case "stage_move":
            let messageId = Self.int64Arg(args, "message_id")
            let target = args["target_folder"] as? String ?? ""
            let change = try FlushEngine.stageMove(db: db, messageId: messageId, targetFolder: target)
            return "Staged move #\(change.id ?? 0): message \(messageId) -> \(target)"

        case "stage_flag":
            let messageId = Self.int64Arg(args, "message_id")
            let flagName = args["flag_name"] as? String ?? ""
            let remove = args["remove"] as? Bool ?? false
            let change = try FlushEngine.stageFlag(db: db, messageId: messageId, flagName: flagName, remove: remove)
            let action = remove ? "remove" : "add"
            return "Staged \(action) flag #\(change.id ?? 0): \(flagName) on message \(messageId)"

        case "stage_delete":
            let messageId = Self.int64Arg(args, "message_id")
            let change = try FlushEngine.stageDelete(db: db, messageId: messageId)
            return "Staged delete #\(change.id ?? 0): message \(messageId)"

        case "unstage":
            let changeId = Self.int64Arg(args, "change_id")
            let removed = try FlushEngine.unstage(db: db, changeId: changeId)
            return removed ? "Unstaged change #\(changeId)" : "Change #\(changeId) not found"

        case "clear_staged":
            let folder = args["folder"] as? String
            let count = try await db.write { db in try StagedChangeRepository.deleteAll(db, folder: folder) }
            let scope = folder.map { "folder '\($0)'" } ?? "all folders"
            return "Cleared \(count) staged changes (\(scope))"

        case "show_staged_changes":
            let (changes, subjects) = try await db.read { db -> ([StagedChange], [Int64: String]) in
                let changes = try StagedChangeRepository.getAll(db)
                var subjects: [Int64: String] = [:]
                for c in changes {
                    if let msg = try MessageRepository.getById(db, id: c.messageId) {
                        subjects[c.messageId] = String(msg.subject.prefix(50))
                    }
                }
                return (changes, subjects)
            }
            guard !changes.isEmpty else { return "No staged changes." }
            var lines: [String] = []
            for c in changes {
                let subject = subjects[c.messageId] ?? "?"
                var detail = ""
                if c.changeType == "move" { detail = "-> \(c.targetFolder ?? "")" }
                else if c.changeType == "flag" { detail = "+\(c.flagName ?? "")" }
                else if c.changeType == "unflag" { detail = "-\(c.flagName ?? "")" }
                lines.append("  [\(c.id ?? 0)] \(c.changeType) | \(c.folder) UID \(c.uid) | \(subject) | \(detail)")
            }
            return "\(changes.count) staged change(s):\n" + lines.joined(separator: "\n")

        case "flush_changes":
            let dryRun = args["dry_run"] as? Bool ?? false
            let progress = onProgress
            let results = try await FlushEngine.flushChanges(db: db, dryRun: dryRun,
                                                              progress: { done, total in
                progress?("Flushing: \(done)/\(total) changes")
            }, syncProgress: { folder, done, total in
                if total > 0 {
                    progress?("Re-syncing \(folder): \(done)/\(total)")
                } else {
                    progress?("Re-syncing \(folder)...")
                }
            })
            if results.isEmpty { return "No staged changes to flush." }
            let prefix = dryRun ? "[DRY RUN] " : ""
            let lines = results.map { r in
                var parts = ["\(prefix)\(r.folder):"]
                if r.flagsSet > 0 { parts.append("\(r.flagsSet) flags set") }
                if r.flagsRemoved > 0 { parts.append("\(r.flagsRemoved) flags removed") }
                if r.moved > 0 { parts.append("\(r.moved) moved") }
                if r.deleted > 0 { parts.append("\(r.deleted) deleted") }
                if !r.errors.isEmpty { parts.append("\(r.errors.count) errors") }
                return parts.joined(separator: " ")
            }
            return lines.joined(separator: "\n")

        // Email compose tools
        case "compose_email":
            let to = args["to"] as? String ?? ""
            let subject = args["subject"] as? String ?? ""
            let body = args["body"] as? String ?? ""
            let cc = args["cc"] as? String ?? ""
            let bcc = args["bcc"] as? String ?? ""
            let replyTo: Int64? = (args["reply_to_message_id"] as? Int).map(Int64.init)
                ?? (args["reply_to_message_id"] as? Double).map { Int64($0) }
            let draft = try FlushEngine.composeDraft(db: db, to: to, cc: cc, bcc: bcc,
                                                      subject: subject, body: body,
                                                      replyToMessageId: replyTo)
            var result = "Draft #\(draft.id ?? 0) created:\n  To: \(to)\n  Subject: \(subject)"
            if !cc.isEmpty { result += "\n  Cc: \(cc)" }
            if !bcc.isEmpty { result += "\n  Bcc: \(bcc)" }
            if let replyTo { result += "\n  In reply to message #\(replyTo)" }
            result += "\n  Body: \(String(body.prefix(200)))"
            if body.count > 200 { result += "..." }
            return result

        case "update_draft":
            let draftId = Self.int64Arg(args, "draft_id")
            let to = args["to"] as? String
            let cc = args["cc"] as? String
            let bcc = args["bcc"] as? String
            let subject = args["subject"] as? String
            let body = args["body"] as? String
            let updated = try FlushEngine.updateDraft(db: db, draftId: draftId, to: to, cc: cc, bcc: bcc,
                                                       subject: subject, body: body)
            return updated ? "Draft #\(draftId) updated." : "No changes to draft #\(draftId)."

        case "remove_draft":
            let draftId = Self.int64Arg(args, "draft_id")
            let removed = try FlushEngine.removeDraft(db: db, draftId: draftId)
            return removed ? "Draft #\(draftId) removed." : "Draft #\(draftId) not found."

        case "show_drafts":
            let drafts = try await db.read { db in try DraftEmailRepository.getAll(db) }
            guard !drafts.isEmpty else { return "No draft emails pending." }
            var lines: [String] = ["\(drafts.count) draft(s) pending:"]
            for d in drafts {
                lines.append("  [#\(d.id ?? 0)] To: \(d.toRecipients) | Subject: \(String(d.subject.prefix(50)))")
                if !d.ccRecipients.isEmpty { lines.append("         Cc: \(d.ccRecipients)") }
                lines.append("         Body: \(String(d.body.prefix(100)))\(d.body.count > 100 ? "..." : "")")
            }
            return lines.joined(separator: "\n")

        case "send_drafts":
            let dryRun = args["dry_run"] as? Bool ?? false
            let progress = onProgress
            let result = try await FlushEngine.sendDrafts(db: db, dryRun: dryRun, progress: { done, total in
                progress?("Sending: \(done)/\(total) emails")
            })
            if result.sent == 0 && result.errors.isEmpty { return "No drafts to send." }
            let prefix = dryRun ? "[DRY RUN] " : ""
            var lines = ["\(prefix)\(result.sent) email(s) sent."]
            if !result.errors.isEmpty {
                lines.append("\(result.errors.count) error(s):")
                for e in result.errors { lines.append("  \(e)") }
            }
            return lines.joined(separator: "\n")

        case "sender_histogram":
            let folder = args["folder"] as? String
            let minCount = args["min_count"] as? Int ?? 1
            let page = args["page"] as? Int ?? 1
            let pageSize = args["page_size"] as? Int ?? 50
            let includeDeleted = args["include_deleted"] as? Bool ?? false
            return try await db.read { db in
                let result = try SearchRepository.senderHistogram(
                    db, folder: folder, minCount: minCount,
                    page: page, pageSize: pageSize, includeDeleted: includeDeleted
                )
                let senders = result["senders"] as? [[String: Any]] ?? []
                let total = result["total"] as? Int ?? 0
                let histPage = result["page"] as? Int ?? 1
                var lines = ["Unique senders: \(total) (page \(histPage))\n"]
                for s in senders {
                    let count = s["count"] as? Int ?? 0
                    let email = s["email"] as? String ?? ""
                    lines.append("  \(String(format: "%5d", count))x  \(email)")
                }
                if result["has_more"] as? Bool == true {
                    lines.append("\n  ... more results (page \(histPage + 1))")
                }
                return lines.joined(separator: "\n")
            }

        case "get_summary":
            return try await db.read { db in
                let stats = try SearchRepository.getSummary(db)
                var lines = [
                    "Total: \(stats["total_messages"] ?? 0)",
                    "Unread: \(stats["unread_count"] ?? 0)",
                    "Flagged: \(stats["flagged_count"] ?? 0)",
                    "", "By folder:",
                ]
                if let byFolder = stats["by_folder"] as? [String: Int] {
                    for (folder, count) in byFolder { lines.append("  \(folder): \(count)") }
                }
                if let topSenders = stats["top_senders"] as? [[String: Any]] {
                    lines.append("\nTop senders:")
                    for s in topSenders.prefix(10) {
                        let senderName = (s["name"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? (s["email"] as? String ?? "")
                        lines.append("  \(senderName): \(s["count"] ?? 0)")
                    }
                }
                return lines.joined(separator: "\n")
            }

        case "list_folders":
            let imap = IMAPClient()
            try await imap.connect(email: KeychainManager.icloudEmail, password: KeychainManager.icloudPassword)
            let remoteFolders = try await imap.listFolders()
            await imap.disconnect()

            let (localFolders, stagedCounts) = try await db.read { db -> ([Folder], [String: Int]) in
                let folders = try FolderRepository.getAll(db)
                let counts = try StagedChangeRepository.countByFolder(db)
                return (folders, counts)
            }
            let localMap = Dictionary(uniqueKeysWithValues: localFolders.map { ($0.name, $0) })
            var lines: [String] = []
            for rf in remoteFolders {
                let lf = localMap[rf.name]
                let staged = stagedCounts[rf.name] ?? 0
                let status = lf?.lastSyncAt != nil ? "synced (\(lf?.messageCount ?? 0) msgs)" : "not synced"
                let stagedStr = staged > 0 ? " [\(staged) staged]" : ""
                lines.append("  \(rf.name) - \(status)\(stagedStr)")
            }
            return "Folders (\(remoteFolders.count)):\n" + lines.joined(separator: "\n")

        case "create_rule":
            let name = args["name"] as? String ?? ""
            let conditions = args["conditions"] as? [[String: String]] ?? []
            let action = args["action"] as? String ?? ""
            let actionTarget = args["action_target"] as? String
            let priority = args["priority"] as? Int ?? 100
            let rule = try await db.write { db in
                try RuleRepository.insert(db, name: name, conditions: conditions,
                                          action: action, actionTarget: actionTarget, priority: priority)
            }
            return Self.formatRule(rule)

        case "list_rules":
            let rules = try await db.read { db in try RuleRepository.getAll(db) }
            guard !rules.isEmpty else { return "No rules defined." }
            var lines = ["Rules (\(rules.count)):"]
            for r in rules {
                let status = r.enabled ? "enabled" : "disabled"
                let conds = r.conditions.map { "\($0.field) \($0.op) '\($0.value)'" }.joined(separator: ", ")
                var actionDesc = r.action
                if let t = r.actionTarget { actionDesc += " -> \(t)" }
                lines.append("  [\(r.id ?? 0)] \(r.name) (\(status))")
                lines.append("       IF \(conds)")
                lines.append("       THEN \(actionDesc)")
            }
            return lines.joined(separator: "\n")

        case "apply_rules":
            let folder = args["folder"] as? String
            let ruleId = (args["rule_id"] as? Int).map(Int64.init)
            let result = try RulesEngine.applyRules(db: db, folder: folder, ruleId: ruleId)
            return Self.formatApplyResult(result)

        case "apply_ad_hoc":
            let conditions = args["conditions"] as? [[String: String]] ?? []
            let action = args["action"] as? String ?? ""
            let actionTarget = args["action_target"] as? String
            let folder = args["folder"] as? String
            let limit = args["limit"] as? Int ?? 500
            let result = try RulesEngine.applyAdHoc(
                db: db, conditions: conditions, action: action,
                actionTarget: actionTarget, folder: folder, limit: limit
            )
            return Self.formatApplyResult(result)

        // Calendar tools
        case "list_calendars":
            return try await calendarService.listCalendars()
        case "get_events":
            return try await calendarService.getEvents(
                startDate: args["start_date"] as? String ?? "",
                endDate: args["end_date"] as? String ?? "",
                calendarName: args["calendar_name"] as? String
            )
        case "get_event":
            return try await calendarService.getEvent(eventId: args["event_id"] as? String ?? "")
        case "create_event":
            return try await calendarService.createEvent(
                title: args["title"] as? String ?? "",
                startDate: args["start_date"] as? String ?? "",
                endDate: args["end_date"] as? String ?? "",
                calendarName: args["calendar_name"] as? String,
                location: args["location"] as? String,
                notes: args["notes"] as? String,
                allDay: args["all_day"] as? Bool ?? false
            )
        case "update_event":
            return try await calendarService.updateEvent(
                eventId: args["event_id"] as? String ?? "",
                title: args["title"] as? String,
                startDate: args["start_date"] as? String,
                endDate: args["end_date"] as? String,
                location: args["location"] as? String,
                notes: args["notes"] as? String
            )
        case "delete_event":
            return try await calendarService.deleteEvent(eventId: args["event_id"] as? String ?? "")
        case "search_events":
            return try await calendarService.searchEvents(
                query: args["query"] as? String ?? "",
                startDate: args["start_date"] as? String,
                endDate: args["end_date"] as? String
            )

        // Contacts tools
        case "resolve_contacts":
            let identifiers = args["identifiers"] as? [String] ?? []
            guard !identifiers.isEmpty else { return "No identifiers provided." }
            return Self.resolveContacts(identifiers)

        // iMessage/SMS tools
        case "sync_imessage_conversations":
            guard let svc = messagesService else { return "Messages companion not configured. Set up in Settings." }
            let limit = args["limit"] as? Int ?? 50
            let since = args["since"] as? String
            return try await svc.syncConversations(limit: limit, since: since)

        case "sync_all_imessages":
            guard let svc = messagesService else { return "Messages companion not configured. Set up in Settings." }
            let convId = Self.int64Arg(args, "conversation_id")
            let before = args["before"] as? String
            let after = args["after"] as? String
            let progress = onProgress
            return try await svc.syncAllMessages(chatId: convId, before: before, after: after, progress: { synced, _ in
                progress?("Syncing messages: \(synced) fetched...")
            })

        case "sync_all_imessages_for":
            guard let svc = messagesService else { return "Messages companion not configured. Set up in Settings." }
            let identifier = args["identifier"] as? String ?? ""
            let before = args["before"] as? String
            let after = args["after"] as? String
            let progress = onProgress

            // Look up conversation by identifier; sync conversations first if not found
            var conv = try await svc.getConversationByIdentifier(identifier)
            if conv == nil {
                progress?("Syncing conversations to find \(identifier)...")
                _ = try await svc.syncConversations(limit: 200)
                conv = try await svc.getConversationByIdentifier(identifier)
            }
            guard let conv, let convId = conv.id else {
                return "No conversation found for '\(identifier)'. Try sync_imessage_conversations first."
            }
            let name = conv.displayName.isEmpty ? conv.chatIdentifier : conv.displayName
            progress?("Found \(name), fetching messages...")
            return try await svc.syncAllMessages(chatId: convId, before: before, after: after, progress: { synced, _ in
                progress?("Syncing \(name): \(synced) messages fetched...")
            })

        case "list_imessage_conversations":
            guard let svc = messagesService else { return "Messages companion not configured. Set up in Settings." }
            let limit = args["limit"] as? Int ?? 50
            let offset = args["offset"] as? Int ?? 0
            let conversations = try await svc.listConversations(limit: limit, offset: offset)
            guard !conversations.isEmpty else { return "No cached iMessage conversations. Try sync_imessage_conversations first." }
            var lines = ["\(conversations.count) conversation(s):"]
            for c in conversations {
                let name = c.displayName.isEmpty ? c.chatIdentifier : c.displayName
                let group = c.isGroup == 1 ? " [group]" : ""
                let date = String(c.lastMessageDate.prefix(10))
                lines.append("  [\(c.id ?? 0)] \(name)\(group) | \(c.participants) | \(date) | \(c.messageCount) msgs")
            }
            return lines.joined(separator: "\n")

        case "get_imessage_conversation":
            guard let svc = messagesService else { return "Messages companion not configured. Set up in Settings." }
            let convId = Self.int64Arg(args, "conversation_id")
            guard let conv = try await svc.getConversation(chatId: convId) else {
                return "Conversation \(convId) not found."
            }
            let name = conv.displayName.isEmpty ? conv.chatIdentifier : conv.displayName
            return """
                ID: \(conv.id ?? 0)
                Name: \(name)
                Identifier: \(conv.chatIdentifier)
                Service: \(conv.serviceName)
                Group: \(conv.isGroup == 1 ? "Yes" : "No")
                Participants: \(conv.participants)
                Messages: \(conv.messageCount)
                Last message: \(conv.lastMessageDate)
                Last synced: \(conv.lastSyncedAt ?? "never")
                """

        case "get_imessages":
            guard let svc = messagesService else { return "Messages companion not configured. Set up in Settings." }
            let convId = Self.int64Arg(args, "conversation_id")
            let limit = args["limit"] as? Int ?? 50
            let before = args["before"] as? String
            let after = args["after"] as? String
            let ascending = (args["sort"] as? String)?.lowercased() == "oldest"
            let messages = try await svc.getMessages(chatId: convId, limit: limit, before: before, after: after, ascending: ascending)
            guard !messages.isEmpty else { return "No cached messages. Try sync_imessages first." }
            var lines = ["\(messages.count) message(s):"]
            for m in messages {
                let who = m.isFromMe == 1 ? "me" : m.sender
                let date = String(m.date.prefix(19))
                let text = String(m.text.prefix(100))
                lines.append("  [\(m.id ?? 0)] \(date) | \(who): \(text)")
            }
            return lines.joined(separator: "\n")

        case "search_imessages":
            guard let svc = messagesService else { return "Messages companion not configured. Set up in Settings." }
            let query = args["query"] as? String ?? ""
            let convId: Int64? = (args["conversation_id"] as? Int).map(Int64.init)
                ?? (args["conversation_id"] as? Double).map { Int64($0) }
            let limit = args["limit"] as? Int ?? 20
            let messages = try await svc.searchMessages(query: query, conversationId: convId, limit: limit)
            guard !messages.isEmpty else { return "No messages matching '\(query)'." }
            var lines = ["\(messages.count) result(s) for '\(query)':"]
            for m in messages {
                let who = m.isFromMe == 1 ? "me" : m.sender
                let date = String(m.date.prefix(19))
                let text = String(m.text.prefix(100))
                lines.append("  [\(m.id ?? 0)] conv:\(m.conversationId) \(date) | \(who): \(text)")
            }
            return lines.joined(separator: "\n")

        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: - Helpers (nonisolated for use in Sendable closures)

    nonisolated private static func intArg(_ args: [String: Any], _ key: String) -> Int {
        if let v = args[key] as? Int { return v }
        if let v = args[key] as? Double { return Int(v) }
        if let v = args[key] as? String { return Int(v) ?? 0 }
        return 0
    }

    nonisolated private static func int64Arg(_ args: [String: Any], _ key: String) -> Int64 {
        Int64(intArg(args, key))
    }

    nonisolated private static func formatSearchResult(_ result: SearchResult) -> String {
        var lines = ["Results: \(result.total) total (page \(result.page), \(result.pageSize)/page)\n"]
        for msg in result.messages {
            let dateStr = msg.date.isEmpty ? "?" : String(msg.date.prefix(10))
            let flags = msg.flags.isEmpty ? "" : " [\(msg.flags)]"
            let email = msg.senderEmail.padding(toLength: 30, withPad: " ", startingAt: 0)
            lines.append("  [\(msg.id ?? 0)] \(dateStr) | \(email) | \(String(msg.subject.prefix(60)))\(flags)")
        }
        if result.hasMore { lines.append("\n  ... more results (page \(result.page + 1))") }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func formatRule(_ rule: Rule) -> String {
        let status = rule.enabled ? "enabled" : "disabled"
        var lines = [
            "Rule #\(rule.id ?? 0): \(rule.name)",
            "Priority: \(rule.priority) | Status: \(status)",
            "Action: \(rule.action)" + (rule.actionTarget.map { " -> \($0)" } ?? ""),
            "Conditions:",
        ]
        for c in rule.conditions { lines.append("  \(c.field) \(c.op) '\(c.value)'") }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func resolveContacts(_ identifiers: [String]) -> String {
        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        var results: [String] = []
        for identifier in identifiers {
            let cleaned = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            var matched: CNContact?

            // Try as phone number
            let phoneNumber = CNPhoneNumber(stringValue: cleaned)
            let phonePredicate = CNContact.predicateForContacts(matching: phoneNumber)
            if let contacts = try? store.unifiedContacts(matching: phonePredicate, keysToFetch: keysToFetch),
               let first = contacts.first {
                matched = first
            }

            // Try as email if phone didn't match
            if matched == nil {
                let emailPredicate = CNContact.predicateForContacts(matchingEmailAddress: cleaned)
                if let contacts = try? store.unifiedContacts(matching: emailPredicate, keysToFetch: keysToFetch),
                   let first = contacts.first {
                    matched = first
                }
            }

            if let contact = matched {
                var name = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if name.isEmpty { name = contact.organizationName }
                if name.isEmpty { name = "(no name)" }
                results.append("  \(cleaned) → \(name)")
            } else {
                results.append("  \(cleaned) → (unknown)")
            }
        }
        return "Resolved \(identifiers.count) identifier(s):\n" + results.joined(separator: "\n")
    }

    nonisolated private static func formatApplyResult(_ result: ApplyRulesResult) -> String {
        var lines = [
            "Rules evaluated: \(result.rulesEvaluated)",
            "Messages scanned: \(result.messagesScanned)",
            "Changes staged: \(result.changesStaged)",
        ]
        if result.skippedNoOp > 0 { lines.append("Skipped (no-op): \(result.skippedNoOp)") }
        if result.skippedAlreadyStaged > 0 { lines.append("Skipped (already staged): \(result.skippedAlreadyStaged)") }
        if !result.errors.isEmpty {
            lines.append("Errors: \(result.errors.count)")
            for e in result.errors { lines.append("  \(e)") }
        }
        if !result.details.isEmpty {
            lines.append("")
            for d in result.details { lines.append("  \(d)") }
        }
        return lines.joined(separator: "\n")
    }
}
