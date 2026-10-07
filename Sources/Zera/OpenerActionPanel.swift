import AppKit

// MARK: - ⌘K actions
//
//   ┣━ [S] Safari                       (the chosen item)
//   ┃   ┣━ ↗  Open Application        ⏎
//   ┃   ┣━ 📁 Show in Finder         ⌘⏎
//   ┃   ┣━ ⧉  Copy Path             ⇧⌘C
//   ┃   ┗━ 🗑 Uninstall Application ⌃⌘⌫
//
// Everything you can do with the chosen result. In the opener they grow as the chosen item's
// children in the tree; the shortcuts work without opening them too.

/// A shortcut shown beside an action, and matched against key presses.
struct KeyCombo: Equatable {
    /// The key, lower-cased (as `charactersIgnoringModifiers` gives it), or nil when `keyCode` is used.
    let key: String?
    let keyCode: UInt16?
    let modifiers: NSEvent.ModifierFlags

    static let returnKey: UInt16 = 36
    static let deleteKey: UInt16 = 51
    static let upKey: UInt16 = 126
    static let downKey: UInt16 = 125

    static func cmd(_ key: String, _ extra: NSEvent.ModifierFlags = []) -> KeyCombo {
        KeyCombo(key: key, keyCode: nil, modifiers: extra.union(.command))
    }
    static func code(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> KeyCombo {
        KeyCombo(key: nil, keyCode: code, modifiers: modifiers)
    }

    /// "⇧⌘C", "⌘⏎", "⌃⌘⌫".
    var label: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch keyCode {
        case Self.returnKey?: s += "⏎"
        case Self.deleteKey?: s += "⌫"
        case Self.upKey?: s += "↑"
        case Self.downKey?: s += "↓"
        case 49?: s += "Space"
        default: s += (key ?? "").uppercased()
        }
        return s
    }

    func matches(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods == modifiers.intersection([.command, .option, .control, .shift]) else { return false }
        if let code = keyCode { return e.keyCode == code }
        return e.charactersIgnoringModifiers?.lowercased() == key
    }

    static func == (a: KeyCombo, b: KeyCombo) -> Bool {
        a.key == b.key && a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }
}

/// One thing you can do with the chosen result.
struct PanelAction {
    var title: String
    var symbol: String
    var shortcut: KeyCombo?
    /// Destructive ones are red.
    var tint: NSColor?
    /// Asks once more first ("Move Safari to the Trash?"), then ⏎ does it.
    var confirm: String?
    /// Actions in the same section sit together between hairlines.
    var section: Int
    var run: () -> Void

    init(_ title: String, _ symbol: String, _ shortcut: KeyCombo? = nil, section: Int, tint: NSColor? = nil,
         confirm: String? = nil, run: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.shortcut = shortcut
        self.section = section; self.tint = tint; self.confirm = confirm; self.run = run
    }
}

/// Doing things to apps: find their running copies, quit, hide, move to the Trash.
enum AppTools {
    /// The running copies of an installed app.
    static func running(_ app: AppEntry) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == app.canonicalURL
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Why it can't be uninstalled, or nil when it can.
    static func uninstallBlocker(_ app: AppEntry) -> String? {
        let path = app.canonicalURL.path
        if path.hasPrefix("/System/") { return "Part of macOS" }
        if Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL == app.canonicalURL { return "That's Zera" }
        if app.bundleID == "com.apple.finder" { return "Part of macOS" }
        return nil
    }

    /// Open apps that Quit All would close: ones with a Dock icon, never Zera or Finder.
    static func quitCandidates() -> [NSRunningApplication] {
        let me = getpid()
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != me
                && $0.bundleIdentifier != "com.apple.finder"
        }.sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    /// How Quit All remembers apps you keep: bundle ID, else path.
    static func keepKey(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? app.bundleURL?.path ?? String(app.processIdentifier)
    }

    enum TrashResult { case trashed, stillRunning, needsFinder }

    /// Quits it (politely) if it's open, then moves the app to the Trash, where Put Back can
    /// restore it. Apps installed by an admin need Finder (and your password): `.needsFinder`.
    static func moveToTrash(_ app: AppEntry, _ done: @escaping (TrashResult) -> Void) {
        let open = running(app)
        open.forEach { $0.terminate() }
        func attempt(_ tries: Int) {
            if open.contains(where: { !$0.isTerminated }) {
                guard tries > 0 else { done(.stillRunning); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { attempt(tries - 1) }
                return
            }
            NSWorkspace.shared.recycle([app.canonicalURL]) { _, error in
                DispatchQueue.main.async { done(error == nil ? .trashed : .needsFinder) }
            }
        }
        attempt(open.isEmpty ? 0 : 16)
    }
}
