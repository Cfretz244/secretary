import Foundation
import GRDB

final class DatabaseManager: Sendable {
    let dbQueue: DatabaseQueue

    static let shared: DatabaseManager = {
        let path = databasePath()
        return try! DatabaseManager(path: path)
    }()

    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5.0)

        let fileManager = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: dir) {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        dbQueue = try DatabaseQueue(path: path, configuration: config)

        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try Schema.create(in: db)
        }
    }

    /// In-memory database for testing
    init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(configuration: config)

        try dbQueue.write { db in
            try Schema.create(in: db)
        }
    }

    private static func databasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Secretary", isDirectory: true)
        return dir.appendingPathComponent("secretary.db").path
    }
}
