import AppKit
import ClaudexBarCore
import Foundation

final class SmartProviderDetector: @unchecked Sendable {
    private let homeDirectory: URL
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func detect() -> SmartProviderSignals {
        SmartProviderSignals(
            foregroundProvider: foregroundProvider(),
            recentActivityProvider: recentActivityProvider(),
            runningProviders: []
        )
    }

    func foregroundProvider() -> ProviderID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        let foregroundText = [
            app.localizedName,
            app.bundleIdentifier,
            app.executableURL?.lastPathComponent
        ]
        if let provider = provider(in: foregroundText) {
            return provider
        }

        return provider(in: frontmostWindowText(for: app.processIdentifier))
    }

    private func frontmostWindowText(for processIdentifier: pid_t) -> [String?] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        guard let window = windowInfo.first(where: { item in
            (item[kCGWindowOwnerPID as String] as? pid_t) == processIdentifier
                && (item[kCGWindowLayer as String] as? Int) == 0
        }) else {
            return []
        }

        return [
            window[kCGWindowOwnerName as String] as? String,
            window[kCGWindowName as String] as? String
        ]
    }

    func recentActivityProvider(now: Date = Date()) -> ProviderID? {
        let codex = latestModificationDate(
            under: homeDirectory.appendingPathComponent(".codex"),
            maxDepth: 2,
            matching: { url in
                let name = url.lastPathComponent
                return name == "session_index.jsonl"
                    || name.hasPrefix("logs_")
                    || url.path.contains("/shell_snapshots/")
            }
        )
        let claude = latestModificationDate(
            under: homeDirectory.appendingPathComponent(".claude"),
            maxDepth: 3,
            matching: { url in
                let ext = url.pathExtension.lowercased()
                return ext == "jsonl" || ext == "json" || url.lastPathComponent == ".highwatermark"
            }
        )

        let recentWindow: TimeInterval = 5 * 60
        let codexRecent = codex.map { now.timeIntervalSince($0) <= recentWindow } ?? false
        let claudeRecent = claude.map { now.timeIntervalSince($0) <= recentWindow } ?? false

        switch (codexRecent, claudeRecent) {
        case (true, false):
            return .codex
        case (false, true):
            return .claude
        case (true, true):
            guard let codex, let claude else { return nil }
            let gap = abs(codex.timeIntervalSince(claude))
            guard gap >= 10 else { return nil }
            return codex > claude ? .codex : .claude
        case (false, false):
            return nil
        }
    }

    private func latestModificationDate(
        under root: URL,
        maxDepth: Int,
        matching predicate: (URL) -> Bool
    ) -> Date? {
        guard fileManager.fileExists(atPath: root.path) else { return nil }

        var latest: Date?
        scanDirectory(root, currentDepth: 0, maxDepth: maxDepth, latest: &latest, matching: predicate)
        return latest
    }

    private func scanDirectory(
        _ directory: URL,
        currentDepth: Int,
        maxDepth: Int,
        latest: inout Date?,
        matching predicate: (URL) -> Bool
    ) {
        guard currentDepth <= maxDepth,
              let items = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return
        }

        for item in items {
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true {
                scanDirectory(item, currentDepth: currentDepth + 1, maxDepth: maxDepth, latest: &latest, matching: predicate)
                continue
            }

            guard predicate(item), let modified = values?.contentModificationDate else { continue }
            if latest.map({ modified > $0 }) ?? true {
                latest = modified
            }
        }
    }

    private func provider(in values: [String?]) -> ProviderID? {
        SmartProviderTextMatcher.provider(in: values)
    }
}
