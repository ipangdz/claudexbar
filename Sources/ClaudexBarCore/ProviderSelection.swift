import Foundation

public struct ProviderSelection: Equatable, Sendable {
    public var activeProvider: ProviderID
    public private(set) var enabledProviders: [ProviderID]

    public init(activeProvider: ProviderID, enabledProviders: [ProviderID]) {
        let uniqueEnabled = ProviderID.allCases.filter { enabledProviders.contains($0) }
        self.enabledProviders = uniqueEnabled.isEmpty ? [.codex] : uniqueEnabled
        self.activeProvider = self.enabledProviders.contains(activeProvider) ? activeProvider : self.enabledProviders[0]
    }

    public mutating func toggleEnabled(_ provider: ProviderID) {
        if enabledProviders.contains(provider) {
            guard enabledProviders.count > 1 else { return }
            enabledProviders.removeAll { $0 == provider }
            if activeProvider == provider {
                activeProvider = enabledProviders[0]
            }
            return
        }

        enabledProviders = ProviderID.allCases.filter { enabledProviders.contains($0) || $0 == provider }
    }

    public func nextProvider() -> ProviderID {
        guard enabledProviders.count > 1,
              let index = enabledProviders.firstIndex(of: activeProvider)
        else {
            return activeProvider
        }
        return enabledProviders[(index + 1) % enabledProviders.count]
    }
}
