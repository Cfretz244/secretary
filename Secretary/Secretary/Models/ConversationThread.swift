import Foundation
import GRDB

struct ConversationThread: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "threads"

    var id: String
    var title: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String = UUID().uuidString, title: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.createdAt = formatter.string(from: createdAt)
        self.updatedAt = formatter.string(from: updatedAt)
    }
}
