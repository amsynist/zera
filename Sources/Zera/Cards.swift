import AppKit
import ServiceManagement

/// Anything that can hang under Zera: tells the controller how big it wants to be.
protocol CardContent: NSView {
    var cardWidth: CGFloat { get }
    var desiredHeight: CGFloat { get }
    var onHeightChange: (() -> Void)? { get set }
}

/// A screen in the notch island: the island draws the glass, so this is just the standard
/// header — title and subtitle on the left of Zera, who hangs in the middle; buttons go on the
/// right. Cards are rebuilt when the palette changes, so colours are read once at construction.
class CardBase: NSView {
    var onHeightChange: (() -> Void)?
    /// Esc anywhere in the card.
    var onEscape: (() -> Void)?

    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    /// Y where content starts, under the header row Zera hangs in.
    var headerBottom: CGFloat { Isle.headerHeight }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(width: CGFloat, title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        let p = Pal
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
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

    /// Lays out the header; subclasses call this first in `layout()`. The title stays left of
    /// Zera's spot in the middle; `trailingWidth` is room kept free on the right for buttons.
    func layoutHeader(trailingWidth: CGFloat = 0) {
        let w = min(bounds.width - Metrics.cardPad * 2 - trailingWidth, bounds.width / 2 - Isle.zeraGap / 2 - Metrics.cardPad)
        let top: CGFloat = subtitleLabel.isHidden ? 33 : 24
        titleLabel.frame = NSRect(x: Metrics.cardPad + 4, y: top, width: max(0, w), height: 22)
        subtitleLabel.frame = NSRect(x: Metrics.cardPad + 4, y: top + 22, width: max(0, w), height: 16)
    }

    /// The header's right side, for buttons: everything right of Zera's spot.
    var headerTrailingRect: NSRect {
        let x = bounds.width / 2 + Isle.zeraGap / 2
        return NSRect(x: x, y: 26, width: bounds.width - Metrics.cardPad - x, height: 36)
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

    /// Glass row: a navy step up with a soft blue edge that lights up under the pointer.
    private func restyle() {
        let p = Pal
        let hot = hovered && onTap != nil
        layer?.backgroundColor = (selected ? p.accentSoft : (hot ? p.surfaceHover : p.surfaceRow)).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (selected ? p.selectedEdge : (hot ? p.accent.withAlphaComponent(0.45) : p.divider)).cgColor
        layer?.masksToBounds = false
        layer?.shadowColor = p.accent.cgColor
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero
        layer?.shadowOpacity = hot ? 0.25 : 0
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
        layer?.backgroundColor = (selected ? p.selectedFill : (hovered ? p.surfaceHover : .clear)).cgColor
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = p.selectedEdge.cgColor
        icon.contentTintColor = selected ? p.selectedAccent : p.textSecondary
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
    private var hovered = false {
        didSet {
            layer?.backgroundColor = (hovered ? Pal.surfaceHover : Pal.surfaceRow).cgColor
            layer?.borderColor = (hovered ? Pal.accent.withAlphaComponent(0.45) : Pal.divider).cgColor
        }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbol: String, color: NSColor, title t: String) {
        tile = IconTile(symbol: symbol, color: color, size: 26, pointSize: 12)
        super.init(frame: .zero)
        roundLayer(Radius.l)
        layer?.backgroundColor = Pal.surfaceRow.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Pal.divider.cgColor
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
        // Small caps label, quiet, so the rows carry the weight.
        title.attributedStringValue = NSAttributedString(string: t.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: Pal.textTertiary, .kern: 0.8])
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

    /// One word for the Home tiles, which sit six in a row.
    var tileTitle: String {
        switch self {
        case .openClaude: return "Claude"
        case .dropFiles: return "Files"
        case .newNote: return "Note"
        case .takeBreak: return "Break"
        case .screenshot: return "Screenshot"
        case .startTimer: return "Timer"
        case .searchFiles: return "Search"
        case .askZera: return "Ask"
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

/// "What does Zera want me to know right now?" Greeting in the header → ask Zera → what needs
/// you (up to three) → one row of quick actions. Recent files live on the Files tab.
final class HomeCard: CardBase, CardContent, NSTextFieldDelegate {
    var cardWidth: CGFloat { 540 }
    var onOpen: ((CardKind) -> Void)?
    var onAction: ((QuickAction) -> Void)?
    var onOpenURL: ((URL) -> Void)?

    private let search = SearchBox(placeholder: "Ask Zera anything, or search recent files…")
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
        super.init(width: 540, title: "")
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
            let t = ActionTile(symbol: a.symbol, color: a.color, title: a.tileTitle)
            t.onTap = { [weak self] in self?.onAction?(a) }
            addSubview(t)
            tiles.append(t)
        }
        for name in [ShelfStore.changed, GitHubService.changed, ClaudeHookService.changed, ReminderService.changed, ClaudeActivityService.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focusSearch() { window?.makeKey(); window?.makeFirstResponder(search.field) }

    private let tileHeight: CGFloat = 54
    private let rowH: CGFloat = 46
    private static let maxAttention = 3

    private func listHeight(_ n: Int) -> CGFloat { n == 0 ? 20 : CGFloat(n) * (rowH + 6) - 6 }

    var desiredHeight: CGFloat {
        var h = headerBottom + 36 + Space.l
        h += 18 + Space.s + listHeight(query.isEmpty ? attentionRows.count : recentRows.count) + Space.l
        h += 18 + Space.s + tileHeight + Metrics.cardPad
        return h
    }

    @objc func refresh() {
        let p = Pal
        let hour = Calendar.current.component(.hour, from: Date())
        titleLabel.stringValue = hour < 12 ? "Good morning" : (hour < 17 ? "Good afternoon" : "Good evening")

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
        if let s = ClaudeActivityService.shared.active.first {
            let waiting = s.status == .waiting
            let r = ListRow(symbol: waiting ? "hand.raised.fill" : "terminal.fill", color: p.tileClaude,
                            title: waiting ? "Claude is waiting for you" : "Claude is working in \(s.folderName)",
                            subtitle: s.currentStep?.text ?? (s.title.isEmpty ? "Claude Code session" : s.title))
            r.showsChevron = true; r.emphasized = waiting
            r.onTap = { [weak self] in self?.onOpen?(.claude) }
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
        let overdue = rs.overdueReminders()
        if !overdue.isEmpty, alerts.isEmpty {
            let r = ListRow(symbol: "clock.badge.exclamationmark", color: p.warning,
                            title: overdue.count == 1 ? "\(overdue[0].title) is overdue" : "\(overdue.count) reminders overdue",
                            subtitle: overdue.map { $0.title }.joined(separator: " · "))
            r.onTap = { [weak self] in self?.onOpen?(.reminders) }
            attentionRows.append(r)
        }
        if let next = rs.nextEvent(within: 3600) {
            let r = ListRow(symbol: "calendar", color: p.tileCalendar, title: next.event.title,
                            subtitle: "in \(max(1, Int(next.start.timeIntervalSinceNow / 60))) min · \(ReminderService.timeFormatter.string(from: next.start))")
            r.onTap = { [weak self] in self?.onOpen?(.reminders) }
            attentionRows.append(r)
        }
        let needs = attentionRows.count
        attentionRows = Array(attentionRows.prefix(Self.maxAttention))
        for r in attentionRows { addSubview(r) }
        allClear.isHidden = !attentionRows.isEmpty
        allClear.stringValue = "All clear — nothing needs you right now ✨"
        let day = Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        setSubtitle(needs == 0 ? "\(day) · all clear" : "\(day) · \(needs) thing\(needs == 1 ? "" : "s") need\(needs == 1 ? "s" : "") you")

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
        // Recent shows only while you search: the matches, so Return can still ask Zera instead.
        for (_, text, r) in entries where !query.isEmpty && text.localizedCaseInsensitiveContains(query) {
            addSubview(r)
            recentRows.append(r)
            if recentRows.count == Self.maxAttention { break }
        }
        recentEmpty.isHidden = true
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
        search.frame = NSRect(x: x, y: y, width: w, height: 36)
        y += 36 + Space.l

        // While searching, the matches take the place of "Needs you".
        let searching = !query.isEmpty
        attentionHeader.title.attributedStringValue = NSAttributedString(string: searching ? "MATCHES" : "NEEDS YOU", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: Pal.textTertiary, .kern: 0.8])
        let shown = searching ? recentRows : attentionRows
        attentionRows.forEach { $0.isHidden = searching }
        recentRows.forEach { $0.isHidden = !searching }
        attentionHeader.frame = NSRect(x: x, y: y, width: w, height: 18); y += 18 + Space.s
        if shown.isEmpty {
            allClear.isHidden = false
            allClear.stringValue = searching ? "No match — press Return to ask Zera." : "All clear — nothing needs you right now ✨"
            allClear.frame = NSRect(x: x + Space.xs, y: y, width: w - Space.xs, height: 20)
            y += 20
        } else {
            allClear.isHidden = true
            for r in shown { r.frame = NSRect(x: x, y: y, width: w, height: rowH); y += rowH + 6 }
            y -= 6
        }
        y += Space.l

        quickHeader.frame = NSRect(x: x, y: y, width: w, height: 18); y += 18 + Space.s
        let n = CGFloat(max(1, tiles.count))
        let tw = (w - Space.s * (n - 1)) / n
        for (i, t) in tiles.enumerated() {
            t.frame = NSRect(x: x + CGFloat(i) * (tw + Space.s), y: y, width: tw, height: tileHeight)
        }
        recentHeader.isHidden = true
        recentEmpty.isHidden = true
    }
}

// MARK: - GitHub
//
// The PR screen lives in GitHubCard.swift; its building blocks in GitHubComponents.swift.

// MARK: - Settings

final class SettingsCard: CardBase, CardContent {
    var cardWidth: CGFloat { 560 }
    var onDefaultChanged: ((CardKind?) -> Void)?
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
        static let nav: [Pane] = [.general, .integrations, .shortcuts, .about]
    }

    private var navRows: [NavRow] = []
    private let paneTitle = NSTextField(labelWithString: "")
    private let closeButton: IconButton
    private let backButton: CardButton
    private let pane = FlippedView()
    private(set) var current: Pane = .general
    private var defaultKind: CardKind?
    private let showingZera: Bool
    private let sidebarW: CGFloat = 150
    private var paneHeight: CGFloat = 200

    init(defaultKind: CardKind?, showingZera: Bool, loginEnabled: Bool) {
        self.defaultKind = defaultKind
        self.showingZera = showingZera
        backButton = CardButton("Integrations", style: .tertiary, symbol: "chevron.left", target: nil, action: #selector(SettingsCard.backTapped))
        closeButton = IconButton(symbol: "xmark", label: "Close", target: nil, action: #selector(SettingsCard.closeTapped))
        super.init(width: 560, title: "Settings")
        backButton.target = self
        closeButton.target = self
        addSubview(closeButton)
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
        for name in [GitHubService.changed, ClaudeHookService.changed, ReminderService.changed, ShelfStore.changed, ClaudeCLI.changed, ClaudeActivityService.changed] {
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
    @objc private func closeTapped() { onEscape?() }

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
    private static let defaultChoices: [CardKind?] = [.shelf, .home, .claude, .reminders, .github, nil]
    private static let breakChoices = [0, 30, 45, 60, 90, 120]

    private func buildGeneral(_ s: inout Stack) {
        defaultPopup = popupRow("Tap on Zera opens", items: Self.defaultChoices.map { $0?.title ?? "Nothing" },
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
        // Right side: the switch, then a gear that opens the detail pane (mock #3).
        let box = FlippedView()
        var bx: CGFloat = 0
        if toggle {
            let t = Toggle()
            t.isOn = on
            t.isEnabled = enabled
            t.onChange = onChange
            t.frame = NSRect(x: 0, y: 3, width: 40, height: 22)
            box.addSubview(t)
            bx = 40 + Space.s
        }
        if let target = target {
            let gear = IconButton(symbol: "gearshape.fill", label: "\(title) settings", target: nil, action: #selector(integrationGearTapped(_:)))
            gear.target = self
            gear.tag = target.rawValue
            gear.frame = NSRect(x: bx, y: 0, width: Metrics.control, height: Metrics.control)
            box.addSubview(gear)
            bx += Metrics.control
            row.onTap = { [weak self] in self?.select(target) }
        }
        box.frame = NSRect(x: 0, y: 0, width: bx, height: Metrics.control)
        row.accessory = box
        pane.addSubview(row)
        s.place(row, height: 52, gap: Space.xs + 2)
    }

    @objc private func integrationGearTapped(_ sender: NSButton) {
        if let p = Pane(rawValue: sender.tag) { select(p) }
    }

    private func buildIntegrations(_ s: inout Stack) {
        let hook = ClaudeHookService.shared, gh = GitHubService.shared, rs = ReminderService.shared, p = Pal
        let (claudeState, claudeDetail) = Self.claudeSummary()
        integrationRow(symbol: "sparkles", color: p.tileClaude, title: "Claude",
                       state: claudeState, detail: claudeDetail + (hook.isInstalled ? " · approvals" : "") + (ClaudeActivityService.shared.isInstalled ? " · live progress" : ""),
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
        integrationRow(symbol: "n.square.fill", color: p.muted, title: "Notion", state: .disconnected, detail: "notes and pages · coming soon",
                       on: false, enabled: false, &s, pane: nil) { _ in }
        integrationRow(symbol: "number.square.fill", color: p.muted, title: "Slack", state: .disconnected, detail: "messages and mentions · coming soon",
                       on: false, enabled: false, &s, pane: nil) { _ in }
        let add = CardButton("Add Integration", style: .tertiary, symbol: "plus", target: nil, action: #selector(closeTapped))
        add.isEnabled = false
        pane.addSubview(add)
        s.place(add, height: Metrics.button, gap: Space.m)
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

        sectionLabel("Live progress · Claude Code sessions", &s)
        let act = ClaudeActivityService.shared
        statusLine(act.isInstalled ? .connected : .disconnected,
                   detail: act.isInstalled ? (act.active.isEmpty ? "no session running" : "\(act.active.count) session\(act.active.count == 1 ? "" : "s") running") : "see Reading → Editing → Running → Done as it happens", &s)
        buttonRow(act.isInstalled ? "Stop following" : "Follow Claude's work", style: act.isInstalled ? .secondary : .primary,
                  status: act.isInstalled ? "Non-blocking hooks; nothing is sent anywhere" : "Adds non-blocking hooks to ~/.claude/settings.json", &s, action: #selector(activityTapped))

        sectionLabel("Approvals · Claude Code hook", &s)
        statusLine(hook.isInstalled ? .connected : .disconnected,
                   detail: hook.isInstalled ? (hook.pending.isEmpty ? "Permission prompts show up here" : "\(hook.pending.count) waiting") : "approve commands from Zera instead of the terminal", &s)
        buttonRow(hook.isInstalled ? "Remove hook" : "Install hook", style: hook.isInstalled ? .secondary : .primary,
                  status: hook.isInstalled ? "Restart open Claude Code sessions after changes" : "Adds a PermissionRequest hook to ~/.claude/settings.json", &s, action: #selector(claudeTapped))
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
            hint("Paste a fine-grained token with read access to Pull requests, Checks and Actions (Actions: write only if you want Approve). Kept in your Keychain, only ever sent to api.github.com.", &s)
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
                  status: rs.calendarAuthorized ? "The next two weeks are loaded" : "macOS will ask once", &s, action: #selector(calendarTapped))
        if rs.calendarAuthorized {
            buttonRow("Sync now", style: .secondary, status: rs.lastCalendarSync.map { "Last sync \(relativeTime($0))" } ?? "", &s, action: #selector(calendarSyncTapped))
        }
    }

    private func buildShelf(_ s: inout Stack) {
        let n = ShelfStore.shared.items.count
        statusLine(.connected, detail: n == 0 ? "nothing held" : (n == 1 ? "holding 1 item" : "holding \(n) items"), &s)
        hint("Files are referenced, not copied. Pasted text and images live in a staging folder until you remove them.", &s)
        buttonRow("Open staging folder", style: .secondary, status: "~/Library/Application Support/Zera/Staged", &s, action: #selector(openStagingTapped))
        buttonRow("Clear shelf", style: .destructive, status: "Takes everything off the Shelf — your files stay on your Mac", &s, action: #selector(clearShelfTapped))
    }

    private func buildShortcuts(_ s: inout Stack) {
        let items: [(String, String)] = [
            ("Open the default card", "Tap Zera"), ("Show the pill", "Hover Zera"), ("Move Zera along the top", "Drag her"),
            ("Close any card", "Esc"), ("Approve / reject a Claude command", "⏎ / Esc"), ("Add an event or reminder", "+ Add Event ▾"),
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
        defaultKind = Self.defaultChoices[max(0, min(Self.defaultChoices.count - 1, pop.indexOfSelectedItem))]
        onDefaultChanged?(defaultKind)
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

    @objc private func activityTapped() {
        let act = ClaudeActivityService.shared
        do {
            if act.isInstalled { try act.uninstall(); say?("okay, I'll stop following Claude", .idle) }
            else { try act.install(); say?("I'll show Claude's progress live 💜 Restart open sessions.", .approved) }
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
        layoutHeader(trailingWidth: 40)
        let x = Metrics.cardPad
        closeButton.frame = NSRect(x: bounds.width - x - Metrics.control, y: 30, width: Metrics.control, height: Metrics.control)
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
    var cardWidth: CGFloat { 560 }
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
        reject = CardButton("Reject", style: .destructive, target: nil, action: #selector(ApprovalCard.rejectTapped))
        approve = CardButton("Approve", style: .success, target: nil, action: #selector(ApprovalCard.approveTapped))
        super.init(width: 560, title: "Claude wants to run a command")
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
        return h + Metrics.cardPad
    }

    @objc func reload() {
        let hook = ClaudeHookService.shared, p = Pal
        current = hook.pending.first
        guard let req = current else { onDrained?(); return }
        titleLabel.stringValue = req.toolName == "Bash" ? "Claude wants to run a command" : "Claude wants to use \(req.toolName)"
        setSubtitle(req.cwd.isEmpty ? (req.sessionID.isEmpty ? nil : "Session \(req.sessionID.prefix(8))") : req.cwdDisplay)
        titleLabel.stringValue = req.toolName == "Bash" ? "Run this command?" : "Use \(req.toolName)?"
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
        // Island header: what Claude wants and where, left of Zera; Reject / Approve on the right.
        let x = Metrics.cardPad, w = bounds.width - x * 2
        tile.isHidden = true
        layoutHeader()
        let aw = max(96, approve.fittedWidth), rw = max(84, reject.fittedWidth)
        approve.frame = NSRect(x: bounds.width - x - aw, y: 29, width: aw, height: 30)
        reject.frame = NSRect(x: approve.frame.minX - Space.s - rw, y: 29, width: rw, height: 30)
        counter.frame = NSRect(x: reject.frame.minX - 70, y: 36, width: 62, height: 16)
        location.isHidden = true
        var y = headerBottom
        let ch = commandHeight
        commandBox.frame = NSRect(x: x, y: y, width: w, height: ch)
        commandText.frame = NSRect(x: Space.m, y: Space.m, width: w - Space.m * 2, height: ch - Space.m * 2)
        y += ch + Space.s
        if !riskChip.isHidden {
            let cw = ceil((riskChip.stringValue as NSString).size(withAttributes: [.font: Typo.badge]).width) + 4
            riskChip.frame = NSRect(x: x, y: y, width: cw, height: 22); y += 22 + Space.s
        }
        if !detail.isHidden { detail.frame = NSRect(x: x, y: y, width: w, height: 18) }
    }
}

// MARK: - Notification toast

/// Compact: "New PR opened · repo #125 · 2 min ago" with Review Now / Later.
final class ToastCard: CardBase, CardContent, TimedNotificationBanner {
    var cardWidth: CGFloat { 520 }
    let countdownLine = BannerCountdownLine()
    var onDismiss: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?

    private var tile: IconTile
    private let when = NSTextField(labelWithString: "")
    private let primary: CardButton
    private let dismiss: IconButton
    private let zera = ZeraCompanion(pose: "card_notify", size: 74)
    private var url: URL?

    init() {
        tile = IconTile(symbol: "bell.fill", color: Pal.accent, size: 36, pointSize: 16)
        primary = CardButton("Open", style: .primary, target: nil, action: #selector(ToastCard.primaryTapped))
        dismiss = IconButton(symbol: "xmark", label: "Dismiss notification", target: nil, action: #selector(ToastCard.dismissTapped))
        super.init(width: 520, title: "")
        primary.target = self; dismiss.target = self
        addSubview(tile)
        when.font = Typo.caption; when.textColor = Pal.textTertiary; when.alignment = .right; addSubview(when)
        addSubview(zera)
        addSubview(primary); addSubview(dismiss)
        addSubview(countdownLine)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A banner: just the header row (Zera hangs in its middle), plus a little air.
    var desiredHeight: CGFloat { headerBottom + 6 }

    func show(event e: GHEvent) {
        tile.removeFromSuperview()
        tile = IconTile(symbol: e.symbol, color: e.tint, size: 36, pointSize: 16)
        addSubview(tile)
        let heading: String, button: String, pose: String, line: String
        switch e.kind {
        case .prOpened:
            heading = e.mine ? "Your PR is up" : "New PR opened"; button = e.mine ? "Open PR" : "Review Now"
            pose = e.mine ? "card_cheer" : "card_notify"; line = e.mine ? "Nice one! It's live 🚀" : "New PR! Want me to take a look? 👀"
        case .reviewRequested: heading = "Review requested"; button = "Review Now"; pose = "card_point_sparkle"; line = "They'd like your eyes on this one 📝"
        case .ciFailed: heading = "CI failed"; button = "See why"; pose = "worried"; line = "Something broke in the checks 😬"
        case .ciPassed: heading = "CI passed"; button = "Open PR"; pose = "card_thumbs_wink"; line = "All green! ✅"
        case .ciRunning: heading = "Checks running"; button = "Open PR"; pose = "card_laptop_side"; line = "Checks are running… ⏳"
        case .needsApproval: heading = "Run waiting for approval"; button = "Open run"; pose = "card_bell"; line = "A workflow needs your OK 🙋"
        case .prApproved: heading = "Your PR was approved"; button = "Open PR"; pose = "card_cheer"; line = "Approved! Ship it? 🎉"
        case .prChangesRequested: heading = "Changes requested"; button = "See review"; pose = "card_read_q"; line = "A few changes asked for 📝"
        case .prCommented: heading = "New comment on your PR"; button = "Reply"; pose = "card_notify"; line = "Someone left you a comment 💬"
        }
        zera.set(pose: pose)
        zera.line = line
        titleLabel.stringValue = heading
        setSubtitle("\(e.subtitle) · \(e.title) · \(relativeTime(e.date))")
        when.stringValue = relativeTime(e.date)
        primary.setTitleText(button)
        url = e.url
        needsLayout = true
    }

    @objc private func primaryTapped() { if let u = url { onOpenURL?(u) }; onDismiss?() }
    @objc private func dismissTapped() { onDismiss?() }

    override func mouseUp(with event: NSEvent) { onDismiss?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func layout() {
        super.layout()
        // Banner: icon · heading / detail left of Zera; the action and dismiss on the right.
        let x = Metrics.cardPad
        zera.isHidden = true
        when.isHidden = true
        tile.frame = NSRect(x: x, y: 26, width: 36, height: 36)
        let half = bounds.width / 2 - Isle.zeraGap / 2
        titleLabel.frame = NSRect(x: x + 46, y: 25, width: max(0, half - x - 46), height: 20)
        subtitleLabel.frame = NSRect(x: x + 46, y: 46, width: max(0, half - x - 46), height: 16)
        let pw = primary.fittedWidth
        dismiss.frame = NSRect(x: bounds.width - x - Metrics.control, y: 30, width: Metrics.control, height: Metrics.control)
        primary.frame = NSRect(x: dismiss.frame.minX - Space.s - pw, y: 29, width: pw, height: 30)
        countdownLine.frame = NSRect(x: 18, y: bounds.height - 8, width: max(0, bounds.width - 36), height: 2)
    }
}
