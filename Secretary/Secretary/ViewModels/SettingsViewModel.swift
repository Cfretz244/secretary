import Foundation
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var icloudEmail: String = ""
    @Published var icloudPassword: String = ""
    @Published var anthropicAPIKey: String = ""
    @Published var connectionStatus: String = ""
    @Published var isTesting: Bool = false

    @Published var companionURL: String = ""
    @Published var companionToken: String = ""
    @Published var companionStatus: String = ""
    @Published var isTestingCompanion: Bool = false

    init() {
        loadFromKeychain()
    }

    func loadFromKeychain() {
        icloudEmail = KeychainManager.get(.icloudEmail) ?? ""
        icloudPassword = KeychainManager.get(.icloudPassword) ?? ""
        anthropicAPIKey = KeychainManager.get(.anthropicAPIKey) ?? ""
        companionURL = KeychainManager.get(.companionURL) ?? ""
        companionToken = KeychainManager.get(.companionToken) ?? ""
    }

    func save() {
        do {
            try KeychainManager.set(.icloudEmail, value: icloudEmail)
            try KeychainManager.set(.icloudPassword, value: icloudPassword)
            try KeychainManager.set(.anthropicAPIKey, value: anthropicAPIKey)
            try KeychainManager.set(.companionURL, value: companionURL)
            try KeychainManager.set(.companionToken, value: companionToken)
            connectionStatus = "Credentials saved."
        } catch {
            connectionStatus = "Failed to save: \(error.localizedDescription)"
        }
    }

    func testCompanion() {
        guard !companionURL.isEmpty, !companionToken.isEmpty else {
            companionStatus = "Please enter URL and token."
            return
        }

        // Save companion credentials before testing
        do {
            try KeychainManager.set(.companionURL, value: companionURL)
            try KeychainManager.set(.companionToken, value: companionToken)
        } catch {
            companionStatus = "Failed to save: \(error.localizedDescription)"
            return
        }

        isTestingCompanion = true
        companionStatus = "Testing..."

        Task {
            do {
                let db = DatabaseManager.shared.dbQueue
                let svc = MessagesService(baseURL: companionURL, authToken: companionToken, db: db)
                let result = try await svc.testConnection()
                companionStatus = result
            } catch {
                companionStatus = "Failed: \(error.localizedDescription)"
            }
            isTestingCompanion = false
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
