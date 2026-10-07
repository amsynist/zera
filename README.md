<p align="center"><img src="docs/banner.png" alt="Zera — your AI desktop buddy (illustration)" width="100%"></p>

<h1 align="center">Zera</h1>
<p align="center"><b>Your AI buddy in the notch.</b> A free, open-source macOS app that lives in your notch: your Mac's vitals, your Claude Code sessions, fresh downloads, tasks and timesheets, and your day. <a href="https://amsynist.github.io/zera/">amsynist.github.io/zera</a></p>

<p align="center">
  <a href="https://github.com/amsynist/zera/releases/latest"><img src="https://img.shields.io/github/v/release/amsynist/zera?label=download&color=4dbdff" alt="Latest release"></a>
  <a href="https://github.com/amsynist/zera/actions/workflows/ci.yml"><img src="https://github.com/amsynist/zera/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13+">
</p>

<p align="center">
  <a href="site/assets/zera-film.mp4"><img src="docs/zera-whats-new.webp" alt="What's new in Zera: the vitals strip on Home and the This Mac page, the Shelf's Fresh tab with a download arriving, clipboard, the week's tasks, pull request approvals and a PR's page, Claude sessions, the low-battery banner, and the Excel export" width="100%"></a><br>
  <sub>What's new, recorded from the app with sample data. <a href="site/assets/zera-film.mp4">1080p MP4</a> · <a href="docs/zera-tour.mp4">the full tour</a></sub>
</p>

## What's new

- **Your Mac at a glance:** a vitals strip on Home (CPU, memory, GPU, Wi-Fi, battery). Tap it for **This Mac**: per-core load, a minute of network and GPU, memory by kind, battery health and cycles, and an internet speed test on demand.
- **Shelf · Fresh:** new files from Downloads, Desktop and folders you add, newest first. Tap to copy, drag straight into Slack, Mail or Finder.
- **Battery alerts:** a banner and its own sound when the battery crosses your mark, and optionally when its health drops.
- **Approvals:** your open PRs that someone approved now show up too, with who approved them.
- **Themes:** Zera, Tokyo Night, Dracula, Catppuccin, Nord, Rosé Pine and Gruvbox, or your own from a JSON file.
- **Snappier:** tabs switch in a few milliseconds, the Shelf copies pictures instantly, and drops land in the same frame.

## What it does

- **Notch island** — hover Zera and the notch opens into tabs: Home, Claude, Files, Clipboard, Tasks, Pull requests, Reminders, Settings.
- **Vitals** — CPU, memory, GPU, network and battery on Home; This Mac for the detail and a speed test.
- **Claude Code, live** — wings beside the notch show what each session is doing; approve its commands and reply when it's done, without the terminal.
- **Tasks and focus** — projects, a to-do list and a focus orb that times your work. Add with `Write docs #project 30m` or ⌥⌘T from anywhere.
- **Timesheets from commits** — link a project to its repos and your commits become done tasks, grouped by Claude. Click a day to copy it, or export to Excel, CSV or text.
- **Files** — drop files on the notch, tap to copy, or ask Claude to summarize, explain or extract. **Fresh** lists what just landed in your Downloads and Desktop.
- **Clipboard history**, **pull requests** (reviews, checks, approvals), **reminders and calendar** with meeting heads-ups, **battery alerts**.
- **App opener** — ⌥Space brings down a tree of your apps and commands, with ⌘K actions.

No account and no API key: Claude runs through your existing Claude Code login.

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
```

Needs macOS 13+ and the Xcode Command Line Tools. No Xcode project, no dependencies.

## Contributing

Issues and PRs welcome. Keep her cute, keep it local, and never require an API key. Please report
security issues privately — see [SECURITY.md](SECURITY.md).

## License and trademarks

A license will be added before the first official release; until then no license is granted beyond
viewing the source. Zera is independent and not affiliated with Anthropic, GitHub or Apple. Claude and
Claude Code are trademarks of Anthropic, PBC; GitHub of GitHub, Inc.; Apple, Mac and macOS of Apple Inc.
