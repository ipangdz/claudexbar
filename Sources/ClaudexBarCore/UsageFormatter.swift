import Foundation

public enum UsageFormatter {
    public static func resetLabel(resetAt: Date?, now: Date = Date(), fallback: String = "") -> String {
        guard let resetAt else { return fallback }
        let seconds = max(0, Int(resetAt.timeIntervalSince(now)))
        let minutes = seconds / 60

        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }

        return "\(hours / 24)d"
    }

    public static func display(for window: UsageWindow, now: Date = Date()) -> WindowDisplay {
        if window.remainingPercent >= 99 {
            return WindowDisplay(label: window.windowLabel, remainingPercent: 100)
        }

        let label = resetLabel(resetAt: window.resetAt, now: now, fallback: window.windowLabel)
        return WindowDisplay(label: label, remainingPercent: window.remainingPercent)
    }
}
