import Foundation

struct SyncResult {
    var folder: String
    var newMessages: Int = 0
    var deletedMessages: Int = 0
    var movedMessages: Int = 0
    var skippedRemovals: Int = 0
    var uidvalidityReset: Bool = false
    var errors: [String] = []
    var skipped: Bool = false

    var summary: String {
        if skipped {
            return "\(folder): up to date"
        }
        var parts = ["\(folder): +\(newMessages)"]
        if movedMessages > 0 { parts.append("~\(movedMessages) moved") }
        if deletedMessages > 0 { parts.append("-\(deletedMessages)") }
        if skippedRemovals > 0 { parts.append("(\(skippedRemovals) removals skipped)") }
        if uidvalidityReset { parts.append("(full re-sync)") }
        if !errors.isEmpty { parts.append("(\(errors.count) errors)") }
        return parts.joined(separator: " ")
    }
}

struct FlushResult {
    var folder: String
    var flagsSet: Int = 0
    var flagsRemoved: Int = 0
    var moved: Int = 0
    var deleted: Int = 0
    var errors: [String] = []
}
