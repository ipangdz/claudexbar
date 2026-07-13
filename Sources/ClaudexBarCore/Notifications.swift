import Foundation

public enum NotificationThreshold: Int, Codable, CaseIterable, Sendable {
    case twentyPercent = 20
    case tenPercent = 10
    case off = -1

    public var remainingLimit: Int? {
        self == .off ? nil : rawValue
    }
}

public struct ProviderHint: Equatable, Sendable {
    public let provider: ProviderID
    public let remainingPercent: Int
}

public struct NotificationDecision: Equatable, Sendable {
    public let provider: ProviderID
    public let windowKind: UsageWindowKind
    public let window: UsageWindow
    public let inactiveProviderHint: ProviderHint?
}

public struct RecoveryNotificationDecision: Equatable, Sendable {
    public let provider: ProviderID
    public let windowKind: UsageWindowKind
    public let window: UsageWindow
}

public struct NotificationSourceSnapshot: Equatable, Sendable {
    public let provider: ProviderID
    public let snapshot: UsageSnapshot

    public init(provider: ProviderID, snapshot: UsageSnapshot) {
        self.provider = provider
        self.snapshot = snapshot
    }
}

public struct NotificationCycleStore: Sendable {
    private var delivered: Set<String> = []
    private var depleted: Set<String> = []
    private var recoveryDelivered: Set<String> = []
    private var lastUsageNotificationAt: Date?

    public init() {}

    mutating func shouldDeliver(provider: ProviderID, kind: UsageWindowKind, resetAt: Date?) -> Bool {
        guard !hasDelivered(provider: provider, kind: kind, resetAt: resetAt) else { return false }
        markDelivered(provider: provider, kind: kind, resetAt: resetAt)
        return true
    }

    func canDeliverUsage(now: Date, minimumInterval: TimeInterval) -> Bool {
        lastUsageNotificationAt.map { now.timeIntervalSince($0) >= minimumInterval } ?? true
    }

    mutating func recordUsageDelivered(now: Date) {
        lastUsageNotificationAt = now
    }

    func hasDelivered(provider: ProviderID, kind: UsageWindowKind, resetAt: Date?) -> Bool {
        delivered.contains(cycleKey(provider: provider, kind: kind, resetAt: resetAt))
    }

    mutating func markDelivered(provider: ProviderID, kind: UsageWindowKind, resetAt: Date?) {
        delivered.insert(cycleKey(provider: provider, kind: kind, resetAt: resetAt))
    }

    mutating func markDepleted(provider: ProviderID, kind: UsageWindowKind) {
        depleted.insert(identityKey(provider: provider, kind: kind))
    }

    mutating func clearDepleted(provider: ProviderID, kind: UsageWindowKind) {
        depleted.remove(identityKey(provider: provider, kind: kind))
    }

    func hasDepleted(provider: ProviderID, kind: UsageWindowKind) -> Bool {
        depleted.contains(identityKey(provider: provider, kind: kind))
    }

    func hasDeliveredRecovery(provider: ProviderID, kind: UsageWindowKind, resetAt: Date?) -> Bool {
        recoveryDelivered.contains(cycleKey(provider: provider, kind: kind, resetAt: resetAt))
    }

    mutating func markRecoveryDelivered(provider: ProviderID, kind: UsageWindowKind, resetAt: Date?) {
        recoveryDelivered.insert(cycleKey(provider: provider, kind: kind, resetAt: resetAt))
    }

    private func identityKey(provider: ProviderID, kind: UsageWindowKind) -> String {
        "\(provider.rawValue):\(kind.rawValue)"
    }

    private func cycleKey(provider: ProviderID, kind: UsageWindowKind, resetAt: Date?) -> String {
        let cycle = resetAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        return "\(identityKey(provider: provider, kind: kind)):\(cycle)"
    }
}

public struct NotificationEvaluator: Sendable {
    public static let defaultUsageNotificationInterval: TimeInterval = 3 * 60 * 60
    public static let depletedRecoveryLimit = 5
    public static let restoredRecoveryLimit = 95

    public let threshold: NotificationThreshold
    public let minimumUsageNotificationInterval: TimeInterval

    public init(
        threshold: NotificationThreshold,
        minimumUsageNotificationInterval: TimeInterval = Self.defaultUsageNotificationInterval
    ) {
        self.threshold = threshold
        self.minimumUsageNotificationInterval = minimumUsageNotificationInterval
    }

    public func decisions(
        activeProvider: ProviderID,
        snapshots: [ProviderID: UsageSnapshot],
        store: inout NotificationCycleStore,
        now: Date
    ) -> [NotificationDecision] {
        guard let remainingLimit = threshold.remainingLimit,
              let activeSnapshot = snapshots[activeProvider]
        else {
            return []
        }

        let inactiveProvider = ProviderID.allCases.first { $0 != activeProvider }
        let inactiveSnapshot = inactiveProvider.flatMap { snapshots[$0] }
        let inactiveIsFresh = inactiveSnapshot.map { now.timeIntervalSince($0.fetchedAt) <= 15 * 60 } ?? false

        guard store.canDeliverUsage(now: now, minimumInterval: minimumUsageNotificationInterval) else {
            return []
        }

        let candidates: [(UsageWindowKind, UsageWindow)] = [
            (.primary, activeSnapshot.primary),
            (.secondary, activeSnapshot.secondary)
        ]
            .compactMap { kind, window in
                window.map { (kind, $0) }
            }
            .filter { kind, window in
                window.remainingPercent <= remainingLimit
                    && !store.hasDelivered(provider: activeProvider, kind: kind, resetAt: window.resetAt)
            }
            .sorted { left, right in
                if left.1.remainingPercent == right.1.remainingPercent {
                    return left.0 == .primary
                }
                return left.1.remainingPercent < right.1.remainingPercent
            }

        guard let (kind, window) = candidates.first else {
            return []
        }

        store.markDelivered(provider: activeProvider, kind: kind, resetAt: window.resetAt)
        store.recordUsageDelivered(now: now)

        let hint: ProviderHint?
        if inactiveIsFresh,
           let inactiveProvider,
           let inactiveWindow = inactiveSnapshot?.window(kind),
           inactiveWindow.remainingPercent >= window.remainingPercent + 25 {
            hint = ProviderHint(provider: inactiveProvider, remainingPercent: inactiveWindow.remainingPercent)
        } else {
            hint = nil
        }

        return [
            NotificationDecision(
                provider: activeProvider,
                windowKind: kind,
                window: window,
                inactiveProviderHint: hint
            )
        ]
    }

    public func recoveryDecisions(
        activeProvider: ProviderID,
        snapshots: [ProviderID: UsageSnapshot],
        store: inout NotificationCycleStore,
        now: Date
    ) -> [RecoveryNotificationDecision] {
        guard threshold.remainingLimit != nil,
              let activeSnapshot = snapshots[activeProvider]
        else {
            return []
        }

        return recoveryDecisions(
            sources: [NotificationSourceSnapshot(provider: activeProvider, snapshot: activeSnapshot)],
            store: &store,
            now: now
        )
    }

    public func recoveryDecisions(
        sources: [NotificationSourceSnapshot],
        store: inout NotificationCycleStore,
        now _: Date
    ) -> [RecoveryNotificationDecision] {
        guard threshold.remainingLimit != nil else {
            return []
        }

        return sources.flatMap { source in
            recoveryDecisions(source: source, store: &store)
        }
    }

    private func recoveryDecisions(
        source: NotificationSourceSnapshot,
        store: inout NotificationCycleStore
    ) -> [RecoveryNotificationDecision] {
        let windows: [(UsageWindowKind, UsageWindow?)] = [
            (.primary, source.snapshot.primary),
            (.secondary, source.snapshot.secondary)
        ]
        return windows.compactMap { kind, optionalWindow in
            guard let window = optionalWindow else { return nil }
            if window.remainingPercent <= Self.depletedRecoveryLimit {
                store.markDepleted(provider: source.provider, kind: kind)
                return nil
            }

            guard window.remainingPercent >= Self.restoredRecoveryLimit,
                  store.hasDepleted(provider: source.provider, kind: kind),
                  !store.hasDeliveredRecovery(provider: source.provider, kind: kind, resetAt: window.resetAt)
            else {
                return nil
            }

            store.markRecoveryDelivered(provider: source.provider, kind: kind, resetAt: window.resetAt)
            store.clearDepleted(provider: source.provider, kind: kind)
            return RecoveryNotificationDecision(provider: source.provider, windowKind: kind, window: window)
        }
    }
}

public extension UsageSnapshot {
    func window(_ kind: UsageWindowKind) -> UsageWindow? {
        switch kind {
        case .primary: return primary
        case .secondary: return secondary
        }
    }
}
