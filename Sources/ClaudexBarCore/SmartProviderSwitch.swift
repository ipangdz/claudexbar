import Foundation

public struct SmartProviderSignals: Equatable, Sendable {
    public var foregroundProvider: ProviderID?
    public var usageDeltaProvider: ProviderID?

    public init(foregroundProvider: ProviderID?, usageDeltaProvider: ProviderID?) {
        self.foregroundProvider = foregroundProvider
        self.usageDeltaProvider = usageDeltaProvider
    }
}

public enum SmartProviderTextMatcher {
    public static func provider(in values: [String?]) -> ProviderID? {
        let joined = values.compactMap { $0?.lowercased() }.joined(separator: " ")
        if matchesClaude(joined) { return .claude }
        if matchesCodex(joined) { return .codex }
        return nil
    }

    public static func provider(in values: [String]) -> ProviderID? {
        provider(in: values.map(Optional.some))
    }

    public static func matchesCodex(_ value: String) -> Bool {
        tokens(in: value).contains("codex")
    }

    public static func matchesClaude(_ value: String) -> Bool {
        let tokenSet = tokens(in: value)
        return tokenSet.contains("claude")
            || tokenSet.contains("claudecode")
    }

    private static func tokens(in value: String) -> Set<String> {
        Set(
            value
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
    }
}

/// Tracks which provider is actually consuming usage between refreshes.
/// A provider whose primary-window remaining percentage dropped since its
/// previous snapshot is being used — no matter where (CLI, desktop app, web,
/// remote session, daemon). Remaining going *up* is a window reset, not usage.
public struct UsageDeltaTracker: Sendable {
    private var lastRemaining: [ProviderID: Int] = [:]
    private var deltas: [ProviderID: Int] = [:]

    public init() {}

    public mutating func record(provider: ProviderID, snapshot: UsageSnapshot) {
        let remaining = snapshot.primary.remainingPercent
        if let previous = lastRemaining[provider] {
            deltas[provider] = max(0, previous - remaining)
        }
        lastRemaining[provider] = remaining
    }

    /// The single provider with the largest positive usage delta; nil when no
    /// provider consumed usage or when the largest deltas tie.
    public func dominantProvider() -> ProviderID? {
        let positive = deltas.filter { $0.value > 0 }
        guard let best = positive.values.max() else { return nil }
        let leaders = positive.filter { $0.value == best }
        return leaders.count == 1 ? leaders.first?.key : nil
    }
}

/// Precedence-based auto switch: a manual selection pins the choice for
/// `manualPinDuration`; a foreground match must be stable for
/// `foregroundStableDuration` and beats the usage-delta signal; with no
/// candidate the active provider never changes (no idle fallback).
public struct SmartProviderSwitchEngine: Sendable {
    public private(set) var activeProvider: ProviderID

    private let manualPinDuration: TimeInterval
    private let foregroundStableDuration: TimeInterval

    private var manualPinUntil: Date?
    private var pendingForeground: ProviderID?
    private var pendingForegroundSince: Date?

    public init(
        activeProvider: ProviderID,
        manualPinDuration: TimeInterval = 10 * 60,
        foregroundStableDuration: TimeInterval = 10
    ) {
        self.activeProvider = activeProvider
        self.manualPinDuration = manualPinDuration
        self.foregroundStableDuration = foregroundStableDuration
    }

    public mutating func recordManualSelection(_ provider: ProviderID, now: Date) {
        activeProvider = provider
        manualPinUntil = now.addingTimeInterval(manualPinDuration)
        pendingForeground = nil
        pendingForegroundSince = nil
    }

    public mutating func recordExternalSelection(_ provider: ProviderID) {
        activeProvider = provider
        pendingForeground = nil
        pendingForegroundSince = nil
    }

    public mutating func evaluate(signals: SmartProviderSignals, now: Date) -> ProviderID? {
        trackForeground(signals.foregroundProvider, now: now)

        if let pinnedUntil = manualPinUntil, now < pinnedUntil {
            return nil
        }

        guard let candidate = stableForeground(now: now) ?? signals.usageDeltaProvider,
              candidate != activeProvider
        else {
            return nil
        }

        activeProvider = candidate
        return candidate
    }

    private mutating func trackForeground(_ provider: ProviderID?, now: Date) {
        if provider != pendingForeground {
            pendingForeground = provider
            pendingForegroundSince = provider == nil ? nil : now
        }
    }

    private func stableForeground(now: Date) -> ProviderID? {
        guard let pendingForeground,
              let since = pendingForegroundSince,
              now.timeIntervalSince(since) >= foregroundStableDuration
        else {
            return nil
        }
        return pendingForeground
    }
}
