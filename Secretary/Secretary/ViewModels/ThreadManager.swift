import Foundation
import SwiftUI
import GRDB
import BackgroundTasks
import UIKit

@MainActor
final class ThreadManager: ObservableObject {
    @Published var threads: [ThreadState] = []
    @Published var activeThreadId: String?

    var activeThread: ThreadState? {
        guard let id = activeThreadId else { return nil }
        return threads.first { $0.id == id }
    }

    private var claudeService: ClaudeService?
    private var calendarService: CalendarService?
    private var messagesService: MessagesService?
    private let db: DatabaseQueue = DatabaseManager.shared.dbQueue
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var progressTimer: Task<Void, Never>?

    // MARK: - Setup

    func setup() {
        guard KeychainManager.hasCredentials else { return }
        claudeService = ClaudeService(apiKey: KeychainManager.anthropicAPIKey)
        calendarService = CalendarService()

        if let url = KeychainManager.get(.companionURL), !url.isEmpty,
           let token = KeychainManager.get(.companionToken), !token.isEmpty {
            messagesService = MessagesService(baseURL: url, authToken: token, db: db)
        }

        loadThreads()

        NotificationCenter.default.addObserver(forName: DatabaseManager.databaseResetNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                for thread in self.threads {
                    thread.messages.removeAll()
                }
                self.activeThread?.messages.append(ChatMessage(role: .assistant,
                    text: "The local database was corrupted and has been reset. Your email will need to be re-synced."))
            }
        }
    }

    private func loadThreads() {
        Task {
            do {
                let dbThreads: [ConversationThread] = try await db.read { db in
                    try ThreadRepository.getAll(db)
                }
                if dbThreads.isEmpty {
                    let thread = await createThreadAsync(title: "")
                    activeThreadId = thread.id
                    await loadHistory(for: thread)
                } else {
                    threads = dbThreads.map { ThreadState(from: $0) }
                    activeThreadId = threads.first?.id
                    if let active = activeThread {
                        await loadHistory(for: active)
                    }
                }
            } catch {
                NSLog("[ThreadManager] Failed to load threads: %@", "\(error)")
                let thread = await createThreadAsync(title: "")
                activeThreadId = thread.id
            }
        }
    }

    // MARK: - Thread management

    @discardableResult
    func createThread(title: String = "") -> ThreadState {
        let dbThread = ConversationThread(title: title)
        let state = ThreadState(from: dbThread)
        threads.insert(state, at: 0)
        activeThreadId = state.id
        Task {
            try? await db.write { db in
                try ThreadRepository.insert(db, thread: dbThread)
            }
        }
        return state
    }

    private func createThreadAsync(title: String) async -> ThreadState {
        let dbThread = ConversationThread(title: title)
        do {
            try await db.write { db in
                try ThreadRepository.insert(db, thread: dbThread)
            }
        } catch {
            NSLog("[ThreadManager] Failed to create thread: %@", "\(error)")
        }
        let state = ThreadState(from: dbThread)
        threads.insert(state, at: 0)
        return state
    }

    func switchToThread(id: String) {
        activeThreadId = id
        if let thread = activeThread, !thread.historyLoaded {
            Task { await loadHistory(for: thread) }
        }
    }

    func deleteThread(id: String) {
        guard let thread = threads.first(where: { $0.id == id }) else { return }
        stopStreaming(in: thread)

        threads.removeAll { $0.id == id }

        Task {
            try? await db.write { db in
                try ThreadRepository.delete(db, id: id)
            }
        }

        if activeThreadId == id {
            if let first = threads.first {
                switchToThread(id: first.id)
            } else {
                createThread(title: "")
            }
        }
    }

    // MARK: - History

    private func loadHistory(for thread: ThreadState) async {
        let sid = thread.id
        do {
            let turns: [ConversationTurn] = try await db.read { db in
                try ConversationRepository.getHistory(db, sessionId: sid)
            }
            thread.historyLoaded = true
            guard !turns.isEmpty else { return }

            var restored: [ChatMessage] = []
            var hadToolCallsSinceLast = false

            for turn in turns {
                switch turn.role {
                case "user":
                    restored.append(ChatMessage(role: .user, text: turn.content))
                    hadToolCallsSinceLast = false

                case "assistant":
                    if hadToolCallsSinceLast || restored.last?.role != .assistant {
                        restored.append(ChatMessage(role: .assistant, text: turn.content))
                        hadToolCallsSinceLast = false
                    } else {
                        restored[restored.count - 1].text += turn.content
                    }

                case "tool_use":
                    guard let toolCallId = turn.toolCallId else { continue }
                    var name = "tool"
                    var inputJson: String? = nil
                    if let data = turn.content.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        name = parsed["name"] as? String ?? "tool"
                        if let input = parsed["input"] {
                            if let inputData = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
                               let str = String(data: inputData, encoding: .utf8) {
                                inputJson = str
                            }
                        }
                    }
                    if restored.isEmpty || restored.last?.role != .assistant {
                        restored.append(ChatMessage(role: .assistant, text: ""))
                    }
                    restored[restored.count - 1].toolCalls.append(
                        ChatMessage.ToolCallStatus(id: toolCallId, name: name, status: .running, detail: nil, input: inputJson)
                    )

                case "tool_result":
                    guard let toolCallId = turn.toolCallId else { continue }
                    hadToolCallsSinceLast = true
                    for i in restored.indices.reversed() {
                        if let idx = restored[i].toolCalls.firstIndex(where: { $0.id == toolCallId }) {
                            restored[i].toolCalls[idx].status = .completed
                            restored[i].toolCalls[idx].result = turn.content
                            break
                        }
                    }

                default:
                    break
                }
            }

            for i in restored.indices {
                for j in restored[i].toolCalls.indices {
                    if restored[i].toolCalls[j].status == .running {
                        restored[i].toolCalls[j].status = .completed
                    }
                }
            }

            thread.messages = restored
        } catch {
            NSLog("[ThreadManager] Failed to load history for thread %@: %@", sid, "\(error)")
        }
    }

    // MARK: - Send / Stop

    func sendMessage(in thread: ThreadState) {
        let text = thread.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thread.isStreaming else { return }
        thread.inputText = ""

        thread.messages.append(ChatMessage(role: .user, text: text))
        let assistantMessage = ChatMessage(role: .assistant, text: "")
        thread.messages.append(assistantMessage)
        let assistantIndex = thread.messages.count - 1

        // Auto-title
        if thread.title.isEmpty {
            let truncated = String(text.prefix(50))
            thread.title = truncated
            let tid = thread.id
            Task {
                try? db.write { db in
                    try ThreadRepository.updateTitle(db, id: tid, title: truncated)
                }
            }
        }

        // Touch updated_at and move to top
        let tid = thread.id
        Task {
            try? db.write { db in
                try ThreadRepository.touch(db, id: tid)
            }
        }
        if let idx = threads.firstIndex(where: { $0.id == tid }), idx != 0 {
            let t = threads.remove(at: idx)
            threads.insert(t, at: 0)
        }

        thread.isStreaming = true
        beginBackgroundProcessing()

        // Create agent loop + tool executor if needed
        if thread.agentLoop == nil, let claudeService, let calendarService {
            let toolExecutor = ToolExecutor(db: db, calendarService: calendarService)
            toolExecutor.messagesService = resolveMessagesService()
            thread.agentLoop = AgentLoop(claudeService: claudeService, toolExecutor: toolExecutor, db: db)
        } else if let agentLoop = thread.agentLoop {
            // Update messagesService on existing agent loop in case credentials changed
            Task { await agentLoop.updateMessagesService(resolveMessagesService()) }
        }

        thread.runningTask = Task {
            guard let agentLoop = thread.agentLoop else {
                thread.messages[assistantIndex].text = "Not configured. Please set up credentials in Settings."
                thread.isStreaming = false
                endBackgroundProcessing()
                return
            }

            let stream = await agentLoop.run(sessionId: thread.id, userMessage: text)

            var currentAssistantIndex = assistantIndex
            var toolCallsOnCurrent = false

            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .textDelta(let delta):
                    if toolCallsOnCurrent {
                        thread.messages.append(ChatMessage(role: .assistant, text: ""))
                        currentAssistantIndex = thread.messages.count - 1
                        toolCallsOnCurrent = false
                    }
                    thread.messages[currentAssistantIndex].text += delta
                    BackgroundTaskCoordinator.shared.updateSubtitle("Responding...")

                case .toolStart(let name, let id, let input):
                    toolCallsOnCurrent = true
                    thread.messages[currentAssistantIndex].toolCalls.append(
                        ChatMessage.ToolCallStatus(id: id, name: name, status: .running, detail: nil, input: input)
                    )
                    BackgroundTaskCoordinator.shared.updateSubtitle("Running \(name)...")

                case .toolProgress(let id, let detail):
                    if let idx = thread.messages[currentAssistantIndex].toolCalls.firstIndex(where: { $0.id == id }) {
                        thread.messages[currentAssistantIndex].toolCalls[idx].detail = detail
                    }
                    BackgroundTaskCoordinator.shared.updateSubtitle(detail)

                case .toolDone(_, let id, let result):
                    if let idx = thread.messages[currentAssistantIndex].toolCalls.firstIndex(where: { $0.id == id }) {
                        thread.messages[currentAssistantIndex].toolCalls[idx].status = .completed
                        thread.messages[currentAssistantIndex].toolCalls[idx].detail = nil
                        thread.messages[currentAssistantIndex].toolCalls[idx].result = result
                    }

                case .error(let errorText):
                    if thread.messages[currentAssistantIndex].text.isEmpty {
                        thread.messages[currentAssistantIndex].text = errorText
                    }

                case .done:
                    if thread.messages[currentAssistantIndex].text.isEmpty && thread.messages[currentAssistantIndex].toolCalls.isEmpty {
                        thread.messages[currentAssistantIndex].text = "Done."
                    }
                }
            }

            thread.isStreaming = false
            endBackgroundProcessing()
        }
    }

    func stopStreaming(in thread: ThreadState) {
        thread.runningTask?.cancel()
        thread.runningTask = nil
        Task {
            await thread.agentLoop?.cancel()
        }
        thread.isStreaming = false
        endBackgroundProcessing()
        fixRunningToolCalls(in: thread, reason: "Cancelled")
    }

    var anyThreadStreaming: Bool {
        threads.contains { $0.isStreaming }
    }

    private func fixRunningToolCalls(in thread: ThreadState, reason: String) {
        for idx in thread.messages.indices.reversed() {
            guard thread.messages[idx].role == .assistant else { break }
            var anyFixed = false
            for j in thread.messages[idx].toolCalls.indices {
                if thread.messages[idx].toolCalls[j].status == .running {
                    thread.messages[idx].toolCalls[j].status = .failed(reason)
                    anyFixed = true
                }
            }
            if anyFixed && thread.messages[idx].text.isEmpty {
                thread.messages[idx].text = "\(reason)."
            }
        }
    }

    private var cachedCompanionURL: String = ""
    private var cachedCompanionToken: String = ""

    private func resolveMessagesService() -> MessagesService? {
        let url = KeychainManager.get(.companionURL) ?? ""
        let token = KeychainManager.get(.companionToken) ?? ""
        guard !url.isEmpty, !token.isEmpty else {
            messagesService = nil
            return nil
        }
        // Reuse cached service if credentials haven't changed
        if let existing = messagesService, url == cachedCompanionURL, token == cachedCompanionToken {
            return existing
        }
        cachedCompanionURL = url
        cachedCompanionToken = token
        let svc = MessagesService(baseURL: url, authToken: token, db: db)
        messagesService = svc
        return svc
    }

    // MARK: - Scene phase

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            for thread in threads where !thread.isStreaming {
                fixRunningToolCalls(in: thread, reason: "Interrupted")
            }
        }
    }

    // MARK: - Background processing

    private func beginBackgroundProcessing() {
        let request = BGContinuedProcessingTaskRequest(
            identifier: SecretaryApp.backgroundTaskId,
            title: "Secretary",
            subtitle: "Processing your request..."
        )
        request.strategy = .queue

        BackgroundTaskCoordinator.shared.onExpiration = { [weak self] in
            self?.handleBackgroundExpiration()
        }
        BackgroundTaskCoordinator.shared.incrementActive()

        do {
            try BGTaskScheduler.shared.submit(request)
            startProgressHeartbeat()
            return
        } catch {
            // Fallback for Simulator or if BGTask unavailable
        }

        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AgentLoop") { [weak self] in
            self?.handleBackgroundExpiration()
        }
    }

    private func endBackgroundProcessing() {
        BackgroundTaskCoordinator.shared.decrementActive()

        if !anyThreadStreaming {
            progressTimer?.cancel()
            progressTimer = nil
            BackgroundTaskCoordinator.shared.onExpiration = nil

            if backgroundTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
                backgroundTaskId = .invalid
            }
        }
    }

    private func handleBackgroundExpiration() {
        for thread in threads where thread.isStreaming {
            thread.runningTask?.cancel()
            thread.runningTask = nil
            Task {
                await thread.agentLoop?.cancel()
            }
            thread.isStreaming = false
            fixRunningToolCalls(in: thread, reason: "Background time expired")
        }
        BackgroundTaskCoordinator.shared.resetActive()
        progressTimer?.cancel()
        progressTimer = nil
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }

    private func startProgressHeartbeat() {
        guard progressTimer == nil else { return }
        progressTimer = Task { [weak self] in
            var tick: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self != nil else { break }
                tick += 1
                BackgroundTaskCoordinator.shared.updateProgress(
                    completed: tick,
                    total: tick + 5
                )
            }
        }
    }
}
