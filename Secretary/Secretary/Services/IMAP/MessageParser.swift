import Foundation
import SwiftSoup

/// Parses IMAP FETCH parts into a dictionary ready for database insertion.
/// Port of sync.py _parse_message, _extract_body_text, _html_to_text.
enum MessageParser {
    static func parse(uid: Int, folder: String, parts: IMAPResponseParser.FetchParts) -> [String: any Sendable] {
        let headerStr = String(data: parts.headerData, encoding: .utf8)
            ?? String(data: parts.headerData, encoding: .ascii) ?? ""
        let textStr = String(data: parts.textData, encoding: .utf8)
            ?? String(data: parts.textData, encoding: .ascii) ?? ""

        // Use simple header parsing (no Foundation MIME parser on iOS)
        let subject = extractHeader(headerStr, field: "Subject")?.decodeRFC2047() ?? ""
        let fromRaw = extractHeader(headerStr, field: "From")?.decodeRFC2047() ?? ""
        let senderEmail = fromRaw.extractEmail()
        let senderName = fromRaw.extractName()
        let to = extractHeader(headerStr, field: "To")?.decodeRFC2047() ?? ""
        let cc = extractHeader(headerStr, field: "Cc")?.decodeRFC2047() ?? ""
        let recipients = cc.isEmpty ? to : (to.isEmpty ? cc : "\(to), \(cc)")

        // Parse date
        let dateHeader = extractHeader(headerStr, field: "Date") ?? parts.internalDate
        let (dateFormatted, dateEpoch) = parseDate(dateHeader)

        // Message-ID
        let messageId = (extractHeader(headerStr, field: "Message-ID") ?? "").trimmingCharacters(in: .whitespaces)

        // Extract body text
        let contentType = extractHeader(headerStr, field: "Content-Type") ?? "text/plain"
        var bodyText = extractBodyText(textStr, contentType: contentType)
        let maxSize = AppConfig.maxBodySize
        if bodyText.utf8.count > maxSize {
            let data = Data(bodyText.utf8.prefix(maxSize))
            bodyText = String(data: data, encoding: .utf8) ?? String(bodyText.prefix(maxSize / 4))
        }
        let bodyPreview = String(bodyText.prefix(200)).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)

        return [
            "folder": folder,
            "uid": uid,
            "message_id": messageId,
            "subject": subject,
            "sender": senderName.isEmpty ? senderEmail : senderName,
            "sender_email": senderEmail,
            "recipients": recipients,
            "date": dateFormatted,
            "date_epoch": dateEpoch,
            "flags": parts.flags,
            "size": parts.rfc822Size,
            "body_text": bodyText,
            "body_preview": bodyPreview,
            "raw_headers": String(headerStr.prefix(10000)),
        ]
    }

    // MARK: - Header extraction

    static func extractHeader(_ headers: String, field: String) -> String? {
        let pattern = "(?i)^\(NSRegularExpression.escapedPattern(for: field)):\\s*(.+?)(?=\\n[^ \\t]|\\n\\n|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..., in: headers)),
              let range = Range(match.range(at: 1), in: headers) else { return nil }
        // Unfold continuation lines
        let value = String(headers[range])
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: " ")
            .replacingOccurrences(of: "\n\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    // MARK: - Body text extraction

    static func extractBodyText(_ rawText: String, contentType: String) -> String {
        let ct = contentType.lowercased()
        if ct.contains("text/html") {
            return htmlToText(rawText)
        }
        if ct.contains("multipart/") {
            return extractFromMultipart(rawText, contentType: contentType)
        }
        // Default: plain text
        return rawText
    }

    static func htmlToText(_ html: String) -> String {
        do {
            let doc = try SwiftSoup.parse(html)
            try doc.select("style, script, head").remove()

            var text = try doc.text(trimAndNormaliseWhitespace: false)

            // Single-pass: strip zero-width chars, trim lines, collapse newlines
            var result: [Character] = []
            result.reserveCapacity(text.count)
            let zwc: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]
            var consecutiveNewlines = 0

            for char in text {
                if zwc.contains(char) { continue }
                if char.isNewline {
                    consecutiveNewlines += 1
                    // Trim trailing whitespace from previous line
                    while let last = result.last, last == " " || last == "\t" {
                        result.removeLast()
                    }
                    if consecutiveNewlines <= 2 {
                        result.append("\n")
                    }
                } else {
                    // Skip leading whitespace on new lines
                    if consecutiveNewlines > 0 && (char == " " || char == "\t") {
                        continue
                    }
                    consecutiveNewlines = 0
                    result.append(char)
                }
            }

            return String(result).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return html
        }
    }

    private static func extractFromMultipart(_ text: String, contentType: String) -> String {
        // Extract boundary from content type
        guard let boundary = extractBoundary(contentType) else { return text }

        let parts = text.components(separatedBy: "--\(boundary)")
        var plainText: String?
        var htmlText: String?

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" { continue }

            // Split headers from body
            let headerBodySplit = trimmed.range(of: "\r\n\r\n") ?? trimmed.range(of: "\n\n")
            guard let split = headerBodySplit else { continue }

            let partHeaders = String(trimmed[..<split.lowerBound])
            let partBody = String(trimmed[split.upperBound...])
            let partCT = extractHeader(partHeaders, field: "Content-Type")?.lowercased() ?? ""

            if partCT.contains("text/plain") && plainText == nil {
                plainText = partBody
            } else if partCT.contains("text/html") && htmlText == nil {
                htmlText = partBody
            } else if partCT.contains("multipart/") {
                let nested = extractFromMultipart(partBody, contentType: partCT)
                if !nested.isEmpty {
                    if plainText == nil { plainText = nested }
                }
            }
        }

        if let plainText, !plainText.isEmpty { return plainText }
        if let htmlText { return htmlToText(htmlText) }
        return ""
    }

    private static func extractBoundary(_ contentType: String) -> String? {
        let pattern = #"boundary="?([^";\s]+)"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)),
              let range = Range(match.range(at: 1), in: contentType) else { return nil }
        return String(contentType[range])
    }

    // MARK: - Date parsing

    private static func parseDate(_ dateStr: String) -> (String, Int) {
        guard !dateStr.isEmpty else { return ("", 0) }

        // Try RFC2822 parsing
        let formatters: [DateFormatter] = {
            let formats = [
                "EEE, dd MMM yyyy HH:mm:ss Z",
                "EEE, dd MMM yyyy HH:mm:ss z",
                "dd MMM yyyy HH:mm:ss Z",
                "dd MMM yyyy HH:mm:ss z",
                "EEE, d MMM yyyy HH:mm:ss Z",
            ]
            return formats.map { fmt in
                let f = DateFormatter()
                f.dateFormat = fmt
                f.locale = Locale(identifier: "en_US_POSIX")
                return f
            }
        }()

        for formatter in formatters {
            if let date = formatter.date(from: dateStr) {
                let iso = ISO8601DateFormatter()
                return (iso.string(from: date), Int(date.timeIntervalSince1970))
            }
        }

        // Try ISO8601
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: dateStr) {
            return (iso.string(from: date), Int(date.timeIntervalSince1970))
        }

        return (dateStr, 0)
    }
}
