<p align="center"><img src="docs/banner.png" alt="Zera — your AI desktop buddy (illustration)" width="100%"></p>

<h1 align="center">Zera</h1>
<p align="center"><b>Your AI buddy in the notch.</b> A free, open-source macOS app that lives in your notch: your Mac's vitals, your Claude Code sessions, fresh downloads, tasks and timesheets, and your day. <a href="https://amsynist.github.io/zera/">amsynist.github.io/zera</a></p>

<p align="center">
  <a href="https://github.com/amsynist/zera/releases/latest"><img src="https://img.shields.io/github/v/release/amsynist/zera?label=download&color=4dbdff" alt="Latest release"></a>
  <a href="https://github.com/amsynist/zera/actions/workflows/ci.yml"><img src="https://github.com/amsynist/zera/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13+">
</p>

<p align="center">
  <a href="docs/zera-highlights.mp4"><img src="docs/zera-highlights.webp" alt="Zera in a minute: hovering her blooms the tabs and opens Home, This Mac, the Claude wings asking to run a command, a download landing in the Shelf, adding a task, the focus orb opening into the focus card, the timesheet export, pull requests, a meeting banner, themes, and the app opener" width="100%"></a><br>
  <sub>Zera in a minute, recorded from the app with sample data. <a href="docs/zera-highlights.mp4">1080p MP4</a> · <a href="docs/zera-tour.mp4">every screen (3½ min)</a></sub>
</p>

## What's new

- **Your Mac at a glance:** a vitals strip on Home (CPU, memory, GPU, Wi-Fi, battery). Tap it for **This Mac**: per-core load, a minute of network and GPU, memory by kind, battery health and cycles, and an internet speed test on demand.
- **Shelf · Fresh:** new files from Downloads, Desktop and folders you add, newest first. Tap to copy, drag straight into Slack, Mail or Finder.
- **Battery alerts:** a banner and its own sound when the battery crosses your mark, and optionally when its health drops.
- **Approvals:** your open PRs that someone approved now show up too, with who approved them.
- **Themes:** Zera, Tokyo Night, Dracula, Catppuccin, Nord, Rosé Pine and Gruvbox, or your own from a JSON file.
- **Snappier:** tabs switch in a few milliseconds, the Shelf copies pictures instantly, and drops land in the same frame.

## What it does

- **Notch island** — hover Zera and eight tabs bloom out round her rope; pick one and the notch opens into it: Home, Claude, Shelf, Clipboard, Tasks, Pull requests, Reminders, Settings.
- **Vitals** — CPU, memory, GPU, network and battery on Home; This Mac for the detail and a speed test.
- **Claude Code, live** — wings beside the notch show what each session is doing; approve its commands and reply when it's done, without the terminal.
- **Tasks and focus** — projects, a to-do list and a focus orb at the screen edge that times your work and opens into the focus card. Add with `Write docs #project 30m` or ⌥⌘T from anywhere.
- **Timesheets from commits** — link a project to its repos and your commits become done tasks, grouped by Claude. Click a day to copy it, or export to Excel, CSV or text.
- **Shelf** — drop files on the notch, tap to copy, or ask Claude to summarize, explain or extract. **Fresh** lists what just landed in your Downloads and Desktop.
- **Clipboard history**, **pull requests** (reviews, checks, approvals), **reminders and calendar** with meeting heads-ups, **battery alerts**.
- **App opener** — ⌥Space: Zera drops down with a search over your apps and commands, with ⌘K actions. Prefer a tree under the notch? Pick the classic style.
- **Themes** — Zera, Tokyo Night, Dracula, Catppuccin, Nord, Rosé Pine and Gruvbox, or your own from a JSON file ([docs/THEMES.md](docs/THEMES.md)).

No account and no API key: Claude runs through your existing Claude Code login.

## Screens

<table>
  <tr>
    <td width="50%"><img src="docs/screens/01-notch-hover.webp" alt="Hovering Zera: eight tab nodes bloom out round her rope"><br><sub><b>Hover her</b>: the tabs bloom out round her rope</sub></td>
    <td width="50%"><img src="docs/screens/04-home.webp" alt="Home: greeting, what needs you, and the vitals strip"><br><sub><b>Home</b>: what needs you, and your Mac's vitals</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screens/04b-this-mac.webp" alt="This Mac: per-core load, network, memory and battery"><br><sub><b>This Mac</b>: cores, network, memory, battery, speed test</sub></td>
    <td><img src="docs/screens/05-claude-sessions.webp" alt="Claude sessions: running, waiting on you, done"><br><sub><b>Claude</b>: every Claude Code session, live</sub></td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/screens/06b-wings-approval.webp" alt="The Claude wings beside the notch asking to run npm test, with Reject and Approve"><br><sub><b>The wings</b>: approve Claude's commands without the terminal</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screens/07b-shelf.webp" alt="The Shelf with four dropped files"><br><sub><b>Shelf</b>: drop files on the notch, tap to copy, ask Claude</sub></td>
    <td><img src="docs/screens/08-shelf-fresh.webp" alt="Shelf Fresh: new files from Downloads and Desktop"><br><sub><b>Fresh</b>: what just landed in Downloads and Desktop</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screens/09-clipboard.webp" alt="Clipboard history: text, a link, code and a colour"><br><sub><b>Clipboard</b>: everything you copied, to copy again</sub></td>
    <td><img src="docs/screens/10b-tasks-added.webp" alt="Tasks for today by project, with a new task just added"><br><sub><b>Tasks</b>: <code>Write docs #project 30m</code> and Return</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screens/12c-focus-card.webp" alt="The focus card grown out of the orb, with a timer running"><br><sub><b>Focus</b>: the orb at the screen edge opens into the focus card</sub></td>
    <td><img src="docs/screens/14-export-timesheet.webp" alt="Export: a timesheet made from commits, day by day"><br><sub><b>Export</b>: a timesheet from your commits, or Excel, CSV, text</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screens/15-pull-requests.webp" alt="Pull requests with checks and approvals"><br><sub><b>Pull requests</b>: reviews, checks, approvals</sub></td>
    <td><img src="docs/screens/15c-pr-detail.webp" alt="A pull request's page with failing checks"><br><sub><b>A PR's page</b>: reviewers and failing checks</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screens/16-reminders.webp" alt="Reminders: today's meetings and reminders"><br><sub><b>Reminders</b>: your day from every calendar</sub></td>
    <td><img src="docs/screens/17-banner-meeting.webp" alt="A meeting heads-up banner with Join call"><br><sub><b>Banners</b>: meetings, battery, water, new PRs</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screens/21-settings-appearance.webp" alt="Settings, Appearance: the theme list"><br><sub><b>Settings</b>: Appearance and seven themes</sub></td>
    <td><img src="docs/screens/22-theme-tokyo-night.webp" alt="Home in the Tokyo Night theme"><br><sub><b>Themes</b>: Tokyo Night here, or your own JSON</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screens/23-app-opener.webp" alt="The app opener: Zera holding the search with Safari found"><br><sub><b>App opener</b>: ⌥Space, type, Return</sub></td>
    <td><img src="docs/screens/25-app-opener-classic.webp" alt="The classic app opener: a tree under the notch"><br><sub><b>Classic opener</b>: a tree held under the notch</sub></td>
  </tr>
</table>

All 53 screens are in [docs/screens](docs/screens).

### Screens and clips for editing

Every screen, with Zera in it, renders from the app's own code as **transparent** stills and clips
(ProRes 4444 and HEVC with alpha), so they go onto any background in a video edit:

```bash
scripts/render-clips.sh          # → renders/zera-screens (about 18 minutes, needs ffmpeg)
```

That makes 53 stills (trimmed, and on the full 1512 × 982 pt screen) and 25 clips. Each clip shows its screen
arriving and leaving: the notch blooming and opening, every tab, the Claude wings, the Shelf, Clipboard,
adding a task, the focus orb, quick add, the timesheet export, pull requests, reminders and banners,
Settings, themes and the app opener. The folder's own README lists every file and how to use them.
`scripts/render-screen.sh` still renders quick single PNGs for reviewing a layout.

## Download

1. Grab **`Zera-<version>.dmg`** from the [latest release](https://github.com/amsynist/zera/releases/latest).
2. Open it and drag **Zera** into **Applications**.
3. Launch Zera. She appears under the notch (or in the middle of the menu bar on Macs without one).

Requires macOS 13 or newer, Apple silicon or Intel. If macOS says an unnotarized build is from an
unidentified developer, right-click Zera → **Open** → **Open** once.

## Setup

Everything is in **Settings → Integrations**:

- **Claude** — install the [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) and sign in once; Zera finds it. An Anthropic API key is optional.
- **Live progress and approvals** — one click adds small hooks to `~/.claude/settings.json`; **Remove** undoes it.
- **GitHub** — paste a fine-grained token with read access to pull requests, checks and actions.
- **Calendar** — connects through macOS Calendar, so Google, Outlook and iCloud accounts all show up.

## Privacy

No account, analytics, telemetry or update service. Everything stays on your Mac; file contents and
commit messages go to Claude only through your own Claude Code login, and only when you ask (or link a
project). Fresh reads only file names, sizes and dates, and the speed test runs only when you press it.
Tokens live in your Keychain. Details in [SECURITY.md](SECURITY.md) and
[docs/PRIVACY_DATA_MAP.md](docs/PRIVACY_DATA_MAP.md).

## Build from source

```bash
git clone https://github.com/amsynist/zera.git
cd zera
./build.sh          # → dist/Zera.app
open dist/Zera.app
swift test
scripts/render-clips.sh   # optional: every screen as transparent stills and clips
```

Needs macOS 13+ and the Xcode Command Line Tools. No Xcode project, no dependencies.

## Contributing

Issues and PRs welcome. Keep her cute, keep it local, and never require an API key. Please report
security issues privately — see [SECURITY.md](SECURITY.md).

## License and trademarks

A license will be added before the first official release; until then no license is granted beyond
viewing the source. Zera is independent and not affiliated with Anthropic, GitHub or Apple. Claude and
Claude Code are trademarks of Anthropic, PBC; GitHub of GitHub, Inc.; Apple, Mac and macOS of Apple Inc.
