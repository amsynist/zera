import AppKit

/// One reminder or calendar event: round coloured check (own reminders) or a glyph (events),
/// title, time. Overdue ones show their time in amber. Hover reveals ✕ for own reminders.
final class ReminderRow: NSView {
    var onToggle: (() -> Void)?
    var onDelete: (() -> Void)?

    private let check = CircleCheck()
    private let glyph = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let remove: IconButton
    private var hovered = false {
        didSet {
            layer?.backgroundColor = (hovered ? Pal.surfaceHover : Pal.surface).cgColor
            remove.isHidden = !hovered || onDelete == nil
            needsLayout = true   // the time label makes room for ✕
        }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(reminder r: Reminder) {
        remove = IconButton(symbol: "xmark.circle.fill", label: "Delete reminder", target: nil, action: #selector(ReminderRow.deleteTapped))
        super.init(frame: .zero)
        remove.target = self
        let now = Date()
        let overdue = !r.isDoneToday && !r.isInterval && r.fireTime(on: now) < now
        common(title: r.title, time: r.timeString, done: r.isDoneToday)
        check.color = r.color
        check.isOn = r.isDoneToday
        check.onTap = { [weak self] in self?.onToggle?() }
        if overdue { time.textColor = Pal.warning; time.font = Typo.caption.withWeight(.semibold) }
        if r.isInterval {
            glyph.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Repeats")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            glyph.contentTintColor = r.color
            glyph.isHidden = false
            check.isHidden = true
            if let next = r.nextDue, !r.isDoneToday {
                time.stringValue = "\(r.timeString) · next \(ReminderService.timeFormatter.string(from: next))"
            }
        }
        setAccessibilityLabel("\(r.title), \(time.stringValue)")
    }

    init(event e: CalendarItem) {
        remove = IconButton(symbol: "xmark.circle.fill", label: "Delete", target: nil, action: #selector(ReminderRow.deleteTapped))
        super.init(frame: .zero)
        let range = "\(ReminderService.timeFormatter.string(from: e.start)) – \(ReminderService.timeFormatter.string(from: e.end))"
        common(title: e.title, time: range, done: e.end < Date())
        glyph.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        glyph.contentTintColor = e.color
        glyph.isHidden = false
        check.isHidden = true
        if e.start > Date(), e.start.timeIntervalSinceNow < 900 { time.textColor = Pal.warning; time.font = Typo.caption.withWeight(.semibold) }
        setAccessibilityLabel("\(e.title), \(range)")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func common(title t: String, time ts: String, done: Bool) {
        let p = Pal
        roundLayer(Radius.l)
        layer?.backgroundColor = p.surface.cgColor
        addSubview(check)
        glyph.isHidden = true
        addSubview(glyph)
        if done {
            title.attributedStringValue = NSAttributedString(string: t, attributes: [
                .font: Typo.bodyMedium, .foregroundColor: p.textTertiary, .strikethroughStyle: NSUnderlineStyle.single.rawValue])
        } else {
            title.stringValue = t
            title.font = Typo.bodyMedium
            title.textColor = p.text
        }
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        time.stringValue = ts
        time.font = Typo.caption
        time.textColor = p.textSecondary
        time.alignment = .right
        time.lineBreakMode = .byTruncatingTail
        addSubview(time)
        remove.isHidden = true
        addSubview(remove)
    }

    @objc private func deleteTapped() { onDelete?() }

    override func layout() {
        super.layout()
        let h = bounds.height
        check.frame = NSRect(x: Space.m, y: (h - 20) / 2, width: 20, height: 20)
        glyph.frame = NSRect(x: Space.m + 2, y: (h - 16) / 2, width: 16, height: 16)
        remove.frame = NSRect(x: bounds.width - Space.s - Metrics.control, y: (h - Metrics.control) / 2, width: Metrics.control, height: Metrics.control)
        let rightEdge = remove.isHidden ? bounds.width - Space.m : remove.frame.minX - Space.xs
        let timeW = min(190, ceil((time.stringValue as NSString).size(withAttributes: [.font: time.font ?? Typo.caption]).width) + 4)
        time.frame = NSRect(x: rightEdge - timeW, y: (h - 15) / 2, width: timeW, height: 15)
        let textX = Space.m + 20 + Space.m
        title.frame = NSRect(x: textX, y: (h - 17) / 2, width: max(20, time.frame.minX - textX - Space.s), height: 17)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

private extension NSFont {
    func withWeight(_ w: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: pointSize, weight: w) }
}

/// Round coloured checkbox.
final class CircleCheck: NSView {
    var color: NSColor = Pal.accent { didSet { needsDisplay = true } }
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? "done" : "not done") } }
    var onTap: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() { super.init(frame: .zero); setAccessibilityRole(.checkBox) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(ovalIn: r)
        if isOn {
            color.setFill(); path.fill()
            if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))?
                .withSymbolConfiguration(.init(hierarchicalColor: .white)) {
                img.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        } else {
            color.setStroke(); path.lineWidth = 2; path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Reminders: Today / Upcoming / Completed, with a composer that folds out from the + button.
final class RemindersCard: CardBase, CardContent {
    var cardWidth: CGFloat { 400 }
    var say: ((String, ZeraMood) -> Void)?

    private let plusButton: IconButton
    private var composing = false
    private let composer = FlippedView()
    private let titleField = ThemedField(placeholder: "Remind me to…")
    private let modePopup = NSPopUpButton()
    private let timeBox = NSView()
    private let timePicker = NSDatePicker()
    private let everyPopup = NSPopUpButton()
    private let headsUp = Toggle()
    private let headsUpLabel = NSTextField(labelWithString: "15 min heads-up")
    private let addButton: CardButton
    private let tabs = PillTabs(titles: ["Today", "Upcoming", "Completed"])
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let empty = NSTextField(labelWithString: "")
    private var rows: [ReminderRow] = []

    private let maxRows = 6
    private let composerFullHeight: CGFloat = Space.m + Metrics.control + Space.s + Metrics.control + Space.m
    /// 0 when folded away.
    private var composerHeight: CGFloat { composing ? composerFullHeight + Space.m : 0 }
    private static let intervalChoices = [15, 20, 30, 45, 60, 90, 120, 180, 240]

    init() {
        addButton = CardButton("Add", style: .primary, target: nil, action: #selector(RemindersCard.saveTapped))
        plusButton = IconButton(symbol: "plus", label: "New reminder", target: nil, action: #selector(RemindersCard.plusTapped))
        super.init(width: 400, title: "Reminders")
        let p = Pal
        addButton.target = self
        plusButton.target = self
        addSubview(plusButton)

        composer.wantsLayer = true
        composer.isHidden = true
        composer.layer?.cornerRadius = Radius.l
        composer.layer?.cornerCurve = .continuous
        composer.layer?.backgroundColor = p.surface.cgColor
        addSubview(composer)
        composer.addSubview(titleField)
        composer.addSubview(addButton)

        modePopup.addItems(withTitles: Reminder.Repeat.allCases.map { $0.title })
        modePopup.selectItem(at: 1)
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        stylePopup(modePopup)
        composer.addSubview(modePopup)

        timeBox.wantsLayer = true
        timeBox.layer?.cornerRadius = Radius.m
        timeBox.layer?.cornerCurve = .continuous
        timeBox.layer?.backgroundColor = p.surfaceStrong.cgColor
        composer.addSubview(timeBox)
        timePicker.datePickerStyle = .textField
        timePicker.datePickerElements = .hourMinute
        timePicker.isBezeled = false
        timePicker.isBordered = false
        timePicker.drawsBackground = false
        timePicker.textColor = p.text
        timePicker.font = Typo.nav
        timePicker.dateValue = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
        timePicker.setAccessibilityLabel("Time")
        timeBox.addSubview(timePicker)

        everyPopup.addItems(withTitles: Self.intervalChoices.map { "every " + Reminder.intervalLabel($0) })
        everyPopup.selectItem(at: Self.intervalChoices.firstIndex(of: 120) ?? 0)
        stylePopup(everyPopup)
        composer.addSubview(everyPopup)

        headsUpLabel.font = Typo.caption; headsUpLabel.textColor = p.textSecondary; headsUpLabel.alignment = .right
        composer.addSubview(headsUpLabel)
        headsUp.setAccessibilityLabel("15 minute heads-up")
        composer.addSubview(headsUp)

        tabs.onSelect = { [weak self] _ in self?.reload() }
        addSubview(tabs)

        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = list
        addSubview(scroll)

        empty.font = Typo.body; empty.textColor = p.textSecondary; empty.alignment = .center
        addSubview(empty)

        modeChanged()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ReminderService.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isIntervalMode: Bool { modePopup.indexOfSelectedItem == Reminder.Repeat.allCases.firstIndex(of: .interval) }

    /// + opens the composer and focuses the title; a second tap (or Esc) folds it away.
    @objc private func plusTapped() { setComposing(!composing) }

    private func setComposing(_ on: Bool) {
        composing = on
        composer.isHidden = !on
        plusButton.setSymbol(on ? "xmark" : "plus", label: on ? "Close composer" : "New reminder")
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
        if on { window?.makeFirstResponder(titleField) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, composing { setComposing(false); return }
        super.keyDown(with: event)
    }

    @objc private func modeChanged() {
        let interval = isIntervalMode
        timeBox.isHidden = interval
        headsUp.isHidden = interval
        headsUpLabel.isHidden = interval
        everyPopup.isHidden = !interval
    }

    @objc private func saveTapped() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            say?("tell me what to remind you about 🙂", .thinking)
            window?.makeFirstResponder(titleField)
            return
        }
        let svc = ReminderService.shared
        if isIntervalMode {
            let n = Self.intervalChoices[max(0, min(Self.intervalChoices.count - 1, everyPopup.indexOfSelectedItem))]
            svc.addInterval(title: title, everyMinutes: n)
            say?("okay! \(title.lowercased()) every \(Reminder.intervalLabel(n)) 💜", .approved)
        } else {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
            let rule = Reminder.Repeat.allCases[max(0, min(Reminder.Repeat.allCases.count - 1, modePopup.indexOfSelectedItem))]
            svc.add(title: title, hour: comps.hour ?? 9, minute: comps.minute ?? 0, repeatRule: rule, leadMinutes: headsUp.isOn ? 15 : 0)
            say?("got it — \(title.lowercased()) at \(ReminderService.timeFormatter.string(from: timePicker.dateValue)) 💜", .approved)
        }
        titleField.stringValue = ""
        tabs.selected = 0
        setComposing(false)
        reload()
    }

    private func build() -> [ReminderRow] {
        let svc = ReminderService.shared
        let now = Date()
        var merged: [(Date, ReminderRow)] = []
        func row(_ r: Reminder) -> ReminderRow {
            let v = ReminderRow(reminder: r)
            v.onToggle = { svc.toggleDone(r.id) }
            v.onDelete = { [weak self] in svc.remove(r.id); self?.say?("removed", .idle) }
            return v
        }
        switch tabs.selected {
        case 0:
            for r in svc.todaysReminders where !r.isDoneToday {
                let t = r.isInterval ? Date.distantFuture : r.fireTime(on: now)
                if r.isInterval || t > now.addingTimeInterval(-3600 * 3) { merged.append((t, row(r))) }
            }
            for e in svc.calendarItems where Calendar.current.isDateInToday(e.start) && e.end > now.addingTimeInterval(-3600) {
                merged.append((e.start, ReminderRow(event: e)))
            }
        case 1:
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
            for r in svc.reminders where r.enabled && !r.isInterval && (r.repeatRule != .once ? r.applies(on: tomorrow) : (r.date ?? now) > now) {
                merged.append((r.fireTime(on: r.repeatRule == .once ? (r.date ?? tomorrow) : tomorrow), row(r)))
            }
            for e in svc.calendarItems where Calendar.current.isDateInTomorrow(e.start) { merged.append((e.start, ReminderRow(event: e))) }
        default:
            for r in svc.todaysReminders where r.isDoneToday { merged.append((r.fireTime(on: now), row(r))) }
            for e in svc.calendarItems where Calendar.current.isDateInToday(e.start) && e.end <= now { merged.append((e.start, ReminderRow(event: e))) }
        }
        merged.sort { $0.0 < $1.0 }
        return merged.map { $0.1 }
    }

    private var listTop: CGFloat { headerBottom + composerHeight + Metrics.control + 2 + Space.m }

    var desiredHeight: CGFloat {
        let n = rows.count
        let listH: CGFloat = n == 0 ? 36 : CGFloat(min(n, maxRows)) * (Metrics.row + Space.xs) - Space.xs
        return listTop + listH + Metrics.cardPad
    }

    @objc func reload() {
        let svc = ReminderService.shared
        rows.forEach { $0.removeFromSuperview() }
        rows = build()
        for r in rows { list.addSubview(r) }
        empty.isHidden = !rows.isEmpty
        switch tabs.selected {
        case 0: empty.stringValue = "You're clear for now."
        case 1: empty.stringValue = "Nothing scheduled for later."
        default: empty.stringValue = "Nothing completed yet today."
        }
        let open = svc.todaysReminders.filter { !$0.isDoneToday && !$0.isInterval }.count
        let rep = svc.reminders.filter { $0.isInterval && $0.enabled }.count
        var bits: [String] = []
        if open > 0 { bits.append("\(open) to do") }
        if rep > 0 { bits.append("\(rep) repeating") }
        if svc.calendarAuthorized, let t = svc.lastCalendarSync { bits.append("calendar synced \(relativeTime(t))") }
        setSubtitle(bits.isEmpty ? nil : bits.joined(separator: " · "))
        scroll.isHidden = rows.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    override func layout() {
        super.layout()
        layoutHeader(trailingWidth: 40)
        let x = Metrics.cardPad, w = bounds.width - x * 2
        plusButton.frame = NSRect(x: bounds.width - x - Metrics.control, y: Space.l - 3, width: Metrics.control, height: Metrics.control)
        composer.frame = NSRect(x: x, y: headerBottom, width: w, height: composerFullHeight)
        let cx = Space.m, cw = w - Space.m * 2
        let row1 = Space.m, row2 = Space.m + Metrics.control + Space.s
        let addW = addButton.fittedWidth
        titleField.frame = NSRect(x: cx, y: row1, width: cw - addW - Space.s, height: Metrics.control)
        addButton.frame = NSRect(x: cx + cw - addW, y: row1, width: addW, height: Metrics.control)
        modePopup.frame = NSRect(x: cx, y: row2, width: 104, height: Metrics.control)
        timeBox.frame = NSRect(x: cx + 104 + Space.s, y: row2, width: 92, height: Metrics.control)
        timePicker.frame = NSRect(x: Space.s, y: 4, width: 76, height: 20)
        everyPopup.frame = NSRect(x: cx + 104 + Space.s, y: row2, width: 136, height: Metrics.control)
        headsUp.frame = NSRect(x: cx + cw - 40, y: row2 + 3, width: 40, height: 22)
        headsUpLabel.frame = NSRect(x: cx + cw - 40 - Space.s - 92, y: row2 + 6, width: 92, height: 16)

        tabs.frame = NSRect(x: x, y: headerBottom + composerHeight, width: w, height: Metrics.control + 2)
        let y = listTop
        let box = NSRect(x: x, y: y, width: w, height: max(0, bounds.height - y - Metrics.cardPad))
        scroll.frame = box
        empty.frame = NSRect(x: x, y: y + 8, width: w, height: 20)
        var ry: CGFloat = 0
        for r in rows { r.frame = NSRect(x: 0, y: ry, width: box.width, height: Metrics.row); ry += Metrics.row + Space.xs }
        list.frame = NSRect(x: 0, y: 0, width: box.width, height: max(ry, box.height))
    }
}

/// The nudge itself: "You have a meeting in 15 minutes!" with Snooze / Done.
final class ReminderAlertCard: CardBase, CardContent {
    var cardWidth: CGFloat { 380 }
    var say: ((String, ZeraMood) -> Void)?
    var onDrained: (() -> Void)?

    private var tile: IconTile
    private let counter = NSTextField(labelWithString: "")
    private let snooze: CardButton
    private let done: CardButton
    private var current: ReminderAlert?

    init() {
        tile = IconTile(symbol: "bell.fill", color: Pal.warning, size: 34, pointSize: 15)
        snooze = CardButton("Snooze 5 min", style: .secondary, target: nil, action: #selector(ReminderAlertCard.snoozeTapped))
        done = CardButton("Done", style: .primary, target: nil, action: #selector(ReminderAlertCard.doneTapped))
        super.init(width: 380, title: "")
        snooze.target = self; done.target = self
        addSubview(tile)
        counter.font = Typo.caption; counter.textColor = Pal.textTertiary; counter.alignment = .right; addSubview(counter)
        addSubview(snooze); addSubview(done)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ReminderService.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    var desiredHeight: CGFloat { Space.l + 40 + Space.m + Metrics.button + Metrics.cardPad }

    @objc func reload() {
        let svc = ReminderService.shared
        current = svc.pendingAlerts.first
        guard let a = current else { onDrained?(); return }
        let isBreak = a.kind == .breakTime
        tile.removeFromSuperview()
        tile = IconTile(symbol: isBreak ? "cup.and.saucer.fill" : (a.kind == .calendarHeadsUp || a.kind == .calendarNow ? "calendar" : "bell.fill"),
                        color: isBreak ? Pal.info : (a.kind == .calendarHeadsUp || a.kind == .calendarNow ? Pal.tileCalendar : Pal.warning), size: 34, pointSize: 15)
        addSubview(tile)
        titleLabel.stringValue = a.headline
        setSubtitle(a.detail)
        counter.stringValue = svc.pendingAlerts.count > 1 ? "1 of \(svc.pendingAlerts.count)" : ""
        done.setTitleText(isBreak ? "Taking it ☕" : "Done")
        snooze.setTitleText(isBreak ? "In 5 min" : "Snooze 5 min")
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    @objc private func snoozeTapped() {
        guard let a = current else { return }
        ReminderService.shared.snooze(a)
        say?("okay, 5 more minutes", .idle)
    }

    @objc private func doneTapped() {
        guard let a = current else { return }
        ReminderService.shared.complete(a)
        say?(a.kind == .breakTime ? "enjoy it! ☕" : "nice ✨", a.kind == .breakTime ? .cozy : .happy)
    }

    override func layout() {
        super.layout()
        let x = Metrics.cardPad, w = bounds.width - x * 2
        tile.frame = NSRect(x: x, y: Space.l, width: 34, height: 34)
        counter.frame = NSRect(x: bounds.width - x - 60, y: Space.l + 2, width: 60, height: 14)
        titleLabel.frame = NSRect(x: x + 44, y: Space.l - 1, width: w - 44 - 66, height: 20)
        subtitleLabel.frame = NSRect(x: x + 44, y: Space.l + 20, width: w - 44, height: 16)
        let y = Space.l + 40 + Space.m
        let dw = max(80, done.fittedWidth), sw = snooze.fittedWidth
        done.frame = NSRect(x: bounds.width - x - dw, y: y, width: dw, height: Metrics.button)
        snooze.frame = NSRect(x: bounds.width - x - dw - Space.s - sw, y: y, width: sw, height: Metrics.button)
    }
}
