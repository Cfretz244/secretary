import Foundation
import GRDB

struct SearchResult {
    var messages: [Message]
    var total: Int
    var page: Int
    var pageSize: Int
    var hasMore: Bool
}

enum SearchRepository {
    static func searchMessages(
        _ db: Database,
        query: String? = nil,
        folder: String? = nil,
        sender: String? = nil,
        dateFrom: String? = nil,
        dateTo: String? = nil,
        flags: String? = nil,
        unreadOnly: Bool = false,
        includeDeleted: Bool = false,
        page: Int = 1,
        pageSize: Int = 20,
        sortBy: String = "date_epoch",
        sortOrder: String = "DESC"
    ) throws -> SearchResult {
        var conditions: [String] = []
        var params: [any DatabaseValueConvertible] = []

        let fromClause: String
        if let query, !query.isEmpty {
            fromClause = "messages_fts fts JOIN messages m ON fts.rowid = m.id"
            conditions.append("messages_fts MATCH ?")
            params.append(query)
        } else {
            fromClause = "messages m"
        }

        if !includeDeleted {
            conditions.append("m.flags NOT LIKE '%\\Deleted%'")
        }

        if let folder, !folder.isEmpty {
            conditions.append("m.folder = ?")
            params.append(folder)
        }
        if let sender, !sender.isEmpty {
            conditions.append("m.sender_email LIKE ?")
            params.append("%\(sender)%")
        }
        if let dateFrom, !dateFrom.isEmpty {
            conditions.append("m.date >= ?")
            params.append(dateFrom)
        }
        if let dateTo, !dateTo.isEmpty {
            conditions.append("m.date <= ?")
            params.append(dateTo)
        }
        if let flags, !flags.isEmpty {
            conditions.append("m.flags LIKE ?")
            params.append("%\(flags)%")
        }
        if unreadOnly {
            conditions.append("m.flags NOT LIKE '%\\Seen%'")
        }

        let whereClause = conditions.isEmpty ? "1=1" : conditions.joined(separator: " AND ")

        let allowedSorts: Set<String> = ["date_epoch", "sender_email", "subject", "size", "id"]
        let safeSortBy = allowedSorts.contains(sortBy) ? sortBy : "date_epoch"
        let safeSortOrder = sortOrder.uppercased() == "ASC" ? "ASC" : "DESC"

        let total = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(fromClause) WHERE \(whereClause)",
            arguments: StatementArguments(params)
        ) ?? 0

        let offset = (page - 1) * pageSize
        var fetchParams = params
        fetchParams.append(pageSize)
        fetchParams.append(offset)

        let messages = try Message.fetchAll(
            db,
            sql: """
                SELECT m.* FROM \(fromClause)
                WHERE \(whereClause)
                ORDER BY m.\(safeSortBy) \(safeSortOrder)
                LIMIT ? OFFSET ?
                """,
            arguments: StatementArguments(fetchParams)
        )

        return SearchResult(
            messages: messages,
            total: total,
            page: page,
            pageSize: pageSize,
            hasMore: (offset + pageSize) < total
        )
    }

    static func getMessages(
        _ db: Database,
        folder: String? = nil,
        page: Int = 1,
        pageSize: Int = 50,
        sortBy: String = "date_epoch",
        sortOrder: String = "DESC"
    ) throws -> SearchResult {
        try searchMessages(db, folder: folder, page: page, pageSize: pageSize,
                           sortBy: sortBy, sortOrder: sortOrder)
    }

    static func senderHistogram(
        _ db: Database,
        folder: String? = nil,
        minCount: Int = 1,
        page: Int = 1,
        pageSize: Int = 50,
        includeDeleted: Bool = false
    ) throws -> [String: Any] {
        var conditions: [String] = []
        var params: [any DatabaseValueConvertible] = []
        if let folder, !folder.isEmpty {
            conditions.append("folder = ?")
            params.append(folder)
        }
        if !includeDeleted {
            conditions.append("flags NOT LIKE '%\\Deleted%'")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let total = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM (
                    SELECT sender_email FROM messages \(whereClause)
                    GROUP BY sender_email
                    HAVING COUNT(*) >= ?
                )
                """,
            arguments: StatementArguments(params + [minCount])
        ) ?? 0

        let offset = (page - 1) * pageSize
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT sender_email, sender AS sender_name, COUNT(*) AS count,
                       MIN(date) AS oldest, MAX(date) AS newest
                FROM messages \(whereClause)
                GROUP BY sender_email
                HAVING COUNT(*) >= ?
                ORDER BY count DESC
                LIMIT ? OFFSET ?
                """,
            arguments: StatementArguments(params + [minCount, pageSize, offset])
        )

        var senders: [[String: Any]] = []
        for r in rows {
            let email: String = r["sender_email"]
            var exParams: [any DatabaseValueConvertible] = [email]
            var exConditions = ["sender_email = ?"]
            if let folder, !folder.isEmpty {
                exConditions.append("folder = ?")
                exParams.append(folder)
            }
            if !includeDeleted {
                exConditions.append("flags NOT LIKE '%\\Deleted%'")
            }
            let exSubject = try String.fetchOne(
                db,
                sql: """
                    SELECT subject FROM messages
                    WHERE \(exConditions.joined(separator: " AND "))
                    ORDER BY date_epoch DESC LIMIT 1
                    """,
                arguments: StatementArguments(exParams)
            ) ?? ""

            senders.append([
                "email": email,
                "name": r["sender_name"] as String,
                "count": r["count"] as Int,
                "oldest": r["oldest"] as String,
                "newest": r["newest"] as String,
                "example_subject": exSubject,
            ])
        }

        return [
            "senders": senders,
            "total": total,
            "page": page,
            "page_size": pageSize,
            "has_more": (offset + pageSize) < total,
        ]
    }

    static func getSummary(_ db: Database) throws -> [String: Any] {
        let notDeleted = "flags NOT LIKE '%\\Deleted%'"
        var stats: [String: Any] = [:]

        stats["total_messages"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE \(notDeleted)") ?? 0
        stats["unread_count"] = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM messages WHERE flags NOT LIKE '%\\Seen%' AND \(notDeleted)"
        ) ?? 0

        let folderRows = try Row.fetchAll(db, sql: """
            SELECT folder, COUNT(*) as cnt FROM messages WHERE \(notDeleted) GROUP BY folder ORDER BY cnt DESC
            """)
        var byFolder: [String: Int] = [:]
        for r in folderRows { byFolder[r["folder"] as String] = r["cnt"] as Int }
        stats["by_folder"] = byFolder

        let topRows = try Row.fetchAll(db, sql: """
            SELECT sender_email, sender, COUNT(*) as cnt FROM messages
            WHERE \(notDeleted) GROUP BY sender_email ORDER BY cnt DESC LIMIT 20
            """)
        stats["top_senders"] = topRows.map { r -> [String: Any] in
            ["email": r["sender_email"] as String, "name": r["sender"] as String, "count": r["cnt"] as Int]
        }

        let dateRows = try Row.fetchAll(db, sql: """
            SELECT DATE(date) as day, COUNT(*) as cnt FROM messages
            WHERE date != '' AND \(notDeleted) GROUP BY day ORDER BY day DESC LIMIT 30
            """)
        var byDate: [String: Int] = [:]
        for r in dateRows {
            if let day: String = r["day"] { byDate[day] = r["cnt"] as Int }
        }
        stats["by_date"] = byDate

        stats["flagged_count"] = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM messages WHERE flags LIKE '%\\Flagged%' AND \(notDeleted)"
        ) ?? 0

        let syncedRows = try Row.fetchAll(db, sql: "SELECT name, message_count, last_sync_at FROM folders ORDER BY name")
        stats["synced_folders"] = syncedRows.map { r -> [String: Any] in
            ["name": r["name"] as String, "messages": r["message_count"] as Int,
             "last_sync": (r["last_sync_at"] as String?) ?? ""]
        }

        return stats
    }
}
