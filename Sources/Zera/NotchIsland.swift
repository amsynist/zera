import AppKit

/// Sizes shared by every screen in the notch island.
enum Isle {
    /// The header row under the notch band. Zera hangs in its middle; titles sit left, actions right.
    static let headerHeight: CGFloat = 132
    /// A banner's one row (reminders, meetings, battery, GitHub toasts).
    static let bannerHeight: CGFloat = 88
    /// Width the header keeps free in its centre for her.
    static let zeraGap: CGFloat = 132
    /// The tallest a screen gets below the notch band; anything taller scrolls inside.
    static let maxContentHeight: CGFloat = 640
    static let maxWidth: CGFloat = 880
    /// v2: every screen opens as one lens this wide (narrower screens shrink to fit).
    static let lensWidth: CGFloat = 880
    static let corner: CGFloat = 34
    /// Hovering her (v2): the nodes bloom out round her on an arc, each centre this far from
    /// the rope (x) and below the top of the screen (y); the search node hangs under them.
    static let bloom: [CGPoint] = [CGPoint(x: -258, y: 72), CGPoint(x: -206, y: 158), CGPoint(x: -130, y: 226), CGPoint(x: -56, y: 272),
                                   CGPoint(x: 56, y: 272), CGPoint(x: 130, y: 226), CGPoint(x: 206, y: 158), CGPoint(x: 258, y: 72)]
    static let bloomSearch = CGPoint(x: 0, y: 336)
    static let bloomNode: CGFloat = 56
    /// The rail's nodes (v2): they hang just under the notch, either side of her, this big and
    /// this far apart; the innermost centre sits `railInner` from the rope.
    static let node: CGFloat = 36
    static let nodeGap: CGFloat = 10
    static let railInner: CGFloat = 154
    /// The rail's centre line, below the notch band.
    static let railDrop: CGFloat = 26
    static let ear: CGFloat = 12
    /// Room around the island inside its window for the glow.
    static let margin: CGFloat = 44

    /// A banner's width: symmetric about Zera, with `bannerText` of room for the heading left of
    /// her and `buttons` (their total width, gaps included) right of her.
    static let bannerText: CGFloat = 260
    static func bannerWidth(buttons: CGFloat) -> CGFloat {
        let left = Metrics.sidePad + 36 + 12 + bannerText
        let right = buttons + Metrics.sidePad
        return ceil((max(left, right) + zeraGap / 2 + 8) * 2)
    }

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

enum HoverMenuStyle: Int, CaseIterable {
    case arc, tiles
    var title: String { self == .arc ? "Arc" : "Tiles" }
    static var current: HoverMenuStyle {
        get { HoverMenuStyle(rawValue: UserDefaults.standard.integer(forKey: "zera.hoverMenuStyle")) ?? .arc }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "zera.hoverMenuStyle") }
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
    var hoverStyle = HoverMenuStyle.current
    private var tiledPeek: Bool { mode == .peek && hoverStyle == .tiles }
    private var tileWidth: CGFloat { min(560, bounds.width - 2 * Isle.margin) }
    private var tileTop: CGFloat { band + 108 }
    private var tileHeight: CGFloat { band + 420 }

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
    /// Live rings on the nodes: CPU on Home, the session on Claude, the next event on Reminders…
    var instruments: [CardKind: IslandInstrument] = [:] { didSet { tabs.forEach { $0.instrument = instruments[$0.kind] } } }
    var onClose: (() -> Void)?
    /// The search node after the rail: opens the App Opener in the middle of the screen.
    var onSearch: (() -> Void)?
    private let closeButton = IslandClose()
    private let searchNode = IslandClose(symbol: "magnifyingglass", label: "Open an app", tip: "Open an app (⌥Space)", accent: true)

    /// The island's current shape, in view coordinates.
    private(set) var islandRect = NSRect.zero
    private(set) var content: NSView?

    private let glow = CAShapeLayer()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let edge = CAShapeLayer()
    private let edgeFade = CAGradientLayer()
    private let hostMask = CAShapeLayer()
    /// v2: where the lens attaches under the notch — a bright hairline and a soft accent bloom.
    private let rootLine = CAGradientLayer()
    private let rootGlow = CAGradientLayer()
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

        rootGlow.type = .radial
        rootGlow.startPoint = CGPoint(x: 0.5, y: 0)
        rootGlow.endPoint = CGPoint(x: 1, y: 1)
        rootGlow.opacity = 0
        rootLine.startPoint = CGPoint(x: 0, y: 0.5)
        rootLine.endPoint = CGPoint(x: 1, y: 0.5)
        rootLine.opacity = 0
        layer?.addSublayer(rootGlow)
        layer?.addSublayer(rootLine)
        recolorRoot()

        host.wantsLayer = true
        host.layer?.mask = hostMask
        addSubview(host)
        whisperView.alphaValue = 0
        whisperView.isHidden = true
        addSubview(whisperView)

        tabIndicator.alphaValue = 0
        tabIndicator.target = { [weak self] in self?.activeTabFrame }
        addSubview(tabIndicator)
        closeButton.alphaValue = 0
        closeButton.onTap = { [weak self] in self?.onClose?() }
        addSubview(closeButton)
        searchNode.alphaValue = 0
        searchNode.onTap = { [weak self] in self?.onSearch?() }
        addSubview(searchNode)
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
    private static func path(_ r: NSRect, corner c: CGFloat, closed: Bool, neck: CGFloat? = nil, band: CGFloat = 0) -> CGPath {
        let p = CGMutablePath()
        let e = Isle.ear, x0 = r.minX, x1 = r.maxX, h = r.maxY
        let k: CGFloat = 0.45
        let n0 = neck.map { r.midX - $0 / 2 } ?? x0
        let n1 = neck.map { r.midX + $0 / 2 } ?? x1
        let shoulder = neck == nil ? e : band + 64
        let root = neck == nil ? e : band
        p.move(to: CGPoint(x: n0 - e, y: 0))
        p.addQuadCurve(to: CGPoint(x: n0, y: e), control: CGPoint(x: n0, y: 0))
        p.addLine(to: CGPoint(x: n0, y: root))
        p.addCurve(to: CGPoint(x: x0, y: shoulder), control1: CGPoint(x: n0, y: shoulder), control2: CGPoint(x: x0, y: root))
        p.addLine(to: CGPoint(x: x0, y: h - c))
        p.addCurve(to: CGPoint(x: x0 + c, y: h), control1: CGPoint(x: x0, y: h - c * k), control2: CGPoint(x: x0 + c * k, y: h))
        p.addLine(to: CGPoint(x: x1 - c, y: h))
        p.addCurve(to: CGPoint(x: x1, y: h - c), control1: CGPoint(x: x1 - c * k, y: h), control2: CGPoint(x: x1, y: h - c * k))
        p.addLine(to: CGPoint(x: x1, y: shoulder))
        p.addCurve(to: CGPoint(x: n1, y: root), control1: CGPoint(x: x1, y: root), control2: CGPoint(x: n1, y: shoulder))
        p.addLine(to: CGPoint(x: n1, y: e))
        p.addQuadCurve(to: CGPoint(x: n1 + e, y: 0), control: CGPoint(x: n1, y: 0))
        if closed { p.closeSubpath() }
        return p
    }

    private func applyShape(_ r: NSRect, corner: CGFloat, animated: Bool) {
        islandRect = r
        let closedPath = Self.path(r, corner: corner, closed: true, neck: tiledPeek ? notchWidth : nil, band: band)
        let openPath = Self.path(r, corner: corner, closed: false, neck: tiledPeek ? notchWidth : nil, band: band)
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
        needsLayout = true
    }

    private func recolorRoot() {
        rootGlow.colors = [Neon.accent.withAlphaComponent(0.16).cgColor, Neon.accent.withAlphaComponent(0).cgColor]
        rootLine.colors = [Neon.accent.withAlphaComponent(0).cgColor, Neon.accent.withAlphaComponent(0.9).cgColor, Neon.accent.withAlphaComponent(0).cgColor]
    }

    /// The theme changed: recolour the glass, its edge and the tabs.
    func themeChanged() {
        recolorRoot()
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
        // The luminous root sits on the island's very top edge, where it meets the screen.
        // Wide enough to show either side of the hardware notch.
        let lw = max(300, notchWidth + 260)
        rootLine.frame = NSRect(x: centerX - lw / 2, y: 0, width: lw, height: 1.5)
        rootGlow.frame = NSRect(x: centerX - 210, y: 0, width: 420, height: 160 + band)
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
        let lead: CGFloat = c is CardBase ? Metrics.cardPad : Metrics.sidePad
        let width = f.width / 2 - Isle.zeraGap / 2 - lead
        whisperView.frame = NSRect(x: f.minX + lead - 2, y: band + CardBase.subtitleTop, width: max(0, width + 2), height: 18)
    }

    /// A node's frame: the disc plus a little room for its badge.
    private var nodeSize: CGFloat { Isle.node }

    /// Nodes are gliding between the rail and the bloom: layout leaves them be.
    private var nodesMovingUntil: CFTimeInterval = 0

    /// Each node's frame in the bloom (with room for its name), and the search node's.
    private func bloomFrame(_ i: Int) -> NSRect {
        if tiledPeek {
            let pad = Space.xl, gap = Space.m
            let w = (tileWidth - 2 * pad - 3 * gap) / 4
            return NSRect(x: (centerX - tileWidth / 2 + pad + CGFloat(i % 4) * (w + gap)).rounded(),
                          y: tileTop + CGFloat(i / 4) * 120, width: w.rounded(), height: 108)
        }
        let p = Isle.bloom[i], d = Isle.bloomNode
        return NSRect(x: (centerX + p.x - 48).rounded(), y: (p.y - d / 2).rounded(), width: 96, height: d + IslandTab.labelH)
    }
    private var bloomSearchFrame: NSRect {
        if tiledPeek {
            return NSRect(x: centerX - tileWidth / 2 + Space.xl, y: tileTop + 252,
                          width: tileWidth - 2 * Space.xl, height: 38)
        }
        let p = Isle.bloomSearch
        return NSRect(x: (centerX + p.x - 22).rounded(), y: p.y - 22, width: 44, height: 44)
    }

    /// Actual controls, rather than their bounding union: captions can use the empty
    /// space beside Zera without being pushed beneath the entire arc or grid.
    var captionObstacles: [NSRect] {
        guard mode == .peek else { return [islandRect] }
        let root = NSRect(x: centerX - notchWidth / 2, y: 0, width: notchWidth, height: band)
        return [root] + tabs.indices.map { bloomFrame($0) } + [bloomSearchFrame]
    }

    /// Everything the pointer can be over while she's bloomed (or the island's shape otherwise).
    var hoverRect: NSRect {
        guard mode == .peek else { return islandRect }
        var r = islandRect
        for i in tabs.indices { r = r.union(bloomFrame(i)) }
        return r.union(bloomSearchFrame)
    }

    /// Glides the nodes to where the mode wants them: out round her (peek), or into the rail.
    private func moveNodes(animated: Bool) {
        let bloom = mode == .peek
        tabs.forEach { $0.tiled = tiledPeek }
        searchNode.expanded = tiledPeek
        guard animated, !Motion.reduced else {
            tabs.forEach { $0.bloomed = bloom }
            layoutTabs()
            return
        }
        let total = 0.5 + Double(tabs.count) * 0.03
        nodesMovingUntil = CACurrentMediaTime() + total
        let rail = railFrames()
        for (i, t) in tabs.enumerated() {
            let target = bloom ? bloomFrame(i) : rail[i]
            t.bloomed = bloom
            // Out from the middle in turn, like petals; back in all at once.
            let delay = bloom ? Double(min(i, tabs.count - 1 - i)) * 0.035 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = bloom ? 0.5 : 0.36
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, bloom ? 1.25 : 1.05, 0.4, 1)
                    ctx.allowsImplicitAnimation = true
                    t.animator().frame = target
                }
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.2, 0.4, 1)
            searchNode.animator().frame = bloom ? bloomSearchFrame : railSearchFrame
            // The search node only hangs in the bloom; the rail has just the screens.
            searchNode.animator().alphaValue = bloom ? 1 : 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in self?.needsLayout = true }
    }

    /// The innermost rail centre's distance from the rope: the design's, or clear of a wide notch.
    private var railInner: CGFloat { max(Isle.railInner, notchWidth / 2 + nodeSize / 2 + 22) }
    private var railY: CGFloat { (band + Isle.railDrop - nodeSize / 2).rounded() }

    private func railFrames() -> [NSRect] {
        let w = nodeSize, step = w + Isle.nodeGap, y = railY
        var out: [NSRect] = []
        let nl = Isle.leftTabs.count
        for i in 0..<nl {
            let cx = centerX - railInner - CGFloat(nl - 1 - i) * step
            out.append(NSRect(x: (cx - w / 2).rounded(), y: y, width: w, height: w))
        }
        for i in 0..<Isle.rightTabs.count {
            let cx = centerX + railInner + CGFloat(i) * step
            out.append(NSRect(x: (cx - w / 2).rounded(), y: y, width: w, height: w))
        }
        return out
    }
    private var railSearchFrame: NSRect {
        let w = nodeSize, step = w + Isle.nodeGap
        let cx = centerX + railInner + CGFloat(Isle.rightTabs.count) * step
        return NSRect(x: (cx - w / 2).rounded(), y: railY, width: w, height: w)
    }

    private func layoutTabs() {
        if CACurrentMediaTime() < nodesMovingUntil { layoutClose(); return }
        let bloom = mode == .peek
        let rail = railFrames()
        for (i, t) in tabs.enumerated() { t.tiled = tiledPeek; t.bloomed = bloom; t.frame = bloom ? bloomFrame(i) : rail[i] }
        searchNode.expanded = tiledPeek
        searchNode.frame = bloom ? bloomSearchFrame : railSearchFrame
        searchNode.isHidden = !bloom
        layoutClose()
    }

    private func layoutClose() {
        let w = nodeSize, h = nodeSize, gap = Isle.nodeGap
        _ = (w, h, gap)
        let cs: CGFloat = 24
        closeButton.frame = NSRect(x: islandRect.maxX - 16 - cs, y: ((band - cs) / 2).rounded(), width: cs, height: cs)
        // Banners carry their own dismiss; the island's ✕ is for lenses.
        closeButton.isHidden = mode != .open || content is TimedNotificationBanner
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
            closeButton.animator().alphaValue = visible && mode == .open ? 1 : 0
            searchNode.animator().alphaValue = visible && mode == .peek ? 1 : 0
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
        rootLine.opacity = open ? 0.9 : 0
        rootGlow.opacity = open ? 1 : 0
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
        let w = nodeSize, gap = Isle.nodeGap
        let side = CGFloat(max(Isle.leftTabs.count, Isle.rightTabs.count)) * (w + gap) - gap
        // Room on the right for the search node too (kept symmetric about the notch).
        return notchWidth + 2 * (14 + side + 6 + w + 16)
    }

    // MARK: - Modes

    /// Just the notch: nothing to see, nothing to click.
    func close(animated: Bool = true, completion: (() -> Void)? = nil) {
        mode = .closed
        activeTab = nil
        whisper(nil)
        dismissContent(direction: 0, animated: animated)
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
        // A screen is up: the rail is already there. (Open with nothing presented is a state
        // that should not exist; rather than swallow every hover, the bloom takes over.)
        guard mode != .open || content == nil else { return }
        let wasClosed = mode == .closed
        mode = .peek
        activeTab = nil
        if wasClosed, !Motion.reduced {
            // From her: every node starts small at the rope and blooms out.
            let start = NSRect(x: centerX - 8, y: band + 30, width: 16, height: 16)
            tabs.forEach { $0.frame = start }
            searchNode.frame = start
        }
        setTabs(visible: true)
        setChrome(.peek)
        // v2: the notch only widens a little; the nodes float round her.
        applyShape(shapeRect(width: tiledPeek ? tileWidth : notchWidth + 44,
                             height: tiledPeek ? tileHeight : band + 2),
                   corner: tiledPeek ? Isle.corner : 14, animated: true)
        moveNodes(animated: true)
    }

    /// Opens (or switches to, or resizes for) a screen. `direction` is the side the new screen
    /// comes from when switching: −1 left, +1 right, 0 open in place.
    func present(_ view: NSView, size: NSSize, direction: CGFloat, animated: Bool) {
        let wasOpen = mode == .open, wasBloomed = mode == .peek
        mode = .open
        // The rail hangs in a screen's header; banners are a slim band of their own.
        setTabs(visible: !(view is TimedNotificationBanner))
        setChrome(.open)
        // The bloomed nodes shrink into the rail either side of the notch. The open node's ring
        // waits until they have landed, rather than sitting at the destination first.
        if wasBloomed {
            moveNodes(animated: animated)
            if animated, !Motion.reduced {
                tabIndicator.alphaValue = 0
                let wait = max(0, nodesMovingUntil - CACurrentMediaTime())
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self = self, self.mode == .open else { return }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.18
                        self.tabIndicator.animator().alphaValue = 1
                    }
                }
            }
        }
        let w = size.width, h = size.height
        let target = NSRect(x: (centerX - w / 2).rounded(), y: band, width: w, height: h)
        if view !== content {
            dismissContent(direction: direction, animated: animated)
            // Back to a screen that was still fading out (a quick A → B → A): drop its exit, or
            // the held-over fade would blank it once it has arrived.
            view.layer?.removeAnimation(forKey: "leave")
            view.layer?.removeAnimation(forKey: "slide")
            view.layer?.opacity = 1
            view.frame = target
            host.addSubview(view)
            content = view
            if animated {
                // Switching tabs: the new screen starts moving with the tab pill, from the side
                // you moved toward. Opening fresh: it settles in from just above, once the island
                // has begun to open. Reduce Motion: a short fade.
                Motion.arrive(view, direction: direction, distance: 16, delay: wasOpen ? 0.02 : 0.1)
                // …and its rows grow in one after another below the header.
                if view is CardContent, size.height > Isle.headerHeight + 60 {
                    Motion.stagger(view, below: Isle.headerHeight, delay: wasOpen ? 0.05 : 0.14)
                }
            }
        } else {
            view.frame = target
        }
        applyShape(shapeRect(width: w, height: band + h), corner: Isle.corner, animated: animated)
        if let t = whisperText { (content as? CardBase)?.whispering = true; whisperView.text = t }
        layoutWhisper()
    }

    private func dismissContent(direction: CGFloat, animated: Bool) {
        guard let old = content else { return }
        content = nil
        guard animated, !Motion.reduced, old.window != nil else { old.removeFromSuperview(); return }
        old.wantsLayer = true
        let id = UUID().uuidString
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.14
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        fade.setValue(id, forKey: "zeraExitID")
        old.layer?.add(fade, forKey: "leave")
        if direction != 0 {
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = 0; move.toValue = -direction * 12; move.duration = 0.16
            move.fillMode = .forwards; move.isRemovedOnCompletion = false
            old.layer?.add(move, forKey: "slide")
        }
        // Always remove the outgoing screen, even if AppKit interrupts its animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak old, weak self] in
            guard let old = old, old !== self?.content,
                  old.layer?.animation(forKey: "leave")?.value(forKey: "zeraExitID") as? String == id else { return }
            old.removeFromSuperview()
            old.layer?.removeAllAnimations()
            old.layer?.opacity = 1
        }
    }

    /// The island, with a little slack, in view coordinates; tabs count in peek.
    func islandContains(_ p: NSPoint) -> Bool {
        guard mode != .closed else { return false }
        if tiledPeek {
            // Transparent shoulders must not intercept the macOS menu bar.
            if fillMask.path?.contains(p) == true { return true }
        } else if islandRect.insetBy(dx: -2, dy: -2).contains(p) { return true }
        // Bloomed: the nodes and the search node take clicks; the gaps between them don't.
        guard mode == .peek else { return false }
        return tabs.contains { $0.frame.contains(p) } || (!searchNode.isHidden && searchNode.alphaValue > 0 && searchNode.frame.contains(p))
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

/// What a node shows live, instead of a plain glyph: a ring (0…1) and a few characters inside it.
struct IslandInstrument: Equatable {
    var progress: CGFloat?
    var text: String?
    /// Ring colour; the accent when nil.
    var tone: NSColor?
}

/// One node of the rail at notch level (v2): a small round instrument — a ring with a number, or
/// the screen's glyph — that wears a count badge (amber when something there needs you). The
/// open screen's node gets the accent ring, drawn underneath by `IslandTabIndicator`.
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
    var instrument: IslandInstrument? { didSet { if instrument != oldValue { needsDisplay = true } } }
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

    /// Bloomed around Zera: a larger node with its name under it.
    var tiled = false { didSet { if tiled != oldValue { needsDisplay = true } } }
    var bloomed = false { didSet { if bloomed != oldValue { needsDisplay = true } } }
    static let labelH: CGFloat = 20

    /// The node's circle inside its frame (the frame leaves room for the badge, and in the
    /// bloom for the name under it).
    var disc: NSRect {
        if tiled {
            let d = max(0, min(64, bounds.width - Space.s * 2, bounds.height - Self.labelH - Space.s * 2))
            return NSRect(x: (bounds.width - d) / 2, y: Space.m, width: d, height: d)
        }
        let h = bloomed ? bounds.height - Self.labelH : bounds.height
        let d = min(bounds.width, h) - 4
        return NSRect(x: (bounds.width - d) / 2, y: (h - d) / 2, width: d, height: d)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = disc
        guard c.width > 4 else { return }
        let k = c.width / 28          // everything scales with the node
        let t = ThemeStore.shared.current
        let circle = NSBezierPath(ovalIn: c)
        if tiled {
            let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Radius.l, yRadius: Radius.l)
            NSGradient(starting: t.glassTop, ending: t.glassBottom)?.draw(in: card, angle: -90)
            (hovered ? t.accent.withAlphaComponent(0.6) : t.border).setStroke()
            card.lineWidth = 0.75; card.stroke()
        } else if bloomed {
            Neon.glowing(NSColor.black.withAlphaComponent(0.55), blur: 18) { t.glassBottom.setFill(); circle.fill() }
        }
        // A glass bead: lit a little from the top with the accent.
        let top = t.glassTop.blended(withFraction: hovered ? 0.24 : 0.14, of: t.accent) ?? t.glassTop
        NSGradient(starting: top, ending: t.glassBottom)?.draw(in: circle, angle: -90)
        (hovered && !isOn ? t.accent.withAlphaComponent(0.7) : t.border.withAlphaComponent(min(1, t.border.alphaComponent * 1.6))).setStroke()
        circle.lineWidth = 1; circle.stroke()

        let ink = isOn || hovered ? Neon.text : Neon.textDim
        if let ins = instrument, let p = ins.progress {
            let r = c.insetBy(dx: 4.5 * k, dy: 4.5 * k)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = 2.2 * k
            Neon.text.withAlphaComponent(0.1).setStroke(); track.stroke()
            let v = max(0, min(1, p))
            if v > 0.005 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                              startAngle: -90, endAngle: -90 + 360 * v, clockwise: false)
                arc.lineWidth = 2.2 * k; arc.lineCapStyle = .round
                (ins.tone ?? Neon.accent).setStroke(); arc.stroke()
            }
            if let text = ins.text, !text.isEmpty {
                let font = NSFont.monospacedDigitSystemFont(ofSize: (text.count > 2 ? 7 : 8.5) * min(k, 1.55), weight: .bold)
                let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                let sz = (text as NSString).size(withAttributes: a)
                (text as NSString).draw(at: NSPoint(x: c.midX - sz.width / 2, y: c.midY - sz.height / 2), withAttributes: a)
            } else {
                Neon.symbol(Isle.symbol(for: kind), in: c, size: 9.5 * k, weight: .semibold, color: ink)
            }
        } else {
            Neon.symbol(Isle.symbol(for: kind), in: c, size: 12 * k, weight: .semibold, color: isOn ? Neon.accent : ink)
        }

        if count > 0 || hasBadge {
            let text = count > 0 ? (count > 9 ? "9+" : "\(count)") : ""
            let b = min(1.35, k)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5 * b, weight: .heavy)
            let tw = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
            let w = text.isEmpty ? 8 * b : max(13 * b, tw + 6 * b), h: CGFloat = (text.isEmpty ? 8 : 13) * b
            let pill = NSRect(x: c.maxX - w * 0.75, y: c.maxY - h * 0.85, width: w, height: h)
            let tone = hasBadge ? Neon.warning : Neon.accent
            Neon.glowing(tone.withAlphaComponent(0.7), blur: 6) { tone.setFill(); NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill() }
            if !text.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Neon.onAccent]
                let ts = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: NSPoint(x: pill.midX - ts.width / 2, y: pill.midY - ts.height / 2), withAttributes: attrs)
            }
        }
        if bloomed {
            let name = kind == .github ? "Pull requests" : kind.title
            let a: [NSAttributedString.Key: Any] = [.font: Typo.control,
                                                    .foregroundColor: hovered ? Neon.text : Neon.textDim]
            let sz = (name as NSString).size(withAttributes: a)
            let y = tiled ? bounds.maxY - Space.s - sz.height : bounds.maxY - Self.labelH + 4
            (name as NSString).draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: y), withAttributes: a)
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

/// A small round button at notch level: the lens's close (✕) on the island's right edge, and
/// the App Opener's search node (🔍) after the rail.
final class IslandClose: NSView {
    var onTap: (() -> Void)?
    private let symbol: String
    /// The search node glows in the accent; close stays quiet.
    private let accent: Bool
    var expanded = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(symbol: String = "xmark", label: String = "Close", tip: String = "Close (Esc)", accent: Bool = false) {
        self.symbol = symbol
        self.accent = accent
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = tip
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        if expanded {
            let t = ThemeStore.shared.current
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.m, yRadius: Radius.m)
            (hovered ? t.glassTop : t.glassBottom).setFill(); p.fill()
            (hovered ? t.accent.withAlphaComponent(0.6) : t.border).setStroke(); p.lineWidth = 0.75; p.stroke()
            Neon.symbol(symbol, in: NSRect(x: 12, y: 9, width: 20, height: 20), size: 15, weight: .regular, color: Neon.textDim)
            ("Search apps and commands…" as NSString).draw(at: NSPoint(x: 42, y: 11),
                withAttributes: [.font: Typo.control, .foregroundColor: Neon.textDim])
            return
        }
        let d = min(bounds.width, bounds.height) - 2
        let disc = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        let c = NSBezierPath(ovalIn: disc)
        if accent {
            let t = ThemeStore.shared.current
            let top = t.glassTop.blended(withFraction: hovered ? 0.34 : 0.2, of: t.accent) ?? t.glassTop
            NSGradient(starting: top, ending: t.glassBottom)?.draw(in: c, angle: -90)
            t.accent.withAlphaComponent(hovered ? 0.9 : 0.55).setStroke(); c.lineWidth = 1; c.stroke()
            Neon.symbol(symbol, in: disc, size: max(11.5, d * 0.36), weight: .bold, color: hovered ? Neon.text : Neon.accent)
        } else {
            (hovered ? Neon.chipHover : Neon.chip).setFill(); c.fill()
            Neon.symbol(symbol, in: disc, size: 9.5, weight: .bold, color: hovered ? Neon.text : Neon.textFaint)
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
        // The open node: an accent ring with a soft halo, gliding from node to node.
        let at = indicator.rect
        let d = min(at.width, at.height) - 4
        let disc = NSRect(x: at.midX - d / 2, y: at.midY - d / 2, width: d, height: d)
        Neon.glowing(Neon.accent.withAlphaComponent(0.55), blur: 10) {
            Neon.accent.withAlphaComponent(0.22).setFill(); NSBezierPath(ovalIn: disc.insetBy(dx: -3, dy: -3)).fill()
        }
        let ring = NSBezierPath(ovalIn: disc.insetBy(dx: -0.5, dy: -0.5))
        Neon.accent.setStroke(); ring.lineWidth = 1.5; ring.stroke()
    }
}
