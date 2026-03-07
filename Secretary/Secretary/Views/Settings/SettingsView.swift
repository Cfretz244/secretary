import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud Mail") {
                    TextField("Email", text: $viewModel.icloudEmail)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)
                    SecureField("App-Specific Password", text: $viewModel.icloudPassword)
                        .textContentType(.password)
                }

                Section("Claude API") {
                    SecureField("Anthropic API Key", text: $viewModel.anthropicAPIKey)
                        .textContentType(.password)
                }

                Section {
                    Button("Test IMAP Connection") {
                        viewModel.testConnection()
                    }
                    .disabled(viewModel.isTesting)

                    if !viewModel.connectionStatus.isEmpty {
                        Text(viewModel.connectionStatus)
                            .font(.caption)
                            .foregroundStyle(viewModel.connectionStatus.contains("Connected") ? .green : .secondary)
                    }
                }

                Section {
                    Button("Save") {
                        viewModel.save()
                    }
                    .disabled(!viewModel.hasCredentials)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
