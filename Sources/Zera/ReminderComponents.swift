import AppKit

// Building blocks for the Reminders & Calendar screen. Same design system as the GitHub /
// Claude / Drop Files screens: `Pal` colours, glass panels, violet gradients.

@MainActor
func rlabel(_ font: NSFont, _ color: NSColor, lines: Int = 1) -> NSTextField {
    let l = lines == 1 ? NSTextField(labelWithString: "") : NSTextField(wrappingLabelWithString: "")
    l.font = font
    l.textColor = color
    l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    if lines > 1 { l.maximumNumberOfLines = lines }
    l.isSelectable = false
    return l
}

private func symbolImage(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .semibold, _ color: NSColor) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))?
        .withSymbolConfiguration(.init(paletteColors: [color]))
}

private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

private func drawCentered(_ img: NSImage?, in r: NSRect) {
    guard let img = img else { return }
    let s = img.size
    img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

// MARK: - Look of each kind of item

/// Colour, glyph and label for what a row is: which calendar, Zera's own, a reminder, water.
enum AgendaLook {
    case source(CalendarEvent.Source)
    case reminder
    case hydration

    static func of(_ item: AgendaItem) -> AgendaLook {
        if let r = item.reminder { return r.isHydration ? .hydration : .reminder }
        return .source(item.event?.source ?? .custom)
    }
    static func of(_ entry: CompletionEntry) -> AgendaLook {
        if entry.itemKind == .reminder { return entry.hydration ? .hydration : .reminder }
        return .source(entry.source ?? .custom)
    }

    var tint: NSColor {
        let p = Pal
        switch self {
        case .source(.google): return srgb(0.26, 0.52, 0.96)
        case .source(.outlook): return srgb(0.05, 0.44, 0.78)
        case .source(.apple): return srgb(0.96, 0.33, 0.36)
        case .source(.custom): return p.accent
        case .reminder: return srgb(1.0, 0.62, 0.20)
        case .hydration: return srgb(0.22, 0.62, 1.0)
        }
    }
    /// A letter drawn instead of a glyph (Google / Outlook), so nothing pretends to be a logo.
    var letter: String? {
        switch self {
        case .source(.google): return "G"
        case .source(.outlook): return "O"
        default: return nil
        }
    }
    var symbol: String {
        switch self {
        case .source(.apple): return "calendar"
        case .source(.custom): return "sparkles"
        case .source: return "calendar"
        case .reminder: return "bell.fill"
        case .hydration: return "drop.fill"
        }
    }
    var label: String {
        switch self {
        case .source(let s): return s == .custom ? "Zera" : s.title
        case .reminder: return "Reminder"
        case .hydration: return "Hydration"
        }
    }
}

/// Rounded gradient tile with a white glyph (or letter) for one kind of item.
final class AgendaTile: NSView {
    var look: AgendaLook = .reminder { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = bounds.width * 0.3
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        // Tinted like every icon tile in the island: soft fill, hairline edge, glyph in the colour.
        let c = look.tint
        let glyph = c.blended(withFraction: 0.25, of: .white) ?? c
        c.withAlphaComponent(0.14).setFill(); path.fill()
        c.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1; path.stroke()
        if let l = look.letter {
            let f = NSFont.systemFont(ofSize: bounds.width * 0.42, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: glyph]
            let s = (l as NSString).size(withAttributes: attrs)
            (l as NSString).draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2), withAttributes: attrs)
        } else {
            drawCentered(symbolImage(look.symbol, bounds.width * 0.4, .semibold, glyph), in: bounds)
        }
        if dimmed {
            Pal.cardBottom.withAlphaComponent(0.45).setFill(); path.fill()
        }
    }
}

// MARK: - State chip

extension AgendaState {
    func chip(for item: AgendaItem, now: Date = Date()) -> (symbol: String, text: String, color: NSColor) {
        let p = Pal
        switch self {
        case .upcoming:
            let s = item.occurrence.timeIntervalSince(now)
            if s < 2 * 3600 { return ("clock.fill", ReminderFormat.countdown(to: item.occurrence, now: now), p.accent) }
            return ("clock", "Upcoming", p.accent)
        case .inProgress: return ("dot.radiowaves.left.and.right", "Now", p.success)
        case .due: return ("bell.fill", "Due now", p.warning)
        case .overdue: return ("exclamationmark.circle.fill", "Overdue", p.danger)
        case .snoozed:
            let until = item.reminder?.snoozedUntil.map { ReminderFormat.time.string(from: $0) } ?? ""
            return ("moon.zzz.fill", until.isEmpty ? "Snoozed" : "Snoozed · \(until)", p.info)
        case .completed: return ("checkmark.circle.fill", "Done", p.success)
        case .doneForToday: return ("checkmark.circle.fill", "Done for today", p.success)
        case .disabled: return ("pause.circle.fill", "Off", p.muted)
        case .ended: return ("checkmark", "Ended", p.muted)
        }
    }
}

// MARK: - Agenda row

/// One event or reminder: time column · tile · title / details · state · actions.
final class AgendaRow: NSView {
    static let height: CGFloat = 68

    var onSelect: (() -> Void)?
    var onCheck: (() -> Void)?
    var onJoin: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onRestore: (() -> Void)?
    var onDelete: (() -> Void)?

    var selected = false { didSet { if selected != oldValue { needsDisplay = true; updateGlow() } } }
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var dim = false
    private var tint: NSColor = Pal.accent

    private let timeLabel = rlabel(NSFont.systemFont(ofSize: 13.5, weight: .semibold), Pal.text)
    private let subTimeLabel = rlabel(NSFont.systemFont(ofSize: 11.5, weight: .medium), Pal.textTertiary)
    private let tile = AgendaTile()
    private let titleLabel = rlabel(NSFont.systemFont(ofSize: 14, weight: .semibold), Pal.text)
    private let detailLabel = rlabel(NSFont.systemFont(ofSize: 12), Pal.textSecondary)
    private let chip = PRStatusChip()
    private var check: GHSquareButton!
    private var more: GHSquareButton!
    private var join: PRActionButton!
    private var restore: PRActionButton!
    private var trash: GHSquareButton!

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        subTimeLabel.alignment = .left
        check = GHSquareButton(symbol: "checkmark", label: "Mark as done", target: self, action: #selector(checkTapped))
        more = GHSquareButton(symbol: "ellipsis", label: "More", target: self, action: #selector(moreTapped))
        join = PRActionButton("Join", style: .primary, symbol: "video.fill", target: self, action: #selector(joinTapped))
        restore = PRActionButton("Restore", style: .secondary, symbol: "arrow.uturn.backward", target: self, action: #selector(restoreTapped))
        trash = GHSquareButton(symbol: "trash", label: "Delete", target: self, action: #selector(deleteTapped))
        [timeLabel, subTimeLabel, tile, titleLabel, detailLabel, chip].forEach { addSubview($0) }
        [check!, more!, trash!].forEach { addSubview($0) }
        [join!, restore!].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A Today / Upcoming row.
    func configure(_ item: AgendaItem, state: AgendaState, now: Date = Date()) {
        let look = AgendaLook.of(item)
        tint = look.tint
        tile.look = look
        dim = state == .disabled || state == .ended || state == .doneForToday
        tile.dimmed = state == .disabled

        if item.isAllDay {
            timeLabel.stringValue = "All day"
            subTimeLabel.stringValue = ""
        } else {
            timeLabel.stringValue = ReminderFormat.time.string(from: item.occurrence)
            if let e = item.event { subTimeLabel.stringValue = ReminderFormat.duration(e.duration) }
            else if let r = item.reminder, r.rule.isInterval { subTimeLabel.stringValue = "every " + Reminder.intervalLabel(Int(r.rule.intervalSeconds / 60)) }
            else { subTimeLabel.stringValue = item.reminder?.rule.isRepeating == true ? "repeats" : "" }
        }
        titleLabel.stringValue = item.title

        var bits: [String] = []
        if let e = item.event {
            if !e.isAllDay, let end = item.end {
                bits.append(ReminderFormat.time.string(from: item.occurrence) + " – " + ReminderFormat.time.string(from: end))
            }
            bits.append(e.source == .custom ? "Zera" : e.source.title)
            if !e.location.isEmpty { bits.append(e.location) }
            else if e.rule.isRepeating { bits.append(e.rule.title) }
        } else if let r = item.reminder {
            bits.append(r.isHydration ? "Hydration" : "Reminder")
            if r.rule.isInterval {
                bits.append(r.rule.title + (r.hasActiveHours ? " · " + r.activeHoursText : ""))
                if item.seriesTotal > 0 { bits.append("\(item.seriesDone) of \(item.seriesTotal) done") }
            } else if r.rule.isRepeating {
                bits.append(r.rule.title)
            } else if !Calendar.current.isDate(item.occurrence, inSameDayAs: now) {
                bits.append(ReminderFormat.relativeDay(item.occurrence, now: now))
            }
            if !r.notes.isEmpty, !r.rule.isInterval { bits.append(r.notes) }
        }
        detailLabel.stringValue = bits.joined(separator: "  ·  ")

        let c = state.chip(for: item, now: now)
        chip.set(symbol: c.symbol, text: c.text, color: c.color)
        chip.isHidden = false

        let isReminder = item.reminder != nil
        let canCheck = isReminder && (state == .due || state == .overdue || state == .upcoming || state == .snoozed)
        check.isHidden = !canCheck
        check.toolTip = "Mark as done"
        // Join only when a call link exists and the meeting is close or under way.
        let close = item.occurrence.timeIntervalSince(now) < 15 * 60
        join.isHidden = !(item.event?.joinURL != nil && (state == .inProgress || (state == .upcoming && close)))
        more.isHidden = false
        restore.isHidden = true
        trash.isHidden = true
        setAccessibilityLabel("\(item.title), \(timeLabel.stringValue), \(c.text)")
        alphaValue = dim ? 0.62 : 1
        needsLayout = true
        needsDisplay = true
    }

    /// A Completed row: Restore and Delete; click to view.
    func configure(completion e: CompletionEntry, now: Date = Date()) {
        let look = AgendaLook.of(e)
        tint = Pal.success
        tile.look = look
        tile.dimmed = false
        dim = false
        timeLabel.stringValue = ReminderFormat.time.string(from: e.completedAt)
        subTimeLabel.stringValue = Calendar.current.isDate(e.completedAt, inSameDayAs: now) ? "today" : ReminderFormat.relativeDay(e.completedAt, now: now)
        titleLabel.stringValue = e.title
        let due = ReminderFormat.relativeDay(e.occurrence, now: now) + " " + ReminderFormat.time.string(from: e.occurrence)
        detailLabel.stringValue = [look.label, (e.itemKind == .event ? "Was at " : "Was due ") + due].joined(separator: "  ·  ")
        chip.set(symbol: "checkmark.circle.fill", text: "Done", color: Pal.success)
        chip.isHidden = false
        check.isHidden = true
        join.isHidden = true
        more.isHidden = true
        restore.isHidden = false
        trash.isHidden = false
        alphaValue = 1
        setAccessibilityLabel("\(e.title), completed")
        needsLayout = true
        needsDisplay = true
    }

    private func updateGlow() {
        layer?.shadowColor = Pal.accent.cgColor
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 10
        layer?.shadowOpacity = selected ? 0.35 : 0
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        timeLabel.frame = NSRect(x: 16, y: subTimeLabel.stringValue.isEmpty ? (h - 18) / 2 : 15, width: 70, height: 18)
        subTimeLabel.frame = NSRect(x: 16, y: 35, width: 70, height: 15)
        tile.frame = NSRect(x: 90, y: (h - 38) / 2, width: 38, height: 38)

        // Right side, from the edge inwards.
        var rx = w - 12
        func place(_ v: NSView, _ width: CGFloat, _ height: CGFloat) {
            guard !v.isHidden else { return }
            rx -= width
            v.frame = NSRect(x: rx, y: (h - height) / 2, width: width, height: height)
            rx -= 8
        }
        place(more, 30, 30)
        place(trash, 30, 30)
        place(restore, restore.fittedWidth, 30)
        place(check, 30, 30)
        place(join, max(70, join.fittedWidth), 30)
        let cw = min(150, chip.fittedWidth)
        place(chip, cw, 24)

        let tx: CGFloat = 140
        let textW = max(40, rx - tx)
        titleLabel.frame = NSRect(x: tx, y: 14, width: textW, height: 19)
        detailLabel.frame = NSRect(x: tx, y: 36, width: textW, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: Radius.l + 2, yRadius: Radius.l + 2)
        if selected { p.drawSelected(path) } else {
            (hovered ? p.surfaceHover : p.surfaceRow).setFill(); path.fill()
            p.border.setStroke(); path.lineWidth = 1; path.stroke()
        }
        // Coloured accent bar on the left, in the item's colour.
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 6, y: 14, width: 3.5, height: bounds.height - 28), xRadius: 1.75, yRadius: 1.75).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if NSPointInRect(convert(event.locationInWindow, from: nil), bounds) { onSelect?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func checkTapped() { onCheck?() }
    @objc private func moreTapped() { onMenu?(more) }
    @objc private func joinTapped() { onJoin?() }
    @objc private func restoreTapped() { onRestore?() }
    @objc private func deleteTapped() { onDelete?() }
}

/// "Tomorrow · Mon, Oct 5" above a day's items in Upcoming.
final class DayHeader: NSView {
    static let height: CGFloat = 30
    private let label = rlabel(NSFont.systemFont(ofSize: 12.5, weight: .bold), Pal.textSecondary)
    private let count = rlabel(NSFont.systemFont(ofSize: 12, weight: .medium), Pal.textTertiary)
    override var isFlipped: Bool { true }

    init(day: Date, items: Int) {
        super.init(frame: .zero)
        let rel = ReminderFormat.relativeDay(day)
        let long = ReminderFormat.longDate.string(from: day)
        label.stringValue = (rel == "Tomorrow" ? "Tomorrow · " + long : long).uppercased()
        count.stringValue = "\(items) item\(items == 1 ? "" : "s")"
        count.alignment = .right
        addSubview(label); addSubview(count)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 6, y: 10, width: bounds.width - 100, height: 16)
        count.frame = NSRect(x: bounds.width - 96, y: 10, width: 90, height: 16)
    }
}

// MARK: - Chips

/// A row of small rounded choices (filters, weekdays, intervals). Single or multiple selection.
final class ChoiceChips: NSView {
    struct Item { let title: String; var dot: NSColor? = nil; var symbol: String? = nil }
    var items: [Item] { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var selection: Set<Int> = [0] { didSet { needsDisplay = true } }
    var multiple = false
    /// Equal-width chips filling the row instead of sized to their text.
    var fill = false
    var onChange: ((Set<Int>) -> Void)?
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private static let font = Typo.chip
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(items: [Item]) {
        self.items = items
        super.init(frame: .zero)
        setAccessibilityRole(.radioGroup)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func naturalWidth(_ it: Item) -> CGFloat {
        let t = ceil((it.title as NSString).size(withAttributes: [.font: Self.font]).width)
        return t + 24 + (it.dot != nil ? 14 : 0) + (it.symbol != nil ? 18 : 0)
    }
    var preferredWidth: CGFloat { items.reduce(0) { $0 + naturalWidth($1) } + CGFloat(max(0, items.count - 1)) * 6 }

    private func slot(_ i: Int) -> NSRect {
        if fill {
            let w = (bounds.width - CGFloat(items.count - 1) * 6) / CGFloat(max(1, items.count))
            return NSRect(x: CGFloat(i) * (w + 6), y: 0, width: w, height: bounds.height)
        }
        var x: CGFloat = 0
        for j in 0..<i { x += naturalWidth(items[j]) + 6 }
        return NSRect(x: x, y: 0, width: naturalWidth(items[i]), height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        for (i, it) in items.enumerated() {
            let r = slot(i).insetBy(dx: 0.5, dy: 0.5)
            let on = selection.contains(i)
            let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            if on {
                p.drawSelected(path)
            } else {
                (hoverIndex == i ? p.surfaceHover : p.surface).setFill(); path.fill()
                p.border.setStroke(); path.lineWidth = 1; path.stroke()
            }
            let color: NSColor = on ? p.accent : p.textSecondary
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
            let tw = ceil((it.title as NSString).size(withAttributes: attrs).width)
            let extra: CGFloat = (it.dot != nil ? 14 : 0) + (it.symbol != nil ? 18 : 0)
            var x = r.midX - (tw + extra) / 2
            if let d = it.dot {
                d.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: r.midY - 4, width: 8, height: 8)).fill()
                x += 14
            }
            if let s = it.symbol {
                drawCentered(symbolImage(s, 11.5, .semibold, color), in: NSRect(x: x, y: r.minY, width: 14, height: r.height))
                x += 18
            }
            let th = ceil(Self.font.ascender - Self.font.descender) + 1
            (it.title as NSString).draw(in: NSRect(x: x, y: r.midY - th / 2, width: tw + 1, height: th), withAttributes: attrs)
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let pt = convert(event.locationInWindow, from: nil)
        return items.indices.first { NSPointInRect(pt, slot($0)) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { hoverIndex = index(at: event) }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }
    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        if multiple {
            if selection.contains(i) { if selection.count > 1 { selection.remove(i) } } else { selection.insert(i) }
        } else {
            selection = [i]
        }
        onChange?(selection)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    var selectedIndex: Int { selection.min() ?? 0 }
}

// MARK: - Form controls

/// Date or time in a field-styled box. Type straight into it, or click it for Zera's own
/// picker: a calendar for dates, a list of times (every 15 minutes) for times. No native steppers.
final class PickerBox: NSView {
    let picker = NSDatePicker()
    var onChange: (() -> Void)?
    private let isTime: Bool
    private let icon = NSImageView()
    private let chevron = NSImageView()
    private var hovered = false { didSet { if hovered != oldValue { updateBorder() } } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(time: Bool) {
        isTime = time
        super.init(frame: .zero)
        let p = Pal
        wantsLayer = true
        layer?.cornerRadius = Radius.m
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = p.field.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.fieldBorder.cgColor
        icon.image = NSImage(systemSymbolName: time ? "clock" : "calendar", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = p.textSecondary
        addSubview(icon)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.contentTintColor = p.textSecondary
        addSubview(chevron)
        picker.datePickerStyle = .textField
        picker.datePickerElements = time ? .hourMinute : .yearMonthDay
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.textColor = p.text
        picker.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        picker.target = self
        picker.action = #selector(changed)
        picker.setAccessibilityLabel(time ? "Time" : "Date")
        addSubview(picker)
    }
    required init?(coder: NSCoder) { fatalError() }

    var date: Date {
        get { picker.dateValue }
        set { picker.dateValue = newValue }
    }
    var isEnabled: Bool {
        get { picker.isEnabled }
        set { picker.isEnabled = newValue; alphaValue = newValue ? 1 : 0.5 }
    }

    @objc private func changed() { onChange?() }

    private func updateBorder() {
        layer?.borderColor = (hovered && isEnabled ? Pal.accentBorder : Pal.fieldBorder).cgColor
    }

    /// Clicks outside the typed text open the picker.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if isTime { showTimes() } else { showCalendar() }
    }

    private func showTimes() {
        let cal = Calendar.current
        let cur = cal.dateComponents([.hour, .minute], from: date)
        let curMin = (cur.hour ?? 0) * 60 + (cur.minute ?? 0)
        let nearest = Int((Double(curMin) / 15).rounded()) * 15
        var items: [DropdownItem] = []
        for m in stride(from: 0, to: 24 * 60, by: 15) {
            items.append(DropdownItem(title: ReminderFormat.clock(minutes: m), checked: m == nearest) { [weak self] in
                guard let self = self else { return }
                self.date = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: self.date) ?? self.date
                self.onChange?()
            })
        }
        ZeraDropdown.shared.show(items, below: self, width: max(bounds.width, 170))
    }

    private func showCalendar() {
        let cal = NSDatePicker()
        cal.datePickerStyle = .clockAndCalendar
        cal.datePickerElements = .yearMonthDay
        cal.isBezeled = false
        cal.isBordered = false
        cal.drawsBackground = false
        cal.textColor = Pal.text
        cal.dateValue = date
        let box = FlippedView()
        let fit = cal.fittingSize
        let size = NSSize(width: max(fit.width, 150) + 24, height: max(fit.height, 140) + 24)
        cal.frame = NSRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24)
        box.addSubview(cal)
        let relay = CalendarRelay { [weak self] d in
            guard let self = self else { return }
            // Keep the time of day; only the day changes.
            let c = Calendar.current
            let t = c.dateComponents([.hour, .minute], from: self.date)
            self.date = c.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: d) ?? d
            self.onChange?()
            ZeraDropdown.shared.dismiss()
        }
        cal.target = relay
        cal.action = #selector(CalendarRelay.picked(_:))
        calendarRelay = relay
        ZeraDropdown.shared.show(content: box, size: size, below: self)
    }
    private var calendarRelay: CalendarRelay?

    /// The typed text belongs to the date picker; everywhere else in the box opens the dropdown.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, NSPointInRect(point, frame) else { return nil }
        let local = convert(point, from: superview)
        if NSPointInRect(local, picker.frame) { return super.hitTest(point) }
        return self
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 11, y: (bounds.height - 16) / 2, width: 16, height: 16)
        chevron.frame = NSRect(x: bounds.width - 12 - 12, y: (bounds.height - 12) / 2, width: 12, height: 12)
        let fit = picker.fittingSize
        let ph = max(20, fit.height)
        picker.frame = NSRect(x: 34, y: (bounds.height - ph) / 2, width: min(max(40, bounds.width - 34 - 30), fit.width + 6), height: ph)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// Target for the calendar in the date dropdown.
final class CalendarRelay: NSObject {
    private let handler: (Date) -> Void
    init(_ handler: @escaping (Date) -> Void) { self.handler = handler }
    @objc func picked(_ sender: NSDatePicker) { handler(sender.dateValue) }
}

/// A whole number with − / + (every N …).
final class CountField: NSView, NSTextFieldDelegate {
    var minValue = 1
    var maxValue = 999
    var step = 1
    var onChange: ((Int) -> Void)?
    private let field = ThemedField(placeholder: "")
    private var minus: GHSquareButton!
    private var plus: GHSquareButton!
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.alignment = .center
        field.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        field.delegate = self
        field.stringValue = "1"
        minus = GHSquareButton(symbol: "minus", label: "Less", target: self, action: #selector(minusTapped))
        plus = GHSquareButton(symbol: "plus", label: "More", target: self, action: #selector(plusTapped))
        [minus!, field, plus!].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    var value: Int {
        get { min(maxValue, max(minValue, Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? minValue)) }
        set { field.stringValue = String(min(maxValue, max(minValue, newValue))) }
    }

    @objc private func minusTapped() { value = value - step; onChange?(value) }
    @objc private func plusTapped() { value = value + step; onChange?(value) }
    func controlTextDidChange(_ obj: Notification) { onChange?(value) }
    func controlTextDidEndEditing(_ obj: Notification) { let v = value; value = v; onChange?(v) }

    override func layout() {
        super.layout()
        let h = bounds.height
        minus.frame = NSRect(x: 0, y: 0, width: h, height: h)
        plus.frame = NSRect(x: bounds.width - h, y: 0, width: h, height: h)
        field.frame = NSRect(x: h + 6, y: 0, width: bounds.width - 2 * h - 12, height: h)
    }
}

/// Notes / description: one tidy line like every other field (placeholder centred).
@MainActor
func notesField(_ placeholder: String) -> ThemedField {
    ThemedField(placeholder: placeholder)
}

// MARK: - Form layout

/// Fields stacked top to bottom; each line has one or two columns, each column a label and
/// controls laid side by side (fixed widths first, the rest flexible). Hidden lines collapse.
final class FormCanvas: NSView {
    struct Control {
        let view: NSView
        var width: CGFloat? = nil
        var height: CGFloat? = nil
    }
    struct Column {
        var label: NSTextField?
        var controls: [Control]
    }
    final class Line {
        var columns: [Column]
        var height: CGFloat
        var isHidden = false
        init(_ columns: [Column], height: CGFloat) { self.columns = columns; self.height = height }
    }

    private(set) var lines: [Line] = []
    override var isFlipped: Bool { true }
    static let labelH: CGFloat = 16, labelGap: CGFloat = 6, lineGap: CGFloat = 14, colGap: CGFloat = 12

    @discardableResult
    func add(_ columns: [Column], height: CGFloat = 34) -> Line {
        let l = Line(columns, height: height)
        lines.append(l)
        for c in columns {
            if let lb = c.label { addSubview(lb) }
            c.controls.forEach { addSubview($0.view) }
        }
        return l
    }

    static func label(_ s: String) -> NSTextField {
        let l = rlabel(NSFont.systemFont(ofSize: 12, weight: .semibold), Pal.textSecondary)
        l.stringValue = s
        return l
    }

    /// Lays everything out for `width`; returns the height used.
    @discardableResult
    func layoutLines(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for line in lines {
            for c in line.columns {
                c.label?.isHidden = line.isHidden
                c.controls.forEach { $0.view.isHidden = line.isHidden }
            }
            guard !line.isHidden else { continue }
            let n = CGFloat(line.columns.count)
            let colW = (width - Self.colGap * (n - 1)) / n
            let hasLabel = line.columns.contains { $0.label != nil }
            let cy = y + (hasLabel ? Self.labelH + Self.labelGap : 0)
            for (i, c) in line.columns.enumerated() {
                let x0 = CGFloat(i) * (colW + Self.colGap)
                c.label?.frame = NSRect(x: x0, y: y, width: colW, height: Self.labelH)
                let fixed = c.controls.compactMap { $0.width }.reduce(0, +)
                let flexCount = CGFloat(c.controls.filter { $0.width == nil }.count)
                let gaps = CGFloat(max(0, c.controls.count - 1)) * 8
                let flexW = flexCount > 0 ? max(30, (colW - fixed - gaps) / flexCount) : 0
                var x = x0
                for ctl in c.controls {
                    let w = ctl.width ?? flexW
                    let h = ctl.height ?? line.height
                    ctl.view.frame = NSRect(x: x, y: cy + (line.height - h) / 2, width: w, height: h)
                    x += w + 8
                }
            }
            y = cy + line.height + Self.lineGap
        }
        return max(0, y - Self.lineGap)
    }
}

// MARK: - Detail info row

/// Icon · label · value, for the detail panel.
final class DetailInfoRow: NSView {
    private let symbol: String
    private let tint: NSColor
    private let label = rlabel(NSFont.systemFont(ofSize: 12, weight: .semibold), Pal.textTertiary)
    private let value = rlabel(NSFont.systemFont(ofSize: 13, weight: .medium), Pal.text, lines: 4)
    override var isFlipped: Bool { true }

    init(symbol: String, tint: NSColor? = nil, label l: String, value v: String) {
        self.symbol = symbol
        self.tint = tint ?? Pal.accent
        super.init(frame: .zero)
        label.stringValue = l
        value.stringValue = v
        value.isSelectable = true
        addSubview(label); addSubview(value)
    }
    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat {
        let w = width - 44
        let r = (value.stringValue as NSString).boundingRect(with: NSSize(width: max(40, w), height: 200),
                                                              options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                              attributes: [.font: value.font!])
        return max(44, 6 + 16 + 2 + min(72, ceil(r.height)) + 6)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 44, y: 6, width: bounds.width - 44, height: 16)
        value.frame = NSRect(x: 44, y: 24, width: bounds.width - 44, height: bounds.height - 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let r = NSRect(x: 0, y: 6, width: 32, height: 32)
        let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        tint.withAlphaComponent(p.isDark ? 0.18 : 0.14).setFill(); path.fill()
        drawCentered(symbolImage(symbol, 13, .semibold, tint), in: r)
    }
}

/// Today's run of a hydration / interval reminder: one dot per nudge, filled when done.
final class SeriesDots: NSView {
    var total = 0 { didSet { needsDisplay = true } }
    var done = 0 { didSet { needsDisplay = true } }
    var tint: NSColor = Pal.accent { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard total > 0 else { return }
        let n = min(total, 24)
        let d: CGFloat = min(16, (bounds.width - CGFloat(n - 1) * 6) / CGFloat(n))
        for i in 0..<n {
            let r = NSRect(x: CGFloat(i) * (d + 6), y: (bounds.height - d) / 2, width: d, height: d)
            let path = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            if i < done { tint.setFill(); path.fill() } else { tint.withAlphaComponent(0.4).setStroke(); path.lineWidth = 1.5; path.stroke() }
        }
    }
}
