import AppKit

/// Owns what Tasks puts on screen outside the notch: the orb on the screen edge, the focus card
/// it opens into, quick add (⌥⌘T) and the export window. The list itself is the notch's Tasks tab.
final class TasksController: NSObject, NSWindowDelegate {
    let store: TaskStore
    /// Something for Zera to say ("done ✨ Ship the menu in 24m").
    var onSay: ((String) -> Void)?
    /// Open the Tasks tab in the notch.
    var onShowList: (() -> Void)?
    /// The shortcut changed (the Tasks screen shows it).
    var onShortcutChanged: ((String?) -> Void)?

    private let orbPanel: FloatingPanel
    private let orbView: FocusOrbView
    private let cardPanel: FloatingPanel
    private let cardView: FocusCardView
    /// The card sits in an unflipped host, so it can grow out of the orb's point.
    private let cardHost = NSView()
    private var cardOpen = false
    private let plusPanel: FloatingPanel
    private let plusView = OrbPlusView()
    private var plusShown = false
    private var hoverOrb = false, hoverPlus = false
    private var orbShown = false
    private var doneCount = 0
    private let quickPanel: FloatingPanel
    private let quickView = QuickAddView()
    private let exportPanel: FloatingPanel
    private let exportView: TaskExportView
    private var hotKey: GlobalHotKey?
    private var syncTimer: Timer?

    init(store: TaskStore = .shared) {
        self.store = store
        let top = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        orbView = FocusOrbView(store: store)
        orbPanel = FloatingPanel.make(size: orbView.frame.size, level: .floating, keyable: false)
        cardView = FocusCardView(store: store)
        cardPanel = FloatingPanel.make(size: cardView.frame.size, level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1), keyable: true)
        plusPanel = FloatingPanel.make(size: NSSize(width: OrbPlusView.size, height: OrbPlusView.size), level: .floating, keyable: false)
        quickPanel = FloatingPanel.make(size: QuickAddView.size, level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1), keyable: true)
        exportView = TaskExportView(store: store)
        exportPanel = FloatingPanel.make(size: TaskExportView.size, level: top, keyable: true)
        super.init()
        cardHost.frame = NSRect(origin: .zero, size: cardView.frame.size)
        cardHost.wantsLayer = true
        cardHost.addSubview(cardView)
        orbView.wantsLayer = true
        plusView.wantsLayer = true
        for (p, v) in [(orbPanel, orbView as NSView), (cardPanel, cardHost), (plusPanel, plusView), (quickPanel, quickView), (exportPanel, exportView)] {
            p.contentView = v
            p.hasShadow = false
            p.appearance = NSAppearance(named: .darkAqua)
            p.delegate = self
        }
        wire()
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: TaskStore.changed, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(ticked), name: TaskStore.ticked, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.store.flush()
        }
        store.onIdlePause = { [weak self] t in self?.onSay?("paused “\(t.title)” while you were away ⏸") }
        doneCount = store.doneToday.count
        applySettings()
        registerHotKey()
        // Linked folders catch up at launch and every half hour (git is cheap; Claude only runs
        // when there are new commits).
        syncCommits(quiet: true)
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.syncCommits(quiet: true) }
        t.tolerance = 120
        RunLoop.main.add(t, forMode: .common)
        syncTimer = t
    }

    // MARK: Commits

    /// Picks a code folder for a project (a repo, or a folder of repos), adds it and reads its commits.
    func linkFolder(for project: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Link"
        panel.message = "Pick a repo, or a folder of repos, for “\(project)”. Your commits there become its done tasks."
        if let path = store.links[project]?.paths.last { panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent) }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] r in
            guard let self = self, r == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let repos = GitCommits.repos(in: url.path)
                DispatchQueue.main.async {
                    guard !repos.isEmpty else { self.onSay?("no git repos in that folder 🤔"); return }
                    // One repo: link the repo itself; a folder of repos: the folder (new repos in it count too).
                    self.store.link(project, to: repos.count == 1 ? repos[0] : url.path)
                    let what = repos.count == 1 ? (repos[0] as NSString).lastPathComponent : "\(repos.count) repos"
                    self.onSay?("linked \(what) to \(project) · reading this week's commits…")
                    self.syncCommits(project: project, quiet: false)
                }
            }
        }
    }

    /// Replaces a project's commit-made tasks from the last `days` days with a fresh read
    /// (Yesterday · Last 7 days · Last month, for a timesheet).
    func rebuildFromCommits(_ project: String, days: Int) {
        guard !TaskGitSync.shared.running.contains(project) else { onSay?("still reading \(project)'s commits…"); return }
        let span = days == 1 ? "yesterday's" : (days <= 7 ? "the last week of" : "a month of")
        onSay?("re-reading \(span) \(project) commits…")
        syncCommits(project: project, quiet: false, days: days)
    }

    /// Reads the last month of commits in linked folders. Not quiet: says what came in, even nothing.
    func syncCommits(project: String? = nil, quiet: Bool, days: Int? = nil, then: (() -> Void)? = nil) {
        guard !store.links.isEmpty else { then?(); return }
        exportView.syncing = true
        TaskGitSync.shared.sync(store, project: project, quiet: quiet, days: days) { [weak self] added, reading in
            guard let self = self else { return }
            self.exportView.syncing = !TaskGitSync.shared.running.isEmpty
            then?()
            let n = added.values.reduce(0, +)
            if n > 0 {
                let names = added.keys.sorted()
                let from = names.count == 1 ? names[0] : "\(names.count) projects"
                self.onSay?("added \(n) done task\(n == 1 ? "" : "s") from \(from)'s commits ✨")
            } else if !reading.isEmpty, !quiet {
                self.onSay?("still reading \(reading.joined(separator: ", "))'s commits… I'll say when it's in")
            } else if !quiet {
                self.onSay?("\(project ?? "your projects") \(project == nil ? "are" : "is") up to date ✨")
            }
        }
    }

    // MARK: Settings

    var shortcut: HotKeyShortcut? {
        get { ZeraController.storedShortcut("tasks.shortcut", default: TasksSettings.defaultShortcut) }
        set { ZeraController.store(newValue, "tasks.shortcut") }
    }

    @discardableResult
    func registerHotKey() -> Bool {
        hotKey = nil
        let label = shortcut?.label
        cardView.shortcutLabel = label
        onShortcutChanged?(label)
        orbView.toolTip = "Click to open · drag to move" + (label.map { " · \($0) adds a task" } ?? "")
        guard let s = shortcut else { return true }
        hotKey = GlobalHotKey(s) { [weak self] in self?.toggleQuickAdd() }
        return hotKey != nil
    }

    /// From the recorder in Settings: keep the old shortcut if the new one can't be used.
    func setShortcut(_ s: HotKeyShortcut?) -> Bool {
        let old = shortcut
        shortcut = s
        if registerHotKey() { return true }
        shortcut = old
        registerHotKey()
        return false
    }

    func pauseHotKey(_ paused: Bool) { if paused { hotKey = nil } else { registerHotKey() } }

    /// Puts the orb in line with Settings.
    func applySettings() {
        updateOrb()
    }

    // MARK: Updates

    @objc private func changed() {
        if cardOpen { cardView.reload(); placeCard() }
        if exportPanel.isVisible { exportView.refresh() }
        orbView.refresh()
        updateOrb()
        // Something got ticked off: the orb gives a little bounce.
        let done = store.doneToday.count
        if done > doneCount, orbShown, let l = orbView.layer { TaskMotion.bounce(l, about: CGPoint(x: l.bounds.midX, y: l.bounds.midY)) }
        doneCount = done
    }

    @objc private func ticked() {
        if cardOpen { cardView.tick() }
        if orbShown { orbView.tick() }
    }

    @objc private func screensChanged() { if orbShown { placeOrb() } }

    // MARK: The orb

    /// Shown while there are tasks (unless you hid it), and always while a timer runs: ▶ brings it up.
    private var orbWanted: Bool { (TasksSettings.orb && !store.today.isEmpty) || store.isRunning }

    private func updateOrb() {
        let show = orbWanted && !cardOpen
        if show, !orbShown { showOrb() } else if !show, orbShown { hideOrb() }
    }

    /// Pops in with a spring from its own middle.
    private func showOrb() {
        orbShown = true
        placeOrb()
        orbView.refresh()
        orbPanel.alphaValue = 1
        orbPanel.orderFrontRegardless()
        if let l = orbView.layer {
            TaskMotion.scale(l, about: CGPoint(x: l.bounds.midX, y: l.bounds.midY), from: 0.2, to: 1, opacity: 0, 1, spring: true)
        }
    }

    private func hideOrb(animated: Bool = true) {
        orbShown = false
        hidePlus()
        guard animated, let l = orbView.layer else { orbPanel.orderOut(nil); return }
        TaskMotion.scale(l, about: CGPoint(x: l.bounds.midX, y: l.bounds.midY), from: 1, to: 0.2, opacity: 1, 0, spring: false, duration: 0.16) { [weak self] in
            guard let self = self, !self.orbShown else { return }
            self.orbPanel.orderOut(nil)
            l.transform = CATransform3DIdentity
            l.opacity = 1
        }
    }

    // MARK: The + beside the orb

    /// Hovering the orb floats a + out on its inner side; it goes once the pointer leaves both.
    private func orbHover(_ on: Bool) {
        hoverOrb = on
        if on { showPlus() } else { schedulePlusHide() }
    }

    private func schedulePlusHide(after delay: TimeInterval = 0.4) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.pointerNearOrb else { return }
            self.hidePlus()
        }
    }

    /// Whether the pointer is over the orb or its + right now (hover events can go stale while
    /// windows come and go under it).
    private var pointerNearOrb: Bool {
        let m = NSEvent.mouseLocation
        return (orbShown && orbPanel.frame.contains(m)) || (plusShown && plusPanel.frame.contains(m))
    }

    /// Where the + sits: just inside the orb, level with its middle.
    private var plusFrame: NSRect {
        let orb = orbPanel.frame, s = OrbPlusView.size
        // The +'s middle sits 8 pt off the orb's edge plus its own radius.
        let om = (FocusOrbView.size - FocusOrbView.orb) / 2, gap: CGFloat = 8 + 17
        let cx = TasksSettings.orbOnLeft ? orb.maxX - om + gap : orb.minX + om - gap
        return NSRect(x: cx - s / 2, y: orb.midY - s / 2, width: s, height: s)
    }

    private func showPlus() {
        // Not while quick add (which the + opens) or the card is up.
        guard orbShown, !cardOpen, !plusShown, !quickPanel.isVisible else { return }
        plusShown = true
        let end = plusFrame
        // Slides out from behind the orb.
        let start = end.offsetBy(dx: TasksSettings.orbOnLeft ? -22 : 22, dy: 0)
        plusPanel.setFrame(start, display: true)
        plusPanel.alphaValue = 0
        plusPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(0.2)
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.3, 0.4, 1)
            plusPanel.animator().setFrame(end, display: true)
            plusPanel.animator().alphaValue = 1
        }
    }

    private func hidePlus() {
        guard plusShown else { return }
        plusShown = false
        let back = plusFrame.offsetBy(dx: TasksSettings.orbOnLeft ? -22 : 22, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(0.14)
            plusPanel.animator().setFrame(back, display: true)
            plusPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.plusShown else { return }
            self.plusPanel.orderOut(nil)
        })
    }

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    /// Where the orb sits: its edge and height, from Settings.
    private var orbFrame: NSRect {
        let vf = screen.visibleFrame, s = FocusOrbView.size
        let inset = 14 - (s - FocusOrbView.orb) / 2   // the orb's own edge ends 14 pt in from the screen edge
        let x = TasksSettings.orbOnLeft ? vf.minX + inset : vf.maxX - s - inset
        let y = vf.minY + 12 + TasksSettings.orbY * max(0, vf.height - s - 24)
        return NSRect(x: x, y: y, width: s, height: s)
    }

    private func placeOrb() { orbPanel.setFrame(orbFrame, display: true) }

    /// The orb's middle, inside the card's window (unflipped), for growing the card out of it.
    private var orbPointInCard: CGPoint {
        let o = orbFrame, c = cardPanel.frame
        return CGPoint(x: o.midX - c.minX, y: o.midY - c.minY)
    }

    /// Dropped after a drag: snap to the nearer side, remember the height.
    private func orbMoved() {
        let vf = screen.visibleFrame, f = orbPanel.frame
        TasksSettings.orbOnLeft = f.midX < vf.midX
        TasksSettings.orbY = max(0, min(1, (f.minY - vf.minY - 12) / max(1, vf.height - f.height - 24)))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(0.22)
            orbPanel.animator().setFrame(orbFrame, display: true)
        }
    }

    func toggleOrbSetting() {
        TasksSettings.orb.toggle()
        if !TasksSettings.orb { closeCard() }
        updateOrb()
        if TasksSettings.orb, store.today.isEmpty { onSay?("the orb shows up once you add a task") }
    }

    private func showOrbMenu(_ e: NSEvent) {
        hidePlus()
        var m: [NeonMenuItem] = [
            .action("Add a Task…" + (shortcut.map { "   \($0.label)" } ?? ""), "plus") { [weak self] in self?.showQuickAdd() },
            .action("All Tasks", "checklist") { [weak self] in self?.onShowList?() },
        ]
        if store.focus != nil {
            m.append(.action(store.isRunning ? "Pause" : "Resume", store.isRunning ? "pause.fill" : "play.fill") { [weak self] in self?.store.togglePause() })
        }
        if !store.links.isEmpty {
            m.append(.action("Sync Commits", "arrow.triangle.2.circlepath") { [weak self] in self?.syncCommits(quiet: false) })
        }
        m.append(.action("Export…", "square.and.arrow.up") { [weak self] in self?.openExport() })
        m.append(.separator)
        m.append(.action("Hide Focus Orb", "eye.slash") { [weak self] in self?.toggleOrbSetting() })
        NeonMenu.shared.show(m)
    }

    // MARK: The card

    /// The orb opens into the card: it grows out of the orb's middle with a spring.
    func openCard() {
        guard !cardOpen else { return }
        closeQuick()
        hidePlus()
        cardOpen = true
        cardView.reload()
        placeCard()
        orbShown = false
        orbPanel.orderOut(nil)
        cardPanel.alphaValue = 1
        cardPanel.makeKeyAndOrderFront(nil)
        cardPanel.makeFirstResponder(cardView)
        if let l = cardHost.layer {
            TaskMotion.scale(l, about: orbPointInCard, from: 0.12, to: 1, opacity: 0, 1, spring: true)
        }
        SoundService.shared.play(.islandOpen)
    }

    /// Folds back into the orb.
    func closeCard() {
        guard cardOpen else { return }
        cardOpen = false
        guard let l = cardHost.layer else { cardPanel.orderOut(nil); updateOrb(); return }
        TaskMotion.scale(l, about: orbPointInCard, from: 1, to: 0.12, opacity: 1, 0, spring: false, duration: 0.17) { [weak self] in
            guard let self = self, !self.cardOpen else { return }
            self.cardPanel.orderOut(nil)
            l.transform = CATransform3DIdentity
            l.opacity = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration(0.12)) { [weak self] in self?.updateOrb() }
    }

    /// The card opens where the orb floats: its outer edge on the orb's, centred on it.
    private func placeCard() {
        let vf = screen.visibleFrame, orb = orbFrame
        let size = NSSize(width: cardView.frame.width, height: cardView.desiredHeight)
        let m = FocusCardView.margin
        let om = (FocusOrbView.size - FocusOrbView.orb) / 2
        let x = TasksSettings.orbOnLeft ? orb.minX + om - m : orb.maxX - om + m - size.width
        let y = max(vf.minY - m, min(vf.maxY + m - size.height, orb.midY - size.height / 2))
        cardPanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        cardHost.frame = NSRect(origin: .zero, size: size)
        cardView.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: Quick add

    func toggleQuickAdd() { quickPanel.isVisible ? closeQuick() : showQuickAdd() }

    func showQuickAdd() {
        closeCard()
        hidePlus()
        let orb = orbFrame, s = QuickAddView.size
        quickView.leftSide = TasksSettings.orbOnLeft
        // Beside the orb, its capsule level with the orb's middle.
        let om = (FocusOrbView.size - FocusOrbView.orb) / 2, qm = QuickAddView.margin
        let x = TasksSettings.orbOnLeft ? orb.maxX - om + 10 - qm : orb.minX + om - 10 - (s.width - qm)
        let y = orb.midY - (s.height - qm - 26)
        quickPanel.setFrame(NSRect(x: x, y: y, width: s.width, height: s.height), display: true)
        quickView.field.stringValue = ""
        quickPanel.alphaValue = 0
        quickPanel.makeKeyAndOrderFront(nil)
        quickPanel.makeFirstResponder(quickView.field)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(0.16)
            quickPanel.animator().alphaValue = 1
        }
    }

    /// Esc, a click elsewhere, or a task added: the + comes back beside the orb, and tucks away
    /// again shortly unless you're over it.
    func closeQuick() {
        guard quickPanel.isVisible else { return }
        quickPanel.orderOut(nil)
        guard orbShown, !cardOpen else { return }
        showPlus()
        schedulePlusHide(after: 1.6)
    }

    // MARK: Export

    func openExport() {
        closeCard(); closeQuick()
        // Starts on the project you're looking at in the Tasks screen, and on the month a
        // timesheet is for: last month in the first week, this month after that.
        exportView.project = store.shownProject
        exportView.span = store.calendar.component(.day, from: store.now()) <= 7 ? .lastMonth : .month
        // A timesheet wants everything: linked folders catch up first, then the preview refreshes.
        syncCommits(quiet: true) { [weak self] in
            self?.exportView.refresh()
            self?.exportView.showNewest()
        }
        let vf = screen.visibleFrame, s = TaskExportView.size
        exportPanel.setFrame(NSRect(x: vf.midX - s.width / 2, y: vf.midY - s.height / 2, width: s.width, height: s.height), display: true)
        exportPanel.makeKeyAndOrderFront(nil)
        exportPanel.makeFirstResponder(exportView)
        exportView.showNewest()
    }

    private func export(_ span: TaskExport.Span, _ format: TaskExport.Format, _ project: String?) {
        do {
            let n = TaskExport.rows(store, span: span, project: project).count
            if let url = try TaskExport.export(store, span: span, format: format, project: project) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                onSay?("saved \(url.lastPathComponent) to Downloads ✨")
            } else {
                let days = TaskExport.days(TaskExport.rows(store, span: span, project: project)).count
                onSay?("copied \(days) day\(days == 1 ? "" : "s") of tasks (\(n)) 📋 paste away")
            }
            SoundService.shared.play(.clipCopy)
            exportPanel.orderOut(nil)
        } catch {
            onSay?("couldn't save to Downloads 😬")
        }
    }

    // MARK: Wiring

    private func wire() {
        orbView.onClick = { [weak self] in self?.openCard() }
        orbView.onMoved = { [weak self] in self?.orbMoved() }
        orbView.onMenu = { [weak self] e in self?.showOrbMenu(e) }
        orbView.onHover = { [weak self] on in self?.orbHover(on) }
        orbView.onDragStart = { [weak self] in self?.hidePlus() }
        plusView.onHover = { [weak self] on in
            self?.hoverPlus = on
            if !on { self?.schedulePlusHide() }
        }
        plusView.onClick = { [weak self] in self?.showQuickAdd() }
        cardView.onClose = { [weak self] in self?.closeCard() }
        cardView.onFinished = { [weak self] t in
            SoundService.shared.play(.claudeDone)
            self?.onSay?("done ✨ “\(t.title)” in \(TaskTime.short(t.spent))")
        }
        quickView.onClose = { [weak self] in self?.closeQuick() }
        quickView.onSubmit = { [weak self] text, focus in
            guard let self = self else { return }
            guard let t = self.store.add(text, focus: focus) else { NSSound.beep(); return }
            self.closeQuick()
            SoundService.shared.play(.tap)
            let p = self.store.projects.count > 1 ? " to \(self.store.project(of: t))" : ""
            self.onSay?(focus ? "focusing on “\(t.title)” ✨" : "added “\(t.title)”\(p)" + (t.estimate > 0 ? " · \(t.estimate)m" : ""))
        }
        exportView.onClose = { [weak self] in self?.exportPanel.orderOut(nil) }
        exportView.onExport = { [weak self] span, format, project in self?.export(span, format, project) }
    }

    // A click anywhere else puts each window away.
    func windowDidResignKey(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === cardPanel { closeCard() }
        else if w === quickPanel { closeQuick() }
        else if w === exportPanel { exportPanel.orderOut(nil) }
    }
}
