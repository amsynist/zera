import AppKit
import Carbon.HIToolbox

// MARK: - Settings (Settings › Shelf › Daily Shelf)

struct DailyShelfSettings: Codable, Equatable {
    var enabled = true
    var edge = DailyShelfEdge.left.rawValue
    var align = DailyShelfAlign.center.rawValue
    var offset: Double = 0
    var attached = true
    var width: Double = 360
    var minHeight: Double = 420
    var maxHeight: Double = 820
    var height: Double = 620
    var radius: Double = 22
    var openOnHover = true
    var hoverDelay = 180
    var showHandle = true
    var keepOpen = false
    var carryOpenPRs = true
    var sortWithClaude = true
    var rolloverHour = 4
    /// The shortcut that opens and closes the shelf. `hotKeyOff` keeps a cleared shortcut cleared.
    var hotKey: HotKeyShortcut? = DailyShelfSettings.defaultHotKey
    var hotKeyOff = false
    var collapsed: [String] = []
    var filter = "all"
    /// Your order for the sections (kind raw values) and for site categories, from dragging them.
    var sectionOrder: [String] = []
    var categoryOrder: [String] = []
    /// Sections ("section:jira") and site categories ("category:Dev tools") kept every day, with all their items.
    var pinnedGroups: [String] = []
    /// When a site and its parent domain publish no icon, ask DuckDuckGo's icon service for the public domain only.
    var iconService = true

    static let defaultHotKey = HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey), key: "Space")
    /// Nil when you cleared it.
    var effectiveHotKey: HotKeyShortcut? { hotKeyOff ? nil : (hotKey ?? Self.defaultHotKey) }

    static let widths: [Double] = [320, 360, 420]
    static let minHeights: [Double] = [320, 380, 420, 480, 560]
    static let maxHeights: [Double] = [600, 720, 820, 960, 1100]
    static let radii: [Double] = [12, 18, 22, 28]
    static let hoverDelays = [0, 120, 180, 300, 500]
    static let rolloverHours = [0, 2, 3, 4, 5, 6]

    var placement: DailyShelfPlacement {
        DailyShelfPlacement(edge: DailyShelfEdge(rawValue: edge) ?? .left, align: DailyShelfAlign(rawValue: align) ?? .center,
                            offset: CGFloat(offset), attached: attached, width: CGFloat(width), minHeight: CGFloat(minHeight),
                            maxHeight: CGFloat(max(minHeight, maxHeight)), height: CGFloat(height), radius: CGFloat(radius))
    }

    init() {}

    /// Missing keys keep their defaults, so adding a setting never resets the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DailyShelfSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        enabled = v(.enabled, d.enabled); edge = v(.edge, d.edge); align = v(.align, d.align); offset = v(.offset, d.offset)
        attached = v(.attached, d.attached); width = v(.width, d.width); minHeight = v(.minHeight, d.minHeight)
        maxHeight = v(.maxHeight, d.maxHeight); height = v(.height, d.height); radius = v(.radius, d.radius)
        openOnHover = v(.openOnHover, d.openOnHover); hoverDelay = v(.hoverDelay, d.hoverDelay); showHandle = v(.showHandle, d.showHandle)
        keepOpen = v(.keepOpen, d.keepOpen); carryOpenPRs = v(.carryOpenPRs, d.carryOpenPRs); sortWithClaude = v(.sortWithClaude, d.sortWithClaude)
        rolloverHour = v(.rolloverHour, d.rolloverHour); collapsed = v(.collapsed, d.collapsed)
        hotKey = (try? c.decodeIfPresent(HotKeyShortcut.self, forKey: .hotKey)) ?? d.hotKey; hotKeyOff = v(.hotKeyOff, d.hotKeyOff)
        filter = v(.filter, d.filter)
        sectionOrder = v(.sectionOrder, d.sectionOrder); categoryOrder = v(.categoryOrder, d.categoryOrder)
        pinnedGroups = v(.pinnedGroups, d.pinnedGroups); iconService = v(.iconService, d.iconService)
    }

    private static let key = "zera.dailyShelf.settings"
    nonisolated static let changed = Notification.Name("ZeraDailyShelfSettingsChanged")

    static var current: DailyShelfSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let s = try? JSONDecoder().decode(DailyShelfSettings.self, from: data) else { return DailyShelfSettings() }
            return s
        }
        set {
            guard newValue != current else { return }
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func update(_ change: (inout DailyShelfSettings) -> Void) {
        var s = current
        change(&s)
        current = s
    }
}

// MARK: - The store

/// Today's items, one JSON file per day, the history behind it and the sites you have filed yourself.
@MainActor
final class DailyShelfStore {
    /// Replaceable so render fixtures can use a disposable folder.
    static var shared = DailyShelfStore()
    /// `userInfo["landed"]`: the id of an item that just arrived or changed, to highlight.
    nonisolated static let changed = Notification.Name("ZeraDailyShelfChanged")

    let folder: URL
    private(set) var day: String
    private(set) var items: [DailyShelfItem] = []
    private(set) var learned: [String: String] = [:]
    private(set) var lastError: String?
    /// How many history days are kept.
    static let historyDays = 14

    private let settings: () -> DailyShelfSettings

    init(folder: URL? = nil, now: Date = Date(), settings: @escaping () -> DailyShelfSettings = { .current }) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera/DailyShelf", isDirectory: true)
        self.settings = settings
        self.day = DailyShelfClock.dayKey(for: now, rolloverHour: settings().rolloverHour)
        load()
    }

    var fileURL: URL { url(for: day) }
    private func url(for key: String) -> URL { folder.appendingPathComponent("\(key).json") }
    private var learnedURL: URL { folder.appendingPathComponent("learned.json") }

    // MARK: Loading and the day

    private func load() {
        if let data = try? Data(contentsOf: learnedURL), let l = try? JSONDecoder().decode([String: String].self, from: data) { learned = l }
        if let today = read(day) {
            items = today.items
        } else if let previous = previousKey(before: day), let old = read(previous) {
            // The app was closed over the rollover: start today from what yesterday kept.
            items = DailyShelfClock.carryOver(old.items, carryOpenPRs: settings().carryOpenPRs, pinnedGroups: Set(settings().pinnedGroups)).kept
            save()
        }
    }

    private func read(_ key: String) -> DailyShelfDay? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? Self.decoder.decode(DailyShelfDay.self, from: data)
    }

    /// Day files on disk, newest first.
    func dayKeys() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil }
            .map { String($0.dropLast(5)) }.sorted(by: >)
    }

    private func previousKey(before key: String) -> String? { dayKeys().first { $0 < key } }

    /// Starts a new day when the rollover hour has passed. Returns true when it did.
    @discardableResult
    func checkRollover(now: Date = Date()) -> Bool {
        let key = DailyShelfClock.dayKey(for: now, rolloverHour: settings().rolloverHour)
        guard key != day else { return false }
        save()
        let kept = DailyShelfClock.carryOver(items, carryOpenPRs: settings().carryOpenPRs, pinnedGroups: Set(settings().pinnedGroups)).kept
        day = key
        if let existing = read(key) {
            items = existing.items
            for k in kept where !items.contains(where: { $0.id == k.id || ($0.url != nil && $0.url == k.url) }) { items.append(k) }
        } else {
            items = kept
        }
        save()
        prune(now: now)
        post()
        return true
    }

    /// The most recent earlier day, minus what is on the shelf today.
    func previousDay() -> DailyShelfDay? {
        guard let key = previousKey(before: day), var d = read(key) else { return nil }
        d.items.removeAll { old in items.contains { $0.id == old.id || ($0.url != nil && $0.url == old.url) } }
        return d
    }

    private func prune(now: Date) {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -Self.historyDays, to: now) else { return }
        let cutoff = DailyShelfClock.dayKey(for: cutoffDate, rolloverHour: settings().rolloverHour)
        for key in dayKeys() where key < cutoff { try? FileManager.default.removeItem(at: url(for: key)) }
    }

    // MARK: Changes

    /// Adds a link. An existing one is not added twice; it is returned so the shelf can point at it.
    @discardableResult
    func add(link raw: URL, title: String?) -> (item: DailyShelfItem, isNew: Bool) {
        let link = Self.canonical(raw)
        if let existing = items.first(where: { $0.url == link.absoluteString }) { return (existing, false) }
        let given = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = (given?.isEmpty == false && given != raw.absoluteString && given != link.absoluteString) ? given : nil
        var it: DailyShelfItem
        if let m = DailyShelfRules.match(link, learned: learned) {
            it = DailyShelfItem(kind: m.kind, url: link.absoluteString, title: usable ?? "", category: m.category,
                                categorySource: m.kind == .site ? .user : .rule)
            if let pr = m.pr {
                it.github = DailyShelfPR(owner: pr.owner, repo: pr.repo, number: pr.number)
                if it.title.isEmpty { it.title = "\(pr.repo) #\(pr.number)" }
            }
            if let key = m.jiraKey { it.jiraKey = key; if it.title.isEmpty { it.title = key } }
        } else {
            it = DailyShelfItem(kind: .site, url: link.absoluteString, title: usable ?? "", category: DailyShelfRules.fallbackCategory,
                                categorySource: .rule)
            it.sorting = settings().sortWithClaude
        }
        if it.title.isEmpty { it.title = DailyShelfRules.fallbackTitle(for: link) }
        items.insert(it, at: 0)
        save()
        post(landed: it.id)
        return (it, true)
    }

    @discardableResult
    func addNote(_ text: String) -> DailyShelfItem {
        let it = DailyShelfItem(kind: .note, url: nil, title: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                category: "Notes", categorySource: .rule)
        items.insert(it, at: 0)
        save()
        post(landed: it.id)
        return it
    }

    /// Changes one item. `quiet` skips the highlight (status refreshes).
    func update(_ id: UUID, landed: Bool = false, _ change: (inout DailyShelfItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var it = items[i]
        change(&it)
        guard it != items[i] || it.sorting != items[i].sorting else { return }
        items[i] = it
        save()
        post(landed: landed ? id : nil)
    }

    /// Rename only the label on this shelf, keeping its link and remote record intact.
    @discardableResult
    func rename(_ id: UUID, to title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, items.contains(where: { $0.id == id }) else { return false }
        update(id) { $0.title = clean; $0.customTitle = true }
        return true
    }

    func setAccent(_ id: UUID, to accent: DailyShelfAccent?) {
        update(id) { $0.accent = accent }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
        post()
    }

    func togglePin(_ id: UUID) { update(id) { $0.pinned.toggle(); if $0.pinned { $0.carried = nil } } }

    func markOpened(_ id: UUID) { update(id) { $0.opens += 1 } }

    /// Files a site where you put it, and remembers that for the site from now on.
    func move(_ id: UUID, to category: String) {
        guard let it = items.first(where: { $0.id == id }) else { return }
        if let host = it.host { learned[host] = category; saveLearned() }
        update(id, landed: true) { $0.kind = .site; $0.category = category; $0.categorySource = .user; $0.sorting = false }
    }

    /// Refiles a link you dragged to another category or to Docs. Sites remember it per site.
    func refile(_ id: UUID, kind: DailyShelfKind, category: String) {
        guard let it = items.first(where: { $0.id == id }), it.kind == .site || it.kind == .doc else { return }
        if kind == .site, let host = it.host { learned[host] = category; saveLearned() }
        update(id, landed: true) { $0.kind = kind; $0.category = category; $0.categorySource = .user; $0.sorting = false; $0.layout = nil }
    }

    /// Takes everything off today's shelf except pinned items and what sits in a pinned category or
    /// section. Returns what was on the shelf before, for Undo.
    @discardableResult
    func clearToday() -> [DailyShelfItem] {
        let before = items
        let pinnedGroups = Set(settings().pinnedGroups)
        items.removeAll { !$0.pinned && !pinnedGroups.contains($0.groupKey) }
        guard items.count != before.count else { return [] }
        save()
        post()
        return before
    }

    /// Puts back what Clear took, in its old order, keeping anything added since.
    func undoClear(_ before: [DailyShelfItem]) {
        guard !before.isEmpty else { return }
        let added = items.filter { now in !before.contains { $0.id == now.id } }
        let current = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = added + before.map { current[$0.id] ?? $0 }
        save()
        post()
    }

    func bringBack(_ old: DailyShelfItem) {
        guard !items.contains(where: { $0.id == old.id }) else { return }
        var it = old
        it.carried = true
        items.insert(it, at: 0)
        save()
        post(landed: it.id)
    }

    // MARK: Saving

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func save() {
        let hour = settings().rolloverHour
        let doc = DailyShelfDay(day: day, rollsOverAt: String(format: "%02d:00", hour), items: items)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.encoder.encode(doc).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Diag.log("daily shelf: save failed: \(error.localizedDescription)")
        }
    }

    private func saveLearned() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Self.encoder.encode(learned).write(to: learnedURL, options: .atomic)
    }

    private func post(landed: UUID? = nil) {
        NotificationCenter.default.post(name: Self.changed, object: self, userInfo: landed.map { ["landed": $0] })
    }

    /// One form per pull request, so /files, /commits or a trailing slash don't add it twice.
    static func canonical(_ url: URL) -> URL {
        if let m = DailyShelfRules.match(url), let pr = m.pr,
           let u = URL(string: "https://github.com/\(pr.owner)/\(pr.repo)/pull/\(pr.number)") { return u }
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.fragment = nil
        if c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        return c.url ?? url
    }
}
