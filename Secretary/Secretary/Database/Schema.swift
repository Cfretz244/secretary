import GRDB

enum Schema {
    static func create(in db: Database) throws {
        // folders
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS folders (
                name TEXT PRIMARY KEY,
                uidvalidity INTEGER NOT NULL DEFAULT 0,
                last_synced_uid INTEGER NOT NULL DEFAULT 0,
                uidnext INTEGER NOT NULL DEFAULT 0,
                message_count INTEGER NOT NULL DEFAULT 0,
                last_sync_at TEXT
            )
            """)

        // messages
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                folder TEXT NOT NULL,
                uid INTEGER NOT NULL,
                message_id TEXT NOT NULL DEFAULT '',
                subject TEXT NOT NULL DEFAULT '',
                sender TEXT NOT NULL DEFAULT '',
                sender_email TEXT NOT NULL DEFAULT '',
                recipients TEXT NOT NULL DEFAULT '',
                date TEXT NOT NULL DEFAULT '',
                date_epoch INTEGER NOT NULL DEFAULT 0,
                flags TEXT NOT NULL DEFAULT '',
                size INTEGER NOT NULL DEFAULT 0,
                body_text TEXT NOT NULL DEFAULT '',
                body_preview TEXT NOT NULL DEFAULT '',
                raw_headers TEXT NOT NULL DEFAULT '',
                UNIQUE(folder, uid)
            )
            """)

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_folder ON messages(folder)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_date ON messages(date_epoch)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_email)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_message_id ON messages(message_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_flags ON messages(flags)")

        // FTS5
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                subject,
                sender,
                body_text,
                content='messages',
                content_rowid='id'
            )
            """)

        // FTS triggers
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, subject, sender, body_text)
                VALUES (new.id, new.subject, new.sender, new.body_text);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, subject, sender, body_text)
                VALUES ('delete', old.id, old.subject, old.sender, old.body_text);
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, subject, sender, body_text)
                VALUES ('delete', old.id, old.subject, old.sender, old.body_text);
                INSERT INTO messages_fts(rowid, subject, sender, body_text)
                VALUES (new.id, new.subject, new.sender, new.body_text);
            END
            """)

        // staged_changes
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS staged_changes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                change_type TEXT NOT NULL CHECK(change_type IN ('move', 'flag', 'unflag', 'delete')),
                message_id INTEGER NOT NULL REFERENCES messages(id),
                folder TEXT NOT NULL,
                uid INTEGER NOT NULL,
                target_folder TEXT,
                flag_name TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """)

        // sync_log
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sync_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                folder TEXT NOT NULL,
                action TEXT NOT NULL,
                messages_synced INTEGER NOT NULL DEFAULT 0,
                details TEXT,
                timestamp TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """)

        // rules
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS rules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                conditions TEXT NOT NULL DEFAULT '[]',
                action TEXT NOT NULL CHECK(action IN ('move', 'flag', 'unflag', 'delete')),
                action_target TEXT,
                priority INTEGER NOT NULL DEFAULT 100,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_rules_priority ON rules(priority, id)")

        // draft_emails
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

        // threads
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS threads (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_threads_updated ON threads(updated_at)")

        // conversations
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                tool_call_id TEXT,
                token_count INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversations_session ON conversations(session_id)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversations_created ON conversations(session_id, created_at)")
    }
}
