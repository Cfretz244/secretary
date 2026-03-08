@preconcurrency import Foundation
@preconcurrency import SwiftAnthropic
import GRDB
import os

/// Stream events emitted during agent loop execution.
enum StreamEvent: Sendable {
    case textDelta(String)
    case toolStart(name: String, id: String)
    case toolProgress(id: String, detail: String)
    case toolDone(name: String, id: String)
    case error(String)
    case done
}

/// Agent loop: streaming Claude API with tool use. Port of claude_loop.py.
actor AgentLoop {
    private let claudeService: ClaudeService
    private let toolExecutor: ToolExecutor
    private let db: DatabaseQueue
    private let logger = Logger(subsystem: "Secretary", category: "AgentLoop")

    private var cancelled = false
    private var innerTask: Task<Void, Never>?

    init(claudeService: ClaudeService, toolExecutor: ToolExecutor, db: DatabaseQueue) {
        self.claudeService = claudeService
        self.toolExecutor = toolExecutor
        self.db = db
    }

    func cancel() {
        cancelled = true
        innerTask?.cancel()
        innerTask = nil
    }

    func run(sessionId: String, userMessage: String) -> AsyncStream<StreamEvent> {
        cancelled = false
        innerTask?.cancel()
        return AsyncStream { continuation in
            innerTask = Task {
                await self.executeLoop(sessionId: sessionId, userMessage: userMessage, continuation: continuation)
            }
        }
    }

    private func executeLoop(sessionId: String, userMessage: String, continuation: AsyncStream<StreamEvent>.Continuation) async {
        let startTime = Date()

        // Save user message and load history
        do {
            try await db.write { db in
                try ConversationRepository.maybeTrim(db, sessionId: sessionId)
                try ConversationRepository.saveUserMessage(db, sessionId: sessionId, text: userMessage)
            }
        } catch {
            continuation.yield(.error("Failed to save message: \(error.localizedDescription)"))
            continuation.yield(.done)
            continuation.finish()
            return
        }

        var messages: [MessageParameter.Message] = []
        do {
            let history: [[String: String]] = try await db.read { db in
                // Flatten history to Sendable types
                let raw = try ConversationRepository.loadHistoryAsMessages(db, sessionId: sessionId)
                return Self.flattenHistory(raw)
            }
            messages = Self.convertToMessages(history)
        } catch {
            continuation.yield(.error("Failed to load history: \(error.localizedDescription)"))
            continuation.yield(.done)
            continuation.finish()
            return
        }

        let systemPrompt = SystemPrompt.get()

        for _ in 0..<AppConfig.maxToolIterations {
            if cancelled || Task.isCancelled {
                logger.info("Agent loop cancelled")
                continuation.yield(.done)
                continuation.finish()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > AppConfig.loopTimeoutSeconds {
                logger.warning("Agent loop timed out after \(elapsed)s")
                continuation.yield(.error("Request timed out. Please try again."))
                continuation.yield(.done)
                continuation.finish()
                return
            }

            do {
                let response = try await sendMessage(
                    systemPrompt: systemPrompt,
                    messages: messages
                )

                // Process response content blocks
                var assistantTextParts: [String] = []
                var toolUses: [(id: String, name: String, input: MessageResponse.Content.Input)] = []

                for block in response.content {
                    switch block {
                    case .text(let text, _):
                        assistantTextParts.append(text)
                        continuation.yield(.textDelta(text))
                    case .toolUse(let toolUse):
                        continuation.yield(.toolStart(name: toolUse.name, id: toolUse.id))
                        toolUses.append((id: toolUse.id, name: toolUse.name, input: toolUse.input))
                    default:
                        break
                    }
                }

                // Save assistant response — pre-serialize to Sendable types
                let textToSave = assistantTextParts.isEmpty ? nil : assistantTextParts.joined(separator: "\n")
                var toolUseJsons: [(id: String, content: String)] = []
                for tu in toolUses {
                    let dict = Self.dynamicContentToDict(tu.input)
                    let obj: [String: Any] = ["name": tu.name, "input": dict]
                    if let data = try? JSONSerialization.data(withJSONObject: obj),
                       let str = String(data: data, encoding: .utf8) {
                        toolUseJsons.append((id: tu.id, content: str))
                    }
                }
                let sid = sessionId
                let toolUseJsonsSnapshot = toolUseJsons
                try await db.write { db in
                    if let text = textToSave {
                        try ConversationRepository.saveAssistantText(db, sessionId: sid, text: text)
                    }
                    for tu in toolUseJsonsSnapshot {
                        _ = try ConversationRepository.insertTurn(db, sessionId: sid,
                                                                   role: "tool_use", content: tu.content,
                                                                   toolCallId: tu.id)
                    }
                }

                // If no tool uses or end_turn, we're done
                if toolUses.isEmpty || response.stopReason == "end_turn" {
                    continuation.yield(.done)
                    continuation.finish()
                    return
                }

                // Execute tools and collect results
                var toolResultObjects: [MessageParameter.Message.Content.ContentObject] = []
                for tu in toolUses {
                    if cancelled || Task.isCancelled {
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    }
                    logger.info("Executing tool: \(tu.name)")
                    let toolId = tu.id
                    toolExecutor.onProgress = { detail in
                        continuation.yield(.toolProgress(id: toolId, detail: detail))
                    }
                    var result = try await toolExecutor.execute(name: tu.name,
                                                               arguments: Self.dynamicContentToDict(tu.input))
                    toolExecutor.onProgress = nil

                    if result.count > AppConfig.toolResultMaxChars {
                        result = String(result.prefix(AppConfig.toolResultMaxChars)) + "\n\n[Result truncated]"
                    }

                    let tuId = tu.id
                    let toolResult = result
                    try await db.write { db in
                        try ConversationRepository.saveToolResult(db, sessionId: sid,
                                                                   toolUseId: tuId, result: toolResult)
                    }

                    continuation.yield(.toolDone(name: tu.name, id: tu.id))
                    toolResultObjects.append(.toolResult(tu.id, result))
                }

                // Build assistant content for next turn
                var assistantContent: [MessageParameter.Message.Content.ContentObject] = []
                for text in assistantTextParts {
                    assistantContent.append(.text(text))
                }
                for tu in toolUses {
                    assistantContent.append(.toolUse(tu.id, tu.name, tu.input))
                }

                messages.append(MessageParameter.Message(role: .assistant, content: .list(assistantContent)))
                messages.append(MessageParameter.Message(role: .user, content: .list(toolResultObjects)))

            } catch let apiError as APIError {
                let desc = apiError.displayDescription
                logger.error("API error: \(desc)")
                if desc.contains("overloaded") || desc.contains("529") {
                    continuation.yield(.error("Claude is overloaded. Please try again in a moment."))
                } else if desc.contains("rate") || desc.contains("429") {
                    continuation.yield(.error("Rate limited. Please wait a moment and try again."))
                } else if desc.contains("too long") || desc.contains("too many tokens") || desc.contains("context") {
                    // Trim history aggressively and inform user
                    let sid = sessionId
                    try? await db.write { db in
                        _ = try ConversationRepository.trimHistory(db, sessionId: sid, keepRecent: 10)
                    }
                    continuation.yield(.error("Conversation too long — older history has been trimmed. Please try again."))
                } else {
                    continuation.yield(.error("API error: \(desc)"))
                }
                continuation.yield(.done)
                continuation.finish()
                return
            } catch {
                logger.error("Agent loop error: \(error)")
                continuation.yield(.error("Something went wrong: \(error.localizedDescription)"))
                continuation.yield(.done)
                continuation.finish()
                return
            }
        }

        logger.warning("Agent loop hit max iterations")
        continuation.yield(.error("Hit tool iteration limit. Please try a simpler request."))
        continuation.yield(.done)
        continuation.finish()
    }

    // MARK: - API call

    private func sendMessage(systemPrompt: String, messages: [MessageParameter.Message]) async throws -> MessageResponse {
        let parameters = MessageParameter(
            model: .other(AppConfig.agentModel),
            messages: messages,
            maxTokens: AppConfig.agentMaxTokens,
            system: .text(systemPrompt),
            tools: ToolDefinitions.all
        )
        return try await claudeService.client.createMessage(parameters)
    }

    // MARK: - Conversion helpers (nonisolated/static for Sendable closures)

    /// Flatten [[String: Any]] to [[String: String]] for Sendable transfer
    nonisolated private static func flattenHistory(_ raw: [[String: Any]]) -> [[String: String]] {
        raw.compactMap { msg -> [String: String]? in
            guard let role = msg["role"] as? String else { return nil }
            if let content = msg["content"] as? String {
                return ["role": role, "content": content]
            }
            if let contentList = msg["content"] as? [[String: Any]] {
                if let json = try? JSONSerialization.data(withJSONObject: contentList),
                   let str = String(data: json, encoding: .utf8) {
                    return ["role": role, "content_json": str]
                }
            }
            return nil
        }
    }

    nonisolated private static func convertToMessages(_ history: [[String: String]]) -> [MessageParameter.Message] {
        history.compactMap { msg -> MessageParameter.Message? in
            guard let role = msg["role"] else { return nil }
            let messageRole: MessageParameter.Message.Role = role == "assistant" ? .assistant : .user

            if let contentStr = msg["content"] {
                return MessageParameter.Message(role: messageRole, content: .text(contentStr))
            }

            if let jsonStr = msg["content_json"],
               let data = jsonStr.data(using: .utf8),
               let contentList = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let blocks: [MessageParameter.Message.Content.ContentObject] = contentList.compactMap { block in
                    let type = block["type"] as? String ?? ""
                    switch type {
                    case "text":
                        return .text(block["text"] as? String ?? "")
                    case "tool_use":
                        let id = block["id"] as? String ?? ""
                        let name = block["name"] as? String ?? ""
                        let input = block["input"] as? [String: Any] ?? [:]
                        return .toolUse(id, name, dictToDynamicContent(input))
                    case "tool_result":
                        let toolUseId = block["tool_use_id"] as? String ?? ""
                        let content = block["content"] as? String ?? ""
                        return .toolResult(toolUseId, content)
                    default:
                        return nil
                    }
                }
                return MessageParameter.Message(role: messageRole, content: .list(blocks))
            }

            return nil
        }
    }

    /// Convert [String: DynamicContent] to [String: Any] for tool execution
    nonisolated static func dynamicContentToDict(_ input: MessageResponse.Content.Input) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in input {
            result[key] = dynamicContentToAny(value)
        }
        return result
    }

    nonisolated private static func dynamicContentToAny(_ value: MessageResponse.Content.DynamicContent) -> Any {
        switch value {
        case .string(let s): return s
        case .integer(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { dynamicContentToAny($0) }
        case .dictionary(let dict): return dynamicContentToDict(dict)
        }
    }

    /// Convert [String: Any] to [String: DynamicContent] for sending back to API
    nonisolated private static func dictToDynamicContent(_ dict: [String: Any]) -> MessageResponse.Content.Input {
        var result: MessageResponse.Content.Input = [:]
        for (key, value) in dict {
            result[key] = anyToDynamicContent(value)
        }
        return result
    }

    nonisolated private static func anyToDynamicContent(_ value: Any) -> MessageResponse.Content.DynamicContent {
        if let b = value as? Bool { return .bool(b) }
        if let i = value as? Int { return .integer(i) }
        if let d = value as? Double { return .double(d) }
        if let s = value as? String { return .string(s) }
        if let arr = value as? [Any] { return .array(arr.map { anyToDynamicContent($0) }) }
        if let dict = value as? [String: Any] { return .dictionary(dictToDynamicContent(dict)) }
        return .null
    }
}
