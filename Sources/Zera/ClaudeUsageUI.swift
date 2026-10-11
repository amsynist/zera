import AppKit

// Compact plan windows: the liquid represents remaining capacity. Tap for Claude sessions.

final class ClaudeUsageStrip: NSView, ZeraAnimating {
    static let height: CGFloat = 44
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
        setAccessibilityValue((u.map(\.spoken) ?? "No reading yet") + ". Liquid shows remaining capacity.")
        toolTip = "Liquid shows remaining capacity. " + ClaudeUsageService.shared.freshnessLabel
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

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let service = ClaudeUsageService.shared
        let u = service.usage
        Neon.symbol("gauge.with.dots.needle.50percent", in: NSRect(x: 0, y: 13, width: 18, height: 18), size: 15, color: p.tileClaude)
        let labelWidth: CGFloat = bounds.width >= 500 ? 84 : 28
        if labelWidth > 28 { VDraw.text("Claude", Typo.control, p.textSecondary, at: NSPoint(x: 26, y: 14)) }
        let values = tween.values.count == 2 ? tween.values : [0, 0]
        let windows: [(String, ClaudeUsage.Window?)] = [("5h", u?.fiveHour), ("Week", u?.week)]
        let width = max(0, (bounds.width - labelWidth - Space.s) / 2)
        for (i, item) in windows.enumerated() {
            let r = NSRect(x: labelWidth + CGFloat(i) * (width + Space.s), y: 2, width: width, height: 40)
            let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 20, yRadius: 20)
            (pressed ? p.surfacePressed : (hovering ? p.surfaceHover : p.surfaceRow)).setFill(); shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            if let window = item.1 {
                let remaining = max(0, min(1, 1 - values[i]))
                let edge = r.minX + r.width * CGFloat(remaining)
                let tint = p.accent
                // Two offset surfaces give the liquid depth without obscuring its level.
                for layer in 0...1 {
                    let liquid = NSBezierPath()
                    let surface = NSBezierPath()
                    let amplitude = 2.8 * sin(.pi * remaining)
                    func point(_ step: Int) -> NSPoint {
                        let y = r.height * CGFloat(step) / 24
                        let wave = sin(Double(y) * 0.13 + flowPhase + Double(layer) * 1.8) * amplitude
                        return NSPoint(x: edge + CGFloat(wave) + (layer == 0 ? 3 : 0), y: r.minY + y)
                    }
                    liquid.move(to: NSPoint(x: r.minX, y: r.minY))
                    liquid.line(to: point(0)); surface.move(to: point(0))
                    for step in 1...24 { liquid.line(to: point(step)); surface.line(to: point(step)) }
                    liquid.line(to: NSPoint(x: r.minX, y: r.maxY)); liquid.close()
                    if remaining > 0 {
                        NSGradient(starting: tint.withAlphaComponent(layer == 0 ? 0.035 : 0.14), ending: p.accentDeep.withAlphaComponent(layer == 0 ? 0.025 : 0.08))?.draw(in: liquid, angle: 90)
                        if remaining < 1 {
                            tint.withAlphaComponent(layer == 0 ? 0.08 : 0.25).setStroke()
                            surface.lineWidth = layer == 0 ? 0.7 : 0.9; surface.stroke()
                        }
                    }
                }
                // Sparse rising bubbles stay in the liquid and away from the copy.
                if r.width > 230 && remaining > 0.15 {
                    for bubble in 0..<3 {
                        let progress = (flowPhase * 0.09 + Double(bubble) / 3).truncatingRemainder(dividingBy: 1)
                        let x = r.minX + r.width * CGFloat(remaining) * CGFloat(0.73 + Double(bubble) * 0.07)
                        let y = r.maxY - CGFloat(progress) * r.height
                        let diameter: CGFloat = bubble == 1 ? 3 : 2
                        p.text.withAlphaComponent(0.065 * sin(.pi * progress)).setStroke()
                        let bead = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter))
                        bead.lineWidth = 0.7; bead.stroke()
                    }
                }
            }
            // A restrained upper reflection makes the container read as curved glass.
            let reflection = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.45)
            NSGradient(starting: p.text.withAlphaComponent(hovering ? 0.035 : 0.018), ending: p.text.withAlphaComponent(0))?.draw(in: reflection, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
            let rim = NSBezierPath()
            rim.move(to: NSPoint(x: r.minX + 20, y: r.minY + 1))
            rim.line(to: NSPoint(x: r.maxX - 20, y: r.minY + 1))
            p.text.withAlphaComponent(0.045).setStroke(); rim.lineWidth = 0.7; rim.stroke()
            (pressed ? p.accentBorder : p.border).setStroke(); shape.lineWidth = 1; shape.stroke()
            let title = item.1.map { "\(item.0) · \($0.percent)% used" } ?? "\(item.0) · —"
            let reset = item.1.map { "Resets in \($0.resetsIn())" } ?? "Awaiting reply"
            let textX = r.minX + Space.l
            VDraw.text(title, Typo.control, p.textSecondary, at: NSPoint(x: textX, y: r.minY + 4))
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (reset as NSString).draw(in: NSRect(x: textX, y: r.minY + 21, width: max(0, width - Space.l * 2), height: 14), withAttributes: [.font: Typo.caption, .foregroundColor: p.textSecondary, .paragraphStyle: paragraph])
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
