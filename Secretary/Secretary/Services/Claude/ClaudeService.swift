import Foundation
import SwiftAnthropic

final class ClaudeService: @unchecked Sendable {
    let client: any AnthropicService

    init(apiKey: String) {
        self.client = AnthropicServiceFactory.service(apiKey: apiKey, betaHeaders: nil)
    }
}
