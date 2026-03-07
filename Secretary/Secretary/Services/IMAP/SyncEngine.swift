import Foundation
import GRDB
import os

/// Delta sync engine: IMAP -> SQLite.
enum SyncEngine {
    private static let logger = Logger(subsystem: "Secretary", category: "SyncEngine")

    static func syncFolder(
        db: DatabaseQueue,
        folderName: String,
        since: String? = nil,
        progress: ((String, Int, Int) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) async throws -> SyncResult {
        let imap = IMAPClient()
        try await imap.connect(email: KeychainManager.icloudEmail, password: KeychainManager.icloudPassword)
        defer { Task { await imap.disconnect() } }
        return try await syncFolderWith(imap: imap, db: db, folderName: folderName, since: since,
                                         progress: progress, cancelled: cancelled)
    }

    static func syncFolderWith(
        imap: IMAPClient,
        db: DatabaseQueue,
        folderName: String,
        since: String? = nil,
        progress: ((String, Int, Int) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) async throws -> SyncResult {
        var result = SyncResult(folder: folderName)
        let isCancelled = { cancelled?() ?? false }

        progress?(folderName, 0, 0)

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

        // Phase 1: Removal detection — don't delete yet, just track stale UIDs.
        // After fetch, we do local dedup to detect moves.
        let staleUids = localUids.subtracting(serverUids)

        // Phase 2: Discover new UIDs
        var newUids = serverUids.subtracting(localUids)

        if let since, !newUids.isEmpty {
            let sinceDate = imapDate(since)
            let sinceUids = Set(try await imap.searchUids(criteria: "SINCE \(sinceDate)"))
            newUids = newUids.intersection(sinceUids)
        }

        if newUids.isEmpty && staleUids.isEmpty {
            let maxUid = serverUids.max() ?? 0
            try await db.write { db in
                try updateFolderState(db, name: folderName, sel: sel, lastUid: maxUid)
            }
            result.skipped = true
            return result
        }

        // Phase 3: Fetch new messages (full headers + bodies)
        var totalFetched = 0
        let fetchUids = newUids.sorted().reversed() as [Int]
        if !fetchUids.isEmpty && !isCancelled() {
            let batchSize = AppConfig.batchSize
            let totalUids = fetchUids.count

            for i in stride(from: 0, to: totalUids, by: batchSize) {
                try Task.checkCancellation()
                if isCancelled() {
                    logger.info("\(folderName): sync cancelled after \(totalFetched) messages")
                    break
                }
                let batch = Array(fetchUids[i..<min(i + batchSize, totalUids)])
                progress?(folderName, totalFetched, totalUids)

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
            progress?(folderName, totalFetched, fetchUids.count)
        }

        // Phase 4: Local move dedup + stale removal
        // Check if any stale messages (gone from this folder) reappeared in another
        // folder (same Message-ID). If so, it was a move — just delete the old copy.
        if !staleUids.isEmpty && !isCancelled() {
            let protectedMsgIds = try await db.read { db in try MessageRepository.messageIdsWithStagedChanges(db) }
            let staleSnapshot = staleUids
            let currentFolder = folderName
            let (deleted, moved) = try await db.write { db -> (Int, Int) in
                var deleteIds: [Int64] = []
                var movedCount = 0
                for uid in staleSnapshot {
                    guard let msg = try MessageRepository.getByFolderUid(db, folder: currentFolder, uid: uid),
                          let msgId = msg.id else { continue }
                    // Skip protected messages (have staged changes)
                    if protectedMsgIds.contains(msgId) { continue }
                    // Check if this message exists in another folder (was moved)
                    if !msg.messageId.isEmpty,
                       let dupe = try MessageRepository.findByMessageId(db, messageIdHeader: msg.messageId),
                       let dupeId = dupe.id, dupeId != msgId {
                        movedCount += 1
                    }
                    deleteIds.append(msgId)
                }
                let count = try MessageRepository.deleteBulk(db, messageIds: deleteIds)
                return (count, movedCount)
            }
            result.deletedMessages += deleted
            result.movedMessages += moved
            if deleted > 0 {
                logger.info("\(folderName): removed \(deleted) stale messages (\(moved) moved)")
            }
        }

        // Phase 5: Purge \Deleted
        if !isCancelled() {
            try await db.write { db in try purgeDeletedFromCache(db, folder: folderName) }
        }

        // Phase 6: Update folder state
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
        progress: ((String, Int, Int) -> Void)? = nil,
        cancelled: (() -> Bool)? = nil
    ) async throws -> [SyncResult] {
        var results: [SyncResult] = []

        let imap = IMAPClient()
        try await imap.connect(email: KeychainManager.icloudEmail, password: KeychainManager.icloudPassword)
        let folders = try await imap.listFolders()
        await imap.disconnect()

        let selectable = folders.filter { !$0.flags.contains("\\Noselect") }

        for folderInfo in selectable {
            if Task.isCancelled || cancelled?() == true { break }
            do {
                let r = try await syncFolder(db: db, folderName: folderInfo.name,
                                              since: since, progress: progress, cancelled: cancelled)
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
