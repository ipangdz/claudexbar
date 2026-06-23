import Foundation

public struct CodexAccount: Equatable, Hashable, Sendable {
    public let id: String
    public let homeURL: URL
    public let displayName: String

    public init(id: String = "codex", homeURL: URL, displayName: String = "Codex") {
        self.id = id
        self.homeURL = homeURL
        self.displayName = displayName
    }

    public var authURL: URL {
        homeURL.appendingPathComponent("auth.json")
    }
}

public struct CodexAccountDiscovery {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func defaultAccount() -> CodexAccount {
        CodexAccount(homeURL: homeDirectory.appendingPathComponent(".codex"))
    }
}
