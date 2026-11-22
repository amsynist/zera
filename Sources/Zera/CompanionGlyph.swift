import AppKit

/// Zera's own soft, luminous ember. Shared by the notch, Home and open-panel companion.
/// Shape, face, hands and light react together; no sprite rotation or downloaded artwork.
enum CompanionGlyph {
    /// Signal: her light is the interface's own status colour, so she and the screen agree.
    /// Idle is the signal colour; thinking blue; done green; needs you amber; failed red; asleep grey.
    static func tint(for mood: ZeraMood) -> NSColor {
        let t = ThemeStore.shared.current
        switch mood {
        case .focused, .thinking: return t.info
        case .approved, .celebrate, .giving: return t.success
        case .worried: return t.warning
        case .error, .sad: return t.danger
        case .sleepy, .cozy, .bored: return t.textTertiary
        default: return t.accent
        }
    }

    /// The signal core: the same silhouette, hands and gestures as before, drawn as dark glass
    /// with a rim in her mood colour, two cursor-block eyes that blink like the terminal cursor,
    /// and a glow under her that strengthens with attention.
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
    /// The glass body's light: the same every frame, so made once.
    private static let bodyGradient = CGGradient(colorsSpace: sRGB, colors: [NSColor(srgbRed: 0.14, green: 0.21, blue: 0.25, alpha: 1).cgColor,
                                                                              NSColor(srgbRed: 0.05, green: 0.08, blue: 0.11, alpha: 1).cgColor,
                                                                              NSColor(srgbRed: 0.02, green: 0.035, blue: 0.05, alpha: 1).cgColor] as CFArray,
                                                 locations: [0, 0.5, 1])

    static func draw(_ ctx: CGContext, in rect: CGRect, mood: ZeraMood, gaze: CGPoint,
                     blink: CGFloat, attention: CGFloat = 0, phase: TimeInterval = 0, reach: CGFloat = 0,
                     tint shown: NSColor? = nil) {
        let body = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.16)
        let d = body.width, center = CGPoint(x: body.midX, y: body.midY)
        // `shown`: the colour the caller is easing toward the mood's, so a mood change never snaps.
        let tint = shown ?? tint(for: mood)
        let happy = [.happy, .celebrate, .love, .approved, .giving, .excited, .hello].contains(mood)
        let rest = mood == .sleepy || mood == .cozy
        let worried = [.worried, .sad, .error].contains(mood)
        let surprise = mood == .surprised
        let focus = mood == .focused || mood == .thinking
        let glass = NSColor(srgbRed: 0.04, green: 0.07, blue: 0.09, alpha: 1)
        let shape = CGMutablePath()
        shape.move(to: CGPoint(x: body.minX, y: body.midY - d * 0.08))
        shape.addCurve(to: CGPoint(x: body.midX, y: body.maxY), control1: CGPoint(x: body.minX - d * 0.02, y: body.maxY - d * 0.16), control2: CGPoint(x: body.midX - d * 0.28, y: body.maxY + d * 0.035))
        shape.addCurve(to: CGPoint(x: body.maxX, y: body.midY - d * 0.08), control1: CGPoint(x: body.maxX - d * 0.12, y: body.maxY + d * 0.03), control2: CGPoint(x: body.maxX + d * 0.025, y: body.midY + d * 0.17))
        shape.addCurve(to: CGPoint(x: body.midX, y: body.minY), control1: CGPoint(x: body.maxX, y: body.minY + d * 0.015), control2: CGPoint(x: body.midX + d * 0.23, y: body.minY - d * 0.018))
        shape.addCurve(to: CGPoint(x: body.minX, y: body.midY - d * 0.08), control1: CGPoint(x: body.minX + d * 0.11, y: body.minY - d * 0.02), control2: CGPoint(x: body.minX, y: body.minY + d * 0.08))
        shape.closeSubpath()
        let rim = max(1, d * 0.024)
        if d > 28 {
            ctx.saveGState(); ctx.setLineCap(.round); ctx.setLineWidth(d * 0.1)
            for side: CGFloat in [-1, 1] {
                let waving = happy && side > 0 && reach < 0.5
                let wave = waving ? d * (0.2 + 0.045 * CGFloat(sin(phase * 9))) : -d * 0.37
                var hand = CGPoint(x: center.x + side * d * (waving ? 0.61 : 0.43), y: center.y + wave)
                // Reaching: both hands rise above her head, ready to catch.
                let raised = CGPoint(x: center.x + side * d * 0.5, y: center.y + d * 0.5)
                hand = CGPoint(x: hand.x + (raised.x - hand.x) * reach, y: hand.y + (raised.y - hand.y) * reach)
                ctx.setStrokeColor(tint.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(d * 0.1)
                ctx.move(to: CGPoint(x: center.x + side * d * 0.37, y: center.y - d * 0.15))
                ctx.addQuadCurve(to: hand, control: CGPoint(x: center.x + side * d * (0.66 - 0.04 * reach),
                                                            y: center.y - d * 0.1 + d * 0.12 * reach)); ctx.strokePath()
                let palm = CGRect(x: hand.x - d * 0.075, y: hand.y - d * 0.075, width: d * 0.15, height: d * 0.15)
                ctx.setFillColor(glass.cgColor); ctx.fillEllipse(in: palm)
                ctx.setLineWidth(rim * 0.8); ctx.strokeEllipse(in: palm)
                if waving {
                    ctx.setStrokeColor(tint.cgColor); ctx.setLineWidth(d * 0.045)
                    for (dx, dy): (CGFloat, CGFloat) in [(0, 0.13), (0.075, 0.09), (0.105, 0.025)] {
                        ctx.move(to: hand); ctx.addLine(to: CGPoint(x: hand.x + dx * d, y: hand.y + dy * d)); ctx.strokePath()
                    }
                }
            }
            ctx.restoreGState()
        }
        // Dark glass, lit from below by her own colour.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: d * (0.16 + attention * 0.1), color: tint.withAlphaComponent(0.55).cgColor)
        ctx.addPath(shape); ctx.setFillColor(glass.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(shape); ctx.clip()
        let space = Self.sRGB
        if let g = Self.bodyGradient {
            let light = CGPoint(x: body.minX + d * (0.34 + gaze.x * 0.03), y: body.maxY - d * 0.2)
            ctx.drawRadialGradient(g, startCenter: light, startRadius: 0, endCenter: light, endRadius: d * 0.95, options: [.drawsAfterEndLocation])
        }
        if let under = CGGradient(colorsSpace: space, colors: [tint.withAlphaComponent(0.34 + attention * 0.2).cgColor, tint.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
            let from = CGPoint(x: body.midX, y: body.minY - d * 0.05)
            ctx.drawRadialGradient(under, startCenter: from, startRadius: 0, endCenter: from, endRadius: d * 0.62, options: [])
        }
        ctx.restoreGState()
        ctx.saveGState()
        // A short highlight on the upper left of the glass.
        ctx.setLineCap(.round); ctx.setLineWidth(max(0.8, d * 0.018))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.26).cgColor)
        ctx.move(to: CGPoint(x: body.minX + d * 0.12, y: body.maxY - d * 0.3))
        ctx.addQuadCurve(to: CGPoint(x: body.minX + d * 0.36, y: body.maxY - d * 0.06), control: CGPoint(x: body.minX + d * 0.17, y: body.maxY - d * 0.1))
        ctx.strokePath()
        // The rim in her colour.
        ctx.addPath(shape); ctx.setStrokeColor(tint.cgColor); ctx.setLineWidth(rim); ctx.strokePath()
        // Face: cursor-block eyes and a mouth stroke, both lit.
        ctx.setShadow(offset: .zero, blur: d * 0.06, color: tint.cgColor)
        ctx.setFillColor(tint.cgColor); ctx.setStrokeColor(tint.cgColor)
        ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(max(1.1, d * 0.034))
        let eyeY = center.y + d * 0.02 + gaze.y * d * 0.04
        for side: CGFloat in [-1, 1] {
            let x = center.x + side * d * 0.165 + gaze.x * d * 0.045
            if rest || (happy && attention > 0.65) || (mood == .giving && side > 0) || blink > 0.92 {
                ctx.move(to: CGPoint(x: x - d * 0.055, y: eyeY))
                ctx.addQuadCurve(to: CGPoint(x: x + d * 0.055, y: eyeY), control: CGPoint(x: x, y: eyeY + (happy ? d * 0.08 : -d * 0.01))); ctx.strokePath()
            } else {
                // The block collapses toward its baseline when she blinks, like a cursor.
                let w = d * 0.088
                let full = d * (surprise ? 0.22 : focus ? 0.1 : 0.17)
                let h = max(d * 0.02, full * (1 - blink))
                let block = CGRect(x: x - w / 2, y: eyeY - full / 2, width: w, height: h)
                ctx.addPath(CGPath(roundedRect: block, cornerWidth: min(w, h) * 0.28, cornerHeight: min(w, h) * 0.28, transform: nil)); ctx.fillPath()
            }
            if worried || focus {
                // Failed frowns; worried lifts the inner ends; thinking keeps them level.
                let slope: CGFloat = mood == .error ? -side * d * 0.025 : (worried ? side * d * 0.03 : 0)
                let lift: CGFloat = focus ? 0.11 : 0.15
                ctx.move(to: CGPoint(x: x - d * 0.055, y: eyeY + d * lift + slope))
                ctx.addLine(to: CGPoint(x: x + d * 0.055, y: eyeY + d * lift - slope)); ctx.strokePath()
            }
        }
        let mouthY = center.y - d * 0.17
        if surprise {
            ctx.fillEllipse(in: CGRect(x: center.x - d * 0.035, y: mouthY - d * 0.04, width: d * 0.07, height: d * 0.085))
        } else {
            let width = d * (happy ? 0.09 : 0.06)
            ctx.move(to: CGPoint(x: center.x - width, y: mouthY))
            ctx.addQuadCurve(to: CGPoint(x: center.x + width, y: mouthY), control: CGPoint(x: center.x, y: mouthY + (worried ? d * 0.06 : focus ? 0 : -d * (happy ? 0.1 : 0.045)))); ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

/// The living open-panel companion. One shared clock, attached only while its panel is visible.
final class LivingCompanionView: NSView, ZeraAnimating {
    weak var source: ZeraView?
    var onTap: (() -> Void)?
    var activityOverride: ZeraActivity?
    var onTintChange: ((NSColor) -> Void)?
    private var phase: TimeInterval = 0, last: TimeInterval?
    private var gaze = CGPoint.zero
    private var blinkAt: TimeInterval = -10, nextBlink = CACurrentMediaTime() + 2
    private var gestureAt: TimeInterval = -10
    private var gesture: CompanionGesture.Kind = .greet
    private var expression: ZeraMood?
    private var expressionUntil: TimeInterval = 0
    private var hover: CGFloat = 0
    /// A short lift of attention when the pointer crosses a tab; eases back down on its own.
    private var interest: CGFloat = 0
    /// Her colour as drawn, eased toward the mood's colour every frame.
    private var shownTint: NSColor?
    private var lastMood: ZeraMood = .idle
    /// Phone transfers: eager toward the phone's edge, a leap to catch the card, then hopping
    /// with hands up while the original pours in.
    private var phoneSide: CGFloat?
    private var cheering = false
    private var leapAt: TimeInterval = -10
    private var reach: CGFloat = 0
    private static let leapDuration: TimeInterval = 1.1
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button); setAccessibilityLabel("Zera companion"); setAccessibilityHelp("Poke Zera for a reaction")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { ZeraAnimationClock.shared.add(self) } else { ZeraAnimationClock.shared.remove(self) } }
    override func viewDidHide() { super.viewDidHide(); ZeraAnimationClock.shared.refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); ZeraAnimationClock.shared.refresh() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); resetHoverTracking() }
    override func mouseEntered(with event: NSEvent) { greet() }
    override func mouseUp(with event: NSEvent) { poke() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { poke() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { poke(); return true }
    func enterFromNotch() {
        greet()
        wantsLayer = true
        guard !Motion.reduced, let layer else { return }
        let fall = CASpringAnimation(keyPath: "transform.translation.y")
        fall.fromValue = -64; fall.toValue = 0
        fall.mass = 1; fall.stiffness = 230; fall.damping = 22
        fall.duration = fall.settlingDuration
        layer.add(fall, forKey: "zera.descend")
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0; appear.toValue = 1; appear.duration = 0.18
        layer.add(appear, forKey: "zera.descend.fade")
    }
    func noticeSelection() {
        // Running the pointer along the tabs: her eyes follow it (gaze), her attention lifts and
        // eases off, and she nods once per pass, not once per tab. No expression or colour change,
        // so nothing snaps from tab to tab.
        interest = 1
        let now = CACurrentMediaTime()
        guard now - gestureAt > CompanionGesture.duration + 0.2 else { return }
        gesture = .acknowledge; gestureAt = now
    }
    func greet() { gesture = .greet; gestureAt = CACurrentMediaTime(); expression = .hello; expressionUntil = gestureAt + 0.8 }
    /// A file is on its way from the phone: eager and bouncing, eyes on the edge it comes from.
    func awaitPhone(from side: CGFloat) {
        phoneSide = side; cheering = false
        expression = nil
    }
    /// The swiped card is released: she crouches, leaps toward the notch with both hands up
    /// as it lands, and comes down cheering.
    func catchFromPhone() {
        phoneSide = nil; cheering = true
        expression = nil
        leapAt = CACurrentMediaTime()
        wantsLayer = true
        guard !Motion.reduced, let layer else { return }
        let jump = CAKeyframeAnimation(keyPath: "transform.translation.y")
        jump.values = [0, 5, -30, -32, 0, 3, 0]
        jump.keyTimes = [0, 0.14, 0.42, 0.55, 0.8, 0.9, 1]
        jump.timingFunctions = [.init(name: .easeOut), .init(name: .easeOut), .init(name: .linear),
                                .init(name: .easeIn), .init(name: .easeOut), .init(name: .easeInEaseOut)]
        jump.duration = Self.leapDuration
        layer.add(jump, forKey: "zera.leap")
    }
    func releasePhone() { phoneSide = nil; cheering = false }
    private var leaping: Bool { phase - leapAt >= 0 && phase - leapAt < Self.leapDuration }
    /// Squash and stretch through the leap: crouch, stretch up, squash on landing.
    private func leapSquash(_ t: TimeInterval) -> CGFloat {
        let keys: [(TimeInterval, CGFloat)] = [(0, 0), (0.15, 0.13), (0.46, -0.12), (0.6, -0.04), (0.88, 0.15), (0.99, -0.03), (1.1, 0)]
        for (a, b) in zip(keys, keys.dropFirst()) where t <= b.0 {
            let f = CGFloat((t - a.0) / (b.0 - a.0))
            return a.1 + (b.1 - a.1) * f
        }
        return 0
    }

    func react(_ reaction: NotchLightReaction) {
        // The leap is its own reaction; a save beat at the same moment must not cut it short.
        guard CACurrentMediaTime() - leapAt >= Self.leapDuration else { return }
        gestureAt = CACurrentMediaTime(); expressionUntil = gestureAt + 1
        switch reaction {
        case .approvalNeeded, .danger: expression = .surprised; gesture = .attention
        case .success: expression = .celebrate; gesture = .greet
        case .copy, .paste, .save: expression = .giving; gesture = .receive
        case .agentArrival: expression = .focused; gesture = .greet
        default: expression = .hello; gesture = .acknowledge
        }
    }
    private func poke() {
        let upset = source?.poke() == true || source?.isReactingToPokes == true
        gestureAt = CACurrentMediaTime(); gesture = upset ? .attention : .greet
        expression = upset ? .error : .happy; expressionUntil = gestureAt + (upset ? 1.8 : 0.9)
        onTap?(); needsDisplay = true
    }
    private var mood: ZeraMood {
        if leaping { return .excited }
        if let expression, phase < expressionUntil { return expression }
        if phoneSide != nil { return .excited }
        if cheering { return .happy }
        let activity = activityOverride ?? source?.activity ?? .none
        if activity == .approval { return .surprised }
        if activity == .running { return .focused }
        if activity == .done { return .celebrate }
        return source?.mood ?? .idle
    }
    func advanceAnimation(at now: TimeInterval) {
        let dt = min(0.1, now - (last ?? now)); last = now; phase = now
        if let window {
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let k = CGFloat(1 - exp(-dt * 9))
            var x = min(1, max(-1, (point.x - bounds.midX) / 140)), y = min(1, max(-1, (point.y - bounds.midY) / 140))
            if let phoneSide { x = phoneSide * 0.9; y = 0.05 }
            if leaping { x = 0; y = 1 }
            gaze.x += (x - gaze.x) * k; gaze.y += (y - gaze.y) * k
            hover += ((bounds.contains(point) ? 1 : 0) - hover) * k
        }
        let reachTarget: CGFloat = leaping ? 1 : cheering ? 0.55 : phoneSide != nil ? 0.3 : 0
        reach += (reachTarget - reach) * CGFloat(1 - exp(-dt * 12))
        interest -= interest * CGFloat(1 - exp(-dt * 2.2))
        // Colour eases over about a quarter second instead of switching with the mood.
        let want = CompanionGlyph.tint(for: mood)
        if let shown = shownTint, dt > 0 {
            shownTint = shown.blended(withFraction: CGFloat(1 - exp(-dt * 10)), of: want) ?? want
        } else {
            shownTint = want
        }
        if now >= nextBlink { blinkAt = now; nextBlink = now + Double.random(in: 2.7...5.2) }
        if mood != lastMood { lastMood = mood; onTintChange?(CompanionGlyph.tint(for: mood)) }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let reduce = Motion.reduced, state = mood
        let pose = CompanionGesture.sample(gesture, elapsed: phase - gestureAt, reduced: reduce)
        let resting = state == .sleepy || state == .cozy
        var bob = reduce ? 0 : CGFloat(sin(phase * (resting ? 0.9 : state == .focused ? 3.8 : 2.2))) * (state == .focused ? 0.6 : 1.3)
        let d = min(bounds.width, bounds.height) * 0.83
        var squash = pose.squash
        if !reduce {
            // Eager bounce while the card approaches; two hops per heartbeat while it pours in.
            if phoneSide != nil { bob = CGFloat(sin(phase * 8)) * 2.2 }
            else if cheering, !leaping { bob = CGFloat(abs(sin(phase * .pi / 0.75))) * d * 0.06 }
            if leaping { squash += leapSquash(phase - leapAt) }
        }
        ctx.saveGState(); ctx.translateBy(x: bounds.midX, y: bounds.midY + bob + pose.lift * d); ctx.rotate(by: pose.tilt)
        let elapsed = phase - gestureAt
        if !reduce, state == .focused || state == .thinking {
            for index in 0..<3 {
                let angle = CGFloat(phase * 1.5) + CGFloat(index) * .pi * 2 / 3
                let radius = d * 0.42
                ctx.setFillColor((shownTint ?? CompanionGlyph.tint(for: state)).withAlphaComponent(0.48).cgColor)
                ctx.fillEllipse(in: CGRect(x: cos(angle) * radius - 1.8, y: sin(angle) * radius * 0.8 - 1.8, width: 3.6, height: 3.6))
            }
        }
        // Rings for real reactions only; a nod while browsing tabs stays quiet.
        if !reduce, elapsed >= 0, elapsed < 1, gesture != .acknowledge {
            let tint = shownTint ?? CompanionGlyph.tint(for: state)
            for i in 0..<3 {
                let progress = CGFloat(elapsed) + CGFloat(i) * 0.16
                let radius = d * (0.3 + progress * 0.32)
                ctx.setStrokeColor(tint.withAlphaComponent(max(0, 0.18 * (1 - progress))).cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: CGRect(x: -radius, y: -radius * 0.65, width: radius * 2, height: radius * 1.3))
            }
        }
        let t = phase - blinkAt, blink: CGFloat = !reduce && t >= 0 && t < 0.18 ? CGFloat(sin(t / 0.18 * .pi)) : 0
        CompanionGlyph.draw(ctx, in: CGRect(x: -d * (1 + squash) / 2, y: -d * (1 - squash) / 2, width: d * (1 + squash), height: d * (1 - squash)), mood: state, gaze: gaze, blink: blink, attention: max(hover, interest * 0.6), phase: reduce ? 0 : phase, reach: reach, tint: shownTint)
        ctx.restoreGState()
    }
}

/// A short body response, sampled on the existing animation clock. Anticipation precedes
/// the release; reduced motion keeps the expression but leaves the body at rest.
enum CompanionGesture {
    enum Kind { case acknowledge, receive, attention, greet }
    struct Pose { var lift: CGFloat = 0; var squash: CGFloat = 0; var tilt: CGFloat = 0 }
    static let duration: TimeInterval = 0.6

    static func sample(_ kind: Kind, elapsed: TimeInterval, reduced: Bool) -> Pose {
        guard !reduced, elapsed >= 0, elapsed < duration else { return Pose() }
        let t = elapsed / duration
        if t < 0.16 {
            let anticipate = CGFloat(sin(t / 0.16 * .pi))
            return Pose(lift: -0.025 * anticipate, squash: 0.06 * anticipate)
        }
        let p = (t - 0.16) / 0.84
        let release = CGFloat(sin(p * .pi) * exp(-p * 1.8))
        switch kind {
        case .acknowledge: return Pose(lift: -0.04 * release, tilt: 0.04 * release)
        case .receive: return Pose(lift: 0.065 * release, squash: -0.04 * release)
        case .attention: return Pose(lift: 0.04 * release, squash: -0.065 * release, tilt: -0.05 * release)
        case .greet: return Pose(lift: 0.11 * release, squash: -0.055 * release, tilt: 0.07 * release)
        }
    }
}
