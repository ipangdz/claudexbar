# Security

## Reporting a vulnerability

Please report security issues privately — do **not** open a public issue. Use
GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
("Report a vulnerability" under the repository's **Security** tab). You'll get a
response as soon as possible. Only the latest release is supported with fixes.

## Security model

ClaudexBar reuses existing local CLI credentials and delegates sign-in to the official CLIs. During Claude re-auth the user signs in through their own browser; the official CLI completes the OAuth exchange and ClaudexBar only ever sees the resulting token. ClaudexBar never asks for passwords, browser cookies, API keys, session keys, or pasted codes.

Credential sources, in priority order:

Codex:

- `~/.codex/auth.json`, JSON path `tokens.access_token`.

Claude Code:

1. ClaudexBar-managed OAuth credential: macOS Keychain service `ClaudexBar-Claude-Credentials` (preferred; access + refresh token).
2. Environment token: `CLAUDE_CODE_OAUTH_TOKEN`.
3. Claude Code's own login: macOS Keychain service `Claude Code-credentials`, then `~/.claude/.credentials.json`.

Why ClaudexBar owns a separate Claude credential: Claude Code's `Claude Code-credentials` item holds a short-lived OAuth access token plus a refresh token that **rotates** on every refresh. A background menu-bar app that read that snapshot would find it invalidated as soon as Claude Code refreshed (and refreshing from ClaudexBar would in turn break Claude Code). ClaudexBar instead runs its own OAuth sign-in to obtain an independent access+refresh credential, which it refreshes itself (persisting the rotated refresh token after each refresh). The suffixed `Claude Code-credentials-*` Keychain items are per-MCP-server OAuth tokens, not logins, and are ignored.

Re-auth:

- Codex: `codex login` is opened in Terminal.
- Claude Code: ClaudexBar runs Claude's OAuth Authorization Code + PKCE flow. It opens the browser to `https://claude.com/cai/oauth/authorize` (PKCE `S256`, scopes `user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`). Claude's OAuth client does not accept a localhost redirect, so the redirect target is Claude's own callback page (`https://platform.claude.com/oauth/code/callback`), which displays a one-time `code#state` string. The user pastes that into a ClaudexBar dialog; ClaudexBar verifies `state` (CSRF protection), then exchanges the code with the PKCE verifier at `https://platform.claude.com/v1/oauth/token`. The resulting access+refresh credential is stored **only** in the Keychain service `ClaudexBar-Claude-Credentials`. The scopes deliberately match a real Claude Code login and omit `org:create_api_key`, which causes the authorize request to be rejected.

Token handling guarantees:

- Tokens are stored only in the macOS Keychain — never in UserDefaults, files, plists, shell profiles, logs, or the repo.
- The pasted authorization code and the tokens are held only in memory during the flow.
- Every log line is routed through a secret scanner that redacts token-shaped strings (`SecretScanner`), as defense-in-depth on top of only ever logging static status strings.
- Logs contain only provider names, status labels, HTTP status summaries, and sanitized errors. Do not file issues or paste logs that include raw credential files or tokens from other tools.

There is no telemetry, no analytics, and no background network traffic beyond the Codex usage endpoint, the Claude OAuth usage endpoint, and Claude OAuth token refresh.

Note on scope of use: ClaudexBar uses the subscription OAuth credential only to read the account's own usage limits (the same `oauth/usage` endpoint Claude Code uses for `/status`), not for inference. This is the same posture as the Codex side.
