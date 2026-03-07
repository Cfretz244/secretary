import SwiftUI

struct OnboardingView: View {
    @StateObject private var viewModel = SettingsViewModel()
    var onComplete: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Welcome to Secretary")
                        .font(.title2.bold())
                    Text("Set up your iCloud Mail and Claude API credentials to get started.")
                        .foregroundStyle(.secondary)
                }

                Section("iCloud Mail") {
                    TextField("iCloud Email", text: $viewModel.icloudEmail)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)
                    SecureField("App-Specific Password", text: $viewModel.icloudPassword)
                        .textContentType(.password)

                    Text("Generate an app-specific password at appleid.apple.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Claude API") {
                    SecureField("Anthropic API Key", text: $viewModel.anthropicAPIKey)
                        .textContentType(.password)
                }

                Section {
                    Button("Test Connection") {
                        viewModel.testConnection()
                    }
                    .disabled(viewModel.isTesting || viewModel.icloudEmail.isEmpty || viewModel.icloudPassword.isEmpty)

                    if !viewModel.connectionStatus.isEmpty {
                        Text(viewModel.connectionStatus)
                            .font(.caption)
                            .foregroundStyle(viewModel.connectionStatus.contains("Connected") ? .green : .secondary)
                    }
                }

                Section {
                    Button("Get Started") {
                        viewModel.save()
                        onComplete()
                    }
                    .disabled(!viewModel.hasCredentials)
                    .frame(maxWidth: .infinity)
                    .bold()
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
