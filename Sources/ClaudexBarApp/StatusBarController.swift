import AppKit
import ClaudexBarCore
import UserNotifications

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = AppSettings.shared
    private let logger = SanitizedLogger.shared
    private let smartSwitchDetector = SmartProviderDetector()
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
    private var codexReauthProcess: Process?
    private var claudeReauthInProgress = false
    private var appearanceObservation: NSKeyValueObservation?
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var smartSwitchTimer: Timer?
    private var smartSwitchEngine: SmartProviderSwitchEngine?
    private var smartSwitchDetectionInProgress = false
    private var refreshesInFlight: Set<ProviderID> = []
    private var presentedMenu: NSMenu?
    private var notificationStore = NotificationCycleStore()
    private var lastAuthNotificationAt: [ProviderID: Date] = [:]
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
        settings.removeLegacyCodexAccountSettings()
        requestNotificationAuthorizationIfAvailable()
        smartSwitchEngine = SmartProviderSwitchEngine(activeProvider: settings.activeProvider)
        configureButton()
        updateImage()
        refreshAll()
        scheduleTimers()
        checkForUpdatesQuietly()
    }

    private var activeEnabledProvider: ProviderID? {
        providerSelection.enabledProviders.contains(activeProvider) ? activeProvider : nil
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
        // No pressed-state highlight behind the custom pill.
        (button.cell as? NSButtonCell)?.highlightsBy = []

        // Re-render the pill when the system appearance (light/dark) changes.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.updateImage() }
        }
    }

    private func scheduleTimers() {
        refreshTimer?.invalidate()
        countdownTimer?.invalidate()
        smartSwitchTimer?.invalidate()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshAll() }
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.updateImage() }
        }
        if settings.smartSwitchEnabled {
            smartSwitchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.beginSmartSwitchEvaluation() }
            }
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
        let enabled = providerSelection.enabledProviders
        guard enabled.count > 1 else { return }
        let index = enabled.firstIndex(of: activeProvider) ?? -1
        let next = enabled[(index + 1) % enabled.count]
        activeProvider = next
        smartSwitchEngine?.recordManualSelection(next, now: Date())
        updateImage()
        refreshActiveProvider()
    }

    private func beginSmartSwitchEvaluation() {
        guard settings.smartSwitchEnabled else { return }
        guard providerSelection.enabledProviders.count > 1 else { return }
        guard !smartSwitchDetectionInProgress else { return }
        smartSwitchDetectionInProgress = true

        let foregroundProvider = smartSwitchDetector.foregroundProvider()
        let detector = smartSwitchDetector
        DispatchQueue.global(qos: .utility).async { [weak self, foregroundProvider, detector] in
            let recentActivityProvider = detector.recentActivityProvider()
            DispatchQueue.main.async {
                self?.finishSmartSwitchEvaluation(
                    foregroundProvider: foregroundProvider,
                    recentActivityProvider: recentActivityProvider
                )
            }
        }
    }

    private func finishSmartSwitchEvaluation(
        foregroundProvider: ProviderID?,
        recentActivityProvider: ProviderID?
    ) {
        smartSwitchDetectionInProgress = false

        guard settings.smartSwitchEnabled else { return }
        let selection = providerSelection
        guard selection.enabledProviders.count > 1 else { return }

        if smartSwitchEngine == nil {
            smartSwitchEngine = SmartProviderSwitchEngine(activeProvider: activeProvider)
        }
        if smartSwitchEngine?.activeProvider != activeProvider {
            smartSwitchEngine?.recordExternalSelection(activeProvider)
        }

        let enabled = Set(selection.enabledProviders)
        let signals = SmartProviderSignals(
            foregroundProvider: foregroundProvider.flatMap { enabled.contains($0) ? $0 : nil },
            recentActivityProvider: recentActivityProvider.flatMap { enabled.contains($0) ? $0 : nil },
            runningProviders: []
        )

        guard let provider = smartSwitchEngine?.evaluate(signals: signals, now: Date()) else { return }
        activeProvider = provider
        updateImage()
        refreshActiveProvider(notify: false)
    }

    private func refreshAll() {
        let enabled = providerSelection.enabledProviders
        guard !enabled.isEmpty else {
            updateImage()
            return
        }
        enabled.forEach { refresh(provider: $0) }
    }

    /// Manual "Refresh All": pulse the pill so the user gets clear feedback that
    /// a refresh was triggered (the data itself may be unchanged), then refetch.
    @objc private func refreshAllManually() {
        pulseRefreshIndicator()
        refreshAll()
    }

    private func pulseRefreshIndicator() {
        guard let button = statusItem.button else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            button.animator().alphaValue = 0.3
        }, completionHandler: { [weak button] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                button?.animator().alphaValue = 1.0
            }
        })
    }

    private func refresh(provider: ProviderID, notify: Bool = true) {
        guard let usageProvider = providers[provider] else { return }
        guard !refreshesInFlight.contains(provider) else { return }
        refreshesInFlight.insert(provider)
        Task {
            let result = await usageProvider.fetchUsage()
            await MainActor.run {
                refreshesInFlight.remove(provider)
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
                if notify {
                    evaluateNotifications()
                }
            }
        }
    }

    private func refreshActiveProvider(notify: Bool = true) {
        guard let provider = activeEnabledProvider else {
            updateImage()
            return
        }
        refresh(provider: provider, notify: notify)
    }

    private func updateImage() {
        guard let button = statusItem.button else { return }
        guard !providerSelection.enabledProviders.isEmpty else {
            button.image = StatusPillRenderer.pausedImage()
            return
        }

        // A status override (e.g. "login" during re-auth) always wins.
        if let override = statusOverrides[activeProvider] {
            button.image = StatusPillRenderer.image(provider: activeProvider, status: override)
            return
        }

        // Keep showing the last good usage on transient errors (rate limit /
        // network blip); only fall back to a status word when there is no
        // snapshot yet, or the error needs the user's attention (auth, parse).
        let error = errors[activeProvider]
        if let snapshot = snapshots[activeProvider], error == nil || error!.isTransient {
            button.image = StatusPillRenderer.image(provider: activeProvider, snapshot: snapshot)
            return
        }

        button.image = StatusPillRenderer.image(provider: activeProvider, status: error?.statusLabel ?? "wait")
    }

    private func showMenu() {
        let menu = NSMenu()
        appendProviderRow(to: menu, provider: .codex)
        appendProviderRow(to: menu, provider: .claude)
        menu.addItem(.separator())

        // "Refresh All" by default; holding Option swaps it for "Open Logs…"
        // (native alternate item), keeping maintenance actions out of the way.
        menu.addItem(NSMenuItem(title: "Refresh All", action: #selector(refreshAllManually), keyEquivalent: "", target: self))
        let logs = NSMenuItem(title: "Open Logs…", action: #selector(openLogs), keyEquivalent: "", target: self)
        logs.isAlternate = true
        logs.keyEquivalentModifierMask = .option
        menu.addItem(logs)

        menu.addItem(toggleItem(title: "Smart Auto Switch", isOn: settings.smartSwitchEnabled, action: #selector(toggleSmartSwitch)))
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

        // Attach the menu to the status item and click it: macOS positions it
        // correctly under the pill (it also draws its standard selection
        // highlight, which is the expected menu-bar behavior).
        statusItem.menu = menu
        presentedMenu = menu
        statusItem.button?.performClick(nil)
        presentedMenu = nil
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
        let wasPaused = activeEnabledProvider == nil
        var selection = providerSelection
        selection.toggleEnabled(provider)
        providerSelection = selection
        if wasPaused, providerSelection.enabledProviders.contains(provider) {
            activeProvider = provider
        }
        if activeEnabledProvider != nil {
            smartSwitchEngine?.recordExternalSelection(activeProvider)
        }
        updateImage()
        scheduleTimers()
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
        runCodexReauth()
    }

    private func runCodexReauth() {
        guard codexReauthProcess == nil else { return }
        guard let executableURL = codexExecutableURL() else {
            errors[.codex] = .authExpired
            notifyReauthFailed(provider: .codex, reason: "codex_not_found")
            updateImage()
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["login"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CODEX_HOME": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path]
        ) { _, new in new }
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let authURLOpener = CodexAuthURLOpener()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in authURLOpener.handle(handle.availableData) }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in authURLOpener.handle(handle.availableData) }

        codexReauthProcess = process
        statusOverrides[.codex] = "login"
        errors[.codex] = nil
        updateImage()

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                self.codexReauthProcess = nil
                self.statusOverrides[.codex] = nil
                if process.terminationStatus == 0 {
                    self.refresh(provider: .codex)
                } else {
                    self.errors[.codex] = .authExpired
                    self.notifyReauthFailed(provider: .codex, reason: "login_exit_\(process.terminationStatus)")
                    self.updateImage()
                }
            }
        }

        do {
            try process.run()
        } catch {
            codexReauthProcess = nil
            statusOverrides[.codex] = nil
            errors[.codex] = .authExpired
            notifyReauthFailed(provider: .codex, reason: "login_start_failed")
            updateImage()
        }
    }

    private func codexExecutableURL() -> URL? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Users/ipang/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func reauthClaude() {
        runClaudeReauth()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAgentManager.setEnabled(!LaunchAgentManager.isEnabled())
    }

    @objc private func toggleSmartSwitch() {
        settings.smartSwitchEnabled.toggle()
        if settings.smartSwitchEnabled {
            smartSwitchEngine = SmartProviderSwitchEngine(activeProvider: activeProvider)
            beginSmartSwitchEvaluation()
        }
        scheduleTimers()
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
            guard let self else { return }
            await MainActor.run {
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
        guard activeEnabledProvider != nil else { return }
        let evaluator = NotificationEvaluator(threshold: settings.notificationThreshold)
        let decisions = evaluator.decisions(
            activeProvider: activeProvider,
            snapshots: snapshots,
            store: &notificationStore,
            now: Date()
        )
        decisions.forEach(sendNotification)
        let recoveryDecisions = evaluator.recoveryDecisions(
            sources: recoveryNotificationSources(),
            store: &notificationStore,
            now: Date()
        )
        recoveryDecisions.forEach(sendRecoveryNotification)

        if let error = errors[activeProvider], error.statusLabel == "auth" {
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

    private func sendRecoveryNotification(_ decision: RecoveryNotificationDecision) {
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        let windowName = decision.windowKind == .primary ? "5h" : "weekly"
        content.body = "\(decision.provider.displayName) \(windowName) limit is back. You have \(decision.window.remainingPercent)% available."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        logger.log(provider: decision.provider, message: "recovery notification sent \(windowName) \(decision.window.remainingPercent)%")
    }

    private func recoveryNotificationSources() -> [NotificationSourceSnapshot] {
        providerSelection.enabledProviders.compactMap { provider in
            snapshots[provider].map { NotificationSourceSnapshot(provider: provider, snapshot: $0) }
        }
    }

    private func sendAuthNotification(provider: ProviderID) {
        let now = Date()
        if let last = lastAuthNotificationAt[provider],
           now.timeIntervalSince(last) < NotificationEvaluator.defaultUsageNotificationInterval {
            return
        }
        lastAuthNotificationAt[provider] = now

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
            guard let self else { return }
            await MainActor.run { self.sendUpdateNotification(update) }
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

private final class CodexAuthURLOpener: @unchecked Sendable {
    private let lock = NSLock()
    private var didOpen = false

    func handle(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8),
              let url = Self.authURL(in: text)
        else {
            return
        }

        lock.lock()
        if didOpen {
            lock.unlock()
            return
        }
        didOpen = true
        lock.unlock()

        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    private static func authURL(in text: String) -> URL? {
        let pattern = #"https://auth\.openai\.com/oauth/authorize\?[^\s]+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
