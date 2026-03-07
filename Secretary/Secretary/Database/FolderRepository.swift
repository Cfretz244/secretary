import Foundation
import GRDB

enum FolderRepository {
    static func upsert(_ db: Database, folder: Folder) throws {
        try db.execute(
            sql: """
                INSERT INTO folders (name, uidvalidity, last_synced_uid, uidnext, message_count, last_sync_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(name) DO UPDATE SET
                    uidvalidity=excluded.uidvalidity,
                    last_synced_uid=excluded.last_synced_uid,
                    uidnext=excluded.uidnext,
                    message_count=excluded.message_count,
                    last_sync_at=excluded.last_sync_at
                """,
            arguments: [folder.name, folder.uidvalidity, folder.lastSyncedUid,
                        folder.uidnext, folder.messageCount, folder.lastSyncAt]
        )
    }

    static func get(_ db: Database, name: String) throws -> Folder? {
        try Folder.fetchOne(db, sql: "SELECT * FROM folders WHERE name = ?", arguments: [name])
    }

    static func getAll(_ db: Database) throws -> [Folder] {
        try Folder.fetchAll(db, sql: "SELECT * FROM folders ORDER BY name")
    }
}
