import Foundation
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var icloudEmail: String = ""
    @Published var icloudPassword: String = ""
    @Published var anthropicAPIKey: String = ""
    @Published var connectionStatus: String = ""
    @Published var isTesting: Bool = false

    init() {
        loadFromKeychain()
    }

    func loadFromKeychain() {
        icloudEmail = KeychainManager.get(.icloudEmail) ?? ""
        icloudPassword = KeychainManager.get(.icloudPassword) ?? ""
        anthropicAPIKey = KeychainManager.get(.anthropicAPIKey) ?? ""
    }

    func save() {
        do {
            try KeychainManager.set(.icloudEmail, value: icloudEmail)
            try KeychainManager.set(.icloudPassword, value: icloudPassword)
            try KeychainManager.set(.anthropicAPIKey, value: anthropicAPIKey)
            connectionStatus = "Credentials saved."
        } catch {
            connectionStatus = "Failed to save: \(error.localizedDescription)"
        }
    }

    func testConnection() {
        guard !icloudEmail.isEmpty, !icloudPassword.isEmpty else {
            connectionStatus = "Please enter email and password."
            return
        }
        isTesting = true
        connectionStatus = "Testing..."

        Task {
            do {
                let imap = IMAPClient()
                try await imap.connect(email: icloudEmail, password: icloudPassword)
                let folders = try await imap.listFolders()
                await imap.disconnect()
                connectionStatus = "Connected! Found \(folders.count) folders."
            } catch {
                connectionStatus = "Connection failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    var hasCredentials: Bool {
        !icloudEmail.isEmpty && !icloudPassword.isEmpty && !anthropicAPIKey.isEmpty
    }
}
