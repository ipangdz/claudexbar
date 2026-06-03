import AppKit
import ClaudexBarCore
import UserNotifications

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = AppSettings.shared
    private let logger = SanitizedLogger.shared
    private let providers: [ProviderID: any UsageProvider] = [
        .codex: CodexProvider(),
        // Persist rotated tokens after every refresh so ClaudexBar's own
        // credential stays valid without re-login.
        .claude: ClaudeProvider(persistRefreshed: { credentials in
            try? ClaudeCredentialStore().save(credentials)
        })
    ]

    private var snapshots: [ProviderID: UsageSnapshot] = [:]
    private var errors: [ProviderID: UsageError] = [:]
    private var statusOverrides: [ProviderID: String] = [:]
    private var claudeReauthInProgress = false
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var notificationStore = NotificationCycleStore()
    private var providerSelection: ProviderSelection {
        get {
            ProviderSelection(activeProvider: settings.activeProvider, enabledProviders: settings.enabledProviders)
        }
        set {
            settings.activeProvider = newValue.activeProvider
            settings.enabledProviders = newValue.enabledProviders
        }
    }
    private var activeProvider: ProviderID {
        get { providerSelection.activeProvider }
        set {
            var selection = providerSelection
            selection.activeProvider = newValue
            providerSelection = selection
        }
    }

    func start() {
        AppPaths.ensureDirectories()
        requestNotificationAuthorizationIfAvailable()
        configureButton()
        updateImage()
        refreshAll()
        scheduleTimers()
        checkForUpdatesQuietly()
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func scheduleTimers() {
        refreshTimer?.invalidate()
        countdownTimer?.invalidate()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateImage() }
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            showMenu()
        default:
            toggleProvider()
        }
    }

    private func toggleProvider() {
        let selection = providerSelection
        guard selection.enabledProviders.count > 1 else { return }
        activeProvider = selection.nextProvider()
        updateImage()
        refresh(provider: activeProvider)
    }

    @objc private func refreshAll() {
        ProviderID.allCases.forEach(refresh(provider:))
    }

    private func refresh(provider: ProviderID) {
        guard let usageProvider = providers[provider] else { return }
        Task {
            let result = await usageProvider.fetchUsage()
            await MainActor.run {
                switch result {
                case .success(let snapshot):
                    snapshots[provider] = snapshot
                    errors[provider] = nil
                    logger.log(provider: provider, message: "usage ok")
                case .failure(let error):
                    errors[provider] = error
                    logger.log(provider: provider, message: error.sanitizedDescription)
                }
                updateImage()
                evaluateNotifications()
            }
        }
    }

    private func updateImage() {
        guard let button = statusItem.button else { return }
        if let snapshot = snapshots[activeProvider], errors[activeProvider] == nil {
            button.image = StatusPillRenderer.image(provider: activeProvider, snapshot: snapshot)
        } else {
            let status = statusOverrides[activeProvider] ?? errors[activeProvider]?.statusLabel ?? "wait"
            button.image = StatusPillRenderer.image(provider: activeProvider, status: status)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        appendProviderRow(to: menu, provider: .codex)
        appendProviderRow(to: menu, provider: .claude)
        menu.addItem(.separator())

        // "Refresh All" by default; holding Option swaps it for "Open Logs…"
        // (native alternate item), keeping maintenance actions out of the way.
        menu.addItem(NSMenuItem(title: "Refresh All", action: #selector(refreshAll), keyEquivalent: "", target: self))
        let logs = NSMenuItem(title: "Open Logs…", action: #selector(openLogs), keyEquivalent: "", target: self)
        logs.isAlternate = true
        logs.keyEquivalentModifierMask = .option
        menu.addItem(logs)

        menu.addItem(toggleItem(title: "Launch at Login", isOn: LaunchAgentManager.isEnabled(), action: #selector(toggleLaunchAtLogin)))
        menu.addItem(refreshIntervalMenu())
        menu.addItem(notificationMenu())
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "", target: self))
        // Hold Option to reveal a notification self-test in its place.
        let testNotif = NSMenuItem(title: "Send Test Notification", action: #selector(sendTestNotification), keyEquivalent: "", target: self)
        testNotif.isAlternate = true
        testNotif.keyEquivalentModifierMask = .option
        menu.addItem(testNotif)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q", target: self))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Provider row: a custom view that toggles the provider's enabled state
    /// **without closing the menu** (settings-checklist feel). Holding Option
    /// swaps it (native alternate item) for that provider's "Re-auth" action.
    private func appendProviderRow(to menu: NSMenu, provider: ProviderID) {
        let row = NSMenuItem()
        row.view = ProviderToggleView(
            label: provider.displayName,
            hint: providerStatusHint(provider),
            isEnabled: { [weak self] in self?.providerSelection.enabledProviders.contains(provider) ?? false },
            onToggle: { [weak self] in self?.toggleProviderEnabled(provider) }
        )
        menu.addItem(row)

        let reauth = NSMenuItem(title: "Re-auth \(provider.displayName)", action: #selector(reauthProvider(_:)), keyEquivalent: "")
        reauth.target = self
        reauth.representedObject = provider.rawValue
        reauth.isAlternate = true
        reauth.keyEquivalentModifierMask = .option
        menu.addItem(reauth)
    }

    /// Inline status shown after the provider name: remaining percentages when
    /// usage is available, otherwise a status word (`login`/`auth`/`net`/`err`).
    private func providerStatusHint(_ provider: ProviderID) -> String {
        if let override = statusOverrides[provider] { return override }
        if let snapshot = snapshots[provider], errors[provider] == nil {
            return "\(snapshot.primary.remainingPercent)% · \(snapshot.secondary.remainingPercent)%"
        }
        if let error = errors[provider] { return error.statusLabel }
        return "wait"
    }

    private func refreshIntervalMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        [60, 300, 600, 900].forEach { seconds in
            let title: String
            switch seconds {
            case 60: title = "1 minute"
            case 300: title = "5 minutes"
            case 600: title = "10 minutes"
            default: title = "15 minutes"
            }
            let item = NSMenuItem(title: title, action: #selector(selectRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = Int(settings.refreshInterval) == seconds ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func notificationMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Notify When Remaining", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        [
            ("20%", NotificationThreshold.twentyPercent),
            ("10%", NotificationThreshold.tenPercent),
            ("Off", NotificationThreshold.off)
        ].forEach { title, threshold in
            let item = NSMenuItem(title: title, action: #selector(selectNotificationThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = threshold.rawValue
            item.state = settings.notificationThreshold == threshold ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func toggleItem(title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    private func toggleProviderEnabled(_ provider: ProviderID) {
        var selection = providerSelection
        selection.toggleEnabled(provider)
        providerSelection = selection
        updateImage()
        if providerSelection.enabledProviders.contains(provider) {
            refresh(provider: provider)
        }
    }

    @objc private func selectRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        settings.refreshInterval = TimeInterval(seconds)
        scheduleTimers()
    }

    @objc private func selectNotificationThreshold(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let threshold = NotificationThreshold(rawValue: raw)
        else { return }
        settings.notificationThreshold = threshold
    }

    @objc private func reauthProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = ProviderID(rawValue: raw) else { return }
        switch provider {
        case .codex: reauthCodex()
        case .claude: reauthClaude()
        }
    }

    private func reauthCodex() {
        runInTerminal(providers[.codex]?.reauthCommand())
    }

    private func reauthClaude() {
        runClaudeReauth()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAgentManager.setEnabled(!LaunchAgentManager.isEnabled())
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(AppPaths.logs)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func runInTerminal(_ command: ShellCommand?) {
        guard let command else { return }
        let script = """
        tell application "Terminal"
          activate
          do script "\(command.terminalCommand.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    /// Runs Claude's OAuth Authorization-Code + PKCE flow. ClaudexBar opens the
    /// browser to Claude's sign-in page; after the user approves, Claude's
    /// callback page shows a `code#state` string. The user pastes it into a
    /// ClaudexBar dialog, and ClaudexBar exchanges it for an independent
    /// access+refresh credential (full scopes) stored only in the Keychain.
    /// Claude's OAuth client does not accept a localhost redirect, so this
    /// one paste is required; the code and tokens are never logged.
    private func runClaudeReauth() {
        guard !claudeReauthInProgress else { return }

        let flow = ClaudeOAuthFlow()
        NSWorkspace.shared.open(flow.authorizeURL())
        logger.log(provider: .claude, message: "reauth started")

        guard let pasted = promptForClaudeCode() else {
            logger.log(provider: .claude, message: "reauth cancelled")
            return
        }

        claudeReauthInProgress = true
        statusOverrides[.claude] = "login"
        errors[.claude] = nil
        updateImage()

        Task { [weak self] in
            let result = await flow.submitCode(pasted)
            await MainActor.run {
                guard let self else { return }
                self.claudeReauthInProgress = false
                self.statusOverrides[.claude] = nil
                switch result {
                case .success:
                    self.logger.log(provider: .claude, message: "reauth ok")
                    self.refresh(provider: .claude)
                case .failure(let error):
                    self.errors[.claude] = .authExpired
                    let reason = Self.reasonLabel(error)
                    self.logger.log(provider: .claude, message: "reauth failed: \(reason)")
                    self.notifyReauthFailed(provider: .claude, reason: reason)
                    self.updateImage()
                }
            }
        }
    }

    /// Shows a modal dialog for the user to paste the `code#state` shown on
    /// Claude's callback page. Pre-fills from the clipboard when it looks like
    /// a code so the common case is one click.
    private func promptForClaudeCode() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Finish Claude Code sign-in"
        alert.informativeText = "Your browser opened the Claude sign-in page. Approve access, copy the code shown on the page, and paste it here."
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Paste the code"
        if let clip = NSPasteboard.general.string(forType: .string),
           clip.contains("#"), !clip.contains(" "), clip.count < 200 {
            field.stringValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let code = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    private static func reasonLabel(_ error: ClaudeOAuthFlow.FlowError) -> String {
        switch error {
        case .emptyCode: return "empty_code"
        case .stateMismatch: return "state_mismatch"
        case .network: return "network"
        case .exchange(let status): return "exchange_http_\(status)"
        case .parse: return "parse"
        case .keychain: return "keychain"
        }
    }

    private func evaluateNotifications() {
        guard notificationsAvailable else { return }
        let evaluator = NotificationEvaluator(threshold: settings.notificationThreshold)
        let decisions = evaluator.decisions(
            activeProvider: activeProvider,
            snapshots: snapshots,
            store: &notificationStore,
            now: Date()
        )
        decisions.forEach(sendNotification)

        if let error = errors[activeProvider],
           error.statusLabel == "auth" {
            sendAuthNotification(provider: activeProvider)
        }
    }

    private func sendNotification(_ decision: NotificationDecision) {
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        let reset = UsageFormatter.resetLabel(resetAt: decision.window.resetAt, fallback: decision.window.windowLabel)
        let windowName = decision.windowKind == .primary ? "5h" : "weekly"
        var body = "\(decision.provider.displayName) \(windowName): \(decision.window.remainingPercent)% left, resets in \(reset)."
        if let hint = decision.inactiveProviderHint {
            body += " \(hint.provider.displayName): \(hint.remainingPercent)% left."
        }
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func sendAuthNotification(provider: ProviderID) {
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        content.body = "\(provider.displayName) auth expired. Run Re-auth \(provider.displayName)."
        let request = UNNotificationRequest(identifier: "auth-\(provider.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Notify the user that a re-auth attempt they just made did not complete,
    /// including the sanitized reason. `reason` is a short status token (e.g.
    /// `exchange_http_400`) and never contains secrets.
    private func notifyReauthFailed(provider: ProviderID, reason: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        content.body = "\(provider.displayName) re-auth didn’t complete (\(reason)). Try Re-auth \(provider.displayName) again."
        let request = UNNotificationRequest(identifier: "reauth-fail-\(provider.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Updates

    @objc private func checkForUpdates() {
        let version = appVersion
        Task {
            let update = await UpdateChecker().latestRelease(currentVersion: version)
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "ClaudexBar"
                if let update, update.isNewer {
                    alert.informativeText = "A newer version (\(update.latest)) is available — you have \(update.current).\n\nUpdate with:\n  git pull && ./scripts/install.sh"
                    alert.addButton(withTitle: "Open Releases")
                    alert.addButton(withTitle: "Close")
                    if alert.runModal() == .alertFirstButtonReturn, let url = update.releaseURL {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    alert.informativeText = (update == nil)
                        ? "Couldn’t check for updates right now. You have \(version)."
                        : "You’re up to date (\(version))."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    /// Quiet check at launch: notify once if a newer release exists. Silent on
    /// failure or when up to date.
    private func checkForUpdatesQuietly() {
        guard notificationsAvailable else { return }
        let version = appVersion
        Task { [weak self] in
            guard let update = await UpdateChecker().latestRelease(currentVersion: version), update.isNewer else { return }
            await MainActor.run { self?.sendUpdateNotification(update) }
        }
    }

    private func sendUpdateNotification(_ update: UpdateChecker.Update) {
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar update available"
        content.body = "Version \(update.latest) is out (you have \(update.current)). Update with git pull && ./scripts/install.sh."
        let request = UNNotificationRequest(identifier: "update-\(update.latest)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// One-click notification self-test: prompts for permission if undecided,
    /// directs to System Settings if denied, otherwise posts a test banner.
    @objc private func sendTestNotification() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch status {
                case .notDetermined:
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        if granted { DispatchQueue.main.async { self.postTestNotification() } }
                    }
                case .denied:
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Notifications are turned off"
                    alert.informativeText = "Enable them in System Settings → Notifications → ClaudexBar, then try again."
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Close")
                    if alert.runModal() == .alertFirstButtonReturn,
                       let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                default:
                    self.postTestNotification()
                }
            }
        }
    }

    private func postTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        content.body = "Test notification — notifications are working."
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private var notificationsAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func requestNotificationAuthorizationIfAvailable() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
