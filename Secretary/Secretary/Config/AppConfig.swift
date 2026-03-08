import Foundation

enum AppConfig {
    static let icloudImapHost = "imap.mail.me.com"
    static let icloudImapPort: UInt16 = 993

    static let maxBodySize = 102400
    static let batchSize = 50
    static let maxOutputSize = 4000
    static let flushBatchSize = 500

    // Agent loop
    static let maxToolIterations = 15
    static let loopTimeoutSeconds: TimeInterval = 120
    static let toolResultMaxChars = 8000
    static let agentModel = "claude-sonnet-4-20250514"
    static let agentMaxTokens = 4096

    // Conversation trimming
    static let trimThreshold = 80
    static let trimKeep = 40
    static let maxContextChars = 80_000
}
