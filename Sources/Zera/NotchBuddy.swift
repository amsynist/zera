import AppKit

/// Where Zera lives: inside the notch (a small living face in a black ear of the notch, the
/// default) or the classic figure hanging from her rope under it.
enum BuddyStyle: Int {
    case notch = 0, hanging = 1
    static let changed = Notification.Name("ZeraBuddyStyleChanged")
    private static let key = "zera.buddyStyle"
    static var current: BuddyStyle {
        get { BuddyStyle(rawValue: UserDefaults.standard.object(forKey: key) as? Int ?? 0) ?? .notch }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

// MARK: - Zera in the notch
//
// A black ear grown out of the right side of the notch, with Zera's face in it. Her state comes
// from the full `ZeraView` (mood, gaze target, hover, Claude activity, pokes), so everything the
// controller already does to her shows up here too. Drawn with Core Graphics on the shared
// animation clock, only while it's on screen: eyes follow the pointer, she blinks, breathes,
// leans in when you hover, squashes when you tap, and glows with what Claude is doing.
final class NotchBuddyView: NSView, ZeraAnimating {
    /// The full figure whose state she mirrors.
    weak var source: ZeraView?
    var activityOverride: ZeraActivity?
    var onActivate: (() -> Void)?
    var onShowNavigation: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Zera companion")
        setAccessibilityHelp("Open the selected screen. Show menu opens navigation.")
        let navigation = NSMenu()
        let item = navigation.addItem(withTitle: "Show navigation", action: #selector(showNavigation), keyEquivalent: "")
        item.target = self
        menu = navigation
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func showNavigation() { onShowNavigation?() }
    override func accessibilityPerformPress() -> Bool { onActivate?(); return true }
    override func accessibilityPerformShowMenu() -> Bool {
        guard let onShowNavigation else { return false }
        onShowNavigation(); return true
    }

    /// How far the ear overlaps the hardware notch (so the black joins seamlessly).
    static let overlap: CGFloat = 8

    private var look = CGPoint.zero
    private var hoverAmount: CGFloat = 0
    private var squashUntil: TimeInterval = 0
    private var nextBlink: TimeInterval = CACurrentMediaTime() + 2.5
    private var blinkStart: TimeInterval = -10
    private var lastFrame: TimeInterval?
    private var phase: TimeInterval = 0
    private var wasHovered = false
    /// A brief greeting expression accompanies the shared body response.
    private var cheerUntil: TimeInterval = 0
    private var surpriseUntil: TimeInterval = 0
    private var gestureStart: TimeInterval = -10
    private var gesture: CompanionGesture.Kind = .acknowledge

    /// Small answers to what you just did, on top of her mood.
    enum Beat { case nod, sparkle, surprise, hop }

    func beat(_ b: Beat) {
        let now = CACurrentMediaTime()
        gestureStart = now
        switch b {
        case .nod: gesture = .acknowledge
        case .sparkle: gesture = .receive
        case .surprise: gesture = .attention
        case .hop: gesture = .greet
        }
        switch b {
        case .nod: break
        case .sparkle: break
        case .surprise: surpriseUntil = now + 0.7
        case .hop: cheerUntil = now + 0.9
        }
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The ear's width for a notch of this height (kept for older callers).
    static func width(forHeight h: CGFloat) -> CGFloat { (h * 1.25).rounded() + overlap }

    /// Zera 2: the notch grows a wing on each side. Zera's face lives in the left one, a live
    /// status (an agent working, waiting, done; music; dictation) in the right one.
    static func wingWidth(forHeight h: CGFloat) -> CGFloat { (h * 1.3).rounded() }
    static func frame(around notch: NSRect) -> NSRect {
        let w = wingWidth(forHeight: notch.height)
        return NSRect(x: notch.minX - w, y: notch.minY, width: notch.width + 2 * w, height: notch.height)
    }

    /// When the current agent activity began (for the elapsed time in the right wing).
    private var activitySince = CACurrentMediaTime()
    private var lastActivity: ZeraActivity = .none

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ZeraAnimationClock.shared.add(self) } else { ZeraAnimationClock.shared.remove(self) }
    }

    override func viewDidHide() { super.viewDidHide(); ZeraAnimationClock.shared.refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); ZeraAnimationClock.shared.refresh() }

    override func mouseUp(with event: NSEvent) {
        squashUntil = CACurrentMediaTime() + 0.28
        beat(.sparkle)
        onActivate?()
        needsDisplay = true
    }

    // MARK: Motion

    func advanceAnimation(at now: TimeInterval) {
        let dt = min(0.1, now - (lastFrame ?? now))
        lastFrame = now
        phase = now
        let target = source?.lookTarget ?? .zero
        let k = CGFloat(1 - exp(-dt * 10))
        look.x += (target.x - look.x) * k
        look.y += (target.y - look.y) * k
        let hovered = source?.hovered ?? false
        hoverAmount += ((hovered ? 1 : 0) - hoverAmount) * CGFloat(1 - exp(-dt * 12))
        if hovered && !wasHovered { beat(.hop) }
        let act = activityOverride ?? source?.activity ?? .none
        if act != lastActivity { lastActivity = act; activitySince = now }
        wasHovered = hovered
        if now >= nextBlink {
            blinkStart = now
            nextBlink = now + Double.random(in: 2.4...5.5)
        }
        needsDisplay = true
    }

    private var blink: CGFloat {
        let t = phase - blinkStart
        guard t >= 0, t < 0.16 else { return 0 }
        return CGFloat(sin(t / 0.16 * .pi))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let reduce = Motion.reduced

        // One black shape: the notch plus a wing on each side, flush with the top of the screen,
        // flared where it meets the menu bar and rounded at its two outer bottom corners.
        let flare = NotchGeometry.shoulderWidth(height: b.height)
        let left = b.minX + flare
        let shape = NotchGeometry.notchOutline(in: b, closed: true)
        let activity = activityOverride ?? source?.activity ?? .none
        let rawMood = source?.mood ?? .idle
        let mood: ZeraMood = source?.isReactingToPokes == true ? rawMood : activity == .running ? .focused : activity == .approval ? .surprised : activity == .done ? .celebrate : rawMood
        let tint = Self.glowColor(activity) ?? (Dictation.shared.isActive ? Self.violet : nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        if let t = tint {
            // Light inside the black: a soft pool rising from the bottom edge, and a hairline.
            let pulse = reduce ? 0.8 : 0.6 + 0.4 * CGFloat(sin(phase * 2 * .pi / 1.8))
            ctx.saveGState()
            ctx.addPath(shape); ctx.clip()
            let cs = CGColorSpace(name: CGColorSpace.sRGB)
            if let g = CGGradient(colorsSpace: cs, colors: [t.withAlphaComponent(0.42 * pulse).cgColor, t.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.minY + b.height * 0.7), options: [])
            }
            ctx.restoreGState()

        }
        ctx.restoreGState()

        let wing = Self.wingWidth(forHeight: b.height)
        drawStatus(ctx, in: NSRect(x: b.maxX - wing, y: 0, width: wing - flare, height: b.height), activity: activity)

        // The whole glyph stays inside the left wing. Body reactions
        // use reserved room rather than letting the forehead or caption collide with the notch.
        let faceArea = NSRect(x: left + 2, y: 0, width: wing - flare - 2, height: b.height)
        let d = min(faceArea.width, faceArea.height) * 0.88
        let pose = CompanionGesture.sample(gesture, elapsed: phase - gestureStart, reduced: reduce)
        let pressed: CGFloat = phase < squashUntil && !reduce ? 0.08 * CGFloat((squashUntil - phase) / 0.28) : 0
        let squash = pose.squash + pressed
        let height = d * 1.12 * (1 - squash), width = d * (1 + squash)
        let breathe = reduce ? 0 : CGFloat(sin(phase * 2 * .pi / 3.4)) * 0.35
        let cy = min(faceArea.maxY - height / 2 - 1.5,
                     max(faceArea.minY + height / 2 + 1.5, faceArea.midY + breathe + pose.lift * d))
        let center = CGPoint(x: faceArea.midX, y: cy)
        let head = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let shown: ZeraMood = phase < cheerUntil ? .happy : (phase < surpriseUntil ? .surprised : mood)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: pose.tilt)
        CompanionGlyph.draw(ctx, in: head, mood: shown, gaze: look,
                            blink: reduce ? 0 : blink, attention: hoverAmount, phase: reduce ? 0 : phase)
        ctx.restoreGState()
    }

    private static let violet = NSColor(srgbRed: 0.61, green: 0.55, blue: 1, alpha: 1)

    /// The right wing: what's going on, at a glance.
    private func drawStatus(_ ctx: CGContext, in rect: NSRect, activity: ZeraActivity) {
        let c = CGPoint(x: rect.midX, y: rect.midY + 1)
        let reduce = Motion.reduced
        switch activity {
        case .running:
            // A spinning arc and how long it's been going.
            let blue = Self.glowColor(.running)!
            let rr = min(rect.height * 0.16, 5.5)
            let ring = CGPoint(x: rect.minX + rr + 2, y: c.y)
            ctx.setLineWidth(2.2); ctx.setLineCap(.round)
            ctx.setStrokeColor(blue.withAlphaComponent(0.25).cgColor)
            ctx.addArc(center: ring, radius: rr, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()
            let a0 = reduce ? 0 : CGFloat(phase * 5).truncatingRemainder(dividingBy: .pi * 2)
            ctx.setStrokeColor(blue.cgColor)
            ctx.addArc(center: ring, radius: rr, startAngle: -a0, endAngle: -a0 - .pi * 1.2, clockwise: true); ctx.strokePath()
            let secs = Int(CACurrentMediaTime() - activitySince)
            let text = secs >= 3600 ? "\(secs / 3600)h" : (secs >= 60 ? "\(secs / 60)m" : "\(secs)s")
            drawText(text, at: CGPoint(x: ring.x + rr + 3, y: c.y), color: blue, size: max(9, rect.height * 0.27))
        case .approval:
            let amber = Self.glowColor(.approval)!
            let pulse = reduce ? 1 : 0.8 + 0.2 * CGFloat(sin(phase * 2 * .pi / 0.9))
            let d = rect.height * 0.46 * pulse
            ctx.setFillColor(amber.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            ctx.setFillColor(NSColor(srgbRed: 0.22, green: 0.12, blue: 0, alpha: 1).cgColor)
            ctx.fill(CGRect(x: c.x - d * 0.06, y: c.y - d * 0.05, width: d * 0.12, height: d * 0.32))
            ctx.fillEllipse(in: CGRect(x: c.x - d * 0.07, y: c.y - d * 0.25, width: d * 0.14, height: d * 0.14))
        case .done:
            let green = Self.glowColor(.done)!
            ctx.setStrokeColor(green.cgColor); ctx.setLineWidth(2.4); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let s = rect.height * 0.18
            ctx.move(to: CGPoint(x: c.x - s, y: c.y)); ctx.addLine(to: CGPoint(x: c.x - s * 0.3, y: c.y - s * 0.7))
            ctx.addLine(to: CGPoint(x: c.x + s, y: c.y + s * 0.7)); ctx.strokePath()
        case .none:
            if Dictation.shared.isActive {
                drawBars(ctx, rect: rect, levels: Dictation.shared.bars, color: Self.violet)
            } else if let t = NowPlayingService.shared.track, t.isPlaying {
                let k: [Double] = reduce ? [0.5, 0.7, 0.4, 0.6] : (0..<4).map { 0.35 + 0.6 * abs(sin(phase * (3.1 + Double($0) * 1.3) + Double($0))) }
                drawBars(ctx, rect: rect, levels: k, color: NSColor(srgbRed: 1, green: 0.54, blue: 0.36, alpha: 1))
            }
        }
    }

    private func drawBars(_ ctx: CGContext, rect: NSRect, levels: [Double], color: NSColor) {
        let n = levels.count, w: CGFloat = 2.6, gap: CGFloat = 2
        let total = CGFloat(n) * w + CGFloat(n - 1) * gap
        var x = rect.midX - total / 2
        ctx.setFillColor(color.cgColor)
        for l in levels {
            let h = max(3, rect.height * 0.5 * CGFloat(min(1, max(0.1, l))))
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: rect.midY - h / 2, width: w, height: h), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
            x += w + gap
        }
        ctx.fillPath()
    }

    private func drawText(_ s: String, at p: CGPoint, color: NSColor, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium), .foregroundColor: color]
        let str = s as NSString
        let sz = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: p.x, y: p.y - sz.height / 2), withAttributes: attrs)
    }

    private static func glowColor(_ a: ZeraActivity) -> NSColor? {
        switch a {
        case .none: return nil
        case .running: return NSColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 1)
        case .approval: return NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 1)
        case .done: return NSColor(srgbRed: 0.3, green: 0.9, blue: 0.6, alpha: 1)
        }
    }

}
