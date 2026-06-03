import Foundation

enum AppPaths {
    static let applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudexBar", isDirectory: true)

    static let logs: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudexBar", isDirectory: true)

    static let launchAgent: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.ipang.claudexbar.plist")

    static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }
}
