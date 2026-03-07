import Foundation

/// Parses raw IMAP FETCH response lines into structured data.
enum IMAPResponseParser {
    struct FetchParts {
        var flags: String = ""
        var rfc822Size: Int = 0
        var internalDate: String = ""
        var headerData: Data = Data()
        var textData: Data = Data()
        var headerFieldsData: Data = Data()
    }

    /// Parse a LIST response line into folder info.
    static func parseListLine(_ line: String) -> (name: String, flags: String, delimiter: String)? {
        // Pattern: (\flags) "delimiter" name
        guard let flagsEnd = line.firstIndex(of: ")"),
              let flagsStart = line.firstIndex(of: "(") else { return nil }

        let flags = String(line[line.index(after: flagsStart)..<flagsEnd])

        let afterFlags = line[line.index(after: flagsEnd)...]
        // Find delimiter in quotes
        guard let delimStart = afterFlags.firstIndex(of: "\"") else { return nil }
        let afterDelimStart = afterFlags[afterFlags.index(after: delimStart)...]
        guard let delimEnd = afterDelimStart.firstIndex(of: "\"") else { return nil }
        let delimiter = String(afterFlags[afterFlags.index(after: delimStart)..<delimEnd])

        // Name is everything after the second quote + space
        let nameStart = afterFlags.index(after: delimEnd)
        var name = String(afterFlags[nameStart...]).trimmingCharacters(in: .whitespaces)
        // Remove surrounding quotes if present
        if name.hasPrefix("\"") && name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast())
        }

        return (name: name, flags: flags, delimiter: delimiter)
    }

    /// Parse STATUS response to extract a numeric value.
    static func parseStatusValue(_ line: String, item: String) -> Int? {
        let pattern = "\(item)\\s+(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[range])
    }

    /// Parse SELECT response lines to extract message count.
    static func parseSelectCount(_ lines: [String]) -> Int {
        for line in lines {
            // "* N EXISTS"
            let pattern = #"^\* (\d+) EXISTS"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                return Int(line[range]) ?? 0
            }
        }
        return 0
    }

    /// Parse UID SEARCH response.
    static func parseSearchResponse(_ lines: [String]) -> [Int] {
        for line in lines where line.hasPrefix("* SEARCH") {
            let parts = line.dropFirst("* SEARCH".count).split(separator: " ")
            return parts.compactMap { Int($0) }
        }
        return []
    }

    /// Parse FETCH response lines (with literals already inlined) into uid -> FetchParts.
    static func parseFetchResponse(_ lines: [String]) -> [Int: FetchParts] {
        var results: [Int: FetchParts] = [:]
        var currentUid: Int?
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Try to extract UID from this line
            if let uid = extractUID(from: line) {
                currentUid = uid
            }

            guard let uid = currentUid else {
                i += 1
                continue
            }

            var parts = results[uid, default: FetchParts()]

            // Extract FLAGS
            if let flagsMatch = extractFlags(from: line) {
                parts.flags = flagsMatch
            }

            // Extract RFC822.SIZE
            if let size = extractRFC822Size(from: line) {
                parts.rfc822Size = size
            }

            // Extract INTERNALDATE
            if let date = extractInternalDate(from: line) {
                parts.internalDate = date
            }

            // Check if this line references a BODY part with a literal following
            let upperLine = line.uppercased()
            if upperLine.contains("BODY[HEADER]") || upperLine.contains("BODY[TEXT]") ||
               upperLine.contains("BODY[HEADER.FIELDS") {
                // Next line should be the literal data
                if i + 1 < lines.count {
                    let literalData = lines[i + 1].data(using: .utf8) ?? Data()
                    if upperLine.contains("BODY[HEADER.FIELDS") {
                        parts.headerFieldsData = literalData
                    } else if upperLine.contains("BODY[HEADER]") {
                        parts.headerData = literalData
                    } else if upperLine.contains("BODY[TEXT]") {
                        parts.textData = literalData
                    }
                    i += 1 // skip the literal line
                }
            }

            results[uid] = parts
            i += 1
        }

        return results
    }

    /// Parse lightweight fetch for Message-ID + FLAGS
    static func parseMessageIdFetch(_ lines: [String]) -> [Int: (messageId: String, flags: String)] {
        var results: [Int: (messageId: String, flags: String)] = [:]
        var currentUid: Int?
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if let uid = extractUID(from: line) {
                currentUid = uid
            }

            guard let uid = currentUid else {
                i += 1
                continue
            }

            var entry = results[uid, default: (messageId: "", flags: "")]

            if let flags = extractFlags(from: line) {
                entry.flags = flags
            }

            // Check for literal containing Message-ID header
            if line.uppercased().contains("BODY[HEADER.FIELDS") && i + 1 < lines.count {
                let headerText = lines[i + 1]
                if let mid = extractMessageIdHeader(from: headerText) {
                    entry.messageId = mid
                }
                i += 1
            }

            results[uid] = entry
            i += 1
        }

        return results
    }

    // MARK: - Helpers

    private static func extractUID(from line: String) -> Int? {
        let pattern = #"UID\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[range])
    }

    private static func extractFlags(from line: String) -> String? {
        let pattern = #"FLAGS\s+\(([^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func extractRFC822Size(from line: String) -> Int? {
        let pattern = #"RFC822\.SIZE\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[range])
    }

    private static func extractInternalDate(from line: String) -> String? {
        let pattern = #"INTERNALDATE\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func extractMessageIdHeader(from text: String) -> String? {
        let pattern = #"(?i)Message-ID:\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
