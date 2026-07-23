import AppKit

if CommandLine.arguments.contains("--update-clis") {
    Task {
        let results = await CLIUpdateManager.shared.updateAll()
        SanitizedLogger.shared.flush()
        exit(results.allSatisfy(\.succeeded) ? 0 : 1)
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
