import Foundation
import GRDB

enum MessageRepository {
    static func insert(_ db: Database, msg: [String: Any]) throws -> Int64 {
        let args: [String: (any DatabaseValueConvertible)?] = [
            "folder": msg["folder"] as? String ?? "",
            "uid": msg["uid"] as? Int ?? 0,
            "message_id": msg["message_id"] as? String ?? "",
            "subject": msg["subject"] as? String ?? "",
            "sender": msg["sender"] as? String ?? "",
            "sender_email": msg["sender_email"] as? String ?? "",
            "recipients": msg["recipients"] as? String ?? "",
            "date": msg["date"] as? String ?? "",
            "date_epoch": msg["date_epoch"] as? Int ?? 0,
            "flags": msg["flags"] as? String ?? "",
            "size": msg["size"] as? Int ?? 0,
            "body_text": msg["body_text"] as? String ?? "",
            "body_preview": msg["body_preview"] as? String ?? "",
            "raw_headers": msg["raw_headers"] as? String ?? "",
        ]
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO messages
                (folder, uid, message_id, subject, sender, sender_email, recipients,
                 date, date_epoch, flags, size, body_text, body_preview, raw_headers)
                VALUES (:folder, :uid, :message_id, :subject, :sender, :sender_email,
                        :recipients, :date, :date_epoch, :flags, :size, :body_text,
                        :body_preview, :raw_headers)
                """,
            arguments: StatementArguments(args)
        )
        return db.lastInsertedRowID
    }

    static func getById(_ db: Database, id: Int64) throws -> Message? {
        try Message.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [id])
    }

    static func getByFolderUid(_ db: Database, folder: String, uid: Int) throws -> Message? {
        try Message.fetchOne(db, sql: "SELECT * FROM messages WHERE folder = ? AND uid = ?",
                             arguments: [folder, uid])
    }

    static func deleteByFolder(_ db: Database, folder: String) throws -> Int {
        try db.execute(sql: "DELETE FROM messages WHERE folder = ?", arguments: [folder])
        return db.changesCount
    }

    static func localUidsForFolder(_ db: Database, folder: String) throws -> Set<Int> {
        let rows = try Int.fetchAll(db, sql: "SELECT uid FROM messages WHERE folder = ?", arguments: [folder])
        return Set(rows)
    }

    static func messageIdsWithStagedChanges(_ db: Database) throws -> Set<Int64> {
        let rows = try Int64.fetchAll(db, sql: "SELECT DISTINCT message_id FROM staged_changes")
        return Set(rows)
    }

    static func findByMessageId(_ db: Database, messageIdHeader: String) throws -> Message? {
        guard !messageIdHeader.isEmpty else { return nil }
        return try Message.fetchOne(db, sql: "SELECT * FROM messages WHERE message_id = ? LIMIT 1",
                                    arguments: [messageIdHeader])
    }

    static func findByMessageIds(_ db: Database, messageIdHeaders: [String]) throws -> [String: Message] {
        guard !messageIdHeaders.isEmpty else { return [:] }
        var result: [String: Message] = [:]
        let batchSize = 900
        for i in stride(from: 0, to: messageIdHeaders.count, by: batchSize) {
            let batch = Array(messageIdHeaders[i..<min(i + batchSize, messageIdHeaders.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            let messages = try Message.fetchAll(db,
                sql: "SELECT * FROM messages WHERE message_id IN (\(placeholders))",
                arguments: StatementArguments(batch)
            )
            for msg in messages {
                result[msg.messageId] = msg
            }
        }
        return result
    }

    static func updateLocation(_ db: Database, localId: Int64, newFolder: String, newUid: Int, newFlags: String) throws {
        try db.execute(
            sql: "UPDATE messages SET folder = ?, uid = ?, flags = ? WHERE id = ?",
            arguments: [newFolder, newUid, newFlags, localId]
        )
    }

    static func updateFlags(_ db: Database, messageId: Int64, flags: String) throws {
        try db.execute(sql: "UPDATE messages SET flags = ? WHERE id = ?", arguments: [flags, messageId])
    }

    static func delete(_ db: Database, messageId: Int64) throws {
        try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [messageId])
    }

    static func moveMessage(_ db: Database, messageId: Int64, newFolder: String, newUid: Int) throws {
        try db.execute(
            sql: "UPDATE messages SET folder = ?, uid = ? WHERE id = ?",
            arguments: [newFolder, newUid, messageId]
        )
    }

    static func deleteByFolderUids(_ db: Database, folder: String, uids: Set<Int>) throws -> Int {
        guard !uids.isEmpty else { return 0 }
        var total = 0
        let uidList = Array(uids)
        let batchSize = 900
        for i in stride(from: 0, to: uidList.count, by: batchSize) {
            let batch = Array(uidList[i..<min(i + batchSize, uidList.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            var args: [any DatabaseValueConvertible] = [folder]
            args.append(contentsOf: batch)
            try db.execute(
                sql: "DELETE FROM messages WHERE folder = ? AND uid IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
            total += db.changesCount
        }
        return total
    }

    static func deleteBulk(_ db: Database, messageIds: [Int64]) throws -> Int {
        guard !messageIds.isEmpty else { return 0 }
        let placeholders = messageIds.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM messages WHERE id IN (\(placeholders))",
            arguments: StatementArguments(messageIds)
        )
        return db.changesCount
    }
}
