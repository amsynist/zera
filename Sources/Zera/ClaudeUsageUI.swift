import AppKit

// Claude's plan usage on Home: one card in the vitals' style. Each window (5 hours, the week)
// reads as “name · N% used”, a slim fluid bar filled to what's used, and when it resets.
// The bar's colour moves from calm to amber to red as the window fills. Tap for Claude sessions.

final class ClaudeUsageStrip: NSView, ZeraAnimating {
    static let height: CGFloat = 66
    var onOpen: (() -> Void)?
    private let tween = VitalsTween()
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    /// Reset times read in minutes: redrawn when the minute changes, not on every reading.
    private var drawnMinute = 0
    private var flowPhase: Double = 0
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        tween.duration = 1.1
        tween.onStep = { [weak self] in self?.needsDisplay = true }
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: ClaudeUsageService.changed, object: nil)
        // Home reads the vitals every second while it's on screen; that's this row's clock too.
        NotificationCenter.default.addObserver(self, selector: #selector(tick), name: SystemVitals.changed, object: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Claude usage")
        changed()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func changed() {
        let u = ClaudeUsageService.shared.usage
        tween.set([u?.fiveHour?.used ?? 0, u?.week?.used ?? 0], animated: window?.isVisible == true && !isHiddenOrHasHiddenAncestor)
        setAccessibilityValue(u.map(\.spoken) ?? "No reading yet")
        toolTip = "Claude plan usage · " + ClaudeUsageService.shared.freshnessLabel
        updateFlow()
        needsDisplay = true
    }

    @objc private func tick() {
        let minute = Int(Date().timeIntervalSince1970 / 60)
        guard minute != drawnMinute, !isHiddenOrHasHiddenAncestor else { return }
        drawnMinute = minute
        changed()   // a window that just reset drops to 0%
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFlow()
    }
    private func updateFlow() {
        if window == nil || Motion.reduced || ClaudeUsageService.shared.usage == nil { ZeraAnimationClock.shared.remove(self) }
        else { ZeraAnimationClock.shared.add(self) }
    }
    override func viewDidHide() { super.viewDidHide(); ZeraAnimationClock.shared.refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); ZeraAnimationClock.shared.refresh() }
    func advanceAnimation(at now: TimeInterval) {
        guard !Motion.reduced, ClaudeUsageService.shared.usage != nil else { return }
        flowPhase = now * 1.5
        needsDisplay = true
    }

    /// Calm while there's room, then amber and red as the window fills.
    static func tone(_ used: Double) -> NSColor {
        let p = Pal
        if used >= 0.9 { return p.danger }
        if used >= 0.75 { return p.warning }
        if used >= 0.4 { return p.accent }
        return p.success
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let u = ClaudeUsageService.shared.usage
        let card = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: card, xRadius: Radius.l, yRadius: Radius.l)
        (pressed ? p.surfacePressed : (hovering ? p.surfaceHover : p.surfaceRow)).setFill(); shape.fill()
        (hovering ? p.border.withAlphaComponent(min(1, p.border.alphaComponent * 2)) : NSColor.clear).setStroke()
        shape.lineWidth = 1; shape.stroke()

        // Who it's for: Claude's tile, and (when there's room) its name.
        let pad = Space.l
        let tile = NSRect(x: pad, y: (bounds.height - 34) / 2, width: 34, height: 34)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10)
        p.tileClaude.withAlphaComponent(0.16).setFill(); tilePath.fill()
        Neon.symbol("sparkle", in: tile, size: 15, weight: .semibold, color: p.tileClaude)
        let wide = bounds.width >= 560
        var x = tile.maxX + Space.m
        if wide {
            VDraw.text("Claude", Typo.control, p.text, at: NSPoint(x: x, y: bounds.midY - 17))
            VDraw.text("Plan usage", Typo.caption, p.textTertiary, at: NSPoint(x: x, y: bounds.midY + 2))
            x += 96
        }

        // The two windows, side by side.
        let values = tween.values.count == 2 ? tween.values : [0, 0]
        let windows: [(String, ClaudeUsage.Window?)] = [("5 hours", u?.fiveHour), ("This week", u?.week)]
        let gap: CGFloat = 28
        let colW = max(0, (bounds.width - pad - x - gap) / 2)
        for (i, item) in windows.enumerated() {
            let cx = x + CGFloat(i) * (colW + gap)
            let used = max(0, min(1, values[i]))
            let tone = item.1 == nil ? p.textTertiary : Self.tone(used)
            // Line 1: the window's name, and how much is used.
            VDraw.label(item.0, at: NSPoint(x: cx, y: 13))
            let figure = item.1.map { "\($0.percent)%" } ?? "—"
            let figureFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            let usedWord = item.1 == nil ? "" : " used"
            let fw = VDraw.width(figure, figureFont), uw = VDraw.width(usedWord, Typo.caption)
            VDraw.text(figure, figureFont, item.1 == nil ? p.textTertiary : p.text, at: NSPoint(x: cx + colW - fw - uw, y: 10))
            if !usedWord.isEmpty { VDraw.text(usedWord, Typo.caption, p.textTertiary, at: NSPoint(x: cx + colW - uw, y: 12)) }
            // Line 2: the fluid bar.
            let bar = NSRect(x: cx, y: 31, width: colW, height: 7)
            drawBar(bar, used: used, tone: tone, live: item.1 != nil)
            // Line 3: when it resets.
            let reset = item.1.map { "Resets in \($0.resetsIn())" } ?? "Waiting for the next Claude reply"
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            (reset as NSString).draw(in: NSRect(x: cx, y: 44, width: colW, height: 14),
                                     withAttributes: [.font: Typo.caption, .foregroundColor: p.textTertiary, .paragraphStyle: para])
        }
    }

    /// A slim track; the used part is liquid: a soft gradient, a meniscus that wobbles at its
    /// end, and a light that flows through it now and then.
    private func drawBar(_ r: NSRect, used: Double, tone: NSColor, live: Bool) {
        let p = Pal
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        p.text.withAlphaComponent(0.08).setFill(); track.fill()
        guard live, used > 0.002 else { return }
        let reduced = Motion.reduced
        let w = max(r.height, r.width * CGFloat(used))
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        // The meniscus: the fill's end leans and wobbles a little, like water in a tube.
        let wobble = reduced ? 0 : CGFloat(sin(flowPhase * 1.6)) * 1.6
        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: r.minX, y: r.minY))
        fill.line(to: NSPoint(x: r.minX + w - wobble, y: r.minY))
        fill.curve(to: NSPoint(x: r.minX + w + wobble, y: r.maxY),
                   controlPoint1: NSPoint(x: r.minX + w + r.height * 0.9, y: r.minY + r.height * 0.3),
                   controlPoint2: NSPoint(x: r.minX + w + r.height * 0.9 + wobble, y: r.maxY - r.height * 0.3))
        fill.line(to: NSPoint(x: r.minX, y: r.maxY)); fill.close()
        NSGradient(starting: tone.withAlphaComponent(0.65), ending: tone)?.draw(in: fill, angle: 0)
        // A light that drifts along the liquid every few seconds.
        if !reduced {
            let cycle = (flowPhase * 0.22).truncatingRemainder(dividingBy: 1)
            let sx = r.minX - 40 + (w + 80) * CGFloat(cycle)
            NSGraphicsContext.saveGraphicsState()
            fill.addClip()
            NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)])?
                .draw(in: NSRect(x: sx, y: r.minY, width: 40, height: r.height), angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Its top edge catches the light.
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSRect(x: r.minX + 2, y: r.minY + 1, width: max(0, w - 4), height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        // A soft glow under the fill when it's getting full.
        if used >= 0.75 {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow(); glow.shadowColor = tone.withAlphaComponent(0.6); glow.shadowBlurRadius = 6; glow.set()
            tone.withAlphaComponent(0.01).setFill(); NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: w, height: r.height), xRadius: r.height / 2, yRadius: r.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { onOpen?() } else { super.keyDown(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
