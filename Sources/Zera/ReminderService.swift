import Foundation
import AppKit
import EventKit

// MARK: - Agenda

/// One row of the Today / Upcoming lists: an event occurrence or a reminder occurrence.
/// Interval reminders (every N minutes / hours) appear once per day with their progress.
struct AgendaItem {
    enum Kind { case event(CalendarEvent), reminder(Reminder) }
    let kind: Kind
    let occurrence: Date
    var seriesTotal = 0
    var seriesDone = 0
    var seriesRemaining = 0

    init(kind: Kind, occurrence: Date) {
        self.kind = kind
        self.occurrence = occurrence
    }

    var refID: String {
        switch kind {
        case .event(let e): return e.id
        case .reminder(let r): return r.id.uuidString
        }
    }
    var id: String { "\(refID)@\(Int(occurrence.timeIntervalSince1970))" }
    var reminder: Reminder? { if case .reminder(let r) = kind { return r }; return nil }
    var event: CalendarEvent? { if case .event(let e) = kind { return e }; return nil }
    var title: String { reminder?.title ?? event?.title ?? "" }
    var isAllDay: Bool { event?.isAllDay ?? false }
    var isSeries: Bool { reminder?.rule.isInterval ?? false }
    var end: Date? {
        guard let e = event else { return nil }
        return occurrence.addingTimeInterval(e.isAllDay ? 86400 : max(0, e.duration))
    }
}

enum AgendaState {
    case upcoming, inProgress, due, overdue, snoozed, completed, disabled, ended, doneForToday
}

/// All · Google · Outlook · Apple · Custom · Reminders
enum AgendaFilter: Int, CaseIterable {
    case all, google, outlook, apple, custom, reminders
    var title: String {
        switch self {
        case .all: return "All"
        case .google: return "Google"
        case .outlook: return "Outlook"
        case .apple: return "Apple"
        case .custom: return "Custom"
        case .reminders: return "Reminders"
        }
    }
    func matches(_ item: AgendaItem) -> Bool {
        switch self {
        case .all: return true
        case .reminders: return item.reminder != nil
        case .google: return item.event?.source == .google
        case .outlook: return item.event?.source == .outlook
        case .apple: return item.event?.source == .apple
        case .custom: return item.event?.source == .custom
        }
    }
}

/// What Zera is telling you right now.
struct ReminderAlert: Equatable {
    enum Kind { case headsUp, now, snoozed, calendarHeadsUp, calendarNow, breakTime, battery }
    let id: String
    let kind: Kind
    let headline: String
    let detail: String
    var reminderID: UUID? = nil
    var eventID: String? = nil
    var occurrence: Date? = nil
    var hydration = false
    var joinURL: URL? = nil
    static func == (a: ReminderAlert, b: ReminderAlert) -> Bool { a.id == b.id }

    var isEvent: Bool { kind == .calendarHeadsUp || kind == .calendarNow || eventID != nil }
}

/// A macOS Calendar calendar Zera may create events in.
struct WritableCalendar {
    let id: String
    let title: String
    let source: CalendarEvent.Source
    let account: String
}

/// Snoozed event / break alerts (reminders keep their snooze on the reminder itself).
private struct PendingSnooze: Codable {
    var key: String
    var until: Date
    var headline: String
    var detail: String
    var eventID: String?
    var isBreak: Bool
}

// MARK: - Service

/// Keeps your reminders and Zera's own events, reads macOS Calendar, runs the schedule and
/// nudges you to take breaks. Posts `alert` when something is due; the controller turns that
/// into Zera speaking and the notification card. Everything stays in
/// ~/Library/Application Support/Zera — none of it is ever sent to Claude.
@MainActor
final class ReminderService {
    static let shared = ReminderService()

    nonisolated static let changed = Notification.Name("RemindersChanged")
    /// userInfo["alert"]: ReminderAlert
    nonisolated static let alert = Notification.Name("ReminderAlert")

    /// A reminder counts as "due" this long after its time, then "overdue".
    static let dueWindow: TimeInterval = 15 * 60
    /// How far back the clock looks for an occurrence it has not announced yet (sleep, relaunch).
    static let fireWindow: TimeInterval = 15 * 60

    private(set) var reminders: [Reminder] = []
    private(set) var customEvents: [CalendarEvent] = []
    private(set) var externalEvents: [CalendarEvent] = []
    private(set) var completions: [CompletionEntry] = []
    private(set) var pendingAlerts: [ReminderAlert] = []
    private(set) var calendarAuthorized = false
    private(set) var calendarDenied = false
    private(set) var writableCalendars: [WritableCalendar] = []

    /// Minutes between break nudges; 0 = off.
    var breakInterval: Int {
        get { UserDefaults.standard.object(forKey: Self.breakPref) as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: Self.breakPref); lastBreakAt = Date(); post() }
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
    private var snoozes: [PendingSnooze] = []
    private var lastBreakAt = Date()

    private static let breakPref = "zera.reminders.breakInterval"
    private static let firedPref = "zera.reminders.fired.v2"
    private static let snoozePref = "zera.reminders.snoozes.v2"
    private static let calendarWantedPref = "zera.reminders.calendarWanted"

    nonisolated static var timeFormatter: DateFormatter { ReminderFormat.time }

    private init() {
        fired = Set(UserDefaults.standard.stringArray(forKey: Self.firedPref) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.snoozePref),
           let list = try? JSONDecoder().decode([PendingSnooze].self, from: data) { snoozes = list }
        load()
    }

    // MARK: - Persistence

    private var baseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var remindersURL: URL { baseURL.appendingPathComponent("reminders-v2.json") }
    private var eventsURL: URL { baseURL.appendingPathComponent("events.json") }
    private var completionsURL: URL { baseURL.appendingPathComponent("completions.json") }
    private var legacyURL: URL { baseURL.appendingPathComponent("reminders.json") }

    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
    private static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }

    private func load() {
        let dec = Self.decoder()
        if let data = try? Data(contentsOf: remindersURL), let list = try? dec.decode([Reminder].self, from: data) {
            reminders = list
        } else if FileManager.default.fileExists(atPath: legacyURL.path) {
            migrateLegacy()
        }
        if let data = try? Data(contentsOf: eventsURL), let list = try? dec.decode([CalendarEvent].self, from: data) {
            customEvents = list.map { var e = $0; e.source = .custom; return e }   // Zera's own events are never anything else
        }
        if let data = try? Data(contentsOf: completionsURL), let list = try? dec.decode([CompletionEntry].self, from: data) {
            completions = list
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? Self.encoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func saveReminders() { write(reminders, to: remindersURL); post() }
    private func saveEvents() { write(customEvents, to: eventsURL); post() }
    private func saveCompletions() {
        // Keep the history readable: the last 60 days, at most 500 entries.
        let cutoff = Date().addingTimeInterval(-60 * 86400)
        completions = Array(completions.filter { $0.completedAt > cutoff }.suffix(500))
        write(completions, to: completionsURL)
        post()
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    /// The first version kept simple daily / weekday / once / "every N minutes" reminders.
    private struct LegacyReminder: Decodable {
        var title: String
        var hour: Int
        var minute: Int
        var repeatRule: String
        var date: Date?
        var enabled: Bool?
        var intervalMinutes: Int?
        var lastFiredAt: Date?
    }

    private func migrateLegacy() {
        guard let data = try? Data(contentsOf: legacyURL),
              let old = try? JSONDecoder().decode([LegacyReminder].self, from: data) else { return }
        let cal = Calendar.current, now = Date()
        reminders = old.map { o in
            let day = o.date ?? now
            let at = cal.date(bySettingHour: o.hour, minute: o.minute, second: 0, of: day) ?? now
            var r: Reminder
            switch o.repeatRule {
            case "daily": r = Reminder(title: o.title, scheduledAt: at, rule: .daily)
            case "weekdays": r = Reminder(title: o.title, scheduledAt: at, rule: .weekdaysOnly)
            case "interval":
                let m = max(5, o.intervalMinutes ?? 60)
                let rule: RepeatRule = m % 60 == 0 ? .hours(m / 60) : .minutes(m)
                let t = o.title.lowercased()
                let water = t.contains("water") || t.contains("drink") || t.contains("hydrat")
                r = Reminder(title: o.title, category: water ? .hydration : .general,
                             scheduledAt: (o.lastFiredAt ?? now).addingTimeInterval(TimeInterval(m * 60)), rule: rule)
            default: r = Reminder(title: o.title, scheduledAt: at)
            }
            if o.enabled == false { r.status = .disabled }
            return r
        }
        write(reminders, to: remindersURL)
        // Keep the old file as a backup rather than deleting it.
        try? FileManager.default.moveItem(at: legacyURL, to: baseURL.appendingPathComponent("reminders-legacy.json"))
    }

    // MARK: - Lookup

    var allEvents: [CalendarEvent] { customEvents + externalEvents }
    func reminder(_ id: UUID) -> Reminder? { reminders.first { $0.id == id } }
    func event(_ id: String) -> CalendarEvent? { allEvents.first { $0.id == id } }

    func isEventCompleted(_ id: String, occurrence: Date) -> Bool {
        let t = occurrence.timeIntervalSince1970
        return completions.contains { $0.itemKind == .event && $0.refID == id && abs($0.occurrence.timeIntervalSince1970 - t) < 1 }
    }

    // MARK: - Reminders

    /// Creates or updates (same id) a reminder.
    func save(reminder r: Reminder) {
        var r = r
        r.title = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = reminders.firstIndex(where: { $0.id == r.id }) {
            // Editing the schedule starts it afresh: an old snooze no longer points anywhere.
            if reminders[i].scheduledAt != r.scheduledAt || reminders[i].rule != r.rule { r.snoozedUntil = nil; r.snoozedOccurrence = nil }
            reminders[i] = r
        } else {
            reminders.append(r)
        }
        pendingAlerts.removeAll { $0.reminderID == r.id }
        saveReminders()
        tick()
    }

    /// Start Timer and other one-shot nudges.
    func addOneOff(title: String, at date: Date) {
        save(reminder: Reminder(title: title, scheduledAt: date))
    }

    func deleteReminder(_ id: UUID) {
        reminders.removeAll { $0.id == id }
        pendingAlerts.removeAll { $0.reminderID == id }
        completions.removeAll { $0.itemKind == .reminder && $0.refID == id.uuidString }
        write(completions, to: completionsURL)
        saveReminders()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        if on {
            reminders[i].status = .active
            // A one-off whose time has long gone is not re-announced; a repeating one carries on.
        } else {
            reminders[i].status = .disabled
            reminders[i].snoozedUntil = nil
            pendingAlerts.removeAll { $0.reminderID == id }
        }
        saveReminders()
    }

    /// The occurrence "Mark as done" means right now: the one that is due or overdue, else the next one.
    func currentOccurrence(of r: Reminder, now: Date = Date()) -> Date {
        if !r.rule.isRepeating { return r.scheduledAt }
        let lookBack = r.rule.isInterval ? max(r.rule.intervalSeconds, Self.dueWindow) : 86400
        if let last = r.last(atOrBefore: now, within: lookBack), !r.isDone(last) { return last }
        return r.next(after: now) ?? r.scheduledAt
    }

    func markDone(_ id: UUID, occurrence: Date? = nil) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        let occ = occurrence ?? currentOccurrence(of: reminders[i])
        var r = reminders[i]
        guard !r.isDone(occ) else { return }
        r.doneOccurrences.append(occ.timeIntervalSince1970)
        if r.doneOccurrences.count > 300 { r.doneOccurrences.removeFirst(r.doneOccurrences.count - 300) }
        if !r.rule.isRepeating { r.status = .completed; r.completedAt = Date() }
        SoundService.shared.play(.reminderDone)
        if let so = r.snoozedOccurrence, abs(so - occ.timeIntervalSince1970) < 1 { r.snoozedUntil = nil; r.snoozedOccurrence = nil }
        reminders[i] = r
        completions.append(CompletionEntry(itemKind: .reminder, refID: id.uuidString, title: r.title, occurrence: occ,
                                           completedAt: Date(), hydration: r.isHydration))
        pendingAlerts.removeAll { $0.reminderID == id && ($0.occurrence.map { abs($0.timeIntervalSince(occ)) < 1 } ?? true) }
        write(reminders, to: remindersURL)
        saveCompletions()
    }

    func snooze(reminder id: UUID, occurrence: Date? = nil, until: Date) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        let occ = occurrence ?? currentOccurrence(of: reminders[i])
        reminders[i].snoozedUntil = until
        reminders[i].snoozedOccurrence = occ.timeIntervalSince1970
        pendingAlerts.removeAll { $0.reminderID == id }
        saveReminders()
    }

    // MARK: - Events

    /// Creates or updates (same id) one of Zera's own events.
    func save(event e: CalendarEvent) {
        var e = e
        e.source = .custom
        e.calendarName = "Zera"
        e.title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = customEvents.firstIndex(where: { $0.id == e.id }) { customEvents[i] = e } else { customEvents.append(e) }
        saveEvents()
        tick()
    }

    func deleteEvent(_ id: String) {
        customEvents.removeAll { $0.id == id }
        pendingAlerts.removeAll { $0.eventID == id }
        completions.removeAll { $0.itemKind == .event && $0.refID == id }
        write(completions, to: completionsURL)
        saveEvents()
    }

    func markEventComplete(_ id: String, occurrence: Date) {
        guard let e = event(id), !isEventCompleted(id, occurrence: occurrence) else { return }
        completions.append(CompletionEntry(itemKind: .event, refID: id, title: e.title, occurrence: occurrence,
                                           completedAt: Date(), source: e.source))
        pendingAlerts.removeAll { $0.eventID == id }
        saveCompletions()
    }

    // MARK: - Completed

    /// Puts it back where it was (the occurrence counts as not done again).
    func restore(_ entry: CompletionEntry) {
        completions.removeAll { $0.id == entry.id }
        if entry.itemKind == .reminder, let uuid = UUID(uuidString: entry.refID), let i = reminders.firstIndex(where: { $0.id == uuid }) {
            let t = entry.occurrence.timeIntervalSince1970
            reminders[i].doneOccurrences.removeAll { abs($0 - t) < 1 }
            if reminders[i].status == .completed { reminders[i].status = .active; reminders[i].completedAt = nil }
            // Already announced once: do not ring again just because it was restored.
            fired.insert("rem-\(uuid)-\(Int(t))")
            persistFired()
            write(reminders, to: remindersURL)
        }
        saveCompletions()
    }

    /// Delete from Completed: a finished one-off reminder or Zera event goes away for good;
    /// for anything that repeats (or lives in macOS Calendar) only the history line goes.
    func deleteCompletion(_ entry: CompletionEntry) {
        switch entry.itemKind {
        case .reminder:
            if let uuid = UUID(uuidString: entry.refID), let r = reminder(uuid), !r.rule.isRepeating {
                deleteReminder(uuid); return
            }
        case .event:
            if let e = customEvents.first(where: { $0.id == entry.refID }), !e.rule.isRepeating {
                deleteEvent(e.id); return
            }
        }
        if let i = completions.firstIndex(where: { $0.id == entry.id }) { completions[i].hidden = true }
        saveCompletions()
    }

    var visibleCompletions: [CompletionEntry] {
        completions.filter { !$0.hidden }.sorted { $0.completedAt > $1.completedAt }
    }

    // MARK: - Agenda

    func state(of item: AgendaItem, now: Date = Date()) -> AgendaState {
        switch item.kind {
        case .reminder(let r):
            if r.status == .disabled { return .disabled }
            let occ = item.occurrence
            if item.isSeries, item.seriesRemaining == 0, item.seriesTotal > 0,
               r.isDone(occ) || now.timeIntervalSince(occ) >= max(r.rule.intervalSeconds, Self.dueWindow) { return .doneForToday }
            if r.isDone(occ) { return .completed }
            if r.isSnoozed(occ, now: now) { return .snoozed }
            if occ > now { return .upcoming }
            return now.timeIntervalSince(occ) < Self.dueWindow ? .due : .overdue
        case .event(let e):
            if isEventCompleted(e.id, occurrence: item.occurrence) { return .completed }
            if let end = item.end, end <= now { return .ended }
            return item.occurrence <= now ? .inProgress : .upcoming
        }
    }

    /// Everything on one day, in time order (all-day events first).
    func items(on day: Date, now: Date = Date()) -> [AgendaItem] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let isToday = cal.isDate(day, inSameDayAs: now)
        var out: [AgendaItem] = []

        for e in allEvents {
            for occ in e.occurrences(from: start, to: end, limit: 50) {
                // A timed event that began yesterday shows only on its own day.
                if !e.isAllDay, occ < start { continue }
                out.append(AgendaItem(kind: .event(e), occurrence: occ))
            }
        }

        for r in reminders {
            if r.rule.isInterval {
                let occs = r.occurrences(from: start, to: end, limit: 1500)
                guard let first = occs.first, let lastOcc = occs.last else { continue }
                var occ = first
                if isToday {
                    let step = r.rule.intervalSeconds
                    if let cur = occs.last(where: { $0 <= now }), now.timeIntervalSince(cur) < step, !r.isDone(cur) { occ = cur }
                    else if let nx = occs.first(where: { $0 > now }) { occ = nx }
                    else { occ = lastOcc }
                }
                var item = AgendaItem(kind: .reminder(r), occurrence: occ)
                item.seriesTotal = occs.count
                item.seriesDone = occs.filter { r.isDone($0) }.count
                item.seriesRemaining = isToday ? occs.filter { $0 > now }.count : occs.count
                out.append(item)
            } else {
                for occ in r.occurrences(from: start, to: end, limit: 50) {
                    out.append(AgendaItem(kind: .reminder(r), occurrence: occ))
                }
                // Missed one-offs from earlier days stay on Today until you deal with them.
                if isToday, !r.rule.isRepeating, r.status == .active, r.scheduledAt < start {
                    out.append(AgendaItem(kind: .reminder(r), occurrence: r.scheduledAt))
                }
            }
        }

        return out.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            return a.occurrence < b.occurrence
        }
    }

    /// Today, minus what is already completed (that lives in Completed).
    func today(now: Date = Date()) -> [AgendaItem] {
        items(on: now, now: now).filter { state(of: $0, now: now) != .completed }
    }

    /// The next `days` days after today, grouped by day; days with nothing are left out.
    func upcoming(days: Int = 14, now: Date = Date()) -> [(day: Date, items: [AgendaItem])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var out: [(day: Date, items: [AgendaItem])] = []
        for i in 1...max(1, days) {
            guard let d = cal.date(byAdding: .day, value: i, to: today) else { continue }
            let list = items(on: d, now: now).filter {
                let s = state(of: $0, now: now)
                return s != .completed && s != .disabled
            }
            if !list.isEmpty { out.append((day: d, items: list)) }
        }
        return out
    }

    /// For Home: reminders that are past due today.
    func overdueReminders(now: Date = Date()) -> [Reminder] {
        today(now: now).filter { $0.reminder != nil && state(of: $0, now: now) == .overdue }.compactMap { $0.reminder }
    }

    /// For Home: the next timed event starting within `seconds`.
    func nextEvent(within seconds: TimeInterval, now: Date = Date()) -> (event: CalendarEvent, start: Date)? {
        var best: (CalendarEvent, Date)?
        for e in allEvents where !e.isAllDay {
            for occ in e.occurrences(from: now, to: now.addingTimeInterval(seconds), limit: 3) where occ > now {
                if isEventCompleted(e.id, occurrence: occ) { continue }
                if best == nil || occ < best!.1 { best = (e, occ) }
            }
        }
        return best.map { (event: $0.0, start: $0.1) }
    }

    // MARK: - Alerts

    func dismiss(_ alert: ReminderAlert) {
        pendingAlerts.removeAll { $0.id == alert.id }
        if alert.kind == .breakTime { lastBreakAt = Date() }
        post()
    }

    /// Snooze from the notification: 15 min … tomorrow.
    func snooze(_ alert: ReminderAlert, until: Date) {
        pendingAlerts.removeAll { $0.id == alert.id }
        if let id = alert.reminderID, reminder(id) != nil {
            snooze(reminder: id, occurrence: alert.occurrence, until: until)
            return
        }
        if alert.kind == .breakTime {
            lastBreakAt = until.addingTimeInterval(-TimeInterval(breakInterval * 60))
        }
        snoozes.append(PendingSnooze(key: alert.id, until: until, headline: alert.headline, detail: alert.detail,
                                     eventID: alert.eventID, isBreak: alert.kind == .breakTime))
        persistSnoozes()
        post()
    }

    func snooze(_ alert: ReminderAlert, minutes: Int) { snooze(alert, until: Date().addingTimeInterval(TimeInterval(minutes * 60))) }

    /// "Mark as done" from the notification.
    func complete(_ alert: ReminderAlert) {
        if let id = alert.reminderID, reminder(id) != nil {
            markDone(id, occurrence: alert.occurrence)
        } else if let eid = alert.eventID, let occ = alert.occurrence {
            markEventComplete(eid, occurrence: occ)
            SoundService.shared.play(.reminderDone)
        }
        dismiss(alert)
    }

    /// "Take a Break" from Quick Actions.
    func triggerBreakNow() {
        let now = Date()
        lastBreakAt = now
        raise(ReminderAlert(id: "break-\(Int(now.timeIntervalSince1970))", kind: .breakTime,
                            headline: "Time for a short break? ☕", detail: "You asked for one — stretch, water, look far away"))
    }

    /// A banner from elsewhere in Zera (the battery), shown like any reminder.
    func raiseNow(_ a: ReminderAlert) { raise(a) }

    /// Shows `a` as the banner without firing or remembering it (screen renders in tests).
    func preview(_ a: ReminderAlert) {
        pendingAlerts = [a]
        post()
    }

    private func raise(_ a: ReminderAlert) {
        guard !pendingAlerts.contains(a) else { return }
        // One card per reminder: a newer nudge replaces an older one still waiting.
        if let rid = a.reminderID { pendingAlerts.removeAll { $0.reminderID == rid } }
        pendingAlerts.append(a)
        fired.insert(a.id)
        persistFired()
        NotificationCenter.default.post(name: Self.alert, object: nil, userInfo: ["alert": a])
        post()
    }

    private func persistFired() { UserDefaults.standard.set(Array(fired), forKey: Self.firedPref) }
    private func persistSnoozes() {
        if let data = try? JSONEncoder().encode(snoozes) { UserDefaults.standard.set(data, forKey: Self.snoozePref) }
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
        } else if UserDefaults.standard.bool(forKey: Self.calendarWantedPref) {
            Task { await self.connectCalendar() }
        }
        tick()
    }

    private static var hasCalendarAccess: Bool {
        let st = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return st == .fullAccess }
        return st == .authorized
    }

    /// Keys end in "-<epoch>"; anything older than two days is forgotten.
    private func pruneFired(_ now: Date) {
        let cutoff = now.timeIntervalSince1970 - 2 * 86400
        let stale = fired.filter { key in
            guard let tail = key.split(separator: "-").last, let t = Double(tail) else { return true }
            return t < cutoff
        }
        if !stale.isEmpty { fired.subtract(stale); persistFired() }
    }

    func tick() {
        let now = Date()
        pruneFired(now)
        var changedReminders = false

        // Reminders: the most recent occurrence not yet announced, plus snoozes coming back.
        for i in reminders.indices where reminders[i].isActive {
            let r = reminders[i]
            if let until = r.snoozedUntil, until <= now {
                let occ = r.snoozedOccurrence.map { Date(timeIntervalSince1970: $0) }
                reminders[i].snoozedUntil = nil
                reminders[i].snoozedOccurrence = nil
                changedReminders = true
                let key = "snz-\(r.id)-\(Int(until.timeIntervalSince1970))"
                if !fired.contains(key), now.timeIntervalSince(until) < 6 * 3600, !(occ.map { r.isDone($0) } ?? false) {
                    raise(ReminderAlert(id: key, kind: .snoozed, headline: r.title, detail: "Snoozed · " + r.scheduleText,
                                        reminderID: r.id, occurrence: occ, hydration: r.isHydration))
                }
                continue
            }
            // A one-off whose time passed while the Mac slept (or Zera was closed) is still
            // announced, once, however late; a repeating one only within its window.
            let lookBack = r.rule.isRepeating ? Self.fireWindow : .greatestFiniteMagnitude
            guard let occ = r.last(atOrBefore: now, within: lookBack) else { continue }
            if r.isDone(occ) || r.isSnoozed(occ, now: now) { continue }
            let key = "rem-\(r.id)-\(Int(occ.timeIntervalSince1970))"
            guard !fired.contains(key) else { continue }
            let detail: String
            if r.rule.isRepeating {
                let next = r.next(after: occ).map { " · next " + ReminderFormat.time.string(from: $0) } ?? ""
                detail = r.scheduleText + next
            } else {
                detail = r.notes.isEmpty ? ReminderFormat.time.string(from: occ) : r.notes
            }
            raise(ReminderAlert(id: key, kind: .now, headline: r.title, detail: detail,
                                reminderID: r.id, occurrence: occ, hydration: r.isHydration))
        }
        if changedReminders { write(reminders, to: remindersURL); post() }

        // Events: a heads-up before, and a nudge as they start.
        for e in allEvents where !e.isAllDay && e.alertMinutes >= 0 {
            let lead = TimeInterval(e.alertMinutes * 60)
            for occ in e.occurrences(from: now.addingTimeInterval(-10 * 60), to: now.addingTimeInterval(lead + 60), limit: 4) {
                if isEventCompleted(e.id, occurrence: occ) { continue }
                let epoch = Int(occ.timeIntervalSince1970)
                let leadKey = "evl-\(e.id)-\(epoch)", atKey = "eva-\(e.id)-\(epoch)"
                let when = ReminderFormat.time.string(from: occ)
                let place = e.location.isEmpty ? "" : " · " + e.location
                if lead > 0, !fired.contains(leadKey), !fired.contains(atKey), now >= occ.addingTimeInterval(-lead), now < occ {
                    let mins = max(1, Int((occ.timeIntervalSince(now) / 60).rounded()))
                    let head = e.kind == .meeting ? "You have a meeting in \(mins) minute\(mins == 1 ? "" : "s")! ⏰" : "\(e.title) in \(mins) min ⏰"
                    raise(ReminderAlert(id: leadKey, kind: .calendarHeadsUp, headline: head,
                                        detail: (e.kind == .meeting ? e.title + " · " : "") + when + place,
                                        eventID: e.id, occurrence: occ, joinURL: e.joinURL))
                }
                if !fired.contains(atKey), now >= occ, now < occ.addingTimeInterval(10 * 60) {
                    raise(ReminderAlert(id: atKey, kind: .calendarNow, headline: "\(e.title) is starting now 📅",
                                        detail: when + place, eventID: e.id, occurrence: occ, joinURL: e.joinURL))
                }
            }
        }

        // Snoozed event / break alerts.
        let due = snoozes.filter { $0.until <= now }
        if !due.isEmpty {
            snoozes.removeAll { $0.until <= now }
            persistSnoozes()
            for s in due where now.timeIntervalSince(s.until) < 6 * 3600 {
                raise(ReminderAlert(id: "snz-\(s.key)-\(Int(s.until.timeIntervalSince1970))", kind: s.isBreak ? .breakTime : .snoozed,
                                    headline: s.headline, detail: s.detail, eventID: s.eventID,
                                    joinURL: s.eventID.flatMap { event($0)?.joinURL }))
            }
        }

        // Time away (idle, asleep) is a break already: the next nudge counts from when you're back.
        if userIsIdle { lastBreakAt = now }
        if breakInterval > 0, !userIsIdle,
           now.timeIntervalSince(lastBreakAt) >= Double(breakInterval) * 60,
           !pendingAlerts.contains(where: { $0.kind == .breakTime }) {
            lastBreakAt = now
            raise(ReminderAlert(id: "break-\(Int(now.timeIntervalSince1970))", kind: .breakTime,
                                headline: "Time for a short break? ☕",
                                detail: "You've been at it for \(breakInterval) minutes"))
        }
    }

    // MARK: - Calendar

    var calendarStatusText: String {
        if calendarAuthorized {
            let today = externalEvents.filter { Calendar.current.isDateInToday($0.startAt) }.count
            let synced = lastCalendarSync.map { " · synced \(relativeTime($0))" } ?? ""
            return (today == 0 ? "Connected · nothing today" : "Connected · \(today) today") + synced
        }
        if calendarDenied { return "Access denied — allow Zera in System Settings → Privacy → Calendars" }
        return "Not connected"
    }

    func connectCalendar() async {
        UserDefaults.standard.set(true, forKey: Self.calendarWantedPref)
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
        // reconnecting does not stack refreshes. Account syncs post this in bursts, so one
        // refresh runs once they settle.
        if let o = storeObserver { NotificationCenter.default.removeObserver(o) }
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleCalendarRefresh() }
        }
    }

    private var calendarRefreshWork: DispatchWorkItem?
    private func scheduleCalendarRefresh() {
        calendarRefreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.refreshCalendar() } }
        calendarRefreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    func disconnectCalendar() {
        UserDefaults.standard.set(false, forKey: Self.calendarWantedPref)
        calendarTimer?.invalidate(); calendarTimer = nil
        if let o = storeObserver { NotificationCenter.default.removeObserver(o); storeObserver = nil }
        calendarAuthorized = false
        calendarDenied = false
        externalEvents = []
        writableCalendars = []
        post()
    }

    /// The account a macOS calendar really syncs from. Anything we cannot tell apart is
    /// "Apple" (it is in Apple Calendar) — never guessed as Google or Outlook.
    nonisolated private static func source(of cal: EKCalendar) -> (CalendarEvent.Source, String) {
        let src: EKSource? = cal.source
        guard let s = src else { return (.apple, "On My Mac") }
        let t = s.title.lowercased()
        if s.sourceType == .exchange || t.contains("outlook") || t.contains("exchange") || t.contains("office 365") || t.contains("microsoft") {
            return (.outlook, s.title)
        }
        if t.contains("google") || t.contains("gmail") { return (.google, s.title) }
        return (.apple, s.title)
    }

    nonisolated private static func hex(_ c: NSColor?) -> String? {
        guard let c = c?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private var calendarRefreshing = false
    private var calendarRefreshAgain = false
    private let calendarQueue = DispatchQueue(label: "ai.zera.calendar", qos: .utility)

    /// Reads the next two weeks from macOS Calendar. The store is queried off the main thread
    /// (a few hundred events across several accounts take long enough to stall the island);
    /// one read runs at a time, and a request made meanwhile runs after it.
    func refreshCalendar() {
        guard calendarAuthorized else { return }
        guard !calendarRefreshing else { calendarRefreshAgain = true; return }
        calendarRefreshing = true
        let store = self.store
        calendarQueue.async { [weak self] in
            let (events, calendars) = Self.readCalendar(store)
            DispatchQueue.main.async {
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    self.calendarRefreshing = false
                    // The store was swapped (disconnected, or reconnected) while this read ran.
                    guard self.calendarAuthorized, store === self.store else { return }
                    self.externalEvents = events
                    self.writableCalendars = calendars
                    self.lastCalendarSync = Date()
                    self.post()
                    self.tick()
                    if self.calendarRefreshAgain { self.calendarRefreshAgain = false; self.refreshCalendar() }
                }
            }
        }
    }

    nonisolated private static func readCalendar(_ store: EKEventStore) -> ([CalendarEvent], [WritableCalendar]) {
        let cal = Calendar.current
        // Yesterday (for anything still running) through the next two weeks: Today + Upcoming.
        let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) ?? Date()
        let end = cal.date(byAdding: .day, value: 16, to: start) ?? Date()
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: pred).map { e in
            let (src, account) = Self.source(of: e.calendar)
            var ev = CalendarEvent(title: e.title ?? "Event", startAt: e.startDate,
                                   duration: max(0, e.endDate.timeIntervalSince(e.startDate)), kind: .other, source: src)
            ev.id = "ek-\(e.calendarItemIdentifier)-\(Int(e.startDate.timeIntervalSince1970))"
            ev.calendarName = (e.calendar.title) + (account.isEmpty ? "" : " · " + account)
            ev.isAllDay = e.isAllDay
            ev.location = e.location ?? ""
            ev.notes = e.notes ?? ""
            ev.url = e.url?.absoluteString
            ev.kind = (e.attendees?.isEmpty == false) ? .meeting : .other
            if let a = e.alarms?.first(where: { $0.relativeOffset < 0 }) {
                ev.alertMinutes = Int(-a.relativeOffset / 60)
            } else {
                ev.alertMinutes = 15
            }
            ev.colorHex = Self.hex(e.calendar.color)
            return ev
        }.sorted { $0.startAt < $1.startAt }
        let calendars = store.calendars(for: .event).filter { $0.allowsContentModifications }.map { c in
            let (src, account) = Self.source(of: c)
            return WritableCalendar(id: c.calendarIdentifier, title: c.title, source: src, account: account)
        }.sorted { ($0.source.rawValue, $0.title) < ($1.source.rawValue, $1.title) }
        return (events, calendars)
    }

    enum CalendarWriteError: Error { case noAccess, noCalendar }

    /// Creates the event in a real macOS calendar (which then syncs it to that account).
    func createInCalendar(_ ev: CalendarEvent, calendarID: String) throws {
        guard calendarAuthorized else { throw CalendarWriteError.noAccess }
        guard let target = store.calendar(withIdentifier: calendarID) else { throw CalendarWriteError.noCalendar }
        let e = EKEvent(eventStore: store)
        e.calendar = target
        e.title = ev.title
        e.isAllDay = ev.isAllDay
        e.startDate = ev.startAt
        e.endDate = ev.isAllDay ? ev.startAt : ev.startAt.addingTimeInterval(max(60, ev.duration))
        e.location = ev.location.isEmpty ? nil : ev.location
        e.notes = ev.notes.isEmpty ? nil : ev.notes
        if ev.alertMinutes >= 0 { e.addAlarm(EKAlarm(relativeOffset: -TimeInterval(ev.alertMinutes * 60))) }
        if let rule = Self.ekRule(ev.rule) { e.recurrenceRules = [rule] }
        try store.save(e, span: .futureEvents, commit: true)
        refreshCalendar()
    }

    private static func ekRule(_ r: RepeatRule) -> EKRecurrenceRule? {
        let freq: EKRecurrenceFrequency
        switch r.unit {
        case .day: freq = .daily
        case .week: freq = .weekly
        case .month: freq = .monthly
        case .year: freq = .yearly
        default: return nil
        }
        let days: [EKRecurrenceDayOfWeek]? = r.unit == .week && !r.weekdays.isEmpty
            ? r.weekdays.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } } : nil
        return EKRecurrenceRule(recurrenceWith: freq, interval: max(1, r.every), daysOfTheWeek: days, daysOfTheMonth: nil,
                                monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
                                end: r.endDate.map { d in
                                    // Zera's end day is inclusive: let EventKit run to the end of it.
                                    let c = Calendar.current
                                    let end = c.date(byAdding: .day, value: 1, to: c.startOfDay(for: d))?.addingTimeInterval(-1) ?? d
                                    return EKRecurrenceEnd(end: end)
                                })
    }
}
