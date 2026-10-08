import AppKit

enum Theme {
    // MARK: Notch buddy

    /// How tall she is below the notch / menu bar.
    static let figureHeight: CGFloat = 84
    /// How far her picture reaches up into the notch / menu bar band, so the rope stays short.
    static let topTuck: CGFloat = 18
    /// Within this distance of the notch centre she snaps back to it when dropped.
    static let snapDistance: CGFloat = 28
    /// Width of her window — much wider than she is, so the sway, hops, wiggles and sparkles
    /// never reach its edges.
    static let buddyWidth: CGFloat = 220
    /// Empty room under her feet inside her window, for bounces and the ripple.
    static let figurePad: CGFloat = 24
    /// Width of the pretend notch on Macs without one.
    static let virtualNotchWidth: CGFloat = 180
    /// Pointer stillness before she dozes off.
    static let sleepAfter: TimeInterval = 240
    /// How long the pointer may be away from her / the widened notch before it folds back.
    static let pillLinger: TimeInterval = 0.5

    // MARK: Window & thumbnails

    static let panelWidth: CGFloat = 360
    static let thumbSize: CGFloat = 42

    // MARK: Colours

    static let purple = NSColor(srgbRed: 0.561, green: 0.482, blue: 1.000, alpha: 1.0)
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}

extension NSView {
    func roundLayer(_ radius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}

func byteString(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useKB, .useMB, .useGB]
    return f.string(fromByteCount: bytes)
}

/// Borderless floating panel used for the nook, the speech bubble and the shelf.
final class FloatingPanel: NSPanel {
    /// Whether this panel may take keyboard focus (the shelf does, for ⎋ and ⌫).
    var keyable = false
    /// Window-scoped commands that must also work when a control takes first responder.
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyDown?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    static func make(size: NSSize, level: NSWindow.Level, keyable: Bool) -> FloatingPanel {
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.keyable = keyable
        p.isFloatingPanel = true
        p.level = level
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isMovable = false
        p.hasShadow = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }
}
