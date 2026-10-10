import AppKit

/// Interactive replacement for decorative sprites. Every screen uses the
/// same clock, pointer response, breathing, pose cross-fade and tap reaction.
final class AnimatedZeraView: NSView, ZeraAnimating {
    /// Optional acting layered around the feet; identity preserves every other screen.
    struct BodyMotion {
        var x: CGFloat = 0, y: CGFloat = 0, angle: CGFloat = 0
        var sx: CGFloat = 1, sy: CGFloat = 1
    }
    var bodyMotion = BodyMotion()
    var alignRight = false
    var expression: ZeraExpression?
    private var speakingUntil: TimeInterval = -10
    func speak(for seconds: TimeInterval = 2.4) { speakingUntil = CACurrentMediaTime() + seconds }
    var pose = "idle" {
        didSet {
            guard pose != oldValue else { return }
            previousPose = hasDrawnPose ? oldValue : nil
            poseChangedAt = hasDrawnPose ? CACurrentMediaTime() : -10
            needsDisplay = true
        }
    }
    private var previousPose: String?
    private var hasDrawnPose = false
    private var poseChangedAt: TimeInterval = -10
    private var lastFrameAt: TimeInterval?
    private var phase: TimeInterval = 0
    private(set) var gaze = CGPoint.zero
    private var face = ZeraFace()
    private var hover: CGFloat = 0
    private var pointerInside = false
    private var reaction = ZeraPokeReaction()
    private var tapAt: TimeInterval = -10
    private var frameTime: TimeInterval = CACurrentMediaTime()
    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel("Zera — tap to interact")
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); lastFrameAt = nil
        if window == nil { ZeraAnimationClock.shared.remove(self) }
        else { ZeraAnimationClock.shared.add(self) }
    }
    override func viewDidHide() { super.viewDidHide(); ZeraAnimationClock.shared.refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); ZeraAnimationClock.shared.refresh() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false }
    override func mouseDown(with event: NSEvent) { tap() }
    override func accessibilityPerformPress() -> Bool { tap(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    func tap(at now: TimeInterval = CACurrentMediaTime()) {
        tapAt = now; _ = reaction.register(at: now); needsDisplay = true
    }

    func advanceAnimation(at now: TimeInterval) {
        let dt = min(0.1, max(0, now - (lastFrameAt ?? now)))
        lastFrameAt = now; frameTime = now; phase += dt
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let follow = reduced ? 1 : CGFloat(1 - exp(-dt / 0.17))
        if let window {
            let point = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
            let mouse = NSEvent.mouseLocation
            gaze.x += (tanh((mouse.x - point.x) / 260) - gaze.x) * follow
            gaze.y += (tanh((mouse.y - point.y) / 200) - gaze.y) * follow
        }
        hover += ((pointerInside ? 1 : 0) - hover) * follow
        face.advance(at: now, reducedMotion: reduced)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        hasDrawnPose = true
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let motion = reaction.motion(at: frameTime, reduceMotion: reduced)
        let elapsed = frameTime - tapAt
        let bounce = !reduced && elapsed >= 0 && elapsed < 0.5 ? CGFloat(sin(elapsed / 0.5 * .pi)) * min(5, bounds.height * 0.04) : 0
        let breathe = reduced ? 0 : CGFloat(sin(phase * 2.2)) * 0.008
        ctx.saveGState()
        if !reduced {
            ctx.translateBy(x: bounds.midX + bodyMotion.x, y: 3 + bodyMotion.y)
            ctx.rotate(by: bodyMotion.angle * .pi / 180)
            ctx.scaleBy(x: bodyMotion.sx, y: bodyMotion.sy)
            ctx.translateBy(x: -bounds.midX, y: -3)
        }
        ctx.translateBy(x: bounds.midX, y: bounds.midY + bounce + motion.dy)
        ctx.rotate(by: reduced ? 0 : (-gaze.x * 2 + motion.angle) * .pi / 180)
        ctx.scaleBy(x: motion.sx * (1 + breathe + hover * 0.018), y: motion.sy * (1 - breathe + hover * 0.018))
        ctx.translateBy(x: -bounds.midX, y: -bounds.midY)
        let progress = reduced ? 1 : min(1, max(0, (frameTime - poseChangedAt) / 0.22))
        if let previousPose, progress < 1 { drawPose(previousPose, alpha: 1 - progress) }
        drawPose(pose, alpha: progress)
        if progress >= 1 { previousPose = nil }
        ctx.restoreGState()
    }

    private func drawPose(_ name: String, alpha: CGFloat) {
        guard let sprite = ZeraFacePose.artwork(for: name) ?? SpriteLibrary.shared.sprite("idle") else { return }
        let space = bounds.insetBy(dx: 3, dy: 3)
        let height = min(space.height, space.width / sprite.aspect)
        let width = height * sprite.aspect
        let rect = NSRect(x: alignRight ? space.maxX - width : space.midX - width / 2, y: space.minY, width: width, height: height)
        sprite.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: false, hints: nil)
        if let rig = ZeraFacePose.available(for: name) {
            face.draw(in: rect, gaze: gaze, alpha: alpha, pose: rig, expression: expression, annoyance: reaction.intensity(at: frameTime), hover: hover, speaking: frameTime < speakingUntil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, time: frameTime)
            ZeraFace.drawForeground(sprite, pose: rig, in: rect, alpha: alpha)
        }
    }
}
