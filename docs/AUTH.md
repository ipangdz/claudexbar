# ClaudexBar Authentication (authoritative)

Last verified: 2026-06-03 (Claude Code v2.1.160, Codex CLI).

This document describes how ClaudexBar actually authenticates today. It supersedes the auth sections of `BRIEF.md`, `docs/IMPLEMENTATION_PLAN.md`, and `docs/PROTOTYPE_NOTES.md`, which describe an earlier design that did not work on current Claude Code.

## Codex

- Token source: `~/.codex/auth.json`, JSON path `tokens.access_token`.
- Usage endpoint: `https://chatgpt.com/backend-api/wham/usage` (headers: `Authorization: Bearer <token>`, `Accept: application/json`, browser-like `User-Agent`).
- Re-auth: `codex login`, opened in Terminal (the official CLI manages the file).
- No refresh logic; if the token is invalid the pill shows `auth` and the user runs `codex login`.

## Claude Code

ClaudexBar runs **its own** Claude OAuth (Authorization Code + PKCE) and stores an **independent** credential. It does not reuse Claude Code's own login, because that login's refresh token **rotates on every refresh** — a background app sharing it would invalidate Claude Code (and vice versa).

### Credential sources, in priority order
1. `CLAUDE_CODE_OAUTH_TOKEN` environment variable (explicit override).
2. ClaudexBar's own credential: Keychain service `ClaudexBar-Claude-Credentials` (access + refresh + expiry, JSON in the `claudeAiOauth` shape).
3. Claude Code's own login: Keychain `Claude Code-credentials`, then `~/.claude/.credentials.json` (best-effort fallback; expires/rotates independently).

The suffixed `Claude Code-credentials-*` Keychain items are per-MCP-server OAuth tokens, **not** logins, and are ignored.

### The OAuth flow (platform-code + one paste)

1. ClaudexBar opens the browser to:
   `https://claude.com/cai/oauth/authorize` with query params:
   - `code=true`
   - `client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e`
   - `response_type=code`
   - `redirect_uri=https://platform.claude.com/oauth/code/callback`
   - `scope=user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`
   - `code_challenge=<base64url(SHA256(verifier))>`, `code_challenge_method=S256`
   - `state=<random>`
2. The user approves. Claude's callback page displays a one-time **`code#state`** string.
3. The user pastes it into the ClaudexBar dialog (pre-filled from the clipboard when recognised).
4. ClaudexBar verifies `state`, then exchanges the code (form-encoded POST) at
   `https://platform.claude.com/v1/oauth/token`:
   `grant_type=authorization_code, code, redirect_uri, client_id, code_verifier, state`.
5. The response (`access_token` `sk-ant-oat01-…`, `refresh_token` `sk-ant-ort01-…`, `expires_in` 28800 = 8 h) is stored in Keychain `ClaudexBar-Claude-Credentials`.

### Usage + refresh
- Usage endpoint: `https://api.anthropic.com/api/oauth/usage`
  (headers: `Authorization: Bearer`, `Accept: application/json`, `Content-Type: application/json`, `anthropic-beta: oauth-2025-04-20`).
  Response: `five_hour.utilization` / `.resets_at`, `seven_day.*` (+ `seven_day_sonnet`/`seven_day_opus` fallbacks).
- The 8-hour access token is refreshed automatically: on expiry or HTTP 401, ClaudexBar POSTs `grant_type=refresh_token` (form-encoded) to the token endpoint, and **persists the rotated access+refresh** back to its own Keychain item. Because the grant is independent of Claude Code, this never conflicts.

## Why not the simpler alternatives (verified dead ends, 2026-06-03)

| Approach | Result |
|---|---|
| Read Claude Code's `Claude Code-credentials` and refresh it | refresh token rotates → conflicts with Claude Code; snapshot dies |
| `claude setup-token` (independent token) | scope is **`user:inference` only → HTTP 403** on the usage endpoint |
| Localhost loopback redirect (`http://localhost:PORT/callback`) | **rejected** by Claude's OAuth client ("Authorization failed / Invalid request format"; callback never fires) |
| Include scope `org:create_api_key` | **authorize request fails** — must be omitted |

The winning combination is the platform-code redirect with the five scopes above (no `org:create_api_key`). The one manual paste is required because Claude's OAuth client only returns the code to its own callback page, not to a localhost server.

## Security
- Tokens live only in the macOS Keychain — never in UserDefaults, files, plists, shell profiles, logs, or the repo.
- The pasted code and tokens are held only in memory during the flow.
- Every log line is routed through `SecretScanner.redact`; logs contain only provider names, status labels, HTTP status summaries, and sanitized errors.

## Note on scope of use
The Claude subscription OAuth credential is, per Anthropic's terms, intended for Claude Code / Claude.ai. ClaudexBar uses it only to **read the account's own usage limits** (the same `oauth/usage` endpoint `claude` uses for `/status`), never for inference — the same posture as the Codex side. This is documented honestly so users can make their own call.
