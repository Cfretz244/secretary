import Foundation
import GRDB
import os

final class DatabaseManager: Sendable {
    static let databaseResetNotification = Notification.Name("DatabaseManager.databaseReset")
    private static let logger = Logger(subsystem: "Secretary", category: "DatabaseManager")
    let dbQueue: DatabaseQueue

    static let shared: DatabaseManager = {
        let path = databasePath()
        NSLog("[DatabaseManager] Opening database at: %@", path)
        NSLog("[DatabaseManager] DB exists: %d, WAL exists: %d, SHM exists: %d",
              FileManager.default.fileExists(atPath: path) ? 1 : 0,
              FileManager.default.fileExists(atPath: path + "-wal") ? 1 : 0,
              FileManager.default.fileExists(atPath: path + "-shm") ? 1 : 0)
        // Retry once — a stale WAL from a killed process can cause a transient
        // open failure that resolves after SQLite replays the journal.
        for attempt in 1...2 {
            do {
                let mgr = try DatabaseManager(path: path)
                NSLog("[DatabaseManager] Opened successfully on attempt %d", attempt)
                return mgr
            } catch {
                NSLog("[DatabaseManager] Open FAILED attempt %d: %@", attempt, "\(error)")
                if attempt == 1 { continue }
                // Final attempt failed — nuke and recreate
                NSLog("[DatabaseManager] Resetting database after repeated failure")
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: path + "-wal")
                try? FileManager.default.removeItem(atPath: path + "-shm")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: DatabaseManager.databaseResetNotification, object: nil)
                }
            }
        }
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

        // Set WAL mode outside a transaction — can't switch journal mode inside one
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }

        try dbQueue.write { db in
            try Schema.create(in: db)
        }

        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(dbQueue)
    }

    /// In-memory database for testing
    init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(configuration: config)

        try dbQueue.write { db in
            try Schema.create(in: db)
        }

        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(dbQueue)
    }

    private static func databasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Secretary", isDirectory: true)
        return dir.appendingPathComponent("secretary.db").path
    }
}
