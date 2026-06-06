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

public struct NotificationCycleStore: Sendable {
    private var delivered: Set<String> = []
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
        delivered.contains(key(provider: provider, kind: kind, resetAt: resetAt))
    }

    mutating func markDelivered(provider: ProviderID, kind: UsageWindowKind, resetAt: Date?) {
        delivered.insert(key(provider: provider, kind: kind, resetAt: resetAt))
    }

    private func key(provider: ProviderID, kind: UsageWindowKind, resetAt: Date?) -> String {
        let cycle = resetAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        return "\(provider.rawValue):\(kind.rawValue):\(cycle)"
    }
}

public struct NotificationEvaluator: Sendable {
    public static let defaultUsageNotificationInterval: TimeInterval = 3 * 60 * 60

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

        let candidates = [
            (.primary, activeSnapshot.primary),
            (.secondary, activeSnapshot.secondary)
        ]
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
}

public extension UsageSnapshot {
    func window(_ kind: UsageWindowKind) -> UsageWindow {
        switch kind {
        case .primary: return primary
        case .secondary: return secondary
        }
    }
}
