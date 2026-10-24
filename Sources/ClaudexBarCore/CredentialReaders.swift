import Foundation

public protocol CodexAuthReading: Sendable {
    func readAccessToken() throws -> String
}

public struct CodexAuthReader: CodexAuthReading {
    private let authURL: URL

    public init(authURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")) {
        self.authURL = authURL
    }

    public func readAccessToken() throws -> String {
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw UsageError.missingAuth
        }

        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ClaudeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Int?

    public init(accessToken: String, refreshToken: String?, expiresAt: Int?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public protocol ClaudeCredentialReading: Sendable {
    func readCredentials() throws -> ClaudeCredentials
}

public struct ClaudeCredentialReader: ClaudeCredentialReading {
    private let keychainServices: [String]
    private let fallbackURL: URL
    private let environment: [String: String]

    public init(
        keychainServices: [String] = ["Claude Code-credentials"],
        fallbackURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.keychainServices = keychainServices
        self.fallbackURL = fallbackURL
        self.environment = environment
    }

    /// Follows Claude Code's own login, re-read on every fetch, so whatever
    /// Claude Code currently holds (after an update, /login, or a token
    /// refresh) is picked up automatically. The refresh token is dropped:
    /// Claude rotates it on every use, so refreshing here would sign Claude
    /// Code out. Claude Code stays the only party that refreshes.
    public func readCredentials() throws -> ClaudeCredentials {
        // Explicit override wins for power users.
        if let credentials = try? Self.credentialsFromEnvironment(environment) {
            return credentials
        }

        for service in keychainServices {
            if let data = keychainData(service: service),
               let credentials = Self.decodeCredentials(data: data) {
                return Self.readOnly(credentials)
            }
        }

        if let data = try? Data(contentsOf: fallbackURL),
           let credentials = Self.decodeCredentials(data: data) {
            return Self.readOnly(credentials)
        }

        throw UsageError.missingAuth
    }

    static func readOnly(_ credentials: ClaudeCredentials) -> ClaudeCredentials {
        ClaudeCredentials(accessToken: credentials.accessToken, refreshToken: nil, expiresAt: credentials.expiresAt)
    }

    public static func credentialsFromEnvironment(_ environment: [String: String]) throws -> ClaudeCredentials {
        guard let token = environment["CLAUDE_CODE_OAUTH_TOKEN"].map(stripBearerPrefix),
              !token.isEmpty
        else {
            throw UsageError.missingAuth
        }

        return ClaudeCredentials(accessToken: token, refreshToken: nil, expiresAt: nil)
    }

    public static func decodeCredentials(data: Data) -> ClaudeCredentials? {
        let decodedData: Data
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["claudeAiOauth"] != nil {
            decodedData = data
        } else if let text = String(data: data, encoding: .utf8),
                  let hexData = decodeHexOrJSONText(text) {
            decodedData = hexData
        } else {
            return nil
        }

        guard let root = try? JSONSerialization.jsonObject(with: decodedData) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let rawAccessToken = oauth["accessToken"] as? String
        else {
            return nil
        }

        return ClaudeCredentials(
            accessToken: stripBearerPrefix(rawAccessToken),
            refreshToken: (oauth["refreshToken"] as? String).flatMap(stripBearerPrefix),
            expiresAt: oauth["expiresAt"] as? Int
        )
    }

    /// Reads through /usr/bin/security rather than SecItemCopyMatching.
    /// Claude Code writes this item with the `security` tool, so `security`
    /// is on the item's access list and the read never triggers a Keychain
    /// prompt, even after Claude Code rewrites the item.
    private func keychainData(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private static func decodeHexOrJSONText(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        var hex = trimmed
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex.removeFirst(2)
        }
        guard hex.count % 2 == 0 else { return nil }

        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

public func stripBearerPrefix(_ token: String) -> String {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("bearer ") {
        return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}
