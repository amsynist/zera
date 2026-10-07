import AppKit

// The Mac's vitals on Home: a slim strip under the search box (CPU, memory, GPU, network,
// battery) that opens a full "This Mac" page. Numbers glide to each new reading; a soft light
// scans across the strip now and then. Readings come from `SystemVitals` while either shows.

// MARK: - Formatting

enum VitalsFormat {
    /// 84_200_000 bits/s → ("84.2", "Mb/s").
    static func rate(_ bps: Double) -> (String, String) {
        if bps >= 1e9 { return (String(format: "%.2f", bps / 1e9), "Gb/s") }
        if bps >= 1e6 { return (bps >= 1e8 ? String(format: "%.0f", bps / 1e6) : String(format: "%.1f", bps / 1e6), "Mb/s") }
        return (String(format: "%.0f", bps / 1e3), "Kb/s")
    }
    static func gb(_ bytes: Double) -> String { String(format: "%.1f", bytes / 1_073_741_824) }
    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60), h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }
    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
}

// MARK: - Gliding numbers

/// Values that ease from one reading to the next instead of jumping.
final class VitalsTween {
    private(set) var values: [Double] = []
    private var from: [Double] = []
    /// Where it's heading: what the numbers say (they change once, not through every step).
    private(set) var to: [Double] = []
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    var duration: CFTimeInterval = 0.55
    var onStep: (() -> Void)?

    func set(_ v: [Double]) {
        guard v.count == values.count, !Motion.reduced else { values = v; to = v; onStep?(); return }
        guard v != to else { return }
        from = values; to = v
        start = CACurrentMediaTime()
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }
    private func tick() {
        let t = min(1, (CACurrentMediaTime() - start) / duration)
        // Ease in and out: starts gently, lands gently.
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        values = zip(from, to).map { $0 + ($1 - $0) * e }
        onStep?()
        if t >= 1 { timer?.invalidate(); timer = nil }
    }
    deinit { timer?.invalidate() }
}

// MARK: - Drawing

private enum VDraw {
    static func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: p)
    }
    static func width(_ s: String, _ font: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }
    static func label(_ s: String, at p: NSPoint, color: NSColor? = nil) { Typo.sectionText(s, color: color).draw(at: p) }

    /// A ring from twelve o'clock, clockwise, in a flipped view.
    static func ring(center c: NSPoint, radius r: CGFloat, width w: CGFloat, progress: Double, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setLineWidth(w)
        ctx.setStrokeColor(color.withAlphaComponent(0.16).cgColor)
        ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        let p = max(0, min(1, progress))
        if p > 0.002 {
            ctx.setLineCap(.round)
            ctx.setStrokeColor(color.cgColor)
            ctx.addArc(center: c, radius: r, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * CGFloat(p), clockwise: false)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// A line through `values` scaled to `maxValue`, filling `rect`; optionally the area under it.
    static func spark(_ values: [Double], in rect: NSRect, max maxValue: Double, color: NSColor, area: Bool = false, dashed: Bool = false, width: CGFloat = 1.5) {
        guard values.count > 1, maxValue > 0 else { return }
        let line = NSBezierPath()
        for (i, v) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1)
            let y = rect.maxY - 1 - (rect.height - 3) * CGFloat(min(1, v / maxValue))
            i == 0 ? line.move(to: NSPoint(x: x, y: y)) : line.line(to: NSPoint(x: x, y: y))
        }
        if area, let fill = line.copy() as? NSBezierPath {
            fill.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            fill.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            fill.close()
            color.withAlphaComponent(0.15).setFill()
            fill.fill()
        }
        line.lineWidth = width
        line.lineJoinStyle = .round
        if dashed { line.setLineDash([3, 3], count: 2, phase: 0) }
        color.setStroke()
        line.stroke()
    }

    static func battery(in r: NSRect, level: Double, color: NSColor, charging: Bool) {
        let body = NSRect(x: r.minX, y: r.minY, width: r.width - 3, height: r.height)
        let shell = NSBezierPath(roundedRect: body.insetBy(dx: 0.75, dy: 0.75), xRadius: r.height * 0.28, yRadius: r.height * 0.28)
        Pal.text.withAlphaComponent(0.32).setStroke(); shell.lineWidth = 1.5; shell.stroke()
        let inner = body.insetBy(dx: 2.5, dy: 2.5)
        let fill = NSRect(x: inner.minX, y: inner.minY, width: inner.width * CGFloat(max(0.04, min(1, level))), height: inner.height)
        color.setFill(); NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        Pal.text.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: r.midY - r.height * 0.18, width: 2, height: r.height * 0.36), xRadius: 1, yRadius: 1).fill()
        if charging {
            Neon.symbol("bolt.fill", in: body, size: r.height * 0.62, weight: .bold, color: Pal.cardBottom.withAlphaComponent(1))
        }
    }
}

/// Colours per vital, from the theme.
private extension Palette {
    var vCPU: NSColor { accent }
    var vMemory: NSColor { info }
    var vGPU: NSColor { highlight }
    var vNet: NSColor { success }
    func vBattery(_ b: VitalsSample.Battery) -> NSColor { b.percent <= 20 && !b.onPower ? danger : success }
}

// MARK: - The strip on Home

/// CPU · Memory · GPU · Network · Battery in one 58 pt bar. Click anywhere to open This Mac.
final class VitalsStrip: NSView {
    static let height: CGFloat = 58
    var onOpen: (() -> Void)?
    private let tween = VitalsTween()
    private let scan = CAGradientLayer()
    private var hoverIndex: Int?
    private var lastSegments: [NSRect] = []
    private var pressed = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.l
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        scan.colors = [NSColor.clear.cgColor, Pal.accent.withAlphaComponent(0.13).cgColor, NSColor.clear.cgColor]
        scan.startPoint = CGPoint(x: 0, y: 0.5)
        scan.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(scan)
        tween.duration = 1.1
        tween.onStep = { [weak self] in self?.needsDisplay = true }
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: SystemVitals.changed, object: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("This Mac")
        changed()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// The strip moves on every other reading, so it reads calmly at a glance.
    private var lastUpdate: CFTimeInterval = 0
    static let interval: CFTimeInterval = 1.9

    @objc private func changed() {
        let now = CACurrentMediaTime()
        guard tween.to.isEmpty || now - lastUpdate >= Self.interval else { return }
        lastUpdate = now
        let s = SystemVitals.shared.now
        tween.set([s.cpu, s.memTotal > 0 ? s.memUsed / s.memTotal : 0, s.gpu ?? 0, s.down, s.up, Double(s.battery?.percent ?? 0)])
        let net = VitalsFormat.rate(s.down)
        setAccessibilityValue("CPU \(Int(s.cpu * 100))%, memory \(VitalsFormat.gb(s.memUsed)) GB, download \(net.0) \(net.1)")
    }

    /// The light that sweeps across now and then (not with Reduce Motion).
    private func startScan() {
        scan.removeAllAnimations()
        guard !Motion.reduced, window != nil else { return }
        let w = bounds.width
        scan.frame = NSRect(x: -100, y: 0, width: 90, height: bounds.height)
        let a = CAKeyframeAnimation(keyPath: "position.x")
        a.values = [-60, -60, w + 60]
        a.keyTimes = [0, 0.6, 1]
        a.duration = 4.5
        a.repeatCount = .infinity
        a.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)]
        scan.add(a, forKey: "scan")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startScan()
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changedWidth = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changedWidth { startScan() }
    }

    /// What each segment shows: a label and a value with an optional quieter part.
    private func content(_ kind: Int, _ v: [Double]) -> (label: String, big: String, small: String?) {
        let s = SystemVitals.shared.now
        switch kind {
        case 0: return ("CPU", "\(Int((v[0] * 100).rounded()))%", nil)
        case 1: return ("Memory", VitalsFormat.gb(v[1] * s.memTotal), "/ \(Int((s.memTotal / 1_073_741_824).rounded())) GB")
        case 2: return ("GPU", s.gpu == nil ? "—" : "\(Int((v[2] * 100).rounded()))%", nil)
        case 3:
            let d = VitalsFormat.rate(v[3]), u = VitalsFormat.rate(v[4])
            return ("\(s.wifiLink == nil ? "Net" : "Wi-Fi") ↑\(u.0)", "↓\(d.0)", d.1)
        default: return ("Battery", "\(Int(v[5].rounded()))%", nil)
        }
    }

    private static let glyph: CGFloat = 24, pad: CGFloat = 10, gap: CGFloat = 8
    private static let bigFont = TaskFont.clock(17)

    /// The widest each segment's words can be ("100%", "99.9 / 16 GB", "↓88.8 Mb/s"), so the
    /// segments keep their size whatever the numbers do.
    private func widest(_ kind: Int) -> CGFloat {
        let s = SystemVitals.shared.now
        let gb = "/ \(Int((s.memTotal / 1_073_741_824).rounded())) GB"
        let (label, big, small): (String, String, String?) = {
            switch kind {
            case 0: return ("CPU", "100%", nil)
            case 1: return ("Memory", "88.8", gb)
            case 2: return ("GPU", "100%", nil)
            case 3: return ("Wi-Fi ↑88.8", "↓88.8", "Mb/s")
            default: return ("Battery", "100%", nil)
            }
        }()
        let l = Typo.sectionText(label).size().width
        let v = VDraw.width(big, Self.bigFont) + (small.map { 3 + VDraw.width($0, Typo.caption) } ?? 0)
        return Self.pad * 2 + Self.glyph + Self.gap + ceil(max(l, v))
    }

    private var segmentCache: (width: CGFloat, battery: Bool, rects: [(kind: Int, rect: NSRect)])?

    /// Fixed segments: each as wide as its widest words, the spare room shared out evenly.
    private func segments() -> [(kind: Int, rect: NSRect)] {
        let battery = SystemVitals.shared.now.battery != nil
        if let c = segmentCache, c.width == bounds.width, c.battery == battery { return c.rects }
        let kinds = battery ? [0, 1, 2, 3, 4] : [0, 1, 2, 3]
        let need = kinds.map(widest)
        let total = need.reduce(0, +)
        let spare = max(0, bounds.width - total) / CGFloat(kinds.count)
        let scale = min(1, bounds.width / max(1, total))
        var x: CGFloat = 0
        let rects: [(kind: Int, rect: NSRect)] = zip(kinds, need).map { k, n in
            let w = (n * scale + spare).rounded()
            defer { x += w }
            return (k, NSRect(x: x, y: 0, width: w, height: bounds.height))
        }
        segmentCache = (bounds.width, battery, rects)
        return rects
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l, yRadius: Radius.l)
        (pressed ? p.surfacePressed : p.surfaceRow).setFill(); shape.fill()
        let s = SystemVitals.shared.now
        let v = tween.values.count == 6 ? tween.values : [0, 0, 0, 0, 0, 0]
        // Rings and the battery glide; the numbers show where they're going.
        let target = tween.to.count == 6 ? tween.to : v
        let segs = segments()
        lastSegments = segs.map(\.rect)
        for (i, seg) in segs.enumerated() {
            let r = seg.rect
            if hoverIndex == i { p.text.withAlphaComponent(0.035).setFill(); r.fill() }
            if i > 0 { p.divider.setFill(); NSRect(x: r.minX, y: 10, width: 1, height: r.height - 20).fill() }
            let gx = r.minX + Self.pad, mid = r.midY, g = Self.glyph
            let tx = gx + g + Self.gap
            let c = content(seg.kind, target)
            switch seg.kind {
            case 0: VDraw.ring(center: NSPoint(x: gx + g / 2, y: mid), radius: g / 2 - 2, width: 3, progress: v[0], color: p.vCPU)
            case 1: VDraw.ring(center: NSPoint(x: gx + g / 2, y: mid), radius: g / 2 - 2, width: 3, progress: v[1], color: p.vMemory)
            case 2: VDraw.ring(center: NSPoint(x: gx + g / 2, y: mid), radius: g / 2 - 2, width: 3, progress: v[2], color: p.vGPU)
            case 3:
                let hist = Array(SystemVitals.shared.downHistory.suffix(16))
                VDraw.spark(hist, in: NSRect(x: gx, y: mid - 10, width: g, height: 20), max: max(1e6, hist.max() ?? 1), color: p.vNet, width: 1.4)
            default:
                if let b = s.battery { VDraw.battery(in: NSRect(x: gx, y: mid - 6, width: g, height: 12), level: v[5] / 100, color: p.vBattery(b), charging: b.charging) }
            }
            VDraw.label(c.label, at: NSPoint(x: tx, y: mid - 16))
            VDraw.text(c.big, Self.bigFont, p.text, at: NSPoint(x: tx, y: mid - 1))
            if let small = c.small {
                VDraw.text(small, Typo.caption, p.textSecondary, at: NSPoint(x: tx + VDraw.width(c.big, Self.bigFont) + 3, y: mid + 2))
            }
        }
        (hoverIndex != nil ? p.accentBorder : p.accent.withAlphaComponent(0.22)).setStroke()
        shape.lineWidth = 1; shape.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let i = lastSegments.firstIndex { $0.contains(pt) }
        if i != hoverIndex { hoverIndex = i; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; pressed = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - This Mac

/// The full page: CPU and GPU rings with the per-core bars and a minute of graphics load, the
/// network graph with an on-demand speed test, memory by kind, and the battery.
final class VitalsPage: NSView {
    static let height: CGFloat = 124 + 8 + 112 + 8 + 100
    private let tween = VitalsTween()
    private let coreTween = VitalsTween()
    private var speedButton: CardButton!
    private var spinPhase: CGFloat = 0
    private var spinTimer: Timer?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        speedButton = CardButton("Run speed test", style: .primary, symbol: "speedometer", target: self, action: #selector(runSpeed))
        speedButton.toolTip = "Measures your internet connection with macOS's networkQuality (about 20 seconds)"
        addSubview(speedButton)
        tween.duration = 0.9
        coreTween.duration = 0.9
        tween.onStep = { [weak self] in self?.needsDisplay = true }
        coreTween.onStep = { [weak self] in self?.needsDisplay = true }
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: SystemVitals.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(speedChanged), name: SystemVitals.speedChanged, object: nil)
        changed()
        speedChanged()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self); spinTimer?.invalidate() }

    @objc private func changed() {
        let s = SystemVitals.shared.now
        tween.set([s.cpu, s.gpu ?? 0, s.down, s.up, s.memApps, s.memWired, s.memCompressed, Double(s.battery?.percent ?? 0), s.battery?.watts ?? 0])
        coreTween.set(s.cores)
    }

    @objc private func runSpeed() { SystemVitals.shared.runSpeedTest() }

    @objc private func speedChanged() {
        let testing = SystemVitals.shared.speedTesting
        speedButton.isHidden = testing
        spinTimer?.invalidate(); spinTimer = nil
        if testing, !Motion.reduced {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                self?.spinPhase += 0.012
                self?.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            spinTimer = t
        }
        needsDisplay = true
    }

    /// For the screen's subtitle: "macOS 26.0 · up 3d 4h".
    static var subtitle: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(v.majorVersion).\(v.minorVersion)"
        let up = SystemVitals.shared.now.uptime
        return up > 0 ? "\(os) · up \(VitalsFormat.duration(up))" : os
    }

    private var rects: (cpu: NSRect, gpu: NSRect, net: NSRect, mem: NSRect, batt: NSRect) {
        let w = bounds.width, half = (w - 8) / 2
        return (NSRect(x: 0, y: 0, width: half, height: 124), NSRect(x: half + 8, y: 0, width: half, height: 124),
                NSRect(x: 0, y: 132, width: w, height: 112),
                NSRect(x: 0, y: 252, width: half, height: 100), NSRect(x: half + 8, y: 252, width: half, height: 100))
    }

    override func layout() {
        super.layout()
        let n = rects.net
        let bw = max(132, speedButton.fittedWidth)
        speedButton.frame = NSRect(x: n.maxX - 14 - bw, y: n.maxY - 14 - 32, width: bw, height: 32)
    }

    private func card(_ r: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l, yRadius: Radius.l)
        p.surfaceRow.setFill(); path.fill()
        p.divider.setStroke(); path.lineWidth = 1; path.stroke()
    }

    /// Faint graph paper behind a chart.
    private func grid(_ r: NSRect) {
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        Pal.field.withAlphaComponent(0.6).setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        Pal.text.withAlphaComponent(0.035).setFill()
        var x = r.minX + 20
        while x < r.maxX { NSRect(x: x, y: r.minY, width: 1, height: r.height).fill(); x += 20 }
        var y = r.minY + 12
        while y < r.maxY { NSRect(x: r.minX, y: y, width: r.width, height: 1).fill(); y += 12 }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func bigRing(_ r: NSRect, _ progress: Double, _ text: String, _ label: String, _ color: NSColor) {
        let c = NSPoint(x: r.minX + 14 + 38, y: r.midY)
        VDraw.ring(center: c, radius: 32, width: 6, progress: progress, color: color)
        let f = TaskFont.clock(22)
        let tw = VDraw.width(text, f)
        VDraw.text(text, f, Pal.text, at: NSPoint(x: c.x - tw / 2, y: c.y - 14))
        let l = Typo.sectionText(label)
        l.draw(at: NSPoint(x: c.x - l.size().width / 2, y: c.y + 9))
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal, vs = SystemVitals.shared, s = vs.now
        let v = tween.values.count == 9 ? tween.values : Array(repeating: 0, count: 9)
        // Rings, bars and graphs glide (v); the numbers show the reading they're heading to (t).
        let t = tween.to.count == 9 ? tween.to : v
        let R = rects

        // CPU: ring and a bar per core.
        card(R.cpu)
        bigRing(R.cpu, v[0], "\(Int((t[0] * 100).rounded()))%", "CPU", p.vCPU)
        let bx = R.cpu.minX + 14 + 76 + 14, bw = R.cpu.maxX - 14 - bx
        let cores = coreTween.values
        if !cores.isEmpty {
            let gap: CGFloat = cores.count > 12 ? 2 : 4
            let cw = (bw - gap * CGFloat(cores.count - 1)) / CGFloat(cores.count)
            for (i, c) in cores.enumerated() {
                let h = max(3, 56 * CGFloat(c))
                (c > 0.75 ? p.vGPU : p.vCPU).setFill()
                NSBezierPath(roundedRect: NSRect(x: bx + CGFloat(i) * (cw + gap), y: R.cpu.minY + 22 + 56 - h, width: cw, height: h), xRadius: min(3, cw / 2), yRadius: min(3, cw / 2)).fill()
            }
        }
        VDraw.text("\(cores.count) cores · load \(String(format: "%.1f", s.load))", Typo.caption, p.textTertiary, at: NSPoint(x: bx, y: R.cpu.minY + 22 + 56 + 10))

        // GPU: ring and the last minute.
        card(R.gpu)
        bigRing(R.gpu, v[1], s.gpu == nil ? "—" : "\(Int((t[1] * 100).rounded()))%", "GPU", p.vGPU)
        let gx = R.gpu.minX + 14 + 76 + 14
        let gr = NSRect(x: gx, y: R.gpu.minY + 22, width: R.gpu.maxX - 14 - gx, height: 56)
        grid(gr)
        VDraw.spark(vs.gpuHistory, in: gr.insetBy(dx: 2, dy: 2), max: 1, color: p.vGPU, area: true)
        VDraw.text(s.gpu == nil ? "Not reported on this Mac" : "Last minute", Typo.caption, p.textTertiary, at: NSPoint(x: gx, y: gr.maxY + 10))

        // Network: now, the last minute, and the speed test.
        card(R.net)
        let nx = R.net.minX + 14
        VDraw.label(s.wifiLink == nil ? "Network now" : "Wi-Fi now", at: NSPoint(x: nx, y: R.net.minY + 14), color: p.textSecondary)
        let d = VitalsFormat.rate(t[2]), u = VitalsFormat.rate(t[3])
        let big = TaskFont.clock(26)
        VDraw.text(d.0, big, p.vNet, at: NSPoint(x: nx, y: R.net.minY + 32))
        VDraw.text("\(d.1) ↓", Typo.caption, p.textSecondary, at: NSPoint(x: nx + VDraw.width(d.0, big) + 4, y: R.net.minY + 44))
        let small = TaskFont.clock(16)
        VDraw.text(u.0, small, p.vMemory, at: NSPoint(x: nx, y: R.net.minY + 68))
        let link = s.wifiLink.map { " · link \(Int($0)) Mb/s" } ?? ""
        VDraw.text("\(u.1) ↑\(link)", Typo.caption, p.textSecondary, at: NSPoint(x: nx + VDraw.width(u.0, small) + 4, y: R.net.minY + 72))
        let right: CGFloat = 160
        let chart = NSRect(x: nx + 150, y: R.net.minY + 14, width: R.net.maxX - 14 - right - 16 - (nx + 150), height: R.net.height - 28)
        grid(chart)
        let peak = max(1e6, (vs.downHistory + vs.upHistory).max() ?? 1)
        VDraw.spark(vs.downHistory, in: chart.insetBy(dx: 2, dy: 3), max: peak, color: p.vNet, area: true)
        VDraw.spark(vs.upHistory, in: chart.insetBy(dx: 2, dy: 3), max: peak, color: p.vMemory, dashed: true, width: 1.2)
        let sx = R.net.maxX - 14 - right
        VDraw.label("Internet speed", at: NSPoint(x: sx, y: R.net.minY + 14))
        let lines: String
        if vs.speedTesting { lines = "Testing your connection…\nabout 20 seconds" }
        else if let e = vs.speedError { lines = e }
        else if let r = vs.lastSpeed {
            let rd = VitalsFormat.rate(r.down), ru = VitalsFormat.rate(r.up)
            lines = "↓ \(rd.0) · ↑ \(ru.0) \(ru.1)" + (r.latency.map { "\n\(Int($0)) ms · \(relativeTime(r.at))" } ?? "\n\(relativeTime(r.at))")
        } else { lines = "Runs only when you ask" }
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 2
        NSAttributedString(string: lines, attributes: [.font: Typo.caption, .foregroundColor: p.textSecondary, .paragraphStyle: ps])
            .draw(in: NSRect(x: sx, y: R.net.minY + 32, width: right, height: 32))
        if vs.speedTesting {
            // An indeterminate bar where the button was.
            let track = NSRect(x: sx, y: R.net.maxY - 14 - 18, width: right, height: 4)
            p.field.setFill(); NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let seg = track.width * 0.35
            let x = track.minX - seg + (track.width + seg) * (spinPhase.truncatingRemainder(dividingBy: 1))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).addClip()
            p.accent.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: track.minY, width: seg, height: 4), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Memory by kind.
        card(R.mem)
        let mx = R.mem.minX + 14, mw = R.mem.width - 28
        VDraw.label("Memory", at: NSPoint(x: mx, y: R.mem.minY + 14), color: p.textSecondary)
        let pressure: (String, NSColor) = s.pressure == .critical ? ("pressure high", p.danger) : (s.pressure == .warning ? ("pressure medium", p.warning) : ("pressure low", p.success))
        VDraw.text(pressure.0, Typo.caption, pressure.1, at: NSPoint(x: mx + Typo.sectionText("Memory").size().width + 8, y: R.mem.minY + 13))
        let used = t[4] + t[5] + t[6]
        let mf = TaskFont.clock(18)
        let total = " of \(Int((s.memTotal / 1_073_741_824).rounded())) GB"
        let usedText = VitalsFormat.gb(used)
        let tw = VDraw.width(usedText, mf) + VDraw.width(total, Typo.caption) + 2
        VDraw.text(usedText, mf, p.text, at: NSPoint(x: R.mem.maxX - 14 - tw, y: R.mem.minY + 10))
        VDraw.text(total, Typo.caption, p.textSecondary, at: NSPoint(x: R.mem.maxX - 14 - VDraw.width(total, Typo.caption), y: R.mem.minY + 15))
        let barR = NSRect(x: mx, y: R.mem.minY + 44, width: mw, height: 10)
        p.field.setFill(); NSBezierPath(roundedRect: barR, xRadius: 5, yRadius: 5).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: barR, xRadius: 5, yRadius: 5).addClip()
        let kinds: [(Double, NSColor, String)] = [(v[4], p.vMemory, "Apps"), (v[5], p.vMemory.blended(withFraction: 0.3, of: .black) ?? p.vMemory, "Wired"),
                                                  (v[6], p.vMemory.blended(withFraction: 0.55, of: .black) ?? p.vMemory, "Compressed")]
        var x = barR.minX
        for (b, c, _) in kinds where s.memTotal > 0 {
            let w = barR.width * CGFloat(b / s.memTotal)
            c.setFill(); NSRect(x: x, y: barR.minY, width: w, height: barR.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
        var lx = mx
        for (_, c, name) in kinds {
            c.setFill(); NSBezierPath(roundedRect: NSRect(x: lx, y: R.mem.minY + 72, width: 7, height: 7), xRadius: 2, yRadius: 2).fill()
            VDraw.text(name, Typo.caption, p.textSecondary, at: NSPoint(x: lx + 11, y: R.mem.minY + 68))
            lx += 11 + VDraw.width(name, Typo.caption) + 12
        }

        // Battery (or, on a desktop, how long the Mac has been up).
        card(R.batt)
        let ax = R.batt.minX + 14
        if let b = s.battery {
            VDraw.battery(in: NSRect(x: ax, y: R.batt.midY - 14, width: 58, height: 28), level: v[7] / 100, color: p.vBattery(b), charging: b.charging)
            let tx = ax + 58 + 14
            VDraw.text("\(Int(t[7].rounded()))%", TaskFont.clock(22), p.text, at: NSPoint(x: tx, y: R.batt.minY + 18))
            let state: String
            if b.charging { state = b.toFull.map { "Charging · full in \(VitalsFormat.minutes($0))" } ?? "Charging" }
            else if b.onPower { state = "On power" }
            else { state = b.toEmpty.map { "\(VitalsFormat.minutes($0)) left" } ?? "On battery" }
            let watts = t[8] > 0.05 ? String(format: " · %.1f W", t[8]) : ""
            VDraw.text(state + watts, Typo.meta, b.charging || b.onPower ? p.success : p.textSecondary, at: NSPoint(x: tx, y: R.batt.minY + 48))
            var facts: [String] = []
            if let h = b.health { facts.append("Health \(Int((h * 100).rounded()))%") }
            if let c = b.cycles { facts.append("\(c) cycles") }
            VDraw.text(facts.joined(separator: " · "), Typo.caption, p.textTertiary, at: NSPoint(x: tx, y: R.batt.minY + 68))
        } else {
            VDraw.label("Uptime", at: NSPoint(x: ax, y: R.batt.minY + 14), color: p.textSecondary)
            VDraw.text(VitalsFormat.duration(s.uptime), TaskFont.clock(22), p.text, at: NSPoint(x: ax, y: R.batt.minY + 36))
            VDraw.text("On power · no battery", Typo.caption, p.textTertiary, at: NSPoint(x: ax, y: R.batt.minY + 68))
        }
    }
}
