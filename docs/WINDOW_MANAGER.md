# Zera v2 window manager

Open Arrange from Zera and explicitly enable window arrangements. Accessibility access lets Zera read, move and resize native app windows. Use Window scope to include all apps, one app or selected apps. Full-screen windows and apps that refuse resizing may not fit a requested layout.

Choose columns, rows, a grid or a main-window layout. Previews use the same geometry as the applied layout. Rotate changes the window order; Undo restores the previous arrangement. Zera checks the result and tries to restore previous positions if an app refuses a move or size.

Workspaces are Zera window groups numbered 1–9, not macOS Spaces. Choose the display for a group and assign apps to a workspace. Windows outside active groups are parked off the working display and restored when you switch back or disable the feature. Zera does not send normal group switches through Dock minimization.

Configure Shortcuts and app scope before enabling. While enabled, the configured bindings (including defaults for ⌘W, ⌘M and ⌘1–9) replace those same app shortcuts. Automatic arrangements and workspace capacities are optional. Quit competing window managers before enabling Zera’s manager.

Visual transitions are a separate opt-in. Screen Recording lets Zera animate temporary window images; they stay in memory and live content pauses briefly. Native frame movement works without that visual layer. Reduce Motion is respected.

## Native release demonstration

The v2 walkthrough shows the actual production ArrangeLayout geometry and ArrangeWindowAccess frame-write engine arranging three new disposable AppKit windows. It switches from overlapping windows to a main-left layout, then columns, then restores the main-left layout. The test verifies each resulting frame through Accessibility. It invokes the frame engine directly; it is not a recording of clicking every Arrange control or a macOS Spaces demo. Only the new fixture process and its wallpaper window are recorded. All content is fictional.

See MEDIA.md for capture setup and reproducible commands. The separate phone-sharing film remains dedicated to Android-to-Mac transfer.
