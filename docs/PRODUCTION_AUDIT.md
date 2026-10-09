# Production-readiness audit — October 2026

Reviewed on 9 October 2026 on this Mac, on branch `optimizations/performance-0.1.5` from `main` at `9dded3c`. Scope: every feature from UI through logic and storage (notch island and its eight screens, both openers, the Claude wings and approval flow, tasks and timesheets, reminders and calendar, Shelf, clipboard, pull requests, battery alerts, settings), the macOS integration (hooks, Keychain, EventKit, sleep/wake, screens), and the repository's privacy posture. This file records what was found and what changed; `PERFORMANCE_REVIEW.md` covers the earlier v2-design pass.

## Claude approvals and wings

| Finding | Fix |
| --- | --- |
| A double-click (or a held ⏎) on Approve answered the next queued request too: the first click removed the request synchronously and the wing/card re-targeted before the second click landed. | `ClaudeHookService.respond` answers each request once and refuses any decision within 0.6 s of the previous one; every Approve/Reject path checks its result before playing a sound. The approval card ignores key repeats. |
| A request whose script had died (Claude Code quit or killed while waiting, or its 600 s hook timeout) stayed on the wing forever and came back as a new request at every launch. | The hook script traps INT/TERM/HUP and removes its request; it polls for 550 s, inside Claude Code's timeout; Zera drops and deletes requests older than 10 minutes and shows the oldest first. |
| `~/.claude/settings.json` that could not be parsed was replaced with a file holding only Zera's hooks. | `ClaudeSettingsFile` refuses to write over a file it cannot read, and copies the previous contents to `settings.json.zera-backup` before every write. |
| The wing could show session A's task next to session B's command, and the session card's Approve could answer another session's request. | An approval from a different session is shown on its own; the session card only shows its own session's request. |
| A reply typed on the wing was held/sent/released against whichever session was current at click time; a passing hover over the notch threw the reply offer away. | The controller remembers the session the field was opened for; offers are only released when the wings are minimized or Zera is hidden. |
| A session killed without a Stop event showed "Claude is working…" for three hours. | A running session with no event for 20 minutes reads as idle. |
| Per-session history grew without bound; the wings' 1 s refresh timer ran for the rest of the process. | History capped at 50; the ticker stops when nothing is live. |

Checked and unchanged: there is no path that answers a request without a user action (timeouts and "Zera quit" exit with no decision, so Claude Code asks in the terminal); request ids come from file names and cannot traverse; nothing from a hook payload is executed or interpolated into a shell.

## Idle CPU, memory and main-thread stalls

Measured by launching a copy of the release build with a fresh `CFFIXED_USER_HOME` and leaving it alone for 30 s (`top -l 7 -s 5`), then a 10 s `sample`. These are readings on this Mac, not guarantees.

| | Before (`9dded3c`) | After |
| --- | --- | --- |
| Idle CPU, six 5 s readings | 21.4, 17.8, 10.2, 13.1, 12.5, 13.0 % | 6.9, 9.6, 9.6, 10.7, 6.7, 6.6 % |
| Memory (`top` MEM) | 65–67 MB | 44–58 MB |
| Main-thread samples in Core Animation commits | 407 of 6633 (6 %) | none attributable to Zera's own drawing |

The user's own running instance (built from the same code) was at a steady 17–25 % CPU over 23 minutes of normal use, with the main thread spending its active time in `CALayer` display → `ripc_DrawImage` / Gaussian blur: the mascot drew its full-size 16-bit PNG with a live shadow 30 times a second.

What changed:

- `ZeraView` renders each pose once at the drawn size, 8-bit, shadow included, and blits that bitmap per frame. Her clock (and the wing orb's) runs only while the window is on screen (`NSWindow.didChangeOcclusionStateNotification`).
- The approval and activity spools are watched with `FolderWatcher` (a `DispatchSource` on the folder) instead of being listed every 0.4 s / 0.5 s; the fallback timers run every 2 s / 1 s.
- Hook payloads (`PostToolUse` carries whole tool results) are read and JSON-parsed on a utility queue; only parsed events reach the main thread.
- `EKEventStore` reads run off the main thread, one at a time, and `EKEventStoreChanged` bursts coalesce into one refresh.
- `tasks.json` is written on a serial utility queue (it was written synchronously on main every 30 s while a timer ran, and on every project-tab switch). `flush()` waits for the write at quit.
- The Anthropic key's Keychain lookup is cached and first made off the main thread; Finder icons are cached and QuickLook is not asked again for files it has no preview for; Shelf threads are dropped with the Recent entries they belong to.

Remaining: the mascot still animates at 30 fps while visible (that is her idle sway); 6–10 % idle on this Mac is what that costs now. Two 30 Hz timers (pointer polling, her sway) are the floor without changing how she moves.

## Data reliability

| Finding | Fix |
| --- | --- |
| A focus timer counted the hours the Mac slept: nothing observed sleep/wake, and the HID idle clock does not advance during sleep. | `TaskStore` folds the time on `willSleep` and restarts the session on `didWake`; `tick` also treats any gap over 60 s between ticks as sleep. Regression test. |
| `tasks.json` or `history.json` that failed to decode became an empty list, which the next save wrote over the user's data. `FocusTask` and `ClipItem` required every field. | Unreadable files are set aside as `*.broken-<epoch>.json`; both types decode with defaults for missing fields; `Saved` carries a `version`. Regression tests. |
| `load()` rewrote `tasks.json` mid-load with `links` and `focus` missing (a property observer fired during init). | Saves are suppressed until loading is finished. |
| A one-off reminder more than 15 minutes overdue (sleep, relaunch) was never announced. | One-offs fire once however late; repeating reminders keep the 15-minute window. Regression test. |
| The break nudge fired immediately after waking from a long sleep. | Idle time resets the break clock. |
| Interval reminders' active hours were a seconds offset from the start, so a "9 AM–9 PM" window ended an hour off on DST days. | The end is a clock time. Regression test (New York, 1 November 2026). |
| "Rebuild from commits" read commits by committer date but removed tasks by author date, so a rebased commit was added again on every rebuild. | The read window is filtered by author date. |
| The Done list credited a task's whole lifetime to the day it was finished when it had no time that day. | `?? 0`. |
| Shelf entries on an unmounted volume were dropped for good at launch. | They stay, marked "missing". |
| A clipboard change within 0.4 s of quitting was lost. | `ClipboardStore.flush()` at quit. |

## UI

Every main screen, the Settings panes, both openers (full and compact, actions open), the wings (running, approval), banners and the export sheets were rendered through `ScreenRenderTests` before and after the changes and compared; the shared layout from the v2 pass holds. The app launcher's selected-app card already keeps the icon and metadata grouped left and pin / ••• / Open app right at one 32 pt height with 8 pt gaps; the one defect was that those buttons (`TreeButton`) had no accessibility role or default label, so VoiceOver did not see them as buttons. Fixed. `ApprovalCard` set its title twice; the dead line is gone.

## Clipboard list

Copying a row left the clicked row drawn under the rebuilt list, switching to Images left stale rows under the tiles, and the "✓ Copied" flash was drawn over the ⌘-key and the pin / ••• buttons. Root cause: `rebuildList` reuses a row when its item is unchanged, but when the item *has* changed (a copy bumps its count and time; pinning) it created a new row and left the old one in the document, because the old view had already been taken out of the pool whose leftovers get removed. Old rows and tiles are now removed when replaced; the list is layer-backed from construction (it was switched on from `layout()`); the flash goes on the row that shows the item after the rebuild, and the row's right end shows one thing at a time. Regression test: `ClipboardTests.testACopyFlashesTheRowThatNowShowsTheItem`.

## The hover bloom

Tapping a bloomed node sent it to the rail while the open node's ring was placed at the destination immediately (it only animated when already showing), so the ring sat waiting for the node to arrive. The ring now fades in once the nodes have landed. A redesign of the bloom with a frosted-glass crescent was tried and taken out again: the blur and the extra motion cost more memory and smoothness than they were worth.

## Full-screen apps

Reported: ⌥Space and the island do not appear over a full-screen app. Reproduced on this Mac with an isolated copy (its own home, its own shortcuts), a helper window in full screen, and `CGWindowListCopyWindowInfo` as the witness: the island (968×706, level 26) and the v2 opener (whole screen, level 29) are both placed on the full-screen Space by the window server when toggled there, so the panels' `canJoinAllSpaces` + `fullScreenAuxiliary` setup is working. What could not be reproduced is the global shortcut itself not firing in a given full-screen app (synthetic key events do not reach Carbon hot keys, so that leg was driven by a timer). If it recurs, the question is whether Zera herself hides when ⌥Space is pressed (the hot key arrived, the panel did not show) or stays (the hot key never reached Zera: the app in front captures the keyboard).

## Code removed or shared

- Unused declarations: `Palette.accentHover/accentPressed/dangerPressed/selectedAccent/systemIsDark`, `Typo.section/bannerTitle`, `Metrics.panelPad`, `stylePopup`, `ZeraTheme.swatches`, `ClaudeProcessManager.activeCount`, `ClaudeActivityService.isWaitingForReply`, `GHEvent.isCI`, `repoName/repoDisplay`, `ZeraGitHubBubble.fittedSize`, three `GitHubCard` layout constants, `TaskStore.forgetCommitTasks`, `FreshFiles.removeFolder`, `ReminderAlert.firedAt`, unused size constants in Reminders/Claude/Shelf/Clipboard/Island views, `orbitBounds`, `lineViews`, `lastKey`, `ZeraPose`, `ShelfFilter` and the no-op `select(filter:)`.
- The never-shown session tip (`ZeraSessionTip`, `tipText`, its defaults key) in the Claude screen.
- 28 sprite PNGs in `Resources/Sprites` that no code names (3.3 MB stays; they were shipping in every build).
- Shared: `highlighted`, `String.capitalizedFirst` and `Array[safe:]` now live once in `OpenerOrbit.swift` (three copies before); `NSPasteboard.setPlainText` replaces two identical copy helpers.

Not done, deliberately: the Classic and v2 openers still share ~600 lines of identical command logic (38 byte-identical methods), and `SettingsCard` reaches into 15 singletons. Both are real but are rewrites, not fixes.

## Privacy

Tracked files, filenames and the full history's file contents contain only `amsynist` plus fictional fixtures; no credentials, internal hosts or machine paths. `.claude/` (local launch config with a machine path) is now ignored. What remains is commit metadata: 36 commits on `main` authored with a personal Gmail address and 14 as a nickname, all already pushed, plus the repo-local `user.email` still set to that address. Rewriting history needs separate authorization; new commits should use the GitHub noreply identity already present in history.

## Verification

- `swift build`, `swift build -c release`: clean.
- `swift test` with a throwaway `CFFIXED_USER_HOME`: 210 tests, 13 skipped (the usual optional ones), 0 failures. Ten tests were added for the behaviour above.
- Live: idle CPU/memory of an isolated copy before and after (table above). Running a second instance competes for the global shortcuts with the user's own copy — disable `appOpener.enabled` and the clipboard/tasks shortcuts in the throwaway home before measuring again.
- Not verified live: a real Claude Code approval round-trip and reply through the patched hook script, calendar accounts with hundreds of events, sleep/wake on hardware (covered by the clock-gap test), multiple displays, Intel.
