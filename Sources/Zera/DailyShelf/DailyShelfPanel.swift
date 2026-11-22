import AppKit
import Carbon.HIToolbox

// MARK: - Daily Shelf: the edge panel
//
// A non-activating panel attached to the chosen screen edge (or floating just off it). It slides
// out when the pointer rests on that edge, when a link is dragged there, from the handle, or with
// ⌃⌥D, and slides away when the pointer leaves. The outline is one cached path; the slide is a
// single spring on the root layer's sublayerTransform, so nothing redraws per frame.

final class DailyShelfMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let s = symbol { image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// The card's glass: gradient fill and hairline edge along the open sides.
final class DailyShelfChromeView: NSView {
    var outline: CGPath? { didSet { needsDisplay = true } }
    var openOutline: CGPath? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let o = outline, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = Pal
        // Signal glass: translucent tint over the blur (the root's `glass`), solid when asked.
        let o2 = GlassSettings.isTranslucent ? max(0.72, GlassSettings.effectiveOpacity) : 1
        ctx.saveGState()
        ctx.addPath(o); ctx.clip()
        NSGradient(starting: p.cardTop.withAlphaComponent(o2), ending: p.cardBottom.withAlphaComponent(o2))?.draw(in: bounds, angle: -90)
        ctx.restoreGState()
        if let e = openOutline {
            // The free edges: a lit hairline in the signal colour with a soft glow.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 8, color: p.accent.withAlphaComponent(0.45).cgColor)
            ctx.addPath(e)
            ctx.setStrokeColor(p.accent.withAlphaComponent(0.42).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}

final class DailyShelfRootView: NSView {
    /// Signal glass under the shelf: the blurred desktop, clipped to its outline.
    private let glass = SignalGlassView(frame: .zero, flipped: false)
    let chrome = DailyShelfChromeView()
    let content = DailyShelfContentView()
    private var glassObserver: NSObjectProtocol?
    override var isFlipped: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.tintColor = .clear
        addSubview(glass)
        addSubview(chrome)
        addSubview(content)
        glassObserver = NotificationCenter.default.addObserver(forName: GlassSettings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.chrome.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let glassObserver { NotificationCenter.default.removeObserver(glassObserver) } }

    func apply(_ l: DailyShelfPlacement.Layout, placement: DailyShelfPlacement) {
        frame = NSRect(origin: .zero, size: l.frame.size)
        chrome.frame = bounds
        glass.frame = bounds
        chrome.outline = DailyShelfPlacement.outline(l, edge: placement.edge, attached: placement.attached, closed: true)
        if let o = chrome.outline { glass.setPath(o) }
        chrome.openOutline = DailyShelfPlacement.outline(l, edge: placement.edge, attached: placement.attached, closed: !placement.attached)
        content.radius = l.radius
        content.gripOnTop = placement.edge == .bottom || (placement.edge.isVertical && placement.align == .end)
        content.sideGripOnLeft = placement.edge == .right
        content.frame = l.body
        content.needsLayout = true
    }
}

/// Where a dragged shelf will settle: its outline at the target, so the snap is never a surprise.
final class DailyShelfPreviewView: NSView {
    var outline: CGPath? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let o = outline, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.addPath(o)
        ctx.setFillColor(Pal.accent.withAlphaComponent(0.10).cgColor)
        ctx.fillPath()
        ctx.addPath(o)
        ctx.setStrokeColor(Pal.accent.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.strokePath()
    }
}

/// The handle on the edge while the shelf is away, and the glow as the pointer comes near.
final class DailyShelfCueView: NSView {
    var edge: DailyShelfEdge = .left { didSet { needsDisplay = true } }
    var showHandle = true { didSet { needsDisplay = true } }
    var count = 0
    var glow: CGFloat = 0 { didSet { if abs(glow - oldValue) > 0.03 || (glow == 0) != (oldValue == 0) { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let v = edge.isVertical
        let len = v ? bounds.height : bounds.width
        if glow > 0.01 {
            let gl = len * 0.9, t: CGFloat = 3
            let r: NSRect
            switch edge {
            case .left: r = NSRect(x: 0, y: (bounds.height - gl) / 2, width: t, height: gl)
            case .right: r = NSRect(x: bounds.width - t, y: (bounds.height - gl) / 2, width: t, height: gl)
            case .top: r = NSRect(x: (bounds.width - gl) / 2, y: bounds.height - t, width: gl, height: t)
            case .bottom: r = NSRect(x: (bounds.width - gl) / 2, y: 0, width: gl, height: t)
            }
            let a = glow * 0.7
            let g = NSGradient(colors: [p.accent.withAlphaComponent(0), p.accent.withAlphaComponent(a), p.accent.withAlphaComponent(0)])
            g?.draw(in: NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5), angle: v ? 90 : 0)
        }
        if showHandle {
            let hl: CGFloat = 46, ht: CGFloat = 6
            let r: NSRect
            switch edge {
            case .left: r = NSRect(x: -1, y: (bounds.height - hl) / 2, width: ht + 1, height: hl)
            case .right: r = NSRect(x: bounds.width - ht, y: (bounds.height - hl) / 2, width: ht + 1, height: hl)
            case .top: r = NSRect(x: (bounds.width - hl) / 2, y: bounds.height - ht, width: hl, height: ht + 1)
            case .bottom: r = NSRect(x: (bounds.width - hl) / 2, y: -1, width: hl, height: ht + 1)
            }
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            p.cardTop.setFill(); path.fill()
            (glow > 0.3 ? p.accent.withAlphaComponent(0.7) : p.edge).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
}

// MARK: - Content

/// A resize grip: vertical (height, on the free end) or horizontal (width, on the free side).
/// Reports the pointer's travel in screen points since the press.
final class DailyShelfGripView: NSView {
    var horizontal = false
    var onDrag: ((CGFloat, Bool) -> Void)?
    private var start: NSPoint?
    private(set) var dragging = false
    private var hovered = false { didSet { needsDisplay = true } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let len: CGFloat = hovered || dragging ? 40 : 32
        let r = horizontal ? NSRect(x: (bounds.width - 4) / 2, y: (bounds.height - len) / 2, width: 4, height: len)
                           : NSRect(x: (bounds.width - len) / 2, y: (bounds.height - 4) / 2, width: len, height: 4)
        (hovered || dragging ? Pal.textSecondary : Pal.surfaceStrong).setFill()
        NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
    }
    override func updateTrackingAreas() { super.updateTrackingAreas(); resetHoverTracking() }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: horizontal ? .resizeLeftRight : .resizeUpDown) }
    private func travel() -> CGFloat {
        guard let s = start else { return 0 }
        let p = NSEvent.mouseLocation
        return horizontal ? p.x - s.x : p.y - s.y
    }
    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation; dragging = true; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { if start != nil { onDrag?(travel(), false) } }
    override func mouseUp(with event: NSEvent) {
        if start != nil { onDrag?(travel(), true) }
        start = nil; dragging = false; needsDisplay = true
    }
}

final class DailyShelfContentView: NSView, NSTextFieldDelegate {
    let companion = LivingCompanionView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
    private let titleLabel = NSTextField(labelWithString: "Today")
    private let dateLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private lazy var clearButton = IconButton(symbol: "xmark.bin", label: "Clear today (\u{2318}\u{232B}) · pinned stay", target: self, action: #selector(clearTapped))
    private lazy var undoButton = CardButton("Undo", style: .tertiary, symbol: "arrow.uturn.backward", target: self, action: #selector(undoTapped))
    /// What Clear took, while Undo is on offer.
    private var undoSnapshot: [DailyShelfItem]?
    private var undoWork: DispatchWorkItem?
    private lazy var searchButton = IconButton(symbol: "magnifyingglass", label: "Find on the shelf ( / )", target: self, action: #selector(searchTapped))
    private lazy var standupButton = IconButton(symbol: "text.badge.checkmark", label: "Standup from today", target: self, action: #selector(standupTapped))
    private lazy var pinButton = IconButton(symbol: "pin", label: "Keep the shelf open", target: self, action: #selector(pinTapped))
    private lazy var moreButton = IconButton(symbol: "ellipsis", label: "More", target: self, action: #selector(moreTapped))
    let field = ThemedField(placeholder: "Paste a link or jot a note")
    private let chips = DailyShelfChipsView()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private lazy var yesterdayButton = CardButton("Yesterday", style: .tertiary, symbol: "clock.arrow.circlepath", target: self, action: #selector(yesterdayTapped))
    private let footNote = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let divider = NSView()
    let grip = DailyShelfGripView()
    let sideGrip = DailyShelfGripView()
    let drop = DailyShelfDropView()
    let sheet = DailyShelfSheetView()

    var radius: CGFloat = 22 { didSet { drop.radius = max(8, radius - 6); sheet.radius = max(8, radius - 6) } }
    var gripOnTop = false
    /// The width grip sits on the left when the shelf hangs from the right edge.
    var sideGripOnLeft = false
    private(set) var searching = false
    private var query = ""
    private var rows: [UUID: NSView] = [:]
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onResize: ((CGFloat, Bool) -> Void)?
    var onResizeWidth: ((CGFloat, Bool) -> Void)?
    /// Dragging the header moves the shelf: travel since the press, and whether it ended.
    var onMove: ((CGPoint, Bool) -> Void)?
    private var moveStart: NSPoint?

    /// The shelf stays out while you type, read a sheet, resize or drop.
    var holdOpen: Bool {
        !sheet.isHidden || grip.dragging || sideGrip.dragging || moveStart != nil || !drop.isHidden
            || (window?.firstResponder as? NSTextView)?.delegate === field && !field.stringValue.isEmpty
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(companion)
        companion.onTap = { [weak self] in self?.companion.greet() }
        titleLabel.font = ZFont.ui(ofSize: 17, weight: .medium)
        dateLabel.font = ZFont.ui(ofSize: 13, weight: .regular)
        subLabel.font = ZFont.ui(ofSize: 12)
        for l in [titleLabel, dateLabel, subLabel, footNote, statusLabel] { l.lineBreakMode = .byTruncatingTail; addSubview(l) }
        footNote.font = Typo.caption; statusLabel.font = Typo.caption; statusLabel.alignment = .right
        for b in [clearButton, searchButton, standupButton, pinButton, moreButton] { addSubview(b) }
        undoButton.isHidden = true
        addSubview(undoButton)
        field.delegate = self
        field.target = self
        field.action = #selector(fieldReturn)
        addSubview(field)
        chips.onSelect = { id in DailyShelfSettings.update { $0.filter = id } }
        addSubview(chips)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        addSubview(scroll)
        divider.wantsLayer = true
        addSubview(divider)
        addSubview(yesterdayButton)
        addSubview(hints)
        grip.onDrag = { [weak self] dy, ended in self?.onResize?(dy, ended) }
        addSubview(grip)
        sideGrip.horizontal = true
        sideGrip.onDrag = { [weak self] dx, ended in self?.onResizeWidth?(dx, ended) }
        addSubview(sideGrip)
        addSubview(drop)
        sheet.isHidden = true
        sheet.onClose = { [weak self] in self?.closeSheet() }
        addSubview(sheet)
        registerForDraggedTypes([DSDrag.item, DSDrag.group, .URL, .string, Self.urlName, Self.safariURLs, DailyShelfArc.pasteboardType])
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(faviconLoaded), name: DailyShelfFavicons.loaded, object: nil)
        nc.addObserver(self, selector: #selector(keyWindowChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyWindowChanged(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    static let urlName = NSPasteboard.PasteboardType("public.url-name")
    static let safariURLs = NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")

    func restyle() {
        let p = Pal
        titleLabel.textColor = p.text
        dateLabel.textColor = p.textSecondary
        footNote.textColor = p.textTertiary
        statusLabel.textColor = p.textTertiary
        divider.layer?.backgroundColor = p.divider.cgColor
        field.setThemedPlaceholder(searching ? "Find on today's shelf" : "Paste a link or jot a note")
        field.textColor = p.text
        field.layer?.backgroundColor = p.field.cgColor
        field.layer?.borderColor = p.fieldBorder.cgColor
        needsDisplay = true
        reload()
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, pad: CGFloat = 16
        let top: CGFloat = gripOnTop ? 20 : 16
        companion.frame = NSRect(x: pad - 2, y: top - 2, width: 40, height: 40)
        var bx = w - pad + 4
        for b in [moreButton, pinButton, standupButton, searchButton, clearButton] { bx -= 28; b.frame = NSRect(x: bx, y: top + 4, width: 28, height: 28) }
        let tx = pad + 48
        let tw = DSText.width(titleLabel.stringValue, titleLabel.font!) + 4
        titleLabel.frame = NSRect(x: tx, y: top - 2, width: tw, height: 22)
        dateLabel.frame = NSRect(x: tx + tw + 4, y: top + 1, width: max(0, bx - tx - tw - 8), height: 18)
        subLabel.frame = NSRect(x: tx, y: top + 20, width: max(0, bx - tx - 4), height: 16)
        field.frame = NSRect(x: pad, y: top + 48, width: w - pad * 2, height: 32)
        chips.frame = NSRect(x: pad, y: top + 92, width: w - pad * 2, height: 28)
        let footH: CGFloat = 40
        let listTop = top + 128
        let listBottom = h - footH - (gripOnTop ? 0 : 4)
        scroll.frame = NSRect(x: 0, y: listTop, width: w, height: max(40, listBottom - listTop))
        divider.frame = NSRect(x: 0, y: listBottom, width: w, height: 1)
        yesterdayButton.frame = NSRect(x: pad - 8, y: listBottom + 6, width: yesterdayButton.fittedWidth, height: 28)
        footNote.frame = NSRect(x: pad, y: listBottom + 12, width: w / 2, height: 16)
        let sx = yesterdayButton.isHidden ? footNote.frame.maxX : yesterdayButton.frame.maxX
        statusLabel.frame = NSRect(x: sx + 8, y: listBottom + 12, width: max(0, w - pad - sx - 8), height: 16)
        hints.frame = NSRect(x: pad, y: listBottom + 10, width: w - pad * 2, height: 20)
        undoButton.frame = NSRect(x: w - pad + 8 - undoButton.fittedWidth, y: listBottom + 6, width: undoButton.fittedWidth, height: 28)
        grip.frame = NSRect(x: (w - 56) / 2, y: gripOnTop ? 0 : h - 12, width: 56, height: 12)
        sideGrip.frame = NSRect(x: sideGripOnLeft ? 0 : w - 12, y: (h - 56) / 2, width: 12, height: 56)
        drop.frame = bounds
        sheet.frame = bounds.insetBy(dx: 8, dy: 8)
        layoutList()
    }

    // MARK: Moving by the header

    private var headerRect: NSRect { NSRect(x: 0, y: 0, width: searchButton.frame.minX - 4, height: field.frame.minY - 4) }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(headerRect, cursor: moveStart == nil ? .openHand : .closedHand)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard headerRect.contains(p), !companion.frame.contains(p) else { super.mouseDown(with: event); return }
        moveStart = NSEvent.mouseLocation
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = moveStart else { super.mouseDragged(with: event); return }
        let p = NSEvent.mouseLocation
        onMove?(CGPoint(x: p.x - s.x, y: p.y - s.y), false)
    }
    override func mouseUp(with event: NSEvent) {
        guard let s = moveStart else { super.mouseUp(with: event); return }
        let p = NSEvent.mouseLocation
        moveStart = nil
        onMove?(CGPoint(x: p.x - s.x, y: p.y - s.y), true)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Building the list

    private var builtWidth: CGFloat = 0
    private var landed: UUID?

    func reload(landed id: UUID? = nil) {
        if let id = id { landed = id }
        let store = DailyShelfStore.shared, s = DailyShelfSettings.current
        let items = store.items
        // Header
        if let d = DailyShelfClock.date(fromKey: store.day) {
            let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE d MMM")
            dateLabel.stringValue = f.string(from: d)
        }
        let need = items.filter { $0.kind == .pr && $0.github.map { DailyShelfPRStatus.of($0).group == .yourMove } == true && $0.github?.checkedAt != nil }.count
        let sub = NSMutableAttributedString(string: items.isEmpty ? "Nothing yet" : "\(items.count) item\(items.count == 1 ? "" : "s")",
                                            attributes: [.font: subLabel.font!, .foregroundColor: Pal.textSecondary])
        if need > 0 { sub.append(NSAttributedString(string: " · \(need) need you", attributes: [.font: ZFont.ui(ofSize: 12, weight: .medium), .foregroundColor: Pal.danger])) }
        subLabel.attributedStringValue = sub
        pinButton.setSymbol(s.keepOpen ? "pin.fill" : "pin", label: s.keepOpen ? "Let the shelf hide" : "Keep the shelf open")
        pinButton.contentTintColor = s.keepOpen ? Pal.accent : Pal.textSecondary
        // Chips
        let counts = Dictionary(grouping: items.filter { !$0.sorting }, by: \.kind).mapValues(\.count)
        var c: [(id: String, title: String, count: Int)] = [("all", "All", items.count)]
        for k in Self.order where (counts[k] ?? 0) > 0 { c.append((k.rawValue, Self.chipTitle[k] ?? k.rawValue, counts[k] ?? 0)) }
        chips.chips = c
        chips.selected = c.contains { $0.id == s.filter } ? s.filter : "all"
        // Footer
        let previous = store.previousDay()
        yesterdayButton.isHidden = (previous?.items.isEmpty ?? true)
        if let p = previous, !p.items.isEmpty {
            yesterdayButton.setTitleText("\(Self.dayName(p.day)) · \(p.items.count)")
        }
        footNote.isHidden = !yesterdayButton.isHidden
        if undoSnapshot == nil { footNote.stringValue = String(format: "Clears at %d:00 · pinned stay", s.rolloverHour) }
        statusLabel.stringValue = statusText(items)
        rebuildList(items: items, settings: s)
        needsLayout = true
    }

    static let order: [DailyShelfKind] = [.pr, .jira, .meeting, .doc, .site, .note]
    static let chipTitle: [DailyShelfKind: String] = [.pr: "PRs", .jira: "Jira", .meeting: "Meet", .doc: "Docs", .site: "Sites", .note: "Notes"]
    static let sectionSymbol: [DailyShelfKind: String] = [.pr: "arrow.triangle.pull", .jira: "ticket", .meeting: "video", .doc: "doc.text", .site: "globe", .note: "note.text"]

    static func dayName(_ key: String) -> String {
        guard let d = DailyShelfClock.date(fromKey: key) else { return key }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: d)
    }

    private func statusText(_ items: [DailyShelfItem]) -> String {
        if items.contains(where: \.sorting) { return "Claude is sorting\u{2026}" }
        if let e = DailyShelfClassifier.shared.lastError, !e.isEmpty { return "Claude unavailable · filed as Websites" }
        let prs = items.contains { $0.kind == .pr }
        if prs && !DailyShelfGitHub.shared.isConnected { return "GitHub not connected" }
        if prs, let t = DailyShelfGitHub.shared.lastChecked { return "GitHub checked \(relativeTime(t))" }
        let n = items.filter { $0.categorySource == .claude }.count
        return n > 0 ? "\(n) sorted by Claude" : ""
    }

    /// Where a dragged item can land: a site category, or a whole section.
    enum Zone: Equatable { case section(DailyShelfKind), category(String) }
    private struct Entry { let view: NSView; let height: CGFloat; var gap: CGFloat; var section: DailyShelfKind?; var zone: Zone? }
    private var entries: [Entry] = []
    private var shownSections: [String] = []
    private var shownCategories: [String] = []
    private let indicator = NSView()
    /// Only actual items are keyboard stops; section titles remain mouse controls.
    enum NavStop: Equatable { case item(UUID) }
    private var navStops: [NavStop] = []
    /// Includes folded items, so arrows can leave a collapsed section in either direction.
    private var itemOrder: [UUID] = []
    private(set) var cursor: NavStop? { didSet { if cursor != oldValue { applySelection(); updateHints() } } }
    /// The item under the cursor, if the cursor is on an item.
    var selectedID: UUID? { if case .item(let id)? = cursor { return id }; return nil }
    /// After a filter switch, the cursor goes to the top of the new list.
    private var cursorToTop = false
    let hints = DailyShelfHintsView()
    override var acceptsFirstResponder: Bool { true }

    private func rebuildList(items all: [DailyShelfItem], settings s: DailyShelfSettings) {
        doc.subviews.forEach { $0.removeFromSuperview() }
        entries.removeAll()
        rows.removeAll()
        let q = query.lowercased()
        let items = all.filter { it in
            q.isEmpty || [it.title, it.url ?? "", it.jiraKey ?? "", it.github.map { "\($0.repo) #\($0.number)" } ?? "", it.category]
                .contains { $0.lowercased().contains(q) }
        }
        let width = max(100, scroll.contentSize.width - 32)
        var section: DailyShelfKind?, zone: Zone?
        func add(_ v: NSView, _ h: CGFloat, gap: CGFloat = 8) {
            // Sections breathe more than the rows inside them.
            if let hv = v as? DailyShelfHeaderView, !hv.isGroup, !entries.isEmpty { entries[entries.count - 1].gap += 12 }
            doc.addSubview(v); entries.append(Entry(view: v, height: h, gap: gap, section: section, zone: zone))
        }
        shownSections = []; shownCategories = []; itemOrder = []

        for it in items where it.sorting {
            let r = row(for: it)
            r.leading = .favicon(it.host); r.meta = (it.host ?? "") + " · Claude is sorting\u{2026}"; r.pill = nil; r.showsActions = false
            add(r, r.fittedHeight(width: width))
        }
        let sectionKinds = DailyShelfOrder.apply(s.sectionOrder, to: Self.order.map(\.rawValue)).compactMap(DailyShelfKind.init(rawValue:))
        for kind in sectionKinds {
            guard s.filter == "all" || s.filter == kind.rawValue else { continue }
            let its = items.filter { $0.kind == kind && !$0.sorting }
            guard !its.isEmpty else { continue }
            shownSections.append(kind.rawValue)
            section = kind
            zone = .section(kind)
            let ordered: [DailyShelfItem]
            switch kind {
            case .pr:
                ordered = DailyShelfPRStatus.Group.allCases.flatMap { group in
                    its.filter { DailyShelfPRStatus.of($0.github ?? DailyShelfPR(owner: "", repo: "", number: 0)).group == group }
                }
            case .site:
                // Flatten old Claude categories into one Sites list, retaining each item's metadata.
                let sorted = its.sorted { $0.opens > $1.opens }
                ordered = sorted.filter { $0.layout != "row" } + sorted.filter { $0.layout == "row" }
            default: ordered = its
            }
            itemOrder += ordered.map(\.id)
            let collapsed = s.collapsed.contains(kind.rawValue)
            let h = DailyShelfHeaderView()
            h.groupKey = "section:\(kind.rawValue)"
            h.pinned = s.pinnedGroups.contains("section:\(kind.rawValue)")
            h.onPin = { Self.togglePinnedGroup("section:\(kind.rawValue)") }
            h.toolTip = h.pinned ? "Kept every day. Click the pin to let it clear at the reset" : "Pin to keep this section every day"
            h.title = DailyShelfRules.sectionTitles[kind] ?? kind.rawValue
            h.symbol = Self.sectionSymbol[kind] ?? "circle"
            h.count = its.count
            h.collapsed = collapsed
            h.onToggle = { Self.toggleCollapsed(kind.rawValue) }
            if kind == .pr {
                let move = its.filter { $0.github.map { DailyShelfPRStatus.of($0).group == .yourMove } == true && $0.github?.checkedAt != nil }
                if move.count > 1 { h.action = "Open \(move.count)"; h.onAction = { [weak self] in move.forEach { self?.open($0) } } }
            }
            add(h, 28, gap: 4)
            guard !collapsed else { continue }
            switch kind {
            case .pr:
                for g in DailyShelfPRStatus.Group.allCases {
                    let grp = its.filter { DailyShelfPRStatus.of($0.github ?? DailyShelfPR(owner: "", repo: "", number: 0)).group == g }
                    guard !grp.isEmpty else { continue }
                    add(groupLabel(g.title, tone: g.tone), 20, gap: 4)
                    for it in grp { let r = row(for: it); add(r, r.fittedHeight(width: width)) }
                }
            case .site:
                let tiles = ordered.filter { $0.layout != "row" }
                if !tiles.isEmpty {
                    let holder = FlippedView()
                    tiles.forEach { holder.addSubview(tile(for: $0)) }
                    let cols = max(1, Int((width + 8) / 80)), lines = (tiles.count + cols - 1) / cols
                    add(holder, CGFloat(lines) * 64 + CGFloat(lines - 1) * 8)
                }
                for it in ordered where it.layout == "row" { let r = row(for: it); add(r, r.fittedHeight(width: width)) }
            case .note:
                for it in its {
                    let n = DailyShelfNoteView(id: it.id)
                    n.text = it.title
                    n.accent = it.accent
                    n.mono = DailyShelfRules.looksLikeCommand(it.title)
                    n.onCopy = { [weak self] in NSPasteboard.general.setPlainText(it.title); self?.companion.react(.copy) }
                    n.pinned = it.pinned
                    n.onPin = { DailyShelfStore.shared.togglePin(it.id) }
                    n.onRemove = { [weak self] in self?.remove(it) }
                    n.contextMenu = { [weak self] in self?.menu(for: it) }
                    rows[it.id] = n
                    add(n, n.fittedHeight(width: width))
                }
            default:
                for it in its { let r = row(for: it); add(r, r.fittedHeight(width: width)) }
            }
        }
        indicator.wantsLayer = true
        indicator.isHidden = true
        doc.addSubview(indicator)
        if entries.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: q.isEmpty
                ? "Nothing on today's shelf.\nDrag a link to this edge, paste one above, or jot a note. PRs, tickets and sites sort themselves."
                : "Nothing matches \u{201C}\(query)\u{201D}.")
            empty.alignment = .center
            empty.font = Typo.body
            empty.textColor = Pal.textSecondary
            add(empty, 90)
        }
        builtWidth = width
        layoutList()
        collectNav()
        if let id = landed, let v = rows[id] {
            landed = nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.doc.scrollToVisible(v.frame.insetBy(dx: 0, dy: -10))
                (v as? DailyShelfRowView)?.flash()
                if let t = v as? DailyShelfTileView { t.layer?.add(Self.pop(), forKey: "pop") }
            }
        }
    }

    private static func pop() -> CAAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0.3, 1, 0.7, 1]; a.duration = 0.8
        return a
    }

    private func layoutList() {
        let width = max(100, scroll.contentSize.width - 32)
        if abs(width - builtWidth) > 0.5, !entries.isEmpty {
            // Heights depend on width: rebuild at the new width.
            builtWidth = width
            rebuildList(items: DailyShelfStore.shared.items, settings: DailyShelfSettings.current)
            return
        }
        var y: CGFloat = 4
        for e in entries {
            e.view.frame = NSRect(x: 16, y: y, width: width, height: e.height)
            if !(e.view is DailyShelfRowView || e.view is DailyShelfNoteView || e.view is DailyShelfHeaderView || e.view is NSTextField) {
                // A tile grid.
                let tiles = e.view.subviews
                let cols = max(1, Int((width + 8) / 80))
                let tw = ((width - CGFloat(cols - 1) * 8) / CGFloat(cols)).rounded(.down)
                for (i, t) in tiles.enumerated() {
                    t.frame = NSRect(x: CGFloat(i % cols) * (tw + 8), y: CGFloat(i / cols) * 72, width: tw, height: 64)
                }
            }
            y += e.height + e.gap
        }
        doc.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, y + 8))
    }

    private func groupLabel(_ title: String, tone: DailyShelfTone?) -> DailyShelfHeaderView {
        let g = DailyShelfHeaderView()
        g.isGroup = true; g.title = title; g.dotTone = tone
        return g
    }

    private func row(for it: DailyShelfItem) -> DailyShelfRowView {
        let r = DailyShelfRowView(id: it.id)
        r.title = it.title
        r.accent = it.accent
        r.pinned = it.pinned
        r.carried = it.carried == true
        let opened = it.opens > 0 ? " · opened \(it.opens)\u{00D7}" : ""
        switch it.kind {
        case .pr:
            let g = it.github ?? DailyShelfPR(owner: "", repo: "", number: 0)
            r.metaAbove = true
            r.titleLines = 2
            var meta = "\(g.repo) #\(g.number)"
            r.number = g.number
            if g.mine == false, let a = g.author { meta += " · @\(a)" }
            if g.checkedAt != nil {
                let s = DailyShelfPRStatus.of(g)
                r.leading = .status(s.symbol, s.tone)
                r.pill = (s.label, s.tone)
                if s.label == "Changes asked" || s.label == "Ready to merge", let who = g.reviewer { meta += " · @\(who)" }
                if let a = g.additions, let d = g.deletions, a + d > 0 { r.diff = (a, d) }
            } else {
                r.leading = .status("arrow.triangle.pull", .muted)
                r.pill = DailyShelfGitHub.shared.isConnected ? ("Checking\u{2026}", .muted) : nil
            }
            r.meta = meta
        case .jira:
            r.leading = .key(it.jiraKey ?? "JIRA")
            r.title = it.title == it.jiraKey ? (it.host ?? it.title) : it.title
            r.meta = "Jira · added \(relativeTime(it.addedAt))" + opened
        case .meeting:
            r.leading = .symbol("video")
            r.meta = (it.host ?? "Meeting") + opened
            r.buttonTitle = "Join"
        case .doc:
            r.leading = .favicon(it.host)
            r.meta = Self.appName(it.host) + opened
        case .site, .note:
            r.leading = .favicon(it.host)
            r.meta = (it.host ?? "") + opened
        }
        r.onAction = { [weak self] a in self?.act(a, on: it) }
        r.contextMenu = { [weak self] in self?.menu(for: it) }
        r.dragPayload = { Self.payload(it) }
        rows[it.id] = r
        return r
    }

    /// Folds or unfolds a section (its kind, "pr") or a site category ("category:Dev tools"); nil toggles.
    static func toggleCollapsed(_ key: String, fold: Bool? = nil) {
        DailyShelfSettings.update { st in
            let folded = st.collapsed.contains(key)
            let want = fold ?? !folded
            if want && !folded { st.collapsed.append(key) } else if !want && folded { st.collapsed.removeAll { $0 == key } }
        }
    }

    static func togglePinnedGroup(_ key: String) {
        DailyShelfSettings.update { st in
            if st.pinnedGroups.contains(key) { st.pinnedGroups.removeAll { $0 == key } } else { st.pinnedGroups.append(key) }
        }
    }

    /// A dragged item: its id for refiling here, and its link and title for other apps.
    static func payload(_ it: DailyShelfItem) -> NSPasteboardItem {
        let p = NSPasteboardItem()
        p.setString(it.id.uuidString, forType: DSDrag.item)
        if let u = it.url {
            p.setString(u, forType: .URL)
            p.setString(u, forType: .string)
            p.setString(it.title, forType: urlName)
        } else {
            p.setString(it.title, forType: .string)
        }
        return p
    }

    private func tile(for it: DailyShelfItem) -> DailyShelfTileView {
        let t = DailyShelfTileView(id: it.id)
        t.host = it.host
        t.accent = it.accent
        t.name = it.customTitle == true ? it.title : (it.title.components(separatedBy: " · ").first ?? it.title)
        t.opens = it.opens
        t.toolTip = it.title
        t.onOpen = { [weak self] in self?.open(it) }
        t.contextMenu = { [weak self] in self?.menu(for: it) }
        t.dragPayload = { Self.payload(it) }
        t.pinned = it.pinned
        t.onPin = { DailyShelfStore.shared.togglePin(it.id) }
        t.toolTip = it.title + (it.pinned ? " · kept every day" : "")
        rows[it.id] = t
        return t
    }

    static func appName(_ host: String?) -> String {
        guard let h = host else { return "Doc" }
        if h == "docs.google.com" { return "Google Docs" }
        if h.contains("notion") { return "Notion" }
        if h.hasSuffix("atlassian.net") { return "Confluence" }
        if h.contains("dropbox") { return "Dropbox Paper" }
        return h
    }

    // MARK: Actions

    private func act(_ a: DailyShelfRowView.Action, on it: DailyShelfItem) {
        switch a {
        case .open, .button:
            if it.kind == .note { NSPasteboard.general.setPlainText(it.title); return }
            open(it)
        case .copy:
            NSPasteboard.general.setPlainText(it.url ?? it.title)
            companion.react(.copy)
        case .pin:
            DailyShelfStore.shared.togglePin(it.id)
        case .remove:
            remove(it)
        }
    }

    func open(_ it: DailyShelfItem) {
        guard let u = it.link else { return }
        NSWorkspace.shared.open(u)
        DailyShelfStore.shared.markOpened(it.id)
    }

    private func remove(_ it: DailyShelfItem) {
        guard let v = rows[it.id], !Motion.reduced else { DailyShelfStore.shared.remove(it.id); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.16; v.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { DailyShelfStore.shared.remove(it.id) } })
    }

    private func menu(for it: DailyShelfItem) -> NSMenu {
        let m = NSMenu()
        if it.link != nil {
            m.addItem(DailyShelfMenuItem("Open", symbol: "arrow.up.right.square") { [weak self] in self?.open(it) })
            m.addItem(DailyShelfMenuItem("Copy link", symbol: "doc.on.doc") { NSPasteboard.general.setPlainText(it.url ?? "") })
        } else {
            m.addItem(DailyShelfMenuItem("Copy", symbol: "doc.on.doc") { NSPasteboard.general.setPlainText(it.title) })
        }
        m.addItem(DailyShelfMenuItem("Rename\u{2026}", symbol: "pencil") { [weak self] in self?.showRename(it) })
        let appearance = NSMenuItem(title: "Accent color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        let reset = DailyShelfMenuItem("Default", symbol: "circle.dashed") { DailyShelfStore.shared.setAccent(it.id, to: nil) }
        reset.state = it.accent == nil ? .on : .off
        colors.addItem(reset)
        colors.addItem(.separator())
        for accent in DailyShelfAccent.allCases {
            let choice = DailyShelfMenuItem(accent.title) { DailyShelfStore.shared.setAccent(it.id, to: accent) }
            choice.image = accent.swatch
            choice.state = it.accent == accent ? .on : .off
            colors.addItem(choice)
        }
        appearance.submenu = colors
        m.addItem(appearance)
        m.addItem(DailyShelfMenuItem(it.pinned ? "Unpin" : "Keep every day", symbol: "pin") { DailyShelfStore.shared.togglePin(it.id) })
        if it.kind == .site || (it.link != nil && it.kind != .pr && it.kind != .jira) {
            m.addItem(.separator())
            let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            var cats = DailyShelfRules.siteCategories
            for c in DailyShelfStore.shared.items.map(\.category) where it.kind == .site && !cats.contains(c) && !["Pull requests", "Jira", "Docs", "Meetings", "Notes"].contains(c) { cats.append(c) }
            for c in cats where !(it.kind == .site && c == it.category) {
                sub.addItem(DailyShelfMenuItem(c) { DailyShelfStore.shared.move(it.id, to: c) })
            }
            move.submenu = sub
            m.addItem(move)
        }
        m.addItem(.separator())
        m.addItem(DailyShelfMenuItem("Remove from today", symbol: "trash") { [weak self] in self?.remove(it) })
        return m
    }

    @objc private func fieldReturn() {
        guard !searching else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        field.stringValue = ""
        DailyShelfContentView.add(text: text, title: nil)
    }

    /// A link becomes an item; anything else becomes a note.
    @discardableResult
    static func add(text: String, title: String?) -> Bool {
        if let u = DailyShelfRules.link(in: text) {
            let r = DailyShelfStore.shared.add(link: u, title: title)
            if !r.isNew { NotificationCenter.default.post(name: DailyShelfStore.changed, object: nil, userInfo: ["landed": r.item.id]) }
            return true
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        DailyShelfStore.shared.addNote(t)
        return true
    }

    func addFromPasteboard(_ pb: NSPasteboard = .general) -> Bool {
        let links = Self.links(from: pb)
        if !links.isEmpty { links.forEach { DailyShelfStore.shared.add(link: $0.0, title: $0.1) }; return true }
        if let s = pb.string(forType: .string) { return Self.add(text: s, title: nil) }
        return false
    }

    func controlTextDidBeginEditing(_ obj: Notification) { cursor = nil; updateHints() }
    func controlTextDidEndEditing(_ obj: Notification) { updateHints() }

    func controlTextDidChange(_ obj: Notification) {
        guard searching else { return }
        query = field.stringValue
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if searching { toggleSearch(false) } else if !field.stringValue.isEmpty { field.stringValue = "" } else { onClose?() }
            return true
        }
        return false
    }

    func toggleSearch(_ on: Bool) {
        searching = on
        query = ""
        field.stringValue = ""
        field.setThemedPlaceholder(on ? "Find on today's shelf" : "Paste a link or jot a note")
        searchButton.contentTintColor = on ? Pal.accent : Pal.textSecondary
        reload()
        if on { window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(field) }
    }

    @objc private func searchTapped() { toggleSearch(!searching) }
    @objc private func clearTapped() { clearToday() }
    @objc private func undoTapped() { undoClear() }

    /// Clears today (pinned items and pinned groups stay) and offers Undo in the footer for a while.
    func clearToday() {
        let before = DailyShelfStore.shared.clearToday()
        guard !before.isEmpty else { return }
        let gone = before.count - DailyShelfStore.shared.items.count
        undoSnapshot = before
        undoWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.endUndo() }
        undoWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
        cursor = nil
        footNote.stringValue = "Cleared \(gone) item\(gone == 1 ? "" : "s")"
        updateHints()
    }

    /// True when there was something to put back.
    @discardableResult
    func undoClear() -> Bool {
        guard let before = undoSnapshot else { return false }
        DailyShelfStore.shared.undoClear(before)
        endUndo()
        return true
    }

    private func endUndo() {
        undoWork?.cancel(); undoWork = nil
        undoSnapshot = nil
        reload()
        updateHints()
    }
    @objc private func pinTapped() { DailyShelfSettings.update { $0.keepOpen.toggle() } }
    @objc private func standupTapped() { showStandup() }
    @objc private func yesterdayTapped() { showYesterday() }
    @objc private func moreTapped() {
        let m = NSMenu()
        m.addItem(DailyShelfMenuItem("Standup from today", symbol: "text.badge.checkmark") { [weak self] in self?.showStandup() })
        m.addItem(DailyShelfMenuItem("Show today's file in Finder", symbol: "curlybraces") {
            NSWorkspace.shared.activateFileViewerSelecting([DailyShelfStore.shared.fileURL])
        })
        m.addItem(DailyShelfMenuItem("Daily Shelf settings\u{2026}", symbol: "slider.horizontal.3") { [weak self] in self?.onOpenSettings?() })
        m.addItem(.separator())
        m.addItem(DailyShelfMenuItem("Clear today (pinned stay)", symbol: "xmark.bin") { [weak self] in self?.clearToday() })
        m.popUp(positioning: nil, at: NSPoint(x: moreButton.frame.minX, y: moreButton.frame.maxY + 4), in: self)
    }

    @objc private func faviconLoaded() {
        for v in doc.subviews { v.needsDisplay = true; v.subviews.forEach { $0.needsDisplay = true } }
    }

    // MARK: Sheets

    private var renameID: UUID?
    private(set) var renameField: ThemedField?

    func showRename(_ item: DailyShelfItem) {
        guard let current = DailyShelfStore.shared.items.first(where: { $0.id == item.id }) else { return }
        renameID = current.id
        let input = ThemedField(placeholder: "Item title")
        input.stringValue = current.title
        input.target = self
        input.action = #selector(saveRename)
        input.setAccessibilityLabel("Item title")
        renameField = input
        let save = CardButton("Save", style: .primary, target: self, action: #selector(saveRename))
        sheet.configure(title: "Rename item", buttons: [save])
        let body = FlippedView(frame: NSRect(x: 0, y: 0, width: max(200, sheet.bounds.width), height: 110))
        input.frame = NSRect(x: 16, y: 8, width: body.bounds.width - 32, height: 36)
        input.autoresizingMask = [.width]
        body.addSubview(input)
        let hint = NSTextField(wrappingLabelWithString: "Changes only the title on your shelf. The link stays the same.")
        hint.font = Typo.body
        hint.textColor = Pal.textSecondary
        hint.frame = NSRect(x: 16, y: 56, width: body.bounds.width - 32, height: 44)
        hint.autoresizingMask = [.width]
        body.addSubview(hint)
        sheet.scroll.documentView = body
        presentSheet()
        window?.makeFirstResponder(input)
        input.selectText(nil)
    }

    @objc func saveRename() {
        guard let id = renameID, let input = renameField,
              DailyShelfStore.shared.rename(id, to: input.stringValue) else { return }
        closeSheet()
        reload()
    }

    private func showStandup() {
        let store = DailyShelfStore.shared
        let d = DailyShelfStandup.draft(store.items)
        let text = DailyShelfStandup.text(d, day: Self.dayName(store.day) == "Yesterday" ? store.day : (dateLabel.stringValue.isEmpty ? store.day : dateLabel.stringValue))
        let copy = CardButton("Copy", style: .primary, target: nil, action: #selector(NSText.copy(_:)))
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: max(200, sheet.bounds.width), height: 400))
        tv.isEditable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = Typo.body
        tv.textColor = Pal.text
        tv.insertionPointColor = Pal.accent
        tv.string = text
        tv.textContainerInset = NSSize(width: 10, height: 4)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        copy.target = self
        copy.action = #selector(copyStandup)
        standupView = tv
        sheet.configure(title: "Standup", buttons: [copy])
        sheet.scroll.documentView = tv
        presentSheet()
    }
    private weak var standupView: NSTextView?
    @objc private func copyStandup() {
        NSPasteboard.general.setPlainText(standupView?.string ?? "")
        companion.react(.copy)
        closeSheet()
    }

    private func showYesterday() {
        guard let prev = DailyShelfStore.shared.previousDay() else { return }
        sheet.configure(title: Self.dayName(prev.day), buttons: [])
        let doc = FlippedView()
        let width = max(100, sheet.bounds.width - 32)
        var y: CGFloat = 0
        for it in prev.items {
            let r = DailyShelfRowView(id: it.id)
            r.title = it.title
            r.accent = it.accent
            r.meta = it.category
            r.showsActions = false
            r.buttonTitle = "Bring back"
            switch it.kind {
            case .pr: let s = DailyShelfPRStatus.of(it.github ?? DailyShelfPR(owner: "", repo: "", number: 0)); r.leading = .status(s.symbol, s.tone)
            case .jira: r.leading = .key(it.jiraKey ?? "JIRA")
            case .note: r.leading = .symbol("note.text")
            default: r.leading = .favicon(it.host)
            }
            r.onAction = { [weak r] a in
                if a == .button { DailyShelfStore.shared.bringBack(it); r?.isHidden = true }
                else if a == .open, let u = it.link { NSWorkspace.shared.open(u) }
            }
            let h = r.fittedHeight(width: width)
            r.frame = NSRect(x: 16, y: y, width: width, height: h)
            doc.addSubview(r)
            y += h + 8
        }
        doc.frame = NSRect(x: 0, y: 0, width: sheet.bounds.width, height: y + 8)
        sheet.scroll.documentView = doc
        presentSheet()
    }

    private func presentSheet() {
        sheet.isHidden = false
        sheet.alphaValue = 0
        sheet.needsLayout = true
        updateHints()
        NSAnimationContext.runAnimationGroup { $0.duration = Motion.duration(0.18); sheet.animator().alphaValue = 1 }
    }

    func closeSheet() {
        guard !sheet.isHidden else { return }
        if renameID != nil {
            renameID = nil
            renameField = nil
            window?.makeFirstResponder(self)
        }
        NSAnimationContext.runAnimationGroup({ $0.duration = Motion.duration(0.14); sheet.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.sheet.isHidden = true })
    }

    // MARK: Keyboard

    private func collectNav() {
        navStops = []
        for e in entries {
            if let r = e.view as? DailyShelfRowView, !r.isHidden { navStops.append(.item(r.itemID)) }
            else if let n = e.view as? DailyShelfNoteView { navStops.append(.item(n.itemID)) }
            else { navStops += e.view.subviews.compactMap { ($0 as? DailyShelfTileView).map { .item($0.itemID) } } }
        }
        if cursorToTop {
            cursorToTop = false
            if !isEditingField { cursor = navStops.first ?? itemOrder.first.map { .item($0) } }
        }
        if let c = cursor, !navStops.contains(c) {
            // Keep a hidden item as the fold anchor, without selecting its section title.
            if case .item(let id) = c,
               itemOrder.contains(id),
               let item = DailyShelfStore.shared.items.first(where: { $0.id == id }),
               DailyShelfSettings.current.collapsed.contains(item.kind.rawValue) {
                // Shift-Tab can reopen this section and restore the same item.
            } else { cursor = navStops.first }
        }
        applySelection()
        updateHints()
    }

    private func applySelection() {
        for (id, v) in rows {
            let on = cursor == .item(id)
            (v as? DailyShelfRowView)?.selected = on
            (v as? DailyShelfTileView)?.selected = on
            (v as? DailyShelfNoteView)?.selected = on
        }
        if let id = selectedID, let v = rows[id], let sv = v.superview {
            doc.scrollToVisible(doc.convert(v.frame, from: sv).insetBy(dx: 0, dy: -12))
        }
    }

    private var selectedItem: DailyShelfItem? { selectedID.flatMap { id in DailyShelfStore.shared.items.first { $0.id == id } } }

    private var isEditingField: Bool { (window?.firstResponder as? NSTextView)?.delegate === field }

    func focusField() {
        cursor = nil
        window?.makeFirstResponder(field)
        updateHints()
    }

    func focusList() {
        window?.makeFirstResponder(self)
        if cursor == nil { cursor = navStops.first ?? itemOrder.first.map { .item($0) } }
        updateHints()
    }

    /// All four arrows step directly between items, skipping titles and folded content.
    private func moveCursor(_ step: Int) {
        guard !navStops.isEmpty else { return }
        guard let c = cursor else { cursor = navStops.first; return }
        if let i = navStops.firstIndex(of: c) {
            if step < 0 && i == 0 { focusField(); return }
            cursor = navStops[max(0, min(navStops.count - 1, i + step))]
        } else if case .item(let id) = c, let i = itemOrder.firstIndex(of: id) {
            let candidates = step > 0 ? Array(itemOrder.dropFirst(i + 1)) : Array(itemOrder.prefix(i).reversed())
            if let next = candidates.first(where: { navStops.contains(.item($0)) }) { cursor = .item(next) }
            else if step < 0 { focusField() }
        } else { cursor = navStops.first }
    }

    /// Tab advances the top-level filter tabs, wrapping back to All.
    private func cycleFilter(_ step: Int) {
        let ids = chips.chips.map(\.id)
        guard ids.count > 1 else { return }
        let i = ids.firstIndex(of: chips.selected) ?? 0
        let next = ids[((i + step) % ids.count + ids.count) % ids.count]
        cursorToTop = true
        DailyShelfSettings.update { $0.filter = next }
        reload()
    }

    /// Shift-Tab (or Space) toggles the section containing the current item.
    private func fold(_ want: Bool?) {
        guard let item = selectedItem else { return }
        let key = item.kind.rawValue
        let folded = DailyShelfSettings.current.collapsed.contains(key)
        let fold = want ?? !folded
        if fold != folded { Self.toggleCollapsed(key, fold: fold); reload() }
    }

    /// Keys while the shelf has the keyboard. Returns true when handled.
    func handleKey(_ e: NSEvent) -> Bool {
        guard sheet.isHidden else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let code = Int(e.keyCode)
        if code == kVK_Tab, mods.isEmpty { cycleFilter(1); return true }
        if code == kVK_Tab, mods == .shift { fold(nil); return true }
        if isEditingField {
            if code == kVK_DownArrow && mods.isEmpty { focusList(); return true }
            return false
        }
        if mods == .command, let n = Int(e.charactersIgnoringModifiers ?? ""), n >= 1, n <= chips.chips.count {
            cursorToTop = true
            DailyShelfSettings.update { $0.filter = self.chips.chips[n - 1].id }
            reload()
            return true
        }
        let ch = e.charactersIgnoringModifiers?.lowercased()
        if mods == .command, ch == "c", let it = selectedItem { act(.copy, on: it); return true }
        if mods == .command, code == kVK_Delete { clearToday(); return true }
        if mods == .command, ch == "z" { return undoClear() }
        guard mods.isEmpty || mods == .shift else { return false }
        switch code {
        case kVK_DownArrow, kVK_RightArrow: moveCursor(1); return true
        case kVK_UpArrow, kVK_LeftArrow: moveCursor(-1); return true
        case kVK_Space: fold(nil); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let it = selectedItem, navStops.contains(.item(it.id)) { act(.open, on: it) }
            return true
        case kVK_Delete, kVK_ForwardDelete:
            if let it = selectedItem, let i = navStops.firstIndex(of: .item(it.id)) {
                let after = navStops[(i + 1)...].first { if case .item = $0 { return true }; return false }
                let before = navStops[..<i].last { if case .item = $0 { return true }; return false }
                DailyShelfStore.shared.remove(it.id)
                cursor = after ?? before
            }
            return true
        default: break
        }
        switch ch {
        case "p": if let it = selectedItem { DailyShelfStore.shared.togglePin(it.id) }; return selectedItem != nil
        case "a", "n": focusField(); return true
        default: return false
        }
    }

    @objc private func keyWindowChanged(_ n: Notification) {
        guard (n.object as? NSWindow) === window else { return }
        updateHints()
    }

    /// The footer shows key hints while the shelf has the keyboard, else the day and status.
    func updateHints() {
        let keyboard = window?.isKeyWindow == true && sheet.isHidden
        let undo = undoSnapshot != nil
        undoButton.isHidden = !undo
        if undo {
            hints.isHidden = true
            yesterdayButton.alphaValue = 0; statusLabel.alphaValue = 0
            footNote.isHidden = false; footNote.alphaValue = 1
            return
        }
        if !keyboard {
            hints.isHidden = true
        } else if isEditingField {
            hints.hints = searching ? [("\u{2193}", "Results"), ("\u{21E5}", "Tabs"), ("esc", "Done")]
                : [("\u{21A9}", "Add"), ("\u{2193}", "Items"), ("\u{21E5}", "Tabs"), ("\u{2318}V", "Paste link")]
            hints.isHidden = false
        } else if selectedID != nil {
            hints.hints = [("\u{2190}\u{2191}\u{2193}\u{2192}", "Items"), ("\u{21E7}\u{21E5}", "Fold"), ("\u{21E5}", "Tabs"), ("\u{21A9}", "Open"), ("P", "Pin"), ("\u{232B}", "Remove")]
            hints.isHidden = false
        } else {
            hints.hints = [("\u{2193}", "Items"), ("\u{21E5}", "Tabs"), ("A", "Add"), ("/", "Find"), ("esc", "Close")]
            hints.isHidden = false
        }
        for v in [yesterdayButton, footNote, statusLabel] as [NSView] { v.alphaValue = hints.isHidden ? 1 : 0 }
    }

    // MARK: Opening motion

    func animateRowsIn(from edge: DailyShelfEdge) {
        guard !Motion.reduced else { return }
        let dx: CGFloat = edge == .left ? -8 : edge == .right ? 8 : 0
        let dy: CGFloat = edge == .top ? -8 : edge == .bottom ? 8 : 0
        for (i, e) in entries.prefix(6).enumerated() {
            guard let l = e.view.layer ?? { e.view.wantsLayer = true; return e.view.layer }() else { continue }
            let t = CABasicAnimation(keyPath: "transform")
            t.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(dx, -dy, 0))
            t.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 0; o.toValue = 1
            let g = CAAnimationGroup()
            g.animations = [t, o]
            g.duration = 0.3
            g.beginTime = CACurrentMediaTime() + 0.08 + Double(i) * 0.04
            g.fillMode = .backwards
            g.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            l.add(g, forKey: "in")
        }
    }

    // MARK: Drops

    static func links(from pb: NSPasteboard) -> [(URL, String?)] {
        let arc = DailyShelfArc.ids(on: pb)
        if !arc.isEmpty { return arc.compactMap(DailyShelfArc.fromSidebarFile) }
        if let plist = pb.propertyList(forType: safariURLs) as? [[String]], plist.count == 2 {
            let urls = plist[0].compactMap { DailyShelfRules.link(in: $0) }
            if !urls.isEmpty { return urls.enumerated().map { ($1, plist[1].indices.contains($0) ? plist[1][$0] : nil) } }
        }
        let title = pb.string(forType: urlName)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL] {
            let web = urls.filter { !$0.isFileURL }.compactMap { DailyShelfRules.link(in: $0.absoluteString) }
            if !web.isEmpty { return web.map { ($0, web.count == 1 ? title : nil) } }
        }
        if let s = pb.string(forType: .string), let u = DailyShelfRules.link(in: s) { return [(u, title)] }
        return []
    }

    // MARK: Refiling and reordering by drag

    private enum Plan {
        case refile(UUID, DailyShelfKind, String, NSRect)
        case reorderSections(String, before: String?, line: CGFloat)
        case reorderCategories(String, before: String?, line: CGFloat)
    }

    /// Each zone's area in the list, in list order.
    private func frames(_ key: (Entry) -> String?) -> [(String, NSRect)] {
        var out: [(String, NSRect)] = []
        for e in entries {
            guard let k = key(e) else { continue }
            if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1 = out[i].1.union(e.view.frame) } else { out.append((k, e.view.frame)) }
        }
        return out
    }

    private func plan(for sender: NSDraggingInfo) -> Plan? {
        let pb = sender.draggingPasteboard
        let pt = doc.convert(sender.draggingLocation, from: nil)
        func insertion(_ list: [(String, NSRect)], moving: String) -> (String?, CGFloat) {
            if let next = list.first(where: { $0.1.midY > pt.y }) { return (next.0, next.1.minY - 8) }
            return (nil, (list.last?.1.maxY ?? 0) + 6)
        }
        if let g = pb.string(forType: DSDrag.group) {
            if g.hasPrefix("section:") {
                let list = frames { $0.section?.rawValue }.filter { shownSections.contains($0.0) }
                let (before, y) = insertion(list, moving: String(g.dropFirst(8)))
                return .reorderSections(String(g.dropFirst(8)), before: before, line: y)
            }
            if g.hasPrefix("category:") {
                let list = frames { if case .category(let c) = $0.zone { return c } else { return nil } }
                let (before, y) = insertion(list, moving: String(g.dropFirst(9)))
                return .reorderCategories(String(g.dropFirst(9)), before: before, line: y)
            }
            return nil
        }
        guard let raw = pb.string(forType: DSDrag.item), let id = UUID(uuidString: raw),
              let it = DailyShelfStore.shared.items.first(where: { $0.id == id }), it.kind == .site || it.kind == .doc else { return nil }
        let zones = frames { e -> String? in
            switch e.zone {
            case .category(let c): return "category:" + c
            case .section(.doc): return "section:doc"
            case .section(.site): return "section:site"
            default: return nil
            }
        }
        guard let hit = zones.first(where: { $0.1.insetBy(dx: -16, dy: -6).contains(pt) }) else { return nil }
        if hit.0 == "section:doc" { return it.kind == .doc ? nil : .refile(id, .doc, "Docs", hit.1) }
        if hit.0 == "section:site" { return it.kind == .site ? nil : .refile(id, .site, DailyShelfRules.fallbackCategory, hit.1) }
        let cat = String(hit.0.dropFirst(9))
        return it.kind == .site && it.category == cat ? nil : .refile(id, .site, cat, hit.1)
    }

    private func showIndicator(_ p: Plan?) {
        guard let p = p else { indicator.isHidden = true; return }
        let l = indicator.layer
        let width = max(100, scroll.contentSize.width - 32)
        switch p {
        case .refile(_, _, _, let r):
            indicator.frame = r.insetBy(dx: -6, dy: -6)
            l?.cornerRadius = 14
            l?.borderWidth = 1.5
            l?.borderColor = Pal.accent.withAlphaComponent(0.6).cgColor
            l?.backgroundColor = Pal.accent.withAlphaComponent(0.06).cgColor
        case .reorderSections(_, _, let y), .reorderCategories(_, _, let y):
            indicator.frame = NSRect(x: 16, y: y - 1, width: width, height: 2)
            l?.cornerRadius = 1
            l?.borderWidth = 0
            l?.backgroundColor = Pal.accent.cgColor
        }
        indicator.isHidden = false
        doc.addSubview(indicator, positioned: .above, relativeTo: nil)
    }

    private func isInternal(_ sender: NSDraggingInfo) -> Bool {
        let t = sender.draggingPasteboard.types ?? []
        return t.contains(DSDrag.item) || t.contains(DSDrag.group)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isInternal(sender) { let p = plan(for: sender); showIndicator(p); return p == nil ? [] : .move }
        let pb = sender.draggingPasteboard
        guard !DailyShelfArc.ids(on: pb).isEmpty || !Self.links(from: pb).isEmpty || pb.string(forType: .string) != nil else { return [] }
        drop.show()
        companion.react(.fileDrag(active: true))
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isInternal(sender) { let p = plan(for: sender); showIndicator(p); return p == nil ? [] : .move }
        return drop.isHidden ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        indicator.isHidden = true
        if let s = sender, isInternal(s) { return }
        drop.hide(swallow: false); companion.react(.fileDrag(active: false))
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isInternal(sender) {
            indicator.isHidden = true
            guard let p = plan(for: sender) else { return false }
            switch p {
            case .refile(let id, let kind, let cat, _): DailyShelfStore.shared.refile(id, kind: kind, category: cat)
            case .reorderSections(let k, let before, _):
                let order = DailyShelfOrder.move(k, before: before, in: shownSections)
                DailyShelfSettings.update { $0.sectionOrder = order }
            case .reorderCategories(let c, let before, _):
                let order = DailyShelfOrder.move(c, before: before, in: shownCategories)
                DailyShelfSettings.update { $0.categoryOrder = order }
            }
            return true
        }
        let pb = sender.draggingPasteboard
        let links = Self.links(from: pb)
        drop.hide(swallow: true)
        companion.react(.fileDrag(active: false))
        if !links.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduced ? 0 : 0.25)) {
                links.forEach { DailyShelfStore.shared.add(link: $0.0, title: $0.1) }
            }
            return true
        }
        // Arc tabs it has not saved yet: ask Arc for each one.
        let arc = DailyShelfArc.ids(on: pb)
        if !arc.isEmpty {
            for id in arc {
                DailyShelfArc.askArc(id) { url, title in
                    MainActor.assumeIsolated {
                        if let u = url { DailyShelfStore.shared.add(link: u, title: title) }
                        else { Diag.log("daily shelf: Arc did not give a link for a dragged tab") }
                    }
                }
            }
            return true
        }
        if let s = pb.string(forType: .string) { return Self.add(text: s, title: nil) }
        return false
    }
}

// MARK: - Controller

@MainActor
final class DailyShelfController {
    static let shared = DailyShelfController()

    private var panel: FloatingPanel?
    private var root: DailyShelfRootView?
    private var cuePanel: FloatingPanel?
    private let cue = DailyShelfCueView()
    private var previewPanel: FloatingPanel?
    private let preview = DailyShelfPreviewView()
    private var previewTarget: DailyShelfPlacement?
    /// The settings change came from dragging the shelf: glide, don't slide out and back.
    private var fromDrag = false
    private(set) var isOpen = false
    private var settings = DailyShelfSettings.current
    private var placement: DailyShelfPlacement {
        var p = settings.placement
        if let h = liveHeight { p.height = h }
        if let w = liveWidth { p.width = w }
        return p
    }
    private var liveHeight: CGFloat?
    private var liveWidth: CGFloat?
    private var resizeStart: CGFloat?
    private var widthStart: CGFloat?
    private var moveOrigin: NSPoint?
    static let widthRange: ClosedRange<CGFloat> = 300...520
    private var layoutNow: DailyShelfPlacement.Layout?
    private var area: NSRect = .zero
    private var dwell: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var openedByKey = false
    private var pointerEntered = false
    private let dragBoard = NSPasteboard(name: .drag)
    private var dragCount = 0
    private var buttonWasDown = false
    private var dragHasLink = false
    private var menuTracking = 0
    private var hotKey: GlobalHotKey?
    private var timer: Timer?
    private var lastGitHub = Date.distantPast
    private var started = false
    private var dirty = true

    weak var companionSource: ZeraView? { didSet { root?.content.companion.source = companionSource } }
    var onOpenSettings: (() -> Void)?

    /// The shortcut's label for Settings and hints ("off" when cleared).
    var shortcutLabel: String { settings.effectiveHotKey?.label ?? "your shortcut" }
    private var hotKeyPaused = false

    /// Settings › Shelf: a new shortcut (nil turns it off). False when macOS refuses it (another app owns it).
    func setHotKey(_ new: HotKeyShortcut?) -> Bool {
        hotKey = nil
        if let s = new, settings.enabled {
            guard let k = GlobalHotKey(s, handler: { [weak self] in self?.toggle() }) else {
                registerHotKey()
                return false
            }
            hotKey = k
        }
        DailyShelfSettings.update { $0.hotKey = new; $0.hotKeyOff = new == nil }
        return true
    }

    /// While the recorder listens, the live shortcut steps aside so pressing it is recorded.
    func pauseHotKey(_ paused: Bool) {
        hotKeyPaused = paused
        registerHotKey()
    }

    private func registerHotKey() {
        hotKey = nil
        guard settings.enabled, !hotKeyPaused, let s = settings.effectiveHotKey else { return }
        hotKey = GlobalHotKey(s) { [weak self] in self?.toggle() }
    }

    func start() {
        guard !started else { return }
        started = true
        let p = FloatingPanel.make(size: NSSize(width: 360, height: 600), level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1), keyable: true)
        p.edgeAnchored = true
        let r = DailyShelfRootView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        p.contentView = r
        p.onKeyDown = { [weak self] e in self?.key(e) ?? false }
        r.content.companion.source = companionSource
        r.content.onClose = { [weak self] in self?.close() }
        r.content.onOpenSettings = { [weak self] in self?.close(); self?.onOpenSettings?() }
        r.content.onResize = { [weak self] dy, ended in self?.resize(dy, ended: ended) }
        r.content.onResizeWidth = { [weak self] dx, ended in self?.resizeWidth(dx, ended: ended) }
        r.content.onMove = { [weak self] d, ended in self?.move(d, ended: ended) }
        panel = p; root = r

        let c = FloatingPanel.make(size: NSSize(width: 20, height: 170), level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1), keyable: false)
        c.edgeAnchored = true
        c.ignoresMouseEvents = true
        c.hasShadow = false
        c.contentView = cue
        cuePanel = c

        let pv = FloatingPanel.make(size: NSSize(width: 360, height: 600), level: .floating, keyable: false)
        pv.edgeAnchored = true
        pv.ignoresMouseEvents = true
        pv.hasShadow = false
        pv.contentView = preview
        previewPanel = pv

        let nc = NotificationCenter.default
        nc.addObserver(forName: DailyShelfStore.changed, object: nil, queue: .main) { [weak self] n in
            let id = n.userInfo?["landed"] as? UUID
            MainActor.assumeIsolated { self?.storeChanged(landed: id) }
        }
        nc.addObserver(forName: DailyShelfSettings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        for name in [DailyShelfGitHub.changed, Palette.changed] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    if n.name == Palette.changed { self?.root?.chrome.needsDisplay = true; self?.cue.needsDisplay = true; self?.root?.content.restyle() }
                    else { self?.reloadIfOpen() }
                }
            }
        }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking += 1 }
        }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let s = self { s.menuTracking = max(0, s.menuTracking - 1) } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodic(force: true) }
        }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.periodic() } }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        settingsChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.periodic(force: true) }
    }

    // MARK: Pointer (called from Zera's pointer poll)

    func track(pointer p: NSPoint, buttonDown: Bool) {
        guard started, settings.enabled else { return }
        // A drag that carries a link (or text) can open the shelf from the edge.
        if buttonDown {
            if !buttonWasDown { dragCount = dragBoard.changeCount; dragHasLink = false }
            else if !dragHasLink, dragBoard.changeCount != dragCount {
                let types = dragBoard.types ?? []
                dragHasLink = types.contains(.URL) || types.contains(.string) || types.contains(DailyShelfContentView.urlName)
                    || types.contains(DailyShelfArc.pasteboardType) || types.contains(DSDrag.group)
            }
        } else if buttonWasDown {
            dragHasLink = false
        }
        buttonWasDown = buttonDown
        if !isOpen, let scr = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }), scr.visibleFrame != area { relayout(on: scr) }
        guard let l = layoutNow else { return }
        let dist = edgeDistance(p)
        let along = placement.edge.isVertical ? p.y : p.x
        let lo = placement.edge.isVertical ? l.frame.minY : l.frame.minX, hi = placement.edge.isVertical ? l.frame.maxY : l.frame.maxX
        let inSpan = along >= lo - 30 && along <= hi + 30
        let near = inSpan && dist >= -1 && dist <= 2
        if !isOpen {
            cue.glow = settings.openOnHover && inSpan && dist >= -1 ? max(0, min(1, 1 - dist / 70)) * 0.9 : 0
            if dragHasLink && buttonDown && inSpan && dist >= -1 && dist <= 40 { open(); return }
            let onHandle = settings.showHandle && handleRect().insetBy(dx: -3, dy: -3).contains(p)
            if (settings.openOnHover && near) || onHandle {
                if dwell == nil {
                    let w = DispatchWorkItem { [weak self] in self?.dwell = nil; self?.open() }
                    dwell = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(settings.hoverDelay), execute: w)
                }
            } else if let d = dwell { d.cancel(); dwell = nil }
            return
        }
        let inside = (panel?.frame.insetBy(dx: -8, dy: -8).contains(p) ?? false) || near
        if inside { pointerEntered = true; cancelClose(); return }
        let hold = settings.keepOpen || (root?.content.holdOpen ?? false) || menuTracking > 0
            || (openedByKey && !pointerEntered) || (buttonDown && dragHasLink) || resizeStart != nil || widthStart != nil || moveOrigin != nil
        if !hold { scheduleClose() }
    }

    private func edgeDistance(_ p: NSPoint) -> CGFloat {
        switch placement.edge {
        case .left: return p.x - area.minX
        case .right: return area.maxX - p.x
        case .top: return area.maxY - p.y
        case .bottom: return p.y - area.minY
        }
    }

    /// The handle pill itself (not the whole cue strip), in screen coordinates.
    private func handleRect() -> NSRect {
        guard let f = cuePanel?.frame, cuePanel?.isVisible == true else { return .zero }
        switch placement.edge {
        case .left: return NSRect(x: f.minX, y: f.midY - 23, width: 8, height: 46)
        case .right: return NSRect(x: f.maxX - 8, y: f.midY - 23, width: 8, height: 46)
        case .top: return NSRect(x: f.midX - 23, y: f.maxY - 8, width: 46, height: 8)
        case .bottom: return NSRect(x: f.midX - 23, y: f.minY, width: 46, height: 8)
        }
    }

    // MARK: Open / close

    func toggle() { isOpen ? close() : open(byKey: true) }

    func open(byKey: Bool = false) {
        guard started, settings.enabled, !isOpen, let panel = panel, let root = root else { return }
        dwell?.cancel(); dwell = nil
        if let scr = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main { relayout(on: scr) }
        isOpen = true
        openedByKey = byKey
        pointerEntered = false
        cancelClose()
        if dirty { root.content.reload(); dirty = false }
        cuePanel?.orderOut(nil)
        panel.alphaValue = 1
        panel.hasShadow = false
        panel.orderFrontRegardless()
        if byKey { panel.makeKey(); root.content.focusField() }
        if Motion.reduced {
            root.layer?.sublayerTransform = CATransform3DIdentity
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.16; panel.animator().alphaValue = 1 },
                                                 completionHandler: { panel.hasShadow = true; panel.invalidateShadow() })
        } else if let layer = root.layer {
            let a = CABasicAnimation(keyPath: "sublayerTransform")
            a.fromValue = NSValue(caTransform3D: hiddenTransform())
            a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            a.duration = 0.38
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self = self, self.isOpen else { return }
                panel.hasShadow = true; panel.invalidateShadow()
            }
            layer.sublayerTransform = CATransform3DIdentity
            layer.add(a, forKey: "slide")
            CATransaction.commit()
            root.content.animateRowsIn(from: placement.edge)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { root.content.companion.greet() }
        }
        if Date().timeIntervalSince(lastGitHub) > 60 { lastGitHub = Date(); DailyShelfGitHub.shared.refresh() }
    }

    func close() {
        guard isOpen, let panel = panel, let root = root else { return }
        isOpen = false
        cancelClose()
        root.content.closeSheet()
        if panel.isKeyWindow { panel.resignKey() }
        let done: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
            guard let self = self, !self.isOpen else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.showCue()
            }
        }
        if Motion.reduced {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; panel.animator().alphaValue = 0 }, completionHandler: done)
        } else if let layer = root.layer {
            panel.hasShadow = false
            let hidden = hiddenTransform()
            let a = CABasicAnimation(keyPath: "sublayerTransform")
            a.fromValue = NSValue(caTransform3D: layer.presentation()?.sublayerTransform ?? CATransform3DIdentity)
            a.toValue = NSValue(caTransform3D: hidden)
            a.duration = 0.2
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.2)
            CATransaction.begin()
            CATransaction.setCompletionBlock(done)
            layer.sublayerTransform = hidden
            layer.add(a, forKey: "slide")
            CATransaction.commit()
        } else { done() }
    }

    private func hiddenTransform() -> CATransform3D {
        guard let l = layoutNow else { return CATransform3DIdentity }
        let d = (placement.edge.isVertical ? l.frame.width : l.frame.height) + 24
        switch placement.edge {
        case .left: return CATransform3DMakeTranslation(-d, 0, 0)
        case .right: return CATransform3DMakeTranslation(d, 0, 0)
        case .top: return CATransform3DMakeTranslation(0, d, 0)
        case .bottom: return CATransform3DMakeTranslation(0, -d, 0)
        }
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.closeWork = nil; self?.close() }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }
    private func cancelClose() { closeWork?.cancel(); closeWork = nil }

    private func key(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown, let content = root?.content else { return false }
        let editing = (panel?.firstResponder as? NSTextView)?.delegate === content.field
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if e.keyCode == UInt16(kVK_Escape) {
            if !content.sheet.isHidden { content.closeSheet() }
            else if content.searching { content.toggleSearch(false) }
            else if editing, !content.field.stringValue.isEmpty { content.field.stringValue = "" }
            else { close() }
            return true
        }
        // Editing a sheet uses normal text shortcuts, not the shelf's item commands.
        guard content.sheet.isHidden else { return false }
        // ⌘V adds a copied link straight away, unless you are typing something in the field.
        if mods == .command, e.charactersIgnoringModifiers == "v", !editing || content.field.stringValue.isEmpty {
            if content.addFromPasteboard() { return true }
        }
        if mods == .command, e.charactersIgnoringModifiers == "f" { content.toggleSearch(true); return true }
        if mods.isEmpty, e.characters == "/", !editing { content.toggleSearch(true); return true }
        return content.handleKey(e)
    }

    // MARK: Layout

    private func relayout(on screen: NSScreen? = nil) {
        guard let panel = panel, let root = root else { return }
        let scr = screen ?? panel.screen ?? NSScreen.main
        guard let s = scr else { return }
        area = s.visibleFrame
        let l = placement.layout(in: area)
        layoutNow = l
        root.apply(l, placement: placement)
        if glideNext { glideNextConsumed = true }
        if glideNext, isOpen, !Motion.reduced {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                panel.animator().setFrame(l.frame, display: true)
            }, completionHandler: { panel.invalidateShadow() })
        } else {
            panel.setFrame(l.frame, display: isOpen)
            if isOpen { panel.invalidateShadow() }
        }
        placeCue(l)
    }

    private func placeCue(_ l: DailyShelfPlacement.Layout) {
        guard let c = cuePanel else { return }
        let e = placement.edge
        let len = min(170, (e.isVertical ? l.body.height : l.body.width) * 0.45), t: CGFloat = 20
        let mid = e.isVertical ? l.frame.midY : l.frame.midX
        let f: NSRect
        switch e {
        case .left: f = NSRect(x: area.minX, y: mid - len / 2, width: t, height: len)
        case .right: f = NSRect(x: area.maxX - t, y: mid - len / 2, width: t, height: len)
        case .top: f = NSRect(x: mid - len / 2, y: area.maxY - t, width: len, height: t)
        case .bottom: f = NSRect(x: mid - len / 2, y: area.minY, width: len, height: t)
        }
        c.setFrame(f, display: true)
        cue.frame = NSRect(origin: .zero, size: f.size)
        cue.edge = e
        cue.showHandle = settings.showHandle
        showCue()
    }

    private func showCue() {
        guard let c = cuePanel else { return }
        let want = settings.enabled && !isOpen && (settings.showHandle || settings.openOnHover)
        if want { c.orderFrontRegardless() } else { c.orderOut(nil) }
    }

    private func resize(_ dy: CGFloat, ended: Bool) {
        guard let l = layoutNow else { return }
        if resizeStart == nil { resizeStart = l.height }
        let p = settings.placement
        let k: CGFloat = p.edge.isVertical && p.align == .center ? 2 : 1
        let gripOnTop = p.edge == .bottom || (p.edge.isVertical && p.align == .end)
        let want = (resizeStart ?? l.height) + (gripOnTop ? dy : -dy) * k
        liveHeight = min(max(want, p.minHeight), p.maxHeight)
        relayout()
        if ended {
            let h = Double(layoutNow?.height ?? l.height)
            liveHeight = nil; resizeStart = nil
            DailyShelfSettings.update { $0.height = h }
        }
    }

    private func resizeWidth(_ dx: CGFloat, ended: Bool) {
        guard let l = layoutNow else { return }
        let p = settings.placement
        let current = p.edge.isVertical ? l.body.width : l.body.width
        if widthStart == nil { widthStart = current }
        let k: CGFloat = !p.edge.isVertical && p.align == .center ? 2 : 1
        let want = (widthStart ?? current) + (p.edge == .right ? -dx : dx) * k
        liveWidth = min(max(want, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        relayout()
        if ended {
            let w = Double(liveWidth ?? current)
            liveWidth = nil; widthStart = nil
            DailyShelfSettings.update { $0.width = w.rounded() }
        }
    }

    /// The header drags the shelf anywhere. An outline shows where it will settle (the edge nearest the
    /// pointer, leaning the way you dragged; a corner or the middle when near one); on release it glides
    /// there and the edge and position become the settings.
    private func move(_ d: CGPoint, ended: Bool) {
        guard let panel = panel else { return }
        if moveOrigin == nil { moveOrigin = panel.frame.origin; panel.hasShadow = false }
        guard let o = moveOrigin else { return }
        panel.setFrameOrigin(NSPoint(x: o.x + d.x, y: o.y + d.y))
        let pointer = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? panel.screen ?? NSScreen.main
        guard let a = scr?.visibleFrame else { return }
        let target = DailyShelfPlacement.snap(frame: panel.frame, pointer: pointer, travel: d, area: a, current: placement)
        guard ended else { showPreview(target, in: a); return }
        hidePreview()
        moveOrigin = nil
        fromDrag = true
        glideNext = true
        area = a
        DailyShelfSettings.update { st in
            st.edge = target.edge.rawValue
            st.align = target.align.rawValue
            st.offset = Double(target.offset)
        }
        if !glideNextConsumed { relayout(on: scr) }
        fromDrag = false
        glideNext = false
        glideNextConsumed = false
        panel.hasShadow = true
    }

    private func showPreview(_ target: DailyShelfPlacement, in a: NSRect) {
        guard let pv = previewPanel else { return }
        let l = target.layout(in: a)
        let changed = target != previewTarget
        previewTarget = target
        guard changed else { return }
        preview.frame = NSRect(origin: .zero, size: l.frame.size)
        preview.outline = DailyShelfPlacement.outline(l, edge: target.edge, attached: target.attached, closed: true)
        let first = !pv.isVisible
        if first {
            pv.setFrame(l.frame, display: true)
            pv.alphaValue = 0
            pv.orderFrontRegardless()
            if let p = panel { pv.order(.below, relativeTo: p.windowNumber) }
            NSAnimationContext.runAnimationGroup { $0.duration = Motion.duration(0.12); pv.animator().alphaValue = 1 }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(0.14)
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                pv.animator().setFrame(l.frame, display: true)
            }
        }
    }

    private func hidePreview() {
        previewTarget = nil
        previewPanel?.orderOut(nil)
    }

    private var glideNextConsumed = false
    /// The next layout glides into place (after a move on the same edge) instead of jumping.
    private var glideNext = false

    // MARK: Changes

    private func settingsChanged() {
        let old = settings
        settings = DailyShelfSettings.current
        if old.effectiveHotKey != settings.effectiveHotKey || old.enabled != settings.enabled || hotKey == nil { registerHotKey() }
        if !settings.enabled { close(); cuePanel?.orderOut(nil); return }
        let moved = old.edge != settings.edge || old.align != settings.align || old.attached != settings.attached
        if moved && isOpen && !fromDrag {
            // Show the new place: slide away, then back out of the new edge.
            panel?.orderOut(nil)
            isOpen = false
            relayout()
            open()
        } else {
            relayout()
        }
        if old.filter != settings.filter || old.collapsed != settings.collapsed || old.keepOpen != settings.keepOpen || old.rolloverHour != settings.rolloverHour
            || old.sectionOrder != settings.sectionOrder || old.categoryOrder != settings.categoryOrder || old.pinnedGroups != settings.pinnedGroups {
            reloadIfOpen()
        }
        showCue()
    }

    private func storeChanged(landed: UUID?) {
        if let id = landed, let it = DailyShelfStore.shared.items.first(where: { $0.id == id }) {
            if it.sorting { DailyShelfClassifier.shared.enqueue(id) }
            if it.kind == .pr, it.github?.checkedAt == nil { DailyShelfGitHub.shared.refresh(only: [id]) }
            if isOpen, it.addedAt.timeIntervalSinceNow > -2 { root?.content.companion.react(.notification) }
        }
        cue.count = DailyShelfStore.shared.items.count
        if isOpen { root?.content.reload(landed: landed) } else { dirty = true }
    }

    private func reloadIfOpen() { if isOpen { root?.content.reload() } else { dirty = true } }

    private func periodic(force: Bool = false) {
        guard settings.enabled else { return }
        if DailyShelfStore.shared.checkRollover() { dirty = true }
        let every: TimeInterval = isOpen ? 180 : 900
        if force || Date().timeIntervalSince(lastGitHub) > every {
            lastGitHub = Date()
            DailyShelfGitHub.shared.refresh()
        }
    }
}
