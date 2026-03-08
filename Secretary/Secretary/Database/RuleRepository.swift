import Foundation
import GRDB

enum RuleRepository {
    static func insert(_ db: Database, name: String, conditions: [[String: String]],
                       action: String, actionTarget: String?, priority: Int = 100) throws -> Rule {
        let conditionsJSON = try validateAndSerialize(conditions)
        try db.execute(
            sql: """
                INSERT INTO rules (name, conditions, action, action_target, priority)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [name, conditionsJSON, action, actionTarget, priority]
        )
        let id = db.lastInsertedRowID
        return try getById(db, ruleId: id)!
    }

    static func getById(_ db: Database, ruleId: Int64) throws -> Rule? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM rules WHERE id = ?", arguments: [ruleId]) else {
            return nil
        }
        return try Rule(row: row)
    }

    static func getAll(_ db: Database) throws -> [Rule] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM rules ORDER BY priority, id")
        return try rows.map { try Rule(row: $0) }
    }

    static func delete(_ db: Database, ruleId: Int64) throws -> Bool {
        try db.execute(sql: "DELETE FROM rules WHERE id = ?", arguments: [ruleId])
        return db.changesCount > 0
    }

    // MARK: - Private

    private static let validFields: Set<String> = [
        "sender_email", "sender", "subject", "body_text", "folder", "flags", "recipients"
    ]

    private static let validOps: Set<String> = [
        "contains", "equals", "starts_with", "ends_with", "matches", "not_contains", "not_equals"
    ]

    private static func validateAndSerialize(_ conditions: [[String: String]]) throws -> String {
        for c in conditions {
            guard let field = c["field"], let op = c["op"], c["value"] != nil else {
                throw SecretaryError.validation("Each condition must have field, op, value")
            }
            guard validFields.contains(field) else {
                throw SecretaryError.validation("Invalid field '\(field)'")
            }
            guard validOps.contains(op) else {
                throw SecretaryError.validation("Invalid op '\(op)'")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: conditions)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

enum SecretaryError: LocalizedError {
    case validation(String)
    case imapError(String)
    case smtpError(String)
    case syncError(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .validation(let msg): return msg
        case .imapError(let msg): return msg
        case .smtpError(let msg): return msg
        case .syncError(let msg): return msg
        case .notFound(let msg): return msg
        }
    }
}
