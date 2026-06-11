import Foundation

public struct CodexAccount: Equatable, Hashable, Sendable {
    public let id: String
    public let homeURL: URL
    public let displayName: String
    public let isDefault: Bool

    public init(id: String, homeURL: URL, displayName: String, isDefault: Bool) {
        self.id = id
        self.homeURL = homeURL
        self.displayName = displayName
        self.isDefault = isDefault
    }

    public var authURL: URL {
        homeURL.appendingPathComponent("auth.json")
    }

    public var initials: String? {
        guard !isDefault else { return nil }
        let parts = displayName
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        if parts.count >= 2 {
            let letters = parts
                .prefix(2)
                .compactMap(\.first)
                .map { String($0).uppercased() }
                .joined()
            if !letters.isEmpty { return letters }
        }

        let compact = (parts.first ?? displayName).filter { $0.isLetter || $0.isNumber }
        return compact.isEmpty ? nil : String(compact.prefix(2)).uppercased()
    }
}

public enum CodexAccountSelection {
    public static func enabledAccounts(
        from accounts: [CodexAccount],
        enabledIDs: [String]?,
        isClaudeEnabled: Bool
    ) -> [CodexAccount] {
        guard let enabledIDs else {
            return accounts
        }

        let enabled = accounts.filter { enabledIDs.contains($0.id) }
        if !enabled.isEmpty {
            return enabled
        }

        return []
    }
}

public struct CodexAccountDiscovery {
    private let homeDirectory: URL
    private let t3CacheDirectory: URL
    private let fileManager: FileManager

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        t3CacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/caches"),
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.t3CacheDirectory = t3CacheDirectory
        self.fileManager = fileManager
    }

    public func discover() -> [CodexAccount] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: homeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        return items
            .filter(isCodexHome)
            .sorted(by: sortCodexHomes)
            .compactMap(account)
    }

    private func isCodexHome(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name == ".codex" || name.hasPrefix(".codex_") else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }

    private func sortCodexHomes(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.lastPathComponent == ".codex" { return true }
        if rhs.lastPathComponent == ".codex" { return false }
        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    private func account(for home: URL) -> CodexAccount? {
        let authURL = home.appendingPathComponent("auth.json")
        guard let auth = try? Data(contentsOf: authURL),
              let accountID = Self.accountID(fromAuthData: auth)
        else {
            return nil
        }

        return CodexAccount(
            id: accountID,
            homeURL: home,
            displayName: displayName(for: home),
            isDefault: home.lastPathComponent == ".codex"
        )
    }

    private func displayName(for home: URL) -> String {
        if home.lastPathComponent == ".codex" {
            return "Codex"
        }

        let cacheName = String(home.lastPathComponent.dropFirst()).replacingOccurrences(of: "-", with: "_")
        let cacheURL = t3CacheDirectory.appendingPathComponent("\(cacheName).json")
        if let data = try? Data(contentsOf: cacheURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let displayName = root["displayName"] as? String,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let suffix = home.lastPathComponent
            .replacingOccurrences(of: ".codex_", with: "")
            .replacingOccurrences(of: ".codex-", with: "")
        return suffix
            .split { $0 == "_" || $0 == "-" }
            .map { part in part.prefix(1).uppercased() + part.dropFirst() }
            .joined(separator: " ")
    }

    public static func accountID(fromAuthData data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let id = root["account_id"] as? String, !id.isEmpty {
            return id
        }
        if let tokens = root["tokens"] as? [String: Any],
           let id = tokens["account_id"] as? String,
           !id.isEmpty {
            return id
        }
        return nil
    }
}

public struct CodexAccountActivityDetector {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func recentAccount(in accounts: [CodexAccount], now: Date = Date()) -> CodexAccount? {
        let recentWindow: TimeInterval = 5 * 60
        return accounts
            .compactMap { account -> (CodexAccount, Date)? in
                guard let modified = latestModificationDate(in: account.homeURL),
                      now.timeIntervalSince(modified) <= recentWindow
                else {
                    return nil
                }
                return (account, modified)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func latestModificationDate(in home: URL) -> Date? {
        var latest: Date?
        consider(home.appendingPathComponent("session_index.jsonl"), latest: &latest)

        guard let items = try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return latest
        }

        for item in items {
            let name = item.lastPathComponent
            if name == "shell_snapshots" {
                latestInDirectory(item, maxDepth: 1, latest: &latest)
            }
        }

        return latest
    }

    private func latestInDirectory(_ directory: URL, maxDepth: Int, latest: inout Date?) {
        guard maxDepth >= 0,
              let items = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return
        }

        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                latestInDirectory(item, maxDepth: maxDepth - 1, latest: &latest)
            } else {
                consider(item, latest: &latest)
            }
        }
    }

    private func consider(_ url: URL, latest: inout Date?) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate
        else {
            return
        }
        if latest.map({ modified > $0 }) ?? true {
            latest = modified
        }
    }
}

public enum CodexAccountProcessMatcher {
    public static func account(inProcessLines lines: [String], accounts: [CodexAccount]) -> CodexAccount? {
        var matchedIDs: [String] = []
        for line in lines where line.contains("CODEX_HOME=") {
            for account in accounts where line.contains("CODEX_HOME=\(account.homeURL.path)") {
                if !matchedIDs.contains(account.id) {
                    matchedIDs.append(account.id)
                }
            }
        }

        guard !matchedIDs.isEmpty else { return nil }
        if let nonDefault = accounts.first(where: { !$0.isDefault && matchedIDs.contains($0.id) }) {
            return nonDefault
        }
        return accounts.first { matchedIDs.contains($0.id) }
    }
}
