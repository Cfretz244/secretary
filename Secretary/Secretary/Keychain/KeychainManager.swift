import Foundation
import KeychainAccess

enum KeychainManager {
    private nonisolated(unsafe) static let keychain = Keychain(service: "com.secretary.ios")

    enum Key: String {
        case icloudEmail = "icloud_email"
        case icloudPassword = "icloud_password"
        case anthropicAPIKey = "anthropic_api_key"
    }

    static func get(_ key: Key) -> String? {
        try? keychain.get(key.rawValue)
    }

    static func set(_ key: Key, value: String) throws {
        try keychain.set(value, key: key.rawValue)
    }

    static func remove(_ key: Key) throws {
        try keychain.remove(key.rawValue)
    }

    static var hasCredentials: Bool {
        Self.get(.icloudEmail) != nil &&
        Self.get(.icloudPassword) != nil &&
        Self.get(.anthropicAPIKey) != nil
    }

    static var icloudEmail: String { Self.get(.icloudEmail) ?? "" }
    static var icloudPassword: String { Self.get(.icloudPassword) ?? "" }
    static var anthropicAPIKey: String { Self.get(.anthropicAPIKey) ?? "" }
}
