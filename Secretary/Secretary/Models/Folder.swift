import Foundation
import GRDB

struct Folder: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "folders"

    var name: String
    var uidvalidity: Int = 0
    var lastSyncedUid: Int = 0
    var uidnext: Int = 0
    var messageCount: Int = 0
    var lastSyncAt: String?

    enum CodingKeys: String, CodingKey {
        case name
        case uidvalidity
        case lastSyncedUid = "last_synced_uid"
        case uidnext
        case messageCount = "message_count"
        case lastSyncAt = "last_sync_at"
    }
}
