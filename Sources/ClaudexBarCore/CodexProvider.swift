import Foundation

public struct CodexProvider: UsageProvider {
    public let id: ProviderID = .codex
    public let displayName = ProviderID.codex.displayName

    private let authReader: any CodexAuthReading
    private let httpClient: any HTTPClient
    private let usageURL: URL

    public init(
        authReader: any CodexAuthReading = CodexAuthReader(),
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        usageURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    ) {
        self.authReader = authReader
        self.httpClient = httpClient
        self.usageURL = usageURL
    }

    public func fetchUsage() async -> Result<UsageSnapshot, UsageError> {
        do {
            let token = try authReader.readAccessToken()
            var request = URLRequest(url: usageURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            request.timeoutInterval = 15

            let response = try await httpClient.data(for: request)
            switch response.statusCode {
            case 200..<300:
                return .success(try Self.parseUsageResponse(response.data, fetchedAt: Date()))
            case 401:
                return .failure(.authExpired)
            case 429:
                return .failure(.rateLimited)
            default:
                return .failure(.server(statusCode: response.statusCode))
            }
        } catch let error as UsageError {
            return .failure(error)
        } catch is DecodingError {
            return .failure(.decoding)
        } catch {
            return .failure(.network)
        }
    }

    public func reauthCommand() -> ShellCommand {
        ShellCommand("codex", ["login"])
    }

    public static func parseUsageResponse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        guard let primary = response.rateLimit.primaryWindow,
              let secondary = response.rateLimit.secondaryWindow
        else {
            throw UsageError.decoding
        }

        return UsageSnapshot(
            primary: UsageWindow(
                windowLabel: "5h",
                remainingPercent: clampPercent(100 - primary.usedPercent),
                resetAt: fetchedAt.addingTimeInterval(TimeInterval(primary.resetAfterSeconds))
            ),
            secondary: UsageWindow(
                windowLabel: "1w",
                remainingPercent: clampPercent(100 - secondary.usedPercent),
                resetAt: fetchedAt.addingTimeInterval(TimeInterval(secondary.resetAfterSeconds))
            ),
            fetchedAt: fetchedAt
        )
    }
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: RateLimit

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Int
        let resetAfterSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAfterSeconds = "reset_after_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = clampPercent(try container.decodeLossyDouble(forKey: .usedPercent))
            resetAfterSeconds = try container.decode(Int.self, forKey: .resetAfterSeconds)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyDouble(forKey key: Key) throws -> Double {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decode(String.self, forKey: key), let double = Double(value) {
            return double
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected numeric value")
    }
}
