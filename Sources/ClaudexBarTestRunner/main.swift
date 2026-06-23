import Foundation
import ClaudexBarCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    if !condition() {
        throw TestFailure(description: description)
    }
}

func expectNonNil<T>(_ value: T?, _ description: String) throws -> T {
    guard let value else { throw TestFailure(description: description) }
    return value
}

func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        throw TestFailure(description: "Missing fixture \(name).json")
    }
    return try Data(contentsOf: url)
}

func testResetLabelsUseAbsoluteResetDates() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    try expect(UsageFormatter.resetLabel(resetAt: now.addingTimeInterval(42 * 60), now: now) == "42m", "42 minute label")
    try expect(UsageFormatter.resetLabel(resetAt: now.addingTimeInterval(4 * 60 * 60), now: now) == "4h", "4 hour label")
    try expect(UsageFormatter.resetLabel(resetAt: now.addingTimeInterval(4 * 24 * 60 * 60), now: now) == "4d", "4 day label")
}

func testCountdownChangesWhenNowChangesWithoutNewFetch() throws {
    let resetAt = Date(timeIntervalSince1970: 10_000)
    let fetched = Date(timeIntervalSince1970: 8_000)
    let later = fetched.addingTimeInterval(600)
    let window = UsageWindow(windowLabel: "5h", remainingPercent: 45, resetAt: resetAt)

    try expect(UsageFormatter.display(for: window, now: fetched).label == "33m", "initial countdown label")
    try expect(UsageFormatter.display(for: window, now: later).label == "23m", "later countdown label")
}

func testFullWindowUsesWindowLabelButPartialShowsExactPercent() throws {
    let now = Date(timeIntervalSince1970: 1_000)

    // Genuinely full: window label + 100%.
    let full = UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(45 * 60))
    let fullDisplay = UsageFormatter.display(for: full, now: now)
    try expect(fullDisplay.label == "5h", "full window label")
    try expect(fullDisplay.remainingPercent == 100, "full window percent")

    // 1% used: shown precisely (99%) with a reset countdown, not clamped to 100.
    let partial = UsageWindow(windowLabel: "5h", remainingPercent: 99, resetAt: now.addingTimeInterval(45 * 60))
    let partialDisplay = UsageFormatter.display(for: partial, now: now)
    try expect(partialDisplay.remainingPercent == 99, "99% shown exactly, not clamped")
    try expect(partialDisplay.label == "45m", "99% uses a reset countdown")
}

func testCodexUsageResponseParsing() throws {
    let data = try fixtureData("codex_usage")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = try CodexProvider.parseUsageResponse(data, fetchedAt: now)

    try expect(snapshot.primary.windowLabel == "5h", "Codex primary label")
    try expect(snapshot.primary.remainingPercent == 93, "Codex primary remaining")
    try expect(snapshot.primary.resetAt == now.addingTimeInterval(2_100), "Codex primary reset")
    try expect(snapshot.secondary.windowLabel == "1w", "Codex secondary label")
    try expect(snapshot.secondary.remainingPercent == 70, "Codex secondary remaining")
    try expect(snapshot.secondary.resetAt == now.addingTimeInterval(395_000), "Codex secondary reset")
}

func testCodexAccountDiscoveryUsesOnlyDefaultHome() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    func writeAccount(_ folder: String, accountID: String) throws {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auth = Data(#"{"tokens":{"access_token":"dummy"},"account_id":"\#(accountID)"}"#.utf8)
        try auth.write(to: dir.appendingPathComponent("auth.json"))
    }

    try writeAccount(".codex", accountID: "default-id")
    try writeAccount(".codex_argun", accountID: "argun-id")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex_empty"), withIntermediateDirectories: true)

    let account = CodexAccountDiscovery(homeDirectory: root).defaultAccount()

    try expect(account.id == "codex", "uses one stable Codex account id")
    try expect(account.displayName == "Codex", "default display name stays compact")
    try expect(account.authURL.path.hasSuffix(".codex/auth.json"), "auth URL points at the default home")
}

func testClaudeUsageResponseParsingUsesSevenDayFallback() throws {
    let data = try fixtureData("claude_usage")
    let snapshot = try ClaudeProvider.parseUsageResponse(data, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))

    try expect(snapshot.primary.windowLabel == "5h", "Claude primary label")
    try expect(snapshot.primary.remainingPercent == 88, "Claude primary remaining")
    try expect(snapshot.primary.resetAt == ISO8601DateFormatter.parseClaudexDate("2026-06-03T19:00:00Z"), "Claude primary reset")
    try expect(snapshot.secondary.windowLabel == "7d", "Claude secondary label")
    try expect(snapshot.secondary.remainingPercent == 64, "Claude secondary remaining")
    try expect(snapshot.secondary.resetAt == ISO8601DateFormatter.parseClaudexDate("2026-06-08T02:28:55Z"), "Claude secondary reset")
}

func testClaudeCredentialReaderAcceptsOAuthEnvironmentToken() throws {
    let credentials = try ClaudeCredentialReader.credentialsFromEnvironment([
        "CLAUDE_CODE_OAUTH_TOKEN": "Bearer sk-ant-oat01-test-token"
    ])

    try expect(credentials.accessToken == "sk-ant-oat01-test-token", "env token stripped")
    try expect(credentials.refreshToken == nil, "env token has no refresh token")
    try expect(credentials.expiresAt == nil, "env token has no local expiry")
}

func testPKCEChallengeMatchesRFC7636Vector() throws {
    // RFC 7636 Appendix B reference vector.
    let pkce = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    try expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "S256 challenge matches RFC vector")
}

func testPastedCodeSplitSeparatesCodeAndState() throws {
    let split = ClaudeOAuthFlow.splitPastedCode("  AbC123def#st-9-XYZ \n")
    try expect(split.code == "AbC123def", "code parsed before #")
    try expect(split.state == "st-9-XYZ", "state parsed after #")

    let bare = ClaudeOAuthFlow.splitPastedCode("justacode")
    try expect(bare.code == "justacode", "bare code parsed")
    try expect(bare.state == nil, "bare code has no state")
}

func testAuthorizeURLUsesPlatformFlowAndProvenScopes() throws {
    let url = ClaudeOAuthFlow().authorizeURL()
    let components = try expectNonNil(URLComponents(url: url, resolvingAgainstBaseURL: false), "authorize url parses")
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

    try expect(url.host == "claude.com" && url.path == "/cai/oauth/authorize", "authorize endpoint is claude.com/cai")
    try expect(value("redirect_uri") == "https://platform.claude.com/oauth/code/callback", "platform-code redirect, not localhost")
    try expect(value("code_challenge_method") == "S256", "uses S256 PKCE")
    let scope = value("scope") ?? ""
    try expect(scope.contains("user:profile") && scope.contains("user:inference"), "requests usage-required scopes")
    try expect(!scope.contains("org:create_api_key"), "omits org:create_api_key (breaks the authorize request)")
}

func testTokenResponseParsingBuildsCredentialWithExpiry() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let json = Data(#"{"access_token":"sk-ant-oat01-abc","refresh_token":"sk-ant-ort01-def","expires_in":28800,"token_type":"Bearer"}"#.utf8)
    let credential = try expectNonNil(ClaudeOAuthFlow.parseTokenResponse(json, now: now), "token response parses")

    try expect(credential.accessToken == "sk-ant-oat01-abc", "access token parsed")
    try expect(credential.refreshToken == "sk-ant-ort01-def", "refresh token parsed")
    try expect(credential.expiresAt == 1_000_000 + 28_800_000, "expiry computed from expires_in")

    // The stored JSON shape must round-trip back through the credential reader.
    var oauth: [String: Any] = ["accessToken": credential.accessToken]
    oauth["refreshToken"] = credential.refreshToken
    oauth["expiresAt"] = credential.expiresAt
    let storedData = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    let reread = try expectNonNil(ClaudeCredentialReader.decodeCredentials(data: storedData), "stored credential re-reads")
    try expect(reread == credential, "stored credential round-trips")
}

func testRefreshResponseParsingRotatesRefreshTokenAndFallsBack() throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let rotated = ClaudeProvider.parseRefreshResponse(
        Data(#"{"access_token":"sk-ant-oat01-new","refresh_token":"sk-ant-ort01-new","expires_in":28800}"#.utf8),
        fallbackRefreshToken: "sk-ant-ort01-old",
        now: now
    )
    try expect(rotated?.refreshToken == "sk-ant-ort01-new", "rotated refresh token kept")

    let noRotation = ClaudeProvider.parseRefreshResponse(
        Data(#"{"access_token":"sk-ant-oat01-new"}"#.utf8),
        fallbackRefreshToken: "sk-ant-ort01-old",
        now: now
    )
    try expect(noRotation?.refreshToken == "sk-ant-ort01-old", "falls back to existing refresh token when none returned")
}

func testUsageErrorTransientClassification() throws {
    try expect(UsageError.rateLimited.isTransient, "rate limit is transient")
    try expect(UsageError.network.isTransient, "network is transient")
    try expect(UsageError.server(statusCode: 503).isTransient, "server error is transient")
    try expect(!UsageError.authExpired.isTransient, "auth expired needs attention")
    try expect(!UsageError.missingAuth.isTransient, "missing auth needs attention")
    try expect(!UsageError.decoding.isTransient, "decoding error is not transient")
}

func testUpdateCheckerVersionComparison() throws {
    try expect(UpdateChecker.isVersion("0.2.0", newerThan: "0.1.0"), "0.2.0 > 0.1.0")
    try expect(UpdateChecker.isVersion("0.10.0", newerThan: "0.9.0"), "0.10.0 > 0.9.0 (numeric, not lexical)")
    try expect(UpdateChecker.isVersion("1.0.0", newerThan: "0.99.99"), "major beats minor/patch")
    try expect(!UpdateChecker.isVersion("0.1.0", newerThan: "0.1.0"), "equal is not newer")
    try expect(!UpdateChecker.isVersion("0.1.0", newerThan: "0.2.0"), "older is not newer")
}

func testSecretScannerRedactsTokenShapedStringsFromLogMessages() throws {
    let leaky = "reauth produced sk-ant-oat01-AbCdEf012345_token.value and a jwt eyJhbGciOiJIUzI1.AAAABBBBCCCCDDDD"
    let redacted = SecretScanner.redact(leaky)

    try expect(SecretScanner.containsSecret(leaky), "scanner flags token-shaped input")
    try expect(!redacted.contains("sk-ant-oat01"), "redaction removes Claude token")
    try expect(redacted.range(of: "sk-ant-[A-Za-z0-9._-]{8,}", options: .regularExpression) == nil, "no token-shaped substring remains")
    try expect(!SecretScanner.containsSecret(redacted), "redacted output has no secrets")
    try expect(redacted.contains("[REDACTED]"), "redaction marks removed secrets")

    let benign = "usage ok"
    try expect(!SecretScanner.containsSecret(benign), "status strings are not flagged")
    try expect(SecretScanner.redact(benign) == benign, "status strings pass through untouched")
}

func testProviderSelectionCyclesOnlyEnabledProviders() throws {
    var selection = ProviderSelection(activeProvider: .codex, enabledProviders: [.codex, .claude])

    selection.toggleEnabled(.claude)
    try expect(selection.enabledProviders == [.codex], "Claude can be disabled")
    try expect(selection.nextProvider() == .codex, "single enabled provider does not cycle")

    selection.toggleEnabled(.claude)
    selection.activeProvider = .codex
    try expect(selection.nextProvider() == .claude, "cycles to next enabled provider")
}

func testProviderSelectionCanBeEmptyForPausedMode() throws {
    var selection = ProviderSelection(activeProvider: .claude, enabledProviders: [.claude])

    selection.toggleEnabled(.claude)

    try expect(selection.enabledProviders.isEmpty, "last provider can be disabled for paused mode")
    try expect(selection.activeProvider == .claude, "active provider remains stable while paused")
    try expect(selection.nextProvider() == .claude, "empty selection has no cycle target")
}

func testSmartSwitchWaitsForStableCandidateBeforeSwitching() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(
        activeProvider: .codex,
        minimumStableDuration: 20,
        manualOverrideDuration: 600,
        scoreAdvantageThreshold: 30,
        switchCooldown: 120
    )

    let early = engine.evaluate(
        signals: SmartProviderSignals(
            foregroundProvider: .claude,
            recentActivityProvider: .claude,
            runningProviders: [.claude]
        ),
        now: start
    )
    try expect(early == nil, "candidate does not switch immediately")

    let stable = engine.evaluate(
        signals: SmartProviderSignals(
            foregroundProvider: .claude,
            recentActivityProvider: .claude,
            runningProviders: [.claude]
        ),
        now: start.addingTimeInterval(21)
    )
    try expect(stable == .claude, "stable candidate switches after debounce")
}

func testSmartSwitchDoesNotSwitchOnTieOrWeakProcessOnlySignal() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(
        activeProvider: .codex,
        minimumStableDuration: 20,
        manualOverrideDuration: 600,
        scoreAdvantageThreshold: 30,
        switchCooldown: 120
    )

    let tie = engine.evaluate(
        signals: SmartProviderSignals(
            foregroundProvider: nil,
            recentActivityProvider: nil,
            runningProviders: [.codex, .claude]
        ),
        now: now.addingTimeInterval(60)
    )
    try expect(tie == nil, "equal running processes do not switch")

    let weak = engine.evaluate(
        signals: SmartProviderSignals(
            foregroundProvider: nil,
            recentActivityProvider: nil,
            runningProviders: [.claude]
        ),
        now: now.addingTimeInterval(120)
    )
    try expect(weak == nil, "process-only signal is too weak to switch")
}

func testSmartSwitchForegroundBeatsConflictingRecentActivity() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(
        activeProvider: .codex,
        minimumStableDuration: 20,
        manualOverrideDuration: 600,
        scoreAdvantageThreshold: 30,
        switchCooldown: 120
    )

    _ = engine.evaluate(
        signals: SmartProviderSignals(
            foregroundProvider: .claude,
            recentActivityProvider: .codex,
            runningProviders: []
        ),
        now: start
    )
    let stable = engine.evaluate(
        signals: SmartProviderSignals(
            foregroundProvider: .claude,
            recentActivityProvider: .codex,
            runningProviders: []
        ),
        now: start.addingTimeInterval(21)
    )

    try expect(stable == .claude, "foreground provider wins over conflicting recent activity")
}

func testSmartSwitchManualOverrideSuppressesAutoSwitchTemporarily() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(
        activeProvider: .codex,
        minimumStableDuration: 20,
        manualOverrideDuration: 600,
        scoreAdvantageThreshold: 30,
        switchCooldown: 120
    )

    engine.recordManualSelection(.codex, now: start)

    let blocked = engine.evaluate(
        signals: SmartProviderSignals(
            foregroundProvider: .claude,
            recentActivityProvider: .claude,
            runningProviders: [.claude]
        ),
        now: start.addingTimeInterval(120)
    )
    try expect(blocked == nil, "manual override blocks auto-switch")

    let afterOverride = engine.evaluate(
        signals: SmartProviderSignals(
            foregroundProvider: .claude,
            recentActivityProvider: .claude,
            runningProviders: [.claude]
        ),
        now: start.addingTimeInterval(621)
    )
    try expect(afterOverride == .claude, "auto-switch resumes after manual override expires")
}

func testSmartProviderTextMatcherDoesNotTreatClaudexBarAsClaude() throws {
    try expect(SmartProviderTextMatcher.provider(in: ["ClaudexBar"]) == nil, "app name is not a provider")
    try expect(SmartProviderTextMatcher.provider(in: ["Claude Code"]) == .claude, "Claude Code text maps to Claude")
    try expect(SmartProviderTextMatcher.provider(in: ["/usr/local/bin/codex"]) == .codex, "codex executable maps to Codex")
}

func testThresholdCreatesOneUsageNotificationPerCooldown() throws {
    var store = NotificationCycleStore()
    let resetAt = Date(timeIntervalSince1970: 2_000)
    let window = UsageWindow(windowLabel: "5h", remainingPercent: 18, resetAt: resetAt)
    let snapshot = UsageSnapshot(primary: window, secondary: window, fetchedAt: Date())
    let evaluator = NotificationEvaluator(threshold: .twentyPercent, minimumUsageNotificationInterval: 30 * 60)

    let first = evaluator.decisions(activeProvider: .codex, snapshots: [.codex: snapshot], store: &store, now: Date(timeIntervalSince1970: 1_000))
    let soonAfter = evaluator.decisions(activeProvider: .codex, snapshots: [.codex: snapshot], store: &store, now: Date(timeIntervalSince1970: 1_100))
    let afterCooldown = evaluator.decisions(activeProvider: .codex, snapshots: [.codex: snapshot], store: &store, now: Date(timeIntervalSince1970: 2_901))

    try expect(first.count == 1, "only one threshold notification is delivered at once")
    try expect(first.first?.windowKind == .primary, "primary window is delivered first")
    try expect(soonAfter.isEmpty, "usage notifications are rate limited")
    try expect(afterCooldown.count == 1, "second window can notify after cooldown")
    try expect(afterCooldown.first?.windowKind == .secondary, "secondary window was delayed, not discarded")
}

func testNotificationCooldownStartsOnlyWhenNotificationIsDelivered() throws {
    var store = NotificationCycleStore()
    let resetAt = Date(timeIntervalSince1970: 4_000)
    let healthy = UsageWindow(windowLabel: "5h", remainingPercent: 60, resetAt: resetAt)
    let low = UsageWindow(windowLabel: "5h", remainingPercent: 18, resetAt: resetAt)
    let evaluator = NotificationEvaluator(threshold: .twentyPercent, minimumUsageNotificationInterval: 30 * 60)

    let none = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: UsageSnapshot(primary: healthy, secondary: healthy, fetchedAt: Date())],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let firstLow = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: UsageSnapshot(primary: low, secondary: healthy, fetchedAt: Date())],
        store: &store,
        now: Date(timeIntervalSince1970: 1_100)
    )

    try expect(none.isEmpty, "healthy usage does not notify")
    try expect(firstLow.count == 1, "first low usage is not suppressed by a healthy refresh")
}

func testDefaultUsageNotificationCooldownIsThreeHours() throws {
    var store = NotificationCycleStore()
    let resetAt = Date(timeIntervalSince1970: 20_000)
    let primary = UsageWindow(windowLabel: "5h", remainingPercent: 18, resetAt: resetAt)
    let firstSnapshot = UsageSnapshot(primary: primary, secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: resetAt), fetchedAt: Date())
    let secondSnapshot = UsageSnapshot(primary: primary, secondary: UsageWindow(windowLabel: "7d", remainingPercent: 12, resetAt: resetAt), fetchedAt: Date())
    let evaluator = NotificationEvaluator(threshold: .twentyPercent)

    let first = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: firstSnapshot],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let beforeThreeHours = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: secondSnapshot],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000 + (3 * 60 * 60) - 1)
    )
    let afterThreeHours = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: secondSnapshot],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000 + (3 * 60 * 60))
    )

    try expect(first.count == 1, "first low usage notifies")
    try expect(beforeThreeHours.isEmpty, "default cooldown blocks notifications before three hours")
    try expect(afterThreeHours.count == 1, "default cooldown allows notifications after three hours")
}

func testCrossProviderHintRequiresTwentyFivePointAdvantage() throws {
    var store = NotificationCycleStore()
    let now = Date(timeIntervalSince1970: 1_000)
    let resetAt = Date(timeIntervalSince1970: 3_000)
    let low = UsageWindow(windowLabel: "5h", remainingPercent: 18, resetAt: resetAt)
    let high = UsageWindow(windowLabel: "5h", remainingPercent: 70, resetAt: resetAt)
    let codex = UsageSnapshot(primary: low, secondary: high, fetchedAt: now)
    let claude = UsageSnapshot(primary: high, secondary: high, fetchedAt: now)

    let decisions = NotificationEvaluator(threshold: .twentyPercent).decisions(
        activeProvider: .codex,
        snapshots: [.codex: codex, .claude: claude],
        store: &store,
        now: now
    )

    try expect(decisions.first?.inactiveProviderHint?.provider == .claude, "cross-provider hint provider")
    try expect(decisions.first?.inactiveProviderHint?.remainingPercent == 70, "cross-provider hint remaining")
}

func testRecoveryNotificationFiresOnceAfterDepletedWindowRestores() throws {
    var store = NotificationCycleStore()
    let evaluator = NotificationEvaluator(threshold: .twentyPercent)
    let depletedReset = Date(timeIntervalSince1970: 2_000)
    let restoredReset = Date(timeIntervalSince1970: 20_000)
    let depleted = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 0, resetAt: depletedReset),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: restoredReset),
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )
    let restored = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: restoredReset),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: restoredReset),
        fetchedAt: Date(timeIntervalSince1970: 2_100)
    )

    let beforeReset = evaluator.recoveryDecisions(
        activeProvider: .codex,
        snapshots: [.codex: depleted],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let afterReset = evaluator.recoveryDecisions(
        activeProvider: .codex,
        snapshots: [.codex: restored],
        store: &store,
        now: Date(timeIntervalSince1970: 2_100)
    )
    let duplicateRefresh = evaluator.recoveryDecisions(
        activeProvider: .codex,
        snapshots: [.codex: restored],
        store: &store,
        now: Date(timeIntervalSince1970: 2_200)
    )

    try expect(beforeReset.isEmpty, "depleted window only arms recovery")
    try expect(afterReset.count == 1, "restored window notifies once")
    try expect(afterReset.first?.provider == .codex, "recovery provider")
    try expect(afterReset.first?.windowKind == .primary, "recovery window kind")
    try expect(afterReset.first?.window.remainingPercent == 100, "recovery remaining percent")
    try expect(duplicateRefresh.isEmpty, "recovery is deduped for the restored cycle")
}

func testRecoveryNotificationRespectsNotificationOffSetting() throws {
    var store = NotificationCycleStore()
    let evaluator = NotificationEvaluator(threshold: .off)
    let depleted = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 0, resetAt: Date(timeIntervalSince1970: 2_000)),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: Date(timeIntervalSince1970: 20_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )
    let restored = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: Date(timeIntervalSince1970: 20_000)),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: Date(timeIntervalSince1970: 20_000)),
        fetchedAt: Date(timeIntervalSince1970: 2_100)
    )

    _ = evaluator.recoveryDecisions(
        activeProvider: .codex,
        snapshots: [.codex: depleted],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let afterReset = evaluator.recoveryDecisions(
        activeProvider: .codex,
        snapshots: [.codex: restored],
        store: &store,
        now: Date(timeIntervalSince1970: 2_100)
    )

    try expect(afterReset.isEmpty, "notification off suppresses recovery")
}

func testRecoveryNotificationEvaluatesAllEnabledSources() throws {
    var store = NotificationCycleStore()
    let evaluator = NotificationEvaluator(threshold: .twentyPercent)
    let depleted = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 0, resetAt: Date(timeIntervalSince1970: 2_000)),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: Date(timeIntervalSince1970: 20_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )
    let restored = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: Date(timeIntervalSince1970: 20_000)),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: Date(timeIntervalSince1970: 20_000)),
        fetchedAt: Date(timeIntervalSince1970: 2_100)
    )
    let healthyCodex = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 60, resetAt: Date(timeIntervalSince1970: 8_000)),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 70, resetAt: Date(timeIntervalSince1970: 20_000)),
        fetchedAt: Date(timeIntervalSince1970: 2_100)
    )

    _ = evaluator.recoveryDecisions(
        sources: [
            NotificationSourceSnapshot(provider: .claude, snapshot: depleted)
        ],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let decisions = evaluator.recoveryDecisions(
        sources: [
            NotificationSourceSnapshot(provider: .codex, snapshot: healthyCodex),
            NotificationSourceSnapshot(provider: .claude, snapshot: restored)
        ],
        store: &store,
        now: Date(timeIntervalSince1970: 2_100)
    )

    try expect(decisions.count == 1, "recovery evaluates inactive provider source")
    try expect(decisions.first?.provider == .claude, "inactive Claude recovery provider")
}

let tests: [(String, () throws -> Void)] = [
    ("reset labels use absolute reset dates", testResetLabelsUseAbsoluteResetDates),
    ("countdown changes without new fetch", testCountdownChangesWhenNowChangesWithoutNewFetch),
    ("full window label vs exact partial percent", testFullWindowUsesWindowLabelButPartialShowsExactPercent),
    ("Codex usage response parsing", testCodexUsageResponseParsing),
    ("Codex default account discovery", testCodexAccountDiscoveryUsesOnlyDefaultHome),
    ("Claude usage response parsing", testClaudeUsageResponseParsingUsesSevenDayFallback),
    ("Claude env OAuth token", testClaudeCredentialReaderAcceptsOAuthEnvironmentToken),
    ("PKCE S256 challenge", testPKCEChallengeMatchesRFC7636Vector),
    ("Pasted code split", testPastedCodeSplitSeparatesCodeAndState),
    ("Authorize URL platform flow", testAuthorizeURLUsesPlatformFlowAndProvenScopes),
    ("OAuth token response parsing", testTokenResponseParsingBuildsCredentialWithExpiry),
    ("OAuth refresh rotation", testRefreshResponseParsingRotatesRefreshTokenAndFallsBack),
    ("Usage error transient classification", testUsageErrorTransientClassification),
    ("Update version comparison", testUpdateCheckerVersionComparison),
    ("Secret scanner redaction", testSecretScannerRedactsTokenShapedStringsFromLogMessages),
    ("Provider selection model", testProviderSelectionCyclesOnlyEnabledProviders),
    ("Provider selection paused mode", testProviderSelectionCanBeEmptyForPausedMode),
    ("Smart switch stable candidate", testSmartSwitchWaitsForStableCandidateBeforeSwitching),
    ("Smart switch tie and weak signal", testSmartSwitchDoesNotSwitchOnTieOrWeakProcessOnlySignal),
    ("Smart switch foreground beats recent activity", testSmartSwitchForegroundBeatsConflictingRecentActivity),
    ("Smart switch manual override", testSmartSwitchManualOverrideSuppressesAutoSwitchTemporarily),
    ("Smart provider text matcher", testSmartProviderTextMatcherDoesNotTreatClaudexBarAsClaude),
    ("threshold notification dedupe", testThresholdCreatesOneUsageNotificationPerCooldown),
    ("notification cooldown starts on delivery", testNotificationCooldownStartsOnlyWhenNotificationIsDelivered),
    ("default usage notification cooldown", testDefaultUsageNotificationCooldownIsThreeHours),
    ("cross-provider hint", testCrossProviderHintRequiresTwentyFivePointAdvantage),
    ("recovery notification fires once", testRecoveryNotificationFiresOnceAfterDepletedWindowRestores),
    ("recovery notification off setting", testRecoveryNotificationRespectsNotificationOffSetting),
    ("recovery notification all enabled sources", testRecoveryNotificationEvaluatesAllEnabledSources)
]

for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        print("FAIL \(name): \(error)")
        exit(1)
    }
}

print("PASS \(tests.count) ClaudexBar core tests")
