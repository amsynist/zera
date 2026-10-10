import AppKit

/// The visit only leaves the waiting state after an explicit acknowledgement.
struct WaterVisitMotion {
    enum Stage { case arriving, waiting, thanking, returning, finished }
    static let arrivalDuration: TimeInterval = 1.25
    static let returnDuration: TimeInterval = 1.0
    private(set) var stage: Stage = .arriving
    private(set) var changedAt: TimeInterval
    init(at now: TimeInterval) { changedAt = now }

    mutating func advance(at now: TimeInterval, reduced: Bool) {
        switch stage {
        case .arriving where reduced || now - changedAt >= Self.arrivalDuration: stage = .waiting; changedAt = now
        case .thanking where now - changedAt >= 2.1: stage = .returning; changedAt = now
        case .returning where reduced || now - changedAt >= Self.returnDuration: stage = .finished; changedAt = now
        default: break
        }
    }
    @discardableResult mutating func acknowledge(at now: TimeInterval) -> Bool {
        guard stage == .waiting || stage == .arriving else { return false }
        stage = .thanking; changedAt = now; return true
    }
    func position(at now: TimeInterval, from: CGPoint, to: CGPoint) -> CGPoint {
        guard stage == .arriving || stage == .returning else { return stage == .finished ? from : to }
        let returning = stage == .returning
        let elapsed = max(0, now - changedAt)
        // Crouch, fly, then absorb the landing. The window stays still while the
        // body anticipates and settles, so there is no positional correction.
        let t = CGFloat(min(1, max(0, (elapsed - 0.16) / (returning ? 0.72 : 0.78))))
        let ease = t * t * (3 - 2 * t)
        let start = returning ? to : from, end = returning ? from : to
        let distance = hypot(end.x - start.x, end.y - start.y)
        let arc = 16 * t * t * (1 - t) * (1 - t) * min(145, max(65, distance * 0.16))
        return CGPoint(x: start.x + (end.x - start.x) * ease,
                       y: start.y + (end.y - start.y) * ease + arc)
    }
    func body(at now: TimeInterval, direction: CGFloat = 1) -> AnimatedZeraView.BodyMotion {
        let elapsed = max(0, now - changedAt)
        switch stage {
        case .arriving, .returning:
            if elapsed < 0.16 {
                let crouch = CGFloat(pow(sin(elapsed / 0.16 * .pi), 2))
                return .init(angle: -direction * 5 * crouch, sx: 1 + 0.11 * crouch, sy: 1 - 0.17 * crouch)
            }
            let flight = stage == .returning ? 0.72 : 0.78
            if elapsed < 0.16 + flight {
                let t = CGFloat((elapsed - 0.16) / flight)
                let stretch = pow(sin(t * .pi), 2)
                return .init(angle: direction * 16 * sin(t * 2 * .pi) * stretch,
                             sx: 1 - 0.07 * stretch, sy: 1 + 0.10 * stretch)
            }
            let duration = stage == .returning ? Self.returnDuration : Self.arrivalDuration
            let settle = CGFloat(min(1, (elapsed - 0.16 - flight) / (duration - 0.16 - flight)))
            let spring = sin(settle * 2 * .pi) * sin(settle * .pi)
            return .init(y: max(0, -spring) * 8, angle: direction * 3 * spring,
                         sx: 1 + 0.12 * spring, sy: 1 - 0.18 * spring)
        case .waiting:
            let beat = elapsed.truncatingRemainder(dividingBy: 12)
            let phrase = Int(elapsed / 12) % WaterVisitView.prompts.count
            // Brief acting at the start of a line, followed by a quiet idle.
            let t = CGFloat(min(1, beat / 2.4)), envelope = pow(sin(t * .pi), 2)
            switch phrase {
            case 0: return .init(x: direction * 3 * sin(t * 6 * .pi) * envelope, angle: direction * 5 * envelope)
            case 1: return .init(y: 5 * envelope, angle: -direction * 7 * envelope, sx: 1 + 0.025 * envelope, sy: 1 + 0.025 * envelope)
            case 2: return .init(angle: 7 * sin(t * 4 * .pi) * envelope)
            case 3: return .init(y: -3 * envelope, angle: direction * 9 * envelope, sx: 1 + 0.05 * envelope, sy: 1 - 0.07 * envelope)
            case 4: return .init(y: 7 * pow(sin(t * 3 * .pi), 2) * envelope, angle: direction * 4 * envelope)
            default: return .init(angle: -direction * 6 * envelope)
            }
        case .thanking:
            let t = CGFloat(min(1, elapsed / 1.4)), joy = pow(sin(t * .pi), 2)
            return .init(y: 8 * pow(sin(t * 2 * .pi), 2) * joy, angle: 5 * sin(t * 2 * .pi) * joy)
        case .finished: return .init()
        }
    }
    static func landing(cursor: CGPoint, visibleFrame: CGRect, size: CGSize) -> CGPoint {
        let proposedX = cursor.x + 28 + size.width <= visibleFrame.maxX ? cursor.x + 28 : cursor.x - size.width - 28
        return CGPoint(x: max(visibleFrame.minX + 8, min(proposedX, visibleFrame.maxX - size.width - 8)),
                       y: max(visibleFrame.minY + 8, min(cursor.y - size.height * 0.6, visibleFrame.maxY - size.height - 8)))
    }
}

/// Nonactivating, cursor-side visit. No global clicks, focus changes or extra timer.
final class WaterReminderVisit {
    private let panel = FloatingPanel.make(size: WaterVisitView.size, level: .popUpMenu, keyable: false)
    let view = WaterVisitView(frame: NSRect(origin: .zero, size: WaterVisitView.size))
    var onAcknowledge: (() -> Void)?
    var onReturn: (() -> Void)?
    var isActive: Bool { view.motion.stage != .finished && panel.isVisible }

    init() {
        panel.hasShadow = false
        panel.contentView = view
        view.onPosition = { [weak self] point in self?.panel.setFrameOrigin(point) }
        view.onAcknowledge = { [weak self] in self?.onAcknowledge?() }
        view.onReturn = { [weak self] in
            self?.panel.orderOut(nil); self?.onReturn?()
        }
    }
    func show(from home: CGPoint) {
        guard !isActive else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        view.landing = WaterVisitMotion.landing(cursor: mouse, visibleFrame: screen.visibleFrame, size: WaterVisitView.size)
        view.bubbleOnLeft = view.landing.x < mouse.x
        view.departure = CGPoint(x: home.x - (view.bubbleOnLeft ? 335 : 55), y: home.y - 88)
        view.begin()
        panel.setFrameOrigin(view.departure)
        panel.orderFrontRegardless()
        ZeraAnimationClock.shared.refresh()
    }
    func acknowledge() { view.acknowledge() }
    deinit { panel.orderOut(nil) }
}

final class WaterVisitView: NSView, ZeraAnimating {
    static let size = CGSize(width: 390, height: 180)
    static let prompts = [
        "Tiny screen tap! Your water misses you. A sip? 💧",
        "One tiny sip? Look, I'm doing my very best puppy eyes.",
        "Another tab? Interesting. Is that tab a glass of water?",
        "I've aged three business days waiting for this sip.",
        "Emotional support boba is here. Your water is over there.",
        "Plot twist: the main character drinks water. That's you. 💧"
    ]
    private(set) var motion = WaterVisitMotion(at: 0)
    var departure = CGPoint.zero, landing = CGPoint.zero
    var bubbleOnLeft = false { didSet { needsLayout = true } }
    var onAcknowledge: (() -> Void)?
    var onReturn: (() -> Void)?
    var onPosition: ((CGPoint) -> Void)?
    let figure = AnimatedZeraView()
    private let glass = WaterSpeechGlass()
    private let text = rlabel(Typo.bodyMedium, Pal.text, lines: 3)
    private let heading = rlabel(Typo.detailTitle, Pal.text)
    private var okay: PRActionButton!
    private(set) var waitingExpression: ZeraExpression = .neutral
    private var lastPrompt = -1
    private var lastTap: TimeInterval = -10
    private var time: TimeInterval = 0
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.roundLayer(Radius.card); addSubview(glass)
        heading.stringValue = "A little water break"
        glass.addSubview(heading); glass.addSubview(text)
        okay = PRActionButton("Okay, drinking", style: .secondary, symbol: "checkmark", target: self, action: #selector(acknowledge))
        glass.addSubview(okay)
        figure.pose = "boba"; addSubview(figure)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ZeraAnimationClock.shared.remove(self) } else { ZeraAnimationClock.shared.add(self) }
    }
    func begin(at now: TimeInterval = CACurrentMediaTime()) {
        motion = WaterVisitMotion(at: now); time = now; lastPrompt = -1; lastTap = -10
        heading.stringValue = "A little water break"; okay.isHidden = false
        figure.pose = "boba"; figure.expression = .surprised; figure.bodyMotion = .init(); glass.isHidden = true
        needsLayout = true
    }
    @objc func acknowledge() {
        guard motion.acknowledge(at: CACurrentMediaTime()) else { return }
        heading.stringValue = "That's my hydrated human!"
        text.stringValue = "Nice sip. Your brain says thanks. Back to my perch! 💙"
        okay.isHidden = true; figure.pose = "boba"; figure.expression = .happy; figure.tap(); figure.speak(for: 2.1)
        glass.isHidden = false
        onAcknowledge?()
    }
    func advanceAnimation(at now: TimeInterval) {
        time = now
        let oldStage = motion.stage
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        motion.advance(at: now, reduced: reduced)
        let point = motion.position(at: now, from: departure, to: landing)
        figure.bodyMotion = reduced ? .init() : motion.body(at: now, direction: bubbleOnLeft ? -1 : 1)
        if !reduced || oldStage != motion.stage { onPosition?(point) }
        glass.isHidden = motion.stage == .arriving || motion.stage == .returning || motion.stage == .finished
        glass.alphaValue = reduced || motion.stage != .waiting ? 1 : min(1, max(0, (now - motion.changedAt) / 0.18))
        if motion.stage == .waiting {
            let elapsed = now - motion.changedAt
            let index = Int(elapsed / 12) % Self.prompts.count
            if index != lastPrompt {
                lastPrompt = index; text.stringValue = Self.prompts[index]
                waitingExpression = [.neutral, .pleading, .unimpressed, .sleepy, .happy, .thoughtful][index]
                figure.expression = waitingExpression
                figure.speak()
            }
            // Three light taps, followed by a quiet pause; never interact with another app.
            let beat = elapsed.truncatingRemainder(dividingBy: 12)
            if (index == 0 || index == 2) && beat < 1.1 && now - lastTap >= 0.36 { lastTap = now; figure.tap(at: now) }
        }
        if motion.stage == .finished && oldStage != .finished { onReturn?() }
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        figure.frame = NSRect(x: bubbleOnLeft ? 284 : 4, y: 16, width: 102, height: 152)
        glass.frame = NSRect(x: bubbleOnLeft ? 6 : 108, y: 18, width: 276, height: 144)
        heading.frame = NSRect(x: Space.l, y: Space.m, width: 244, height: 22)
        text.frame = NSRect(x: Space.l, y: 42, width: 244, height: 48)
        okay.frame = NSRect(x: Space.l, y: 100, width: okay.fittedWidth, height: 32)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), hit !== self else { return nil }
        return hit
    }
    override func draw(_ dirtyRect: NSRect) {
        guard motion.stage == .waiting, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let t = time - lastTap
        guard t >= 0 && t < 0.5 else { return }
        let radius = CGFloat(5 + t * 28)
        Pal.accent.withAlphaComponent(CGFloat(1 - t / 0.5) * 0.65).setStroke()
        let ripple = NSBezierPath(ovalIn: NSRect(x: (bubbleOnLeft ? 286 : 94) - radius, y: 99 - radius, width: radius * 2, height: radius * 2))
        ripple.lineWidth = 1.5; ripple.stroke()
    }
}

private final class WaterSpeechGlass: NSView {
    private let blur = NSVisualEffectView()
    private let paint = WaterSpeechPaint()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        blur.material = .hudWindow; blur.blendingMode = .behindWindow; blur.state = .active
        addSubview(blur); addSubview(paint)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); blur.frame = bounds; paint.frame = bounds }
}

private final class WaterSpeechPaint: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.card, yRadius: Radius.card)
        NSGradient(starting: Pal.cardTop.withAlphaComponent(0.60), ending: Pal.cardBottom.withAlphaComponent(0.78))?.draw(in: path, angle: -90)
        Pal.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
}
