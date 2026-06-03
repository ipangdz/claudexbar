import Foundation

/// Lightweight update check for a source-built app: asks GitHub for the latest
/// release tag and compares it to the running version. No Sparkle, no extra
/// dependency, no hosted appcast — it only ever points the user at the releases
/// page; updating is `git pull && ./scripts/install.sh`.
public struct UpdateChecker: Sendable {
    /// GitHub `owner/repo`. Update this once the public repo exists.
    public static let repoSlug = "ipangdz/claudexbar"

    public struct Update: Sendable, Equatable {
        public let latest: String
        public let current: String
        public let releaseURL: URL?

        public var isNewer: Bool { UpdateChecker.isVersion(latest, newerThan: current) }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func latestRelease(currentVersion: String) async -> Update? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repoSlug)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudexBar", forHTTPHeaderField: "User-Agent") // GitHub requires a UA
        request.timeoutInterval = 15

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else {
            return nil
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let releaseURL = (root["html_url"] as? String).flatMap(URL.init(string:))
        return Update(latest: latest, current: currentVersion, releaseURL: releaseURL)
    }

    /// Numeric dotted-version comparison (e.g. "0.10.0" > "0.9.0"). Non-numeric
    /// components are treated as 0.
    public static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
