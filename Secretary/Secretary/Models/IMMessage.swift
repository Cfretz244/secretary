import Foundation
import GRDB

struct IMMessage: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {
    static let databaseTableName = "im_messages"

    var id: Int64?
    var conversationId: Int64
    var guid: String
    var text: String
    var isFromMe: Int
    var date: String
    var dateEpoch: Int64
    var sender: String
    var service: String

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case guid
        case text
        case isFromMe = "is_from_me"
        case date
        case dateEpoch = "date_epoch"
        case sender
        case service
    }
}
