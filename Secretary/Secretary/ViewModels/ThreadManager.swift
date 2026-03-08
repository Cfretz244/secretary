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
    private let db: DatabaseQueue = DatabaseManager.shared.dbQueue
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var progressTimer: Task<Void, Never>?

    // MARK: - Setup

    func setup() {
        guard KeychainManager.hasCredentials else { return }
        claudeService = ClaudeService(apiKey: KeychainManager.anthropicAPIKey)
        calendarService = CalendarService()

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
        do {
            let dbThreads: [ConversationThread] = try db.read { db in
                try ThreadRepository.getAll(db)
            }
            if dbThreads.isEmpty {
                let thread = createThreadSync(title: "")
                activeThreadId = thread.id
                loadHistory(for: thread)
            } else {
                threads = dbThreads.map { ThreadState(from: $0) }
                activeThreadId = threads.first?.id
                if let active = activeThread {
                    loadHistory(for: active)
                }
            }
        } catch {
            NSLog("[ThreadManager] Failed to load threads: %@", "\(error)")
            let thread = createThreadSync(title: "")
            activeThreadId = thread.id
        }
    }

    // MARK: - Thread management

    @discardableResult
    func createThread(title: String = "") -> ThreadState {
        let thread = createThreadSync(title: title)
        activeThreadId = thread.id
        return thread
    }

    @discardableResult
    private func createThreadSync(title: String) -> ThreadState {
        let dbThread = ConversationThread(title: title)
        do {
            try db.write { db in
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
            loadHistory(for: thread)
        }
    }

    func deleteThread(id: String) {
        guard let thread = threads.first(where: { $0.id == id }) else { return }
        stopStreaming(in: thread)

        do {
            try db.write { db in
                try ThreadRepository.delete(db, id: id)
            }
        } catch {
            NSLog("[ThreadManager] Failed to delete thread: %@", "\(error)")
        }

        threads.removeAll { $0.id == id }

        if activeThreadId == id {
            if let first = threads.first {
                switchToThread(id: first.id)
            } else {
                let newThread = createThreadSync(title: "")
                activeThreadId = newThread.id
            }
        }
    }

    // MARK: - History

    private func loadHistory(for thread: ThreadState) {
        let sid = thread.id
        do {
            let turns: [ConversationTurn] = try db.read { db in
                try ConversationRepository.getHistory(db, sessionId: sid)
            }
            thread.historyLoaded = true
            guard !turns.isEmpty else { return }

            var restored: [ChatMessage] = []

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
                    var name = "tool"
                    if let data = turn.content.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        name = parsed["name"] as? String ?? "tool"
                    }
                    if restored.isEmpty || restored.last?.role != .assistant {
                        restored.append(ChatMessage(role: .assistant, text: ""))
                    }
                    restored[restored.count - 1].toolCalls.append(
                        ChatMessage.ToolCallStatus(id: toolCallId, name: name, status: .running, detail: nil)
                    )

                case "tool_result":
                    guard let toolCallId = turn.toolCallId else { continue }
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
            thread.agentLoop = AgentLoop(claudeService: claudeService, toolExecutor: toolExecutor, db: db)
        }

        thread.runningTask = Task {
            guard let agentLoop = thread.agentLoop else {
                thread.messages[assistantIndex].text = "Not configured. Please set up credentials in Settings."
                thread.isStreaming = false
                endBackgroundProcessing()
                return
            }

            let stream = await agentLoop.run(sessionId: thread.id, userMessage: text)

            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .textDelta(let delta):
                    thread.messages[assistantIndex].text += delta
                    BackgroundTaskCoordinator.shared.updateSubtitle("Responding...")

                case .toolStart(let name, let id):
                    thread.messages[assistantIndex].toolCalls.append(
                        ChatMessage.ToolCallStatus(id: id, name: name, status: .running, detail: nil)
                    )
                    BackgroundTaskCoordinator.shared.updateSubtitle("Running \(name)...")

                case .toolProgress(let id, let detail):
                    if let idx = thread.messages[assistantIndex].toolCalls.firstIndex(where: { $0.id == id }) {
                        thread.messages[assistantIndex].toolCalls[idx].detail = detail
                    }
                    BackgroundTaskCoordinator.shared.updateSubtitle(detail)

                case .toolDone(_, let id):
                    if let idx = thread.messages[assistantIndex].toolCalls.firstIndex(where: { $0.id == id }) {
                        thread.messages[assistantIndex].toolCalls[idx].status = .completed
                        thread.messages[assistantIndex].toolCalls[idx].detail = nil
                    }

                case .error(let errorText):
                    if thread.messages[assistantIndex].text.isEmpty {
                        thread.messages[assistantIndex].text = errorText
                    }

                case .done:
                    if thread.messages[assistantIndex].text.isEmpty && thread.messages[assistantIndex].toolCalls.isEmpty {
                        thread.messages[assistantIndex].text = "Done."
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
        if let lastIdx = thread.messages.indices.last, thread.messages[lastIdx].role == .assistant {
            for i in thread.messages[lastIdx].toolCalls.indices {
                if thread.messages[lastIdx].toolCalls[i].status == .running {
                    thread.messages[lastIdx].toolCalls[i].status = .failed("Cancelled")
                }
            }
            if thread.messages[lastIdx].text.isEmpty {
                thread.messages[lastIdx].text = "Cancelled."
            }
        }
    }

    var anyThreadStreaming: Bool {
        threads.contains { $0.isStreaming }
    }

    // MARK: - Scene phase

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            for thread in threads where !thread.isStreaming {
                if let lastIdx = thread.messages.indices.last, thread.messages[lastIdx].role == .assistant {
                    var anyFixed = false
                    for i in thread.messages[lastIdx].toolCalls.indices {
                        if thread.messages[lastIdx].toolCalls[i].status == .running {
                            thread.messages[lastIdx].toolCalls[i].status = .failed("Interrupted")
                            anyFixed = true
                        }
                    }
                    if anyFixed && thread.messages[lastIdx].text.isEmpty {
                        thread.messages[lastIdx].text = "Task was interrupted while the app was in the background."
                    }
                }
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
            if let lastIdx = thread.messages.indices.last, thread.messages[lastIdx].role == .assistant {
                for i in thread.messages[lastIdx].toolCalls.indices {
                    if thread.messages[lastIdx].toolCalls[i].status == .running {
                        thread.messages[lastIdx].toolCalls[i].status = .failed("Background time expired")
                    }
                }
                if thread.messages[lastIdx].text.isEmpty {
                    thread.messages[lastIdx].text = "Background time expired. Open the app to continue."
                }
            }
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
