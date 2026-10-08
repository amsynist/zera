# Performance and lifecycle review — v2-design

Reviewed on 9 October 2026 on this Mac. Scope: shared app/window lifecycle, all eight main screens, all twelve Settings panes, both opener styles, and auxiliary task, assistant, reminder and vitals surfaces. The visual redesign remains focused on the v2 opener; this review does not certify the later screen-by-screen design phases as complete.

## Bugs fixed

- Clipboard Images → All/Text retained inactive tile and row arrays. Switching now detaches and releases the inactive representation and invalidates the document backing store. A local capture after ten grid/list cycles shows no stale images behind the list. Preview images use bounded asynchronous thumbnails and clear on exit; late results cannot overwrite a different detail item.
- Opener keyboard handling depended on the search field remaining first responder. The opener now routes its commands at the window level, preserving ordinary text input and marked-text composition. Arrow keys, Tab, Return, ⌘K/⌘M and Escape work after a button takes focus. Repeated Escape can immediately dismiss an exiting panel.
- Closing depended on a Core Animation completion that could be interrupted. Dismissal now has a bounded deadline and a presentation generation. Rapid reopen cannot be hidden by an older close or receive an older catalog refresh/launch completion. Hidden opener content detaches from its panel.
- Island navigation could retain outgoing screens and their backing layers, including transitions requested without animation. Instant switches detach immediately. Animated cleanup is bounded and checks the outgoing animation identity, including rapid A → B → A → C.
- Repeated layout restarted the tab indicator spring at the same target. It now settles without restarting. Repeated hover tracking likewise avoids restarting the icon zoom.
- ⌘K previously replaced the arc with a single panel fade. The selected icon now follows a curved path to the action header; the search and mascot shift together, options unfold in order, and returning reverses the movement. Temporary icons are removed on interruption and completion. Reduced motion changes state immediately.

## Memory and shared services

| Area | Change |
| --- | --- |
| Screen creation | Removed eager construction of hidden main screens and the unused extra opener view. Cached screens and opener styles are created on demand. |
| Finder/app icons | Keep one 8-bit sRGB Retina bitmap at the displayed size instead of all Finder representations. Resolve opener icons only for visible arc items. |
| Image caches | App icons: 8 MiB/128 entries; QuickLook: 8 MiB/200; Clipboard: 16 MiB/100; avatars: 8 MiB/128. Charge actual decoded pixel cost. NSCache limits are eviction targets, not hard process-memory caps. |
| Clipboard decoding | Serial decode queue, autorelease pools and coalesced requests prevent parallel duplicate image decodes. |
| Sounds | Prepare only requested sounds, on a background queue. Reuse prepared players; drop stale requests rather than playing delayed sounds. Opening Sounds settings no longer initializes every audio file. |
| GitHub credentials | A live startup sample showed `SecItemCopyMatching` blocking the main thread. Initial reads/migration, saves and deletes now use an ordered background queue. Late reads cannot overwrite newer connection state, and failed migration preserves the old file. |
| Diagnostics | Read cached shell information without waiting for login-shell discovery on the UI thread. Background CLI environment resolution still works. |
| Claude activity | Consume newline batches with a forward cursor instead of repeatedly copying the remaining tail. Preserve partial final lines and prune expired sessions even without new events. |
| Claude approvals | Bound the remembered request IDs to request files still on disk. |

## Screen review

Timings below are from the debug performance fixture, in milliseconds. “First show” excludes construction; “switch” averages five subsequent shows. These are measurements on this Mac, not universal latency guarantees.

| Main screen | Create / first show / switch | Findings and changes |
| --- | --- | --- |
| Home | 5.4 / 3.6 / 2.8 | Skip service-driven UI rebuilds while detached/hidden; refresh on show. Hidden vitals update values without starting animation timers. |
| Claude | 4.8 / 2.3 / 0.5 | Skip hidden session rebuilds and per-second UI updates; services continue processing events. |
| Shelf | 17.3 / 12.6 / 7.6 | Skip hidden UI rebuilds while retaining assistant result/state updates. Bounded Finder and QuickLook images. |
| Clipboard | 180.0 / 21.4 / 3.8 | Fixed grid/list retention and overlapping backing pixels; bounded decode and preview memory. Cold creation still builds 200 native rows in this fixture. |
| Tasks | 1.5 / 7.0 / 1.5 | Skip hidden store rebuilds; stop sync spinner on detachment and restart on attachment. Fix shared selection spring restart. |
| Pull requests | 1.9 / 0.6 / 0.3 | Skip hidden notification rebuilds; bounded decoded avatar cache and failed URL history. |
| Reminders | 1.2 / 3.2 / 0.6 | Skip hidden notification/ticker UI rebuilds; refresh on show. |
| Settings | 13.1 / 4.0 / 3.2 | Rebuild service panes when visible, preserving active field editing; refresh on attachment. Remove audio and shell discovery stalls. |

All twelve Settings panes were measured: General, Sounds, Clipboard, Appearance, Integrations, Shortcuts, About, Claude, GitHub, Calendar, Shelf and Diagnostics. Sounds first entry improved from **633.4 ms to 13.5 ms**; Diagnostics from **127.2 ms to 4.8 ms**. Other pane entries in the final run took 0.6–24.0 ms.

Auxiliary construction and layout: Result 20.2 ms; Approval 1.8; Alert 5.1; Toast 8.5; Vitals 0.6; task orb 0.6; mini task 6.3; quick add 0.5; export 7.2; event form 13.0; reminder form 10.0; water form 5.0. Streaming Result carets stop on detachment; hidden vitals do not start 60 Hz tweens; the speed-test spinner stops when hidden/detached. Auxiliary timings measure construction/layout, not external service completion or permission flows.

## Measured memory

The populated navigation fixture includes 200 clipboard entries (40 screenshot files), 30 Shelf files and task data. Memory is physical footprint, measured inside the test process after warm-up.

| Measurement | Before | After |
| --- | --- | --- |
| Populated navigation after warm-up | 1,294 MiB | 212 MiB |
| After 420 additional switches | 1,290 MiB | 212–228 MiB across two final runs (+0.2 / +15.8 MiB) |
| Orbit: 50 close/reopen cycles | — | +10.0 / +11.1 MiB |
| Classic: 50 close/reopen cycles | — | +4.8 / +5.0 MiB |

The navigation fixture is a debug synthetic workload, not the user's reported 350 MB Activity Monitor reading. Before fixes, the running release app was sampled at approximately 339 MiB RSS / 215 MiB physical footprint. A subsequent release sample recorded approximately 165 MiB RSS / 127 MiB footprint, with a 189 MiB footprint peak. Those live samples were taken in different UI states and are observations rather than a controlled before/after comparison. Visible mascot animation and Core Animation backing surfaces still consume CPU and memory.

## Verification and reproduction

- Full unit/regression suite passed: 190 tests, 13 optional tests skipped, zero failures. The native release build, separate performance run and optional Clipboard/motion renders also passed. Regression coverage includes real window event routing after focus moves, rapid close/reopen, interrupted action transitions, repeated grid/list switches, bounded icon pixels, rapid island transitions, spring settling and split Unicode activity batches, and a deliberately blocked credential reader that leaves the UI responsive and cannot overwrite a newer connection.
- Performance gates check navigation growth under 32 MiB and footprint under 512 MiB, plus each opener's growth under 32 MiB after 50 reopens. The observed warm process plateau passed these checks.
- Clipboard transition still and opener motion GIF are local, optional artifacts under `.build/ui-review/`. No PNG/GIF publication was added to CI or PRs.
- Two copies of Zera were running during the initial live keyboard check (`/Applications` and `dist`). They can compete for the global shortcut, and accessibility focus changed during the check. The extra installed instance opened during the check was stopped, and the updated development build was reloaded. Accessibility automation then timed out; a process sample identified the synchronous startup Keychain read, which this pass subsequently moved off the UI thread. The actual-window regression tests and animated window capture passed; a clean single-instance global-hotkey and animation-feel check remains a manual shipping check.

Use a throwaway home so fixtures do not replace personal app data:

```sh
mkdir -p .build/performance-review-home
env CFFIXED_USER_HOME="$PWD/.build/performance-review-home" swift test
env CFFIXED_USER_HOME="$PWD/.build/performance-review-home" ZERA_PERF=1 swift test --filter PerfTests
swift build -c release
env CFFIXED_USER_HOME="$PWD/.build/performance-review-home" ZERA_RENDER_SCREENS="$PWD/.build/ui-review" swift test --filter ScreenRenderTests/testRenderClipboardAfterGridSwitch
env CFFIXED_USER_HOME="$PWD/.build/performance-review-home" ZERA_RENDER_SCREENS="$PWD/.build/ui-review" ZERA_RENDER_OPENER_MOTION=1 swift test --filter ScreenRenderTests/testRenderOpenerActionMotion
```

Remaining limits: Clipboard cold construction still scales with row count; GPU surfaces and active images exist outside cache budgets; external integrations and all themes require their planned live interaction review. This pass fixes demonstrated lifecycle, memory and UI-thread stalls without changing the app's manual layout architecture.
