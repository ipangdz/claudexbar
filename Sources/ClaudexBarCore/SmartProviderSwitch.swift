import Foundation

public struct SmartProviderSignals: Equatable, Sendable {
    public var foregroundProvider: ProviderID?
    public var recentActivityProvider: ProviderID?
    public var runningProviders: Set<ProviderID>

    public init(
        foregroundProvider: ProviderID?,
        recentActivityProvider: ProviderID?,
        runningProviders: Set<ProviderID>
    ) {
        self.foregroundProvider = foregroundProvider
        self.recentActivityProvider = recentActivityProvider
        self.runningProviders = runningProviders
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

public struct SmartProviderSwitchEngine: Sendable {
    public private(set) var activeProvider: ProviderID

    private let minimumStableDuration: TimeInterval
    private let manualOverrideDuration: TimeInterval
    private let scoreAdvantageThreshold: Int
    private let switchCooldown: TimeInterval

    private var pendingCandidate: ProviderID?
    private var pendingCandidateSince: Date?
    private var manualOverrideUntil: Date?
    private var lastSwitchAt: Date?

    public init(
        activeProvider: ProviderID,
        minimumStableDuration: TimeInterval = 25,
        manualOverrideDuration: TimeInterval = 10 * 60,
        scoreAdvantageThreshold: Int = 30,
        switchCooldown: TimeInterval = 2 * 60
    ) {
        self.activeProvider = activeProvider
        self.minimumStableDuration = minimumStableDuration
        self.manualOverrideDuration = manualOverrideDuration
        self.scoreAdvantageThreshold = scoreAdvantageThreshold
        self.switchCooldown = switchCooldown
    }

    public mutating func recordManualSelection(_ provider: ProviderID, now: Date) {
        activeProvider = provider
        manualOverrideUntil = now.addingTimeInterval(manualOverrideDuration)
        lastSwitchAt = now
        pendingCandidate = nil
        pendingCandidateSince = nil
    }

    public mutating func recordExternalSelection(_ provider: ProviderID) {
        activeProvider = provider
        pendingCandidate = nil
        pendingCandidateSince = nil
    }

    public mutating func evaluate(signals: SmartProviderSignals, now: Date) -> ProviderID? {
        guard let candidate = strongestCandidate(from: signals),
              candidate != activeProvider
        else {
            pendingCandidate = nil
            pendingCandidateSince = nil
            return nil
        }

        if pendingCandidate != candidate {
            pendingCandidate = candidate
            pendingCandidateSince = now
        }

        let candidateSince = pendingCandidateSince ?? now
        let stableLongEnough = now.timeIntervalSince(candidateSince) >= minimumStableDuration
        let manualOverrideActive = manualOverrideUntil.map { now < $0 } ?? false
        let cooldownElapsed = lastSwitchAt.map { now.timeIntervalSince($0) >= switchCooldown } ?? true

        guard stableLongEnough, !manualOverrideActive, cooldownElapsed else {
            return nil
        }

        activeProvider = candidate
        lastSwitchAt = now
        pendingCandidate = nil
        pendingCandidateSince = nil
        return candidate
    }

    private func strongestCandidate(from signals: SmartProviderSignals) -> ProviderID? {
        let scored = ProviderID.allCases.map { provider in
            (provider, score(provider: provider, signals: signals))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            return nil
        }

        let runnerUp = scored
            .filter { item in item.0 != best.0 }
            .map(\.1)
            .max() ?? 0

        return best.1 - runnerUp >= scoreAdvantageThreshold ? best.0 : nil
    }

    private func score(provider: ProviderID, signals: SmartProviderSignals) -> Int {
        var value = 0
        if signals.foregroundProvider == provider { value += 100 }
        if signals.recentActivityProvider == provider { value += 50 }
        if signals.runningProviders.contains(provider) { value += 10 }
        return value
    }
}
