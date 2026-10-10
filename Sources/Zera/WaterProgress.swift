import AppKit

/// Glasses of water, read from the reminders' own completion history (60 days, on this Mac).
/// A glass is one completed hydration reminder; the day's goal is how many are scheduled.
enum WaterStats {
    struct Day: Equatable { let date: Date; let count: Int }

    static func glasses(on day: Date, in completions: [CompletionEntry], calendar: Calendar = .current) -> Int {
        completions.filter { $0.hydration && calendar.isDate($0.completedAt, inSameDayAs: day) }.count
    }

    /// Scheduled hydration reminders for the day (8 when none can be counted).
    static func goal(on day: Date, reminders: [Reminder], calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 8 }
        let n = reminders.filter { $0.isHydration && $0.isActive }
            .reduce(0) { $0 + $1.occurrences(from: start, to: end, limit: 48).count }
        return n > 0 ? min(24, n) : 8
    }

    /// The seven days ending with `day`, oldest first.
    static func week(ending day: Date, in completions: [CompletionEntry], calendar: Calendar = .current) -> [Day] {
        (0..<7).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: day))
        }.map { Day(date: $0, count: glasses(on: $0, in: completions, calendar: calendar)) }
    }

    /// Days in a row with at least one glass, counting back from `day` (or from yesterday if
    /// today hasn't started yet).
    static func streak(ending day: Date, in completions: [CompletionEntry], calendar: Calendar = .current) -> Int {
        var date = calendar.startOfDay(for: day)
        if glasses(on: date, in: completions, calendar: calendar) == 0 {
            guard let y = calendar.date(byAdding: .day, value: -1, to: date) else { return 0 }
            date = y
        }
        var n = 0
        while glasses(on: date, in: completions, calendar: calendar) > 0, n < 60 {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
        }
        return n
    }

    /// “4 of 8 today”.
    static func todayLine(count: Int, goal: Int) -> String { "\(count) of \(goal) today" }

    /// Whether to mention the weekly card after a sip: on Fridays, or the day a 7-day streak is
    /// reached; once per week.
    static func shouldOfferCard(now: Date, streak: Int, offeredWeek: String?, calendar: Calendar = .current) -> Bool {
        let week = weekKey(now, calendar: calendar)
        guard offeredWeek != week else { return false }
        return calendar.component(.weekday, from: now) == 6 || streak == 7
    }
    static func weekKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(c.yearForWeekOfYear ?? 0)-W\(c.weekOfYear ?? 0)"
    }
}

/// The small glass under the notch: today's glasses against the goal. Click it for the week.
final class WaterGlassCounterView: NSView {
    static let size = CGSize(width: 50, height: 22)
    var count = 0 { didSet { update() } }
    var goal = 8 { didSet { update() } }
    var onClick: (() -> Void)?
    /// The pointer is over it: it stays put until the pointer leaves.
    private(set) var hovered = false { didSet { needsDisplay = true; onHover?(hovered) } }
    var onHover: ((Bool) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        let line = WaterStats.todayLine(count: count, goal: goal)
        toolTip = "Water · \(line) · click for your week"
        setAccessibilityLabel("Water, \(line). Open your week")
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.black.withAlphaComponent(hovered ? 0.9 : 0.78).setFill(); pill.fill()
        Pal.water.withAlphaComponent(hovered ? 0.6 : 0.3).setStroke(); pill.lineWidth = 1; pill.stroke()
        // The glass: a tapered outline with today's water in it.
        let g = NSRect(x: 8, y: 5, width: 10, height: 13)
        let glass = NSBezierPath()
        glass.move(to: NSPoint(x: g.minX, y: g.minY)); glass.line(to: NSPoint(x: g.maxX, y: g.minY))
        glass.line(to: NSPoint(x: g.maxX - 1.5, y: g.maxY)); glass.line(to: NSPoint(x: g.minX + 1.5, y: g.maxY)); glass.close()
        let fill = goal > 0 ? min(1, CGFloat(count) / CGFloat(goal)) : 0
        NSGraphicsContext.saveGraphicsState(); glass.addClip()
        Pal.water.setFill()
        NSRect(x: g.minX, y: g.maxY - g.height * fill, width: g.width, height: g.height * fill).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.75).setStroke(); glass.lineWidth = 1.1; glass.stroke()
        let text = "\(count)/\(goal)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
                                                    .foregroundColor: NSColor(calibratedRed: 0.75, green: 0.85, blue: 1, alpha: 1)]
        text.draw(at: NSPoint(x: 22, y: (bounds.height - 13) / 2), withAttributes: attrs)
    }
}

/// The weekly card: seven glasses, the week's total and streak, a small Zera. 1080 × 1350 when
/// saved; drawn at any size.
final class WaterWeekCardView: NSView {
    static let exportSize = CGSize(width: 1080, height: 1350)
    var week: [WaterStats.Day] = [] { didSet { needsDisplay = true } }
    var goal = 8 { didSet { needsDisplay = true } }
    var streak = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    var total: Int { week.reduce(0) { $0 + $1.count } }
    var headline: String {
        streak >= 2 ? "\(total) glasses.\n\(streak) days in a row." : "\(total) glasses\nthis week."
    }

    override func draw(_ dirtyRect: NSRect) {
        let k = bounds.width / Self.exportSize.width
        let card = NSBezierPath(roundedRect: bounds, xRadius: 72 * k, yRadius: 72 * k)
        NSColor(calibratedRed: 0.071, green: 0.071, blue: 0.098, alpha: 1).setFill(); card.fill()
        NSGraphicsContext.saveGraphicsState(); card.addClip()
        NSGradient(starting: Pal.water.withAlphaComponent(0.26), ending: Pal.water.withAlphaComponent(0))?
            .draw(fromCenter: NSPoint(x: bounds.width * 0.85, y: 0), radius: 0, toCenter: NSPoint(x: bounds.width * 0.85, y: 0), radius: 700 * k, options: [])
        NSGraphicsContext.restoreGraphicsState()

        let pad = 80 * k
        let week = WaterStats.weekKey(self.week.last?.date ?? Date()).components(separatedBy: "W").last ?? ""
        ("WEEK \(week) · WATER" as NSString).draw(at: NSPoint(x: pad, y: pad), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 34 * k, weight: .bold), .kern: 6 * k,
            .foregroundColor: Pal.water])
        let para = NSMutableParagraphStyle(); para.lineSpacing = 8 * k
        (headline as NSString).draw(in: NSRect(x: pad, y: pad + 80 * k, width: bounds.width - pad * 2, height: 340 * k), withAttributes: [
            .font: NSFont.systemFont(ofSize: 104 * k, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: para])

        // Seven glasses, oldest on the left; each filled to that day's share of the goal.
        let n = max(1, self.week.count), gap = 26 * k
        let gw = (bounds.width - pad * 2 - gap * CGFloat(n - 1)) / CGFloat(n), gh = 230 * k
        let top = bounds.height - pad - 150 * k - gh
        let days = DateFormatter(); days.dateFormat = "EEEEE"
        for (i, d) in self.week.enumerated() {
            let r = NSRect(x: pad + CGFloat(i) * (gw + gap), y: top, width: gw, height: gh)
            let inset = gw * 0.12
            let glass = NSBezierPath()
            glass.move(to: NSPoint(x: r.minX, y: r.minY)); glass.line(to: NSPoint(x: r.maxX, y: r.minY))
            glass.line(to: NSPoint(x: r.maxX - inset, y: r.maxY)); glass.line(to: NSPoint(x: r.minX + inset, y: r.maxY)); glass.close()
            let share = goal > 0 ? min(1, CGFloat(d.count) / CGFloat(goal)) : 0
            NSGraphicsContext.saveGraphicsState(); glass.addClip()
            NSGradient(starting: Pal.water, ending: Pal.waterDeep)?.draw(in: NSRect(x: r.minX, y: r.maxY - gh * share, width: gw, height: gh * share), angle: 90)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.45).setStroke(); glass.lineWidth = 4 * k; glass.stroke()
            let label = days.string(from: d.date) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 30 * k, weight: .bold),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.maxY + 18 * k), withAttributes: attrs)
        }

        // Signed by her.
        let mark = NSRect(x: pad, y: bounds.height - pad - 70 * k, width: 64 * k, height: 70 * k)
        if let zera = SpriteLibrary.shared.sprite("cheerful")?.image {
            zera.draw(in: mark, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        ("with Zera" as NSString).draw(at: NSPoint(x: mark.maxX + 20 * k, y: mark.midY - 20 * k), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 32 * k, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
    }

    /// The card as a PNG at full size.
    func pngData() -> Data? {
        let size = Self.exportSize
        let card = WaterWeekCardView(frame: NSRect(origin: .zero, size: size))
        card.week = week; card.goal = goal; card.streak = streak
        // Exactly 1080 × 1350 pixels, whatever the screen's scale.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        card.cacheDisplay(in: card.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// A small window under the notch: the card, Save image and Close.
final class WaterWeekPanel {
    private let panel = FloatingPanel.make(size: CGSize(width: 340, height: 488), level: .popUpMenu, keyable: false)
    private let root = WaterWeekRoot(frame: NSRect(x: 0, y: 0, width: 340, height: 488))
    var onSaved: ((URL) -> Void)?

    init() {
        panel.hasShadow = true
        panel.contentView = root
        root.close.target = self; root.close.action = #selector(close)
        root.save.target = self; root.save.action = #selector(save)
    }

    var isVisible: Bool { panel.isVisible }

    func show(week: [WaterStats.Day], goal: Int, streak: Int, below notch: CGRect) {
        root.card.week = week; root.card.goal = goal; root.card.streak = streak
        panel.setFrameOrigin(CGPoint(x: notch.midX - 170, y: notch.minY - 488 - 10))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = Motion.duration(0.2); panel.animator().alphaValue = 1 }
    }

    @objc func close() { panel.orderOut(nil) }

    @objc private func save() {
        guard let data = root.card.pngData(),
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { NSSound.beep(); return }
        let week = WaterStats.weekKey(root.card.week.last?.date ?? Date())
        let url = downloads.appendingPathComponent("Zera water \(week).png")
        do { try data.write(to: url); NSWorkspace.shared.activateFileViewerSelecting([url]); onSaved?(url); close() }
        catch { NSSound.beep() }
    }
}

private final class WaterWeekRoot: NSView {
    let card = WaterWeekCardView(frame: .zero)
    let save = PRActionButton("Save image", style: .primary, target: nil, action: #selector(WaterWeekPanel.close))
    let close = PRActionButton("Close", style: .secondary, target: nil, action: #selector(WaterWeekPanel.close))
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.backgroundColor = Pal.cardBottom.cgColor
        layer?.borderColor = Pal.border.cgColor
        layer?.borderWidth = 1
        save.setLine("download")
        [card, save, close].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        card.frame = NSRect(x: 16, y: 16, width: 308, height: 385)
        let bh = Metrics.button
        close.frame = NSRect(x: bounds.width - 16 - 84, y: 418, width: 84, height: bh)
        save.frame = NSRect(x: close.frame.minX - 8 - 120, y: 418, width: 120, height: bh)
    }
}
