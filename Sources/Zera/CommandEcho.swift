import AppKit
import ApplicationServices
import CoreAudio
import AudioToolbox
import IOKit
import IOKit.graphics

// MARK: - Command Echo
//
// A small HUD under the notch that echoes the shortcut you just pressed ("⌘C  Copy") and the
// media keys (volume and brightness as a level bar, play / next / previous), and tells the
// notch light what happened (`onReaction`) so the edge can answer each event.
// Uses the shared listen-only event tap, with NSEvent fallback while access is unavailable.
// Single
// DispatchWorkItems hide the pill 1.6 s after the last event, re-read a level 80 ms after a
// media key, and notice a modifier held for 180 ms.
//
// ⌘C / ⌘X watch the clipboard for a few hundred ms and show what was caught on the right of the
// pill: a swatch and its hex for a colour (#4DBDFF, rgb(…), hsl(…), a colour-picker colour), a
// file name, a link's host, or the first line of text. The edge's comet takes the copied colour.
// ⌘V shows what went in. Anything an app marks private (password managers) only shows "Hidden".
// Caps Lock and Shift held on its own (0.5 s, any other key cancels it) get their own pill too.

@MainActor
final class CommandEcho {
    static let shared = CommandEcho()

    private enum Key {
        static let enabled = "zera.echo.enabled"
        static let hud = "zera.echo.hud"
        static let reactions = "zera.notchLight.reactions"
        static let preview = "zera.echo.preview"
    }
    private static let hideAfter: TimeInterval = 1.6
    /// Media keys change the level just after the key-down reaches us; read it again shortly after.
    private static let rereadAfter: TimeInterval = 0.08
    /// A modifier held this long on its own counts as "held" (a shortcut arriving first cancels it).
    private static let modifierHold: TimeInterval = 0.18
    /// One brightness key press, when the real level can't be read.
    private static let brightnessStep: Double = 1 / 16
    private static let volumeStep: Double = 1 / 16
    /// Shift on its own must be held this long before it shows (typing capitals never does).
    private static let shiftHold: TimeInterval = 0.5
    /// After ⌘C / ⌘X, how often and how many times to look for the clipboard to change.
    private static let copyCheckEvery: TimeInterval = 0.04
    private static let copyChecks = 8

    private let hud = EchoHUD()
    private var monitors: [Any] = []
    private var hideWork: DispatchWorkItem?
    private var rereadWork: DispatchWorkItem?
    private var modifierWork: DispatchWorkItem?
    /// `.modifier(held: true)` went out and its release is still owed.
    private var modifierHeld = false
    /// A key went down while modifiers were held: no "held" glow for this press.
    private var keyPressedWithModifiers = false
    /// Stepped guess of the display brightness while no API answers (see `DisplayBrightness`).
    private var brightnessEstimate: Double = 0.5
    private var capsOn = false
    private var shiftWork: DispatchWorkItem?
    private var copyWork: DispatchWorkItem?
    private var lastShiftKeyCode: UInt16 = 0
    /// Key-downs the monitors actually delivered (the self-test checks real keys arrive).
    private(set) var keysSeen = 0
    /// Watches the display's brightness (Control Centre slider, keyboards whose brightness keys
    /// never reach an event monitor) while Command Echo is on and the level can be read.
    private var brightnessTimer: Timer?
    private var brightnessSeen: Double?
    private var brightnessKeyAt = Date.distantPast

    /// The notch light's hook: called for every echoed event when `reactionsEnabled`. The colour,
    /// when there is one, is what you just copied or pasted.
    var onReaction: ((NotchLightReaction, NSColor?) -> Void)?

    private var feedbackRevision = 0
    private var skippedObserver: NSObjectProtocol?

    init() {}

    /// Useful to diagnostics and native interaction checks; never retains clipboard history.
    var currentFeedback: EchoContent? { hud.currentContent }
    var isFeedbackVisible: Bool { hud.isVisible }

    /// Routing an existing companion caption must not reclaim a newer command or dictation.
    func presentCaption(_ content: EchoContent, replacing ownerRevision: Int?, hold: TimeInterval) -> Int? {
        guard currentFeedback == nil || ownerRevision == feedbackRevision else { return nil }
        return present(content, hold: hold)
    }

    #if DEBUG
    func focusVisualReview() { hud.focusVisualReview() }
    #endif

    /// A later event owns the HUD. Clipboard polls, level rereads and hide work from an older
    /// event must never replace or dismiss it.
    private func beginFeedback() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZERA_REVIEW_FEEDBACK"] == "volume" {
            Diag.log("review feedback begin revision \(feedbackRevision): " + Thread.callStackSymbols.filter { $0.contains("Zera") }.prefix(4).joined(separator: " | "))
        }
        #endif
        feedbackRevision &+= 1
        hideWork?.cancel(); hideWork = nil
        copyWork?.cancel(); copyWork = nil
        rereadWork?.cancel(); rereadWork = nil
    }

    // MARK: Settings

    /// Settings → Command Echo. Governs the monitors (and so both the pill and the reactions).
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.enabled)
            if newValue { install() } else { uninstall() }
        }
    }

    /// Show the pill under the notch (light reactions can stay on without it).
    var hudEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.hud) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.hud)
            if !newValue { hideWork?.cancel(); hideWork = nil; hud.hide(animated: false) }
        }
    }

    /// Show what ⌘C / ⌘X caught and what ⌘V pasted on the right of the pill.
    var previewEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.preview) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.preview) }
    }

    /// Let the notch light react to shortcuts and levels (the pill can stay on without it).
    var reactionsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.reactions) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.reactions) }
    }

    /// Either Input Monitoring or Accessibility can authorize the listen-only keyboard tap.
    var needsKeyboardAccess: Bool { !GlobalKeys.keysAllowed }

    /// Ask for listen-only access explicitly from Settings, rather than two prompts at launch.
    func requestKeyboardAccess() { GlobalKeys.requestListen() }

    /// Registered app shortcuts already reach Carbon without global keyboard permission.
    /// Echo their actual configured keys and action rather than a generic command guess.
    func configuredShortcut(keys: String, label: String, symbol: String) {
        guard isEnabled else { return }
        echo(EchoContent(symbol: symbol, keys: keys, text: label, tint: Pal.accent), reaction: .shortcut)
    }

    enum Preview: String, CaseIterable {
        case copy = "Copy · ⌘C", paste = "Paste · ⌘V", volume = "Volume", brightness = "Brightness"
    }

    /// Explicit visual previews work before keyboard access is granted. They never read or
    /// write the clipboard, post keys, or change the Mac's volume or brightness.
    func preview(_ kind: Preview) {
        let content: EchoContent
        let reaction: NotchLightReaction
        switch kind {
        case .copy:
            content = EchoContent(symbol: "doc.on.doc", keys: "⌘C", text: "Copy", detail: "Preview", tint: Pal.accent)
            reaction = .copy
        case .paste:
            content = EchoContent(symbol: "doc.on.clipboard", keys: "⌘V", text: "Paste", detail: "Preview", tint: Pal.accent)
            reaction = .paste
        case .volume:
            content = Self.volumeContent(level: 0.62, muted: false)
            reaction = .level(kind: .volume, value: 0.62)
        case .brightness:
            content = Self.brightnessContent(level: 0.75, up: true)
            reaction = .level(kind: .brightness, value: 0.75)
        }
        present(content, hold: 2)
        react(reaction)
    }

    /// Call once at launch (after the app finished launching).
    func start() {
        if isEnabled { install() }
        // Skipping a track peeks at the one that comes up (title · artist).
        guard skippedObserver == nil else { return }
        skippedObserver = NotificationCenter.default.addObserver(forName: NowPlayingService.skipped, object: nil, queue: .main) { [weak self] note in
            let forward = note.userInfo?["forward"] as? Bool ?? true
            MainActor.assumeIsolated { self?.peekTrack(forward: forward) }
        }
    }

    private func peekTrack(forward: Bool) {
        guard isEnabled, hudEnabled, let t = NowPlayingService.shared.track else { return }
        echo(EchoContent(symbol: forward ? "forward.fill" : "backward.fill", keys: "", text: t.title,
                         detail: t.artist, tint: Pal.accent), reaction: nil)
    }

    // MARK: Self-test tour (ZERA_TOUR)

    /// One step of the self-test tour: the same content and reaction a real key press makes.
    enum TourStep: String, CaseIterable {
        case copyColour, copyText, paste, cut, undo, save, capsOn, capsOff, shift, volume, brightness, mute
    }

    /// Plays `step` through the real echo paths (the clipboard is written for the copy steps;
    /// the tour restores it when it finishes).
    func tour(_ step: TourStep) {
        let app = "Zera"
        func shortcut(_ combo: String) {
            guard let k = Self.shortcuts[combo] else { return }
            echo(EchoContent(symbol: k.symbol, keys: combo, text: k.label, detail: app, tint: Self.tint(for: k.reaction)),
                 reaction: k.reaction)
        }
        switch step {
        case .copyColour, .copyText:
            let pb = NSPasteboard.general
            let before = pb.changeCount
            let base = EchoContent(symbol: "doc.on.doc", keys: "⌘C", text: "Copy", detail: app, tint: Self.tint(for: .copy))
            echo(base, reaction: nil)
            pb.clearContents()
            pb.setString(step == .copyColour ? "#4DBDFF" : "Ship the build tonight, then tell the team", forType: .string)
            checkCopy(base: base, reaction: .copy, from: before, revision: feedbackRevision, attempt: 1)
        case .paste:
            let preview = previewEnabled ? ClipPreview.read() : nil
            var content = EchoContent(symbol: "doc.on.clipboard", keys: "⌘V", text: "Pasted", detail: app, tint: Self.tint(for: .paste))
            if let pv = preview { content.apply(pv) }
            echo(content, reaction: .paste, tint: preview?.color)
        case .cut: shortcut("⌘X")
        case .undo: shortcut("⌘Z")
        case .save: shortcut("⌘S")
        case .capsOn, .capsOff:
            let on = step == .capsOn
            echo(EchoContent(symbol: on ? "capslock.fill" : "capslock", keys: "", text: "Caps Lock",
                             detail: on ? "On" : "Off", tint: on ? Pal.success : nil), reaction: .capsLock(on: on))
        case .shift:
            echo(EchoContent(symbol: "shift.fill", keys: "⇧", text: "Shift"), reaction: .shiftHeld)
        case .volume:
            echo(Self.volumeContent(level: 0.62, muted: false), reaction: .level(kind: .volume, value: 0.62))
        case .brightness:
            echo(Self.brightnessContent(level: 0.75, up: true), reaction: .level(kind: .brightness, value: 0.75))
        case .mute:
            echo(Self.volumeContent(level: 0, muted: true), reaction: .level(kind: .mute, value: nil))
        }
    }

    // MARK: Presenting from elsewhere (dictation, voice answers)

    /// Shows `content` in the pill. `hold` nil keeps it up until `dismissPresented()`.
    @discardableResult
    func present(_ content: EchoContent, hold: TimeInterval?) -> Int {
        beginFeedback()
        let revision = feedbackRevision
        hud.show(content)
        guard let hold = hold else { return revision }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, self.feedbackRevision == revision else { return }
            self.hud.hide(animated: true)
        } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
        return revision
    }

    func dismissPresented(revision: Int? = nil) {
        guard revision == nil || revision == feedbackRevision else { return }
        beginFeedback()
        hud.hide(animated: true)
    }

    func stop() {
        uninstall()
        if let skippedObserver { NotificationCenter.default.removeObserver(skippedObserver) }
        skippedObserver = nil
    }

    // MARK: Monitors

    private func install() {
        guard monitors.isEmpty else { return }
        capsOn = NSEvent.modifierFlags.contains(.capsLock)
        let id = GlobalKeys.shared.subscribe([.keyDown, .systemDefined, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        monitors.append(id)
        startBrightnessWatch()
    }

    /// 4 Hz read of the built-in display's brightness; a change of 2 % or more that no key press
    /// just explained shows the level like a key would. Gentle auto-brightness ramps stay quiet.
    private func startBrightnessWatch() {
        guard brightnessTimer == nil, let first = DisplayBrightness.read() else { return }
        brightnessSeen = first
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.brightnessTick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        brightnessTimer = t
    }

    private func brightnessTick() {
        guard let now = DisplayBrightness.read() else { return }
        defer { brightnessSeen = now }
        guard let seen = brightnessSeen, abs(now - seen) >= 0.02,
              Date().timeIntervalSince(brightnessKeyAt) > 0.5 else { return }
        brightnessEstimate = now
        echo(Self.brightnessContent(level: now, up: now > seen), reaction: .level(kind: .brightness, value: now))
    }

    private func uninstall() {
        beginFeedback()
        monitors.compactMap { $0 as? Int }.forEach { GlobalKeys.shared.unsubscribe($0) }
        monitors.removeAll()
        hideWork?.cancel(); hideWork = nil
        rereadWork?.cancel(); rereadWork = nil
        modifierWork?.cancel(); modifierWork = nil
        shiftWork?.cancel(); shiftWork = nil
        copyWork?.cancel(); copyWork = nil
        brightnessTimer?.invalidate(); brightnessTimer = nil
        if modifierHeld { modifierHeld = false; react(.modifier(held: false)) }
        keyPressedWithModifiers = false
        hud.hide(animated: false)
    }

    func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown: handleKey(event)
        case .systemDefined: handleMediaKey(event)
        case .flagsChanged: handleFlags(event)
        default: break
        }
    }

    // MARK: Modifiers held

    private func handleFlags(_ event: NSEvent) {
        handleCaseKeys(event)
        let held = event.modifierFlags.intersection([.command, .option, .control])
        if held.isEmpty {
            modifierWork?.cancel(); modifierWork = nil
            keyPressedWithModifiers = false
            if modifierHeld { modifierHeld = false; react(.modifier(held: false)) }
        } else if modifierWork == nil, !modifierHeld, !keyPressedWithModifiers {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.modifierHoldElapsed() } }
            modifierWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.modifierHold, execute: work)
        }
    }

    /// Caps Lock: a pill and a flash each time it flips. Shift: only when held on its own.
    private func handleCaseKeys(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let caps = flags.contains(.capsLock)
        if caps != capsOn {
            capsOn = caps
            let green = Pal.success
            echo(EchoContent(symbol: caps ? "capslock.fill" : "capslock", keys: "", text: "Caps Lock",
                             detail: caps ? "On" : "Off", tint: caps ? green : nil),
                 reaction: .capsLock(on: caps))
            return
        }
        let modifiers = flags.subtracting([.capsLock, .numericPad, .function, .help])
        if event.keyCode == 56 || event.keyCode == 60 { lastShiftKeyCode = event.keyCode }
        if modifiers == [.shift] {
            guard shiftWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.shiftHoldElapsed() } }
            shiftWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.shiftHold, execute: work)
        } else {
            shiftWork?.cancel(); shiftWork = nil
        }
    }

    private func shiftHoldElapsed() {
        shiftWork = nil
        // Holding right ⇧ is dictation's key (Settings → Voice): no Shift peek over it.
        if Dictation.shared.claimsRightShift, lastShiftKeyCode == 60 { return }
        guard NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .help]) == [.shift] else { return }
        echo(EchoContent(symbol: "shift.fill", keys: "⇧", text: "Shift"), reaction: .shiftHeld)
    }

    private func modifierHoldElapsed() {
        modifierWork = nil
        guard !keyPressedWithModifiers, !modifierHeld else { return }
        modifierHeld = true
        react(.modifier(held: true))
    }

    // MARK: Shortcuts

    private func handleKey(_ event: NSEvent) {
        keysSeen += 1
        // Our own ⌘V (dictation typing its words) is not something you pressed.
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Dictation.eventTag { return }
        // Apple Silicon keyboards send brightness as plain key-downs (0x90 up, 0x91 down).
        if event.keyCode == 144 || event.keyCode == 145 {
            showBrightness(step: event.keyCode == 144 ? Self.brightnessStep : -Self.brightnessStep)
            return
        }
        // Any keystroke means Shift was for a capital, not a Shift peek.
        shiftWork?.cancel(); shiftWork = nil
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.intersection([.command, .option, .control]).isEmpty {
            // A shortcut, not a held modifier: no "held" glow for this press.
            keyPressedWithModifiers = true
            modifierWork?.cancel(); modifierWork = nil
        }
        guard flags.contains(.command), let key = Self.keyName(for: event) else { return }
        var glyphs = ""
        if flags.contains(.control) { glyphs += "⌃" }
        if flags.contains(.option) { glyphs += "⌥" }
        if flags.contains(.shift) { glyphs += "⇧" }
        glyphs += "⌘"
        let combo = glyphs + key
        guard let known = Self.shortcuts[combo] else {
            echo(EchoContent(symbol: "command", keys: combo, text: "", detail: Self.frontAppName), reaction: nil)
            return
        }
        let tint = Self.tint(for: known.reaction)
        switch known.reaction {
        case .copy, .cut:
            // The light waits until the clipboard actually changes (and takes its colour).
            let base = EchoContent(symbol: known.symbol, keys: combo, text: known.label, detail: Self.frontAppName, tint: tint)
            echo(base, reaction: nil)
            watchCopy(base: base, reaction: known.reaction, from: NSPasteboard.general.changeCount, revision: feedbackRevision)
        case .paste:
            let preview = previewEnabled ? ClipPreview.read() : nil
            var content = EchoContent(symbol: known.symbol, keys: combo, text: "Pasted", detail: Self.frontAppName, tint: tint)
            if let pv = preview { content.apply(pv) }
            echo(content, reaction: known.reaction, tint: preview?.color)
        default:
            echo(EchoContent(symbol: known.symbol, keys: combo, text: known.label, detail: Self.frontAppName, tint: tint),
                 reaction: known.reaction)
        }
    }

    /// Looks for the clipboard to change after ⌘C / ⌘X, every 40 ms for up to 320 ms. When it
    /// does: history picks it up at once, the pill says what was caught, and the edge answers in
    /// its colour. If nothing changes (the app was slower, or there was nothing to copy) the edge
    /// still answers once, uncoloured.
    private func watchCopy(base: EchoContent, reaction: NotchLightReaction, from count: Int, revision: Int, attempt: Int = 0) {
        copyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkCopy(base: base, reaction: reaction, from: count, revision: revision, attempt: attempt + 1) }
        }
        copyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copyCheckEvery, execute: work)
    }

    private func checkCopy(base: EchoContent, reaction: NotchLightReaction, from count: Int, revision: Int, attempt: Int) {
        guard revision == feedbackRevision else { return }
        copyWork = nil
        guard NSPasteboard.general.changeCount != count else {
            if attempt < Self.copyChecks { watchCopy(base: base, reaction: reaction, from: count, revision: revision, attempt: attempt) }
            else { react(reaction) }
            return
        }
        ClipboardStore.shared.pollNow()
        let preview = previewEnabled ? ClipPreview.read() : nil
        var content = base
        content.text = reaction == .cut ? "Cut" : "Copied"
        if let pv = preview { content.apply(pv) }
        if hud.isVisible { hud.update(content) }
        react(reaction, tint: preview?.color)
    }

    /// The app the shortcut went to, shown dim on the right ("Safari").
    private static var frontAppName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }

    /// Each kind of shortcut keeps its own colour, matching the edge.
    private static func tint(for r: NotchLightReaction) -> NSColor? {
        let p = Pal
        switch r {
        case .cut: return p.danger
        case .undo: return p.warning
        case .save: return p.success
        case .copy, .paste: return p.accent
        default: return nil
        }
    }

    /// The key's own glyph: letters upper-cased, the number row by position (so ⇧⌘3 stays "3"),
    /// and the usual symbols for space, tab, return, delete, escape and arrows.
    private static func keyName(for event: NSEvent) -> String? {
        if let special = specialKeys[event.keyCode] { return special }
        if let digit = numberRow[event.keyCode] { return digit }
        guard let chars = event.charactersIgnoringModifiers, let first = chars.unicodeScalars.first else { return nil }
        // Control characters (⌃ combos, function keys we don't name) have nothing to show.
        guard first.value >= 0x20, first.value != 0x7F, first.value < 0xF700 else { return nil }
        return String(first).uppercased()
    }

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 48: "⇥", 36: "↩", 76: "⌤", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    private static let numberRow: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"
    ]

    private struct Shortcut {
        let label: String
        let symbol: String
        let reaction: NotchLightReaction
    }

    /// Modifiers in Apple's order (⌃⌥⇧⌘) followed by the key.
    private static let shortcuts: [String: Shortcut] = [
        "⌘C": Shortcut(label: "Copy", symbol: "doc.on.doc", reaction: .copy),
        "⌘V": Shortcut(label: "Paste", symbol: "doc.on.clipboard", reaction: .paste),
        "⌘X": Shortcut(label: "Cut", symbol: "scissors", reaction: .cut),
        "⌘Z": Shortcut(label: "Undo", symbol: "arrow.uturn.backward", reaction: .undo),
        "⇧⌘Z": Shortcut(label: "Redo", symbol: "arrow.uturn.forward", reaction: .redo),
        "⌘S": Shortcut(label: "Save", symbol: "square.and.arrow.down", reaction: .save),
        "⇧⌘S": Shortcut(label: "Save as", symbol: "square.and.arrow.down.on.square", reaction: .save),
        "⌘A": Shortcut(label: "Select all", symbol: "checkmark.square", reaction: .shortcut),
        "⌘F": Shortcut(label: "Find", symbol: "magnifyingglass", reaction: .shortcut),
        "⌘T": Shortcut(label: "New tab", symbol: "plus.rectangle.on.rectangle", reaction: .shortcut),
        "⌘W": Shortcut(label: "Close", symbol: "xmark", reaction: .shortcut),
        "⌘Q": Shortcut(label: "Quit", symbol: "power", reaction: .shortcut),
        "⌘N": Shortcut(label: "New", symbol: "plus", reaction: .shortcut),
        "⇧⌘N": Shortcut(label: "New window", symbol: "macwindow.badge.plus", reaction: .shortcut),
        "⌘O": Shortcut(label: "Open", symbol: "folder", reaction: .shortcut),
        "⌘P": Shortcut(label: "Print", symbol: "printer", reaction: .shortcut),
        "⌘M": Shortcut(label: "Minimize", symbol: "arrow.down.right.and.arrow.up.left", reaction: .shortcut),
        "⌘H": Shortcut(label: "Hide", symbol: "eye.slash", reaction: .shortcut),
        "⇧⌘3": Shortcut(label: "Screenshot", symbol: "camera.viewfinder", reaction: .screenshot),
        "⇧⌘4": Shortcut(label: "Screenshot", symbol: "camera.viewfinder", reaction: .screenshot),
        "⇧⌘5": Shortcut(label: "Screenshot", symbol: "camera.viewfinder", reaction: .screenshot),
        "⌘Space": Shortcut(label: "Spotlight", symbol: "magnifyingglass", reaction: .shortcut),
        "⌘⇥": Shortcut(label: "Switch app", symbol: "square.on.square", reaction: .shortcut),
        "⌘,": Shortcut(label: "Settings", symbol: "gearshape", reaction: .shortcut),
        "⌘R": Shortcut(label: "Refresh", symbol: "arrow.clockwise", reaction: .shortcut),
        "⌘B": Shortcut(label: "Bold", symbol: "bold", reaction: .shortcut),
        "⌘I": Shortcut(label: "Italic", symbol: "italic", reaction: .shortcut),
        "⌘U": Shortcut(label: "Underline", symbol: "underline", reaction: .shortcut)
    ]

    // MARK: Media keys

    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    private enum MediaKey: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
        case play = 16, next = 17, previous = 18, fast = 19, rewind = 20
    }

    private func handleMediaKey(_ event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }
        let data = event.data1
        let code = (data & 0xFFFF_0000) >> 16
        let flags = data & 0xFFFF
        let down = ((flags & 0xFF00) >> 8) == 0xA
        guard down, let key = MediaKey(rawValue: code) else { return }
        switch key {
        case .soundUp: showVolume(step: Self.volumeStep)
        case .soundDown: showVolume(step: -Self.volumeStep)
        case .mute: showVolume(step: nil)
        case .brightnessUp: showBrightness(step: Self.brightnessStep)
        case .brightnessDown: showBrightness(step: -Self.brightnessStep)
        case .play:
            echo(EchoContent(symbol: "playpause.fill", keys: "", text: "Play / Pause"), reaction: .shortcut)
        case .next, .fast:
            NowPlayingService.shared.noteSkip(forward: true)
            echo(EchoContent(symbol: "forward.fill", keys: "", text: "Next"), reaction: .shortcut)
        case .previous, .rewind:
            NowPlayingService.shared.noteSkip(forward: false)
            echo(EchoContent(symbol: "backward.fill", keys: "", text: "Previous"), reaction: .shortcut)
        }
    }

    /// Shows the volume now (predicting the press's own step, since the system applies it a
    /// moment later), then reads the real level once 80 ms on. `step` nil = the mute key.
    private func showVolume(step: Double?) {
        let reading = OutputVolume.read()
        var predicted = reading?.level
        if let s = step, let l = predicted { predicted = max(0, min(1, l + s)) }
        let muted = step == nil ? !(reading?.muted ?? false) : (reading?.muted ?? false)
        let reaction: NotchLightReaction = step == nil ? .level(kind: .mute, value: nil) : .level(kind: .volume, value: predicted)
        echo(Self.volumeContent(level: predicted, muted: muted), reaction: reaction)
        scheduleReread { [weak self] in self?.rereadVolume() }
    }

    private func rereadVolume() {
        guard let reading = OutputVolume.read() else { return }
        hud.update(Self.volumeContent(level: reading.level, muted: reading.muted))
    }

    private static func volumeContent(level: Double?, muted: Bool) -> EchoContent {
        let symbol: String
        if muted || (level ?? 1) <= 0.001 { symbol = "speaker.slash.fill" }
        else if let l = level { symbol = l < 0.34 ? "speaker.wave.1.fill" : (l < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill") }
        else { symbol = "speaker.wave.2.fill" }
        let text = muted ? "Muted" : "Volume"
        if let l = level { return EchoContent(symbol: symbol, keys: "", text: text, level: muted ? 0 : l) }
        return EchoContent(symbol: symbol, keys: "", text: text)
    }

    /// Brightness: the real level when an API answers (plus the press's own step, applied a moment
    /// later by the system), otherwise the stepped estimate; re-read 80 ms on.
    private func showBrightness(step: Double) {
        brightnessKeyAt = Date()
        if let real = DisplayBrightness.read() { brightnessEstimate = real }
        brightnessEstimate = max(0, min(1, brightnessEstimate + step))
        let level = brightnessEstimate
        echo(Self.brightnessContent(level: level, up: step > 0), reaction: .level(kind: .brightness, value: level))
        let up = step > 0
        scheduleReread { [weak self] in self?.rereadBrightness(up: up) }
    }

    private func rereadBrightness(up: Bool) {
        guard let real = DisplayBrightness.read() else { return }
        brightnessEstimate = real
        brightnessSeen = real
        brightnessKeyAt = Date()
        hud.update(Self.brightnessContent(level: real, up: up))
        react(.level(kind: .brightness, value: real))
    }

    private static func brightnessContent(level: Double, up: Bool) -> EchoContent {
        EchoContent(symbol: up ? "sun.max.fill" : "sun.min.fill", keys: "", text: "Brightness", level: level)
    }

    private func scheduleReread(_ body: @escaping @MainActor () -> Void) {
        rereadWork?.cancel()
        let revision = feedbackRevision
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, self.feedbackRevision == revision else { return }
            self.rereadWork = nil
            body()
        } }
        rereadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rereadAfter, execute: work)
    }

    // MARK: Echoing

    /// The pill (when `hudEnabled`) and the light (when `reactionsEnabled`), for one event.
    private func echo(_ content: EchoContent, reaction: NotchLightReaction?, tint: NSColor? = nil) {
        beginFeedback()
        if hudEnabled { hud.show(content) }
        if let r = reaction { react(r, tint: tint) }
        guard hudEnabled else { return }
        let revision = feedbackRevision
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, self.feedbackRevision == revision else { return }
            self.hud.hide(animated: true)
        } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideAfter, execute: work)
    }

    private func react(_ reaction: NotchLightReaction, tint: NSColor? = nil) {
        guard reactionsEnabled else { return }
        onReaction?(reaction, tint)
    }
}

// MARK: - Display brightness

/// The built-in display's brightness, 0…1, or nil when no API answers.
///
/// There is no public API for this. The first try is `DisplayServicesGetBrightness` from the
/// private DisplayServices framework, looked up with `dlsym` at runtime so nothing links against
/// it and a missing or renamed symbol just returns nil. The second is IOKit's display parameters,
/// which answer on older Intel Macs. Everything degrades to Command Echo's stepped estimate.
enum DisplayBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    /// Resolved once; nil when the framework or the symbol isn't there.
    private static let displayServicesGet: GetBrightness? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    static func read() -> Double? {
        if let get = displayServicesGet {
            var value: Float = 0
            if get(CGMainDisplayID(), &value) == 0, value.isFinite { return Double(max(0, min(1, value))) }
        }
        return ioDisplay()
    }

    /// `IODisplayConnect` only exists for older (Intel, non-Apple-Silicon) displays; elsewhere the
    /// iterator is simply empty.
    private static func ioDisplay() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var value: Float = 0
            if IODisplayGetFloatParameter(service, 0, "brightness" as CFString, &value) == KERN_SUCCESS {
                return Double(max(0, min(1, value)))
            }
        }
        return nil
    }
}

// MARK: - Output volume (CoreAudio)

/// The default output device's volume and mute, read through the audio hardware service.
enum OutputVolume {
    struct Reading { var level: Double; var muted: Bool }

    static func read() -> Reading? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if !(AudioObjectHasProperty(device, &address) && AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr) {
            // No virtual main volume (some devices): the loudest of the first two channels.
            var best: Float32 = -1
            for channel in 1...2 {
                var perChannel = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                            mScope: kAudioObjectPropertyScopeOutput, mElement: UInt32(channel))
                var v: Float32 = 0
                var s = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectHasProperty(device, &perChannel), AudioObjectGetPropertyData(device, &perChannel, 0, nil, &s, &v) == noErr {
                    best = max(best, v)
                }
            }
            guard best >= 0 else { return nil }
            volume = best
        }
        var muted: UInt32 = 0
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) {
            _ = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted)
        }
        return Reading(level: Double(max(0, min(1, volume))), muted: muted != 0)
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}

// MARK: - The pill

/// What the HUD shows: a symbol tile, then either key glyphs + a label, or a level bar.
struct EchoContent: Equatable {
    var symbol: String
    var keys: String
    var text: String
    /// Dim, right-aligned context: the app, what was copied, "On".
    var detail: String = ""
    /// Colours the tile and the pill's rim (cut red, undo amber, save green…).
    var tint: NSColor? = nil
    /// A colour you copied, drawn as a small swatch before `detail`.
    var swatch: NSColor? = nil
    var level: Double? = nil
    var trailingSymbol: String? = nil
    /// Voice bars for the right wing (0…1, oldest first), while the mic listens.
    var bars: [Double]? = nil

    init(symbol: String, keys: String, text: String, detail: String = "", tint: NSColor? = nil,
         swatch: NSColor? = nil, level: Double? = nil, trailingSymbol: String? = nil, bars: [Double]? = nil) {
        self.symbol = symbol; self.keys = keys; self.text = text; self.detail = detail
        self.tint = tint; self.swatch = swatch; self.level = level; self.trailingSymbol = trailingSymbol
        self.bars = bars
    }

    /// What the clipboard holds replaces the app name on the right.
    mutating func apply(_ p: ClipPreview) {
        detail = p.detail
        swatch = p.color
        if let c = p.color { tint = c }
        if let s = p.symbol { trailingSymbol = s }
    }
}

// MARK: - What's on the clipboard

/// A one-line description of the clipboard for the pill. Reads only the general pasteboard's
/// declared types and, for text, at most its first line.
struct ClipPreview {
    var detail: String
    var symbol: String? = nil
    var color: NSColor? = nil

    @MainActor
    static func read() -> ClipPreview? {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        if types.isEmpty { return nil }
        if ClipboardStore.isPrivate(types) { return ClipPreview(detail: "Hidden", symbol: "lock.fill") }
        if types.contains(.color), let c = NSColor(from: pb) { return ClipPreview(detail: ColorText.hex(c), color: c) }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first {
            let name = first.lastPathComponent
            return ClipPreview(detail: urls.count > 1 ? "\(name) +\(urls.count - 1)" : name, symbol: "doc.fill")
        }
        if let text = pb.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let c = ColorText.parse(trimmed) { return ClipPreview(detail: ColorText.hex(c), color: c) }
            if let url = URL(string: trimmed), let scheme = url.scheme, scheme.hasPrefix("http"), let host = url.host,
               !trimmed.contains(" ") {
                return ClipPreview(detail: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, symbol: "link")
            }
            let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
            if !line.isEmpty { return ClipPreview(detail: String(line.prefix(80))) }
        }
        if types.contains(.tiff) || types.contains(.png) { return ClipPreview(detail: "Image", symbol: "photo") }
        return nil
    }
}

/// Colours written as text: #RGB, #RGBA, #RRGGBB, #RRGGBBAA (or 0x…), rgb()/rgba(), hsl()/hsla().
enum ColorText {
    static func parse(_ raw: String) -> NSColor? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.count <= 48 else { return nil }
        return hexColor(s) ?? functional(s)
    }

    /// "#4DBDFF" (and "#4DBDFF80" when it isn't opaque), in sRGB.
    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "Colour" }
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        var out = String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
        if c.alphaComponent < 0.999 { out += String(format: "%02X", byte(c.alphaComponent)) }
        return out
    }

    private static func hexColor(_ s: String) -> NSColor? {
        var h = Substring(s)
        if h.hasPrefix("#") { h = h.dropFirst() } else if h.hasPrefix("0x") { h = h.dropFirst(2) } else { return nil }
        guard [3, 4, 6, 8].contains(h.count), h.allSatisfy(\.isHexDigit) else { return nil }
        var digits = String(h)
        if digits.count <= 4 { digits = String(digits.flatMap { [$0, $0] }) }
        guard let v = UInt64(digits, radix: 16) else { return nil }
        let opaque = digits.count == 6
        let rgba = opaque ? (v << 8) | 0xFF : v
        func ch(_ shift: UInt64) -> CGFloat { CGFloat((rgba >> shift) & 0xFF) / 255 }
        return NSColor(srgbRed: ch(24), green: ch(16), blue: ch(8), alpha: ch(0))
    }

    private static func functional(_ s: String) -> NSColor? {
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let name = s[..<open].trimmingCharacters(in: .whitespaces)
        let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
        let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        /// A number, or a percentage of 1; plain numbers are divided by `scale`.
        func num(_ p: String, scale: Double) -> Double? {
            if p.hasSuffix("%") { return Double(p.dropLast()).map { $0 / 100 } }
            return Double(p).map { $0 / scale }
        }
        guard let alpha = parts.count == 4 ? num(parts[3], scale: 1) : 1 else { return nil }
        func clamp(_ v: Double) -> CGFloat { CGFloat(max(0, min(1, v))) }
        switch name {
        case "rgb", "rgba":
            guard let r = num(parts[0], scale: 255), let g = num(parts[1], scale: 255), let b = num(parts[2], scale: 255) else { return nil }
            return NSColor(srgbRed: clamp(r), green: clamp(g), blue: clamp(b), alpha: clamp(alpha))
        case "hsl", "hsla":
            guard let hue = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
                  let sat = num(parts[1], scale: 100), let light = num(parts[2], scale: 100) else { return nil }
            let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
            let sv = max(0, min(1, sat)), lv = max(0, min(1, light))
            let c = (1 - abs(2 * lv - 1)) * sv
            let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
            let m = lv - c / 2
            let (r, g, b): (Double, Double, Double)
            switch Int(h) {
            case 0: (r, g, b) = (c, x, 0)
            case 1: (r, g, b) = (x, c, 0)
            case 2: (r, g, b) = (0, c, x)
            case 3: (r, g, b) = (0, x, c)
            case 4: (r, g, b) = (x, 0, c)
            default: (r, g, b) = (c, 0, x)
            }
            return NSColor(srgbRed: clamp(r + m), green: clamp(g + m), blue: clamp(b + m), alpha: clamp(alpha))
        default:
            return nil
        }
    }
}

/// The notch itself grows to answer, Glance-style: it stays the height of the notch and
/// widens sideways, words on the left of the camera and the answer on the right, with a thin
/// glowing rim in the event's colour. Levels also light the arms along the top edge of the
/// screen (`EdgeLight`). Springs open from exactly the notch's size and folds back into it.
/// Never takes focus or the pointer. With Reduce Motion it just fades.
@MainActor
final class EchoHUD {
    /// Room around the shape for the rim's glow.
    private static let glowRoom: CGFloat = 48
    private static let maxWidth: CGFloat = 760

    private let panel: FloatingPanel
    private let view = EchoNotchView()
    private var shown = false
    private var generation = 0
    private var displayObserver: NSObjectProtocol?
    private(set) var currentContent: EchoContent?

    init() {
        panel = FloatingPanel.make(size: NSSize(width: Self.maxWidth, height: 60), level: .popUpMenu, keyable: false)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.title = "Command feedback"
        panel.contentView = view
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let content = self.currentContent else { return }
                    if self.shown {
                        _ = self.place()
                        self.view.show(content, animated: false, forceLayout: true)
                    } else { self.show(content) }
                }
            }
    }

    deinit {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }

    var isVisible: Bool { shown && panel.isVisible && panel.alphaValue > 0.01 }
    var contourWidth: CGFloat? {
        currentContent.map { min(view.bounds.width - 24, EchoRowView.width(for: $0, gap: view.notchSize.width))
            + 2 * NotchGeometry.shoulderWidth(height: view.notchSize.height) }
    }
    #if DEBUG
    func focusVisualReview() {
        panel.keyable = true
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif

    /// Swap what it shows without touching its timing (a level read again after a key).
    func update(_ c: EchoContent) {
        guard shown else { return }
        currentContent = c
        view.show(c, animated: true)
    }

    func show(_ c: EchoContent) {
        generation += 1
        currentContent = c
        // During a display disconnect WindowServer can briefly report no screens. Keep the
        // current event until its normal expiry and place it if a screen returns meanwhile.
        guard !NSScreen.screens.isEmpty else { return }
        let moved = place()
        EdgeLight.shared.feedbackVisible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        if !shown {
            shown = true
            panel.orderFrontRegardless()
            view.collapse(animated: false)
        }
        view.show(c, animated: true, forceLayout: moved)
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZERA_REVIEW_FEEDBACK"] == "volume" {
            Diag.log("review HUD show generation \(generation), visible \(panel.isVisible), alpha \(panel.alphaValue)")
        }
        #endif
    }

    func hide(animated: Bool) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZERA_REVIEW_FEEDBACK"] == "volume" {
            Diag.log("review HUD hide generation \(generation): " + Thread.callStackSymbols.filter { $0.contains("Zera") }.prefix(5).joined(separator: " | "))
        }
        #endif
        currentContent = nil
        let wasShown = shown
        shown = false
        generation += 1
        let gen = generation
        guard animated, !Motion.reduced, wasShown else {
            view.collapse(animated: false); panel.orderOut(nil)
            EdgeLight.shared.feedbackVisible = false
            return
        }
        // Fade in place: shrinking the black shape while its halo was still wide created
        // a detached border. A new event supersedes this fade and retains its own contour.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown, gen == self.generation else { return }
                self.panel.orderOut(nil)
                self.view.collapse(animated: false)
                EdgeLight.shared.feedbackVisible = false
            }
        })
    }

    /// Centred on the notch, flush with the top of its screen.
    @discardableResult private func place() -> Bool {
        guard !NSScreen.screens.isEmpty else { return false }
        let g = NotchGeometry.detect()
        let notch = g.notchRect
        let frame = NotchGeometry.feedbackFrame(screen: g.screen.frame, notch: notch,
                                                maxWidth: g.screen.frame.width, glowRoom: max(Self.glowRoom, EdgeLight.shared.size.depth * 1.3))
        let changed = panel.frame != frame || view.notchSize != notch.size
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if view.frame.size != frame.size { view.frame = NSRect(origin: .zero, size: frame.size) }
        if view.notchSize != notch.size { view.notchSize = notch.size }
        return changed
    }
}

/// The growing notch: a black shape, its glowing rim, and the two wings' content.
final class EchoNotchView: NSView {
    var notchSize = NSSize(width: 190, height: 32) { didSet { needsLayout = true } }
    private let shape = CAShapeLayer()
    private var halo: GlowStrip?
    private var haloSignature = ""
    private let haloLevelMask = LightLevelMask()
    private let rim = CAShapeLayer()
    private let row = EchoRowView()
    private let innerGlow = CAGradientLayer()
    private let glowMask = CAShapeLayer()
    private let levelTrack = CAShapeLayer()
    private let levelFill = CAShapeLayer()
    private var expandedWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        wantsLayer = true
        layer?.masksToBounds = false
        shape.fillColor = NSColor.black.cgColor
        rim.fillColor = nil
        rim.lineWidth = 1.2
        rim.lineCap = .round
        rim.shadowOffset = .zero
        rim.shadowRadius = 5
        rim.shadowOpacity = 1
        layer?.addSublayer(shape)
        innerGlow.mask = glowMask
        innerGlow.startPoint = CGPoint(x: 0.5, y: 1)
        innerGlow.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(innerGlow)
        for bar in [levelTrack, levelFill] {
            bar.fillColor = nil
            bar.lineWidth = 3
            bar.lineCap = .round
            bar.isHidden = true
        }
        row.wantsLayer = true
        row.layer?.masksToBounds = true
        row.layer?.addSublayer(levelTrack)
        row.layer?.addSublayer(levelFill)
        layer?.addSublayer(rim)
        row.alphaValue = 0
        addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The notch grown to `w` × `h`, hanging from the top edge, with small flares where it meets
    /// the menu bar. `closed: false` leaves the path open along the top (for the rim).
    private func path(width w: CGFloat, height h: CGFloat, closed: Bool) -> CGPath {
        let shoulder = NotchGeometry.shoulderWidth(height: h)
        let rect = CGRect(x: bounds.midX - w / 2 - shoulder, y: bounds.maxY - h,
                          width: w + 2 * shoulder, height: h)
        return NotchGeometry.notchOutline(in: rect, closed: closed)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds
        rim.frame = bounds
        innerGlow.frame = bounds
        glowMask.frame = bounds
        CATransaction.commit()
    }

    private func setShape(width: CGFloat, animated: Bool, spring: Bool, completion: (() -> Void)? = nil) {
        let h = notchSize.height
        let fill = path(width: width, height: h, closed: true)
        let edge = path(width: width, height: h, closed: false)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        if animated && !Motion.reduced {
            for (layer, to) in [(shape, fill), (rim, edge), (glowMask, fill)] {
                let from = layer.presentation()?.path ?? layer.path
                let a: CABasicAnimation
                if spring {
                    let s = CASpringAnimation(keyPath: "path")
                    s.damping = 16; s.stiffness = 260; s.mass = 1; s.initialVelocity = 0
                    s.duration = s.settlingDuration
                    a = s
                } else {
                    a = CABasicAnimation(keyPath: "path")
                    a.duration = 0.2
                    a.timingFunction = CAMediaTimingFunction(name: .easeIn)
                }
                a.fromValue = from
                a.toValue = to
                layer.add(a, forKey: "grow")
            }
        }
        CATransaction.setDisableActions(true)
        shape.path = fill
        glowMask.path = fill
        rim.path = edge
        CATransaction.commit()
    }

    func show(_ c: EchoContent, animated: Bool, forceLayout: Bool = false) {
        setAccessibilityLabel([c.keys, c.text, c.detail].filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityValue(c.level.map { "\(Int((min(1, max(0, $0)) * 100).rounded()))%" })
        let w = min(bounds.width - 24, EchoRowView.width(for: c, gap: notchSize.width))
        // The same light as the notch's edge and the glow along the screen: one colour, one rim.
        let tint = c.tint ?? WallpaperTint.lightAccent
        let settings = EdgeLight.shared
        let signature = "\(settings.style.rawValue)|\(settings.size.rawValue)|\(NotchLightStyle.intensity)|\(tint)|\(bounds.size)"
        let shoulder = NotchGeometry.shoulderWidth(height: notchSize.height)
        let notch = CGRect(x: bounds.midX - w / 2 - shoulder, y: bounds.maxY - notchSize.height,
                           width: w + 2 * shoulder, height: notchSize.height)
        let outline = NotchGeometry.topLightPath(bounds: bounds, notch: notch, withArms: settings.mode != .notch)
        if halo == nil || signature != haloSignature {
            halo?.stopLoops(); halo?.layer.removeFromSuperlayer()
            halo = GlowStrip(frame: bounds, edge: .top, depth: settings.size.depth,
                             color: tint, style: settings.style, contour: outline)
            if let halo { layer?.insertSublayer(halo.layer, below: shape) }
            haloSignature = signature
        } else { halo?.updateContour(outline) }
        halo?.layer.isHidden = !NotchLightStyle.reactionsEnabled
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.duration(0.18))
        if let level = c.level {
            haloLevelMask.update(bounds: bounds, notch: notch, value: CGFloat(level))
            halo?.layer.mask = haloLevelMask.layer
        } else { halo?.layer.mask = nil }
        halo?.layer.opacity = 1
        CATransaction.commit()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rim.removeAnimation(forKey: "fade")
        rim.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        rim.shadowColor = tint.cgColor
        rim.shadowOpacity = c.level == nil ? 0 : 0.18
        rim.shadowRadius = 3
        rim.opacity = 0
        innerGlow.colors = [NSColor.clear.cgColor, tint.withAlphaComponent(c.level == nil ? 0.03 : 0.14).cgColor]
        levelTrack.isHidden = c.level == nil
        levelFill.isHidden = c.level == nil
        CATransaction.commit()
        let grew = abs(w - expandedWidth) > 0.5
        expandedWidth = w
        if grew || row.alphaValue < 0.99 || forceLayout { setShape(width: w, animated: false, spring: true) }
        if let level = c.level { showLevel(level, width: w, tint: tint, animated: animated && !forceLayout) }
        row.gap = notchSize.width
        row.content = c
        row.frame = NSRect(x: (bounds.midX - w / 2).rounded(), y: bounds.maxY - notchSize.height,
                           width: w.rounded(), height: notchSize.height)
        // The words wait until the wings have mostly grown, so they never show outside the black.
        if row.alphaValue < 0.99, fadeToken == nil {
            let token = UUID()
            fadeToken = token
            let delay = animated && !Motion.reduced ? 0.13 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.fadeToken == token else { return }
                self.fadeToken = nil
                guard self.expandedWidth > 0 else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.duration(0.16)
                    self.row.animator().alphaValue = 1
                }
            }
        }
    }

    private var fadeToken: UUID?

    /// Retarget from the visible fill when a key repeats; no restart at zero or extra timer.
    private func showLevel(_ value: Double, width: CGFloat, tint: NSColor, animated: Bool) {
        let x = width / 2 + notchSize.width / 2 + 14
        let end = width - 66
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: notchSize.height / 2))
        path.addLine(to: CGPoint(x: max(x, end), y: notchSize.height / 2))
        let from = levelFill.presentation()?.strokeEnd ?? levelFill.strokeEnd
        let target = CGFloat(min(1, max(0, value)))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let frame = CGRect(x: 0, y: 0, width: width, height: notchSize.height)
        levelTrack.frame = frame; levelFill.frame = frame
        levelTrack.path = path; levelFill.path = path
        levelTrack.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        levelFill.strokeColor = tint.blended(withFraction: 0.25, of: .white)?.cgColor ?? tint.cgColor
        levelFill.strokeEnd = target
        CATransaction.commit()
        if animated, !Motion.reduced {
            let change = CABasicAnimation(keyPath: "strokeEnd")
            change.fromValue = from; change.toValue = target
            change.duration = Motion.selectionDuration
            change.timingFunction = CAMediaTimingFunction(name: .easeOut)
            levelFill.add(change, forKey: "level")
        } else { levelFill.removeAnimation(forKey: "level") }
    }

    func collapse(animated: Bool, completion: (() -> Void)? = nil) {
        halo?.stopLoops(); halo?.layer.removeFromSuperlayer(); halo = nil; haloSignature = ""
        expandedWidth = 0
        fadeToken = nil
        levelTrack.isHidden = true
        levelFill.isHidden = true
        innerGlow.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        guard animated, !Motion.reduced else {
            row.alphaValue = 0
            setShape(width: notchSize.width, animated: false, spring: false)
            rim.opacity = 0
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            row.animator().alphaValue = 0
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = rim.opacity; fade.toValue = 0; fade.duration = 0.2
        rim.add(fade, forKey: "fade")
        rim.opacity = 0
        setShape(width: notchSize.width, animated: true, spring: false, completion: completion)
    }
}

/// The two wings' content: symbol and label left of the camera, the answer right of it.
private final class EchoRowView: NSView {
    var content = EchoContent(symbol: "command", keys: "", text: "") { didSet { if content != oldValue { needsDisplay = true } } }
    /// The camera's width in the middle: nothing is drawn there.
    var gap: CGFloat = 190 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let pad: CGFloat = 14
    private static let symbolBox: CGFloat = 16
    private static let labelFont = Typo.bodyStrong
    private static let keysFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let detailFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let sideMax: CGFloat = 220
    private static let swatch: CGFloat = 13
    private static let barCount = 7

    private static func w(_ s: String, _ f: NSFont) -> CGFloat { s.isEmpty ? 0 : ceil((s as NSString).size(withAttributes: [.font: f]).width) }

    private static func percent(_ c: EchoContent) -> String? { c.level.map { "\(Int((max(0, min(1, $0)) * 100).rounded()))%" } }

    /// The widths the left and right wings want.
    private static func sides(_ c: EchoContent) -> (CGFloat, CGFloat) {
        var left = symbolBox + 8 + w(c.text, labelFont)
        if !c.keys.isEmpty { left += 6 + w(c.keys, keysFont) }
        var right: CGFloat = 0
        if let bars = c.bars, !bars.isEmpty { right = CGFloat(barCount) * 5 }
        else if percent(c) != nil {
            // Reserve the progress track as well as its percentage; measuring only the
            // number squeezed volume feedback into a barely visible dash.
            right = 96 + 12 + w("100%", detailFont)
        }
        else {
            if !c.detail.isEmpty { right += min(sideMax, w(c.detail, detailFont)) }
            if c.swatch != nil { right += swatch + 7 }
            if c.trailingSymbol != nil { right += 20 }
        }
        return (min(sideMax, left), min(sideMax, right))
    }

    /// Symmetric about the notch: as wide as the wider wing on both sides.
    static func width(for c: EchoContent, gap: CGFloat) -> CGFloat {
        let (l, r) = sides(c)
        return gap + 2 * (max(l, r, 40) + pad + 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = content
        let h = bounds.height
        let tint = c.tint.flatMap { $0.blended(withFraction: 0.3, of: .white) } ?? .white
        let wing = max(0, (bounds.width - gap) / 2)
        let leftMax = wing - Self.pad - 8
        // Left wing: symbol, label, keys.
        drawSymbol(c.symbol, in: NSRect(x: Self.pad, y: (h - Self.symbolBox) / 2, width: Self.symbolBox, height: Self.symbolBox),
                   pointSize: 12, color: tint)
        var x = Self.pad + Self.symbolBox + 8
        if !c.text.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: NSColor.white,
                                                        .paragraphStyle: Self.truncating(.left)]
            let size = (c.text as NSString).size(withAttributes: attrs)
            let wdt = min(max(0, leftMax - x + Self.pad), ceil(size.width))
            (c.text as NSString).draw(in: NSRect(x: x, y: (h - size.height) / 2, width: wdt, height: ceil(size.height)), withAttributes: attrs)
            x += wdt
        }
        if !c.keys.isEmpty, x + 20 < wing {
            let a: [NSAttributedString.Key: Any] = [.font: Self.keysFont, .foregroundColor: NSColor.white.withAlphaComponent(0.45)]
            let size = (c.keys as NSString).size(withAttributes: a)
            (c.keys as NSString).draw(at: NSPoint(x: x + 6, y: (h - size.height) / 2), withAttributes: a)
        }
        // Right wing, right-aligned.
        var right = bounds.width - Self.pad
        let rightMin = bounds.width - wing + 8
        if let bars = c.bars, !bars.isEmpty {
            let n = Self.barCount
            for i in 0..<n {
                let v = CGFloat(i < bars.count ? max(0.08, min(1, bars[bars.count - 1 - i])) : 0.08)
                let bh = max(3, (h - 14) * v)
                let r = NSRect(x: right - CGFloat(i + 1) * 5 + 1, y: (h - bh) / 2, width: 3, height: bh)
                tint.withAlphaComponent(0.55 + 0.45 * v).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return
        }
        if let p = Self.percent(c) {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.8)]
            let size = (p as NSString).size(withAttributes: a)
            (p as NSString).draw(at: NSPoint(x: right - size.width, y: (h - size.height) / 2), withAttributes: a)
            return
        }
        if let trailing = c.trailingSymbol {
            drawSymbol(trailing, in: NSRect(x: right - 14, y: (h - 14) / 2, width: 14, height: 14), pointSize: 11,
                       color: NSColor.white.withAlphaComponent(0.7))
            right -= 20
        }
        if !c.detail.isEmpty {
            let a: [NSAttributedString.Key: Any] = [.font: Self.detailFont, .foregroundColor: NSColor.white.withAlphaComponent(0.7),
                                                    .paragraphStyle: Self.truncating(.right)]
            let size = (c.detail as NSString).size(withAttributes: a)
            let wdt = min(ceil(size.width), max(0, right - rightMin - (c.swatch == nil ? 0 : Self.swatch + 7)))
            (c.detail as NSString).draw(in: NSRect(x: right - wdt, y: (h - size.height) / 2, width: wdt, height: ceil(size.height)),
                                        withAttributes: a)
            right -= wdt + 7
        }
        if let sw = c.swatch, right - Self.swatch >= rightMin {
            let r = NSRect(x: right - Self.swatch, y: (h - Self.swatch) / 2, width: Self.swatch, height: Self.swatch)
            let path = NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5)
            sw.setFill(); path.fill()
            NSColor.white.withAlphaComponent(0.6).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }

    private static func truncating(_ align: NSTextAlignment) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        p.alignment = align
        return p
    }

    private func drawSymbol(_ name: String, in rect: NSRect, pointSize: CGFloat, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [color])) else { return }
        let size = image.size
        let box = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
