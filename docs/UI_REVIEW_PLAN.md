# V2 design review and shipping plan

Branch: `v2-design`. Zera is a native macOS AppKit companion in the notch for Mac vitals, Claude Code sessions and approvals, files, clipboard, tasks and focus, pull requests, reminders and calendar, and app launching. `ZeraController` owns the companion, island, and floating panels; `NotchIsland.swift` defines navigation; feature views draw each screen using manual frames in `layout()`. Build with `swift build` during iteration, run `swift test` for checks, and use `./build.sh` for the distributable app.

## Inventory

There are **8 main notch screens**, a hover/navigation shell, an app opener, and floating states. Settings has **12 panes**: 7 top-level and 5 detail panes. Review states below are interactions within those surfaces, not new top-level screens.

| Order | Surface | Live states and actions to review |
| --- | --- | --- |
| 0 | Companion and notch shell | Idle, hover bloom, badges, search, open/switch/close island, click outside, no-notch placement, live wings |
| 1 | Home | Attention/empty, quick actions, search, vitals, This Mac, speed test |
| 2 | Claude | Empty/running/waiting/done, select session, approve/reject, reply, minimize/restore wings |
| 3 | Shelf and file assistant | Empty/list/Fresh, add/drop/copy/drag, details, file actions, streaming answer, errors |
| 4 | Clipboard | Empty/history, search/filter, preview, copy, delete/clear, privacy controls |
| 5 | Tasks and focus | Today/week, project menu, create/edit/complete, mini task/quick add, focus card, orb/pill, export |
| 6 | Pull requests | Empty/list, tabs/filters, approvals, PR detail, checks/review actions, toast |
| 7 | Reminders and calendar | Today/Upcoming/Completed, item detail, forms, meeting/water/battery banners |
| 8 | Settings | General, Sounds, Clipboard, Appearance, Integrations, Shortcuts, About; Claude, GitHub, Calendar, Shelf, Diagnostics |
| 9 | App opener | Open/close, search, command/app results, hover and keyboard selection, action menus, classic tree, pin/quit |

## Live review loop

1. Run the current app on this Mac. After a code change, rebuild and relaunch it, then return to the same UI state. Inspect the actual window and use the mouse and keyboard to try every visible action. Avoid saving screenshots of personal Shelf, clipboard, calendar, or GitHub data.
2. Fix one observed issue at a time in its view or shared component. Revisit the same state immediately, then check adjacent states that use the changed layout or control.
3. Use an isolated still capture **only when useful** for layout comparison: `./scripts/render-screen.sh 07-tasks` (or another state name in `ScreenRenderTests.swift`). It uses fictional sample data and saves the PNG locally under `.build/ui-review/`. The existing render test can generate all sample states on demand, but no PR or CI job generates or publishes them.
4. Run the relevant layout/navigation tests after a screen change. Run `swift test` and `./build.sh` before shipping.

The real app is the source of truth for hover, clicks, keyboard focus, scroll, drag, motion, and permission flows. A still render is a diagnostic aid, not a completion requirement.

## Done criteria for each surface

- No clipping, overlap, or jumps at the island size and on a small display. Headers, scroll regions, menus, and detail panels stay within visible bounds.
- Typography, spacing, icon weights, hover/pressed/focus states, contrast, badges, and empty/loading/error states are consistent across themes.
- Every visible button, row, menu, tab, shortcut, and close/back action works by pointer and, where applicable, keyboard. Focus is visible and targets remain reachable.
- Search, filters, selection, details, timers, and dialogs recover sensibly after tab switches, dismissal, and relaunch. External actions show useful feedback.
- Transitions settle cleanly and respect reduced motion. Relevant tests pass; the running app has been checked after the fix.

## Phases

1. **Orbit app opener (current pass):** Search and results, the action ring, hover and keyboard selection, pin/quit paths, spacing, and entrance/exit motion. The design places larger icons on one shared arc, with clickable app names and shortcut badges below them, an app detail/action bar using Zera's existing glass controls, and one keyboard guidance line. Arrow keys browse during search. The native build and on-demand captures cover populated default, compact, actions, and three-result search states. The global shortcut still needs a hands-on check because automated keystrokes do not reach its macOS hotkey handler.
2. **Classic app opener (next):** Review its tree layout, search, action menus, keyboard navigation, pin/quit paths, and transitions with the same loop.
3. **Shell:** Companion idle/hover, bloom, badges, island open/switch/dismiss, search node, wings placement. This affects every screen.
4. **Main screens, one at a time:** Home → Claude → Shelf → Clipboard → Tasks and mini task/focus orb → Pull requests → Reminders → Settings. Finish each live interaction pass before moving on.
5. **Shipping pass:** All seven themes, small display/no-notch, reduced motion, accessibility, empty/error/permission states, full tests, and distributable build.

Record a defect here with the surface, exact action, and observed result. Keep fixes local unless the same cause affects a shared component.
