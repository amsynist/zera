import AppKit
import Carbon.HIToolbox

/// A key combination you chose, stored the way Carbon hot keys want it, with its label ("⇧⌘V").
struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey | shiftKey | …).
    var modifiers: UInt32
    /// The key's own name: "V", "Space", "F5", "→".
    var key: String

    static let `default` = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), key: "V")

    /// ⌃⌥⇧⌘ in the order macOS menus show them, then the key.
    var label: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// A shortcut needs ⌘, ⌥ or ⌃: Shift alone (or nothing) would swallow ordinary typing.
    var isUsable: Bool { modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// Just the modifier symbols, for showing what's held down while recording.
    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        HotKeyShortcut(keyCode: 0, modifiers: carbonModifiers(flags), key: "").label
    }

    /// The name of the key in a key-down event.
    static func keyName(keyCode: UInt16, characters: String?) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = special[Int(keyCode)] { return s }
        return (characters ?? "").uppercased()
    }
}

/// A keyboard shortcut that works from any app (Carbon hot keys: no permission needed).
/// Keep the object alive for as long as the shortcut should work; it unregisters on deinit.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    /// Nil when macOS refuses it (another app already owns that combination).
    init?(_ shortcut: HotKeyShortcut, handler: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5A455241), id: id)   // 'ZERA'
        var out: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &out)
        guard status == noErr, let r = out else { return nil }
        ref = r
        Self.handlers[id] = handler
    }

    deinit {
        if let r = ref { UnregisterEventHotKey(r) }
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return err }
            let id = hk.id
            DispatchQueue.main.async { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Click it, press the keys you want: a shortcut field. Esc cancels, ⌫ turns the shortcut off.
/// `onChange` returns false when the combination can't be used (taken by another app).
final class ShortcutRecorder: NSView {
    var shortcut: HotKeyShortcut? { didSet { needsDisplay = true } }
    var onChange: ((HotKeyShortcut?) -> Bool)?
    /// Recording started / stopped: the live shortcut is paused meanwhile so pressing it is recorded.
    var onRecording: ((Bool) -> Void)?
    var isRecording: Bool { recording }
    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            held = ""
            message = nil
            onRecording?(recording)
            needsDisplay = true
        }
    }
    private var held = ""
    private var message: String?
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateAccessibility() {
        setAccessibilityLabel("Shortcut")
        setAccessibilityValue(recording ? "Recording" : (shortcut?.label ?? "Off"))
        toolTip = recording ? "Press the keys · Esc cancels · ⌫ turns it off" : "Click, then press the keys you want"
    }

    override func mouseDown(with event: NSEvent) { toggle() }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }

    private func toggle() {
        if recording { stop(); return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        recording = true
        updateAccessibility()
    }

    override func resignFirstResponder() -> Bool {
        if recording { recording = false; updateAccessibility() }
        return super.resignFirstResponder()
    }

    private func stop() {
        recording = false
        updateAccessibility()
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { super.flagsChanged(with: event); return }
        held = HotKeyShortcut.symbols(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        message = nil
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘-combinations arrive here first; record them instead of letting menus take them.
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mods = HotKeyShortcut.carbonModifiers(flags)
        if Int(event.keyCode) == kVK_Escape, mods == 0 { stop(); return }
        if (Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete), mods == 0 {
            if onChange?(nil) ?? true { shortcut = nil }
            stop()
            return
        }
        let s = HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: mods,
                               key: HotKeyShortcut.keyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers))
        guard s.isUsable else {
            message = "Add ⌘, ⌥ or ⌃"
            NSSound.beep()
            needsDisplay = true
            return
        }
        guard onChange?(s) ?? true else {
            message = "Taken, try another"
            NSSound.beep()
            needsDisplay = true
            return
        }
        shortcut = s
        stop()
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: Radius.m, yRadius: Radius.m)
        if recording {
            p.selectedFill.setFill(); path.fill()
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow(); glow.shadowColor = p.accent.withAlphaComponent(0.6); glow.shadowBlurRadius = 6; glow.set()
            p.accent.setStroke(); path.lineWidth = 1.5; path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            (hovered ? p.surfaceHover : p.field).setFill(); path.fill()
            (hovered ? p.accentBorder : p.border).setStroke(); path.lineWidth = 1; path.stroke()
        }
        let text: String
        let color: NSColor
        let font: NSFont
        if recording {
            if let m = message { text = m; color = p.warning; font = Typo.bodyMedium }
            else if !held.isEmpty { text = held + "…"; color = p.text; font = .systemFont(ofSize: 14, weight: .semibold) }
            else { text = "Press keys…"; color = p.accent; font = Typo.bodyMedium }
        } else if let s = shortcut {
            text = s.label; color = p.text; font = .systemFont(ofSize: 14, weight: .semibold)
        } else {
            text = "Off · click to set"; color = p.textSecondary; font = Typo.body
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
