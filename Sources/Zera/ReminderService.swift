import Foundation
import AppKit
import EventKit

/// Something you asked Zera to remind you about.
struct Reminder: Codable, Equatable {
    enum Repeat: String, Codable, CaseIterable {
        case once, daily, weekdays, interval
        var title: String {
            switch self {
            case .once: return "Once"
            case .daily: return "Daily"
            case .weekdays: return "Weekdays"
            case .interval: return "Every…"
            }
        }
    }

    var id: UUID = UUID()
    var title: String
    var hour: Int
    var minute: Int
    var repeatRule: Repeat
    /// For `.once`: the day it is for (start of day).
    var date: Date?
    /// Minutes of heads-up before the time (0 = only at the time).
    var leadMinutes: Int
    var colorIndex: Int
    var enabled = true
    /// "yyyy-MM-dd" of the day it was ticked off (for `.interval`: paused for the day).
    var doneOn: String?
    /// For `.interval`: how often, in minutes ("water every 2 hours" = 120).
    var intervalMinutes: Int = 0
    /// For `.interval`: when it last went off, so the countdown survives relaunches.
    var lastFiredAt: Date? = nil

    static func == (a: Reminder, b: Reminder) -> Bool { a.id == b.id }

    var isInterval: Bool { repeatRule == .interval }

    var timeString: String {
        if isInterval { return "every " + Reminder.intervalLabel(intervalMinutes) }
        var c = DateComponents(); c.hour = hour; c.minute = minute
        let d = Calendar.current.date(from: c) ?? Date()
        return ReminderService.timeFormatter.string(from: d)
    }

    static func intervalLabel(_ m: Int) -> String {
        if m % 60 == 0 { return m == 60 ? "hour" : "\(m / 60) h" }
        if m > 60 { return "\(m / 60) h \(m % 60) min" }
        return "\(m) min"
    }

    /// Next time an interval reminder is due.
    var nextDue: Date? {
        guard isInterval else { return nil }
        return (lastFiredAt ?? Date()).addingTimeInterval(Double(intervalMinutes) * 60)
    }

    func fireTime(on day: Date) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    func applies(on day: Date) -> Bool {
        guard enabled else { return false }
        switch repeatRule {
        case .daily, .interval: return true
        case .weekdays:
            let wd = Calendar.current.component(.weekday, from: day)
            return wd >= 2 && wd <= 6
        case .once:
            guard let d = date else { return false }
            return Calendar.current.isDate(d, inSameDayAs: day)
        }
    }

    var isDoneToday: Bool { doneOn == ReminderService.dayKey(Date()) }

    static var palette: [NSColor] {
        let p = Pal
        return [p.info, p.tileCalendar, p.warning, p.success, p.accent, NSColor(srgbRed: 1.00, green: 0.55, blue: 0.80, alpha: 1)]
    }
    var color: NSColor { Reminder.palette[((colorIndex % Reminder.palette.count) + Reminder.palette.count) % Reminder.palette.count] }
}

/// A calendar event happening today.
struct CalendarItem: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: NSColor
    static func == (a: CalendarItem, b: CalendarItem) -> Bool { a.id == b.id }
}

/// What Zera is telling you right now.
struct ReminderAlert: Equatable {
    enum Kind { case headsUp, now, snoozed, calendarHeadsUp, calendarNow, breakTime }
    let id: String
    let kind: Kind
    let headline: String
    let detail: String
    let reminderID: UUID?
    let firedAt: Date
    static func == (a: ReminderAlert, b: ReminderAlert) -> Bool { a.id == b.id }
}

/// Keeps your reminders, watches the clock, reads today's calendar, and nudges you to take
/// breaks. Posts `alert` when something is due; the controller turns that into Zera speaking
/// and the alert card.
@MainActor
final class ReminderService {
    static let shared = ReminderService()

    nonisolated static let changed = Notification.Name("RemindersChanged")
    /// userInfo["alert"]: ReminderAlert
    nonisolated static let alert = Notification.Name("ReminderAlert")

    private(set) var reminders: [Reminder] = []
    private(set) var calendarItems: [CalendarItem] = []
    private(set) var pendingAlerts: [ReminderAlert] = []
    private(set) var calendarAuthorized = false
    private(set) var calendarDenied = false

    /// Minutes between break nudges; 0 = off.
    var breakInterval: Int {
        get { UserDefaults.standard.object(forKey: Self.breakKey) as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: Self.breakKey); lastBreakAt = Date(); post() }
    }
    /// The controller sets this from pointer activity so breaks are not suggested to an empty chair.
    var userIsIdle = false

    private var store = EKEventStore()
    private var timer: Timer?
    private var calendarTimer: Timer?
    private var storeObserver: NSObjectProtocol?
    private(set) var lastCalendarSync: Date?
    /// Calendar is polled this often, plus instantly whenever macOS says it changed.
    let calendarSyncInterval: TimeInterval = 150
    private var fired: Set<String>
    private var snoozedUntil: [String: Date] = [:]
    private var lastBreakAt = Date()

    private static let breakKey = "zera.reminders.breakInterval"
    private static let firedKey = "zera.reminders.fired"
    private static let calendarWantedKey = "zera.reminders.calendarWanted"

    nonisolated static var timeFormatter: DateFormatter { ReminderFormat.time }
    nonisolated static func dayKey(_ d: Date) -> String { ReminderFormat.day.string(from: d) }

    private init() {
        fired = Set(UserDefaults.standard.stringArray(forKey: Self.firedKey) ?? [])
        load()
    }

    // MARK: - Persistence

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("reminders.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Reminder].self, from: data) else { return }
        reminders = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reminders) { try? data.write(to: fileURL, options: .atomic) }
        post()
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    // MARK: - Reminders

    func add(title: String, hour: Int, minute: Int, repeatRule: Reminder.Repeat, leadMinutes: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        var date: Date? = nil
        if repeatRule == .once {
            // If the time has already passed today, it is for tomorrow.
            let candidate = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today
            date = candidate > Date() ? today : Calendar.current.date(byAdding: .day, value: 1, to: today)
        }
        let r = Reminder(title: title, hour: hour, minute: minute, repeatRule: repeatRule, date: date,
                         leadMinutes: leadMinutes, colorIndex: reminders.count)
        reminders.append(r)
        save()
    }

    func addInterval(title: String, everyMinutes: Int) {
        let r = Reminder(title: title, hour: 0, minute: 0, repeatRule: .interval, date: nil,
                         leadMinutes: 0, colorIndex: reminders.count, intervalMinutes: max(5, everyMinutes),
                         lastFiredAt: Date())
        reminders.append(r)
        save()
    }

    func remove(_ id: UUID) {
        reminders.removeAll { $0.id == id }
        pendingAlerts.removeAll { $0.reminderID == id }
        save()
    }

    func toggleDone(_ id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].doneOn = reminders[i].isDoneToday ? nil : Self.dayKey(Date())
        if reminders[i].isDoneToday { pendingAlerts.removeAll { $0.reminderID == id } }
        save()
    }

    /// Today's own reminders, in time order.
    var todaysReminders: [Reminder] {
        let today = Date()
        let timed = reminders.filter { $0.applies(on: today) && !$0.isInterval }
            .sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        let repeating = reminders.filter { $0.applies(on: today) && $0.isInterval }
            .sorted { $0.intervalMinutes < $1.intervalMinutes }
        return timed + repeating
    }

    // MARK: - Alerts

    func dismiss(_ alert: ReminderAlert) {
        pendingAlerts.removeAll { $0.id == alert.id }
        if alert.kind == .breakTime { lastBreakAt = Date() }
        post()
    }

    func snooze(_ alert: ReminderAlert, minutes: Int = 5) {
        pendingAlerts.removeAll { $0.id == alert.id }
        snoozedUntil[alert.id] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        if alert.kind == .breakTime { lastBreakAt = Date().addingTimeInterval(TimeInterval(minutes * 60) - TimeInterval(breakInterval * 60)) }
        post()
    }

    /// Done from the alert card: marks the reminder done for today.
    func complete(_ alert: ReminderAlert) {
        if let id = alert.reminderID, let i = reminders.firstIndex(where: { $0.id == id }), !reminders[i].isInterval {
            reminders[i].doneOn = Self.dayKey(Date())
            save()
        }
        dismiss(alert)
    }

    /// "Take a Break" from Quick Actions.
    func triggerBreakNow() {
        let now = Date()
        lastBreakAt = now
        raise(ReminderAlert(id: "break-\(Int(now.timeIntervalSince1970))", kind: .breakTime,
                            headline: "Time for a short break? ☕", detail: "You asked for one — stretch, water, look far away",
                            reminderID: nil, firedAt: now))
    }

    private func raise(_ a: ReminderAlert) {
        guard !pendingAlerts.contains(a) else { return }
        pendingAlerts.append(a)
        fired.insert(a.id)
        UserDefaults.standard.set(Array(fired), forKey: Self.firedKey)
        NotificationCenter.default.post(name: Self.alert, object: nil, userInfo: ["alert": a])
        post()
    }

    // MARK: - Clock

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastBreakAt = Date()
        // Already allowed in a previous run? Start syncing straight away, no prompt.
        if Self.hasCalendarAccess {
            calendarAuthorized = true
            beginCalendarSync()
        } else if UserDefaults.standard.bool(forKey: Self.calendarWantedKey) {
            Task { await self.connectCalendar() }
        }
        tick()
    }

    private static var hasCalendarAccess: Bool {
        let st = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return st == .fullAccess }
        return st == .authorized
    }

    private func tick() {
        let now = Date()
        let today = Self.dayKey(now)
        // Keep the fired set small: only today's keys matter.
        let tomorrow = Self.dayKey(now.addingTimeInterval(86400))
        let stale = fired.filter { !$0.hasSuffix(today) && !$0.hasSuffix(tomorrow) && !$0.hasPrefix("every-") && !$0.hasPrefix("break-") && !$0.hasPrefix("snooze-") }
        if !stale.isEmpty {
            fired.subtract(stale)
            UserDefaults.standard.set(Array(fired), forKey: Self.firedKey)
        }

        for (i, r) in reminders.enumerated() where r.isInterval && r.enabled && !r.isDoneToday {
            let last = r.lastFiredAt ?? now
            if r.lastFiredAt == nil { reminders[i].lastFiredAt = now; continue }
            if now.timeIntervalSince(last) >= Double(r.intervalMinutes) * 60 {
                reminders[i].lastFiredAt = now
                save()
                raise(ReminderAlert(id: "every-\(r.id)-\(Int(now.timeIntervalSince1970))", kind: .now,
                                    headline: "\(r.title) 🔔", detail: r.timeString, reminderID: r.id, firedAt: now))
            }
        }

        for r in todaysReminders where !r.isDoneToday && !r.isInterval {
            let at = r.fireTime(on: now)
            let leadKey = "lead-\(r.id)-\(today)", atKey = "at-\(r.id)-\(today)"
            if r.leadMinutes > 0, !fired.contains(leadKey),
               now >= at.addingTimeInterval(-Double(r.leadMinutes) * 60), now < at {
                raise(ReminderAlert(id: leadKey, kind: .headsUp,
                                    headline: "\(r.title) in \(r.leadMinutes) minutes ⏰",
                                    detail: "at \(r.timeString)", reminderID: r.id, firedAt: now))
            }
            if !fired.contains(atKey), now >= at, now < at.addingTimeInterval(15 * 60) {
                raise(ReminderAlert(id: atKey, kind: .now, headline: "\(r.title) — it's time! 🔔",
                                    detail: r.timeString, reminderID: r.id, firedAt: now))
            }
        }

        for e in calendarItems {
            let day = Self.dayKey(e.start)
            let leadKey = "cal-lead-\(e.id)-\(day)", atKey = "cal-at-\(e.id)-\(day)"
            if !fired.contains(leadKey), now >= e.start.addingTimeInterval(-15 * 60), now < e.start {
                raise(ReminderAlert(id: leadKey, kind: .calendarHeadsUp,
                                    headline: "You have a meeting in 15 minutes! ⏰",
                                    detail: "\(e.title) · \(Self.timeFormatter.string(from: e.start))",
                                    reminderID: nil, firedAt: now))
            }
            if !fired.contains(atKey), now >= e.start, now < min(e.end, e.start.addingTimeInterval(10 * 60)) {
                raise(ReminderAlert(id: atKey, kind: .calendarNow, headline: "\(e.title) is starting now 📅",
                                    detail: Self.timeFormatter.string(from: e.start), reminderID: nil, firedAt: now))
            }
        }

        // Snoozes come back as their own alert.
        for (key, until) in snoozedUntil where now >= until {
            snoozedUntil.removeValue(forKey: key)
            let original = key
            let title = reminders.first { original.contains($0.id.uuidString) }?.title
            raise(ReminderAlert(id: "snooze-\(key)-\(Int(now.timeIntervalSince1970))", kind: .snoozed,
                                headline: title.map { "\($0) — snooze is up 🔔" } ?? "Snooze is up 🔔",
                                detail: Self.timeFormatter.string(from: now),
                                reminderID: reminders.first { original.contains($0.id.uuidString) }?.id, firedAt: now))
        }

        if breakInterval > 0, !userIsIdle,
           now.timeIntervalSince(lastBreakAt) >= Double(breakInterval) * 60,
           !pendingAlerts.contains(where: { $0.kind == .breakTime }) {
            lastBreakAt = now
            raise(ReminderAlert(id: "break-\(Int(now.timeIntervalSince1970))", kind: .breakTime,
                                headline: "Time for a short break? ☕",
                                detail: "You've been at it for \(breakInterval) minutes",
                                reminderID: nil, firedAt: now))
        }
    }

    // MARK: - Calendar

    var calendarStatusText: String {
        if calendarAuthorized {
            let today = calendarItems.filter { Calendar.current.isDateInToday($0.start) }.count
            let synced = lastCalendarSync.map { " · synced \(relativeTime($0))" } ?? ""
            return (today == 0 ? "Connected · nothing today" : "Connected · \(today) today") + synced
        }
        if calendarDenied { return "Access denied — allow Zera in System Settings → Privacy → Calendars" }
        return "Not connected"
    }

    func connectCalendar() async {
        UserDefaults.standard.set(true, forKey: Self.calendarWantedKey)
        var granted = false
        do {
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await withCheckedThrowingContinuation { cont in
                    store.requestAccess(to: .event) { ok, err in
                        if let err = err { cont.resume(throwing: err) } else { cont.resume(returning: ok) }
                    }
                }
            }
        } catch {
            granted = false
        }
        calendarAuthorized = granted
        calendarDenied = !granted
        if granted { beginCalendarSync() }
        post()
    }

    private func beginCalendarSync() {
        // A store created before access was granted answers with nothing: start fresh.
        store = EKEventStore()
        refreshCalendar()
        calendarTimer?.invalidate()
        let t = Timer(timeInterval: calendarSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCalendar() }
        }
        RunLoop.main.add(t, forMode: .common)
        calendarTimer = t
        // Block observers are removed by token, not by `self`: drop the old one first so
        // reconnecting does not stack refreshes.
        if let o = storeObserver { NotificationCenter.default.removeObserver(o) }
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCalendar() }
        }
    }

    func disconnectCalendar() {
        UserDefaults.standard.set(false, forKey: Self.calendarWantedKey)
        calendarTimer?.invalidate(); calendarTimer = nil
        if let o = storeObserver { NotificationCenter.default.removeObserver(o); storeObserver = nil }
        calendarAuthorized = false
        calendarDenied = false
        calendarItems = []
        post()
    }

    func refreshCalendar() {
        guard calendarAuthorized else { return }
        let cal = Calendar.current
        // Today and tomorrow, so the Upcoming tab has something and an early meeting tomorrow
        // still gets its heads-up.
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 2, to: start)!
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: pred).filter { !$0.isAllDay }
        calendarItems = events.map { e in
            CalendarItem(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Event",
                         start: e.startDate, end: e.endDate,
                         color: e.calendar.color ?? Pal.tileCalendar)
        }.sorted { $0.start < $1.start }
        lastCalendarSync = Date()
        post()
        tick()
    }
}

/// Formatters live outside the actor so plain structs and views can use them freely.
enum ReminderFormat {
    static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}
