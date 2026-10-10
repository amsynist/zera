import AppKit

/// Splash, the water visit: a glass of water pops up beside the pointer while Zera jumps from
/// the notch into it with a splash. She waves from the water until you answer. Drank: she drinks
/// and jumps home. 10 min: she jumps home and the reminder snoozes. Left alone for 30 s she jumps
/// home and leaves a bead under the notch. It never takes focus or clicks outside its own buttons.
struct WaterVisitMotion {
    enum Stage { case jumping, waiting, drinking, returning, finished }
    enum Outcome { case drank, later, ignored }
    static let jumpDuration: TimeInterval = 0.75
    static let popDuration: TimeInterval = 0.42
    static let drinkDuration: TimeInterval = 1.1
    static let returnDuration: TimeInterval = 0.7
    static let ignoreAfter: TimeInterval = 30
    /// How far the arc rises above the higher of its two ends.
    static let arcLift: CGFloat = 90

    private(set) var stage: Stage = .jumping
    private(set) var changedAt: TimeInterval
    let startedAt: TimeInterval
    private(set) var outcome: Outcome?
    init(at now: TimeInterval) { changedAt = now; startedAt = now }

    mutating func advance(at now: TimeInterval, reduced: Bool) {
        let elapsed = now - changedAt
        switch stage {
        case .jumping where reduced || elapsed >= Self.jumpDuration: move(to: .waiting, at: now)
        case .waiting where elapsed >= Self.ignoreAfter: outcome = .ignored; move(to: .returning, at: now)
        case .drinking where reduced || elapsed >= Self.drinkDuration: move(to: .returning, at: now)
        case .returning where reduced || elapsed >= Self.returnDuration: move(to: .finished, at: now)
        default: break
        }
    }
    @discardableResult mutating func drank(at now: TimeInterval) -> Bool {
        guard stage == .waiting || stage == .jumping else { return false }
        outcome = .drank; move(to: .drinking, at: now); return true
    }
    @discardableResult mutating func later(at now: TimeInterval) -> Bool {
        guard stage == .waiting else { return false }
        outcome = .later; move(to: .returning, at: now); return true
    }
    private mutating func move(to next: Stage, at now: TimeInterval) { stage = next; changedAt = now }

    /// 0…1 through the current jump (down into the glass or back up), nil while she isn't in the air.
    func flight(at now: TimeInterval) -> CGFloat? {
        let duration: TimeInterval
        switch stage {
        case .jumping: duration = Self.jumpDuration
        case .returning: duration = Self.returnDuration
        default: return nil
        }
        return CGFloat(min(1, max(0, (now - changedAt) / duration)))
    }
    /// One arc from `a` to `b` in screen points (y up), eased, peaking `arcLift` above the higher end.
    static func arc(_ t: CGFloat, from a: CGPoint, to b: CGPoint) -> CGPoint {
        let s = t * t * (3 - 2 * t), u = 1 - s
        let peak = max(a.y, b.y) + arcLift
        return CGPoint(x: u * u * a.x + 2 * u * s * (a.x + b.x) / 2 + s * s * b.x,
                       y: u * u * a.y + 2 * u * s * peak + s * s * b.y)
    }
    /// The glass growing from its base: 0 → 1.1 → 1.
    static func popScale(_ elapsed: TimeInterval) -> CGFloat {
        let t = CGFloat(min(1, max(0, elapsed / popDuration)))
        if t < 0.6 { let k = t / 0.6; return 1.1 * k * k * (3 - 2 * k) }
        let k = (t - 0.6) / 0.4
        return 1.1 - 0.1 * k * k * (3 - 2 * k)
    }
    /// The glass squashing as she lands, settling back to 1 × 1.
    static func squash(_ elapsed: TimeInterval) -> (sx: CGFloat, sy: CGFloat) {
        guard elapsed >= 0, elapsed < 0.42 else { return (1, 1) }
        let wave = CGFloat(sin(elapsed / 0.42 * .pi * 2) * (1 - elapsed / 0.42))
        return (1 + 0.05 * wave, 1 - 0.06 * wave)
    }
}

/// Owns the three small windows: the glass with its reminder, Zera in flight, and the bead.
final class WaterReminderVisit {
    private let panel = FloatingPanel.make(size: WaterVisitView.size, level: .popUpMenu, keyable: false)
    private let jumperPanel = FloatingPanel.make(size: WaterJumperView.size, level: .popUpMenu, keyable: false)
    private let beadPanel = FloatingPanel.make(size: WaterBeadView.size, level: .popUpMenu, keyable: false)
    let view = WaterVisitView(frame: NSRect(origin: .zero, size: WaterVisitView.size))
    private let jumper = WaterJumperView(frame: NSRect(origin: .zero, size: WaterJumperView.size))
    private let bead = WaterBeadView(frame: NSRect(origin: .zero, size: WaterBeadView.size))
    var onDrank: (() -> Void)?
    var onLater: (() -> Void)?
    var onReturn: ((WaterVisitMotion.Outcome?) -> Void)?
    var onBead: (() -> Void)?
    var isActive: Bool { view.motion.stage != .finished && panel.isVisible }

    init() {
        for p in [panel, jumperPanel, beadPanel] { p.hasShadow = false }
        panel.contentView = view
        jumperPanel.contentView = jumper
        jumperPanel.ignoresMouseEvents = true
        beadPanel.contentView = bead
        view.onDrank = { [weak self] in self?.onDrank?() }
        view.onLater = { [weak self] in self?.onLater?() }
        view.onJumper = { [weak self] center, angle, pose in self?.moveJumper(center, angle: angle, pose: pose) }
        view.onReturn = { [weak self] outcome in
            self?.panel.orderOut(nil); self?.jumperPanel.orderOut(nil)
            self?.onReturn?(outcome)
        }
        bead.onClick = { [weak self] in self?.hideBead(); self?.onBead?() }
    }

    /// Pops the glass up beside the pointer and sends Zera from `home` (her head, in screen points).
    func show(from home: CGPoint, detail: String) {
        guard !isActive else { return }
        hideBead()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let place = WaterVisitView.placement(cursor: mouse, visibleFrame: screen.visibleFrame)
        view.mirrored = place.mirrored
        view.origin = place.origin
        view.home = home
        view.detail = detail
        panel.setFrameOrigin(place.origin)
        view.begin()
        panel.orderFrontRegardless()
        ZeraAnimationClock.shared.refresh()
    }
    func drank() { view.drank() }

    /// A small bead under the notch, right of her rope: the reminder is still waiting.
    func showBead(below notch: CGRect) {
        let s = WaterBeadView.size
        beadPanel.setFrameOrigin(CGPoint(x: notch.midX + 26 - s.width / 2, y: notch.minY - s.height - 4))
        bead.appear()
        beadPanel.orderFrontRegardless()
    }
    func hideBead() { beadPanel.orderOut(nil) }
    var isBeadShowing: Bool { beadPanel.isVisible }

    private func moveJumper(_ center: CGPoint?, angle: CGFloat, pose: String) {
        guard let center else { jumperPanel.orderOut(nil); return }
        let s = WaterJumperView.size
        jumper.figure.pose = pose
        jumper.figure.frameCenterRotation = angle
        jumperPanel.setFrameOrigin(CGPoint(x: center.x - s.width / 2, y: center.y - s.height / 2))
        if !jumperPanel.isVisible { jumperPanel.orderFrontRegardless() }
    }

    deinit { panel.orderOut(nil); jumperPanel.orderOut(nil); beadPanel.orderOut(nil) }
}

/// The glass beside the pointer, Zera in it, the splash, and the reminder capsule.
final class WaterVisitView: NSView, ZeraAnimating {
    static let size = CGSize(width: 612, height: 208)
    static let glassSize = CGSize(width: 80, height: 96)
    static let capsuleSize = CGSize(width: 420, height: 58)
    /// Clear space round the glass for the splash and her head.
    static let side: CGFloat = 60

    /// The glass in this view's (flipped) coordinates.
    static func glassRect(mirrored: Bool) -> NSRect {
        NSRect(x: mirrored ? size.width - side - glassSize.width : side, y: 92, width: glassSize.width, height: glassSize.height)
    }
    static func capsuleRect(mirrored: Bool) -> NSRect {
        let g = glassRect(mirrored: mirrored)
        return NSRect(x: mirrored ? g.minX - 16 - capsuleSize.width : g.maxX + 16, y: g.minY + 12,
                      width: capsuleSize.width, height: capsuleSize.height)
    }
    /// The glass 22 pt right of and below the pointer's tip (left of it near the right edge),
    /// so it never sits under the pointer; the window kept inside the screen.
    static func placement(cursor: CGPoint, visibleFrame: CGRect) -> (origin: CGPoint, mirrored: Bool) {
        let mirrored = cursor.x + 22 + glassSize.width + 16 + capsuleSize.width + 16 > visibleFrame.maxX
        let g = glassRect(mirrored: mirrored)
        let glassLeft = mirrored ? cursor.x - 22 - g.width : cursor.x + 22
        let glassTop = cursor.y - 22
        let x = max(visibleFrame.minX, min(glassLeft - g.minX, visibleFrame.maxX - size.width))
        let y = max(visibleFrame.minY, min(glassTop - size.height + g.minY, visibleFrame.maxY - size.height))
        return (CGPoint(x: x, y: y), mirrored)
    }
    /// Where she sits in the glass, in screen points: the end of the jump down, the start of the one home.
    static func seat(origin: CGPoint, mirrored: Bool) -> CGPoint {
        let g = glassRect(mirrored: mirrored)
        return CGPoint(x: origin.x + g.midX, y: origin.y + size.height - g.minY - 12)
    }

    private(set) var motion = WaterVisitMotion(at: 0)
    var mirrored = false { didSet { needsLayout = true } }
    var origin = CGPoint.zero
    var home = CGPoint.zero
    var detail = "" { didSet { capsule.meta.stringValue = detail } }
    var onDrank: (() -> Void)?
    var onLater: (() -> Void)?
    var onReturn: ((WaterVisitMotion.Outcome?) -> Void)?
    /// Zera in the air: her centre in screen points (nil: not flying), her spin and her pose.
    var onJumper: ((CGPoint?, CGFloat, String) -> Void)?

    /// Whether to skip the jumps and the splash (the system's Reduce Motion; tests can set it).
    var reducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private let box = WaterGlassBox()
    let figure = AnimatedZeraView()
    private let capsule = WaterCapsule()
    private var landedAt: TimeInterval?
    private var lastStage: WaterVisitMotion.Stage = .finished
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        box.wantsLayer = true
        addSubview(box)
        box.insertFigure(figure)
        figure.pose = "hello"
        figure.setAccessibilityLabel("Zera, in a glass of water")
        capsule.drank.target = self; capsule.drank.action = #selector(drank)
        capsule.later.target = self; capsule.later.action = #selector(later)
        addSubview(capsule)
        capsule.alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ZeraAnimationClock.shared.remove(self) } else { ZeraAnimationClock.shared.add(self) }
    }

    func begin(at now: TimeInterval = CACurrentMediaTime()) {
        motion = WaterVisitMotion(at: now); landedAt = nil; lastStage = .jumping
        figure.pose = "hello"; figure.bodyMotion = .init(); figure.isHidden = true
        box.level = 0.64; box.splashAt = nil; box.scale = 0
        capsule.alphaValue = 0; capsule.isHidden = true
        capsule.drank.reset()
        needsLayout = true
        advanceAnimation(at: now)
    }

    @objc func drank() {
        guard motion.drank(at: CACurrentMediaTime()) else { return }
        if landedAt == nil { land(at: CACurrentMediaTime()) }
        figure.pose = "cheerful"
        onDrank?()
    }
    @objc func later() {
        guard motion.later(at: CACurrentMediaTime()) else { return }
        onLater?()
    }

    private func land(at now: TimeInterval) {
        landedAt = now
        figure.isHidden = false
        if !reducedMotion() { box.splashAt = now }
    }

    func advanceAnimation(at now: TimeInterval) {
        let reduced = reducedMotion()
        motion.advance(at: now, reduced: reduced)
        let stage = motion.stage
        defer { lastStage = stage }
        if stage != .jumping, landedAt == nil { land(at: now) }

        // The glass: pops up, squashes as she lands, shrinks away as she leaves.
        var scale = reduced ? 1 : WaterVisitMotion.popScale(now - motion.startedAt)
        if stage == .returning {
            let t = CGFloat(min(1, max(0, (now - motion.changedAt - 0.15) / 0.42)))
            scale *= reduced ? 0 : 1 - t * t
        }
        if stage == .finished { scale = 0 }
        box.scale = scale
        box.squash = landedAt.map { WaterVisitMotion.squash(now - $0) } ?? (1, 1)
        box.time = now

        // The water goes down as she drinks.
        if stage == .drinking {
            let t = CGFloat(min(1, (now - motion.changedAt) / WaterVisitMotion.drinkDuration))
            box.level = 0.64 - 0.52 * t * t * (3 - 2 * t)
        }

        // Zera: in the glass while waiting or drinking, in the air on the way there and back.
        figure.isHidden = !(stage == .waiting || stage == .drinking)
        if let landed = landedAt, stage == .waiting, !reduced {
            let t = CGFloat(min(1, (now - landed) / 0.5))
            figure.bodyMotion = .init(y: -14 * (1 - t * t * (3 - 2 * t)))
        } else {
            figure.bodyMotion = .init()
        }
        if stage == .waiting { figure.pose = "hello" }

        let seat = Self.seat(origin: origin, mirrored: mirrored)
        if let t = motion.flight(at: now), !reduced, stage != .finished {
            if stage == .jumping {
                onJumper?(WaterVisitMotion.arc(t, from: home, to: seat), -360 * t, "excited")
            } else {
                let pose = motion.outcome == .drank ? "cheerful" : "sleepy"
                onJumper?(WaterVisitMotion.arc(t, from: seat, to: home), 360 * t, pose)
            }
        } else if lastStage == .jumping || lastStage == .returning || stage == .finished {
            onJumper?(nil, 0, "")
        }

        // The capsule slides in once she's surfaced, and goes as soon as you answer.
        let surfaced = landedAt.map { now - $0 >= (reduced ? 0 : 0.35) } ?? false
        // After Drank the bar stays a moment, so you see the button fill with water.
        let filling = stage == .drinking && !reduced && now - motion.changedAt < 0.55
        let showCapsule = (stage == .waiting && surfaced) || filling
        capsule.drank.advance(at: now, reduced: reduced)
        let target: CGFloat = showCapsule ? 1 : 0
        capsule.alphaValue += (target - capsule.alphaValue) * (reduced ? 1 : 0.3)
        if abs(capsule.alphaValue - target) < 0.02 { capsule.alphaValue = target }
        capsule.isHidden = capsule.alphaValue == 0
        capsule.offset = (1 - capsule.alphaValue) * (mirrored ? 10 : -10)
        capsule.needsLayout = true

        if stage == .finished && lastStage != .finished { onReturn?(motion.outcome) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let g = Self.glassRect(mirrored: mirrored)
        box.frame = NSRect(x: g.minX - Self.side, y: g.minY - 90, width: g.width + Self.side * 2, height: g.height + 98)
        let c = Self.capsuleRect(mirrored: mirrored)
        capsule.frame = c.offsetBy(dx: capsule.offset, dy: 0)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the capsule's buttons (and Zera herself) take clicks; the rest lets them through.
        guard let hit = super.hitTest(point), hit !== self, hit !== box, hit !== capsule else { return nil }
        return hit
    }
}

/// The glass, drawn in its own unflipped space so it can grow from its base.
private final class WaterGlassBox: NSView {
    /// The glass inside the box (y up): room above for her head and the splash, room round it for the drops.
    static let glass = NSRect(x: WaterVisitView.side, y: 8, width: WaterVisitView.glassSize.width, height: WaterVisitView.glassSize.height)
    var scale: CGFloat = 0 { didSet { applyTransform() } }
    var squash: (sx: CGFloat, sy: CGFloat) = (1, 1) { didSet { applyTransform() } }
    var level: CGFloat = 0.64 { didSet { front.needsDisplay = true } }
    var splashAt: TimeInterval?
    var time: TimeInterval = 0 { didSet { front.needsDisplay = true; drops.needsDisplay = true } }
    private let back = WaterGlassBack()
    private let front = WaterGlassFront()
    private let drops = WaterSplashDrops()

    override init(frame: NSRect) {
        super.init(frame: frame)
        front.box = self; drops.box = self
        addSubview(back); addSubview(front); addSubview(drops)
    }
    required init?(coder: NSCoder) { fatalError() }

    func insertFigure(_ figure: AnimatedZeraView) { addSubview(figure, positioned: .above, relativeTo: back) }

    override func layout() {
        super.layout()
        back.frame = bounds; front.frame = bounds; drops.frame = bounds
        let g = Self.glass
        // Her head and shoulders clear the rim by about 30 pt; the water covers her below the waist.
        for case let figure as AnimatedZeraView in subviews {
            figure.frame = NSRect(x: g.minX + 2, y: g.minY + 44, width: 76, height: 82)
        }
        applyTransform()
    }

    private func applyTransform() {
        guard let layer else { return }
        let g = Self.glass
        var t = CATransform3DMakeTranslation(g.midX, g.minY, 0)
        t = CATransform3DScale(t, scale * squash.sx, scale * squash.sy, 1)
        t = CATransform3DTranslate(t, -g.midX, -g.minY, 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.sublayerTransform = t
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for case let figure as AnimatedZeraView in subviews where !figure.isHidden && figure.frame.contains(local) {
            return figure
        }
        return nil
    }

    /// The glass's tapered outline.
    static func outline() -> NSBezierPath {
        let g = glass, inset: CGFloat = 9.6
        let p = NSBezierPath()
        p.move(to: NSPoint(x: g.minX, y: g.maxY))
        p.line(to: NSPoint(x: g.maxX, y: g.maxY))
        p.line(to: NSPoint(x: g.maxX - inset, y: g.minY))
        p.line(to: NSPoint(x: g.minX + inset, y: g.minY))
        p.close()
        p.lineJoinStyle = .round
        return p
    }
}

/// Behind her: the glass's body and its shadow.
private final class WaterGlassBack: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let g = WaterGlassBox.glass
        NSColor.black.withAlphaComponent(0.32).setFill()
        NSBezierPath(ovalIn: NSRect(x: g.minX + 4, y: g.minY - 6, width: g.width - 8, height: 9)).fill()
        let body = WaterGlassBox.outline()
        NSGradient(colors: [Pal.water.withAlphaComponent(0.14), Pal.cardBottom.withAlphaComponent(0.42), Pal.water.withAlphaComponent(0.10)])?
            .draw(in: body, angle: 0)
    }
}

/// In front of her: the water, its moving surface, the rim and one highlight.
private final class WaterGlassFront: NSView {
    weak var box: WaterGlassBox?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let box else { return }
        let g = WaterGlassBox.glass, outline = WaterGlassBox.outline()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let phase = reduced ? 0 : CGFloat(box.time) * 2.2
        let surface = g.minY + g.height * box.level
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        let water = NSBezierPath(), crest = NSBezierPath()
        for x in stride(from: g.minX - 2, through: g.maxX + 2, by: 2) {
            let point = NSPoint(x: x, y: surface + sin(x / 9 + phase) * 1.3)
            if x == g.minX - 2 { water.move(to: point); crest.move(to: point) } else { water.line(to: point); crest.line(to: point) }
        }
        water.line(to: NSPoint(x: g.maxX + 2, y: g.minY - 2)); water.line(to: NSPoint(x: g.minX - 2, y: g.minY - 2)); water.close()
        NSGradient(starting: Pal.water.withAlphaComponent(0.62), ending: Pal.waterDeep.withAlphaComponent(0.86))?.draw(in: water, angle: -90)
        NSColor.white.withAlphaComponent(0.55).setStroke(); crest.lineWidth = 1; crest.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.55).setStroke(); outline.lineWidth = 1.5; outline.stroke()
        let mouth = NSBezierPath(ovalIn: NSRect(x: g.minX + 0.8, y: g.maxY - 3, width: g.width - 1.6, height: 6))
        NSColor.white.withAlphaComponent(0.45).setStroke(); mouth.lineWidth = 1; mouth.stroke()
        let shine = NSBezierPath()
        shine.move(to: NSPoint(x: g.minX + 9, y: g.maxY - 10)); shine.line(to: NSPoint(x: g.minX + 14, y: g.minY + 12))
        NSColor.white.withAlphaComponent(0.5).setStroke(); shine.lineWidth = 3; shine.lineCapStyle = .round; shine.stroke()
    }
}

/// The splash: a ripple on the water and eight drops thrown up over the rim.
private final class WaterSplashDrops: NSView {
    weak var box: WaterGlassBox?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let box, let start = box.splashAt else { return }
        let p = CGFloat((box.time - start) / 0.75)
        guard p >= 0, p < 1 else { return }
        let g = WaterGlassBox.glass
        let surface = g.minY + g.height * box.level
        let ring = NSBezierPath(ovalIn: NSRect(x: g.midX - 40 * (0.4 + 1.2 * p), y: surface - 6 * (0.4 + 1.2 * p),
                                               width: 80 * (0.4 + 1.2 * p), height: 12 * (0.4 + 1.2 * p)))
        NSColor.white.withAlphaComponent(0.8 * (1 - p)).setStroke(); ring.lineWidth = 1.5; ring.stroke()
        for i in 0..<8 {
            let lane = CGFloat(i) - 3.5
            let reach = lane * 14 + CGFloat([3, -2, 4, -3, 2, -4, 1, -1][i])
            let rise = 42 + CGFloat(i % 3) * 14
            let x = g.midX + lane * 6 + reach * p
            let y = surface + rise * 4 * p * (1 - p) - 28 * p * p
            let drop = NSBezierPath(ovalIn: NSRect(x: x - 2.5, y: y - 3.5, width: 5, height: 7))
            Pal.water.withAlphaComponent(0.9 * (1 - p * p)).setFill(); drop.fill()
            NSColor.white.withAlphaComponent(0.8 * (1 - p * p)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1.2, y: y + 0.6, width: 1.6, height: 1.6)).fill()
        }
    }
}

/// The reminder beside the glass: what it is, today's line, Drank and 10 min.
private final class WaterCapsule: NSView {
    let title = rlabel(Typo.rowTitleStrong, Pal.text)
    let meta = rlabel(Typo.meta, Pal.textSecondary)
    let drank = WaterDrankButton("Drank", style: .secondary, target: nil, action: #selector(WaterVisitView.drank))
    let later = PRActionButton("10 min", style: .secondary, target: nil, action: #selector(WaterVisitView.later))
    var offset: CGFloat = 0
    private let blur = NSVisualEffectView()
    private let rim = WaterCapsuleRim()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blur.material = Pal.blurMaterial; blur.blendingMode = .behindWindow; blur.state = .active
        blur.wantsLayer = true
        addSubview(blur); addSubview(rim)
        title.stringValue = "Water break"
        meta.lineBreakMode = .byTruncatingTail
        drank.setLine("check"); later.setLine("clock")
        drank.setAccessibilityLabel("Drank water"); later.setAccessibilityLabel("Remind me in 10 minutes")
        [title, meta, drank, later].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let r = bounds.height / 2
        blur.frame = bounds; blur.layer?.cornerRadius = r; blur.layer?.masksToBounds = true
        rim.frame = bounds
        let lw = max(74, later.fittedWidth), dw = max(78, drank.fittedWidth), bh: CGFloat = 32
        later.frame = NSRect(x: bounds.width - 12 - lw, y: (bounds.height - bh) / 2, width: lw, height: bh)
        drank.frame = NSRect(x: later.frame.minX - 8 - dw, y: later.frame.minY, width: dw, height: bh)
        let tw = max(40, drank.frame.minX - 12 - 20)
        title.frame = NSRect(x: 20, y: 10, width: tw, height: 19)
        meta.frame = NSRect(x: 20, y: 30, width: tw, height: 17)
    }
}

private final class WaterCapsuleRim: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        Pal.cardBottom.withAlphaComponent(0.35).setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke(); path.lineWidth = 1; path.stroke()
    }
}

/// Drank, as a little glass of water: a sip of water sloshes in it at rest, it rises when you
/// point at it, and a tap fills it to the brim with waves and bubbles.
final class WaterDrankButton: PRActionButton {
    private var pointing = false
    private(set) var fill: CGFloat = 0.22
    private var phase: CGFloat = 0
    private var lastTime: TimeInterval?
    private(set) var tappedAt: TimeInterval?

    func reset() { fill = 0.22; tappedAt = nil; lastTime = nil; needsDisplay = true }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); pointing = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); pointing = false }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if tappedAt == nil { tappedAt = CACurrentMediaTime() }
        return super.sendAction(action, to: target)
    }

    func advance(at time: TimeInterval, reduced: Bool) {
        let dt = CGFloat(min(0.1, max(0, time - (lastTime ?? time))))
        lastTime = time
        let tapped = tappedAt != nil || isHighlighted
        let target: CGFloat = tapped ? 1.12 : (pointing || window?.firstResponder === self ? 0.52 : 0.22)
        fill += (target - fill) * (reduced ? 1 : 1 - exp(-dt * (tapped ? 7 : 5)))
        phase = reduced ? 0 : CGFloat(time)
        needsDisplay = true
    }

    override func drawContentBackground(in rect: NSRect) {
        let radius = min(Radius.m - 1, rect.height / 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        // The splash of a tap: the surface sloshes harder for a moment, then settles.
        let since = tappedAt.map { CGFloat(CACurrentMediaTime() - $0) } ?? 9
        let slosh = 1 + 2.2 * max(0, 1 - since / 0.8)
        func surface(_ speed: CGFloat, _ wavelength: CGFloat, _ amp: CGFloat, _ lift: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            for x in stride(from: rect.minX - 2, through: rect.maxX + 2, by: 2) {
                let level = rect.height * min(1.12, fill) + lift
                    + sin(x / wavelength + phase * speed) * amp * slosh + sin(x / (wavelength * 0.55) - phase * speed * 0.6) * amp * 0.4
                let y = flipped ? rect.maxY - level : rect.minY + level
                if x == rect.minX - 2 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
            }
            return path
        }
        let bottom = flipped ? rect.maxY + 2 : rect.minY - 2
        for (i, layer) in [(speed: CGFloat(-1.6), wavelength: CGFloat(13), amp: CGFloat(1.2), lift: CGFloat(1.5)),
                           (speed: CGFloat(2.2), wavelength: CGFloat(9), amp: CGFloat(1.4), lift: CGFloat(0))].enumerated() {
            let crest = surface(layer.speed, layer.wavelength, layer.amp, layer.lift)
            let water = crest.copy() as! NSBezierPath
            water.line(to: NSPoint(x: rect.maxX + 2, y: bottom)); water.line(to: NSPoint(x: rect.minX - 2, y: bottom)); water.close()
            NSGradient(starting: Pal.water.withAlphaComponent(i == 0 ? 0.22 : 0.42),
                       ending: Pal.waterDeep.withAlphaComponent(i == 0 ? 0.18 : 0.55))?.draw(in: water, angle: flipped ? -90 : 90)
            if i == 1 { NSColor.white.withAlphaComponent(0.45).setStroke(); crest.lineWidth = 0.9; crest.stroke() }
        }
        // Bubbles rise once there's water to rise through.
        guard fill > 0.35 else { return }
        for i in 0..<5 {
            let t = (phase * 0.55 + CGFloat(i) * 0.23).truncatingRemainder(dividingBy: 1)
            let x = rect.minX + rect.width * (0.15 + 0.17 * CGFloat(i)) + sin(phase * 2 + CGFloat(i)) * 2
            let rise = rect.height * min(1, fill) * t
            let y = flipped ? rect.maxY - 2 - rise : rect.minY + 2 + rise
            let r: CGFloat = i.isMultiple(of: 2) ? 1.3 : 1.9
            NSColor.white.withAlphaComponent(0.55 * sin(t * .pi)).setStroke()
            let bubble = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            bubble.lineWidth = 0.8; bubble.stroke()
        }
    }
}

/// Zera in the air between the notch and the glass. Spins about her middle.
final class WaterJumperView: NSView {
    static let size = CGSize(width: 140, height: 150)
    let figure = AnimatedZeraView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        figure.frame = NSRect(x: 30, y: 30, width: 80, height: 90)
        figure.pose = "excited"
        addSubview(figure)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The bead under the notch while a water reminder waits. Click it and she comes back down.
final class WaterBeadView: NSView {
    static let size = CGSize(width: 22, height: 26)
    var onClick: (() -> Void)?
    private var shownAt: TimeInterval = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Water reminder waiting")
        toolTip = "Water break · click when you're ready"
    }
    required init?(coder: NSCoder) { fatalError() }
    func appear() { alphaValue = 0; animator().alphaValue = 1; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 3)
        let drop = NSBezierPath()
        drop.move(to: NSPoint(x: r.midX, y: r.maxY))
        drop.curve(to: NSPoint(x: r.maxX, y: r.minY + r.width / 2), controlPoint1: NSPoint(x: r.midX + 3, y: r.maxY - 6), controlPoint2: NSPoint(x: r.maxX, y: r.minY + r.width))
        drop.appendArc(withCenter: NSPoint(x: r.midX, y: r.minY + r.width / 2), radius: r.width / 2, startAngle: 0, endAngle: 180, clockwise: true)
        drop.curve(to: NSPoint(x: r.midX, y: r.maxY), controlPoint1: NSPoint(x: r.minX, y: r.minY + r.width), controlPoint2: NSPoint(x: r.midX - 3, y: r.maxY - 6))
        drop.close()
        NSGradient(starting: Pal.water.withAlphaComponent(0.85), ending: Pal.waterDeep)?.draw(in: drop, angle: -90)
        NSColor.white.withAlphaComponent(0.7).setStroke(); drop.lineWidth = 0.8; drop.stroke()
    }
}
