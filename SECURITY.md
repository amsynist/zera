# Security Policy

## Reporting a vulnerability

Please report security issues **privately** through GitHub: open this repository's **Security** tab
and choose **Report a vulnerability**. Don't open a public issue for vulnerabilities.

Include what you found, steps to reproduce, and the Zera version (Settings → About). We aim to
acknowledge reports within 7 days.

## Supported versions

Only the latest release gets security fixes.

## How Zera handles your data and system

- **Not sandboxed.** Zera runs with your user's permissions so it can read files you drop, run your own
  `claude` CLI, and edit `~/.claude/settings.json` when you turn its hooks on. Install it only from this
  repository's Releases page and check `SHA256SUMS.txt`.
- **Secrets** (Anthropic API key, GitHub token) are kept in your login Keychain and sent only to
  `api.anthropic.com` / `api.github.com`. Zera never reads Claude Code's own credentials.
- **No telemetry**, analytics, crash reporting or auto-update.
- **Claude Code approvals** use a local file drop-box in `~/Library/Application Support/Zera/hooks`
  (folders readable only by you). Like anything running as your user, another program running as you
  could interfere with it; Zera doesn't defend against malware already running under your account.
- **Live progress** events are handed to Zera and deleted as soon as they're read; nothing is written
  while Zera isn't running.

## Scope

Reports about the app, its Claude Code hooks, the GitHub integration, the build scripts and the
release workflow are all welcome.
