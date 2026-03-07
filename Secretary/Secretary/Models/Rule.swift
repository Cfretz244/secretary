import Foundation
import GRDB

struct RuleCondition: Codable, Equatable {
    var field: String
    var op: String
    var value: String
}

struct Rule: Codable, FetchableRecord, Equatable, Identifiable {
    var id: Int64?
    var name: String
    var conditions: [RuleCondition]
    var action: String
    var actionTarget: String?
    var priority: Int = 100
    var enabled: Bool = true
    var createdAt: String = ""
    var updatedAt: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case conditions
        case action
        case actionTarget = "action_target"
        case priority
        case enabled
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: Int64? = nil, name: String, conditions: [RuleCondition], action: String,
         actionTarget: String? = nil, priority: Int = 100, enabled: Bool = true,
         createdAt: String = "", updatedAt: String = "") {
        self.id = id
        self.name = name
        self.conditions = conditions
        self.action = action
        self.actionTarget = actionTarget
        self.priority = priority
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        action = row["action"]
        actionTarget = row["action_target"]
        priority = row["priority"]
        enabled = row["enabled"] as? Bool ?? (row["enabled"] as? Int == 1)
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""

        let conditionsJSON: String = row["conditions"] ?? "[]"
        if let data = conditionsJSON.data(using: .utf8) {
            conditions = (try? JSONDecoder().decode([RuleCondition].self, from: data)) ?? []
        } else {
            conditions = []
        }
    }
}

struct ApplyRulesResult {
    var rulesEvaluated: Int = 0
    var messagesScanned: Int = 0
    var changesStaged: Int = 0
    var skippedAlreadyStaged: Int = 0
    var skippedNoOp: Int = 0
    var errors: [String] = []
    var details: [String] = []
}
