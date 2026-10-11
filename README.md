<p align="center"><img src="docs/banner.png" alt="Zera — your AI desktop buddy (illustration)" width="100%"></p>

<h1 align="center">Zera</h1>
<p align="center"><b>Your AI buddy in the notch.</b> A free, open-source macOS app that lives in your notch: your Mac's vitals, your Claude Code sessions, fresh downloads, tasks and timesheets, and your day. <a href="https://zera.pravincodes.in/">zera.pravincodes.in</a></p>

<p align="center">
  <a href="https://github.com/amsynist/zera/releases/latest"><img src="https://img.shields.io/github/v/release/amsynist/zera?label=download&color=4dbdff" alt="Latest release"></a>
  <a href="https://github.com/amsynist/zera/actions/workflows/ci.yml"><img src="https://github.com/amsynist/zera/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13+">
</p>

<p align="center">
  <a href="site/assets/zera-film.mp4"><img src="docs/zera-film.webp" alt="Zera in action: hovering her blooms the tabs, approving a Claude Code command from the notch, dropping a file on the Shelf, adding a task from the focus orb, and choosing an app on the ⌥Space arc" width="100%"></a><br>
  <sub>▶ <a href="site/assets/zera-film.mp4">Watch the 40-second film</a> (with sound)</sub>
</p>

## What's new

- **Claude plan usage:** one compact card on Home shows your 5-hour and weekly limits, with slim fluid bars that fill as usage rises and change color near the limit. Percentages and reset times stay visible. A gauge badge keeps the same readings in Claude sessions.
- **Agent timelines:** follow each Claude Code agent's task, live steps and result from its session's **Agents** tab. Background agents keep their own lifecycle when the main reply finishes.
- **Optional Dock icon:** turn off **Settings → General → Show in the Dock** to keep Zera at the notch and in the menu bar.

- **A buddy with personality:** Zera follows your cursor with live eyes, blinks, breathes and reacts to hover and taps. Four quick taps earn a playful huff.
- **Water breaks · Splash:** a glass pops up beside your cursor and Zera jumps from the notch into it with a splash. Answer **Drank** or **10 min**, and she jumps back up. After each sip a small glass under the notch shows today's count, and your week makes a shareable card. [Try the interactive preview](https://zera.pravincodes.in/#water).

- **Your Mac at a glance:** a vitals strip on Home (CPU, memory, GPU, Wi-Fi, battery). Tap it for **This Mac**: per-core load, a minute of network and GPU, memory by kind, battery health and cycles, and an internet speed test on demand.
- **Shelf · Fresh:** new files from Downloads, Desktop and folders you add, newest first. Tap to copy, drag straight into Slack, Mail or Finder.
- **Battery alerts:** a banner and its own sound when the battery crosses your mark, and optionally when its health drops. Plug in and the warning goes away, replaced by a short **Charging** banner with the time to full (Settings › General can turn that off).
- **Approvals:** your open PRs that someone approved now show up too, with who approved them.
- **Themes:** Zera, Tokyo Night, Dracula, Catppuccin, Nord, Rosé Pine and Gruvbox, or your own from a JSON file.
- **Snappier:** tabs switch in a few milliseconds, the Shelf copies pictures instantly, and drops land in the same frame.

## What it does

- **Notch island** — hover Zera to open eight destinations as an **Arc** or a **Tiles** grid (Settings → General → Hover menu); pick one and the notch opens into it: Home, Claude, Shelf, Clipboard, Tasks, Pull requests, Reminders, Settings.
- **Vitals** — CPU, memory, GPU, network and battery on Home; This Mac for the detail and a speed test.
- **Claude Code, live** — wings beside the notch show what each session is doing; approve its commands and reply when it's done, without the terminal. Follow agents individually and see your plan usage on Home or in Claude sessions.
- **Tasks and focus** — projects, a to-do list and a focus orb at the screen edge that times your work and opens into the focus card. Add with `Write docs #project 30m` or ⌥⌘T from anywhere.
- **Timesheets from commits** — link a project to its repos and your commits become done tasks, grouped by Claude. Click a day to copy it, or export to Excel, CSV or text.
- **Shelf** — drop files on the notch, drag them back out into any app, tap to copy, or ask Claude to summarize, explain or extract. **Fresh** lists what just landed in your Downloads and Desktop.
- **Clipboard history**, **pull requests** (reviews, checks, approvals), **reminders and calendar** with meeting heads-ups, **battery alerts**.
- **Playful hydration reminders** — choose your interval and active hours; when it's time, a glass pops up beside your cursor and Zera jumps into it until you answer.
- **App opener** — ⌥Space: Zera drops down with your usual apps on an arc. Arrow to one and press Return, or type to search apps and commands, with ⌘K actions. Prefer a tree under the notch? Pick the classic style.
- **Themes** — Zera, Tokyo Night, Dracula, Catppuccin, Nord, Rosé Pine and Gruvbox, or your own from a JSON file ([docs/THEMES.md](docs/THEMES.md)).

No account and no API key: Claude runs through your existing Claude Code login.

## Download

1. Grab **`Zera-<version>.dmg`** from [zera.pravincodes.in](https://zera.pravincodes.in/) or the [latest release](https://github.com/amsynist/zera/releases/latest).
2. Open the DMG and drag **Zera** onto the **Applications** shortcut. This installs it at `/Applications/Zera.app`.
3. Open **Finder → Applications → Zera**, then eject the DMG. She appears under the notch (or in the middle of the menu bar on Macs without one).

Requires macOS 13 or newer, Apple silicon or Intel. Claude Code is optional for installation; connect it later for Claude features.

### If macOS blocks the first launch

The current release is not notarized. After trying to open Zera, go to **System Settings → Privacy & Security**, scroll to **Security**, and choose **Open Anyway** beside Zera. Authenticate if asked, then confirm **Open**. macOS remembers this exception for that copy. See [Apple's first-launch guide](https://support.apple.com/en-us/102445).

<details>
<summary>Optional Terminal method for the official download</summary>

After moving Zera to Applications, open **Terminal** and paste:

```sh
xattr -dr com.apple.quarantine "/Applications/Zera.app"
open "/Applications/Zera.app"
```

This removes quarantine from **Zera only**; it does not sign or notarize the app. Use it only for a copy downloaded from this repository or the official site. If macOS reports malware or a damaged app, download a fresh copy and report the issue rather than bypassing that warning.

</details>

[Full install, update and uninstall guide](docs/INSTALL.txt).

## Setup

Everything is in **Settings → Integrations**:

- **Claude** — install the [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) and sign in once; Zera finds it. An Anthropic API key is optional.
- **Live progress and approvals** — one click adds small hooks to `~/.claude/settings.json`; **Remove** undoes it. Enable **Follow each agent on its own** for separate agent timelines.
- **Plan usage** — in the Claude integration, choose **Track usage**, then **Show on Home** and/or **Show in Claude sessions**. Available for Claude Code Pro and Max plan readings.
- **GitHub** — paste a fine-grained token with read access to pull requests, checks and actions.
- **Calendar** — connects through macOS Calendar, so Google, Outlook and iCloud accounts all show up.

## Claude plan usage

Enable **Settings → Integrations → Claude → Track usage**. Claude Code supplies the 5-hour and weekly plan readings after a reply; Zera displays them without making an extra API request.

- **Home:** one card matches the Mac vitals and shows **5 hours** and **This week**, each with **percentage used**, a slim fluid bar, and **time until reset**. Each bar fills with usage and clears when its window resets; its color changes as you approach the limit. Motion respects macOS Reduce Motion.
- **Claude sessions:** a gauge badge shows the same plan readings inside the header, without changing the session list's spacing. This is plan usage, not a session's task progress.
- **Freshness:** hover the usage card or gauge badge for the last reading time. Readings update after Claude replies, not continuously; the card shows a waiting label until the first reading arrives.

Tracking installs a status-line wrapper in `~/.claude/settings.json`. Your existing status-line command continues to run and is restored by **Stop tracking usage**. Zera keeps the percentages and reset times locally and leaves your Claude login alone. A project that overrides the status line won't send readings to Zera.

## Water breaks with Zera

In **Reminders**, open the **Add Event ▾** menu and choose **Hydration**. Pick an interval and your active hours, then create the reminder.

When it's time, a glass of water pops up just beside your cursor (never under it, so your clicks still land). At the same moment Zera lets go of her rope, flips through the air from the notch and lands in the glass with a splash. She waves from the water, and a slim bar beside her shows **Water break** with two answers:

- **Drank** — the water goes down as she drinks with you, then she jumps back up to her rope. The reminder is marked done.
- **10 min** — she jumps back up and the reminder comes back in ten minutes.
- No answer for 30 seconds — she heads home and leaves a small drop under the notch. Click it whenever you're ready and she comes back down.

After each sip, a tiny glass shows under the notch for a few seconds with today's water, like **5/8**: glasses you've had against the water reminders scheduled for today. It also shows beside the waiting drop, and stays hidden the rest of the time. Click it, or choose **Water this week…** from the Zera menu-bar icon, for your week: seven glasses side by side with your total and streak. **Save image** puts a 1080 × 1350 card in Downloads, ready to share. On Fridays, or the day you reach a 7-day streak, Zera mentions it once.

If Zera is hidden (a full-screen app, or she's turned off), only the drop under the notch appears. The visit never takes focus or clicks anything in other apps; only its two buttons take clicks. Reduce Motion skips the jump and the splash. Reminder data stays on your Mac.

[Try the water-break preview on the website](https://zera.pravincodes.in/#water).

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

Issues and pull requests are welcome — integrations, expressions, sounds, accessibility improvements and bug fixes. See [CONTRIBUTING.md](CONTRIBUTING.md). Please report security issues privately through [SECURITY.md](SECURITY.md).

## Credits

Created by [amsynist](https://github.com/amsynist). Thanks to everyone who has contributed — see [contributors](https://github.com/amsynist/zera/graphs/contributors).

Zera is independent and not affiliated with Anthropic, GitHub or Apple. Claude and Claude Code are
trademarks of Anthropic, PBC; GitHub of GitHub, Inc.; Apple, Mac and macOS of Apple Inc.

## License

- **Code:** [MIT](LICENSE) — use it, fork it, learn from it; keep the copyright and license notices.
- **Zera name, character, icons, original artwork, sounds and media:** © 2026 amsynist, all rights reserved — see [LICENSE-ASSETS.md](LICENSE-ASSETS.md). Shipping your own fork? Give it your own name and creative assets.

**If Zera makes your day easier, a ⭐ helps.**

[Website](https://zera.pravincodes.in/) · [Privacy](docs/PRIVACY_DATA_MAP.md) · [Support](https://github.com/amsynist/zera/issues)
