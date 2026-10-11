import AppKit

// Claude Code's plan usage on Home: one slim row under the Mac's vitals — the 5-hour and the
// weekly limit, each a number that glides to its reading over a bar, and when it resets. Tap
// it to open Claude sessions. Readings come from `ClaudeUsageService`.

/// How full a limit looks: Claude's own colour, then amber, then red near the end.
private extension Palette {
    func claudeUsage(_ used: Double) -> NSColor { used >= 0.9 ? danger : (used >= 0.75 ? warning : tileClaude) }
}

final class ClaudeUsageStrip: NSView {
    static let height: CGFloat = 44
    var onOpen: (() -> Void)?
    private let tween = VitalsTween()
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    /// Reset times read in minutes: redrawn when the minute changes, not on every reading.
    private var drawnMinute = 0
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
        needsDisplay = true
    }

    @objc private func tick() {
        let minute = Int(Date().timeIntervalSince1970 / 60)
        guard minute != drawnMinute, !isHiddenOrHasHiddenAncestor else { return }
        drawnMinute = minute
        changed()   // a window that just reset drops to 0%
    }

    private static let valueFont = TaskFont.clock(14)

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l, yRadius: Radius.l)
        (pressed ? p.surfacePressed : (hovering ? p.surfaceHover : p.surfaceRow)).setFill(); shape.fill()
        (hovering ? p.border.withAlphaComponent(min(1, p.border.alphaComponent * 2)) : NSColor.clear).setStroke()
        shape.lineWidth = 1; shape.stroke()

        // Who it's about: Claude's sparkles and name.
        let mid = bounds.midY
        var x = Space.l
        Neon.symbol("sparkles", in: NSRect(x: x, y: mid - 9, width: 18, height: 18), size: 14, color: p.tileClaude)
        x += 18 + Space.s
        VDraw.label("Claude", at: NSPoint(x: x, y: mid - 7))
        x += Typo.sectionText("Claude").size().width + Space.xl

        let u = ClaudeUsageService.shared.usage
        let v = tween.values.count == 2 ? tween.values : [0, 0]
        // Bars glide; the numbers show where they're going.
        let target = tween.to.count == 2 ? tween.to : v
        let windows: [(label: String, window: ClaudeUsage.Window?)] = [("5-hour", u?.fiveHour), ("Weekly", u?.week)]
        let gap = Space.xl
        let segW = max(0, (bounds.width - x - Space.l - gap) / 2)
        for (i, item) in windows.enumerated() {
            let r = NSRect(x: x + CGFloat(i) * (segW + gap), y: 0, width: segW, height: bounds.height)
            let w = item.window
            // Line: name and number on the left, when it resets on the right.
            VDraw.label(item.label, at: NSPoint(x: r.minX, y: 9))
            let nx = r.minX + Typo.sectionText(item.label).size().width + 6
            let big = w == nil ? "—" : "\(Int((target[i] * 100).rounded()))%"
            VDraw.text(big, Self.valueFont, p.text, at: NSPoint(x: nx, y: 5))
            let note: String
            if let w = w { note = w.hasReset() ? "fresh window" : "resets in \(w.resetsIn())" }
            else { note = u == nil ? "on Claude's next reply" : "not reported" }
            let noteW = VDraw.width(note, Typo.caption)
            if noteW <= r.maxX - (nx + VDraw.width(big, Self.valueFont) + Space.s) {
                VDraw.text(note, Typo.caption, p.textTertiary, at: NSPoint(x: r.maxX - noteW, y: 8))
            }
            // Bar.
            let bar = NSRect(x: r.minX, y: bounds.height - 16, width: r.width, height: 6)
            let track = NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3)
            p.text.withAlphaComponent(0.08).setFill(); track.fill()
            let fillW = bar.width * CGFloat(max(0, min(1, w == nil ? 0 : v[i])))
            if fillW > 0.5 {
                p.claudeUsage(target[i]).setFill()
                NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(6, fillW), height: bar.height), xRadius: 3, yRadius: 3).fill()
            }
        }
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
