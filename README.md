# ClaudexBar

[![CI](https://github.com/ipangdz/claudexbar/actions/workflows/ci.yml/badge.svg)](https://github.com/ipangdz/claudexbar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)

A small native macOS menu-bar app that shows **Codex** and **Claude Code** usage limits at a glance. Zero-config: it reuses your existing CLI login, shows each provider's session (5-hour) and weekly windows, and warns before you run low — no API keys, no browser cookies, no dependencies.

## Features

- Native AppKit menu bar app with no Dock icon and no main window.
- Two providers only: Codex and Claude Code.
- Codex auth from `~/.codex/auth.json`. Claude Code auth from a ClaudexBar-managed OAuth credential in Keychain (`ClaudexBar-Claude-Credentials`), falling back to `CLAUDE_CODE_OAUTH_TOKEN` and Claude Code's own `Claude Code-credentials` login.
- Re-auth: Codex opens `codex login` in Terminal; Claude Code opens your browser to Claude's sign-in page. After you approve, Claude shows a one-time code — paste it into the ClaudexBar dialog and it stores its own access+refresh credential (no Terminal).
- Configurable refresh interval and remaining-usage notifications.
- No telemetry, analytics, or browser cookies. The only value you paste is the one-time Claude authorization code, which is exchanged for a token and never stored.

## Install

```bash
./scripts/install.sh
```

The installer builds the release binary, assembles `~/Applications/ClaudexBar.app` (with its icon), **ad-hoc code-signs it** (`codesign --sign -`), installs `~/.local/bin/claudexbar`, writes a LaunchAgent, and starts it.

ClaudexBar is built from source on your own machine, so no Apple Developer account, certificate, or notarization is required — the local ad-hoc signature is enough. (The app is a menu-bar accessory via `LSUIElement`, so its icon appears in Finder/Spotlight rather than the Dock.)

## Development

```bash
swift build
swift run ClaudexBarTestRunner
```

`ClaudexBarTestRunner` covers reset-label formatting, live countdown rendering, Codex and Claude response parsing, notification threshold decisions, one-notification-per-window-cycle deduping, and cross-provider hints.

## Uninstall

```bash
./scripts/uninstall.sh
```

Uninstall removes the ClaudexBar binary, LaunchAgent, app settings, and logs. It does not touch Codex or Claude Code credentials.

## Usage

Left-click the pill to cycle between enabled providers. If only one provider is enabled, left-click leaves that provider selected. Right-click for the menu.

The right-click menu lists each provider once, as a 1-click checkbox row:

- The checkbox toggles whether the provider is enabled (Codex + Claude Code both checked → left-click cycles between them; only one checked → ClaudexBar stays on it). At least one provider always stays enabled.
- The row shows that provider's live usage (`5h% · 7d%`), or a status word (`auth` / `net` / `err`) when there is a problem.
- **Hold ⌥ Option** (the menu reacts live): each provider row turns into **Re-auth Codex / Re-auth Claude Code**, and **Refresh All** turns into **Open Logs…**.

Below the providers are Refresh All, Launch at Login, Refresh Interval, and Notify When Remaining.

The left usage column is the current session window. The right column is the weekly budget. Session usage also chips away at the weekly budget.

## Troubleshooting

- `auth` for Codex: run `codex login`.
- `auth` for Claude Code: choose `Re-auth` → `Claude Code` from the ClaudexBar menu. Your browser opens to Claude's sign-in page (`claude.com/cai/oauth/authorize`). Approve access; Claude's callback page then shows a one-time `code#state` string. Copy it and paste it into the ClaudexBar dialog (it pre-fills from your clipboard when it recognises a code). ClaudexBar exchanges it for an access+refresh credential — with the full scopes the usage endpoint needs — stored in the Keychain service `ClaudexBar-Claude-Credentials`, then refreshes usage. The code and tokens are never logged.
- Why a paste (and not a fully automatic flow): Claude's OAuth client does not accept a `localhost` redirect, so the authorization code is returned to Claude's own callback page rather than to ClaudexBar directly. The one paste bridges that page back to the app.
- Why a separate credential: Claude Code's own `Claude Code-credentials` login rotates its refresh token on every refresh, so a background menu-bar app reading that snapshot would be invalidated whenever Claude Code refreshes (and vice versa). ClaudexBar runs its own OAuth sign-in to get an independent credential it refreshes on its own (the access token lasts ~8 hours and is refreshed automatically).
- `login` stuck in the pill: the code exchange is still running or failed. Check `auth` afterwards and re-run `Re-auth` → `Claude Code`.
- `auth` right after re-auth: the paste may have been incomplete. Re-run and paste the entire `code#state` string from Claude's page.
- If you want terminal Claude Code sessions to use a manually generated token too, set:

  ```bash
  export CLAUDE_CODE_OAUTH_TOKEN='<token>'
  ```

- Claude `err`/HTTP 403: the stored credential lacks a required scope. Run `Re-auth` → `Claude Code` again — ClaudexBar requests the correct scope set itself. (Note: `claude setup-token` is **not** used; its token has too narrow a scope for the usage endpoint. See [docs/AUTH.md](docs/AUTH.md).)
- `net`: the usage endpoint could not be reached or may be rate limited. Use the provider's `Refresh` from the menu a little later.

## Non-goals

- No history graphs.
- No cost estimation.
- No embedded/in-app web view: sign-in happens in your real browser via the official CLI.
- No additional providers in MVP.

## Documentation

- [docs/AUTH.md](docs/AUTH.md) — how Codex and Claude Code authentication work, and why.
- [SECURITY.md](SECURITY.md) — security model and how to report a vulnerability.
- [CHANGELOG.md](CHANGELOG.md) — release notes.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The project is
deliberately narrow (Codex + Claude Code only) and dependency-free.

## License

[MIT](LICENSE).
