import Foundation
import GRDB

struct IMConversation: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {
    static let databaseTableName = "im_conversations"

    var id: Int64?
    var guid: String
    var chatIdentifier: String
    var displayName: String
    var serviceName: String
    var isGroup: Int
    var participants: String
    var lastMessageDate: String
    var messageCount: Int
    var lastSyncedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case guid
        case chatIdentifier = "chat_identifier"
        case displayName = "display_name"
        case serviceName = "service_name"
        case isGroup = "is_group"
        case participants
        case lastMessageDate = "last_message_date"
        case messageCount = "message_count"
        case lastSyncedAt = "last_synced_at"
    }
}
