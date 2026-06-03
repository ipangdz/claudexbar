import Foundation

/// Detects and redacts secret-shaped strings so they never reach logs or any
/// other persisted/displayed surface. This is defense-in-depth: callers should
/// already avoid passing secrets, but every log line is routed through `redact`
/// so an accidental leak is scrubbed before it is written.
public enum SecretScanner {
    /// Patterns for credentials we never want to persist or display.
    private static let patterns: [String] = [
        #"sk-ant-[A-Za-z0-9._-]{8,}"#,   // Claude OAuth / API tokens (e.g. sk-ant-oat01-...)
        #"eyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9._-]{16,}"#, // JWT-shaped tokens
        #"ey[A-Za-z0-9]{6,}#[A-Za-z0-9._-]{16,}"#       // setup-token `code#state` paste strings
    ]

    public static func containsSecret(_ text: String) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Returns `text` with every secret-shaped substring replaced by `[REDACTED]`.
    public static func redact(_ text: String) -> String {
        var output = text
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "[REDACTED]",
                options: .regularExpression
            )
        }
        return output
    }
}
