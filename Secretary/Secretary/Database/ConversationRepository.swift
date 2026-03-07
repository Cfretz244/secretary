import Foundation
import GRDB

enum ConversationRepository {
    static func insertTurn(_ db: Database, sessionId: String, role: String,
                           content: String, toolCallId: String? = nil, tokenCount: Int = 0) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO conversations (session_id, role, content, tool_call_id, token_count)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [sessionId, role, content, toolCallId, tokenCount]
        )
        return db.lastInsertedRowID
    }

    static func getHistory(_ db: Database, sessionId: String) throws -> [ConversationTurn] {
        try ConversationTurn.fetchAll(
            db,
            sql: "SELECT * FROM conversations WHERE session_id = ? ORDER BY id",
            arguments: [sessionId]
        )
    }

    static func trimHistory(_ db: Database, sessionId: String, keepRecent: Int = 20) throws -> Int {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations WHERE session_id = ?",
                                     arguments: [sessionId]) ?? 0
        guard total > keepRecent else { return 0 }

        guard let cutoff = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM conversations WHERE session_id = ? ORDER BY id DESC LIMIT 1 OFFSET ?",
            arguments: [sessionId, keepRecent - 1]
        ) else { return 0 }

        try db.execute(
            sql: "DELETE FROM conversations WHERE session_id = ? AND id < ?",
            arguments: [sessionId, cutoff]
        )
        return db.changesCount
    }

    static func clear(_ db: Database, sessionId: String) throws -> Int {
        try db.execute(sql: "DELETE FROM conversations WHERE session_id = ?", arguments: [sessionId])
        return db.changesCount
    }

    // MARK: - Conversation persistence helpers (port of conversations.py)

    static func saveUserMessage(_ db: Database, sessionId: String, text: String) throws {
        _ = try insertTurn(db, sessionId: sessionId, role: "user", content: text)
    }

    static func saveAssistantText(_ db: Database, sessionId: String, text: String) throws {
        _ = try insertTurn(db, sessionId: sessionId, role: "assistant", content: text)
    }

    static func saveToolUse(_ db: Database, sessionId: String,
                            toolUseId: String, name: String, inputArgs: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": name, "input": inputArgs])
        let content = String(data: data, encoding: .utf8) ?? "{}"
        _ = try insertTurn(db, sessionId: sessionId, role: "tool_use", content: content, toolCallId: toolUseId)
    }

    static func saveToolResult(_ db: Database, sessionId: String, toolUseId: String, result: String) throws {
        _ = try insertTurn(db, sessionId: sessionId, role: "tool_result", content: result, toolCallId: toolUseId)
    }

    static func maybeTrim(_ db: Database, sessionId: String) throws {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations WHERE session_id = ?",
                                     arguments: [sessionId]) ?? 0
        if count > AppConfig.trimThreshold {
            let trimmed = try trimHistory(db, sessionId: sessionId, keepRecent: AppConfig.trimKeep)
            if trimmed > 0 {
                print("Trimmed \(trimmed) old conversation turns for \(sessionId)")
            }
        }
    }

    /// Load conversation history and reconstruct as Anthropic messages API format
    static func loadHistoryAsMessages(_ db: Database, sessionId: String) throws -> [[String: Any]] {
        let rows = try getHistory(db, sessionId: sessionId)
        guard !rows.isEmpty else { return [] }

        // Skip leading rows until we find a plain user message
        var start = 0
        var foundUser = false
        for (i, row) in rows.enumerated() {
            if row.role == "user" {
                start = i
                foundUser = true
                break
            }
        }
        guard foundUser else { return [] }
        let trimmedRows = Array(rows[start...])

        var messages: [[String: Any]] = []
        var seenToolUseIds: Set<String> = []
        var totalChars = 0

        for row in trimmedRows {
            totalChars += row.content.count
            if totalChars > AppConfig.maxContextChars { break }

            switch row.role {
            case "user":
                messages.append(["role": "user", "content": row.content])

            case "assistant":
                if let last = messages.last, last["role"] as? String == "assistant" {
                    var updated = last
                    var content = ensureContentList(&updated)
                    content.append(["type": "text", "text": row.content])
                    updated["content"] = content
                    messages[messages.count - 1] = updated
                } else {
                    messages.append(["role": "assistant", "content": row.content])
                }

            case "tool_use":
                guard let toolCallId = row.toolCallId,
                      let data = row.content.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                seenToolUseIds.insert(toolCallId)
                let block: [String: Any] = [
                    "type": "tool_use",
                    "id": toolCallId,
                    "name": parsed["name"] ?? "",
                    "input": parsed["input"] ?? [:],
                ]
                if let last = messages.last, last["role"] as? String == "assistant" {
                    var updated = last
                    var content = ensureContentList(&updated)
                    content.append(block)
                    updated["content"] = content
                    messages[messages.count - 1] = updated
                } else {
                    messages.append(["role": "assistant", "content": [block]])
                }

            case "tool_result":
                guard let toolCallId = row.toolCallId,
                      seenToolUseIds.contains(toolCallId) else { continue }
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": toolCallId,
                    "content": row.content,
                ]
                if let last = messages.last,
                   last["role"] as? String == "user",
                   last["content"] is [[String: Any]] {
                    var updated = last
                    var content = updated["content"] as! [[String: Any]]
                    content.append(block)
                    updated["content"] = content
                    messages[messages.count - 1] = updated
                } else {
                    messages.append(["role": "user", "content": [block]])
                }

            default:
                break
            }
        }

        // Validate: every tool_use must be followed by a tool_result.
        // After cancellation, tool_use blocks may be orphaned. Insert synthetic
        // tool_results wherever they're missing.
        messages = repairToolUseHistory(messages)

        return messages
    }

    /// Scan through messages and insert synthetic tool_results for any
    /// tool_use blocks that lack a corresponding tool_result.
    private static func repairToolUseHistory(_ messages: [[String: Any]]) -> [[String: Any]] {
        // Collect all tool_result IDs in the history
        var answeredIds = Set<String>()
        for msg in messages {
            if let contentList = msg["content"] as? [[String: Any]] {
                for block in contentList where block["type"] as? String == "tool_result" {
                    if let id = block["tool_use_id"] as? String { answeredIds.insert(id) }
                }
            }
        }

        var result: [[String: Any]] = []
        for msg in messages {
            // Check if this assistant message has tool_use blocks missing results
            if msg["role"] as? String == "assistant" {
                var missingIds: [String] = []
                if let contentList = msg["content"] as? [[String: Any]] {
                    for block in contentList where block["type"] as? String == "tool_use" {
                        if let id = block["id"] as? String, !answeredIds.contains(id) {
                            missingIds.append(id)
                        }
                    }
                }
                result.append(msg)
                if !missingIds.isEmpty {
                    // Insert a synthetic user message with tool_results right after
                    let syntheticResults: [[String: Any]] = missingIds.map { id in
                        ["type": "tool_result", "tool_use_id": id, "content": "Cancelled by user."]
                    }
                    result.append(["role": "user", "content": syntheticResults])
                }
            } else {
                result.append(msg)
            }
        }

        // Merge consecutive user messages (synthetic results + real user text)
        var merged: [[String: Any]] = []
        for msg in result {
            if msg["role"] as? String == "user",
               let prev = merged.last, prev["role"] as? String == "user" {
                // Merge into previous user message
                var updated = prev
                var prevContent: [[String: Any]]
                if let list = updated["content"] as? [[String: Any]] {
                    prevContent = list
                } else if let text = updated["content"] as? String {
                    prevContent = [["type": "text", "text": text]]
                } else {
                    prevContent = []
                }
                if let list = msg["content"] as? [[String: Any]] {
                    prevContent.append(contentsOf: list)
                } else if let text = msg["content"] as? String {
                    prevContent.append(["type": "text", "text": text])
                }
                updated["content"] = prevContent
                merged[merged.count - 1] = updated
            } else {
                merged.append(msg)
            }
        }

        return merged
    }

    private static func ensureContentList(_ message: inout [String: Any]) -> [[String: Any]] {
        if let str = message["content"] as? String {
            let list: [[String: Any]] = [["type": "text", "text": str]]
            message["content"] = list
            return list
        }
        return message["content"] as? [[String: Any]] ?? []
    }
}
