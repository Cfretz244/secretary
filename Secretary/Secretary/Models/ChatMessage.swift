import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var text: String
    var toolCalls: [ToolCallStatus]
    let timestamp: Date

    enum Role: Equatable {
        case user
        case assistant
    }

    struct ToolCallStatus: Identifiable, Equatable {
        let id: String
        let name: String
        var status: Status
        var detail: String?

        enum Status: Equatable {
            case running
            case completed
            case failed(String)
        }
    }

    init(role: Role, text: String, toolCalls: [ToolCallStatus] = []) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.timestamp = Date()
    }
}
