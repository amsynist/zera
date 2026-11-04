import AppKit
import QuartzCore

/// The existing island is the vessel. While bytes arrive the tide beats like a pulse: the surface
/// swells and shivers on each beat, a light wave sinks through the body, a thin stream falls from
/// the notch and rings out where it lands, and bubbles rise. The beat's tempo follows the measured
/// throughput. Everything runs on the compositor; packet progress only moves the level.
/// No frame timer, live blur or audio capture.
final class PhoneLiquidLayer: CALayer {
    let outline = CAShapeLayer()
    private let vessel = CALayer()
    /// A vivid backdrop above the pool: three accent-hued glows that beat with the tide.
    private let aura = CALayer()
    private let glows = (0..<3).map { _ in CAGradientLayer() }
    private let stream = CALayer()
    private let streamFade = CAGradientLayer()
    private let streamGlow = CAShapeLayer()
    private let streamCore = CAShapeLayer()
    private let back = CAShapeLayer()
    private let body = CAGradientLayer()
    private let sink = CALayer()
    private let beatLight = CAGradientLayer()
    private let fizz = CAEmitterLayer()
    private let surface = CAShapeLayer()
    private let harmonics = (0..<2).map { _ in CAShapeLayer() }
    private let waveMask = CAShapeLayer()
    private let depth = CAGradientLayer()
    private let splash = CALayer()
    /// The panel's own edge lights up: sides and bottom, fading out toward the notch, beating
    /// with the tide. Outside the liquid's clip so its glow can spill past the edge.
    private let rim = CALayer()
    private let rimFade = CAGradientLayer()
    private let rimLines = (0..<3).map { _ in CAShapeLayer() }
    private let ripple = CAShapeLayer()
    private var size = CGSize.zero
    private var receipt: PhoneTransferState?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var fraction: CGFloat = 0
    private(set) var moving = false
    private var reduced = false
    private var sample: (id: String, time: CFTimeInterval, bytes: Int64)?
    private var rate: Double = 0
    private var poured: String?
    private let amplitude: CGFloat = 5
    /// Room above the mean line for the tallest swell plus its shiver.
    private var headroom: CGFloat { amplitude * 2.6 }

    /// One heartbeat: a strong swell, a softer echo, then rest. Shiver is in points.
    private let beatPeriod: CFTimeInterval = 1.5
    private let beatTimes: [NSNumber] = [0, 0.07, 0.16, 0.26, 0.42, 1]
    private let beatSwell: [CGFloat] = [1, 2, 1.15, 1.6, 1, 1]
    private let beatShiver: [CGFloat] = [0, 2.4, 0.7, 1.6, 0, 0]

    private struct Wave { let phase, scale, lift: CGFloat; let drift: CFTimeInterval; let reverse, closed: Bool }
    private var waves: [(CAShapeLayer, Wave)] {
        [(waveMask, Wave(phase: 0, scale: 1, lift: 0, drift: 6.8, reverse: false, closed: true)),
         (surface, Wave(phase: 0, scale: 1, lift: 0, drift: 6.8, reverse: false, closed: false)),
         (harmonics[0], Wave(phase: 0, scale: 1, lift: 0, drift: 6.8, reverse: false, closed: false)),
         (harmonics[1], Wave(phase: 1.1, scale: 0.95, lift: 5, drift: 8.8, reverse: false, closed: false)),
         (back, Wave(phase: 2.2, scale: 0.85, lift: 6, drift: 9.6, reverse: true, closed: true))]
    }

    private static let bubble: CGImage? = {
        let side = 16
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 2, dy: 2)
        ctx.setFillColor(gray: 1, alpha: 0.18); ctx.fillEllipse(in: r)
        ctx.setStrokeColor(gray: 1, alpha: 0.85); ctx.setLineWidth(1.3); ctx.strokeEllipse(in: r)
        ctx.setFillColor(gray: 1, alpha: 0.9); ctx.fillEllipse(in: CGRect(x: 5, y: 9, width: 2.6, height: 2.6))
        return ctx.makeImage()
    }()

    override init() {
        super.init()
        addSublayer(vessel)
        vessel.mask = outline
        rimFade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        rim.mask = rimFade
        for (line, width) in zip(rimLines, [14, 6, 1.6] as [CGFloat]) {
            line.fillColor = nil
            line.lineWidth = width
            line.lineCap = .round
            line.lineJoin = .round
            rim.addSublayer(line)
        }
        addSublayer(rim)
        vessel.masksToBounds = true
        for glow in glows {
            glow.type = .radial
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.locations = [0, 0.5, 1]
            glow.opacity = 0.55
            aura.addSublayer(glow)
        }
        vessel.addSublayer(aura)

        // The stream sits behind the body, so where it plunges in the liquid swallows it.
        streamFade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        streamFade.locations = [0, 0.16, 1]
        stream.mask = streamFade
        for line in [streamGlow, streamCore] {
            line.fillColor = nil
            line.lineCap = .round
            stream.addSublayer(line)
        }
        streamGlow.lineWidth = 6
        streamCore.lineWidth = 2
        streamCore.lineDashPattern = [3, 7]
        vessel.addSublayer(stream)

        back.anchorPoint = .zero
        vessel.addSublayer(back)

        body.startPoint = CGPoint(x: 0, y: 1)
        body.endPoint = CGPoint(x: 1, y: 0.12)
        body.locations = [0, 0.24, 0.7, 1]
        body.mask = waveMask
        vessel.addSublayer(body)
        sink.anchorPoint = .zero
        beatLight.startPoint = CGPoint(x: 0.5, y: 0)
        beatLight.endPoint = CGPoint(x: 0.5, y: 1)
        beatLight.opacity = 0
        sink.addSublayer(beatLight)
        body.addSublayer(sink)

        let cell = CAEmitterCell()
        cell.name = "bubble"
        cell.contents = Self.bubble
        cell.contentsScale = 2
        cell.birthRate = 9
        cell.lifetime = 12; cell.lifetimeRange = 3
        cell.velocity = 22; cell.velocityRange = 14
        cell.emissionLongitude = -.pi / 2; cell.emissionRange = .pi / 14
        cell.yAcceleration = -5
        cell.scale = 0.45; cell.scaleRange = 0.28; cell.scaleSpeed = 0.012
        cell.alphaRange = 0.45
        fizz.emitterCells = [cell]
        fizz.emitterShape = .line
        fizz.renderMode = .unordered
        fizz.birthRate = 0
        body.addSublayer(fizz)

        depth.colors = [NSColor.black.withAlphaComponent(0.12).cgColor, NSColor.black.withAlphaComponent(0.3).cgColor]
        depth.startPoint = CGPoint(x: 0.5, y: 0)
        depth.endPoint = CGPoint(x: 0.5, y: 1)
        vessel.addSublayer(depth)
        for line in [surface] + harmonics {
            line.fillColor = nil
            line.lineCap = .round
            line.anchorPoint = .zero
            vessel.addSublayer(line)
        }
        surface.lineWidth = 0.9
        for (i, line) in harmonics.enumerated() { line.lineWidth = i == 0 ? 4 : 0.6 }
        waveMask.anchorPoint = .zero

        splash.anchorPoint = .zero
        ripple.fillColor = nil
        ripple.lineWidth = 1.5
        ripple.opacity = 0
        ripple.path = CGPath(ellipseIn: CGRect(x: -120, y: -9, width: 240, height: 18), transform: nil)
        splash.addSublayer(ripple)
        vessel.addSublayer(splash)

        opacity = 0
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: Palette.changed, object: nil, queue: .main) { [weak self] _ in
            self?.apply(animated: false)
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.update(self.receipt, reducedMotion: Motion.reduced)
        }))
    }
    deinit { for (center, observer) in observers { center.removeObserver(observer) } }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func layout(in rect: CGRect, canvas: CGRect, corner: CGFloat = Isle.corner) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = canvas
        vessel.frame = rect
        // The island's outline is in canvas coordinates; the vessel sits at `rect` inside it.
        outline.frame = CGRect(x: -rect.minX, y: -rect.minY, width: canvas.width, height: canvas.height)
        rim.frame = CGRect(origin: .zero, size: canvas.size)
        rimFade.frame = CGRect(x: rect.minX - 20, y: rect.minY, width: rect.width + 40, height: rect.height + 20)
        rimFade.locations = [0, NSNumber(value: Double(min(0.6, 72 / max(1, rimFade.frame.height))))]
        let edge = Self.edgePath(rect, corner: corner)
        for line in rimLines { line.path = edge }
        let changed = size != rect.size
        size = rect.size
        body.frame = vessel.bounds
        depth.frame = vessel.bounds
        aura.frame = vessel.bounds
        // Behind Zera, on the phone's side, and a quieter one opposite.
        for (glow, spot) in zip(glows, [(0.5, 0.2, 0.8, 1.0), (0.88, 0.4, 0.62, 1.1), (0.12, 0.55, 0.5, 0.9)] as [(CGFloat, CGFloat, CGFloat, CGFloat)]) {
            glow.bounds = CGRect(x: 0, y: 0, width: size.width * spot.2, height: size.height * spot.3)
            glow.position = CGPoint(x: size.width * spot.0, y: size.height * spot.1)
        }
        stream.frame = vessel.bounds
        streamFade.frame = stream.bounds
        sink.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        beatLight.frame = CGRect(x: 0, y: -36, width: size.width, height: 72)
        fizz.frame = body.bounds
        fizz.emitterPosition = CGPoint(x: size.width / 2, y: size.height + 4)
        fizz.emitterSize = CGSize(width: size.width * 0.8, height: 1)
        splash.bounds = CGRect(x: 0, y: 0, width: size.width, height: 1)
        ripple.position = CGPoint(x: size.width / 2, y: 0)
        if changed, size.width > 0, size.height > 0 {
            let bounds = CGRect(x: 0, y: 0, width: size.width * 3, height: size.height * 2 + headroom * 2)
            for (layer, wave) in waves {
                layer.bounds = bounds
                layer.path = wavePath(phase: wave.phase, amplitude: amplitude * wave.scale, closed: wave.closed)
            }
            stopMotion()
        }
        CATransaction.commit()
        apply(animated: false)
    }

    func update(_ receipt: PhoneTransferState?, reducedMotion: Bool) {
        let changedMotion = reduced != reducedMotion
        reduced = reducedMotion
        self.receipt = receipt
        fraction = receipt.map { $0.phase == .saved ? 1 : CGFloat($0.progress ?? 0) } ?? 0
        measure(receipt)
        if changedMotion { stopMotion() }
        apply(animated: !reducedMotion)
    }

    /// Smoothed bytes per second from real progress; it only sets the beat's tempo.
    private func measure(_ receipt: PhoneTransferState?) {
        guard let receipt, receipt.phase == .receiving else { sample = nil; rate = 0; return }
        let now = CACurrentMediaTime()
        guard let last = sample, last.id == receipt.id else { sample = (receipt.id, now, receipt.received); return }
        let dt = now - last.time
        guard dt >= 0.25 else { return }
        let instant = Double(max(0, receipt.received - last.bytes)) / dt
        rate = rate == 0 ? instant : rate * 0.7 + instant * 0.3
        sample = (receipt.id, now, receipt.received)
        // ~0.8× while trickling, up to ~1.7× near 100 MB/s.
        let fast = min(1, log10(1 + rate / 1_000_000) / 2)
        setTempo(Float(0.8 + fast * 0.9))
    }

    private func setTempo(_ tempo: Float) {
        guard abs(vessel.speed - tempo) > 0.08 else { return }
        // Re-anchor local time so the running beat changes pace without jumping.
        let now = CACurrentMediaTime()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for clock in [vessel, rim] {
            clock.timeOffset = clock.convertTime(now, from: nil)
            clock.beginTime = convertTime(now, from: nil)
            clock.speed = tempo
        }
        CATransaction.commit()
    }

    private func apply(animated: Bool) {
        guard let receipt, size.width > 0 else {
            opacity = 0; stopMotion(); return
        }
        let receiving = receipt.phase == .receiving
        let failed = receipt.phase == .failed
        // Unknown sizes have a small indeterminate pool; no percentage is fabricated.
        let level = receipt.progress == nil && receiving ? CGFloat(0.08) : fraction
        let mean = size.height * (1 - level)
        let live = level > 0 && level < 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        opacity = 1
        let accent = failed ? Pal.danger : Pal.accent
        let deep = accent.blended(withFraction: 0.55, of: Pal.cardBottom) ?? accent
        let middle = accent.blended(withFraction: 0.28, of: Pal.cardBottom) ?? accent
        let pearl = accent.blended(withFraction: 0.35, of: Pal.text) ?? accent
        body.startPoint = CGPoint(x: 0.25, y: max(0, 1 - level))
        body.endPoint = CGPoint(x: 0.65, y: 1)
        body.colors = [accent.withAlphaComponent(0.7).cgColor,
                       middle.withAlphaComponent(0.8).cgColor,
                       deep.withAlphaComponent(0.92).cgColor,
                       deep.withAlphaComponent(0.98).cgColor]
        body.opacity = level > 0 ? 1 : 0
        back.fillColor = pearl.withAlphaComponent(0.2).cgColor
        surface.strokeColor = pearl.withAlphaComponent(0.65).cgColor
        harmonics[0].strokeColor = pearl.withAlphaComponent(0.1).cgColor
        harmonics[1].strokeColor = accent.withAlphaComponent(0.14).cgColor
        beatLight.colors = [pearl.withAlphaComponent(0).cgColor, pearl.withAlphaComponent(0.3).cgColor,
                            pearl.withAlphaComponent(0).cgColor]
        streamGlow.strokeColor = accent.withAlphaComponent(0.22).cgColor
        streamCore.strokeColor = pearl.withAlphaComponent(0.85).cgColor
        ripple.strokeColor = pearl.withAlphaComponent(0.8).cgColor
        fizz.setValue(pearl.withAlphaComponent(0.75).cgColor, forKeyPath: "emitterCells.bubble.color")
        for (glow, (shift, peak)) in zip(glows, [(0, 0.66), (0.09, 0.56), (-0.11, 0.44)] as [(CGFloat, CGFloat)]) {
            let hue = Self.vivid(accent, shift: shift)
            glow.colors = [hue.withAlphaComponent(peak).cgColor, hue.withAlphaComponent(peak * 0.32).cgColor,
                           hue.withAlphaComponent(0).cgColor]
        }
        // The brighter side glow sits where the phone's card came in.
        let phoneSide = receipt.side < 0 ? CGFloat(0.12) : 0.88
        glows[1].position.x = size.width * phoneSide
        glows[2].position.x = size.width * (1 - phoneSide)

        var riders: [(CALayer, CGPoint)] = waves.map { layer, wave in
            // The mask must cover the whole vessel once it is full.
            let y = layer === waveMask && level >= 1 ? -headroom * 2 - 2 : mean - headroom - wave.lift
            return (layer, CGPoint(x: -size.width, y: y))
        }
        riders += [(sink, CGPoint(x: 0, y: mean)), (splash, CGPoint(x: 0, y: mean))]
        for (layer, target) in riders {
            let from = layer.presentation()?.position.y ?? layer.position.y
            layer.position = target
            if animated, abs(from - target.y) > 0.5 {
                let rise = CABasicAnimation(keyPath: "position.y")
                rise.fromValue = from; rise.toValue = target.y; rise.duration = 0.38
                rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(rise, forKey: "liquid.level")
            }
        }
        for (layer, _) in waves where layer !== waveMask { layer.opacity = live ? 1 : 0 }
        waveMask.opacity = 1

        let fall = CGMutablePath()
        fall.move(to: CGPoint(x: size.width / 2, y: 0))
        fall.addLine(to: CGPoint(x: size.width / 2, y: mean + headroom * 2))
        for line in [streamGlow, streamCore] {
            let from = line.presentation()?.path ?? line.path
            line.path = fall
            if animated, let from {
                let rise = CABasicAnimation(keyPath: "path")
                rise.fromValue = from; rise.toValue = fall; rise.duration = 0.38
                rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
                line.add(rise, forKey: "liquid.level")
            }
        }
        stream.opacity = receiving && level < 1 ? 1 : 0
        if receiving, animated, poured != receipt.id {
            // The swiped card lands in the notch first; then the stream starts to pour.
            poured = receipt.id
            let pour = CABasicAnimation(keyPath: "opacity")
            pour.fromValue = 0; pour.toValue = 1; pour.duration = 0.25
            pour.beginTime = stream.convertTime(CACurrentMediaTime(), from: nil) + 0.5
            pour.fillMode = .backwards
            stream.add(pour, forKey: "liquid.pour")
        }
        // The panel's edge: breathing while the card approaches, beating with the tide as it pours.
        let edgeHue = Self.vivid(accent, shift: 0)
        for (line, alpha) in zip(rimLines, [0.14, 0.32, 0.95] as [CGFloat]) {
            let hue = line === rimLines[2] ? (edgeHue.blended(withFraction: 0.3, of: .white) ?? edgeHue) : edgeHue
            line.strokeColor = hue.withAlphaComponent(alpha).cgColor
        }
        let approaching = receipt.phase == .approaching
        rim.opacity = approaching || (receiving && level < 1) ? 0.8 : 0
        if approaching, !reduced {
            if rim.animation(forKey: "liquid.rim.breathe") == nil {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.4; breathe.toValue = 1; breathe.duration = 1.1
                breathe.autoreverses = true; breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                rim.add(breathe, forKey: "liquid.rim.breathe")
            }
        } else { rim.removeAnimation(forKey: "liquid.rim.breathe") }
        CATransaction.commit()
        if receiving, !reduced, level < 1 { startMotion() }
        else { stopMotion() }
    }

    private func startMotion() {
        if moving, waveMask.animation(forKey: "liquid.flow") != nil { return }
        stopMotion()
        moving = true
        let epoch = vessel.convertTime(CACurrentMediaTime(), from: nil)
        func beat(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: keyPath)
            a.values = values; a.keyTimes = beatTimes
            a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: beatTimes.count - 1)
            a.duration = beatPeriod; a.repeatCount = .infinity; a.beginTime = epoch
            return a
        }
        for (layer, wave) in waves {
            let flow = CABasicAnimation(keyPath: "transform.translation.x")
            flow.fromValue = 0; flow.toValue = wave.reverse ? -size.width : size.width
            flow.duration = wave.drift
            flow.repeatCount = .infinity
            flow.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(flow, forKey: "liquid.flow")
            layer.add(beat("path", zip(beatSwell, beatShiver).map { swell, shiver in
                wavePath(phase: wave.phase, amplitude: amplitude * wave.scale * swell, shiver: shiver * wave.scale, closed: wave.closed)
            }), forKey: "liquid.beat")
        }
        harmonics[0].add(beat("lineWidth", [4, 9, 5, 7.5, 4, 4]), forKey: "liquid.beat.glow")
        streamGlow.add(beat("lineWidth", [6, 12, 7, 10, 6, 6]), forKey: "liquid.beat")

        let drip = CABasicAnimation(keyPath: "lineDashPhase")
        drip.fromValue = 0; drip.toValue = -10; drip.duration = 0.24
        drip.repeatCount = .infinity
        streamCore.add(drip, forKey: "liquid.flow")

        // The beat's light sinks through the body and fades on the way down.
        let descend = CABasicAnimation(keyPath: "transform.translation.y")
        descend.fromValue = 0; descend.toValue = size.height * 0.75
        descend.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0, 1, 0.55, 0]; glow.keyTimes = [0, 0.1, 0.45, 1]
        let sinkBeat = CAAnimationGroup()
        sinkBeat.animations = [descend, glow]
        sinkBeat.duration = beatPeriod; sinkBeat.repeatCount = .infinity; sinkBeat.beginTime = epoch
        beatLight.add(sinkBeat, forKey: "liquid.beat")

        // Where the stream lands, each beat rings out across the surface.
        let spread = CABasicAnimation(keyPath: "transform.scale")
        spread.fromValue = 0.08; spread.toValue = 1
        spread.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]; fade.keyTimes = [0, 0.12, 1]
        let ring = CAAnimationGroup()
        ring.animations = [spread, fade]
        ring.duration = beatPeriod; ring.repeatCount = .infinity
        ring.beginTime = epoch + beatPeriod * 0.05
        ripple.add(ring, forKey: "liquid.beat")

        // The backdrop breathes on the same heartbeat and drifts slowly, each glow at its own pace.
        for (i, glow) in glows.enumerated() {
            glow.add(beat("opacity", [0.55, 1, 0.72, 0.92, 0.55, 0.55]), forKey: "liquid.beat")
            glow.add(beat("transform.scale", [1, 1.14, 1.03, 1.09, 1, 1]), forKey: "liquid.beat.swell")
            let drift = CABasicAnimation(keyPath: "transform.translation.x")
            drift.fromValue = -size.width * 0.05; drift.toValue = size.width * 0.05
            drift.duration = [5.5, 7, 6.3][i]
            drift.autoreverses = true; drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(drift, forKey: "liquid.flow")
        }

        // The rim lives outside the vessel, so it starts its beat on its own clock, now.
        let edgeBeat = beat("opacity", [0.55, 1, 0.7, 0.9, 0.55, 0.55])
        edgeBeat.beginTime = rim.convertTime(CACurrentMediaTime(), from: nil)
        rim.add(edgeBeat, forKey: "liquid.beat")

        fizz.lifetime = 1
        fizz.birthRate = 1
    }

    /// The panel's sides and bottom, matching the island's own corner curve; the top is left open.
    private static func edgePath(_ r: CGRect, corner c: CGFloat) -> CGPath {
        let p = CGMutablePath(), k: CGFloat = 0.45
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        p.addCurve(to: CGPoint(x: r.minX + c, y: r.maxY), control1: CGPoint(x: r.minX, y: r.maxY - c * k),
                   control2: CGPoint(x: r.minX + c * k, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY - c), control1: CGPoint(x: r.maxX - c * k, y: r.maxY),
                   control2: CGPoint(x: r.maxX, y: r.maxY - c * k))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }

    /// The accent turned toward a neighbouring hue and lifted to full vividness; greys stay grey.
    private static func vivid(_ color: NSColor, shift: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s >= 0.15 else { return rgb }
        return NSColor(hue: (h + shift + 1).truncatingRemainder(dividingBy: 1), saturation: max(s, 0.72), brightness: max(b, 0.92), alpha: 1)
    }
    func stopMotion() {
        moving = false
        for (layer, _) in waves {
            layer.removeAnimation(forKey: "liquid.flow")
            layer.removeAnimation(forKey: "liquid.beat")
        }
        harmonics[0].removeAnimation(forKey: "liquid.beat.glow")
        for layer in [streamGlow, streamCore, beatLight, ripple, rim] + glows as [CALayer] {
            layer.removeAnimation(forKey: "liquid.flow")
            layer.removeAnimation(forKey: "liquid.beat")
            layer.removeAnimation(forKey: "liquid.beat.swell")
        }
        // Zero lifetime clears bubbles already in flight, not just new births.
        fizz.birthRate = 0
        fizz.lifetime = 0
    }

    private func wavePath(phase: CGFloat, amplitude: CGFloat, shiver: CGFloat = 0, closed: Bool) -> CGPath {
        let path = CGMutablePath()
        let width = max(1, size.width)
        let k = CGFloat.pi * 2 / width
        // Enough segments that the 7× shiver stays round; every path has the same element count.
        let segments = 216
        func point(_ x: CGFloat) -> CGPoint {
            CGPoint(x: x, y: headroom + sin(x * k + phase) * amplitude
                    + sin(x * k * 2 + phase) * amplitude * 0.2
                    + sin(x * k * 7 + phase * 3) * shiver)
        }
        func slope(_ x: CGFloat) -> CGFloat {
            k * (cos(x * k + phase) * amplitude + cos(x * k * 2 + phase) * amplitude * 0.4
                 + cos(x * k * 7 + phase * 3) * shiver * 7)
        }
        path.move(to: point(0))
        for i in 1...segments {
            let x0 = CGFloat(i - 1) / CGFloat(segments) * width * 3
            let x1 = CGFloat(i) / CGFloat(segments) * width * 3
            let a = point(x0), b = point(x1), dx = (x1 - x0) / 3
            path.addCurve(to: b, control1: CGPoint(x: x0 + dx, y: a.y + slope(x0) * dx),
                          control2: CGPoint(x: x1 - dx, y: b.y - slope(x1) * dx))
        }
        if closed {
            path.addLine(to: CGPoint(x: width * 3, y: size.height * 2 + headroom * 2))
            path.addLine(to: CGPoint(x: 0, y: size.height * 2 + headroom * 2))
            path.closeSubpath()
        }
        return path
    }
}
