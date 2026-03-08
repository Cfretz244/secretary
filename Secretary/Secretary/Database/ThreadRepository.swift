import Foundation
import GRDB

enum ThreadRepository {
    static func insert(_ db: Database, thread: ConversationThread) throws {
        try thread.insert(db)
    }

    static func getAll(_ db: Database) throws -> [ConversationThread] {
        try ConversationThread.fetchAll(
            db,
            sql: "SELECT * FROM threads ORDER BY updated_at DESC"
        )
    }

    static func get(_ db: Database, id: String) throws -> ConversationThread? {
        try ConversationThread.fetchOne(db, key: id)
    }

    static func delete(_ db: Database, id: String) throws {
        // Delete conversations for this thread first (session_id == thread id)
        try db.execute(sql: "DELETE FROM conversations WHERE session_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [id])
    }

    static func updateTitle(_ db: Database, id: String, title: String) throws {
        try db.execute(
            sql: "UPDATE threads SET title = ?, updated_at = datetime('now') WHERE id = ?",
            arguments: [title, id]
        )
    }

    static func touch(_ db: Database, id: String) throws {
        try db.execute(
            sql: "UPDATE threads SET updated_at = datetime('now') WHERE id = ?",
            arguments: [id]
        )
    }
}
