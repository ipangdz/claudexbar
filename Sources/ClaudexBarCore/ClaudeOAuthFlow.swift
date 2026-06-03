import Foundation
import Security
#if canImport(CryptoKit)
import CryptoKit
#endif

/// base64url encoding without padding (RFC 7636).
func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// PKCE pair used by the Claude OAuth flow. Public for testing.
public struct PKCEChallenge: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = base64URLEncode(Data(digest))
        #else
        self.challenge = verifier
        #endif
    }

    public static func random() -> PKCEChallenge {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PKCEChallenge(verifier: base64URLEncode(Data(bytes)))
    }
}

/// Stores ClaudexBar's own Claude OAuth credential (access + refresh + expiry)
/// in the macOS Keychain, in the same `claudeAiOauth` JSON shape Claude Code
/// uses so `ClaudeCredentialReader.decodeCredentials` can read it back.
public struct ClaudeCredentialStore: Sendable {
    public static let service = "ClaudexBar-Claude-Credentials"
    private let account = "default"

    public init() {}

    public func save(_ credentials: ClaudeCredentials) throws {
        var oauth: [String: Any] = ["accessToken": credentials.accessToken]
        if let refresh = credentials.refreshToken { oauth["refreshToken"] = refresh }
        if let expiresAt = credentials.expiresAt { oauth["expiresAt"] = expiresAt }
        let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw UsageError.keychain }
            return
        }
        throw UsageError.keychain
    }

    public func load() -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return ClaudeCredentialReader.decodeCredentials(data: data)
    }

    public func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service
        ] as CFDictionary)
    }
}

/// Runs Claude's OAuth Authorization-Code + PKCE flow (the same one Claude
/// Code's own `auth login` uses). ClaudexBar opens the browser to the Claude
/// authorize page; after the user approves, Claude's callback page displays a
/// `code#state` string, which the user pastes into ClaudexBar. ClaudexBar
/// exchanges it (with the PKCE verifier) for an independent access+refresh
/// credential carrying the scopes the usage endpoint requires. This is the
/// platform-code flow — Claude's OAuth client does not accept a localhost
/// loopback redirect, so there is no in-app callback server.
///
/// The scopes deliberately match a real Claude Code login (and exclude
/// `org:create_api_key`, which makes the authorize request fail). Tokens are
/// never logged.
public final class ClaudeOAuthFlow: @unchecked Sendable {
    public enum FlowError: Error, Sendable {
        case emptyCode
        case stateMismatch
        case network
        case exchange(status: Int)
        case parse
        case keychain
    }

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let scope = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    static let authorizeBase = "https://claude.com/cai/oauth/authorize"
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    private let pkce: PKCEChallenge
    private let state: String
    private let store: ClaudeCredentialStore
    private let session: URLSession

    public init(store: ClaudeCredentialStore = ClaudeCredentialStore(), session: URLSession = .shared) {
        self.pkce = PKCEChallenge.random()
        self.state = base64URLEncode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        self.store = store
        self.session = session
    }

    /// The URL to open in the user's browser to begin sign-in.
    public func authorizeURL() -> URL {
        var components = URLComponents(string: Self.authorizeBase)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    /// Splits a pasted `code#state` (or bare `code`) into its parts.
    public static func splitPastedCode(_ pasted: String) -> (code: String, state: String?) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = trimmed.firstIndex(of: "#") else { return (trimmed, nil) }
        return (String(trimmed[..<hash]), String(trimmed[trimmed.index(after: hash)...]))
    }

    /// Exchanges the pasted authorization code for a credential and stores it.
    public func submitCode(_ pasted: String) async -> Result<ClaudeCredentials, FlowError> {
        let (code, returnedState) = Self.splitPastedCode(pasted)
        guard !code.isEmpty else { return .failure(.emptyCode) }
        if let returnedState, returnedState != state { return .failure(.stateMismatch) }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = Self.formBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": pkce.verifier,
            "state": state
        ])

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else { return .failure(.exchange(status: status)) }
            guard let credentials = Self.parseTokenResponse(data) else { return .failure(.parse) }
            do {
                try store.save(credentials)
            } catch {
                return .failure(.keychain)
            }
            return .success(credentials)
        } catch {
            return .failure(.network)
        }
    }

    public static func parseTokenResponse(_ data: Data, now: Date = Date()) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = (root["access_token"] as? String).map(stripBearerPrefix),
              !accessToken.isEmpty else {
            return nil
        }
        let refreshToken = (root["refresh_token"] as? String).flatMap { token -> String? in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var expiresAt: Int?
        if let expiresIn = root["expires_in"] as? Int {
            expiresAt = Int(now.timeIntervalSince1970 * 1_000) + expiresIn * 1_000
        } else if let expiresIn = root["expires_in"] as? Double {
            expiresAt = Int(now.timeIntervalSince1970 * 1_000) + Int(expiresIn * 1_000)
        }
        return ClaudeCredentials(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
    }

    static func formBody(_ values: [String: String]) -> Data {
        let body = values.map { "\(urlFormEncode($0))=\(urlFormEncode($1))" }
            .sorted()
            .joined(separator: "&")
        return Data(body.utf8)
    }

    static func urlFormEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
