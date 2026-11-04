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
  Claude/Codex tools, optionally manage windows with Accessibility, and edit `~/.claude/settings.json` when you turn its hooks on. Install it only from this
  repository's Releases page and check `SHA256SUMS.txt`.
- **Secrets** (Anthropic API key, GitHub token) are kept in your login Keychain and sent only to
  `api.anthropic.com` / `api.github.com`. Zera never reads Claude Code's own credentials.
- **No telemetry**, analytics, crash reporting or auto-update.
- **Claude Code approvals** use a local file drop-box in `~/Library/Application Support/Zera/hooks`
  (folders readable only by you). Like anything running as your user, another program running as you
  could interfere with it; Zera doesn't defend against malware already running under your account.
- **Live progress** events are handed to Zera and deleted as soon as they're read; nothing is written
  while Zera isn't running.

- **Android sharing** listens on local TCP 8989 while enabled and advertises Bonjour `_androp._tcp`. Pairing gates access, but traffic is unencrypted: use trusted LANs/hotspots and do not expose the listener to the internet. Receipts are size/hash verified, safely named and quarantined before publication. Disable via Zera menu → Android sharing.

## Scope

Reports about the app, Android companion/local receiver, agent integrations, optional permissions, the build scripts and the
release workflow are all welcome.
