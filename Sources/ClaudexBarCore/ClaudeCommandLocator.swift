import Foundation

public enum ClaudeCommandLocator {
    public static func findClaudeExecutable(fileExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first(where: fileExists)
    }
}
