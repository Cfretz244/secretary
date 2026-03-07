import SwiftUI
import BackgroundTasks

@main
struct SecretaryApp: App {
    static let backgroundTaskIdentifier = "com.secretary.ios.agent"

    init() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            continuedTask.expirationHandler = {
                BackgroundTaskCoordinator.shared.handleExpiration()
                continuedTask.setTaskCompleted(success: false)
            }
            continuedTask.progress.totalUnitCount = -1 // indeterminate initially
            BackgroundTaskCoordinator.shared.activeTask = continuedTask
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Coordinates between the BGContinuedProcessingTask handler and the ChatViewModel.
@MainActor
final class BackgroundTaskCoordinator {
    static let shared = BackgroundTaskCoordinator()
    var activeTask: BGContinuedProcessingTask?
    var onExpiration: (() -> Void)?

    func handleExpiration() {
        onExpiration?()
        activeTask = nil
        onExpiration = nil
    }

    func complete(success: Bool) {
        activeTask?.setTaskCompleted(success: success)
        activeTask = nil
        onExpiration = nil
    }

    func updateProgress(completed: Int64, total: Int64) {
        guard let task = activeTask else { return }
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = completed
    }
}
