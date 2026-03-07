import Foundation
import GRDB

/// Rules engine — match conditions against messages, stage bulk changes.
/// Port of rules.py.
enum RulesEngine {
    static func applyOperator(fieldValue: String, op: String, target: String) -> Bool {
        let fv = fieldValue.lowercased()
        let tv = target.lowercased()
        switch op {
        case "contains": return fv.contains(tv)
        case "not_contains": return !fv.contains(tv)
        case "equals": return fv == tv
        case "not_equals": return fv != tv
        case "starts_with": return fv.hasPrefix(tv)
        case "ends_with": return fv.hasSuffix(tv)
        case "matches":
            return (try? NSRegularExpression(pattern: target, options: .caseInsensitive)
                .firstMatch(in: fieldValue, range: NSRange(fieldValue.startIndex..., in: fieldValue))) != nil
        default: return false
        }
    }

    static func getFieldValue(_ msg: Message, field: String) -> String {
        switch field {
        case "sender_email": return msg.senderEmail
        case "sender": return msg.sender
        case "subject": return msg.subject
        case "body_text": return msg.bodyText
        case "folder": return msg.folder
        case "flags": return msg.flags
        case "recipients": return msg.recipients
        default: return ""
        }
    }

    static func matchCondition(_ msg: Message, condition: RuleCondition) -> Bool {
        let value = getFieldValue(msg, field: condition.field)
        return applyOperator(fieldValue: value, op: condition.op, target: condition.value)
    }

    static func matchRule(_ msg: Message, rule: Rule) -> Bool {
        guard !rule.conditions.isEmpty else { return false }
        return rule.conditions.allSatisfy { matchCondition(msg, condition: $0) }
    }

    static func isNoOp(_ msg: Message, rule: Rule) -> Bool {
        switch rule.action {
        case "move": return msg.folder == rule.actionTarget
        case "flag":
            let flag = FlushEngine.resolveFlag(rule.actionTarget ?? "")
            return msg.flags.contains(flag)
        case "unflag":
            let flag = FlushEngine.resolveFlag(rule.actionTarget ?? "")
            return !msg.flags.contains(flag)
        default: return false
        }
    }

    // MARK: - Apply

    static func applyRules(db: DatabaseQueue, folder: String? = nil, ruleId: Int64? = nil) throws -> ApplyRulesResult {
        try db.write { db in
            var result = ApplyRulesResult()
            let rules: [Rule]
            if let ruleId {
                guard let rule = try RuleRepository.getById(db, ruleId: ruleId) else {
                    result.errors.append("Rule \(ruleId) not found")
                    return result
                }
                rules = [rule]
            } else {
                rules = try RuleRepository.getAll(db).filter(\.enabled)
            }

            result.rulesEvaluated = rules.count
            guard !rules.isEmpty else { return result }

            var sql = "SELECT * FROM messages"
            var args: [any DatabaseValueConvertible] = []
            if let folder, !folder.isEmpty {
                sql += " WHERE folder = ?"
                args.append(folder)
            }
            sql += " ORDER BY date_epoch DESC"

            let messages = try Message.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            result.messagesScanned = messages.count

            var claimed = Set<Int64>()

            for rule in rules {
                var ruleMatches = 0
                for msg in messages {
                    guard let msgId = msg.id, !claimed.contains(msgId) else { continue }
                    guard matchRule(msg, rule: rule) else { continue }

                    if isNoOp(msg, rule: rule) {
                        result.skippedNoOp += 1
                        claimed.insert(msgId)
                        continue
                    }

                    let existing = try StagedChangeRepository.getForMessage(db, messageId: msgId)
                    if !existing.isEmpty {
                        result.skippedAlreadyStaged += 1
                        claimed.insert(msgId)
                        continue
                    }

                    if try stageForRule(db, msg: msg, rule: rule) {
                        result.changesStaged += 1
                        ruleMatches += 1
                        claimed.insert(msgId)
                    }
                }

                var actionDesc = rule.action
                if let target = rule.actionTarget { actionDesc += " -> \(target)" }
                result.details.append("Rule '\(rule.name)': \(ruleMatches) staged (\(actionDesc))")
            }

            return result
        }
    }

    static func applyAdHoc(db: DatabaseQueue, conditions: [[String: String]], action: String,
                           actionTarget: String? = nil, folder: String? = nil, limit: Int = 500) throws -> ApplyRulesResult {
        try db.write { db in
            let parsed = conditions.map { RuleCondition(field: $0["field"] ?? "", op: $0["op"] ?? "", value: $0["value"] ?? "") }
            let tempRule = Rule(name: "(ad-hoc)", conditions: parsed, action: action, actionTarget: actionTarget)

            var result = ApplyRulesResult(rulesEvaluated: 1)

            var sql = "SELECT * FROM messages"
            var args: [any DatabaseValueConvertible] = []
            if let folder, !folder.isEmpty {
                sql += " WHERE folder = ?"
                args.append(folder)
            }
            sql += " ORDER BY date_epoch DESC"

            let messages = try Message.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            result.messagesScanned = messages.count

            var staged = 0
            for msg in messages {
                guard staged < limit else { break }
                guard let msgId = msg.id else { continue }
                guard matchRule(msg, rule: tempRule) else { continue }

                if isNoOp(msg, rule: tempRule) {
                    result.skippedNoOp += 1
                    continue
                }

                let existing = try StagedChangeRepository.getForMessage(db, messageId: msgId)
                if !existing.isEmpty {
                    result.skippedAlreadyStaged += 1
                    continue
                }

                if try stageForRule(db, msg: msg, rule: tempRule) {
                    result.changesStaged += 1
                    staged += 1
                }
            }

            var actionDesc = action
            if let actionTarget { actionDesc += " -> \(actionTarget)" }
            result.details.append("Ad-hoc rule: \(staged) staged (\(actionDesc))")

            return result
        }
    }

    // MARK: - Private

    private static func stageForRule(_ db: Database, msg: Message, rule: Rule) throws -> Bool {
        guard let msgId = msg.id else { return false }
        var change: [String: Any] = [
            "message_id": msgId,
            "folder": msg.folder,
            "uid": msg.uid,
        ]
        switch rule.action {
        case "move":
            change["change_type"] = "move"
            change["target_folder"] = rule.actionTarget
        case "flag":
            change["change_type"] = "flag"
            change["flag_name"] = FlushEngine.resolveFlag(rule.actionTarget ?? "")
        case "unflag":
            change["change_type"] = "unflag"
            change["flag_name"] = FlushEngine.resolveFlag(rule.actionTarget ?? "")
        case "delete":
            change["change_type"] = "delete"
        default:
            return false
        }
        _ = try StagedChangeRepository.insert(db, change: change)
        return true
    }
}
