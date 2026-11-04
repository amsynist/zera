import AppKit
import QuartzCore

// MARK: - State

enum OnboardingState {
    private static let key = "zera.onboarded"
    /// True once the first-run window was finished or skipped.
    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - Window controller

/// The first-run window: Welcome → Pick your light → Connect → Shortcuts → Done.
/// `presentIfNeeded()` at launch shows it once; `present()` shows it again from Settings/Help.
/// Esc or the close button skips (and marks onboarding done, so it never nags).
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 720, height: 520)
    /// The one on screen, if any.
    private(set) static var current: OnboardingWindowController?

    /// Open Settings → Integrations (GitHub). Provided by the integrator.
    var onOpenSettings: (() -> Void)?
    /// Finished or skipped; the window is already closing.
    var onFinish: (() -> Void)?

    private let root: OnboardingView

    /// Shows the window on a first run; returns it so the caller can set `onOpenSettings` / `onFinish`.
    @discardableResult
    static func presentIfNeeded() -> OnboardingWindowController? {
        guard !OnboardingState.done else { return nil }
        return present()
    }

    @discardableResult
    static func present() -> OnboardingWindowController {
        if let c = current {
            c.showWindow(nil)
            c.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return c
        }
        let c = OnboardingWindowController()
        current = c
        c.showWindow(nil)
        c.window?.center()
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return c
    }

    init() {
        root = OnboardingView(frame: NSRect(origin: .zero, size: Self.size))
        let w = OnboardingWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.titled, .fullSizeContentView, .closable],
                                 backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Welcome to Zera"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.minSize = Self.size
        w.maxSize = Self.size
        w.contentView = root
        w.delegate = self
        w.onEscape = { [weak self] in self?.skip() }
        w.onKey = { [weak self] event in self?.root.handle(key: event) ?? false }
        root.onFinish = { [weak self] in self?.finish() }
        root.onSkip = { [weak self] in self?.skip() }
        root.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var finishing = false

    /// "Open Zera": done, close, tell the owner.
    private func finish() {
        guard !finishing else { return }
        finishing = true
        OnboardingState.done = true
        SoundService.shared.play(.button)
        close()
        onFinish?()
    }

    /// Esc / close: also counts as done so the window never comes back uninvited.
    private func skip() {
        guard !finishing else { return }
        finishing = true
        OnboardingState.done = true
        close()
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) {
        root.willClose()
        if !finishing {
            // Closed with the red button: same as skipping.
            finishing = true
            OnboardingState.done = true
            onFinish?()
        }
        if Self.current === self { Self.current = nil }
    }
}

/// Keyboard: Esc skips, ⏎ / → go on, ← goes back.
private final class OnboardingWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Root view

/// Navy glass, the pages in the middle, dots and Back / Next at the bottom.
private final class OnboardingView: NSView {
    var onFinish: (() -> Void)?
    var onSkip: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let blur = NSVisualEffectView()
    private let tint = CAGradientLayer()
    private let rim = CALayer()
    private let pageHost = FlippedView()
    private let dots = PageDots(count: 5)
    private let back: CardButton
    private let next: CardButton
    private let skipButton: CardButton
    private var pages: [OnboardingPage?] = Array(repeating: nil, count: 5)
    private var index = 0
    private var current: OnboardingPage?
    private var transitioning = false

    override var isFlipped: Bool { true }

    private static let footerH: CGFloat = 72
    private static let topInset: CGFloat = 36

    override init(frame: NSRect) {
        back = CardButton("Back", style: .tertiary, symbol: "chevron.left", target: nil, action: #selector(OnboardingView.backTapped))
        next = CardButton("Next", style: .primary, target: nil, action: #selector(OnboardingView.nextTapped))
        skipButton = CardButton("Skip", style: .tertiary, target: nil, action: #selector(OnboardingView.skipTapped))
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        addSubview(blur)
        tint.colors = [Neon.fillTop.withAlphaComponent(0.9).cgColor, Neon.fillBottom.withAlphaComponent(0.94).cgColor]
        tint.startPoint = CGPoint(x: 0.5, y: 0)
        tint.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(tint)
        rim.borderWidth = 1
        rim.borderColor = Neon.edge.withAlphaComponent(0.5).cgColor
        rim.cornerRadius = 14
        rim.cornerCurve = .continuous
        layer?.addSublayer(rim)

        pageHost.wantsLayer = true
        pageHost.layer?.masksToBounds = true
        addSubview(pageHost)
        addSubview(dots)
        back.target = self
        next.target = self
        skipButton.target = self
        addSubview(back)
        addSubview(next)
        addSubview(skipButton)
        show(0, direction: 0, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func page(_ i: Int) -> OnboardingPage {
        if let p = pages[i] { return p }
        let p: OnboardingPage
        switch i {
        case 0: p = WelcomePage()
        case 1: p = LightPage()
        case 2:
            let c = ConnectPage()
            c.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
            p = c
        case 3: p = ShortcutsPage()
        default:
            let d = DonePage()
            d.onOpen = { [weak self] in self?.onFinish?() }
            p = d
        }
        pages[i] = p
        return p
    }

    // MARK: Paging

    private func show(_ i: Int, direction: CGFloat, animated: Bool) {
        guard pages.indices.contains(i), !transitioning else { return }
        let old = current
        let new = page(i)
        index = i
        current = new
        dots.selected = i
        back.isHidden = i == 0
        next.setTitleText(i == pages.count - 1 ? "Open Zera" : "Next")
        skipButton.isHidden = i == pages.count - 1
        needsLayout = true

        let w = pageHost.bounds.width
        new.frame = pageHost.bounds
        new.wantsLayer = true
        pageHost.addSubview(new)
        new.layoutSubtreeIfNeeded()
        new.didShow()

        guard let old = old, old !== new else { return }
        old.willHide()
        let dur = Motion.duration(0.28)
        guard animated, dur > 0, direction != 0, window != nil, w > 0 else {
            old.removeFromSuperview()
            return
        }
        transitioning = true
        old.wantsLayer = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(dur)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self, weak old] in
            old?.removeFromSuperview()
            old?.layer?.removeAllAnimations()
            self?.transitioning = false
        }
        let leave = CABasicAnimation(keyPath: "transform.translation.x")
        leave.fromValue = 0; leave.toValue = -direction * w; leave.duration = dur
        leave.fillMode = .forwards; leave.isRemovedOnCompletion = false
        old.layer?.add(leave, forKey: "slide")
        let leaveFade = CABasicAnimation(keyPath: "opacity")
        leaveFade.fromValue = 1; leaveFade.toValue = 0; leaveFade.duration = dur
        leaveFade.fillMode = .forwards; leaveFade.isRemovedOnCompletion = false
        old.layer?.add(leaveFade, forKey: "fade")
        let enter = CABasicAnimation(keyPath: "transform.translation.x")
        enter.fromValue = direction * w; enter.toValue = 0; enter.duration = dur
        new.layer?.add(enter, forKey: "slide")
        let enterFade = CABasicAnimation(keyPath: "opacity")
        enterFade.fromValue = 0; enterFade.toValue = 1; enterFade.duration = dur
        new.layer?.add(enterFade, forKey: "fade")
        CATransaction.commit()
    }

    @objc private func backTapped() {
        SoundService.shared.play(.tab)
        show(index - 1, direction: -1, animated: true)
    }

    @objc private func nextTapped() {
        if index == pages.count - 1 { onFinish?(); return }
        SoundService.shared.play(.tab)
        show(index + 1, direction: 1, animated: true)
    }

    @objc private func skipTapped() { onSkip?() }

    /// ⏎ / → forward, ← back. Returns whether the key was used.
    func handle(key event: NSEvent) -> Bool {
        if current?.wantsKeys == true { return false }
        switch event.keyCode {
        case 36, 76, 124: nextTapped(); return true   // return, enter, →
        case 123: if index > 0 { backTapped() }; return true
        default: return false
        }
    }

    func willClose() {
        pages.forEach { $0?.willHide() }
    }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        blur.frame = b
        tint.frame = b
        rim.frame = b
        CATransaction.commit()
        pageHost.frame = NSRect(x: 0, y: Self.topInset, width: b.width, height: b.height - Self.topInset - Self.footerH)
        current?.frame = pageHost.bounds
        let fy = b.height - Self.footerH
        let bh = Metrics.button
        let by = fy + (Self.footerH - bh) / 2
        let bw = max(80, back.fittedWidth)
        back.frame = NSRect(x: Space.xxl, y: by, width: bw, height: bh)
        let sw = max(70, skipButton.fittedWidth)
        skipButton.frame = NSRect(x: back.isHidden ? Space.xxl : back.frame.maxX + Space.s, y: by, width: sw, height: bh)
        let nw = max(110, next.fittedWidth + 12)
        next.frame = NSRect(x: b.width - Space.xxl - nw, y: by, width: nw, height: bh)
        dots.frame = NSRect(x: (b.width - 120) / 2, y: fy + (Self.footerH - 12) / 2, width: 120, height: 12)
    }
}

// MARK: - Dots

private final class PageDots: NSView {
    let count: Int
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(count: Int) {
        self.count = count
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let d: CGFloat = 7, gap: CGFloat = 8, wide: CGFloat = 20
        let total = CGFloat(count - 1) * (d + gap) + wide
        var x = (bounds.width - total) / 2
        let y = (bounds.height - d) / 2
        for i in 0..<count {
            let w = i == selected ? wide : d
            let r = NSRect(x: x, y: y, width: w, height: d)
            (i == selected ? p.accent : p.textTertiary.withAlphaComponent(0.5)).setFill()
            NSBezierPath(roundedRect: r, xRadius: d / 2, yRadius: d / 2).fill()
            x += w + gap
        }
    }
}

// MARK: - Pages

/// One step. Content starts at `Space.xxl * 2` from the sides; `layoutBody` places it.
private class OnboardingPage: NSView {
    override var isFlipped: Bool { true }
    /// Pages with text fields keep ⏎ / arrows to themselves.
    var wantsKeys: Bool { false }
    static let inset: CGFloat = 48

    let heading = NSTextField(labelWithString: "")
    let lede = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        heading.font = Typo.screenTitle
        heading.textColor = Pal.text
        heading.lineBreakMode = .byTruncatingTail
        addSubview(heading)
        lede.font = Typo.screenSubtitle
        lede.textColor = Pal.textSecondary
        lede.isSelectable = false
        addSubview(lede)
    }
    required init?(coder: NSCoder) { fatalError() }

    func didShow() {}
    func willHide() {}

    /// Title + lede at the top; returns the y where the body starts.
    func layoutHeader() -> CGFloat {
        let w = bounds.width - Self.inset * 2
        heading.frame = NSRect(x: Self.inset, y: Space.l, width: w, height: 32)
        let hasLede = !lede.stringValue.isEmpty
        lede.isHidden = !hasLede
        guard hasLede else { return heading.frame.maxY + Space.l }
        let h = (lede.stringValue as NSString).boundingRect(with: NSSize(width: w, height: 80), options: [.usesLineFragmentOrigin],
                                                            attributes: [.font: Typo.screenSubtitle]).height
        lede.frame = NSRect(x: Self.inset, y: heading.frame.maxY + Space.xs, width: w, height: ceil(h) + 2)
        return lede.frame.maxY + Space.l
    }
}

// MARK: Welcome

private final class WelcomePage: OnboardingPage {
    private let zera = ZeraCompanion(pose: "card_greet", size: 150, side: .bubbleRight)
    private let props: [PropRow] = [
        PropRow(symbol: "macbook", color: Pal.info, text: "Your Mac at a glance — vitals, media, weather and what's next"),
        PropRow(symbol: "sparkles", color: Pal.tileClaude, text: "Your agents, approvals and alerts, right under the notch"),
        PropRow(symbol: "tray.full.fill", color: Pal.tileNote, text: "Files, clipboard, focus, reminders and a teleprompter")
    ]

    override init() {
        super.init()
        heading.stringValue = "Meet Zera, your buddy in the notch."
        lede.stringValue = "She lives at the top of your screen and keeps the useful things one hover away."
        zera.line = "hi! 👋"
        addSubview(zera)
        props.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let y0 = layoutHeader()
        let w = bounds.width - Self.inset * 2
        let figW: CGFloat = 230
        let avail = bounds.height - y0 - Space.l
        zera.frame = NSRect(x: Self.inset, y: y0 + max(0, (avail - 170) / 2), width: figW, height: 170)
        let rowH: CGFloat = 50, gap = Space.m
        let listH = CGFloat(props.count) * rowH + CGFloat(props.count - 1) * gap
        var y = y0 + max(0, (avail - listH) / 2)
        let x = Self.inset + figW + Space.xl
        for r in props {
            r.frame = NSRect(x: x, y: y, width: w - figW - Space.xl, height: rowH)
            y += rowH + gap
        }
    }
}

/// Icon tile + one line.
private final class PropRow: NSView {
    private let tile: IconTile
    private let label = NSTextField(wrappingLabelWithString: "")
    override var isFlipped: Bool { true }

    init(symbol: String, color: NSColor, text: String) {
        tile = IconTile(symbol: symbol, color: color, size: 36, pointSize: 15)
        super.init(frame: .zero)
        addSubview(tile)
        label.stringValue = text
        label.font = Typo.rowTitle
        label.textColor = Pal.text
        label.maximumNumberOfLines = 2
        label.isSelectable = false
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        tile.frame = NSRect(x: 0, y: (h - 36) / 2, width: 36, height: 36)
        let tx = 36 + Space.m
        let tw = bounds.width - tx
        let th = (label.stringValue as NSString).boundingRect(with: NSSize(width: tw, height: h), options: [.usesLineFragmentOrigin],
                                                              attributes: [.font: Typo.rowTitle]).height
        label.frame = NSRect(x: tx, y: ((h - ceil(th)) / 2).rounded(), width: tw, height: ceil(th) + 2)
    }
}

// MARK: Light

private final class LightPage: OnboardingPage {
    private let picker = NotchLightPicker()

    override init() {
        super.init()
        heading.stringValue = "Pick your light."
        lede.stringValue = "How the island's edge glows. You can change it any time in Settings → Appearance."
        picker.onChange = { s in NotchLightStyle.current = s }
        picker.onIntensityChange = { v in NotchLightStyle.intensity = v }
        addSubview(picker)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func didShow() { picker.resumePreviews() }
    override func willHide() { picker.pausePreviews() }

    override func layout() {
        super.layout()
        let y0 = layoutHeader()
        let w = bounds.width - Self.inset * 2
        let h = picker.preferredHeight
        picker.frame = NSRect(x: Self.inset, y: y0 + Space.m, width: w, height: h)
    }
}

// MARK: Connect

private final class ConnectPage: OnboardingPage {
    var onOpenSettings: (() -> Void)?

    private let claudeRow = ListRow(symbol: "sparkles", color: Pal.tileClaude, title: "Claude Code hooks", subtitle: "Live progress and approvals")
    private let githubRow = ListRow(symbol: "arrow.triangle.pull", color: Pal.tileGitHub, title: "GitHub", subtitle: "Pull requests, checks and runs to approve")
    private let calendarRow = ListRow(symbol: "calendar", color: Pal.tileCalendar, title: "Calendar & Reminders", subtitle: "Next up on Home, meeting alerts")
    private let weatherRow = ListRow(symbol: "location.fill", color: Pal.info, title: "Weather location", subtitle: "Local forecast on Home (Open-Meteo, no account)")
    private let claudeToggle = Toggle()
    private let githubButton: CardButton
    private let calendarToggle = Toggle()
    private let weatherToggle = Toggle()
    private let note = NSTextField(wrappingLabelWithString: "")
    private var observers: [NSObjectProtocol] = []

    override init() {
        githubButton = CardButton("Connect…", style: .secondary, target: nil, action: #selector(ConnectPage.githubTapped))
        super.init()
        heading.stringValue = "Connect what you use."
        lede.stringValue = "Everything is optional and stays on this Mac. Each one can be changed later in Settings → Integrations."

        claudeToggle.onChange = { [weak self] on in self?.setClaude(on) }
        claudeRow.accessory = claudeToggle
        githubButton.target = self
        githubRow.accessory = githubButton
        calendarToggle.onChange = { [weak self] on in self?.setCalendar(on) }
        calendarRow.accessory = calendarToggle
        weatherToggle.onChange = { [weak self] on in self?.setWeather(on) }
        weatherRow.accessory = weatherToggle
        [claudeRow, githubRow, calendarRow, weatherRow].forEach(addSubview)

        note.font = Typo.caption
        note.textColor = Pal.textTertiary
        note.isSelectable = false
        note.stringValue = "Hooks are added to ~/.claude/settings.json and removed the same way. Zera never sends your data anywhere but the service you connect."
        addSubview(note)

        let nc = NotificationCenter.default
        for name in [ClaudeHookService.changed, ClaudeActivityService.changed, GitHubService.changed, ReminderService.changed] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    override func didShow() { refresh() }

    private func refresh() {
        let hook = ClaudeHookService.shared, act = ClaudeActivityService.shared
        let hooksOn = hook.isInstalled && act.isInstalled
        claudeToggle.isOn = hooksOn
        claudeRow.set(subtitle: hooksOn ? "Installed · live progress and approvals" : "Live progress and approvals")

        let gh = GitHubService.shared
        if gh.isConnected, let login = gh.login {
            githubRow.set(subtitle: "Connected as \(login)")
            githubButton.setTitleText("Settings…")
        } else {
            githubRow.set(subtitle: "Pull requests, checks and runs to approve")
            githubButton.setTitleText("Connect…")
        }

        weatherToggle.isOn = WeatherService.shared.mode == .location

        let rs = ReminderService.shared
        calendarToggle.isOn = rs.calendarAuthorized
        if rs.calendarAuthorized {
            calendarRow.set(subtitle: "Allowed · next up on Home, meeting alerts")
        } else if rs.calendarDenied {
            calendarRow.set(subtitle: "Denied — allow Zera in System Settings → Privacy → Calendars")
        } else {
            calendarRow.set(subtitle: "Next up on Home, meeting alerts")
        }
        needsLayout = true
    }

    private func setClaude(_ on: Bool) {
        let hook = ClaudeHookService.shared, act = ClaudeActivityService.shared
        do {
            if on {
                if !hook.isInstalled { try hook.install() }
                if !act.isInstalled { try act.install() }
            } else {
                if hook.isInstalled { try hook.uninstall() }
                if act.isInstalled { try act.uninstall() }
            }
        } catch {
            claudeRow.set(subtitle: "Couldn't edit ~/.claude/settings.json")
        }
        refresh()
    }

    @objc private func githubTapped() { onOpenSettings?() }

    private func setCalendar(_ on: Bool) {
        let rs = ReminderService.shared
        if on {
            calendarRow.set(subtitle: "Asking macOS…")
            Task { @MainActor [weak self] in
                await rs.connectCalendar()
                self?.refresh()
            }
        } else {
            rs.disconnectCalendar()
            refresh()
        }
    }

    private func setWeather(_ on: Bool) {
        // `WeatherService.shared.setMode(_:city:)`; location access is asked for by the service.
        WeatherService.shared.setMode(on ? .location : .off)
        weatherRow.set(subtitle: on ? "Using your location · local forecast on Home" : "Local forecast on Home (Open-Meteo, no account)")
    }

    override func layout() {
        super.layout()
        let y0 = layoutHeader()
        let w = bounds.width - Self.inset * 2
        var y = y0
        let rh = Metrics.settingRow
        for r in [claudeRow, githubRow, calendarRow, weatherRow] {
            r.frame = NSRect(x: Self.inset, y: y, width: w, height: rh)
            y += rh + Metrics.rowGap
        }
        let nh = (note.stringValue as NSString).boundingRect(with: NSSize(width: w, height: 60), options: [.usesLineFragmentOrigin],
                                                             attributes: [.font: Typo.caption]).height
        note.frame = NSRect(x: Self.inset + 4, y: y + Space.xs, width: w - 8, height: ceil(nh) + 2)
    }
}

// MARK: Shortcuts

private final class ShortcutsPage: OnboardingPage {
    private var rows: [ShortcutRow] = []
    private let echoRow = ListRow(symbol: "keyboard", color: Pal.accent, title: "Command Echo", subtitle: "Shows what you press under the notch")
    private let echoToggle = Toggle()

    override init() {
        super.init()
        heading.stringValue = "A few things to try."
        lede.stringValue = "Hover her for the tabs; the rest are shortcuts you can change in Settings → Shortcuts."

        let opener = HotKeyShortcut.load("appOpener.shortcut", default: AppOpenerSettings.defaultShortcut)
        let tasks = HotKeyShortcut.load("tasks.shortcut", default: TasksSettings.defaultShortcut)
        let clip = HotKeyShortcut.load("clipboard.shortcut", default: .default)
        rows = [
            ShortcutRow(title: "Hover Zera", detail: "The tabs bloom around the notch", keys: ["Hover"]),
            ShortcutRow(title: "Open an app", detail: "Type a few letters, ⏎ to launch", keys: Self.keys(opener, off: "Off")),
            ShortcutRow(title: "Add a task", detail: "Quick add, from anywhere", keys: Self.keys(tasks, off: "Off")),
            ShortcutRow(title: "Clipboard", detail: "Your recent copies, searchable", keys: Self.keys(clip, off: "Off"))
        ]
        rows.forEach(addSubview)

        // `CommandEcho.shared.isEnabled` owns the `zera.echo.enabled` default and installs or
        // removes its event monitors as it changes.
        echoToggle.isOn = CommandEcho.shared.isEnabled
        echoToggle.onChange = { on in CommandEcho.shared.isEnabled = on }
        echoRow.accessory = echoToggle
        addSubview(echoRow)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "⌥⌘T" → ["⌥", "⌘", "T"]; nil → one "Off" cap.
    private static func keys(_ s: HotKeyShortcut?, off: String) -> [String] {
        guard let s = s else { return [off] }
        var out: [String] = []
        var rest = Substring(s.label)
        while let c = rest.first, "⌃⌥⇧⌘".contains(c) {
            out.append(String(c))
            rest = rest.dropFirst()
        }
        out.append(rest.isEmpty ? s.key : String(rest))
        return out
    }

    override func layout() {
        super.layout()
        let y0 = layoutHeader()
        let w = bounds.width - Self.inset * 2
        var y = y0
        let rh: CGFloat = 46
        for r in rows {
            r.frame = NSRect(x: Self.inset, y: y, width: w, height: rh)
            y += rh + Space.xs
        }
        y += Space.s
        echoRow.frame = NSRect(x: Self.inset, y: y, width: w, height: RowTier.standard.height)
    }
}

/// Title + detail on the left, keycaps on the right.
private final class ShortcutRow: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let keys: [String]
    override var isFlipped: Bool { true }

    init(title t: String, detail d: String, keys k: [String]) {
        keys = k
        super.init(frame: .zero)
        title.stringValue = t
        title.font = Typo.rowTitle
        title.textColor = Pal.text
        addSubview(title)
        detail.stringValue = d
        detail.font = Typo.meta
        detail.textColor = Pal.textSecondary
        detail.lineBreakMode = .byTruncatingTail
        addSubview(detail)
        setAccessibilityLabel("\(t): \(k.joined()) — \(d)")
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let capFont = Typo.bodyStrong
    private static let capH: CGFloat = 26
    private static let capGap: CGFloat = 6

    private var capWidths: [CGFloat] {
        keys.map { max(Self.capH, ceil(($0 as NSString).size(withAttributes: [.font: Self.capFont]).width) + 16) }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let capsW = capWidths.reduce(0, +) + CGFloat(max(0, keys.count - 1)) * Self.capGap
        let textW = max(60, bounds.width - capsW - Space.l)
        title.frame = NSRect(x: 0, y: (h / 2 - 18).rounded(), width: textW, height: 18)
        detail.frame = NSRect(x: 0, y: (h / 2 + 1).rounded(), width: textW, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let widths = capWidths
        let total = widths.reduce(0, +) + CGFloat(max(0, keys.count - 1)) * Self.capGap
        var x = bounds.width - total
        let y = (bounds.height - Self.capH) / 2
        // Hairline under the row.
        p.divider.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)).fill()
        for (i, k) in keys.enumerated() {
            let r = NSRect(x: x, y: y, width: widths[i], height: Self.capH)
            let cap = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
            p.surfaceStrong.setFill(); cap.fill()
            p.accentBorder.withAlphaComponent(0.35).setStroke(); cap.lineWidth = 1; cap.stroke()
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.capFont, .foregroundColor: p.text, .paragraphStyle: para]
            let th = Self.capFont.ascender - Self.capFont.descender
            (k as NSString).draw(in: NSRect(x: r.minX, y: r.midY - th / 2, width: r.width, height: th + 2), withAttributes: attrs)
            x += widths[i] + Self.capGap
        }
    }
}

// MARK: Done

private final class DonePage: OnboardingPage {
    var onOpen: (() -> Void)?
    private let zera = ZeraCompanion(pose: "card_cheer", size: 150, side: .bubbleRight)
    private let open: CardButton
    private let hint = NSTextField(wrappingLabelWithString: "")

    override init() {
        open = CardButton("Open Zera", style: .primary, symbol: "sparkles", target: nil, action: #selector(DonePage.openTapped))
        super.init()
        heading.stringValue = "You're set."
        lede.stringValue = "Zera is up at the notch. Hover her to open the tabs; ⌘, opens Settings from her menu bar icon."
        zera.line = "see you up top ✨"
        addSubview(zera)
        open.target = self
        addSubview(open)
        hint.stringValue = "You can run this welcome again from Settings → About."
        hint.font = Typo.caption
        hint.textColor = Pal.textTertiary
        hint.isSelectable = false
        hint.alignment = .center
        addSubview(hint)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func openTapped() { onOpen?() }

    override func layout() {
        super.layout()
        let y0 = layoutHeader()
        let avail = bounds.height - y0 - Space.l
        let figH: CGFloat = 170
        let bw = max(140, open.fittedWidth + 16), bh: CGFloat = 36
        let block = figH + Space.l + bh + Space.s + 16
        var y = y0 + max(0, (avail - block) / 2)
        zera.frame = NSRect(x: (bounds.width - 300) / 2, y: y, width: 300, height: figH)
        y += figH + Space.l
        open.frame = NSRect(x: (bounds.width - bw) / 2, y: y, width: bw, height: bh)
        y += bh + Space.s
        hint.frame = NSRect(x: Self.inset, y: y, width: bounds.width - Self.inset * 2, height: 16)
    }
}
