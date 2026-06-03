# Contributing to ClaudexBar

Thanks for your interest! ClaudexBar is a small, deliberately narrow macOS
menu-bar app for Codex and Claude Code usage. Contributions that keep it
focused and dependency-free are very welcome.

## Build & test

```bash
git clone https://github.com/ipangdz/claudexbar.git
cd claudexbar
swift build
swift run ClaudexBarTestRunner   # core unit tests
./scripts/install.sh             # build + install the app locally
```

CI (GitHub Actions) runs `swift build` and the test runner on every push and
pull request.

## Scope

ClaudexBar intentionally supports **only Codex and Claude Code**, and stays out
of: usage history/graphs, cost estimation, per-model breakdowns in the pill,
browser-cookie login, and additional providers. Please open an issue to discuss
before adding anything outside that scope.

## Guidelines

- Keep PRs focused — one concern per pull request.
- No third-party dependencies: the app depends only on macOS frameworks.
- Never log, print, or commit tokens or credentials. All log output goes through
  `SecretScanner`, and tokens live only in the macOS Keychain.
- Run `swift build` and `swift run ClaudexBarTestRunner` before submitting.

## Security

Please do not open public issues for security problems — see
[SECURITY.md](SECURITY.md) for how to report a vulnerability privately.
