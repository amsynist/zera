import AppKit

// MARK: - Hover deck (Zera v2)
//
// A compact status row for hover: no repeated portrait or nested dashboard cards.
// The busiest agent and what is playing or coming up sit beside the summary. Navigation sits
// under it in the same black. Refreshes when it appears and when any of its sources change.
final class HoverDeck: NSView {
    static let height: CGFloat = 80
    var onOpen: ((CardKind) -> Void)?

    private let hero = DeckTile(symbol: "checkmark.circle")
    private let now = DeckTile(symbol: "music.note")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(hero)
        now.onTap = { [weak self] in self?.onOpen?(.home) }
        addSubview(now)
        for n in [ClaudeActivityService.changed, ClaudeHookService.changed, CodexAgentService.changed, ClaudeAgentService.changed, AgentWatch.changed, NowPlayingService.changed, ReminderService.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: n, object: nil)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func refresh() {
        let p = Pal
        let activity = MainActor.assumeIsolated { AgentOverview.snapshot() }
        let active = activity.filter { [.working, .waiting, .failed].contains($0.state) }
        let first = active.sorted { $0.state.rawValue < $1.state.rawValue }.first
        if let first {
            hero.symbolName = first.needsApproval ? "hand.raised" : "waveform.path"
            hero.set(title: "\(first.providerName) · \(first.title)", detail: first.needsApproval ? "Needs your approval · \(first.activity)" : first.activity, tint: first.tone)
            hero.onTap = { [weak self] in self?.onOpen?(.claude) }
        } else {
            hero.symbolName = "checkmark.circle"
            hero.set(title: "Your space is clear", detail: "Open Home to pick up where you left off", tint: p.textSecondary)
            hero.onTap = { [weak self] in self?.onOpen?(.home) }
        }
        if let t = NowPlayingService.shared.track {
            now.symbolName = "music.note"
            now.set(title: t.title, detail: t.artist, tint: NSColor(srgbRed: 1, green: 0.54, blue: 0.36, alpha: 1))
        } else if let next = ReminderService.shared.nextEvent(within: 6 * 3600) {
            now.symbolName = "calendar"
            now.set(title: next.event.title, detail: "at \(ReminderService.timeFormatter.string(from: next.start))", tint: p.tileCalendar)
        } else {
            now.symbolName = "sparkles"
            now.set(title: "Quiet so far", detail: "Music and your next event show here", tint: p.textTertiary)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        let centerSpace: CGFloat = 112
        let width = max(0, (bounds.width - centerSpace) / 2)
        hero.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        now.frame = NSRect(x: width + centerSpace, y: 0, width: max(0, width - 32), height: bounds.height)
    }
}

/// A small dark tile: a coloured symbol, a title and a detail line. Click to open its screen.
final class DeckTile: NSButton {
    override var acceptsFirstResponder: Bool { true }
    var onTap: (() -> Void)?
    var symbolName: String { didSet { icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold)) } }
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var hovered = false { didSet { restyle() } }

    override var isFlipped: Bool { true }

    init(symbol: String) {
        symbolName = symbol
        super.init(frame: .zero)
        title = ""; isBordered = false
        setButtonType(.momentaryChange)
        target = self; action = #selector(activate)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        wantsLayer = true
        layer?.cornerRadius = Radius.m
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        titleLabel.font = Typo.control
        titleLabel.lineBreakMode = .byTruncatingTail
        detail.font = Typo.secondary
        detail.maximumNumberOfLines = 2
        [icon, titleLabel, detail].forEach(addSubview)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, detail d: String, tint: NSColor) {
        titleLabel.stringValue = t
        detail.stringValue = d
        icon.contentTintColor = tint
        setAccessibilityLabel("\(t), \(d)")
    }

    private func restyle() {
        let p = Pal
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : 0.16)
        layer?.backgroundColor = (hovered ? p.surfaceHover : .clear).cgColor
        layer?.borderWidth = 0
        layer?.borderColor = p.border.cgColor
        CATransaction.commit()
        titleLabel.textColor = p.text
        detail.textColor = p.textSecondary
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, x: CGFloat = 40, w = max(0, bounds.width - x - pad)
        icon.frame = NSRect(x: pad, y: 22, width: 18, height: 18)
        titleLabel.frame = NSRect(x: x, y: 16, width: w, height: 18)
        detail.frame = NSRect(x: x, y: 42, width: w, height: 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetHoverTracking()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    @objc private func activate() { onTap?() }
    override func draw(_ dirtyRect: NSRect) { drawControlFocus() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
