import AppKit

// Three separate forms — never one giant one:
//   • EventFormView     — Create / Edit Event (a calendar entry)
//   • ReminderFormView  — Create / Edit Reminder (a nudge, once or repeating, with active hours)
//   • HydrationFormView — the fast "Drink water every …" preset
// Each one is shown in the side panel of the Reminders & Calendar screen.

/// Scrolling form + footer (Cancel / primary). Subclasses add fields to `canvas`.
class ReminderFormBase: NSView {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var say: ((String, ZeraMood) -> Void)?

    // What the side panel's header shows while this form is open.
    var headerTitle: String { "" }
    var headerSubtitle: String { "" }
    var headerLook: AgendaLook { .reminder }
    var zeraPose: String { "card_writing" }

    let scroll = NSScrollView()
    let canvas = FormCanvas()
    let previewLabel = rlabel(NSFont.systemFont(ofSize: 12.5, weight: .medium), Pal.textSecondary, lines: 3)
    private let errorLabel = rlabel(NSFont.systemFont(ofSize: 12, weight: .semibold), Pal.danger)
    private(set) var cancelButton: PRActionButton!
    private(set) var saveButton: PRActionButton!
    var svc: ReminderService { ReminderService.shared }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(saveTitle: String, saveSymbol: String) {
        super.init(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = canvas
        addSubview(scroll)
        addSubview(errorLabel)
        cancelButton = PRActionButton("Cancel", style: .secondary, target: self, action: #selector(cancelTapped))
        saveButton = PRActionButton(saveTitle, style: .primary, symbol: saveSymbol, target: self, action: #selector(saveTapped))
        addSubview(cancelButton)
        addSubview(saveButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    func showError(_ s: String?) {
        errorLabel.stringValue = s ?? ""
        needsLayout = true
    }

    /// Re-evaluate which lines show (repeat → custom fields, active hours…) and the preview.
    func refresh() {
        showError(nil)
        needsLayout = true
    }

    @objc func saveTapped() {}
    @objc func cancelTapped() { onCancel?() }

    func focusFirstField(_ f: NSView) {
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(f) }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let bh: CGFloat = 38
        let sw = max(150, saveButton.fittedWidth + 8)
        saveButton.frame = NSRect(x: w - sw, y: h - bh, width: sw, height: bh)
        let cw = max(96, cancelButton.fittedWidth)
        cancelButton.frame = NSRect(x: saveButton.frame.minX - 10 - cw, y: h - bh, width: cw, height: bh)
        let errH: CGFloat = errorLabel.stringValue.isEmpty ? 0 : 20
        errorLabel.frame = NSRect(x: 0, y: h - bh - 8 - errH, width: w, height: errH)
        let bottom = h - bh - 12 - errH
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, bottom))
        let innerW = w - 14   // room for the overlay scroller
        let used = canvas.layoutLines(width: innerW)
        canvas.frame = NSRect(x: 0, y: 0, width: innerW, height: max(used + 8, scroll.frame.height))
    }

    // MARK: Shared helpers

    static func combine(day: Date, time: Date) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: time)
        return cal.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: day) ?? day
    }

    static func minutesOfDay(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func timeToday(minutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: (m / 60) % 24, minute: m % 60, second: 0, of: Date()) ?? Date()
    }

    /// The next whole half hour (default time for new items).
    static func nextHalfHour(_ now: Date = Date()) -> Date {
        let cal = Calendar.current
        let m = cal.component(.minute, from: now)
        let add = m < 30 ? 30 - m : 60 - m
        let d = now.addingTimeInterval(TimeInterval(add * 60))
        return cal.dateInterval(of: .minute, for: d)?.start ?? d
    }

    /// "Today: 11:00 AM, 1:00 PM, 3:00 PM … 6 in all · Tomorrow from 9:00 AM" — straight from the engine.
    static func preview(for r: Reminder, now: Date = Date()) -> String {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        guard let endToday = cal.date(byAdding: .day, value: 1, to: startToday),
              let endTomorrow = cal.date(byAdding: .day, value: 2, to: startToday) else { return "" }
        let t = ReminderFormat.time
        if r.rule.isInterval {
            let today = r.occurrences(from: now, to: endToday, limit: 300)
            var s: String
            if today.isEmpty { s = "Nothing more today" }
            else {
                s = "Today: " + today.prefix(4).map { t.string(from: $0) }.joined(separator: ", ")
                if today.count > 4 { s += " … \(today.count) in all" }
            }
            if let first = r.occurrences(from: endToday, to: endTomorrow, limit: 1).first {
                s += "\nTomorrow from " + t.string(from: first)
            }
            return s
        }
        guard let next = r.occurrences(from: now, to: now.addingTimeInterval(400 * 86400), limit: 3).first else {
            return r.rule.isRepeating ? "No upcoming times — check the end date." : "That time has passed — it will show as overdue."
        }
        var s = "Next: " + ReminderFormat.relativeDay(next, now: now) + " at " + t.string(from: next)
        if r.rule.isRepeating, let after = r.next(after: next) {
            s += " · then " + ReminderFormat.relativeDay(after, now: now) + " at " + t.string(from: after)
        }
        return s
    }

    /// The small "to" between two times.
    static func joiner(_ s: String) -> NSTextField {
        let l = rlabel(NSFont.systemFont(ofSize: 12.5, weight: .medium), Pal.textSecondary)
        l.stringValue = s
        l.alignment = .center
        return l
    }

    /// The first occurrence after now, on the active-hours grid (9:00, 10:00, … for "every hour").
    static func gridAnchor(rule: RepeatRule, activeStart: Int, activeEnd: Int, now: Date = Date()) -> Date {
        let start = timeToday(minutes: activeStart)
        let next = Recurrence.occurrences(anchor: start, rule: rule, activeStart: activeStart, activeEnd: activeEnd,
                                          from: now.addingTimeInterval(60), to: now.addingTimeInterval(3 * 86400), limit: 1).first
        return next ?? start
    }

    static func weekdayChips() -> ChoiceChips {
        let names = Calendar.current.veryShortWeekdaySymbols   // S M T W T F S (index 0 = Sunday)
        let c = ChoiceChips(items: names.map { .init(title: $0) })
        c.multiple = true
        c.fill = true
        return c
    }
}


// MARK: - Create / Edit Event

final class EventFormView: ReminderFormBase {
    private let editing: CalendarEvent?
    private let titleField = ThemedField(placeholder: "e.g. Design review")
    private let typeChips = ChoiceChips(items: CalendarEvent.Kind.allCases.map { .init(title: $0.title, symbol: $0.symbol) })
    private var calendarSelect: ZeraSelect!
    private let dateBox = PickerBox(time: false)
    private let timeBox = PickerBox(time: true)
    private let durationSelect = ZeraSelect(EventFormView.durationTitles)
    private let allDay = Toggle()
    private let allDayLabel = rlabel(NSFont.systemFont(ofSize: 13, weight: .medium), Pal.text)
    private let repeatSelect = ZeraSelect(EventFormView.repeatTitles, symbols: EventFormView.repeatSymbols)
    private let everyCount = CountField()
    private let everyUnit = ZeraSelect(["days", "weeks", "months"])
    private let weekdays = ReminderFormBase.weekdayChips()
    private let endsChips = ChoiceChips(items: [.init(title: "Never"), .init(title: "On date")])
    private let endDateBox = PickerBox(time: false)
    private let locationField = ThemedField(placeholder: "Room, address or call link")
    private let notes = notesField("Add a description")
    private let alertSelect = ZeraSelect(EventFormView.alertTitles, symbols: EventFormView.alertTitles.map { t -> String? in t == "None" ? "bell.slash" : "bell" })

    private var calendarLine: FormCanvas.Line!
    private var customLine: FormCanvas.Line!
    private var weekdayLine: FormCanvas.Line!
    private var endsLine: FormCanvas.Line!
    private var calendars: [WritableCalendar] = []

    private static let kinds = CalendarEvent.Kind.allCases
    private static let durations = [15, 30, 45, 60, 90, 120, 180, 240, 480]
    private static let durationTitles = ["15 min", "30 min", "45 min", "1 hour", "1.5 hours", "2 hours", "3 hours", "4 hours", "8 hours"]
    private static let repeatTitles = ["Does not repeat", "Every day", "Every weekday", "Every week", "Every month", "Every year", "Custom…"]
    private static let repeatSymbols: [String?] = ["minus.circle", "sun.max", "briefcase", "calendar", "calendar.circle", "gift", "slider.horizontal.3"]
    private static let customUnits: [RepeatRule.Unit] = [.day, .week, .month]
    private static let alerts = [-1, 0, 5, 10, 15, 30, 60, 1440]
    private static let alertTitles = ["None", "At start", "5 min before", "10 min before", "15 min before", "30 min before", "1 hour before", "1 day before"]

    override var headerTitle: String { editing == nil ? "Create Event" : "Edit Event" }
    override var headerSubtitle: String { "A meeting, focus block or plan on your calendar" }
    override var headerLook: AgendaLook { .source(.custom) }
    override var zeraPose: String { "card_writing" }

    init(editing: CalendarEvent?) {
        self.editing = editing
        super.init(saveTitle: editing == nil ? "Create Event" : "Save Changes", saveSymbol: editing == nil ? "plus" : "checkmark")
        calendars = editing == nil ? svc.writableCalendars : []
        calendarSelect = ZeraSelect(["Zera — this Mac only"] + calendars.map { "\($0.title) · \($0.source.title)" },
                                    symbols: [String?](["sparkles"]) + calendars.map { _ -> String? in "calendar" })
        typeChips.fill = true
        allDayLabel.stringValue = "All-day"
        allDay.onChange = { [weak self] _ in self?.refresh() }
        [dateBox, timeBox, endDateBox].forEach { $0.onChange = { [weak self] in self?.refresh() } }
        [durationSelect, repeatSelect, everyUnit, alertSelect, calendarSelect!].forEach { $0.onChange = { [weak self] _ in self?.refresh() } }
        everyCount.maxValue = 99
        everyCount.onChange = { [weak self] _ in self?.refresh() }
        weekdays.onChange = { [weak self] _ in self?.refresh() }
        endsChips.onChange = { [weak self] _ in self?.refresh() }
        typeChips.onChange = { [weak self] _ in self?.refresh() }

        typealias C = FormCanvas.Control
        typealias Col = FormCanvas.Column
        let L = FormCanvas.label
        canvas.add([Col(label: L("Title"), controls: [C(view: titleField)])])
        canvas.add([Col(label: L("Type"), controls: [C(view: typeChips)])], height: 32)
        canvas.add([Col(label: L("Date"), controls: [C(view: dateBox)]),
                    Col(label: L("Start time"), controls: [C(view: timeBox)])])
        canvas.add([Col(label: L("Duration"), controls: [C(view: durationSelect)]),
                    Col(label: L("All-day"), controls: [C(view: allDay, width: 40, height: 22), C(view: allDayLabel, height: 18)])])
        canvas.add([Col(label: L("Repeat"), controls: [C(view: repeatSelect)]),
                    Col(label: L("Remind me"), controls: [C(view: alertSelect)])])
        customLine = canvas.add([Col(label: L("Every"), controls: [C(view: everyCount, width: 120), C(view: everyUnit)])])
        weekdayLine = canvas.add([Col(label: L("On"), controls: [C(view: weekdays)])], height: 30)
        endsLine = canvas.add([Col(label: L("Ends"), controls: [C(view: endsChips, width: 170), C(view: endDateBox)])])
        calendarLine = canvas.add([Col(label: L("Calendar"), controls: [C(view: calendarSelect)])])
        canvas.add([Col(label: L("Location"), controls: [C(view: locationField)])])
        canvas.add([Col(label: L("Description"), controls: [C(view: notes)])])
        canvas.add([Col(label: nil, controls: [C(view: previewLabel)])], height: 40)

        fill()
        refresh()
        focusFirstField(titleField)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func fill() {
        let now = Date()
        endsChips.selection = [0]
        guard let e = editing else {
            let start = ReminderFormBase.nextHalfHour(now)
            dateBox.date = start
            timeBox.date = start
            typeChips.selection = [0]
            durationSelect.select(1)
            alertSelect.select(Self.alerts.firstIndex(of: 10) ?? 3)
            endDateBox.date = Calendar.current.date(byAdding: .month, value: 1, to: now) ?? now
            weekdays.selection = [Calendar.current.component(.weekday, from: start) - 1]
            return
        }
        titleField.stringValue = e.title
        typeChips.selection = [Self.kinds.firstIndex(of: e.kind) ?? 0]
        dateBox.date = e.startAt
        timeBox.date = e.startAt
        allDay.isOn = e.isAllDay
        let mins = Int(e.duration / 60)
        let closest = Self.durations.enumerated().min { abs($0.element - mins) < abs($1.element - mins) }?.offset ?? 1
        durationSelect.select(closest)
        locationField.stringValue = e.location
        notes.stringValue = e.notes
        alertSelect.select(Self.alerts.firstIndex(of: e.alertMinutes) ?? (Self.alerts.firstIndex(of: 10) ?? 3))
        let r = e.rule
        weekdays.selection = Set((r.weekdays.isEmpty ? [Calendar.current.component(.weekday, from: e.startAt)] : r.weekdays).map { $0 - 1 })
        endDateBox.date = r.endDate ?? (Calendar.current.date(byAdding: .month, value: 1, to: e.startAt) ?? now)
        endsChips.selection = [r.endDate == nil ? 0 : 1]
        switch (r.unit, r.every) {
        case (RepeatRule.Unit.none, _): repeatSelect.select(0)
        case (.day, 1): repeatSelect.select(1)
        case (.week, 1) where Set(r.weekdays) == [2, 3, 4, 5, 6]: repeatSelect.select(2)
        case (.week, 1) where r.weekdays.count <= 1: repeatSelect.select(3)
        case (.month, 1): repeatSelect.select(4)
        case (.year, 1): repeatSelect.select(5)
        default:
            repeatSelect.select(6)
            everyCount.value = r.every
            everyUnit.select(Self.customUnits.firstIndex(of: r.unit) ?? 0)
        }
    }

    private var rule: RepeatRule {
        var r: RepeatRule
        switch repeatSelect.selectedIndex {
        case 1: r = .daily
        case 2: r = .weekdaysOnly
        case 3: r = .weekly
        case 4: r = .monthly
        case 5: r = .yearly
        case 6:
            let unit = Self.customUnits[max(0, min(Self.customUnits.count - 1, everyUnit.selectedIndex))]
            r = RepeatRule(unit: unit, every: everyCount.value)
            if unit == .week { r.weekdays = weekdays.selection.map { $0 + 1 }.sorted() }
        default: r = .noRepeat
        }
        if r.isRepeating, endsChips.selectedIndex == 1 { r.endDate = Calendar.current.startOfDay(for: endDateBox.date) }
        return r
    }

    private var startDate: Date {
        allDay.isOn ? Calendar.current.startOfDay(for: dateBox.date) : ReminderFormBase.combine(day: dateBox.date, time: timeBox.date)
    }

    override func refresh() {
        let custom = repeatSelect.selectedIndex == 6
        customLine.isHidden = !custom
        weekdayLine.isHidden = !(custom && everyUnit.selectedIndex == 1)
        endsLine.isHidden = repeatSelect.selectedIndex == 0
        endDateBox.isEnabled = endsChips.selectedIndex == 1
        calendarLine.isHidden = calendars.isEmpty
        timeBox.isEnabled = !allDay.isOn
        durationSelect.isEnabled = !allDay.isOn
        let start = startDate
        let r = rule
        var text = ReminderFormat.relativeDay(start) + (allDay.isOn ? " · all day" : " at " + ReminderFormat.time.string(from: start))
        if r.isRepeating { text += " · " + r.title.lowercased() }
        let ci = calendarSelect.selectedIndex
        if ci > 0, ci - 1 < calendars.count {
            text += "\nAdded to \(calendars[ci - 1].title) (\(calendars[ci - 1].source.title)) through macOS Calendar."
        } else {
            text += "\nKept by Zera on this Mac."
        }
        previewLabel.stringValue = text
        super.refresh()
    }

    override func saveTapped() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            showError("Give the event a title.")
            window?.makeFirstResponder(titleField)
            return
        }
        let start = startDate
        let r = rule
        if let end = r.endDate, end < Calendar.current.startOfDay(for: start) {
            showError("The end date is before the event starts.")
            return
        }
        var ev = editing ?? CalendarEvent(title: title, startAt: start)
        ev.title = title
        ev.startAt = start
        ev.kind = Self.kinds[max(0, min(Self.kinds.count - 1, typeChips.selectedIndex))]
        ev.isAllDay = allDay.isOn
        ev.duration = allDay.isOn ? 86400 : TimeInterval(Self.durations[max(0, min(Self.durations.count - 1, durationSelect.selectedIndex))] * 60)
        ev.rule = r
        ev.location = locationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ev.notes = notes.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ev.alertMinutes = Self.alerts[max(0, min(Self.alerts.count - 1, alertSelect.selectedIndex))]

        let ci = calendarSelect.selectedIndex
        if editing == nil, ci > 0, ci - 1 < calendars.count {
            let target = calendars[ci - 1]
            do {
                try svc.createInCalendar(ev, calendarID: target.id)
                say?("added to \(target.title) 📅", .approved)
            } catch {
                showError("Couldn't add it to \(target.title). Check Calendar access in System Settings.")
                return
            }
        } else {
            svc.save(event: ev)
            say?(editing == nil ? "event created 📅" : "event updated ✨", .approved)
        }
        onDone?()
    }
}

// MARK: - Create / Edit Reminder

final class ReminderFormView: ReminderFormBase {
    private let editing: Reminder?
    private let titleField = ThemedField(placeholder: "e.g. Send the weekly update")
    private let notes = notesField("Notes (optional)")
    private let dateBox = PickerBox(time: false)
    private let timeBox = PickerBox(time: true)
    private let repeatSelect = ZeraSelect(ReminderFormView.repeatTitles, symbols: ReminderFormView.repeatSymbols)
    private let everyCount = CountField()
    private let everyUnit = ZeraSelect(["minutes", "hours", "days", "weeks"])
    private let activeToggle = Toggle()
    private let activeLabel = rlabel(NSFont.systemFont(ofSize: 13, weight: .medium), Pal.text)
    private let activeFrom = PickerBox(time: true)
    private let activeTo = PickerBox(time: true)
    private let toLabel = ReminderFormBase.joiner("to")
    private let endsChips = ChoiceChips(items: [.init(title: "Never"), .init(title: "On date")])
    private let endDateBox = PickerBox(time: false)

    private var customLine: FormCanvas.Line!
    private var activeLine: FormCanvas.Line!
    private var activeTimesLine: FormCanvas.Line!
    private var endsLine: FormCanvas.Line!

    private static let repeatTitles = ["Does not repeat", "Every day", "Every 2 hours", "Every 3 hours", "Every 4 hours", "Every week", "Custom…"]
    private static let repeatSymbols: [String?] = ["minus.circle", "sun.max", "clock", "clock", "clock", "calendar", "slider.horizontal.3"]
    private static let customUnits: [RepeatRule.Unit] = [.minute, .hour, .day, .week]

    override var headerTitle: String { editing == nil ? "Create Reminder" : "Edit Reminder" }
    override var headerSubtitle: String { "A nudge from Zera — once, or on a schedule" }
    override var headerLook: AgendaLook { .reminder }
    override var zeraPose: String { "pencil" }

    init(editing: Reminder?) {
        self.editing = editing
        super.init(saveTitle: editing == nil ? "Create Reminder" : "Save Changes", saveSymbol: editing == nil ? "bell.badge" : "checkmark")
        activeLabel.stringValue = "Only during set hours"
        activeToggle.onChange = { [weak self] _ in self?.refresh() }
        [dateBox, timeBox, activeFrom, activeTo, endDateBox].forEach { $0.onChange = { [weak self] in self?.refresh() } }
        [repeatSelect, everyUnit].forEach { $0.onChange = { [weak self] _ in self?.refresh() } }
        everyCount.maxValue = 999
        everyCount.onChange = { [weak self] _ in self?.refresh() }
        endsChips.onChange = { [weak self] _ in self?.refresh() }

        typealias C = FormCanvas.Control
        typealias Col = FormCanvas.Column
        let L = FormCanvas.label
        canvas.add([Col(label: L("Title"), controls: [C(view: titleField)])])
        canvas.add([Col(label: L("Notes"), controls: [C(view: notes)])])
        canvas.add([Col(label: L("Date"), controls: [C(view: dateBox)]),
                    Col(label: L("Time"), controls: [C(view: timeBox)])])
        canvas.add([Col(label: L("Repeat"), controls: [C(view: repeatSelect)])])
        customLine = canvas.add([Col(label: L("Every"), controls: [C(view: everyCount, width: 120), C(view: everyUnit)])])
        activeLine = canvas.add([Col(label: L("Active hours"), controls: [C(view: activeToggle, width: 40, height: 22), C(view: activeLabel, height: 18)])])
        activeTimesLine = canvas.add([Col(label: L("Between"), controls: [C(view: activeFrom), C(view: toLabel, width: 24, height: 18), C(view: activeTo)])])
        endsLine = canvas.add([Col(label: L("Ends"), controls: [C(view: endsChips, width: 170), C(view: endDateBox)])])
        canvas.add([Col(label: nil, controls: [C(view: previewLabel)])], height: 40)

        fill()
        refresh()
        focusFirstField(titleField)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func fill() {
        let now = Date()
        activeFrom.date = ReminderFormBase.timeToday(minutes: 9 * 60)
        activeTo.date = ReminderFormBase.timeToday(minutes: 21 * 60)
        endDateBox.date = Calendar.current.date(byAdding: .month, value: 1, to: now) ?? now
        endsChips.selection = [0]
        guard let r = editing else {
            let start = ReminderFormBase.nextHalfHour(now)
            dateBox.date = start
            timeBox.date = start
            return
        }
        titleField.stringValue = r.title
        notes.stringValue = r.notes
        dateBox.date = r.scheduledAt
        timeBox.date = r.scheduledAt
        if let s = r.activeStart, let e = r.activeEnd {
            activeToggle.isOn = r.hasActiveHours
            activeFrom.date = ReminderFormBase.timeToday(minutes: s)
            activeTo.date = ReminderFormBase.timeToday(minutes: e)
        }
        if let end = r.rule.endDate { endsChips.selection = [1]; endDateBox.date = end }
        let rule = r.rule
        switch (rule.unit, rule.every) {
        case (RepeatRule.Unit.none, _): repeatSelect.select(0)
        case (.day, 1): repeatSelect.select(1)
        case (.hour, 2): repeatSelect.select(2)
        case (.hour, 3): repeatSelect.select(3)
        case (.hour, 4): repeatSelect.select(4)
        case (.week, 1) where rule.weekdays.count <= 1: repeatSelect.select(5)
        default:
            repeatSelect.select(6)
            everyCount.value = rule.every
            everyUnit.select(Self.customUnits.firstIndex(of: rule.unit) ?? 1)
        }
    }

    private var rule: RepeatRule {
        var r: RepeatRule
        switch repeatSelect.selectedIndex {
        case 1: r = .daily
        case 2: r = .hours(2)
        case 3: r = .hours(3)
        case 4: r = .hours(4)
        case 5: r = .weekly
        case 6:
            let unit = Self.customUnits[max(0, min(Self.customUnits.count - 1, everyUnit.selectedIndex))]
            r = RepeatRule(unit: unit, every: everyCount.value)
        default: r = .noRepeat
        }
        if r.isRepeating, endsChips.selectedIndex == 1 { r.endDate = Calendar.current.startOfDay(for: endDateBox.date) }
        return r
    }

    /// The reminder as the form currently describes it (used for the live preview and saving).
    private func draft(title: String) -> Reminder {
        var r = editing ?? Reminder(title: title, scheduledAt: Date())
        r.title = title
        r.notes = notes.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        r.scheduledAt = ReminderFormBase.combine(day: dateBox.date, time: timeBox.date)
        r.rule = rule
        if r.rule.isInterval, activeToggle.isOn {
            r.activeStart = ReminderFormBase.minutesOfDay(activeFrom.date)
            r.activeEnd = ReminderFormBase.minutesOfDay(activeTo.date)
        } else {
            r.activeStart = nil
            r.activeEnd = nil
        }
        return r
    }

    override func refresh() {
        let custom = repeatSelect.selectedIndex == 6
        customLine.isHidden = !custom
        let r = rule
        activeLine.isHidden = !r.isInterval
        activeTimesLine.isHidden = !(r.isInterval && activeToggle.isOn)
        endsLine.isHidden = !r.isRepeating
        endDateBox.isEnabled = endsChips.selectedIndex == 1
        everyCount.minValue = custom && everyUnit.selectedIndex == 0 ? 5 : 1
        previewLabel.stringValue = ReminderFormBase.preview(for: draft(title: "x"))
        super.refresh()
    }

    override func saveTapped() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            showError("What should Zera remind you about?")
            window?.makeFirstResponder(titleField)
            return
        }
        let r = draft(title: title)
        if r.rule.unit == .minute, r.rule.every < 5 { showError("Every 5 minutes is the shortest."); return }
        if let end = r.rule.endDate, end < Calendar.current.startOfDay(for: r.scheduledAt) {
            showError("The end date is before the first reminder.")
            return
        }
        if r.hasActiveHours, r.occurrences(from: Date(), to: Date().addingTimeInterval(3 * 86400), limit: 1).isEmpty {
            showError("No reminder fits inside those hours.")
            return
        }
        svc.save(reminder: r)
        say?(editing == nil ? "got it — I'll remind you 🔔" : "reminder updated ✨", .approved)
        onDone?()
    }
}

// MARK: - Hydration

/// "Drink water · every 1h · between 9:00 AM and 9:00 PM" — that's all there is to it. It starts
/// right away, on the hour grid of your active hours (so every hour means 10:00, 11:00, …).
final class HydrationFormView: ReminderFormBase {
    private let editing: Reminder?
    private let titleField = ThemedField(placeholder: "Drink water")
    private let intervals = ChoiceChips(items: [.init(title: "30m"), .init(title: "1h"), .init(title: "2h"), .init(title: "3h"), .init(title: "Custom")])
    private let customMinutes = CountField()
    private let customUnitLabel = ReminderFormBase.joiner("minutes")
    private let activeFrom = PickerBox(time: true)
    private let activeTo = PickerBox(time: true)
    private let toLabel = ReminderFormBase.joiner("to")
    private var customLine: FormCanvas.Line!

    private static let presets = [30, 60, 120, 180]

    override var headerTitle: String { editing == nil ? "Hydration Reminder" : "Edit Hydration" }
    override var headerSubtitle: String { "Zera reminds you to drink water through the day 💧" }
    override var headerLook: AgendaLook { .hydration }
    override var zeraPose: String { "boba" }

    init(editing: Reminder?) {
        self.editing = editing
        super.init(saveTitle: editing == nil ? "Create Hydration Reminder" : "Save Changes", saveSymbol: "drop.fill")
        intervals.fill = true
        intervals.selection = [1]
        intervals.onChange = { [weak self] _ in self?.refresh() }
        customMinutes.minValue = 10
        customMinutes.maxValue = 480
        customMinutes.step = 15
        customMinutes.value = 45
        customMinutes.onChange = { [weak self] _ in self?.refresh() }
        [activeFrom, activeTo].forEach { $0.onChange = { [weak self] in self?.refresh() } }

        typealias C = FormCanvas.Control
        typealias Col = FormCanvas.Column
        let L = FormCanvas.label
        canvas.add([Col(label: L("Reminder"), controls: [C(view: titleField)])])
        canvas.add([Col(label: L("Remind me every"), controls: [C(view: intervals)])], height: 34)
        customLine = canvas.add([Col(label: L("Custom interval"), controls: [C(view: customMinutes, width: 150), C(view: customUnitLabel, width: 60, height: 18)])])
        canvas.add([Col(label: L("Between"), controls: [C(view: activeFrom), C(view: toLabel, width: 24, height: 18), C(view: activeTo)])])
        canvas.add([Col(label: nil, controls: [C(view: previewLabel)])], height: 60)

        fill()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func fill() {
        titleField.stringValue = "Drink water"
        activeFrom.date = ReminderFormBase.timeToday(minutes: 9 * 60)
        activeTo.date = ReminderFormBase.timeToday(minutes: 21 * 60)
        guard let r = editing else { return }
        titleField.stringValue = r.title
        let m = Int(r.rule.intervalSeconds / 60)
        if let i = Self.presets.firstIndex(of: m) { intervals.selection = [i] } else { intervals.selection = [4]; customMinutes.value = m }
        if let s = r.activeStart, let e = r.activeEnd {
            activeFrom.date = ReminderFormBase.timeToday(minutes: s)
            activeTo.date = ReminderFormBase.timeToday(minutes: e)
        }
    }

    private var minutes: Int {
        let i = intervals.selectedIndex
        return i < Self.presets.count ? Self.presets[i] : customMinutes.value
    }

    private func draft(title: String, now: Date = Date()) -> Reminder {
        let m = minutes
        let rule: RepeatRule = m % 60 == 0 ? .hours(m / 60) : .minutes(m)
        let start = ReminderFormBase.minutesOfDay(activeFrom.date)
        let end = ReminderFormBase.minutesOfDay(activeTo.date)
        let anchor = ReminderFormBase.gridAnchor(rule: rule, activeStart: start, activeEnd: end, now: now)
        var r = editing ?? Reminder(title: title, category: .hydration, scheduledAt: anchor)
        r.title = title
        r.category = .hydration
        r.scheduledAt = anchor
        r.rule = rule
        r.activeStart = start
        r.activeEnd = end
        return r
    }

    override func refresh() {
        customLine.isHidden = intervals.selectedIndex != 4
        let now = Date()
        let r = draft(title: "x", now: now)
        let cal = Calendar.current
        let endToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let today = r.occurrences(from: now, to: endToday, limit: 300)
        let t = ReminderFormat.time
        var lines: [String] = []
        if let first = today.first {
            lines.append("First reminder at " + t.string(from: first) + (today.count > 1 ? " · \(today.count) today" : ""))
        } else if let next = r.occurrences(from: now, to: now.addingTimeInterval(2 * 86400), limit: 1).first {
            lines.append("First reminder " + ReminderFormat.relativeDay(next, now: now).lowercased() + " at " + t.string(from: next))
        }
        lines.append("Every " + Reminder.intervalLabel(minutes) + ", from " + ReminderFormat.clock(minutes: r.activeStart ?? 540)
                     + " to " + ReminderFormat.clock(minutes: r.activeEnd ?? 1260) + ", every day")
        previewLabel.stringValue = lines.joined(separator: "\n")
        super.refresh()
    }

    override func saveTapped() {
        var title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Drink water" }
        let r = draft(title: title)
        guard r.hasActiveHours else { showError("Pick different start and end times."); return }
        if r.occurrences(from: Date(), to: Date().addingTimeInterval(3 * 86400), limit: 1).isEmpty {
            showError("No reminder fits between those times.")
            return
        }
        svc.save(reminder: r)
        say?(editing == nil ? "I'll remind you to drink water every \(Reminder.intervalLabel(minutes)) 💧" : "hydration updated 💧", .love)
        onDone?()
    }
}
