import Foundation

public struct ClaudeProvider: UsageProvider {
    public let id: ProviderID = .claude
    public let displayName = ProviderID.claude.displayName

    private let credentialReader: any ClaudeCredentialReading
    private let httpClient: any HTTPClient
    private let usageURL: URL
    private let refreshURL: URL
    private let now: @Sendable () -> Date
    private let persistRefreshed: (@Sendable (ClaudeCredentials) -> Void)?

    public init(
        credentialReader: any ClaudeCredentialReading = ClaudeCredentialReader(),
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        usageURL: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        refreshURL: URL = URL(string: "https://platform.claude.com/v1/oauth/token")!,
        now: @escaping @Sendable () -> Date = { Date() },
        persistRefreshed: (@Sendable (ClaudeCredentials) -> Void)? = nil
    ) {
        self.credentialReader = credentialReader
        self.httpClient = httpClient
        self.usageURL = usageURL
        self.refreshURL = refreshURL
        self.now = now
        self.persistRefreshed = persistRefreshed
    }

    public func fetchUsage() async -> Result<UsageSnapshot, UsageError> {
        do {
            let credentials = try credentialReader.readCredentials()
            let accessToken: String
            if Self.isExpired(credentials.expiresAt, now: now()) {
                guard let refreshToken = credentials.refreshToken else {
                    return .failure(.authExpired)
                }
                accessToken = try await refreshAccessToken(refreshToken)
            } else {
                accessToken = credentials.accessToken
            }

            return try await fetchUsage(accessToken: accessToken, refreshToken: credentials.refreshToken)
        } catch let error as UsageError {
            return .failure(error)
        } catch is DecodingError {
            return .failure(.decoding)
        } catch {
            return .failure(.network)
        }
    }

    public func reauthCommand() -> ShellCommand {
        ShellCommand("claude", ["setup-token"])
    }

    public static func parseUsageResponse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        guard let fiveHour = response.fiveHour else {
            throw UsageError.decoding
        }
        let sevenDay = response.sevenDay ?? response.sevenDaySonnet ?? response.sevenDayOpus

        return UsageSnapshot(
            primary: UsageWindow(
                windowLabel: "5h",
                remainingPercent: clampPercent(100 - fiveHour.utilization),
                resetAt: ISO8601DateFormatter.parseClaudexDate(fiveHour.resetsAt)
            ),
            secondary: UsageWindow(
                windowLabel: "7d",
                remainingPercent: sevenDay.map { clampPercent(100 - $0.utilization) } ?? 0,
                resetAt: ISO8601DateFormatter.parseClaudexDate(sevenDay?.resetsAt)
            ),
            fetchedAt: fetchedAt
        )
    }

    static func isExpired(_ expiresAt: Int?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        let nowMs = Int(now.timeIntervalSince1970 * 1_000)
        return expiresAt < nowMs + 60_000
    }

    private func fetchUsage(accessToken: String, refreshToken: String?) async throws -> Result<UsageSnapshot, UsageError> {
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(stripBearerPrefix(accessToken))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let response = try await httpClient.data(for: request)
        switch response.statusCode {
        case 200..<300:
            return .success(try Self.parseUsageResponse(response.data, fetchedAt: now()))
        case 401:
            guard let refreshToken else { return .failure(.authExpired) }
            do {
                let refreshed = try await refreshAccessToken(refreshToken)
                return try await fetchUsage(accessToken: refreshed, refreshToken: nil)
            } catch {
                return .failure(.authExpired)
            }
        case 429:
            return .failure(.rateLimited)
        default:
            return .failure(.server(statusCode: response.statusCode))
        }
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> String {
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": ClaudeOAuthFlow.clientID
        ])
        request.timeoutInterval = 15

        let response = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw UsageError.refreshFailed
        }
        guard let refreshed = Self.parseRefreshResponse(response.data, fallbackRefreshToken: refreshToken, now: now()) else {
            throw UsageError.refreshFailed
        }
        // Persist the rotated credential so the next refresh uses the new
        // refresh token (Claude rotates it on every refresh).
        persistRefreshed?(refreshed)
        return refreshed.accessToken
    }

    public static func parseRefreshResponse(_ data: Data, fallbackRefreshToken: String, now: Date) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = (root["access_token"] as? String).map(stripBearerPrefix),
              !accessToken.isEmpty else {
            return nil
        }
        let rotated = (root["refresh_token"] as? String).flatMap { token -> String? in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var expiresAt: Int?
        if let expiresIn = root["expires_in"] as? Int {
            expiresAt = Int(now.timeIntervalSince1970 * 1_000) + expiresIn * 1_000
        } else if let expiresIn = root["expires_in"] as? Double {
            expiresAt = Int(now.timeIntervalSince1970 * 1_000) + Int(expiresIn * 1_000)
        }
        return ClaudeCredentials(accessToken: accessToken, refreshToken: rotated ?? fallbackRefreshToken, expiresAt: expiresAt)
    }

    private func formBody(_ values: [String: String]) -> Data {
        let body = values.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }
        .sorted()
        .joined(separator: "&")
        return Data(body.utf8)
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDaySonnet: Window?
    let sevenDayOpus: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
    }

    struct Window: Decodable {
        let utilization: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}
