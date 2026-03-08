import Foundation
import GRDB
import os

/// Stage/unstage changes and flush to IMAP. Port of staging.py.
enum FlushEngine {
    private static let logger = Logger(subsystem: "Secretary", category: "FlushEngine")

    static let flagMap: [String: String] = [
        "seen": "\\Seen",
        "flagged": "\\Flagged",
        "answered": "\\Answered",
        "draft": "\\Draft",
        "deleted": "\\Deleted",
    ]

    static func resolveFlag(_ name: String) -> String {
        flagMap[name.lowercased()] ?? name
    }

    // MARK: - Stage operations

    static func stageMove(db: DatabaseQueue, messageId: Int64, targetFolder: String) throws -> StagedChange {
        try db.write { db in
            guard let msg = try MessageRepository.getById(db, id: messageId) else {
                throw SecretaryError.notFound("Message \(messageId) not found")
            }
            let existing = try StagedChangeRepository.getForMessage(db, messageId: messageId)
            for change in existing {
                if change.changeType == "delete" {
                    throw SecretaryError.validation("Message \(messageId) is already staged for deletion")
                }
                if change.changeType == "move" {
                    throw SecretaryError.validation("Message \(messageId) is already staged for a move to \(change.targetFolder ?? "")")
                }
            }
            let changeId = try StagedChangeRepository.insert(db, change: [
                "change_type": "move",
                "message_id": messageId,
                "folder": msg.folder,
                "uid": msg.uid,
                "target_folder": targetFolder,
            ])
            return StagedChange(id: changeId, changeType: "move", messageId: messageId,
                                folder: msg.folder, uid: msg.uid, targetFolder: targetFolder)
        }
    }

    static func stageFlag(db: DatabaseQueue, messageId: Int64, flagName: String, remove: Bool = false) throws -> StagedChange {
        try db.write { db in
            guard let msg = try MessageRepository.getById(db, id: messageId) else {
                throw SecretaryError.notFound("Message \(messageId) not found")
            }
            let imapFlag = resolveFlag(flagName)
            let changeType = remove ? "unflag" : "flag"

            let existing = try StagedChangeRepository.getForMessage(db, messageId: messageId)
            for change in existing {
                if change.changeType == "delete" {
                    throw SecretaryError.validation("Message \(messageId) is staged for deletion")
                }
                if (change.changeType == "flag" || change.changeType == "unflag") && change.flagName == imapFlag {
                    throw SecretaryError.validation("Message \(messageId) already has a staged \(change.changeType) for \(flagName)")
                }
            }
            let changeId = try StagedChangeRepository.insert(db, change: [
                "change_type": changeType,
                "message_id": messageId,
                "folder": msg.folder,
                "uid": msg.uid,
                "flag_name": imapFlag,
            ])
            return StagedChange(id: changeId, changeType: changeType, messageId: messageId,
                                folder: msg.folder, uid: msg.uid, flagName: imapFlag)
        }
    }

    static func stageDelete(db: DatabaseQueue, messageId: Int64) throws -> StagedChange {
        try db.write { db in
            guard let msg = try MessageRepository.getById(db, id: messageId) else {
                throw SecretaryError.notFound("Message \(messageId) not found")
            }
            let existing = try StagedChangeRepository.getForMessage(db, messageId: messageId)
            for change in existing {
                if change.changeType == "move" {
                    throw SecretaryError.validation("Message \(messageId) is staged for a move — unstage it first")
                }
                if change.changeType == "delete" {
                    throw SecretaryError.validation("Message \(messageId) is already staged for deletion")
                }
            }
            let changeId = try StagedChangeRepository.insert(db, change: [
                "change_type": "delete",
                "message_id": messageId,
                "folder": msg.folder,
                "uid": msg.uid,
            ])
            return StagedChange(id: changeId, changeType: "delete", messageId: messageId,
                                folder: msg.folder, uid: msg.uid)
        }
    }

    static func unstage(db: DatabaseQueue, changeId: Int64) throws -> Bool {
        try db.write { db in try StagedChangeRepository.delete(db, changeId: changeId) }
    }

    // MARK: - Draft Email operations

    static func composeDraft(db: DatabaseQueue, to: String, cc: String, bcc: String,
                             subject: String, body: String, replyToMessageId: Int64?) throws -> DraftEmail {
        try db.write { db in
            // If replying, verify the source message exists
            if let replyId = replyToMessageId {
                guard try MessageRepository.getById(db, id: replyId) != nil else {
                    throw SecretaryError.notFound("Message \(replyId) not found")
                }
            }
            guard !to.isEmpty else {
                throw SecretaryError.validation("At least one 'to' recipient is required")
            }
            let draftId = try DraftEmailRepository.insert(db, to: to, cc: cc, bcc: bcc,
                                                           subject: subject, body: body,
                                                           replyToMessageId: replyToMessageId)
            return DraftEmail(id: draftId, toRecipients: to, ccRecipients: cc, bccRecipients: bcc,
                              subject: subject, body: body, replyToMessageId: replyToMessageId)
        }
    }

    static func updateDraft(db: DatabaseQueue, draftId: Int64, to: String?, cc: String?, bcc: String?,
                            subject: String?, body: String?) throws -> Bool {
        try db.write { db in
            guard try DraftEmailRepository.getById(db, id: draftId) != nil else {
                throw SecretaryError.notFound("Draft \(draftId) not found")
            }
            return try DraftEmailRepository.update(db, id: draftId, to: to, cc: cc, bcc: bcc,
                                                    subject: subject, body: body)
        }
    }

    static func removeDraft(db: DatabaseQueue, draftId: Int64) throws -> Bool {
        try db.write { db in try DraftEmailRepository.delete(db, id: draftId) }
    }

    // MARK: - Send Drafts

    struct SendResult {
        var sent: Int = 0
        var errors: [String] = []
    }

    static func sendDrafts(
        db: DatabaseQueue,
        dryRun: Bool = false,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> SendResult {
        let drafts = try await db.read { db in try DraftEmailRepository.getAll(db) }
        guard !drafts.isEmpty else { return SendResult() }

        if dryRun {
            return SendResult(sent: drafts.count)
        }

        let senderEmail = KeychainManager.icloudEmail
        let total = drafts.count
        var done = 0
        var result = SendResult()

        let smtp = SMTPClient()
        try await smtp.connect(email: senderEmail, password: KeychainManager.icloudPassword)
        defer { Task { await smtp.disconnect() } }

        for draft in drafts {
            let toList = draft.toRecipients.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let ccList = draft.ccRecipients.isEmpty ? [] : draft.ccRecipients.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let bccList = draft.bccRecipients.isEmpty ? [] : draft.bccRecipients.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

            // Resolve In-Reply-To header from source message
            var inReplyTo: String? = nil
            if let replyId = draft.replyToMessageId {
                inReplyTo = try await db.read { db in
                    try MessageRepository.getById(db, id: replyId)?.messageId
                }
            }

            do {
                if done > 0 { try await smtp.reset() }
                _ = try await smtp.send(from: senderEmail, to: toList, cc: ccList, bcc: bccList,
                                        subject: draft.subject, body: draft.body, inReplyTo: inReplyTo)
                result.sent += 1
                // Remove the sent draft
                try await db.write { db in _ = try DraftEmailRepository.delete(db, id: draft.id!) }
            } catch {
                result.errors.append("Draft \(draft.id ?? 0) (\(draft.subject)): \(error.localizedDescription)")
            }
            done += 1
            progress?(done, total)
        }

        // Log the send operation
        let sentCount = result.sent
        try await db.write { db in
            try SyncLogRepository.log(db, folder: "Sent Messages", action: "send",
                                      messagesSynced: sentCount, details: ["sent": sentCount])
        }

        return result
    }

    // MARK: - Flush

    static func flushChanges(
        db: DatabaseQueue,
        dryRun: Bool = false,
        progress: ((Int, Int) -> Void)? = nil,
        syncProgress: ((String, Int, Int) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) async throws -> [FlushResult] {
        let changes = try await db.read { db in try StagedChangeRepository.getAll(db) }
        guard !changes.isEmpty else { return [] }

        let total = changes.count
        var done = 0
        let isCancelled = { cancelled?() ?? false }

        // Group by source folder
        var byFolder: [String: [StagedChange]] = [:]
        for c in changes {
            byFolder[c.folder, default: []].append(c)
        }

        if dryRun {
            return byFolder.map { (folder, folderChanges) in
                var r = FlushResult(folder: folder)
                for c in folderChanges {
                    switch c.changeType {
                    case "flag": r.flagsSet += 1
                    case "unflag": r.flagsRemoved += 1
                    case "move": r.moved += 1
                    case "delete": r.deleted += 1
                    default: break
                    }
                }
                return r
            }
        }

        var results: [FlushResult] = []
        let imap = IMAPClient()
        try await imap.connect(email: KeychainManager.icloudEmail, password: KeychainManager.icloudPassword)
        defer { Task { await imap.disconnect() } }

        for (folder, folderChanges) in byFolder {
            if isCancelled() { break }
            var flushResult = FlushResult(folder: folder)
            var needsExpunge = false

            do {
                _ = try await imap.selectFolder(folder, readonly: false)
            } catch {
                flushResult.errors.append("Could not select \(folder): \(error)")
                results.append(flushResult)
                done += folderChanges.count
                progress?(done, total)
                continue
            }

            // Phase 1: Flag changes
            let flagChanges = folderChanges.filter { $0.changeType == "flag" || $0.changeType == "unflag" }
            var flagGroups: [String: [StagedChange]] = [:]
            for c in flagChanges {
                let key = "\(c.changeType)|\(c.flagName ?? "")"
                flagGroups[key, default: []].append(c)
            }

            for (_, group) in flagGroups {
                for i in stride(from: 0, to: group.count, by: AppConfig.flushBatchSize) {
                    if isCancelled() { break }
                    let batch = Array(group[i..<min(i + AppConfig.flushBatchSize, group.count)])
                    let uids = batch.map(\.uid)
                    let isAdd = batch[0].changeType == "flag"
                    let flagName = batch[0].flagName ?? ""
                    do {
                        if isAdd {
                            try await imap.addFlags(uids: uids, flags: "(\(flagName))")
                            flushResult.flagsSet += batch.count
                        } else {
                            try await imap.removeFlags(uids: uids, flags: "(\(flagName))")
                            flushResult.flagsRemoved += batch.count
                        }
                        let idsToDelete = batch.compactMap(\.id)
                        let messageIds = batch.map(\.messageId)
                        try await db.write { db in
                            _ = try StagedChangeRepository.deleteBulk(db, changeIds: idsToDelete)
                            // Update local message flags to match IMAP
                            for msgId in messageIds {
                                if let msg = try MessageRepository.getById(db, id: msgId) {
                                    let updatedFlags: String
                                    if isAdd {
                                        if msg.flags.contains(flagName) {
                                            updatedFlags = msg.flags
                                        } else {
                                            updatedFlags = msg.flags.isEmpty ? flagName : "\(msg.flags) \(flagName)"
                                        }
                                    } else {
                                        updatedFlags = msg.flags
                                            .replacingOccurrences(of: flagName, with: "")
                                            .replacingOccurrences(of: "  ", with: " ")
                                            .trimmingCharacters(in: .whitespaces)
                                    }
                                    try MessageRepository.updateFlags(db, messageId: msgId, flags: updatedFlags)
                                }
                            }
                        }
                    } catch {
                        flushResult.errors.append("Flag batch: \(error)")
                    }
                    done += batch.count
                    progress?(done, total)
                }
            }

            // Phase 2: Moves
            let moveChanges = folderChanges.filter { $0.changeType == "move" }
            var moveGroups: [String: [StagedChange]] = [:]
            for c in moveChanges {
                moveGroups[c.targetFolder ?? "", default: []].append(c)
            }

            for (target, group) in moveGroups {
                for i in stride(from: 0, to: group.count, by: AppConfig.flushBatchSize) {
                    if isCancelled() { break }
                    let batch = Array(group[i..<min(i + AppConfig.flushBatchSize, group.count)])
                    let uids = batch.map(\.uid)
                    do {
                        try await imap.copy(uids: uids, targetFolder: target)
                        try await imap.markDeleted(uids: uids)
                        needsExpunge = true
                        flushResult.moved += batch.count
                        let changeIds = batch.compactMap(\.id)
                        let msgIds = batch.map(\.messageId)
                        try await db.write { db in
                            _ = try StagedChangeRepository.deleteBulk(db, changeIds: changeIds)
                            _ = try MessageRepository.deleteBulk(db, messageIds: msgIds)
                        }
                    } catch {
                        flushResult.errors.append("Move batch -> \(target): \(error)")
                    }
                    done += batch.count
                    progress?(done, total)
                }
            }

            // Phase 3: Deletes
            let deleteChanges = folderChanges.filter { $0.changeType == "delete" }
            for i in stride(from: 0, to: deleteChanges.count, by: AppConfig.flushBatchSize) {
                if isCancelled() { break }
                let batch = Array(deleteChanges[i..<min(i + AppConfig.flushBatchSize, deleteChanges.count)])
                let uids = batch.map(\.uid)
                do {
                    try await imap.markDeleted(uids: uids)
                    needsExpunge = true
                    flushResult.deleted += batch.count
                    let changeIds = batch.compactMap(\.id)
                    let msgIds = batch.map(\.messageId)
                    try await db.write { db in
                        _ = try StagedChangeRepository.deleteBulk(db, changeIds: changeIds)
                        _ = try MessageRepository.deleteBulk(db, messageIds: msgIds)
                    }
                } catch {
                    flushResult.errors.append("Delete batch: \(error)")
                }
                done += batch.count
                progress?(done, total)
            }

            // Phase 4: Expunge
            if needsExpunge {
                do { try await imap.expunge() } catch {
                    flushResult.errors.append("Expunge: \(error)")
                }
            }

            results.append(flushResult)
            let logFlagsSet = flushResult.flagsSet
            let logFlagsRemoved = flushResult.flagsRemoved
            let logMoved = flushResult.moved
            let logDeleted = flushResult.deleted
            try await db.write { db in
                try SyncLogRepository.log(db, folder: folder, action: "flush",
                                          messagesSynced: logMoved + logDeleted, details: [
                                              "flags_set": logFlagsSet,
                                              "flags_removed": logFlagsRemoved,
                                              "moved": logMoved,
                                              "deleted": logDeleted,
                                          ])
            }
        }

        // Post-flush re-sync
        if !isCancelled() {
            var affected = Set<String>()
            for c in changes {
                affected.insert(c.folder)
                if let target = c.targetFolder { affected.insert(target) }
            }
            for folder in affected {
                if isCancelled() { break }
                do {
                    _ = try await SyncEngine.syncFolder(db: db, folderName: folder,
                                                         progress: syncProgress)
                } catch {
                    logger.error("Post-flush sync error for \(folder): \(error)")
                }
            }
        }

        return results
    }
}
