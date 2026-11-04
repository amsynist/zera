import AppKit

// MARK: - Alerts island
//
//  Alerts                          (Zera)                 [⊗ Clear all]
//  2 need you · 9 today
//  [ All | Agents | PRs | Reminders | System ]
//  NEEDS YOU
//  [✋] Claude is waiting for approval          3 min ago   (✕ on hover)
//  [👁] Review requested · zera/notch #42        1 h ago
//  EARLIER
//  [✓] CI passed · zera/notch #41               yesterday
//
// One inbox for everything that nudged you: Claude approvals waiting, GitHub events, reminder
// and meeting alerts, battery and hydration. Rows come from `AlertCenter`, which fills itself
// from the services that already post notifications — nothing here polls. Tap a row to open
// its source screen or URL; ✕ dismisses one, "Clear all" empties the inbox.

// MARK: - Model

/// One thing in the inbox. `id` is stable per source item (a GitHub event, a hook request…),
/// so a source refreshed twice updates the row instead of adding a second one.
struct ZeraAlert: Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case agent, pullRequest, reminder, meeting, battery, hydration, system
    }

    let id: String
    let kind: Kind
    var title: String
    var detail: String
    var date: Date
    /// SF Symbol for the icon tile.
    var symbol: String
    var tint: NSColor
    /// Opened in the browser on tap, when there is one.
    var url: URL? = nil
    /// The screen to open on tap, when the alert belongs to one.
    var opens: CardKind? = nil
    /// Still waiting on you: listed under "Needs you" rather than "Earlier".
    var isActionable: Bool = false
}

// MARK: - Inbox

/// The alerts inbox: in memory, mirrored to ~/Library/Application Support/Zera/alerts.json
/// (the last 200). Fills itself from GitHubService, ClaudeHookService, ClaudeActivityService
/// and ReminderService (which BatteryAlerts and hydration nudges both go through) whenever
/// they post a change — event-driven, no timers. Anything else can `post` an alert directly.
@MainActor
final class AlertCenter {
    static let shared = AlertCenter()

    /// Posted after any change to `alerts` or the unread count.
    nonisolated static let changed = Notification.Name("ZeraAlertsChanged")
    /// How many alerts the inbox keeps.
    static let keep = 200
    /// How many dismissed ids are remembered, so a source cannot bring them back.
    private static let keepDismissed = 400

    /// Newest first.
    private(set) var alerts: [ZeraAlert] = []
    private var seen: Set<String> = []
    private var dismissed: [String] = []
    private var dismissedSet: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "zera.alerts.save", qos: .utility)
    private let url: URL?

    /// Alerts you have not looked at (the badge on the Alerts tab).
    var unread: Int { alerts.reduce(0) { $0 + (seen.contains($1.id) ? 0 : 1) } }
    /// Alerts still waiting on you.
    var needsYou: Int { alerts.reduce(0) { $0 + ($1.isActionable ? 1 : 0) } }
    /// Alerts that arrived today.
    var today: Int {
        let cal = Calendar.current
        return alerts.reduce(0) { $0 + (cal.isDateInToday($1.date) ? 1 : 0) }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera", isDirectory: true).appendingPathComponent("alerts.json")
    }

    private convenience init() { self.init(url: Self.defaultURL) }

    /// `url` nil keeps everything in memory (tests).
    init(url: URL?) {
        self.url = url
        load()
        subscribe()
    }

    // MARK: API

    /// Adds `a` (or updates the alert with the same id). Newest first. Posts `changed`.
    func post(_ a: ZeraAlert) {
        guard insert(a) else { return }
        saveAndPost()
    }

    func dismiss(id: String) {
        guard alerts.contains(where: { $0.id == id }) else { return }
        alerts.removeAll { $0.id == id }
        seen.remove(id)
        forget(id)
        saveAndPost()
    }

    func clearAll() {
        guard !alerts.isEmpty else { return }
        for a in alerts { forget(a.id) }
        alerts = []
        seen = []
        saveAndPost()
    }

    func markAllSeen() {
        let all = Set(alerts.map(\.id))
        guard seen != all else { return }
        seen = all
        saveAndPost()
    }

    /// Pulls what the services hold right now: GitHub's feed, Claude's pending approvals and
    /// sessions waiting on you, and the reminder / battery / hydration banners. Items that a
    /// source no longer lists stop being actionable and slide down to "Earlier".
    func refreshFromSources() {
        let p = Pal
        var live: Set<String> = []
        var dirty = false

        // GitHub: every event in the feed; the ones that want something from you are actionable.
        let gh = GitHubService.shared
        for e in gh.events {
            let id = "gh-" + e.id
            live.insert(id)
            let a = ZeraAlert(id: id, kind: .pullRequest, title: Self.heading(for: e), detail: "\(e.title) · \(e.subtitle)",
                              date: e.date, symbol: e.symbol, tint: e.tint, url: e.url, opens: .github,
                              isActionable: Self.wantsYou(e))
            if insert(a) { dirty = true }
        }

        // Claude Code: tool calls blocked on the approval hook.
        for r in ClaudeHookService.shared.pending {
            let id = "hook-" + r.id
            live.insert(id)
            let what = r.command.isEmpty ? r.toolName : r.command
            let a = ZeraAlert(id: id, kind: .agent, title: "Claude is waiting for approval",
                              detail: "\(r.toolName) · \(Self.oneLine(what)) · \(r.cwdDisplay)",
                              date: r.receivedAt, symbol: "terminal.fill", tint: p.tileClaude, opens: .approval, isActionable: true)
            if insert(a) { dirty = true }
        }

        // Claude Code: sessions whose last hook notification was a permission prompt.
        for s in ClaudeActivityService.shared.active where s.status == .waiting {
            let id = "claude-wait-" + s.id
            live.insert(id)
            let step = s.currentStep
            let detail = step?.detail ?? step?.text ?? (s.title.isEmpty ? "Claude Code session" : s.title)
            let a = ZeraAlert(id: id, kind: .agent, title: "Claude is waiting for you in \(s.folderName)",
                              detail: Self.oneLine(detail), date: stamp(id, or: step?.at ?? s.lastEventAt),
                              symbol: "hand.raised.fill", tint: p.tileClaude, opens: .claude, isActionable: true)
            if insert(a) { dirty = true }
        }

        // Reminders, meetings, breaks, hydration and the battery all arrive as reminder banners.
        for r in ReminderService.shared.pendingAlerts {
            let id = "rem-" + r.id
            live.insert(id)
            let kind: ZeraAlert.Kind
            let symbol: String
            let tint: NSColor
            if r.kind == .battery {
                kind = .battery; symbol = "battery.25"; tint = p.warning
            } else if r.hydration {
                kind = .hydration; symbol = "drop.fill"; tint = p.water
            } else if r.isEvent {
                kind = .meeting; symbol = "calendar"; tint = p.tileCalendar
            } else if r.kind == .breakTime {
                kind = .system; symbol = "cup.and.saucer.fill"; tint = p.info
            } else {
                kind = .reminder; symbol = "bell.fill"; tint = p.warning
            }
            let a = ZeraAlert(id: id, kind: kind, title: r.headline, detail: r.detail, date: stamp(id, or: Date()),
                              symbol: symbol, tint: tint, url: r.joinURL, opens: r.kind == .battery ? .home : .reminders, isActionable: true)
            if insert(a) { dirty = true }
        }

        // Gone from its source (answered, dismissed, merged): no longer needs you.
        for i in alerts.indices where alerts[i].isActionable && Self.isSourced(alerts[i].id) && !live.contains(alerts[i].id) {
            alerts[i].isActionable = false
            dirty = true
        }

        if dirty { saveAndPost() }
    }

    // MARK: Mapping

    /// The headline for a GitHub event, worded as the toast banner words it.
    static func heading(for e: GHEvent) -> String {
        switch e.kind {
        case .prOpened: return e.mine ? "Your PR is up" : "New PR opened"
        case .reviewRequested: return "Review requested"
        case .ciFailed: return "CI failed"
        case .ciPassed: return "CI passed"
        case .ciRunning: return "Checks running"
        case .needsApproval: return "Run waiting for approval"
        case .prApproved: return "Your PR was approved"
        case .prChangesRequested: return "Changes requested"
        case .prCommented: return "New comment on your PR"
        }
    }

    /// Events that ask something of you, as opposed to news.
    static func wantsYou(_ e: GHEvent) -> Bool {
        switch e.kind {
        case .reviewRequested, .needsApproval, .ciFailed, .prChangesRequested, .prCommented: return true
        case .prOpened, .ciRunning, .ciPassed, .prApproved: return false
        }
    }

    /// Ids this inbox fills in from a service (and so may mark resolved).
    private static func isSourced(_ id: String) -> Bool {
        id.hasPrefix("gh-") || id.hasPrefix("hook-") || id.hasPrefix("claude-wait-") || id.hasPrefix("rem-")
    }

    private static func oneLine(_ s: String, limit: Int = 120) -> String {
        let one = s.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return one.count > limit ? String(one.prefix(limit)) + "…" : one
    }

    /// The date an alert already in the inbox carries, so a refresh does not move it.
    private func stamp(_ id: String, or date: Date) -> Date {
        alerts.first { $0.id == id }?.date ?? date
    }

    // MARK: Mutation

    /// Adds or updates `a`; `false` when nothing changed (same content, or dismissed earlier).
    @discardableResult
    private func insert(_ a: ZeraAlert) -> Bool {
        if dismissedSet.contains(a.id) { return false }
        if let i = alerts.firstIndex(where: { $0.id == a.id }) {
            if alerts[i] == a { return false }
            alerts[i] = a
        } else {
            alerts.append(a)
        }
        alerts.sort { $0.date > $1.date }
        if alerts.count > Self.keep {
            for a in alerts[Self.keep...] { seen.remove(a.id) }
            alerts.removeLast(alerts.count - Self.keep)
        }
        return true
    }

    private func forget(_ id: String) {
        guard !dismissedSet.contains(id) else { return }
        dismissed.append(id)
        dismissedSet.insert(id)
        if dismissed.count > Self.keepDismissed {
            let drop = dismissed.prefix(dismissed.count - Self.keepDismissed)
            drop.forEach { dismissedSet.remove($0) }
            dismissed.removeFirst(drop.count)
        }
    }

    private func saveAndPost() {
        save()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    // MARK: Sources

    private func subscribe() {
        let names = [GitHubService.changed, GitHubService.newEvents,
                     ClaudeHookService.changed, ClaudeHookService.newRequest,
                     ClaudeActivityService.changed, ClaudeActivityService.milestone,
                     ReminderService.changed, ReminderService.alert]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
    }

    /// Services post in bursts (every Claude tool call, each poll); one refresh runs once they settle.
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.refreshFromSources() } }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    // MARK: Persistence

    private struct StoredAlert: Codable {
        var id: String
        var kind: String
        var title: String
        var detail: String
        var date: Date
        var symbol: String
        /// sRGB red, green, blue, alpha.
        var tint: [Double]
        var url: String?
        var opens: Int?
        var actionable: Bool
        var seen: Bool
    }
    private struct Saved: Codable {
        var alerts: [StoredAlert]
        var dismissed: [String]
    }

    private func load() {
        guard let url = url, let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let saved = try? dec.decode(Saved.self, from: data) else { return }
        var list: [ZeraAlert] = []
        for s in saved.alerts {
            guard let kind = ZeraAlert.Kind(rawValue: s.kind) else { continue }
            let c = s.tint.count == 4
                ? NSColor(srgbRed: CGFloat(s.tint[0]), green: CGFloat(s.tint[1]), blue: CGFloat(s.tint[2]), alpha: CGFloat(s.tint[3]))
                : Pal.accent
            list.append(ZeraAlert(id: s.id, kind: kind, title: s.title, detail: s.detail, date: s.date, symbol: s.symbol, tint: c,
                                  url: s.url.flatMap { URL(string: $0) }, opens: s.opens.flatMap { CardKind(rawValue: $0) },
                                  isActionable: s.actionable))
            if s.seen { seen.insert(s.id) }
        }
        alerts = Array(list.sorted { $0.date > $1.date }.prefix(Self.keep))
        dismissed = Array(saved.dismissed.suffix(Self.keepDismissed))
        dismissedSet = Set(dismissed)
    }

    private func save() {
        guard let url = url else { return }
        let stored = alerts.map { a -> StoredAlert in
            // Catalog / pattern colours have no components; they come back as the accent.
            let tint: [Double] = a.tint.usingColorSpace(.sRGB).map {
                [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent), Double($0.alphaComponent)] } ?? []
            return StoredAlert(id: a.id, kind: a.kind.rawValue, title: a.title, detail: a.detail, date: a.date, symbol: a.symbol,
                               tint: tint, url: a.url?.absoluteString, opens: a.opens?.rawValue, actionable: a.isActionable,
                               seen: seen.contains(a.id))
        }
        let snapshot = Saved(alerts: stored, dismissed: dismissed)
        saveQueue.async { Self.write(snapshot, to: url) }
    }

    nonisolated private static func write(_ saved: Saved, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(saved) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Screen

private enum AL {
    static let pad: CGFloat = Metrics.sidePad
    static let rowH: CGFloat = RowTier.standard.height
    static let rowGap: CGFloat = Metrics.rowGap
    static let sectionH: CGFloat = 18
    static let sectionGap: CGFloat = Space.m
    static let groupGap: CGFloat = Space.xxl
    /// Air under the list.
    static let bottom: CGFloat = Space.xl
    static let emptyH: CGFloat = 90
}

final class AlertsView: CardBase, CardContent {
    var cardWidth: CGFloat { Isle.lensWidth }
    /// A row was tapped: the controller opens `opens` or `url`.
    var onOpen: ((ZeraAlert) -> Void)?
    /// Zera speaks for the inbox.
    var say: ((String, ZeraMood) -> Void)?

    private enum Filter: Int, CaseIterable {
        case all, agents, prs, reminders, system
        var title: String {
            switch self {
            case .all: return "All"
            case .agents: return "Agents"
            case .prs: return "PRs"
            case .reminders: return "Reminders"
            case .system: return "System"
            }
        }
        func includes(_ k: ZeraAlert.Kind) -> Bool {
            switch self {
            case .all: return true
            case .agents: return k == .agent
            case .prs: return k == .pullRequest
            case .reminders: return k == .reminder || k == .meeting || k == .hydration
            case .system: return k == .battery || k == .system
            }
        }
    }

    private var center: AlertCenter { AlertCenter.shared }
    private var filter: Filter = .all
    private let chips = ChoiceChips(items: Filter.allCases.map { .init(title: $0.title) })
    private var clearButton: CardButton!
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let needsHeader = SectionHeader("Needs you")
    private let earlierHeader = SectionHeader("Earlier")
    private let empty = NSTextField(labelWithString: "All quiet. Nothing needs you.")
    private var needsRows: [AlertRow] = []
    private var earlierRows: [AlertRow] = []
    /// While `willShow` refreshes the inbox itself, its `changed` posts are not reloaded twice.
    private var reloading = false

    init() {
        super.init(width: Isle.lensWidth, title: "Alerts")
        let p = Pal
        clearButton = CardButton("Clear all", style: .secondary, symbol: "xmark.circle", target: self, action: #selector(clearTapped))
        addSubview(clearButton)

        chips.selection = [0]
        chips.onChange = { [weak self] sel in
            guard let self = self else { return }
            self.filter = Filter(rawValue: sel.min() ?? 0) ?? .all
            self.reload()
        }
        chips.switches = { [weak self] in self.map { [$0.scroll] } ?? [] }
        addSubview(chips)

        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        // Layer-backed from the start, so a dismissed row takes its pixels with it.
        scroll.wantsLayer = true
        scroll.contentView.wantsLayer = true
        doc.wantsLayer = true
        scroll.documentView = doc
        addSubview(scroll)
        doc.addSubview(needsHeader)
        doc.addSubview(earlierHeader)

        empty.font = Typo.body
        empty.textColor = p.textTertiary
        empty.alignment = .center
        empty.isHidden = true
        addSubview(empty)

        NotificationCenter.default.addObserver(self, selector: #selector(centerChanged), name: AlertCenter.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Each time the island opens on Alerts: pull the sources, count everything as seen, top of the list.
    func willShow() {
        reloading = true
        center.refreshFromSources()
        center.markAllSeen()
        reloading = false
        reload()
        if !NotchNavigation.shared.remembersScreen { scroll.contentView.scroll(to: .zero) }
    }

    @objc private func centerChanged() {
        guard !reloading, window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        reload()
    }

    @objc private func clearTapped() {
        guard !center.alerts.isEmpty else { return }
        SoundService.shared.play(.button)
        center.clearAll()
        say?("inbox zero ✨", .happy)
    }

    // MARK: Data

    private func reload() {
        let all = center.alerts
        let shown = all.filter { filter.includes($0.kind) }
        let needs = shown.filter(\.isActionable)
        let earlier = shown.filter { !$0.isActionable }

        let n = center.needsYou, today = center.today
        if all.isEmpty {
            setSubtitle("All quiet")
        } else {
            let who = n == 0 ? "Nothing needs you" : "\(n) need\(n == 1 ? "s" : "") you"
            setSubtitle("\(who) · \(today) today")
        }
        clearButton.isEnabled = !all.isEmpty

        // Rows for alerts that haven't changed are kept and moved; the rest are rebuilt.
        var pool = Dictionary((needsRows + earlierRows).map { ($0.alert.id, $0) }, uniquingKeysWith: { a, _ in a })
        func rows(for list: [ZeraAlert]) -> [AlertRow] {
            list.map { a in
                if let r = pool.removeValue(forKey: a.id), r.alert == a {
                    r.refreshTime()
                    return r
                }
                let r = AlertRow(alert: a)
                r.onTap = { [weak self] in self?.open(a) }
                r.onDismiss = { [weak self] in self?.dismiss(a) }
                doc.addSubview(r)
                return r
            }
        }
        needsRows = rows(for: needs)
        earlierRows = rows(for: earlier)
        pool.values.forEach { $0.removeFromSuperview() }

        let isEmpty = shown.isEmpty
        empty.isHidden = !isEmpty
        scroll.isHidden = isEmpty
        needsHeader.isHidden = needs.isEmpty
        earlierHeader.isHidden = earlier.isEmpty

        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    private func open(_ a: ZeraAlert) {
        SoundService.shared.play(.tap)
        onOpen?(a)
    }

    private func dismiss(_ a: ZeraAlert) {
        center.dismiss(id: a.id)
        if center.alerts.isEmpty { say?("all quiet now 🌙", .cozy) }
    }

    // MARK: Layout

    private var listTop: CGFloat { headerBottom + Metrics.chip + Space.l }

    private var listContentHeight: CGFloat {
        if needsRows.isEmpty && earlierRows.isEmpty { return AL.emptyH }
        var h: CGFloat = 0
        for rows in [needsRows, earlierRows] where !rows.isEmpty {
            if h > 0 { h += AL.groupGap }
            h += AL.sectionH + AL.sectionGap + CGFloat(rows.count) * (AL.rowH + AL.rowGap) - AL.rowGap
        }
        return h
    }

    var desiredHeight: CGFloat {
        min(Isle.maxContentHeight, listTop + listContentHeight + AL.bottom)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, x = AL.pad, iw = w - AL.pad * 2
        let mid = headerTrailingRect.midY
        let bw = max(96, clearButton.fittedWidth), bh = Metrics.button
        clearButton.frame = NSRect(x: w - x - bw, y: mid - bh / 2, width: bw, height: bh)
        layoutHeader(trailingWidth: bw)

        chips.frame = NSRect(x: x, y: headerBottom, width: min(iw, chips.preferredWidth), height: Metrics.chip)

        let lh = max(0, desiredHeight - listTop - AL.bottom)
        scroll.frame = NSRect(x: x - 4, y: listTop, width: iw + 8, height: lh)
        // More below: the last row fades out instead of being cut.
        if listContentHeight > lh + 1 {
            let fade = (scroll.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
            fade.frame = scroll.bounds
            fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.locations = [0, NSNumber(value: Double((lh - 28) / max(1, lh))), 1]
            scroll.layer?.mask = fade
        } else {
            scroll.layer?.mask = nil
        }
        empty.frame = NSRect(x: x, y: listTop + (AL.emptyH - 20) / 2, width: iw, height: 20)

        var y: CGFloat = 0
        for (header, rows) in [(needsHeader, needsRows), (earlierHeader, earlierRows)] where !rows.isEmpty {
            if y > 0 { y += AL.groupGap }
            header.frame = NSRect(x: 6, y: y, width: iw - 4, height: AL.sectionH)
            y += AL.sectionH + AL.sectionGap
            for r in rows {
                r.frame = NSRect(x: 4, y: y, width: iw, height: AL.rowH)
                y += AL.rowH + AL.rowGap
            }
            y -= AL.rowGap
        }
        doc.frame = NSRect(x: 0, y: 0, width: iw + 8, height: max(y, scroll.frame.height))
    }
}

// MARK: - Row

/// One alert: icon tile, title, detail, how long ago on the right; ✕ takes the time's place
/// under the pointer. The whole row is the tap target. Everything is layer-backed: hover only
/// swaps the layer's colour, so nothing redraws.
final class AlertRow: NSView {
    let alert: ZeraAlert
    var onTap: (() -> Void)?
    var onDismiss: (() -> Void)?
    private let tile: IconTile
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let when = NSTextField(labelWithString: "")
    private var dismiss: IconButton!
    private var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            dismiss.isHidden = !hovered
            when.isHidden = hovered
            restyle()
        }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(alert a: ZeraAlert) {
        alert = a
        tile = IconTile(symbol: a.symbol, color: a.tint, size: RowTier.standard.tile, pointSize: 15)
        super.init(frame: .zero)
        let p = Pal
        roundLayer(Radius.l)
        addSubview(tile)
        title.stringValue = a.title
        title.font = a.isActionable ? Typo.rowTitleStrong : Typo.rowTitle
        title.textColor = p.text
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        detail.stringValue = a.detail
        detail.font = Typo.meta
        detail.textColor = p.textSecondary
        detail.lineBreakMode = .byTruncatingTail
        addSubview(detail)
        when.font = Typo.caption
        when.textColor = p.textTertiary
        when.alignment = .right
        addSubview(when)
        dismiss = IconButton(symbol: "xmark", label: "Dismiss", target: self, action: #selector(dismissTapped))
        dismiss.setLine("x")
        dismiss.isHidden = true
        addSubview(dismiss)
        refreshTime()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(a.title). \(a.detail)")
        toolTip = a.detail.isEmpty ? nil : a.detail
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// "2 min ago" is redone each time the list shows.
    func refreshTime() { when.stringValue = relativeTime(alert.date) }

    private func restyle() {
        let p = Pal
        layer?.backgroundColor = (hovered ? p.surfaceHover : p.surfaceRow).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.divider.cgColor
    }

    @objc private func dismissTapped() { onDismiss?() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, mid = (h / 2).rounded()
        let ts = RowTier.standard.tile
        tile.frame = NSRect(x: Space.m, y: mid - ts / 2, width: ts, height: ts)
        let db = Metrics.rowButton
        dismiss.frame = NSRect(x: w - Space.m - db, y: mid - db / 2, width: db, height: db)
        let tw: CGFloat = when.stringValue.isEmpty ? 0
            : min(120, ceil((when.stringValue as NSString).size(withAttributes: [.font: Typo.caption]).width) + 4)
        when.frame = NSRect(x: w - Space.m - tw, y: mid - 7, width: tw, height: 14)
        let right = w - Space.m - max(tw, db) - Space.m
        let textX = tile.frame.maxX + Space.m
        let textW = max(20, right - textX)
        if detail.stringValue.isEmpty {
            title.frame = NSRect(x: textX, y: mid - 9, width: textW, height: 18)
            detail.isHidden = true
        } else {
            title.frame = NSRect(x: textX, y: mid - 18, width: textW, height: 18)
            detail.frame = NSRect(x: textX, y: mid + 1, width: textW, height: 16)
            detail.isHidden = false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetHoverTracking()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
