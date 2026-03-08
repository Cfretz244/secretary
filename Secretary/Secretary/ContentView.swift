import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @StateObject private var threadManager = ThreadManager()

    var body: some View {
        if hasCompletedOnboarding && KeychainManager.hasCredentials {
            ChatView()
                .environmentObject(threadManager)
                .onAppear {
                    threadManager.setup()
                }
        } else {
            OnboardingView {
                hasCompletedOnboarding = true
            }
        }
    }
}
