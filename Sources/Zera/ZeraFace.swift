import AppKit

enum ZeraExpression { case neutral, happy, thoughtful, surprised, sleepy, pleading, unimpressed }

/// Anchors in each original sprite's pixel coordinates, measured from the top.
/// Original artwork remains the fallback if a blank-face base is unavailable.
struct ZeraFacePose {
    let size: CGSize
    let left: CGPoint
    let right: CGPoint
    let mouth: CGPoint
    let radius: CGFloat
    let expression: ZeraExpression
    let ropeEnd: CGPoint?
    let ropeStart: CGPoint?

    static let poses: [String: ZeraFacePose] = [
        "hang_smile": .init(size: .init(width: 153, height: 264), left: .init(x: 51, y: 167), right: .init(x: 109, y: 140), mouth: .init(x: 79, y: 166), radius: 11.8, expression: .neutral, ropeEnd: .init(x: 89, y: 264), ropeStart: .init(x: 89, y: 0)),
        "hang_wave": .init(size: .init(width: 164, height: 264), left: .init(x: 54, y: 173), right: .init(x: 105, y: 146), mouth: .init(x: 85, y: 167), radius: 10, expression: .happy, ropeEnd: .init(x: 84, y: 148), ropeStart: .init(x: 84, y: 0)),
        "hang_climb": .init(size: .init(width: 151, height: 191), left: .init(x: 59, y: 153), right: .init(x: 106, y: 127), mouth: .init(x: 87, y: 150), radius: 10, expression: .neutral, ropeEnd: .init(x: 117, y: 173), ropeStart: .init(x: 126, y: 0)),
        "hang_peek": .init(size: .init(width: 177, height: 207), left: .init(x: 54, y: 157), right: .init(x: 116, y: 148), mouth: .init(x: 88, y: 169), radius: 12, expression: .surprised, ropeEnd: .init(x: 89, y: 96), ropeStart: .init(x: 89, y: 0)),
        "hang_think": .init(size: .init(width: 171, height: 268), left: .init(x: 53, y: 170), right: .init(x: 103, y: 144), mouth: .init(x: 83, y: 166), radius: 11.5, expression: .thoughtful, ropeEnd: .init(x: 78, y: 112), ropeStart: .init(x: 78, y: 0)),
        "hang_swing": .init(size: .init(width: 175, height: 254), left: .init(x: 58, y: 174), right: .init(x: 103, y: 144), mouth: .init(x: 88, y: 170), radius: 10.5, expression: .happy, ropeEnd: .init(x: 144, y: 235), ropeStart: .init(x: 79, y: 0)),
        "hang_upsidedown": .init(size: .init(width: 146, height: 268), left: .init(x: 101, y: 192), right: .init(x: 47, y: 188), mouth: .init(x: 76, y: 177), radius: 10, expression: .surprised, ropeEnd: .init(x: 74, y: 89), ropeStart: .init(x: 74, y: 0)),
        "boba": .init(size: .init(width: 183, height: 206), left: .init(x: 72, y: 119), right: .init(x: 135, y: 106), mouth: .init(x: 108, y: 127), radius: 13, expression: .neutral, ropeEnd: .init(x: 113, y: 149), ropeStart: .init(x: 107, y: 124))
    ]

    static func available(for name: String) -> ZeraFacePose? {
        guard SpriteLibrary.shared.sprite(name + "_base") != nil else { return nil }
        return poses[name]
    }

    static func artwork(for name: String) -> Sprite? {
        if poses[name] != nil, let base = SpriteLibrary.shared.sprite(name + "_base") { return base }
        return SpriteLibrary.shared.sprite(name)
    }
}

/// Live facial layers, shared by the notch character and screen mascots.
struct ZeraFace {
    private var nextBlink: TimeInterval?
    private var blinkStart: TimeInterval?
    private(set) var openness: CGFloat = 1

    mutating func advance(at now: TimeInterval, reducedMotion: Bool, interval: TimeInterval = Double.random(in: 3...6)) {
        guard !reducedMotion else { openness = 1; blinkStart = nil; nextBlink = nil; return }
        if nextBlink == nil { nextBlink = now + interval }
        if let due = nextBlink, now >= due, blinkStart == nil { blinkStart = now; nextBlink = now + interval }
        guard let start = blinkStart else { openness = 1; return }
        let elapsed = now - start
        if elapsed >= 0.22 { blinkStart = nil; openness = 1 }
        else { openness = elapsed < 0.07 ? max(0, 1 - CGFloat(elapsed / 0.07)) : (elapsed < 0.10 ? 0 : min(1, CGFloat((elapsed - 0.10) / 0.12))) }
    }

    func draw(in rect: NSRect, gaze: CGPoint, alpha: CGFloat, pose: ZeraFacePose = ZeraFacePose.poses["hang_smile"]!, expression override: ZeraExpression? = nil, annoyance: CGFloat = 0, hover: CGFloat = 0, speaking: Bool = false, time: TimeInterval = CACurrentMediaTime()) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); ctx.setAlpha(alpha)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / pose.size.width, y: rect.height / pose.size.height)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: pose.size.height - p.y) }
        let l = point(pose.left), r = point(pose.right)
        let angle = atan2(r.y - l.y, r.x - l.x)
        let radius = pose.radius
        let expression = override ?? pose.expression
        for (index, anchor) in [l, r].enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: anchor.x + gaze.x * 4, y: anchor.y + gaze.y * 3)
            ctx.rotate(by: angle)
            let far: CGFloat = index == 0 ? max(0, gaze.x) : max(0, -gaze.x)
            ctx.scaleBy(x: (1 - far * 0.10) * (1 + hover * 0.05), y: 1 + hover * 0.05)
            let brow = NSBezierPath()
            let inward: CGFloat = index == 0 ? -1 : 1
            let pleading = expression == .pleading
            let unimpressed = expression == .unimpressed
            let browTilt = (annoyance * 0.45 + (pleading ? -0.28 : 0) + (unimpressed ? 0.15 : 0)) * radius * inward
            brow.move(to: CGPoint(x: -radius * 0.5, y: radius * 1.8 - browTilt))
            brow.curve(to: CGPoint(x: radius * 0.5, y: radius * 1.8 + browTilt), controlPoint1: CGPoint(x: -radius * 0.2, y: radius * 2.0 - browTilt), controlPoint2: CGPoint(x: radius * 0.2, y: radius * 2.0 + browTilt))
            NSColor(srgbRed: 0.65, green: 0.40, blue: 0.38, alpha: 0.3 + annoyance * 0.4).setStroke()
            brow.lineWidth = radius * 0.25; brow.lineCapStyle = .round; brow.stroke()
            let eyeSize: CGFloat = pleading ? 1.13 : (expression == .surprised ? 1.08 : 1)
            ctx.scaleBy(x: eyeSize, y: max(0.045, openness * eyeSize * (expression == .sleepy ? 0.55 : 1)))
            if expression == .happy && annoyance < 0.05 && hover < 0.2 {
                let arc = NSBezierPath()
                arc.move(to: CGPoint(x: -radius * 0.8, y: -radius * 0.15))
                arc.curve(to: CGPoint(x: radius * 0.8, y: -radius * 0.15), controlPoint1: CGPoint(x: -radius * 0.5, y: radius * 0.8), controlPoint2: CGPoint(x: radius * 0.5, y: radius * 0.8))
                NSColor.black.setStroke(); arc.lineWidth = radius * 0.55; arc.lineCapStyle = .round; arc.stroke()
            } else {
                // Eyelids lower and tilt inward as she becomes annoyed; this changes
                // continuously with the reaction, instead of replacing the entire pose.
                let lidAnnoyance = max(annoyance, unimpressed ? 0.85 : 0)
                let lid = NSBezierPath()
                lid.move(to: CGPoint(x: -radius * 1.1, y: radius * (1.1 - lidAnnoyance * (index == 0 ? 0.15 : 0.7))))
                lid.line(to: CGPoint(x: radius * 1.1, y: radius * (1.1 - lidAnnoyance * (index == 0 ? 0.7 : 0.15))))
                lid.line(to: CGPoint(x: radius * 1.1, y: -radius * 1.1)); lid.line(to: CGPoint(x: -radius * 1.1, y: -radius * 1.1)); lid.close(); lid.addClip()
                let eye = NSBezierPath(ovalIn: NSRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
                NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.08, blue: 0.09, alpha: 1), ending: .black)?.draw(in: eye, angle: -90)
                // The iris ring and the shine roll toward where she's looking, inside the eye,
                // on top of the eye itself moving: her gaze reads even at a glance.
                let roll = CGPoint(x: max(-1, min(1, gaze.x)) * radius * 0.2, y: max(-1, min(1, gaze.y)) * radius * 0.16)
                let iris = NSBezierPath(ovalIn: NSRect(x: roll.x - radius * 0.66, y: roll.y - radius * 0.66, width: radius * 1.32, height: radius * 1.32))
                NSColor(srgbRed: 0.42, green: 0.27, blue: 0.30, alpha: 0.45 * openness).setStroke()
                iris.lineWidth = radius * 0.16; iris.stroke()
                NSColor.white.withAlphaComponent(0.96 * openness * openness).setFill()
                NSBezierPath(ovalIn: NSRect(x: -radius * 0.47 + roll.x * 0.6, y: radius * 0.25 + roll.y * 0.6, width: radius * 0.51, height: radius * 0.59)).fill()
                NSColor.white.withAlphaComponent(0.25 * openness * openness).setFill()
                NSBezierPath(ovalIn: NSRect(x: radius * 0.25 + roll.x * 0.4, y: -radius * 0.51 + roll.y * 0.4, width: radius * 0.21, height: radius * 0.21)).fill()
            }
            ctx.restoreGState()
        }
        ctx.saveGState()
        let mouth = point(pose.mouth)
        ctx.translateBy(x: mouth.x, y: mouth.y); ctx.rotate(by: angle)
        if speaking { ctx.scaleBy(x: 1, y: 0.75 + 0.65 * CGFloat(pow(sin(time * 9), 2))) }
        let huff = annoyance * (0.65 + 0.35 * CGFloat(sin(time * 12) * sin(time * 12)))
        NSColor(srgbRed: 0.12, green: 0.045, blue: 0.055, alpha: 1).setFill()
        if expression == .unimpressed {
            let smirk = NSBezierPath()
            smirk.move(to: CGPoint(x: -radius * 0.35, y: 0))
            smirk.curve(to: CGPoint(x: radius * 0.35, y: radius * 0.1), controlPoint1: CGPoint(x: 0, y: -radius * 0.05), controlPoint2: CGPoint(x: radius * 0.2, y: -radius * 0.1))
            NSColor(srgbRed: 0.12, green: 0.045, blue: 0.055, alpha: 1).setStroke()
            smirk.lineWidth = radius * 0.18; smirk.lineCapStyle = .round; smirk.stroke()
        } else if expression == .surprised || expression == .pleading {
            NSBezierPath(ovalIn: NSRect(x: -radius * 0.24, y: -radius * 0.3, width: radius * 0.48, height: radius * (expression == .surprised ? 0.65 : 0.35))).fill()
        } else if annoyance > 0.05 {
            NSBezierPath(ovalIn: NSRect(x: -radius * 0.3, y: -radius * 0.22, width: radius * 0.6, height: radius * (0.3 + huff * 0.35))).fill()
        } else {
            let smile = NSBezierPath()
            let width = radius * (expression == .thoughtful ? 0.65 : 0.95)
            smile.move(to: CGPoint(x: -width / 2, y: 1))
            smile.curve(to: CGPoint(x: width / 2, y: 1), controlPoint1: CGPoint(x: -width / 2, y: -radius * 0.7), controlPoint2: CGPoint(x: width / 2, y: -radius * 0.7))
            smile.curve(to: CGPoint(x: -width / 2, y: 1), controlPoint1: CGPoint(x: width * 0.1, y: -2), controlPoint2: CGPoint(x: -width * 0.1, y: -2)); smile.fill()
            NSColor(srgbRed: 0.96, green: 0.35, blue: 0.37, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: -width * 0.2, y: -radius * 0.4, width: width * 0.45, height: radius * 0.2)).fill()
        }
        ctx.restoreGState(); ctx.restoreGState()
    }

    /// Restore the rope in front of the face, especially when she swings sideways.
    static func drawForeground(_ artwork: Sprite, pose: ZeraFacePose, in rect: NSRect, alpha: CGFloat) {
        guard let start = pose.ropeStart, let end = pose.ropeEnd, let ctx = NSGraphicsContext.current?.cgContext else { return }
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x / pose.size.width * rect.width, y: rect.maxY - p.y / pose.size.height * rect.height) }
        ctx.saveGState()
        let rope = CGMutablePath(); rope.move(to: point(start)); rope.addLine(to: point(end))
        ctx.addPath(rope.copy(strokingWithWidth: rect.width / pose.size.width * 9, lineCap: .round, lineJoin: .round, miterLimit: 1))
        ctx.clip()
        artwork.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: false, hints: nil)
        ctx.restoreGState()
    }
}
