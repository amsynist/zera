import AppKit

/// Where the light goes beyond the notch's own outline.
enum EdgeLightMode: Int, CaseIterable {
    case notch = 0, top = 1, screen = 2
    var title: String {
        switch self {
        case .notch: return "Notch only"
        case .top: return "Top edge"
        case .screen: return "Whole screen"
        }
    }
}

/// How the edge light looks (Settings → Notch → Light style).
enum EdgeLightStyle: Int, CaseIterable {
    case glow = 0, glitch = 1, prism = 2, ember = 3, aurora = 4
    var title: String {
        switch self {
        case .glow: return "Soft glow"
        case .glitch: return "Glitch"
        case .prism: return "Spectrum"
        case .ember: return "Ember"
        case .aurora: return "Aurora"
        }
    }
    var blurb: String {
        switch self {
        case .glow: return "light bleeding in from the edge, a slow shimmer running through it"
        case .glitch: return "the glow tears into red and cyan, slips and stutters"
        case .prism: return "every colour flowing along the edge"
        case .ember: return "warm light that flickers like a fire behind the screen"
        case .aurora: return "three shades of the colour drifting and breathing"
        }
    }
}

/// How a moment (a copy, an agent starting) enters the edge.
enum EdgeEntrance: Int, CaseIterable {
    case sweep = 0, trace = 1, burst = 2
    var title: String {
        switch self {
        case .sweep: return "Sweeps out of the notch"
        case .trace: return "Traces corner to corner"
        case .burst: return "Bursts from the edge"
        }
    }
}

/// How far the light reaches into the screen.
enum EdgeGlowSize: Int, CaseIterable {
    case subtle = 0, medium = 1, large = 2
    var title: String {
        switch self {
        case .subtle: return "Subtle"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
    var depth: CGFloat {
        switch self {
        case .subtle: return 26
        case .medium: return 44
        case .large: return 72
        }
    }
}

/// Shared level reveal: the notch stays connected while both arms advance toward the edges.
final class LightLevelMask {
    let layer = CALayer()
    private let left = CALayer(), right = CALayer(), bridge = CALayer()
    private let leftTail = CAGradientLayer(), rightTail = CAGradientLayer()

    init() {
        [left, right, bridge].forEach { $0.backgroundColor = NSColor.black.cgColor }
        leftTail.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        rightTail.colors = [NSColor.black.cgColor, NSColor.clear.cgColor]
        for tail in [leftTail, rightTail] {
            tail.startPoint = CGPoint(x: 0, y: 0.5); tail.endPoint = CGPoint(x: 1, y: 0.5)
        }
        [left, leftTail, right, rightTail, bridge].forEach { layer.addSublayer($0) }
    }

    func update(bounds: CGRect, notch: CGRect, value: CGFloat) {
        let v = min(1, max(0, value)), tail: CGFloat = 110 * min(1, max(0, value) * 3)
        layer.frame = bounds
        let l = notch.minX - (notch.minX - bounds.minX) * v
        let r = notch.maxX + (bounds.maxX - notch.maxX) * v
        left.frame = CGRect(x: l, y: 0, width: notch.minX - l, height: bounds.height)
        right.frame = CGRect(x: notch.maxX, y: 0, width: r - notch.maxX, height: bounds.height)
        bridge.frame = CGRect(x: notch.minX, y: 0, width: notch.width, height: bounds.height)
        leftTail.frame = CGRect(x: l - tail, y: 0, width: tail, height: bounds.height)
        rightTail.frame = CGRect(x: r, y: 0, width: tail, height: bounds.height)
    }
}

// MARK: - Glow strip

/// Light coming in from one edge of the screen: a body of colour that is brightest at the edge
/// and falls off softly into the screen (no line, no caps), a hot near-white core right at the
/// edge, and a style's own life on top — a shimmer running through it, colours flowing along
/// it, a flicker, or a chromatic tear. Pure Core Animation gradients (no shadows, no offscreen
/// passes). Curved edges cache a smooth mask when geometry changes. `layer` is masked by
/// whoever owns it to set how far along the edge it reaches.
final class GlowStrip {
    enum Edge { case top, bottom, left, right }

    let layer = CALayer()
    private var loops: [(CALayer, String)] = []
    private var contourShapes: [CAShapeLayer] = []
    private var contourFalloffs: [(layer: CALayer, depth: CGFloat, alpha: CGFloat)] = []
    private var contour: CGPath?
    let edge: Edge

    init(frame: CGRect, edge: Edge, depth: CGFloat, color base: NSColor, style: EdgeLightStyle, intensity: CGFloat = 1, contour: CGPath? = nil) {
        let intensity = intensity * NotchLightStyle.intensity
        self.edge = edge
        self.contour = contour
        let color = base.usingColorSpace(.sRGB) ?? base
        layer.frame = frame
        let b = CGRect(origin: .zero, size: frame.size)
        let along = Self.isHorizontal(edge) ? b.width : b.height
        let colors = Self.palette(style, color)

        let body = makeBody(bounds: b, depth: depth, colors: colors, along: along, alpha: intensity * 0.72, flow: style != .glow && style != .glitch)
        layer.addSublayer(body)

        // The hot core: almost white where the light meets the glass.
        let core = CAGradientLayer()
        let coreW = max(1, min(1.8, depth * 0.028))
        let hot = (colors.first ?? color).blended(withFraction: 0.28, of: .white) ?? .white
        if let contour {
            core.frame = b
            core.startPoint = CGPoint(x: 0, y: 0.5); core.endPoint = CGPoint(x: 1, y: 0.5)
            core.colors = colors.map { ($0.blended(withFraction: 0.28, of: .white) ?? $0).withAlphaComponent(0.72 * intensity).cgColor }
            let mask = CAShapeLayer()
            mask.frame = b; mask.path = contour; mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            mask.lineWidth = coreW; mask.lineCap = .round; mask.lineJoin = .round
            core.mask = mask; contourShapes.append(mask)
        } else {
            core.frame = Self.band(b, edge: edge, depth: coreW)
            core.colors = [hot.withAlphaComponent(0.72 * intensity).cgColor, hot.withAlphaComponent(0).cgColor]
            Self.point(core, edge: edge)
        }
        layer.addSublayer(core)

        switch style {
        case .glow:
            shimmer(in: body, bounds: b, along: along, period: 3.4, alpha: 0.42)
            breathe(body, values: [1, 0.86, 1], duration: 3.2)
        case .aurora:
            shimmer(in: body, bounds: b, along: along, period: 5, alpha: 0.3)
            stretch(body, by: 1.3, duration: 2.6)
        case .prism:
            shimmer(in: body, bounds: b, along: along, period: 2.4, alpha: 0.35)
        case .ember:
            loop(body, "opacity", values: [1, 0.9, 0.97, 0.86, 1, 0.94, 0.98, 0.9, 1], duration: 1.8, discrete: false)
            stretch(body, by: 1.18, duration: 0.7)
            loop(core, "opacity", values: [1, 0.86, 0.95, 0.82, 1], duration: 1.2, discrete: false)
        case .glitch:
            // Red and cyan copies torn off the light, jumping sideways; bright slices that
            // blink in and out; the whole edge stutters.
            let red = NSColor(srgbRed: 1, green: 0.1, blue: 0.35, alpha: 1)
            let cyan = NSColor(srgbRed: 0.1, green: 0.95, blue: 1, alpha: 1)
            for (c, sign) in [(red, -1.0), (cyan, 1.0)] {
                let copy = makeBody(bounds: b, depth: depth * 0.8, colors: [c, c], along: along, alpha: 0.75 * intensity, flow: false)
                layer.insertSublayer(copy, below: body)
                let jumps: [CGFloat] = [-6, 3, -9, 1, -4, 8, -2]
                loop(copy, "transform", values: jumps.map {
                    let d = $0 * CGFloat(sign)
                    return NSValue(caTransform3D: Self.isHorizontal(edge) ? CATransform3DMakeTranslation(d, 0, 0) : CATransform3DMakeTranslation(0, d, 0))
                }, duration: 0.38, discrete: true)
            }
            for i in 0..<5 {
                let slice = CALayer()
                let w = CGFloat([40, 90, 24, 130, 60][i]), d = depth * CGFloat([0.5, 0.3, 0.7, 0.22, 0.4][i])
                slice.backgroundColor = hot.withAlphaComponent(0.75).cgColor
                slice.frame = Self.isHorizontal(edge) ? CGRect(x: 0, y: edge == .top ? b.height - d : 0, width: w, height: d)
                                                      : CGRect(x: edge == .right ? b.width - d : 0, y: 0, width: d, height: w)
                (contour == nil ? layer : body).addSublayer(slice)
                let spots = (0..<6).map { _ in CGFloat.random(in: 0.05...0.95) * along }
                loop(slice, Self.isHorizontal(edge) ? "position.x" : "position.y", values: spots, duration: 0.5 + Double(i) * 0.13, discrete: true)
                loop(slice, "opacity", values: [0, 1, 0, 0, 0.8, 0], duration: 0.44 + Double(i) * 0.09, discrete: true)
            }
            loop(layer, "opacity", values: [1, 1, 0.55, 1, 0.92, 1, 0.4, 1, 1, 0.8], duration: 1.05, discrete: true)
        }
    }

    // MARK: Building

    /// The coloured light: a gradient along the edge, masked by a soft falloff into the screen.
    private func makeBody(bounds b: CGRect, depth: CGFloat, colors: [NSColor], along: CGFloat, alpha: CGFloat, flow: Bool) -> CALayer {
        let body = CALayer()
        body.frame = contour == nil ? Self.band(b, edge: edge, depth: depth) : b
        let local = CGRect(origin: .zero, size: body.frame.size)
        body.anchorPoint = Self.edgeAnchor(edge)
        body.frame = contour == nil ? Self.band(b, edge: edge, depth: depth) : b

        let fill = CAGradientLayer()
        // Twice as long as the edge when the colours flow, so it can slide seamlessly.
        let ring = colors + [colors[0]]
        if Self.isHorizontal(edge) {
            fill.frame = CGRect(x: 0, y: 0, width: flow ? local.width * 2 : local.width, height: local.height)
            fill.startPoint = CGPoint(x: 0, y: 0.5); fill.endPoint = CGPoint(x: 1, y: 0.5)
        } else {
            fill.frame = CGRect(x: 0, y: 0, width: local.width, height: flow ? local.height * 2 : local.height)
            fill.startPoint = CGPoint(x: 0.5, y: 0); fill.endPoint = CGPoint(x: 0.5, y: 1)
        }
        fill.colors = (flow ? ring + ring.dropFirst() : ring).map { $0.cgColor }
        body.addSublayer(fill)
        if flow && !Motion.reduced {
            let slide = CABasicAnimation(keyPath: Self.isHorizontal(edge) ? "position.x" : "position.y")
            let start = Self.isHorizontal(edge) ? fill.position.x : fill.position.y
            slide.fromValue = start
            slide.toValue = start - along
            slide.duration = Double(along / 90)
            slide.repeatCount = .infinity
            fill.add(slide, forKey: "loop.flow")
            loops.append((fill, "loop.flow"))
        }

        if let contour {
            // A sampled optical falloff follows the very same path as the core. Colors and
            // animations above remain the original glow/prism/aurora/ember/glitch treatments.
            let falloff = CALayer()
            falloff.frame = local
            falloff.contents = Self.falloffImage(path: contour, bounds: local, depth: depth, alpha: alpha)
            falloff.contentsScale = 2
            contourFalloffs.append((falloff, depth, alpha))
            body.mask = falloff
        } else {
            // Brightest at the edge, then an exponential-ish fade: reads as light, not a band.
            let falloff = CAGradientLayer()
            falloff.frame = local
            let stops: [CGFloat] = [0, 0.08, 0.22, 0.4, 0.62, 0.82, 1]
            falloff.colors = stops.map { NSColor(white: 0, alpha: Self.opticalFalloff($0) * alpha).cgColor }
            falloff.locations = stops.map { NSNumber(value: Double($0)) }
            Self.point(falloff, edge: edge)
            body.mask = falloff
        }
        return body
    }

    /// A bright, rounded shoulder plus a faint long tail; both reach zero at the outer edge.
    /// The same profile is used for straight edges and the curved notch so they join cleanly.
    static func opticalFalloff(_ distance: CGFloat) -> CGFloat {
        let x = min(1, max(0, distance))
        let end = 0.68 * exp(-8.0) + 0.32 * exp(-4.0)
        let light = 0.68 * exp(-8 * x * x) + 0.32 * exp(-4 * x)
        return max(0, min(1, (light - end) / (1 - end)))
    }

    /// Rasterize the smooth falloff only when geometry changes. The running effect uses one
    /// mask texture, rather than a stack of animated strokes or a per-frame drawing timer.
    private static func falloffImage(path: CGPath, bounds: CGRect, depth: CGFloat, alpha: CGFloat) -> CGImage? {
        guard bounds.width > 0, bounds.height > 0,
              let context = CGContext(data: nil, width: Int(ceil(bounds.width * 2)), height: Int(ceil(bounds.height * 2)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        context.setLineCap(.round); context.setLineJoin(.round)
        var previous: CGFloat = 0
        for i in stride(from: 256, through: 1, by: -1) {
            let fraction = CGFloat(i) / 256
            let target = min(1, alpha * opticalFalloff(fraction))
            let opacity = max(0, (target - previous) / max(0.001, 1 - previous))
            context.setStrokeColor(NSColor(white: 0, alpha: opacity).cgColor)
            context.setLineWidth(depth * 2 * fraction)
            context.addPath(path); context.strokePath()
            previous = target
        }
        return context.makeImage()
    }

    /// A pale band of light that keeps running along the edge, inside the body's falloff.
    func updateContour(_ path: CGPath) {
        guard contour != path else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        contour = path
        contourShapes.forEach { $0.path = path }
        for falloff in contourFalloffs {
            falloff.layer.contents = Self.falloffImage(path: path, bounds: falloff.layer.bounds, depth: falloff.depth, alpha: falloff.alpha)
        }
        CATransaction.commit()
    }

    private func shimmer(in body: CALayer, bounds b: CGRect, along: CGFloat, period: TimeInterval, alpha: CGFloat) {
        guard !Motion.reduced else { return }
        let s = CAGradientLayer()
        let len = max(160, along * 0.22)
        let size = body.bounds.size
        if Self.isHorizontal(edge) {
            s.frame = CGRect(x: -len, y: 0, width: len, height: size.height)
            s.startPoint = CGPoint(x: 0, y: 0.5); s.endPoint = CGPoint(x: 1, y: 0.5)
        } else {
            s.frame = CGRect(x: 0, y: -len, width: size.width, height: len)
        }
        s.colors = [NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: alpha).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        body.addSublayer(s)
        let run = CABasicAnimation(keyPath: Self.isHorizontal(edge) ? "position.x" : "position.y")
        run.fromValue = -len / 2
        run.toValue = along + len / 2
        run.duration = period
        run.repeatCount = .infinity
        s.add(run, forKey: "loop.shimmer")
        loops.append((s, "loop.shimmer"))
    }

    private func breathe(_ l: CALayer, values: [Double], duration: TimeInterval) {
        loop(l, "opacity", values: values, duration: duration, discrete: false)
    }

    /// The light reaching deeper into the screen and back.
    private func stretch(_ l: CALayer, by k: CGFloat, duration: TimeInterval) {
        if contour != nil {
            // Breathe the shading without moving its connection to the notch.
            if let mask = l.mask { breathe(mask, values: [1, 1 / Double(k), 1], duration: duration) }
            return
        }
        let key = Self.isHorizontal(edge) ? "transform.scale.y" : "transform.scale.x"
        loop(l, key, values: [1, k, 1], duration: duration, discrete: false)
    }

    private func loop(_ l: CALayer, _ key: String, values: [Any], duration: TimeInterval, discrete: Bool) {
        guard !Motion.reduced else { return }
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = values
        a.duration = duration
        a.repeatCount = .infinity
        if discrete { a.calculationMode = .discrete } else { a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut) }
        let name = "loop.\(key).\(loops.count)"
        l.add(a, forKey: name)
        loops.append((l, name))
    }

    func stopLoops() {
        for (l, k) in loops { l.removeAnimation(forKey: k) }
        loops.removeAll()
    }

    // MARK: Geometry helpers

    static func isHorizontal(_ e: Edge) -> Bool { e == .top || e == .bottom }

    /// The strip of `b` that is `depth` deep from `edge` (macOS layers: y grows upwards).
    static func band(_ b: CGRect, edge: Edge, depth: CGFloat) -> CGRect {
        let d = min(depth, isHorizontal(edge) ? b.height : b.width)
        switch edge {
        case .top: return CGRect(x: 0, y: b.height - d, width: b.width, height: d)
        case .bottom: return CGRect(x: 0, y: 0, width: b.width, height: d)
        case .left: return CGRect(x: 0, y: 0, width: d, height: b.height)
        case .right: return CGRect(x: b.width - d, y: 0, width: d, height: b.height)
        }
    }

    static func edgeAnchor(_ e: Edge) -> CGPoint {
        switch e {
        case .top: return CGPoint(x: 0.5, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 0)
        case .left: return CGPoint(x: 0, y: 0.5)
        case .right: return CGPoint(x: 1, y: 0.5)
        }
    }

    /// Gradient running from the edge (first colour) into the screen (last).
    static func point(_ g: CAGradientLayer, edge: Edge) {
        switch edge {
        case .top: g.startPoint = CGPoint(x: 0.5, y: 1); g.endPoint = CGPoint(x: 0.5, y: 0)
        case .bottom: g.startPoint = CGPoint(x: 0.5, y: 0); g.endPoint = CGPoint(x: 0.5, y: 1)
        case .left: g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5)
        case .right: g.startPoint = CGPoint(x: 1, y: 0.5); g.endPoint = CGPoint(x: 0, y: 0.5)
        }
    }

    /// The colours a style paints with, starting from the moment's colour.
    static func palette(_ style: EdgeLightStyle, _ c: NSColor) -> [NSColor] {
        switch style {
        case .glow:
            return [c, c.shiftedHue(0.03), c.blended(withFraction: 0.25, of: .white) ?? c, c.shiftedHue(-0.03)]
        case .aurora:
            return [c, c.shiftedHue(0.13), c.shiftedHue(0.26), c.shiftedHue(-0.1)]
        case .prism:
            return [0.0, 0.07, 0.14, 0.3, 0.5, 0.6, 0.74, 0.86].map { NSColor(hue: $0, saturation: 0.72, brightness: 1, alpha: 1) }
        case .ember:
            let warm = [NSColor(srgbRed: 1, green: 0.42, blue: 0.08, alpha: 1), NSColor(srgbRed: 1, green: 0.2, blue: 0.08, alpha: 1),
                        NSColor(srgbRed: 1, green: 0.68, blue: 0.22, alpha: 1)]
            return warm.map { $0.blended(withFraction: 0.2, of: c) ?? $0 }
        case .glitch:
            return [c, c.blended(withFraction: 0.3, of: .white) ?? c]
        }
    }
}

extension NSColor {
    /// The same colour with its hue turned by `amount` (0…1 is a full turn).
    func shiftedHue(_ amount: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var nh = (h + amount).truncatingRemainder(dividingBy: 1)
        if nh < 0 { nh += 1 }
        return NSColor(hue: nh, saturation: max(0.5, s), brightness: max(0.85, b), alpha: a)
    }
}

// MARK: - Edge light
//
// Light that leaves the notch. "Top edge" (the default): light bleeds in along the very top of
// the screen, both ways out of the notch — a level (volume, brightness, battery) is how far it
// reaches, fading softly at its end; a copy sweeps a pool of light out to the corners; an agent
// starting sends blue out. "Whole screen": agent and notification moments send light in from
// every edge, travelling round from the notch, like phone edge lighting. Five looks, three
// entrances, three sizes. Core Animation gradients only; the windows never take the pointer,
// sit out of screen shares with the rest of Zera, and are ordered out when nothing is lit.
// Use from the main thread.
final class EdgeLight {
    static let shared = EdgeLight()
    static let styleChanged = Notification.Name("zera.edgeLight.styleChanged")
    private static let modeKey = "zera.edgeLight.mode"
    private static let styleKey = "zera.edgeLight.style"
    private static let entranceKey = "zera.edgeLight.entrance"
    private static let sizeKey = "zera.edgeLight.size"
    private static let tail: CGFloat = 110

    private var armsPanel: FloatingPanel?
    private let armsView = NSView()
    private var levelStrip: GlowStrip?
    private var sustained: [String: GlowStrip] = [:]
    private let levelMask = LightLevelMask()
    /// Feedback carries its own halo in the same window; suppress competing edge layers.
    var feedbackVisible = false {
        didSet {
            if feedbackVisible { armsPanel?.orderOut(nil) }
            else if !sustained.isEmpty { showArms() }
            screenTopStrip?.layer.isHidden = feedbackVisible
        }
    }
    private let levelHot = [CAGradientLayer(), CAGradientLayer()]
    private var levelSignature = ""
    private var screenPanel: FloatingPanel?
    private var screenTopStrip: GlowStrip?
    private var screenContainer: CALayer?
    private var screenStrips: [GlowStrip] = []
    private let screenView = NSView()
    private var levelFade: DispatchWorkItem?
    private var armsIdle: DispatchWorkItem?
    private var screenIdle: DispatchWorkItem?
    private var levelValue: CGFloat = 0
    private var live = 0
    private var momentStrip: GlowStrip?
    private var momentGeneration = 0

    private init() {}

    var mode: EdgeLightMode {
        get { EdgeLightMode(rawValue: UserDefaults.standard.object(forKey: Self.modeKey) as? Int ?? EdgeLightMode.top.rawValue) ?? .top }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
            if newValue == .notch {
                sustained.values.forEach { $0.stopLoops(); $0.layer.removeFromSuperlayer() }
                sustained.removeAll()
                armsPanel?.orderOut(nil); screenPanel?.orderOut(nil)
            }
        }
    }

    var style: EdgeLightStyle {
        get { EdgeLightStyle(rawValue: UserDefaults.standard.object(forKey: Self.styleKey) as? Int ?? 0) ?? .glow }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.styleKey)
            levelSignature = ""
            NotificationCenter.default.post(name: Self.styleChanged, object: nil)
        }
    }

    var entrance: EdgeEntrance {
        get { EdgeEntrance(rawValue: UserDefaults.standard.object(forKey: Self.entranceKey) as? Int ?? 0) ?? .sweep }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.entranceKey) }
    }

    var size: EdgeGlowSize {
        get { EdgeGlowSize(rawValue: UserDefaults.standard.object(forKey: Self.sizeKey) as? Int ?? 1) ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.sizeKey); levelSignature = "" }
    }

    private var depth: CGFloat { size.depth }

    /// Settings' "Try it": a level, then a moment, in the current look.
    func preview(color: NSColor? = nil) {
        let c = color ?? WallpaperTint.lightAccent
        level(0.72, color: c, hold: 1.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self = self else { return }
            if self.mode == .screen { self.wave(color: c) } else { self.sweep(color: c, inward: false, times: 1) }
        }
    }

    // MARK: Reacting

    /// The edge's answer to a moment the notch light also answers.
    func react(_ r: NotchLightReaction, tint: NSColor?) {
        guard NotchLightStyle.reactionsEnabled else { return }
        if feedbackVisible {
            switch r {
            case .level, .copy, .paste, .cut, .undo, .redo, .save, .screenshot, .shortcut, .capsLock, .shiftHeld: return
            default: break
            }
        }
        let p = Pal
        let blue = NSColor(srgbRed: 0.3, green: 0.55, blue: 1, alpha: 1)
        let amber = NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 1)
        let warm = NSColor(srgbRed: 1, green: 0.8, blue: 0.45, alpha: 1)
        let screen = mode == .screen
        switch r {
        case .level(let kind, let value):
            let color: NSColor
            switch kind {
            case .volume: color = tint ?? WallpaperTint.lightAccent
            case .brightness: color = warm
            case .mute: color = p.danger
            case .battery: color = p.success
            }
            level(kind == .mute ? 0 : CGFloat(value ?? 0.5), color: color, hold: kind == .battery ? 1.8 : 1.2,
                  boost: kind == .brightness)
        case .copy: sweep(color: tint ?? .white, inward: false, times: 1)
        case .paste: sweep(color: tint ?? p.accent, inward: true, times: 1)
        case .cut: flash(color: p.danger, times: 1)
        case .undo: sweep(color: p.warning, inward: true, times: 1)
        case .redo: sweep(color: p.warning, inward: false, times: 1)
        case .shortcut: flash(color: tint ?? .white, times: 1)
        case .save: flash(color: p.success, times: 1)
        case .screenshot: flash(color: .white, times: 1)
        case .capsLock(let on): flash(color: on ? p.success : .white, times: on ? 2 : 1)
        case .shiftHeld: sweep(color: .white, inward: false, times: 1)
        case .modifier(let on): sustain("modifier", on: on, color: tint ?? p.accent)
        case .music(let on): sustain("music", on: on, color: tint ?? p.accent)
        case .fileDrag(let on): sustain("fileDrag", on: on, color: tint ?? amber)
        case .listening(let on): sustain("listening", on: on, color: NSColor(srgbRed: 0.69, green: 0.48, blue: 1, alpha: 1))
        case .agentArrival: screen ? wave(color: blue) : sweep(color: blue, inward: false, times: 1)
        case .approvalNeeded: screen ? wave(color: amber) : flash(color: amber, times: 2)
        case .success: screen ? wave(color: p.success) : sweep(color: p.success, inward: false, times: 1)
        case .notification: screen ? wave(color: tint ?? p.accent) : sweep(color: tint ?? p.accent, inward: false, times: 1)
        case .danger: flash(color: p.danger, times: 1)
        }
    }

    /// Long-lived feedback shares the same silhouette as short command/level feedback.
    /// Releasing the source removes both its layer and any animation immediately.
    private func sustain(_ key: String, on: Bool, color: NSColor) {
        if let previous = sustained.removeValue(forKey: key) {
            previous.stopLoops(); previous.layer.removeFromSuperlayer()
        }
        guard on else { scheduleArmsIdle(after: 0.3); return }
        guard let t = top() else { return }
        let strip = GlowStrip(frame: armsView.bounds, edge: .top, depth: depth, color: color,
                              style: style, intensity: 0.28, contour: t.contour)
        armsView.layer?.addSublayer(strip.layer)
        sustained[key] = strip
        showArms()
    }

    // MARK: Along the top edge

    private struct Top {
        let width: CGFloat; let height: CGFloat; let leftNotch: CGFloat; let rightNotch: CGFloat
        let contour: CGPath
        var leftEnd: CGFloat { contour.boundingBoxOfPath.minX }
        var rightEnd: CGFloat { contour.boundingBoxOfPath.maxX }
    }

    private func top() -> Top? {
        guard !NSScreen.screens.isEmpty else { return nil }
        let g = NotchGeometry.detect()
        let scr = g.screen.frame, n = g.notchRect
        let h = n.height + EdgeGlowSize.large.depth * 1.3
        let frame = NSRect(x: scr.minX, y: scr.maxY - h, width: scr.width, height: h)
        if armsPanel == nil {
            let panel = FloatingPanel.make(size: frame.size, level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1), keyable: false)
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            armsView.wantsLayer = true
            panel.title = "Notch light"
            panel.contentView = armsView
            armsPanel = panel
        }
        if armsPanel?.frame != frame { armsPanel?.setFrame(frame, display: false); levelSignature = "" }
        armsView.frame = NSRect(origin: .zero, size: frame.size)
        let silhouette = BuddyStyle.current == .notch ? NotchBuddyView.frame(around: n) : n
        let width = min(frame.width, silhouette.width)
        let local = CGRect(x: n.midX - scr.minX - width / 2, y: h - n.height, width: width, height: n.height)
        return Top(width: frame.width, height: h, leftNotch: local.minX, rightNotch: local.maxX,
                   contour: NotchGeometry.topLightPath(bounds: armsView.bounds, notch: local, withArms: mode != .notch))
    }

    private func showArms() {
        guard !feedbackVisible else { return }
        armsIdle?.cancel(); armsIdle = nil
        armsPanel?.orderFrontRegardless()
    }

    private func scheduleArmsIdle(after seconds: TimeInterval) {
        armsIdle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.levelValue <= 0.001, self.live == 0, self.sustained.isEmpty else { return }
            self.levelStrip?.stopLoops(); self.levelStrip?.layer.removeFromSuperlayer(); self.levelStrip = nil
            self.levelSignature = ""
            self.armsPanel?.orderOut(nil)
        }
        armsIdle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// Light out to `value` (0…1) of the way to the screen's corners, fading softly at its end,
    /// with a brighter pool where it ends. `boost` (brightness) burns brighter as it rises.
    func level(_ value: CGFloat, color: NSColor, hold: TimeInterval, boost: Bool = false) {
        stopMoment()
        guard let t = top() else { return }
        showArms()
        let v = max(0, min(1, value))
        let sig = "\(style.rawValue)|\(color.hexString)|\(depth)|\(t.width)|\(t.leftNotch)|\(t.rightNotch)|\(t.height)"
        if sig != levelSignature || levelStrip == nil {
            levelSignature = sig
            levelStrip?.stopLoops(); levelStrip?.layer.removeFromSuperlayer()
            let strip = GlowStrip(frame: armsView.bounds, edge: .top, depth: depth, color: color, style: style, contour: t.contour)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layoutLevel(t, levelValue)
            strip.layer.mask = levelMask.layer
            strip.layer.opacity = levelValue > 0 ? 1 : 0
            // A pool of brighter light where the level ends.
            for h in levelHot {
                h.type = .radial
                h.startPoint = CGPoint(x: 0.5, y: 1)
                h.endPoint = CGPoint(x: 1, y: 0)
                let hot = color.blended(withFraction: 0.45, of: .white) ?? color
                h.colors = [hot.withAlphaComponent(0.9).cgColor, color.withAlphaComponent(0.35).cgColor, color.withAlphaComponent(0).cgColor]
                h.locations = [0, 0.35, 1]
                strip.layer.addSublayer(h)
            }
            CATransaction.commit()
            armsView.layer?.addSublayer(strip.layer)
            levelStrip = strip
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : 0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        levelStrip?.layer.removeAnimation(forKey: "fade")
        levelStrip?.layer.opacity = boost ? Float(0.65 + 0.35 * v) : 1
        layoutLevel(t, v)
        CATransaction.commit()
        levelValue = v
        levelFade?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeLevel() }
        levelFade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    /// Both reaches (solid from the notch, then a soft tail) and the pools at their ends.
    private func layoutLevel(_ t: Top, _ v: CGFloat) {
        levelMask.update(bounds: armsView.bounds,
                         notch: CGRect(x: t.leftNotch, y: 0, width: t.rightNotch - t.leftNotch, height: t.height), value: v)
        let lEnd = t.leftNotch * (1 - v)
        let rEnd = t.rightNotch + (t.width - t.rightNotch) * v
        let d = depth * 1.4
        levelHot[0].frame = CGRect(x: lEnd - d, y: t.height - d, width: d * 2, height: d * 2)
        levelHot[1].frame = CGRect(x: rEnd - d, y: t.height - d, width: d * 2, height: d * 2)
        levelHot.forEach { $0.opacity = v > 0.02 ? 1 : 0 }
    }

    private func fadeLevel() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : 0.22)
        levelStrip?.layer.opacity = 0
        CATransaction.commit()
        levelValue = 0
        scheduleArmsIdle(after: 0.8)
    }

    // MARK: Moments

    /// A soft-ended window of light (clear → light → clear) used as a moving mask.
    private static func window(length: CGFloat, height: CGFloat) -> CAGradientLayer {
        let w = CAGradientLayer()
        w.bounds = CGRect(x: 0, y: 0, width: length, height: height)
        w.startPoint = CGPoint(x: 0, y: 0.5); w.endPoint = CGPoint(x: 1, y: 0.5)
        w.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        w.locations = [0, 0.32, 0.68, 1]
        return w
    }

    /// Adds a transient strip; removes it when `duration` has passed.
    private func stopMoment() {
        momentGeneration += 1
        momentStrip?.stopLoops(); momentStrip?.layer.removeFromSuperlayer()
        momentStrip = nil; live = 0
    }

    private func moment(_ strip: GlowStrip, in view: NSView, duration: TimeInterval) {
        stopMoment()
        view.layer?.addSublayer(strip.layer)
        momentStrip = strip; live = 1
        let generation = momentGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            guard let self, self.momentGeneration == generation else { return }
            self.stopMoment()
        }
    }

    /// A moment along the top edge, in the chosen entrance: out of the notch (or in towards it).
    func sweep(color: NSColor, inward: Bool, times: Int) {
        fadeLevel()
        guard let t = top() else { return }
        showArms()
        let n = max(1, times)
        switch Motion.reduced ? EdgeEntrance.burst : entrance {
        case .sweep:
            let d: TimeInterval = 0.85
            let strip = GlowStrip(frame: armsView.bounds, edge: .top, depth: depth, color: color, style: style, contour: t.contour)
            let mask = CALayer()
            mask.frame = armsView.bounds
            let len: CGFloat = 340
            for (from, to) in [(t.leftNotch, t.leftEnd - len / 2), (t.rightNotch, t.rightEnd + len / 2)] {
                let w = Self.window(length: len, height: t.height)
                w.position = CGPoint(x: inward ? to : from, y: t.height / 2)
                mask.addSublayer(w)
                let a = CABasicAnimation(keyPath: "position.x")
                a.fromValue = inward ? to : from
                a.toValue = inward ? from : to
                a.duration = d
                a.repeatCount = Float(n)
                a.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
                w.add(a, forKey: "run")
                w.position.x = inward ? from : to
            }
            strip.layer.mask = mask
            moment(strip, in: armsView, duration: d * Double(n))
            scheduleArmsIdle(after: d * Double(n) + 0.3)
        case .trace:
            let d: TimeInterval = 1.25
            let strip = GlowStrip(frame: armsView.bounds, edge: .top, depth: depth, color: color, style: style, contour: t.contour)
            let len: CGFloat = 520
            let w = Self.window(length: len, height: t.height)
            let (from, to) = inward ? (t.rightEnd + len / 2, t.leftEnd - len / 2) : (t.leftEnd - len / 2, t.rightEnd + len / 2)
            w.position = CGPoint(x: to, y: t.height / 2)
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = from; a.toValue = to; a.duration = d; a.repeatCount = Float(n)
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.add(a, forKey: "run")
            strip.layer.mask = w
            moment(strip, in: armsView, duration: d * Double(n))
            scheduleArmsIdle(after: d * Double(n) + 0.3)
        case .burst:
            flash(color: color, times: n, burst: true)
        }
    }

    /// The whole top edge lights at once and fades (`times` pulses). A burst also reaches in.
    func flash(color: NSColor, times: Int, burst: Bool = false) {
        fadeLevel()
        guard let t = top() else { return }
        showArms()
        let d: TimeInterval = Motion.reduced ? 0.3 : 0.32 * Double(max(1, times)) + 0.45
        let strip = GlowStrip(frame: armsView.bounds, edge: .top, depth: depth, color: color, style: style, contour: t.contour)
        // Soft at both corners and dark under the notch's middle.
        let mask = CAGradientLayer()
        mask.frame = armsView.bounds
        mask.startPoint = CGPoint(x: 0, y: 0.5); mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0, 0.06, NSNumber(value: Double(t.leftNotch / t.width)), NSNumber(value: Double(t.rightNotch / t.width)), 0.94, 1]
        strip.layer.mask = mask
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = times > 1 ? [0, 1, 0.2, 1, 0] : [0, 1, 0.9, 0]
        fade.keyTimes = times > 1 ? [0, 0.12, 0.35, 0.55, 1] : [0, 0.1, 0.3, 1]
        fade.duration = d
        strip.layer.opacity = 0
        strip.layer.add(fade, forKey: "flash")
        moment(strip, in: armsView, duration: d)
        scheduleArmsIdle(after: d + 0.3)
    }

    // MARK: Whole-screen edge lighting

    /// Light comes in from every edge, travelling from the notch round both sides to meet at the
    /// bottom (or all at once for the burst entrance), and fades.
    func wave(color: NSColor) {
        guard !NSScreen.screens.isEmpty else { return }
        let g = NotchGeometry.detect()
        let scr = g.screen.frame
        if screenPanel == nil {
            let panel = FloatingPanel.make(size: scr.size, level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1), keyable: false)
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            screenView.wantsLayer = true
            panel.contentView = screenView
            screenPanel = panel
        }
        if screenPanel?.frame != scr { screenPanel?.setFrame(scr, display: false) }
        screenView.frame = NSRect(origin: .zero, size: scr.size)
        screenIdle?.cancel()
        screenStrips.forEach { $0.stopLoops() }
        screenContainer?.removeFromSuperlayer()
        screenPanel?.orderFrontRegardless()

        let b = CGRect(origin: .zero, size: scr.size)
        let container = CALayer()
        container.frame = b
        var strips: [GlowStrip] = []
        let n = BuddyStyle.current == .notch ? NotchBuddyView.frame(around: g.notchRect) : g.notchRect
        let notch = CGRect(x: n.minX - scr.minX, y: b.height - n.height, width: n.width, height: n.height)
        let topPath = NotchGeometry.topLightPath(bounds: b, notch: notch)
        for e in [GlowStrip.Edge.top, .bottom, .left, .right] {
            let s = GlowStrip(frame: b, edge: e, depth: depth * 1.1, color: color, style: style, contour: e == .top ? topPath : nil)
            if e == .top { screenTopStrip = s; s.layer.isHidden = feedbackVisible }
            container.addSublayer(s.layer)
            strips.append(s)
        }
        screenContainer = container; screenStrips = strips
        let d: TimeInterval = Motion.reduced ? 0.5 : 1.9
        if entrance != .burst && !Motion.reduced {
            // A very wide stroke round the screen, growing both ways from the top centre: its
            // round leading end makes a soft front.
            let reveal = CALayer()
            reveal.frame = b
            let r = depth * 3
            for clockwise in [true, false] {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: b.midX, y: b.maxY))
                let corners: [CGPoint] = clockwise
                    ? [CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.midX, y: b.minY)]
                    : [CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.midX, y: b.minY)]
                corners.forEach { p.addLine(to: $0) }
                let s = CAShapeLayer()
                s.frame = b
                s.path = p
                s.fillColor = nil
                s.strokeColor = NSColor.black.cgColor
                s.lineWidth = r
                s.lineCap = .round
                s.lineJoin = .round
                s.strokeEnd = 1
                let grow = CABasicAnimation(keyPath: "strokeEnd")
                grow.fromValue = 0; grow.toValue = 1; grow.duration = d * 0.6
                grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                s.add(grow, forKey: "grow")
                if entrance == .trace {
                    s.strokeStart = 1
                    let tailA = CABasicAnimation(keyPath: "strokeStart")
                    tailA.fromValue = 0; tailA.toValue = 1; tailA.duration = d
                    tailA.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    s.add(tailA, forKey: "tail")
                }
                reveal.addSublayer(s)
            }
            container.mask = reveal
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.08, 0.6, 1]
        fade.duration = d
        container.opacity = 0
        container.add(fade, forKey: "fade")
        screenView.layer?.addSublayer(container)
        let w = DispatchWorkItem { [weak self] in
            strips.forEach { $0.stopLoops() }
            container.removeFromSuperlayer()
            self?.screenPanel?.orderOut(nil)
        }
        screenIdle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.1, execute: w)
    }
}

private extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "?" }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
