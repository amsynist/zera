import AppKit

// MARK: - Tasks: the notch screen, the focus orb and its card, quick add, export
//
//   notch tab  Tasks    → Today: add field, to-dos with ▶, done, Hide orb · Export…
//   screen edge  (◎)    → the orb: one outer segment per task (mint done, blue in focus), an
//                         inner arc for time against the estimate, the clock in the middle.
//                         Click: it opens into the focus card right where it floats.
//   ⌥⌘T                 → a quick-add capsule slides out of the orb.

enum TasksSettings {
    private static let orbKey = "tasks.orb"
    private static let orbLeftKey = "tasks.orb.left"
    private static let orbYKey = "tasks.orb.y"
    /// The orb on the screen edge (shown while there are tasks).
    static var orb: Bool {
        get { UserDefaults.standard.object(forKey: orbKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: orbKey) }
    }
    static var orbOnLeft: Bool {
        get { UserDefaults.standard.bool(forKey: orbLeftKey) }
        set { UserDefaults.standard.set(newValue, forKey: orbLeftKey) }
    }
    /// How far up the edge it sits, 0 (bottom) to 1 (top).
    static var orbY: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: orbYKey) as? Double ?? 0.32) }
        set { UserDefaults.standard.set(Double(newValue), forKey: orbYKey) }
    }
    static let defaultShortcut = HotKeyShortcut(keyCode: 17, modifiers: UInt32(256 | 2048), key: "T")   // ⌥⌘T
}

enum TaskTime {
    /// "04:10", "1:02:10".
    static func clock(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
    /// "24m", "1h 05m".
    static func short(_ s: TimeInterval) -> String { TaskExport.duration(Int((s / 60).rounded())) }

    /// What a row shows on its right: time spent, against the estimate (when there is one) while it's open.
    static func rowText(_ t: FocusTask, spent: TimeInterval, focus: Bool) -> String {
        if t.done { return short(spent) }
        let est = t.estimate > 0 ? " / \(t.estimate)m" : ""
        if focus { return clock(spent) + est }
        if spent >= 60 { return short(spent) + est }
        return t.estimate > 0 ? "\(t.estimate)m" : ""
    }
}

// MARK: - The ring

enum FocusRing {
    enum Segment { case done, focus, open }

    /// One per task on today's list: finished ones first, then the one in focus, then the rest.
    static func segments(_ store: TaskStore) -> [Segment] {
        let today = store.today
        let done = today.filter(\.done).count
        let focus = store.focus == nil ? 0 : 1
        return Array(repeating: .done, count: done) + Array(repeating: .focus, count: focus)
            + Array(repeating: .open, count: today.count - done - focus)
    }

    /// An arc from `a0` to `a1` degrees, clockwise from 12 o'clock, in a flipped view.
    static func arc(_ c: NSPoint, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let steps = max(2, Int(abs(a1 - a0) / 3))
        for i in 0...steps {
            let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)) * .pi / 180
            let pt = NSPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
            i == 0 ? p.move(to: pt) : p.line(to: pt)
        }
        return p
    }

    /// The two rings: task segments outside, the focus session (against its estimate) inside.
    static func draw(center c: NSPoint, outer: CGFloat, outerWidth: CGFloat, inner: CGFloat, innerWidth: CGFloat,
                     segments: [Segment], progress: Double, pulse: Bool = false, track: Bool = false) {
        let n = max(1, segments.count)
        let span = 360 / CGFloat(n)
        let gap = n > 1 ? min(14, span * 0.3) : 0
        if segments.isEmpty {
            let p = arc(c, outer, 0, 359.9)
            p.lineWidth = outerWidth
            (track ? NSColor.white.withAlphaComponent(0.12) : Neon.chipEdge.withAlphaComponent(0.35)).setStroke(); p.stroke()
        }
        for (i, s) in segments.enumerated() {
            let p = arc(c, outer, CGFloat(i) * span + gap / 2, CGFloat(i + 1) * span - gap / 2)
            p.lineWidth = outerWidth
            p.lineCapStyle = .round
            switch s {
            case .done: Neon.green.setStroke(); p.stroke()
            case .open: (track ? NSColor.white.withAlphaComponent(0.18) : Neon.textFaint.withAlphaComponent(0.55)).setStroke(); p.stroke()
            case .focus: Neon.glowing(Neon.cyan, blur: 4) { Neon.cyan.withAlphaComponent(pulse ? 0.55 : 1).setStroke(); p.stroke() }
            }
        }
        guard inner > 0 else { return }
        let tr = arc(c, inner, 0, 359.9)
        tr.lineWidth = innerWidth
        (track ? NSColor.white.withAlphaComponent(0.14) : Neon.cyan.withAlphaComponent(0.14)).setStroke(); tr.stroke()
        if progress > 0.002 {
            let p = arc(c, inner, 0, 360 * CGFloat(min(1, progress)))
            p.lineWidth = innerWidth
            p.lineCapStyle = .round
            let col = progress > 1 ? Neon.warning : Neon.cyan
            Neon.glowing(col, blur: 5) { col.setStroke(); p.stroke() }
        }
    }
}

// MARK: - Small pieces

/// Paints with a closure and lets clicks fall through.
final class TaskPaint: NSView {
    var paint: ((NSRect) -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { paint?(bounds) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private func drawText(_ s: String, _ font: NSFont, _ color: NSColor, in r: NSRect, align: NSTextAlignment = .left,
                      strike: Bool = false, kern: CGFloat = 0) {
    let ps = NSMutableParagraphStyle()
    ps.alignment = align
    ps.lineBreakMode = .byTruncatingTail
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: ps]
    if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attrs[.strikethroughColor] = color }
    if kern != 0 { attrs[.kern] = kern }
    let h = ceil(font.ascender - font.descender + font.leading)
    NSAttributedString(string: s, attributes: attrs).draw(with: NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h),
                                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

private let monoFont = { (size: CGFloat, w: NSFont.Weight) in NSFont.monospacedDigitSystemFont(ofSize: size, weight: w) }

/// The orb's numbers: DIN Alternate, square and sharp, with every digit the same width so a
/// ticking clock doesn't jiggle.
enum TaskFont {
    static func clock(_ size: CGFloat) -> NSFont {
        NSFont(name: "DINAlternate-Bold", size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }
}

/// Draws `s` centred on `x`, with its capitals' middle on `capMid`, so lines centre by what you see.
private func drawCap(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, capMid: CGFloat, kern: CGFloat = 0) {
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if kern != 0 { attrs[.kern] = kern }
    let a = NSAttributedString(string: s, attributes: attrs)
    // Kerning adds space after the last letter too: leave it out of the width.
    let w = a.size().width - kern
    a.draw(at: NSPoint(x: x - w / 2, y: capMid + font.capHeight / 2 - font.ascender))
}
private let sectionFont = Typo.sectionLabel

/// A borderless text field in the navy look, with a cyan caret.
final class TaskField: NSTextField {
    init(placeholder: String, size: CGFloat) {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: size, weight: .medium)
        textColor = Neon.text
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .regular), .foregroundColor: Neon.textDim.withAlphaComponent(0.8)])
        setAccessibilityLabel("New task")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        (currentEditor() as? NSTextView)?.insertionPointColor = Neon.cyan
        return ok
    }
}

/// A task in a list: ○ title · time ▶. The circle finishes it, ▶ focuses on it (⏸ pauses).
final class TaskRowView: NSView {
    static let height: CGFloat = 40
    /// v2: rows in the Tasks lens are filled cards, a little taller, with a gap between them.
    static let cardHeight: CGFloat = 50
    static let cardGap: CGFloat = 8
    var carded = false { didSet { needsDisplay = true } }
    private var inset: CGFloat { carded ? 16 : 10 }
    private(set) var task: FocusTask
    var isFocus = false { didSet { needsDisplay = true } }
    var running = false { didSet { needsDisplay = true } }
    var spent: TimeInterval = 0 { didSet { needsDisplay = true } }
    var onToggle: (() -> Void)?
    var onFocus: (() -> Void)?
    var onDelete: (() -> Void)?
    /// Its project, shown as a small tag (when the list mixes projects).
    var projectTag: String? { didSet { needsDisplay = true } }
    /// Projects it can move to, from the right-click menu.
    var projects: [String] = []
    var onMove: ((String) -> Void)?
    /// A commit-made task: a click opens its commits underneath.
    var onExpand: (() -> Void)? { didSet { toolTip = onExpand == nil ? toolTip : "Click to see what was done" } }
    var expanded = false { didSet { needsDisplay = true } }
    /// In a look back (Week, Month) done is a given: no strike-through, full-strength text.
    var history = false { didSet { needsDisplay = true } }
    /// Read live while drawing, so rows a scroll moved under the pointer don't stay lit.
    private var hovered: Bool { isPointerInside }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(_ task: FocusTask) {
        self.task = task
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(task.title + (task.done ? ", done" : "") + (task.fromCommits ? ", from commits" : ""))
        if let c = task.commits, !c.isEmpty { toolTip = "Made from \(c.count) commit\(c.count == 1 ? "" : "s")" }
    }
    required init?(coder: NSCoder) { fatalError() }

    var checkRect: NSRect { NSRect(x: inset, y: (bounds.height - 20) / 2, width: 20, height: 20) }
    var playRect: NSRect { NSRect(x: bounds.width - 28 - (carded ? 12 : 8), y: (bounds.height - 28) / 2, width: 28, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: carded ? Radius.l : 10, yRadius: carded ? Radius.l : 10)
        if carded {
            (hovered && !isFocus ? Neon.chipHover : Neon.row).setFill(); bg.fill()
        }
        if isFocus {
            Neon.accent.withAlphaComponent(0.12).setFill(); bg.fill()
            Neon.accent.withAlphaComponent(0.45).setStroke(); bg.lineWidth = 1; bg.stroke()
        } else if hovered && !carded {
            Neon.chipHover.withAlphaComponent(0.6).setFill(); bg.fill()
        }
        // The circle.
        let cr = checkRect.insetBy(dx: 0.8, dy: 0.8)
        let circle = NSBezierPath(ovalIn: cr)
        if task.done {
            Neon.green.setFill(); circle.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: cr.minX + 5, y: cr.midY + 0.5))
            tick.line(to: NSPoint(x: cr.minX + 8.2, y: cr.midY + 3.6))
            tick.line(to: NSPoint(x: cr.maxX - 4.6, y: cr.midY - 3.2))
            tick.lineWidth = 2.2; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
            Neon.fillBottom.withAlphaComponent(1).setStroke(); tick.stroke()
        } else {
            circle.lineWidth = 1.6
            (hovered ? Neon.accent : Neon.textDim.withAlphaComponent(0.8)).setStroke(); circle.stroke()
        }
        // Time, then the title in what's left.
        let time = TaskTime.rowText(task, spent: spent, focus: isFocus)
        let tf = monoFont(11.5, .medium)
        let tw = ceil((time as NSString).size(withAttributes: [.font: tf]).width)
        let right = task.done ? bounds.width - (carded ? 18 : 12) : playRect.minX - 10
        drawText(time, tf, isFocus ? Neon.cyan : Neon.textDim, in: NSRect(x: right - tw, y: 0, width: tw, height: bounds.height))
        var titleRight = right - tw - 10
        if task.fromCommits {
            // Made from commits: a small branch, its hashes in the tooltip.
            Neon.symbol(expanded ? "chevron.down" : "arrow.triangle.branch", in: NSRect(x: titleRight - 14, y: 0, width: 14, height: bounds.height),
                        size: expanded ? 9 : 10, color: expanded ? Neon.cyan : Neon.glyph.withAlphaComponent(0.75))
            titleRight -= 22
        }
        if !task.repos.isEmpty {
            // Where it came from: the repo (and how many more), in a cyan capsule.
            let rs = task.repos
            let label = rs[0] + (rs.count > 1 ? " +\(rs.count - 1)" : "")
            let f = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            let w = min(150, ceil((label as NSString).size(withAttributes: [.font: f]).width) + 14)
            let r = NSRect(x: titleRight - w, y: (bounds.height - 18) / 2, width: w, height: 18)
            let p = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            Neon.cyan.withAlphaComponent(0.1).setFill(); p.fill()
            Neon.cyan.withAlphaComponent(0.35).setStroke(); p.lineWidth = 1; p.stroke()
            drawText(label, f, Neon.cyan.withAlphaComponent(0.95), in: r.insetBy(dx: 7, dy: 0), align: .center)
            titleRight = r.minX - 6
        }
        if let tag = projectTag, carded {
            // v2: the project as a glowing dot and its name.
            let f = NSFont.systemFont(ofSize: 12, weight: .medium)
            let w = min(130, ceil((tag as NSString).size(withAttributes: [.font: f]).width))
            let tx = titleRight - w - 4
            drawText(tag, f, Neon.textDim.withAlphaComponent(task.done ? 0.6 : 1), in: NSRect(x: tx, y: 0, width: w, height: bounds.height))
            let dot = NSRect(x: tx - 12, y: bounds.height / 2 - 3, width: 6, height: 6)
            Neon.glowing(Neon.violet.withAlphaComponent(0.8), blur: 5) { Neon.violet.setFill(); NSBezierPath(ovalIn: dot).fill() }
            titleRight = dot.minX - 12
        } else if let tag = projectTag {
            // A small capsule left of the time.
            let f = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            let w = min(110, ceil((tag as NSString).size(withAttributes: [.font: f]).width) + 14)
            let r = NSRect(x: titleRight - w, y: (bounds.height - 18) / 2, width: w, height: 18)
            let p = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            Neon.violet.withAlphaComponent(0.14).setFill(); p.fill()
            Neon.violet.withAlphaComponent(0.4).setStroke(); p.lineWidth = 1; p.stroke()
            drawText(tag, f, (Neon.violet.blended(withFraction: 0.45, of: .white) ?? Neon.violet).withAlphaComponent(task.done ? 0.6 : 1),
                     in: r.insetBy(dx: 7, dy: 0), align: .center)
            titleRight = r.minX - 8
        }
        let tx = checkRect.maxX + (carded ? 14 : 10)
        drawText(task.title, carded ? Typo.rowTitle : .systemFont(ofSize: 13.5, weight: .medium), task.done && !history ? Neon.textDim.withAlphaComponent(0.75) : Neon.text,
                 in: NSRect(x: tx, y: 0, width: max(0, titleRight - tx), height: bounds.height), strike: task.done && !history)
        guard !task.done else { return }
        let pr = playRect.insetBy(dx: 0.5, dy: 0.5)
        let pp = NSBezierPath(roundedRect: pr, xRadius: 8, yRadius: 8)
        (isFocus ? Neon.accent.withAlphaComponent(0.2) : Neon.chip).setFill(); pp.fill()
        (isFocus ? Neon.accent.withAlphaComponent(0.7) : Neon.chipEdge).setStroke(); pp.lineWidth = 1; pp.stroke()
        Neon.symbol(isFocus && running ? "pause.fill" : "play.fill", in: pr, size: 10, color: isFocus ? Neon.text : Neon.glyph)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if checkRect.insetBy(dx: -8, dy: -8).contains(p) { onToggle?() }
        else if let e = onExpand, task.done { e() }
        else if !task.done, playRect.insetBy(dx: -4, dy: -4).contains(p) || event.clickCount == 2 { onFocus?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        var m: [NeonMenuItem] = []
        if !task.done {
            m.append(.action(isFocus && running ? "Pause" : "Focus on This", isFocus && running ? "pause.fill" : "play.fill") { [weak self] in self?.onFocus?() })
        }
        m.append(.action(task.done ? "Mark as Not Done" : "Mark as Done", task.done ? "arrow.uturn.backward" : "checkmark.circle") { [weak self] in self?.onToggle?() })
        if projects.count > 1 {
            m.append(.separator)
            m.append(.header("MOVE TO"))
            for p in projects {
                m.append(.action(p, "folder", checked: p == projectTag) { [weak self] in self?.onMove?(p) })
            }
        }
        if let c = task.commits, !c.isEmpty {
            m.append(.separator)
            m.append(.info("Made from \(c.count) commit\(c.count == 1 ? "" : "s")", "arrow.triangle.branch"))
        }
        m.append(.separator)
        m.append(.action("Delete", "trash", destructive: true) { [weak self] in self?.onDelete?() })
        NeonMenu.shared.show(m)
    }
    override func accessibilityPerformPress() -> Bool { onFocus?(); return true }
}

/// Room around each tasks window's glass for its glow to fade out completely, so the window's
/// edge never shows as a hard square.
enum TaskGlow { static let margin: CGFloat = 56 }

/// The rounded glass behind each tasks window, with room around it for the glow.
private func glassRoot(_ root: NSView, margin: CGFloat, radius: CGFloat) -> OpenerGlass {
    let g = OpenerGlass(frame: root.bounds.insetBy(dx: margin, dy: margin))
    g.radius = radius
    g.glow = 0.5
    g.autoresizingMask = [.width, .height]
    root.addSubview(g)
    return g
}

// MARK: - The Tasks screen (a tab right of the notch)

/// Today's list in the island: an add field, what's left (▶ to focus), what's done, and the
/// orb and export buttons along the bottom.
final class TasksCard: CardBase, CardContent, NSTextFieldDelegate {
    var cardWidth: CGFloat { Isle.lensWidth }
    private let store: TaskStore
    var onExport: (() -> Void)?
    var onToggleOrb: (() -> Void)?
    var onAdded: ((FocusTask, Bool) -> Void)?
    /// Pick a folder for a project (the controller shows the panel).
    var onLinkFolder: ((String) -> Void)?
    var onSync: ((String?) -> Void)?
    var onRebuild: ((String, Int) -> Void)?
    var shortcutLabel: String? = TasksSettings.defaultShortcut.label { didSet { hints.needsDisplay = true } }
    var orbShown = true { didSet { orbButton.title = orbShown ? "Hide orb" : "Show orb"; needsLayout = true } }

    let projectBar = ProjectBar()
    /// Today · Week · Month: how far back the Done list goes.
    private var spanChoices: [TaskChoice] = []
    private lazy var spanIndicator = SlidingIndicator(view: spanTrack)
    private let spanTrack = TaskPaint()
    private var viewSpan: TaskViewSpan = TaskViewSpan(rawValue: UserDefaults.standard.integer(forKey: "tasks.viewSpan")) ?? .today {
        didSet { UserDefaults.standard.set(viewSpan.rawValue, forKey: "tasks.viewSpan") }
    }
    /// Commit tasks opened to show their commits.
    private var expanded = Set<UUID>()
    private let fieldBox = TaskPaint()
    let field = TaskField(placeholder: "Add a task… try “Write docs 30m”", size: 14)
    private let hints = TaskPaint()
    /// Right of Zera in the header: time focused today.
    private let total = TaskPaint()
    private let scroll = NSScrollView()
    private let doc = OpenerFlipped()
    private(set) var rows: [TaskRowView] = []
    private let footLine = TaskPaint()
    private let orbButton = TreeButton()
    private let exportButton = TreeButton()
    private var listHeight: CGFloat = 0

    private let pad: CGFloat = Metrics.sidePad, barH: CGFloat = ProjectBar.height + 12, fieldH: CGFloat = 42, hintH: CGFloat = 30, footH: CGFloat = 58

    init(store: TaskStore) {
        self.store = store
        super.init(width: 560, title: "Tasks")
        projectBar.onSelect = { [weak self] p in self?.store.shownProject = p }
        projectBar.switches = { [weak self] in self.map { [$0.scroll] } ?? [] }
        projectBar.onCreate = { [weak self] name in
            guard let self = self else { return }
            self.store.shownProject = self.store.addProject(name)
        }
        projectBar.onRename = { [weak self] old, new in self?.store.renameProject(old, to: new) ?? false }
        projectBar.onDelete = { [weak self] p in self?.store.deleteProject(p) }
        projectBar.onSetDefault = { [weak self] p in self?.store.setDefaultProject(p) }
        projectBar.onLink = { [weak self] p in self?.onLinkFolder?(p) }
        projectBar.onUnlink = { [weak self] p in self?.store.unlink(p) }
        projectBar.onSync = { [weak self] p in self?.onSync?(p) }
        projectBar.onRebuild = { [weak self] p, days in self?.onRebuild?(p, days) }
        addSubview(projectBar)
        spanTrack.paint = { [weak self] r in
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.m + 2, yRadius: Radius.m + 2)
            Neon.chip.setFill(); p.fill()
            Neon.divider.setStroke(); p.lineWidth = 1; p.stroke()
            guard let self = self else { return }
            drawTrackIndicator(self.spanIndicator, under: self.spanChoices.first { $0.selected }, in: self.spanTrack)
        }
        addSubview(spanTrack)
        for v in TaskViewSpan.allCases {
            let c = TaskChoice(v.title)
            c.drawsSelection = false
            c.onClick = { [weak self] in
                guard let self = self, self.viewSpan != v else { return }
                let old = self.viewSpan.rawValue
                self.viewSpan = v
                let h = self.desiredHeight
                self.reload()
                self.scroll.contentView.scroll(to: .zero)
                if self.desiredHeight != h { self.onHeightChange?() }
                Motion.tabSwitch([self.scroll], from: old, to: v.rawValue)
            }
            spanChoices.append(c)
            addSubview(c)
        }
        fieldBox.paint = { r in
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            Neon.accent.withAlphaComponent(0.08).setFill(); p.fill()
            Neon.accent.withAlphaComponent(0.5).setStroke(); p.lineWidth = 1; p.stroke()
            Neon.symbol("plus", in: NSRect(x: 4, y: 0, width: 28, height: r.height), size: 13, weight: .bold, color: Neon.cyan)
            let k = NSRect(x: r.width - 34, y: (r.height - 20) / 2, width: 24, height: 20)
            let kp = NSBezierPath(roundedRect: k, xRadius: 5, yRadius: 5)
            Neon.chipEdge.setStroke(); kp.lineWidth = 1; kp.stroke()
            drawText("⏎", monoFont(11, .medium), Neon.glyph, in: k, align: .center)
        }
        addSubview(fieldBox)
        field.delegate = self
        addSubview(field)
        hints.paint = { [weak self] r in
            let c = Neon.textDim.withAlphaComponent(0.85), f = NSFont.systemFont(ofSize: 11.5)
            drawText("⇥ add and focus · #name picks a project · double-click to focus", f, c, in: NSRect(x: 4, y: 0, width: r.width * 0.7, height: r.height))
            if let k = self?.shortcutLabel {
                drawText("\(k) from anywhere", f, c, in: NSRect(x: r.width * 0.6, y: 0, width: r.width * 0.4 - 4, height: r.height), align: .right)
            }
        }
        addSubview(hints)
        total.paint = { [weak self] r in
            guard let self = self else { return }
            if let (name, p) = self.syncShown {
                // Syncing: name, a bar, and where it's got to, in the header's right side.
                drawText("Syncing \(name)", .systemFont(ofSize: 12.5, weight: .semibold), Neon.text, in: NSRect(x: 0, y: 0, width: r.width, height: 16), align: .right)
                SyncRing.bar(NSRect(x: r.width - 132, y: 21, width: 132, height: 4), progress: p.fraction, spin: self.spin)
                let detail = p.total > 0 ? "\(p.stage) · \(p.done) of \(p.total)" : p.stage + "…"
                drawText(detail, .systemFont(ofSize: 11), Neon.textDim, in: NSRect(x: 0, y: 28, width: r.width, height: 14), align: .right)
                return
            }
            drawText(TaskTime.short(self.store.focusedToday), .monospacedDigitSystemFont(ofSize: 24, weight: .bold), Neon.text, in: NSRect(x: 0, y: 0, width: r.width, height: 30), align: .right)
            drawText("focused today", .systemFont(ofSize: 11.5), Neon.textDim, in: NSRect(x: 0, y: 31, width: r.width, height: 14), align: .right)
        }
        addSubview(total)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.documentView = doc
        // Rows read the pointer while drawing; scrolling redraws them so none stays lit.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        addSubview(scroll)
        footLine.paint = { r in Neon.divider.setFill(); r.fill() }
        addSubview(footLine)
        orbButton.title = "Hide orb"
        orbButton.key = "⌘O"
        orbButton.onClick = { [weak self] in self?.onToggleOrb?() }
        exportButton.title = "Export…"
        exportButton.symbol = "square.and.arrow.up"
        exportButton.key = "⌘E"
        exportButton.primary = true
        exportButton.onClick = { [weak self] in self?.onExport?() }
        addSubview(orbButton)
        addSubview(exportButton)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: TaskStore.changed, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(storeTicked), name: TaskStore.ticked, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(syncChanged), name: TaskGitSync.progressChanged, object: nil)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var listTop: CGFloat { headerBottom + barH + fieldH + hintH }
    private var maxList: CGFloat { Isle.maxContentHeight - listTop - 6 - footH }

    var desiredHeight: CGFloat { listTop + min(listHeight, maxList) + 6 + footH }

    func willShow() {
        field.stringValue = ""
        onSync?(nil)   // linked folders catch up (quietly: at most every 10 minutes)
        reload()
        scroll.contentView.scroll(to: .zero)
    }

    @objc private func storeChanged() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        let h = desiredHeight
        reload()
        if desiredHeight != h { onHeightChange?() }
    }

    /// A second went by: only the clocks change.
    @objc private func storeTicked() {
        guard window?.isVisible == true else { return }
        for r in rows where r.isFocus { r.spent = store.spent(r.task) }
        updateSubtitle()
    }

    // MARK: Sync progress

    private var spin: CGFloat = 0
    private var spinTimer: Timer?

    deinit { spinTimer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncChanged()
    }

    /// The sync to show in the header: the shown project's, else any.
    private var syncShown: (String, SyncProgress)? {
        let all = TaskGitSync.shared.progress
        if let p = store.shownProject { return all[p].map { (p, $0) } }
        return all.sorted { $0.key < $1.key }.first.map { ($0.key, $0.value) }
    }

    @objc private func syncChanged() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            spinTimer?.invalidate(); spinTimer = nil
            return
        }
        let all = TaskGitSync.shared.progress
        projectBar.syncing = all
        total.isHidden = syncShown == nil && store.focusedToday < 60
        total.needsDisplay = true
        // The ring and bar move while something syncs (only then: no timer otherwise).
        if all.isEmpty { spinTimer?.invalidate(); spinTimer = nil }
        else if spinTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self = self, self.window?.isVisible == true else { return }
                self.spin += 0.035
                self.projectBar.spin = self.spin
                self.total.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            spinTimer = t
        }
    }

    @objc private func listScrolled() {
        func redraw(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(redraw) }
        redraw(doc)
    }

    private func updateSubtitle() {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        spanChoices.enumerated().forEach { $1.selected = TaskViewSpan.allCases[$0] == viewSpan }
        if let c = spanChoices.first(where: { $0.selected }), spanTrack.frame.width > 0 {
            spanIndicator.move(to: spanTrack.convert(c.frame, from: c.superview), animated: true)
        }
        spanTrack.needsDisplay = true
        if viewSpan == .today {
            let list = store.today(in: store.shownProject)
            setSubtitle("\(f.string(from: store.now())) · \(list.filter(\.done).count) of \(list.count) done")
        } else {
            let since = viewSpan.since(store), shown = store.shownProject
            let done = store.tasks.filter { t in (t.doneAt.map { $0 >= since } ?? false) && (shown == nil || store.project(of: t) == shown) }
            let secs = done.reduce(0) { $0 + $1.spent }
            setSubtitle("\(viewSpan == .week ? "Last 7 days" : "Last 30 days") · \(done.count) done · \(TaskTime.short(secs))")
        }
        // v2: the day's focus total always sits right of Zera ("0m focused today").
        total.isHidden = viewSpan != .today && syncShown == nil
        total.needsDisplay = true
    }

    /// Rebuilds the rows from the store.
    func reload() {
        doc.subviews.forEach { $0.removeFromSuperview() }
        rows = []
        let w = cardWidth - pad * 2
        var y: CGFloat = 0
        func section(_ t: String, _ right: String? = nil) {
            let l = TaskPaint(frame: NSRect(x: 0, y: y, width: w, height: 30))
            l.paint = { r in
                drawText(t, sectionFont, Neon.textDim, in: NSRect(x: 4, y: 6, width: r.width - 8, height: 18), kern: Typo.sectionKern)
                // A day's total reads as a time ("2h 00m"), not as part of the label.
                if let right = right { drawText(right, monoFont(11.5, .medium), Pal.textSecondary, in: NSRect(x: 4, y: 6, width: r.width - 22, height: 18), align: .right) }
            }
            doc.addSubview(l)
            y += 30
        }
        let shown = store.shownProject
        let mine = { (t: FocusTask) in shown == nil || self.store.project(of: t) == shown }
        let open = store.open.filter(mine)
        // Done: today's, or (Week, Month) every day in that span, newest day first.
        let since = viewSpan.since(store)
        let done = (viewSpan == .today ? store.doneToday : store.tasks.filter { t in t.doneAt.map { $0 >= since } ?? false })
            .filter(mine).sorted { $0.doneAt! > $1.doneAt! }
        projectBar.projects = store.projects
        projectBar.defaultProject = store.defaultProject
        projectBar.linked = store.links.mapValues(\.paths)
        projectBar.syncing = TaskGitSync.shared.progress
        projectBar.selected = shown
        let target = shown ?? store.defaultProject
        field.placeholderAttributedString = NSAttributedString(string: "Add to \(target)… try “Write docs 30m”", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: Neon.textDim.withAlphaComponent(0.8)])
        // Week and Month look back at what got done; to-dos live in Today.
        if viewSpan == .today { section("TO DO · \(open.count)") }
        if viewSpan == .today, open.isEmpty {
            let l = TaskPaint(frame: NSRect(x: 0, y: y, width: w, height: 36))
            let empty = shown.map { "Nothing to do in \($0). Add one above ✨" } ?? "Nothing to do. Add one above ✨"
            l.paint = { r in drawText(empty, .systemFont(ofSize: 12.5), Neon.textDim, in: NSRect(x: 10, y: 0, width: r.width - 20, height: r.height)) }
            doc.addSubview(l)
            y += 36
        }
        if viewSpan == .today { for t in open { add(t, w, &y) } }
        if viewSpan == .today {
            if !done.isEmpty {
                section("DONE · \(done.count)")
                for t in done.reversed() { add(t, w, &y) }
            }
        } else {
            let f = DateFormatter()
            f.dateFormat = "EEE d MMM"
            let byDay = Dictionary(grouping: done) { store.calendar.startOfDay(for: $0.doneAt!) }
            if done.isEmpty {
                section("DONE")
                let l = TaskPaint(frame: NSRect(x: 0, y: y, width: w, height: 36))
                let what = viewSpan == .week ? "in the last 7 days" : "in the last 30 days"
                l.paint = { r in drawText("Nothing done \(what) yet.", .systemFont(ofSize: 12.5), Neon.textDim, in: NSRect(x: 10, y: 0, width: r.width - 20, height: r.height)) }
                doc.addSubview(l)
                y += 36
            }
            for day in byDay.keys.sorted(by: >) {
                let list = byDay[day]!.sorted { $0.doneAt! < $1.doneAt! }
                let key = store.dayKey(day)
                let secs = list.reduce(0) { $0 + ($1.log[key] ?? $1.spent) }
                section(f.string(from: day).uppercased() + " · \(list.count) TASK\(list.count == 1 ? "" : "S")", TaskTime.short(secs))
                for t in list { add(t, w, &y) }
            }
        }
        listHeight = y + 6
        doc.frame = NSRect(x: 0, y: 0, width: w, height: listHeight)
        updateSubtitle()
        needsLayout = true
    }

    /// "aurora-api · 5b62e36 · feat: shorten session expiry" → "Shorten session expiry":
    /// just what was done.
    static func whatWasDone(_ note: String) -> String {
        let parts = note.components(separatedBy: " · ")
        let subject = parts.count >= 3 ? parts.dropFirst(2).joined(separator: " · ") : (parts.count == 2 ? parts[1] : note)
        return GitCommits.title(fromSubject: subject)
    }

    private func add(_ t: FocusTask, _ w: CGFloat, _ y: inout CGFloat) {
        let r = TaskRowView(t)
        r.carded = true
        r.frame = NSRect(x: 0, y: y, width: w, height: TaskRowView.cardHeight)
        r.isFocus = t.id == store.focusID && !t.done
        r.running = store.isRunning
        r.spent = store.spent(t)
        r.history = viewSpan != .today
        r.onToggle = { [weak self] in self?.store.toggleDone(t.id) }
        r.onFocus = { [weak self] in self?.store.focusOn(t.id) }
        r.onDelete = { [weak self] in self?.store.delete(t.id) }
        // A task made from commits opens to show them: how it was made.
        if t.fromCommits {
            r.onExpand = { [weak self] in
                guard let self = self else { return }
                if self.expanded.contains(t.id) { self.expanded.remove(t.id) } else { self.expanded.insert(t.id) }
                let h = self.desiredHeight
                self.reload()
                if self.desiredHeight != h { self.onHeightChange?() }
            }
            r.expanded = expanded.contains(t.id)
        }
        // Mixed list: each task shows its project.
        if store.shownProject == nil, store.projects.count > 1 { r.projectTag = store.project(of: t) }
        r.projects = store.projects
        r.onMove = { [weak self] p in self?.store.move(t.id, to: p) }
        doc.addSubview(r)
        rows.append(r)
        y += TaskRowView.cardHeight + TaskRowView.cardGap
        if expanded.contains(t.id), let raw = t.commitNotes, !raw.isEmpty {
            let notes = raw.map(Self.whatWasDone)
            let repos = raw.map { n -> String in let p = n.components(separatedBy: " · "); return p.count >= 3 ? p[0] : "" }
            let h = CGFloat(notes.count) * 20 + 12
            let box = TaskPaint(frame: NSRect(x: 40, y: y, width: w - 52, height: h))
            box.paint = { r in
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                Neon.field.withAlphaComponent(0.9).setFill(); p.fill()
                Neon.chipEdge.withAlphaComponent(0.35).setStroke(); p.lineWidth = 1; p.stroke()
                for (i, n) in notes.enumerated() {
                    let y = 6 + CGFloat(i) * 20
                    let dot = NSBezierPath(ovalIn: NSRect(x: 12, y: y + 8, width: 4, height: 4))
                    Neon.cyan.withAlphaComponent(0.7).setFill(); dot.fill()
                    let repo = repos[i]
                    let rf = NSFont.systemFont(ofSize: 11, weight: .medium)
                    let rw = repo.isEmpty ? 0 : min(170, ceil((repo as NSString).size(withAttributes: [.font: rf]).width))
                    drawText(n, .systemFont(ofSize: 12), Neon.text.withAlphaComponent(0.85),
                             in: NSRect(x: 24, y: y, width: r.width - 44 - rw, height: 20))
                    if rw > 0 { drawText(repo, rf, Neon.cyan.withAlphaComponent(0.7), in: NSRect(x: r.width - 10 - rw, y: y, width: rw, height: 20), align: .right) }
                }
            }
            doc.addSubview(box)
            y += h + 6
        }
    }

    override func layout() {
        super.layout()
        layoutHeader()
        let w = bounds.width
        projectBar.frame = NSRect(x: pad, y: headerBottom, width: w - pad * 2, height: ProjectBar.height)
        let top = headerBottom + barH
        fieldBox.frame = NSRect(x: pad, y: top, width: w - pad * 2, height: fieldH)
        field.frame = NSRect(x: pad + 32, y: top + (fieldH - 20) / 2, width: w - pad * 2 - 32 - 44, height: 20)
        hints.frame = NSRect(x: pad, y: top + fieldH + 6, width: w - pad * 2, height: 18)
        let tr = headerTrailingRect
        total.frame = NSRect(x: tr.maxX - 140, y: tr.midY - 24, width: 140, height: 48)
        scroll.frame = NSRect(x: pad, y: listTop, width: w - pad * 2, height: min(listHeight, maxList))
        let fy = bounds.height - footH
        footLine.frame = NSRect(x: pad, y: fy, width: w - pad * 2, height: 1)
        let ow = orbButton.fittedWidth, ew = exportButton.fittedWidth
        let by = fy + (footH - Metrics.segment) / 2
        orbButton.frame = NSRect(x: pad, y: by, width: ow, height: Metrics.segment)
        exportButton.frame = NSRect(x: w - pad - ew, y: by, width: ew, height: Metrics.segment)
        // Today · Week · Month in the middle of the footer.
        let sw: CGFloat = 196, sh = Metrics.segment, inset = Metrics.segmentInset
        spanTrack.frame = NSRect(x: (w - sw) / 2, y: by, width: sw, height: sh)
        let cw = (sw - inset * 2) / CGFloat(spanChoices.count)
        for (i, c) in spanChoices.enumerated() {
            c.frame = NSRect(x: spanTrack.frame.minX + inset + CGFloat(i) * cw, y: spanTrack.frame.minY + inset, width: cw, height: sh - inset * 2)
        }
    }

    // ⏎ adds, ⇥ adds and focuses, Esc clears the field (then closes).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): submit(focus: false); return true
        case #selector(NSResponder.insertTab(_:)): submit(focus: true); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { onEscape?() } else { field.stringValue = "" }
            return true
        default: return false
        }
    }

    private func submit(focus: Bool) {
        guard let t = store.add(field.stringValue, focus: focus, project: store.shownProject) else { NSSound.beep(); return }
        field.stringValue = ""
        onAdded?(t, focus)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods == .command, window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "e": onExport?(); return true
        case "o": onToggleOrb?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - The orb

final class FocusOrbView: NSView {
    static let size: CGFloat = 124         // the window: the 64 pt orb plus room for its glow
    static let orb: CGFloat = 64
    private let store: TaskStore
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// A drag started (the + steps aside).
    var onDragStart: (() -> Void)?
    private var downAt: NSPoint?
    private var startOrigin: NSPoint = .zero
    private var dragging = false
    private var hovered = false { didSet { needsDisplay = true } }
    private var pulse = false
    /// v2: a glossy core that breathes inside the rings, lit in the focus colour.
    private let coreGlow = CALayer()
    private let core = CAGradientLayer()
    private let pauseGlyph = NSImageView()
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(store: TaskStore) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        toolTip = "Click to open · drag to move · right-click for more"
        core.type = .radial
        core.startPoint = CGPoint(x: 0.35, y: 0.3)
        core.endPoint = CGPoint(x: 1.12, y: 1.1)
        core.masksToBounds = true
        coreGlow.addSublayer(core)
        coreGlow.shadowOffset = .zero
        coreGlow.shadowRadius = 12
        coreGlow.shadowOpacity = 0.75
        layer?.addSublayer(coreGlow)
        pauseGlyph.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
        pauseGlyph.contentTintColor = .white
        addSubview(pauseGlyph)
        restyleCore()
    }
    required init?(coder: NSCoder) { fatalError() }

    func tick() { pulse.toggle(); needsDisplay = true; restyleCore(); updateAccessibility() }
    func refresh() { pulse = false; needsDisplay = true; restyleCore(); updateAccessibility() }

    private var clock: String {
        if let f = store.focus { return TaskTime.clock(store.spent(f)) }
        let today = store.today
        return "\(today.filter(\.done).count)/\(today.count)"
    }
    private var word: String { store.focus == nil ? "TODAY" : (store.isRunning ? "FOCUS" : "PAUSED") }

    /// What the hover pill says: the clock (against the estimate) and what's in focus.
    var info: (big: String, small: String) {
        guard let f = store.focus else {
            return ("\(clock) done today", "TODAY · click to open")
        }
        let est = f.estimate > 0 ? "of \(f.estimate) min" : "focused"
        return ("\(clock) \(est)", "\(word) · \(f.title)")
    }

    private var over: Bool { store.focus.map { $0.estimate > 0 && store.progress > 1 } ?? false }
    private var paused: Bool { store.focus != nil && !store.isRunning }

    private func updateAccessibility() {
        setAccessibilityLabel("Focus orb: " + (store.focus.map { "\($0.title), \(clock), \(word.lowercased())" } ?? "\(clock) tasks done today"))
    }

    /// The core's colour: the accent while focusing, deeper at rest, amber past the estimate,
    /// greyed out while paused.
    private func restyleCore() {
        let c: NSColor = over ? Neon.warning : (store.isRunning ? Neon.accent : Neon.violet)
        let tint = paused ? c.blended(withFraction: 0.65, of: NSColor(white: 0.35, alpha: 1)) ?? c : c
        let dark = tint.blended(withFraction: 0.4, of: .black) ?? tint
        CATransaction.begin(); CATransaction.setDisableActions(true)
        core.colors = [NSColor.white.withAlphaComponent(paused ? 0.55 : 0.9).cgColor, tint.cgColor, dark.cgColor]
        core.locations = [0, 0.35, 1]
        coreGlow.shadowColor = tint.cgColor
        coreGlow.shadowOpacity = paused ? 0.25 : 0.75
        CATransaction.commit()
        pauseGlyph.isHidden = !paused
        if paused || Motion.reduced { coreGlow.removeAnimation(forKey: "breathe") }
        else if coreGlow.animation(forKey: "breathe") == nil {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 1; a.toValue = 1.08; a.duration = 1.6
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            coreGlow.add(a, forKey: "breathe")
        }
    }

    override func layout() {
        super.layout()
        let d = Self.orb - 20, c = NSPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        coreGlow.frame = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        coreGlow.shadowPath = CGPath(ellipseIn: coreGlow.bounds, transform: nil)
        core.frame = coreGlow.bounds
        core.cornerRadius = d / 2
        CATransaction.commit()
        pauseGlyph.frame = NSRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The design's orb: today's tasks as segments round the outside, the focus session
        // (against its estimate) on the inner ring; the glossy core sits in the middle.
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let s = Self.orb / 64 * (hovered ? 1.04 : 1)
        FocusRing.draw(center: c, outer: 27 * s, outerWidth: 3.5, inner: 21 * s, innerWidth: 3.5,
                       segments: FocusRing.segments(store), progress: store.focus == nil ? 0 : store.progress,
                       pulse: pulse && store.isRunning, track: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: discRect, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; onHover?(false) }
    override func resetCursorRects() { addCursorRect(discRect, cursor: .pointingHand) }
    /// The orb itself, without the room for its glow.
    var discRect: NSRect { bounds.insetBy(dx: (Self.size - Self.orb) / 2, dy: (Self.size - Self.orb) / 2) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return hypot(p.x - bounds.midX, p.y - bounds.midY) <= Self.orb / 2 + 2 ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, let w = window else { return }
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - d.x, p.y - d.y) < 4 { return }
        if !dragging { onDragStart?() }
        dragging = true
        w.setFrameOrigin(NSPoint(x: startOrigin.x + p.x - d.x, y: startOrigin.y + p.y - d.y))
    }
    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil; dragging = false }
        if dragging { onMoved?() } else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

// MARK: - The focus card (the orb, opened)

final class FocusCardView: NSView {
    static let width: CGFloat = 384
    static let margin: CGFloat = TaskGlow.margin
    private let store: TaskStore
    var onClose: (() -> Void)?
    var onFinished: ((FocusTask) -> Void)?
    var shortcutLabel: String? = TasksSettings.defaultShortcut.label
    private var glass: OpenerGlass!
    private let paint = TaskPaint()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let pauseButton = TreeButton(), doneButton = TreeButton(), nextButton = TreeButton()
    private var rows: [TaskRowView] = []
    private var pulse = false
    private let dial: CGFloat = 132
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(store: TaskStore) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width + Self.margin * 2, height: 420))
        glass = glassRoot(self, margin: Self.margin, radius: 26)
        paint.paint = { [weak self] r in self?.paintCard(r) }
        glass.addSubview(paint)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = Neon.text
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        glass.addSubview(titleLabel)
        pauseButton.key = "Space"
        pauseButton.onClick = { [weak self] in self?.store.togglePause() }
        doneButton.title = "Done"
        doneButton.key = "⏎"
        doneButton.primary = true
        doneButton.tint = Neon.green
        doneButton.onClick = { [weak self] in self?.finish() }
        nextButton.title = "Next"
        nextButton.key = "⇥"
        nextButton.onClick = { [weak self] in self?.store.next() }
        [pauseButton, doneButton, nextButton].forEach(glass.addSubview)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    private let upNextTop: CGFloat = 256
    var desiredHeight: CGFloat {
        let n = max(1, rows.count)
        return upNextTop + 26 + CGFloat(n) * (TaskRowView.cardHeight - 6 + 6) + 14 + Self.margin * 2
    }

    func reload() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        let f = store.focus
        titleLabel.stringValue = f?.title ?? "Pick a task to focus on"
        titleLabel.textColor = f == nil ? Neon.textDim : Neon.text
        pauseButton.title = store.isRunning ? "Pause" : "Resume"
        pauseButton.isHidden = f == nil
        doneButton.isHidden = f == nil
        nextButton.title = f == nil ? "Start next" : "Next"
        nextButton.primary = f == nil
        nextButton.isHidden = store.open.isEmpty
        for t in store.open.filter({ $0.id != store.focusID }).prefix(3) {
            let r = TaskRowView(t)
            r.spent = store.spent(t)
            r.onToggle = { [weak self] in self?.store.toggleDone(t.id) }
            r.onFocus = { [weak self] in self?.store.focusOn(t.id) }
            r.onDelete = { [weak self] in self?.store.delete(t.id) }
            glass.addSubview(r)
            rows.append(r)
        }
        setAccessibilityLabel("Focus: " + (f?.title ?? "nothing"))
        needsLayout = true
        paint.needsDisplay = true
    }

    func tick() { pulse.toggle(); paint.needsDisplay = true }

    override func layout() {
        super.layout()
        let w = glass.bounds.width
        paint.frame = glass.bounds
        // The title and the two lines under it, centred on the ring.
        let tw = w - dial - 54
        let th = min(66, ceil(titleLabel.sizeThatFits(NSSize(width: tw, height: 200)).height))
        // Project, title and the two lines under it, centred on the ring.
        titleLabel.frame = NSRect(x: 18 + dial + 18, y: 44 + dial / 2 - (th + 46 + 20) / 2 + 20, width: tw, height: th)
        // Each button as wide as its words need, the spare room shared out evenly.
        let visible = [pauseButton, doneButton, nextButton].filter { !$0.isHidden }
        let room = w - 36 - CGFloat(max(0, visible.count - 1)) * 8
        let need = visible.map(\.fittedWidth)
        let spare = max(0, room - need.reduce(0, +)) / CGFloat(max(1, visible.count))
        var x: CGFloat = 18
        for (b, n) in zip(visible, need) {
            let bw = need.reduce(0, +) > room ? room / CGFloat(visible.count) : n + spare
            b.frame = NSRect(x: x, y: 196, width: bw, height: 34)
            x += bw + 8
        }
        for (i, r) in rows.enumerated() {
            r.carded = true
            r.frame = NSRect(x: 18, y: upNextTop + 26 + CGFloat(i) * (TaskRowView.cardHeight), width: w - 36, height: TaskRowView.cardHeight - 6)
        }
    }

    private var closeRect: NSRect { NSRect(x: glass.bounds.width - 42, y: 12, width: 28, height: 28) }

    private func paintCard(_ r: NSRect) {
        let f = store.focus
        let label = f == nil ? "TODAY" : (store.isRunning ? "FOCUSING" : "PAUSED")
        drawText(label, sectionFont, store.isRunning ? Neon.cyan : Neon.textDim, in: NSRect(x: 20, y: 18, width: 200, height: 16), kern: Typo.sectionKern)
        let cr = closeRect.insetBy(dx: 0.5, dy: 0.5)
        let cp = NSBezierPath(roundedRect: cr, xRadius: 8, yRadius: 8)
        Neon.chip.setFill(); cp.fill(); Neon.chipEdge.setStroke(); cp.lineWidth = 1; cp.stroke()
        Neon.symbol("arrow.down.right.and.arrow.up.left", in: cr, size: 10, color: Neon.glyph)

        let c = NSPoint(x: 18 + dial / 2, y: 44 + dial / 2)
        FocusRing.draw(center: c, outer: dial / 2 - 4, outerWidth: 5, inner: dial / 2 - 16, innerWidth: 7,
                       segments: FocusRing.segments(store), progress: f == nil ? 0 : store.progress, pulse: pulse && store.isRunning)
        let clock = f.map { TaskTime.clock(store.spent($0)) } ?? "\(store.doneToday.count)/\(store.today.count)"
        let big = TaskFont.clock(clock.count > 5 ? 24 : 30), small = NSFont.systemFont(ofSize: 11, weight: .medium)
        let gap: CGFloat = 9, block = big.capHeight + gap + small.capHeight
        drawCap(clock, big, Neon.text, x: c.x, capMid: c.y - block / 2 + big.capHeight / 2)
        drawCap(f.map { $0.estimate > 0 ? "of \($0.estimate) min" : "focused" } ?? "done today", small, Neon.textDim, x: c.x, capMid: c.y + block / 2 - small.capHeight / 2)

        let x = 18 + dial + 18, sw = r.width - x - 16
        if let f = store.focus ?? store.open.first, store.projects.count > 1 {
            drawText(store.project(of: f).uppercased(), sectionFont, Neon.violet.blended(withFraction: 0.45, of: .white) ?? Neon.violet,
                     in: NSRect(x: x, y: titleLabel.frame.minY - 20, width: sw, height: 14), kern: Typo.sectionKern)
        }
        let ty = titleLabel.frame.maxY + 10
        drawText("\(store.doneToday.count) of \(store.today.count) done today", .systemFont(ofSize: 12, weight: .medium), Neon.green,
                 in: NSRect(x: x, y: ty, width: sw, height: 16))
        drawText("\(TaskTime.short(store.focusedToday)) focused", .systemFont(ofSize: 12), Neon.textDim, in: NSRect(x: x, y: ty + 20, width: sw, height: 16))

        drawText("UP NEXT", sectionFont, Neon.textDim, in: NSRect(x: 20, y: upNextTop, width: 120, height: 16), kern: Typo.sectionKern)
        if rows.isEmpty {
            let hint = shortcutLabel.map { "Nothing else today. \($0) adds one." } ?? "Nothing else today."
            drawText(hint, .systemFont(ofSize: 12.5), Neon.textDim, in: NSRect(x: 20, y: upNextTop + 30, width: r.width - 40, height: 18))
        }
    }

    private func finish() {
        guard let f = store.focus else { return }
        let spent = store.spent(f)
        store.toggleDone(f.id)
        var done = f
        done.log = [store.dayKey(store.now()): spent]
        onFinished?(done)
    }

    override func mouseUp(with event: NSEvent) {
        if closeRect.contains(glass.convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: store.togglePause()
        case 36, 76: finish()
        case 48: store.next()
        case 53: onClose?()
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Quick add (⌥⌘T), out of the orb

final class QuickAddView: NSView, NSTextFieldDelegate {
    static let margin: CGFloat = 50   // room for the capsule's glow
    /// v2 (the design): a 400 pt glass capsule holding the field and, under it, its keys.
    static let size = NSSize(width: 430 + margin * 2, height: margin + 88 + margin)
    var onSubmit: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    /// The orb is on the left edge: the capsule grows to the right and the hints line up left.
    var leftSide = false { didSet { needsLayout = true; hints.needsDisplay = true } }
    private var glass: OpenerGlass!
    private let box = TaskPaint()
    private let hints = TaskPaint()
    let field = TaskField(placeholder: "New task… 30m for a time, #name for a project", size: 15)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        glass = OpenerGlass(frame: .zero)
        glass.radius = 22
        glass.lineWidth = 1
        glass.glow = 0.45
        addSubview(glass)
        // The field: the design's field box, lit as focused (it always is while this is up).
        box.paint = { r in
            let f = r.insetBy(dx: 4, dy: 4)
            let shape = NSBezierPath(roundedRect: f, xRadius: 14, yRadius: 14)
            let halo = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
            Neon.accent.withAlphaComponent(0.14).setFill(); halo.fill()
            Pal.field.setFill(); shape.fill()
            Neon.accent.withAlphaComponent(0.6).setStroke(); shape.lineWidth = 1; shape.stroke()
            Neon.symbol("plus", in: NSRect(x: f.minX + 10, y: f.minY, width: 22, height: f.height), size: 14, weight: .semibold, color: Pal.textTertiary)
            Self.key("⏎", at: NSPoint(x: f.maxX - 14, y: f.midY), alignRight: true)
        }
        glass.addSubview(box)
        field.delegate = self
        glass.addSubview(field)
        hints.paint = { [weak self] r in
            Self.drawHints(in: r, left: self?.leftSide ?? false)
        }
        glass.addSubview(hints)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A key cap: the design's `.kbd` (dark fill, hairline border, mono).
    @discardableResult
    private static func key(_ k: String, at p: NSPoint, alignRight: Bool = false) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let w = max(18, ceil((k as NSString).size(withAttributes: [.font: font]).width) + 12)
        let r = NSRect(x: alignRight ? p.x - w : p.x, y: p.y - 9, width: w, height: 18)
        let kp = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.4).setFill(); kp.fill()
        Pal.border.setStroke(); kp.lineWidth = 1; kp.stroke()
        drawText(k, font, Pal.textSecondary, in: r.offsetBy(dx: 0, dy: 1), align: .center)
        return w
    }

    private static func drawHints(in r: NSRect, left: Bool) {
        let items = [("⏎", "add"), ("⇥", "add and focus"), ("esc", "close")]
        let font = NSFont.systemFont(ofSize: 12.5)
        let kf = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let widths = items.map { max(18, ceil(($0.0 as NSString).size(withAttributes: [.font: kf]).width) + 12) + 6
            + ceil(($0.1 as NSString).size(withAttributes: [.font: font]).width) }
        let total = widths.reduce(0, +) + CGFloat(items.count - 1) * 14
        var x = left ? r.minX + 4 : r.maxX - 4 - total
        for (i, it) in items.enumerated() {
            let kw = key(it.0, at: NSPoint(x: x, y: r.midY))
            drawText(it.1, font, Pal.textTertiary, in: NSRect(x: x + kw + 6, y: r.midY - 8, width: 200, height: 16))
            x += widths[i] + 14
        }
    }

    override func layout() {
        super.layout()
        let m = Self.margin
        glass.frame = NSRect(x: m, y: m, width: bounds.width - m * 2, height: 88)
        let gw = glass.bounds.width
        box.frame = NSRect(x: 8, y: 6, width: gw - 16, height: 52)
        field.frame = NSRect(x: 8 + 4 + 36, y: 6 + 4 + 12, width: gw - 16 - 8 - 36 - 40, height: 22)
        hints.frame = NSRect(x: 12, y: 62, width: gw - 24, height: 20)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): onSubmit?(field.stringValue, false); return true
        case #selector(NSResponder.insertTab(_:)): onSubmit?(field.stringValue, true); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }
}

// MARK: - Export

/// A choice in the export window: a range chip or a format tile.
final class TaskChoice: NSView {
    var title: String
    var subtitle: String?
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? "selected" : "") } }
    /// False for segments sitting in a track whose sliding indicator shows the choice.
    var drawsSelection = true
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(_ title: String, _ subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // On its own (Times / Repos) a choice is a filled pill chip; in a track, a flat segment.
        let radius: CGFloat = subtitle == nil ? (drawsSelection ? bounds.height / 2 : Radius.m - 1) : Radius.m
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if subtitle == nil {
            if drawsSelection {
                (hovered && !selected ? Neon.chipHover : Neon.chip).setFill(); p.fill()
                if selected { Pal.drawSelected(p) }
            } else if hovered && !selected { Neon.chipHover.setFill(); p.fill() }
        } else {
            // A format tile: a filled card, no outline; the chosen one wears the accent look.
            (hovered && !selected ? Neon.chipHover : Neon.row).setFill(); p.fill()
            if selected && drawsSelection { Pal.drawSelected(p) }
        }
        if let s = subtitle {
            drawText(title, Typo.rowTitleStrong, selected ? Neon.accent : Neon.text, in: NSRect(x: 12, y: 12, width: bounds.width - 24, height: 18))
            drawText(s, Typo.meta, Neon.textDim, in: NSRect(x: 12, y: 34, width: bounds.width - 24, height: 16))
        } else {
            let color = selected ? (drawsSelection ? Neon.accent : Neon.text) : Neon.textDim
            drawText(title, Typo.chip, color, in: bounds, align: .center)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    // Segments pick on press, like every segmented control; tiles on release.
    override func mouseDown(with event: NSEvent) { if subtitle == nil { onClick?() } }
    override func mouseUp(with event: NSEvent) {
        if subtitle != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A sliding indicator drawn by a track under separate segment views (Tasks' Today / Week /
/// Month, Export's range): it glides to whichever segment is selected.
private func drawTrackIndicator(_ ind: SlidingIndicator, under segment: TaskChoice?, in track: NSView) {
    guard let seg = segment, track.frame.width > 0 else { return }
    ind.settle(at: track.convert(seg.frame, from: seg.superview))
    Pal.drawSegmentIndicator(NSBezierPath(roundedRect: ind.rect, xRadius: Radius.m - 1, yRadius: Radius.m - 1))
}

final class TaskExportView: NSView {
    static let size = NSSize(width: 660 + TaskGlow.margin * 2, height: 600 + TaskGlow.margin * 2)
    private let store: TaskStore
    var span: TaskExport.Span = .today {
        didSet { refresh(); showNewest(); switched(Self.index(oldValue), Self.index(span)) }
    }
    var format: TaskExport.Format = .timesheet {
        didSet { refresh(); showNewest(); formatWash.glide(); switched(Self.index(oldValue), Self.index(format)) }
    }
    /// nil: every project. (The project bar pages the preview itself.)
    var project: String? { didSet { refresh(); showNewest() } }
    private let formatWash = GlideWash()
    private static func index<T: CaseIterable & Equatable>(_ v: T) -> Int { Array(T.allCases).firstIndex(of: v) ?? 0 }
    /// A range, a format or a project changed: the preview comes in from that side.
    private func switched(_ old: Int, _ new: Int) {
        Motion.tabSwitch([previewScroll, tableScroll, table.header, sheetScroll], from: old, to: new)
    }
    /// Linked folders are being read (the subtitle says so).
    var syncing = false { didSet { if syncing != oldValue { paint.needsDisplay = true } } }
    var onClose: (() -> Void)?
    var onExport: ((TaskExport.Span, TaskExport.Format, String?) -> Void)?
    private let projectBar = ProjectBar()
    private var glass: OpenerGlass!
    private let paint = TaskPaint()
    private var spanChips: [TaskChoice] = []
    /// Glides under the chosen range; drawn by `paint`, whose frame is the glass's bounds.
    private lazy var spanIndicator = SlidingIndicator(view: paint)
    private var formatTiles: [TaskChoice] = []
    private let previewScroll = NSScrollView()
    private let preview = NSTextView()
    /// Excel and CSV: the rows as a table.
    private let tableScroll = NSScrollView()
    private let table = TaskTableView()
    /// Timesheet: the days as cards, and what a copy holds.
    private let sheetScroll = NSScrollView()
    private let sheet = TimesheetView()
    private var optionChips: [TaskChoice] = []
    private var options = TaskExport.SheetOptions.saved {
        didSet { TaskExport.SheetOptions.saved = options; sheet.options = options; refreshOptions() }
    }
    private let cancelButton = TreeButton(), saveButton = TreeButton()
    private var rows: [TaskExport.Row] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(store: TaskStore) {
        self.store = store
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        glass = glassRoot(self, margin: TaskGlow.margin, radius: 24)
        paint.paint = { [weak self] r in self?.paintChrome(r) }
        glass.addSubview(paint)
        projectBar.editable = false
        projectBar.allTitle = "All projects"
        projectBar.onSelect = { [weak self] p in self?.project = p }
        projectBar.switches = { [weak self] in self.map { [$0.previewScroll, $0.tableScroll, $0.table.header, $0.sheetScroll] } ?? [] }
        glass.addSubview(projectBar)
        for s in TaskExport.Span.allCases {
            let c = TaskChoice(s.title)
            c.drawsSelection = false
            c.onClick = { [weak self] in self?.span = s }
            spanChips.append(c)
            glass.addSubview(c)
        }
        for f in TaskExport.Format.allCases {
            let c = TaskChoice(f.title, f.subtitle)
            c.drawsSelection = false
            c.onClick = { [weak self] in self?.format = f }
            formatTiles.append(c)
            glass.addSubview(c)
        }
        // The chosen format's look glides from tile to tile.
        formatWash.radius = Radius.m
        formatWash.target = { [weak self] in self?.formatTiles.first { $0.selected }?.frame }
        glass.addSubview(formatWash)
        preview.isEditable = false
        preview.isSelectable = true
        preview.drawsBackground = false
        preview.textContainerInset = NSSize(width: 10, height: 10)
        let lines = NSMutableParagraphStyle()
        lines.lineSpacing = 4
        preview.defaultParagraphStyle = lines
        preview.font = Typo.body
        preview.textColor = Neon.text.withAlphaComponent(0.9)
        preview.isHorizontallyResizable = true
        preview.textContainer?.widthTracksTextView = false
        preview.textContainer?.containerSize = NSSize(width: 4000, height: CGFloat.greatestFiniteMagnitude)
        preview.setAccessibilityLabel("Preview")
        previewScroll.documentView = preview
        previewScroll.drawsBackground = false
        previewScroll.hasVerticalScroller = false
        previewScroll.hasHorizontalScroller = false
        previewScroll.borderType = .noBorder
        glass.addSubview(previewScroll)
        tableScroll.documentView = table
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = false
        tableScroll.hasHorizontalScroller = false
        tableScroll.borderType = .noBorder
        tableScroll.contentView.drawsBackground = false
        glass.addSubview(tableScroll)
        glass.addSubview(table.header)
        sheetScroll.documentView = sheet
        sheetScroll.drawsBackground = false
        sheetScroll.hasVerticalScroller = false
        sheetScroll.hasHorizontalScroller = false
        sheetScroll.borderType = .noBorder
        sheetScroll.contentView.drawsBackground = false
        // Scrolling moves the cards under a still pointer: redraw so only the one under it lights.
        sheetScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(sheetScrolled), name: NSView.boundsDidChangeNotification,
                                               object: sheetScroll.contentView)
        glass.addSubview(sheetScroll)
        sheet.options = options
        sheet.onCopy = { [weak self] day in
            guard let self = self else { return }
            TaskExport.copy(TaskExport.dayText(day.rows, self.options))
            day.flashCopied()
            SoundService.shared.play(.clipCopy)
        }
        for (i, t) in Self.optionTitles.enumerated() {
            let c = TaskChoice(t)
            c.toolTip = ["Show and copy each task's time, and each day's total", "Show and copy each task's repo", "Quarter hours, as timesheets take them"][i]
            c.onClick = { [weak self] in
                guard let self = self else { return }
                switch i {
                case 0: self.options.times.toggle()
                case 1: self.options.repos.toggle()
                default: self.options.round.toggle()
                }
                self.needsLayout = true
            }
            optionChips.append(c)
            glass.addSubview(c)
        }
        cancelButton.title = "Cancel"
        cancelButton.key = "esc"
        cancelButton.onClick = { [weak self] in self?.onClose?() }
        saveButton.primary = true
        saveButton.key = "⏎"
        saveButton.onClick = { [weak self] in self?.run() }
        glass.addSubview(cancelButton)
        glass.addSubview(saveButton)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        rows = TaskExport.rows(store, span: span, project: project)
        projectBar.projects = store.projects
        projectBar.selected = project
        projectBar.isHidden = store.projects.count < 2
        for (i, c) in spanChips.enumerated() { c.selected = TaskExport.Span.allCases[i] == span }
        if let c = spanChips.first(where: { $0.selected }), c.frame.width > 0 { spanIndicator.move(to: c.frame, animated: true) }
        for (i, c) in formatTiles.enumerated() { c.selected = TaskExport.Format.allCases[i] == format }
        preview.string = rows.isEmpty ? "No tasks in this range yet." : (format == .text ? TaskExport.text(rows, project: project) : "")
        let isSheet = format == .timesheet
        let isTable = (format == .xlsx || format == .csv) && !rows.isEmpty
        previewScroll.isHidden = (isSheet || isTable) && !rows.isEmpty
        sheetScroll.isHidden = !isSheet || rows.isEmpty
        tableScroll.isHidden = !isTable
        table.header.isHidden = !isTable
        if isTable { table.show(rows, width: max(200, tableScroll.frame.width)) }
        optionChips.forEach { $0.isHidden = !isSheet }
        if isSheet { sheet.show(rows, width: max(200, sheetScroll.frame.width)) }
        refreshOptions()
        let days = TaskExport.days(rows).count
        saveButton.title = isSheet ? "Copy all \(days) day\(days == 1 ? "" : "s")" : "Save \(rows.count) task\(rows.count == 1 ? "" : "s")"
        paint.needsDisplay = true
        needsLayout = true
    }

    @objc private func sheetScrolled() { sheet.cards.forEach { $0.needsDisplay = true } }

    /// Back to the top, where the newest day is, so it can be copied without scrolling.
    /// Not part of `refresh()`: a live refresh keeps wherever you scrolled to.
    func showNewest() {
        layoutSubtreeIfNeeded()
        sheet.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: 1))
        preview.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: 1))
        table.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    static let optionTitles = ["Times", "Repos", "Round to 15m"]

    private func refreshOptions() {
        let on = [options.times, options.repos, options.round]
        for (i, c) in optionChips.enumerated() {
            c.title = (on[i] ? "✓ " : "") + Self.optionTitles[i]
            c.selected = on[i]
            c.needsDisplay = true
        }
        // Rounding only means something with times showing.
        optionChips[2].isHidden = format != .timesheet || !options.times
        paint.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let w = glass.bounds.width, pad: CGFloat = 24
        paint.frame = glass.bounds
        let n = CGFloat(spanChips.count), inset = Metrics.segmentInset
        let cw = (w - pad * 2 - inset * 2) / n
        for (i, c) in spanChips.enumerated() {
            c.frame = NSRect(x: pad + inset + CGFloat(i) * cw, y: 84 + inset, width: cw, height: Metrics.segment - inset * 2)
        }
        let tw = (w - pad * 2 - 3 * 10) / 4
        // The project row, when there's more than one project.
        let po = projectOffset
        projectBar.frame = NSRect(x: pad, y: 134, width: w - pad * 2, height: ProjectBar.height)
        for (i, c) in formatTiles.enumerated() { c.frame = NSRect(x: pad + CGFloat(i) * (tw + 10), y: 136 + po, width: tw, height: 62) }
        formatWash.frame = glass.bounds
        formatWash.needsDisplay = true
        previewScroll.frame = NSRect(x: pad + 1, y: 252 + po, width: w - pad * 2 - 2, height: glass.bounds.height - 252 - po - 74)
        let sheetFrame = NSRect(x: pad + 1, y: 252 + po, width: w - pad * 2 - 2, height: glass.bounds.height - 252 - po - 74)
        if sheetScroll.frame.width != sheetFrame.width, format == .timesheet {
            sheetScroll.frame = sheetFrame
            sheet.show(rows, width: sheetFrame.width)
            sheet.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: 1))
        }
        sheetScroll.frame = sheetFrame
        let headerFrame = NSRect(x: pad + 1, y: 252 + po, width: w - pad * 2 - 2, height: TaskTableView.headH)
        let tableFrame = NSRect(x: pad + 1, y: headerFrame.maxY, width: headerFrame.width, height: sheetFrame.maxY - headerFrame.maxY)
        if tableScroll.frame.width != tableFrame.width, !tableScroll.isHidden {
            tableScroll.frame = tableFrame
            table.show(rows, width: tableFrame.width)
        }
        table.header.frame = headerFrame
        tableScroll.frame = tableFrame
        // The options sit in the preview's top bar, on the right.
        var ox = w - pad - 10
        for c in optionChips.reversed() where !c.isHidden {
            let cw = ceil((c.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium)]).width) + 22
            ox -= cw
            c.frame = NSRect(x: ox, y: 218 + po + 5, width: cw, height: 24)
            ox -= 6
        }
        // The shared button size; the main action keeps one width as its count changes.
        let bh = Metrics.segment, by = glass.bounds.height - 22 - bh
        let saveW = max(160, saveButton.fittedWidth), cancelW = cancelButton.fittedWidth
        saveButton.frame = NSRect(x: w - pad - saveW, y: by, width: saveW, height: bh)
        cancelButton.frame = NSRect(x: saveButton.frame.minX - 8 - cancelW, y: by, width: cancelW, height: bh)
    }

    private var projectOffset: CGFloat { projectBar.isHidden ? 0 : 44 }

    private func paintChrome(_ r: NSRect) {
        let pad: CGFloat = 24, po = projectOffset
        // A timesheet counts what it'll copy: rounded to quarter hours when that's on.
        let round = format == .timesheet && options.round && options.times
        let mins = rows.reduce(0) { $0 + TaskExport.minutes($1.minutes, round: round) }
        drawText("Export tasks", Typo.screenTitle, Neon.text, in: NSRect(x: pad, y: 18, width: 300, height: 32))
        drawText("\(syncing ? "Reading commits… · " : "")\(project.map { $0 + " · " } ?? "")\(span.title) · \(rows.count) task\(rows.count == 1 ? "" : "s") · \(TaskExport.duration(mins)) focused",
                 Typo.screenSubtitle, Neon.textDim, in: NSRect(x: pad, y: 52, width: 420, height: 18))
        // The range chips sit in one track, the shared segmented control's.
        let track = NSBezierPath(roundedRect: NSRect(x: pad, y: 84, width: r.width - pad * 2, height: Metrics.segment).insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: Radius.m + 2, yRadius: Radius.m + 2)
        Neon.chip.setFill(); track.fill()
        drawTrackIndicator(spanIndicator, under: spanChips.first { $0.selected }, in: paint)
        // Preview box.
        let box = NSRect(x: pad, y: 218 + po, width: r.width - pad * 2, height: r.height - 218 - po - 72)
        // v2: no box round the preview — the label row, then the day cards or the table on the glass.
        if format == .timesheet {
            let label = Typo.sectionText("Click a day to copy it")
            label.draw(at: NSPoint(x: box.minX + 4, y: box.minY + (33 - label.size().height) / 2))
        } else {
            let label = Typo.sectionText("Preview")
            label.draw(at: NSPoint(x: box.minX + 4, y: box.minY + (33 - label.size().height) / 2))
            let name = "Downloads / " + TaskExport.fileName(span, format, project: project, now: store.now(), calendar: store.calendar)
            drawText(name, monoFont(11.5, .medium), Pal.textTertiary, in: NSRect(x: box.minX + 120, y: box.minY + 9, width: box.width - 124, height: 16), align: .right)
        }
        let note: String
        switch format {
        case .xlsx: note = "Opens in Excel, Numbers or Google Sheets."
        case .csv: note = "Comma-separated, UTF-8."
        case .timesheet: note = "Click a day to copy it. ⏎ copies them all."
        case .text: note = "Each day's date, then its tasks numbered."
        }
        drawText(note, .systemFont(ofSize: 12), Neon.textDim, in: NSRect(x: pad, y: r.height - 58, width: 260, height: 36))
    }

    private func run() {
        guard !rows.isEmpty else { NSSound.beep(); return }
        onExport?(span, format, project)
    }

    override func mouseUp(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: run()
        case 53: onClose?()
        case 123: format = TaskExport.Format(rawValue: (format.rawValue + 3) % 4) ?? format
        case 124: format = TaskExport.Format(rawValue: (format.rawValue + 1) % 4) ?? format
        case 125: span = TaskExport.Span(rawValue: min(TaskExport.Span.allCases.count - 1, span.rawValue + 1)) ?? span
        case 126: span = TaskExport.Span(rawValue: max(0, span.rawValue - 1)) ?? span
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - The + beside the orb

/// v2: the pill that floats out beside the orb while you hover it, as in the design: the clock
/// against the estimate and what's in focus, with a round + at the end nearest the orb. The + adds
/// a task; the rest of the pill opens the focus card.
final class OrbPlusView: NSView {
    static let size: CGFloat = 64          // the window's height: the 46 pt pill plus room for its glow
    static let pad: CGFloat = 14           // room round the pill for its glow, either side
    var onClick: (() -> Void)?
    var onOpen: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// The orb is on the left edge: the pill grows to the right and the + sits on its left.
    var leftSide = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    private var big = "", small = ""
    private var hovered = false { didSet { needsDisplay = true } }
    private var overPlus = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
    private static let smallFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add a task")
        toolTip = "Add a task"
    }
    required init?(coder: NSCoder) { fatalError() }

    func setInfo(big: String, small: String) {
        self.big = big; self.small = small.count > 34 ? String(small.prefix(33)) + "…" : small
        needsDisplay = true
    }

    /// The window's width for the current text.
    var fittedWidth: CGFloat {
        let w1 = (big as NSString).size(withAttributes: [.font: Self.bigFont]).width
        let w2 = (small as NSString).size(withAttributes: [.font: Self.smallFont, .kern: 0.6]).width
        return ceil(max(w1, w2)) + 14 + 10 + 30 + 8 + Self.pad * 2
    }

    private var pill: NSRect { NSRect(x: Self.pad, y: (bounds.height - 46) / 2, width: bounds.width - Self.pad * 2, height: 46) }
    var discRect: NSRect {
        let p = pill
        return NSRect(x: leftSide ? p.minX + 8 : p.maxX - 8 - 30, y: p.midY - 15, width: 30, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = pill
        let shape = NSBezierPath(roundedRect: p, xRadius: 14, yRadius: 14)
        Neon.glowing(NSColor.black.withAlphaComponent(0.55), blur: 14) {
            Neon.fillBottom.withAlphaComponent(1).setFill(); shape.fill()
        }
        NSGradient(starting: Neon.fillTop.withAlphaComponent(1), ending: Neon.fillBottom.withAlphaComponent(1))?.draw(in: shape, angle: 90)
        (hovered ? Neon.edge : Pal.border).setStroke(); shape.lineWidth = 1; shape.stroke()
        // The text, on the side away from the orb.
        let tx = leftSide ? discRect.maxX + 10 : p.minX + 14
        let tw = p.width - 14 - 10 - 30 - 8
        // "12:34 of 30 min": the clock in the accent, the rest plain.
        let attr = NSMutableAttributedString(string: big, attributes: [.font: Self.bigFont, .foregroundColor: Neon.text])
        if let sp = big.firstIndex(of: " ") {
            attr.addAttribute(.foregroundColor, value: Neon.accent, range: NSRange(big.startIndex..<sp, in: big))
        }
        attr.draw(in: NSRect(x: tx, y: p.minY + 7, width: tw, height: 16))
        (small as NSString).draw(in: NSRect(x: tx, y: p.minY + 25, width: tw, height: 14),
                                 withAttributes: [.font: Self.smallFont, .foregroundColor: Neon.textDim, .kern: 0.6])
        // The round + nearest the orb.
        let d = discRect
        let disc = NSBezierPath(ovalIn: d)
        (overPlus ? Neon.accent.withAlphaComponent(0.28) : Neon.accent.withAlphaComponent(0.14)).setFill(); disc.fill()
        Neon.accent.withAlphaComponent(overPlus ? 0.9 : 0.45).setStroke(); disc.lineWidth = 1; disc.stroke()
        Neon.symbol("plus", in: d, size: 13, weight: .bold, color: overPlus ? Neon.text : Neon.accent)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: pill.insetBy(dx: -4, dy: -4), options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; overPlus = false; onHover?(false) }
    override func mouseMoved(with event: NSEvent) {
        overPlus = discRect.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if discRect.insetBy(dx: -4, dy: -4).contains(pt) { onClick?() } else if pill.contains(pt) { (onOpen ?? onClick)?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(pill, cursor: .pointingHand) }
}

// MARK: - Motion

enum TaskMotion {
    /// Scales `layer` about `p` (in its superlayer's points, from the layer's origin) and fades it,
    /// with a spring on the way in. Skipped (jumps to the end) when Reduce Motion is on.
    static func scale(_ layer: CALayer, about p: CGPoint, from s0: CGFloat, to s1: CGFloat,
                      opacity o0: Float, _ o1: Float, spring: Bool, duration: TimeInterval = 0.22,
                      done: (() -> Void)? = nil) {
        func t(_ s: CGFloat) -> CATransform3D {
            let a = CGPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * layer.bounds.height)
            let dx = p.x - a.x, dy = p.y - a.y
            var m = CATransform3DMakeTranslation(dx, dy, 0)
            m = CATransform3DScale(m, s, s, 1)
            return CATransform3DTranslate(m, -dx, -dy, 0)
        }
        layer.removeAnimation(forKey: "taskScale")
        layer.removeAnimation(forKey: "taskFade")
        guard !Motion.reduced else {
            layer.transform = t(s1); layer.opacity = o1; done?(); return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(done)
        let move: CABasicAnimation
        if spring {
            let sp = CASpringAnimation(keyPath: "transform")
            sp.mass = 1; sp.stiffness = 260; sp.damping = 20; sp.initialVelocity = 0
            sp.duration = min(0.6, sp.settlingDuration)
            move = sp
        } else {
            move = CABasicAnimation(keyPath: "transform")
            move.duration = duration
            move.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        move.fromValue = t(s0)
        move.toValue = t(s1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = o0
        fade.toValue = o1
        fade.duration = spring ? 0.16 : duration
        layer.transform = t(s1)
        layer.opacity = o1
        layer.add(move, forKey: "taskScale")
        layer.add(fade, forKey: "taskFade")
        CATransaction.commit()
    }

    /// A quick squash and bounce, for "done".
    static func bounce(_ layer: CALayer, about p: CGPoint) {
        guard !Motion.reduced else { return }
        let a = CGPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * layer.bounds.height)
        let dx = p.x - a.x, dy = p.y - a.y
        func t(_ s: CGFloat) -> NSValue {
            var m = CATransform3DMakeTranslation(dx, dy, 0)
            m = CATransform3DScale(m, s, s, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(m, -dx, -dy, 0))
        }
        let k = CAKeyframeAnimation(keyPath: "transform")
        k.values = [t(1), t(1.16), t(0.94), t(1.04), t(1)]
        k.keyTimes = [0, 0.3, 0.55, 0.8, 1]
        k.duration = 0.5
        layer.add(k, forKey: "taskBounce")
    }
}

// MARK: - Projects

/// One project in the bar: a capsule with its name (a dot marks the default).
final class ProjectChip: NSView {
    let name: String?            // nil: All
    var title: String { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? "selected" : "") } }
    var isDefault = false { didSet { needsDisplay = true } }
    /// Linked to a code folder: a small branch shows.
    var isLinked = false { didSet { needsDisplay = true } }
    /// Syncing: a small ring fills (or spins, before there's a total) where the branch sits.
    var sync: SyncProgress? { didSet { if sync != oldValue { needsDisplay = true } } }
    var spin: CGFloat = 0 { didSet { if sync != nil { needsDisplay = true } } }
    var isAdd = false
    /// The bar draws the selected wash itself (it glides between chips); the chip keeps its base.
    var washManaged = false
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private static let font = Typo.chip
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(name: String?, title: String) {
        self.name = name
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    var fittedWidth: CGFloat {
        isAdd ? Metrics.chip : ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 26 + (isDefault ? 10 : 0) + (isLinked ? 16 : 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        // v2 chips are filled pills with no outline; the selected look is the accent wash.
        if selected && washManaged {
            Neon.chip.setFill(); p.fill()
        } else if selected {
            Neon.chip.setFill(); p.fill()
            Pal.drawSelected(p)
        } else if isAdd {
            // The + is a ghost: a dashed outline only.
            if hovered { Neon.chipHover.setFill(); p.fill() }
            let d: [CGFloat] = [3, 3]; p.setLineDash(d, count: 2, phase: 0)
            Neon.chipEdge.withAlphaComponent(0.7).setStroke(); p.lineWidth = 1; p.stroke()
        } else {
            (hovered ? Neon.chipHover : Neon.chip).setFill(); p.fill()
        }
        if isAdd {
            Neon.symbol("plus", in: bounds, size: 11, weight: .bold, color: hovered ? Neon.text : Neon.cyan)
            return
        }
        var x: CGFloat = 13
        if isDefault {
            let dot = NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - 2.5, width: 5, height: 5))
            Neon.green.setFill(); dot.fill()
            x += 10
        }
        let right: CGFloat = isLinked ? 26 : 12
        drawText(title, Self.font, selected ? Neon.accent : Neon.textDim, in: NSRect(x: x, y: 0, width: bounds.width - x - right, height: bounds.height))
        if let p = sync {
            SyncRing.draw(center: NSPoint(x: bounds.width - 18, y: bounds.midY), radius: 5.5, progress: p.fraction, spin: spin)
        } else if isLinked {
            Neon.symbol("arrow.triangle.branch", in: NSRect(x: bounds.width - 25, y: 0, width: 14, height: bounds.height), size: 9.5,
                        color: selected ? Neon.cyan : Neon.glyph.withAlphaComponent(0.8))
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// All · General · Zera · +: pick a project (nil is All). With editing on, + makes a new one
/// in place and a right-click sets the default, renames or deletes.
final class ProjectBar: NSView, NSTextFieldDelegate {
    static let height: CGFloat = Metrics.chip
    var allTitle = "All"
    var editable = true
    var projects: [String] = [] { didSet { rebuild() } }
    var defaultProject: String? { didSet { rebuild() } }
    var selected: String? {
        didSet {
            chips.forEach { $0.selected = !$0.isAdd && $0.name == selected }
            if selected != oldValue { wash.glide() }
        }
    }
    var onSelect: ((String?) -> Void)?
    /// What each project shows: after a switch these page in from the side you moved toward.
    var switches: (() -> [NSView])?
    /// The selected look, gliding from chip to chip.
    private let wash = GlideWash()
    private func chipIndex(_ p: String?) -> Int { chips.firstIndex { !$0.isAdd && $0.name == p } ?? 0 }
    var onCreate: ((String) -> Void)?
    var onRename: ((String, String) -> Bool)?
    var onDelete: ((String) -> Void)?
    var onSetDefault: ((String) -> Void)?
    /// Projects linked to a code folder, and their folders.
    var linked: [String: [String]] = [:] { didSet { if linked != oldValue { rebuild() } } }
    /// Projects syncing now, and how far.
    var syncing: [String: SyncProgress] = [:] { didSet { applySync() } }
    var spin: CGFloat = 0 { didSet { chips.forEach { $0.spin = spin } } }
    private func applySync() { chips.forEach { c in c.sync = c.isAdd ? nil : c.name.flatMap { syncing[$0] } } }
    var onLink: ((String) -> Void)?
    var onUnlink: ((String) -> Void)?
    var onSync: ((String) -> Void)?
    var onRebuild: ((String, Int) -> Void)?
    private let scroll = NSScrollView()
    private let doc = OpenerFlipped()
    private var chips: [ProjectChip] = []
    private let editBox = TaskPaint()
    private let editField = TaskField(placeholder: "Project name", size: 12.5)
    /// What the field is for: nil a new project, else the one being renamed.
    private var renaming: String?
    private var editing = false
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.documentView = doc
        addSubview(scroll)
        editBox.paint = { r in
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
            Neon.accent.withAlphaComponent(0.1).setFill(); p.fill()
            Neon.accent.withAlphaComponent(0.7).setStroke(); p.lineWidth = 1; p.stroke()
        }
        editField.delegate = self
        editField.setAccessibilityLabel("Project name")
        doc.addSubview(editBox)
        doc.addSubview(editField)
        editBox.isHidden = true
        editField.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        chips.forEach { $0.removeFromSuperview() }
        chips = []
        let all = ProjectChip(name: nil, title: allTitle)
        all.onClick = { [weak self] in self?.pick(nil) }
        chips.append(all)
        for p in projects {
            let c = ProjectChip(name: p, title: p)
            c.isDefault = editable && p == defaultProject && projects.count > 1
            c.isLinked = linked[p] != nil
            if let paths = linked[p] { c.toolTip = "Commits from " + paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ") }
            c.onClick = { [weak self] in self?.pick(p) }
            if editable { c.onMenu = { [weak self] e in self?.menu(for: p, e) } }
            chips.append(c)
        }
        if editable {
            let add = ProjectChip(name: nil, title: "New project")
            add.isAdd = true
            add.toolTip = "New project (or type #name in a task)"
            add.setAccessibilityLabel("New project")
            add.onClick = { [weak self] in self?.beginEdit(renaming: nil) }
            chips.append(add)
        }
        chips.forEach { doc.addSubview($0, positioned: .below, relativeTo: editBox) }
        chips.forEach { $0.washManaged = true; $0.selected = !$0.isAdd && $0.name == selected }
        wash.removeFromSuperview()
        doc.addSubview(wash, positioned: .below, relativeTo: editBox)
        wash.target = { [weak self] in
            guard let self = self, let c = self.chips.first(where: { $0.selected }), !c.isHidden else { return nil }
            return c.frame
        }
        applySync()
        needsLayout = true
    }

    private func pick(_ p: String?) {
        let old = chipIndex(selected)
        selected = p
        onSelect?(p)
        if let views = switches?() { Motion.tabSwitch(views, from: old, to: chipIndex(p)) }
    }

    private func menu(for p: String, _ e: NSEvent) {
        var m: [NeonMenuItem] = []
        if let paths = linked[p], !paths.isEmpty {
            m.append(.action("Sync Commits Now", "arrow.triangle.2.circlepath") { [weak self] in self?.onSync?(p) })
            m.append(.separator)
            m.append(.header("REBUILD FROM COMMITS"))
            for (title, days) in [("Yesterday", 1), ("Last 7 days", 7), ("Last month", 31)] {
                m.append(.action(title, "arrow.counterclockwise") { [weak self] in self?.onRebuild?(p, days) })
            }
            m.append(.separator)
            m.append(.header("CODE FOLDERS"))
            for path in paths { m.append(.info((path as NSString).abbreviatingWithTildeInPath, "folder")) }
            m.append(.action("Add Another Folder…", "plus") { [weak self] in self?.onLink?(p) })
            m.append(.action("Unlink All Folders", "link", destructive: false) { [weak self] in self?.onUnlink?(p) })
        } else {
            m.append(.action("Link Code Folder…", "arrow.triangle.branch") { [weak self] in self?.onLink?(p) })
        }
        m.append(.separator)
        if p != defaultProject { m.append(.action("Set as Default", "star") { [weak self] in self?.onSetDefault?(p) }) }
        m.append(.action("Rename…", "pencil") { [weak self] in self?.beginEdit(renaming: p) })
        if p != defaultProject {
            m.append(.separator)
            m.append(.action("Delete Project", "trash", destructive: true) { [weak self] in self?.onDelete?(p) })
        }
        NeonMenu.shared.show(m)
    }

    private func beginEdit(renaming p: String?) {
        renaming = p
        editing = true
        editField.stringValue = p ?? ""
        editBox.isHidden = false
        editField.isHidden = false
        layout()
        window?.makeFirstResponder(editField)
        if let ed = editField.currentEditor() { ed.selectAll(nil) }
    }

    private func endEdit(commit: Bool) {
        guard editing else { return }
        editing = false
        let text = editField.stringValue.trimmingCharacters(in: .whitespaces)
        editBox.isHidden = true
        editField.isHidden = true
        if commit, !text.isEmpty {
            if let old = renaming { if onRename?(old, text) == false { NSSound.beep() } }
            else { onCreate?(text) }
        }
        renaming = nil
        needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): endEdit(commit: true); return true
        case #selector(NSResponder.cancelOperation(_:)): endEdit(commit: false); return true
        default: return false
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) { endEdit(commit: true) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        var x: CGFloat = 0
        for c in chips {
            // The field takes the place of the chip being renamed, or of the +.
            let replaced = editing && ((c.isAdd && renaming == nil) || (!c.isAdd && c.name != nil && c.name == renaming))
            c.isHidden = replaced
            if replaced {
                editBox.frame = NSRect(x: x, y: 0, width: 150, height: bounds.height)
                editField.frame = NSRect(x: x + 12, y: (bounds.height - 17) / 2, width: 126, height: 17)
                x += 158
                continue
            }
            c.frame = NSRect(x: x, y: 0, width: c.fittedWidth, height: bounds.height)
            x += c.fittedWidth + 8
        }
        doc.frame = NSRect(x: 0, y: 0, width: max(bounds.width, x), height: bounds.height)
        wash.frame = doc.bounds
        wash.needsDisplay = true
    }
}

/// The sync indicator: a ring (on a chip) or a bar (in the header). With a total it fills; before
/// that a short arc sweeps round.
enum SyncRing {
    static func draw(center c: NSPoint, radius r: CGFloat, progress: Double?, spin: CGFloat) {
        let track = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        track.lineWidth = 2
        Neon.cyan.withAlphaComponent(0.2).setStroke(); track.stroke()
        let a0: CGFloat, a1: CGFloat
        if let p = progress { a0 = 0; a1 = max(12, 360 * CGFloat(p)) }
        else { a0 = (spin * 360).truncatingRemainder(dividingBy: 360); a1 = a0 + 90 }
        let arc = FocusRing.arc(c, r, a0, a1)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        Neon.glowing(Neon.cyan, blur: 3) { Neon.cyan.setStroke(); arc.stroke() }
    }

    static func bar(_ r: NSRect, progress: Double?, spin: CGFloat) {
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        Neon.cyan.withAlphaComponent(0.15).setFill(); track.fill()
        var fill: NSRect
        if let p = progress {
            fill = NSRect(x: r.minX, y: r.minY, width: max(r.height, r.width * CGFloat(p)), height: r.height)
        } else {
            // A short piece slides along while it counts.
            let w = r.width * 0.3, t = (spin * 0.8).truncatingRemainder(dividingBy: 1)
            fill = NSRect(x: r.minX - w + (r.width + w) * t, y: r.minY, width: w, height: r.height).intersection(r)
        }
        guard fill.width > 0 else { return }
        let p = NSBezierPath(roundedRect: fill, xRadius: r.height / 2, yRadius: r.height / 2)
        Neon.glowing(Neon.cyan, blur: 4) { Neon.cyan.setFill(); p.fill() }
    }
}

/// How far back the Tasks screen's Done list goes.
enum TaskViewSpan: Int, CaseIterable {
    case today, week, month
    var title: String { ["Today", "Week", "Month"][rawValue] }
    func since(_ store: TaskStore) -> Date {
        let cal = store.calendar, today = cal.startOfDay(for: store.now())
        switch self {
        case .today: return today
        case .week: return cal.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: return cal.date(byAdding: .day, value: -30, to: today) ?? today
        }
    }
}

// MARK: - Timesheet (the export's default view)

/// One day as a card: its date and total on top with a copy button, its tasks beneath. A click
/// anywhere on it copies that day's tasks, ready to paste into a timesheet.
final class TimesheetDayView: NSView {
    static let headH: CGFloat = 42, lineH: CGFloat = 24
    let date: Date
    let rows: [TaskExport.Row]
    var options = TaskExport.SheetOptions() { didSet { needsDisplay = true } }
    var onCopy: ((TimesheetDayView) -> Void)?
    /// Read live while drawing: when the list scrolls under a still pointer, enter / exit events
    /// go missing and every card it passed over used to stay lit as if selected.
    private var hovered: Bool { isPointerInside }
    private var copiedUntil: Date?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(date: Date, rows: [TaskExport.Row]) {
        self.date = date
        self.rows = rows
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        setAccessibilityLabel("Copy \(f.string(from: date)): \(rows.count) task\(rows.count == 1 ? "" : "s")")
        toolTip = "Click to copy this day's tasks"
    }
    required init?(coder: NSCoder) { fatalError() }

    static func height(_ n: Int) -> CGFloat { headH + CGFloat(n) * lineH + 10 }
    var total: Int { rows.reduce(0) { $0 + TaskExport.minutes($1.minutes, round: options.round) } }

    func flashCopied() {
        copiedUntil = Date().addingTimeInterval(1.4)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) { [weak self] in self?.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let copied = (copiedUntil ?? .distantPast) > Date()
        // v2: a filled card; an edge only while you point at it, green once it's copied.
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l - 2, yRadius: Radius.l - 2)
        (hovered ? Neon.chipHover : Neon.row).setFill()
        card.fill()
        if copied || hovered {
            (copied ? Neon.green : Neon.chipEdge).setStroke()
            card.lineWidth = 1; card.stroke()
        }

        // Header: "Tue  30 Sep" · total · copy.
        let wd = DateFormatter(), dm = DateFormatter()
        wd.dateFormat = "EEE"; dm.dateFormat = "d MMM"
        let today = Calendar.current.isDateInToday(date), yesterday = Calendar.current.isDateInYesterday(date)
        let dayName = today ? "Today" : (yesterday ? "Yesterday" : wd.string(from: date))
        let nf = NSFont.systemFont(ofSize: 14, weight: .bold)
        let nw = ceil((dayName as NSString).size(withAttributes: [.font: nf]).width)
        drawText(dayName, nf, Neon.text, in: NSRect(x: 14, y: 0, width: nw + 4, height: Self.headH))
        drawText(dm.string(from: date), .systemFont(ofSize: 12.5, weight: .medium), Neon.textDim, in: NSRect(x: 14 + nw + 6, y: 0, width: 120, height: Self.headH))
        // The copy glyph on the right (no box of its own); the day's count or total left of it.
        let cb = NSRect(x: bounds.width - 36, y: (Self.headH - 22) / 2, width: 22, height: 22)
        Neon.symbol(copied ? "checkmark" : "doc.on.doc", in: cb, size: 12, weight: .semibold, color: copied ? Neon.green : (hovered ? Neon.text : Neon.textDim))
        // The day's total shows with Times on; "Copied" shows either way.
        if copied || options.times {
            let label = copied ? "Copied" : TaskExport.duration(total)
            drawText(label, copied ? .systemFont(ofSize: 12.5, weight: .semibold) : TaskFont.clock(16), copied ? Neon.green : Neon.cyan,
                     in: NSRect(x: cb.minX - 130, y: 0, width: 120, height: Self.headH), align: .right)
        } else {
            let n = "\(rows.count) task\(rows.count == 1 ? "" : "s")"
            drawText(n, .systemFont(ofSize: 12.5, weight: .medium), Neon.textDim, in: NSRect(x: cb.minX - 130, y: 0, width: 124, height: Self.headH), align: .right)
        }

        // Tasks: dot · title · repo · time.
        for (i, r) in rows.enumerated() {
            let y = Self.headH - 6 + CGFloat(i) * Self.lineH
            let dot = NSBezierPath(ovalIn: NSRect(x: 18, y: y + Self.lineH / 2 - 2, width: 4, height: 4))
            Neon.textDim.setFill(); dot.fill()
            var right = bounds.width - 16
            if options.times {
                let time = TaskExport.duration(TaskExport.minutes(r.minutes, round: options.round))
                let tf = TaskFont.clock(13)
                let tw = ceil((time as NSString).size(withAttributes: [.font: tf]).width)
                drawText(r.minutes > 0 ? time : "—", tf, Neon.textDim, in: NSRect(x: right - tw, y: y, width: tw, height: Self.lineH), align: .right)
                right -= tw + 14
            }
            if options.repos, !r.repo.isEmpty {
                let rf = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
                let first = r.repo.components(separatedBy: ", ")
                let label = first[0] + (first.count > 1 ? " +\(first.count - 1)" : "")
                let w = min(160, ceil((label as NSString).size(withAttributes: [.font: rf]).width) + 14)
                let pr = NSRect(x: right - w, y: y + (Self.lineH - 18) / 2, width: w, height: 18)
                let pp = NSBezierPath(roundedRect: pr, xRadius: 9, yRadius: 9)
                Neon.cyan.withAlphaComponent(0.09).setFill(); pp.fill()
                Neon.cyan.withAlphaComponent(0.3).setStroke(); pp.lineWidth = 1; pp.stroke()
                drawText(label, rf, Neon.cyan.withAlphaComponent(0.9), in: pr.insetBy(dx: 7, dy: 0), align: .center)
                right = pr.minX - 10
            }
            drawText(r.title, .systemFont(ofSize: 13), r.done ? Neon.text : Neon.textDim,
                     in: NSRect(x: 30, y: y, width: max(0, right - 30), height: Self.lineH))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onCopy?(self) } }
    override func accessibilityPerformPress() -> Bool { onCopy?(self); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The days of a range as cards, newest first.
final class TimesheetView: NSView {
    private(set) var cards: [TimesheetDayView] = []
    var options = TaskExport.SheetOptions() { didSet { cards.forEach { $0.options = options } } }
    var onCopy: ((TimesheetDayView) -> Void)?
    override var isFlipped: Bool { true }

    func show(_ rows: [TaskExport.Row], width: CGFloat) {
        cards.forEach { $0.removeFromSuperview() }
        cards = []
        var y: CGFloat = 2
        for d in TaskExport.days(rows) {
            let c = TimesheetDayView(date: d.date, rows: d.rows)
            c.options = options
            c.frame = NSRect(x: 0, y: y, width: width, height: TimesheetDayView.height(d.rows.count))
            c.onCopy = { [weak self] v in self?.onCopy?(v) }
            addSubview(c)
            cards.append(c)
            y += c.frame.height + 8
        }
        frame = NSRect(x: 0, y: 0, width: width, height: y + 2)
    }
}

// MARK: - Export preview table

/// Excel and CSV previewed as a table that fits its box: short columns at their content width,
/// the task taking the rest, each day's date on its first row and days banded. Columns that would
/// say nothing (one project, no repos, no estimates) step aside; the saved file keeps them all.
final class TaskTableView: NSView {
    static let rowH: CGFloat = 26
    static let headH: CGFloat = 30
    private static let gap: CGFloat = 14, side: CGFloat = 14
    private static let cellFont = NSFont.systemFont(ofSize: 12.5)
    private static let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    struct Column { let title: String; let cell: (TaskExport.Row) -> String; let right: Bool; var x: CGFloat = 0; var w: CGFloat = 0 }
    private var rows: [TaskExport.Row] = []
    private var cols: [Column] = []
    /// The column titles, pinned above the scrolling rows.
    let header = TaskPaint()
    override var isFlipped: Bool { true }

    func show(_ rows: [TaskExport.Row], width: CGFloat) {
        self.rows = rows
        cols = Self.columns(rows, width: width)
        frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * Self.rowH + 8)
        header.paint = { [weak self] r in self?.paintHeader(r) }
        needsDisplay = true
        header.needsDisplay = true
    }

    static func columns(_ rows: [TaskExport.Row], width: CGFloat) -> [Column] {
        var cs: [Column] = [Column(title: "Date", cell: { $0.day }, right: false)]
        if Set(rows.map(\.project)).count > 1 { cs.append(Column(title: "Project", cell: { $0.project }, right: false)) }
        if rows.contains(where: { !$0.repo.isEmpty }) { cs.append(Column(title: "Repo", cell: { $0.repo }, right: false)) }
        cs.append(Column(title: "Task", cell: { $0.title }, right: false))
        cs.append(Column(title: "Status", cell: { $0.status }, right: false))
        cs.append(Column(title: "Min", cell: { String($0.minutes) }, right: true))
        if rows.contains(where: { $0.estimate > 0 }) { cs.append(Column(title: "Est", cell: { $0.estimate > 0 ? String($0.estimate) : "" }, right: true)) }

        func natural(_ c: Column) -> CGFloat {
            let head = ceil(Typo.sectionText(c.title).size().width)
            let font = c.right || c.title == "Date" ? digitFont : cellFont
            let cell = rows.prefix(400).map { ceil((c.cell($0) as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
            return max(head, cell)
        }
        let task = cs.firstIndex { $0.title == "Task" }!
        for i in cs.indices where i != task { cs[i].w = natural(cs[i]) }
        // Project and repo give way (down to a readable stub) before the task gets cramped.
        let caps: [String: CGFloat] = ["Project": 96, "Repo": 140]
        for i in cs.indices { if let cap = caps[cs[i].title] { cs[i].w = min(cs[i].w, cap) } }
        let room = width - side * 2 - gap * CGFloat(cs.count - 1)
        var fixed = cs.indices.filter { $0 != task }.reduce(0) { $0 + cs[$1].w }
        for name in ["Repo", "Project"] where room - fixed < 180 {
            if let i = cs.firstIndex(where: { $0.title == name }) {
                let cut = min(cs[i].w - 56, 180 - (room - fixed))
                if cut > 0 { cs[i].w -= cut; fixed -= cut }
            }
        }
        cs[task].w = max(80, room - fixed)
        var x = side
        for i in cs.indices { cs[i].x = x; x += cs[i].w + gap }
        return cs
    }

    private func paintHeader(_ r: NSRect) {
        for c in cols {
            let s = Typo.sectionText(c.title)
            let w = s.size().width
            s.draw(at: NSPoint(x: c.right ? c.x + c.w - w : c.x, y: (r.height - s.size().height) / 2))
        }
        Neon.divider.setFill()
        NSRect(x: 0, y: r.height - 1, width: r.width, height: 1).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        var dayIndex = -1, lastDay = ""
        for (i, row) in rows.enumerated() {
            let y = CGFloat(i) * Self.rowH
            guard y + Self.rowH >= dirtyRect.minY, y <= dirtyRect.maxY else {
                if row.day != lastDay { dayIndex += 1; lastDay = row.day }
                continue
            }
            let first = row.day != lastDay
            if first { dayIndex += 1; lastDay = row.day }
            // Every other day is banded, so a day's tasks read as one group.
            if dayIndex % 2 == 1 { p.text.withAlphaComponent(0.035).setFill(); NSRect(x: 0, y: y, width: bounds.width, height: Self.rowH).fill() }
            if first && i > 0 { Neon.divider.setFill(); NSRect(x: Self.side, y: y, width: bounds.width - Self.side * 2, height: 1).fill() }
            for c in cols {
                let text = c.cell(row)
                let rect = NSRect(x: c.x, y: y, width: c.w, height: Self.rowH)
                switch c.title {
                case "Date": if first { drawText(text, Self.digitFont, p.textSecondary, in: rect) }
                case "Task": drawText(text, Self.cellFont, p.text, in: rect)
                case "Status": drawText(text, Self.cellFont, row.done ? p.success.withAlphaComponent(0.85) : p.textTertiary, in: rect)
                case "Min", "Est": drawText(text, Self.digitFont, p.textSecondary, in: rect, align: .right)
                default: drawText(text, Self.cellFont, p.textSecondary, in: rect)
                }
            }
        }
    }
}
