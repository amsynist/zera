import AppKit

// MARK: - Right-click menus in Zera's look
//
//   ╭──────────────────────────╮
//   │ ▶  Focus on This         │   navy glass, blue neon edge
//   │ ✓  Mark as Done          │   ↑↓ to move, ⏎ to choose, Esc or a click away to close
//   │ MOVE TO                  │
//   │    General           ✓   │
//   │ ──────────────────────── │
//   │ 🗑 Delete                 │   red for anything destructive
//   ╰──────────────────────────╯
//
// It never takes keyboard focus from the window it opened over (the focus card or the island
// stays up); keys are read with a local monitor while it shows.

struct NeonMenuItem {
    enum Kind { case action, header, separator, info }
    var kind: Kind
    var title: String
    var symbol: String?
    var checked = false
    var destructive = false
    var run: (() -> Void)?

    static func action(_ title: String, _ symbol: String? = nil, checked: Bool = false, destructive: Bool = false,
                       _ run: @escaping () -> Void) -> NeonMenuItem {
        NeonMenuItem(kind: .action, title: title, symbol: symbol, checked: checked, destructive: destructive, run: run)
    }
    static func header(_ title: String) -> NeonMenuItem { NeonMenuItem(kind: .header, title: title) }
    static func info(_ title: String, _ symbol: String? = nil) -> NeonMenuItem { NeonMenuItem(kind: .info, title: title, symbol: symbol) }
    static let separator = NeonMenuItem(kind: .separator, title: "")
}

final class NeonMenu: NSObject {
    static let shared = NeonMenu()
    private static let margin: CGFloat = 22, rowH: CGFloat = 30, headerH: CGFloat = 24, sepH: CGFloat = 9, pad: CGFloat = 6

    private let panel: FloatingPanel
    private let view = NeonMenuView()
    private var monitors: [Any] = []
    private(set) var isOpen = false

    private override init() {
        panel = FloatingPanel.make(size: NSSize(width: 200, height: 100), level: .popUpMenu, keyable: false)
        super.init()
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        view.onChoose = { [weak self] item in
            self?.close()
            DispatchQueue.main.async { item.run?() }
        }
    }

    static func height(_ item: NeonMenuItem) -> CGFloat {
        switch item.kind {
        case .action, .info: return rowH
        case .header: return headerH
        case .separator: return sepH
        }
    }

    /// Opens at the pointer (kept on screen).
    func show(_ items: [NeonMenuItem], at point: NSPoint = NSEvent.mouseLocation) {
        close()
        guard items.contains(where: { $0.kind == .action }) else { return }
        let font = NeonMenuView.font
        let textW = items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 100
        let w = max(190, ceil(textW) + 76) + Self.margin * 2
        let h = items.reduce(0) { $0 + Self.height($1) } + Self.pad * 2 + Self.margin * 2
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        // Top-left corner of the glass at the pointer; flipped to the other side near an edge.
        var x = point.x - Self.margin + 2, y = point.y + Self.margin - h - 2
        if x + w - Self.margin > vf.maxX { x = point.x - w + Self.margin - 2 }
        if y + Self.margin < vf.minY { y = point.y - Self.margin + 2 }
        x = max(vf.minX - Self.margin, min(vf.maxX - w + Self.margin, x))
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        view.frame = NSRect(x: 0, y: 0, width: w, height: h)
        view.items = items
        view.cursor = nil
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(0.1)
            panel.animator().alphaValue = 1
        }
        isOpen = true
        watch()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.orderOut(nil)
    }

    private func watch() {
        // A click anywhere else closes it (in Zera's other windows, or in another app).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            guard let self = self, e.window !== self.panel else { return e }
            self.close()
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.close() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self = self, self.isOpen else { return e }
            switch e.keyCode {
            case 53: self.close()
            case 125: self.view.moveCursor(1)
            case 126: self.view.moveCursor(-1)
            case 36, 76: self.view.chooseCursor()
            default: return e
            }
            return nil
        }) { monitors.append(m) }
    }
}

final class NeonMenuView: NSView {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    var items: [NeonMenuItem] = [] { didSet { needsDisplay = true } }
    var cursor: Int? { didSet { needsDisplay = true } }
    var onChoose: ((NeonMenuItem) -> Void)?
    private let m: CGFloat = 22, pad: CGFloat = 6
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var glass: NSRect { bounds.insetBy(dx: m, dy: m) }

    private func rects() -> [NSRect] {
        var y = glass.minY + pad
        return items.map { it in
            let h = NeonMenu.height(it)
            defer { y += h }
            return NSRect(x: glass.minX + pad, y: y, width: glass.width - pad * 2, height: h)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let g = NSBezierPath(roundedRect: glass, xRadius: 14, yRadius: 14)
        Neon.glowing(Neon.halo.withAlphaComponent(0.45), blur: 14) {
            NSColor(srgbRed: 0.024, green: 0.043, blue: 0.11, alpha: 0.985).setFill(); g.fill()
        }
        Neon.edge.withAlphaComponent(0.7).setStroke(); g.lineWidth = 1; g.stroke()
        for (i, (it, r)) in zip(items, rects()).enumerated() {
            switch it.kind {
            case .separator:
                NSColor(srgbRed: 0.33, green: 0.5, blue: 1, alpha: 0.18).setFill()
                NSRect(x: r.minX + 6, y: r.midY, width: r.width - 12, height: 1).fill()
            case .header:
                text(it.title, TaskFont.clock(10.5), Neon.textDim, NSRect(x: r.minX + 10, y: r.minY + 4, width: r.width - 20, height: r.height - 4), kern: 1.2)
            case .info:
                if let sym = it.symbol { Neon.symbol(sym, in: NSRect(x: r.minX + 6, y: r.minY, width: 20, height: r.height), size: 10.5, color: Neon.textDim) }
                text(it.title, .systemFont(ofSize: 12), Neon.textDim, NSRect(x: r.minX + 32, y: r.minY, width: r.width - 40, height: r.height))
            case .action:
                let on = cursor == i
                if on {
                    let hp = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
                    (it.destructive ? Neon.red.withAlphaComponent(0.16) : Neon.accent.withAlphaComponent(0.16)).setFill(); hp.fill()
                    (it.destructive ? Neon.red.withAlphaComponent(0.45) : Neon.accent.withAlphaComponent(0.45)).setStroke(); hp.lineWidth = 1; hp.stroke()
                }
                let col = it.destructive ? Neon.red : Neon.text
                if let sym = it.symbol {
                    Neon.symbol(sym, in: NSRect(x: r.minX + 6, y: r.minY, width: 20, height: r.height), size: 11,
                                color: it.destructive ? Neon.red : (on ? Neon.cyan : Neon.glyph))
                }
                text(it.title, Self.font, col, NSRect(x: r.minX + 32, y: r.minY, width: r.width - 60, height: r.height))
                if it.checked {
                    Neon.symbol("checkmark", in: NSRect(x: r.maxX - 26, y: r.minY, width: 20, height: r.height), size: 11, weight: .bold, color: Neon.cyan)
                }
            }
        }
    }

    private func text(_ s: String, _ f: NSFont, _ c: NSColor, _ r: NSRect, kern: CGFloat = 0) {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c, .paragraphStyle: ps]
        if kern != 0 { a[.kern] = kern }
        let h = ceil(f.ascender - f.descender)
        NSAttributedString(string: s, attributes: a).draw(with: NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h),
                                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func index(at p: NSPoint) -> Int? {
        rects().firstIndex { $0.contains(p) }.flatMap { items[$0].kind == .action ? $0 : nil }
    }

    func moveCursor(_ d: Int) {
        let acts = items.indices.filter { items[$0].kind == .action }
        guard !acts.isEmpty else { return }
        let at = cursor.flatMap { acts.firstIndex(of: $0) } ?? (d > 0 ? -1 : acts.count)
        cursor = acts[(at + d + acts.count) % acts.count]
    }
    func chooseCursor() { if let c = cursor { onChoose?(items[c]) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { cursor = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { cursor = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onChoose?(items[i]) }
    }
    override func resetCursorRects() { addCursorRect(glass, cursor: .pointingHand) }
}
