import Foundation
import ClaudexBarCore

final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var activeProvider: ProviderID {
        get {
            ProviderID(rawValue: defaults.string(forKey: "activeProvider") ?? "") ?? .codex
        }
        set {
            defaults.set(newValue.rawValue, forKey: "activeProvider")
        }
    }

    var enabledProviders: [ProviderID] {
        get {
            guard let rawValues = defaults.array(forKey: "enabledProviders") as? [String] else {
                return ProviderID.allCases
            }
            let providers = rawValues.compactMap(ProviderID.init(rawValue:))
            return providers.isEmpty ? ProviderID.allCases : ProviderID.allCases.filter { providers.contains($0) }
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: "enabledProviders")
        }
    }

    var refreshInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: "refreshInterval")
            return value > 0 ? value : 300
        }
        set {
            defaults.set(newValue, forKey: "refreshInterval")
        }
    }

    var notificationThreshold: NotificationThreshold {
        get {
            NotificationThreshold(rawValue: defaults.integer(forKey: "notificationThreshold")) ?? .twentyPercent
        }
        set {
            defaults.set(newValue.rawValue, forKey: "notificationThreshold")
        }
    }
}
