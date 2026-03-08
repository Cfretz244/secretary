import Foundation
import GRDB

enum IMConversationRepository {
    static func upsert(_ db: Database, conversation: IMConversation) throws {
        try db.execute(
            sql: """
                INSERT INTO im_conversations (id, guid, chat_identifier, display_name, service_name,
                    is_group, participants, last_message_date, message_count, last_synced_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    guid = excluded.guid,
                    chat_identifier = excluded.chat_identifier,
                    display_name = excluded.display_name,
                    service_name = excluded.service_name,
                    is_group = excluded.is_group,
                    participants = excluded.participants,
                    last_message_date = excluded.last_message_date,
                    message_count = excluded.message_count,
                    last_synced_at = excluded.last_synced_at
                """,
            arguments: [
                conversation.id, conversation.guid, conversation.chatIdentifier,
                conversation.displayName, conversation.serviceName,
                conversation.isGroup, conversation.participants,
                conversation.lastMessageDate, conversation.messageCount,
                conversation.lastSyncedAt,
            ]
        )
    }

    static func getAll(_ db: Database, limit: Int = 50, offset: Int = 0) throws -> [IMConversation] {
        try IMConversation.fetchAll(
            db,
            sql: "SELECT * FROM im_conversations ORDER BY last_message_date DESC LIMIT ? OFFSET ?",
            arguments: [limit, offset]
        )
    }

    static func getById(_ db: Database, id: Int64) throws -> IMConversation? {
        try IMConversation.fetchOne(
            db,
            sql: "SELECT * FROM im_conversations WHERE id = ?",
            arguments: [id]
        )
    }

    static func getByIdentifier(_ db: Database, identifier: String) throws -> IMConversation? {
        // Try exact match first, then partial (for phone number variations)
        if let exact = try IMConversation.fetchOne(
            db,
            sql: "SELECT * FROM im_conversations WHERE chat_identifier = ?",
            arguments: [identifier]
        ) { return exact }

        let pattern = "%\(identifier)%"
        return try IMConversation.fetchOne(
            db,
            sql: "SELECT * FROM im_conversations WHERE chat_identifier LIKE ? OR participants LIKE ? ORDER BY last_message_date DESC LIMIT 1",
            arguments: [pattern, pattern]
        )
    }

    static func search(_ db: Database, query: String, limit: Int = 20) throws -> [IMConversation] {
        let pattern = "%\(query)%"
        return try IMConversation.fetchAll(
            db,
            sql: """
                SELECT * FROM im_conversations
                WHERE chat_identifier LIKE ? OR display_name LIKE ? OR participants LIKE ?
                ORDER BY last_message_date DESC LIMIT ?
                """,
            arguments: [pattern, pattern, pattern, limit]
        )
    }
}
