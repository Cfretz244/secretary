import Foundation

extension String {
    /// Extract email address from a From header (e.g. "Name <email@example.com>")
    func extractEmail() -> String {
        if let match = self.range(of: #"<([^>]+)>"#, options: .regularExpression) {
            let inner = self[match].dropFirst().dropLast()
            return String(inner).lowercased()
        }
        if let match = self.range(of: #"[\w.+-]+@[\w.-]+"#, options: .regularExpression) {
            return String(self[match]).lowercased()
        }
        return self.lowercased()
    }

    /// Extract display name from a From header
    func extractName() -> String {
        if let match = self.range(of: #""?([^"<]+)"?\s*<"#, options: .regularExpression) {
            let name = self[match]
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "<", with: "")
                .trimmingCharacters(in: .whitespaces)
            return name
        }
        return ""
    }

    /// Decode RFC2047 encoded header value
    func decodeRFC2047() -> String {
        // Pattern: =?charset?encoding?encoded_text?=
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }

        var result = self
        let matches = regex.matches(in: self, range: NSRange(self.startIndex..., in: self))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let charsetRange = Range(match.range(at: 1), in: result),
                  let encodingRange = Range(match.range(at: 2), in: result),
                  let textRange = Range(match.range(at: 3), in: result) else { continue }

            let charset = String(result[charsetRange])
            let encoding = String(result[encodingRange]).uppercased()
            let encodedText = String(result[textRange])

            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            let swiftEncoding = String.Encoding(rawValue: nsEncoding)

            var decoded: String?
            if encoding == "B" {
                if let data = Data(base64Encoded: encodedText) {
                    decoded = String(data: data, encoding: swiftEncoding)
                }
            } else if encoding == "Q" {
                let unescaped = encodedText
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "=([0-9A-Fa-f]{2})", with: "", options: .regularExpression)
                // Simple Q decoding
                var data = Data()
                var i = unescaped.startIndex
                let qText = encodedText.replacingOccurrences(of: "_", with: " ")
                var qi = qText.startIndex
                while qi < qText.endIndex {
                    if qText[qi] == "=" {
                        let hexStart = qText.index(after: qi)
                        if hexStart < qText.endIndex {
                            let hexEnd = qText.index(hexStart, offsetBy: min(2, qText.distance(from: hexStart, to: qText.endIndex)))
                            let hex = String(qText[hexStart..<hexEnd])
                            if let byte = UInt8(hex, radix: 16) {
                                data.append(byte)
                                qi = hexEnd
                                continue
                            }
                        }
                    }
                    if let byte = String(qText[qi]).data(using: .ascii)?.first {
                        data.append(byte)
                    }
                    qi = qText.index(after: qi)
                }
                decoded = String(data: data, encoding: swiftEncoding)
            }

            if let decoded {
                result.replaceSubrange(fullRange, with: decoded)
            }
        }

        return result
    }
}
