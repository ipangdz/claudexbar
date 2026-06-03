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

    public init() {}

    mutating func shouldDeliver(provider: ProviderID, kind: UsageWindowKind, resetAt: Date?) -> Bool {
        let cycle = resetAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        let key = "\(provider.rawValue):\(kind.rawValue):\(cycle)"
        guard !delivered.contains(key) else { return false }
        delivered.insert(key)
        return true
    }
}

public struct NotificationEvaluator: Sendable {
    public let threshold: NotificationThreshold

    public init(threshold: NotificationThreshold) {
        self.threshold = threshold
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

        return [
            (.primary, activeSnapshot.primary),
            (.secondary, activeSnapshot.secondary)
        ].compactMap { kind, window in
            guard window.remainingPercent <= remainingLimit,
                  store.shouldDeliver(provider: activeProvider, kind: kind, resetAt: window.resetAt)
            else {
                return nil
            }

            let hint: ProviderHint?
            if inactiveIsFresh,
               let inactiveProvider,
               let inactiveWindow = inactiveSnapshot?.window(kind),
               inactiveWindow.remainingPercent >= window.remainingPercent + 25 {
                hint = ProviderHint(provider: inactiveProvider, remainingPercent: inactiveWindow.remainingPercent)
            } else {
                hint = nil
            }

            return NotificationDecision(
                provider: activeProvider,
                windowKind: kind,
                window: window,
                inactiveProviderHint: hint
            )
        }
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
