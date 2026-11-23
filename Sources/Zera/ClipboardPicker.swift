import AppKit
import Carbon.HIToolbox

/// The clipboard shortcut opens this temporary, nonactivating picker beside the pointer: a Signal
/// prompt wired into a deck of cards (see ClipDeck.swift), with no window box behind it.
final class ClipboardPicker: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let size = ClipDeckLayout.size
    private let panel = FloatingPanel.make(size: ClipboardPicker.size, level: .popUpMenu, keyable: true)
    private let store = ClipboardStore.shared
    private let root = Root(frame: NSRect(origin: .zero, size: ClipboardPicker.size))
    /// Internal so render tests can stamp a card without touching the real clipboard.
    let deck = ClipDeckView(frame: .zero)
    private let prompt = ClipPromptView(frame: .zero)
    private let status = ClipStatusView(frame: .zero)
    private(set) var items: [ClipItem] = []
    private(set) var selected = 0
    private(set) var filter: ClipboardStore.Filter = .all
    private var isOpen = false
    private var closeWork: DispatchWorkItem?
    private var saidWork: DispatchWorkItem?
    var onOpenHistory: (() -> Void)?
    var searchField: NSTextField { prompt.field }
    /// The cards on show (tests).
    var visibleCards: Int { deck.visibleCount }

    private final class Root: NSView {
        override var isFlipped: Bool { true }
    }

    override init() {
        super.init()

        panel.title = "Clipboard Picker"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        // The cards carry their own shadows; a window shadow would trail behind them as they move.
        panel.hasShadow = false
        panel.onKeyDown = { [weak self] in self?.handleKey($0) ?? false }
        root.wantsLayer = true
        panel.contentView = root
        [deck, status, prompt].forEach { root.addSubview($0) }

        prompt.field.delegate = self
        prompt.filterButton.onPress = { [weak self] in self?.cycleFilter(1) }
        prompt.openButton.onPress = { [weak self] in self?.openHistory() }
        deck.onCopy = { [weak self] in
            guard let self = self else { return }
            if let item = self.items[safe: self.selected] { self.copy(item) } else if !self.store.enabled { self.openHistory() }
        }
        deck.onSelect = { [weak self] in self?.select($0) }
        deck.onStep = { [weak self] in self?.step($0) }
        status.hints = [("↑↓", "flip"), ("↵", "copy"), ("⇥", "filter"), ("⌘1–9", ""), ("⌘P", "pin")]
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: ClipboardStore.changed, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func toggle(at pointer: NSPoint) {
        if isOpen { close(); return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }

        let frame = Self.frame(near: pointer, in: screen.visibleFrame)
        panel.setFrame(frame, display: false)
        let layout = ClipDeckLayout(bounds: frame.size)
        deck.scale = screen.backingScaleFactor
        deck.frame = NSRect(origin: .zero, size: frame.size)
        prompt.frame = layout.prompt
        status.frame = layout.status
        root.layoutSubtreeIfNeeded()

        prompt.field.stringValue = ""
        filter = .all
        deck.clear()
        isOpen = true
        reload()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(store.enabled ? prompt.field : deck)
        deck.setLive(true)
        deck.deal()
        deck.focus()
        if !Motion.reduced {
            prompt.alphaValue = 0
            status.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                prompt.animator().alphaValue = 1
                status.animator().alphaValue = 1
            }
        }
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
        closeWork?.cancel()
        closeWork = nil
        saidWork?.cancel()
        status.said = ""
        deck.setLive(false)
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        prompt.field.stringValue = ""
        items.removeAll()
        deck.clear()
        deck.releasePictures()
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func openHistory() {
        close()
        onOpenHistory?()
    }

    @objc private func storeChanged() {
        if isOpen { reload(prefer: items[safe: selected]?.id) }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    /// Tab steps through All, Text, Images, Files and Pinned.
    func cycleFilter(_ direction: Int) {
        guard store.enabled else { return }
        let all = ClipboardStore.Filter.allCases
        let i = all.firstIndex(of: filter) ?? 0
        filter = all[((i + direction) % all.count + all.count) % all.count]
        reload()
    }

    private func filterName(_ f: ClipboardStore.Filter) -> String {
        switch f {
        case .all: return "ALL"
        case .text: return "TEXT"
        case .images: return "IMAGES"
        case .files: return "FILES"
        case .pinned: return "PINNED"
        }
    }

    private func reload(prefer id: UUID? = nil) {
        let query = prompt.field.stringValue
        prompt.field.isEnabled = store.enabled
        items = store.enabled ? store.items(filter, matching: query) : []
        selected = id.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        if items.isEmpty {
            let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
            if !store.enabled {
                deck.showNote("Clipboard history is off", hint: "Press ↵ to open the full Clipboard and turn it on.", animated: isOpen)
            } else if searching || filter != .all {
                deck.showNote("No matching copies", hint: searching ? "Try fewer letters, or press ⇥ for another filter." : "Press ⇥ for another filter.", animated: isOpen)
            } else {
                deck.showNote("Nothing copied yet", hint: "Copy something and it lands on this clip.", animated: isOpen)
            }
        } else {
            deck.show(items, selected: selected, step: nil, animated: isOpen)
        }
        refreshChrome()
    }

    private func refreshChrome() {
        prompt.filterButton.title = filterName(filter)
        prompt.filterButton.lit = filter != .all
        prompt.filterButton.isHidden = !store.enabled
        status.counter = items.isEmpty ? "" : "\(selected + 1)/\(items.count)"
        status.filter = store.enabled ? filterName(filter) : "off"
        if let item = items[safe: selected] {
            deck.setAccessibilityValue("\(item.kindName): \(item.title), \(selected + 1) of \(items.count)")
        } else {
            deck.setAccessibilityValue("")
        }
        NSAccessibility.post(element: deck, notification: .valueChanged)
    }

    /// Bring the card at `index` to the front.
    func select(_ index: Int) {
        guard !items.isEmpty else { return }
        let i = max(0, min(items.count - 1, index))
        guard i != selected else { if index != selected { deck.nudge(index < selected ? 1 : -1) }; return }
        let step = i - selected
        selected = i
        deck.show(items, selected: selected, step: step, animated: true)
        refreshChrome()
    }

    func step(_ delta: Int) { select(selected + delta) }

    private func copy(_ item: ClipItem) {
        guard store.enabled else { return }
        // Bring the copied card forward first, so the stamp lands on it.
        if let i = items.firstIndex(where: { $0.id == item.id }), i != selected { select(i) }
        guard store.copy(item) else {
            SoundService.shared.play(.fileReject)
            deck.stamp(ok: false)
            return
        }
        // It moved to the top of the history; stay on it.
        reload(prefer: item.id)
        SoundService.shared.play(.clipCopy)
        deck.stamp(ok: true)
        say("copied · ⌘V to paste")
        guard store.foldAfterCopy else { return }
        // Long enough to see the stamp land, short enough to paste straight away.
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduced ? 0.12 : 0.3), execute: work)
    }

    /// A word on the status line for a moment.
    private func say(_ line: String) {
        saidWork?.cancel()
        status.said = line
        let work = DispatchWorkItem { [weak self] in self?.status.said = "" }
        saidWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let code = Int(event.keyCode)
        if modifiers == .command {
            if let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) {
                if let item = items[safe: digit - 1] { copy(item) }
                return true
            }
            switch code {
            case kVK_ANSI_P:
                if let item = items[safe: selected] { store.togglePin(item.id) }
            case kVK_ANSI_O:
                openHistory()
            case kVK_Delete:
                guard prompt.field.stringValue.isEmpty, let item = items[safe: selected] else { return false }
                store.delete(item.id)
            default: return false
            }
            return true
        }
        if code == kVK_Tab, modifiers.isEmpty || modifiers == .shift {
            cycleFilter(modifiers == .shift ? -1 : 1)
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch code {
        case kVK_Escape: close()
        case kVK_DownArrow: step(1)
        case kVK_UpArrow: step(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !store.enabled { openHistory(); return true }
            guard let item = items[safe: selected] else { return false }
            copy(item)
        default: return false
        }
        return true
    }
}
