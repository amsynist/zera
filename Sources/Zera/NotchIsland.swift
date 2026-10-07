import AppKit

/// Sizes shared by every screen in the notch island.
enum Isle {
    /// The header row under the notch band. Zera hangs in its middle; titles sit left, actions right.
    static let headerHeight: CGFloat = 88
    /// Width the header keeps free in its centre for her.
    static let zeraGap: CGFloat = 124
    /// The tallest a screen gets below the notch band; anything taller scrolls inside.
    static let maxContentHeight: CGFloat = 470
    static let minWidth: CGFloat = 520
    static let maxWidth: CGFloat = 660
    /// Hovering her: the peek bar hangs this far below the menu bar, framed by its blue edge.
    static let peekDrop: CGFloat = 6
    static let corner: CGFloat = 30
    static let ear: CGFloat = 12
    /// Room around the island inside its window for the glow.
    static let margin: CGFloat = 44

    /// The tabs at notch level: Home · Claude · Files · Clipboard left of the notch, Tasks ·
    /// PRs · Reminders · Settings right of it.
    static let leftTabs: [CardKind] = [.home, .claude, .shelf, .clipboard]
    static let rightTabs: [CardKind] = [.tasks, .github, .reminders, .settings]

    /// Which tab lights up for a screen that has none of its own.
    static func tab(for kind: CardKind) -> CardKind {
        switch kind {
        case .result: return .shelf
        case .approval: return .claude
        case .reminderAlert: return .reminders
        case .toast: return .github
        default: return kind
        }
    }

    static func symbol(for tab: CardKind) -> String {
        switch tab {
        case .home: return "house"
        case .claude: return "terminal"
        case .shelf: return "tray.full"
        case .github: return "arrow.triangle.pull"
        case .reminders: return "calendar"
        case .settings: return "gearshape"
        case .clipboard: return "doc.on.clipboard"
        case .tasks: return "checklist"
        default: return tab.symbol
        }
    }

    /// Zera's pose while a screen is open.
    static func pose(for kind: CardKind) -> String {
        switch kind {
        case .home: return "hang_wave"
        case .claude, .approval: return "hang_climb"
        case .shelf: return "hang_peek"
        case .github, .result: return "hang_think"
        case .reminders, .reminderAlert: return "hang_smile"
        case .settings: return "hang_swing"
        case .toast: return "hang_wave"
        case .clipboard: return "hang_upsidedown"
        case .tasks: return "hang_smile"
        }
    }
}

/// The notch island: every screen opens out of the notch as compact navy glass with a blue neon
/// edge — the live wings' look. The notch band carries the tabs on either side of the notch;
/// Zera hangs in the middle (her own window sits above this one).
///
/// The window is a fixed transparent canvas; only the island's shape is drawn and clickable, and
/// it springs between sizes (closed → peek → a screen → another screen) with Core Animation.
final class IslandView: NSView {
    enum Mode { case closed, peek, open }

    var onTab: ((CardKind) -> Void)?
    private(set) var mode: Mode = .closed

    /// Notch height (the black band) and width.
    var band: CGFloat = 34 { didSet { needsLayout = true } }
    var notchWidth: CGFloat = 190 { didSet { needsLayout = true } }
    /// Where the island is centred, in view coordinates (under Zera's rope).
    var centerX: CGFloat = 0 { didSet { needsLayout = true } }

    var activeTab: CardKind? {
        didSet {
            tabs.forEach { $0.isOn = $0.kind == activeTab }
            // The pill glides from the tab you were on to the one you picked; on first open it
            // simply appears under it.
            tabIndicator.moveTo(activeTabFrame, animated: oldValue != nil && activeTab != nil)
        }
    }
    var badges: Set<CardKind> = [] { didSet { tabs.forEach { $0.hasBadge = badges.contains($0.kind) } } }
    /// Numbers on the tabs, such as running Claude sessions.
    var counts: [CardKind: Int] = [:] { didSet { tabs.forEach { $0.count = counts[$0.kind] ?? 0 } } }

    /// The island's current shape, in view coordinates.
    private(set) var islandRect = NSRect.zero
    private(set) var content: NSView?

    private let glow = CAShapeLayer()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let edge = CAShapeLayer()
    private let edgeFade = CAGradientLayer()
    private let hostMask = CAShapeLayer()
    private let host = IslandHost()
    private var tabs: [IslandTab] = []
    /// The soft pill under the open screen's tab.
    private let tabIndicator = IslandTabIndicator()
    /// Zera's line while a screen is open: the header's second line, left of her.
    private let whisperView = IslandWhisper()
    private(set) var whisperText: String?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        glow.fillColor = Neon.fillBottom.cgColor
        glow.shadowColor = Neon.halo.cgColor
        glow.shadowOpacity = 0
        glow.shadowRadius = 16
        glow.shadowOffset = .zero
        layer?.addSublayer(glow)

        fill.mask = fillMask
        layer?.addSublayer(fill)

        edge.fillColor = nil
        edge.strokeColor = Neon.edge.cgColor
        edge.lineWidth = 1.2
        edge.shadowColor = Neon.edge.cgColor
        edge.shadowRadius = 4
        edge.shadowOpacity = 0.6
        edge.shadowOffset = .zero
        edge.opacity = 0
        edgeFade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        edge.mask = edgeFade
        layer?.addSublayer(edge)

        host.wantsLayer = true
        host.layer?.mask = hostMask
        addSubview(host)
        whisperView.alphaValue = 0
        whisperView.isHidden = true
        addSubview(whisperView)

        tabIndicator.alphaValue = 0
        tabIndicator.target = { [weak self] in self?.activeTabFrame }
        addSubview(tabIndicator)
        for kind in Isle.leftTabs + Isle.rightTabs {
            let t = IslandTab(kind: kind)
            t.onTap = { [weak self] in self?.onTab?(kind) }
            t.alphaValue = 0
            addSubview(t)
            tabs.append(t)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Shape

    private func shapeRect(width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: (centerX - width / 2).rounded(), y: 0, width: width.rounded(), height: height.rounded())
    }

    /// Flat top flush with the screen edge, concave ears where it meets it, round bottom corners.
    /// Always the same elements, so one shape morphs smoothly into another.
    private static func path(_ r: NSRect, corner c: CGFloat, closed: Bool) -> CGPath {
        let p = CGMutablePath()
        let e = Isle.ear, x0 = r.minX, x1 = r.maxX, h = r.maxY
        let k: CGFloat = 0.45
        p.move(to: CGPoint(x: x0 - e, y: 0))
        p.addQuadCurve(to: CGPoint(x: x0, y: e), control: CGPoint(x: x0, y: 0))
        p.addLine(to: CGPoint(x: x0, y: h - c))
        p.addCurve(to: CGPoint(x: x0 + c, y: h), control1: CGPoint(x: x0, y: h - c * k), control2: CGPoint(x: x0 + c * k, y: h))
        p.addLine(to: CGPoint(x: x1 - c, y: h))
        p.addCurve(to: CGPoint(x: x1, y: h - c), control1: CGPoint(x: x1 - c * k, y: h), control2: CGPoint(x: x1, y: h - c * k))
        p.addLine(to: CGPoint(x: x1, y: e))
        p.addQuadCurve(to: CGPoint(x: x1 + e, y: 0), control: CGPoint(x: x1, y: 0))
        if closed { p.closeSubpath() }
        return p
    }

    private func applyShape(_ r: NSRect, corner: CGFloat, animated: Bool) {
        islandRect = r
        let closedPath = Self.path(r, corner: corner, closed: true)
        let openPath = Self.path(r, corner: corner, closed: false)
        let pairs: [(CAShapeLayer, CGPath)] = [(glow, closedPath), (fillMask, closedPath), (hostMask, closedPath), (edge, openPath)]
        for (layer, p) in pairs {
            if animated, !Motion.reduced {
                let from = layer.presentation()?.path ?? layer.path
                let a = CASpringAnimation(keyPath: "path")
                a.fromValue = from; a.toValue = p
                a.mass = 1; a.stiffness = 210; a.damping = 22; a.initialVelocity = 0
                a.duration = a.settlingDuration
                layer.add(a, forKey: "morph")
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.path = p
            CATransaction.commit()
        }
        window?.invalidateCursorRects(for: self)
    }

    /// The theme changed: recolour the glass, its edge and the tabs.
    func themeChanged() {
        glow.fillColor = Neon.fillBottom.cgColor
        glow.shadowColor = Neon.halo.cgColor
        edge.strokeColor = Neon.edge.cgColor
        edge.shadowColor = Neon.edge.cgColor
        tabs.forEach { $0.needsDisplay = true }
        whisperView.needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = bounds
        fill.frame = b
        let h = max(1, b.height)
        fill.colors = [NSColor.black.cgColor, NSColor.black.cgColor, Neon.fillTop.cgColor, Neon.fillBottom.cgColor]
        fill.locations = [0, NSNumber(value: Double(band / h)), NSNumber(value: Double((band + 44) / h)), 1]
        edge.frame = b
        edgeFade.frame = b
        CATransaction.commit()
        updateEdgeFade()
        host.frame = b
        layoutTabs()
        layoutWhisper()
    }

    // MARK: - Zera's whisper

    /// Shows `text` in the header's second line of the open screen (nil hides it). It sits on
    /// the island's own fill, so it covers that screen's subtitle while it's up.
    func whisper(_ text: String?, tone: NSColor = Neon.cyan) {
        let on = !(text ?? "").isEmpty && mode == .open && content != nil
        whisperText = on ? text : nil
        (content as? CardBase)?.whispering = on
        if on {
            whisperView.text = text ?? ""
            whisperView.tone = tone
            layoutWhisper()
            whisperView.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(on ? 0.22 : 0.18)
            whisperView.animator().alphaValue = on ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.whisperText == nil else { return }
            self.whisperView.isHidden = true
        })
    }

    private func layoutWhisper() {
        guard let c = content else { return }
        let f = c.frame
        // Every screen starts its header text at the side padding + 4.
        let lead: CGFloat = c is CardBase ? Metrics.cardPad + 4 : Metrics.sidePad + 4
        let width = f.width / 2 - Isle.zeraGap / 2 - lead
        whisperView.frame = NSRect(x: f.minX + lead - 2, y: band + 45, width: max(0, width + 2), height: 18)
    }

    private func layoutTabs() {
        let w: CGFloat = 30, h: CGFloat = 26, gap: CGFloat = 4
        let y = ((band - h) / 2).rounded()
        var x = centerX - notchWidth / 2 - 10 - CGFloat(Isle.leftTabs.count) * (w + gap) + gap
        for t in tabs.prefix(Isle.leftTabs.count) { t.frame = NSRect(x: x, y: y, width: w, height: h); x += w + gap }
        x = centerX + notchWidth / 2 + 10
        for t in tabs.suffix(Isle.rightTabs.count) { t.frame = NSRect(x: x, y: y, width: w, height: h); x += w + gap }
        tabIndicator.frame = bounds
        tabIndicator.needsDisplay = true
    }

    /// Where the open screen's tab is, in this view's coordinates.
    private var activeTabFrame: NSRect? {
        guard let k = activeTab, let t = tabs.first(where: { $0.kind == k }) else { return nil }
        return t.frame
    }

    private func setTabs(visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(visible ? 0.22 : 0.12)
            tabs.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
            tabIndicator.animator().alphaValue = visible ? 1 : 0
        }
    }

    private func setChrome(_ m: Mode) {
        let open = m == .open, peek = m == .peek
        let a = CABasicAnimation(keyPath: "opacity")
        a.duration = Motion.duration(0.3)
        CATransaction.begin()
        // The peek bar wears the island's edge too, a touch softer: a black bar framed in blue.
        edge.opacity = open ? 1 : (peek ? 0.9 : 0)
        glow.shadowOpacity = open ? 0.55 : (peek ? 0.4 : 0)
        glow.shadowRadius = open ? 16 : 10
        edge.add(a, forKey: "fade")
        CATransaction.commit()
        updateEdgeFade()
    }

    /// The edge fades in from the top of the screen: over the band when a screen is open, and
    /// sooner on the short peek bar so its sides and bottom show.
    private func updateEdgeFade() {
        let h = max(1, bounds.height)
        let (from, to): (CGFloat, CGFloat) = mode == .peek ? (4, band * 0.6) : (band - 14, band + 30)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        edgeFade.locations = [NSNumber(value: Double(from / h)), NSNumber(value: Double(to / h))]
        CATransaction.commit()
    }

    /// Wide enough for the longer row of tabs on either side of the notch.
    private var peekWidth: CGFloat {
        let w: CGFloat = 30, gap: CGFloat = 4
        let side = CGFloat(max(Isle.leftTabs.count, Isle.rightTabs.count)) * (w + gap) - gap
        return notchWidth + 2 * (10 + side + 14)
    }

    // MARK: - Modes

    /// Just the notch: nothing to see, nothing to click.
    func close(animated: Bool = true, completion: (() -> Void)? = nil) {
        mode = .closed
        activeTab = nil
        whisper(nil)
        dismissContent(direction: 0)
        setTabs(visible: false)
        setChrome(.closed)
        applyShape(shapeRect(width: notchWidth, height: band), corner: 12, animated: animated)
        let wait = animated && !Motion.reduced ? 0.42 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self, self.mode == .closed else { return }
            completion?()
        }
    }

    /// Hovering her: the notch widens to show the tabs.
    func peek() {
        guard mode != .open else { return }
        mode = .peek
        activeTab = nil
        setTabs(visible: true)
        setChrome(.peek)
        applyShape(shapeRect(width: peekWidth, height: band + Isle.peekDrop), corner: 16, animated: true)
    }

    /// Opens (or switches to, or resizes for) a screen. `direction` is the side the new screen
    /// comes from when switching: −1 left, +1 right, 0 open in place.
    func present(_ view: NSView, size: NSSize, direction: CGFloat, animated: Bool) {
        let wasOpen = mode == .open
        mode = .open
        setTabs(visible: true)
        setChrome(.open)
        let w = size.width, h = size.height
        let target = NSRect(x: (centerX - w / 2).rounded(), y: band, width: w, height: h)
        if view !== content {
            dismissContent(direction: direction)
            view.frame = target
            host.addSubview(view)
            content = view
            if animated {
                // Switching tabs: the new screen starts moving with the tab pill, from the side
                // you moved toward. Opening fresh: it settles in from just above, once the island
                // has begun to open. Reduce Motion: a short fade.
                Motion.arrive(view, direction: direction, distance: 16, delay: wasOpen ? 0.02 : 0.1)
            }
        } else {
            view.frame = target
        }
        applyShape(shapeRect(width: w, height: band + h), corner: Isle.corner, animated: animated)
        if let t = whisperText { (content as? CardBase)?.whispering = true; whisperView.text = t }
        layoutWhisper()
    }

    private func dismissContent(direction: CGFloat) {
        guard let old = content else { return }
        content = nil
        guard !Motion.reduced, old.window != nil else { old.removeFromSuperview(); return }
        old.wantsLayer = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak old, weak self] in
            guard let old = old, old !== self?.content else { return }
            old.removeFromSuperview()
            old.layer?.removeAllAnimations()
            old.layer?.opacity = 1
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.14
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        old.layer?.add(fade, forKey: "leave")
        if direction != 0 {
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = 0; move.toValue = -direction * 12; move.duration = 0.16
            move.fillMode = .forwards; move.isRemovedOnCompletion = false
            old.layer?.add(move, forKey: "slide")
        }
        CATransaction.commit()
    }

    /// The island, with a little slack, in view coordinates; tabs count in peek.
    func islandContains(_ p: NSPoint) -> Bool {
        mode != .closed && islandRect.insetBy(dx: -2, dy: -2).contains(p)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview.map { convert(point, from: $0) } ?? point
        guard islandContains(p) else { return nil }
        return super.hitTest(point) ?? self
    }
}

/// Zera's line inside an open island: a small spark and the line in her tone, on the island's
/// own fill so it can sit over the screen's subtitle.
final class IslandWhisper: NSView {
    var text = "" { didSet { label.stringValue = text; setAccessibilityLabel(text) } }
    var tone: NSColor = Neon.cyan { didSet { label.textColor = tone; needsDisplay = true } }
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = tone
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 18, y: 0, width: max(0, bounds.width - 18), height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The island's fill at this depth, opaque, feathered on the right so the cover is invisible.
        let base = Neon.fillTop.withAlphaComponent(1)
        NSGradient(colors: [base, base, base.withAlphaComponent(0)], atLocations: [0, 0.92, 1], colorSpace: .sRGB)?
            .draw(in: bounds, angle: 0)
        Neon.symbol("sparkle", in: NSRect(x: 2, y: (bounds.height - 12) / 2 - 1, width: 12, height: 12),
                    size: 10, weight: .bold, color: tone)
    }
}

/// Holds the current screen, clipped to the island's shape.
final class IslandHost: NSView {
    override var isFlipped: Bool { true }
}

/// One tab at notch level: an SF Symbol that lights up cyan with a glowing underline when its
/// screen is open, and wears an amber dot when something there needs you, or a small count
/// (cyan, amber when it needs you) for things in progress.
final class IslandTab: NSView {
    let kind: CardKind
    var onTap: (() -> Void)?
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var hasBadge = false { didSet { if hasBadge != oldValue { needsDisplay = true } } }
    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(count > 0 ? "\(count)" : nil)
        }
    }
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(kind: CardKind) {
        self.kind = kind
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(kind.title)
        toolTip = kind == .github ? "Pull requests" : kind.title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        // The open tab's pill is drawn underneath by `IslandTabIndicator`, so it can glide.
        if hovered && !isOn {
            Neon.chipHover.setFill()
            NSBezierPath(roundedRect: b, xRadius: 9, yRadius: 9).fill()
        }
        let color = isOn ? Neon.accent : (hovered ? Neon.text : Neon.textDim)
        Neon.symbol(Isle.symbol(for: kind), in: b.insetBy(dx: 0, dy: -1), size: 13.5, weight: .semibold, color: color)
        if count > 0 {
            let text = count > 9 ? "9+" : "\(count)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
            let tw = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            let pill = NSRect(x: b.maxX - max(12, tw + 6), y: 0, width: max(12, tw + 6), height: 12)
            let tone = hasBadge ? Neon.warning : Neon.highlight
            Neon.glowing(tone, blur: 5) { tone.setFill(); NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill() }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Neon.fillBottom.withAlphaComponent(1)]
            let ts = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: pill.midX - ts.width / 2, y: pill.midY - ts.height / 2), withAttributes: attrs)
        } else if hasBadge {
            let d = NSRect(x: b.maxX - 8, y: 3, width: 6, height: 6)
            Neon.glowing(Neon.warning, blur: 5) { Neon.warning.setFill(); NSBezierPath(ovalIn: d).fill() }
        }
    }

    override func mouseDown(with event: NSEvent) { onTap?() }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

/// The soft accent pill under the open screen's tab. It spans the whole island so it can glide
/// from one tab to another (across the notch, too), and never takes a click.
final class IslandTabIndicator: NSView {
    /// Where the pill belongs right now (the open tab's frame), or nil for none.
    var target: (() -> NSRect?)?
    private lazy var indicator = SlidingIndicator(view: self)
    private var showing = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func moveTo(_ r: NSRect?, animated: Bool) {
        guard let r = r else { showing = false; needsDisplay = true; return }
        indicator.move(to: r, animated: animated && showing)
        showing = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showing, let r = target?() else { return }
        indicator.settle(at: r)
        let path = NSBezierPath(roundedRect: indicator.rect, xRadius: 9, yRadius: 9)
        Neon.accent.withAlphaComponent(0.16).setFill(); path.fill()
        Neon.accent.withAlphaComponent(0.3).setStroke(); path.lineWidth = 1; path.stroke()
    }
}
