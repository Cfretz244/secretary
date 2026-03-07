import Foundation
import SwiftUI
import GRDB
import BackgroundTasks
import UIKit

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false

    private var agentLoop: AgentLoop?
    private var runningTask: Task<Void, Never>?
    private let sessionId: String
    private let db: DatabaseQueue
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    init() {
        self.sessionId = "ios-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "default")"
        self.db = DatabaseManager.shared.dbQueue
    }

    func setup() {
        guard KeychainManager.hasCredentials else { return }
        let claudeService = ClaudeService(apiKey: KeychainManager.anthropicAPIKey)
        let calendarService = CalendarService()
        let toolExecutor = ToolExecutor(db: db, calendarService: calendarService)
        agentLoop = AgentLoop(claudeService: claudeService, toolExecutor: toolExecutor, db: db)

        loadConversationHistory()

        NotificationCenter.default.addObserver(forName: DatabaseManager.databaseResetNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.messages.removeAll()
            self?.messages.append(ChatMessage(role: .assistant,
                text: "The local database was corrupted and has been reset. Your email will need to be re-synced."))
        }
    }

    private func loadConversationHistory() {
        let sid = sessionId
        do {
            let turns: [ConversationTurn] = try db.read { db in
                try ConversationRepository.getHistory(db, sessionId: sid)
            }
            guard !turns.isEmpty else { return }

            var restored: [ChatMessage] = []
            // Track tool_use IDs to their names for tool call display
            var toolNames: [String: String] = [:]

            for turn in turns {
                switch turn.role {
                case "user":
                    restored.append(ChatMessage(role: .user, text: turn.content))

                case "assistant":
                    if let last = restored.last, last.role == .assistant {
                        restored[restored.count - 1].text += turn.content
                    } else {
                        restored.append(ChatMessage(role: .assistant, text: turn.content))
                    }

                case "tool_use":
                    guard let toolCallId = turn.toolCallId else { continue }
                    // Parse the tool name from the stored JSON
                    var name = "tool"
                    if let data = turn.content.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        name = parsed["name"] as? String ?? "tool"
                    }
                    toolNames[toolCallId] = name
                    // Ensure there's an assistant message to attach to
                    if restored.isEmpty || restored.last?.role != .assistant {
                        restored.append(ChatMessage(role: .assistant, text: ""))
                    }
                    restored[restored.count - 1].toolCalls.append(
                        ChatMessage.ToolCallStatus(id: toolCallId, name: name, status: .running, detail: nil)
                    )

                case "tool_result":
                    guard let toolCallId = turn.toolCallId else { continue }
                    // Mark the tool call as completed
                    for i in restored.indices.reversed() {
                        if let idx = restored[i].toolCalls.firstIndex(where: { $0.id == toolCallId }) {
                            restored[i].toolCalls[idx].status = .completed
                            break
                        }
                    }

                default:
                    break
                }
            }

            // Mark any still-running tool calls as completed (they're historical)
            for i in restored.indices {
                for j in restored[i].toolCalls.indices {
                    if restored[i].toolCalls[j].status == .running {
                        restored[i].toolCalls[j].status = .completed
                    }
                }
            }

            messages = restored
        } catch {
            NSLog("[ChatViewModel] Failed to load conversation history: %@", "\(error)")
        }
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        inputText = ""

        messages.append(ChatMessage(role: .user, text: text))
        let assistantMessage = ChatMessage(role: .assistant, text: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        isStreaming = true
        beginBackgroundProcessing()

        runningTask = Task {
            guard let agentLoop else {
                messages[assistantIndex].text = "Not configured. Please set up credentials in Settings."
                isStreaming = false
                endBackgroundProcessing()
                return
            }

            let stream = await agentLoop.run(sessionId: sessionId, userMessage: text)
            var toolsCompleted: Int64 = 0
            var toolsTotal: Int64 = 0

            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .textDelta(let delta):
                    messages[assistantIndex].text += delta
                    BackgroundTaskCoordinator.shared.updateSubtitle("Responding...")

                case .toolStart(let name, let id):
                    messages[assistantIndex].toolCalls.append(
                        ChatMessage.ToolCallStatus(id: id, name: name, status: .running, detail: nil)
                    )
                    toolsTotal += 1
                    BackgroundTaskCoordinator.shared.updateProgress(completed: toolsCompleted, total: toolsTotal)
                    BackgroundTaskCoordinator.shared.updateSubtitle("Running \(name)...")

                case .toolProgress(let id, let detail):
                    if let idx = messages[assistantIndex].toolCalls.firstIndex(where: { $0.id == id }) {
                        messages[assistantIndex].toolCalls[idx].detail = detail
                    }
                    BackgroundTaskCoordinator.shared.updateSubtitle(detail)

                case .toolDone(_, let id):
                    if let idx = messages[assistantIndex].toolCalls.firstIndex(where: { $0.id == id }) {
                        messages[assistantIndex].toolCalls[idx].status = .completed
                        messages[assistantIndex].toolCalls[idx].detail = nil
                    }
                    toolsCompleted += 1
                    BackgroundTaskCoordinator.shared.updateProgress(completed: toolsCompleted, total: toolsTotal)

                case .error(let errorText):
                    if messages[assistantIndex].text.isEmpty {
                        messages[assistantIndex].text = errorText
                    }

                case .done:
                    if messages[assistantIndex].text.isEmpty && messages[assistantIndex].toolCalls.isEmpty {
                        messages[assistantIndex].text = "Done."
                    }
                }
            }

            isStreaming = false
            endBackgroundProcessing()
        }
    }

    func stopStreaming() {
        runningTask?.cancel()
        runningTask = nil
        Task {
            await agentLoop?.cancel()
        }
        isStreaming = false
        endBackgroundProcessing()
        if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
            for i in messages[lastIdx].toolCalls.indices {
                if messages[lastIdx].toolCalls[i].status == .running {
                    messages[lastIdx].toolCalls[i].status = .failed("Cancelled")
                }
            }
            if messages[lastIdx].text.isEmpty {
                messages[lastIdx].text = "Cancelled."
            }
        }
    }

    func clearConversation() {
        stopStreaming()
        messages.removeAll()
        Task {
            try? db.write { db in
                _ = try ConversationRepository.clear(db, sessionId: sessionId)
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active && !isStreaming {
            if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                var anyFixed = false
                for i in messages[lastIdx].toolCalls.indices {
                    if messages[lastIdx].toolCalls[i].status == .running {
                        messages[lastIdx].toolCalls[i].status = .failed("Interrupted")
                        anyFixed = true
                    }
                }
                if anyFixed && messages[lastIdx].text.isEmpty {
                    messages[lastIdx].text = "Task was interrupted while the app was in the background."
                }
            }
        }
    }

    private func handleBackgroundExpiration() {
        runningTask?.cancel()
        runningTask = nil
        Task {
            await agentLoop?.cancel()
        }
        isStreaming = false
        endBackgroundProcessing()
        if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
            for i in messages[lastIdx].toolCalls.indices {
                if messages[lastIdx].toolCalls[i].status == .running {
                    messages[lastIdx].toolCalls[i].status = .failed("Background time expired")
                }
            }
            if messages[lastIdx].text.isEmpty {
                messages[lastIdx].text = "Background time expired. Open the app to continue."
            }
        }
    }

    // MARK: - Background processing

    private func beginBackgroundProcessing() {
        // Try BGContinuedProcessingTask (device only, extended background time)
        let request = BGContinuedProcessingTaskRequest(
            identifier: SecretaryApp.backgroundTaskId,
            title: "Secretary",
            subtitle: "Processing your request..."
        )
        request.strategy = .queue

        BackgroundTaskCoordinator.shared.onExpiration = { [weak self] in
            self?.handleBackgroundExpiration()
        }

        do {
            try BGTaskScheduler.shared.submit(request)
            return
        } catch {
            // Fallback for Simulator or if BGTask unavailable
        }

        // Fallback: beginBackgroundTask (~30s)
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AgentLoop") { [weak self] in
            self?.stopStreaming()
        }
    }

    private func endBackgroundProcessing() {
        // Signal the BGTask handler to stop blocking
        BackgroundTaskCoordinator.shared.markFinished()
        BackgroundTaskCoordinator.shared.onExpiration = nil

        // End legacy background task if active
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }
}
