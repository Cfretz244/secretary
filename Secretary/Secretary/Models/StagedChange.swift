import Foundation
import GRDB

struct StagedChange: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {
    static let databaseTableName = "staged_changes"

    var id: Int64?
    var changeType: String
    var messageId: Int64
    var folder: String
    var uid: Int
    var targetFolder: String?
    var flagName: String?
    var createdAt: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case changeType = "change_type"
        case messageId = "message_id"
        case folder
        case uid
        case targetFolder = "target_folder"
        case flagName = "flag_name"
        case createdAt = "created_at"
    }
}
