import AppKit

enum Theme {
    // MARK: Notch buddy

    /// How tall she is below the notch / menu bar.
    static let figureHeight: CGFloat = 44
    /// How far her picture reaches up into the notch / menu bar band, so the rope stays short.
    static let topTuck: CGFloat = 6
    /// Within this distance of the notch centre she snaps back to it when dropped.
    static let snapDistance: CGFloat = 28
    /// Width of her window — wider than she is so the sway has room.
    static let buddyWidth: CGFloat = 110
    /// Width of the pretend notch on Macs without one.
    static let virtualNotchWidth: CGFloat = 180
    /// Pointer stillness before she dozes off.
    static let sleepAfter: TimeInterval = 240
    /// Gap between her feet and a card hanging under her.
    static let cardGap: CGFloat = 10
    /// How long the pointer may be away from her / the pill before the pill folds away.
    static let pillLinger: TimeInterval = 0.5

    // MARK: Shelf grid

    static let panelWidth: CGFloat = 360
    static let corner: CGFloat = Radius.card
    static let tileWidth: CGFloat = 104
    static let tileHeight: CGFloat = 84
    static let tileGap: CGFloat = 8
    static let tileCorner: CGFloat = Radius.l
    static let thumbSize: CGFloat = 42
    static let gridColumns: Int = 3
    static let pad: CGFloat = 16
    static let maxVisibleGridRows: Int = 3

    // MARK: Colours

    static let purple = NSColor(srgbRed: 0.561, green: 0.482, blue: 1.000, alpha: 1.0)
    /// Selection / highlight colour used by the shelf tiles.
    static var accent: NSColor { Pal.accent }
    static let pillFill = NSColor(srgbRed: 0.120, green: 0.105, blue: 0.180, alpha: 0.94)
    static let bubbleFill = NSColor(srgbRed: 0.120, green: 0.105, blue: 0.180, alpha: 0.94)
    static let bubbleText = NSColor(srgbRed: 0.965, green: 0.955, blue: 1.000, alpha: 1.0)

    static func tileFill(_ selected: Bool, _ hovered: Bool) -> NSColor {
        let p = Pal
        if selected { return p.accentSoft }
        if hovered { return p.surfaceHover }
        return p.surface
    }

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

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

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
        p.hasShadow = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }
}
