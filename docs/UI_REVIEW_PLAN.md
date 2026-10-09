# V2 design review and shipping plan

Branch: `v2-design`. Zera is a native macOS AppKit companion in the notch for Mac vitals, Claude Code sessions and approvals, files, clipboard, tasks and focus, pull requests, reminders and calendar, and app launching. `ZeraController` owns the companion, island, and floating panels; `NotchIsland.swift` defines navigation; feature views draw each screen using manual frames in `layout()`. Build with `swift build` during iteration, run `swift test` for checks, and use `./build.sh` for the distributable app.

## Current status — 9 October 2026

**Both opener designs are approved by the user. The shared layout/typography pass now covers all main screens, following Home and Settings.** Each screen's live interaction/visual approval and shipping checks remain tracked below.

There are **8 main screens**, plus the shared companion/notch shell, the opener's **2 styles**, and auxiliary panels listed below. Settings contains **12 panes**. Auxiliary states belong to their screen's review; they do not disappear from the checklist when the main screen is finished.

| Phase | Scope | Status | What remains |
| --- | --- | --- | --- |
| 1 | V2 opener + action tree | Visual design approved | Shipping integration/display checks below |
| 2 | Classic opener | Visual design approved | Shipping integration checks |
| 3 | Companion/notch shell | Shared transition fixes implemented; visual review pending | Hover menus, badges, wings, open/switch/close and placement |
| 4.1 | Home | Current review; typography/layout refined | Visual approval, live search/actions and This Mac flows |
| 4.2 | Claude | Shared layout/type pass implemented | Live sessions, approvals, replies and wings |
| 4.3 | Shelf + file assistant | Shared layout/type pass implemented | Live files, Fresh, drag/drop, details and assistant states |
| 4.4 | Clipboard | Layout/type and overlap/memory fixes implemented | Live filters, search, preview, copy/delete and privacy flows |
| 4.5 | Tasks + focus | Shared layout/type pass implemented | Live lists, projects, mini task, orb, quick add and export |
| 4.6 | Pull requests | Shared layout/type pass implemented | Live tabs, detail, checks, approvals, menus and feedback |
| 4.7 | Reminders + calendar | Shared layout/type pass implemented | Live lists, forms, meetings, water and battery alerts |
| 4.8 | Settings | Shared typography/controls and scroll cue implemented | Live visual approval and integration checks |
| 5 | Shipping | Not started | Themes, accessibility, display sizes, integration errors and release validation |

“Performance reviewed” means the code and benchmark pass is complete; it does **not** mean that screen's visual design or every live interaction is finished. Measurements and limitations are in [PERFORMANCE_REVIEW.md](PERFORMANCE_REVIEW.md).

## Phase 1 checklist — visual design approved

### Implemented and tested

- [x] Remove the top-left Zera text and symbol.
- [x] Align search and app detail widths; refine spacing, icon sizes and arc placement.
- [x] Soften type weights and use the muted Open app gradient; latest color refinement uses neutral charcoal/slate cards and a darker primary button.
- [x] Replace the opaque full-screen paint/glow with native macOS frosted blur and a 28% neutral charcoal tint; subtle gradients live on search, detail and action cards (user-requested follow-up).
- [x] Match rounded keyboard hints across browsing and actions.
- [x] Center hover zoom and avoid restarting it on repeated tracking updates.
- [x] Implement a searchable, clickable ⌘K/⌘M action tree with arrows, Return, confirmations and Escape/query restoration.
- [x] Route opener keys at the window level after search loses focus.
- [x] Fix interrupted close/reopen and stale animation/catalog callbacks.
- [x] Replace the stop-and-adjust icon handoff: one 480 ms position/scale timeline, matching landing geometry and reversal from the visible position.
- [x] Pass 27 opener regression tests and the optional local animated capture; build and reload the release app.
- [x] Commit and push the implementation (`183524f`, followed by `8d32ef5`).

### Approval and deferred shipping verification

- [x] User approves the v2 opener as clean overall; proceed to Classic. Interrupted transitions have regression coverage; live stress checks remain in shipping.
- [ ] Complete the single-instance global shortcut check from another app.
- [ ] Complete a live pointer/keyboard pass through tabs, search, selection, menus, pin/unpin, opening apps, commands and confirmation/cancel flows.
- [ ] Check compact display, long names, empty/loading/error states and reduced motion live.
- [ ] Close any defects found in the shipping verification pass.

## Shared fixes already completed

- [x] Clipboard grid/list overlap: release inactive views, redraw removed pixels and reject stale preview callbacks.
- [x] Island outgoing-screen cleanup and rapid-switch handling.
- [x] Lazy screen creation, bounded decoded image caches and coalesced thumbnail decoding.
- [x] Skip hidden-screen rebuilds and unnecessary animation/spinner work.
- [x] Remove Sounds and Diagnostics UI-thread stalls.
- [x] Move GitHub credential work off the UI thread; protect against stale credential completion.
- [x] Review core activity parsing/pruning and screen performance; record results and remaining limits.
- [x] Run the broader regression suite: 190 tests, 13 optional tests skipped, zero failures before the latest motion refinement; that refinement separately passed all 27 opener tests and its render check.
- [ ] Run a longer live session across the finished screens and repeat memory profiling during the shipping pass.

## Current and remaining phase checklists

Finish one surface's layout, interactions and motion loop before starting the next.

### Phase 2 — Classic opener (visual design approved)

- [x] Share Classic branch-label typography with v2 tabs, including uppercase labels and measured letter spacing.
- [x] Centralize opener search/detail/button fonts; reuse global spacing and control metrics.

First pass: soften the search/detail type, reduce halo glow, reuse the muted v2 primary gradient, add ⌘M/⌘K parity, separate metadata columns, and hide Run when action search has no matches.

- [x] Review initial tree/search/action layouts; refine typography, metadata spacing and primary button.
- [x] Widen Classic by 60 points, relax row spacing and give shortcut guidance its own footer row.
- [x] Use shared rounded keycaps for Classic footer hints and action controls; fit the taller panel to standard Mac display heights.
- [x] Route Classic left/right arrows alongside up/down, and ignore stale composition in an inactive field editor; actual-window regression passes.
- [x] Pass 28 opener tests, including Classic ⌘M/⌘K, empty action search and Escape query restoration.
- [x] User approves both opener designs after the last refinements.
- [ ] Verify action menus, keyboard navigation, pin/quit and confirmation paths.
- [ ] Refine transitions and verify interrupted/reduced-motion states.

### Phase 3 — Companion and shell

- [ ] Idle mascot, hover bloom/menu, badges and search node.
- [ ] Island opening, switching, outside-click/Escape dismissal and rapid reversals.
- [ ] Live wings, minimize/restore, display edges and no-notch placement.

### Phase 4 — main screens, in order

- [ ] **Home:** attention/empty states, quick actions, search, vitals, This Mac and speed test.
- [ ] **Claude:** empty/running/waiting/done sessions; select, approve/reject, reply and wings.
- [ ] **Shelf:** empty/list/Fresh; add/drop/copy/drag; details, menus, streaming answers and errors.
- [ ] **Clipboard:** all filters, search, preview, copy, delete/clear, pin and privacy controls; revisit grid/list switching live.
- [ ] **Tasks:** Today/week/project menus, create/edit/complete, mini task, quick add, focus card, orb/pill and export.
- [ ] **Pull requests:** empty/list, filters/tabs, approval/detail/checks, review actions, menus and toast feedback.
- [ ] **Reminders/calendar:** Today/Upcoming/Completed, detail/edit forms, meeting/water/battery alerts.
- [ ] **Settings:** General, Appearance, Sounds, Clipboard, Shelf, Integrations, Shortcuts, About, Claude, GitHub, Calendar and Diagnostics.

### Settings pass

- [x] Replace Settings native popup controls with shared `ZeraSelect`.
- [x] Centralize pane title, setting label, control type and row height in the shared design tokens.
- [x] Add Appearance → Menu appearance: Zera glass / Native macOS, applied to shared dropdown and action menus.
- [x] Add custom-menu arrows/Return/Escape, keyboard focus and selected-row scrolling.
- [x] Release menu content, key handlers and first responder when closing; retain native menu callbacks safely.
- [x] Check layout bounds and row/control spacing across all twelve Settings panes.
- [x] Remove the overlay scrollbar that covered trailing controls; retain trackpad/wheel scrolling.
- [x] Show a “Scroll for more” footer with a softly pulsing arrow only when content remains below; hide it at the bottom and respect reduced motion.
- [x] Pass five Settings/dropdown regressions and the optional Appearance render; build and reload the release app.
- [ ] Complete live visual approval and integration control checks in each pane.

### Current Home pass

- [x] Reuse shared medium control/setting-label type; add a shared monospaced metric-value role.
- [x] Relax vital tiles and separate values from units; use shared gaps and corner radii.
- [x] Wrap quick actions at compact widths instead of hiding trailing actions.
- [x] Share header title/subtitle/control geometry across Home, Reminders, Claude, Shelf, Tasks, Clipboard, Settings and PRs.
- [x] Place Home search in its own full-width content row below the greeting, aligned with cards/actions; tighten the bottom inset to the shared 20-point spacing.
- [x] Distribute spare quick-action row width through shared flow layout and centre each icon/label group.
- [x] Keep busy Home content inside a bounded scroll region without an overlapping scrollbar.
- [x] Check quick-action bounds at 560/880 points and This Mac → Back restoration; inspect the local Home capture.
- [ ] User visual approval and live search, attention links, quick actions, vitals, speed test and Escape checks.

### Phase 5 — shipping

- [ ] All seven themes; small display and no-notch layouts.
- [ ] Reduced motion, accessibility, focus visibility and keyboard-only use.
- [ ] Empty/loading/error/offline/permission states and external integration flows.
- [ ] Extended open/switch/close session, memory/CPU profiling and recovery after relaunch.
- [ ] Full regression suite and distributable build; fix remaining release defects.

### Shared layout and typography pass — 9 October

- [x] Use shared medium row, chip and button fonts; migrate standard text roles in Claude, Shelf, Clipboard, Tasks, PRs, Reminders, forms and supporting cards.
- [x] Use shared detail-title/subtitle and Back/action-button placement across Claude, Shelf and Reminders.
- [x] Keep Claude/Clipboard search available on compact layouts with one shared wrapping toolbar; align filters and search vertically.
- [x] Reuse Home's wrapping action layout in Shelf suggestions and Claude quick asks; keep every action reachable and align input/footer spacing.
- [x] Relax Clipboard rows to the standard 58-point tier and shared 8-point gap.
- [x] Use the shared monospaced metric font for task/focus timers and vitals.
- [x] Check the six remaining main-screen captures, Shelf detail, export, focus card/orb and quick-add locally; no captures uploaded to CI or PRs.
- [x] Pass compact toolbar and horizontal/vertical screen-bounds checks; full suite: 200 tests, 13 optional skips, zero failures.
- [x] Verify the final detail-footer changes with 13 targeted checks and the local detail/floating-panel capture pass.
- [ ] Complete the live interaction/visual approval items for each surface above.

## Defect tracker

| Defect | Implementation status | Verification still needed |
| --- | --- | --- |
| Opener arrows/Escape stop after focus changes | Window routing plus Classic horizontal arrows and inactive-editor composition fixes; regression passes | Recheck the previously failing live Classic flow |
| Images remain behind Clipboard list after filter switch | Fixed; repeated-switch regression and local render pass | Full Clipboard live review in Phase 4.4 |
| ⌘K/⌘M icon stops then shifts to fit header | Latest correction pushed in `8d32ef5`; relayout/reversal tests and capture pass | Visual result approved; rapid live reversals remain shipping checks |
| UI test asks a real app to quit | Fixed: the ⌘Q fallback test now selects Custom Commands before dispatch | Corrected suite: 28 tests passed |
| Startup freezes waiting for Keychain | Background credential queue implemented and tested | Revisit normal startup/relaunch in shipping pass |

Update this tracker and the relevant checkbox whenever a defect is found or closed. Keep captures local and create them only when they help the current review; do not publish PNGs/GIFs to CI or PRs.

## Inventory

There are **8 main notch screens**, a hover/navigation shell, an app opener, and floating states. Settings has **12 panes**, with 8 navigation entries and 4 other detail panes. Review states below are interactions within those surfaces, not new top-level screens.

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

## Shared design system

Use the existing `Palette.swift` tokens (`Typo`, `Space`, `Radius`, `Metrics`) for app-wide type, spacing and controls. Use `OpenerLook` for opener-specific colors, dimensions and font roles. Both opener styles share branch labels (`Typo.branchLabel` and `branchKern`) and button typography; Classic has explicit search/detail font overrides for its larger panel. Measure text with the same font and tracking used to draw it.

As each screen enters review, replace duplicated standard values with these roles. Keep geometry that defines a particular screen local; name and document deliberate overrides. Avoid changing global values simply to fix one screen, and check both users of any shared component. Migration across the remaining screens is part of their phase checklist, not complete yet.

## Done criteria for each surface

- No clipping, overlap, or jumps at the island size and on a small display. Headers, scroll regions, menus, and detail panels stay within visible bounds.
- Shared font/spacing/control tokens are used, with deliberate screen-specific overrides documented.
- Typography, spacing, icon weights, hover/pressed/focus states, contrast, badges, and empty/loading/error states are consistent across themes.
- Every visible button, row, menu, tab, shortcut, and close/back action works by pointer and, where applicable, keyboard. Focus is visible and targets remain reachable.
- Search, filters, selection, details, timers, and dialogs recover sensibly after tab switches, dismissal, and relaunch. External actions show useful feedback.
- Transitions settle cleanly and respect reduced motion. Relevant tests pass; the running app has been checked after the fix.

## Phases

1. **Orbit app opener (visual design approved):** Apply the compact refinement spec: no top-left branding, matching 720-point search/detail widths, a 52-point search bar, 36-point neutral tabs, consistent rounded app containers (80/64/56 points), shallow arc, and a 76-point detail bar. The bar uses one metadata line and 32-point Pin → More → Open controls. Shortcut badges appear on the selected item or while holding Command; ⌘1–⌘9 follow the visible left-to-right order. Footer hints cover arrows, Tab, Enter, ⌘M and Escape, with rounded keycaps in both browsing and action states. ⌘K remains an alias for ⌘M. The primary button uses a muted indigo gradient. Hover grows 4% from the icon centre over 200 ms; reduced motion skips the transition. ⌘K opens the searchable action tree with clickable rows, arrow/Enter selection, and Escape/query restoration. Native type, colors and dimensions are defined in AppKit, with shared opener style values. On-demand local captures cover default, compact, and compact actions; 27 opener tests cover layout bounds, navigation, shortcut mapping, window-level keyboard routing after focus changes, ⌘M/Escape restoration, centered hover and interrupted action transitions. The selected icon follows a curved path to the action header, with movement and scale sharing one 480 ms timeline and an identical landing frame. Options unfold beneath it; Escape reverses from the current visible position. AppKit keeps ownership of the layer anchor so the handoff does not readjust the icon. An optional local GIF preview uses `ZERA_RENDER_OPENER_MOTION=1`. The user has approved the visual result; global shortcuts and the full live integration pass remain shipping checks.
2. **Classic app opener (visual design approved):** Review its tree layout, search, action menus, keyboard navigation, pin/quit paths, and transitions with the same loop.
3. **Shell:** Companion idle/hover, bloom, badges, island open/switch/dismiss, search node, wings placement. This affects every screen.
4. **Main screens, one at a time:** Home → Claude → Shelf → Clipboard → Tasks and mini task/focus orb → Pull requests → Reminders → Settings. Finish each live interaction pass before moving on.
5. **Shipping pass:** All seven themes, small display/no-notch, reduced motion, accessibility, empty/error/permission states, full tests, and distributable build.

Record a defect here with the surface, exact action, and observed result. Keep fixes local unless the same cause affects a shared component.
