import Foundation
import GRDB

struct DraftEmail: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {
    static let databaseTableName = "draft_emails"

    var id: Int64?
    var toRecipients: String
    var ccRecipients: String
    var bccRecipients: String
    var subject: String
    var body: String
    var replyToMessageId: Int64?
    var createdAt: String = ""
    var updatedAt: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case toRecipients = "to_recipients"
        case ccRecipients = "cc_recipients"
        case bccRecipients = "bcc_recipients"
        case subject
        case body
        case replyToMessageId = "reply_to_message_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
