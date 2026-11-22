# Daily Shelf: design

Status: built natively on branch `feature/daily-shelf` (local, not committed). The HTML prototype stays here
as the design reference. See **As built** at the end for where the app differs from the prototype.

Prototype: `index.html` in this folder. Run it with

```bash
python3 -m http.server 4190 --bind 127.0.0.1 --directory docs/design/daily-shelf
```

then open http://localhost:4190. The panel on the right is prototype-only. It drives placement, size, behaviour,
theme and the sample events: adding a PR, letting Claude sort a site, a PR status change, the 4:00 rollover and
the JSON view.

## What it is

A shelf for the day's working links: pull requests, Jira tickets, docs, meetings, the sites you keep going back
to, and short notes. It slides out from a screen edge you pick.

- **Only what you add.** Nothing is read from your browser, history, GitHub notifications or Jira. The
  existing PRs screen keeps doing discovery; the Daily Shelf only shows what you put there.
- **It files itself.** Known links (GitHub PRs, Jira, Docs, meeting links) are filed by rules. Claude files the
  rest, and your corrections teach it per site.
- **It lives for a day.** At 4:00, unpinned items move to Yesterday. Pinned items stay. Open PRs can carry over.
- **Plain JSON.** One file per day that you, scripts and Claude Code can read.

## Surface and placement

| Setting | Options | Default |
| --- | --- | --- |
| Screen edge | Left, Right, Top, Bottom | Left |
| Corner | Start, Middle, End (along the edge; Top offers left and right corners only, away from the notch) | Middle |
| Nudge from corner | 0–240 pt | 0 |
| Shape | Island rim (attached, with concave shoulders like the notch island) or Floating (12 pt gap, four rounded corners) | Island rim |
| Width | 320, 360, 420 pt | 360 |
| Min / max height | 280–640 / 400–1100 pt; the grip on the free end resizes inside these, with a small rubber band at the limits | 420 / 820 |
| Corner radius | 0–34 pt | 22 |
| Opens on | Edge hover (2 pt hot strip over the shelf's span, plus a hover delay) or Handle / hotkey only | Edge hover |
| Hover delay | 0–600 ms | 180 ms |
| Handle when hidden | A 7 × 46 pt tab on the edge | On |
| Hotkey | ⌥⌘D toggles | On |
| Display | The screen with the pointer | |

- Leaving the shelf hides it after 0.5 s. It stays open while you type, while a menu or sheet is open, while
  you resize, and when **Keep open** (the pin in the header) is on.
- Dragging a link to the edge always opens it, whatever the trigger setting. The shelf catches the drop.
- Full-screen visibility and screen-sharing hiding follow the existing Zera settings.

## Layout

```
┌──────────────────────────────────────┐
│ (Zera) Today  Fri 6 Nov     ⌕ ≡ 📌 … │  header: companion, date, counts, search, standup, keep open, more
│        25 items · 3 need you         │
│ ┌ + Paste a link or jot a note  ⌘V ┐ │  add field; search (/) reuses it
│ [All 25][PRs 7][Jira 4][Meet 2]…     │  segmented filter, scrolls with a fade
│ ┌ 18:13 Design review   Up next [Join]│  next meeting within 90 min
│ ⌄ Pull requests 7            Open 3  │
│ • Your move                          │  failing CI, changes asked, your review
│ ⊗ aurora-web #214 · 12m   [2 failing]│
│   Make the settings page work from   │  two-line titles, diff under
│   the keyboard          +212 −48     │
│ • Ready to merge / Waiting / Done    │
│ ⌄ Jira 4   (In progress → In review → To do → Done)
│ ⌄ Meetings · Docs                    │
│ ⌄ Sites 8                            │
│ • Dev tools ✦   [▲][S][⌁][L]         │  favicon tiles for places (Claude category ✦)
│ • Reference ✦   rows with title      │  rows for pages
│ ⌄ Notes                              │
│ ↺ Yesterday · 18      ✦ 8 by Claude  │  footer
└──────────────────────────────────────┘
```

- **Pull requests** are grouped by what you need to do: *Your move* (CI failing, changes asked, your review
  requested), *Ready to merge*, *Waiting on others* (checks running, in review, draft), *Done today* (merged,
  closed). Status labels and tones match the PRs screen.
- **Jira** rows show the key, summary, priority and status, ordered In progress → In review → To do → Done.
- **Sites** use Claude's categories. Places (dashboards, dev tools, design files) are favicon tiles ordered by
  how often you open them from the shelf. Pages (reference, reading) are rows with their titles.
- **Notes**: anything that isn't a link. Shell-looking notes use the monospace face. Clicking copies.
- Each row has hover actions (copy, keep every day, remove) and a context menu (open, copy, pin, *Move to…*,
  remove). Moving a site teaches the classifier that host.
- **Standup**: drafts Done / Doing / Reviewing / Ready to merge from the shelf only. *Polish with Claude* uses
  the existing Claude provider.

## Adding things

1. Drag a link from any browser to the chosen edge. The title comes from the drag pasteboard
   (`public.url-name`), so nothing is fetched to name it.
2. Paste into the add field (⌘V while the shelf is open), or type a note and press Return.
3. From Zera's Clipboard screen: *Add to Daily Shelf* (optional, later).

No browser extension, no AppleScript, no history access.

## Sorting

```
link ─▶ rules ─▶ learned hosts ─▶ Claude ─▶ "Websites"
```

- **Rules**: `github.com/{o}/{r}/pull/{n}` → PR; `*.atlassian.net/browse/KEY-1` → Jira;
  `docs.google.com`, `notion.so`, Confluence `/wiki` → Docs; Meet, Zoom, Teams → Meetings; non-URL → Note.
- **Learned hosts**: your *Move to…* choices, stored with the day files.
- **Claude**: only links no rule matched. Batched every 2 s; sends the URL and title only, never page contents
  or cookies. It uses the provider chosen in Settings → Claude (`claude -p --output-format json`, or the API
  key). It asks for `{category, shortTitle, layout: tile|row}` from a fixed list plus at most one new category.
  Off in settings means everything unmatched goes to *Websites*.
- Each item records `categorySource`: `rule`, `claude` or `user`. A user choice is never overwritten.

## Status

- **GitHub** uses the existing Keychain token (`github-token`, api.github.com only). For each PR on the shelf:
  `GET /repos/{o}/{r}/pulls/{n}`, its reviews and the head commit's check runs, mapped to the same
  `GHPullRequest` fields the PRs screen uses (CI, review, draft, merged, diff). It refreshes every 2 min while
  the shelf is visible and every 10 min otherwise, with ETags. No discovery queries.
- **Jira** (optional): site URL, email and API token in the Keychain (new account `jira-token`).
  `GET /rest/api/3/issue/{key}?fields=summary,status,priority`. Without it, the key comes from the URL and the
  title from the drag, with no status.
- **Favicons** are fetched from the site itself (`/favicon.ico`, then `<link rel="icon">`), with no
  third-party favicon service. They're cached in `~/Library/Caches/Zera/Favicons/<host>.png` for 30 days and
  fall back to a themed monogram.

## The day

- The day starts at 4:00 (configurable). At rollover, unpinned items move to that day's history file. Pinned
  items stay. Open PRs stay when *Carry open PRs into tomorrow* is on.
- *Yesterday* (footer) shows the previous day read-only, with *Bring back*. History is kept 14 days.

## Storage

`~/Library/Application Support/Zera/DailyShelf/2026-11-06.json`, plus `learned.json` (host → category).
Atomic writes, `version` field, readable by Claude Code ("what PRs am I on today?").

```json
{
  "version": 1,
  "day": "2026-11-06",
  "rollsOverAt": "04:00",
  "items": [
    {
      "id": "7F3C…",
      "kind": "pr",
      "url": "https://github.com/aurora/aurora-web/pull/214",
      "title": "Make the settings page work from the keyboard",
      "category": "Pull requests",
      "categorySource": "rule",
      "addedAt": "2026-11-06T09:12:00Z",
      "pinned": false,
      "opens": 4,
      "github": { "owner": "aurora", "repo": "aurora-web", "number": 214, "state": "open", "draft": false,
                  "ci": "failing", "failing": 2, "review": "none", "additions": 212, "deletions": 48 }
    },
    { "kind": "site", "url": "https://vercel.com/aurora/aurora-web/deployments", "title": "Vercel · aurora-web deployments",
      "category": "Dev tools", "categorySource": "claude", "opens": 9 },
    { "kind": "jira", "url": "https://aurora.atlassian.net/browse/AUR-142", "title": "Settings: full keyboard navigation",
      "jira": { "key": "AUR-142", "status": "In progress", "priority": "high" }, "pinned": true }
  ]
}
```

## Motion

| Moment | Motion | Reduce Motion |
| --- | --- | --- |
| Edge approach | Accent lip glows along the shelf's span, stronger as you get closer | Same, no fade |
| Open | Spring slide from the edge (stiffness 240, damping 23 ≈ `CASpringAnimation`), rows stagger 22 ms, Zera waves | 160 ms fade |
| Close | 230 ms ease-in slide | 140 ms fade |
| Drag over | Themed liquid rises in the shelf (accent → accentDeep tonal depth, one surface) | Static fill |
| Drop | Liquid swallows the link, then the row lands with a soft accent ring | Row appears |
| Sorting | Row shimmers *Claude is sorting…*, Zera turns blue (thinking), then the row moves into its section | No shimmer |
| Reflow | Rows and headers spring to new positions (FLIP) on status or category changes | Instant |
| Status change | Pill crossfades and pulses once; Zera celebrates (green) or worries (red) briefly | Crossfade only |
| Empty | Sleepy Zera | Static |

Native notes: one cached `CAShapeLayer` path for the rim (rebuilt only on resize or settings change),
`shadowPath` set, no per-frame blur, no SwiftUI rebuild per frame. The companion is the shared
`LivingCompanionView` on `ZeraAnimationClock` and pauses while the shelf is hidden.

## Native plan

New files, following existing patterns:

- `DailyShelfStore.swift`: day files, rollover, history, learned hosts, `changed` notification.
- `DailyShelfClassifier.swift`: rules, learned hosts, batched Claude request through the existing provider.
- `DailyShelfStatus.swift`: GitHub through `GitHubService`'s token reader; optional Jira client and its Keychain account.
- `DailyShelfFavicons.swift`: direct fetch, disk cache, monogram.
- `DailyShelfPanel.swift`: non-activating `NSPanel` (`canJoinAllSpaces`, `fullScreenAuxiliary`), the 2 pt edge
  hot strip (ignores clicks except during a drag session), placement and resize.
- `DailyShelfView.swift`: AppKit views using the theme tokens and the existing row, pill and segmented controls.
- Settings: a *Daily Shelf* section with the table above, plus *Sort with Claude*, *Day starts at* and *Jira*.
- Tests: rule parsing, rollover, carry-over, JSON round trip, classifier batching (stubbed), placement for all
  edges, corners and min/max clamps.

## Needs your call

1. **A second surface.** `AGENTS.md` says the notch island is the shared container and no parallel floating
   status panels are added. The Daily Shelf is an edge panel outside the notch. Either approve it as an
   intentional exception and record that in `AGENTS.md`, or put the same content in a notch screen instead
   (a new `CardKind` appended at the end).
2. **Jira status**: add the optional Jira token, or keep Jira as links only for now?
3. **Claude sorting**: on by default (URL and title only), or opt-in?
4. **Rollover hour**: 4:00?

## Also on this branch

Settings › Claude › **Wings while working**. The wings show when a Claude Code (or observed Codex) turn starts,
then tuck away after the chosen time: 3 s (default), 5, 10 or 30 s, *Only when Claude needs you*, or *Keep
showing*. They come back for a new turn, an approval, a finished turn or the Claude tab. Approvals are never
auto-hidden, and the countdown waits while the pointer is on the wings.

## As built

Code: `Sources/Zera/DailyShelf/`
- `DailyShelfModel.swift`: items, rules, PR status groups, the day clock, placement and outline, standup.
- `DailyShelfStore.swift`: settings, day files, rollover, learned hosts.
- `DailyShelfServices.swift`: GitHub status, Claude sorting (`ZeraAssistant.quickAnswer`, `haiku` on Claude Code), favicons.
- `DailyShelfView.swift`: rows, tiles, headers, chips, drop catcher, sheets.
- `DailyShelfPanel.swift`: content view, the edge panel, the cue handle, the controller.

Settings: **Settings › Shelf › Daily Shelf**. Tests: `swift test --filter DailyShelf`. To review the look without
running the app, render it to PNG files:

```bash
ZERA_RENDER_SCREENS=/tmp/zera-render swift test --filter DailyShelfRenderTests
```

Where the app differs from the prototype:
- The shortcut is set in Settings › Shelf with the standard recorder. It defaults to **⌃Space**, and clearing it turns it off.
  (⌥⌘D, from the prototype, is macOS's own Dock show/hide shortcut.)
- The open shelf can be **dragged by its header** to any edge or position. On release it settles on the nearest
  edge, and the edge and position are saved. The end grip sets the height between min and max, and the side grip
  sets the width (300–520 pt). Both are saved.
- **Arc** sidebar tabs carry only Arc's item id when dragged. The shelf reads that one tab's link and title from
  Arc's `StorableSidebar.json`, or asks Arc for it through AppleScript when Arc hasn't saved it yet (macOS asks once).
- Claude is sent only new, unmatched links (address and title), batched up to 12, with the category list plus the
  categories already in use and the ones you taught it.
- **Dropping the shelf** shows a dashed outline of where it will land. It picks the edge nearest the pointer,
  leaning toward the direction you dragged, and locks into a corner within 96 pt of one or into the middle near the
  center. Otherwise it keeps the exact spot. It glides there and saves the edge and position.
- **Refile and reorder by drag:** drag a site row or tile onto another category (or onto Docs) to move it; the site
  is remembered. Drag a category label or section header to reorder; the order is saved. Items dragged out of the
  shelf carry their link to other apps.
- **Pins everywhere:** every row, tile and note has a hover pin. Category labels and section headers have one too,
  and a pinned category or section keeps all its items through the reset, including ones added later.
- **Icons:** the site itself, then its parent domain (a portal under a company domain often has none of its own),
  then DuckDuckGo's icon service asked for the public domain only (Settings toggle, on by default). Failures retry
  after 6 hours.
- **Keyboard:** opening with the shortcut puts the cursor in the add field (↩ adds, ⌘V adds a copied link).
  ⇥ advances the filter tabs (All, PRs, Jira, Meet, Docs, Sites, Notes), wrapping around.
  ↓ enters the list from the add field. All four arrows move directly between actual items in display
  order, skipping every section/status title and folded items (↑/← from the first item returns to the
  field). Sites is one flat tile/row list, without Claude category headers. ⇧⇥ toggles the selected
  item's section; the hidden item anchors the fold so another ⇧⇥ restores it without selecting a title.
  Clicking a section title also toggles it. Space retains its fold shortcut; ↩ opens the selected item,
  P pins, ⌫ removes, ⌘C copies, A/N goes to the add field, and the other shortcuts stay in place. While the
  shelf has the keyboard, the footer shows keycaps for the keys that apply.
- After an unslop pass, the status color lives only in the PR pill. Status tiles, diffs and counts are quiet,
  type uses two weights on a 4 pt grid, there are no sparkles, and entrances use a single ease-out curve.
- Meetings show a **Join** button but no time or *Up next* bar, since a meeting link carries no time.
- Jira items show the key and title only. Jira status (the optional token) is not built yet.
- Size settings are fixed choices in Settings (width 320/360/420; min and max height steps). The grip sets the
  height in between.
- There is no in-panel JSON viewer. *More › Show today's file in Finder* opens the folder instead.
- The handle opens the shelf only from the pill itself, after the hover delay. The 20 pt strip around it does not.

### Local item titles

Right-click any item and choose **Rename…**. The inline Shelf editor starts with the current title;
Save or Return applies a nonempty name, and Escape/close cancels. This edits only the local label,
including site names and PR titles. The URL and GitHub PR record stay unchanged. Explicit names
are saved with the item and protected from later automatic GitHub/Claude title updates.

Right-click → **Accent color** offers Ocean, Aurora, Sunset, Mint, Gold, and Rose gradients,
with a soft background tint and gradient rim on cards, site tiles, and notes. **Default** removes
the custom accent and follows the active theme again. Selection strengthens the rim; text and
PR status labels retain their existing readable colors. The choice is saved per item locally.

The palette now has 16 presets. Lagoon, Sapphire, Lavender, Orchid, Cherry, Coral, Ember,
Citrus, Emerald, and Moonstone join the original six. Card surfaces use a three-stop wash,
a quiet upper sheen, a shaded lower edge, and a fine gradient rim. Hover lifts the tint and
rim; keyboard selection has a stronger two-point outline. Effects are static and drawn
only when the view needs display, without animations or continuous rendering.
