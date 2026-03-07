import Foundation
import GRDB

enum SyncLogRepository {
    static func log(_ db: Database, folder: String, action: String, messagesSynced: Int, details: [String: Any]? = nil) throws {
        let detailsJSON: String?
        if let details {
            let data = try JSONSerialization.data(withJSONObject: details)
            detailsJSON = String(data: data, encoding: .utf8)
        } else {
            detailsJSON = nil
        }
        try db.execute(
            sql: "INSERT INTO sync_log (folder, action, messages_synced, details) VALUES (?, ?, ?, ?)",
            arguments: [folder, action, messagesSynced, detailsJSON]
        )
    }
}
