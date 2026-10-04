import AppKit

/// Claude Code's live readout as two glowing wings hanging off Zera on either side of her
/// rope, laid out like the mock:
///
///   ( ◌ Claude · Ready      (📄)(🔍)(>_)(≣) )~~ Zera ~~( ılıllı Waiting for your next request…  (✦) )
///
/// Left wing — what Claude is doing: a ring (spinning while it works), the headline, the
/// current step and a strip of tool glyphs with the one Claude is using lit up.
/// Right wing — what it means for you: a waveform and "Working on it…", or the command that is
/// waiting on you with Reject / Approve right there.
///
/// One transparent panel spans both wings. The gap in the middle is where she hangs (her window
/// sits above this one) and each wing tapers into a tendril that reaches into her.
final class LiveActivityView: NSView {
    enum Mode: Equatable { case idle, running, approval, attention, done }

    /// Tap a wing: open the session.
    var onTap: (() -> Void)?
    /// Right-click: hide until Claude has something new.
    var onClose: (() -> Void)?
    /// Approve (true) / Reject (false) on the right wing.
    var onDecide: ((HookRequest, Bool) -> Void)?

    static let panelSize = NSSize(width: 1120, height: 84)

    /// Where she hangs, in this view's coordinates. The controller sets it after placing the panel.
    var centerX: CGFloat = LiveActivityView.panelSize.width / 2 { didSet { needsLayout = true; needsDisplay = true } }
    private(set) var mode: Mode = .idle
    private(set) var request: HookRequest?

    /// Wide enough for the command and both buttons; otherwise the approval card takes over.
    var canShowApproval: Bool { rightBody.width >= M.approvalMin }

    private enum M {
        static let wingH: CGFloat = 56
        static let tail: CGFloat = 62          // body end → her centre
        static let tip: CGFloat = 12           // the tendril ends this far from her centre (behind her)
        static let droop: CGFloat = 8          // tendrils meet her a little below the wings' centre line
        static let edge: CGFloat = 12          // outer margin, room for the glow
        static let leftMax: CGFloat = 440
        static let rightMax: CGFloat = 480
        static let minWing: CGFloat = 200
        static let approvalMin: CGFloat = 360
    }

    // Left wing.
    private let ring = RingGlyph()
    private let leftTitle = LiveActivityView.label(size: 15, weight: .semibold, color: Neon.text)
    private let leftSub = LiveActivityView.label(size: 12, weight: .regular, color: Neon.textDim)
    private let tools = ToolStrip()

    // Right wing.
    private let wave = Waveform()
    private let glyph = BoxGlyph()
    private let rightTitle = LiveActivityView.label(size: 14.5, weight: .medium, color: Neon.text)
    private let rightSub = LiveActivityView.label(size: 12, weight: .regular, color: Neon.textDim)
    private let action = GlowIconButton()
    private let reject = GlowPillButton(title: "Reject", symbol: "xmark", color: Neon.red)
    private let approve = GlowPillButton(title: "Approve", symbol: "checkmark", color: Neon.green)

    private var leftBody = NSRect.zero
    private var rightBody = NSRect.zero
    private var leftPath = NSBezierPath()
    private var rightPath = NSBezierPath()
    private var leftTail = NSBezierPath()
    private var rightTail = NSBezierPath()

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        [ring, leftTitle, leftSub, tools, wave, glyph, rightTitle, rightSub, action, reject, approve].forEach { addSubview($0) }
        action.onTap = { [weak self] in self?.onTap?() }
        reject.onTap = { [weak self] in self?.decide(false) }
        approve.onTap = { [weak self] in self?.decide(true) }
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func label(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.wantsLayer = true
        return l
    }

    private func decide(_ allow: Bool) {
        guard let r = request else { return }
        onDecide?(r, allow)
    }

    // MARK: - Content

    /// Everything from the session and the first pending approval; safe to call every second.
    func update(session s: ClaudeSession?, pending: HookRequest?) {
        request = pending
        let newMode: Mode
        if pending != nil { newMode = .approval }
        else if let s = s {
            switch s.status {
            case .running: newMode = .running
            case .waiting: newMode = .attention
            case .done: newMode = .done
            case .idle, .ended: newMode = .idle
            }
        } else { newMode = .idle }
        let modeChanged = newMode != mode
        mode = newMode

        let elapsed = (s?.promptAt == nil) ? nil : s.map { ClaudeActivityCard.clock($0.elapsed) }
        let current = s?.steps.last(where: { !$0.finished }) ?? s?.steps.last
        let task = s.map { ClaudeActivityService.oneLine($0.title, max: 60) } ?? ""

        // Left wing.
        switch mode {
        case .idle:
            ring.set(.idle)
            set(leftTitle, "Claude · Ready")
            set(leftSub, "Ask me anything…")
            tools.set(symbols: Self.idleTools, active: 0, connected: false)
        case .running:
            ring.set(.spinning)
            set(leftTitle, "Claude is running…")
            let step: String? = current.map { $0.finished ? $0.text : ($0.progressLine.isEmpty ? $0.text : "\($0.text) — \($0.progressLine)") }
            set(leftSub, step ?? (task.isEmpty ? "Thinking…" : task))
            tools.set(symbols: Self.runTools, active: Self.toolIndex(for: current?.kind), connected: true)
        case .approval:
            ring.set(.spinning)
            set(leftTitle, "Claude is running…")
            set(leftSub, pending?.detail.map { ClaudeActivityService.oneLine($0, max: 60) }
                ?? (task.isEmpty ? "Paused on your OK to continue." : task))
            let git = pending?.command.hasPrefix("git") ?? false
            tools.set(symbols: ["doc.text", "magnifyingglass", git ? "arrow.triangle.branch" : "terminal", "cylinder.split.1x2"],
                      active: 2, connected: true)
        case .attention:
            ring.set(.waiting)
            set(leftTitle, "Claude needs you")
            set(leftSub, task.isEmpty ? "Waiting for your reply." : task)
            tools.set(symbols: Self.runTools, active: nil, connected: true)
        case .done:
            ring.set(.done)
            set(leftTitle, "Claude · Done")
            set(leftSub, task.isEmpty ? "All finished." : task)
            tools.set(symbols: Self.runTools, active: nil, connected: true)
        }

        // Right wing.
        wave.isHidden = mode == .approval || mode == .attention
        glyph.isHidden = !wave.isHidden
        reject.isHidden = mode != .approval
        approve.isHidden = mode != .approval
        action.isHidden = mode == .approval
        switch mode {
        case .idle:
            wave.set(.resting)
            action.symbol = "sparkle"; action.setAccessibilityLabel("Open Claude sessions")
            set(rightTitle, "Waiting for your next request…")
            set(rightSub, "")
        case .running:
            wave.set(.live)
            action.symbol = "chevron.down"; action.setAccessibilityLabel("Open the live session")
            set(rightTitle, "Working on it…")
            var sub: String
            if let eta = s?.eta { sub = "About \(ClaudeActivityCard.clock(eta)) left" }
            else if let s = s, s.hasRealProgress { sub = "\(Int((s.progress * 100).rounded()))% of the plan done" }
            else { sub = "This may take a few minutes." }
            if let e = elapsed { sub += " · \(e)" }
            set(rightSub, sub)
        case .approval:
            glyph.symbol = "chevron.right.2"
            set(rightTitle, "Needs your approval")
            set(rightSub, ClaudeActivityService.oneLine(pending?.command ?? "", max: 80))
        case .attention:
            glyph.symbol = "hand.raised"
            action.symbol = "chevron.down"; action.setAccessibilityLabel("Open the session")
            set(rightTitle, "Needs your attention")
            set(rightSub, "Reply to Claude in \(s?.folderName ?? "the terminal")")
        case .done:
            wave.set(.done)
            action.symbol = "sparkle"; action.setAccessibilityLabel("Open the session")
            set(rightTitle, "All done")
            set(rightSub, elapsed.map { "Finished in \($0)" } ?? "")
        }
        // Approval reads small label → big command; the other modes read big → small.
        rightTitle.font = NSFont.systemFont(ofSize: mode == .approval ? 12 : 14.5, weight: .medium)
        rightTitle.textColor = mode == .approval ? Neon.textDim : Neon.text
        rightSub.font = mode == .approval ? NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
                                          : NSFont.systemFont(ofSize: 12, weight: .regular)
        rightSub.textColor = mode == .approval ? Neon.text : Neon.textDim

        setAccessibilityLabel("Claude — \(leftTitle.stringValue) \(leftSub.stringValue). \(rightTitle.stringValue) \(rightSub.stringValue)")
        needsLayout = true
        if modeChanged { needsDisplay = true }
    }

    private static let idleTools = ["doc.text", "magnifyingglass", "terminal", "cylinder.split.1x2"]
    private static let runTools = ["doc.text", "magnifyingglass", "chevron.left.forwardslash.chevron.right", "terminal", "sparkle"]

    /// Which glyph in `runTools` lights up for the step Claude is on.
    private static func toolIndex(for kind: ActivityStep.Kind?) -> Int? {
        switch kind {
        case .read?: return 0
        case .search?: return 1
        case .edit?: return 2
        case .run?: return 3
        case nil: return nil
        default: return 4
        }
    }

    /// Cross-fades a label only when its text actually changes.
    private func set(_ label: NSTextField, _ text: String) {
        guard label.stringValue != text else { return }
        if !Motion.reduced {
            let t = CATransition(); t.type = .fade; t.duration = 0.25
            label.layer?.add(t, forKey: "text")
        }
        label.stringValue = text
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        let y = ((bounds.height - M.wingH) / 2).rounded()
        let mid = y + M.wingH / 2
        let tipY = mid + M.droop

        let lx1 = centerX - M.tail
        let lx0 = max(M.edge, lx1 - M.leftMax)
        leftBody = NSRect(x: lx0, y: y, width: max(0, lx1 - lx0), height: M.wingH)
        let rx0 = centerX + M.tail
        let rx1 = min(w - M.edge, rx0 + M.rightMax)
        rightBody = NSRect(x: rx0, y: y, width: max(0, rx1 - rx0), height: M.wingH)

        (leftPath, leftTail) = Self.wing(body: leftBody, inward: 1, tip: NSPoint(x: centerX - M.tip, y: tipY))
        (rightPath, rightTail) = Self.wing(body: rightBody, inward: -1, tip: NSPoint(x: centerX + M.tip, y: tipY))

        layoutLeft(mid: mid)
        layoutRight(mid: mid)
        window?.invalidateCursorRects(for: self)
    }

    private func layoutLeft(mid: CGFloat) {
        let b = leftBody
        let show = b.width >= M.minWing
        [ring, leftTitle, leftSub, tools].forEach { $0.isHidden = !show }
        guard show else { return }
        ring.frame = NSRect(x: b.minX + 12, y: mid - 19, width: 38, height: 38)
        let textX = b.minX + 60
        let tw = ToolStrip.width(for: tools.count)
        let toolsX = b.maxX - 4 - tw
        var textW = toolsX - 12 - textX
        if textW < 120 { tools.isHidden = true; textW = b.maxX - 8 - textX }
        tools.frame = NSRect(x: toolsX, y: mid - ToolStrip.height / 2, width: tw, height: ToolStrip.height)
        leftTitle.frame = NSRect(x: textX, y: mid - 20, width: textW, height: 20)
        leftSub.frame = NSRect(x: textX, y: mid + 1, width: textW, height: 17)
    }

    private func layoutRight(mid: CGFloat) {
        let b = rightBody
        let show = b.width >= M.minWing
        [wave, glyph, rightTitle, rightSub, action, reject, approve].forEach { if !show { $0.isHidden = true } }
        guard show else { return }
        let lead = b.minX + 10
        wave.frame = NSRect(x: lead, y: mid - 14, width: 44, height: 28)
        glyph.frame = NSRect(x: lead, y: mid - 22, width: 44, height: 44)
        var trailing = b.maxX - 10
        if mode == .approval {
            let aw = approve.fittedWidth, rw = reject.fittedWidth
            approve.frame = NSRect(x: trailing - aw, y: mid - 20, width: aw, height: 40)
            reject.frame = NSRect(x: approve.frame.minX - 8 - rw, y: mid - 20, width: rw, height: 40)
            trailing = reject.frame.minX
        } else {
            action.frame = NSRect(x: trailing - 40, y: mid - 20, width: 40, height: 40)
            trailing = action.frame.minX
        }
        let textX = lead + 58
        let textW = max(0, trailing - 10 - textX)
        if rightSub.stringValue.isEmpty {
            rightTitle.frame = NSRect(x: textX, y: mid - 10, width: textW, height: 20)
        } else if mode == .approval {
            rightTitle.frame = NSRect(x: textX, y: mid - 20, width: textW, height: 16)
            rightSub.frame = NSRect(x: textX, y: mid - 2, width: textW, height: 20)
        } else {
            rightTitle.frame = NSRect(x: textX, y: mid - 20, width: textW, height: 20)
            rightSub.frame = NSRect(x: textX, y: mid + 1, width: textW, height: 17)
        }
        rightSub.isHidden = rightSub.stringValue.isEmpty
    }

    /// A pill whose inner end swells into a tail and tapers to a point at `tip`.
    /// `inward` is +1 when the tail points right (the left wing), −1 for the right wing.
    private static func wing(body b: NSRect, inward d: CGFloat, tip: NSPoint) -> (NSBezierPath, NSBezierPath) {
        let path = NSBezierPath(), tail = NSBezierPath()
        guard b.width > 0 else { return (path, tail) }
        let r = b.height / 2
        let outer = d > 0 ? b.minX : b.maxX
        let inner = d > 0 ? b.maxX : b.minX
        let cap = outer + d * r
        let top = b.minY, bottom = b.maxY
        let cpOut: CGFloat = 26, cpIn: CGFloat = 34

        path.move(to: NSPoint(x: cap, y: top))
        path.line(to: NSPoint(x: inner, y: top))
        path.curve(to: tip, controlPoint1: NSPoint(x: inner + d * cpOut, y: top),
                   controlPoint2: NSPoint(x: tip.x - d * cpIn, y: tip.y - 1.5))
        path.curve(to: NSPoint(x: inner, y: bottom), controlPoint1: NSPoint(x: tip.x - d * cpIn, y: tip.y + 1.5),
                   controlPoint2: NSPoint(x: inner + d * cpOut, y: bottom))
        path.line(to: NSPoint(x: cap, y: bottom))
        // Round outer end: bottom (90°) → top (270°) through the outer side.
        path.appendArc(withCenter: NSPoint(x: cap, y: b.midY), radius: r, startAngle: 90, endAngle: 270, clockwise: d < 0)
        path.close()

        // The brighter streaks along the tail.
        tail.move(to: NSPoint(x: inner - d * 18, y: top))
        tail.line(to: NSPoint(x: inner, y: top))
        tail.curve(to: tip, controlPoint1: NSPoint(x: inner + d * cpOut, y: top),
                   controlPoint2: NSPoint(x: tip.x - d * cpIn, y: tip.y - 1.5))
        tail.curve(to: NSPoint(x: inner, y: bottom), controlPoint1: NSPoint(x: tip.x - d * cpIn, y: tip.y + 1.5),
                   controlPoint2: NSPoint(x: inner + d * cpOut, y: bottom))
        tail.line(to: NSPoint(x: inner - d * 18, y: bottom))
        return (path, tail)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if leftBody.width >= M.minWing { drawWing(leftPath, tail: leftTail) }
        if rightBody.width >= M.minWing { drawWing(rightPath, tail: rightTail) }
    }

    private func drawWing(_ path: NSBezierPath, tail: NSBezierPath) {
        NSGradient(starting: Neon.fillTop, ending: Neon.fillBottom)?.draw(in: path, angle: -90)

        // Soft outer glow, then a crisp edge on top of it.
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = Neon.glow.withAlphaComponent(0.85)
        glow.shadowBlurRadius = 10
        glow.shadowOffset = .zero
        glow.set()
        Neon.edge.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        Neon.edge.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        // The tendril glows brightest where it reaches her.
        NSGraphicsContext.saveGraphicsState()
        let streak = NSShadow()
        streak.shadowColor = Neon.cyan
        streak.shadowBlurRadius = 6
        streak.shadowOffset = .zero
        streak.set()
        Neon.cyan.withAlphaComponent(0.7).setStroke()
        tail.lineWidth = 1.2
        tail.lineCapStyle = .round
        tail.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Mouse

    /// Whether `p` (view coordinates) is on a wing, with a little slack for the glow.
    func wingContains(_ p: NSPoint) -> Bool {
        onWing(p) || onWing(NSPoint(x: p.x, y: p.y - 4)) || onWing(NSPoint(x: p.x, y: p.y + 4))
    }

    private func onWing(_ p: NSPoint) -> Bool {
        (leftBody.width >= M.minWing && leftPath.contains(p)) || (rightBody.width >= M.minWing && rightPath.contains(p))
    }

    /// Only the wings take clicks; the transparent rest of the panel lets them through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview.map { convert(point, from: $0) } ?? point
        guard onWing(p) else { return nil }
        // Buttons take their own clicks; labels and glyphs hand them to the wing.
        let v = super.hitTest(point)
        return (v is GlowIconButton || v is GlowPillButton) ? v : self
    }

    override func mouseDown(with event: NSEvent) {
        if onWing(convert(event.locationInWindow, from: nil)) { onTap?() }
    }
    override func rightMouseDown(with event: NSEvent) { onClose?() }
    override func resetCursorRects() {
        if leftBody.width >= M.minWing { addCursorRect(leftBody, cursor: .pointingHand) }
        if rightBody.width >= M.minWing { addCursorRect(rightBody, cursor: .pointingHand) }
    }
}

// MARK: - Look

/// The wings keep their own neon-on-navy look in light and dark, like her bubble and pill.
enum Neon {
    static let fillTop = NSColor(srgbRed: 0.045, green: 0.070, blue: 0.190, alpha: 0.97)
    static let fillBottom = NSColor(srgbRed: 0.020, green: 0.030, blue: 0.105, alpha: 0.97)
    static let edge = NSColor(srgbRed: 0.33, green: 0.50, blue: 1.00, alpha: 1)
    static let glow = NSColor(srgbRed: 0.25, green: 0.38, blue: 1.00, alpha: 1)
    static let cyan = NSColor(srgbRed: 0.36, green: 0.76, blue: 1.00, alpha: 1)
    static let violet = NSColor(srgbRed: 0.62, green: 0.45, blue: 1.00, alpha: 1)
    static let text = NSColor(srgbRed: 0.96, green: 0.97, blue: 1.00, alpha: 1)
    static let textDim = NSColor(srgbRed: 0.70, green: 0.75, blue: 0.92, alpha: 1)
    static let glyph = NSColor(srgbRed: 0.55, green: 0.68, blue: 1.00, alpha: 1)
    static let chip = NSColor(srgbRed: 0.060, green: 0.090, blue: 0.250, alpha: 1)
    static let chipLit = NSColor(srgbRed: 0.085, green: 0.150, blue: 0.380, alpha: 1)
    static let red = NSColor(srgbRed: 1.00, green: 0.32, blue: 0.44, alpha: 1)
    static let green = NSColor(srgbRed: 0.22, green: 0.92, blue: 0.70, alpha: 1)

    /// Draws an SF Symbol centred in `rect`.
    static func symbol(_ name: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) else { return }
        let s = img.size
        img.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Runs `body` with a coloured glow behind whatever it draws.
    static func glowing(_ color: NSColor, blur: CGFloat, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = color
        s.shadowBlurRadius = blur
        s.shadowOffset = .zero
        s.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Pieces

/// The ring at the start of the left wing: a dotted-centre ring when idle, a spinning arc while
/// Claude works, an amber ring while it waits on you, a full green ring when done.
final class RingGlyph: NSView {
    enum Style { case idle, spinning, waiting, done }
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let dot = CAShapeLayer()
    private var style: Style?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [track, arc] {
            l.fillColor = NSColor.clear.cgColor
            l.lineWidth = 4
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        track.strokeColor = Neon.edge.withAlphaComponent(0.22).cgColor
        arc.shadowOpacity = 1
        arc.shadowRadius = 4
        arc.shadowOffset = .zero
        layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ st: Style) {
        guard st != style else { return }
        style = st
        let color: NSColor
        switch st {
        case .idle: color = Neon.cyan
        case .spinning: color = Neon.cyan
        case .waiting: color = NSColor(srgbRed: 1.0, green: 0.74, blue: 0.30, alpha: 1)
        case .done: color = Neon.green
        }
        arc.strokeColor = color.cgColor
        arc.shadowColor = color.cgColor
        dot.fillColor = color.cgColor
        dot.shadowColor = color.cgColor
        dot.shadowOpacity = 1
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        arc.strokeEnd = st == .done ? 1 : (st == .spinning ? 0.7 : 0.78)
        dot.isHidden = st == .spinning
        arc.removeAllAnimations()
        if st == .spinning, !Motion.reduced {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi
            a.duration = 1.1; a.repeatCount = .infinity
            arc.add(a, forKey: "spin")
        } else if st == .waiting, !Motion.reduced {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.45; a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
            arc.add(a, forKey: "pulse")
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = bounds
        let ring = CGPath(ellipseIn: b.insetBy(dx: 4, dy: 4), transform: nil)
        for l in [track, arc] { l.frame = b; l.path = ring }
        let d: CGFloat = 9
        dot.frame = b
        dot.path = CGPath(ellipseIn: CGRect(x: b.midX - d / 2, y: b.midY - d / 2, width: d, height: d), transform: nil)
        CATransaction.commit()
    }
}

/// Little equaliser bars: moving while Claude works, resting otherwise, green when done.
final class Waveform: NSView {
    enum Style { case resting, live, done }
    private var bars: [CALayer] = []
    private var style: Style?
    private static let heights: [CGFloat] = [0.35, 0.7, 0.5, 0.95, 0.6, 1.0, 0.55, 0.8, 0.4]
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for _ in Self.heights {
            let b = CALayer()
            b.cornerRadius = 1.5
            b.shadowOpacity = 0.9
            b.shadowRadius = 3
            b.shadowOffset = .zero
            layer?.addSublayer(b)
            bars.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ st: Style) {
        guard st != style else { return }
        style = st
        for (i, b) in bars.enumerated() {
            let c: NSColor
            switch st {
            case .done: c = Neon.green
            case .live: c = i % 3 == 1 ? Neon.violet : Neon.cyan
            case .resting: c = Neon.edge
            }
            b.backgroundColor = c.cgColor
            b.shadowColor = c.cgColor
            b.removeAllAnimations()
            if st == .live, !Motion.reduced {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = 0.3; a.toValue = 1
                a.duration = 0.38 + Double(i % 4) * 0.11
                a.autoreverses = true; a.repeatCount = .infinity
                a.timeOffset = Double(i) * 0.13
                b.add(a, forKey: "bounce")
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let bw: CGFloat = 3, gap: CGFloat = 2
        let total = CGFloat(bars.count) * bw + CGFloat(bars.count - 1) * gap
        var x = (bounds.width - total) / 2
        for (i, b) in bars.enumerated() {
            let h = max(4, bounds.height * Self.heights[i])
            b.frame = CGRect(x: x, y: (bounds.height - h) / 2, width: bw, height: h)
            x += bw + gap
        }
        CATransaction.commit()
    }
}

/// A row of round tool glyphs; the active one glows, rails join them while Claude works.
final class ToolStrip: NSView {
    static let diameter: CGFloat = 32
    static let gap: CGFloat = 10
    static let height: CGFloat = 44         // diameter + room for the glow
    private var symbols: [String] = []
    private var active: Int?
    private var connected = false
    var count: Int { symbols.count }
    override var isFlipped: Bool { true }

    static func width(for n: Int) -> CGFloat {
        n == 0 ? 0 : CGFloat(n) * diameter + CGFloat(n - 1) * gap + 12
    }

    func set(symbols s: [String], active a: Int?, connected c: Bool) {
        guard s != symbols || a != active || c != connected else { return }
        let resized = s.count != symbols.count
        symbols = s; active = a; connected = c
        if resized { superview?.needsLayout = true }
        needsDisplay = true
    }

    private func circle(_ i: Int) -> NSRect {
        NSRect(x: 6 + CGFloat(i) * (Self.diameter + Self.gap), y: (bounds.height - Self.diameter) / 2,
               width: Self.diameter, height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        if connected, symbols.count > 1 {
            Neon.edge.withAlphaComponent(0.6).setStroke()
            for i in 1..<symbols.count {
                let a = circle(i - 1), b = circle(i)
                let rail = NSBezierPath()
                rail.move(to: NSPoint(x: a.maxX, y: a.midY)); rail.line(to: NSPoint(x: b.minX, y: b.midY))
                rail.lineWidth = 1.5
                rail.stroke()
            }
        }
        for (i, name) in symbols.enumerated() {
            let c = circle(i).insetBy(dx: 0.75, dy: 0.75)
            let lit = i == active
            let ring = NSBezierPath(ovalIn: c)
            (lit ? Neon.chipLit : Neon.chip).setFill()
            ring.fill()
            ring.lineWidth = lit ? 1.6 : 1
            if lit {
                Neon.glowing(Neon.cyan, blur: 8) { Neon.cyan.setStroke(); ring.stroke() }
            } else {
                Neon.edge.withAlphaComponent(0.5).setStroke(); ring.stroke()
            }
            Neon.symbol(name, in: c, size: 13, color: lit ? Neon.text : Neon.glyph)
        }
    }
}

/// The rounded square at the start of the right wing when Claude is waiting on you.
final class BoxGlyph: NSView {
    var symbol = "chevron.right.2" { didSet { if symbol != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        let box = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        Neon.chip.setFill(); box.fill()
        box.lineWidth = 1.5
        Neon.glowing(Neon.glow, blur: 6) { Neon.edge.setStroke(); box.stroke() }
        Neon.symbol(symbol, in: r, size: 15, weight: .bold, color: Neon.cyan)
    }
}

/// Round glyph button (✦ / ⌄) at the end of the right wing.
final class GlowIconButton: NSView {
    var onTap: (() -> Void)?
    var symbol = "sparkle" { didSet { if symbol != oldValue { needsDisplay = true } } }
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let c = bounds.insetBy(dx: 4, dy: 4)
        let ring = NSBezierPath(ovalIn: c)
        (hovered ? Neon.chipLit : Neon.chip).setFill(); ring.fill()
        ring.lineWidth = 1.2
        Neon.glowing(Neon.glow.withAlphaComponent(hovered ? 1 : 0.6), blur: hovered ? 9 : 5) {
            Neon.edge.withAlphaComponent(0.8).setStroke(); ring.stroke()
        }
        Neon.symbol(symbol, in: c, size: 13, weight: .bold, color: Neon.cyan)
    }

    override func mouseDown(with event: NSEvent) { onTap?() }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

/// Outlined, glowing "✕ Reject" / "✓ Approve".
final class GlowPillButton: NSView {
    var onTap: (() -> Void)?
    private let title: String
    private let symbol: String
    private let color: NSColor
    private var hovered = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String, symbol: String, color: NSColor) {
        self.title = title; self.symbol = symbol; self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Glow inset + icon + gap + text + padding.
    var fittedWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 4 * 2 + 16 + 16 + 8 + 18
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        let shape = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        color.withAlphaComponent(hovered ? 0.24 : 0.10).setFill(); shape.fill()
        shape.lineWidth = 1.5
        Neon.glowing(color.withAlphaComponent(hovered ? 0.9 : 0.6), blur: hovered ? 10 : 6) {
            color.setStroke(); shape.stroke()
        }
        let icon = NSRect(x: r.minX + 14, y: r.midY - 8, width: 16, height: 16)
        Neon.symbol(symbol, in: icon, size: 13, weight: .bold, color: color)
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let s = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: icon.maxX + 8, y: r.midY - s.height / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { onTap?() }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

/// "● Running" — dot + label in a soft tinted pill.
final class StatusChip: NSView {
    private let label = NSTextField(labelWithString: "")
    private var color: NSColor = .gray
    /// Smaller type and tighter padding for the one-row bar.
    var compact = false {
        didSet { guard compact != oldValue else { return }; label.font = font; needsLayout = true; needsDisplay = true }
    }
    override var isFlipped: Bool { true }

    private var font: NSFont { NSFont.systemFont(ofSize: compact ? 12 : 13, weight: .semibold) }
    private var dotX: CGFloat { compact ? 9 : 11 }      // dot inset; 8pt dot
    private var textX: CGFloat { compact ? 22 : 26 }    // where the label starts
    private var trailing: CGFloat { compact ? 10 : 12 } // after the label
    private var dotSize: CGFloat { compact ? 8 : 9 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 13
        label.font = font
        label.lineBreakMode = .byClipping
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, color c: NSColor) {
        color = c
        label.stringValue = text
        label.textColor = Pal.isDark ? c : (c.blended(withFraction: 0.35, of: .black) ?? c)
        layer?.backgroundColor = c.withAlphaComponent(Pal.isDark ? 0.18 : 0.15).cgColor
        needsDisplay = true; needsLayout = true
    }

    /// Exact width for the current text — dot inset + text + trailing padding, rounded up.
    var fittedWidth: CGFloat {
        ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + textX + trailing
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let th: CGFloat = compact ? 15 : 16
        label.frame = NSRect(x: textX, y: ((bounds.height - th) / 2).rounded(), width: max(0, bounds.width - textX - trailing), height: th)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: dotX, y: bounds.midY - dotSize / 2, width: dotSize, height: dotSize)).fill()
    }
}
