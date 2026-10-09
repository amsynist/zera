import AppKit

// MARK: - Tasks
//
// A short to-do list with a focus timer. One task at a time is "in focus"; while its timer runs
// the time is added to that task, under the day it happened, so an export can say what you did
// on which date. Everything stays on this Mac in Application Support/Zera/tasks.json.

/// One thing to do, and the time you've spent on it.
struct FocusTask: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var created: Date
    /// Minutes you meant it to take ("Write docs 30m"); 0 when you didn't say.
    var estimate: Int
    /// Seconds focused, by day ("2026-10-07"). The running session isn't in here until it's folded in.
    var log: [String: TimeInterval] = [:]
    var doneAt: Date?
    /// Which project it belongs to ("Zera", "Client work"); nil reads as the default project.
    var project: String?
    /// Made from these commits (short hashes) by a linked folder's sync; nil for tasks you added.
    var commits: [String]?
    /// Those commits as "repo · abc1234 · subject", to show how the task was made.
    var commitNotes: [String]?

    init(id: UUID = UUID(), title: String, created: Date, estimate: Int) {
        self.id = id; self.title = title; self.created = created; self.estimate = estimate
    }

    /// Reads older (or hand-edited) files too: only the title is required.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        estimate = try c.decodeIfPresent(Int.self, forKey: .estimate) ?? 0
        log = try c.decodeIfPresent([String: TimeInterval].self, forKey: .log) ?? [:]
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        commits = try c.decodeIfPresent([String].self, forKey: .commits)
        commitNotes = try c.decodeIfPresent([String].self, forKey: .commitNotes)
    }

    var done: Bool { doneAt != nil }
    var spent: TimeInterval { log.values.reduce(0, +) }
    var fromCommits: Bool { !(commits ?? []).isEmpty }
    /// The repos its commits came from, in order, each once.
    var repos: [String] {
        var out: [String] = []
        for n in commitNotes ?? [] {
            let parts = n.components(separatedBy: " · ")
            if parts.count >= 3, !parts[0].isEmpty, !out.contains(parts[0]) { out.append(parts[0]) }
        }
        return out
    }
}

/// A project's code folders: each is a repo, or a folder of repos. Your commits in them become
/// done tasks.
struct ProjectLink: Codable, Equatable {
    var paths: [String]
    /// Commits up to here have been looked at.
    var syncedThrough: Date?
    /// Commits already turned into tasks (full hashes), so nothing comes in twice.
    var seen: [String] = []

    init(paths: [String]) { self.paths = paths }

    private enum CodingKeys: String, CodingKey { case paths, path, syncedThrough, seen }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        // Older saves had one `path`.
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? [c.decode(String.self, forKey: .path)]
        syncedThrough = try c.decodeIfPresent(Date.self, forKey: .syncedThrough)
        seen = try c.decodeIfPresent([String].self, forKey: .seen) ?? []
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(paths, forKey: .paths)
        try c.encodeIfPresent(syncedThrough, forKey: .syncedThrough)
        try c.encode(seen, forKey: .seen)
    }
}

final class TaskStore {
    static let shared = TaskStore(url: TaskStore.defaultURL)
    /// The list or the focus changed.
    static let changed = Notification.Name("TaskStore.changed")
    /// A second went by while focusing (only the clocks need redrawing).
    static let ticked = Notification.Name("TaskStore.ticked")
    /// Away from the keyboard this long and the timer pauses itself.
    static let idleLimit: TimeInterval = 300

    private(set) var tasks: [FocusTask] = []
    private(set) var focusID: UUID?
    /// When the running session started (or was last folded in); nil while paused.
    private(set) var runningSince: Date?
    /// Your projects, in the order you made them. Always holds the default.
    private(set) var projects: [String] = [TaskStore.firstProject]
    /// Where tasks go when no project is named (changeable).
    private(set) var defaultProject = TaskStore.firstProject
    /// The project the Tasks screen shows (and adds to); nil is All.
    var shownProject: String? { didSet { if loaded, shownProject != oldValue { saveAndPost() } } }
    /// Set once the file has been read, so nothing is written back while it is still being read.
    private var loaded = false
    static let firstProject = "General"
    /// Projects linked to a code folder, by project name.
    private(set) var links: [String: ProjectLink] = [:]
    /// The timer paused itself because nobody was at the keyboard.
    var onIdlePause: ((FocusTask) -> Void)?

    var now: () -> Date = Date.init
    var idleSeconds: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    var calendar = Calendar.current

    private let url: URL?
    private var timer: Timer?
    private var ticks = 0

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera", isDirectory: true).appendingPathComponent("tasks.json")
    }

    /// `url` nil keeps everything in memory (tests).
    init(url: URL?) {
        self.url = url
        load()
        loaded = true
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.sleepBegan() },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.wokeUp() }
        ]
    }

    deinit { sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
    private var sleepObservers: [NSObjectProtocol] = []

    // MARK: Sleep

    /// A gap between ticks this long means the Mac was asleep (the clock does not tick then).
    static let sleepGap: TimeInterval = 60
    private var lastTickAt: Date?

    /// Going to sleep: the time so far is booked; the session goes on from the wake, so the
    /// hours the lid was closed never count as focus.
    private func sleepBegan() {
        guard isRunning else { return }
        fold()
        save()
    }

    private func wokeUp() {
        guard isRunning else { return }
        runningSince = now()
        lastTickAt = nil
        saveAndPost()
    }

    // MARK: Reading

    var isRunning: Bool { runningSince != nil && focus != nil }
    var focus: FocusTask? { focusID.flatMap { id in tasks.first { $0.id == id && !$0.done } } }

    /// Seconds on this task so far, the running session included.
    func spent(_ t: FocusTask) -> TimeInterval {
        t.spent + (t.id == focusID ? running : 0)
    }
    private var running: TimeInterval { runningSince.map { max(0, now().timeIntervalSince($0)) } ?? 0 }

    /// What the list shows: everything still open, then what you finished today.
    var today: [FocusTask] { open + doneToday }
    var open: [FocusTask] { tasks.filter { !$0.done } }
    var doneToday: [FocusTask] {
        tasks.filter { $0.doneAt.map { calendar.isDate($0, inSameDayAs: now()) } ?? false }
            .sorted { $0.doneAt! < $1.doneAt! }
    }
    /// Seconds focused today, across every task.
    var focusedToday: TimeInterval {
        let key = dayKey(now())
        return tasks.reduce(0) { $0 + ($1.log[key] ?? 0) } + (isRunning ? running : 0)
    }
    /// How far the focused task is through its estimate (can pass 1). With no estimate, the ring
    /// goes round once an hour instead, like a clock hand.
    var progress: Double {
        guard let f = focus else { return 0 }
        guard f.estimate > 0 else { return spent(f).truncatingRemainder(dividingBy: 3600) / 3600 }
        return spent(f) / Double(f.estimate * 60)
    }

    /// A task's project, the default standing in for none.
    func project(of t: FocusTask) -> String {
        guard let p = t.project, projects.contains(p) else { return defaultProject }
        return p
    }

    /// Today's list for one project (nil: all of them).
    func today(in project: String?) -> [FocusTask] {
        guard let p = project else { return today }
        return today.filter { self.project(of: $0) == p }
    }

    func dayKey(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Changing

    /// "Write docs 30m" → a 30-minute task. `focus` starts its timer straight away.
    /// "#zera" anywhere in the text files it under that project (made if new); otherwise it goes
    /// to `project`, or the default.
    @discardableResult
    func add(_ text: String, focus start: Bool = false, project: String? = nil) -> FocusTask? {
        let (rest, tag) = Self.projectTag(text)
        let (title, minutes) = Self.parse(rest)
        guard !title.isEmpty else { return nil }
        var t = FocusTask(title: title, created: now(), estimate: minutes ?? 0)
        let p = tag.map { addProject($0) } ?? project.flatMap { projects.contains($0) ? $0 : nil } ?? defaultProject
        t.project = p
        tasks.append(t)
        if start { focusOn(t.id) } else { saveAndPost() }
        return t
    }

    /// Done ⇄ not done. Finishing the task in focus stops its timer.
    func toggleDone(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        if tasks[i].done {
            tasks[i].doneAt = nil
        } else {
            if id == focusID { fold(); runningSince = nil; focusID = nil; stopTimer() }
            tasks[i].doneAt = now()
        }
        saveAndPost()
    }

    /// Focus on this one (and start its clock); on the one already in focus, pause or resume.
    func focusOn(_ id: UUID) {
        guard tasks.contains(where: { $0.id == id && !$0.done }) else { return }
        if id == focusID, focus != nil { togglePause(); return }
        fold()
        focusID = id
        runningSince = now()
        startTimer()
        saveAndPost()
    }

    func togglePause() { isRunning ? pause() : resume() }

    func pause() {
        guard isRunning else { return }
        fold()
        runningSince = nil
        stopTimer()
        saveAndPost()
    }

    func resume() {
        guard focus != nil, runningSince == nil else { return }
        runningSince = now()
        startTimer()
        saveAndPost()
    }

    /// Moves focus to the next open task (after the current one, wrapping round) and starts it.
    func next() {
        let o = open
        guard !o.isEmpty else { return }
        let at = o.firstIndex { $0.id == focusID }
        let n = at.map { o[($0 + 1) % o.count] } ?? o[0]
        guard n.id != focusID else { if !isRunning { resume() }; return }
        focusOn(n.id)
    }

    func delete(_ id: UUID) {
        if id == focusID { fold(); focusID = nil; runningSince = nil; stopTimer() }
        tasks.removeAll { $0.id == id }
        saveAndPost()
    }

    func rename(_ id: UUID, to text: String) {
        let (title, minutes) = Self.parse(text)
        guard !title.isEmpty, let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].title = title
        if let m = minutes { tasks[i].estimate = m }
        saveAndPost()
    }

    // MARK: Projects

    /// Adds a project (or finds one with that name, ignoring case) and returns its name.
    @discardableResult
    func addProject(_ name: String) -> String {
        let n = Self.cleanProject(name)
        guard !n.isEmpty else { return defaultProject }
        if let have = projects.first(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { return have }
        projects.append(n)
        saveAndPost()
        return n
    }

    /// Renames a project and every task in it. False if the name is empty or taken.
    @discardableResult
    func renameProject(_ old: String, to name: String) -> Bool {
        let n = Self.cleanProject(name)
        guard !n.isEmpty, let i = projects.firstIndex(of: old) else { return false }
        if n == old { return true }
        guard !projects.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame && $0 != old }) else { return false }
        projects[i] = n
        for j in tasks.indices where tasks[j].project == old { tasks[j].project = n }
        if defaultProject == old { defaultProject = n }
        if shownProject == old { shownProject = n }
        if let l = links.removeValue(forKey: old) { links[n] = l }
        saveAndPost()
        return true
    }

    /// Deletes a project; its tasks move to the default. The default itself can't go.
    func deleteProject(_ name: String) {
        guard name != defaultProject, let i = projects.firstIndex(of: name) else { return }
        projects.remove(at: i)
        for j in tasks.indices where tasks[j].project == name { tasks[j].project = defaultProject }
        if shownProject == name { shownProject = nil }
        links[name] = nil
        saveAndPost()
    }

    // MARK: Linked folders

    /// Adds a folder (a repo, or a folder of repos) to a project. Already-seen commits stay seen.
    func link(_ project: String, to path: String) {
        guard projects.contains(project) else { return }
        var l = links[project] ?? ProjectLink(paths: [])
        // A folder inside one already linked adds nothing; one around them replaces them.
        if l.paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return }
        l.paths.removeAll { $0.hasPrefix(path + "/") }
        l.paths.append(path)
        links[project] = l
        saveAndPost()
    }

    /// Removes one folder, or (nil) every folder, from a project.
    func unlink(_ project: String, path: String? = nil) {
        if let p = path, var l = links[project] {
            l.paths.removeAll { $0 == p }
            links[project] = l.paths.isEmpty ? nil : l
            saveAndPost()
            return
        }
        links[project] = nil
        saveAndPost()
    }

    /// Done tasks made from a folder's commits, and how far it's been read. `replacing`: a rebuild —
    /// the project's commit tasks from that day on go in the same step the new ones come in, so a
    /// rebuild that's stopped partway never leaves the timesheet empty.
    func importCommits(_ project: String, tasks new: [FocusTask], seen: [String], through: Date, replacing since: Date? = nil) {
        guard var l = links[project] else { return }
        if let since = since {
            let gone = tasks.filter { $0.fromCommits && self.project(of: $0) == project && ($0.doneAt ?? $0.created) >= since }
            tasks.removeAll { t in gone.contains { $0.id == t.id } }
            let shorts = Set(gone.flatMap { $0.commits ?? [] })
            l.seen.removeAll { shorts.contains(String($0.prefix(7))) }
        }
        tasks.append(contentsOf: new)
        l.seen = Array((l.seen + seen).suffix(2000))
        l.syncedThrough = through
        links[project] = l
        saveAndPost()
    }

    func setDefaultProject(_ name: String) {
        guard projects.contains(name) else { return }
        defaultProject = name
        saveAndPost()
    }

    /// Moves a task to another project.
    func move(_ id: UUID, to project: String) {
        guard projects.contains(project), let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].project = project
        saveAndPost()
    }

    /// "Write docs #zera 30m" → ("Write docs 30m", "zera"). Only the first tag counts, and it
    /// starts with a letter, so "PR #8" stays a title.
    static func projectTag(_ text: String) -> (String, String?) {
        guard let re = try? NSRegularExpression(pattern: #"(?:^|\s)#(\p{L}[^\s#]*)"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text), let tag = Range(m.range(at: 1), in: text) else { return (text, nil) }
        let name = String(text[tag]).replacingOccurrences(of: "_", with: " ")
        var rest = text
        rest.replaceSubrange(r, with: " ")
        return (rest.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "), name)
    }

    private static func cleanProject(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
    }

    /// Adds the running session to the focused task's log, under today, and restarts the session clock.
    private func fold(until end: Date? = nil) {
        guard let since = runningSince, let id = focusID, let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let stop = end ?? now()
        let secs = max(0, stop.timeIntervalSince(since))
        if secs > 0 { tasks[i].log[dayKey(since), default: 0] += secs }
        runningSince = stop
    }

    // MARK: The clock

    private func startTimer() {
        guard timer == nil else { return }
        ticks = 0
        lastTickAt = nil
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// Once a second while focusing: redraw the clocks, fold the time in every 30 s (so a crash
    /// loses little, and time lands on the right day), and pause when you've walked away.
    func tick() {
        guard isRunning else { stopTimer(); return }
        let t = now()
        if let last = lastTickAt, t.timeIntervalSince(last) > Self.sleepGap {
            // The clock stood still: the Mac slept (and the sleep notice was missed). Time up to
            // the last tick counts; the gap does not.
            fold(until: last)
            runningSince = t
            saveAndPost()
        }
        lastTickAt = t
        let idle = idleSeconds()
        if idle >= Self.idleLimit, let f = focus {
            fold(until: now().addingTimeInterval(-idle))
            runningSince = nil
            stopTimer()
            saveAndPost()
            onIdlePause?(f)
            return
        }
        ticks += 1
        if ticks % 30 == 0 { fold(); save() }
        NotificationCenter.default.post(name: Self.ticked, object: self)
    }

    // MARK: Parsing

    /// "Write docs 30m" → ("Write docs", 30); "Deploy 1h30m" → ("Deploy", 90); "Read" → ("Read", nil).
    static func parse(_ text: String) -> (String, Int?) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\s+(?:(\d+(?:\.\d+)?)\s*h(?:rs?|ours?)?)?\s*(?:(\d+)\s*m(?:in(?:s|utes?)?)?)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.range.length > 0 else { return (s, nil) }
        func num(_ i: Int) -> Double? { Range(m.range(at: i), in: s).flatMap { Double(s[$0]) } }
        let h = num(1), mins = num(2)
        guard h != nil || mins != nil else { return (s, nil) }
        let total = Int(((h ?? 0) * 60 + (mins ?? 0)).rounded())
        let title = String(s[..<Range(m.range, in: s)!.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard total > 0, !title.isEmpty else { return (s, nil) }
        return (title, min(total, 24 * 60))
    }

    // MARK: Saving

    private struct Saved: Codable {
        /// The file's format; readers tolerate missing fields, so this only needs to go up for
        /// a change they cannot absorb.
        var version: Int? = 1
        var tasks: [FocusTask]
        var focus: UUID?
        var projects: [String]?
        var defaultProject: String?
        var shownProject: String?
        var links: [String: ProjectLink]?
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let url = url, let data = try? Data(contentsOf: url) else { return }
        guard let saved = try? dec.decode(Saved.self, from: data) else {
            // An unreadable file (a cut-off write, a hand edit) is set aside, never written
            // over by the empty list that would otherwise be saved next.
            let stamp = Int(now().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("broken-\(stamp).json"))
            return
        }
        tasks = saved.tasks
        // Tasks made from commits are done work with nothing to aim for (older ones had a made-up estimate).
        for i in tasks.indices where tasks[i].fromCommits { tasks[i].estimate = 0 }
        projects = saved.projects ?? []
        // Projects named on tasks but missing from the list come back too.
        for p in tasks.compactMap(\.project) where !projects.contains(p) { projects.append(p) }
        defaultProject = saved.defaultProject ?? projects.first ?? Self.firstProject
        if !projects.contains(defaultProject) { projects.insert(defaultProject, at: 0) }
        shownProject = saved.shownProject.flatMap { projects.contains($0) ? $0 : nil }
        links = (saved.links ?? [:]).filter { projects.contains($0.key) }
        // A session that was running when Zera quit stays paused; the time up to its last fold is kept.
        focusID = saved.focus
        // Keep the list short: finished tasks older than 90 days go (export them first if you need them).
        let cutoff = now().addingTimeInterval(-90 * 86_400)
        tasks.removeAll { ($0.doneAt ?? .distantFuture) < cutoff }
    }

    /// Writes go here in order; the file (every commit hash of every linked repo) is not small,
    /// and it is saved every 30 s while a timer runs.
    private let saveQueue = DispatchQueue(label: "ai.zera.tasks-save", qos: .utility)

    private func save() {
        guard let url = url else { return }
        let snapshot = Saved(tasks: tasks, focus: focusID, projects: projects, defaultProject: defaultProject, shownProject: shownProject, links: links)
        saveQueue.async { Self.write(snapshot, to: url) }
    }

    private static func write(_ saved: Saved, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(saved) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveAndPost() {
        save()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// Fold the running session in and finish writing before Zera quits.
    func flush() {
        fold()
        save()
        saveQueue.sync {}
    }
}
