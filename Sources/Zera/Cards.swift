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
    /// Zera is speaking in the header's second line: keep the title up top to make room.
    var whispering = false { didSet { if whispering != oldValue { needsLayout = true } } }
    /// Y where content starts, under the header row Zera hangs in.
    var headerBottom: CGFloat { Isle.headerHeight }
    /// v2: the title sits under the rail, which hangs in the header's top 44 pt.
    static let titleTop: CGFloat = 56
    static var subtitleTop: CGFloat { titleTop + 34 }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(width: CGFloat, title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        let p = Pal
        titleLabel.stringValue = title
        titleLabel.font = Typo.screenTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = p.text
        addSubview(titleLabel)
        subtitleLabel.font = Typo.screenSubtitle
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
        let top: CGFloat = subtitleLabel.isHidden && !whispering ? Self.titleTop + 8 : Self.titleTop
        titleLabel.frame = NSRect(x: Metrics.cardPad, y: top, width: max(0, w), height: 32)
        subtitleLabel.frame = NSRect(x: Metrics.cardPad, y: top + 34, width: max(0, w), height: 18)
    }

    /// The header's right side, for buttons: everything right of Zera's spot.
    var headerTrailingRect: NSRect {
        let x = bounds.width / 2 + Isle.zeraGap / 2
        return NSRect(x: x, y: Self.titleTop + 2, width: bounds.width - Metrics.cardPad - x, height: 36)
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
    var emphasized = false { didSet { title.font = emphasized ? Typo.rowTitleStrong : Typo.rowTitle } }
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
        title.font = Typo.rowTitle
        title.textColor = Pal.text
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        subtitle.stringValue = s
        subtitle.font = Typo.meta
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

    /// Glass row: one step up from the glass, a step brighter under the pointer.
    private func restyle() {
        let p = Pal
        let hot = hovered && onTap != nil
        layer?.backgroundColor = (selected ? p.accentSoft : (hot ? p.surfaceHover : p.surfaceRow)).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (selected ? p.selectedEdge : p.divider).cgColor
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        // Standard rows (52) carry the standard 36 pt tile; shorter ones keep the compact one.
        let ts: CGFloat = h >= RowTier.standard.height - 2 ? RowTier.standard.tile : Metrics.icon
        tile.frame = NSRect(x: Space.m, y: (h - ts) / 2, width: ts, height: ts)
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
        let textX = tile.frame.maxX + Space.m
        let textW = max(20, right - textX)
        if subtitle.stringValue.isEmpty {
            title.frame = NSRect(x: textX, y: (h - 18) / 2, width: textW, height: 18)
            subtitle.isHidden = true
        } else {
            title.frame = NSRect(x: textX, y: (h / 2 - 18).rounded(), width: textW, height: 18)
            subtitle.frame = NSRect(x: textX, y: (h / 2 + 1).rounded(), width: textW, height: 16)
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
    /// The sidebar draws the selected wash itself, gliding from row to row.
    var washManaged = false { didSet { restyle() } }
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
        let wash = selected && !washManaged
        layer?.backgroundColor = (wash ? p.selectedFill : (hovered && !selected ? p.surfaceHover : .clear)).cgColor
        layer?.borderWidth = wash ? 1 : 0
        layer?.borderColor = p.selectedEdge.cgColor
        icon.contentTintColor = selected ? p.text : p.textSecondary
        title.textColor = selected ? p.text : p.textSecondary
        // One weight in both states, so the label never shifts when you pick a pane.
        title.font = Typo.chip
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

/// Square tile for the Quick Actions grid.
final class ActionTile: NSView {
    var onTap: (() -> Void)?
    private let symbol: String
    private let tint: NSColor
    private let title = NSTextField(labelWithString: "")
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// v2: a pill chip — the action's glyph in its colour, then its name.
    init(symbol: String, color: NSColor, title t: String) {
        self.symbol = symbol
        self.tint = color
        super.init(frame: .zero)
        title.stringValue = t
        title.font = Typo.chip
        title.textColor = Pal.text(0.88)
        title.lineBreakMode = .byClipping
        addSubview(title)
        setAccessibilityRole(.button)
        setAccessibilityLabel(t)
    }

    required init?(coder: NSCoder) { fatalError() }

    static let height: CGFloat = 34
    private static let glyph: CGFloat = 16
    var fittedWidth: CGFloat { ceil(14 + Self.glyph + 8 + title.intrinsicContentSize.width + 16) }

    override func layout() {
        super.layout()
        let th = title.intrinsicContentSize.height
        title.frame = NSRect(x: 14 + Self.glyph + 8, y: ((bounds.height - th) / 2).rounded(), width: max(0, bounds.width - 14 - Self.glyph - 8 - 12), height: th)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (pressed ? p.surfacePressed : (hovered ? p.surfaceHover : p.surface)).setFill(); shape.fill()
        Neon.symbol(symbol, in: NSRect(x: 14, y: 0, width: Self.glyph, height: bounds.height), size: 12, weight: .semibold,
                    color: tint.blended(withFraction: 0.25, of: .white) ?? tint)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap?() }
    }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
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
        title.attributedStringValue = Typo.sectionText(t)
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
    case openClaude, dropFiles, clipboard, newNote, takeBreak, screenshot, startTimer, searchFiles
    /// A question typed into Home — answered inside Zera, no file attached.
    case askZera(String)

    var title: String {
        switch self {
        case .openClaude: return "Open Claude"
        case .dropFiles: return "Drop Files"
        case .clipboard: return "Clipboard"
        case .newNote: return "New Note"
        case .takeBreak: return "Take a Break"
        case .screenshot: return "Screenshot"
        case .startTimer: return "Start Timer"
        case .searchFiles: return "Search Files"
        case .askZera: return "Ask Zera"
        }
    }

    /// One word for the Home tiles, which sit seven in a row.
    var tileTitle: String {
        switch self {
        case .openClaude: return "Claude"
        case .dropFiles: return "Files"
        case .clipboard: return "Clipboard"
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
        case .clipboard: return "doc.on.clipboard.fill"
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
        case .clipboard: return p.info
        case .newNote: return p.tileNote
        case .takeBreak: return p.info
        case .screenshot: return p.accentSoft.blended(withFraction: 0.5, of: p.accent) ?? p.accent
        case .startTimer: return p.success
        case .searchFiles: return p.tileLink
        }
    }

    static let grid: [QuickAction] = [.openClaude, .dropFiles, .clipboard, .newNote, .takeBreak, .screenshot, .startTimer]
}

// MARK: - Home

/// "What does Zera want me to know right now?" Greeting in the header → ask Zera → what needs
/// you (up to three) → one row of quick actions. Recent files live on the Files tab.
final class HomeCard: CardBase, CardContent, NSTextFieldDelegate {
    /// Wide enough for seven quick-action labels ("Clipboard", "Screenshot") in full.
    var cardWidth: CGFloat { Isle.lensWidth }
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
    /// The Mac's vitals (v2): five tiles under "This Mac"; any of them opens the This Mac page.
    private let vitalsStrip = VitalsOrgans()
    private let macHeader = SectionHeader("This Mac")
    private let macHint = NSTextField(labelWithString: "tap a vital to open it")
    private let vitalsPage = VitalsPage()
    private var backButton: GHSquareButton!
    private var showingVitals = false
    private var watchingVitals = false

    init() {
        super.init(width: 540, title: "")
        let p = Pal
        search.field.delegate = self
        addSubview(search)
        vitalsStrip.onOpen = { [weak self] in self?.setVitals(true) }
        addSubview(vitalsStrip)
        addSubview(macHeader)
        macHint.font = Typo.caption; macHint.textColor = p.textTertiary; macHint.alignment = .right
        addSubview(macHint)
        vitalsPage.isHidden = true
        addSubview(vitalsPage)
        backButton = GHSquareButton(symbol: "chevron.left", label: "Back", target: self, action: #selector(backTapped))
        backButton.isHidden = true
        addSubview(backButton)
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
            NotificationCenter.default.addObserver(self, selector: #selector(refreshIfVisible), name: name, object: nil)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focusSearch() { window?.makeKey(); window?.makeFirstResponder(search.field) }

    /// Each time the island opens on Home: back to the main page.
    func willShow() {
        if showingVitals { setVitals(false, animated: false) }
        refresh()
    }

    @objc private func backTapped() { setVitals(false) }

    /// Opens or closes the This Mac page, sliding like any other page.
    func setVitals(_ on: Bool, animated: Bool = true) {
        guard on != showingVitals else { return }
        showingVitals = on
        [search, vitalsStrip, macHeader, macHint, attentionHeader, allClear, quickHeader].forEach { $0.isHidden = on }
        (attentionRows + recentRows + tiles).forEach { $0.isHidden = on }
        vitalsPage.isHidden = !on
        backButton.isHidden = !on
        let tiles = vitalsStrip.frame
        refresh()
        if animated {
            // A vital grows into This Mac; Back slides Home back in.
            layoutSubtreeIfNeeded()
            if on { Motion.grow(vitalsPage, from: tiles) } else { Motion.page(search, forward: false) }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if showingVitals { setVitals(false) } else { onEscape?() }
    }

    // Readings run only while Home is on screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let on = window != nil
        guard on != watchingVitals else { return }
        watchingVitals = on
        if on { SystemVitals.shared.watch() } else { SystemVitals.shared.unwatch() }
    }
    deinit { if watchingVitals { SystemVitals.shared.unwatch() } }

    private let tileHeight: CGFloat = ActionTile.height
    private let rowH: CGFloat = RowTier.standard.height
    /// Up to three rows; the subtitle still counts everything waiting.
    private static let maxAttention = 3

    private func listHeight(_ n: Int) -> CGFloat { n == 0 ? 20 : CGFloat(n) * (rowH + Metrics.rowGap) - Metrics.rowGap }

    var desiredHeight: CGFloat {
        if showingVitals { return headerBottom + VitalsPage.height + Metrics.cardPad }
        var h = headerBottom
        h += 18 + Space.m + listHeight(query.isEmpty ? attentionRows.count : recentRows.count) + Space.xxl
        h += 18 + Space.m + VitalsOrgans.height + Space.xxl
        h += 18 + Space.m + tileHeight + Space.xxl + 4
        return h
    }

    @objc func refresh() {
        let p = Pal
        let hour = Calendar.current.component(.hour, from: Date())
        titleLabel.stringValue = showingVitals ? "This Mac" : (hour < 12 ? "Good morning" : (hour < 17 ? "Good afternoon" : "Good evening"))

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
        for r in attentionRows { r.isHidden = showingVitals; addSubview(r) }
        allClear.isHidden = showingVitals || !attentionRows.isEmpty
        allClear.stringValue = "All clear — nothing needs you right now ✨"
        let day = Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        setSubtitle(showingVitals ? VitalsPage.subtitle
                    : (needs == 0 ? "\(day) · all clear" : "\(day) · \(needs) thing\(needs == 1 ? "" : "s") need\(needs == 1 ? "s" : "") you"))

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
            r.isHidden = showingVitals
            addSubview(r)
            recentRows.append(r)
            if recentRows.count == Self.maxAttention { break }
        }
        recentEmpty.isHidden = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    @objc private func refreshIfVisible() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        refresh()
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
        if !showingVitals {
            // Ask Zera sits right of her, level with the greeting.
            let t = headerTrailingRect
            search.frame = NSRect(x: t.minX + 8, y: t.midY - Metrics.field / 2, width: t.width - 8, height: Metrics.field)
        }
        if showingVitals {
            // Back button first; the title and subtitle move over for it.
            let mid = headerTrailingRect.midY
            backButton.frame = NSRect(x: x, y: mid - Metrics.headerButton / 2, width: Metrics.headerButton, height: Metrics.headerButton)
            let shift = Metrics.headerButton + Space.m
            titleLabel.frame.origin.x += shift - 4; titleLabel.frame.size.width -= shift
            subtitleLabel.frame.origin.x += shift - 4; subtitleLabel.frame.size.width -= shift
            vitalsPage.frame = NSRect(x: x, y: y, width: w, height: VitalsPage.height)
            return
        }
        // While searching, the matches take the place of "Needs you".
        let searching = !query.isEmpty
        attentionHeader.title.attributedStringValue = Typo.sectionText(searching ? "Matches" : "Needs you")
        let shown = searching ? recentRows : attentionRows
        attentionRows.forEach { $0.isHidden = searching }
        recentRows.forEach { $0.isHidden = !searching }
        attentionHeader.frame = NSRect(x: x, y: y, width: w, height: 18); y += 18 + Space.m
        if shown.isEmpty {
            allClear.isHidden = false
            allClear.stringValue = searching ? "No match — press Return to ask Zera." : "All clear — nothing needs you right now ✨"
            allClear.frame = NSRect(x: x + Space.xs, y: y, width: w - Space.xs, height: 20)
            y += 20
        } else {
            allClear.isHidden = true
            for r in shown { r.frame = NSRect(x: x, y: y, width: w, height: rowH); y += rowH + Metrics.rowGap }
            y -= Metrics.rowGap
        }
        y += Space.xxl

        macHeader.frame = NSRect(x: x, y: y, width: w, height: 18)
        macHint.frame = NSRect(x: x + w - 220, y: y + 1, width: 220, height: 16)
        y += 18 + Space.m
        vitalsStrip.frame = NSRect(x: x, y: y, width: w, height: VitalsOrgans.height)
        y += VitalsOrgans.height + Space.xxl

        quickHeader.frame = NSRect(x: x, y: y, width: w, height: 18); y += 18 + Space.m
        var tx = x
        for t in tiles {
            let tw = t.fittedWidth
            t.isHidden = showingVitals || tx + tw > x + w
            t.frame = NSRect(x: tx, y: y, width: tw, height: tileHeight)
            tx += tw + Space.s
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
    var cardWidth: CGFloat { Isle.lensWidth }
    var onDefaultChanged: ((CardKind?) -> Void)?
    var onShowZeraChanged: ((Bool) -> Void)?
    /// The shortcut that opens Clipboard from any app.
    var clipboardShortcut: HotKeyShortcut? = .default
    /// Returns false when the shortcut can't be used (another app owns it).
    var onClipboardShortcutChanged: ((HotKeyShortcut?) -> Bool)?
    var onClipboardShortcutRecording: ((Bool) -> Void)?
    /// The app opener's shortcut (nil = off) and its switches.
    var openerShortcut: HotKeyShortcut? = AppOpenerSettings.defaultShortcut
    var onOpenerShortcutChanged: ((HotKeyShortcut?) -> Bool)?
    var onOpenerShortcutRecording: ((Bool) -> Void)?
    var onOpenerEnabledChanged: ((Bool) -> Void)?
    /// Quick add for Tasks (nil = off), and the menu bar item / orb switches.
    var tasksShortcut: HotKeyShortcut? = TasksSettings.defaultShortcut
    var onTasksShortcutChanged: ((HotKeyShortcut?) -> Bool)?
    var onTasksShortcutRecording: ((Bool) -> Void)?
    var onTasksSettingsChanged: (() -> Void)?
    var say: ((String, ZeraMood) -> Void)?

    enum Pane: Int, CaseIterable {
        case general, sounds, clipboard, appearance, integrations, shortcuts, about
        case claude, github, calendar, shelf   // detail panes, reached from Integrations
        case diagnostics                        // detail of Claude
        var title: String {
            switch self {
            case .general: return "General"
            case .sounds: return "Sounds"
            case .clipboard: return "Clipboard"
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
            case .sounds: return "speaker.wave.2.fill"
            case .clipboard: return "doc.on.clipboard.fill"
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
        var isDetail: Bool { rawValue >= Pane.claude.rawValue && self != .shelf }
        static let nav: [Pane] = [.general, .appearance, .sounds, .clipboard, .shelf, .integrations, .shortcuts, .about]
    }

    private var navRows: [NavRow] = []
    private let paneTitle = NSTextField(labelWithString: "")
    private let closeButton: IconButton
    private let backButton: CardButton
    private let pane = FlippedView()
    /// Panes taller than the island scroll instead of being cut off.
    private let paneScroll = NSScrollView()
    private let scrollHint = NSTextField(labelWithString: "Scroll for more")
    private let scrollArrow = NSTextField(labelWithString: "↓")
    private(set) var current: Pane = .general
    private var defaultKind: CardKind?
    private let showingZera: Bool
    private let sidebarW: CGFloat = 180
    private let navWash = GlideWash()
    /// Which provider tab the Claude pane last showed, so a rebuild can glide from it.
    private var providerShown: Int?
    private var paneHeight: CGFloat = 200

    init(defaultKind: CardKind?, showingZera: Bool, loginEnabled: Bool) {
        self.defaultKind = defaultKind
        self.showingZera = showingZera
        backButton = CardButton("Integrations", style: .tertiary, symbol: "chevron.left", target: nil, action: #selector(SettingsCard.backTapped))
        closeButton = IconButton(symbol: "xmark", label: "Close", target: nil, action: #selector(SettingsCard.closeTapped))
        super.init(width: Isle.lensWidth, title: "Settings")
        setSubtitle("Everything stays on this Mac")
        backButton.target = self
        closeButton.target = self
        addSubview(closeButton)
        backButton.isHidden = true
        addSubview(backButton)
        for pn in Pane.nav {
            let row = NavRow(symbol: pn.symbol, title: pn.title)
            row.selected = pn == current
            row.onTap = { [weak self] in self?.select(pn) }
            row.washManaged = true
            addSubview(row)
            navRows.append(row)
        }
        navWash.radius = 11
        navWash.edged = false
        navWash.target = { [weak self] in self?.navRows.first { $0.selected }?.frame }
        addSubview(navWash)
        paneTitle.font = Typo.paneTitle
        paneTitle.textColor = Pal.text
        addSubview(paneTitle)
        paneScroll.drawsBackground = false
        paneScroll.contentView.drawsBackground = false
        paneScroll.borderType = .noBorder
        paneScroll.hasVerticalScroller = false // Scroll by trackpad/wheel without covering trailing controls.
        paneScroll.autohidesScrollers = true
        paneScroll.scrollerStyle = .overlay
        paneScroll.verticalScrollElasticity = .allowed
        paneScroll.documentView = pane
        addSubview(paneScroll)
        scrollHint.font = Typo.secondary
        scrollHint.textColor = Pal.textSecondary
        scrollArrow.font = Typo.secondary
        scrollArrow.textColor = Pal.textSecondary
        scrollArrow.wantsLayer = true
        scrollHint.isHidden = true
        scrollArrow.isHidden = true
        addSubview(scrollHint)
        addSubview(scrollArrow)
        paneScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateScrollHint), name: NSView.boundsDidChangeNotification, object: paneScroll.contentView)
        for name in [GitHubService.changed, ClaudeHookService.changed, ReminderService.changed, ShelfStore.changed, ClaudeCLI.changed, ClaudeActivityService.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(serviceChanged), name: name, object: nil)
        }
        rebuildPane()
    }

    required init?(coder: NSCoder) { fatalError() }

    var desiredHeight: CGFloat {
        let nav = headerBottom + CGFloat(Pane.nav.count) * (38 + Space.xs) + Metrics.cardPad
        return max(nav, headerBottom + 40 + visiblePaneHeight + Metrics.cardPad)
    }

    /// As much of the pane as fits in the island; the rest scrolls.
    private var visiblePaneHeight: CGFloat {
        min(paneHeight, Isle.maxContentHeight - headerBottom - 40 - Metrics.cardPad)
    }

    func select(_ p: Pane) {
        // A detail pane (Claude, GitHub…) comes in like a page and Back reverses it; switching
        // between sidebar panes just settles the new one in.
        if p != current, window != nil {
            if p.isDetail != current.isDetail { Motion.page(paneScroll, forward: p.isDetail) }
            else {
                // Sidebar panes switch like tabs: down the list comes in from the right.
                let a = Pane.nav.firstIndex(of: current) ?? 0, b = Pane.nav.firstIndex(of: p) ?? 0
                Motion.tabSwitch([paneScroll], from: a, to: b)
            }
        }
        current = p
        paneScroll.contentView.scroll(to: .zero)
        let highlight: Pane = p.isDetail ? .integrations : p
        for (i, row) in navRows.enumerated() { row.selected = Pane.nav[i] == highlight }
        navWash.glide()
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
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refreshServicePane() }
        updateScrollHint()
    }

    @objc private func serviceChanged() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        refreshServicePane()
    }

    private func refreshServicePane() {
        // Only panes that show a service's state need rebuilding. Claude sessions report changes
        // every second, and a rebuild would throw away whatever you're in the middle of.
        guard [.integrations, .claude, .github, .calendar, .shelf, .diagnostics].contains(current) else { return }
        if shortcutRecorder?.isRecording == true { return }
        if let f = tokenField, f.currentEditor() != nil { return }
        if let f = apiKeyField, f.currentEditor() != nil { return }
        rebuildPane()
    }

    @objc private func rebuildPane() {
        pane.subviews.forEach { $0.removeFromSuperview() }
        paneTitle.stringValue = current.title
        backButton.isHidden = !current.isDetail
        backButton.setTitleText(current.parent.title)
        var s = Stack(width: cardWidth - sidebarW - Metrics.cardPad * 2 - Space.xxl)
        switch current {
        case .general: buildGeneral(&s)
        case .sounds: buildSounds(&s)
        case .clipboard: buildClipboard(&s)
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
        let f = Typo.body
        let l = label(text, font: f, color: Pal.textTertiary, in: pane, wraps: true)
        let w = min(s.width, 520)
        let h = (text as NSString).boundingRect(with: NSSize(width: w, height: 200), options: [.usesLineFragmentOrigin], attributes: [.font: f]).height
        s.y += Space.m
        l.frame = NSRect(x: 4, y: s.y, width: w, height: ceil(h) + 2)
        s.y += ceil(h) + 2 + Space.m
    }

    /// v2: one setting per row — its name left, its control right, a hairline under it.
    private static let rowH = Metrics.settingRow
    private func settingRow(_ title: String, _ s: inout Stack, control: NSView, controlWidth: CGFloat) {
        let row = FlippedView()
        let h = Self.rowH
        let l = label(title, font: Typo.settingLabel, in: row)
        l.frame = NSRect(x: 4, y: (h - 18) / 2, width: max(0, s.width - min(controlWidth, s.width * 0.48) - Space.m - Space.xs), height: 18)
        let toggle = control is Toggle
        let ch: CGFloat = toggle ? 24 : Metrics.button
        let cw = toggle ? 44 : min(controlWidth, s.width * 0.48)
        control.frame = NSRect(x: s.width - cw, y: ((h - ch) / 2).rounded(), width: cw, height: ch)
        row.addSubview(control)
        let rule = NSView(frame: NSRect(x: 0, y: h - 1, width: s.width, height: 1))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Pal.divider.cgColor
        row.addSubview(rule)
        pane.addSubview(row)
        s.place(row, height: h, gap: 0)
    }

    private func toggleRow(_ title: String, on: Bool, _ s: inout Stack, enabled: Bool = true, onChange: @escaping (Bool) -> Void) {
        let t = Toggle()
        t.isOn = on
        t.isEnabled = enabled
        t.onChange = onChange
        settingRow(title, &s, control: t, controlWidth: 40)
    }

    @discardableResult
    private func popupRow(_ title: String, items: [String], selected: Int, _ s: inout Stack, action: Selector) -> ZeraSelect {
        let pop = ZeraSelect(items)
        pop.select(selected)
        pop.setAccessibilityLabel(title)
        pop.onChange = { [weak self, weak pop] _ in
            guard let self = self, let pop = pop else { return }
            NSApp.sendAction(action, to: self, from: pop)
        }
        // Wide enough for the longest choice and the ⌄ beside it.
        let longest = items.map { ($0 as NSString).size(withAttributes: [.font: Typo.control]).width }.max() ?? 0
        settingRow(title, &s, control: pop, controlWidth: max(150, ceil(longest) + 52))
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

    private var defaultPopup: ZeraSelect?
    private weak var shortcutRecorder: ShortcutRecorder?
    private var breakPopup: ZeraSelect?
    private var tokenField: ThemedSecureField?
    private var apiKeyField: ThemedSecureField?
    private var overrideField: ThemedField?
    private var modelPopup: ZeraSelect?
    private var cliModelPopup: ZeraSelect?
    private var timeoutPopup: ZeraSelect?
    private var maxOutputPopup: ZeraSelect?
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

        // Battery: a banner when it runs low, and (if you like) when its health drops.
        let battery = BatteryAlerts.shared
        if battery.hasBattery {
            toggleRow("Warn when the battery is low", on: battery.lowEnabled, &s) { [weak self] on in
                battery.lowEnabled = on
                self?.rebuildPane()
            }
            let low = popupRow("Warn at", items: BatteryAlerts.lowChoices.map { "\($0)%" },
                               selected: BatteryAlerts.lowChoices.firstIndex(of: battery.lowThreshold) ?? 2, &s, action: #selector(batteryLowChanged(_:)))
            low.isEnabled = battery.lowEnabled
            toggleRow("Warn when battery health drops", on: battery.healthEnabled, &s) { [weak self] on in
                battery.healthEnabled = on
                self?.rebuildPane()
            }
            let health = popupRow("Health below", items: BatteryAlerts.healthChoices.map { "\($0)%" },
                                  selected: BatteryAlerts.healthChoices.firstIndex(of: battery.healthThreshold) ?? 2, &s, action: #selector(batteryHealthChanged(_:)))
            health.isEnabled = battery.healthEnabled
            hint("Low battery: once when it crosses your mark, once more at \(BatteryAlerts.critical)%, and not again until you've plugged in. "
                 + "Health: once when it drops below your mark.", &s)
        }

        // The app opener has no tab: Zera brings it down from the notch when you press its shortcut.
        toggleRow("App opener", on: AppOpenerSettings.enabled, &s) { [weak self] on in
            AppOpenerSettings.enabled = on
            self?.onOpenerEnabledChanged?(on)
            self?.rebuildPane()
        }
        let recorder = ShortcutRecorder()
        recorder.shortcut = openerShortcut
        recorder.onChange = { [weak self] new in
            guard let self = self, self.onOpenerShortcutChanged?(new) ?? true else { return false }
            self.openerShortcut = new
            return true
        }
        recorder.onRecording = { [weak self] on in self?.onOpenerShortcutRecording?(on) }
        settingRow("Open apps with", &s, control: recorder, controlWidth: 150)
        let style = popupRow("Opener style", items: ["Orbit (centred)", "Classic tree"], selected: AppOpenerSettings.style.rawValue, &s,
                             action: #selector(openerStyleChanged))
        style.isEnabled = AppOpenerSettings.enabled
        toggleRow("Show running apps first", on: AppOpenerSettings.runningFirst, &s, enabled: AppOpenerSettings.enabled) { on in
            AppOpenerSettings.runningFirst = on
        }

        // Tasks: a tab right of the notch, plus the orb on the screen edge.
        toggleRow("Focus orb on the screen edge", on: TasksSettings.orb, &s) { [weak self] on in
            TasksSettings.orb = on
            self?.onTasksSettingsChanged?()
        }
        let tasksRecorder = ShortcutRecorder()
        tasksRecorder.shortcut = tasksShortcut
        tasksRecorder.onChange = { [weak self] new in
            guard let self = self, self.onTasksShortcutChanged?(new) ?? true else { return false }
            self.tasksShortcut = new
            return true
        }
        tasksRecorder.onRecording = { [weak self] on in self?.onTasksShortcutRecording?(on) }
        settingRow("Add a task with", &s, control: tasksRecorder, controlWidth: 150)
        toggleRow("Group commits into tasks with Claude", on: TaskGitSync.useClaude, &s) { on in TaskGitSync.useClaude = on }
        hint("Drag the orb along either edge. Its outer ring is today's tasks, the inner one your time against the estimate (type 30m after a task to set one; without, it goes round hourly); "
             + "the timer pauses itself after 5 minutes away. Right-click a project → Link Code Folder… and your commits there "
             + "become its done tasks (only commit messages go to Claude, through your Claude Code login).", &s)
    }

    @objc private func batteryLowChanged(_ sender: ZeraSelect) {
        let i = sender.selectedIndex
        guard BatteryAlerts.lowChoices.indices.contains(i) else { return }
        BatteryAlerts.shared.lowThreshold = BatteryAlerts.lowChoices[i]
    }

    @objc private func batteryHealthChanged(_ sender: ZeraSelect) {
        let i = sender.selectedIndex
        guard BatteryAlerts.healthChoices.indices.contains(i) else { return }
        BatteryAlerts.shared.healthThreshold = BatteryAlerts.healthChoices[i]
    }

    private func buildSounds(_ s: inout Stack) {
        let snd = SoundService.shared
        toggleRow("Play sounds", on: snd.enabled, &s) { [weak self] on in
            snd.enabled = on
            if on { snd.play(.tap) }
            self?.rebuildPane()
        }
        let slider = NSSlider(value: Double(snd.volume), minValue: 0, maxValue: 1, target: self, action: #selector(soundVolumeChanged(_:)))
        slider.isContinuous = false
        slider.isEnabled = snd.enabled
        settingRow("Volume", &s, control: slider, controlWidth: 150)
        for family in ZeraSound.Family.allCases {
            toggleRow(family.title, on: snd.isOn(family), &s, enabled: snd.enabled) { on in
                snd.set(family, on: on)
                if on { snd.play(Self.sample(for: family)) }
            }
        }
        hint("One sound at a time, quieter than system alerts. GitHub news is off unless you turn it on.", &s)
    }

    /// What a family sounds like, played when you switch it on.
    private static func sample(for family: ZeraSound.Family) -> ZeraSound {
        switch family {
        case .zera: return .fileCatch
        case .island: return .islandOpen
        case .claude: return .claudeDone
        case .reminders: return .water
        case .clipboard: return .clipCopy
        case .opener: return .openerLaunch
        case .github: return .githubPing
        }
    }

    private func buildClipboard(_ s: inout Stack) {
        let clip = ClipboardStore.shared
        toggleRow("Keep clipboard history", on: clip.enabled, &s) { [weak self] on in
            clip.enabled = on
            self?.rebuildPane()
        }
        let on = clip.enabled
        let keep = popupRow("Keep items for", items: ClipboardStore.keepChoices.map { $0 == 0 ? "Until the limit" : ($0 == 1 ? "1 day" : "\($0) days") },
                            selected: ClipboardStore.keepChoices.firstIndex(of: clip.keepDays) ?? 1, &s, action: #selector(clipKeepChanged(_:)))
        let max = popupRow("Up to", items: ClipboardStore.maxChoices.map { "\($0) items" },
                           selected: ClipboardStore.maxChoices.firstIndex(of: clip.maxItems) ?? 2, &s, action: #selector(clipMaxChanged(_:)))
        [keep, max].forEach { $0.isEnabled = on }
        let recorder = ShortcutRecorder()
        shortcutRecorder = recorder
        recorder.shortcut = clipboardShortcut
        recorder.onChange = { [weak self] new in
            guard let self = self, self.onClipboardShortcutChanged?(new) ?? true else { return false }
            self.clipboardShortcut = new
            return true
        }
        recorder.onRecording = { [weak self] on in self?.onClipboardShortcutRecording?(on) }
        settingRow("Open with (from any app)", &s, control: recorder, controlWidth: 150)
        toggleRow("Fold away after copying", on: clip.foldAfterCopy, &s, enabled: on) { v in clip.foldAfterCopy = v }
        hint("Click the shortcut, then press keys with ⌘, ⌥ or ⌃ (⌫ turns it off). Passwords, private copies and password "
             + "managers are never kept, and everything stays on this Mac.", &s)
        if !clip.items.isEmpty {
            buttonRow("Clear history", style: .destructive, status: "Pinned items stay", &s, action: #selector(clipClearTapped))
        }
    }

    static let replyWindows = [0, 10, 20, 30, 60]
    @objc private func replyWindowChanged(_ sender: ZeraSelect) {
        ClaudeActivityService.shared.replyWindow = Self.replyWindows[max(0, sender.selectedIndex)]
    }

    @objc private func clipKeepChanged(_ sender: ZeraSelect) {
        ClipboardStore.shared.keepDays = ClipboardStore.keepChoices[max(0, sender.selectedIndex)]
    }
    @objc private func clipMaxChanged(_ sender: ZeraSelect) {
        ClipboardStore.shared.maxItems = ClipboardStore.maxChoices[max(0, sender.selectedIndex)]
    }
    @objc private func clipClearTapped() {
        ClipboardStore.shared.clear()
        SoundService.shared.play(.clipClear)
        rebuildPane()
    }

    private func themeRow(_ t: ZeraTheme, _ s: inout Stack) {
        let row = ThemeRow(theme: t)
        row.selected = t.id == ThemeStore.shared.current.id
        row.onTap = { ThemeStore.shared.select(t) }
        pane.addSubview(row)
        s.place(row, height: ThemeRow.height, gap: Space.xs)
    }

    @objc private func newThemeTapped() {
        guard let url = ThemeStore.shared.makeCustom() else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openThemesTapped() { ThemeStore.shared.revealFolder() }

    @objc private func soundVolumeChanged(_ sender: NSSlider) {
        SoundService.shared.volume = Float(sender.doubleValue)
        SoundService.shared.play(.reminderDone)
    }

    private func buildAppearance(_ s: inout Stack) {
        let store = ThemeStore.shared
        sectionLabel("Menus", &s)
        popupRow("Menu appearance", items: DropdownStyle.allCases.map(\.title), selected: DropdownStyle.current.rawValue,
                 &s, action: #selector(menuAppearanceChanged(_:)))
        hint("Zera glass matches your theme. Native macOS menus follow your system appearance.", &s)
        sectionLabel("Theme", &s)
        for t in store.builtIns { themeRow(t, &s) }
        if !store.custom.isEmpty {
            s.y += Space.s
            sectionLabel("Your themes", &s)
            for t in store.custom { themeRow(t, &s) }
        }
        s.y += Space.s
        buttonRow("New custom theme", style: .secondary, status: "Copies \(store.current.name) to a file you can edit", &s, action: #selector(newThemeTapped))
        buttonRow("Open themes folder", style: .tertiary, status: "Add or edit .json theme files; Zera picks up saved changes", &s, action: #selector(openThemesTapped))
        for problem in store.problems { hint("⚠︎ " + problem, &s) }
        hint("Zera herself and her bubble keep their own look in every theme.", &s)
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
        if s.y > 0 { s.y += Space.l }
        let l = label("", in: pane)
        l.attributedStringValue = Typo.sectionText(text)
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
        // The pane is rebuilt on a switch: the new tabs start where the old pill was and glide.
        tabs.selected = providerShown ?? a.provider.rawValue
        if providerShown != nil, providerShown != a.provider.rawValue {
            DispatchQueue.main.async { tabs.selected = a.provider.rawValue }
        }
        providerShown = a.provider.rawValue
        tabs.onSelect = { [weak self] i in
            ZeraAssistant.shared.provider = ZeraAssistant.Provider(rawValue: i) ?? .claudeCode
            if i == 0 { ClaudeCLI.shared.ensureProbed { _ in } }
            self?.rebuildPane()
            // Only what's under the tabs moves; the rest of the pane stays put.
            if let self = self { for v in self.pane.subviews where v.frame.minY > tabs.frame.maxY { Motion.page(v, forward: i == 1) } }
        }
        pane.addSubview(tabs)
        s.place(tabs, height: Metrics.segment, gap: Space.m)

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
        if act.isInstalled {
            let windows = Self.replyWindows
            let pop = popupRow("Reply when done", items: windows.map { $0 == 0 ? "Off" : "Wait \($0) s" },
                               selected: windows.firstIndex(of: act.replyWindow) ?? 2, &s, action: #selector(replyWindowChanged(_:)))
            pop.toolTip = "A finished session waits this long for a reply from the wings; typing one pauses the countdown"
            hint("When Claude finishes, the wings show Reply for a few seconds: type a follow-up and Claude carries on in the "
                 + "same session. Sessions the wings aren't showing are never held.", &s)
        }

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
        kvRow("Shell PATH entries", ShellEnvironment.shared.cachedPathCount.map(String.init) ?? "Not checked", &s)
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

        // Fresh: new files in the folders you watch, one tab over from the Shelf.
        let fresh = FreshFiles.shared
        s.y += Space.s
        sectionLabel("Fresh files", &s)
        toggleRow("Show what's new in your folders", on: fresh.enabled, &s) { [weak self] on in
            fresh.enabled = on
            self?.rebuildPane()
        }
        let look = popupRow("Look back", items: FreshFiles.windows.map(\.0),
                            selected: FreshFiles.windows.firstIndex { $0.1 == fresh.window } ?? 1, &s, action: #selector(freshWindowChanged(_:)))
        look.isEnabled = fresh.enabled
        for f in fresh.folders {
            toggleRow(f.isDefault ? f.name : "\(f.name)  ·  \((f.path as NSString).abbreviatingWithTildeInPath)", on: f.on, &s, enabled: fresh.enabled) { on in
                fresh.setFolder(f.path, on: on)
            }
        }
        buttonRow("Add folder…", style: .secondary, status: "New files there show up in Fresh", &s, action: #selector(freshAddFolderTapped))
        hint("Only names, sizes and dates are read. Half-finished downloads (.crdownload, .download, .part) show once they finish.", &s)
    }

    @objc private func freshWindowChanged(_ sender: ZeraSelect) {
        let i = sender.selectedIndex
        guard FreshFiles.windows.indices.contains(i) else { return }
        FreshFiles.shared.window = FreshFiles.windows[i].1
    }

    @objc private func freshAddFolderTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch Folder"
        panel.message = "New files in this folder show up in the Shelf's Fresh tab."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] r in
            guard r == .OK, let u = panel.url else { return }
            FreshFiles.shared.addFolder(u)
            self?.rebuildPane()
        }
    }

    private func buildShortcuts(_ s: inout Stack) {
        let items: [(String, String)] = [
            ("Open the default card", "Tap Zera"), ("Show the pill", "Hover Zera"), ("Move Zera along the top", "Drag her"),
            ("Close any card", "Esc"), ("Approve / reject a Claude command", "⏎ / Esc"), ("Add an event or reminder", "+ Add Event ▾"),
            ("Open clipboard history", clipboardShortcut?.label ?? "Clipboard tab"),
            ("Open an app", openerShortcut?.label ?? "Off (Settings → General)"),
            ("Add a task from anywhere", tasksShortcut?.label ?? "Off (Settings → General)"),
            ("Focus card: pause · done · next", "Space · ⏎ · ⇥"),
            ("Export tasks (from the list)", "⌘E"),
            ("Copy an item again", "Click it · ⏎ · ⌘1–⌘9"),
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
        defaultKind = Self.defaultChoices[max(0, min(Self.defaultChoices.count - 1, pop.selectedIndex))]
        onDefaultChanged?(defaultKind)
    }

    @objc private func openerStyleChanged(_ pop: ZeraSelect) {
        AppOpenerSettings.style = AppOpenerSettings.Style(rawValue: pop.selectedIndex) ?? .orbit
        say?(AppOpenerSettings.style == .orbit ? "the opener comes down in the middle now ✨" : "back to the classic tree 🌳", .happy)
    }

    @objc private func menuAppearanceChanged(_ pop: ZeraSelect) {
        DropdownStyle.current = DropdownStyle(rawValue: pop.selectedIndex) ?? .zera
    }

    @objc private func breakChanged() {
        guard let pop = breakPopup else { return }
        let m = Self.breakChoices[max(0, min(Self.breakChoices.count - 1, pop.selectedIndex))]
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
        guard let pop = modelPopup else { return }
        AnthropicAPIClient.shared.model = pop.selectedTitle
    }

    @objc private func cliModelChanged() {
        guard let pop = cliModelPopup else { return }
        ZeraAssistant.shared.cliModel = Self.cliModelChoices[max(0, min(Self.cliModelChoices.count - 1, pop.selectedIndex))]
    }

    @objc private func timeoutChanged() {
        guard let pop = timeoutPopup else { return }
        ZeraAssistant.shared.timeout = TimeInterval(Self.timeoutChoices[max(0, min(Self.timeoutChoices.count - 1, pop.selectedIndex))])
    }

    @objc private func maxOutputChanged() {
        guard let pop = maxOutputPopup else { return }
        ZeraAssistant.shared.maxOutputTokens = Self.maxOutputChoices[max(0, min(Self.maxOutputChoices.count - 1, pop.selectedIndex))]
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

    @objc private func updateScrollHint() {
        let hasMore = paneHeight > paneScroll.contentView.bounds.maxY + 2
        scrollHint.isHidden = !hasMore
        scrollArrow.isHidden = !hasMore
        if hasMore && window != nil && !Motion.reduced {
            if scrollArrow.layer?.animation(forKey: "scrollPulse") == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.45
                pulse.toValue = 1
                pulse.duration = 1.1
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                scrollArrow.layer?.add(pulse, forKey: "scrollPulse")
            }
        } else { scrollArrow.layer?.removeAnimation(forKey: "scrollPulse") }
    }

    override func layout() {
        super.layout()
        layoutHeader()
        let x = Metrics.cardPad
        // v2: the island's own ✕ at notch level closes the lens.
        closeButton.isHidden = true
        var y = headerBottom
        let navH: CGFloat = 38
        for row in navRows {
            row.frame = NSRect(x: x, y: y, width: sidebarW, height: navH)
            y += navH + Space.xs
        }
        navWash.frame = bounds
        navWash.needsDisplay = true
        let px = x + sidebarW + Space.xxl
        let pw = bounds.width - px - x
        if backButton.isHidden {
            paneTitle.frame = NSRect(x: px, y: headerBottom + 4, width: pw, height: 24)
        } else {
            let bw = backButton.fittedWidth
            backButton.frame = NSRect(x: px - Space.s, y: headerBottom + 2, width: bw, height: Metrics.control)
            paneTitle.frame = NSRect(x: px + bw, y: headerBottom + 4, width: pw - bw, height: 24)
        }
        paneScroll.frame = NSRect(x: px, y: headerBottom + 40, width: pw, height: visiblePaneHeight)
        pane.frame = NSRect(x: 0, y: 0, width: pw, height: paneHeight)
        let hintWidth = ceil((scrollHint.stringValue as NSString).size(withAttributes: [.font: Typo.secondary]).width)
        let hintX = px + (pw - hintWidth - 18) / 2
        scrollArrow.frame = NSRect(x: hintX, y: paneScroll.frame.maxY + 4, width: 14, height: 16)
        scrollHint.frame = NSRect(x: hintX + 18, y: paneScroll.frame.maxY + 4, width: hintWidth, height: 16)
        updateScrollHint()
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
        SoundService.shared.play(.claudeApproved)
        ClaudeHookService.shared.respond(req, allow: true)
        say?("approved ✅", .approved)
    }

    @objc private func rejectTapped() {
        guard let req = current else { return }
        approve.isEnabled = false; reject.isEnabled = false
        SoundService.shared.play(.claudeRejected)
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

// MARK: - Banner layout

/// v2 banners share one neat row: a 40 pt icon tile, a one-line heading over a one-line detail
/// (the pair centred on the buttons), and the buttons on the right, all on `midY`.
enum BannerLayout {
    static let midY: CGFloat = 46
    static let tile: CGFloat = 40

    /// One line each; a long heading steps down to 14 pt before it truncates.
    static func text(_ title: NSTextField, _ detail: NSTextField, x: CGFloat, width: CGFloat) {
        for l in [title, detail] {
            l.maximumNumberOfLines = 1
            l.lineBreakMode = .byTruncatingTail
            l.cell?.truncatesLastVisibleLine = true
            l.cell?.wraps = false
            l.toolTip = l.stringValue
        }
        var size: CGFloat = 16
        func fits(_ s: CGFloat) -> Bool {
            (title.stringValue as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: s, weight: .bold)]).width <= width
        }
        while size > 14, !fits(size) { size -= 0.5 }
        title.font = .systemFont(ofSize: size, weight: .bold)
        detail.font = Typo.bannerDetail
        title.frame = NSRect(x: x, y: midY - 21, width: max(0, width), height: 21)
        detail.frame = NSRect(x: x, y: midY + 2, width: max(0, width), height: 18)
    }

    static func tileFrame(x: CGFloat) -> NSRect { NSRect(x: x, y: midY - tile / 2, width: tile, height: tile) }
    static func buttonY(_ h: CGFloat) -> CGFloat { (midY - h / 2).rounded() }
}

extension GHEvent.Kind {
    /// The banner's line icon for the event.
    var lineIcon: String {
        switch self {
        case .prOpened: return "branch"
        case .reviewRequested: return "eye"
        case .ciFailed: return "alert"
        case .ciPassed, .prApproved: return "check"
        case .ciRunning: return "clock"
        case .needsApproval: return "bell"
        case .prChangesRequested, .prCommented: return "message"
        }
    }
}

// MARK: - Notification toast

/// Compact: "New PR opened · repo #125 · 2 min ago" with Review Now / Later.
final class ToastCard: CardBase, CardContent, TimedNotificationBanner {
    /// Sized like the reminder banner, so both have room for a full title.
    var cardWidth: CGFloat { Isle.bannerWidth(buttons: max(84, primary.fittedWidth) + Space.s + Metrics.rowButton) }
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
        dismiss.setLine("x")
        addSubview(tile)
        when.font = Typo.caption; when.textColor = Pal.textTertiary; when.alignment = .right; addSubview(when)
        addSubview(zera)
        addSubview(primary); addSubview(dismiss)
        addSubview(countdownLine)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A banner: just the header row (Zera hangs in its middle), plus a little air.
    /// Banners stay a slim band under the notch (v2 lenses have a taller header).
    override var headerBottom: CGFloat { Isle.bannerHeight }
    var desiredHeight: CGFloat { headerBottom + 6 }

    func show(event e: GHEvent) {
        tile.removeFromSuperview()
        tile = IconTile(symbol: e.symbol, color: e.tint, size: 40, pointSize: 16)
        tile.setLine(e.kind.lineIcon)
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
        tile.frame = BannerLayout.tileFrame(x: x)
        let half = bounds.width / 2 - Isle.zeraGap / 2 - 12, tx = x + BannerLayout.tile + 14
        BannerLayout.text(titleLabel, subtitleLabel, x: tx, width: half - tx)
        let pw = max(84, primary.fittedWidth), bh = Metrics.button, db = Metrics.rowButton
        dismiss.frame = NSRect(x: bounds.width - x - db, y: BannerLayout.buttonY(db), width: db, height: db)
        primary.frame = NSRect(x: dismiss.frame.minX - Space.s - pw, y: BannerLayout.buttonY(bh), width: pw, height: bh)
        countdownLine.frame = NSRect(x: 0, y: bounds.height - 3, width: bounds.width, height: 3)
    }
}
