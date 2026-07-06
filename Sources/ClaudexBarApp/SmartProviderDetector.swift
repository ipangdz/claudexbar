import AppKit
import ClaudexBarCore
import Foundation

/// Detects whether the frontmost app/window is clearly Claude or Codex.
/// Main-thread only; no disk I/O.
@MainActor
final class SmartProviderDetector {
    func foregroundProvider() -> ProviderID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        let foregroundText = [
            app.localizedName,
            app.bundleIdentifier,
            app.executableURL?.lastPathComponent
        ]
        if let provider = SmartProviderTextMatcher.provider(in: foregroundText) {
            return provider
        }

        return SmartProviderTextMatcher.provider(in: frontmostWindowText(for: app.processIdentifier))
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
}
