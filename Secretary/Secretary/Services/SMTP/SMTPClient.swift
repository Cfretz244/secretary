import Foundation
import Network
import os

/// SMTP client for sending email via iCloud (SMTPS, port 465).
/// Built on NWConnection with implicit TLS, matching the IMAP approach.
actor SMTPClient {
    private var connection: NWConnection?
    private var buffer = Data()
    private let logger = Logger(subsystem: "Secretary", category: "SMTPClient")

    // MARK: - Connect & Authenticate

    func connect(email: String, password: String) async throws {
        try await openConnection(host: AppConfig.icloudSmtpHost, port: AppConfig.icloudSmtpPort)

        // EHLO
        let ehloResp = try await command("EHLO Secretary")
        guard ehloResp.code == 250 else {
            throw SecretaryError.smtpError("EHLO failed: \(ehloResp.text)")
        }

        // AUTH PLAIN: base64(\0email\0password)
        let authString = "\0\(email)\0\(password)"
        let authBase64 = Data(authString.utf8).base64EncodedString()
        let authResp = try await command("AUTH PLAIN \(authBase64)")
        guard authResp.code == 235 else {
            throw SecretaryError.smtpError("AUTH failed: \(authResp.text)")
        }

        logger.info("SMTP authenticated as \(email)")
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        buffer = Data()
    }

    // MARK: - Send

    /// Send a single email. Returns the server response for DATA completion.
    func send(from: String, to: [String], cc: [String], bcc: [String],
              subject: String, body: String, inReplyTo: String? = nil) async throws -> String {
        // MAIL FROM
        let fromResp = try await command("MAIL FROM:<\(from)>")
        guard fromResp.code == 250 else {
            throw SecretaryError.smtpError("MAIL FROM failed: \(fromResp.text)")
        }

        // RCPT TO for all recipients
        let allRecipients = to + cc + bcc
        guard !allRecipients.isEmpty else {
            throw SecretaryError.smtpError("No recipients specified")
        }
        for recipient in allRecipients {
            let rcptResp = try await command("RCPT TO:<\(recipient.trimmingCharacters(in: .whitespaces))>")
            guard rcptResp.code == 250 || rcptResp.code == 251 else {
                throw SecretaryError.smtpError("RCPT TO <\(recipient)> failed: \(rcptResp.text)")
            }
        }

        // DATA
        let dataResp = try await command("DATA")
        guard dataResp.code == 354 else {
            throw SecretaryError.smtpError("DATA failed: \(dataResp.text)")
        }

        // Build RFC 822 message
        let message = buildMessage(from: from, to: to, cc: cc, subject: subject,
                                   body: body, inReplyTo: inReplyTo)

        // Send message body, terminated by \r\n.\r\n
        try await sendRaw(message)
        if !message.hasSuffix("\r\n") {
            try await sendRaw("\r\n")
        }
        let endResp = try await command(".")
        guard endResp.code == 250 else {
            throw SecretaryError.smtpError("Message delivery failed: \(endResp.text)")
        }

        return endResp.text
    }

    /// RSET between sends in the same session.
    func reset() async throws {
        let resp = try await command("RSET")
        guard resp.code == 250 else {
            throw SecretaryError.smtpError("RSET failed: \(resp.text)")
        }
    }

    // MARK: - Message Building

    private func buildMessage(from: String, to: [String], cc: [String],
                              subject: String, body: String, inReplyTo: String?) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = dateFormatter.string(from: Date())

        let messageId = "<\(UUID().uuidString)@\(from.components(separatedBy: "@").last ?? "secretary.local")>"

        var headers = [
            "From: \(from)",
            "To: \(to.joined(separator: ", "))",
        ]
        if !cc.isEmpty {
            headers.append("Cc: \(cc.joined(separator: ", "))")
        }
        headers += [
            "Subject: \(encodeMIMEHeader(subject))",
            "Date: \(dateStr)",
            "Message-ID: \(messageId)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable",
            "X-Mailer: Secretary/1.0",
        ]
        if let inReplyTo {
            headers.append("In-Reply-To: \(inReplyTo)")
            headers.append("References: \(inReplyTo)")
        }

        let encodedBody = quotedPrintableEncode(body)
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + encodedBody
    }

    /// Encode header value for non-ASCII characters (RFC 2047).
    private func encodeMIMEHeader(_ value: String) -> String {
        if value.allSatisfy({ $0.isASCII }) { return value }
        let encoded = Data(value.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    /// Quoted-printable encoding for message body.
    private func quotedPrintableEncode(_ text: String) -> String {
        // Escape dots at start of lines (SMTP transparency)
        var result = ""
        for char in text.unicodeScalars {
            if char == "\n" {
                result += "\r\n"
            } else if char == "\r" {
                continue // will be added with \n
            } else if char.value > 126 || char == "=" {
                let bytes = String(char).utf8
                for byte in bytes {
                    result += String(format: "=%02X", byte)
                }
            } else {
                result += String(char)
            }
        }
        return result
    }

    // MARK: - Low-level Connection

    private func openConnection(host: String, port: UInt16) async throws {
        let tlsOptions = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 30

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: error)
                case .cancelled:
                    cont.resume(throwing: SecretaryError.smtpError("Connection cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue(label: "smtp.connection"))
        }
        connection?.stateUpdateHandler = nil

        // Read server greeting (220)
        let greeting = try await readResponse()
        guard greeting.code == 220 else {
            throw SecretaryError.smtpError("Unexpected greeting: \(greeting.text)")
        }
    }

    private struct Response {
        let code: Int
        let text: String
    }

    /// Read a full SMTP response (may be multiline: "250-..." continuation, "250 ..." final).
    private func readResponse() async throws -> Response {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            lines.append(line)
            // SMTP response: 3-digit code, then space (final) or dash (continuation)
            if line.count >= 4 {
                let separator = line[line.index(line.startIndex, offsetBy: 3)]
                if separator == " " {
                    // Final line
                    let codeStr = String(line.prefix(3))
                    let code = Int(codeStr) ?? 0
                    return Response(code: code, text: lines.joined(separator: "\n"))
                }
            } else {
                // Malformed response
                return Response(code: 0, text: lines.joined(separator: "\n"))
            }
        }
    }

    /// Send a command and read the response.
    private func command(_ cmd: String) async throws -> Response {
        try await sendRaw("\(cmd)\r\n")
        return try await readResponse()
    }

    private func sendRaw(_ text: String) async throws {
        guard let connection else { throw SecretaryError.smtpError("Not connected") }
        let data = text.data(using: .utf8)!
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readLine() async throws -> String {
        let crlf = Data("\r\n".utf8)
        while true {
            try Task.checkCancellation()
            if let range = buffer.range(of: crlf) {
                let lineData = buffer[buffer.startIndex..<range.lowerBound]
                buffer = Data(buffer[range.upperBound...])
                return String(data: Data(lineData), encoding: .utf8)
                    ?? String(data: Data(lineData), encoding: .ascii) ?? ""
            }
            try await fillBuffer()
        }
    }

    private func fillBuffer() async throws {
        guard let connection else { throw SecretaryError.smtpError("Not connected") }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: SecretaryError.smtpError("Connection closed"))
                }
            }
        }
        buffer.append(data)
    }
}
