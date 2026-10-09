import AppKit

// MARK: - Reminders & Calendar
//
//  ┌──────────────── Overview (main) ─────────────────┐  ┌────── Side panel (on demand) ──────┐
//  │ [📅] Reminders & Calendar    ╭bubble╮(Z) [+ Add ▾]│  │ [tile] Title          (Z)  [✕]     │
//  │      Your day, all in one place                  │  │        subtitle                    │
//  │ [☀ Today 5 | 📅 Upcoming 12 | ✓ Completed 3]     │  │  Event detail / Reminder detail /  │
//  │ (All)(•Google)(•Outlook)(•Apple)(•Custom)(•Rem.) │  │  Create Event / Create Reminder /  │
//  │ ┌ 9:00 AM │ [G] Standup        ● in 25m  ⋯ ┐     │  │  Hydration Reminder form           │
//  │ ┌ 11:00   │ [💧] Drink water   ● Due  ✓ ⋯ ┐     │  │                                    │
//  │ …                                                │  │                [Cancel] [Create]   │
//  │ (Z) Next up ✨ …                                  │  └────────────────────────────────────┘
//  └──────────────────────────────────────────────────┘
//
// The first screen is the overview only. Creating is always an explicit choice from
// "+ Add Event ▾" (Create Event · Create Reminder · Hydration Reminder); clicking an item opens
// its details. ✕ folds the side panel away again.

private enum RS {
    static let gap: CGFloat = 14
    static let pad: CGFloat = Metrics.sidePad
    static let mainWidth: CGFloat = Isle.lensWidth
    static let sideWidth: CGFloat = 480
    static let maxHeight: CGFloat = 820
    static let expandedHeight: CGFloat = 720
    static let tipH: CGFloat = 72
    static let rowGap: CGFloat = Metrics.rowGap
    /// Header (88) · tabs (34) · 10 · source chips (28) · 12, then the list.
    static let listTop: CGFloat = Isle.headerHeight + Metrics.segment + 10 + Metrics.chip + 12
}

/// Snooze choices shared by the list, the detail panel and the notification.
@MainActor
func snoozeItems(_ apply: @escaping (Date, String) -> Void) -> [DropdownItem] {
    let now = Date()
    let cal = Calendar.current
    let tomorrow9 = cal.date(bySettingHour: 9, minute: 0, second: 0,
                             of: cal.date(byAdding: .day, value: 1, to: now) ?? now) ?? now.addingTimeInterval(86400)
    let opts: [(String, Date, String, String)] = [
        ("15 minutes", now.addingTimeInterval(15 * 60), "15 min", "clock"),
        ("30 minutes", now.addingTimeInterval(30 * 60), "30 min", "clock"),
        ("1 hour", now.addingTimeInterval(3600), "an hour", "clock"),
        ("2 hours", now.addingTimeInterval(7200), "2 hours", "clock"),
        ("Tomorrow · " + ReminderFormat.time.string(from: tomorrow9), tomorrow9, "tomorrow", "sunrise")
    ]
    return opts.map { o in DropdownItem(title: o.0, symbol: o.3) { apply(o.1, o.2) } }
}

/// Bottom-of-list note from Zera, optionally with one action button.
private final class AgendaTip: NSView {
    var onAction: (() -> Void)?
    var onClose: (() -> Void)?
    private let title = rlabel(Typo.rowTitle, Pal.text)
    private let body = rlabel(Typo.body, Pal.textSecondary, lines: 2)
    private var action: PRActionButton?
    private var close: GHSquareButton!
    override var isFlipped: Bool { true }
    static let zeraRoom: CGFloat = 104

    override init(frame: NSRect) {
        super.init(frame: frame)
        close = GHSquareButton(symbol: "xmark", label: "Dismiss", target: self, action: #selector(closeTapped))
        addSubview(title); addSubview(body); addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, body b: String, action a: String?, closable: Bool) {
        title.stringValue = t
        body.stringValue = b
        close.isHidden = !closable
        if a == nil, let old = action { old.removeFromSuperview(); action = nil }
        if let a = a {
            if action == nil {
                let btn = PRActionButton(a, style: .primary, target: self, action: #selector(actionTapped))
                addSubview(btn)
                action = btn
            } else {
                action?.setTitleText(a)
            }
        }
        setAccessibilityLabel("\(t). \(b)")
        needsLayout = true
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func actionTapped() { onAction?() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        close.frame = NSRect(x: w - 12 - 28, y: 12, width: 28, height: 28)
        var right = close.isHidden ? w - 14 : close.frame.minX - 8
        if let a = action {
            let aw = a.fittedWidth
            a.frame = NSRect(x: right - aw, y: (h - 32) / 2, width: aw, height: 32)
            right = a.frame.minX - 10
        }
        let x = Self.zeraRoom
        title.frame = NSRect(x: x, y: 13, width: max(40, right - x), height: 19)
        body.frame = NSRect(x: x, y: 34, width: max(40, right - x), height: h - 34 - 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l + 2, yRadius: Radius.l + 2)
        NSGradient(starting: p.accentSoft.withAlphaComponent(p.isDark ? 0.55 : 0.6), ending: p.surfaceElevated)?.draw(in: path, angle: 0)
        p.accentBorder.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

final class RemindersView: NSView, CardContent {
    var onHeightChange: (() -> Void)?
    var onEscape: (() -> Void)?
    var say: ((String, ZeraMood) -> Void)?

    private enum Side {
        case none
        case item(refID: String, occurrence: Date)
        case completion(UUID)
        case eventForm(CalendarEvent?)
        case reminderForm(Reminder?)
        case hydration(Reminder?)
    }
    private var side: Side = .none
    /// Where a form goes back to (the item's details when editing).
    private var formReturn: Side = .none

    // Survive rebuilds (theme change).
    private static var tab = 0
    private static var filter: AgendaFilter = .all
    private static let calendarTipKey = "zera.reminders.calendarTipDismissed"

    private let main = GlassPanel()
    private let sidePanel = GlassPanel()

    // Main panel
    private let screenTile: ScreenIconTile = {
        let c = Pal.tileCalendar
        return ScreenIconTile(symbol: "calendar.badge.clock", top: c.blended(withFraction: 0.12, of: .white) ?? c,
                              bottom: c.blended(withFraction: 0.25, of: .black) ?? c)
    }()
    private let titleLabel = rlabel(Typo.screenTitle, Pal.text)
    private let subtitleLabel = rlabel(Typo.screenSubtitle, Pal.textSecondary)
    private let peek = NSImageView()
    private let bubble = ZeraGitHubBubble()
    private let addButton = GHSplitButton(title: "Add Event", symbol: "plus")
    private let tabs = GitHubSegmentedControl(items: [])
    private let filters = ChoiceChips(items: [])
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var entries: [(view: NSView, height: CGFloat)] = []
    private let emptyState = GHStateView()
    private var emptyKey = ""
    private let tip = AgendaTip()
    private let tipZera = NSImageView()
    private var tipAction: (() -> Void)?

    // Side panel
    private var back: GHSquareButton!
    private var close: GHSquareButton!
    private let sideTile = AgendaTile()
    private let sideTitle = rlabel(Typo.detailTitle, Pal.text)
    private let sideSubtitle = rlabel(Typo.meta, Pal.textSecondary)
    private let sideZera = NSImageView()
    private var form: ReminderFormBase?
    private let detailScroll = NSScrollView()
    private let detailList = FlippedView()
    private var detailRows: [NSView] = []
    private var detailButtons: [[PRActionButton]] = []
    private let detailChip = PRStatusChip()
    private let detailNext = rlabel(Typo.control, Pal.textSecondary)
    private let dots = SeriesDots()
    private let dotsLabel = rlabel(Typo.control, Pal.textSecondary)

    private var ticker: Timer?
    private var svc: ReminderService { ReminderService.shared }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Size

    private var screen: NSRect { (window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875) }
    private var expanded: Bool { if case .none = side { return false }; return true }
    /// Not wide enough for both panels: the side panel replaces the overview (with a back button).
    /// In the island the details (or a form) replace the overview, with a back button.
    private var singlePane: Bool { true }
    private var mainWidth: CGFloat { min(Isle.lensWidth, screen.width - 40) }

    var cardWidth: CGFloat { mainWidth }
    var desiredHeight: CGFloat {
        if expanded { return Isle.maxContentHeight }
        let listH = entries.isEmpty ? 150 : min(4 * (AgendaRow.height + RS.rowGap), entries.reduce(0) { $0 + $1.height + RS.rowGap })
        return RS.listTop + listH + 12
    }

    /// Set just before opening to land on one reminder's or event's details (from the banner):
    /// a reminder's UUID string or an event id, and the occurrence the banner was about.
    var focusOnShow: (refID: String, occurrence: Date?)?

    /// Each time the screen opens: the overview on its own (or the reminder asked for).
    func willShow() {
        ZeraDropdown.shared.dismiss()
        // A form is work in progress; list filters are temporary navigation.
        if form != nil, focusOnShow == nil { reload(); return }
        Self.tab = 0
        Self.filter = .all
        side = .none
        formReturn = .none
        form?.removeFromSuperview()
        form = nil
        if let f = focusOnShow {
            if let id = UUID(uuidString: f.refID), let r = svc.reminder(id) {
                side = .item(refID: r.id.uuidString, occurrence: f.occurrence ?? svc.currentOccurrence(of: r))
            } else if let e = svc.event(f.refID) {
                side = .item(refID: f.refID, occurrence: f.occurrence ?? e.startAt)
            }
        }
        focusOnShow = nil
        reload()
        scroll.contentView.scroll(to: .zero)
    }

    // MARK: Init

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: RS.mainWidth, height: 600))
        addSubview(main)
        addSubview(sidePanel)

        main.addSubview(screenTile)
        titleLabel.stringValue = "Reminders"
        main.addSubview(titleLabel)
        subtitleLabel.stringValue = "Your day, all in one place"
        main.addSubview(subtitleLabel)
        peek.imageScaling = .scaleProportionallyUpOrDown
        peek.imageAlignment = .alignBottom
        peek.image = SpriteLibrary.shared.sprite("card_peek_down")?.image ?? SpriteLibrary.shared.sprite("peek")?.image
        main.addSubview(peek)
        bubble.tailRight = true
        main.addSubview(bubble)
        addButton.onMain = { [weak self] in self?.formReturn = .none; self?.openForm(.eventForm(nil)) }
        addButton.onMenu = { [weak self] v in self?.showAddMenu(from: v) }
        addButton.toolTip = "Create an event — or pick a reminder from ▾"
        main.addSubview(addButton)

        tabs.chipStyle = true
        tabs.onSelect = { [weak self] i in Self.tab = i; self?.reload() }
        tabs.switches = { [weak self] in self.map { [$0.scroll] } ?? [] }
        filters.switches = { [weak self] in self.map { [$0.scroll] } ?? [] }
        main.addSubview(tabs)
        filters.items = AgendaFilter.allCases.map { f in
            switch f {
            case .all: return ChoiceChips.Item(title: f.title)
            case .google: return ChoiceChips.Item(title: f.title, dot: AgendaLook.source(.google).tint)
            case .outlook: return ChoiceChips.Item(title: f.title, dot: AgendaLook.source(.outlook).tint)
            case .apple: return ChoiceChips.Item(title: f.title, dot: AgendaLook.source(.apple).tint)
            case .custom: return ChoiceChips.Item(title: f.title, dot: AgendaLook.source(.custom).tint)
            case .reminders: return ChoiceChips.Item(title: f.title, dot: AgendaLook.reminder.tint)
            }
        }
        filters.selection = [Self.filter.rawValue]
        filters.onChange = { [weak self] s in
            Self.filter = AgendaFilter(rawValue: s.min() ?? 0) ?? .all
            self?.reload()
        }
        main.addSubview(filters)

        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = list
        main.addSubview(scroll)
        main.addSubview(emptyState)
        tip.onAction = { [weak self] in self?.tipAction?() }
        tip.onClose = { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.calendarTipKey)
            self?.reload()
        }
        main.addSubview(tip)
        tipZera.imageScaling = .scaleProportionallyUpOrDown
        tipZera.imageAlignment = .alignBottom
        main.addSubview(tipZera)

        // Side panel.
        back = GHSquareButton(symbol: "chevron.left", label: "Back to overview", target: self, action: #selector(closeSide))
        close = GHSquareButton(symbol: "xmark", label: "Close", target: self, action: #selector(closeSide))
        sidePanel.addSubview(back)
        sidePanel.addSubview(close)
        sidePanel.addSubview(sideTile)
        sidePanel.addSubview(sideTitle)
        sidePanel.addSubview(sideSubtitle)
        sideZera.imageScaling = .scaleProportionallyUpOrDown
        sideZera.imageAlignment = .alignBottom
        sidePanel.addSubview(sideZera)
        detailScroll.hasVerticalScroller = false
        detailScroll.borderType = .noBorder
        detailScroll.drawsBackground = false
        detailScroll.contentView.drawsBackground = false
        detailScroll.documentView = detailList
        sidePanel.addSubview(detailScroll)
        detailList.addSubview(detailChip)
        detailList.addSubview(detailNext)
        detailList.addSubview(dots)
        detailList.addSubview(dotsLabel)

        NotificationCenter.default.addObserver(self, selector: #selector(reloadIfVisible), name: ReminderService.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        NotificationCenter.default.removeObserver(self)
        ticker?.invalidate()
    }

    // Countdowns and due / overdue states move with the clock while the screen is up.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker?.invalidate(); ticker = nil
        guard window != nil else { ZeraDropdown.shared.dismiss(); return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfVisible() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if expanded { closeSide() } else { onEscape?() }
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Public entry points

    /// Opens straight to one reminder's details (from the notification).
    func show(reminderID: UUID) {
        guard let r = svc.reminder(reminderID) else { return }
        setSide(.item(refID: r.id.uuidString, occurrence: svc.currentOccurrence(of: r)))
    }

    // MARK: Data

    @objc private func reloadIfVisible() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        reload()
    }

    private func filtered(_ items: [AgendaItem]) -> [AgendaItem] { items.filter { Self.filter.matches($0) } }

    @objc func reload() {
        let p = Pal
        let now = Date()
        let today = filtered(svc.today(now: now))
        let upcoming = svc.upcoming(days: 14, now: now).compactMap { g -> (day: Date, items: [AgendaItem])? in
            let f = filtered(g.items)
            return f.isEmpty ? nil : (day: g.day, items: f)
        }
        let completed = svc.visibleCompletions.filter { e in
            switch Self.filter {
            case .all: return true
            case .reminders: return e.itemKind == .reminder
            case .google: return e.source == .google
            case .outlook: return e.source == .outlook
            case .apple: return e.source == .apple
            case .custom: return e.itemKind == .event && e.source == .custom
            }
        }
        let openToday = today.filter { let s = svc.state(of: $0, now: now); return s != .ended && s != .doneForToday }
        tabs.items = [
            .init(symbol: "sun.max.fill", title: "Today", count: openToday.count, tint: p.warning, badgeTint: nil, showsZero: true),
            .init(symbol: "calendar", title: "Upcoming", count: upcoming.reduce(0) { $0 + $1.items.count }, tint: p.info, badgeTint: nil, showsZero: true),
            .init(symbol: "checkmark.circle.fill", title: "Completed", count: completed.count, tint: p.success, badgeTint: nil, showsZero: true)
        ]
        tabs.selected = Self.tab
        filters.selection = [Self.filter.rawValue]

        // Header bubble.
        let due = today.filter { [.due, .overdue].contains(svc.state(of: $0, now: now)) }
        if let d = due.first(where: { $0.reminder?.isHydration == true }) { bubble.text = "\(d.title) 💧" }
        else if !due.isEmpty { bubble.text = "\(due.count) need\(due.count == 1 ? "s" : "") you 🔔" }
        else if openToday.isEmpty { bubble.text = "All clear today ✨" }
        else { bubble.text = "\(openToday.count) thing\(openToday.count == 1 ? "" : "s") today ✨" }

        rebuildList(today: today, upcoming: upcoming, completed: completed, now: now)
        updateTip(today: openToday, now: now)
        reloadSide()
        needsLayout = true
        if !expanded { onHeightChange?() }
    }

    private var selectedKey: String? {
        switch side {
        case .item(let ref, let occ): return "\(ref)@\(Int(occ.timeIntervalSince1970))"
        case .completion(let id): return id.uuidString
        default: return nil
        }
    }

    private func rebuildList(today: [AgendaItem], upcoming: [(day: Date, items: [AgendaItem])], completed: [CompletionEntry], now: Date) {
        entries.forEach { $0.view.removeFromSuperview() }
        entries = []
        let sel = selectedKey
        func row(_ item: AgendaItem) -> AgendaRow {
            let r = AgendaRow()
            r.configure(item, state: svc.state(of: item, now: now), now: now)
            r.selected = item.id == sel
            let ref = item.refID, occ = item.occurrence
            r.onSelect = { [weak self] in self?.setSide(.item(refID: ref, occurrence: occ)) }
            r.onCheck = { [weak self] in self?.complete(item) }
            r.onJoin = { [weak self] in if let u = item.event?.joinURL { self?.openURL(u) } }
            r.onMenu = { [weak self] v in self?.showMenu(for: item, from: v) }
            return r
        }
        switch Self.tab {
        case 0:
            for item in today { entries.append((view: row(item) as NSView, height: AgendaRow.height)) }
        case 1:
            for g in upcoming {
                entries.append((view: DayHeader(day: g.day, items: g.items.count) as NSView, height: DayHeader.height))
                for item in g.items { entries.append((view: row(item) as NSView, height: AgendaRow.height)) }
            }
        default:
            for e in completed.prefix(150) {
                let r = AgendaRow()
                r.configure(completion: e, now: now)
                r.selected = e.id.uuidString == sel
                let id = e.id
                r.onSelect = { [weak self] in self?.setSide(.completion(id)) }
                r.onRestore = { [weak self] in self?.restore(e) }
                r.onDelete = { [weak self] in self?.deleteCompletion(e) }
                entries.append((view: r as NSView, height: AgendaRow.height))
            }
        }
        entries.forEach { list.addSubview($0.view) }

        emptyState.isHidden = !entries.isEmpty
        let key = "\(Self.tab)|\(Self.filter.rawValue)|\(svc.calendarAuthorized)"
        if entries.isEmpty, key != emptyKey {
            emptyKey = key
            let filteredNote = Self.filter == .all ? "" : " for \(Self.filter.title)"
            switch Self.tab {
            case 0:
                emptyState.set(pose: "card_thumbs_wink", title: "Nothing left today\(filteredNote)",
                               subtitle: "Add an event or a reminder with + Add Event.")
            case 1:
                emptyState.set(pose: "card_read_q", title: "Nothing coming up\(filteredNote)",
                               subtitle: svc.calendarAuthorized ? "The next two weeks are clear." : "Connect Calendar to see your Google, Outlook and Apple events.")
            default:
                emptyState.set(pose: "checklist", title: "Nothing completed yet\(filteredNote)",
                               subtitle: "Things you mark as done show up here — restore them any time.")
            }
        } else if !entries.isEmpty {
            emptyKey = ""
        }
    }

    private func updateTip(today: [AgendaItem], now: Date) {
        tipAction = nil
        var pose = "card_point_sparkle"
        if !svc.calendarAuthorized, !UserDefaults.standard.bool(forKey: Self.calendarTipKey) {
            tip.set(title: "See your real calendars 📅",
                    body: "Connect macOS Calendar and Google, Outlook and Apple events show up here — read on your Mac only.",
                    action: "Connect", closable: true)
            tipAction = { [weak self] in self?.connectCalendar() }
            pose = "card_greet"
        } else if let water = today.first(where: { $0.reminder?.isHydration == true && [.due, .overdue].contains(svc.state(of: $0, now: now)) }) {
            tip.set(title: "Time to hydrate 💧", body: "\(water.title) — \(water.seriesDone) of \(water.seriesTotal) done today. Mark it when you've had a glass.",
                    action: "Done", closable: false)
            tipAction = { [weak self] in self?.complete(water) }
            pose = "boba"
        } else if let next = today.first(where: { svc.state(of: $0, now: now) == .upcoming || svc.state(of: $0, now: now) == .inProgress }) {
            let st = svc.state(of: next, now: now)
            let when = st == .inProgress ? "happening now" : ReminderFormat.time.string(from: next.occurrence) + " · " + ReminderFormat.countdown(to: next.occurrence, now: now)
            let isMeeting = next.event?.kind == .meeting
            tip.set(title: "Next up ✨", body: "\(next.title) — \(when)." + (isMeeting ? " I'll warn you before it starts." : ""),
                    action: nil, closable: false)
            pose = isMeeting ? "card_bell" : "card_point_sparkle"
        } else if today.isEmpty {
            tip.set(title: "All done for today 🎉", body: "Nothing else on your plate. Enjoy it!", action: nil, closable: false)
            pose = "celebrate"
        } else {
            tip.set(title: "Zera's tip ✨", body: "Tap anything to see details, snooze it or mark it done.", action: nil, closable: false)
        }
        tipZera.image = SpriteLibrary.shared.sprite(pose)?.image ?? SpriteLibrary.shared.sprite("idle")?.image
    }

    // MARK: Side panel

    private func setSide(_ s: Side) {
        ZeraDropdown.shared.dismiss()
        let wasExpanded = expanded
        if case .eventForm = s {} else if case .reminderForm = s {} else if case .hydration = s {} else {
            form?.removeFromSuperview()
            form = nil
        }
        side = s
        reload()
        if wasExpanded != expanded || singlePane {
            layoutSubtreeIfNeeded()
            onHeightChange?()
        }
        // Opening an item (or a form) slides it in like a page; closing slides the list back.
        if wasExpanded != expanded { Motion.open(expanded ? sidePanel : main, forward: expanded) }
        // Already open on something else: the new item pages in over it.
        else if expanded, window != nil { Motion.page(sidePanel, forward: true) }
    }

    @objc private func closeSide() {
        if form != nil, case .item = formReturn {
            let ret = formReturn
            formReturn = .none
            form?.removeFromSuperview(); form = nil
            setSide(ret)
            return
        }
        formReturn = .none
        form?.removeFromSuperview(); form = nil
        setSide(.none)
    }

    private func openForm(_ s: Side) {
        form?.removeFromSuperview()
        let f: ReminderFormBase
        switch s {
        case .eventForm(let e): f = EventFormView(editing: e)
        case .reminderForm(let r): f = ReminderFormView(editing: r)
        case .hydration(let r): f = HydrationFormView(editing: r)
        default: return
        }
        f.say = { [weak self] line, mood in self?.say?(line, mood) }
        f.onCancel = { [weak self] in self?.closeSide() }
        f.onDone = { [weak self] in self?.closeSide() }
        form = f
        sidePanel.addSubview(f)
        setSide(s)
    }

    private func showAddMenu(from v: NSView) {
        ZeraDropdown.shared.show([
            DropdownItem(title: "Event", subtitle: "Meeting, focus block or plan", symbol: "calendar.badge.plus", tint: AgendaLook.source(.custom).tint) { [weak self] in
                self?.formReturn = .none; self?.openForm(.eventForm(nil))
            },
            DropdownItem(title: "Reminder", subtitle: "A nudge — once or repeating", symbol: "bell.fill", tint: AgendaLook.reminder.tint) { [weak self] in
                self?.formReturn = .none; self?.openForm(.reminderForm(nil))
            },
            DropdownItem(title: "Hydration", subtitle: "Drink water through the day", symbol: "drop.fill", tint: AgendaLook.hydration.tint) { [weak self] in
                self?.formReturn = .none; self?.openForm(.hydration(nil))
            }
        ], below: v, width: 270)
    }

    /// The agenda item a detail panel is about, re-read from the service (it may have changed).
    private func resolve(refID: String, occurrence: Date) -> AgendaItem? {
        if let uuid = UUID(uuidString: refID), let r = svc.reminder(uuid) {
            let valid = !r.occurrences(from: occurrence.addingTimeInterval(-1), to: occurrence.addingTimeInterval(1), limit: 1).isEmpty
                || (!r.rule.isRepeating && abs(r.scheduledAt.timeIntervalSince(occurrence)) < 1)
            var item = AgendaItem(kind: .reminder(r), occurrence: valid ? occurrence : svc.currentOccurrence(of: r))
            if r.rule.isInterval {
                let cal = Calendar.current
                let start = cal.startOfDay(for: item.occurrence)
                let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
                let occs = r.occurrences(from: start, to: end, limit: 1500)
                item.seriesTotal = occs.count
                item.seriesDone = occs.filter { r.isDone($0) }.count
                item.seriesRemaining = occs.filter { $0 > Date() }.count
            }
            return item
        }
        if let e = svc.event(refID) {
            var occ = occurrence
            if e.occurrences(from: occurrence.addingTimeInterval(-1), to: occurrence.addingTimeInterval(1), limit: 1).isEmpty {
                occ = e.occurrences(from: Calendar.current.startOfDay(for: Date()), to: Date().addingTimeInterval(400 * 86400), limit: 1).first ?? e.startAt
            }
            return AgendaItem(kind: .event(e), occurrence: occ)
        }
        return nil
    }

    private func clearDetail() {
        detailRows.forEach { $0.removeFromSuperview() }
        detailRows = []
        detailButtons.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        detailButtons = []
    }

    private func reloadSide() {
        let showingForm = form != nil
        detailScroll.isHidden = showingForm
        form?.isHidden = !showingForm
        switch side {
        case .none:
            clearDetail()
        case .eventForm, .reminderForm, .hydration:
            clearDetail()
            if let f = form {
                sideTile.look = f.headerLook
                sideTitle.stringValue = f.headerTitle
                sideSubtitle.stringValue = f.headerSubtitle
                setZera(f.zeraPose)
            }
        case .item(let ref, let occ):
            guard let item = resolve(refID: ref, occurrence: occ) else { side = .none; clearDetail(); return }
            buildDetail(item)
        case .completion(let id):
            guard let e = svc.completions.first(where: { $0.id == id }) else { side = .none; clearDetail(); return }
            buildDetail(completion: e)
        }
        sideTile.dimmed = false
        needsLayout = true
    }

    private func setZera(_ pose: String) {
        sideZera.image = SpriteLibrary.shared.sprite(pose)?.image ?? SpriteLibrary.shared.sprite("idle")?.image
    }

    private func info(_ symbol: String, _ label: String, _ value: String, tint: NSColor? = nil) {
        guard !value.isEmpty else { return }
        let r = DetailInfoRow(symbol: symbol, tint: tint, label: label, value: value)
        detailList.addSubview(r)
        detailRows.append(r)
    }

    private func button(_ title: String, _ style: PRActionButton.Style, _ symbol: String?, _ handler: @escaping () -> Void) -> ClosureActionButton {
        let b = ClosureActionButton(title, style: style, symbol: symbol, handler: handler)
        sidePanel.addSubview(b)
        return b
    }

    private func buildDetail(_ item: AgendaItem) {
        clearDetail()
        let p = Pal
        let now = Date()
        let st = svc.state(of: item, now: now)
        let c = st.chip(for: item, now: now)
        detailChip.set(symbol: c.symbol, text: c.text, color: c.color)
        let look = AgendaLook.of(item)
        sideTile.look = look
        sideTitle.stringValue = item.title
        dots.isHidden = true
        dotsLabel.isHidden = true

        if let r = item.reminder {
            sideSubtitle.stringValue = (r.isHydration ? "Hydration reminder" : "Reminder") + " · " + r.rule.title
            let next = r.next(after: now)
            switch st {
            case .due, .overdue: detailNext.stringValue = "Was due " + ReminderFormat.countdown(to: item.occurrence, now: now)
            case .snoozed: detailNext.stringValue = "Back " + (r.snoozedUntil.map { ReminderFormat.countdown(to: $0, now: now) } ?? "soon")
            case .disabled: detailNext.stringValue = "Turned off — Zera won't remind you"
            default: detailNext.stringValue = next.map { "Next " + ReminderFormat.relativeDay($0, now: now).lowercased() + " at " + ReminderFormat.time.string(from: $0) } ?? ""
            }
            if r.rule.isInterval, item.seriesTotal > 0 {
                dots.isHidden = false
                dotsLabel.isHidden = false
                dots.tint = look.tint
                dots.total = item.seriesTotal
                dots.done = item.seriesDone
                dotsLabel.stringValue = "TODAY · \(item.seriesDone) OF \(item.seriesTotal) DONE"
            }
            info("calendar.badge.clock", "Schedule", r.scheduleText, tint: look.tint)
            if r.hasActiveHours { info("sun.horizon.fill", "Active hours", r.activeHoursText, tint: p.warning) }
            info("clock", r.rule.isRepeating ? "Started" : "When", ReminderFormat.fullDate.string(from: r.scheduledAt), tint: p.info)
            if let end = r.rule.endDate { info("flag.checkered", "Ends", ReminderFormat.longDate.string(from: end), tint: p.muted) }
            info("text.alignleft", "Notes", r.notes, tint: p.textSecondary)
            info("lock.fill", "Privacy", "Kept on this Mac. Never sent to Claude.", tint: p.success)
            setZera(r.isHydration ? "boba" : (st == .overdue ? "worried" : (st == .due ? "card_bell" : (st == .disabled ? "sleepy" : "card_point_sparkle"))))

            let id = r.id, occ = item.occurrence
            var row1: [PRActionButton] = []
            if st == .disabled {
                row1.append(button("Turn on", .primary, "play.fill") { [weak self] in self?.svc.setEnabled(id, true); self?.say?("back on 🔔", .happy) })
            } else if st != .doneForToday {
                row1.append(button("Mark as done", .success, "checkmark") { [weak self] in self?.complete(item) })
                let snooze = button("Snooze", .secondary, "moon.zzz.fill") {}
                snooze.handler = { [weak self, weak snooze] in
                    guard let self = self, let s = snooze else { return }
                    ZeraDropdown.shared.show(snoozeItems { until, label in
                        self.svc.snooze(reminder: id, occurrence: occ, until: until)
                        self.say?("okay — I'll remind you in \(label) 😴", .sleepy)
                    }, below: s)
                }
                row1.append(snooze)
            }
            var row2: [PRActionButton] = []
            row2.append(button("Edit", .secondary, "pencil") { [weak self] in
                guard let self = self else { return }
                self.formReturn = self.side
                self.openForm(r.isHydration ? .hydration(r) : .reminderForm(r))
            })
            if st != .disabled {
                row2.append(button("Turn off", .secondary, "pause.fill") { [weak self] in self?.svc.setEnabled(id, false); self?.say?("turned off", .idle) })
            }
            row2.append(button("Delete", .destructive, "trash") { [weak self] in
                self?.svc.deleteReminder(id)
                self?.say?("reminder deleted", .idle)
                self?.closeSide()
            })
            detailButtons = [row1, row2].filter { !$0.isEmpty }
        } else if let e = item.event {
            sideSubtitle.stringValue = e.source.longTitle + (e.isExternal ? " · " + e.calendarName : "") + " · " + e.kind.title
            switch st {
            case .inProgress: detailNext.stringValue = "Happening now · ends " + (item.end.map { ReminderFormat.time.string(from: $0) } ?? "")
            case .ended: detailNext.stringValue = "Ended"
            case .completed: detailNext.stringValue = "Marked complete"
            default: detailNext.stringValue = "Starts " + ReminderFormat.countdown(to: item.occurrence, now: now)
            }
            let day = ReminderFormat.relativeDay(item.occurrence, now: now)
            let when: String
            if e.isAllDay { when = day + " · all day" }
            else {
                let end = item.end ?? item.occurrence
                when = day + " · " + ReminderFormat.time.string(from: item.occurrence) + " – " + ReminderFormat.time.string(from: end)
                    + " (" + ReminderFormat.duration(e.duration) + ")"
            }
            info("clock", "When", when, tint: look.tint)
            if e.rule.isRepeating { info("repeat", "Repeats", e.rule.title, tint: p.accent) }
            info("calendar", "Calendar", e.isExternal ? e.source.longTitle + " · " + e.calendarName : "Zera — kept on this Mac", tint: look.tint)
            info("mappin.and.ellipse", "Location", e.location, tint: p.danger)
            var alert = ""
            if !e.isAllDay {
                let m = e.alertMinutes
                if m < 0 { alert = "None" }
                else if m == 0 { alert = "At the start" }
                else {
                    let lead = (m >= 60 && m % 60 == 0) ? "\(m / 60) h" : "\(m) min"
                    alert = lead + " before, and as it starts"
                }
            }
            info("bell", "Zera reminds you", alert, tint: p.warning)
            info("text.alignleft", "Description", e.notes, tint: p.textSecondary)
            setZera(st == .inProgress ? "card_notify" : (e.kind == .meeting ? "card_bell" : "card_point_sparkle"))

            let id = e.id, occ = item.occurrence
            var row1: [PRActionButton] = []
            if let u = e.joinURL, st != .ended, st != .completed {
                row1.append(button("Join call", .primary, "video.fill") { [weak self] in self?.openURL(u) })
            }
            if st != .completed {
                row1.append(button("Mark complete", row1.isEmpty ? .primary : .secondary, "checkmark") { [weak self] in
                    self?.svc.markEventComplete(id, occurrence: occ)
                    self?.say?("done ✅", .happy)
                    self?.closeSide()
                })
            }
            var row2: [PRActionButton] = []
            if e.isExternal {
                row2.append(button("Open Calendar", .secondary, "calendar") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                })
            } else {
                row2.append(button("Edit", .secondary, "pencil") { [weak self] in
                    guard let self = self else { return }
                    self.formReturn = self.side
                    self.openForm(.eventForm(e))
                })
                row2.append(button("Delete", .destructive, "trash") { [weak self] in
                    self?.svc.deleteEvent(id)
                    self?.say?("event deleted", .idle)
                    self?.closeSide()
                })
            }
            detailButtons = [row1, row2].filter { !$0.isEmpty }
        }
    }

    private func buildDetail(completion e: CompletionEntry) {
        clearDetail()
        let p = Pal
        let look = AgendaLook.of(e)
        sideTile.look = look
        sideTitle.stringValue = e.title
        sideSubtitle.stringValue = "Completed · " + look.label
        detailChip.set(symbol: "checkmark.circle.fill", text: "Done", color: p.success)
        detailNext.stringValue = "Completed " + ReminderFormat.relativeDay(e.completedAt).lowercased() + " at " + ReminderFormat.time.string(from: e.completedAt)
        dots.isHidden = true
        dotsLabel.isHidden = true
        info("checkmark.circle.fill", "Completed", ReminderFormat.fullDate.string(from: e.completedAt), tint: p.success)
        info("clock", e.itemKind == .event ? "Was scheduled" : "Was due", ReminderFormat.fullDate.string(from: e.occurrence), tint: look.tint)
        info("tag.fill", "Type", look.label, tint: look.tint)
        setZera("celebrate")

        var row: [PRActionButton] = []
        row.append(button("Restore", .primary, "arrow.uturn.backward") { [weak self] in self?.restore(e) })
        let exists: Bool = e.itemKind == .reminder ? (UUID(uuidString: e.refID).flatMap { svc.reminder($0) } != nil) : (svc.event(e.refID) != nil)
        if exists {
            row.append(button("View", .secondary, "eye") { [weak self] in self?.setSide(.item(refID: e.refID, occurrence: e.occurrence)) })
        }
        row.append(button("Delete", .destructive, "trash") { [weak self] in self?.deleteCompletion(e) })
        detailButtons = [row]
    }

    // MARK: Actions

    private func complete(_ item: AgendaItem) {
        if let r = item.reminder {
            let occ = svc.state(of: item) == .upcoming && r.rule.isInterval ? svc.currentOccurrence(of: r) : item.occurrence
            svc.markDone(r.id, occurrence: occ)
            say?(r.isHydration ? "nice — stay hydrated 💧" : "done! ✨", r.isHydration ? .love : .happy)
        } else if let e = item.event {
            svc.markEventComplete(e.id, occurrence: item.occurrence)
            say?("done ✅", .happy)
        }
        if case .item(let ref, _) = side, ref == item.refID { closeSide() }
    }

    private func restore(_ e: CompletionEntry) {
        svc.restore(e)
        say?("restored ↩️", .happy)
        if case .completion(let id) = side, id == e.id { closeSide() }
    }

    private func deleteCompletion(_ e: CompletionEntry) {
        svc.deleteCompletion(e)
        say?("deleted", .idle)
        if case .completion(let id) = side, id == e.id { closeSide() }
    }

    private func openURL(_ u: URL) {
        NSWorkspace.shared.open(u)
    }

    private func connectCalendar() {
        Task { @MainActor [weak self] in
            await ReminderService.shared.connectCalendar()
            let ok = ReminderService.shared.calendarAuthorized
            self?.say?(ok ? "calendar connected — I'll warn you before meetings 📅" : "macOS didn't let me see your calendar 😬", ok ? .approved : .worried)
            self?.reload()
        }
    }

    private func showMenu(for item: AgendaItem, from v: NSView) {
        let st = svc.state(of: item)
        var items: [DropdownItem] = [
            DropdownItem(title: "Show details", symbol: "sidebar.right") { [weak self] in
                self?.setSide(.item(refID: item.refID, occurrence: item.occurrence))
            }
        ]
        if let r = item.reminder {
            let id = r.id, occ = item.occurrence
            if st != .disabled && st != .doneForToday {
                items.append(DropdownItem(title: "Mark as done", symbol: "checkmark") { [weak self] in self?.complete(item) })
                items.append(DropdownItem(title: "Snooze…", symbol: "moon.zzz") { [weak self, weak v] in
                    guard let v = v else { return }
                    ZeraDropdown.shared.show(snoozeItems { until, label in
                        self?.svc.snooze(reminder: id, occurrence: occ, until: until)
                        self?.say?("okay — I'll remind you in \(label) 😴", .sleepy)
                    }, below: v)
                })
            }
            items.append(.separator())
            items.append(DropdownItem(title: "Edit", symbol: "pencil") { [weak self] in
                self?.formReturn = .none
                self?.openForm(r.isHydration ? .hydration(r) : .reminderForm(r))
            })
            items.append(DropdownItem(title: st == .disabled ? "Turn on" : "Turn off", symbol: st == .disabled ? "play" : "pause") { [weak self] in
                self?.svc.setEnabled(id, st == .disabled)
            })
            items.append(DropdownItem(title: "Delete", symbol: "trash", destructive: true) { [weak self] in
                self?.svc.deleteReminder(id)
                self?.say?("reminder deleted", .idle)
            })
        } else if let e = item.event {
            let id = e.id, occ = item.occurrence
            if let u = e.joinURL { items.append(DropdownItem(title: "Join call", symbol: "video") { [weak self] in self?.openURL(u) }) }
            if st != .completed {
                items.append(DropdownItem(title: "Mark complete", symbol: "checkmark") { [weak self] in
                    self?.svc.markEventComplete(id, occurrence: occ); self?.say?("done ✅", .happy)
                })
            }
            items.append(.separator())
            if e.isExternal {
                items.append(DropdownItem(title: "Open Calendar", symbol: "calendar") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                })
            } else {
                items.append(DropdownItem(title: "Edit", symbol: "pencil") { [weak self] in self?.formReturn = .none; self?.openForm(.eventForm(e)) })
                items.append(DropdownItem(title: "Delete", symbol: "trash", destructive: true) { [weak self] in
                    self?.svc.deleteEvent(id); self?.say?("event deleted", .idle)
                })
            }
        }
        ZeraDropdown.shared.show(items, below: v, width: 200)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        if !expanded {
            main.isHidden = false
            sidePanel.isHidden = true
            main.frame = NSRect(x: 0, y: 0, width: w, height: h)
        } else if singlePane {
            main.isHidden = true
            sidePanel.isHidden = false
            sidePanel.frame = NSRect(x: 0, y: 0, width: w, height: h)
        } else {
            main.isHidden = false
            sidePanel.isHidden = false
            let mw = min(RS.mainWidth, w - RS.gap - 360)
            main.frame = NSRect(x: 0, y: 0, width: mw, height: h)
            sidePanel.frame = NSRect(x: mw + RS.gap, y: 0, width: w - mw - RS.gap, height: h)
        }
        if !main.isHidden { layoutMain(main.bounds.size) }
        if !sidePanel.isHidden { layoutSide(sidePanel.bounds.size) }
    }

    private func layoutMain(_ size: NSSize) {
        let w = size.width, h = size.height, x = RS.pad, iw = w - RS.pad * 2

        // Island header: title and summary left of Zera (she hangs in the middle); "+ Add ▾" on
        // the right. Her own pictures and the tip stay hidden in the island.
        [screenTile, peek, bubble, tip, tipZera].forEach { $0.isHidden = true }
        titleLabel.frame = ScreenHeader.titleFrame(width: w, padding: x)
        subtitleLabel.frame = ScreenHeader.subtitleFrame(width: w, padding: x)
        let bw = min(170, addButton.fittedWidth + 8)
        addButton.frame = NSRect(x: w - x - bw, y: ScreenHeader.controlY(Metrics.button), width: bw, height: Metrics.button)

        tabs.frame = NSRect(x: x, y: Isle.headerHeight, width: iw, height: Metrics.segment)
        filters.fill = filters.preferredWidth > iw
        filters.frame = NSRect(x: x, y: Isle.headerHeight + Metrics.segment + 10, width: filters.fill ? iw : filters.preferredWidth, height: Metrics.chip)

        let listBottom = h - 12
        let y = RS.listTop
        scroll.frame = NSRect(x: x - 6, y: y - 4, width: iw + 12, height: max(0, listBottom - y + 4))
        emptyState.frame = NSRect(x: x, y: y, width: iw, height: max(0, listBottom - y))
        var ry: CGFloat = 4
        for e in entries {
            e.view.frame = NSRect(x: 6, y: ry, width: iw, height: e.height)
            ry += e.height + RS.rowGap
        }
        list.frame = NSRect(x: 0, y: 0, width: iw + 12, height: max(ry, scroll.frame.height))
    }

    private func layoutSide(_ size: NSSize) {
        let w = size.width, h = size.height, x = RS.pad, iw = w - RS.pad * 2
        let single = singlePane
        back.isHidden = !single
        close.isHidden = single
        back.frame = NSRect(x: x, y: ScreenHeader.controlY(Metrics.headerButton), width: Metrics.headerButton, height: Metrics.headerButton)
        close.frame = NSRect(x: w - x - 34, y: ScreenHeader.controlY(Metrics.headerButton), width: Metrics.headerButton, height: Metrics.headerButton)
        // Island header: back · title / subtitle left of Zera (she hangs in the middle).
        sideTile.isHidden = true
        sideZera.isHidden = true
        sideTitle.frame = ScreenHeader.detailTitleFrame(width: w, padding: x)
        sideSubtitle.frame = ScreenHeader.detailSubtitleFrame(width: w, padding: x)

        let bodyTop: CGFloat = Isle.headerHeight
        if let f = form {
            f.frame = NSRect(x: x, y: bodyTop, width: iw, height: max(0, h - RS.pad - bodyTop))
            return
        }

        // Buttons pinned to the bottom, one row per group, equal widths.
        var by = h - 16
        for row in detailButtons.reversed() {
            by -= 32
            let n = CGFloat(row.count)
            let bw = (iw - (n - 1) * 8) / max(1, n)
            for (i, b) in row.enumerated() {
                b.frame = NSRect(x: x + CGFloat(i) * (bw + 8), y: by, width: bw, height: 32)
            }
            by -= 8
        }
        detailScroll.frame = NSRect(x: x, y: bodyTop, width: iw, height: max(0, by - 6 - bodyTop))

        var y: CGFloat = 4
        let cw = min(220, detailChip.fittedWidth)
        detailChip.frame = NSRect(x: 0, y: y, width: cw, height: 26)
        detailNext.frame = NSRect(x: cw + 12, y: y + 4, width: max(40, iw - cw - 12), height: 18)
        y += 26 + 16
        if !dots.isHidden {
            dotsLabel.frame = NSRect(x: 0, y: y, width: iw, height: 16)
            y += 20
            dots.frame = NSRect(x: 0, y: y, width: iw, height: 18)
            y += 18 + 16
        }
        for r in detailRows {
            let rh = (r as? DetailInfoRow)?.height(for: iw) ?? 44
            r.frame = NSRect(x: 0, y: y, width: iw, height: rh)
            y += rh + 6
        }
        detailList.frame = NSRect(x: 0, y: 0, width: iw, height: max(y, detailScroll.frame.height))
    }
}

/// PRActionButton that runs a closure (detail panel buttons are built per item).
final class ClosureActionButton: PRActionButton {
    var handler: () -> Void
    init(_ title: String, style: Style, symbol: String?, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title, style: style, symbol: symbol, target: nil, action: #selector(ClosureActionButton.fire))
        target = self
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
