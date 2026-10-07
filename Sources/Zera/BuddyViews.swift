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

/// Zera's caption: a small tag in the wings' navy glass that hangs under her feet, with a
/// tail pointing up at her and a tone dot for her mood. Lives in its own click-through panel;
/// the panel is `halo` larger than the tag on every side so the glow is not clipped.
final class BubbleView: NSView {
    var text: String = "" {
        didSet {
            label.stringValue = text
            setAccessibilityLabel(text)
            needsLayout = true
        }
    }
    /// Cyan for a neutral line, green when she's happy, amber while she's busy, red when upset.
    var tone: NSColor = Neon.cyan { didSet { needsDisplay = true } }
    /// Where the tail points, in this view's x coordinates.
    var tailX: CGFloat = 0 { didSet { needsDisplay = true } }
    private let label = NSTextField(wrappingLabelWithString: "")

    static let font = Theme.font(12.5, .medium)
    static let leadPad: CGFloat = 10
    static let trailPad: CGFloat = 13
    static let vPad: CGFloat = 7
    static let dot: CGFloat = 7
    static let dotGap: CGFloat = 8
    static let radius: CGFloat = 14
    static let tail: CGFloat = 6
    /// Widest the tag gets before it wraps to a second line.
    static let maxWidth: CGFloat = 280
    static let maxLines = 2
    /// Space between her (or the wings) and the tag.
    static let gap: CGFloat = 8
    /// Room around the tag for its halo and shadow.
    static let halo: CGFloat = 14
    // NSTextField reserves two points at either side of its text cell.
    private static let cellInset: CGFloat = 4
    private static var textLead: CGFloat { leadPad + dot + dotGap }
    private static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Self.font
        label.textColor = Neon.text
        label.maximumNumberOfLines = Self.maxLines
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The tag itself (not the panel): one line up to `maxWidth`, then two, then an ellipsis.
    static func size(for text: String, maxWidth: CGFloat = BubbleView.maxWidth) -> NSSize {
        let width = min(Self.maxWidth, maxWidth)
        let natural = ceil((text as NSString).size(withAttributes: [.font: font]).width) + cellInset
        let textWidth = max(1, min(width - textLead - trailPad, natural))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: textWidth - cellInset, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph])
        let lines = min(CGFloat(maxLines), max(1, (ceil(measured.height) / lineHeight).rounded()))
        return NSSize(width: ceil(textWidth + textLead + trailPad), height: lines * lineHeight + vPad * 2)
    }

    /// Screen coordinates for the tag: centred under `bodyX`, `gap` below her feet and below any
    /// obstacle it would touch (the wings, the island), clamped inside `safeFrame`, which already
    /// leaves out the menu bar.
    static func frame(for size: NSSize, figure: NSRect, bodyX: CGFloat? = nil, safeFrame: NSRect,
                      obstacles: [NSRect] = []) -> NSRect {
        let cx = bodyX ?? figure.midX
        let x = max(safeFrame.minX, min(safeFrame.maxX - size.width, cx - size.width / 2))
        var top = min(figure.minY, safeFrame.maxY) - gap
        // Push down past anything in the way; a few passes settle stacked obstacles.
        for _ in 0..<3 {
            let r = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
            guard let hit = obstacles.first(where: { $0.intersects(r.insetBy(dx: 0, dy: -gap + 0.5)) }) else { break }
            top = hit.minY - gap
        }
        let y = max(safeFrame.minY, top - size.height)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// The panel around a tag frame, with room for the glow.
    static func panelFrame(for tag: NSRect) -> NSRect { tag.insetBy(dx: -halo, dy: -halo) }

    private var body: NSRect { bounds.insetBy(dx: Self.halo, dy: Self.halo) }

    override func layout() {
        super.layout()
        let b = body
        label.frame = NSRect(x: b.minX + Self.textLead - Self.cellInset / 2, y: b.minY + Self.vPad,
                             width: b.width - Self.textLead - Self.trailPad + Self.cellInset,
                             height: b.height - Self.vPad * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = body
        let path = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        // The tail: a small notch up toward her, sliding along the top edge.
        let tx = max(b.minX + Self.radius + 2, min(b.maxX - Self.radius - 2, tailX))
        let tailPath = NSBezierPath()
        tailPath.move(to: NSPoint(x: tx - Self.tail - 1, y: b.minY + 0.5))
        tailPath.line(to: NSPoint(x: tx, y: b.minY - Self.tail + 0.5))
        tailPath.line(to: NSPoint(x: tx + Self.tail + 1, y: b.minY + 0.5))
        tailPath.close()
        path.append(tailPath)
        path.windingRule = .nonZero

        NSGraphicsContext.saveGraphicsState()
        let shade = NSShadow()
        shade.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shade.shadowOffset = NSSize(width: 0, height: -4)
        shade.shadowBlurRadius = 9
        shade.set()
        Neon.fillBottom.setFill()
        path.fill()
        let glow = NSShadow()
        glow.shadowColor = Neon.halo.withAlphaComponent(0.55)
        glow.shadowBlurRadius = 10
        glow.set()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: Neon.fillTop, ending: Neon.fillBottom)?.draw(in: path, angle: 90)
        Neon.edge.setStroke()
        path.lineWidth = 1
        path.stroke()
        // Cover the seam between the tail and the body.
        Neon.fillTop.setStroke()
        let seam = NSBezierPath()
        seam.move(to: NSPoint(x: tx - Self.tail + 0.5, y: b.minY + 0.5))
        seam.line(to: NSPoint(x: tx + Self.tail - 0.5, y: b.minY + 0.5))
        seam.lineWidth = 1.2
        seam.stroke()

        // Mood dot, centred on the first line.
        let d = Self.dot
        let dotRect = NSRect(x: b.minX + Self.leadPad, y: b.minY + Self.vPad + (Self.lineHeight - d) / 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let dotGlow = NSShadow()
        dotGlow.shadowColor = tone.withAlphaComponent(0.9)
        dotGlow.shadowBlurRadius = 5
        dotGlow.set()
        tone.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The three things you can open from her: the shelf, home and settings.
enum CardKind: Int, CaseIterable {
    case shelf, home, github, settings, approval, reminders, reminderAlert, toast
    /// Zera's answer about a file (Summarize / Explain / Extract / Ask).
    case result
    /// Live progress of your Claude Code sessions.
    case claude
    /// Everything you copied, to copy again. Last, so saved raw values stay the same.
    case clipboard
    /// Today's to-dos and the focus timer.
    case tasks

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
        case .clipboard: return "Clipboard"
        case .tasks: return "Tasks"
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
        case .clipboard: return "doc.on.clipboard"
        case .tasks: return "checklist"
        }
    }
}
