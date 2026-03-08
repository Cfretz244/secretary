import GRDB

enum Migrations {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2-threads") { db in
            // Create threads table if not exists (idempotent with Schema.create)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_threads_updated ON threads(updated_at)")

            // Migrate legacy conversations: create a thread for each distinct session_id
            let sessionIds = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT session_id FROM conversations"
            )
            for sessionId in sessionIds {
                // Check if a thread already exists for this session
                let exists = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM threads WHERE id = ?",
                    arguments: [sessionId]
                ) ?? 0
                guard exists == 0 else { continue }

                // Get the earliest and latest timestamps for this session
                let firstDate = try String.fetchOne(
                    db,
                    sql: "SELECT MIN(created_at) FROM conversations WHERE session_id = ?",
                    arguments: [sessionId]
                ) ?? ""
                let lastDate = try String.fetchOne(
                    db,
                    sql: "SELECT MAX(created_at) FROM conversations WHERE session_id = ?",
                    arguments: [sessionId]
                ) ?? ""

                // Get first user message as title
                let title = try String.fetchOne(
                    db,
                    sql: """
                        SELECT content FROM conversations
                        WHERE session_id = ? AND role = 'user'
                        ORDER BY id LIMIT 1
                        """,
                    arguments: [sessionId]
                ) ?? ""
                let truncatedTitle = String(title.prefix(50))

                try db.execute(
                    sql: "INSERT INTO threads (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
                    arguments: [sessionId, truncatedTitle, firstDate.isEmpty ? "datetime('now')" : firstDate, lastDate.isEmpty ? "datetime('now')" : lastDate]
                )
            }
        }
    }
}
