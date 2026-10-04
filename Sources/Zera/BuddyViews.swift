import AppKit

/// Zera dangling from the notch. Fully transparent apart from her: clicks land only on
/// the part of the window where she actually is, so the menu bar stays usable.
final class BuddyView: NSView {
    let zera = ZeraView()

    /// Fired on click (a press that did not turn into a drag) — opens her default card.
    var onActivate: (() -> Void)?
    /// Dragging her along the top edge: began / pointer screen-x moved / let go.
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var pressPoint = NSPoint.zero
    private var dragging = false
    /// Something was dropped straight onto her.
    var onDrop: ((NSPasteboard) -> Bool)?
    /// True when a drag arrives over her, false when it leaves or lands.
    var onDragStateChange: ((Bool) -> Void)?

    /// Points at the top that belong to the notch / menu bar; input there passes through.
    var hangInset: CGFloat = 0 {
        didSet { zera.hangInset = hangInset }
    }

    /// Soft rings that grow out from her like a radar ping — one per tap, repeating on hover.
    private let radar = CALayer()
    private var radarTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        radar.frame = bounds
        layer?.addSublayer(radar)
        zera.style = .hanging
        zera.pose = .peek
        zera.framesPerSecond = 30
        addSubview(zera)
        registerForDraggedTypes([.fileURL, .png, .tiff, .pdf, .rtf, .string, .URL])
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { radarTimer?.invalidate() }

    /// One ring: starts just around her body, grows to ~2.6× and fades out.
    func ping(strong: Bool = false) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let f = figureBounds
        let center = CGPoint(x: f.midX, y: f.minY + f.height * 0.45)
        let r0: CGFloat = 18
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -r0, y: -r0, width: r0 * 2, height: r0 * 2), transform: nil)
        ring.position = center
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = Theme.purple.cgColor
        ring.lineWidth = strong ? 2.5 : 1.5
        ring.opacity = 0
        radar.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.55; scale.toValue = strong ? 1.7 : 1.4
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, strong ? 0.9 : 0.6, 0.0]; fade.keyTimes = [0, 0.15, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = strong ? 0.9 : 1.3
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        ring.add(group, forKey: "ping")
        DispatchQueue.main.asyncAfter(deadline: .now() + group.duration) { ring.removeFromSuperlayer() }
    }

    /// Hovering: a gentle repeating ping while the pointer stays on her.
    func setRadar(active: Bool) {
        radarTimer?.invalidate(); radarTimer = nil
        guard active else { return }
        ping()
        radarTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ping() }
        }
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        zera.frame = bounds
        radar.frame = bounds
    }

    /// Her body, in view coordinates: the strip below the notch, as wide as she is.
    var figureBounds: NSRect {
        NSRect(x: bounds.midX - 32, y: 0, width: 64, height: max(0, bounds.height - hangInset))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates; we are the content view so they match.
        NSPointInRect(convert(point, from: superview), figureBounds.insetBy(dx: -4, dy: 0)) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(figureBounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        pressPoint = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragging, abs(p.x - pressPoint.x) > 4 {
            dragging = true
            onDragBegan?()
        }
        if dragging { onDragMoved?(p.x) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            onDragEnded?()
        } else {
            ping(strong: true)
            onActivate?()
        }
    }

    // MARK: Drag & drop onto her

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragStateChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragStateChange?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragStateChange?(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}

/// Rounded speech bubble with a tail toward Zera. Lives in its own click-through panel.
final class BubbleView: NSView {
    enum Tail { case left, right }
    var text: String = "" { didSet { needsDisplay = true } }
    var tail: Tail = .right { didSet { needsDisplay = true } }

    static let font = Theme.font(12.5, .medium)
    static let tailSize: CGFloat = 8
    static let hPad: CGFloat = 13
    static let vPad: CGFloat = 8

    static func size(for text: String) -> NSSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(s.width) + hPad * 2 + tailSize,
                      height: ceil(s.height) + vPad * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = Self.tailSize
        let body = NSRect(x: tail == .left ? t : 0, y: 0, width: bounds.width - t, height: bounds.height)
        let path = NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2)
        let tailPath = NSBezierPath()
        if tail == .left {
            tailPath.move(to: NSPoint(x: body.minX + 2, y: body.midY + 6))
            tailPath.line(to: NSPoint(x: body.minX - t + 1, y: body.midY))
            tailPath.line(to: NSPoint(x: body.minX + 2, y: body.midY - 6))
        } else {
            tailPath.move(to: NSPoint(x: body.maxX - 2, y: body.midY + 6))
            tailPath.line(to: NSPoint(x: body.maxX + t - 1, y: body.midY))
            tailPath.line(to: NSPoint(x: body.maxX - 2, y: body.midY - 6))
        }
        tailPath.close()
        path.append(tailPath)
        Theme.bubbleFill.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Theme.bubbleText]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: body.minX + Self.hPad, y: body.midY - size.height / 2),
                                withAttributes: attrs)
    }
}

/// The three things you can open from her: the shelf, home and settings.
enum CardKind: Int, CaseIterable {
    case shelf, home, github, settings, approval, reminders, reminderAlert, toast
    /// Zera's answer about a file (Summarize / Explain / Extract / Ask).
    case result
    /// Live progress of your Claude Code sessions.
    case claude

    var title: String {
        switch self {
        case .shelf: return "Shelf"
        case .home: return "Home"
        case .github: return "GitHub"
        case .settings: return "Settings"
        case .approval: return "Claude Code"
        case .reminders: return "Reminders"
        case .reminderAlert: return "Reminder"
        case .toast: return "Notification"
        case .result: return "Zera"
        case .claude: return "Claude"
        }
    }

    var symbol: String {
        switch self {
        case .shelf: return "tray.full.fill"
        case .home: return "house.fill"
        case .github: return "arrow.triangle.pull"
        case .settings: return "gearshape.fill"
        case .approval: return "terminal.fill"
        case .reminders, .reminderAlert, .toast: return "bell.fill"
        case .result: return "sparkles"
        case .claude: return "terminal.fill"
        }
    }
}

/// Small pill of round buttons that fades in beside her on hover.
final class ActionPill: NSView {
    var onPick: ((CardKind) -> Void)?
    var defaultKind: CardKind = .shelf { didSet { needsDisplay = true } }
    /// The card that is open right now; it, not the default, wears the highlight while up.
    var activeKind: CardKind? { didSet { if activeKind != oldValue { needsDisplay = true } } }
    /// Red dot on a button (e.g. unseen GitHub activity).
    var badges: Set<CardKind> = [] { didSet { needsDisplay = true } }
    let kinds: [CardKind] = [.shelf, .home, .claude, .reminders, .github, .settings]

    static let buttonSize: CGFloat = 28
    static let gap: CGFloat = 4
    static let inset: CGFloat = 4

    static var preferredSize: NSSize {
        let n = CGFloat(6)
        return NSSize(width: inset * 2 + n * buttonSize + (n - 1) * gap, height: inset * 2 + buttonSize)
    }

    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func slot(_ i: Int) -> NSRect {
        NSRect(x: Self.inset + CGFloat(i) * (Self.buttonSize + Self.gap), y: Self.inset,
               width: Self.buttonSize, height: Self.buttonSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverIndex = kinds.indices.first { NSPointInRect(p, slot($0)) }
    }

    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = kinds.indices.first(where: { NSPointInRect(p, slot($0)) }) { onPick?(kinds[i]) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Theme.pillFill.setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        // Highlight the open card; with nothing open, the one a tap on her would open.
        let lit: CardKind = activeKind ?? defaultKind
        for (i, kind) in kinds.enumerated() {
            let r = slot(i)
            let isDefault = kind == lit
            let hot = hoverIndex == i
            if isDefault || hot {
                (isDefault ? Theme.purple.withAlphaComponent(hot ? 0.95 : 0.8) : NSColor.white.withAlphaComponent(0.14)).setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            let tint = isDefault ? NSColor.white : NSColor.white.withAlphaComponent(hot ? 0.95 : 0.75)
            if let img = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)?
                .withSymbolConfiguration(.init(pointSize: 12.5, weight: .semibold))?
                .withSymbolConfiguration(.init(hierarchicalColor: tint)) {
                let s = img.size
                img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: 1)
            }
            if badges.contains(kind) {
                NSColor(srgbRed: 1.0, green: 0.35, blue: 0.42, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.maxX - 8, y: r.maxY - 8, width: 7, height: 7)).fill()
            }
        }
    }
}
