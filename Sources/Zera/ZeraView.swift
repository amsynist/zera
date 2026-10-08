import AppKit

/// What Zera is feeling right now. Drives which cut-out is shown and how she moves.
enum ZeraMood {
    case idle, hello, excited, happy, giving, thinking, sleepy, bored
    case surprised, celebrate, love, focused, worried, sad, approved, error, cozy
}

/// Which crop of her is drawn.
enum ZeraPose { case peek, fullBody }

/// Dangling from a rope out of the notch, or standing on a surface.
enum ZeraStyle { case hanging, standing }

/// What Claude Code is doing while the live wings are out. She hugs her rope and acts it out:
/// breathing and swinging while it works, perking up when a command needs you, hopping when done.
enum ZeraActivity { case none, running, approval, done }

/// Four actual clicks close together trigger a short reaction; hovering does not count.
struct ZeraPokeReaction {
    static let duration: TimeInterval = 2.6
    private var lastPokeAt: TimeInterval?
    private var count = 0
    private(set) var startedAt: TimeInterval?

    mutating func register(at now: TimeInterval) -> Bool {
        guard !isActive(at: now) else { return false }
        count = lastPokeAt.map { now >= $0 && now - $0 <= 1.1 } == true ? count + 1 : 1
        lastPokeAt = now
        guard count == 4 else { return false }
        count = 0
        startedAt = now
        return true
    }

    func isActive(at now: TimeInterval) -> Bool {
        guard let start = startedAt else { return false }
        return now >= start && now - start < Self.duration
    }

    func intensity(at now: TimeInterval) -> CGFloat {
        guard let start = startedAt, isActive(at: now) else { return 0 }
        let t = now - start
        let edge = CGFloat(min(1, t / 0.15, (Self.duration - t) / 0.45))
        return edge * edge * (3 - 2 * edge)
    }

    func motion(at now: TimeInterval, reduceMotion: Bool) -> (angle: CGFloat, dy: CGFloat, sx: CGFloat, sy: CGFloat) {
        guard let start = startedAt, isActive(at: now), !reduceMotion else { return (0, 0, 1, 1) }
        let t = now - start
        let strength = intensity(at: now)
        let shake = CGFloat(sin(t * 2 * .pi / 0.22) * exp(-t * 1.5)) * strength
        let huff = CGFloat(max(0, sin(t * 2 * .pi / 0.5)) * max(0, 1 - t / 1.5)) * strength
        return (shake * 6, -huff * 2.5, 1 + huff * 0.045, 1 - huff * 0.05)
    }
}

/// Zera, rendered from the PNG cut-outs in `Resources/Sprites`: a pendulum sway on the rope,
/// a lean toward whatever she is looking at, cross-fades between expressions and idle fidgets.
/// If the sprites are missing she draws a tiny placeholder so the app still runs.
final class ZeraView: NSView {

    var mood: ZeraMood = .idle {
        didSet {
            guard mood != oldValue else { return }
            if mood == .happy || mood == .celebrate { happyStartedAt = CACurrentMediaTime() }
            needsDisplay = true
        }
    }
    var pose: ZeraPose = .peek { didSet { needsDisplay = true } }
    var style: ZeraStyle = .hanging { didSet { needsDisplay = true } }
    var framesPerSecond: Double = 30
    /// Points at the top of the view hidden behind the notch. The rope runs through them.
    var hangInset: CGFloat = 0
    /// Empty room under her feet, so bounces and sparkles never reach the window's edge.
    var bottomPad: CGFloat = 0
    /// While Claude Code works, waits on you or has just finished, she hugs her rope whatever
    /// her mood, with the motion and effects for that state. `.none` = back to her moods.
    var activity: ZeraActivity = .none {
        didSet {
            guard activity != oldValue else { return }
            activityChangedAt = CACurrentMediaTime()
            needsDisplay = true
        }
    }
    /// The pointer is on her; while Claude is active she wiggles.
    var hovered = false
    /// v2: things that need you orbit her as small glowing motes — amber for Claude, violet for
    /// a review, blue for a meeting soon, red for a low battery. Hidden while you look at her.
    var motes: [NSColor] = [] { didSet { needsDisplay = true } }
    private var moteAlpha: CGFloat = 0

    /// A tap: a little jump with a burst of sparkles, and a swing on the rope that settles.
    /// Each tap kicks her the other way, so a few taps rock her back and forth.
    func bump() {
        bumpAt = CACurrentMediaTime()
        swingSide = -swingSide
    }

    /// A new caption: a small hop, no sparkles.
    func nudge() {
        guard !isReactingToPokes else { return }
        nudgeAt = CACurrentMediaTime()
    }

    private var pokeReaction = ZeraPokeReaction()
    var isReactingToPokes: Bool { pokeReaction.isActive(at: CACurrentMediaTime()) }

    /// Returns true on the fourth quick tap. Further taps let the reaction finish.
    func poke() -> Bool {
        let triggered = pokeReaction.register(at: CACurrentMediaTime())
        if triggered { bumpAt = -10 }
        else if !isReactingToPokes { bump() }
        needsDisplay = true
        return triggered
    }

    /// The pose for every Claude state: holding on to the rope with both hands.
    static let claudePose = "hang_climb"

    /// While a screen is open in the notch island she takes that screen's pose (waving on Home,
    /// peeking at Files…). It wins over her moods and the Claude poses. nil = island closed.
    var islandPose: String? {
        didSet {
            guard islandPose != oldValue else { return }
            activityChangedAt = CACurrentMediaTime()   // a little pop as she changes pose
            needsDisplay = true
        }
    }

    /// In the Claude pose her body hangs beside the rope, not under it: how far its centre sits
    /// from the rope (negative = left), so the wings can reach into her rather than the rope.
    var claudeBodyOffset: CGFloat {
        guard style == .hanging, let s = SpriteLibrary.shared.sprite(Self.claudePose), let rope = s.ropeX else { return 0 }
        let w = max(1, bounds.height - hangInset - bottomPad - 2) * s.aspect
        return (0.44 - rope) * w
    }

    /// Where she should look, -1…1 on both axes relative to herself. Smoothed in `tick`.
    var lookTarget: CGPoint = .zero
    private(set) var look: CGPoint = .zero

    private var timer: Timer?
    private var phase: Double = 0
    private var happyStartedAt: Double = -10
    private var raise: CGFloat = 0
    private var wave: CGFloat = 0
    private var droop: CGFloat = 0
    private var activityChangedAt: Double = -10
    private var bumpAt: Double = -10
    private var nudgeAt: Double = -10
    private var swingSide: CGFloat = 1
    // Eased 0…1 amounts so effects fade in and out instead of popping.
    private var wiggleAmt: CGFloat = 0
    private var askAmt: CGFloat = 0
    private var arcsAmt: CGFloat = 0
    private var burstAmt: CGFloat = 0
    private var starsAmt: CGFloat = 0

    private var currentSprite: Sprite?
    private var previousSprite: Sprite?
    private var fadeStart: Double = -10
    private var fidgetName: String?
    private var fidgetUntil: Double = 0
    private var nextFidgetAt: Double = CACurrentMediaTime() + 20

    /// System "Reduce motion" (Accessibility → Display). Read here rather than via `Motion`
    /// so this file stays buildable on its own for the icon tool.
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var isFlipped: Bool { false }
    /// She is decoration: clicks go to whatever holds her.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stop() : start()
    }

    deinit { timer?.invalidate() }

    private func start() {
        stop()
        let t = Timer(timeInterval: 1.0 / framesPerSecond, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let w = window, w.isVisible, w.alphaValue > 0.02 else { return }
        phase += 1.0 / framesPerSecond
        func blend(_ v: inout CGFloat, _ target: CGFloat, _ k: CGFloat) { v += (target - v) * k }
        blend(&raise, [.excited, .happy, .celebrate, .surprised].contains(mood) ? 1 : 0, 0.22)
        blend(&wave, mood == .hello ? 1 : 0, 0.20)
        blend(&droop, mood == .sleepy ? 1 : 0, 0.06)
        let angry = isReactingToPokes
        blend(&wiggleAmt, !angry && hovered && activity != .none ? 1 : 0, 0.2)
        blend(&askAmt, !angry && activity == .approval ? 1 : 0, 0.1)
        blend(&arcsAmt, !angry && activity == .running ? 1 : 0, 0.12)
        blend(&burstAmt, !angry && activity == .approval ? 1 : 0, 0.15)
        let sparkling = !angry && (activity == .done || CACurrentMediaTime() - bumpAt < 1.4)
        blend(&starsAmt, sparkling ? 1 : 0, 0.15)
        blend(&moteAlpha, motes.isEmpty || hovered || islandPose != nil ? 0 : 1, 0.12)
        look.x += (lookTarget.x - look.x) * 0.18
        look.y += (lookTarget.y - look.y) * 0.18
        needsDisplay = true
    }

    // MARK: - Which picture

    func spriteName(for mood: ZeraMood) -> String {
        switch style {
        case .hanging:
            switch mood {
            case .idle, .giving, .love, .cozy: return "hang_smile"
            case .hello, .happy, .celebrate, .approved: return "hang_wave"
            case .excited, .surprised, .error: return "hang_swing"
            case .thinking, .worried: return "hang_think"
            case .sleepy, .sad: return "hang_sleep"
            case .bored: return "hang_upsidedown"
            case .focused: return "hang_back"
            }
        case .standing:
            switch mood {
            case .idle: return "idle"
            case .hello: return "hello"
            case .excited: return "excited"
            case .happy: return "cheerful"
            case .giving: return "holding_doc"
            case .thinking: return "thinking"
            case .sleepy: return "sleepy"
            case .bored: return "pondering"
            case .surprised: return "surprised"
            case .celebrate: return "celebrate"
            case .love: return "love"
            case .focused: return "laptop"
            case .worried: return "worried"
            case .sad: return "sad"
            case .approved: return "approved"
            case .error: return "error"
            case .cozy: return "cozy"
            }
        }
    }

    private static let hangingFidgets = ["hang_upsidedown", "hang_upsidedown2", "hang_back", "hang_swing", "hang_think", "hang_climb"]

    private func resolvedSpriteName(now: Double) -> String {
        if pokeReaction.isActive(at: now) { return style == .hanging ? Self.claudePose : "error" }
        if style == .hanging, let p = islandPose { return p }
        if style == .hanging, activity != .none { return Self.claudePose }
        if style == .hanging, mood == .idle, !Self.reduceMotion {
            if now < fidgetUntil, let f = fidgetName { return f }
            if now > nextFidgetAt {
                fidgetName = Self.hangingFidgets.randomElement()
                fidgetUntil = now + Double.random(in: 3.0...4.5)
                nextFidgetAt = fidgetUntil + Double.random(in: 25...55)
                return fidgetName!
            }
        }
        return spriteName(for: mood)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let now = CACurrentMediaTime()
        var lift = CGFloat(sin(phase * (1.7 - Double(droop) * 0.8))) * (0.7 - droop * 0.3)
        let sinceHappy = now - happyStartedAt
        if sinceHappy < 0.7, mood == .happy || mood == .celebrate {
            let t = CGFloat(sinceHappy / 0.7)
            lift += sin(t * .pi) * 6 * (1 - t * 0.35)
        }

        guard SpriteLibrary.shared.isAvailable else { drawPlaceholder(lift: lift); return }

        let name = resolvedSpriteName(now: now)
        if currentSprite?.name != name, let next = SpriteLibrary.shared.sprite(name) {
            previousSprite = currentSprite
            currentSprite = next
            fadeStart = now
        }
        guard let sprite = currentSprite else { drawPlaceholder(lift: lift); return }
        let t = Self.reduceMotion ? 1 : CGFloat(min(1, (now - fadeStart) / 0.22))
        ctx.saveGState()
        ctx.interpolationQuality = .high
        if let prev = previousSprite, t < 1 { drawSprite(prev, alpha: 1 - t, lift: lift, effects: false) }
        drawSprite(sprite, alpha: t, lift: lift, effects: true)
        ctx.restoreGState()
        if t >= 1 { previousSprite = nil }
        drawMotes()
    }

    private func drawMotes() {
        guard moteAlpha > 0.02, !motes.isEmpty, style == .hanging else { return }
        let n = motes.count
        let cy = bottomPad + (bounds.height - hangInset - bottomPad) * 0.45
        let rx = min(bounds.width / 2 - 10, 62), ry: CGFloat = 16
        let speed = Self.reduceMotion ? 0.0 : 0.55
        for (i, c) in motes.enumerated() {
            let a = phase * speed + Double(i) / Double(n) * 2 * .pi
            let p = NSPoint(x: bounds.midX + CGFloat(cos(a)) * rx, y: cy + CGFloat(sin(a)) * ry)
            // Behind her (the far side of the orbit) they dim a little.
            let near = 0.55 + 0.45 * (CGFloat(sin(a)) * -0.5 + 0.5)
            let d: CGFloat = 8
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = c.withAlphaComponent(0.8 * moteAlpha)
            glow.shadowBlurRadius = 8
            glow.set()
            c.withAlphaComponent(moteAlpha * near).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawSprite(_ sprite: Sprite, alpha: CGFloat, lift: CGFloat, effects: Bool) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        if style == .hanging, let ropeX = sprite.ropeX {
            // Pendulum about the point where the rope leaves the top of the view.
            let pivot = NSPoint(x: bounds.midX, y: bounds.maxY)
            let k: CGFloat = Self.reduceMotion ? 0.25 : 1   // "Reduce motion": barely a sway
            var angle = (CGFloat(sin(phase * 0.9)) * 2.2 + CGFloat(sin(phase * 1.7)) * 0.6) * k
            angle += raise * CGFloat(sin(phase * 4.2)) * 5 * k
            angle += wave * CGFloat(sin(phase * 5)) * 1.5 * k
            angle -= look.x * 3.5 * k
            angle += droop * CGFloat(sin(phase * 0.5)) * 1.2 * k
            // Claude states: a quicker swing and a perky side-to-side while a command waits on
            // you; a wiggle when you point at her.
            angle += askAmt * (CGFloat(sin(phase * 2.4)) * 1.2 + CGFloat(sin(phase * 2 * .pi / 1.1)) * 2.5) * k
            angle += wiggleAmt * CGFloat(sin(phase * 2 * .pi / 0.9)) * 4 * k
            angle += pokeReaction.motion(at: CACurrentMediaTime(), reduceMotion: Self.reduceMotion).angle
            // A tap swings her on the rope: a quick push that dies away.
            let sinceTap = CACurrentMediaTime() - bumpAt
            if sinceTap < 1.8, !Self.reduceMotion {
                angle += swingSide * 7 * CGFloat(sin(sinceTap * 2 * .pi / 0.85) * exp(-sinceTap * 2.4))
            }
            ctx.translateBy(x: pivot.x, y: pivot.y)
            ctx.rotate(by: angle * .pi / 180)
            ctx.translateBy(x: -pivot.x, y: -pivot.y)

            let h = max(1, bounds.height - hangInset - bottomPad - 2 - lift * 0.4)
            let w = h * sprite.aspect
            let top = bounds.maxY - hangInset + lift * 0.4
            let rect = NSRect(x: pivot.x - ropeX * w, y: top - h, width: w, height: h)

            // Rope from her picture up to the top edge of the window (into the notch, if any).
            let rope = NSBezierPath()
            rope.move(to: NSPoint(x: pivot.x, y: top - 1))
            rope.line(to: NSPoint(x: pivot.x, y: bounds.maxY))
            rope.lineWidth = max(1.5, w * 0.035)
            rope.lineCapStyle = .butt
            sprite.ropeColor.withAlphaComponent(alpha).setStroke()
            rope.stroke()

            // Her body moves on the rope: breathing, hops, the pop on a new state, a tap's bump.
            // Scaled about the point where she holds the rope, so her hands stay on it.
            let m = bodyMotion()
            ctx.saveGState()
            ctx.translateBy(x: pivot.x, y: top + m.dy)
            ctx.scaleBy(x: m.sx, y: m.sy)
            ctx.translateBy(x: -pivot.x, y: -top)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 7, color: NSColor.black.withAlphaComponent(0.45 * alpha).cgColor)
            sprite.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: false, hints: nil)
            ctx.restoreGState()
            if effects {
                if isReactingToPokes { drawAngryReaction(around: rect, alpha: alpha) }
                else { drawEffects(around: rect) }
            }
            ctx.restoreGState()
        } else {
            let h = max(1, bounds.height - 2)
            let w = min(h * sprite.aspect, bounds.width)
            let hh = w / sprite.aspect
            let foot = NSPoint(x: bounds.midX, y: bounds.minY + 1)
            let anger = pokeReaction.motion(at: CACurrentMediaTime(), reduceMotion: Self.reduceMotion)
            ctx.translateBy(x: foot.x + look.x * 1.5, y: foot.y + lift + anger.dy)
            ctx.rotate(by: (-look.x * 4 + droop * 4 + anger.angle) * .pi / 180)
            ctx.scaleBy(x: anger.sx, y: anger.sy)
            ctx.translateBy(x: -foot.x, y: -foot.y)
            sprite.image.draw(in: NSRect(x: foot.x - w / 2, y: foot.y, width: w, height: hh),
                              from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: false, hints: nil)
        }
        ctx.restoreGState()
    }

    // MARK: - Claude-state motion and effects

    /// Vertical offset (up is +) and squash for her body this frame.
    private func bodyMotion() -> (dy: CGFloat, sx: CGFloat, sy: CGFloat) {
        if isReactingToPokes {
            let anger = pokeReaction.motion(at: CACurrentMediaTime(), reduceMotion: Self.reduceMotion)
            return (anger.dy, anger.sx, anger.sy)
        }
        guard !Self.reduceMotion else { return (0, 1, 1) }
        let now = CACurrentMediaTime()
        var dy: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1
        if activity != .none {
            // Breathing: a slow, slight sink and squash.
            let b = CGFloat((1 - cos(phase * 2 * .pi / 2.6)) / 2)
            dy -= 1.6 * b; sx += 0.015 * b; sy -= 0.015 * b
        }
        // Perking up: two small lifts per side-to-side.
        dy += askAmt * 2 * CGFloat(abs(cos(phase * 2 * .pi / 1.1)))
        if activity == .done {
            let t = CGFloat(fmod(now - activityChangedAt, 2.2) / 2.2)
            let h = Self.keyframes(t, [(0, 0, 1, 1), (0.62, 0, 1, 1), (0.72, 6, 0.98, 1.03), (0.82, 0, 1.03, 0.97),
                                       (0.9, 2, 1, 1), (1, 0, 1, 1)])
            dy += h.0; sx *= h.1; sy *= h.2
        }
        let sincePop = CGFloat(now - activityChangedAt)
        if sincePop < 0.55 {
            let p = Self.keyframes(sincePop / 0.55, [(0, 0, 0.9, 0.94), (0.55, 0, 1.05, 1.03), (1, 0, 1, 1)])
            sx *= p.1; sy *= p.2
        }
        let sinceBump = CGFloat(now - bumpAt)
        if sinceBump < 0.7 {
            let p = Self.keyframes(sinceBump / 0.7, [(0, 0, 1, 1), (0.25, 12, 0.96, 1.05), (0.55, -2, 1.05, 0.95), (1, 0, 1, 1)])
            dy += p.0; sx *= p.1; sy *= p.2
        }
        let sinceNudge = CGFloat(now - nudgeAt)
        if sinceNudge < 0.45 {
            let p = Self.keyframes(sinceNudge / 0.45, [(0, 0, 1, 1), (0.35, 4, 0.98, 1.03), (0.7, -1, 1.02, 0.98), (1, 0, 1, 1)])
            dy += p.0; sx *= p.1; sy *= p.2
        }
        return (dy, sx, sy)
    }

    /// Smoothly interpolates (time, dy, sx, sy) keyframes at `t` (0…1).
    private static func keyframes(_ t: CGFloat, _ k: [(CGFloat, CGFloat, CGFloat, CGFloat)]) -> (CGFloat, CGFloat, CGFloat) {
        guard let last = k.last else { return (0, 1, 1) }
        for i in 1..<k.count where t <= k[i].0 {
            let a = k[i - 1], b = k[i]
            var u = (t - a.0) / max(0.0001, b.0 - a.0)
            u = u * u * (3 - 2 * u)
            return (a.1 + (b.1 - a.1) * u, a.2 + (b.2 - a.2) * u, a.3 + (b.3 - a.3) * u)
        }
        return (last.1, last.2, last.3)
    }

    // Her own colours, the same in every theme: this file is also compiled on its own to
    // render the app icon (build.sh), so it can't reach the theme.
    private static let violet = NSColor(srgbRed: 0.58, green: 0.40, blue: 1.0, alpha: 1)
    private static let cyan = NSColor(srgbRed: 0.30, green: 0.74, blue: 1.0, alpha: 1)
    private static let green = NSColor(srgbRed: 0.21, green: 0.89, blue: 0.67, alpha: 1)

    /// Eyebrows follow the tilted face of hang_climb; small steam clouds stay in her window.
    private func drawAngryReaction(around rect: NSRect, alpha: CGFloat) {
        let now = CACurrentMediaTime()
        let strength = (Self.reduceMotion ? 1 : pokeReaction.intensity(at: now)) * alpha
        let w = rect.width, h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + w * x, y: rect.minY + h * y)
        }
        NSColor(srgbRed: 0.20, green: 0.10, blue: 0.13, alpha: strength).setStroke()
        for (a, b) in [(point(0.31, 0.285), point(0.455, 0.235)),
                       (point(0.61, 0.385), point(0.73, 0.47))] {
            let brow = NSBezierPath()
            brow.move(to: a); brow.line(to: b)
            brow.lineWidth = max(1.3, w * 0.027)
            brow.lineCapStyle = .round
            brow.stroke()
        }

        // A tiny anime anger mark beside her tuft, easing with the reaction.
        let mark = point(0.08, 0.61)
        let size = max(3, w * 0.065)
        NSColor(srgbRed: 1, green: 0.40, blue: 0.48, alpha: strength * 0.9).setStroke()
        for (dx, dy) in [(-1.0, -1.0), (-1.0, 1.0), (1.0, -1.0), (1.0, 1.0)] {
            let p = NSBezierPath()
            let x = CGFloat(dx), y = CGFloat(dy)
            p.move(to: NSPoint(x: mark.x + x * size, y: mark.y + y * size * 0.3))
            p.curve(to: NSPoint(x: mark.x + x * size * 0.3, y: mark.y + y * size),
                    controlPoint1: NSPoint(x: mark.x + x * size * 0.4, y: mark.y + y * size * 0.3),
                    controlPoint2: NSPoint(x: mark.x + x * size * 0.3, y: mark.y + y * size * 0.4))
            p.lineWidth = max(1, w * 0.025)
            p.lineCapStyle = .round
            p.stroke()
        }

        guard let start = pokeReaction.startedAt else { return }
        for (x, y, delay) in [(-0.08, 0.34, 0.0), (1.02, 0.46, 0.25)] {
            let u = Self.reduceMotion ? 0.5 : (now - start + delay).truncatingRemainder(dividingBy: 0.8) / 0.8
            let fade = Self.reduceMotion ? 0.65 : sin(u * .pi)
            let center = point(CGFloat(x), CGFloat(y) + CGFloat(u) * 0.10)
            let r = max(1.5, w * 0.035) * (0.7 + CGFloat(u))
            NSColor(srgbRed: 1, green: 0.82, blue: 0.85, alpha: strength * fade * 0.75).setFill()
            for (dx, dy) in [(-0.6, 0.0), (0.0, 0.4), (0.6, 0.0)] {
                NSBezierPath(ovalIn: NSRect(x: center.x + CGFloat(dx) * r - r, y: center.y + CGFloat(dy) * r - r,
                                           width: r * 2, height: r * 2)).fill()
            }
        }
    }

    /// Motion arcs by her feet while Claude works, burst lines by her head while a command waits
    /// on you, and twinkling sparkles when it is done (or when you tap her).
    private func drawEffects(around rect: NSRect) {
        let w = rect.width, h = rect.height
        let still = Self.reduceMotion
        let line = max(1.4, w * 0.032)

        if arcsAmt > 0.01 {
            // Two brackets on each side, pulsing in turn.
            let box = NSRect(x: rect.minX - w * 0.14, y: rect.minY + h * 0.04, width: w * 1.28, height: h * 0.3)
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x / 128 * box.width, y: box.maxY - y / 34 * box.height) }
            let arcs: [(NSPoint, NSPoint, NSPoint, Int)] = [
                (pt(12, 5), pt(5, 17), pt(13, 29), 0), (pt(21, 9), pt(16, 17), pt(22, 25), 1),
                (pt(116, 5), pt(123, 17), pt(115, 29), 0), (pt(107, 9), pt(112, 17), pt(106, 25), 1)]
            for (a, c, b, pair) in arcs {
                let pulse = still ? 0.6 : 0.2 + 0.75 * CGFloat((1 - cos(phase * 2 * .pi / 1.4 + Double(pair) * .pi)) / 2)
                let p = NSBezierPath()
                p.move(to: a)
                p.curve(to: b, controlPoint1: NSPoint(x: a.x + (c.x - a.x) * 2 / 3, y: a.y + (c.y - a.y) * 2 / 3),
                        controlPoint2: NSPoint(x: b.x + (c.x - b.x) * 2 / 3, y: b.y + (c.y - b.y) * 2 / 3))
                p.lineWidth = line * 0.8
                p.lineCapStyle = .round
                Self.violet.withAlphaComponent(pulse * arcsAmt).setStroke()
                p.stroke()
            }
        }

        if burstAmt > 0.01 {
            // Three cyan dashes off the top right of her head, pulsing out.
            let box = NSRect(x: rect.maxX - w * 0.2, y: rect.maxY - h * 0.34, width: w * 0.42, height: h * 0.34)
            let s: CGFloat = still ? 1 : 0.88 + 0.18 * CGFloat((1 - cos(phase * 2 * .pi)) / 2)
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: box.minX + x / 40 * box.width * s, y: box.minY + (40 - y) / 40 * box.height * s)
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = Self.cyan.withAlphaComponent(0.8 * burstAmt); shadow.shadowBlurRadius = 3; shadow.set()
            for (a, b) in [(pt(6, 22), pt(3, 9)), (pt(15, 25), pt(22, 10)), (pt(22, 33), pt(36, 26))] {
                let p = NSBezierPath(); p.move(to: a); p.line(to: b)
                p.lineWidth = line; p.lineCapStyle = .round
                Self.cyan.withAlphaComponent(burstAmt * (0.55 + 0.45 * (s - 0.88) / 0.18)).setStroke()
                p.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        if starsAmt > 0.01 {
            let box = rect.insetBy(dx: -w * 0.24, dy: -h * 0.1)
            let stars: [(CGFloat, CGFloat, Double, NSColor)] = [(0.06, 0.12, 0, Self.green), (0.86, 0.04, 0.5, Self.cyan),
                (0.96, 0.46, 0.9, Self.green), (0.02, 0.58, 1.2, Self.cyan), (0.5, -0.06, 0.3, Self.violet)]
            let size = max(4, w * 0.1)
            for (fx, fy, delay, color) in stars {
                let u = still ? 0.5 : fmod(max(0, phase - delay), 1.6) / 1.6
                let v = CGFloat(sin(u * .pi))
                guard v > 0.02 else { continue }
                let c = NSPoint(x: box.minX + fx * box.width + size / 2, y: box.maxY - fy * box.height - size / 2)
                color.withAlphaComponent(v * starsAmt).setFill()
                Self.star(at: c, radius: size / 2 * (0.3 + 0.7 * v), turn: v * .pi / 4).fill()
            }
        }
    }

    /// A four-pointed sparkle.
    private static func star(at c: NSPoint, radius r: CGFloat, turn: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        for i in 0..<8 {
            let a = turn + CGFloat(i) * .pi / 4
            let d = i % 2 == 0 ? r : r * 0.32
            let pt = NSPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
            i == 0 ? p.move(to: pt) : p.line(to: pt)
        }
        p.close()
        return p
    }

    /// A white puff with a violet tuft — only ever seen if the sprite folder is missing.
    private func drawPlaceholder(lift: CGFloat) {
        let s = min(bounds.width, bounds.height - hangInset)
        let c = NSPoint(x: bounds.midX, y: bounds.minY + s * 0.45 + lift)
        let r = s * 0.36
        NSColor(srgbRed: 0.97, green: 0.95, blue: 0.97, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        NSColor(srgbRed: 0.561, green: 0.482, blue: 1.0, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r * 0.25, y: c.y + r * 0.7, width: r * 0.5, height: r * 0.7)).fill()
        NSColor.black.setFill()
        for dx in [-0.35, 0.35] as [CGFloat] {
            NSBezierPath(ovalIn: NSRect(x: c.x + dx * r - r * 0.12, y: c.y - r * 0.05, width: r * 0.24, height: r * 0.26)).fill()
        }
    }

    // MARK: - Static renders

    /// Her idle pose squared up for the menu bar / footer.
    static func headImage(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        if let s = SpriteLibrary.shared.sprite("idle") {
            NSGraphicsContext.current?.cgContext.interpolationQuality = .high
            let h = size, w = min(size, h * s.aspect), hh = w / s.aspect
            s.image.draw(in: NSRect(x: (size - w) / 2, y: (size - hh) / 2, width: w, height: hh),
                         from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let v = ZeraView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            v.style = .standing
            v.drawPlaceholder(lift: 0)
        }
        img.unlockFocus()
        return img
    }
}
