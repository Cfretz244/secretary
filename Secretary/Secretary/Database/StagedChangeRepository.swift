import Foundation
import GRDB

enum StagedChangeRepository {
    static func insert(_ db: Database, change: [String: Any]) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO staged_changes (change_type, message_id, folder, uid, target_folder, flag_name)
                VALUES (:change_type, :message_id, :folder, :uid, :target_folder, :flag_name)
                """,
            arguments: StatementArguments([
                "change_type": change["change_type"] as? String ?? "",
                "message_id": change["message_id"] as? Int64 ?? 0,
                "folder": change["folder"] as? String ?? "",
                "uid": change["uid"] as? Int ?? 0,
                "target_folder": change["target_folder"] as? String,
                "flag_name": change["flag_name"] as? String,
            ])
        )
        return db.lastInsertedRowID
    }

    static func getAll(_ db: Database) throws -> [StagedChange] {
        try StagedChange.fetchAll(db, sql: "SELECT * FROM staged_changes ORDER BY created_at")
    }

    static func getForFolder(_ db: Database, folder: String) throws -> [StagedChange] {
        try StagedChange.fetchAll(db, sql: "SELECT * FROM staged_changes WHERE folder = ? ORDER BY created_at",
                                  arguments: [folder])
    }

    static func getForMessage(_ db: Database, messageId: Int64) throws -> [StagedChange] {
        try StagedChange.fetchAll(db, sql: "SELECT * FROM staged_changes WHERE message_id = ? ORDER BY created_at",
                                  arguments: [messageId])
    }

    static func delete(_ db: Database, changeId: Int64) throws -> Bool {
        try db.execute(sql: "DELETE FROM staged_changes WHERE id = ?", arguments: [changeId])
        return db.changesCount > 0
    }

    static func deleteBulk(_ db: Database, changeIds: [Int64]) throws -> Int {
        guard !changeIds.isEmpty else { return 0 }
        let placeholders = changeIds.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM staged_changes WHERE id IN (\(placeholders))",
            arguments: StatementArguments(changeIds)
        )
        return db.changesCount
    }

    static func deleteAll(_ db: Database, folder: String? = nil) throws -> Int {
        if let folder {
            try db.execute(sql: "DELETE FROM staged_changes WHERE folder = ?", arguments: [folder])
        } else {
            try db.execute(sql: "DELETE FROM staged_changes")
        }
        return db.changesCount
    }

    static func countByFolder(_ db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: "SELECT folder, COUNT(*) as cnt FROM staged_changes GROUP BY folder")
        var result: [String: Int] = [:]
        for row in rows {
            result[row["folder"] as String] = row["cnt"] as Int
        }
        return result
    }

    static func updateLocation(_ db: Database, messageId: Int64, newFolder: String, newUid: Int) throws {
        try db.execute(
            sql: "UPDATE staged_changes SET folder = ?, uid = ? WHERE message_id = ?",
            arguments: [newFolder, newUid, messageId]
        )
    }
}
