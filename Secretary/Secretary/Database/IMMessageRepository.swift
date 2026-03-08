import Foundation
import GRDB

enum IMMessageRepository {
    static func upsertBatch(_ db: Database, messages: [IMMessage]) throws {
        for msg in messages {
            try db.execute(
                sql: """
                    INSERT INTO im_messages (id, conversation_id, guid, text, is_from_me, date, date_epoch, sender, service)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        text = excluded.text,
                        is_from_me = excluded.is_from_me,
                        date = excluded.date,
                        date_epoch = excluded.date_epoch,
                        sender = excluded.sender,
                        service = excluded.service
                    """,
                arguments: [
                    msg.id, msg.conversationId, msg.guid, msg.text,
                    msg.isFromMe, msg.date, msg.dateEpoch, msg.sender, msg.service,
                ]
            )
        }
    }

    static func getByConversation(_ db: Database, conversationId: Int64,
                                   limit: Int = 50, offset: Int = 0,
                                   before: String? = nil, after: String? = nil,
                                   ascending: Bool = false) throws -> [IMMessage] {
        var sql = "SELECT * FROM im_messages WHERE conversation_id = ?"
        var args: [any DatabaseValueConvertible] = [conversationId]

        if let after {
            sql += " AND date > ?"
            args.append(after)
        }
        if let before {
            sql += " AND date < ?"
            args.append(before)
        }

        let order = ascending ? "ASC" : "DESC"
        sql += " ORDER BY date_epoch \(order) LIMIT ? OFFSET ?"
        args.append(limit)
        args.append(offset)

        return try IMMessage.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    static func search(_ db: Database, query: String, conversationId: Int64? = nil, limit: Int = 20) throws -> [IMMessage] {
        // Sanitize FTS5 query: strip special characters, build prefix terms
        let cleaned = query.unicodeScalars.filter { c in
            c.properties.isAlphabetic || c.properties.isASCIIHexDigit || c == " "
        }
        let words = String(cleaned).split(separator: " ").filter { !$0.isEmpty }
        guard !words.isEmpty else {
            // Fall back to LIKE search if no valid FTS terms
            return try likeFallback(db, query: query, conversationId: conversationId, limit: limit)
        }
        let ftsQuery = words.map { "\"\($0)\"*" }.joined(separator: " ")

        if let conversationId {
            return try IMMessage.fetchAll(
                db,
                sql: """
                    SELECT im_messages.* FROM im_messages
                    JOIN im_messages_fts ON im_messages_fts.rowid = im_messages.id
                    WHERE im_messages_fts MATCH ?
                    AND im_messages.conversation_id = ?
                    ORDER BY im_messages.date_epoch DESC LIMIT ?
                    """,
                arguments: [ftsQuery, conversationId, limit]
            )
        } else {
            return try IMMessage.fetchAll(
                db,
                sql: """
                    SELECT im_messages.* FROM im_messages
                    JOIN im_messages_fts ON im_messages_fts.rowid = im_messages.id
                    WHERE im_messages_fts MATCH ?
                    ORDER BY im_messages.date_epoch DESC LIMIT ?
                    """,
                arguments: [ftsQuery, limit]
            )
        }
    }

    private static func likeFallback(_ db: Database, query: String, conversationId: Int64?, limit: Int) throws -> [IMMessage] {
        let pattern = "%\(query)%"
        if let conversationId {
            return try IMMessage.fetchAll(
                db,
                sql: "SELECT * FROM im_messages WHERE text LIKE ? AND conversation_id = ? ORDER BY date_epoch DESC LIMIT ?",
                arguments: [pattern, conversationId, limit]
            )
        } else {
            return try IMMessage.fetchAll(
                db,
                sql: "SELECT * FROM im_messages WHERE text LIKE ? ORDER BY date_epoch DESC LIMIT ?",
                arguments: [pattern, limit]
            )
        }
    }

    static func getLatestDate(_ db: Database, conversationId: Int64) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT MAX(date) FROM im_messages WHERE conversation_id = ?",
            arguments: [conversationId]
        )
    }
}
