import SwiftUI
import BackgroundTasks

@main
struct SecretaryApp: App {
    static let backgroundTaskId = "\(Bundle.main.bundleIdentifier!).background"

    init() {
        Self.registerBackgroundTask()
    }

    /// Must be nonisolated so the handler closure does NOT inherit @MainActor.
    /// App protocol is @MainActor; closures in @MainActor context inherit that
    /// isolation. The BGTask handler fires on a background queue, so Swift 6
    /// runtime traps if the closure is @MainActor-isolated.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskId,
            using: nil
        ) { task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            var wasExpired = false
            continuedTask.expirationHandler = {
                wasExpired = true
                DispatchQueue.main.async {
                    BackgroundTaskCoordinator.shared.onExpiration?()
                }
            }

            continuedTask.progress.totalUnitCount = 0
            BackgroundTaskCoordinator.shared.task = continuedTask

            // Block this thread until work completes or expires.
            // The handler MUST block — returning immediately causes a crash.
            while !BackgroundTaskCoordinator.shared.isFinished && !wasExpired {
                sleep(1)
            }

            continuedTask.setTaskCompleted(success: !wasExpired)
            BackgroundTaskCoordinator.shared.task = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Thread-safe coordinator between BGTask handler (background queue) and ChatViewModel (main queue).
final class BackgroundTaskCoordinator: @unchecked Sendable {
    static let shared = BackgroundTaskCoordinator()

    private let lock = NSLock()
    private var _task: BGContinuedProcessingTask?
    private var _isFinished = false
    private var _onExpiration: (() -> Void)?

    var task: BGContinuedProcessingTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue; if newValue != nil { _isFinished = false } } }
    }

    var isFinished: Bool {
        get { lock.withLock { _isFinished } }
    }

    var onExpiration: (() -> Void)? {
        get { lock.withLock { _onExpiration } }
        set { lock.withLock { _onExpiration = newValue } }
    }

    func markFinished() {
        lock.withLock { _isFinished = true }
    }

    func updateProgress(completed: Int64, total: Int64) {
        lock.withLock {
            guard let task = _task else { return }
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = completed
        }
    }

    func updateSubtitle(_ subtitle: String) {
        lock.withLock {
            _task?.updateTitle("Secretary", subtitle: subtitle)
        }
    }
}
