import Foundation
import Network

/// Low-level NWConnection wrapper for IMAP over TLS.
actor IMAPConnection {
    private var connection: NWConnection?
    private var buffer = Data()
    private var tagCounter = 0

    func connect(host: String, port: UInt16) async throws {
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
                    cont.resume(throwing: SecretaryError.imapError("Connection cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue(label: "imap.connection"))
        }
        connection?.stateUpdateHandler = nil

        // Read server greeting
        let greeting = try await readLine()
        guard greeting.hasPrefix("* OK") else {
            throw SecretaryError.imapError("Unexpected greeting: \(greeting)")
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        buffer = Data()
    }

    func nextTag() -> String {
        tagCounter += 1
        return "A\(String(format: "%04d", tagCounter))"
    }

    /// Send a tagged command and collect all response lines until the tagged response.
    func command(_ cmd: String) async throws -> (tag: String, lines: [String]) {
        let tag = nextTag()
        try await send("\(tag) \(cmd)\r\n")

        var lines: [String] = []
        while true {
            let line = try await readLine()
            if line.hasPrefix(tag) {
                // Check for OK
                let rest = String(line.dropFirst(tag.count + 1))
                if !rest.hasPrefix("OK") {
                    throw SecretaryError.imapError("\(cmd) failed: \(line)")
                }
                return (tag, lines)
            }
            lines.append(line)
        }
    }

    /// Send a tagged command that may include literal data in responses (FETCH).
    /// Returns raw response lines, including literal data appended to the preceding line.
    func commandWithLiterals(_ cmd: String) async throws -> (tag: String, lines: [String]) {
        let tag = nextTag()
        try await send("\(tag) \(cmd)\r\n")

        var lines: [String] = []
        while true {
            let line = try await readLine()
            if line.hasPrefix(tag) {
                let rest = String(line.dropFirst(tag.count + 1))
                if !rest.hasPrefix("OK") {
                    throw SecretaryError.imapError("\(cmd) failed: \(line)")
                }
                return (tag, lines)
            }

            // Check for literal marker {N}
            if let literalSize = parseLiteralSize(line) {
                let literalData = try await readExact(literalSize)
                let literalStr = String(data: literalData, encoding: .utf8) ?? String(data: literalData, encoding: .ascii) ?? ""
                lines.append(line)
                lines.append(literalStr)
            } else {
                lines.append(line)
            }
        }
    }

    // MARK: - Private I/O

    private func send(_ text: String) async throws {
        guard let connection else { throw SecretaryError.imapError("Not connected") }
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

    func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer[buffer.startIndex..<range.lowerBound]
                buffer.removeSubrange(buffer.startIndex...range.upperBound - 1)
                return String(data: lineData, encoding: .utf8) ?? String(data: lineData, encoding: .ascii) ?? ""
            }
            try await fillBuffer()
        }
    }

    private func readExact(_ count: Int) async throws -> Data {
        while buffer.count < count {
            try await fillBuffer()
        }
        let data = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(data)
    }

    private func fillBuffer() async throws {
        guard let connection else { throw SecretaryError.imapError("Not connected") }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: SecretaryError.imapError("Connection closed"))
                }
            }
        }
        buffer.append(data)
    }

    private func parseLiteralSize(_ line: String) -> Int? {
        guard line.hasSuffix("}") else { return nil }
        guard let openBrace = line.lastIndex(of: "{") else { return nil }
        let sizeStr = line[line.index(after: openBrace)..<line.index(before: line.endIndex)]
        return Int(sizeStr)
    }
}
