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
        let primary = response.rateLimit.primaryWindow
        let secondary = response.rateLimit.secondaryWindow
        let windows = [primary, secondary].compactMap { $0 }

        var fiveHour: CodexUsageResponse.Window?
        var weekly: CodexUsageResponse.Window?
        for window in windows {
            switch window.limitWindowSeconds {
            case 18_000:
                fiveHour = window
            case 604_800:
                weekly = window
            default:
                break
            }
        }

        // Older valid responses omitted duration metadata and used stable
        // primary/secondary positions. Keep that shape backwards compatible.
        if windows.allSatisfy({ $0.limitWindowSeconds == nil }),
           let primary,
           let secondary {
            fiveHour = primary
            weekly = secondary
        }

        guard fiveHour != nil || weekly != nil else {
            throw UsageError.decoding
        }

        func usageWindow(_ window: CodexUsageResponse.Window?, label: String) -> UsageWindow? {
            window.map {
                UsageWindow(
                    windowLabel: label,
                    remainingPercent: clampPercent(100 - $0.usedPercent),
                    resetAt: fetchedAt.addingTimeInterval(TimeInterval($0.resetAfterSeconds))
                )
            }
        }

        return UsageSnapshot(
            primary: usageWindow(fiveHour, label: "5h"),
            secondary: usageWindow(weekly, label: "1w"),
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
        let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAfterSeconds = "reset_after_seconds"
            case limitWindowSeconds = "limit_window_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = clampPercent(try container.decodeLossyDouble(forKey: .usedPercent))
            resetAfterSeconds = try container.decode(Int.self, forKey: .resetAfterSeconds)
            limitWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)
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
