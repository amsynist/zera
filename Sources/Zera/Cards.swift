import AppKit
import ServiceManagement

/// Anything that can hang under Zera: tells the controller how big it wants to be.
protocol CardContent: NSView {
    var cardWidth: CGFloat { get }
    var desiredHeight: CGFloat { get }
    var onHeightChange: (() -> Void)? { get set }
}

/// Soft wash over the blur.
final class CardWash: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [Pal.cardTop, Pal.cardBottom])?.draw(in: bounds, angle: -90)
    }
}

/// Card chrome: blur, wash, hairline border, rounded corners, and the standard header.
/// Cards are rebuilt when the palette changes, so colours are read once at construction.
class CardBase: NSView {
    private let blur = NSVisualEffectView()
    private let wash = CardWash()
    var onHeightChange: (() -> Void)?
    /// Esc anywhere in the card.
    var onEscape: (() -> Void)?

    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    /// Y where content starts, under the header.
    var headerBottom: CGFloat { Space.l + 22 + (subtitleLabel.isHidden ? 0 : 18) + Space.m }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(width: CGFloat, title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        roundLayer(Radius.card)
        let p = Pal
        blur.material = p.blurMaterial
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur)
        wash.autoresizingMask = [.width, .height]
        wash.frame = bounds
        addSubview(wash)
        layer?.borderWidth = 1
        layer?.borderColor = p.border.cgColor

        titleLabel.stringValue = title
        titleLabel.font = Typo.title
        titleLabel.textColor = p.text
        addSubview(titleLabel)
        subtitleLabel.font = Typo.caption
        subtitleLabel.textColor = p.textSecondary
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = true
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSubtitle(_ s: String?) {
        subtitleLabel.stringValue = s ?? ""
        subtitleLabel.isHidden = (s ?? "").isEmpty
        needsLayout = true
    }

    /// Lays out the header; subclasses call this first in `layout()`. `trailingWidth` is room
    /// kept free on the right of the title row for buttons.
    func layoutHeader(trailingWidth: CGFloat = 0) {
        let w = bounds.width - Metrics.cardPad * 2
        titleLabel.frame = NSRect(x: Metrics.cardPad, y: Space.l, width: w - trailingWidth, height: 22)
        subtitleLabel.frame = NSRect(x: Metrics.cardPad, y: Space.l + 22, width: w, height: 16)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    @discardableResult
    func label(_ text: String, font: NSFont = Typo.body, color: NSColor? = nil, in parent: NSView? = nil, wraps: Bool = false) -> NSTextField {
        let l = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color ?? Pal.text
        l.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        (parent ?? self).addSubview(l)
        return l
    }
}

// MARK: - Rows & tiles

/// The list row: icon tile, title, optional subtitle, optional trailing text, badge, chevron,
/// and an accessory view slot (toggle, button). Hover lifts it; tap runs `onTap`.
final class ListRow: NSView {
    var onTap: (() -> Void)?
    private let tile: IconTile
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    var badge = 0 { didSet { needsDisplay = true; needsLayout = true } }
    var showsChevron = false { didSet { needsDisplay = true; needsLayout = true } }
    var selected = false { didSet { restyle() } }
    var emphasized = false { didSet { title.font = emphasized ? Typo.bodyStrong : Typo.bodyMedium } }
    /// A control shown at the right edge, vertically centred (e.g. Toggle, CardButton).
    var accessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let a = accessory { addSubview(a) }
            needsLayout = true
        }
    }
    private var hovered = false { didSet { restyle() } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbol: String, color: NSColor, title t: String, subtitle s: String = "", trailing tr: String = "") {
        tile = IconTile(symbol: symbol, color: color)
        super.init(frame: .zero)
        roundLayer(Radius.l)
        addSubview(tile)
        title.stringValue = t
        title.font = Typo.bodyMedium
        title.textColor = Pal.text
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        subtitle.stringValue = s
        subtitle.font = Typo.caption
        subtitle.textColor = Pal.textSecondary
        subtitle.lineBreakMode = .byTruncatingTail
        addSubview(subtitle)
        trailing.stringValue = tr
        trailing.font = Typo.caption
        trailing.textColor = Pal.textTertiary
        trailing.alignment = .right
        addSubview(trailing)
        setAccessibilityRole(.button)
        setAccessibilityLabel(t)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String? = nil, subtitle s: String? = nil, trailing tr: String? = nil) {
        if let t = t { title.stringValue = t; setAccessibilityLabel(t) }
        if let s = s { subtitle.stringValue = s }
        if let tr = tr { trailing.stringValue = tr }
        needsLayout = true
    }

    func setTrailingColor(_ c: NSColor) { trailing.textColor = c }

    private func restyle() {
        let p = Pal
        layer?.backgroundColor = (selected ? p.accentSoft : (hovered && onTap != nil ? p.surfaceHover : p.surface)).cgColor
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        tile.frame = NSRect(x: Space.m, y: (h - Metrics.icon) / 2, width: Metrics.icon, height: Metrics.icon)
        var right = bounds.width - Space.m
        if let a = accessory {
            let aw = (a as? CardButton)?.fittedWidth ?? a.frame.width
            let ah: CGFloat = a is Toggle ? 22 : min(Metrics.control, h - 12)
            a.frame = NSRect(x: right - aw, y: (h - ah) / 2, width: aw, height: ah)
            right -= aw + Space.m
        }
        if showsChevron { right -= 14 + Space.s }
        if badge > 0 { right -= 28 + Space.s }
        let trW: CGFloat = trailing.stringValue.isEmpty ? 0 : min(150, ceil((trailing.stringValue as NSString).size(withAttributes: [.font: Typo.caption]).width) + 4)
        trailing.frame = NSRect(x: right - trW, y: (h - 14) / 2, width: trW, height: 14)
        if trW > 0 { right -= trW + Space.s }
        let textX = Space.m + Metrics.icon + Space.m
        let textW = max(20, right - textX)
        if subtitle.stringValue.isEmpty {
            title.frame = NSRect(x: textX, y: (h - 16) / 2, width: textW, height: 16)
            subtitle.isHidden = true
        } else {
            title.frame = NSRect(x: textX, y: h / 2 - 16, width: textW, height: 16)
            subtitle.frame = NSRect(x: textX, y: h / 2 + 1, width: textW, height: 14)
            subtitle.isHidden = false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { if onTap != nil { addCursorRect(bounds, cursor: .pointingHand) } }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        var x = bounds.maxX - Space.m
        if let a = accessory { x = a.frame.minX - Space.m }
        if showsChevron, let c = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))?
            .withSymbolConfiguration(.init(hierarchicalColor: p.textTertiary)) {
            c.draw(in: NSRect(x: x - c.size.width, y: bounds.midY - c.size.height / 2, width: c.size.width, height: c.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x -= 14 + Space.s
        }
        drawBadge(badge, rightEdge: x, midY: bounds.midY)
    }
}

/// Sidebar entry for Settings: small icon + label, highlighted when selected.
final class NavRow: NSView {
    var onTap: (() -> Void)?
    var badge = 0 { didSet { needsDisplay = true } }
    var selected = false { didSet { restyle() } }
    private var hovered = false { didSet { restyle() } }
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbol: String, title t: String) {
        super.init(frame: .zero)
        roundLayer(Radius.m)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: t)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        addSubview(icon)
        title.stringValue = t
        addSubview(title)
        setAccessibilityRole(.button)
        setAccessibilityLabel(t)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let p = Pal
        layer?.backgroundColor = (selected ? p.accentSoft : (hovered ? p.surfaceHover : .clear)).cgColor
        icon.contentTintColor = selected ? p.accent : p.textSecondary
        title.textColor = selected ? p.text : p.text(0.8)
        title.font = selected ? Typo.bodyStrong : Typo.nav
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: Space.m, y: (bounds.height - 16) / 2, width: 16, height: 16)
        title.frame = NSRect(x: Space.m + 24, y: (bounds.height - 16) / 2, width: bounds.width - 70, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) { drawBadge(badge, rightEdge: bounds.maxX - Space.m, midY: bounds.midY) }
}

/// A placeholder row while a list loads: a soft tile and two bars where the text will be.
final class SkeletonRow: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        p.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Radius.l, yRadius: Radius.l).fill()
        p.surfaceStrong.setFill()
        let h = bounds.height
        NSBezierPath(roundedRect: NSRect(x: Space.m, y: (h - Metrics.icon) / 2, width: Metrics.icon, height: Metrics.icon), xRadius: Radius.m, yRadius: Radius.m).fill()
        let x = Space.m + Metrics.icon + Space.m
        NSBezierPath(roundedRect: NSRect(x: x, y: h / 2 - 13, width: bounds.width * 0.55, height: 9), xRadius: 4, yRadius: 4).fill()
        NSBezierPath(roundedRect: NSRect(x: x, y: h / 2 + 3, width: bounds.width * 0.32, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
    }
}

/// Square tile for the Quick Actions grid.
final class ActionTile: NSView {
    var onTap: (() -> Void)?
    private let tile: IconTile
    private let title = NSTextField(labelWithString: "")
    private var hovered = false { didSet { layer?.backgroundColor = (hovered ? Pal.surfaceHover : Pal.surface).cgColor } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbol: String, color: NSColor, title t: String) {
        tile = IconTile(symbol: symbol, color: color, size: 26, pointSize: 12)
        super.init(frame: .zero)
        roundLayer(Radius.l)
        layer?.backgroundColor = Pal.surface.cgColor
        addSubview(tile)
        title.stringValue = t
        title.font = Typo.caption
        title.textColor = Pal.text(0.9)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        setAccessibilityRole(.button)
        setAccessibilityLabel(t)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        tile.frame = NSRect(x: (bounds.width - 26) / 2, y: Space.s, width: 26, height: 26)
        title.frame = NSRect(x: Space.xs, y: bounds.height - 20, width: bounds.width - Space.s, height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Small section heading with an optional trailing link.
final class SectionHeader: NSView {
    let title = NSTextField(labelWithString: "")
    let link = NSButton()
    var onLink: (() -> Void)?
    override var isFlipped: Bool { true }

    init(_ t: String, link l: String? = nil) {
        super.init(frame: .zero)
        title.stringValue = t
        title.font = Typo.section
        title.textColor = Pal.text
        addSubview(title)
        link.isBordered = false
        link.isHidden = l == nil
        link.attributedTitle = NSAttributedString(string: l ?? "", attributes: [.font: Typo.caption, .foregroundColor: Pal.accent])
        link.target = self
        link.action = #selector(linkTapped)
        addSubview(link)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func linkTapped() { onLink?() }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 0, y: 0, width: bounds.width - 70, height: 18)
        link.frame = NSRect(x: bounds.width - 70, y: -2, width: 70, height: 20)
    }
}

// MARK: - Quick actions

enum QuickAction {
    case openClaude, dropFiles, newNote, takeBreak, screenshot, startTimer, searchFiles
    /// A question typed into Home — answered inside Zera, no file attached.
    case askZera(String)

    var title: String {
        switch self {
        case .openClaude: return "Open Claude"
        case .dropFiles: return "Drop Files"
        case .newNote: return "New Note"
        case .takeBreak: return "Take a Break"
        case .screenshot: return "Screenshot"
        case .startTimer: return "Start Timer"
        case .searchFiles: return "Search Files"
        case .askZera: return "Ask Zera"
        }
    }

    var symbol: String {
        switch self {
        case .openClaude: return "sparkles"
        case .dropFiles: return "tray.and.arrow.down.fill"
        case .newNote: return "note.text"
        case .takeBreak: return "cup.and.saucer.fill"
        case .screenshot: return "camera.viewfinder"
        case .startTimer: return "timer"
        case .searchFiles: return "magnifyingglass"
        case .askZera: return "bubble.left.fill"
        }
    }

    var color: NSColor {
        let p = Pal
        switch self {
        case .openClaude, .askZera: return p.tileClaude
        case .dropFiles: return p.accent
        case .newNote: return p.tileNote
        case .takeBreak: return p.info
        case .screenshot: return p.accentSoft.blended(withFraction: 0.5, of: p.accent) ?? p.accent
        case .startTimer: return p.success
        case .searchFiles: return p.tileLink
        }
    }

    static let grid: [QuickAction] = [.openClaude, .dropFiles, .newNote, .takeBreak, .screenshot, .startTimer]
}

// MARK: - Home

/// "What does Zera want me to know right now?" Greeting → search / ask → Needs attention →
/// Recent → Quick Actions. Navigation lives in the hover pill, not here.
final class HomeCard: CardBase, CardContent, NSTextFieldDelegate {
    var cardWidth: CGFloat { 460 }
    var onOpen: ((CardKind) -> Void)?
    var onAction: ((QuickAction) -> Void)?
    var onOpenURL: ((URL) -> Void)?

    private let search = SearchBox(placeholder: "Search files, notes, or ask Zera…")
    private let attentionHeader = SectionHeader("Needs attention")
    private var attentionRows: [ListRow] = []
    private let allClear = NSTextField(labelWithString: "")
    private let recentHeader = SectionHeader("Recent", link: "See all")
    private var recentRows: [ListRow] = []
    private let recentEmpty = NSTextField(labelWithString: "")
    private let quickHeader = SectionHeader("Quick actions")
    private var tiles: [ActionTile] = []
    private var query = ""

    init() {
        super.init(width: 460, title: "")
        let p = Pal
        search.field.delegate = self
        addSubview(search)
        addSubview(attentionHeader)
        allClear.font = Typo.body; allClear.textColor = p.textSecondary
        addSubview(allClear)
        recentHeader.onLink = { [weak self] in self?.onOpen?(.shelf) }
        addSubview(recentHeader)
        recentEmpty.font = Typo.caption; recentEmpty.textColor = p.textTertiary
        addSubview(recentEmpty)
        addSubview(quickHeader)
        for a in QuickAction.grid {
            let t = ActionTile(symbol: a.symbol, color: a.color, title: a.title)
            t.onTap = { [weak self] in self?.onAction?(a) }
            addSubview(t)
            tiles.append(t)
        }
        for name in [ShelfStore.changed, GitHubService.changed, ClaudeHookService.changed, ReminderService.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focusSearch() { window?.makeKey(); window?.makeFirstResponder(search.field) }

    private let tileHeight: CGFloat = 56
    private var tileRows: Int { (tiles.count + 2) / 3 }

    private func listHeight(_ n: Int) -> CGFloat { n == 0 ? 20 : CGFloat(n) * (Metrics.row + Space.xs) - Space.xs }

    var desiredHeight: CGFloat {
        var h = headerBottom + Metrics.control + 4 + Space.l
        h += 18 + Space.s + listHeight(attentionRows.count) + Space.l
        h += 18 + Space.s + listHeight(recentRows.count) + Space.l
        h += 18 + Space.s + CGFloat(tileRows) * (tileHeight + Space.s) - Space.s + Metrics.cardPad
        return h
    }

    @objc func refresh() {
        let p = Pal
        let hour = Calendar.current.component(.hour, from: Date())
        titleLabel.stringValue = (hour < 12 ? "Good morning" : (hour < 17 ? "Good afternoon" : "Good evening")) + " 👋"
        setSubtitle("What shall we do today?")

        // Needs attention: Claude approvals, alerts, unseen GitHub, overdue reminders, a meeting soon.
        attentionRows.forEach { $0.removeFromSuperview() }
        attentionRows = []
        let hook = ClaudeHookService.shared, gh = GitHubService.shared, rs = ReminderService.shared
        if !hook.pending.isEmpty {
            let r = ListRow(symbol: "terminal.fill", color: p.tileClaude,
                            title: hook.pending.count == 1 ? "Claude is waiting for approval" : "\(hook.pending.count) Claude commands waiting",
                            subtitle: hook.pending.first?.command ?? "")
            r.badge = hook.pending.count; r.emphasized = true
            r.onTap = { [weak self] in self?.onOpen?(.approval) }
            attentionRows.append(r)
        }
        let alerts = rs.pendingAlerts
        if let a = alerts.first {
            let r = ListRow(symbol: "bell.fill", color: p.warning, title: a.headline, subtitle: a.detail)
            r.badge = alerts.count; r.emphasized = true
            r.onTap = { [weak self] in self?.onOpen?(.reminderAlert) }
            attentionRows.append(r)
        }
        for e in gh.events.filter({ gh.unseen.contains($0.id) }).prefix(3) {
            let r = ListRow(symbol: e.symbol, color: e.tint, title: e.title, subtitle: "\(e.subtitle) · \(relativeTime(e.date))")
            r.showsChevron = true
            r.onTap = { [weak self] in self?.onOpenURL?(e.url) }
            attentionRows.append(r)
        }
        let overdue = rs.todaysReminders.filter { !$0.isDoneToday && !$0.isInterval && $0.fireTime(on: Date()) < Date() }
        if !overdue.isEmpty, alerts.isEmpty {
            let r = ListRow(symbol: "clock.badge.exclamationmark", color: p.warning,
                            title: overdue.count == 1 ? "\(overdue[0].title) is overdue" : "\(overdue.count) reminders overdue",
                            subtitle: overdue.map { $0.title }.joined(separator: " · "))
            r.onTap = { [weak self] in self?.onOpen?(.reminders) }
            attentionRows.append(r)
        }
        if let next = rs.calendarItems.first(where: { $0.start > Date() && $0.start.timeIntervalSinceNow < 3600 }) {
            let r = ListRow(symbol: "calendar", color: p.tileCalendar, title: next.title,
                            subtitle: "in \(max(1, Int(next.start.timeIntervalSinceNow / 60))) min · \(ReminderService.timeFormatter.string(from: next.start))")
            r.onTap = { [weak self] in self?.onOpen?(.reminders) }
            attentionRows.append(r)
        }
        for r in attentionRows { addSubview(r) }
        allClear.isHidden = !attentionRows.isEmpty
        allClear.stringValue = "All clear — nothing needs you right now ✨"

        // Recent: shelf items and PR activity, newest first, filtered by the search box.
        recentRows.forEach { $0.removeFromSuperview() }
        recentRows = []
        var entries: [(Date, String, ListRow)] = []
        for item in ShelfStore.shared.items.prefix(8) {
            let sym = item.isLink ? "link" : (item.isNote ? "note.text" : "doc.fill")
            let color = item.isLink ? p.tileLink : (item.isNote ? p.tileNote : p.tileFile)
            let r = ListRow(symbol: sym, color: color, title: item.name, subtitle: "\(item.subtitle) · \(relativeTime(item.addedAt))")
            r.onTap = { NSWorkspace.shared.open(item.url) }
            entries.append((item.addedAt, item.name, r))
        }
        for e in gh.events.filter({ $0.isPR || $0.isActivity }).prefix(6) {
            let r = ListRow(symbol: "arrow.triangle.pull", color: p.tileGitHub, title: e.title, subtitle: "\(e.subtitle) · \(relativeTime(e.date))")
            r.onTap = { [weak self] in self?.onOpenURL?(e.url) }
            entries.append((e.date, e.title + " " + e.subtitle, r))
        }
        entries.sort { $0.0 > $1.0 }
        for (_, text, r) in entries where query.isEmpty || text.localizedCaseInsensitiveContains(query) {
            addSubview(r)
            recentRows.append(r)
            if recentRows.count == 3 { break }
        }
        recentEmpty.isHidden = !recentRows.isEmpty
        recentEmpty.stringValue = query.isEmpty ? "Files you drop and PRs you touch show up here." : "No match — press Return to ask Zera."
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        query = search.field.stringValue
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let q = search.field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return true }
            onAction?(.askZera(q))
            search.field.stringValue = ""
            query = ""
            refresh()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onEscape?(); return true }
        return false
    }

    override func layout() {
        super.layout()
        layoutHeader()
        let x = Metrics.cardPad, w = bounds.width - x * 2
        var y = headerBottom
        search.frame = NSRect(x: x, y: y, width: w, height: Metrics.control + 4)
        y += Metrics.control + 4 + Space.l

        attentionHeader.frame = NSRect(x: x, y: y, width: w, height: 18); y += 18 + Space.s
        if attentionRows.isEmpty {
            allClear.frame = NSRect(x: x + Space.xs, y: y, width: w - Space.xs, height: 20)
        } else {
            for r in attentionRows { r.frame = NSRect(x: x, y: y, width: w, height: Metrics.row); y += Metrics.row + Space.xs }
            y -= Space.xs + 20
        }
        y += 20 + Space.l

        recentHeader.frame = NSRect(x: x, y: y, width: w, height: 18); y += 18 + Space.s
        if recentRows.isEmpty {
            recentEmpty.frame = NSRect(x: x + Space.xs, y: y, width: w - Space.xs, height: 20)
        } else {
            for r in recentRows { r.frame = NSRect(x: x, y: y, width: w, height: Metrics.row); y += Metrics.row + Space.xs }
            y -= Space.xs + 20
        }
        y += 20 + Space.l

        quickHeader.frame = NSRect(x: x, y: y, width: w, height: 18); y += 18 + Space.s
        let tw = (w - Space.s * 2) / 3
        for (i, t) in tiles.enumerated() {
            let col = CGFloat(i % 3), row = CGFloat(i / 3)
            t.frame = NSRect(x: x + col * (tw + Space.s), y: y + row * (tileHeight + Space.s), width: tw, height: tileHeight)
        }
    }
}

// MARK: - GitHub

final class GitHubCard: CardBase, CardContent {
    var cardWidth: CGFloat { 420 }
    var onOpenSettings: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var say: ((String, ZeraMood) -> Void)?

    private let refreshButton: IconButton
    private let spinner = NSProgressIndicator()
    private let tabs = PillTabs(titles: ["Open", "Review", "CI", "Approvals"])
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let empty = NSTextField(labelWithString: "")
    private var errorRow: ListRow?
    private let openBrowser: CardButton
    private let connect: CardButton
    private var rows: [ListRow] = []
    private var skeletons: [SkeletonRow] = []
    private let maxRows = 5

    init() {
        refreshButton = IconButton(symbol: "arrow.clockwise", label: "Check now", target: nil, action: #selector(GitHubCard.refreshTapped))
        openBrowser = CardButton("Open in Browser", style: .secondary, symbol: "safari", target: nil, action: #selector(GitHubCard.openBrowserTapped))
        connect = CardButton("Connect GitHub", style: .primary, target: nil, action: #selector(GitHubCard.connectTapped))
        super.init(width: 420, title: "GitHub PRs")
        refreshButton.target = self; openBrowser.target = self; connect.target = self
        addSubview(refreshButton)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        tabs.onSelect = { [weak self] _ in self?.reload() }
        addSubview(tabs)
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = list
        addSubview(scroll)
        empty.font = Typo.body; empty.textColor = Pal.textSecondary; empty.alignment = .center
        addSubview(empty)
        addSubview(openBrowser)
        addSubview(connect)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: GitHubService.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var filtered: [GHEvent] {
        let all = GitHubService.shared.events
        switch tabs.selected {
        case 0: return all.filter { $0.kind == .prOpened || $0.isActivity }   // your PRs and what people said on them
        case 1: return all.filter { $0.kind == .reviewRequested }
        case 2: return all.filter { $0.isCI }
        default: return all.filter { $0.kind == .needsApproval }
        }
    }

    private var listTop: CGFloat { headerBottom + Metrics.control + 2 + Space.m }

    var desiredHeight: CGFloat {
        guard GitHubService.shared.isConnected else { return headerBottom + 20 + Space.m + Metrics.button + Metrics.cardPad }
        let n = max(rows.count, skeletons.count)
        let listH: CGFloat = (errorRow == nil ? 0 : Metrics.row + Space.xs) + (n == 0 ? 36 : CGFloat(min(n, maxRows)) * (Metrics.row + Space.xs) - Space.xs)
        return listTop + listH + Space.m + Metrics.button + Metrics.cardPad
    }

    @objc func reload() {
        let gh = GitHubService.shared, p = Pal
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        skeletons.forEach { $0.removeFromSuperview() }
        skeletons = []
        errorRow?.removeFromSuperview(); errorRow = nil
        let counts = [gh.events.filter { $0.kind == .prOpened || $0.isActivity }.count, gh.events.filter { $0.kind == .reviewRequested }.count,
                      gh.events.filter { $0.isCI }.count, gh.events.filter { $0.kind == .needsApproval }.count]
        tabs.titles = zip(["Open", "Review", "CI", "Approvals"], counts).map { $1 > 0 ? "\($0) \($1)" : $0 }
        if gh.isRefreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refreshButton.isHidden = gh.isRefreshing || !gh.isConnected

        if gh.isConnected {
            var sub = "@\(gh.login ?? "")"
            if gh.isRefreshing { sub += " · checking…" }
            else if let t = gh.lastChecked { sub += " · checked \(relativeTime(t))" }
            setSubtitle(sub)
            connect.isHidden = true
            tabs.isHidden = false
            openBrowser.isHidden = false
            if let e = gh.lastError {
                let expired = e.contains("401") || e.localizedCaseInsensitiveContains("bad credentials")
                let r = ListRow(symbol: "exclamationmark.triangle.fill", color: p.danger,
                                title: expired ? "GitHub token expired or revoked" : "Couldn't reach GitHub",
                                subtitle: expired ? "Paste a new token to reconnect." : e)
                r.accessory = CardButton(expired ? "Reconnect" : "Retry", style: .secondary, target: self,
                                         action: expired ? #selector(connectTapped) : #selector(refreshTapped))
                addSubview(r)
                errorRow = r
            }
            for e in filtered {
                // PR rows wear the dark GitHub tile; CI and approvals keep their state colour.
                let r = ListRow(symbol: e.symbol, color: e.isPR ? p.tileGitHub : e.tint, title: e.title,
                                subtitle: e.subtitle, trailing: relativeTime(e.date))
                r.emphasized = gh.unseen.contains(e.id)
                if e.approval != nil {
                    let b = CardButton("Approve", style: .primary, target: self, action: #selector(approveTapped(_:)))
                    b.tag = gh.events.firstIndex(of: e) ?? -1
                    r.accessory = b
                } else {
                    r.showsChevron = true
                }
                r.onTap = { [weak self] in self?.onOpenURL?(e.url) }
                list.addSubview(r)
                rows.append(r)
            }
            // First load: placeholders instead of a bare "nothing" while GitHub answers.
            if rows.isEmpty, gh.isRefreshing, gh.events.isEmpty {
                for _ in 0..<3 { let sk = SkeletonRow(); list.addSubview(sk); skeletons.append(sk) }
            }
            empty.isHidden = !rows.isEmpty || !skeletons.isEmpty
            empty.stringValue = gh.events.isEmpty ? "No PRs need your attention." : "Nothing in this tab."
            scroll.isHidden = rows.isEmpty && skeletons.isEmpty
        } else {
            setSubtitle(nil)
            tabs.isHidden = true
            scroll.isHidden = true
            openBrowser.isHidden = true
            empty.isHidden = false
            empty.stringValue = "Connect GitHub to watch your PRs, CI and approvals."
            connect.isHidden = false
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    @objc private func approveTapped(_ sender: NSButton) {
        let events = GitHubService.shared.events
        guard sender.tag >= 0, sender.tag < events.count else { return }
        let e = events[sender.tag]
        sender.isEnabled = false
        Task { @MainActor in
            do {
                try await GitHubService.shared.approve(e)
                say?("approved! ✅", .approved)
            } catch {
                sender.isEnabled = true
                say?("GitHub said no: \(error.localizedDescription)", .worried)
            }
        }
    }

    @objc private func refreshTapped() { Task { @MainActor in await GitHubService.shared.refresh() } }
    @objc private func connectTapped() { onOpenSettings?() }
    @objc private func openBrowserTapped() {
        let login = GitHubService.shared.login ?? ""
        onOpenURL?(URL(string: "https://github.com/pulls?q=is%3Aopen+is%3Apr+involves%3A\(login)")!)
    }

    override func layout() {
        super.layout()
        layoutHeader(trailingWidth: 40)
        let x = Metrics.cardPad, w = bounds.width - x * 2
        refreshButton.frame = NSRect(x: bounds.width - x - Metrics.control, y: Space.l - 3, width: Metrics.control, height: Metrics.control)
        spinner.frame = NSRect(x: bounds.width - x - 20, y: Space.l + 2, width: 16, height: 16)
        if connect.isHidden {
            tabs.frame = NSRect(x: x, y: headerBottom, width: w, height: Metrics.control + 2)
            var y = listTop
            if let er = errorRow { er.frame = NSRect(x: x, y: y, width: w, height: Metrics.row); y += Metrics.row + Space.xs }
            let bottom = bounds.height - Metrics.cardPad - Metrics.button
            let box = NSRect(x: x, y: y, width: w, height: max(0, bottom - Space.m - y))
            scroll.frame = box
            empty.frame = NSRect(x: x, y: y + 8, width: w, height: 20)
            openBrowser.frame = NSRect(x: x, y: bottom, width: w, height: Metrics.button)
            var ry: CGFloat = 0
            for r in rows { r.frame = NSRect(x: 0, y: ry, width: box.width, height: Metrics.row); ry += Metrics.row + Space.xs }
            for sk in skeletons { sk.frame = NSRect(x: 0, y: ry, width: box.width, height: Metrics.row); ry += Metrics.row + Space.xs }
            list.frame = NSRect(x: 0, y: 0, width: box.width, height: max(ry, box.height))
        } else {
            empty.frame = NSRect(x: x, y: headerBottom, width: w, height: 20)
            let cw = connect.fittedWidth
            connect.frame = NSRect(x: (bounds.width - cw) / 2, y: headerBottom + 20 + Space.m, width: cw, height: Metrics.button)
        }
    }
}

// MARK: - Settings

final class SettingsCard: CardBase, CardContent {
    var cardWidth: CGFloat { 560 }
    var onDefaultChanged: ((CardKind) -> Void)?
    var onShowZeraChanged: ((Bool) -> Void)?
    var say: ((String, ZeraMood) -> Void)?

    enum Pane: Int, CaseIterable {
        case general, appearance, integrations, shortcuts, about
        case claude, github, calendar, shelf   // detail panes, reached from Integrations
        case diagnostics                        // detail of Claude
        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .integrations: return "Integrations"
            case .shortcuts: return "Shortcuts"
            case .about: return "About"
            case .claude: return "Claude"
            case .github: return "GitHub"
            case .calendar: return "Calendar"
            case .shelf: return "Shelf"
            case .diagnostics: return "Claude diagnostics"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .appearance: return "paintpalette.fill"
            case .integrations: return "puzzlepiece.extension.fill"
            case .shortcuts: return "keyboard"
            case .about: return "info.circle.fill"
            case .claude: return "sparkles"
            case .github: return "arrow.triangle.pull"
            case .calendar: return "calendar"
            case .shelf: return "tray.full.fill"
            case .diagnostics: return "stethoscope"
            }
        }
        /// Where ‹ Back goes.
        var parent: Pane { self == .diagnostics ? .claude : .integrations }
        var isDetail: Bool { rawValue >= Pane.claude.rawValue }
        static let nav: [Pane] = [.general, .appearance, .integrations, .shortcuts, .about]
    }

    private var navRows: [NavRow] = []
    private let paneTitle = NSTextField(labelWithString: "")
    private let backButton: CardButton
    private let pane = FlippedView()
    private(set) var current: Pane = .general
    private let defaultKind: CardKind
    private let showingZera: Bool
    private let sidebarW: CGFloat = 150
    private var paneHeight: CGFloat = 200

    init(defaultKind: CardKind, showingZera: Bool, loginEnabled: Bool) {
        self.defaultKind = defaultKind
        self.showingZera = showingZera
        backButton = CardButton("Integrations", style: .tertiary, symbol: "chevron.left", target: nil, action: #selector(SettingsCard.backTapped))
        super.init(width: 560, title: "Settings")
        backButton.target = self
        backButton.isHidden = true
        addSubview(backButton)
        for pn in Pane.nav {
            let row = NavRow(symbol: pn.symbol, title: pn.title)
            row.selected = pn == current
            row.onTap = { [weak self] in self?.select(pn) }
            addSubview(row)
            navRows.append(row)
        }
        paneTitle.font = Typo.section
        paneTitle.textColor = Pal.text
        addSubview(paneTitle)
        addSubview(pane)
        for name in [GitHubService.changed, ClaudeHookService.changed, ReminderService.changed, ShelfStore.changed, ClaudeCLI.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(serviceChanged), name: name, object: nil)
        }
        rebuildPane()
    }

    required init?(coder: NSCoder) { fatalError() }

    var desiredHeight: CGFloat {
        let nav = headerBottom + CGFloat(Pane.nav.count) * (Metrics.control + Space.xs) + Metrics.cardPad
        return max(nav, headerBottom + 24 + paneHeight + Metrics.cardPad)
    }

    func select(_ p: Pane) {
        current = p
        let highlight: Pane = p.isDetail ? .integrations : p
        for (i, row) in navRows.enumerated() { row.selected = Pane.nav[i] == highlight }
        rebuildPane()
    }

    @objc private func backTapped() { select(current.parent) }

    // MARK: Pane builders

    private struct Stack {
        var y: CGFloat = 0
        let width: CGFloat
        mutating func place(_ v: NSView, height: CGFloat, gap: CGFloat = Space.s) {
            v.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + gap
        }
    }

    /// Service notifications rebuild the pane — except while you are typing into a field,
    /// so a background GitHub poll cannot wipe a half-pasted token.
    @objc private func serviceChanged() {
        if let f = tokenField, f.currentEditor() != nil { return }
        if let f = apiKeyField, f.currentEditor() != nil { return }
        rebuildPane()
    }

    @objc private func rebuildPane() {
        pane.subviews.forEach { $0.removeFromSuperview() }
        paneTitle.stringValue = current.title
        backButton.isHidden = !current.isDetail
        backButton.setTitleText(current.parent.title)
        var s = Stack(width: cardWidth - sidebarW - Metrics.cardPad * 2 - Space.m)
        switch current {
        case .general: buildGeneral(&s)
        case .appearance: buildAppearance(&s)
        case .integrations: buildIntegrations(&s)
        case .shortcuts: buildShortcuts(&s)
        case .about: buildAbout(&s)
        case .claude: buildClaude(&s)
        case .github: buildGitHub(&s)
        case .calendar: buildCalendar(&s)
        case .shelf: buildShelf(&s)
        case .diagnostics: buildDiagnostics(&s)
        }
        paneHeight = max(120, s.y)
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    private func hint(_ text: String, _ s: inout Stack) {
        let l = label(text, font: Typo.caption, color: Pal.textSecondary, in: pane, wraps: true)
        let h = (text as NSString).boundingRect(with: NSSize(width: s.width, height: 200), options: [.usesLineFragmentOrigin], attributes: [.font: Typo.caption]).height
        s.place(l, height: ceil(h) + 2, gap: Space.m)
    }

    private func settingRow(_ title: String, _ s: inout Stack, control: NSView, controlWidth: CGFloat) {
        let row = FlippedView()
        let l = label(title, font: Typo.bodyMedium, in: row)
        l.frame = NSRect(x: 0, y: 7, width: s.width - controlWidth - Space.m, height: 18)
        let ch: CGFloat = control is Toggle ? 22 : Metrics.control
        control.frame = NSRect(x: s.width - controlWidth, y: (Metrics.button - ch) / 2, width: controlWidth, height: ch)
        row.addSubview(control)
        pane.addSubview(row)
        s.place(row, height: Metrics.button)
    }

    private func toggleRow(_ title: String, on: Bool, _ s: inout Stack, enabled: Bool = true, onChange: @escaping (Bool) -> Void) {
        let t = Toggle()
        t.isOn = on
        t.isEnabled = enabled
        t.onChange = onChange
        settingRow(title, &s, control: t, controlWidth: 40)
    }

    private func popupRow(_ title: String, items: [String], selected: Int, _ s: inout Stack, action: Selector) -> NSPopUpButton {
        let pop = NSPopUpButton()
        pop.addItems(withTitles: items)
        pop.selectItem(at: selected)
        pop.target = self
        pop.action = action
        stylePopup(pop)
        settingRow(title, &s, control: pop, controlWidth: 150)
        return pop
    }

    private func buttonRow(_ title: String, style: CardButton.Style, status: String, _ s: inout Stack, action: Selector) {
        let row = FlippedView()
        let b = CardButton(title, style: style, target: self, action: action)
        let bw = max(110, b.fittedWidth)
        b.frame = NSRect(x: 0, y: 0, width: bw, height: Metrics.control)
        row.addSubview(b)
        let l = label(status, font: Typo.caption, color: Pal.textSecondary, in: row)
        l.frame = NSRect(x: bw + Space.m, y: 6, width: s.width - bw - Space.m, height: 16)
        pane.addSubview(row)
        s.place(row, height: Metrics.control, gap: Space.m)
    }

    private func statusLine(_ state: ConnectionState, detail: String, _ s: inout Stack) {
        let row = FlippedView()
        let dot = NSView(frame: NSRect(x: 0, y: 6, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = state.color.cgColor
        row.addSubview(dot)
        let l = label("\(state.label)\(detail.isEmpty ? "" : " · \(detail)")", font: Typo.caption, color: Pal.textSecondary, in: row)
        l.frame = NSRect(x: 14, y: 2, width: s.width - 14, height: 16)
        pane.addSubview(row)
        s.place(row, height: 20, gap: Space.m)
    }

    private var defaultPopup: NSPopUpButton?
    private var breakPopup: NSPopUpButton?
    private var tokenField: ThemedSecureField?
    private var apiKeyField: ThemedSecureField?
    private var overrideField: ThemedField?
    private var modelPopup: NSPopUpButton?
    private var cliModelPopup: NSPopUpButton?
    private var timeoutPopup: NSPopUpButton?
    private var maxOutputPopup: NSPopUpButton?
    private var claudeTestResult: String?
    private var apiTestResult: String?
    private static let timeoutChoices = [60, 120, 180, 300, 600, 900]
    private static let cliModelChoices = ["", "sonnet", "opus", "haiku"]
    private static let maxOutputChoices = [1024, 2048, 4096, 8192]
    private static let defaultChoices: [CardKind] = [.shelf, .home, .reminders, .github]
    private static let breakChoices = [0, 30, 45, 60, 90, 120]

    private func buildGeneral(_ s: inout Stack) {
        defaultPopup = popupRow("Tap on Zera opens", items: Self.defaultChoices.map { $0.title },
                                selected: Self.defaultChoices.firstIndex(of: defaultKind) ?? 0, &s, action: #selector(defaultChanged))
        toggleRow("Show Zera at the notch", on: showingZera, &s) { [weak self] on in self?.onShowZeraChanged?(on) }
        toggleRow("Open at login", on: SMAppService.mainApp.status == .enabled, &s) { on in
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSSound.beep() }
        }
        let rs = ReminderService.shared
        breakPopup = popupRow("Break reminder", items: ["Off", "Every 30 min", "Every 45 min", "Every hour", "Every 90 min", "Every 2 hours"],
                              selected: Self.breakChoices.firstIndex(of: rs.breakInterval) ?? 0, &s, action: #selector(breakChanged))
        hint("Breaks are only suggested while you're actually at the keyboard.", &s)
    }

    private func buildAppearance(_ s: inout Stack) {
        let t = PillTabs(titles: Appearance.allCases.map { $0.title })
        t.selected = Palette.appearance.rawValue
        t.onSelect = { i in Palette.appearance = Appearance(rawValue: i) ?? .system }
        pane.addSubview(t)
        s.place(t, height: Metrics.control + 2, gap: Space.m)
        hint(Palette.appearance == .system ? "Following macOS — \(Palette.systemIsDark ? "dark" : "light") right now. Zera, the pill and her bubble keep their own look."
                                           : "Zera, the pill and her bubble keep their own look.", &s)
        toggleRow("Reduce motion (system setting)", on: Motion.reduced, &s, enabled: false) { _ in }
        hint("Change it in System Settings → Accessibility → Display.", &s)
    }

    private func integrationRow(symbol: String, color: NSColor, title: String, state: ConnectionState, detail: String,
                                on: Bool, enabled: Bool, toggle: Bool = true, _ s: inout Stack, pane target: Pane?, onChange: @escaping (Bool) -> Void) {
        let row = ListRow(symbol: symbol, color: color, title: title, subtitle: detail.isEmpty ? state.label : "\(state.label) · \(detail)")
        if toggle {
            let t = Toggle()
            t.isOn = on
            t.isEnabled = enabled
            t.onChange = onChange
            row.accessory = t
        }
        if let target = target {
            row.showsChevron = true
            row.onTap = { [weak self] in self?.select(target) }
        }
        pane.addSubview(row)
        s.place(row, height: 52, gap: Space.xs + 2)
    }

    private func buildIntegrations(_ s: inout Stack) {
        let hook = ClaudeHookService.shared, gh = GitHubService.shared, rs = ReminderService.shared, p = Pal
        let (claudeState, claudeDetail) = Self.claudeSummary()
        integrationRow(symbol: "sparkles", color: p.tileClaude, title: "Claude",
                       state: claudeState, detail: claudeDetail + (hook.isInstalled ? " · approvals" : ""),
                       on: false, enabled: false, toggle: false, &s, pane: .claude) { _ in }
        let ghState: ConnectionState = gh.isConnected ? ((gh.lastError?.contains("401") ?? false) ? .error : .connected) : .disconnected
        integrationRow(symbol: "arrow.triangle.pull", color: p.tileGitHub, title: "GitHub",
                       state: ghState, detail: gh.isConnected ? "@\(gh.login ?? "")" : "PRs, CI, approvals",
                       on: gh.isConnected, enabled: true, &s, pane: .github) { [weak self] on in
            if on { self?.select(.github) } else { gh.disconnect(); self?.rebuildPane() }
        }
        let calState: ConnectionState = rs.calendarAuthorized ? .connected : (rs.calendarDenied ? .needsAuth : .disconnected)
        integrationRow(symbol: "calendar", color: p.tileCalendar, title: "Calendar",
                       state: calState, detail: rs.calendarAuthorized ? "meeting alerts 15 min before" : "meeting alerts",
                       on: rs.calendarAuthorized, enabled: true, &s, pane: .calendar) { [weak self] on in
            if on { Task { @MainActor in await rs.connectCalendar(); self?.rebuildPane() } }
            else { rs.disconnectCalendar(); self?.rebuildPane() }
        }
        integrationRow(symbol: "tray.full.fill", color: p.accent, title: "Shelf", state: .connected, detail: "drag files from anywhere",
                       on: true, enabled: false, &s, pane: .shelf) { _ in }
        hint("Notion and Slack are coming later.", &s)
    }

    // MARK: Claude pane

    /// One line for the Integrations list: what the file assistant can do right now.
    private static func claudeSummary() -> (ConnectionState, String) {
        let a = ZeraAssistant.shared
        switch a.provider {
        case .anthropicAPI:
            return AnthropicAPIClient.shared.isConfigured ? (.connected, "Anthropic API") : (.needsAuth, "API key missing")
        case .claudeCode:
            let info = ClaudeCLI.shared.info
            switch info.status {
            case .connected: return (.connected, "Claude Code" + (info.version.map { " \($0)" } ?? ""))
            case .checking: return (.connecting, "checking Claude Code")
            case .unknown: return (.disconnected, "Claude Code not checked yet")
            case .notDetected: return (.disconnected, "Claude Code not found")
            case .needsAuth: return (.needsAuth, "Claude Code needs sign-in")
            case .programmaticUnavailable: return (.error, "Claude Code can't run in the background")
            }
        }
    }

    private func sectionLabel(_ text: String, _ s: inout Stack) {
        let l = label(text, font: Typo.section, color: Pal.textSecondary, in: pane)
        s.place(l, height: 18, gap: Space.xs)
    }

    private func kvRow(_ key: String, _ value: String, _ s: inout Stack, mono: Bool = false) {
        let row = FlippedView()
        let k = label(key, font: Typo.caption, color: Pal.textSecondary, in: row)
        k.frame = NSRect(x: 0, y: 2, width: 130, height: 16)
        let v = label(value, font: mono ? Typo.mono : Typo.caption, in: row)
        v.lineBreakMode = .byTruncatingMiddle
        v.frame = NSRect(x: 130, y: 2, width: s.width - 130, height: 16)
        v.toolTip = value
        pane.addSubview(row)
        s.place(row, height: 20, gap: Space.xs)
    }

    private func buildClaude(_ s: inout Stack) {
        let a = ZeraAssistant.shared, cli = ClaudeCLI.shared.info, api = AnthropicAPIClient.shared, hook = ClaudeHookService.shared
        let (state, detail) = Self.claudeSummary()
        statusLine(state, detail: detail, &s)
        hint("Summarize, Explain, Extract and Ask run in the background and answer inside Zera — no terminal window, ever.", &s)

        let tabs = PillTabs(titles: ["Existing Claude Code", "Anthropic API"])
        tabs.selected = a.provider.rawValue
        tabs.onSelect = { [weak self] i in
            ZeraAssistant.shared.provider = ZeraAssistant.Provider(rawValue: i) ?? .claudeCode
            if i == 0 { ClaudeCLI.shared.ensureProbed { _ in } }
            self?.rebuildPane()
        }
        pane.addSubview(tabs)
        s.place(tabs, height: Metrics.control + 2, gap: Space.m)

        switch a.provider {
        case .claudeCode:
            kvRow("Claude executable", cli.executable == nil ? (cli.status == .checking ? "Looking…" : "Not found") : cli.executableDisplay, &s, mono: cli.executable != nil)
            let signedIn: String
            if let l = cli.loggedIn {
                signedIn = l ? "Yes" + (cli.authMethod.map { " (\($0))" } ?? "") : "No"
            } else {
                signedIn = cli.status == .checking ? "Checking…" : "Unknown — found out on first use"
            }
            kvRow("Signed in", signedIn, &s)
            buttonRow("Test Claude", style: .secondary, status: claudeTestResult ?? "Sends a one-word request through your login", &s, action: #selector(testClaudeTapped))
            switch cli.status {
            case .notDetected:
                hint("Claude Code isn't installed on this Mac. Install it (claude.ai/code), or point Zera at it under Diagnostics. You can also use an Anthropic API key instead.", &s)
            case .needsAuth:
                hint("Open a terminal, run `claude`, and sign in once. Zera reuses that login and never sees the token.", &s)
            case .programmaticUnavailable(let why):
                hint("This Claude Code installation can't be used for background file analysis (\(why)). Switch to an Anthropic API key, or update Claude Code.", &s)
            default: break
            }
        case .anthropicAPI:
            if api.isConfigured {
                let masked = KeychainStore.read(.apiKey).map(KeychainStore.masked) ?? "saved"
                statusLine(.connected, detail: "Key \(masked) · in your Keychain", &s)
                buttonRow("Test Connection", style: .secondary, status: apiTestResult ?? "Lists your models — no tokens spent", &s, action: #selector(testAPITapped))
                buttonRow("Remove Key", style: .destructive, status: "Deletes it from the Keychain", &s, action: #selector(removeKeyTapped))
                let models = api.knownModels.isEmpty ? [api.model] : api.knownModels
                modelPopup = popupRow("Model", items: models, selected: max(0, models.firstIndex(of: api.model) ?? 0), &s, action: #selector(apiModelChanged))
            } else {
                hint("Paste an Anthropic API key (console.anthropic.com). It is stored in your Keychain and only ever sent to api.anthropic.com. Requests are billed to that account.", &s)
                keyRow(&s)
            }
        }

        sectionLabel("Advanced", &s)
        let t = Int(a.timeout)
        timeoutPopup = popupRow("Timeout", items: Self.timeoutChoices.map { "\($0 / 60) min" },
                                selected: Self.timeoutChoices.firstIndex(of: t) ?? 2, &s, action: #selector(timeoutChanged))
        if a.provider == .claudeCode {
            cliModelPopup = popupRow("Model", items: Self.cliModelChoices.map { $0.isEmpty ? "Claude Code default" : $0 },
                                     selected: Self.cliModelChoices.firstIndex(of: a.cliModel) ?? 0, &s, action: #selector(cliModelChanged))
        } else {
            maxOutputPopup = popupRow("Max output", items: Self.maxOutputChoices.map { "\($0 / 1024)k tokens" },
                                      selected: Self.maxOutputChoices.firstIndex(of: a.maxOutputTokens) ?? 1, &s, action: #selector(maxOutputChanged))
        }
        toggleRow("Keep Claude's error output for diagnostics", on: a.debugLogging, &s) { on in ZeraAssistant.shared.debugLogging = on }
        buttonRow("Diagnostics", style: .tertiary, status: a.lastRunSummary, &s, action: #selector(diagnosticsTapped))

        sectionLabel("Approvals · Claude Code hook", &s)
        statusLine(hook.isInstalled ? .connected : .disconnected,
                   detail: hook.isInstalled ? (hook.pending.isEmpty ? "Bash commands ask here first" : "\(hook.pending.count) waiting") : "approve commands from Zera instead of the terminal", &s)
        buttonRow(hook.isInstalled ? "Remove hook" : "Install hook", style: hook.isInstalled ? .secondary : .primary,
                  status: hook.isInstalled ? "Restart open Claude Code sessions after changes" : "Adds a PreToolUse hook to ~/.claude/settings.json", &s, action: #selector(claudeTapped))
    }

    private func keyRow(_ s: inout Stack) {
        let f = ThemedSecureField(placeholder: "sk-ant-…")
        apiKeyField = f
        let row = FlippedView()
        let b = CardButton("Save", style: .primary, target: self, action: #selector(saveKeyTapped))
        let bw = b.fittedWidth
        f.frame = NSRect(x: 0, y: 0, width: s.width - bw - Space.s, height: Metrics.control)
        b.frame = NSRect(x: s.width - bw, y: 0, width: bw, height: Metrics.control)
        row.addSubview(f); row.addSubview(b)
        pane.addSubview(row)
        s.place(row, height: Metrics.control, gap: Space.m)
    }

    private func buildDiagnostics(_ s: inout Stack) {
        let cli = ClaudeCLI.shared.info, a = ZeraAssistant.shared, caps = cli.capabilities
        hint("What Zera found on this Mac. Nothing here is secret: no keys, no tokens, no document text.", &s)
        kvRow("Claude CLI", cli.executable == nil ? cli.status.label : "Detected", &s)
        kvRow("Path", cli.executable == nil ? "—" : cli.executableDisplay, &s, mono: cli.executable != nil)
        kvRow("Version", cli.version ?? "—", &s)
        kvRow("Programmatic mode", caps.programmaticOK ? "Available (print + \(caps.streamJSON ? "stream-json" : "json"))" : "Unavailable", &s)
        let auth: String
        if let l = cli.loggedIn {
            var parts = [l ? "Signed in" : "Not signed in"]
            if l, let m = cli.authMethod { parts.append(m) }
            if l, let pr = cli.apiProvider { parts.append(pr) }
            auth = parts.joined(separator: " · ")
        } else {
            auth = "Unknown (older CLI)"
        }
        kvRow("Authentication", auth, &s)
        kvRow("Output streaming", caps.streamingOK ? "Available" : (caps.streamJSON ? "Per message (no partial deltas)" : "Unavailable"), &s)
        kvRow("Follow-up questions", caps.resume ? "Available (--resume)" : "Unavailable (new session each time)", &s)
        kvRow("Tool restriction", caps.tools ? "--tools" : (caps.disallowedTools ? "--disallowedTools" : "none"), &s)
        let masked = KeychainStore.read(.apiKey).map(KeychainStore.masked) ?? ""
        kvRow("API key", AnthropicAPIClient.shared.isConfigured ? "Configured · \(masked)" : "Not configured", &s)
        let active: String
        switch a.activeProvider {
        case .claudeCode?: active = "Claude Code"
        case .anthropicAPI?: active = "Anthropic API"
        case nil: active = "— (nothing run yet)"
        }
        kvRow("Active provider", active, &s)
        let health = a.lastRunSummary.isEmpty ? (cli.status == .connected ? "Healthy" : cli.status.label) : a.lastRunSummary
        kvRow("Zera connection", health, &s)
        kvRow("Shell PATH entries", "\(ShellEnvironment.shared.path.count)", &s)
        kvRow("Last checked", cli.checkedAt.map { relativeTime($0) } ?? "never", &s)
        if a.debugLogging, !a.lastStderr.isEmpty {
            sectionLabel("Last error output", &s)
            let box = NSTextField(wrappingLabelWithString: String(a.lastStderr.suffix(600)))
            box.font = Typo.mono; box.textColor = Pal.textSecondary
            box.maximumNumberOfLines = 8
            pane.addSubview(box)
            s.place(box, height: 110, gap: Space.m)
        }
        sectionLabel("Claude executable override", &s)
        let f = ThemedField(placeholder: "Leave empty to detect automatically")
        f.stringValue = ClaudeCLI.shared.executableOverride
        overrideField = f
        let row = FlippedView()
        let b = CardButton("Save", style: .secondary, target: self, action: #selector(saveOverrideTapped))
        let bw = b.fittedWidth
        f.frame = NSRect(x: 0, y: 0, width: s.width - bw - Space.s, height: Metrics.control)
        b.frame = NSRect(x: s.width - bw, y: 0, width: bw, height: Metrics.control)
        row.addSubview(f); row.addSubview(b)
        pane.addSubview(row)
        s.place(row, height: Metrics.control, gap: Space.m)
        buttonRow("Re-check", style: .secondary, status: "Runs claude --version, --help and auth status again", &s, action: #selector(recheckTapped))
        buttonRow("Copy report", style: .tertiary, status: "Plain text, safe to paste in a bug report", &s, action: #selector(copyReportTapped))
    }

    private func buildGitHub(_ s: inout Stack) {
        let gh = GitHubService.shared
        if gh.isConnected {
            let expired = gh.lastError?.contains("401") ?? false
            statusLine(expired ? .error : .connected,
                       detail: expired ? "token expired — paste a new one" : "@\(gh.login ?? "")" + (gh.lastChecked.map { " · checked \(relativeTime($0))" } ?? ""), &s)
            if let e = gh.lastError, !expired { hint(e, &s) }
            buttonRow("Check now", style: .secondary, status: "Polls every \(Int(gh.pollInterval / 60)) minutes", &s, action: #selector(githubRefreshTapped))
            buttonRow("Disconnect", style: .destructive, status: "Removes the saved token", &s, action: #selector(githubDisconnectTapped))
            if expired { tokenRow(&s) }
        } else {
            statusLine(.disconnected, detail: "", &s)
            hint("Paste a personal access token. Classic: repo + workflow · fine-grained: Pull requests, Checks, Actions. Stored locally, only ever sent to api.github.com.", &s)
            tokenRow(&s)
        }
    }

    private func tokenRow(_ s: inout Stack) {
        let f = ThemedSecureField(placeholder: "ghp_… or github_pat_…")
        tokenField = f
        let row = FlippedView()
        let b = CardButton("Connect", style: .primary, target: self, action: #selector(githubConnectTapped))
        let bw = b.fittedWidth
        f.frame = NSRect(x: 0, y: 0, width: s.width - bw - Space.s, height: Metrics.control)
        b.frame = NSRect(x: s.width - bw, y: 0, width: bw, height: Metrics.control)
        row.addSubview(f); row.addSubview(b)
        pane.addSubview(row)
        s.place(row, height: Metrics.control, gap: Space.m)
    }

    private func buildCalendar(_ s: inout Stack) {
        let rs = ReminderService.shared
        statusLine(rs.calendarAuthorized ? .connected : (rs.calendarDenied ? .needsAuth : .disconnected), detail: rs.calendarStatusText, &s)
        hint("Zera warns you 15 minutes before each meeting and again when it starts. Syncs every \(Int(rs.calendarSyncInterval / 60)) minutes and whenever Calendar changes.", &s)
        if rs.calendarDenied { hint("Allow Zera in System Settings → Privacy & Security → Calendars (Full Access).", &s) }
        buttonRow(rs.calendarAuthorized ? "Disconnect" : "Connect Calendar", style: rs.calendarAuthorized ? .secondary : .primary,
                  status: rs.calendarAuthorized ? "Today and tomorrow are loaded" : "macOS will ask once", &s, action: #selector(calendarTapped))
        if rs.calendarAuthorized {
            buttonRow("Sync now", style: .secondary, status: rs.lastCalendarSync.map { "Last sync \(relativeTime($0))" } ?? "", &s, action: #selector(calendarSyncTapped))
        }
    }

    private func buildShelf(_ s: inout Stack) {
        let n = ShelfStore.shared.items.count
        statusLine(.connected, detail: n == 0 ? "nothing held" : (n == 1 ? "holding 1 item" : "holding \(n) items"), &s)
        hint("Files are referenced, not copied. Pasted text and images live in a staging folder until you remove them.", &s)
        buttonRow("Open staging folder", style: .secondary, status: "~/Library/Application Support/Zera/Staged", &s, action: #selector(openStagingTapped))
        buttonRow("Clear shelf", style: .destructive, status: "Removes every item", &s, action: #selector(clearShelfTapped))
    }

    private func buildShortcuts(_ s: inout Stack) {
        let items: [(String, String)] = [
            ("Open the default card", "Tap Zera"), ("Show the pill", "Hover Zera"), ("Move Zera along the top", "Drag her"),
            ("Close any card", "Esc"), ("Approve / reject a Claude command", "⏎ / Esc"), ("Add a reminder", "⏎ in the composer"),
            ("Paste clipboard onto the shelf", "⌘V"), ("Select all tiles", "⌘A"), ("Remove selected tiles", "⌫"),
        ]
        for (what, key) in items {
            let row = FlippedView()
            let l = label(what, font: Typo.body, in: row)
            l.frame = NSRect(x: 0, y: 4, width: s.width - 150, height: 16)
            let k = label(key, font: Typo.caption, color: Pal.textSecondary, in: row)
            k.alignment = .right
            k.frame = NSRect(x: s.width - 150, y: 4, width: 150, height: 16)
            pane.addSubview(row)
            s.place(row, height: 24, gap: Space.xs)
        }
    }

    private func buildAbout(_ s: inout Stack) {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let t = label("Zera \(v)", font: Typo.title, in: pane)
        s.place(t, height: 22, gap: Space.xs)
        hint("Your AI desktop buddy. She hangs from the notch, holds your files, summarizes and explains them with your own Claude Code login, watches your PRs, approves Claude Code commands and keeps you on track.", &s)
        hint("Open source · MIT", &s)
    }

    // MARK: Actions

    @objc private func defaultChanged() {
        guard let pop = defaultPopup else { return }
        onDefaultChanged?(Self.defaultChoices[max(0, min(Self.defaultChoices.count - 1, pop.indexOfSelectedItem))])
    }

    @objc private func breakChanged() {
        guard let pop = breakPopup else { return }
        let m = Self.breakChoices[max(0, min(Self.breakChoices.count - 1, pop.indexOfSelectedItem))]
        ReminderService.shared.breakInterval = m
        say?(m == 0 ? "no more break nudges" : "I'll nudge you every \(Reminder.intervalLabel(m)) ☕", .cozy)
    }

    @objc private func claudeTapped() {
        let hook = ClaudeHookService.shared
        do {
            if hook.isInstalled { try hook.uninstall(); say?("hook removed", .idle) }
            else { try hook.install(); say?("I'll ask you before Claude runs commands 💜", .approved) }
        } catch { say?("couldn't edit ~/.claude/settings.json 😬", .worried) }
        rebuildPane()
    }

    @objc private func githubConnectTapped() {
        guard let f = tokenField else { return }
        let token = f.stringValue
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { say?("paste a token first 🙂", .thinking); return }
        say?("checking the token…", .thinking)
        Task { @MainActor in
            do { let name = try await GitHubService.shared.connect(token: token); say?("connected as @\(name)! 🎉", .celebrate) }
            catch { say?("that token didn't work 😬", .worried) }
            rebuildPane()
        }
    }

    @objc private func githubDisconnectTapped() {
        GitHubService.shared.disconnect()
        say?("GitHub disconnected", .idle)
        rebuildPane()
    }

    @objc private func githubRefreshTapped() { Task { @MainActor in await GitHubService.shared.refresh() } }

    @objc private func calendarTapped() {
        let rs = ReminderService.shared
        if rs.calendarAuthorized { rs.disconnectCalendar(); say?("calendar disconnected", .idle); return }
        Task { @MainActor in
            await rs.connectCalendar()
            say?(rs.calendarAuthorized ? "I'll warn you 15 min before meetings 📅" : "macOS didn't let me see your calendar 😬", rs.calendarAuthorized ? .approved : .worried)
            rebuildPane()
        }
    }

    @objc private func calendarSyncTapped() { ReminderService.shared.refreshCalendar(); say?("calendar synced 📅", .approved) }

    // Claude pane

    @objc private func testClaudeTapped() {
        claudeTestResult = "Testing…"
        rebuildPane()
        say?("checking Claude…", .thinking)
        ZeraAssistant.shared.testConnection { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg): self.claudeTestResult = msg; self.say?("Claude's ready ✨", .celebrate)
            case .failure(let err): self.claudeTestResult = err.message; self.say?("hmm, not yet 😬", .worried)
            }
            self.rebuildPane()
        }
    }

    @objc private func testAPITapped() {
        apiTestResult = "Testing…"
        rebuildPane()
        ZeraAssistant.shared.testConnection { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg): self.apiTestResult = msg; self.say?("API key works ✨", .celebrate)
            case .failure(let err): self.apiTestResult = err.message; self.say?("that key didn't work 😬", .worried)
            }
            self.rebuildPane()
        }
    }

    @objc private func saveKeyTapped() {
        guard let f = apiKeyField else { return }
        let key = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { say?("paste a key first 🙂", .thinking); return }
        f.stringValue = ""
        guard KeychainStore.write(key, to: .apiKey) else { say?("Keychain said no 😬", .worried); return }
        say?("key saved to your Keychain 🔐", .approved)
        apiTestResult = nil
        rebuildPane()
        testAPITapped()
    }

    @objc private func removeKeyTapped() {
        KeychainStore.delete(.apiKey)
        apiTestResult = nil
        say?("key removed", .idle)
        rebuildPane()
    }

    @objc private func apiModelChanged() {
        guard let pop = modelPopup, let title = pop.titleOfSelectedItem else { return }
        AnthropicAPIClient.shared.model = title
    }

    @objc private func cliModelChanged() {
        guard let pop = cliModelPopup else { return }
        ZeraAssistant.shared.cliModel = Self.cliModelChoices[max(0, min(Self.cliModelChoices.count - 1, pop.indexOfSelectedItem))]
    }

    @objc private func timeoutChanged() {
        guard let pop = timeoutPopup else { return }
        ZeraAssistant.shared.timeout = TimeInterval(Self.timeoutChoices[max(0, min(Self.timeoutChoices.count - 1, pop.indexOfSelectedItem))])
    }

    @objc private func maxOutputChanged() {
        guard let pop = maxOutputPopup else { return }
        ZeraAssistant.shared.maxOutputTokens = Self.maxOutputChoices[max(0, min(Self.maxOutputChoices.count - 1, pop.indexOfSelectedItem))]
    }

    @objc private func diagnosticsTapped() { select(.diagnostics) }

    @objc private func saveOverrideTapped() {
        ClaudeCLI.shared.executableOverride = overrideField?.stringValue ?? ""
        ClaudeCLI.shared.ensureProbed(force: true) { [weak self] _ in self?.rebuildPane() }
        say?("re-checking Claude…", .thinking)
    }

    @objc private func recheckTapped() {
        ShellEnvironment.shared.refresh()
        ClaudeCLI.shared.ensureProbed(force: true) { [weak self] info in
            self?.rebuildPane()
            self?.say?(info.status == .connected ? "Claude's ready ✨" : info.status.label, info.status == .connected ? .approved : .thinking)
        }
    }

    @objc private func copyReportTapped() {
        let cli = ClaudeCLI.shared.info, a = ZeraAssistant.shared
        let lines = [
            "Zera diagnostics",
            "Claude CLI: \(cli.executable == nil ? cli.status.label : "Detected at \(cli.executableDisplay)")",
            "Version: \(cli.version ?? "-")",
            "Programmatic mode: \(cli.capabilities.programmaticOK ? "available" : "unavailable")",
            "Streaming: \(cli.capabilities.streamingOK ? "available" : "unavailable")",
            "Resume: \(cli.capabilities.resume ? "available" : "unavailable")",
            "Authentication: \(cli.loggedIn.map { $0 ? "signed in" : "not signed in" } ?? "unknown") \(cli.authMethod ?? "") \(cli.apiProvider ?? "")",
            "API key: \(AnthropicAPIClient.shared.isConfigured ? "configured" : "not configured")",
            "Provider setting: \(a.provider == .claudeCode ? "Claude Code" : "Anthropic API")",
            "Last run: \(a.lastRunSummary.isEmpty ? "-" : a.lastRunSummary)",
            "Last error output: \(a.debugLogging ? String(a.lastStderr.suffix(600)) : "(diagnostics logging off)")",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        say?("report copied 📋", .happy)
    }
    @objc private func clearShelfTapped() { ShelfStore.shared.clear(); say?("all tidy! ✨", .happy) }
    @objc private func openStagingTapped() { NSWorkspace.shared.open(ShelfStore.shared.stagingDir) }

    override func layout() {
        super.layout()
        layoutHeader()
        let x = Metrics.cardPad
        var y = headerBottom
        for row in navRows {
            row.frame = NSRect(x: x, y: y, width: sidebarW, height: Metrics.control)
            y += Metrics.control + Space.xs
        }
        let px = x + sidebarW + Space.m
        let pw = bounds.width - px - x
        if backButton.isHidden {
            paneTitle.frame = NSRect(x: px, y: headerBottom, width: pw, height: 18)
        } else {
            let bw = backButton.fittedWidth
            backButton.frame = NSRect(x: px - Space.s, y: headerBottom - 5, width: bw, height: Metrics.control)
            paneTitle.frame = NSRect(x: px + bw, y: headerBottom, width: pw - bw, height: 18)
        }
        pane.frame = NSRect(x: px, y: headerBottom + 24, width: pw, height: paneHeight)
    }
}

// MARK: - Claude Code approval

final class ApprovalCard: CardBase, CardContent {
    var cardWidth: CGFloat { 420 }
    var say: ((String, ZeraMood) -> Void)?
    var onDrained: (() -> Void)?

    private let tile = IconTile(symbol: "terminal.fill", color: Pal.tileClaude, size: 28, pointSize: 13)
    private let counter = NSTextField(labelWithString: "")
    private let commandBox = NSView()
    private let commandText = NSTextField(wrappingLabelWithString: "")
    private let riskChip = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let location = NSTextField(labelWithString: "")
    private let reject: CardButton
    private let approve: CardButton
    private var current: HookRequest?

    init() {
        reject = CardButton("Reject", style: .secondary, target: nil, action: #selector(ApprovalCard.rejectTapped))
        approve = CardButton("Approve", style: .primary, target: nil, action: #selector(ApprovalCard.approveTapped))
        super.init(width: 420, title: "Claude wants to run a command")
        let p = Pal
        reject.target = self; approve.target = self
        reject.keyEquivalent = "\u{1b}"; approve.keyEquivalent = "\r"
        addSubview(tile)
        counter.font = Typo.caption; counter.textColor = p.textTertiary; counter.alignment = .right; addSubview(counter)
        commandBox.wantsLayer = true
        commandBox.layer?.cornerRadius = Radius.m
        commandBox.layer?.cornerCurve = .continuous
        commandBox.layer?.backgroundColor = p.codeBox.cgColor
        addSubview(commandBox)
        commandText.font = Typo.mono
        commandText.textColor = p.codeText
        commandText.maximumNumberOfLines = 6
        commandText.lineBreakMode = .byTruncatingTail
        commandText.isSelectable = true
        commandBox.addSubview(commandText)
        riskChip.font = Typo.badge
        riskChip.wantsLayer = true
        riskChip.layer?.cornerRadius = Radius.s
        riskChip.alignment = .center
        riskChip.isHidden = true
        addSubview(riskChip)
        detail.font = Typo.caption; detail.textColor = p.text(0.8); detail.maximumNumberOfLines = 2; addSubview(detail)
        location.font = Typo.caption; location.textColor = p.textSecondary; location.lineBreakMode = .byTruncatingMiddle; addSubview(location)
        addSubview(reject); addSubview(approve)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ClaudeHookService.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Plain-language caution for commands that are hard to undo.
    private static func risk(of command: String) -> String? {
        let c = command.lowercased()
        let rules: [(String, String)] = [
            ("rm -rf", "Deletes files permanently"), ("rm -r", "Deletes directories"), ("sudo", "Runs with admin rights"),
            ("git push --force", "Rewrites remote history"), ("git push -f", "Rewrites remote history"), ("git reset --hard", "Discards local changes"),
            ("git clean", "Deletes untracked files"), ("chmod 777", "Opens permissions to everyone"), ("| sh", "Runs downloaded code"),
            ("| bash", "Runs downloaded code"), ("curl", "Fetches from the network"), ("wget", "Fetches from the network"),
            ("dd ", "Writes raw disk data"), ("mkfs", "Formats a disk"), ("> /dev/", "Writes to a device"), ("killall", "Kills processes"),
            ("npm publish", "Publishes a package"), ("docker system prune", "Deletes Docker data"),
        ]
        for (needle, why) in rules where c.contains(needle) { return why }
        return nil
    }

    private var commandHeight: CGFloat {
        let text = current?.command ?? ""
        let bound = (text as NSString).boundingRect(with: NSSize(width: cardWidth - Metrics.cardPad * 2 - Space.m * 2, height: 200),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Typo.mono])
        return min(96, max(18, ceil(bound.height))) + Space.m * 2
    }

    var desiredHeight: CGFloat {
        var h = headerBottom + commandHeight + Space.s
        if !riskChip.isHidden { h += 22 + Space.s }
        if !detail.isHidden { h += 18 + Space.xs }
        h += 16 + Space.l + Metrics.button + Metrics.cardPad
        return h
    }

    @objc func reload() {
        let hook = ClaudeHookService.shared, p = Pal
        current = hook.pending.first
        guard let req = current else { onDrained?(); return }
        titleLabel.stringValue = req.toolName == "Bash" ? "Claude wants to run a command" : "Claude wants to use \(req.toolName)"
        setSubtitle(req.sessionID.isEmpty ? nil : "Session \(req.sessionID.prefix(8))")
        counter.stringValue = hook.pending.count > 1 ? "1 of \(hook.pending.count)" : ""
        commandText.stringValue = req.command
        if let why = Self.risk(of: req.command) {
            riskChip.isHidden = false
            riskChip.stringValue = "  ⚠︎ \(why)  "
            riskChip.textColor = p.isDark ? p.warning : NSColor(srgbRed: 0.55, green: 0.35, blue: 0.0, alpha: 1)
            riskChip.layer?.backgroundColor = p.warning.withAlphaComponent(p.isDark ? 0.18 : 0.22).cgColor
        } else {
            riskChip.isHidden = true
        }
        detail.stringValue = req.detail ?? ""
        detail.isHidden = (req.detail ?? "").isEmpty
        location.stringValue = req.cwd.isEmpty ? "" : "in \(req.cwdDisplay)"
        approve.isEnabled = true; reject.isEnabled = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    @objc private func approveTapped() {
        guard let req = current else { return }
        approve.isEnabled = false; reject.isEnabled = false
        ClaudeHookService.shared.respond(req, allow: true)
        say?("approved ✅", .approved)
    }

    @objc private func rejectTapped() {
        guard let req = current else { return }
        approve.isEnabled = false; reject.isEnabled = false
        ClaudeHookService.shared.respond(req, allow: false)
        say?("okay, not running that", .sad)
    }

    override func layout() {
        super.layout()
        let x = Metrics.cardPad, w = bounds.width - x * 2
        tile.frame = NSRect(x: x, y: Space.l - 3, width: 28, height: 28)
        titleLabel.frame = NSRect(x: x + 36, y: Space.l, width: w - 36 - 70, height: 22)
        subtitleLabel.frame = NSRect(x: x + 36, y: Space.l + 22, width: w - 36, height: 16)
        counter.frame = NSRect(x: bounds.width - x - 70, y: Space.l + 3, width: 70, height: 16)
        var y = headerBottom
        let ch = commandHeight
        commandBox.frame = NSRect(x: x, y: y, width: w, height: ch)
        commandText.frame = NSRect(x: Space.m, y: Space.m, width: w - Space.m * 2, height: ch - Space.m * 2)
        y += ch + Space.s
        if !riskChip.isHidden {
            let cw = ceil((riskChip.stringValue as NSString).size(withAttributes: [.font: Typo.badge]).width) + 4
            riskChip.frame = NSRect(x: x, y: y, width: cw, height: 22); y += 22 + Space.s
        }
        if !detail.isHidden { detail.frame = NSRect(x: x, y: y, width: w, height: 18); y += 18 + Space.xs }
        location.frame = NSRect(x: x, y: y, width: w, height: 16)
        y += 16 + Space.l
        let aw = max(100, approve.fittedWidth), rw = max(88, reject.fittedWidth)
        approve.frame = NSRect(x: bounds.width - x - aw, y: y, width: aw, height: Metrics.button)
        reject.frame = NSRect(x: bounds.width - x - aw - Space.s - rw, y: y, width: rw, height: Metrics.button)
    }
}

// MARK: - Notification toast

/// Compact: "New PR opened · repo #125 · 2 min ago" with Review Now / Later.
final class ToastCard: CardBase, CardContent {
    var cardWidth: CGFloat { 400 }
    var onDismiss: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?

    private var tile: IconTile
    private let when = NSTextField(labelWithString: "")
    private let primary: CardButton
    private let later: CardButton
    private var url: URL?

    init() {
        tile = IconTile(symbol: "bell.fill", color: Pal.accent, size: 36, pointSize: 16)
        primary = CardButton("Open", style: .primary, target: nil, action: #selector(ToastCard.primaryTapped))
        later = CardButton("Later", style: .tertiary, target: nil, action: #selector(ToastCard.laterTapped))
        super.init(width: 400, title: "")
        primary.target = self; later.target = self
        addSubview(tile)
        when.font = Typo.caption; when.textColor = Pal.textTertiary; when.alignment = .right; addSubview(when)
        addSubview(primary); addSubview(later)
    }

    required init?(coder: NSCoder) { fatalError() }

    var desiredHeight: CGFloat { Space.l + 40 + Space.m + Metrics.button + Metrics.cardPad }

    func show(event e: GHEvent) {
        tile.removeFromSuperview()
        tile = IconTile(symbol: e.symbol, color: e.tint, size: 36, pointSize: 16)
        addSubview(tile)
        let heading: String, button: String
        switch e.kind {
        case .prOpened: heading = "New PR opened"; button = "Review Now"
        case .reviewRequested: heading = "Review requested"; button = "Review Now"
        case .ciFailed: heading = "CI failed"; button = "See why"
        case .ciPassed: heading = "CI passed"; button = "Open PR"
        case .ciRunning: heading = "Checks running"; button = "Open PR"
        case .needsApproval: heading = "Run waiting for approval"; button = "Open run"
        case .prApproved: heading = "Your PR was approved"; button = "Open PR"
        case .prChangesRequested: heading = "Changes requested"; button = "See review"
        case .prCommented: heading = "New comment on your PR"; button = "Reply"
        }
        titleLabel.stringValue = heading
        setSubtitle("\(e.subtitle) · \(e.title)")
        when.stringValue = relativeTime(e.date)
        primary.setTitleText(button)
        url = e.url
        needsLayout = true
    }

    @objc private func primaryTapped() { if let u = url { onOpenURL?(u) }; onDismiss?() }
    @objc private func laterTapped() { onDismiss?() }

    override func layout() {
        super.layout()
        let x = Metrics.cardPad, w = bounds.width - x * 2
        tile.frame = NSRect(x: x, y: Space.l, width: 36, height: 36)
        when.frame = NSRect(x: bounds.width - x - 70, y: Space.l + 2, width: 70, height: 14)
        titleLabel.frame = NSRect(x: x + 46, y: Space.l - 1, width: w - 46 - 76, height: 20)
        subtitleLabel.frame = NSRect(x: x + 46, y: Space.l + 20, width: w - 46, height: 16)
        let y = Space.l + 40 + Space.m
        let lw = later.fittedWidth, pw = primary.fittedWidth
        later.frame = NSRect(x: bounds.width - x - lw, y: y, width: lw, height: Metrics.button)
        primary.frame = NSRect(x: bounds.width - x - lw - Space.s - pw, y: y, width: pw, height: Metrics.button)
    }
}
