import AppKit

// MARK: - Signal chrome
//
// The pieces that make a surface read as a Ghostty X pane, shared by every screen:
//
//   SignalPaneLayer   the focused-pane frame: hairline in the signal colour, soft glow, corner
//                     brackets and the port the trace plugs into; `sweep()` scans it once.
//   SignalTraceLayer  the lit line from Zera through the selected tab into the pane's port, with
//                     a pulse travelling along it.
//   SignalDraw        drawing helpers for views that paint themselves: index tile, key cap,
//                     brackets, tracked section label, status dot.
//
// All Core Animation or plain drawing; the only running animation is the trace pulse, which
// stops whenever its owner hides it, and none run under Reduce Motion.

enum Signal {
    /// The signal colour: the theme's accent (Tidal mint in the Signal theme).
    static var color: NSColor { ThemeStore.shared.current.accent }
    /// Item colours for things that need their own (sessions, projects, calendars, sites),
    /// in Ghostty X's tab order.
    static let itemColors: [NSColor] = ["#7BE1C2", "#9B8DF9", "#EE7991", "#5AB8FF", "#FFC35A", "#B6F36A"]
        .compactMap { NSColor(themeHex: $0) }
    static func itemColor(_ i: Int) -> NSColor { itemColors[((i % itemColors.count) + itemColors.count) % itemColors.count] }
    /// Faint ink for decoration only (labels, sizes, rulers).
    static var faint: NSColor {
        let t = ThemeStore.shared.current
        return t.textTertiary.blended(withFraction: 0.35, of: t.glassBottom) ?? t.textTertiary
    }
    static let bracket: CGFloat = 13
    static let paneRadius: CGFloat = 10
}

// MARK: Pane frame

final class SignalPaneLayer: CALayer {
    enum Side { case left, right, none }

    private let glow = CAShapeLayer()
    private let line = CAShapeLayer()
    private let brackets = CAShapeLayer()
    private let port = CAShapeLayer()
    private let scanHost = CALayer()
    private let scan = CAGradientLayer()
    private(set) var rect: CGRect = .zero
    private(set) var side: Side = .left

    var color: NSColor = Signal.color { didSet { recolor() } }

    override init() {
        super.init()
        masksToBounds = false
        for s in [glow, line, brackets, port] {
            s.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            s.lineJoin = .round; s.lineCap = .round
            addSublayer(s)
        }
        glow.fillColor = nil; glow.lineWidth = 1
        glow.shadowOffset = .zero; glow.shadowRadius = 16; glow.shadowOpacity = 0.55
        line.fillColor = nil; line.lineWidth = 1
        brackets.fillColor = nil; brackets.lineWidth = 2
        brackets.shadowOffset = .zero; brackets.shadowRadius = 3; brackets.shadowOpacity = 0.9
        port.shadowOffset = .zero; port.shadowRadius = 5; port.shadowOpacity = 1
        scanHost.masksToBounds = true
        scanHost.addSublayer(scan)
        addSublayer(scanHost)
        recolor()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private func recolor() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.strokeColor = color.withAlphaComponent(0.18).cgColor
        glow.shadowColor = color.cgColor
        line.strokeColor = color.withAlphaComponent(0.42).cgColor
        brackets.strokeColor = color.cgColor
        brackets.shadowColor = color.cgColor
        port.fillColor = color.cgColor
        port.shadowColor = color.cgColor
        scan.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.12).cgColor, color.withAlphaComponent(0.6).cgColor]
        CATransaction.commit()
    }

    /// Places the frame at `r` (this layer's coordinates, flipped like its owner) with the port
    /// on `side`. Geometry only; no animation.
    func update(rect r: CGRect, side s: Side, flipped: Bool = true) {
        rect = r; side = s
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let rr = Signal.paneRadius
        let outline = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: rr, cornerHeight: rr, transform: nil)
        glow.path = outline
        glow.shadowPath = outline.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 1)
        line.path = outline
        let bp = Self.bracketPath(r, arm: Signal.bracket, radius: rr)
        brackets.path = bp
        brackets.shadowPath = bp.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        let top = flipped ? r.minY + 9 : r.maxY - 16
        let px = s == .right ? r.maxX - 3.5 : r.minX - 3.5
        port.path = s == .none ? nil : CGPath(ellipseIn: CGRect(x: px, y: top, width: 7, height: 7), transform: nil)
        port.shadowPath = port.path
        scanHost.frame = r
        scanHost.cornerRadius = rr
        scan.frame = CGRect(x: 0, y: -70, width: r.width, height: 70)
        CATransaction.commit()
    }

    /// The four corner brackets of `r`, each an arc with two short arms.
    static func bracketPath(_ r: CGRect, arm a: CGFloat, radius rr: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let x0 = r.minX - 1, x1 = r.maxX + 1, y0 = r.minY - 1, y1 = r.maxY + 1
        p.move(to: CGPoint(x: x0, y: y0 + a)); p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + a, y: y0), radius: rr); p.addLine(to: CGPoint(x: x0 + a, y: y0))
        p.move(to: CGPoint(x: x1 - a, y: y0)); p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + a), radius: rr); p.addLine(to: CGPoint(x: x1, y: y0 + a))
        p.move(to: CGPoint(x: x1, y: y1 - a)); p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - a, y: y1), radius: rr); p.addLine(to: CGPoint(x: x1 - a, y: y1))
        p.move(to: CGPoint(x: x0 + a, y: y1)); p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - a), radius: rr); p.addLine(to: CGPoint(x: x0, y: y1 - a))
        return p
    }

    /// The pane takes focus: a band of the signal colour scans down it once.
    func sweep() {
        guard !Motion.reduced, rect.height > 0 else { return }
        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = -35; move.toValue = rect.height + 35
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.6, 1]
        let g = CAAnimationGroup()
        g.animations = [move, fade]; g.duration = 0.75
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scan.opacity = 0
        scan.add(g, forKey: "sweep")
    }

    /// Brackets close in from a few points out, as in Ghostty X when a pane takes focus.
    func snapBrackets() {
        guard !Motion.reduced else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0; a.toValue = 1; a.duration = 0.35
        brackets.add(a, forKey: "snap")
        port.add(a, forKey: "snap")
    }
}

// MARK: Trace

final class SignalTraceLayer: CALayer {
    private let base = CAShapeLayer()
    /// The pulse's glow: a wider, faint copy of the dash. No layer shadow, so nothing renders offscreen.
    private let halo = CAShapeLayer()
    private let pulse = CAShapeLayer()
    private var running = false
    private static let dash: [NSNumber] = [14, 190]

    var color: NSColor = Signal.color { didSet { applyColor() } }

    private func applyColor() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.strokeColor = color.withAlphaComponent(0.45).cgColor
        pulse.strokeColor = color.cgColor
        halo.strokeColor = color.withAlphaComponent(0.22).cgColor
        CATransaction.commit()
    }

    override init() {
        super.init()
        masksToBounds = false
        for s in [base, halo, pulse] {
            s.fillColor = nil; s.lineCap = .round; s.lineJoin = .round
            s.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            addSublayer(s)
        }
        base.lineWidth = 1
        pulse.lineWidth = 1.6
        pulse.lineDashPattern = Self.dash
        halo.lineWidth = 6
        halo.lineDashPattern = [16, 188]
        halo.lineDashPhase = 1
        applyColor()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setPath(_ p: CGPath?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.path = p; halo.path = p; pulse.path = p
        CATransaction.commit()
    }

    /// Runs the pulse while visible; stops it (and every animation) otherwise.
    func setRunning(_ on: Bool) {
        let want = on && !Motion.reduced
        pulse.isHidden = !want
        halo.isHidden = !want
        guard want != running else { return }
        running = want
        pulse.removeAnimation(forKey: "flow")
        halo.removeAnimation(forKey: "flow")
        guard want else { return }
        let flow = CABasicAnimation(keyPath: "lineDashPhase")
        flow.fromValue = 0; flow.toValue = -204
        flow.duration = 2.2; flow.repeatCount = .infinity
        pulse.add(flow, forKey: "flow")
        let glow = flow.copy() as! CABasicAnimation
        glow.fromValue = 1; glow.toValue = -203
        halo.add(glow, forKey: "flow")
    }

    /// The design's route: from Zera along the tab row to the tab, down past it, along to the
    /// gutter beside the pane, down to the port, and into the pane. Flipped coordinates.
    static func route(from zeraX: CGFloat, tab: CGRect, pane: CGRect, side: SignalPaneLayer.Side, gutter: CGFloat = 7) -> CGPath {
        let p = CGMutablePath(), r: CGFloat = 6
        let left = side != .right
        let s: CGFloat = left ? -1 : 1
        let ty = tab.midY, tx = tab.midX
        let y2 = tab.maxY + 7
        let gx = left ? pane.minX - gutter : pane.maxX + gutter
        let px = left ? pane.minX : pane.maxX
        let py = pane.minY + 12.5
        p.move(to: CGPoint(x: zeraX, y: ty))
        p.addLine(to: CGPoint(x: tx, y: ty))
        guard py - y2 > 2 * r else { return p }
        p.addLine(to: CGPoint(x: tx, y: y2 - r))
        p.addQuadCurve(to: CGPoint(x: tx + s * r, y: y2), control: CGPoint(x: tx, y: y2))
        p.addLine(to: CGPoint(x: gx - s * r, y: y2))
        p.addQuadCurve(to: CGPoint(x: gx, y: y2 + r), control: CGPoint(x: gx, y: y2))
        p.addLine(to: CGPoint(x: gx, y: py - r))
        p.addQuadCurve(to: CGPoint(x: gx - s * r, y: py), control: CGPoint(x: gx, y: py))
        p.addLine(to: CGPoint(x: px, y: py))
        return p
    }
}

// MARK: Drawing helpers

enum SignalDraw {
    /// A numbered (or lettered) tile: tinted with `color`, or filled when `filled`.
    static func indexTile(_ text: String, in r: NSRect, color: NSColor, filled: Bool = false, radius: CGFloat? = nil) {
        let rr = radius ?? max(5, r.height * 0.28)
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: rr, yRadius: rr)
        if filled {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow(); glow.shadowColor = color.withAlphaComponent(0.7); glow.shadowBlurRadius = 10; glow.set()
            color.setFill(); path.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            color.withAlphaComponent(0.11).setFill(); path.fill()
            color.withAlphaComponent(0.3).setStroke(); path.lineWidth = 1; path.stroke()
        }
        guard !text.isEmpty else { return }
        // Longer ids ("1234") shrink to fit the tile rather than spill out of it.
        var size = max(8, r.height * 0.4)
        let room = r.width - 6
        let natural = (text as NSString).size(withAttributes: [.font: ZFont.mono(ofSize: size, weight: .bold)]).width
        if natural > room, natural > 0 { size = max(7, size * room / natural) }
        let font = ZFont.mono(ofSize: size, weight: .bold)
        let ink = filled ? ThemeStore.shared.current.glassBottom : color
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let s = (text as NSString).size(withAttributes: a)
        (text as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: a)
    }

    /// A key cap ("⌘K", "esc"); returns its width. `lit` uses the signal colour.
    @discardableResult
    static func keycap(_ text: String, at p: NSPoint, height: CGFloat = 16, lit: Bool = false) -> CGFloat {
        let t = ThemeStore.shared.current
        let font = ZFont.mono(ofSize: 10, weight: .medium)
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: lit ? t.text : t.textSecondary]
        let s = (text as NSString).size(withAttributes: a)
        let r = NSRect(x: p.x, y: p.y, width: ceil(s.width) + 10, height: height)
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        if lit { t.accent.withAlphaComponent(0.08).setFill(); path.fill() }
        (lit ? t.accent.withAlphaComponent(0.35) : t.border.withAlphaComponent(min(1, t.border.alphaComponent * 2))).setStroke()
        path.lineWidth = 1; path.stroke()
        (text as NSString).draw(at: NSPoint(x: r.minX + 5, y: r.midY - s.height / 2), withAttributes: a)
        return r.width
    }

    /// Corner brackets round `r` (focus on an input block, a selected card).
    static func brackets(_ r: NSRect, color: NSColor = Signal.color, arm: CGFloat = 11, radius: CGFloat = 6, width: CGFloat = 1.6) {
        let b = r.insetBy(dx: 1, dy: 1), a = min(arm, b.width / 2, b.height / 2)
        let path = NSBezierPath()
        let corners: [(NSPoint, NSPoint, NSPoint)] = [
            (NSPoint(x: b.minX, y: b.minY + a), NSPoint(x: b.minX, y: b.minY), NSPoint(x: b.minX + a, y: b.minY)),
            (NSPoint(x: b.maxX - a, y: b.minY), NSPoint(x: b.maxX, y: b.minY), NSPoint(x: b.maxX, y: b.minY + a)),
            (NSPoint(x: b.maxX, y: b.maxY - a), NSPoint(x: b.maxX, y: b.maxY), NSPoint(x: b.maxX - a, y: b.maxY)),
            (NSPoint(x: b.minX + a, y: b.maxY), NSPoint(x: b.minX, y: b.maxY), NSPoint(x: b.minX, y: b.maxY - a))]
        for (start, corner, end) in corners {
            path.move(to: start)
            path.appendArc(from: corner, to: end, radius: min(radius, a))
            path.line(to: end)
        }
        path.lineWidth = width; path.lineCapStyle = .round
        color.setStroke(); path.stroke()
    }

    /// The Ghostty X input block: a faint wash, a hairline, corner brackets in the signal colour
    /// and a lit prompt caret (›) in `caretIn`. Used for every "type here" field (Tasks, Focus,
    /// Quick add) so they all read as the terminal's prompt.
    static func inputBlock(_ r: NSRect, caretIn c: NSRect?, radius: CGFloat = 7) {
        let t = ThemeStore.shared.current
        let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        t.accent.withAlphaComponent(0.05).setFill(); box.fill()
        t.accent.withAlphaComponent(0.16).setStroke(); box.lineWidth = 1; box.stroke()
        brackets(r, color: t.accent, arm: min(11, r.height / 3), radius: max(3, radius - 1), width: 1.6)
        guard let c else { return }
        let mid = NSPoint(x: c.midX, y: c.midY), s: CGFloat = 4.5
        let caret = NSBezierPath()
        caret.move(to: NSPoint(x: mid.x - s * 0.5, y: mid.y - s))
        caret.line(to: NSPoint(x: mid.x + s * 0.5, y: mid.y))
        caret.line(to: NSPoint(x: mid.x - s * 0.5, y: mid.y + s))
        caret.lineWidth = 2.2; caret.lineCapStyle = .round; caret.lineJoinStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow(); glow.shadowColor = t.accent.withAlphaComponent(0.8); glow.shadowBlurRadius = 5; glow.set()
        t.accent.setStroke(); caret.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A tracked, upper-case section label ("SESSIONS  03").
    static func label(_ text: String, count: String? = nil, color: NSColor? = nil) -> NSAttributedString {
        let t = ThemeStore.shared.current
        let out = NSMutableAttributedString(string: text.uppercased(), attributes: [
            .font: ZFont.mono(ofSize: 10, weight: .medium), .foregroundColor: color ?? Signal.faint, .kern: 0.8])
        if let count {
            out.append(NSAttributedString(string: "  " + count, attributes: [
                .font: ZFont.mono(ofSize: 10, weight: .medium), .foregroundColor: t.textSecondary, .kern: 0.8]))
        }
        return out
    }

    /// A status dot; `pulse` draws the outer ring a running item has.
    static func dot(at c: NSPoint, color: NSColor, radius: CGFloat = 3, ring: Bool = false) {
        if ring {
            color.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - radius * 2, y: c.y - radius * 2, width: radius * 4, height: radius * 4)).fill()
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
}

// MARK: Status line

/// The strip under the open screen, as in Ghostty X: "● LIVE", the screen, then the keys that
/// work there and the time. Drawn once per change; a slow timer (only while shown) keeps the
/// clock current. Never takes a click.
final class SignalStatusLine: NSView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var hints: [(key: String, label: String)] = [] { didSet { needsDisplay = true } }
    private var timer: Timer?
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setRunning(_ on: Bool) {
        if on {
            guard timer == nil else { return }
            let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.needsDisplay = true }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            timer = t
            needsDisplay = true
        } else {
            timer?.invalidate(); timer = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setRunning(false) }
    }

    deinit { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        let t = ThemeStore.shared.current
        // The pane's bottom edge (3 pt down) is the divider; centre the line in the room below it.
        let mid = ((bounds.height + 4) / 2).rounded() + 0.5
        var x: CGFloat = 22
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow(); glow.shadowColor = t.accent; glow.shadowBlurRadius = 6; glow.set()
        SignalDraw.dot(at: NSPoint(x: x + 3, y: mid), color: t.accent)
        NSGraphicsContext.restoreGraphicsState()
        x += 13
        let strong: [NSAttributedString.Key: Any] = [.font: ZFont.mono(ofSize: 10, weight: .semibold), .foregroundColor: t.accent, .kern: 0.5]
        let live = NSAttributedString(string: "LIVE", attributes: strong)
        let ls = live.size()
        live.draw(at: NSPoint(x: x, y: mid - ls.height / 2))
        x += ceil(ls.width) + 16
        let quiet: [NSAttributedString.Key: Any] = [.font: ZFont.mono(ofSize: 10, weight: .medium), .foregroundColor: Signal.faint, .kern: 0.5]
        let dim: [NSAttributedString.Key: Any] = [.font: ZFont.mono(ofSize: 10, weight: .medium), .foregroundColor: t.textSecondary, .kern: 0.3]
        // Right side first, so the title can truncate before it.
        var r = bounds.width - 22
        let time = NSAttributedString(string: Self.clock.string(from: Date()), attributes: dim)
        let tsz = time.size()
        r -= ceil(tsz.width)
        time.draw(at: NSPoint(x: r, y: mid - tsz.height / 2))
        r -= 16
        for h in hints.reversed() {
            let label = NSAttributedString(string: h.label, attributes: quiet)
            let lsz = label.size()
            let keyW = ceil((h.key as NSString).size(withAttributes: [.font: ZFont.mono(ofSize: 10, weight: .medium)]).width) + 10
            let need = ceil(lsz.width) + 6 + keyW
            guard r - need > x + 80 else { break }
            r -= ceil(lsz.width)
            label.draw(at: NSPoint(x: r, y: mid - lsz.height / 2))
            r -= 6 + keyW
            SignalDraw.keycap(h.key, at: NSPoint(x: r, y: mid - 8))
            r -= 14
        }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        var titleAttrs = quiet; titleAttrs[.paragraphStyle] = para
        let tt = NSAttributedString(string: title.uppercased(), attributes: titleAttrs)
        let th = tt.size().height
        tt.draw(in: NSRect(x: x, y: mid - th / 2, width: max(0, r - x - 8), height: th + 1))
    }
}

// MARK: Input view

/// `SignalDraw.inputBlock` as a view, for layouts built from views (the app opener's search).
/// Draws the wash, hairline and corner brackets; `caret` adds the lit ">" prompt at the left.
final class SignalInputView: NSView {
    var caret = false { didSet { needsDisplay = true } }
    var radius: CGFloat = 7 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let c = caret ? NSRect(x: 12, y: bounds.midY - 8, width: 14, height: 16) : nil
        SignalDraw.inputBlock(bounds, caretIn: c, radius: radius)
    }
}
