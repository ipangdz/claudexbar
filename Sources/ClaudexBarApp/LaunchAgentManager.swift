import Foundation

enum LaunchAgentManager {
    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: AppPaths.launchAgent.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private static func install() {
        guard let executable = Bundle.main.executableURL else { return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.ipang.claudexbar</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(executable.path)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\(AppPaths.logs.appendingPathComponent("claudexbar.out.log").path)</string>
          <key>StandardErrorPath</key>
          <string>\(AppPaths.logs.appendingPathComponent("claudexbar.err.log").path)</string>
        </dict>
        </plist>
        """
        AppPaths.ensureDirectories()
        try? FileManager.default.createDirectory(
            at: AppPaths.launchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? plist.write(to: AppPaths.launchAgent, atomically: true, encoding: .utf8)
        runLaunchctl(["bootstrap", "gui/\(getuid())", AppPaths.launchAgent.path])
    }

    private static func uninstall() {
        runLaunchctl(["bootout", "gui/\(getuid())", AppPaths.launchAgent.path])
        try? FileManager.default.removeItem(at: AppPaths.launchAgent)
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }
}
