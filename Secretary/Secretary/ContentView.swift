import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding && KeychainManager.hasCredentials {
            ChatView()
        } else {
            OnboardingView {
                hasCompletedOnboarding = true
            }
        }
    }
}
