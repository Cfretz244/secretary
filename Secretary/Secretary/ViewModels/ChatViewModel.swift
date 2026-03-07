import Foundation
import SwiftUI
import GRDB

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false

    private var agentLoop: AgentLoop?
    private var runningTask: Task<Void, Never>?
    private let sessionId: String
    private let db: DatabaseQueue

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

        NotificationCenter.default.addObserver(forName: DatabaseManager.databaseResetNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.messages.append(ChatMessage(role: .assistant,
                text: "⚠️ The local database was corrupted and has been reset. Your email will need to be re-synced."))
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

        runningTask = Task {
            guard let agentLoop else {
                messages[assistantIndex].text = "Not configured. Please set up credentials in Settings."
                isStreaming = false
                return
            }

            let stream = await agentLoop.run(sessionId: sessionId, userMessage: text)

            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .textDelta(let delta):
                    messages[assistantIndex].text += delta

                case .toolStart(let name, let id):
                    messages[assistantIndex].toolCalls.append(
                        ChatMessage.ToolCallStatus(id: id, name: name, status: .running, detail: nil)
                    )

                case .toolProgress(let id, let detail):
                    if let idx = messages[assistantIndex].toolCalls.firstIndex(where: { $0.id == id }) {
                        messages[assistantIndex].toolCalls[idx].detail = detail
                    }

                case .toolDone(_, let id):
                    if let idx = messages[assistantIndex].toolCalls.firstIndex(where: { $0.id == id }) {
                        messages[assistantIndex].toolCalls[idx].status = .completed
                        messages[assistantIndex].toolCalls[idx].detail = nil
                    }

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
        }
    }

    func stopStreaming() {
        runningTask?.cancel()
        runningTask = nil
        Task {
            await agentLoop?.cancel()
        }
        isStreaming = false
        // Mark any running tool calls as cancelled
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
}
