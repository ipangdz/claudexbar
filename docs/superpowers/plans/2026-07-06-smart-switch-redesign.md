# Smart Auto Switch Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the noisy score-based smart switch with a two-signal precedence engine (foreground + usage delta), unify the duplicated Codex path in `StatusBarController`, and delete dead code, per `docs/superpowers/specs/2026-07-06-smart-switch-redesign-design.md`.

**Architecture:** `ClaudexBarCore` gains a rewritten `SmartProviderSwitch.swift` containing `SmartProviderSignals` (foreground + usageDelta), a new `UsageDeltaTracker`, and a precedence-based `SmartProviderSwitchEngine` (manual pin + foreground debounce, no scoring). `StatusBarController` treats Codex as a regular `UsageProvider` (no parallel `codexSnapshot`/`UsageSource` path) and evaluates the engine on a 5-second timer using detector foreground + tracker delta. `SmartProviderDetector` keeps only the foreground check.

**Tech Stack:** Swift 5.9 SPM package, AppKit, custom `ClaudexBarTestRunner` executable (no XCTest).

## Global Constraints

- macOS 13+, no third-party dependencies (Package.swift stays dependency-free).
- Tests run via `swift run ClaudexBarTestRunner`; every test must print PASS and the runner exits 0.
- All log lines go through `SanitizedLogger` / `SecretScanner` (do not add raw prints of tokens).
- Build must stay green at every commit: `swift build` succeeds and the test runner passes.
- Engine tunables (spec): manual pin 10 minutes, foreground debounce 10 seconds. No other tunables.

---

### Task 1: Delete untracked residue files

**Files:**
- Delete: `favicon.png` (repo root)
- Delete: `public/` (contains duplicate `favicon.png`, `icon.png`)

**Interfaces:** none — files are referenced nowhere (verified via grep across README, scripts, packaging).

- [ ] **Step 1: Delete the files**

```bash
rm /Users/ipang/ClaudexBar/favicon.png
rm -r /Users/ipang/ClaudexBar/public
```

- [ ] **Step 2: Verify clean status (untracked files gone, nothing tracked deleted)**

Run: `git status --short`
Expected: only `?? docs/superpowers/plans/...` remains (this plan), no `D` lines.

No commit needed — the files were never tracked.

---

### Task 2: Unify the Codex path in StatusBarController; delete CodexAccounts.swift

**Files:**
- Modify: `Sources/ClaudexBarApp/StatusBarController.swift`
- Delete: `Sources/ClaudexBarCore/CodexAccounts.swift`
- Modify: `Sources/ClaudexBarTestRunner/main.swift` (remove `testCodexAccountDiscoveryUsesOnlyDefaultHome`)

**Interfaces:**
- Consumes: `CodexProvider()` default init (already defaults `CodexAuthReader` to `~/.codex/auth.json`), existing `snapshots`/`errors`/`statusOverrides: [ProviderID: …]` dictionaries.
- Produces: `refresh(provider:notify:)` working for both providers; `activeEnabledProvider: ProviderID?` (nil = paused) replacing `currentSource()`; `refreshActiveProvider(notify:)` replacing `refreshActiveSource`. Task 3 relies on these names.

- [ ] **Step 1: Remove the CodexAccountDiscovery test**

In `Sources/ClaudexBarTestRunner/main.swift` delete the whole function `testCodexAccountDiscoveryUsesOnlyDefaultHome` (lines ~72–92) and its registry entry `("Codex default account discovery", testCodexAccountDiscoveryUsesOnlyDefaultHome),`.

- [ ] **Step 2: Unify StatusBarController**

All edits in `Sources/ClaudexBarApp/StatusBarController.swift`:

2a. Replace the fields `codexAccount`, `providers`, `codexSnapshot`, `codexError`, `codexStatusOverride` and the `UsageSource`-typed state:

```swift
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
```

and change `private var refreshesInFlight: Set<UsageSource> = []` to `private var refreshesInFlight: Set<ProviderID> = []`. Delete the `private enum UsageSource` declaration entirely.

2b. Delete `enabledSources()`, `currentSource()`, `setActiveSource(_:)`. Add:

```swift
private var activeEnabledProvider: ProviderID? {
    providerSelection.enabledProviders.contains(activeProvider) ? activeProvider : nil
}
```

2c. Replace `toggleProvider()`:

```swift
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
```

2d. Replace `refreshAll()` body and delete `refreshCodex(notify:)`; make `refresh(provider:notify:)` generic (it currently hardcodes `UsageSource.claude`):

```swift
private func refreshAll() {
    let enabled = providerSelection.enabledProviders
    guard !enabled.isEmpty else {
        updateImage()
        return
    }
    enabled.forEach { refresh(provider: $0) }
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
```

Update the two `refreshActiveSource(...)` call sites (in `toggleProvider` — already done in 2c — and in the smart-switch completion) to `refreshActiveProvider(...)`.

2e. Replace `updateImage()` (drop the Codex special case):

```swift
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
```

2f. Replace `providerStatusHint(_:)` (drop the Codex branch):

```swift
private func providerStatusHint(_ provider: ProviderID) -> String {
    if let override = statusOverrides[provider] { return override }
    if let snapshot = snapshots[provider], errors[provider] == nil {
        return "\(snapshot.primary.remainingPercent)% · \(snapshot.secondary.remainingPercent)%"
    }
    if let error = errors[provider] { return error.statusLabel }
    return "wait"
}
```

2g. Replace `toggleProviderEnabled(_:)`:

```swift
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
```

2h. In `runCodexReauth()`: replace `codexStatusOverride` with `statusOverrides[.codex]`, `codexError` with `errors[.codex]`, `self.refreshCodex()` with `self.refresh(provider: .codex)`, and the CODEX_HOME line with:

```swift
process.environment = ProcessInfo.processInfo.environment.merging(
    ["CODEX_HOME": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path]
) { _, new in new }
```

(`codexStatusOverride = nil` becomes `statusOverrides[.codex] = nil`, `codexError = nil` becomes `errors[.codex] = nil`, `codexError = .authExpired` becomes `errors[.codex] = .authExpired` — in all branches including `catch`.)

2i. Replace `evaluateNotifications()` and `recoveryNotificationSources()` (snapshots dict now already contains Codex):

```swift
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

private func recoveryNotificationSources() -> [NotificationSourceSnapshot] {
    providerSelection.enabledProviders.compactMap { provider in
        snapshots[provider].map { NotificationSourceSnapshot(provider: provider, snapshot: $0) }
    }
}
```

2j. In `finishSmartSwitchEvaluation` (still on the old engine API until Task 3): replace `let sources = enabledSources(); guard !sources.isEmpty …; guard sources.count > 1` with `guard providerSelection.enabledProviders.count > 1 else { return }`, and `refreshActiveSource(notify: false)` with `refreshActiveProvider(notify: false)`. In `evaluateNotifications` the old code referenced `codexSnapshot` — already covered by 2i.

- [ ] **Step 3: Delete CodexAccounts.swift**

```bash
rm /Users/ipang/ClaudexBar/Sources/ClaudexBarCore/CodexAccounts.swift
```

- [ ] **Step 4: Build and run tests**

Run: `swift build && swift run ClaudexBarTestRunner`
Expected: build succeeds; runner prints `PASS 28 ClaudexBar core tests` (29 minus the removed discovery test) and exits 0.

- [ ] **Step 5: Commit**

```bash
git add -A Sources
git commit -m "Unify Codex into the generic provider path; drop CodexAccounts"
```

---

### Task 3: Rewrite the smart switch core (signals, delta tracker, precedence engine)

**Files:**
- Rewrite: `Sources/ClaudexBarCore/SmartProviderSwitch.swift`
- Modify: `Sources/ClaudexBarApp/SmartProviderDetector.swift` (foreground only)
- Modify: `Sources/ClaudexBarApp/StatusBarController.swift` (evaluation path)
- Test: `Sources/ClaudexBarTestRunner/main.swift`

**Interfaces:**
- Consumes: `ProviderID`, `UsageSnapshot` from `UsageModels.swift`; `snapshots` updates from Task 2's `refresh(provider:)`.
- Produces (exact API used by the controller and tests):
  - `SmartProviderSignals(foregroundProvider: ProviderID?, usageDeltaProvider: ProviderID?)`
  - `UsageDeltaTracker()` with `mutating func record(provider: ProviderID, snapshot: UsageSnapshot)` and `func dominantProvider() -> ProviderID?`
  - `SmartProviderSwitchEngine(activeProvider: ProviderID, manualPinDuration: TimeInterval = 600, foregroundStableDuration: TimeInterval = 10)` with `activeProvider: ProviderID { get }`, `mutating func recordManualSelection(_:now:)`, `mutating func recordExternalSelection(_:)`, `mutating func evaluate(signals: SmartProviderSignals, now: Date) -> ProviderID?`
  - `SmartProviderTextMatcher` unchanged.

- [ ] **Step 1: Replace the old engine tests with the new ones (failing first)**

In `Sources/ClaudexBarTestRunner/main.swift`, delete these four functions and their registry entries:
`testSmartSwitchWaitsForStableCandidateBeforeSwitching`, `testSmartSwitchDoesNotSwitchOnTieOrWeakProcessOnlySignal`, `testSmartSwitchForegroundBeatsConflictingRecentActivity`, `testSmartSwitchManualOverrideSuppressesAutoSwitchTemporarily`.

Add in their place:

```swift
func makeSnapshot(remaining: Int, at fetchedAt: Date = Date(timeIntervalSince1970: 0)) -> UsageSnapshot {
    let window = UsageWindow(windowLabel: "5h", remainingPercent: remaining, resetAt: nil)
    return UsageSnapshot(primary: window, secondary: window, fetchedAt: fetchedAt)
}

func testUsageDeltaTrackerFindsSingleActiveProvider() throws {
    var tracker = UsageDeltaTracker()
    tracker.record(provider: .claude, snapshot: makeSnapshot(remaining: 90))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 80))
    try expect(tracker.dominantProvider() == nil, "first snapshots produce no delta")

    tracker.record(provider: .claude, snapshot: makeSnapshot(remaining: 85))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 80))
    try expect(tracker.dominantProvider() == .claude, "only Claude consumed usage")
}

func testUsageDeltaTrackerLargerDeltaWinsAndTiesDoNothing() throws {
    var tracker = UsageDeltaTracker()
    tracker.record(provider: .claude, snapshot: makeSnapshot(remaining: 90))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 90))

    tracker.record(provider: .claude, snapshot: makeSnapshot(remaining: 80))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 88))
    try expect(tracker.dominantProvider() == .claude, "larger delta wins when both increase")

    tracker.record(provider: .claude, snapshot: makeSnapshot(remaining: 75))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 83))
    try expect(tracker.dominantProvider() == nil, "equal deltas produce no candidate")
}

func testUsageDeltaTrackerIgnoresWindowResets() throws {
    var tracker = UsageDeltaTracker()
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 5))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 100))
    try expect(tracker.dominantProvider() == nil, "remaining going up (window reset) is not usage")
}

func testSmartSwitchForegroundNeedsStabilityThenSwitches() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(activeProvider: .codex)

    let first = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start
    )
    try expect(first == nil, "foreground candidate does not switch immediately")

    let flicker = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: nil, usageDeltaProvider: nil),
        now: start.addingTimeInterval(5)
    )
    try expect(flicker == nil, "losing foreground resets the debounce")

    _ = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start.addingTimeInterval(10)
    )
    let stable = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start.addingTimeInterval(21)
    )
    try expect(stable == .claude, "stable foreground switches after the debounce")
    try expect(engine.activeProvider == .claude, "engine tracks the new active provider")
}

func testSmartSwitchForegroundBeatsUsageDelta() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(activeProvider: .codex)

    _ = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: .codex),
        now: start
    )
    let stable = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: .codex),
        now: start.addingTimeInterval(11)
    )
    try expect(stable == .claude, "foreground wins over a conflicting usage delta")
}

func testSmartSwitchUsageDeltaSwitchesWithoutForeground() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(activeProvider: .codex)

    let switched = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: nil, usageDeltaProvider: .claude),
        now: start
    )
    try expect(switched == .claude, "usage delta alone switches (it is already refresh-interval slow)")

    let idle = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: nil, usageDeltaProvider: nil),
        now: start.addingTimeInterval(60)
    )
    try expect(idle == nil, "no candidate keeps the last selection")
    try expect(engine.activeProvider == .claude, "idle does not fall back anywhere")
}

func testSmartSwitchManualPinBlocksAutoSwitchTemporarily() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(activeProvider: .claude)

    engine.recordManualSelection(.codex, now: start)

    let blocked = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start.addingTimeInterval(599)
    )
    try expect(blocked == nil, "manual pin blocks auto-switch for 10 minutes")

    _ = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start.addingTimeInterval(601)
    )
    let afterPin = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start.addingTimeInterval(612)
    )
    try expect(afterPin == .claude, "auto-switch resumes after the pin expires")
}
```

Registry entries (replace the four removed lines, keep the text-matcher line):

```swift
    ("usage delta tracker single provider", testUsageDeltaTrackerFindsSingleActiveProvider),
    ("usage delta tracker ties and magnitude", testUsageDeltaTrackerLargerDeltaWinsAndTiesDoNothing),
    ("usage delta tracker window reset", testUsageDeltaTrackerIgnoresWindowResets),
    ("smart switch foreground debounce", testSmartSwitchForegroundNeedsStabilityThenSwitches),
    ("smart switch foreground beats delta", testSmartSwitchForegroundBeatsUsageDelta),
    ("smart switch delta without foreground", testSmartSwitchUsageDeltaSwitchesWithoutForeground),
    ("smart switch manual pin", testSmartSwitchManualPinBlocksAutoSwitchTemporarily),
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift build 2>&1 | head -20`
Expected: compile errors — `UsageDeltaTracker` not found, `SmartProviderSignals` has no member `usageDeltaProvider`.

- [ ] **Step 3: Rewrite `Sources/ClaudexBarCore/SmartProviderSwitch.swift`**

Full new file content (keeps `SmartProviderTextMatcher` verbatim):

```swift
import Foundation

public struct SmartProviderSignals: Equatable, Sendable {
    public var foregroundProvider: ProviderID?
    public var usageDeltaProvider: ProviderID?

    public init(foregroundProvider: ProviderID?, usageDeltaProvider: ProviderID?) {
        self.foregroundProvider = foregroundProvider
        self.usageDeltaProvider = usageDeltaProvider
    }
}

public enum SmartProviderTextMatcher {
    public static func provider(in values: [String?]) -> ProviderID? {
        let joined = values.compactMap { $0?.lowercased() }.joined(separator: " ")
        if matchesClaude(joined) { return .claude }
        if matchesCodex(joined) { return .codex }
        return nil
    }

    public static func provider(in values: [String]) -> ProviderID? {
        provider(in: values.map(Optional.some))
    }

    public static func matchesCodex(_ value: String) -> Bool {
        tokens(in: value).contains("codex")
    }

    public static func matchesClaude(_ value: String) -> Bool {
        let tokenSet = tokens(in: value)
        return tokenSet.contains("claude")
            || tokenSet.contains("claudecode")
    }

    private static func tokens(in value: String) -> Set<String> {
        Set(
            value
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
    }
}

/// Tracks which provider is actually consuming usage between refreshes.
/// A provider whose primary-window remaining percentage dropped since its
/// previous snapshot is being used — no matter where (CLI, desktop app, web,
/// remote session, daemon). Remaining going *up* is a window reset, not usage.
public struct UsageDeltaTracker: Sendable {
    private var lastRemaining: [ProviderID: Int] = [:]
    private var deltas: [ProviderID: Int] = [:]

    public init() {}

    public mutating func record(provider: ProviderID, snapshot: UsageSnapshot) {
        let remaining = snapshot.primary.remainingPercent
        if let previous = lastRemaining[provider] {
            deltas[provider] = max(0, previous - remaining)
        }
        lastRemaining[provider] = remaining
    }

    /// The single provider with the largest positive usage delta; nil when no
    /// provider consumed usage or when the largest deltas tie.
    public func dominantProvider() -> ProviderID? {
        let positive = deltas.filter { $0.value > 0 }
        guard let best = positive.values.max() else { return nil }
        let leaders = positive.filter { $0.value == best }
        return leaders.count == 1 ? leaders.first?.key : nil
    }
}

/// Precedence-based auto switch: a manual selection pins the choice for
/// `manualPinDuration`; a foreground match must be stable for
/// `foregroundStableDuration` and beats the usage-delta signal; with no
/// candidate the active provider never changes (no idle fallback).
public struct SmartProviderSwitchEngine: Sendable {
    public private(set) var activeProvider: ProviderID

    private let manualPinDuration: TimeInterval
    private let foregroundStableDuration: TimeInterval

    private var manualPinUntil: Date?
    private var pendingForeground: ProviderID?
    private var pendingForegroundSince: Date?

    public init(
        activeProvider: ProviderID,
        manualPinDuration: TimeInterval = 10 * 60,
        foregroundStableDuration: TimeInterval = 10
    ) {
        self.activeProvider = activeProvider
        self.manualPinDuration = manualPinDuration
        self.foregroundStableDuration = foregroundStableDuration
    }

    public mutating func recordManualSelection(_ provider: ProviderID, now: Date) {
        activeProvider = provider
        manualPinUntil = now.addingTimeInterval(manualPinDuration)
        pendingForeground = nil
        pendingForegroundSince = nil
    }

    public mutating func recordExternalSelection(_ provider: ProviderID) {
        activeProvider = provider
        pendingForeground = nil
        pendingForegroundSince = nil
    }

    public mutating func evaluate(signals: SmartProviderSignals, now: Date) -> ProviderID? {
        trackForeground(signals.foregroundProvider, now: now)

        if let pinnedUntil = manualPinUntil, now < pinnedUntil {
            return nil
        }

        guard let candidate = stableForeground(now: now) ?? signals.usageDeltaProvider,
              candidate != activeProvider
        else {
            return nil
        }

        activeProvider = candidate
        return candidate
    }

    private mutating func trackForeground(_ provider: ProviderID?, now: Date) {
        guard provider == pendingForeground else {
            pendingForeground = provider
            pendingForegroundSince = provider == nil ? nil : now
            return
        }
    }

    private func stableForeground(now: Date) -> ProviderID? {
        guard let pendingForeground,
              let since = pendingForegroundSince,
              now.timeIntervalSince(since) >= foregroundStableDuration
        else {
            return nil
        }
        return pendingForeground
    }
}
```

- [ ] **Step 4: Reduce `SmartProviderDetector` to the foreground check**

Full new content of `Sources/ClaudexBarApp/SmartProviderDetector.swift`:

```swift
import AppKit
import ClaudexBarCore
import Foundation

/// Detects whether the frontmost app/window is clearly Claude or Codex.
/// Main-thread only; no disk I/O.
@MainActor
final class SmartProviderDetector {
    func foregroundProvider() -> ProviderID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        let foregroundText = [
            app.localizedName,
            app.bundleIdentifier,
            app.executableURL?.lastPathComponent
        ]
        if let provider = SmartProviderTextMatcher.provider(in: foregroundText) {
            return provider
        }

        return SmartProviderTextMatcher.provider(in: frontmostWindowText(for: app.processIdentifier))
    }

    private func frontmostWindowText(for processIdentifier: pid_t) -> [String?] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        guard let window = windowInfo.first(where: { item in
            (item[kCGWindowOwnerPID as String] as? pid_t) == processIdentifier
                && (item[kCGWindowLayer as String] as? Int) == 0
        }) else {
            return []
        }

        return [
            window[kCGWindowOwnerName as String] as? String,
            window[kCGWindowName as String] as? String
        ]
    }
}
```

- [ ] **Step 5: Rewire StatusBarController evaluation**

In `Sources/ClaudexBarApp/StatusBarController.swift`:

5a. Delete the field `private var smartSwitchDetectionInProgress = false` and add next to `smartSwitchEngine`:

```swift
private var usageDeltaTracker = UsageDeltaTracker()
```

5b. In `refresh(provider:notify:)`'s success branch, after `errors[provider] = nil`, add:

```swift
usageDeltaTracker.record(provider: provider, snapshot: snapshot)
```

5c. Replace `beginSmartSwitchEvaluation()` and `finishSmartSwitchEvaluation(...)` with one synchronous method (no background queue — the detector no longer touches the disk):

```swift
private func evaluateSmartSwitch() {
    guard settings.smartSwitchEnabled else { return }
    let enabled = Set(providerSelection.enabledProviders)
    guard enabled.count > 1 else { return }

    if smartSwitchEngine == nil {
        smartSwitchEngine = SmartProviderSwitchEngine(activeProvider: activeProvider)
    }
    if smartSwitchEngine?.activeProvider != activeProvider {
        smartSwitchEngine?.recordExternalSelection(activeProvider)
    }

    let signals = SmartProviderSignals(
        foregroundProvider: smartSwitchDetector.foregroundProvider()
            .flatMap { enabled.contains($0) ? $0 : nil },
        usageDeltaProvider: usageDeltaTracker.dominantProvider()
            .flatMap { enabled.contains($0) ? $0 : nil }
    )

    guard let provider = smartSwitchEngine?.evaluate(signals: signals, now: Date()) else { return }
    activeProvider = provider
    updateImage()
    refreshActiveProvider(notify: false)
}
```

5d. Update the two callers: the 5-second timer block in `scheduleTimers()` and `toggleSmartSwitch()` call `self.evaluateSmartSwitch()` / `evaluateSmartSwitch()` instead of `beginSmartSwitchEvaluation()`.

- [ ] **Step 6: Build and run tests to verify they pass**

Run: `swift build && swift run ClaudexBarTestRunner`
Expected: build succeeds; runner prints `PASS 31 ClaudexBar core tests` (28 − 4 old engine tests + 7 new) and exits 0.

- [ ] **Step 7: Commit**

```bash
git add -A Sources
git commit -m "Replace score-based smart switch with foreground + usage-delta precedence"
```

---

### Task 4: Changelog

**Files:**
- Modify: `CHANGELOG.md` (Unreleased section)

- [ ] **Step 1: Add entries under `## Unreleased` → `### Changed`**

Append these bullets to the existing `### Changed` list:

```markdown
- Redesigned smart auto switch: the pill now follows the provider that is
  actually consuming usage (works for CLI, desktop, web, and remote sessions)
  or the one clearly in the foreground; with no signal it stays on your last
  choice instead of falling back to Codex.
- Removed the filesystem-activity heuristic and its 5-second `~/.codex` /
  `~/.claude` scans.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "Changelog: smart switch redesign"
```

---

### Task 5: Rebuild, install, restart

**Files:** none (uses `scripts/install.sh`, which builds release, installs to `~/Applications/ClaudexBar.app`, rewrites the LaunchAgent, and restarts the app via `launchctl bootout` + `bootstrap`).

- [ ] **Step 1: Run the installer**

Run: `./scripts/install.sh`
Expected output ends with: `Installed ClaudexBar at /Users/ipang/Applications/ClaudexBar.app`

- [ ] **Step 2: Verify the new build is running**

Run: `launchctl print "gui/$(id -u)/com.ipang.claudexbar" | grep -E "state|pid"` and `pgrep -fl ClaudexBar`
Expected: state = running, a live PID for `~/Applications/ClaudexBar.app/Contents/MacOS/ClaudexBar`.

- [ ] **Step 3: Smoke-check the logs for a clean start**

Run: `tail -5 ~/Library/Logs/ClaudexBar/claudexbar.err.log`
Expected: no crash/backtrace lines.
