import AppKit

// MARK: - Focus: the island screen
//
//   notch tab  Focus  → a big ring timer on TaskStore's focus task (Start / Pause · Reset · Done),
//                       session presets 25 · 45 · 60 · Custom, today's open tasks (tap to focus),
//                       quick add, and the day's total. The closed notch reads the same session
//                       through the tab's IslandInstrument ring (`FocusView.instrument`).
//
// No clock of its own: TaskStore ticks once a second while focusing (`TaskStore.ticked`) and
// posts `TaskStore.changed` when the list or the focus moves; this screen only pushes values in.

// MARK: - Presets

/// How long a focus session is meant to run, for a task that has no estimate of its own.
enum FocusPreset: Equatable {
    case twentyFive, fortyFive, sixty, custom(Int)

    private static let presetKey = "zera.focus.preset"
    private static let customKey = "zera.focus.customMinutes"
    static let defaultCustom = 90

    var minutes: Int {
        switch self {
        case .twentyFive: return 25
        case .fortyFive: return 45
        case .sixty: return 60
        case .custom(let m): return max(1, min(24 * 60, m))
        }
    }

    /// Position among the chips: 25 · 45 · 60 · Custom.
    var chipIndex: Int {
        switch self {
        case .twentyFive: return 0
        case .fortyFive: return 1
        case .sixty: return 2
        case .custom: return 3
        }
    }

    static func at(chipIndex i: Int) -> FocusPreset {
        switch i {
        case 0: return .twentyFive
        case 1: return .fortyFive
        case 2: return .sixty
        default: return .custom(customMinutes)
        }
    }

    /// The custom length, remembered on its own so switching back to Custom finds it again.
    static var customMinutes: Int {
        get {
            let m = UserDefaults.standard.integer(forKey: customKey)
            return m > 0 ? m : defaultCustom
        }
        set { UserDefaults.standard.set(max(1, min(24 * 60, newValue)), forKey: customKey) }
    }

    static var current: FocusPreset {
        get {
            let raw = UserDefaults.standard.object(forKey: presetKey) as? Int ?? 0
            return at(chipIndex: raw)
        }
        set {
            if case .custom(let m) = newValue { customMinutes = m }
            UserDefaults.standard.set(newValue.chipIndex, forKey: presetKey)
        }
    }

    static let chipTitles = ["25", "45", "60", "Custom"]
}

// MARK: - The session

/// What the ring measures: the focused task's time against its target (its estimate, or the
/// preset when it has none). A task without an estimate counts from when it came into focus,
/// so an old task with hours on it still gets a fresh 25 minutes. Shared by the screen and the
/// notch instrument, so both read the same clock.
enum FocusSession {
    struct Reading {
        let task: FocusTask
        /// Seconds into this session.
        let spent: TimeInterval
        let target: TimeInterval
        var remaining: TimeInterval { max(0, target - spent) }
        var progress: Double { target > 0 ? min(1, spent / target) : 0 }
        var finished: Bool { target > 0 && spent >= target }
    }

    /// The task the base was taken for, and the seconds it had then.
    private static var baseTaskID: UUID?
    private static var base: TimeInterval = 0
    private static var observer: NSObjectProtocol?

    /// Starts following the store's focus (once); safe to call often.
    static func activate() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: TaskStore.changed, object: TaskStore.shared, queue: .main) { _ in
            FocusSession.rebase(TaskStore.shared)
        }
        rebase(TaskStore.shared)
    }

    private static func rebase(_ store: TaskStore) {
        guard let f = store.focus else { baseTaskID = nil; base = 0; return }
        guard f.id != baseTaskID else { return }
        baseTaskID = f.id
        base = f.estimate > 0 ? 0 : f.spent
    }

    static func target(_ t: FocusTask) -> TimeInterval {
        TimeInterval(t.estimate > 0 ? t.estimate : FocusPreset.current.minutes) * 60
    }

    static func reading(_ store: TaskStore) -> Reading? {
        guard let f = store.focus else { return nil }
        if f.id != baseTaskID { rebase(store) }
        return Reading(task: f, spent: max(0, store.spent(f) - base), target: target(f))
    }

    /// Starts the session over from now (the time already spent stays on the task's log).
    static func reset(_ store: TaskStore) {
        guard let f = store.focus else { return }
        baseTaskID = f.id
        base = store.spent(f)
    }
}

// MARK: - The ring

/// A large circular timer: a quiet track, an accent-gradient arc that fills clockwise from
/// twelve, the time left in the middle and the task under it. Pure Core Animation — nothing
/// here ticks; push values in with `set(progress:animated:)` and `set(time:title:)`.
final class FocusTimerRing: NSView {
    enum State { case idle, running, paused, done }
    static let size: CGFloat = 180
    static let lineWidth: CGFloat = 10

    private let track = CAShapeLayer()
    private let glow = CALayer()              // carries the gradient (and its soft shadow)
    private let gradient = CAGradientLayer()
    private let arc = CAShapeLayer()           // masks the gradient to the progress
    private let timeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private(set) var state: State = .idle
    private(set) var progress: Double = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.masksToBounds = false
        track.fillColor = NSColor.clear.cgColor
        track.lineWidth = Self.lineWidth
        layer?.addSublayer(track)
        arc.fillColor = NSColor.clear.cgColor
        arc.strokeColor = NSColor.black.cgColor
        arc.lineWidth = Self.lineWidth
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.mask = arc
        glow.addSublayer(gradient)
        glow.shadowOpacity = 0.55
        glow.shadowRadius = 6
        glow.shadowOffset = .zero
        layer?.addSublayer(glow)

        timeLabel.font = Typo.metricValue.withSize(38)
        timeLabel.alignment = .center
        timeLabel.lineBreakMode = .byClipping
        timeLabel.stringValue = "25:00"
        addSubview(timeLabel)
        titleLabel.font = Typo.meta
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = Pal.textSecondary
        addSubview(titleLabel)
        setAccessibilityRole(.progressIndicator)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Colour for the state: running = accent, paused = quiet, done = green.
    func set(state s: State) {
        guard s != state else { return }
        state = s
        restyle()
    }

    /// The two lines in the middle.
    func set(time: String, title: String) {
        if timeLabel.stringValue != time {
            timeLabel.stringValue = time
            // "1:02:10" needs a smaller face than "25:00" to stay inside the ring.
            let size: CGFloat = time.count > 5 ? 28 : 38
            if timeLabel.font?.pointSize != size { timeLabel.font = Typo.metricValue.withSize(size) }
        }
        if titleLabel.stringValue != title { titleLabel.stringValue = title; needsLayout = true }
        setAccessibilityValue("\(time) \(title)")
    }

    /// Fills the arc to `progress` (0…1). Animated: a short ease on `strokeEnd`, skipped with
    /// Reduce Motion.
    func set(progress p: Double, animated: Bool) {
        let to = CGFloat(max(0, min(1, p)))
        progress = Double(to)
        let from = (arc.presentation() ?? arc).strokeEnd
        arc.removeAnimation(forKey: "fill")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = to
        CATransaction.commit()
        guard animated, !Motion.reduced, abs(to - from) > 0.0005 else { return }
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = from
        a.toValue = to
        // Tick to tick the arc glides for the second; a jump (reset, new task) eases over.
        let jump = abs(to - from) > 0.05
        a.duration = jump ? 0.45 : 1.0
        a.timingFunction = CAMediaTimingFunction(name: jump ? .easeInEaseOut : .linear)
        arc.add(a, forKey: "fill")
    }

    private func restyle() {
        let p = Pal
        let colors: [NSColor]
        let ink: NSColor
        switch state {
        case .running:
            colors = [p.accent, p.accentDeep, p.accent]
            ink = p.text
        case .paused, .idle:
            colors = [p.textTertiary, p.textTertiary]
            ink = state == .idle ? p.textSecondary : p.text
        case .done:
            colors = [p.success, p.success]
            ink = p.success
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = p.accent.withAlphaComponent(0.14).cgColor
        gradient.colors = colors.map { $0.cgColor }
        glow.shadowColor = (state == .done ? p.success : (state == .running ? p.accent : NSColor.clear)).cgColor
        glow.shadowOpacity = state == .running || state == .done ? 0.55 : 0
        CATransaction.commit()
        timeLabel.textColor = ink
        titleLabel.textColor = state == .idle ? p.textTertiary : p.textSecondary
    }

    override func layout() {
        super.layout()
        let b = bounds
        let inset = Self.lineWidth / 2 + 2
        let r = min(b.width, b.height) / 2 - inset
        let c = CGPoint(x: b.midX, y: b.midY)
        // From twelve o'clock, clockwise (the layer shares the view's flipped geometry).
        let path = CGMutablePath()
        path.addArc(center: c, radius: r, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2, clockwise: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = b; track.path = path
        glow.frame = b
        gradient.frame = b
        arc.frame = b; arc.path = path
        CATransaction.commit()
        let th: CGFloat = 44, sh: CGFloat = 17
        let inner = b.insetBy(dx: inset + Self.lineWidth + 10, dy: 0)
        timeLabel.frame = NSRect(x: inner.minX, y: (b.midY - (th + sh + 2) / 2).rounded(), width: inner.width, height: th)
        titleLabel.frame = NSRect(x: inner.minX, y: timeLabel.frame.maxY + 2, width: inner.width, height: sh)
    }
}

// MARK: - The screen

/// The Focus screen: ring and transport on the left, what's up next on the right.
final class FocusView: CardBase, CardContent, NSTextFieldDelegate {
    var cardWidth: CGFloat { Isle.lensWidth }
    var say: ((String, ZeraMood) -> Void)?
    /// "All tasks →": open the Tasks screen.
    var onOpenTasks: (() -> Void)?

    private let store: TaskStore
    private let ring = FocusTimerRing()
    private let startButton: CardButton
    private let resetButton: CardButton
    private let doneButton: CardButton
    private let chips = ChoiceChips(items: FocusPreset.chipTitles.map { ChoiceChips.Item(title: $0) })
    private let customField = ThemedField(placeholder: "min")
    private let upNext = SectionHeader("Up next", link: "All tasks →")
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private var rows: [ListRow] = []
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let fieldBox = TaskPaint()
    /// Quick add: "Write docs #proj 30m" ⏎ adds it and starts focusing.
    let field = TaskField(placeholder: "Focus on something new… “Write docs #proj 30m”", size: 14)
    private let stats = NSTextField(labelWithString: "")
    private var listHeight: CGFloat = 0
    /// Said "time's up" for this task already.
    private var finishedSaid: UUID?

    private let pad: CGFloat = Metrics.sidePad
    private static let content: CGFloat = 300
    private static let leftWidth: CGFloat = 300
    private static let gutter: CGFloat = Space.xxl
    private static let rowHeight: CGFloat = RowTier.compact.height

    init(store: TaskStore = .shared) {
        self.store = store
        startButton = CardButton("Start", style: .primary, symbol: "play.fill", target: nil, action: #selector(FocusView.startTapped))
        resetButton = CardButton("Reset", style: .secondary, symbol: "arrow.counterclockwise", target: nil, action: #selector(FocusView.resetTapped))
        doneButton = CardButton("Done", style: .success, symbol: "checkmark", target: nil, action: #selector(FocusView.doneTapped))
        super.init(width: Isle.lensWidth, title: "Focus")
        FocusSession.activate()
        let p = Pal

        addSubview(ring)
        for b in [startButton, resetButton, doneButton] {
            b.target = self
            addSubview(b)
        }

        chips.selection = [FocusPreset.current.chipIndex]
        chips.onChange = { [weak self] sel in
            guard let self = self, let i = sel.min() else { return }
            self.pick(FocusPreset.at(chipIndex: i))
        }
        addSubview(chips)
        customField.alignment = .center
        customField.delegate = self
        customField.stringValue = "\(FocusPreset.customMinutes)"
        customField.toolTip = "Custom length, in minutes"
        customField.isHidden = FocusPreset.current.chipIndex != 3
        addSubview(customField)

        upNext.onLink = { [weak self] in self?.onOpenTasks?() }
        addSubview(upNext)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.documentView = doc
        addSubview(scroll)

        emptyLabel.stringValue = "Pick something to focus on"
        emptyLabel.font = Typo.rowTitle
        emptyLabel.textColor = p.textSecondary
        emptyLabel.alignment = .left
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        fieldBox.paint = { r in
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.m, yRadius: Radius.m)
            Neon.accent.withAlphaComponent(0.08).setFill(); path.fill()
            Neon.accent.withAlphaComponent(0.5).setStroke(); path.lineWidth = 1; path.stroke()
            Neon.symbol("plus", in: NSRect(x: 4, y: 0, width: 28, height: r.height), size: 13, weight: .bold, color: Neon.cyan)
            let k = NSRect(x: r.width - 34, y: (r.height - 20) / 2, width: 24, height: 20)
            let kp = NSBezierPath(roundedRect: k, xRadius: 5, yRadius: 5)
            Neon.chipEdge.setStroke(); kp.lineWidth = 1; kp.stroke()
            let ps = NSMutableParagraphStyle(); ps.alignment = .center
            ("⏎" as NSString).draw(in: NSRect(x: k.minX, y: k.minY + 2, width: k.width, height: k.height),
                                   withAttributes: [.font: Typo.mono, .foregroundColor: Neon.glyph, .paragraphStyle: ps])
        }
        addSubview(fieldBox)
        field.delegate = self
        addSubview(field)

        stats.font = Typo.secondary
        stats.textColor = p.textTertiary
        stats.lineBreakMode = .byTruncatingTail
        addSubview(stats)

        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: TaskStore.changed, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(storeTicked), name: TaskStore.ticked, object: store)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    var desiredHeight: CGFloat { min(Isle.maxContentHeight, headerBottom + Self.content) }

    func willShow() {
        field.stringValue = ""
        reload()
        scroll.contentView.scroll(to: .zero)
        refreshRing(animated: false)
    }

    // MARK: Store

    @objc private func storeChanged() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        reload()
        refreshRing(animated: true)
    }

    /// A second went by: only the ring and the totals move.
    @objc private func storeTicked() {
        guard window?.isVisible == true else { return }
        refreshRing(animated: true)
        updateTotals()
    }

    /// Rebuilds the list from the store; the ring is refreshed separately.
    func reload() {
        doc.subviews.forEach { $0.removeFromSuperview() }
        rows = []
        let open = store.open
        let w = max(0, cardWidth - pad * 2 - Self.leftWidth - Self.gutter)
        var y: CGFloat = 0
        for t in open {
            let inFocus = t.id == store.focusID
            let symbol = inFocus ? (store.isRunning ? "pause.fill" : "play.fill") : "circle"
            let row = ListRow(symbol: symbol, color: inFocus ? Pal.accent : Pal.textTertiary, title: t.title,
                              subtitle: store.projects.count > 1 ? store.project(of: t) : "",
                              trailing: TaskTime.rowText(t, spent: store.spent(t), focus: inFocus))
            row.selected = inFocus
            row.frame = NSRect(x: 0, y: y, width: w, height: Self.rowHeight)
            row.onTap = { [weak self] in self?.focus(on: t) }
            doc.addSubview(row)
            rows.append(row)
            y += Self.rowHeight + Metrics.rowGap
        }
        listHeight = max(0, y - Metrics.rowGap)
        doc.frame = NSRect(x: 0, y: 0, width: w, height: listHeight)
        emptyLabel.isHidden = !open.isEmpty
        scroll.isHidden = open.isEmpty
        upNext.title.attributedStringValue = Typo.sectionText(open.isEmpty ? "Up next" : "Up next · \(open.count)")
        chips.selection = [FocusPreset.current.chipIndex]
        updateTotals()
        needsLayout = true
    }

    private func updateTotals() {
        let open = store.open.count
        let line = "\(TaskTime.short(store.focusedToday)) focused today · \(open) open"
        if subtitleLabel.stringValue != line { setSubtitle(line) }
        let done = store.doneToday.count
        stats.stringValue = "Today · \(TaskTime.short(store.focusedToday)) focused · \(done) done   ·   ⏎ adds and focuses"
    }

    /// Pushes the session into the ring and the transport.
    private func refreshRing(animated: Bool) {
        if let r = FocusSession.reading(store) {
            let running = store.isRunning
            ring.set(state: r.finished ? .done : (running ? .running : .paused))
            ring.set(progress: r.progress, animated: animated)
            ring.set(time: r.finished ? "Done" : TaskTime.clock(r.remaining), title: r.task.title)
            startButton.setTitleText(running ? "Pause" : "Resume")
            startButton.isEnabled = true
            resetButton.isEnabled = true
            doneButton.isEnabled = true
            if r.finished, finishedSaid != r.task.id {
                finishedSaid = r.task.id
                say?("Time! \(Int(r.target / 60))m on \(r.task.title) 🎉", .celebrate)
            }
        } else {
            ring.set(state: .idle)
            ring.set(progress: 0, animated: animated)
            let open = store.open
            ring.set(time: TaskTime.clock(TimeInterval(FocusPreset.current.minutes * 60)),
                     title: open.isEmpty ? "Nothing in focus" : open[0].title)
            startButton.setTitleText("Start")
            startButton.isEnabled = true
            resetButton.isEnabled = false
            doneButton.isEnabled = false
        }
        for b in [startButton, resetButton, doneButton] { b.needsDisplay = true }
        for row in rows where row.selected {
            if let t = store.focus { row.set(trailing: TaskTime.rowText(t, spent: store.spent(t), focus: true)) }
        }
    }

    // MARK: Actions

    /// Start / Pause / Resume: the focused task's clock, or the first open task when none is.
    @objc private func startTapped() {
        if store.focus != nil {
            let wasRunning = store.isRunning
            store.togglePause()
            if !wasRunning { SoundService.shared.play(.timerSet) }
            return
        }
        guard let first = store.open.first else {
            say?("Pick something to focus on ✨", .thinking)
            window?.makeFirstResponder(field)
            return
        }
        focus(on: first)
    }

    /// Focus moves to this task (tap on a row): starts it, or pauses / resumes the one in focus.
    private func focus(on t: FocusTask) {
        let starting = !(t.id == store.focusID && store.isRunning)
        store.focusOn(t.id)
        if starting { SoundService.shared.play(.timerSet) }
    }

    @objc private func resetTapped() {
        guard store.focus != nil else { return }
        if store.isRunning { store.pause() }   // posts `changed`: the ring and rows follow
        FocusSession.reset(store)
        finishedSaid = nil
        refreshRing(animated: true)
    }

    @objc private func doneTapped() {
        guard let f = store.focus else { return }
        store.toggleDone(f.id)
        finishedSaid = nil
        say?("\(f.title) — done ✓", .happy)
    }

    /// A preset chip: the session length; a focused task with no estimate takes it as its own.
    private func pick(_ preset: FocusPreset) {
        FocusPreset.current = preset
        customField.isHidden = preset.chipIndex != 3
        if preset.chipIndex == 3 { customField.stringValue = "\(FocusPreset.customMinutes)" }
        if let f = store.focus, f.estimate == 0 {
            store.rename(f.id, to: "\(f.title) \(preset.minutes)m")   // posts `changed`
        } else {
            refreshRing(animated: true)
        }
        needsLayout = true
    }

    private func commitCustom() {
        let n = Int(customField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        guard n > 0 else { customField.stringValue = "\(FocusPreset.customMinutes)"; NSSound.beep(); return }
        pick(.custom(n))
        window?.makeFirstResponder(field)
    }

    private func submit() {
        guard let t = store.add(field.stringValue, focus: true, project: store.shownProject) else { NSSound.beep(); return }
        field.stringValue = ""
        SoundService.shared.play(.timerSet)
        say?("Focusing on \(t.title)", .focused)
    }

    // ⏎ in the add field adds and focuses; in the custom field it sets the length. Esc clears, then closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if control === customField { commitCustom() } else { submit() }
            return true
        case #selector(NSResponder.insertTab(_:)):
            if control === field { submit(); return true }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            if control === customField { customField.stringValue = "\(FocusPreset.customMinutes)"; window?.makeFirstResponder(field); return true }
            if field.stringValue.isEmpty { onEscape?() } else { field.stringValue = "" }
            return true
        default: return false
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutHeader()
        let top = headerBottom
        let bottom = min(bounds.height, top + Self.content) - Space.l

        // Left: the ring, the transport under it, then the presets.
        let leftX = pad
        let ringSize = FocusTimerRing.size
        ring.frame = NSRect(x: leftX + (Self.leftWidth - ringSize) / 2, y: top - 4, width: ringSize, height: ringSize)
        let bw = [startButton, resetButton, doneButton].map { max($0.fittedWidth, 72) }
        let tw = bw.reduce(0, +) + Space.s * 2
        var bx = leftX + ((Self.leftWidth - tw) / 2).rounded()
        let by = ring.frame.maxY + Space.m
        for (i, b) in [startButton, resetButton, doneButton].enumerated() {
            b.frame = NSRect(x: bx, y: by, width: bw[i], height: Metrics.button)
            bx += bw[i] + Space.s
        }
        let cy = by + Metrics.button + Space.m
        let customW: CGFloat = customField.isHidden ? 0 : 56 + Space.s
        let cw = min(chips.preferredWidth, Self.leftWidth - customW)
        let cx = leftX + ((Self.leftWidth - cw - customW) / 2).rounded()
        chips.frame = NSRect(x: cx, y: cy, width: cw, height: Metrics.chip)
        customField.frame = NSRect(x: chips.frame.maxX + Space.s, y: cy, width: 56, height: Metrics.chip)

        // Right: Up next, the list, the add field, the day's numbers.
        let rx = pad + Self.leftWidth + Self.gutter
        let rw = max(0, bounds.width - pad - rx)
        upNext.frame = NSRect(x: rx, y: top, width: rw, height: 18)
        stats.frame = NSRect(x: rx, y: bottom - 16, width: rw, height: 16)
        let fieldH: CGFloat = Metrics.field
        let fy = stats.frame.minY - Space.s - fieldH
        fieldBox.frame = NSRect(x: rx, y: fy, width: rw, height: fieldH)
        field.frame = NSRect(x: rx + 32, y: fy + (fieldH - 20) / 2, width: max(0, rw - 32 - 44), height: 20)
        let listTop = upNext.frame.maxY + Space.s
        let listH = max(0, fy - Space.m - listTop)
        scroll.frame = NSRect(x: rx, y: listTop, width: rw, height: min(listH, listHeight))
        doc.frame.size.width = rw
        for r in rows { r.frame.size.width = rw }
        emptyLabel.frame = NSRect(x: rx + Space.xs, y: listTop + Space.s, width: rw - Space.s, height: 40)
    }
}

// MARK: - The notch instrument

extension FocusView {
    /// The Focus node's live ring while a session runs: how far through the target, and the
    /// minutes left inside it (green once the target is met). Nil when nothing runs.
    static func instrument(now: Date = Date()) -> IslandInstrument? {
        let store = TaskStore.shared
        FocusSession.activate()
        guard store.isRunning, let r = FocusSession.reading(store) else { return nil }
        let mins = Int(ceil(r.remaining / 60))
        return IslandInstrument(progress: CGFloat(r.progress), text: r.finished ? "✓" : "\(mins)m", tone: r.finished ? Neon.green : nil)
    }
}
