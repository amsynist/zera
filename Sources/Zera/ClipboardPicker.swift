import AppKit
import Carbon.HIToolbox

/// The clipboard shortcut opens this temporary, nonactivating picker beside the pointer.
final class ClipboardPicker: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let size = NSSize(width: 382, height: 386)
    private let panel = FloatingPanel.make(size: ClipboardPicker.size, level: .popUpMenu, keyable: true)
    private let store = ClipboardStore.shared
    private let search = SearchBox(placeholder: "Search history")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let header = NSTextField(labelWithString: "Clipboard")
    private let footer = NSTextField(labelWithString: "↑↓ Select    ↵ Copy    esc Close")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private lazy var history = GHSquareButton(symbol: "arrow.up.right", label: "Open full Clipboard",
                                             target: self, action: #selector(openHistory))
    private var items: [ClipItem] = []
    private var isOpen = false
    var onOpenHistory: (() -> Void)?

    override init() {
        super.init()

        panel.title = "Clipboard Picker"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.onKeyDown = { [weak self] in self?.handleKey($0) ?? false }
        let surface = OpenerGlass(frame: NSRect(origin: .zero, size: Self.size))
        surface.radius = Radius.card
        surface.lineWidth = 1
        surface.glow = 0.25
        panel.contentView = surface

        header.font = Typo.bodyStrong
        header.textColor = Pal.text
        footer.font = Typo.caption
        footer.textColor = Pal.textSecondary
        empty.font = Typo.body
        empty.alignment = .center
        empty.textColor = Pal.textSecondary
        search.field.delegate = self

        let column = NSTableColumn(identifier: .init("clipboard"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.focusRingType = .none
        table.selectionHighlightStyle = .none
        table.rowHeight = RowTier.compact.height
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Clipboard history")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay

        [header, history, search, scroll, empty, footer].forEach { surface.addSubview($0) }
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: ClipboardStore.changed, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func toggle(at pointer: NSPoint) {
        if isOpen { close(); return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }

        let frame = Self.frame(near: pointer, in: screen.visibleFrame)
        panel.setFrame(frame, display: false)
        let w = frame.width, h = frame.height
        header.frame = NSRect(x: 16, y: 15, width: w - 70, height: 21)
        history.frame = NSRect(x: w - 44, y: 8, width: 32, height: 32)
        search.frame = NSRect(x: 12, y: 47, width: w - 24, height: 33)
        scroll.frame = NSRect(x: 12, y: 92, width: w - 24, height: max(0, h - 126))
        empty.frame = NSRect(x: 22, y: 112, width: w - 44, height: 44)
        footer.frame = NSRect(x: 16, y: h - 24, width: w - 32, height: 16)

        search.field.stringValue = ""
        reload()
        isOpen = true
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(store.enabled ? search.field : history)
    }

    /// Prefer below and to the right, flipping independently at each screen edge.
    static func frame(near point: NSPoint, in visibleFrame: NSRect) -> NSRect {
        let safe = visibleFrame.insetBy(dx: 8, dy: 8)
        let w = min(size.width, safe.width), h = min(size.height, safe.height)
        let gap: CGFloat = 12
        let right = point.x + gap
        let below = point.y - gap - h
        let x = right + w <= safe.maxX ? right : point.x - gap - w
        let y = below >= safe.minY ? below : point.y + gap
        return NSRect(x: max(safe.minX, min(x, safe.maxX - w)),
                      y: max(safe.minY, min(y, safe.maxY - h)), width: w, height: h)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        search.field.stringValue = ""
        items.removeAll()
        table.reloadData()
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    @objc private func openHistory() {
        close()
        onOpenHistory?()
    }

    @objc private func storeChanged() {
        if isOpen { reload(prefer: items[safe: table.selectedRow]?.id) }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    private func reload(prefer id: UUID? = nil) {
        search.field.isEnabled = store.enabled
        items = store.enabled ? store.items(.all, matching: search.field.stringValue) : []
        empty.stringValue = !store.enabled ? "Clipboard history is off. Open full Clipboard to turn it on."
            : search.field.stringValue.isEmpty ? "Items you copy will appear here." : "No matching copies."
        empty.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        footer.isHidden = items.isEmpty
        table.reloadData()
        select(id.flatMap { id in items.firstIndex { $0.id == id } } ?? 0)
    }

    private func select(_ row: Int) {
        guard !items.isEmpty else { return }
        let i = max(0, min(items.count - 1, row))
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = items[safe: row] else { return nil }
        let view = ClipRow(item: item, index: row, showsActions: false)
        view.selected = row == tableView.selectedRow
        view.onCopy = { [weak self] in self?.copy(item) }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? ClipRow)?.selected = row == self.table.selectedRow
        }
    }

    private func copy(_ item: ClipItem) {
        guard store.enabled else { return }
        guard store.copy(item) else {
            SoundService.shared.play(.fileReject)
            if let row = items.firstIndex(where: { $0.id == item.id }) {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipRow)?.flash(ok: false)
            }
            return
        }
        SoundService.shared.play(.clipCopy)
        if store.foldAfterCopy { close(); return }
        if let row = items.firstIndex(where: { $0.id == item.id }) {
            select(row)
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipRow)?.flash(ok: true)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if modifiers == .command, let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) {
            if let item = items[safe: digit - 1] { copy(item) }
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape: close()
        case kVK_DownArrow: select(table.selectedRow + 1)
        case kVK_UpArrow: select(table.selectedRow - 1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !store.enabled { openHistory(); return true }
            guard let item = items[safe: table.selectedRow] else { return false }
            copy(item)
        default: return false
        }
        return true
    }
}
