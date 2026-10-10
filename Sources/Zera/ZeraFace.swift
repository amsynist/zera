import AppKit

/// Facial layers for the hanging idle pose. Anchors are in the original sprite's
/// 153 × 264 coordinates; body and face share the same pendulum/breathing transform.
struct ZeraFace {
    private var nextBlink: TimeInterval?
    private var blinkStart: TimeInterval?
    private(set) var openness: CGFloat = 1

    mutating func advance(at now: TimeInterval, reducedMotion: Bool, interval: TimeInterval = Double.random(in: 3...6)) {
        guard !reducedMotion else {
            openness = 1; blinkStart = nil; nextBlink = nil
            return
        }
        if nextBlink == nil { nextBlink = now + interval }
        if let due = nextBlink, now >= due, blinkStart == nil {
            blinkStart = now; nextBlink = now + interval
        }
        guard let start = blinkStart else { openness = 1; return }
        let elapsed = now - start
        if elapsed >= 0.22 { blinkStart = nil; openness = 1 }
        else {
            // Quick close, brief hold, slower reopen.
            openness = elapsed < 0.07 ? max(0, 1 - CGFloat(elapsed / 0.07))
                : (elapsed < 0.10 ? 0 : min(1, CGFloat((elapsed - 0.10) / 0.12)))
        }
    }

    func draw(in rect: NSRect, gaze: CGPoint, alpha: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 153, y: rect.height / 264)
        // The eyes sit along the tilted face. Looking moves them together, with a
        // small foreshortening on the far eye to suggest a curved cheek.
        for (index, anchor) in [CGPoint(x: 51, y: 97), CGPoint(x: 109, y: 124)].enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: anchor.x + gaze.x * 4, y: anchor.y + gaze.y * 3)
            let farSide: CGFloat = index == 0 ? max(0, gaze.x) : max(0, -gaze.x)
            ctx.scaleBy(x: 1 - farSide * 0.10, y: max(0.045, openness))
            let eye = NSBezierPath(ovalIn: NSRect(x: -11.8, y: -12, width: 23.6, height: 24))
            NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.08, blue: 0.09, alpha: 1), ending: .black)?.draw(in: eye, angle: -90)
            NSColor.white.withAlphaComponent(0.96 * openness * openness).setFill()
            NSBezierPath(ovalIn: NSRect(x: -5.5, y: 3, width: 6, height: 7)).fill()
            NSColor.white.withAlphaComponent(0.25 * openness * openness).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: -6, width: 2.5, height: 2.5)).fill()
            ctx.restoreGState()
        }
        let brow = NSBezierPath()
        brow.move(to: CGPoint(x: 37, y: 122))
        brow.curve(to: CGPoint(x: 44, y: 126), controlPoint1: CGPoint(x: 39, y: 125), controlPoint2: CGPoint(x: 42, y: 127))
        brow.move(to: CGPoint(x: 99, y: 149))
        brow.curve(to: CGPoint(x: 107, y: 150), controlPoint1: CGPoint(x: 102, y: 152), controlPoint2: CGPoint(x: 105, y: 152))
        NSColor(srgbRed: 0.65, green: 0.40, blue: 0.38, alpha: 0.30).setStroke()
        brow.lineWidth = 3; brow.lineCapStyle = .round; brow.stroke()
        let mouth = NSBezierPath()
        mouth.move(to: CGPoint(x: 74, y: 98))
        mouth.curve(to: CGPoint(x: 84, y: 101), controlPoint1: CGPoint(x: 78, y: 89), controlPoint2: CGPoint(x: 83, y: 92))
        mouth.curve(to: CGPoint(x: 74, y: 98), controlPoint1: CGPoint(x: 81, y: 98), controlPoint2: CGPoint(x: 78, y: 96))
        NSColor(srgbRed: 0.12, green: 0.045, blue: 0.055, alpha: 1).setFill(); mouth.fill()
        NSColor(srgbRed: 0.96, green: 0.35, blue: 0.37, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 78, y: 94, width: 4, height: 2.5)).fill()
        ctx.restoreGState()
    }
}
