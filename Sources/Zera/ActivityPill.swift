import AppKit

/// Claude Code's live readout as two glass wings hanging off Zera on either side of her rope:
///
///   ( ◯ Claude is working…       (📄) )~~ Zera ~~( Running · 62%  ━━━━━━──   ılıl  (⌄) )
///   ( ◯ Claude is ready          (📄) )~~ Zera ~~( (>_) git commit -m "…"  [✕ Reject] [✓ Approve] (⌄) )
///
/// Left wing — what Claude is doing: a gradient ring (spinning while it works), the headline,
/// the current step and a files button. Right wing — what it means for you: progress while it
/// runs, or the command waiting on you with Reject / Approve right there.
///
/// One transparent panel spans both wings. The gap in the middle is where she hangs (her window
/// sits above this one) and each wing tapers into a tendril that reaches into her. Light and dark
/// follow the app palette.
final class LiveActivityView: NSView {
    enum Mode: Equatable { case idle, running, approval, attention, done }

    /// Tap a wing, the files button or the chevron: open the session.
    var onTap: (() -> Void)?
    /// Right-click: hide until Claude has something new.
    var onClose: (() -> Void)?
    /// Approve (true) / Reject (false) on the right wing.
    var onDecide: ((HookRequest, Bool) -> Void)?

    static let panelSize = NSSize(width: 1280, height: 88)

    /// Where she hangs, in this view's coordinates. The controller sets it after placing the panel.
    var centerX: CGFloat = LiveActivityView.panelSize.width / 2 { didSet { needsLayout = true; needsDisplay = true } }
    private(set) var mode: Mode = .idle
    private(set) var request: HookRequest?

    /// Wide enough for the command and both buttons; otherwise the approval card takes over.
    var canShowApproval: Bool { rightBody.width >= M.approvalMin }

    private enum M {
        static let wingH: CGFloat = 60
        static let tail: CGFloat = 64          // body end → her centre
        static let tip: CGFloat = 12           // the tendril ends this far from her centre (behind her)
        static let droop: CGFloat = 6          // tendrils meet her a little below the wings' centre line
        static let edge: CGFloat = 14          // outer margin, room for the glow
        static let leftMax: CGFloat = 420
        static let rightMax: CGFloat = 560
        static let minWing: CGFloat = 220
        static let approvalMin: CGFloat = 470
        static let button: CGFloat = 44        // round buttons, glow included
    }

    // Left wing.
    private let ring = RingGlyph()
    private let leftTitle = LiveActivityView.label()
    private let leftSub = LiveActivityView.label()
    private let files = GlowIconButton(symbol: "doc.text")

    // Right wing.
    private let status = LiveActivityView.label()
    private let bar = GlowProgressBar()
    private let wave = Waveform()
    private let prompt = BoxGlyph()
    private let command = LiveActivityView.label()
    private let reject = GlowPillButton(title: "Reject", symbol: "xmark", tint: .red)
    private let approve = GlowPillButton(title: "Approve", symbol: "checkmark", tint: .green)
    private let chevron = GlowIconButton(symbol: "chevron.down")

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
        [ring, leftTitle, leftSub, files, status, bar, wave, prompt, command, reject, approve, chevron].forEach { addSubview($0) }
        files.onTap = { [weak self] in self?.onTap?() }
        files.setAccessibilityLabel("Open the session's files")
        chevron.onTap = { [weak self] in self?.onTap?() }
        chevron.setAccessibilityLabel("Open the session")
        reject.onTap = { [weak self] in self?.decide(false) }
        approve.onTap = { [weak self] in self?.decide(true) }
        setAccessibilityRole(.group)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func label() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.wantsLayer = true
        return l
    }

    private func decide(_ allow: Bool) {
        guard let r = request else { return }
        onDecide?(r, allow)
    }

    /// Light ↔ dark: recolour everything.
    func themeChanged() {
        restyle()
        [ring, files, bar, wave, prompt, reject, approve, chevron].forEach { $0.needsDisplay = true }
        ring.refresh(); wave.refresh(); bar.refresh()
        needsDisplay = true
    }

    private func restyle() {
        leftTitle.font = NSFont.systemFont(ofSize: 15.5, weight: .semibold)
        leftTitle.textColor = Neon.text
        leftSub.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        leftSub.textColor = Neon.textDim
        command.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        command.textColor = Neon.text
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

        let elapsed: String? = s?.promptAt == nil ? nil : s.map { ClaudeActivityCard.clock($0.elapsed) }
        let current = s?.steps.last(where: { !$0.finished }) ?? s?.steps.last
        let task = s.map { ClaudeActivityService.oneLine($0.title, max: 60) } ?? ""

        // Left wing.
        switch mode {
        case .idle:
            ring.set(.idle)
            set(leftTitle, "Claude is ready")
            set(leftSub, "Ask me anything…")
        case .running:
            ring.set(.spinning)
            set(leftTitle, "Claude is working…")
            let step: String? = current.map { $0.finished || $0.progressLine.isEmpty ? $0.text : "\($0.text)…" }
            set(leftSub, step ?? (task.isEmpty ? "Thinking…" : task))
        case .approval:
            ring.set(.idle)
            set(leftTitle, "Claude is ready")
            set(leftSub, pending?.detail.map { ClaudeActivityService.oneLine($0, max: 60) }
                ?? (task.isEmpty ? "Waiting on your OK to continue" : task))
        case .attention:
            ring.set(.waiting)
            set(leftTitle, "Claude needs you")
            set(leftSub, task.isEmpty ? "Waiting for your reply" : task)
        case .done:
            ring.set(.done)
            set(leftTitle, "Claude is done")
            set(leftSub, task.isEmpty ? "All finished" : task)
        }

        // Right wing: a status line + bar, or the command with its two buttons.
        let asking = mode == .approval
        [status, bar, wave].forEach { $0.isHidden = asking }
        [prompt, command, reject, approve].forEach { $0.isHidden = !asking }
        let p = s?.progress ?? 0
        switch mode {
        case .idle:
            status.attributedStringValue = Self.statusLine("Ready", detail: "waiting for your next request")
            bar.set(progress: 0, tint: .accent)
            wave.set(.resting)
        case .running:
            // The percentage is only real when Claude keeps a plan; otherwise show the time.
            let real = s?.hasRealProgress ?? false
            status.attributedStringValue = Self.statusLine("Running", detail: real ? "\(Int((p * 100).rounded()))%" : (elapsed ?? "…"),
                                                       strong: true)
            bar.set(progress: p, tint: .accent)
            wave.set(.live)
        case .approval:
            set(command, ClaudeActivityService.oneLine(pending?.command ?? "", max: 80))
            command.toolTip = pending?.command
        case .attention:
            status.attributedStringValue = Self.statusLine("Waiting", detail: "reply in \(s?.folderName ?? "the terminal")", warn: true)
            bar.set(progress: p, tint: .warning)
            wave.set(.resting)
        case .done:
            status.attributedStringValue = Self.statusLine("Done", detail: elapsed ?? "100%", strong: true, good: true)
            bar.set(progress: 1, tint: .success)
            wave.set(.done)
        }

        setAccessibilityLabel(asking
            ? "Claude needs your approval: \(command.stringValue)"
            : "\(leftTitle.stringValue), \(leftSub.stringValue). \(status.stringValue)")
        needsLayout = true
        if modeChanged { needsDisplay = true }
    }

    /// "Running · 62%" — the word in the quiet colour, the detail in the accent.
    private static func statusLine(_ word: String, detail: String, strong: Bool = false, warn: Bool = false, good: Bool = false) -> NSAttributedString {
        let s = NSMutableAttributedString(string: word, attributes: [
            .font: NSFont.systemFont(ofSize: 15.5, weight: .medium), .foregroundColor: Neon.textDim])
        let tint = warn ? Neon.warning : (good ? Neon.green : Neon.accent)
        s.append(NSAttributedString(string: "  ·  ", attributes: [
            .font: NSFont.systemFont(ofSize: 15.5, weight: .bold), .foregroundColor: tint]))
        s.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 15.5, weight: strong ? .semibold : .regular),
            .foregroundColor: strong ? tint : Neon.textDim]))
        return s
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
        [ring, leftTitle, leftSub, files].forEach { $0.isHidden = !show }
        guard show else { return }
        ring.frame = NSRect(x: b.minX + 14, y: mid - 22, width: 44, height: 44)
        files.frame = NSRect(x: b.maxX - 2 - M.button, y: mid - M.button / 2, width: M.button, height: M.button)
        let textX = ring.frame.maxX + 14
        let textW = max(0, files.frame.minX - 10 - textX)
        leftTitle.frame = NSRect(x: textX, y: mid - 21, width: textW, height: 21)
        leftSub.frame = NSRect(x: textX, y: mid + 2, width: textW, height: 18)
    }

    private func layoutRight(mid: CGFloat) {
        let b = rightBody
        let show = b.width >= M.minWing
        if !show { [status, bar, wave, prompt, command, reject, approve, chevron].forEach { $0.isHidden = true }; return }
        chevron.isHidden = false
        chevron.frame = NSRect(x: b.maxX - 10 - M.button, y: mid - M.button / 2, width: M.button, height: M.button)
        if mode == .approval {
            let aw = approve.fittedWidth, rw = reject.fittedWidth
            approve.frame = NSRect(x: chevron.frame.minX - 6 - aw, y: mid - 22, width: aw, height: 44)
            reject.frame = NSRect(x: approve.frame.minX - 6 - rw, y: mid - 22, width: rw, height: 44)
            prompt.frame = NSRect(x: b.minX + 14, y: mid - 22, width: 44, height: 44)
            let cx = prompt.frame.maxX + 12
            command.frame = NSRect(x: cx, y: mid - 10, width: max(0, reject.frame.minX - 10 - cx), height: 20)
        } else {
            wave.frame = NSRect(x: chevron.frame.minX - 18 - 40, y: mid - 14, width: 40, height: 28)
            let sx = b.minX + 26
            let sw = max(0, wave.frame.minX - 24 - sx)
            status.frame = NSRect(x: sx, y: mid - 22, width: sw, height: 21)
            bar.frame = NSRect(x: sx, y: mid + 7, width: min(sw, 340), height: 8)
        }
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
        let cpOut: CGFloat = 30, cpIn: CGFloat = 32

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

        // The tendril: the two curves that sweep into her.
        tail.move(to: NSPoint(x: inner - d * 24, y: top))
        tail.line(to: NSPoint(x: inner, y: top))
        tail.curve(to: tip, controlPoint1: NSPoint(x: inner + d * cpOut, y: top),
                   controlPoint2: NSPoint(x: tip.x - d * cpIn, y: tip.y - 1.5))
        tail.curve(to: NSPoint(x: inner, y: bottom), controlPoint1: NSPoint(x: tip.x - d * cpIn, y: tip.y + 1.5),
                   controlPoint2: NSPoint(x: inner + d * cpOut, y: bottom))
        tail.line(to: NSPoint(x: inner - d * 24, y: bottom))
        return (path, tail)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if leftBody.width >= M.minWing { drawWing(leftPath, tail: leftTail, body: leftBody, inward: 1) }
        if rightBody.width >= M.minWing { drawWing(rightPath, tail: rightTail, body: rightBody, inward: -1) }
    }

    private func drawWing(_ path: NSBezierPath, tail: NSBezierPath, body: NSRect, inward d: CGFloat) {
        // Glass body with a soft halo.
        Neon.glowing(Neon.halo, blur: 16) { Neon.fillBottom.setFill(); path.fill() }
        NSGradient(starting: Neon.fillTop, ending: Neon.fillBottom)?.draw(in: path, angle: -90)

        // Hairline edge.
        Neon.edge.setStroke()
        path.lineWidth = 1.2
        path.stroke()

        // The tendril glows cyan → violet as it reaches her.
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let gradient = NSGradient(colors: [Neon.cyan.withAlphaComponent(0.1), Neon.cyan, Neon.violet]) else { return }
        let from = d > 0 ? body.maxX - 28 : body.minX + 28
        let to = centerX - d * M.tip
        let cg = tail.cgPathCompat
        let passes: [(width: CGFloat, blur: CGFloat, alpha: CGFloat)] = [(5, 8, 0.45), (1.6, 0, 1)]
        for pass in passes {
            ctx.saveGState()
            ctx.addPath(cg)
            ctx.setLineWidth(pass.width)
            ctx.setLineCap(.round)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.setAlpha(pass.alpha)
            gradient.draw(from: NSPoint(x: from, y: 0), to: NSPoint(x: to, y: 0), options: [])
            ctx.restoreGState()
        }
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

private extension NSBezierPath {
    /// `cgPath` only arrived in macOS 14; build it by hand for 13.
    var cgPathCompat: CGPath {
        let path = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo: path.move(to: pts[0])
            case .lineTo: path.addLine(to: pts[0])
            case .curveTo: path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: path.closeSubpath()
            default: break
            }
        }
        return path
    }
}

// MARK: - Look

/// The wings' colours: frosted white glass with a lavender glow in light mode, deep navy glass
/// with blue neon in dark mode — read live from the app palette.
enum Neon {
    private static var dark: Bool { Pal.isDark }
    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static var fillTop: NSColor { dark ? c(0.055, 0.085, 0.215, 0.96) : c(1.0, 1.0, 1.0, 0.95) }
    static var fillBottom: NSColor { dark ? c(0.025, 0.040, 0.125, 0.96) : c(0.940, 0.948, 1.0, 0.95) }
    static var edge: NSColor { dark ? c(0.33, 0.50, 1.0, 0.70) : c(0.62, 0.70, 1.0, 0.55) }
    static var halo: NSColor { dark ? c(0.22, 0.36, 1.0, 0.55) : c(0.55, 0.62, 1.0, 0.30) }
    static var cyan: NSColor { dark ? c(0.30, 0.74, 1.0) : c(0.36, 0.72, 1.0) }
    static var violet: NSColor { c(0.58, 0.40, 1.0) }
    static var accent: NSColor { dark ? c(0.38, 0.72, 1.0) : c(0.16, 0.52, 0.98) }
    static var text: NSColor { dark ? c(0.96, 0.97, 1.0) : c(0.07, 0.09, 0.20) }
    static var textDim: NSColor { dark ? c(0.72, 0.76, 0.92) : c(0.34, 0.38, 0.52) }
    static var glyph: NSColor { dark ? c(0.62, 0.72, 1.0) : c(0.30, 0.42, 0.85) }
    static var chip: NSColor { dark ? c(0.075, 0.105, 0.260) : c(0.945, 0.950, 1.0) }
    static var chipHover: NSColor { dark ? c(0.105, 0.155, 0.360) : c(0.900, 0.915, 1.0) }
    static var chipEdge: NSColor { dark ? c(0.33, 0.50, 1.0, 0.45) : c(0.62, 0.70, 1.0, 0.55) }
    static var track: NSColor { dark ? c(0.16, 0.20, 0.36) : c(0.86, 0.88, 0.96) }
    static var red: NSColor { dark ? c(1.0, 0.32, 0.42) : c(0.93, 0.22, 0.34) }
    static var green: NSColor { dark ? c(0.22, 0.90, 0.68) : c(0.08, 0.70, 0.52) }
    static var warning: NSColor { c(1.0, 0.70, 0.25) }

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

    /// The round chips' look: soft fill, hairline edge, faint glow.
    static func drawChip(_ shape: NSBezierPath, hovered: Bool) {
        glowing(halo.withAlphaComponent(hovered ? 0.8 : 0.4), blur: hovered ? 8 : 5) {
            (hovered ? chipHover : chip).setFill(); shape.fill()
        }
        chipEdge.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

// MARK: - Pieces

/// The ring at the start of the left wing: a thick cyan → violet arc, spinning while Claude
/// works, pulsing amber while it waits on you, a full green ring when done.
final class RingGlyph: NSView {
    enum Style { case idle, spinning, waiting, done }
    private let track = CAShapeLayer()
    private let spinner = CALayer()           // rotates; holds the gradient masked to the arc
    private let gradient = CAGradientLayer()
    private let arc = CAShapeLayer()
    private var style: Style = .idle
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        track.fillColor = NSColor.clear.cgColor
        track.lineWidth = 6
        layer?.addSublayer(track)
        arc.fillColor = NSColor.clear.cgColor
        arc.strokeColor = NSColor.black.cgColor
        arc.lineWidth = 6
        arc.lineCap = .round
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.mask = arc
        spinner.addSublayer(gradient)
        spinner.shadowOpacity = 0.8
        spinner.shadowRadius = 4
        spinner.shadowOffset = .zero
        layer?.addSublayer(spinner)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ st: Style) {
        guard st != style else { return }
        style = st
        refresh()
    }

    /// Colours and motion for the current style and theme.
    func refresh() {
        let colors: [NSColor]
        switch style {
        case .idle, .spinning: colors = [Neon.violet, Neon.cyan, Neon.accent, Neon.violet]
        case .waiting: colors = [Neon.warning, Neon.warning.withAlphaComponent(0.6), Neon.warning]
        case .done: colors = [Neon.green, Neon.green]
        }
        track.strokeColor = Neon.track.cgColor
        gradient.colors = colors.map { $0.cgColor }
        spinner.shadowColor = (style == .done ? Neon.green : (style == .waiting ? Neon.warning : Neon.cyan)).cgColor
        arc.strokeEnd = style == .done ? 1 : 0.78
        spinner.removeAllAnimations()
        guard !Motion.reduced else { return }
        if style == .spinning {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi
            a.duration = 1.2; a.repeatCount = .infinity
            spinner.add(a, forKey: "spin")
        } else if style == .waiting {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.45; a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
            spinner.add(a, forKey: "pulse")
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = bounds
        let ring = CGPath(ellipseIn: b.insetBy(dx: 6, dy: 6), transform: nil)
        track.frame = b; track.path = ring
        spinner.frame = b
        gradient.frame = b
        arc.frame = b; arc.path = ring
        CATransaction.commit()
    }
}

/// Thin rounded progress bar: cyan → violet fill with a soft glow over a quiet track.
final class GlowProgressBar: NSView {
    enum Tint { case accent, warning, success }
    private let fill = CAGradientLayer()
    private var progress: CGFloat = 0
    private var tint: Tint = .accent
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        fill.startPoint = CGPoint(x: 0, y: 0.5); fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.shadowOpacity = 0.7
        fill.shadowRadius = 4
        fill.shadowOffset = .zero
        layer?.addSublayer(fill)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(progress p: Double, tint t: Tint) {
        let np = CGFloat(max(0, min(1, p)))
        guard np != progress || t != tint else { return }
        progress = np
        if t != tint { tint = t; refresh() }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.duration(0.45))
        place()
        CATransaction.commit()
    }

    func refresh() {
        let colors: [NSColor]
        switch tint {
        case .accent: colors = [Neon.cyan, Neon.accent, Neon.violet]
        case .warning: colors = [Neon.warning, Neon.warning]
        case .success: colors = [Neon.green, Neon.green]
        }
        fill.colors = colors.map { $0.cgColor }
        fill.shadowColor = colors[colors.count / 2].cgColor
        layer?.backgroundColor = Neon.track.cgColor
    }

    private func place() {
        let h = bounds.height
        layer?.cornerRadius = h / 2
        fill.cornerRadius = h / 2
        fill.frame = CGRect(x: 0, y: 0, width: progress == 0 ? 0 : max(h, bounds.width * progress), height: h)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); place(); CATransaction.commit()
    }
}

/// Little equaliser bars: moving while Claude works, resting otherwise, green when done.
final class Waveform: NSView {
    enum Style { case resting, live, done }
    private var bars: [CALayer] = []
    private var style: Style = .resting
    private static let heights: [CGFloat] = [0.35, 0.7, 0.45, 1.0, 0.6, 0.85, 0.4]
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for _ in Self.heights {
            let b = CALayer()
            b.cornerRadius = 1.25
            b.shadowOpacity = 0.6
            b.shadowRadius = 2.5
            b.shadowOffset = .zero
            layer?.addSublayer(b)
            bars.append(b)
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ st: Style) {
        guard st != style else { return }
        style = st
        refresh()
    }

    func refresh() {
        for (i, b) in bars.enumerated() {
            let c: NSColor
            switch style {
            case .done: c = Neon.green
            case .live: c = i % 3 == 1 ? Neon.violet : Neon.accent
            case .resting: c = Neon.accent.withAlphaComponent(0.55)
            }
            b.backgroundColor = c.cgColor
            b.shadowColor = c.cgColor
            b.removeAllAnimations()
            if style == .live, !Motion.reduced {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = 0.35; a.toValue = 1
                a.duration = 0.4 + Double(i % 4) * 0.11
                a.autoreverses = true; a.repeatCount = .infinity
                a.timeOffset = Double(i) * 0.13
                b.add(a, forKey: "bounce")
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let bw: CGFloat = 2.5, gap: CGFloat = 3
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

/// The rounded square with a `>_` prompt in front of the command waiting on you.
final class BoxGlyph: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        Neon.drawChip(NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10), hovered: false)
        Neon.symbol("chevron.right", in: NSRect(x: r.minX + 6, y: r.minY, width: r.width / 2 - 2, height: r.height),
                    size: 13, weight: .bold, color: Neon.accent)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: r.midX + 1, y: r.midY + 6)); line.line(to: NSPoint(x: r.maxX - 9, y: r.midY + 6))
        line.lineWidth = 2; line.lineCapStyle = .round
        Neon.accent.setStroke(); line.stroke()
    }
}

/// Round glyph button (📄 / ⌄) on the wings.
final class GlowIconButton: NSView {
    var onTap: (() -> Void)?
    private let symbol: String
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let c = bounds.insetBy(dx: 4, dy: 4)
        Neon.drawChip(NSBezierPath(ovalIn: c), hovered: hovered)
        Neon.symbol(symbol, in: c, size: 14, weight: .semibold, color: Neon.glyph)
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

/// Outlined, softly glowing "✕ Reject" / "✓ Approve".
final class GlowPillButton: NSView {
    enum Tint { case red, green }
    var onTap: (() -> Void)?
    private let title: String
    private let symbol: String
    private let tint: Tint
    private var hovered = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 14.5, weight: .semibold)
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String, symbol: String, tint: Tint) {
        self.title = title; self.symbol = symbol; self.tint = tint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Glow inset + padding + icon + gap + text + padding.
    var fittedWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 4 * 2 + 18 + 16 + 8 + 20
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = tint == .red ? Neon.red : Neon.green
        let r = bounds.insetBy(dx: 4, dy: 4)
        let shape = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        Neon.glowing(color.withAlphaComponent(hovered ? 0.55 : 0.3), blur: hovered ? 10 : 6) {
            color.withAlphaComponent(hovered ? 0.2 : 0.11).setFill()
            shape.fill()
        }
        shape.lineWidth = 1.3
        color.withAlphaComponent(0.85).setStroke(); shape.stroke()
        let icon = NSRect(x: r.minX + 18, y: r.midY - 8, width: 16, height: 16)
        Neon.symbol(symbol, in: icon, size: 14, weight: .bold, color: color)
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
