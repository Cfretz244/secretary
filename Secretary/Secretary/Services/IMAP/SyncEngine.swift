import Foundation
import GRDB
import os

/// Delta sync engine: IMAP -> SQLite. Port of sync.py.
enum SyncEngine {
    private static let logger = Logger(subsystem: "Secretary", category: "SyncEngine")

    static func syncFolder(
        db: DatabaseQueue,
        folderName: String,
        since: String? = nil,
        progress: ((Int, Int) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) async throws -> SyncResult {
        var result = SyncResult(folder: folderName)
        let isCancelled = { cancelled?() ?? false }

        let imap = IMAPClient()
        try await imap.connect(email: KeychainManager.icloudEmail, password: KeychainManager.icloudPassword)
        defer { Task { await imap.disconnect() } }

        // Phase 0: Select folder and UIDVALIDITY check
        let sel = try await imap.selectFolder(folderName, readonly: true)
        let localFolder = try await db.read { db in try FolderRepository.get(db, name: folderName) }

        var effectiveLocalFolder = localFolder
        if let lf = localFolder, lf.uidvalidity != 0, lf.uidvalidity != sel.uidvalidity {
            logger.info("UIDVALIDITY changed for \(folderName), purging local data")
            let deleted = try await db.write { db in try MessageRepository.deleteByFolder(db, folder: folderName) }
            result.uidvalidityReset = true
            result.deletedMessages = deleted
            effectiveLocalFolder = nil
        }

        let lastSyncedUid = effectiveLocalFolder?.lastSyncedUid ?? 0

        // Quick skip: nothing changed
        if let lf = effectiveLocalFolder, sel.uidnext == lf.uidnext, !result.uidvalidityReset {
            try await db.write { db in try purgeDeletedFromCache(db, folder: folderName) }
            result.skipped = true
            return result
        }

        // Get all server UIDs
        let serverUids = Set(try await imap.searchUids())
        let localUids = try await db.read { db in try MessageRepository.localUidsForFolder(db, folder: folderName) }

        // Phase 1: Removal detection
        var staleUids = localUids.subtracting(serverUids)
        if !staleUids.isEmpty && !isCancelled() {
            let protectedMsgIds = try await db.read { db in try MessageRepository.messageIdsWithStagedChanges(db) }
            if !protectedMsgIds.isEmpty {
                let staleSnapshot = staleUids
                let protectedUids: Set<Int> = try await db.read { db in
                    var protected = Set<Int>()
                    for uid in staleSnapshot {
                        if let msg = try MessageRepository.getByFolderUid(db, folder: folderName, uid: uid),
                           let id = msg.id, protectedMsgIds.contains(id) {
                            protected.insert(uid)
                        }
                    }
                    return protected
                }
                let removable = staleUids.subtracting(protectedUids)
                result.skippedRemovals = protectedUids.count
                staleUids = removable
            }

            if !staleUids.isEmpty {
                let toDelete = staleUids
                let deleted = try await db.write { db in
                    try MessageRepository.deleteByFolderUids(db, folder: folderName, uids: toDelete)
                }
                result.deletedMessages += deleted
                logger.info("\(folderName): removed \(deleted) stale messages")
            }
        }

        // Phase 2: New UID discovery with move deduplication
        var newUids = serverUids.subtracting(localUids)

        if let since, !newUids.isEmpty {
            let sinceDate = imapDate(since)
            let sinceUids = Set(try await imap.searchUids(criteria: "SINCE \(sinceDate)"))
            newUids = newUids.intersection(sinceUids)
        }

        if newUids.isEmpty && result.deletedMessages == 0 {
            let maxUid = serverUids.max() ?? 0
            try await db.write { db in
                try updateFolderState(db, name: folderName, sel: sel, lastUid: maxUid)
            }
            result.skipped = true
            return result
        }

        // Move deduplication
        var fetchUids: [Int] = []
        if !newUids.isEmpty && !isCancelled() {
            let batchSize = AppConfig.batchSize
            let newUidList = newUids.sorted()
            for i in stride(from: 0, to: newUidList.count, by: batchSize) {
                if isCancelled() { break }
                let batch = Array(newUidList[i..<min(i + batchSize, newUidList.count)])
                do {
                    let midData = try await imap.fetchMessageIdsAndFlags(uids: batch)
                    for uid in batch {
                        guard let info = midData[uid], !info.messageId.isEmpty else {
                            fetchUids.append(uid)
                            continue
                        }
                        let existing = try await db.read { db in
                            try MessageRepository.findByMessageId(db, messageIdHeader: info.messageId)
                        }
                        if let existing, let existingId = existing.id, existing.folder != folderName {
                            let flags = info.flags
                            try await db.write { db in
                                try MessageRepository.updateLocation(db, localId: existingId,
                                                                     newFolder: folderName, newUid: uid, newFlags: flags)
                                try StagedChangeRepository.updateLocation(db, messageId: existingId,
                                                                          newFolder: folderName, newUid: uid)
                            }
                            result.movedMessages += 1
                        } else {
                            fetchUids.append(uid)
                        }
                    }
                } catch {
                    result.errors.append("Message-ID fetch batch: \(error)")
                    fetchUids.append(contentsOf: batch)
                }
            }
        }

        // Phase 3: Full fetch for genuinely new messages
        var totalFetched = 0
        if !fetchUids.isEmpty && !isCancelled() {
            fetchUids = fetchUids.sorted().reversed()
            let batchSize = AppConfig.batchSize
            let totalUids = fetchUids.count

            for i in stride(from: 0, to: totalUids, by: batchSize) {
                if isCancelled() {
                    logger.info("\(folderName): sync cancelled after \(totalFetched) messages")
                    break
                }
                let batch = Array(fetchUids[i..<min(i + batchSize, totalUids)])
                progress?(totalFetched, totalUids)

                do {
                    let fetched = try await imap.fetchMessages(uids: batch)
                    let batchCount = fetched.count
                    try await db.write { db in
                        for (uid, parts) in fetched {
                            let msgDict = MessageParser.parse(uid: uid, folder: folderName, parts: parts)
                            _ = try MessageRepository.insert(db, msg: msgDict)
                        }
                    }
                    totalFetched += batchCount
                } catch {
                    result.errors.append("Fetch batch \(i): \(error)")
                    logger.error("Fetch error for batch \(i): \(error)")
                }
            }

            result.newMessages = totalFetched
            progress?(totalFetched, fetchUids.count)
        }

        // Phase 4: Purge \Deleted
        if !isCancelled() {
            try await db.write { db in try purgeDeletedFromCache(db, folder: folderName) }
        }

        // Phase 5: Update folder state
        let syncCompleted = !isCancelled()
        let finalUid = serverUids.max() ?? 0
        let logNewMessages = result.newMessages
        let logNewUids = newUids.count
        let logMoved = result.movedMessages
        let logDeleted = result.deletedMessages
        let logSkipped = result.skippedRemovals
        let logErrors = result.errors.count
        let logReset = result.uidvalidityReset
        let effectiveLastUid = syncCompleted ? finalUid : lastSyncedUid
        try await db.write { db in
            try updateFolderState(db, name: folderName, sel: sel, lastUid: effectiveLastUid)
            try SyncLogRepository.log(db, folder: folderName, action: "delta_sync",
                                      messagesSynced: logNewMessages, details: [
                                          "new_uids": logNewUids,
                                          "moved": logMoved,
                                          "removed": logDeleted,
                                          "skipped_removals": logSkipped,
                                          "errors": logErrors,
                                          "uidvalidity_reset": logReset,
                                      ])
        }

        return result
    }

    static func syncAllFolders(
        db: DatabaseQueue,
        since: String? = nil,
        progress: ((Int, Int) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) async throws -> [SyncResult] {
        var results: [SyncResult] = []

        let imap = IMAPClient()
        try await imap.connect(email: KeychainManager.icloudEmail, password: KeychainManager.icloudPassword)
        let folders = try await imap.listFolders()
        await imap.disconnect()

        let selectable = folders.filter { !$0.flags.contains("\\Noselect") }

        for folderInfo in selectable {
            if cancelled?() == true { break }
            do {
                let r = try await syncFolder(db: db, folderName: folderInfo.name, since: since,
                                              progress: progress, cancelled: cancelled)
                results.append(r)
            } catch {
                results.append(SyncResult(folder: folderInfo.name, errors: [error.localizedDescription]))
                logger.error("Sync error for \(folderInfo.name): \(error)")
            }
        }

        return results
    }

    // MARK: - Private

    private static func purgeDeletedFromCache(_ db: Database, folder: String) throws {
        let protectedIds = try MessageRepository.messageIdsWithStagedChanges(db)
        let rows = try Row.fetchAll(db,
            sql: "SELECT id FROM messages WHERE folder = ? AND flags LIKE '%\\Deleted%'",
            arguments: [folder]
        )
        let purgeIds = rows.compactMap { row -> Int64? in
            let id: Int64 = row["id"]
            return protectedIds.contains(id) ? nil : id
        }
        if !purgeIds.isEmpty {
            _ = try MessageRepository.deleteBulk(db, messageIds: purgeIds)
        }
    }

    private static func updateFolderState(_ db: Database, name: String, sel: IMAPClient.SelectResult, lastUid: Int) throws {
        try FolderRepository.upsert(db, folder: Folder(
            name: name,
            uidvalidity: sel.uidvalidity,
            lastSyncedUid: lastUid,
            uidnext: sel.uidnext,
            messageCount: sel.messageCount,
            lastSyncAt: ISO8601DateFormatter().string(from: Date())
        ))
    }

    private static func imapDate(_ isoDate: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: isoDate) else { return isoDate }
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date)
    }
}
