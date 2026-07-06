# Smart Auto Switch Redesign

Date: 2026-07-06
Status: Approved

## Problem

The current smart auto switch keeps showing Codex when the user wants Claude usage,
even when Codex is not open and nothing Codex-related is running.

Root causes found in the current implementation:

1. The "recent activity" signal scans file mtimes under `~/.codex`
   (`session_index.jsonl`, `logs_*`, `shell_snapshots/`). Background processes
   (Codex.app helpers, Codex plugins inside Claude Code sessions) touch these
   files without the user using Codex. The activity score (50) alone exceeds the
   switch threshold (30), so the pill flips to Codex.
2. The `runningProviders` signal is always `[]` — it was never implemented.
3. The default provider in `AppSettings` is `.codex`, so every fallback path
   lands on Codex.
4. The engine is over-tuned: a scoring system plus four tunables
   (stable duration, cooldown, manual override, score threshold), and the
   detector does a recursive filesystem scan every 5 seconds.

A separate constraint from the user: Claude and Codex are used through many
surfaces — local CLI, desktop app, Paseo, web, remote sessions, and an
always-on daemon. Local process detection and local file activity can never be
accurate for web/remote usage, and an always-running daemon would bias any
process-based signal.

## Design

### Signals (exactly two, no scoring)

1. **Foreground** — checked every 5 seconds. Cheap: frontmost app name, bundle
   id, executable name, and frontmost window title, matched with the existing
   `SmartProviderTextMatcher`. A foreground match must be stable for ~10
   seconds (debounce) before it becomes a candidate. No disk I/O.
2. **Usage delta** — evaluated when a usage refresh completes (no extra timer,
   no extra fetches; ClaudexBar already fetches usage for all enabled
   providers on its refresh timer). If a provider's primary-window used
   percentage increased between the previous and the new snapshot, that
   provider is actively consuming usage — regardless of where (CLI, web,
   remote, Paseo, daemon). If both providers increased, the larger delta wins;
   equal deltas produce no candidate.

### Decision rules (precedence, not scores)

1. A manual selection (left-click toggle) pins the choice for 10 minutes;
   no automatic switch happens during the pin.
2. Foreground candidate wins over usage-delta candidate.
3. A candidate only matters if it differs from the active provider and is an
   enabled provider.
4. No candidate → stay on the last selection. There is no idle fallback of any
   kind (this removes "always falls back to Codex").

### What gets deleted or simplified

- `SmartProviderDetector.recentActivityProvider` and the recursive filesystem
  scanning (including the dead `.highwatermark` matcher, which never fired
  because the scan uses `skipsHiddenFiles`). The detector keeps only the
  foreground check.
- `SmartProviderSwitchEngine` scoring (`score`, `strongestCandidate`,
  `scoreAdvantageThreshold`, `switchCooldown`) → replaced by a small
  precedence-based engine whose only tunables are the manual pin duration and
  the foreground debounce.
- `SmartProviderSignals.runningProviders` (never populated) → removed.
  Signals become `foregroundProvider` + `usageDeltaProvider`.
- **Codex path unification in `StatusBarController`**: `codexSnapshot`,
  `codexError`, `codexStatusOverride`, the `UsageSource` enum, and the
  Codex-specific refresh/hint/notification branches are merged into the
  existing generic `snapshots` / `errors` / `statusOverrides` dictionaries and
  `providers` map. Codex becomes a regular `UsageProvider` entry like Claude.
- `CodexAccounts.swift` (`CodexAccount`, `CodexAccountDiscovery`) → deleted.
  `CodexAuthReader` defaults to `~/.codex/auth.json`; the reauth flow uses
  `~/.codex` directly for `CODEX_HOME`.
- Untracked residue files `favicon.png` (repo root) and `public/` (duplicate
  favicons, referenced nowhere) → deleted.

### What stays unchanged

- `AppSettings.smartSwitchEnabled` and the menu toggle.
- Manual left-click toggle behavior and the 10-minute pin.
- The refresh timer, pill rendering, notifications, reauth flows.
- `SmartProviderTextMatcher` (still used for foreground matching, including
  the "ClaudexBar is not Claude" rule).

### Data flow

- 5s timer → detector reads frontmost app/window → engine records foreground
  observation → engine may return a switch → update pill, refresh active
  provider.
- Refresh completion (per provider) → controller computes used-percent delta
  vs the previous snapshot → engine records delta observation → engine may
  return a switch → update pill.
- Left-click toggle → `recordManualSelection` (pin 10 min).
- External changes (enable/disable provider) → `recordExternalSelection`,
  same as today.

### Error handling

- Missing snapshots (first refresh, auth errors) simply produce no delta
  candidate — no switching on incomplete data.
- A provider disabled in settings can never become a candidate (filtered
  before the engine, as today).
- Failed refreshes keep the previous snapshot for delta comparison only if a
  new successful snapshot arrives later; errors never synthesize a delta.

### Testing

`ClaudexBarTestRunner` updates:

- Delete tests for the removed scoring engine behavior and
  `CodexAccountDiscovery`.
- Keep `SmartProviderTextMatcher` tests.
- New engine tests: foreground beats delta; delta switches when only one
  provider increases; larger delta wins when both increase; equal deltas do
  nothing; no candidate keeps the active provider; manual pin blocks
  switching for its duration; foreground debounce requires stability;
  disabled providers never win.
- Unified-controller behavior is covered by keeping existing formatter /
  notification tests passing after the refactor.

## Trade-off (accepted)

Usage-delta reaction time follows the refresh interval (default 5 minutes).
If the user starts using Claude via web with no Claude window on the Mac, the
pill switches on the next refresh. The foreground signal covers local usage
instantly.
