import Foundation
import GRDB

struct ConversationTurn: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "conversations"

    var id: Int64?
    var sessionId: String
    var role: String
    var content: String
    var toolCallId: String?
    var tokenCount: Int = 0
    var createdAt: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case role
        case content
        case toolCallId = "tool_call_id"
        case tokenCount = "token_count"
        case createdAt = "created_at"
    }
}
