# Codex Optional 5-Hour Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep weekly Codex usage available while rendering a temporarily missing 5-hour window as only `—`, then restore the normal 5-hour metric automatically when the API returns it.

**Architecture:** Make the two snapshot windows optional, classify Codex windows by `limit_window_seconds` when available, and retain the legacy positional mapping when both old-format windows are present. Centralize missing-window text in `UsageFormatter`, then make rendering, notifications, and usage-delta tracking consume optional windows without synthesizing percentages.

**Tech Stack:** Swift 5.9, Foundation, AppKit, Swift Package Manager, the existing `ClaudexBarTestRunner` executable.

---

## File Map

- Create `Sources/ClaudexBarTestRunner/Fixtures/codex_usage_weekly_only.json` as the regression payload matching the current Codex API shape.
- Modify `Sources/ClaudexBarTestRunner/main.swift` for parser, formatter, notification, and usage-delta regression tests.
- Modify `Sources/ClaudexBarCore/UsageModels.swift` so a snapshot can represent an unavailable window.
- Modify `Sources/ClaudexBarCore/CodexProvider.swift` to decode duration metadata and map windows by duration with legacy compatibility.
- Modify `Sources/ClaudexBarCore/UsageFormatter.swift` to produce neutral metric text for an unavailable window.
- Modify `Sources/ClaudexBarCore/Notifications.swift` to skip missing windows.
- Modify `Sources/ClaudexBarCore/SmartProviderSwitch.swift` to clear primary-window delta state while that window is unavailable.
- Modify `Sources/ClaudexBarApp/StatusPillRenderer.swift` and `Sources/ClaudexBarApp/StatusBarController.swift` to render `—` without a label or percentage.

### Task 1: Lock Down the Live Codex Response Shape

**Files:**
- Create: `Sources/ClaudexBarTestRunner/Fixtures/codex_usage_weekly_only.json`
- Modify: `Sources/ClaudexBarTestRunner/main.swift`

- [ ] **Step 1: Add the weekly-only fixture**

```json
{
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 30,
      "reset_after_seconds": 566340,
      "limit_window_seconds": 604800,
      "reset_at": 1784487548
    },
    "secondary_window": null
  }
}
```

- [ ] **Step 2: Add a parser regression test and register it**

```swift
func testCodexUsageResponseParsingSupportsWeeklyOnlyWindow() throws {
    let data = try fixtureData("codex_usage_weekly_only")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = try CodexProvider.parseUsageResponse(data, fetchedAt: now)

    try expect(snapshot.primary == nil, "Codex missing 5h window stays unavailable")
    let weekly = try expectNonNil(snapshot.secondary, "Codex weekly window remains available")
    try expect(weekly.windowLabel == "1w", "Codex weekly label")
    try expect(weekly.remainingPercent == 70, "Codex weekly remaining")
    try expect(weekly.resetAt == now.addingTimeInterval(566_340), "Codex weekly reset")
}
```

Add `("Codex weekly-only usage parsing", testCodexUsageResponseParsingSupportsWeeklyOnlyWindow)` immediately after the existing Codex parsing test.

- [ ] **Step 3: Run the focused runner and verify the new case is red**

Run: `swift run ClaudexBarTestRunner`

Expected: FAIL at `Codex weekly-only usage parsing` with `UsageError.decoding`; all earlier tests pass.

### Task 2: Represent and Parse Optional Windows

**Files:**
- Modify: `Sources/ClaudexBarCore/UsageModels.swift`
- Modify: `Sources/ClaudexBarCore/CodexProvider.swift`
- Modify: `Sources/ClaudexBarCore/Notifications.swift`
- Modify: `Sources/ClaudexBarCore/SmartProviderSwitch.swift`
- Modify: `Sources/ClaudexBarApp/StatusPillRenderer.swift`
- Modify: `Sources/ClaudexBarApp/StatusBarController.swift`
- Modify: `Sources/ClaudexBarTestRunner/main.swift`

- [ ] **Step 1: Make snapshot windows optional**

Change `UsageSnapshot` to store and initialize `UsageWindow?` values:

```swift
public struct UsageSnapshot: Equatable, Sendable {
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let fetchedAt: Date

    public init(primary: UsageWindow?, secondary: UsageWindow?, fetchedAt: Date) {
        self.primary = primary
        self.secondary = secondary
        self.fetchedAt = fetchedAt
    }
}
```

- [ ] **Step 2: Decode and classify Codex windows**

Add `limitWindowSeconds: Int?` to `CodexUsageResponse.Window`, decode `limit_window_seconds` with `decodeIfPresent`, and replace the fixed guard/mapping in `parseUsageResponse` with logic that:

```swift
let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
let primary = response.rateLimit.primaryWindow
let secondary = response.rateLimit.secondaryWindow
let windows = [primary, secondary].compactMap { $0 }

var fiveHour: CodexUsageResponse.Window?
var weekly: CodexUsageResponse.Window?
for window in windows {
    switch window.limitWindowSeconds {
    case 18_000: fiveHour = window
    case 604_800: weekly = window
    default: break
    }
}

if windows.allSatisfy({ $0.limitWindowSeconds == nil }),
   let primary,
   let secondary {
    fiveHour = primary
    weekly = secondary
}

guard fiveHour != nil || weekly != nil else {
    throw UsageError.decoding
}
```

Build the returned snapshot with a small local mapper that converts each optional API window into an optional `UsageWindow`, using labels `5h` and `1w`.

- [ ] **Step 3: Make optional consumers compile without inventing data**

- In `Notifications.swift`, build candidate arrays with `compactMap`, and change `UsageSnapshot.window(_:)` to return `UsageWindow?`.
- In recovery evaluation, `compactMap` both optional snapshot windows before threshold logic.
- In `SmartProviderSwitch.swift`, guard `snapshot.primary`; when it is missing, remove the provider from both `lastRemaining` and `deltas` and return.
- Temporarily unwrap windows in existing test assertions using `expectNonNil`.
- Keep Claude parsing behavior unchanged; it still creates both concrete windows, now implicitly wrapped as optionals.

- [ ] **Step 4: Run the test runner**

Run: `swift run ClaudexBarTestRunner`

Expected: PASS including `Codex weekly-only usage parsing` and existing legacy Codex/Claude parsing cases.

- [ ] **Step 5: Commit the parser and model slice**

```bash
git add Sources/ClaudexBarCore Sources/ClaudexBarApp Sources/ClaudexBarTestRunner
git commit -m "fix: support optional Codex usage windows"
```

### Task 3: Render the Missing Window as Only an Em Dash

**Files:**
- Modify: `Sources/ClaudexBarCore/UsageModels.swift`
- Modify: `Sources/ClaudexBarCore/UsageFormatter.swift`
- Modify: `Sources/ClaudexBarApp/StatusPillRenderer.swift`
- Modify: `Sources/ClaudexBarApp/StatusBarController.swift`
- Modify: `Sources/ClaudexBarTestRunner/main.swift`

- [ ] **Step 1: Add the failing formatter test**

```swift
func testMissingWindowFormatsAsOnlyEmDash() throws {
    let display = UsageFormatter.metricDisplay(for: nil)
    try expect(display.label.isEmpty, "missing window has no label")
    try expect(display.value == "—", "missing window uses only em dash")
    try expect(UsageFormatter.percentText(for: nil) == "—", "missing menu percentage uses only em dash")
}
```

Register `("missing window em dash formatting", testMissingWindowFormatsAsOnlyEmDash)` after the existing formatter tests.

- [ ] **Step 2: Run the test runner and verify it is red**

Run: `swift run ClaudexBarTestRunner`

Expected: compile failure because `UsageFormatter.metricDisplay(for:)` and `percentText(for:)` do not exist.

- [ ] **Step 3: Add the pure formatting representation**

Add this model to `UsageModels.swift`:

```swift
public struct UsageMetricDisplay: Equatable, Sendable {
    public let label: String
    public let value: String
}
```

Add these functions to `UsageFormatter`:

```swift
public static func metricDisplay(for window: UsageWindow?, now: Date = Date()) -> UsageMetricDisplay {
    guard let window else {
        return UsageMetricDisplay(label: "", value: "—")
    }
    let display = display(for: window, now: now)
    return UsageMetricDisplay(label: display.label, value: "\(display.remainingPercent)%")
}

public static func percentText(for window: UsageWindow?) -> String {
    window.map { "\($0.remainingPercent)%" } ?? "—"
}
```

- [ ] **Step 4: Use the formatter in both UI surfaces**

- In `StatusPillRenderer.image(provider:snapshot:now:)`, call `metricDisplay` for both optional windows and pass string values into the private image function.
- Change the private renderer parameters from integer remaining values to `primaryValue: String` and `secondaryValue: String`, then draw the strings directly.
- In `StatusBarController.providerStatusHint`, render `"\(UsageFormatter.percentText(for: snapshot.primary)) · \(UsageFormatter.percentText(for: snapshot.secondary))"`.

- [ ] **Step 5: Run tests and build the application**

Run: `swift run ClaudexBarTestRunner && swift build`

Expected: all runner cases pass and both executable targets build successfully.

- [ ] **Step 6: Commit the rendering slice**

```bash
git add Sources/ClaudexBarCore Sources/ClaudexBarApp Sources/ClaudexBarTestRunner
git commit -m "fix: render unavailable usage as em dash"
```

### Task 4: Prove Missing Windows Cannot Trigger Side Effects

**Files:**
- Modify: `Sources/ClaudexBarTestRunner/main.swift`

- [ ] **Step 1: Add notification and delta regression tests**

```swift
func testMissingPrimaryWindowDoesNotNotify() throws {
    let weekly = UsageWindow(windowLabel: "1w", remainingPercent: 70, resetAt: Date(timeIntervalSince1970: 20_000))
    let snapshot = UsageSnapshot(primary: nil, secondary: weekly, fetchedAt: Date(timeIntervalSince1970: 1_000))
    let evaluator = NotificationEvaluator(threshold: .twentyPercent)
    var store = NotificationCycleStore()

    let decisions = evaluator.decisions(activeProvider: .codex, snapshots: [.codex: snapshot], store: &store, now: Date(timeIntervalSince1970: 1_000))
    try expect(decisions.isEmpty, "missing primary window does not notify")
}

func testUsageDeltaTrackerIgnoresMissingPrimaryAndRebaselinesOnRestore() throws {
    let resetAt = Date(timeIntervalSince1970: 20_000)
    var tracker = UsageDeltaTracker()
    tracker.record(provider: .codex, snapshot: UsageSnapshot(primary: UsageWindow(windowLabel: "5h", remainingPercent: 80, resetAt: resetAt), secondary: nil, fetchedAt: Date()))
    tracker.record(provider: .codex, snapshot: UsageSnapshot(primary: nil, secondary: UsageWindow(windowLabel: "1w", remainingPercent: 70, resetAt: resetAt), fetchedAt: Date()))
    tracker.record(provider: .codex, snapshot: UsageSnapshot(primary: UsageWindow(windowLabel: "5h", remainingPercent: 60, resetAt: resetAt), secondary: nil, fetchedAt: Date()))
    try expect(tracker.dominantProvider() == nil, "restored primary window starts a new delta baseline")
}
```

Register both tests next to the existing notification and usage-delta cases.

- [ ] **Step 2: Run the regression suite**

Run: `swift run ClaudexBarTestRunner`

Expected: PASS for both new cases and the complete runner.

- [ ] **Step 3: Verify source scope and remove accidental debug residue**

Run: `rg -n '\[DEBUG-' Sources || true`, `git diff --check`, and `git status --short`.

Expected: no debug tags, no whitespace errors, and only the planned source/test/fixture files changed since the prior commit.

- [ ] **Step 4: Commit the side-effect regression tests**

```bash
git add Sources/ClaudexBarTestRunner/main.swift
git commit -m "test: cover unavailable Codex window side effects"
```

### Task 5: Final Runtime-Parity Verification

**Files:**
- No source changes expected.

- [ ] **Step 1: Run the complete local verification path**

Run: `swift run ClaudexBarTestRunner && swift build -c release`

Expected: every test prints `PASS`, the final summary reports the updated test count, and the release build completes successfully.

- [ ] **Step 2: Exercise the current live response through the regression shape**

Compare a sanitized live `/backend-api/wham/usage` response with the weekly-only fixture: `primary_window.limit_window_seconds` is `604800`, `secondary_window` is null, and no token or account data is printed.

Expected: the live response shape matches the fixture assumptions.

- [ ] **Step 3: Install and restart the local app**

Run: `./scripts/install.sh`

Expected: the current checkout is built, installed to `~/Applications/ClaudexBar.app`, and the LaunchAgent restarts successfully.

- [ ] **Step 4: Verify the active app no longer logs a decoding error**

Refresh Codex once from the menu or wait for the configured refresh interval, then inspect `~/Library/Logs/ClaudexBar/claudexbar.log`.

Expected: the latest Codex line is `usage ok`; the pill shows only `—` in the left slot and the actual weekly percentage in the right slot.

- [ ] **Step 5: Report completion without pushing or deploying**

Report test/build/install evidence and the local commit hashes. Do not push, create a release, bump a version, or deploy unless the user explicitly asks.
