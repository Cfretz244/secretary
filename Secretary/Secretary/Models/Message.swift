import Foundation
import GRDB

struct Message: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {
    static let databaseTableName = "messages"

    var id: Int64?
    var folder: String
    var uid: Int
    var messageId: String = ""
    var subject: String = ""
    var sender: String = ""
    var senderEmail: String = ""
    var recipients: String = ""
    var date: String = ""
    var dateEpoch: Int = 0
    var flags: String = ""
    var size: Int = 0
    var bodyText: String = ""
    var bodyPreview: String = ""
    var rawHeaders: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case folder
        case uid
        case messageId = "message_id"
        case subject
        case sender
        case senderEmail = "sender_email"
        case recipients
        case date
        case dateEpoch = "date_epoch"
        case flags
        case size
        case bodyText = "body_text"
        case bodyPreview = "body_preview"
        case rawHeaders = "raw_headers"
    }
}
