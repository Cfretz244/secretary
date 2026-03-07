import Foundation

/// High-level IMAP client wrapping IMAPConnection.
/// Port of Python imap_client.py — all methods are async.
actor IMAPClient {
    private let connection = IMAPConnection()
    private let host: String
    private let port: UInt16

    struct FolderInfo {
        let name: String
        let flags: String
        let delimiter: String
    }

    struct SelectResult {
        let uidvalidity: Int
        let uidnext: Int
        let messageCount: Int
    }

    init(host: String = AppConfig.icloudImapHost, port: UInt16 = AppConfig.icloudImapPort) {
        self.host = host
        self.port = port
    }

    func connect(email: String, password: String) async throws {
        try await connection.connect(host: host, port: port)
        let (_, lines) = try await connection.command("LOGIN \"\(email)\" \"\(password)\"")
        _ = lines // login response
    }

    func disconnect() async {
        try? await connection.command("LOGOUT")
        await connection.disconnect()
    }

    // MARK: - Folder operations

    func listFolders() async throws -> [FolderInfo] {
        let (_, lines) = try await connection.command("LIST \"\" \"*\"")
        return lines.compactMap { line -> FolderInfo? in
            guard line.hasPrefix("* LIST") else { return nil }
            let content = String(line.dropFirst("* LIST ".count))
            guard let parsed = IMAPResponseParser.parseListLine(content) else { return nil }
            return FolderInfo(name: parsed.name, flags: parsed.flags, delimiter: parsed.delimiter)
        }
    }

    func selectFolder(_ folder: String, readonly: Bool = true) async throws -> SelectResult {
        let cmd = readonly ? "EXAMINE" : "SELECT"
        let (_, lines) = try await connection.command("\(cmd) \"\(folder)\"")
        let messageCount = IMAPResponseParser.parseSelectCount(lines)

        let uidvalidity = try await getStatusValue(folder: folder, item: "UIDVALIDITY")
        let uidnext = try await getStatusValue(folder: folder, item: "UIDNEXT")

        return SelectResult(uidvalidity: uidvalidity, uidnext: uidnext, messageCount: messageCount)
    }

    func createFolder(_ folder: String) async throws {
        let (_, _) = try await connection.command("CREATE \"\(folder)\"")
    }

    // MARK: - UID operations

    func searchUids(criteria: String = "ALL") async throws -> [Int] {
        let (_, lines) = try await connection.command("UID SEARCH \(criteria)")
        return IMAPResponseParser.parseSearchResponse(lines)
    }

    func searchUidsRange(startUid: Int) async throws -> [Int] {
        try await searchUids(criteria: "UID \(startUid):*")
    }

    func fetchMessages(uids: [Int], parts: String = "(FLAGS BODY.PEEK[HEADER] BODY.PEEK[TEXT] RFC822.SIZE INTERNALDATE)") async throws -> [Int: IMAPResponseParser.FetchParts] {
        guard !uids.isEmpty else { return [:] }
        let uidStr = uids.map(String.init).joined(separator: ",")
        let (_, lines) = try await connection.commandWithLiterals("UID FETCH \(uidStr) \(parts)")
        return IMAPResponseParser.parseFetchResponse(lines)
    }

    func fetchMessageIdsAndFlags(uids: [Int]) async throws -> [Int: (messageId: String, flags: String)] {
        guard !uids.isEmpty else { return [:] }
        let uidStr = uids.map(String.init).joined(separator: ",")
        let (_, lines) = try await connection.commandWithLiterals(
            "UID FETCH \(uidStr) (FLAGS BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])"
        )
        return IMAPResponseParser.parseMessageIdFetch(lines)
    }

    // MARK: - Modification operations

    func copy(uids: [Int], targetFolder: String) async throws {
        let uidStr = uids.map(String.init).joined(separator: ",")
        let (_, _) = try await connection.command("UID COPY \(uidStr) \"\(targetFolder)\"")
    }

    func addFlags(uids: [Int], flags: String) async throws {
        let uidStr = uids.map(String.init).joined(separator: ",")
        let (_, _) = try await connection.command("UID STORE \(uidStr) +FLAGS \(flags)")
    }

    func removeFlags(uids: [Int], flags: String) async throws {
        let uidStr = uids.map(String.init).joined(separator: ",")
        let (_, _) = try await connection.command("UID STORE \(uidStr) -FLAGS \(flags)")
    }

    func markDeleted(uids: [Int]) async throws {
        try await addFlags(uids: uids, flags: "(\\Deleted)")
    }

    func expunge() async throws {
        let (_, _) = try await connection.command("EXPUNGE")
    }

    // MARK: - Private

    private func getStatusValue(folder: String, item: String) async throws -> Int {
        let (_, lines) = try await connection.command("STATUS \"\(folder)\" (\(item))")
        for line in lines {
            if let value = IMAPResponseParser.parseStatusValue(line, item: item) {
                return value
            }
        }
        throw SecretaryError.imapError("Could not parse \(item) for \(folder)")
    }
}
