import SwiftUI
import GRDB

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirmation = false

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

                Section("Data") {
                    Button("Reset Database", role: .destructive) {
                        showResetConfirmation = true
                    }
                }
            }
            .confirmationDialog("Reset Database?",
                                isPresented: $showResetConfirmation,
                                titleVisibility: .visible) {
                Button("Delete All Data", role: .destructive) {
                    resetDatabase()
                }
            } message: {
                Text("This will delete all synced emails, rules, and conversation history. Your credentials will be kept. Email will need to be re-synced.")
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

    private func resetDatabase() {
        let db = DatabaseManager.shared.dbQueue
        do {
            try db.write { db in
                // Drop all tables and recreate schema
                try db.execute(sql: """
                    DROP TABLE IF EXISTS conversations;
                    DROP TABLE IF EXISTS rules;
                    DROP TABLE IF EXISTS sync_log;
                    DROP TABLE IF EXISTS staged_changes;
                    DROP TABLE IF EXISTS messages_fts;
                    DROP TABLE IF EXISTS messages;
                    DROP TABLE IF EXISTS folders;
                """)
                try Schema.create(in: db)
            }
            NotificationCenter.default.post(name: DatabaseManager.databaseResetNotification, object: nil)
        } catch {
            NSLog("[SettingsView] Database reset failed: %@", "\(error)")
        }
    }
}
