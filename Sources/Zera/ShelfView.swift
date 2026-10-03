import AppKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

protocol ShelfViewDelegate: AnyObject {
    func shelfDidAcceptDrop()
    func shelfDragOverChanged(_ over: Bool)
    func shelfDragOutBegan()
    func shelfDragOutEnded()
    func shelfRequestsHide()
    func shelfHeightChanged()
    /// Zera speaks for the shelf. `seconds == 0` holds the line until `shelfSettles()`.
    func shelfSays(_ line: String, mood: ZeraMood, for seconds: TimeInterval)
    func shelfSettles()
    /// Summarize / Explain / Extract / Ask about a shelf item — answered inside Zera.
    func shelfRequests(_ action: FileAction, on item: ShelfItem)
}

/// Which kinds of items the shelf is showing.
enum ShelfFilter: Int, CaseIterable {
    case all, files, links, notes
    var title: String {
        switch self {
        case .all: return "All"
        case .files: return "Files"
        case .links: return "Links"
        case .notes: return "Notes"
        }
    }
}

extension ShelfItem {
    var isLink: Bool { url.pathExtension.lowercased() == "webloc" }
    var isNote: Bool { ["txt", "rtf", "md"].contains(url.pathExtension.lowercased()) }

    func matches(_ filter: ShelfFilter) -> Bool {
        switch filter {
        case .all: return true
        case .files: return !isLink && !isNote
        case .links: return isLink
        case .notes: return isNote
        }
    }
}

/// The Drop Files card: search, type tabs, the dashed drop zone or a grid of tiles, and an
/// action row — Summarize / Explain / Extract, plus "Ask Zera" — that Zera answers herself.
/// Double-click a tile to open it.
final class ShelfView: CardBase, CardContent {
    weak var delegate: ShelfViewDelegate?
    var cardWidth: CGFloat { Theme.panelWidth }

    private let search = SearchBox(placeholder: "Search files, links, notes…")
    private let tabs = PillTabs(titles: ShelfFilter.allCases.map { $0.title })
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let empty = DropZone()
    private let dropRing = NSView()
    private let actions = FlippedView()
    private var actionChips: [ActionChip] = []
    private let askField = ThemedField(placeholder: "Ask Zera about this file…")
    private let askSend: IconButton
    private var asking = false
    private let footer = FooterBar()

    private var tiles: [ItemTileView] = []
    private var selection: Set<UUID> = []
    private var lastClickedID: UUID?
    private var filter: ShelfFilter = .all
    private var query = ""

    private var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            dropRing.isHidden = !isDropTarget
            empty.isTargeted = isDropTarget
            if isDropTarget { delegate?.shelfSays("toss it here! 🙌", mood: .excited, for: 0) }
            else { delegate?.shelfSettles() }
            delegate?.shelfDragOverChanged(isDropTarget)
        }
    }

    private let searchHeight: CGFloat = Metrics.control + 4
    private let tabsHeight: CGFloat = Metrics.control + 2
    private let emptyHeight: CGFloat = 188
    /// Two rows of action chips, plus the ask field when it is open.
    private var actionsHeight: CGFloat { ActionChip.height * 2 + Space.s + (asking ? Space.s + Metrics.control : 0) }
    private let footerHeight: CGFloat = 48
    private let listInset: CGFloat = 6

    private var headerHeight: CGFloat { headerBottom + searchHeight + Space.m + tabsHeight + Space.m }

    override var acceptsFirstResponder: Bool { true }

    init() {
        askSend = IconButton(symbol: "arrow.up.circle.fill", label: "Ask Zera", target: nil, action: #selector(ShelfView.askTapped))
        super.init(width: Theme.panelWidth, title: "Drop Files")
        askSend.target = self
        build()
        registerForDraggedTypes([.fileURL, .png, .tiff, .pdf, .rtf, .string, .URL])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ShelfStore.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    private func build() {
        let p = Pal
        search.field.delegate = self
        addSubview(search)

        tabs.onSelect = { [weak self] i in
            self?.filter = ShelfFilter(rawValue: i) ?? .all
            self?.reload()
        }
        addSubview(tabs)

        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = list
        addSubview(scroll)

        addSubview(empty)

        dropRing.wantsLayer = true
        dropRing.layer?.borderWidth = 2
        dropRing.layer?.cornerRadius = Radius.card
        dropRing.layer?.cornerCurve = .continuous
        dropRing.layer?.borderColor = p.accent.cgColor
        dropRing.layer?.backgroundColor = p.accent.withAlphaComponent(0.08).cgColor
        dropRing.isHidden = true
        addSubview(dropRing)

        addSubview(actions)
        // 2 × 2, like the mock: Summarize · Extract / Explain · Ask Zera.
        let specs: [(String, String, NSColor, () -> Void)] = [
            ("Summarize file", "sparkles", p.tileClaude, { [weak self] in self?.request(.summarize) }),
            ("Extract text", "doc.text", p.tileNote, { [weak self] in self?.request(.extract) }),
            ("Explain file", "text.magnifyingglass", p.info, { [weak self] in self?.request(.explain) }),
            ("Ask Zera", "questionmark.bubble", p.accent, { [weak self] in self?.toggleAsk() }),
        ]
        for (t, sym, color, act) in specs {
            let c = ActionChip(symbol: sym, color: color, title: t)
            c.onTap = act
            actions.addSubview(c)
            actionChips.append(c)
        }
        askField.delegate = self
        askField.isHidden = true
        askSend.isHidden = true
        actions.addSubview(askField)
        actions.addSubview(askSend)

        footer.onPaste = { [weak self] in self?.paste() }
        footer.onClear = { [weak self] in self?.clearAll() }
        addSubview(footer)
    }

    // MARK: - Sizing

    private var visibleItems: [ShelfItem] {
        ShelfStore.shared.items.filter { item in
            item.matches(filter) && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query))
        }
    }

    var desiredHeight: CGFloat {
        let n = visibleItems.count
        let contentH: CGFloat
        if n == 0 {
            contentH = emptyHeight
        } else {
            let gridRows = Int(ceil(Double(n) / Double(Theme.gridColumns)))
            let visible = min(gridRows, Theme.maxVisibleGridRows)
            contentH = CGFloat(visible) * Theme.tileHeight + CGFloat(visible - 1) * Theme.tileGap + listInset * 2
        }
        let actionsH: CGFloat = n == 0 ? 0 : actionsHeight + Space.s
        return headerHeight + contentH + actionsH + footerHeight
    }

    override func layout() {
        super.layout()
        layoutHeader()
        let w = bounds.width
        let inner = w - Theme.pad * 2
        search.frame = NSRect(x: Theme.pad, y: headerBottom, width: inner, height: searchHeight)
        tabs.frame = NSRect(x: Theme.pad, y: search.frame.maxY + Space.m, width: inner, height: tabsHeight)

        let hasItems = !visibleItems.isEmpty
        let actionsH: CGFloat = hasItems ? actionsHeight + Space.s : 0
        let box = NSRect(x: Theme.pad, y: headerHeight, width: inner,
                         height: bounds.height - headerHeight - footerHeight - actionsH)
        scroll.frame = box
        empty.frame = box
        dropRing.frame = bounds
        actions.isHidden = !hasItems
        actions.frame = NSRect(x: Theme.pad, y: box.maxY + Space.s, width: inner, height: actionsHeight)
        let cw = (inner - Space.s) / 2
        for (i, c) in actionChips.enumerated() {
            let col = CGFloat(i % 2), row = CGFloat(i / 2)
            c.frame = NSRect(x: col * (cw + Space.s), y: row * (ActionChip.height + Space.s), width: cw, height: ActionChip.height)
        }
        actionChips.last?.selected = asking
        let ay = ActionChip.height * 2 + Space.s * 2
        askField.frame = NSRect(x: 0, y: ay, width: inner - Metrics.control - Space.s, height: Metrics.control)
        askSend.frame = NSRect(x: inner - Metrics.control, y: ay, width: Metrics.control, height: Metrics.control)
        footer.frame = NSRect(x: 0, y: bounds.height - footerHeight, width: w, height: footerHeight)
        layoutTiles()
    }

    private func layoutTiles() {
        let cols = Theme.gridColumns
        let w = scroll.contentSize.width
        let used = CGFloat(cols) * Theme.tileWidth + CGFloat(cols - 1) * Theme.tileGap
        let leading = max(0, (w - used) / 2)
        for (i, tile) in tiles.enumerated() {
            let col = i % cols, row = i / cols
            tile.frame = NSRect(x: leading + CGFloat(col) * (Theme.tileWidth + Theme.tileGap),
                                y: listInset + CGFloat(row) * (Theme.tileHeight + Theme.tileGap),
                                width: Theme.tileWidth, height: Theme.tileHeight)
        }
        let rowCount = Int(ceil(Double(tiles.count) / Double(cols)))
        let h = rowCount == 0 ? scroll.contentSize.height
              : CGFloat(rowCount) * Theme.tileHeight + CGFloat(rowCount - 1) * Theme.tileGap + listInset * 2
        list.frame = NSRect(x: 0, y: 0, width: w, height: max(h, scroll.contentSize.height))
    }

    // MARK: - Data

    @objc func reload() {
        let items = visibleItems
        let all = ShelfStore.shared.items
        tiles.forEach { $0.removeFromSuperview() }
        selection = selection.filter { id in all.contains { $0.id == id } }
        tiles = items.map { item in
            let tile = ItemTileView(item: item)
            tile.delegate = self
            tile.selected = selection.contains(item.id)
            list.addSubview(tile)
            return tile
        }
        empty.isHidden = !items.isEmpty
        empty.mode = all.isEmpty ? .drop : (items.isEmpty ? .noMatch : .drop)
        scroll.isHidden = items.isEmpty
        footer.count = all.count
        footer.clearEnabled = !all.isEmpty
        setSubtitle(all.isEmpty ? nil : (selection.isEmpty ? "\(all.count) item\(all.count == 1 ? "" : "s") · drag any tile out to use it" : "\(selection.count) selected"))
        needsLayout = true
        layoutSubtreeIfNeeded()
        delegate?.shelfHeightChanged()
        onHeightChange?()
    }

    /// Show one filter (Home → Notes).
    func select(filter f: ShelfFilter) {
        filter = f
        tabs.selected = f.rawValue
        reload()
    }

    private func clearAll() {
        ShelfStore.shared.clear()
        delegate?.shelfSays("all tidy! ✨", mood: .happy, for: 1.4)
    }

    // MARK: - Zera actions (in-app)

    /// The file an action applies to: the selected tile, or the only / first visible one.
    /// One file at a time keeps the answer about *that* file.
    private var target: ShelfItem? {
        if let sel = visibleItems.first(where: { selection.contains($0.id) && $0.exists }) { return sel }
        return visibleItems.first { $0.exists }
    }

    private func request(_ action: FileAction) {
        guard let item = target else { delegate?.shelfSays("pick a file first 🙂", mood: .thinking, for: 1.8); return }
        if selection.count > 1 { delegate?.shelfSays("one at a time — taking \(item.name)", mood: .thinking, for: 2.2) }
        delegate?.shelfRequests(action, on: item)
    }

    /// "Ask Zera" folds the question field out under the chips.
    private func toggleAsk() {
        asking.toggle()
        askField.isHidden = !asking
        askSend.isHidden = !asking
        needsLayout = true
        layoutSubtreeIfNeeded()
        delegate?.shelfHeightChanged()
        onHeightChange?()
        if asking { window?.makeFirstResponder(askField) }
    }

    @objc private func askTapped() {
        let q = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { window?.makeFirstResponder(askField); return }
        askField.stringValue = ""
        request(.ask(q))
    }



    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 51, 117: removeSelected()
        case 53: onEscape?()
        case 0 where cmd:
            selection = Set(visibleItems.map { $0.id })
            syncSelection()
        case 9 where cmd: paste()
        default: super.keyDown(with: event)
        }
    }

    func paste() {
        let n = ShelfStore.shared.ingest(pasteboard: .general)
        if n > 0 {
            delegate?.shelfSays(n == 1 ? "got it! ✨" : "got all \(n)! ✨", mood: .happy, for: 1.5)
            delegate?.shelfDidAcceptDrop()
        } else {
            delegate?.shelfSays("clipboard's empty 🤔", mood: .thinking, for: 1.6)
        }
    }

    private func removeSelected() {
        if selection.isEmpty, let first = visibleItems.first { selection = [first.id] }
        ShelfStore.shared.remove(ids: selection)
        selection.removeAll()
    }

    private func syncSelection() {
        for tile in tiles { tile.selected = selection.contains(tile.item.id) }
        let all = ShelfStore.shared.items
        setSubtitle(all.isEmpty ? nil : (selection.isEmpty ? "\(all.count) item\(all.count == 1 ? "" : "s") · drag any tile out to use it" : "\(selection.count) selected"))
    }

    // MARK: - Drop in

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { isDropTarget = true; return .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { isDropTarget = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isDropTarget = false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { isDropTarget = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let pb = sender.draggingPasteboard
        let added = ShelfStore.shared.ingest(pasteboard: pb)
        if added > 0 {
            delegate?.shelfSays(added == 1 ? "got it! ✨" : "got all \(added)! ✨", mood: .happy, for: 1.5)
            delegate?.shelfDidAcceptDrop()
            return true
        }
        if ShelfStore.shared.alreadyHas(pasteboard: pb) {
            delegate?.shelfSays("already have that one 😊", mood: .happy, for: 1.3)
            delegate?.shelfDidAcceptDrop()
            return true
        }
        delegate?.shelfSays("hmm, can't hold that", mood: .thinking, for: 1.6)
        return false
    }
}

extension ShelfView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === search.field else { return }
        query = search.field.stringValue
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if control === askField, asking { toggleAsk() } else { onEscape?() }
            return true
        }
        guard control === askField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { askTapped(); return true }
        return false
    }
}

// MARK: - Tile delegate & drag out

extension ShelfView: ItemTileDelegate {
    func tile(_ tile: ItemTileView, clickedWith event: NSEvent) {
        let id = tile.item.id
        if event.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if event.modifierFlags.contains(.shift), let anchor = lastClickedID,
                  let a = tiles.firstIndex(where: { $0.item.id == anchor }),
                  let b = tiles.firstIndex(where: { $0.item.id == id }) {
            for t in tiles[min(a, b)...max(a, b)] { selection.insert(t.item.id) }
        } else {
            selection = [id]
        }
        lastClickedID = id
        syncSelection()
    }

    func tile(_ tile: ItemTileView, startDragWith event: NSEvent) {
        if !selection.contains(tile.item.id) {
            selection = [tile.item.id]
            lastClickedID = tile.item.id
            syncSelection()
        }
        let dragged = tiles.filter { selection.contains($0.item.id) && $0.item.exists }
        guard !dragged.isEmpty else { return }
        let anchor = convert(tile.bounds, from: tile)
        var draggingItems: [NSDraggingItem] = []
        for (i, r) in dragged.enumerated() {
            let di = NSDraggingItem(pasteboardWriter: r.item.url as NSURL)
            let offset = CGFloat(i) * 4
            di.setDraggingFrame(NSRect(x: anchor.minX + offset, y: anchor.minY + offset, width: anchor.width, height: anchor.height),
                                contents: r.dragImage())
            draggingItems.append(di)
        }
        delegate?.shelfDragOutBegan()
        delegate?.shelfSays(dragged.count == 1 ? "take it! 💜" : "take all \(dragged.count)! 💜", mood: .giving, for: 0)
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func tileRequestedRemove(_ tile: ItemTileView) { ShelfStore.shared.remove(ids: [tile.item.id]) }
    func tileOpened(_ tile: ItemTileView) { NSWorkspace.shared.open(tile.item.url) }
}

extension ShelfView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [] : [.copy, .generic]
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty { delegate?.shelfSettles() }
        else { delegate?.shelfSays("delivered! 🎉", mood: .happy, for: 1.4) }
        delegate?.shelfDragOutEnded()
    }
}

// MARK: - Pieces

/// The dashed "Drop files here" zone with the cloud, the blurb and the type chips.
final class DropZone: NSView {
    enum Mode { case drop, noMatch }
    var mode: Mode = .drop { didSet { needsDisplay = true } }
    var isTargeted = false { didSet { needsDisplay = true } }

    private let chips = ["PDF", "Image", "Code", "Text", "Docs", "Any file"]
    private let cloud = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "Drop")?
        .withSymbolConfiguration(.init(pointSize: 30, weight: .light))

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let inset = bounds.insetBy(dx: 1, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: Radius.l, yRadius: Radius.l)
        (isTargeted ? p.accent.withAlphaComponent(0.16) : p.accent.withAlphaComponent(p.isDark ? 0.07 : 0.06)).setFill()
        path.fill()
        path.lineWidth = 1.5
        path.setLineDash([6, 5], count: 2, phase: 0)
        (isTargeted ? p.accent : p.accent.withAlphaComponent(0.55)).setStroke()
        path.stroke()

        var y = inset.minY + 20
        if let img = cloud?.withSymbolConfiguration(.init(hierarchicalColor: p.accent)) {
            let s = img.size
            img.draw(in: NSRect(x: bounds.midX - s.width / 2, y: y, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            y += s.height + 8
        }
        let title = mode == .noMatch ? "Nothing matches" : (isTargeted ? "Let go — I'll catch it" : "Drop files here")
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: Typo.title, .foregroundColor: p.text]
        let ts = (title as NSString).size(withAttributes: titleAttrs)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: y), withAttributes: titleAttrs)
        y += ts.height + 3

        let sub = mode == .noMatch ? "Try another tab or clear the search." : "I'll summarize, explain or extract the text — right here."
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let subAttrs: [NSAttributedString.Key: Any] = [.font: Typo.secondary, .paragraphStyle: style, .foregroundColor: p.textSecondary]
        (sub as NSString).draw(in: NSRect(x: inset.minX + 14, y: y, width: inset.width - 28, height: 18), withAttributes: subAttrs)
        y += 30

        guard mode == .drop else { return }
        let chipAttrs: [NSAttributedString.Key: Any] = [.font: Typo.badge, .foregroundColor: p.text(0.8)]
        let chipH: CGFloat = 22, chipPad: CGFloat = 9, gap: CGFloat = 6
        let widths = chips.map { ceil(($0 as NSString).size(withAttributes: chipAttrs).width) + chipPad * 2 }
        var x = bounds.midX - (widths.reduce(0, +) + gap * CGFloat(chips.count - 1)) / 2
        for (chip, w) in zip(chips, widths) {
            let r = NSRect(x: x, y: y, width: w, height: chipH)
            let cp = NSBezierPath(roundedRect: r, xRadius: Radius.s, yRadius: Radius.s)
            p.surface.setFill(); cp.fill()
            cp.lineWidth = 1; p.border.setStroke(); cp.stroke()
            let s = (chip as NSString).size(withAttributes: chipAttrs)
            (chip as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: chipAttrs)
            x += w + gap
        }
    }
}

/// A compact action: icon tile + label, two per row. Hover lifts it; `selected` keeps it lit
/// while something it opened (the ask field) is showing.
final class ActionChip: NSView {
    var onTap: (() -> Void)?
    var selected = false { didSet { restyle() } }
    static let height: CGFloat = 36
    private let tile: IconTile
    private let title = NSTextField(labelWithString: "")
    private var hovered = false { didSet { restyle() } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbol: String, color: NSColor, title t: String) {
        tile = IconTile(symbol: symbol, color: color, size: 22, pointSize: 10.5)
        super.init(frame: .zero)
        roundLayer(Radius.m)
        addSubview(tile)
        title.stringValue = t
        title.font = Typo.nav
        title.textColor = Pal.text
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        setAccessibilityRole(.button)
        setAccessibilityLabel(t)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let p = Pal
        layer?.backgroundColor = (selected ? p.accentSoft : (hovered ? p.surfaceHover : p.surface)).cgColor
    }

    override func layout() {
        super.layout()
        tile.frame = NSRect(x: Space.s, y: (bounds.height - 22) / 2, width: 22, height: 22)
        title.frame = NSRect(x: Space.s + 22 + Space.s, y: (bounds.height - 16) / 2, width: bounds.width - Space.s * 3 - 22, height: 16)
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

/// Footer: her little face, "Zera · Online", and the paste / clear buttons.
final class FooterBar: NSView {
    var onPaste: (() -> Void)?
    var onClear: (() -> Void)?
    var count: Int = 0 { didSet { needsDisplay = true } }
    var clearEnabled = true { didSet { clearButton.isHidden = !clearEnabled } }

    private let avatar = NSImageView()
    private let pasteButton: IconButton
    private let clearButton: IconButton

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        pasteButton = IconButton(symbol: "doc.on.clipboard", label: "Paste clipboard onto the shelf", target: nil, action: #selector(FooterBar.pasteTapped))
        clearButton = IconButton(symbol: "trash", label: "Clear the shelf", target: nil, action: #selector(FooterBar.clearTapped))
        super.init(frame: frameRect)
        pasteButton.target = self; clearButton.target = self
        avatar.image = ZeraView.headImage(size: 28)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        addSubview(avatar)
        addSubview(pasteButton)
        addSubview(clearButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func pasteTapped() { onPaste?() }
    @objc private func clearTapped() { onClear?() }

    override func layout() {
        super.layout()
        avatar.frame = NSRect(x: Theme.pad, y: (bounds.height - 28) / 2, width: 28, height: 28)
        let c = Metrics.control
        clearButton.frame = NSRect(x: bounds.width - Theme.pad - c, y: (bounds.height - c) / 2, width: c, height: c)
        pasteButton.frame = NSRect(x: clearButton.frame.minX - c - Space.xs, y: (bounds.height - c) / 2, width: c, height: c)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        p.divider.setFill()
        NSRect(x: Theme.pad, y: 0, width: bounds.width - Theme.pad * 2, height: 1).fill()
        let x = avatar.frame.maxX + 10
        ("Zera" as NSString).draw(at: NSPoint(x: x, y: bounds.midY - 15), withAttributes: [.font: Typo.bodyStrong, .foregroundColor: p.text])
        NSColor(srgbRed: 0.30, green: 0.80, blue: 0.45, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY + 5, width: 7, height: 7)).fill()
        let status = count == 0 ? "Online" : (count == 1 ? "Online · holding 1 item" : "Online · holding \(count) items")
        (status as NSString).draw(at: NSPoint(x: x + 11, y: bounds.midY + 1), withAttributes: [.font: Typo.caption, .foregroundColor: p.textSecondary])
    }
}
