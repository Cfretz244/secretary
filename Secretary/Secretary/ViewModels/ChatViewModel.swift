import Foundation
import SwiftUI
import GRDB

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false

    private var agentLoop: AgentLoop?
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

        Task {
            guard let agentLoop else {
                messages[assistantIndex].text = "Not configured. Please set up credentials in Settings."
                isStreaming = false
                return
            }

            let stream = await agentLoop.run(sessionId: sessionId, userMessage: text)

            for await event in stream {
                switch event {
                case .textDelta(let delta):
                    messages[assistantIndex].text += delta

                case .toolStart(let name, let id):
                    messages[assistantIndex].toolCalls.append(
                        ChatMessage.ToolCallStatus(id: id, name: name, status: .running)
                    )

                case .toolDone(_, let id):
                    if let idx = messages[assistantIndex].toolCalls.firstIndex(where: { $0.id == id }) {
                        messages[assistantIndex].toolCalls[idx].status = .completed
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

    func clearConversation() {
        messages.removeAll()
        Task {
            try? db.write { db in
                _ = try ConversationRepository.clear(db, sessionId: sessionId)
            }
        }
    }
}
