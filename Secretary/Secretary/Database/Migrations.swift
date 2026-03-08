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

        migrator.registerMigration("v3-draft-emails") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS draft_emails (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    to_recipients TEXT NOT NULL DEFAULT '',
                    cc_recipients TEXT NOT NULL DEFAULT '',
                    bcc_recipients TEXT NOT NULL DEFAULT '',
                    subject TEXT NOT NULL DEFAULT '',
                    body TEXT NOT NULL DEFAULT '',
                    reply_to_message_id INTEGER,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
                """)
        }

        migrator.registerMigration("v4-imessages") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS im_conversations (
                    id INTEGER PRIMARY KEY,
                    guid TEXT NOT NULL DEFAULT '',
                    chat_identifier TEXT NOT NULL DEFAULT '',
                    display_name TEXT NOT NULL DEFAULT '',
                    service_name TEXT NOT NULL DEFAULT '',
                    is_group INTEGER NOT NULL DEFAULT 0,
                    participants TEXT NOT NULL DEFAULT '',
                    last_message_date TEXT NOT NULL DEFAULT '',
                    message_count INTEGER NOT NULL DEFAULT 0,
                    last_synced_at TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_im_conv_identifier ON im_conversations(chat_identifier)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_im_conv_date ON im_conversations(last_message_date)")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS im_messages (
                    id INTEGER PRIMARY KEY,
                    conversation_id INTEGER NOT NULL REFERENCES im_conversations(id),
                    guid TEXT NOT NULL DEFAULT '',
                    text TEXT NOT NULL DEFAULT '',
                    is_from_me INTEGER NOT NULL DEFAULT 0,
                    date TEXT NOT NULL DEFAULT '',
                    date_epoch INTEGER NOT NULL DEFAULT 0,
                    sender TEXT NOT NULL DEFAULT '',
                    service TEXT NOT NULL DEFAULT ''
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_im_msg_conv ON im_messages(conversation_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_im_msg_date ON im_messages(date_epoch)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_im_msg_sender ON im_messages(sender)")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS im_messages_fts USING fts5(
                    text,
                    sender,
                    content='im_messages',
                    content_rowid='id'
                )
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS im_messages_ai AFTER INSERT ON im_messages BEGIN
                    INSERT INTO im_messages_fts(rowid, text, sender)
                    VALUES (new.id, new.text, new.sender);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS im_messages_ad AFTER DELETE ON im_messages BEGIN
                    INSERT INTO im_messages_fts(im_messages_fts, rowid, text, sender)
                    VALUES ('delete', old.id, old.text, old.sender);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS im_messages_au AFTER UPDATE ON im_messages BEGIN
                    INSERT INTO im_messages_fts(im_messages_fts, rowid, text, sender)
                    VALUES ('delete', old.id, old.text, old.sender);
                    INSERT INTO im_messages_fts(rowid, text, sender)
                    VALUES (new.id, new.text, new.sender);
                END
                """)
        }
    }
}
