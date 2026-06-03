import Foundation
import Security

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
    private let credentialStore: ClaudeCredentialStore

    public init(
        keychainServices: [String] = ["Claude Code-credentials"],
        fallbackURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialStore: ClaudeCredentialStore = ClaudeCredentialStore()
    ) {
        self.keychainServices = keychainServices
        self.fallbackURL = fallbackURL
        self.environment = environment
        self.credentialStore = credentialStore
    }

    public func readCredentials() throws -> ClaudeCredentials {
        // Explicit override wins for power users.
        if let credentials = try? Self.credentialsFromEnvironment(environment) {
            return credentials
        }

        // ClaudexBar's own OAuth credential (full scopes, with refresh token).
        if let credentials = credentialStore.load() {
            return credentials
        }

        // Fall back to Claude Code's own login if present and still valid.
        for service in keychainServices {
            if let data = keychainData(service: service),
               let credentials = Self.decodeCredentials(data: data) {
                return credentials
            }
        }

        if let data = try? Data(contentsOf: fallbackURL),
           let credentials = Self.decodeCredentials(data: data) {
            return credentials
        }

        throw UsageError.missingAuth
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

    private func keychainData(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
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
