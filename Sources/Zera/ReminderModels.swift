import Foundation

// MARK: - Reminders & Calendar: data
//
// Two separate things, never mixed:
//   • CalendarEvent — something that happens at a time (a meeting, focus block…). Either one
//     Zera keeps itself (`source == .custom`) or one read from macOS Calendar, labelled with
//     the account it really comes from.
//   • Reminder — something Zera nudges you about, once or on a schedule. Hydration is just a
//     reminder with `category == .hydration`.
// Both repeat through the same `RepeatRule` + `Recurrence` engine, which is what the scheduler
// fires from — what you see in the list is exactly what will go off.
//
// Everything here is plain Foundation so it can be unit-tested. Nothing in this file (or the
// service) is ever sent to Claude.

/// How something repeats.
struct RepeatRule: Codable, Equatable {
    enum Unit: String, Codable, CaseIterable {
        case none, minute, hour, day, week, month, year
    }

    var unit: Unit = .none
    /// Every N units (≥ 1).
    var every: Int = 1
    /// Weekly only: which weekdays, 1 = Sunday … 7 = Saturday. Empty = the start's weekday.
    var weekdays: [Int] = []
    /// Last day it can happen on (inclusive). nil = forever.
    var endDate: Date? = nil

    init(unit: Unit = .none, every: Int = 1, weekdays: [Int] = [], endDate: Date? = nil) {
        self.unit = unit
        self.every = max(1, every)
        self.weekdays = weekdays
        self.endDate = endDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = (try? c.decode(Unit.self, forKey: .unit)) ?? Unit.none
        every = max(1, (try? c.decode(Int.self, forKey: .every)) ?? 1)
        weekdays = (try? c.decode([Int].self, forKey: .weekdays)) ?? []
        endDate = try? c.decodeIfPresent(Date.self, forKey: .endDate)
    }

    static let noRepeat = RepeatRule()
    static let daily = RepeatRule(unit: .day)
    static let weekly = RepeatRule(unit: .week)
    static let weekdaysOnly = RepeatRule(unit: .week, weekdays: [2, 3, 4, 5, 6])
    static let monthly = RepeatRule(unit: .month)
    static let yearly = RepeatRule(unit: .year)
    static func hours(_ n: Int) -> RepeatRule { RepeatRule(unit: .hour, every: n) }
    static func minutes(_ n: Int) -> RepeatRule { RepeatRule(unit: .minute, every: n) }

    var isRepeating: Bool { unit != Unit.none }
    /// Minutes / hours: an interval within the day (where active hours apply).
    var isInterval: Bool { unit == .minute || unit == .hour }

    /// Seconds between occurrences for the interval units.
    var intervalSeconds: TimeInterval {
        switch unit {
        case .minute: return TimeInterval(every * 60)
        case .hour: return TimeInterval(every * 3600)
        default: return 0
        }
    }

    /// "Every 2 hours", "Every weekday", "Does not repeat"…
    var title: String {
        let n = every
        func plural(_ one: String, _ many: String) -> String { n == 1 ? "Every \(one)" : "Every \(n) \(many)" }
        switch unit {
        case .none: return "Does not repeat"
        case .minute: return plural("minute", "minutes")
        case .hour: return plural("hour", "hours")
        case .day: return plural("day", "days")
        case .week:
            let set = Set(weekdays)
            if set == [2, 3, 4, 5, 6], n == 1 { return "Every weekday" }
            if set.isEmpty || set.count == 1 { return plural("week", "weeks") }
            let names = Calendar.current.shortWeekdaySymbols
            let days = weekdays.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: ", ")
            return (n == 1 ? "Weekly" : "Every \(n) weeks") + " on " + days
        case .month: return plural("month", "months")
        case .year: return plural("year", "years")
        }
    }
}

/// The recurrence engine. Pure functions of (start, rule, active hours, range): the list, the
/// detail panel and the scheduler all ask it the same question.
enum Recurrence {
    /// Every occurrence in `[from, to)`, in order.
    ///
    /// - `anchor`: the first occurrence (date and time of day).
    /// - Interval rules (minutes / hours) with active hours restart each day at `activeStart`
    ///   and stop after `activeEnd` (both minutes after midnight; the end is inclusive).
    ///   "Every 2 hours, 9 AM → 9 PM" gives 9, 11, 1, 3, 5, 7, 9 — every day. On the start's own
    ///   day the series runs from the start itself.
    /// - Day / week / month / year rules keep the start's time of day.
    static func occurrences(anchor: Date, rule: RepeatRule, activeStart: Int? = nil, activeEnd: Int? = nil,
                            from: Date, to: Date, calendar cal: Calendar = .current, limit: Int = 500) -> [Date] {
        guard to > from, limit > 0 else { return [] }
        let hardEnd: Date = {
            guard let e = rule.endDate else { return to }
            let afterEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e)) ?? e
            return min(to, afterEnd)
        }()
        guard hardEnd > from else { return [] }
        var out: [Date] = []
        func add(_ d: Date) -> Bool {
            if d >= from && d < hardEnd && d >= anchor { out.append(d) }
            return out.count < limit
        }

        switch rule.unit {
        case .none:
            _ = add(anchor)

        case .minute, .hour:
            let step = rule.intervalSeconds
            guard step > 0 else { return [] }
            if let s = activeStart, let e = activeEnd, s != e {
                // Window per day: [day + s, day + s + length], length wrapping past midnight.
                let length = TimeInterval(((e - s) % 1440 + 1440) % 1440) * 60
                var day = cal.startOfDay(for: max(anchor, from))
                day = cal.date(byAdding: .day, value: -1, to: day) ?? day   // a window can spill over midnight
                var guardDays = 0
                while day < hardEnd, guardDays < 4000 {
                    guardDays += 1
                    let windowStart = cal.date(bySettingHour: (s / 60) % 24, minute: s % 60, second: 0, of: day)
                        ?? day.addingTimeInterval(TimeInterval(s) * 60)
                    let windowEnd = windowStart.addingTimeInterval(length)
                    // On the start's own day the series runs from the start itself ("starting now");
                    // every later day restarts at the beginning of the active hours.
                    var t = windowStart
                    if anchor > windowStart { t = anchor }
                    if t < from {
                        let k = ceil(from.timeIntervalSince(t) / step - 1e-9)
                        t = t.addingTimeInterval(k * step)
                    }
                    while t <= windowEnd + 0.5 {
                        if t >= hardEnd { return out }
                        if !add(t) { return out }
                        t = t.addingTimeInterval(step)
                    }
                    guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
            } else {
                var t = anchor
                if from > anchor {
                    let k = ceil(from.timeIntervalSince(anchor) / step - 1e-9)
                    t = anchor.addingTimeInterval(k * step)
                }
                while t < hardEnd {
                    if !add(t) { return out }
                    t = t.addingTimeInterval(step)
                }
            }

        case .day, .month, .year:
            let comp: Calendar.Component = rule.unit == .day ? .day : (rule.unit == .month ? .month : .year)
            // Skip straight to the neighbourhood of `from` instead of walking from the start.
            var k = 0
            if from > anchor {
                let diff = cal.dateComponents([comp], from: anchor, to: from).value(for: comp) ?? 0
                k = max(0, diff / rule.every - 1)
            }
            var guardSteps = 0
            while guardSteps < 20000 {
                guardSteps += 1
                // Always from the start (not step by step), so 31 Jan + 1 month stays on the 31st when it can.
                guard let t = cal.date(byAdding: comp, value: k * rule.every, to: anchor) else { break }
                if t >= hardEnd { break }
                if !add(t) { break }
                k += 1
            }

        case .week:
            let anchorWeekday = cal.component(.weekday, from: anchor)
            let days = (rule.weekdays.isEmpty ? [anchorWeekday] : rule.weekdays).filter { (1...7).contains($0) }.sorted()
            // Start of the anchor's week (by the calendar's first weekday).
            let anchorWeek = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? cal.startOfDay(for: anchor)
            let tod = cal.dateComponents([.hour, .minute, .second], from: anchor)
            var w = 0
            if from > anchorWeek {
                let diff = cal.dateComponents([.weekOfYear], from: anchorWeek, to: from).weekOfYear ?? 0
                w = max(0, diff / rule.every - 1)
            }
            var guardWeeks = 0
            while guardWeeks < 5000 {
                guardWeeks += 1
                guard let weekStart = cal.date(byAdding: .weekOfYear, value: w * rule.every, to: anchorWeek) else { break }
                if weekStart >= hardEnd { break }
                var dayList: [Date] = []
                for offset in 0..<7 {
                    guard let d = cal.date(byAdding: .day, value: offset, to: weekStart) else { continue }
                    if days.contains(cal.component(.weekday, from: d)),
                       let t = cal.date(bySettingHour: tod.hour ?? 0, minute: tod.minute ?? 0, second: tod.second ?? 0, of: d) {
                        dayList.append(t)
                    }
                }
                for t in dayList.sorted() {
                    if t >= hardEnd { return out }
                    if !add(t) { return out }
                }
                w += 1
            }
        }
        return out
    }

    /// The first occurrence strictly after `date`.
    static func next(after date: Date, anchor: Date, rule: RepeatRule, activeStart: Int? = nil, activeEnd: Int? = nil,
                     calendar cal: Calendar = .current) -> Date? {
        let from = date.addingTimeInterval(1)
        let horizon: TimeInterval
        switch rule.unit {
        case .none: horizon = max(0, anchor.timeIntervalSince(from)) + 1
        case .minute, .hour: horizon = 3 * 86400 + rule.intervalSeconds
        case .day: horizon = Double(rule.every + 1) * 86400 * 1.1
        case .week: horizon = Double(rule.every + 1) * 7 * 86400 * 1.1
        case .month: horizon = Double(rule.every + 1) * 32 * 86400
        case .year: horizon = Double(rule.every + 1) * 367 * 86400
        }
        return occurrences(anchor: anchor, rule: rule, activeStart: activeStart, activeEnd: activeEnd,
                           from: from, to: from.addingTimeInterval(max(horizon, 60)), calendar: cal, limit: 1).first
    }

    /// The latest occurrence at or before `date` (looking back at most `within` seconds).
    static func last(atOrBefore date: Date, within: TimeInterval, anchor: Date, rule: RepeatRule,
                     activeStart: Int? = nil, activeEnd: Int? = nil, calendar cal: Calendar = .current) -> Date? {
        occurrences(anchor: anchor, rule: rule, activeStart: activeStart, activeEnd: activeEnd,
                    from: date.addingTimeInterval(-within), to: date.addingTimeInterval(1), calendar: cal, limit: 2000).last
    }
}

// MARK: - Reminder

struct Reminder: Codable, Identifiable, Equatable {
    enum Category: String, Codable { case general, hydration }
    enum Status: String, Codable { case active, completed, disabled }

    var id = UUID()
    var title: String
    var notes: String = ""
    var category: Category = .general
    /// The first occurrence; repeating ones keep its time of day (or interval phase).
    var scheduledAt: Date
    var rule: RepeatRule = .noRepeat
    /// Interval reminders only: active hours, minutes after midnight (end inclusive).
    var activeStart: Int? = nil
    var activeEnd: Int? = nil
    var status: Status = .active
    var createdAt = Date()
    var completedAt: Date? = nil
    /// Occurrences you ticked off (epoch seconds), newest last; trimmed to the recent ones.
    var doneOccurrences: [Double] = []
    /// Snooze: when it comes back, and which occurrence it was.
    var snoozedUntil: Date? = nil
    var snoozedOccurrence: Double? = nil

    init(title: String, notes: String = "", category: Category = .general, scheduledAt: Date, rule: RepeatRule = .noRepeat,
         activeStart: Int? = nil, activeEnd: Int? = nil) {
        self.title = title
        self.notes = notes
        self.category = category
        self.scheduledAt = scheduledAt
        self.rule = rule
        self.activeStart = activeStart
        self.activeEnd = activeEnd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? "Reminder"
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        category = (try? c.decode(Category.self, forKey: .category)) ?? .general
        scheduledAt = (try? c.decode(Date.self, forKey: .scheduledAt)) ?? Date()
        rule = (try? c.decode(RepeatRule.self, forKey: .rule)) ?? RepeatRule.noRepeat
        activeStart = try? c.decodeIfPresent(Int.self, forKey: .activeStart)
        activeEnd = try? c.decodeIfPresent(Int.self, forKey: .activeEnd)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .active
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        completedAt = try? c.decodeIfPresent(Date.self, forKey: .completedAt)
        doneOccurrences = (try? c.decode([Double].self, forKey: .doneOccurrences)) ?? []
        snoozedUntil = try? c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        snoozedOccurrence = try? c.decodeIfPresent(Double.self, forKey: .snoozedOccurrence)
    }

    static func == (a: Reminder, b: Reminder) -> Bool {
        a.id == b.id && a.status == b.status && a.doneOccurrences == b.doneOccurrences && a.snoozedUntil == b.snoozedUntil
            && a.title == b.title && a.scheduledAt == b.scheduledAt && a.rule == b.rule
    }

    var isHydration: Bool { category == .hydration }
    var isActive: Bool { status == .active }
    /// Active hours only mean something for minute / hour intervals.
    var hasActiveHours: Bool { rule.isInterval && activeStart != nil && activeEnd != nil && activeStart != activeEnd }

    func occurrences(from: Date, to: Date, limit: Int = 500) -> [Date] {
        Recurrence.occurrences(anchor: scheduledAt, rule: rule,
                               activeStart: hasActiveHours ? activeStart : nil, activeEnd: hasActiveHours ? activeEnd : nil,
                               from: from, to: to, limit: limit)
    }

    func next(after d: Date) -> Date? {
        Recurrence.next(after: d, anchor: scheduledAt, rule: rule,
                        activeStart: hasActiveHours ? activeStart : nil, activeEnd: hasActiveHours ? activeEnd : nil)
    }

    func last(atOrBefore d: Date, within: TimeInterval) -> Date? {
        Recurrence.last(atOrBefore: d, within: within, anchor: scheduledAt, rule: rule,
                        activeStart: hasActiveHours ? activeStart : nil, activeEnd: hasActiveHours ? activeEnd : nil)
    }

    func isDone(_ occurrence: Date) -> Bool {
        if !rule.isRepeating && status == .completed { return true }
        let t = occurrence.timeIntervalSince1970
        return doneOccurrences.contains { abs($0 - t) < 1 }
    }

    func isSnoozed(_ occurrence: Date, now: Date = Date()) -> Bool {
        guard let until = snoozedUntil, until > now, let o = snoozedOccurrence else { return false }
        return abs(o - occurrence.timeIntervalSince1970) < 1
    }

    /// "Every 2 hours · 9:00 AM – 9:00 PM", "Every day at 8:00 AM", "Today at 3:00 PM".
    var scheduleText: String {
        let time = ReminderFormat.time.string(from: scheduledAt)
        switch rule.unit {
        case .none: return ReminderFormat.relativeDay(scheduledAt) + " at " + time
        case .minute, .hour:
            return rule.title + (hasActiveHours ? " · " + activeHoursText : "")
        default:
            return rule.title + " at " + time
        }
    }

    var activeHoursText: String {
        guard let s = activeStart, let e = activeEnd else { return "All day" }
        return ReminderFormat.clock(minutes: s) + " – " + ReminderFormat.clock(minutes: e)
    }

    /// "2 h", "45 min" — kept for Settings' break picker.
    static func intervalLabel(_ m: Int) -> String {
        if m % 60 == 0 { return m == 60 ? "hour" : "\(m / 60) h" }
        if m > 60 { return "\(m / 60) h \(m % 60) min" }
        return "\(m) min"
    }
}

// MARK: - Calendar event

struct CalendarEvent: Codable, Identifiable, Equatable {
    /// Where it really lives. `.custom` = kept by Zera on this Mac; the others come from
    /// macOS Calendar and are labelled by the account they sync from.
    enum Source: String, Codable, CaseIterable {
        case google, outlook, apple, custom
        var title: String {
            switch self {
            case .google: return "Google"
            case .outlook: return "Outlook"
            case .apple: return "Apple"
            case .custom: return "Custom"
            }
        }
        /// How the detail panel names it.
        var longTitle: String {
            switch self {
            case .google: return "Google Calendar"
            case .outlook: return "Outlook"
            case .apple: return "Apple Calendar"
            case .custom: return "Zera (this Mac)"
            }
        }
    }

    enum Kind: String, Codable, CaseIterable {
        case meeting, focus, personal, travel, other
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        var symbol: String {
            switch self {
            case .meeting: return "person.2.fill"
            case .focus: return "scope"
            case .personal: return "heart.fill"
            case .travel: return "airplane"
            case .other: return "calendar"
            }
        }
    }

    var id: String = UUID().uuidString
    var title: String
    var kind: Kind = .meeting
    var source: Source = .custom
    var calendarName: String = "Zera"
    var startAt: Date
    var duration: TimeInterval = 1800
    var isAllDay = false
    var location: String = ""
    var notes: String = ""
    var url: String? = nil
    var rule: RepeatRule = .noRepeat
    /// Minutes before the start for the heads-up; -1 = none, 0 = at the start only.
    var alertMinutes: Int = 10
    /// macOS Calendar: the colour of its calendar (hex), for the row accent.
    var colorHex: String? = nil

    init(title: String, startAt: Date, duration: TimeInterval = 1800, kind: Kind = .meeting, source: Source = .custom) {
        self.title = title
        self.startAt = startAt
        self.duration = duration
        self.kind = kind
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? "Event"
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .other
        source = (try? c.decode(Source.self, forKey: .source)) ?? .custom
        calendarName = (try? c.decode(String.self, forKey: .calendarName)) ?? "Zera"
        startAt = (try? c.decode(Date.self, forKey: .startAt)) ?? Date()
        duration = (try? c.decode(TimeInterval.self, forKey: .duration)) ?? 1800
        isAllDay = (try? c.decode(Bool.self, forKey: .isAllDay)) ?? false
        location = (try? c.decode(String.self, forKey: .location)) ?? ""
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        rule = (try? c.decode(RepeatRule.self, forKey: .rule)) ?? RepeatRule.noRepeat
        alertMinutes = (try? c.decode(Int.self, forKey: .alertMinutes)) ?? 10
        colorHex = try? c.decodeIfPresent(String.self, forKey: .colorHex)
    }

    var isExternal: Bool { source != .custom }

    func occurrences(from: Date, to: Date, limit: Int = 200) -> [Date] {
        // Include occurrences that started before `from` but are still going.
        let lookBack = isAllDay ? 86400 : max(0, duration)
        return Recurrence.occurrences(anchor: startAt, rule: rule, from: from.addingTimeInterval(-lookBack), to: to, limit: limit)
            .filter { $0.addingTimeInterval(isAllDay ? 86400 : max(60, duration)) > from }
    }

    /// A video-call link, if the event has one (URL field, location or notes).
    var joinURL: URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "around.co", "facetime.apple.com"]
        let text = [url ?? "", location, notes].joined(separator: " ")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let u = m.url, let h = u.host?.lowercased(), hosts.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { return u }
        }
        return nil
    }
}

/// One thing you finished — shown in Completed, where it can be restored or deleted.
struct CompletionEntry: Codable, Identifiable, Equatable {
    enum ItemKind: String, Codable { case reminder, event }
    var id = UUID()
    var itemKind: ItemKind
    var refID: String
    var title: String
    var occurrence: Date
    var completedAt: Date
    var hydration = false
    var source: CalendarEvent.Source? = nil
    /// Deleted from the history list but still counts as done.
    var hidden = false
}

// MARK: - Formatting

/// Formatters live outside the actor so plain structs and views can use them freely.
enum ReminderFormat {
    static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    /// "Sun, Oct 5"
    static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE MMM d"); return f
    }()
    /// "Sunday, October 5"
    static let longDate: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE MMMM d"); return f
    }()
    /// "Sun, Oct 5 at 3:00 PM"
    static let fullDate: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f
    }()

    /// 540 → "9:00 AM"
    static func clock(minutes m: Int) -> String {
        var c = DateComponents(); c.hour = (m / 60) % 24; c.minute = m % 60
        let d = Calendar.current.date(from: c) ?? Date()
        return time.string(from: d)
    }

    /// "Today", "Tomorrow", "Yesterday" or "Sun, Oct 5".
    static func relativeDay(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "Tomorrow" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return shortDate.string(from: d)
    }

    /// 5400 → "1h 30m", 1800 → "30m", 86400 → "1 day"
    static func duration(_ s: TimeInterval) -> String {
        let m = Int((s / 60).rounded())
        if m >= 1440, m % 1440 == 0 { return m == 1440 ? "1 day" : "\(m / 1440) days" }
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// "in 25 min", "in 2h 5m", "5 min ago".
    static func countdown(to d: Date, now: Date = Date()) -> String {
        let s = d.timeIntervalSince(now)
        let m = Int((abs(s) / 60).rounded(.up))
        let text: String = m < 60 ? "\(max(1, m)) min" : (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m")
        return s >= 0 ? "in " + text : text + " ago"
    }
}
