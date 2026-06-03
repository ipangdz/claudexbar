import Foundation
import ClaudexBarCore

final class SanitizedLogger {
    static let shared = SanitizedLogger()

    private let logURL = AppPaths.logs.appendingPathComponent("claudexbar.log")
    private let queue = DispatchQueue(label: "ClaudexBar.SanitizedLogger")

    func log(provider: ProviderID, message: String) {
        // Defense-in-depth: scrub any secret-shaped substring before it is
        // ever written, even though callers only pass static status strings.
        let safeMessage = SecretScanner.redact(message)
        queue.async {
            AppPaths.ensureDirectories()
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(provider.rawValue) \(safeMessage)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: self.logURL.path),
               let handle = try? FileHandle(forWritingTo: self.logURL) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: self.logURL, options: .atomic)
            }
        }
    }
}
