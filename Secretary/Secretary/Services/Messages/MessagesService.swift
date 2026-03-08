import Foundation
import GRDB
import os

/// Actor wrapping companion API sync + local GRDB queries for iMessage/SMS.
actor MessagesService {
    private let baseURL: String
    private let authToken: String
    private let session: URLSession
    private let db: DatabaseQueue
    private let logger = Logger(subsystem: "Secretary", category: "MessagesService")

    init(baseURL: String, authToken: String, db: DatabaseQueue) {
        var url = baseURL
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        self.baseURL = url
        self.authToken = authToken
        self.db = db

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.companionTimeout
        config.timeoutIntervalForResource = AppConfig.companionTimeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - Sync (companion API → local DB)

    func syncConversations(limit: Int = 50, since: String? = nil) async throws -> String {
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let since { queryItems.append(URLQueryItem(name: "since", value: since)) }

        let response: CompanionResponse<[CompanionConversation]> = try await request("/conversations", queryItems: queryItems)
        guard let conversations = response.data else {
            return response.error ?? "No data returned"
        }

        let now = ISO8601DateFormatter().string(from: Date())
        try await db.write { db in
            for conv in conversations {
                let record = IMConversation(
                    id: Int64(conv.chat_id),
                    guid: conv.guid,
                    chatIdentifier: conv.chat_identifier,
                    displayName: conv.display_name,
                    serviceName: conv.service_name,
                    isGroup: conv.is_group ? 1 : 0,
                    participants: conv.participants.joined(separator: ", "),
                    lastMessageDate: conv.last_message_date,
                    messageCount: conv.message_count,
                    lastSyncedAt: now
                )
                try IMConversationRepository.upsert(db, conversation: record)
            }
        }

        return "Synced \(conversations.count) conversations."
    }

    func syncMessages(chatId: Int64, before: String? = nil, after: String? = nil, page: Int = 1, pageSize: Int = 200) async throws -> String {
        let offset = (page - 1) * pageSize

        var queryItems = [
            URLQueryItem(name: "limit", value: "\(pageSize)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
        ]
        if let after, !after.isEmpty {
            queryItems.append(URLQueryItem(name: "after", value: after))
        }
        if let before {
            queryItems.append(URLQueryItem(name: "before", value: before))
        }

        let response: CompanionResponse<[CompanionMessage]> = try await request(
            "/conversations/\(chatId)/messages", queryItems: queryItems
        )
        guard let messages = response.data else {
            return response.error ?? "No data returned"
        }

        let isoFormatter = ISO8601DateFormatter()
        let records = messages.map { msg -> IMMessage in
            let epoch: Int64
            if let date = isoFormatter.date(from: msg.date) {
                epoch = Int64(date.timeIntervalSince1970)
            } else {
                epoch = 0
            }
            return IMMessage(
                id: Int64(msg.message_id),
                conversationId: chatId,
                guid: msg.guid,
                text: msg.text,
                isFromMe: msg.is_from_me ? 1 : 0,
                date: msg.date,
                dateEpoch: epoch,
                sender: msg.sender,
                service: msg.service
            )
        }

        try await db.write { db in
            try IMMessageRepository.upsertBatch(db, messages: records)
        }

        // Update last_synced_at on the conversation
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.write { db in
            try db.execute(
                sql: "UPDATE im_conversations SET last_synced_at = ? WHERE id = ?",
                arguments: [now, chatId]
            )
        }

        let hasMore = messages.count == pageSize
        var result = "Synced \(messages.count) messages for conversation \(chatId) (page \(page))."
        if hasMore { result += " More available — call again with page \(page + 1)." }
        return result
    }

    func syncAllMessages(chatId: Int64, before: String? = nil, after: String? = nil, pageSize: Int = 200, progress: ((Int, Int) -> Void)? = nil) async throws -> String {
        var page = 1
        var totalSynced = 0

        while true {
            try Task.checkCancellation()
            progress?(totalSynced, 0)

            let offset = (page - 1) * pageSize
            var queryItems = [
                URLQueryItem(name: "limit", value: "\(pageSize)"),
                URLQueryItem(name: "offset", value: "\(offset)"),
            ]
            if let after, !after.isEmpty {
                queryItems.append(URLQueryItem(name: "after", value: after))
            }
            if let before {
                queryItems.append(URLQueryItem(name: "before", value: before))
            }

            let response: CompanionResponse<[CompanionMessage]> = try await request(
                "/conversations/\(chatId)/messages", queryItems: queryItems
            )
            guard let messages = response.data, !messages.isEmpty else { break }

            let isoFormatter = ISO8601DateFormatter()
            let records = messages.map { msg -> IMMessage in
                let epoch: Int64
                if let date = isoFormatter.date(from: msg.date) {
                    epoch = Int64(date.timeIntervalSince1970)
                } else {
                    epoch = 0
                }
                return IMMessage(
                    id: Int64(msg.message_id),
                    conversationId: chatId,
                    guid: msg.guid,
                    text: msg.text,
                    isFromMe: msg.is_from_me ? 1 : 0,
                    date: msg.date,
                    dateEpoch: epoch,
                    sender: msg.sender,
                    service: msg.service
                )
            }

            try await db.write { db in
                try IMMessageRepository.upsertBatch(db, messages: records)
            }

            totalSynced += messages.count
            progress?(totalSynced, 0)

            if messages.count < pageSize { break }
            page += 1
        }

        let now = ISO8601DateFormatter().string(from: Date())
        try await db.write { db in
            try db.execute(
                sql: "UPDATE im_conversations SET last_synced_at = ? WHERE id = ?",
                arguments: [now, chatId]
            )
        }

        return "Synced all \(totalSynced) messages for conversation \(chatId)."
    }

    func testConnection() async throws -> String {
        let response: CompanionHealthResponse = try await request("/health", queryItems: [], authenticated: false)
        return "Connected! Server v\(response.version), \(response.message_count) messages in database."
    }

    // MARK: - Local queries (GRDB only, no network)

    func listConversations(limit: Int = 50, offset: Int = 0) async throws -> [IMConversation] {
        try await db.read { db in
            try IMConversationRepository.getAll(db, limit: limit, offset: offset)
        }
    }

    func getConversationByIdentifier(_ identifier: String) async throws -> IMConversation? {
        try await db.read { db in
            try IMConversationRepository.getByIdentifier(db, identifier: identifier)
        }
    }

    func getConversation(chatId: Int64) async throws -> IMConversation? {
        try await db.read { db in
            try IMConversationRepository.getById(db, id: chatId)
        }
    }

    func getMessages(chatId: Int64, limit: Int = 50, before: String? = nil, after: String? = nil, ascending: Bool = false) async throws -> [IMMessage] {
        try await db.read { db in
            try IMMessageRepository.getByConversation(db, conversationId: chatId, limit: limit, before: before, after: after, ascending: ascending)
        }
    }

    func searchMessages(query: String, conversationId: Int64? = nil, limit: Int = 20) async throws -> [IMMessage] {
        try await db.read { db in
            try IMMessageRepository.search(db, query: query, conversationId: conversationId, limit: limit)
        }
    }

    // MARK: - HTTP helpers

    private func request<T: Decodable>(_ path: String, queryItems: [URLQueryItem], authenticated: Bool = true) async throws -> T {
        guard var components = URLComponents(string: baseURL + path) else {
            throw SecretaryError.companionError("Invalid URL: \(baseURL + path)")
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw SecretaryError.companionError("Invalid URL: \(baseURL + path)")
        }

        var req = URLRequest(url: url)
        if authenticated {
            req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, httpResponse) = try await session.data(for: req)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw SecretaryError.companionError("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SecretaryError.companionError("HTTP \(http.statusCode): \(body)")
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Companion API response types

private struct CompanionResponse<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}

private struct CompanionHealthResponse: Decodable {
    let ok: Bool
    let version: String
    let message_count: Int
}

private struct CompanionConversation: Decodable {
    let chat_id: Int
    let guid: String
    let chat_identifier: String
    let display_name: String
    let service_name: String
    let is_group: Bool
    let participants: [String]
    let last_message_date: String
    let message_count: Int
}

private struct CompanionMessage: Decodable {
    let message_id: Int
    let guid: String
    let text: String
    let is_from_me: Bool
    let date: String
    let sender: String
    let service: String
}
