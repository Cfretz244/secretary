import Foundation

@MainActor
final class ThreadState: ObservableObject, Identifiable {
    let id: String
    @Published var title: String
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var inputText: String = ""
    let createdAt: Date

    var agentLoop: AgentLoop?
    var runningTask: Task<Void, Never>?
    var historyLoaded: Bool = false

    init(id: String, title: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }

    init(from thread: ConversationThread) {
        self.id = thread.id
        self.title = thread.title
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.createdAt = formatter.date(from: thread.createdAt) ?? Date()
    }
}
