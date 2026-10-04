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
    /// While Claude Code works or waits on you she switches to one of its poses (at the laptop,
    /// holding a "?" clipboard), whatever her mood. nil = back to her moods.
    var activityPose: String? { didSet { if activityPose != oldValue { needsDisplay = true } } }

    /// Poses cut without a rope: she sits on it, so it runs behind her at this fraction of the width.
    private static let ropeBehind: [String: CGFloat] = ["claude_working": 0.53, "claude_approval": 0.49]

    /// Where she should look, -1…1 on both axes relative to herself. Smoothed in `tick`.
    var lookTarget: CGPoint = .zero
    private(set) var look: CGPoint = .zero

    private var timer: Timer?
    private var phase: Double = 0
    private var happyStartedAt: Double = -10
    private var raise: CGFloat = 0
    private var wave: CGFloat = 0
    private var droop: CGFloat = 0

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
        look.x += (lookTarget.x - look.x) * 0.18
        look.y += (lookTarget.y - look.y) * 0.18
        needsDisplay = true
    }

    /// For static renders (the icon) where `tick` never runs.
    func snapPose() {
        raise = [.excited, .happy, .celebrate, .surprised].contains(mood) ? 1 : 0
        wave = mood == .hello ? 1 : 0
        droop = mood == .sleepy ? 1 : 0
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
        if style == .hanging, let p = activityPose { return p }
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
        if let prev = previousSprite, t < 1 { drawSprite(prev, alpha: 1 - t, lift: lift) }
        drawSprite(sprite, alpha: t, lift: lift)
        ctx.restoreGState()
        if t >= 1 { previousSprite = nil }
    }

    private func drawSprite(_ sprite: Sprite, alpha: CGFloat, lift: CGFloat) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        if style == .hanging, let ropeX = sprite.ropeX ?? Self.ropeBehind[sprite.name] {
            // Pendulum about the point where the rope leaves the top of the view.
            let pivot = NSPoint(x: bounds.midX, y: bounds.maxY)
            let k: CGFloat = Self.reduceMotion ? 0.25 : 1   // "Reduce motion": barely a sway
            var angle = (CGFloat(sin(phase * 0.9)) * 2.2 + CGFloat(sin(phase * 1.7)) * 0.6) * k
            angle += raise * CGFloat(sin(phase * 4.2)) * 5 * k
            angle += wave * CGFloat(sin(phase * 5)) * 1.5 * k
            angle -= look.x * 3.5 * k
            angle += droop * CGFloat(sin(phase * 0.5)) * 1.2 * k
            ctx.translateBy(x: pivot.x, y: pivot.y)
            ctx.rotate(by: angle * .pi / 180)
            ctx.translateBy(x: -pivot.x, y: -pivot.y)

            let h = max(1, bounds.height - hangInset - 2 - lift * 0.4)
            let w = h * sprite.aspect
            let top = bounds.maxY - hangInset + lift * 0.4
            let rect = NSRect(x: pivot.x - ropeX * w, y: top - h, width: w, height: h)

            // Rope from her picture up to the top edge of the window (into the notch, if any);
            // for the poses where she sits on it, down behind her body too.
            let rope = NSBezierPath()
            rope.move(to: NSPoint(x: pivot.x, y: sprite.ropeX == nil ? rect.minY + h * 0.08 : top - 1))
            rope.line(to: NSPoint(x: pivot.x, y: bounds.maxY))
            rope.lineWidth = max(1.5, w * 0.035)
            rope.lineCapStyle = .butt
            sprite.ropeColor.withAlphaComponent(alpha).setStroke()
            rope.stroke()
            sprite.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: false, hints: nil)
        } else {
            let h = max(1, bounds.height - 2)
            let w = min(h * sprite.aspect, bounds.width)
            let hh = w / sprite.aspect
            let foot = NSPoint(x: bounds.midX, y: bounds.minY + 1)
            ctx.translateBy(x: foot.x + look.x * 1.5, y: foot.y + lift)
            ctx.rotate(by: (-look.x * 4 + droop * 4) * .pi / 180)
            ctx.translateBy(x: -foot.x, y: -foot.y)
            sprite.image.draw(in: NSRect(x: foot.x - w / 2, y: foot.y, width: w, height: hh),
                              from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: false, hints: nil)
        }
        ctx.restoreGState()
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
