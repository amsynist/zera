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
    /// Empty room under her feet (bounces, the ripple); not part of her body.
    var bottomPad: CGFloat = 0 {
        didSet { zera.bottomPad = bottomPad; needsLayout = true }
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

    /// One ring: starts just around her body, grows and fades out.
    func ping(strong: Bool = false) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let f = figureBounds
        // Around her body, which hangs beside the rope in the Claude pose.
        let bodyX = f.midX + (zera.activity == .none ? 0 : zera.claudeBodyOffset)
        let center = CGPoint(x: bodyX, y: f.minY + f.height * 0.45)
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

    /// Hovering: one gentle ping when the pointer arrives on her (not a constant ripple).
    func setRadar(active: Bool) {
        radarTimer?.invalidate(); radarTimer = nil
        if active { ping() }
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
        NSRect(x: bounds.midX - 32, y: bottomPad, width: 64, height: max(0, bounds.height - hangInset - bottomPad))
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

/// A compact caption in the island's navy glass. Lives in its own click-through panel.
final class BubbleView: NSView {
    var text: String = "" {
        didSet {
            label.stringValue = text
            setAccessibilityLabel(text)
            needsLayout = true
        }
    }
    private let label = NSTextField(wrappingLabelWithString: "")

    static let font = Theme.font(12.5, .medium)
    static let hPad: CGFloat = 14
    static let vPad: CGFloat = 9
    static let maxWidth: CGFloat = 320
    static let gap: CGFloat = 12
    // NSTextField reserves two points at either side of its text cell.
    private static let cellInset: CGFloat = 4

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Self.font
        label.textColor = Neon.text
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func size(for text: String, maxWidth: CGFloat = BubbleView.maxWidth) -> NSSize {
        let width = min(Self.maxWidth, maxWidth)
        let textWidth = max(1, min(width - hPad * 2 - cellInset,
                                  ceil((text as NSString).size(withAttributes: [.font: font]).width)))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return NSSize(width: min(width, max(70, textWidth + hPad * 2 + cellInset)),
                      height: min(lineHeight * 3, max(lineHeight, ceil(measured.height))) + vPad * 2)
    }

    /// Screen coordinates: keep captions clear of Zera, the menu bar and any open surface.
    static func frame(for size: NSSize, figure: NSRect, safeFrame: NSRect,
                      obstacle: NSRect? = nil, below: Bool = false) -> NSRect {
        let occupied = obstacle.map { $0.union(figure) } ?? figure
        let y = min(safeFrame.maxY - size.height,
                    figure.minY + figure.height * 0.55 - size.height / 2)
        if !below {
            let right = NSRect(x: occupied.maxX + gap, y: y, width: size.width, height: size.height)
            if safeFrame.contains(right) { return right.integral }
            let left = NSRect(x: occupied.minX - gap - size.width, y: y, width: size.width, height: size.height)
            if safeFrame.contains(left) { return left.integral }
        }
        let x = max(safeFrame.minX, min(safeFrame.maxX - size.width, figure.midX - size.width / 2))
        return NSRect(x: x.rounded(), y: (occupied.minY - gap - size.height).rounded(),
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.hPad, dy: Self.vPad)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSGradient(starting: Neon.fillTop, ending: Neon.fillBottom)?.draw(in: path, angle: 90)
        Neon.edge.withAlphaComponent(0.4).setStroke()
        path.lineWidth = 1
        path.stroke()
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
