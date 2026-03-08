import Foundation
import GRDB

enum DraftEmailRepository {
    static func insert(_ db: Database, to: String, cc: String, bcc: String,
                       subject: String, body: String, replyToMessageId: Int64?) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO draft_emails (to_recipients, cc_recipients, bcc_recipients, subject, body, reply_to_message_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [to, cc, bcc, subject, body, replyToMessageId]
        )
        return db.lastInsertedRowID
    }

    static func getAll(_ db: Database) throws -> [DraftEmail] {
        try DraftEmail.fetchAll(db, sql: "SELECT * FROM draft_emails ORDER BY created_at")
    }

    static func getById(_ db: Database, id: Int64) throws -> DraftEmail? {
        try DraftEmail.fetchOne(db, sql: "SELECT * FROM draft_emails WHERE id = ?", arguments: [id])
    }

    static func update(_ db: Database, id: Int64, to: String?, cc: String?, bcc: String?,
                       subject: String?, body: String?) throws -> Bool {
        var sets: [String] = []
        var values: [any DatabaseValueConvertible] = []

        if let to {
            sets.append("to_recipients = ?")
            values.append(to)
        }
        if let cc {
            sets.append("cc_recipients = ?")
            values.append(cc)
        }
        if let bcc {
            sets.append("bcc_recipients = ?")
            values.append(bcc)
        }
        if let subject {
            sets.append("subject = ?")
            values.append(subject)
        }
        if let body {
            sets.append("body = ?")
            values.append(body)
        }

        guard !sets.isEmpty else { return false }
        sets.append("updated_at = datetime('now')")
        values.append(id)

        try db.execute(
            sql: "UPDATE draft_emails SET \(sets.joined(separator: ", ")) WHERE id = ?",
            arguments: StatementArguments(values)
        )
        return db.changesCount > 0
    }

    static func delete(_ db: Database, id: Int64) throws -> Bool {
        try db.execute(sql: "DELETE FROM draft_emails WHERE id = ?", arguments: [id])
        return db.changesCount > 0
    }

    static func deleteAll(_ db: Database) throws -> Int {
        try db.execute(sql: "DELETE FROM draft_emails")
        return db.changesCount
    }

    static func count(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM draft_emails") ?? 0
    }
}
