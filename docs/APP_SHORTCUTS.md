# App Shortcuts

App Shortcuts is an optional Extra under Settings → Extras. It sends the native application open/reopen request, including restoring an existing hidden or minimized app when supported. It does not discover, move, resize, hide or assign windows, intercept trackpad gestures or manage workspaces.

Enable App Shortcuts, choose **Configure App Shortcuts…**, then **Add app…**. Click the shortcut field and press a combination containing Command, Option or Control. Escape cancels recording; Delete clears a binding. Open tests the selected application; the minus button removes its entry without uninstalling the app. Exclusive global registrations detect conflicts with other processes. Conflicting edits retain the previous binding; an unavailable binding at startup does not disable the other apps. Global bindings override the same keys in other apps, so choose combinations deliberately.

Fresh installs start disabled with no preset apps. Existing scrolling-workspace app rules migrate first; earlier arrangement rules are the fallback. Names, bundle IDs, paths and shortcut choices survive; workspace/layout values are not imported. Original preference records remain untouched for rollback. The former Arrange navigation raw value now opens App Shortcuts, preserving remembered navigation identity.

No Accessibility, Input Monitoring or Screen Recording permission is needed for these Carbon hotkeys. Activation follows macOS and the separately installed window manager's policies. Zera does not force a particular window or Space.

## Separate window management

[OmniWM](https://omniwm.app/) is an independent option for scrolling workspaces, tiled layouts, padding, gestures and monitor routing. Install and configure it separately; its current releases require Apple silicon and macOS 26+. Zera contains no OmniWM integration or bundled window engine. Keep only one active window manager.

Before updating from a window-manager build, quit that Zera normally so its owned engine restores parked windows. Old local preferences are retained but inactive. Earlier walkthrough footage includes the removed window arrangement demo and is historical for that chapter.
