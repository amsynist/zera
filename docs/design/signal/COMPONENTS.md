# Signal interface: component catalog

The Signal look carries Ghostty X's interface into Zera: the notch island is a session rail and a
focused pane, wired by one lit trace, set in one monospaced face on tinted, blurred glass. The
visual reference is `index.html` in this folder (open it in a browser; ↑↓ switches screens).

**Rule: before drawing anything, look here.** If a piece exists, use it. If you need a variant, add a
parameter to the existing piece instead of a second copy. If you add a new reusable piece, add a row
to the tables below in the same change.

Everything is local work on the `feature/daily-shelf` branch; nothing here is committed.

## Tokens

| Token | Where | Notes |
| --- | --- | --- |
| Colours | `ZeraTheme.swift` → `BuiltInThemes.signal` (default, first in `all`) | Accent `#7BE1C2` is the signal colour. Status colours only with a word or icon. |
| Item colours | `Signal.itemColor(i)` in `Signal/SignalChrome.swift` | Ghostty X tab order: mint, violet, rose, blue, amber, lime. For sessions, projects, calendars, sites. |
| Faint ink | `Signal.faint` | Decoration only (labels, sizes, rulers). Never for text a person must read. |
| Type | `ZFont.ui / mono / digits` in `Signal/SignalFont.swift`; named roles in `Typo` (`Palette.swift`) | JetBrains Mono NL, bundled. `ui` scales ×0.88 so layouts keep their widths. Never call `NSFont.systemFont` directly. |
| Section labels | `Typo.sectionText(_:)` | Upper case, tracked 1.6. `SignalDraw.label(_:count:)` for drawn labels with a count. |
| Radii | `Radius` (`Palette.swift`) | chip 5 · button 7 · row 9 · card/pane 10 · island 22 (`Isle.corner`). |
| Heights | `Metrics`, `RowTier` | Unchanged from v2 so screen bodies keep their origin. |
| Motion | `Motion` | Every animation checks `Motion.reduced`. |

## Surfaces

| Piece | File | Use for |
| --- | --- | --- |
| `GlassSettings` | `Signal/SignalGlass.swift` | Background opacity (0.3–1) and blur (0–100), like Ghostty's `background-opacity` / `background-blur`. Reduce Transparency forces solid. Post-change notification: `GlassSettings.changed`. |
| `SignalGlassView` | `Signal/SignalGlass.swift` | Any floating surface: blurred desktop + theme tint, shaped by `shape` / `setPath`, optional black notch band (`bandHeight`). `init(frame:flipped:)` for unflipped owners. Never takes clicks. |
| `SignalLayerView` | `Signal/SignalGlass.swift` | Holds loose Core Animation layers at a fixed place among sibling views. **Always use it when layers must sit above a subview**: AppKit draws a view's subview layers above its own loose sublayers, which is why the island's light, liquid, pane and trace live in `IslandView.chrome`, and the wings' energy in `LiveActivityView.fx`. |
| `OpenerGlass` | `AppOpener.swift` | Rounded glass windows (app opener, focus card, quick add, export). Already contains a `SignalGlassView`; reuse it rather than adding another. |
| Island glass | `NotchIsland.swift` (`IslandView.glass`) | The island body; its mask morphs with the island path in `applyShape`. |
| Wing glass | `ActivityPill.swift` (`LiveActivityView.glass` + `WingFace`) | Wings keep their pill-and-tendril outline (`LiveActivityView.wing`); `WingFace` paints above the blur. |
| Shelf glass | `DailyShelf/DailyShelfPanel.swift` (`DailyShelfRootView.glass`) | Clipped to the shelf outline. |

## Chrome

| Piece | File | Use for |
| --- | --- | --- |
| `SignalPaneLayer` | `Signal/SignalChrome.swift` | The focused-pane frame: hairline, glow, corner brackets, port; `sweep()` once on focus, `snapBrackets()` on open. The island draws one around every open screen; screens do not draw their own. |
| `SignalTraceLayer` | `Signal/SignalChrome.swift` | Lit line + travelling pulse. `route(from:tab:pane:side:)` gives the Zera → tab → gutter → port path. `setRunning(false)` whenever hidden. |
| `SignalDraw.indexTile` | `Signal/SignalChrome.swift` | Numbered/lettered tile ("01", "C1", "214"), tinted or filled. PR numbers, session ids, monograms. |
| `SignalDraw.keycap` | `Signal/SignalChrome.swift` | Key hints ("⌘K", "esc"). Footers and status lines. |
| `SignalDraw.brackets` | `Signal/SignalChrome.swift` | Corner brackets round a focused input block or selected card. |
| `SignalInputView` | `Signal/SignalChrome.swift` | `inputBlock` as a view, for view-built layouts (the opener's search). `caret` adds the lit `>`. |
| `SignalDraw.dot` | `Signal/SignalChrome.swift` | Status dot, optional ring for "running". |
| Rail tiles | `NotchIsland.swift` (`IslandTab`, `IslandTabIndicator`) | Squared tiles with a hairline; the open screen's tile is filled in the signal colour by the gliding indicator. |
| Zera | `CompanionGlyph.swift` | Signal core: dark glass body, rim and cursor-block eyes in the mood colour (`CompanionGlyph.tint(for:)`). Shape, hands and gestures unchanged. Her colour eases (`LivingCompanionView.shownTint`); browsing tabs (`noticeSelection`) only lifts attention and nods once per pass, never changes her expression, so nothing snaps. |
| Edge light | `EdgeLight.swift` (`EdgeLightStyle.signal`, default) | Hairline + tight glow + pulse; Glitch adds a short tear. |

## Controls (all in `Palette.swift` unless noted)

| Control | Signal treatment |
| --- | --- |
| `CardButton` | `.primary`: signal wash + lit hairline. `.secondary`: surface + border. Status styles tinted. |
| `Palette.drawSelected`, `selectedFill/Edge` | Signal wash + accent hairline (chips, rows, nav). |
| `Palette.drawSegmentIndicator` | Gradient wash (24 % → 7 %) + hairline + soft glow (segments, bloomed tiles). |
| `Toggle` | Squared track; on = signal wash, glowing knob. |
| `SearchBox`, `ThemedField` | Radius 8; field colour from the theme. |
| `IconTile` | Index-tile look: 12 % wash + 30 % hairline in its colour. |
| `IconButton` | Rounded-square hover. |
| `drawBadge` | Squared count chip. |

## Screens: status

Update this table as each pass lands. "Shell" means the shared pieces above already apply (glass,
pane frame, trace, type, controls); "Signal pass" means the screen-specific layout from the design.

| Screen | Files | Shell | Signal pass |
| --- | --- | --- | --- |
| Notch, hover bar, banners | `NotchIsland.swift`, `HoverDeck.swift`, `Cards.swift` (ToastCard), `BannerCountdown.swift` | done | status line (● LIVE · screen · ⌘, esc · clock) done; to do: deck tiles as index tiles, countdown as 2 pt bar |
| Wings | `ActivityPill.swift` | done | done (shape kept, glass added) |
| Edge light | `EdgeLight.swift`, `NotchLight.swift` | done | done (Signal style); to do: corner brackets for Whole screen |
| Home | `Cards.swift` (HomeCard), `VitalsUI.swift` | done | to do: input block, telemetry tiles |
| Agents | `AgentsDashboard.swift`, `AgentOverview.swift`, `ClaudeSessionsView.swift` | done | to do: session index tiles, folded step blocks |
| Pull requests | `GitHubCard.swift`, `GitHubComponents.swift` | done | done (PR number index tiles, tinted status chips) |
| Alerts | `AlertsView.swift` | done | done (log-tail rows: HH:mm stamp + WAIT/FAIL/WARN/DONE/INFO level) |
| Clipboard | `ClipboardView.swift` | done | to do: kind tiles (keys stay in the screen footer; status line shows only ⌘, / esc) |
| Shelf / phone transfer | `DropFilesView.swift`, `ResultCard.swift`, `Androp/PhoneLiquid.swift` | done | to do: dashed drop row, answer block |
| Tasks / export | `TasksUI.swift` | done | input block done; to do: parsed chips, mono table |
| Reminders | `RemindersView.swift`, `ReminderComponents.swift` | done | to do: time column rule |
| Teleprompter | `Teleprompter.swift` | done | to do: line numbers, hairline reading band |
| Focus | `FocusView.swift`, `TasksUI.swift` (FocusRing) | done | done (60-tick bezel, input block) |
| Settings | `Cards.swift` (SettingsCard) | done | Glass + font rows added; to do: numbered pane rail |
| App Shortcuts | `AppShortcutsView.swift` | done | to do |
| Daily Shelf | `DailyShelf/*View.swift`, `*Panel.swift` | done (glass, lit edge) | PR index tiles done; to do: status foot |
| Focus orb / card / quick add | `TasksUI.swift` | done (OpenerGlass) | quick add input block done; to do: orb tick bezel |
| App opener | `AppOpener.swift`, `OpenerTree.swift`, `OpenerOrbit.swift` | done: three looks. Minimal (centred palette, `TreeOpenerView.minimal`, design `opener-minimal.html`): bracketed `>` search, branch tabs (`OpenerTabs`), ⌘1–6 index tiles on rows (`TreeRowView.index`), one-line facts strip, `OpenerFooter.liveTitle` status line. Tree (classic): signal-core Zera on a lit line, pane frame + brackets round the card, square root node, `SignalInputView` search, rows with a lit left bar, keycap footer, accent main button | to do: palette search line |

## Checks

Local runner (Mac): `bash .rea/signal-runner.sh` watches `.rea/signal-ci/request` (two lines: an id, then
`build`, `test`, `test:<Filter>`, `render` or `app`) and writes `<id>.log` and `<id>.status`. It runs nothing
else and never touches git. Last verified: 438 tests, 0 failures; renders reviewed; `./build.sh` signed build.

- Syntax, from the repo: the tree-sitter check used during the redesign (`python3 parsecheck.py Sources`).
- On the Mac: `./build.sh && open dist/Zera.app`, `swift test`.
- Look: `ZERA_RENDER_SCREENS=$PWD/.rea/render swift test --filter ScreenRenderTests` (and `DailyShelfRenderTests`), then compare with `index.html`.
- A full copy of the source from before the redesign is in `.rea/backups/` (see `.rea/backups/LATEST_SIGNAL`).
