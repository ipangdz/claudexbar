# Changelog

All notable changes to ClaudexBar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## Unreleased

### Changed
- Simplified Codex support to a single default account at `~/.codex/auth.json`.
- Removed Codex account hiding, hidden-account restore, manual account rescan,
  account badges, and per-account smart-switch detection.
- Kept provider-level enable/disable, paused/off, smart switching, and re-auth
  for the two supported providers: Codex and Claude Code.
- Redesigned smart auto switch: the pill now follows the provider that is
  actually consuming usage (works for CLI, desktop, web, and remote sessions)
  or the one clearly in the foreground; with no signal it stays on your last
  choice instead of falling back to Codex.
- Removed the filesystem-activity heuristic and its 5-second `~/.codex` /
  `~/.claude` scans.

## [0.1.0] — 2026-06-03

Initial release.

### Added
- Native AppKit menu-bar app (no Dock icon) showing Codex and Claude Code usage.
- Codex usage from `~/.codex/auth.json`; Claude Code usage via the OAuth usage endpoint.
- Claude Code authentication via in-app OAuth (Authorization Code + PKCE): browser
  sign-in, one code paste, full scopes, stored in the Keychain and auto-refreshed
  (8-hour token). See [docs/AUTH.md](docs/AUTH.md).
- Right-click menu: per-provider enable checklist that stays open while toggling;
  hold ⌥ Option to reveal Re-auth and Open Logs; Refresh All; Check for Updates.
- Left-click cycles the active provider; compact two-window pill (session + weekly).
- Threshold notifications (remaining-percentage based) and re-auth failure notifications.
- Lightweight update check against GitHub releases (no third-party dependencies).
- Security hardening: tokens only ever in the Keychain; all log lines routed through
  `SecretScanner` redaction.
