<p align="center">
  <img src="docs/banner.png" alt="Zera — your AI desktop buddy" width="100%">
</p>

<h1 align="center">Zera</h1>
<p align="center"><b>Your AI desktop buddy.</b> A cute, open-source macOS companion for Claude, GitHub, and your daily workflow.</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#what-she-does">What she does</a> ·
  <a href="#integrations">Integrations</a> ·
  <a href="#building-from-source">Build from source</a> ·
  <a href="#project-layout">Layout</a> ·
  <a href="#roadmap">Roadmap</a>
</p>

---

Zera is a fluffy little puff with a blue-violet tuft who dangles from a rope out of your Mac's
notch. She watches your pointer, says hi when you come near, holds files for you, watches your
GitHub PRs, lets you approve Claude Code commands from the desktop, and keeps you on track with
reminders — all with the tools you already have. **No API keys, no accounts:** GitHub uses a
personal access token you paste in, Claude uses the `claude` CLI and its hooks, so your existing
subscription is all you need.

<p align="center">
  <img src="docs/screens.png" alt="Zera screens: hover pill, Home dashboard, GitHub PRs, Settings, Drop Files, Reminders, notification toast" width="100%">
</p>

## Install

Zera is open source and not (yet) in the App Store, so you build it once from source. It takes
about a minute.

**Requirements:** macOS 13 Ventura or newer, Xcode Command Line Tools (`xcode-select --install`).
A notch is nice but optional — without one she hangs from the middle of the menu bar.

```bash
git clone https://github.com/<you>/zera.git
cd zera
./build.sh                      # compiles, bundles sprites, renders the icon → dist/Zera.app
cp -R dist/Zera.app /Applications/
open /Applications/Zera.app
```

The first launch may show "Zera can't be opened because it is from an unidentified developer"
(the build is ad-hoc signed). Right-click the app → **Open** once, and macOS remembers.

Then, from the menu-bar menu (her face, top right) or Settings:

- **Open at login** so she's there every morning.
- **Settings → Appearance** for Light / Dark / System.
- **Settings → Integrations** to switch on GitHub, Claude and Calendar.

## What she does

| | |
| --- | --- |
| **Hangs from the notch** | Small, tucked under the menu bar, no background — just her on a rope. Drag her sideways along the top edge and she stays where you drop her (snaps back near the notch). |
| **Watches & greets** | Leans and sways toward the pointer; waves and says hi on launch, on hover, and when you come back after she has dozed off. |
| **Hover pill** | Hover her and a small pill appears: Shelf · Home · Reminders · GitHub · Settings. Tap her to open the default (changeable). |
| **Home** | Greeting → "Search files, notes, or ask Zera…" (Return asks Zera, answered in-app) → **Needs attention** (Claude approvals, reminders, unseen PRs, meetings within the hour) → Recent → Quick Actions: Open Claude, Drop Files, New Note, Take a Break, Screenshot, Start Timer. |
| **Shelf** | Drop files on her or the card; drag tiles back out into any upload field. Search, All / Files / Links / Notes, and under the tiles **Summarize · Explain · Extract** plus an **Ask Zera about this file…** field. Double-click a tile to open it. |
| **Zera reads your files** | Summarize / Explain / Extract / Ask run in the background through *your own Claude Code login* and stream into a result card under her — Copy, Save Note, follow-up questions with the file still in context. No terminal window, no API key required (an Anthropic API key is an optional alternative). |
| **GitHub** | Paste a PAT once. Every 2 minutes she reads the open PRs of the repos you pushed to most recently (real time) plus a search for PRs involving you, CI on your PRs, workflow runs waiting for approval, and — for PRs you raised in the last 24 hours — approvals, change requests and comments. Each new item gets a bubble ("Your PR is up! 🚀", "sam approved your PR ✅") plus a toast with **Review Now / Later**; the GitHub card has Open / Review / CI / Approvals tabs and **Approve** for runs. |
| **Claude Code approvals** | Install the hook and, when Claude Code wants to run a command, she drops an approval card (command, description, folder) with **Approve / Reject** (Return / Esc). Claude Code gets the answer. |
| **Reminders** | Today / Upcoming / Completed. Add your own: at a time (once, daily, weekdays, with an optional 15-minute heads-up) or **every N minutes/hours** ("water every 2 hours"). Connect Calendar and she warns you 15 minutes before meetings. Break nudges every 30–120 minutes. Alerts come with **Snooze 5 min / Done**. |
| **Settings** | Sidebar: General · Appearance · Integrations · Shortcuts · About. Integrations opens Claude (provider, status, Test Claude, API key, diagnostics, approval hook), GitHub, Calendar and Shelf. Light / Dark / System, Esc closes any card, honours Reduce Motion. |
| **Dozes off** | Four minutes without the mouse moving and she sleeps on the rope with little z's. |

## Integrations

### GitHub (personal access token)

Settings → GitHub → paste → **Connect**. Classic token: `repo` + `workflow`. Fine-grained:
Pull requests, Checks and Actions (read; Actions write if you want **Approve** to work). The token
is stored in `~/Library/Application Support/Zera/github.token` (mode 600) and only ever sent to
`api.github.com`.

### Claude — Summarize, Explain, Extract, Ask (your existing Claude Code login)

Settings → Integrations → Claude. Two providers; **Existing Claude Code** is the default and nothing
falls back to the paid API on its own.

**How it runs.** When you click Summarize, Zera finds your `claude` executable (your login shell's
`PATH`, then the usual installer locations — `~/.local/bin`, `~/.claude/local`, Homebrew, npm, nvm,
volta — or a path you set under Diagnostics), checks `claude --help` for the flags this build
supports, and launches it hidden with a plain argv — no shell, no Terminal:

```
claude --print --output-format stream-json --verbose --include-partial-messages \
       --session-id <uuid> --tools Read --allowedTools Read --permission-prompts none \
       --max-turns 8 --system-prompt "…" --strict-mcp-config --name "Zera: spec.pdf" "<prompt>"
```

Text, Markdown, code, RTF/Word (via `textutil`) and PDFs with a text layer are extracted locally and
piped on stdin. Scanned PDFs and images are read by Claude's own `Read` tool (vision), with the
file's folder as the working directory and nothing but `Read` enabled. The answer streams in as
Claude writes it; follow-up questions `--resume` the same session so the file stays in context.
Flags missing on an older CLI are simply left out (down to `--print --output-format json`).
Authentication is whatever `claude` already has — Zera only runs the CLI and never reads, copies
or stores its token. `claude auth status --json` is used to show whether you are signed in.

**Anthropic API (optional).** If you'd rather not use Claude Code, switch the provider and paste a
key: it goes into your login Keychain (`ai.zera.anthropic`), is only ever sent to
`api.anthropic.com`, is masked after saving, and **Test Connection** lists your models without
spending tokens. **Remove Key** deletes it.

**Diagnostics** (Settings → Claude → Diagnostics) shows the detected executable, version,
programmatic mode, authentication, streaming support, the active provider and the last run — never a
key, token or document text. **Copy report** gives you plain text for a bug report.

**Open Claude** on Home is the one deliberately external action: it opens the Claude desktop app, or
— only if that is not installed — a Terminal window running plain `claude`.

### Claude Code approvals (hook, no API key)

Settings → Integrations → Claude → **Install hook**. This writes `~/Library/Application Support/Zera/zera-hook.sh`
and adds one `PreToolUse` entry (matcher `Bash`, timeout 600 s) to `~/.claude/settings.json`,
leaving the rest of that file untouched. **Remove hook** undoes both.

How it works: the script spools the tool call to `…/Zera/hooks/requests/`, Zera writes your
decision to `…/hooks/responses/`, and the script prints it back to Claude Code as
`hookSpecificOutput.permissionDecision` (`allow` / `deny`). If Zera isn't running or you don't
answer within ten minutes, the script exits quietly and Claude Code asks in the terminal as usual.
Claude Code reads hooks when a session starts — restart any open session after installing. Each
run is logged to `…/hooks/hook.log`. Zera's own file-analysis requests set `ZERA_ASSISTANT=1`, which
the hook recognises and ignores, so a Summarize never shows up as an approval.

To also route file edits through Zera, change the matcher in `settings.json` to `Bash|Write|Edit`.

### Calendar

Settings → Reminders → **Connect Calendar** (macOS asks once). Today's events show in Reminders;
she warns 15 minutes before each and again when it starts.

## Building from source

```bash
./build.sh            # universal build if the toolchain allows, native otherwise
swift build           # or just the binary, for development
swift test            # parser, CLI detection, prompts, argv, Markdown, file payloads
```

Acceptance check for the file assistant (do it once after building): quit Terminal, make sure
`claude` is signed in, launch Zera, drop a PDF on her, click **Summarize**. Terminal and iTerm must
stay closed, Zera goes thinking → focused, the answer streams into the card, **Ask Zera** keeps the
file in context, and **Open Claude** on Home is the only thing that ever opens an external window.

`build.sh` compiles with SwiftPM, copies `Resources/Sprites/*.png` into the bundle, renders the
app icon from the `hello` sprite (`Tools/MakeIcon.swift`), writes `Info.plist` (with the
Calendar usage strings) and ad-hoc signs. No Xcode project, no dependencies.

### Her artwork

Zera is drawn from real artwork — 60+ transparent PNG cut-outs in `Resources/Sprites`, sliced
from a generated sheet (`docs/sprite-sheet.png`). `hang_*` poses are the rope poses used at the
notch; the rest are standing poses for cards and reactions. To regenerate a sheet at a higher
resolution or add poses, use the prompt in `Resources/SPRITE_SHEET_PROMPT.md`: it asks for a
strict 6 × 5 grid, and the slicer drops the results straight into `Resources/Sprites` under the
names the app expects. If the folder is missing she falls back to a vector drawing.

## Project layout

| File | Role |
| --- | --- |
| `Sources/Zera/ZeraView.swift` | Zera herself: sprite rendering (rope, sway, cross-fades, fidgets) with a vector fallback; moods |
| `Sources/Zera/Sprites.swift` | Loads the cut-outs and finds where the rope leaves each one |
| `Sources/Zera/ZeraController.swift` | The brain: her window, bubble, hover pill, the card under her, pointer polling, greet / sleep, reactions to GitHub / Claude / reminders, quick actions |
| `Sources/Zera/NotchGeometry.swift` | Finds the notch (or fakes one) and derives her frame |
| `Sources/Zera/BuddyViews.swift` | `BuddyView` (her transparent, draggable window), `BubbleView`, `ActionPill`, `CardKind` |
| `Sources/Zera/Palette.swift` | Design tokens (`Space`, `Radius`, `Metrics`, `Typo`, `Palette`) and the shared controls (`CardButton`, `IconButton`, `PillTabs`, fields, `Toggle`) |
| `Sources/Zera/Cards.swift` | `HomeCard`, `GitHubCard`, `SettingsCard`, `ApprovalCard`, `ToastCard`, `ListRow` and the card chrome |
| `Sources/Zera/ShelfView.swift` | The Drop Files card: search, tabs, drop zone, tile grid, Summarize / Explain / Extract / Ask, drag-out |
| `Sources/Zera/ZeraAssistant.swift` | The file assistant: prompts (`ZeraPrompts`), file payloads (`FilePayload`), sessions, provider choice, settings |
| `Sources/Zera/ClaudeCLI.swift` | Finds `claude`, reads `--help` / `--version` / `auth status`, login-shell environment, cached status |
| `Sources/Zera/ClaudeProcessManager.swift` | Hidden `claude` process: pipes, streaming, cancel, timeout, cleanup |
| `Sources/Zera/ClaudeCodeOutputParser.swift` | stream-json / json / text → events; transcript builder |
| `Sources/Zera/AnthropicAPIClient.swift` | Optional Messages API provider (SSE streaming, model list) |
| `Sources/Zera/KeychainStore.swift` | The API key's only home |
| `Sources/Zera/ResultCard.swift` | The answer card: streaming text, Markdown-lite, Copy / Save Note / Ask Zera |
| `Sources/Zera/ReminderCards.swift` | `RemindersCard` (Today / Upcoming / Completed + add form) and `ReminderAlertCard` |
| `Sources/Zera/ReminderService.swift` | Reminders model & store, clock, Calendar (EventKit), break nudges |
| `Sources/Zera/GitHubService.swift` | PAT storage, polling, PR / CI / approval feed, Approve |
| `Sources/Zera/ClaudeHookService.swift` | Claude Code hook (approvals): install/uninstall, request spool, decisions |
| `Tests/ZeraTests/*` | XCTest: parser, capability parsing, argv, prompts, payloads, Markdown |
| `Sources/Zera/ItemTileView.swift` | One shelf tile: thumbnail, name, hover, drag origin |
| `Sources/Zera/ShelfStore.swift` | Shelf item model, persistence, pasteboard ingestion |
| `Sources/Zera/Thumbnails.swift` | QuickLook thumbnail cache with Finder-icon fallback |
| `Sources/Zera/Theme.swift` | Sizes and the shared `FloatingPanel` |
| `Sources/Zera/AppDelegate.swift` | Menu-bar item, menu, login item, Dock-icon drops |
| `Resources/Sprites/*.png` | Her poses |
| `Tools/MakeIcon.swift` | Renders the app icon at build time |

## Tuning

Top of `Theme.swift`: `figureHeight` (how tall she is below the menu bar), `topTuck`,
`snapDistance`, `sleepAfter`, `cardGap`, `pillLinger`. Her sway, lean and fidget timing live in
`ZeraView.swift` (`drawSprite`, `hangingFidgets`); which sprite stands in for which mood is
`spriteName(for:)`. Her lines are `helloLines` / `greetingForNow()` in `ZeraController.swift`
and the `shelfSays` calls in `ShelfView.swift`. Colours for the cards are in `Palette.swift`.

## Behaviour notes

Files on the shelf are referenced, not copied; pasted content is written to
`~/Library/Application Support/Zera/Staged/`. Nothing is ordered out from under a live drag.
Re-dropping something already on the shelf counts as a success. No Accessibility or Input
Monitoring permission is needed — pointer position is polled, there is no event tap. Everything
she knows stays on your Mac except the GitHub API calls you asked for and the file contents you
explicitly send to Claude with Summarize / Explain / Extract / Ask (nothing is sent at drop time).
Document text is never logged.

## Roadmap

- "Always allow" rules for Claude Code approvals; routing file edits through Zera
- PR summaries through the same in-app Claude path
- Several files at once; links (WebFetch) in the file assistant
- Slack / Jira / Notion notifications
- Signed & notarized release builds, Homebrew cask

## Contributing

Issues and PRs welcome. Keep her cute, keep it local, never require an API key.

## License

MIT
