import Foundation

public struct CLIUpdateSnapshot: Sendable, Equatable {
    public let installed: [ProviderID: String]
    public let latest: [ProviderID: String]

    public init(installed: [ProviderID: String], latest: [ProviderID: String]) {
        self.installed = installed
        self.latest = latest
    }

    public func hasUpdate(for provider: ProviderID) -> Bool {
        guard let installed = installed[provider], let latest = latest[provider] else {
            return false
        }
        return UpdateChecker.isVersion(latest, newerThan: installed)
    }

    public var hasAnyUpdate: Bool {
        ProviderID.allCases.contains(where: hasUpdate)
    }
}

public enum CLIVersionParser {
    public static func semanticVersion(in text: String) -> String? {
        let pattern = #"(?<![0-9])v?([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    public static func latestVersion(provider: ProviderID, from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch provider {
        case .claude:
            guard let tag = root["tag_name"] as? String else { return nil }
            return semanticVersion(in: tag)
        case .codex:
            guard let version = root["version"] as? String else { return nil }
            return semanticVersion(in: version)
        }
    }
}

public struct CLILatestVersionChecker: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchLatestVersions() async -> [ProviderID: String] {
        await withTaskGroup(of: (ProviderID, String?).self) { group in
            for provider in ProviderID.allCases {
                group.addTask {
                    (provider, await latestVersion(for: provider))
                }
            }

            var versions: [ProviderID: String] = [:]
            for await (provider, version) in group {
                versions[provider] = version
            }
            return versions
        }
    }

    private func latestVersion(for provider: ProviderID) async -> String? {
        let urlString: String
        switch provider {
        case .claude:
            urlString = "https://api.github.com/repos/anthropics/claude-code/releases/latest"
        case .codex:
            urlString = "https://registry.npmjs.org/%40openai%2Fcodex/latest"
        }
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("ClaudexBar", forHTTPHeaderField: "User-Agent")
        if provider == .claude {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            return nil
        }
        return CLIVersionParser.latestVersion(provider: provider, from: data)
    }
}
