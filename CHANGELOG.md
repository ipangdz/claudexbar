# Changelog

All notable changes to ClaudexBar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

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
