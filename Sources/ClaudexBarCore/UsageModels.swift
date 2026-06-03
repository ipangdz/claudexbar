import Foundation

public enum ProviderID: String, CaseIterable, Codable, Hashable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

public struct ShellCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(_ executable: String, _ arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    public var terminalCommand: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9_\-./:]+$"#, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    func fetchUsage() async -> Result<UsageSnapshot, UsageError>
    func reauthCommand() -> ShellCommand
}

public struct UsageSnapshot: Equatable, Sendable {
    public let primary: UsageWindow
    public let secondary: UsageWindow
    public let fetchedAt: Date

    public init(primary: UsageWindow, secondary: UsageWindow, fetchedAt: Date) {
        self.primary = primary
        self.secondary = secondary
        self.fetchedAt = fetchedAt
    }
}

public struct UsageWindow: Equatable, Sendable {
    public let windowLabel: String
    public let remainingPercent: Int
    public let resetAt: Date?

    public init(windowLabel: String, remainingPercent: Int, resetAt: Date?) {
        self.windowLabel = windowLabel
        self.remainingPercent = max(0, min(100, remainingPercent))
        self.resetAt = resetAt
    }
}

public enum UsageError: Error, Equatable, Sendable {
    case missingAuth
    case authExpired
    case network
    case rateLimited
    case server(statusCode: Int)
    case decoding
    case keychain
    case refreshFailed

    public var statusLabel: String {
        switch self {
        case .missingAuth, .authExpired, .refreshFailed:
            return "auth"
        case .network, .rateLimited:
            return "net"
        case .server, .decoding, .keychain:
            return "err"
        }
    }

    /// Transient errors (network blips, rate limits, server hiccups) where a
    /// recently-fetched snapshot is still worth showing rather than blanking
    /// the pill to a status word.
    public var isTransient: Bool {
        switch self {
        case .network, .rateLimited, .server:
            return true
        case .missingAuth, .authExpired, .refreshFailed, .decoding, .keychain:
            return false
        }
    }

    public var sanitizedDescription: String {
        switch self {
        case .missingAuth:
            return "Missing CLI authentication"
        case .authExpired:
            return "CLI authentication expired"
        case .network:
            return "Network request failed"
        case .rateLimited:
            return "Usage endpoint rate limited"
        case .server(let statusCode):
            return "Usage endpoint returned HTTP \(statusCode)"
        case .decoding:
            return "Usage response could not be parsed"
        case .keychain:
            return "Credential lookup failed"
        case .refreshFailed:
            return "Credential refresh failed"
        }
    }
}

public enum UsageWindowKind: String, Hashable, Sendable {
    case primary
    case secondary
}

public struct WindowDisplay: Equatable, Sendable {
    public let label: String
    public let remainingPercent: Int
}

public extension ISO8601DateFormatter {
    static let claudex: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let claudexNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseClaudexDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return claudex.date(from: value) ?? claudexNoFraction.date(from: value)
    }
}

public func clampPercent(_ value: Double) -> Int {
    max(0, min(100, Int(value.rounded())))
}

public func clampPercent(_ value: Int) -> Int {
    max(0, min(100, value))
}
