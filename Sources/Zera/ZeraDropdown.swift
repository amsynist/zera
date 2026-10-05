import AppKit

// Zera's own dropdowns: a small floating glass panel with styled rows, used instead of native
// pop-up buttons and menus on the Reminders screens (choices, ••• menus, snooze, + Add).
// It lives in its own borderless window, so it is never clipped by the card it opens from.

struct DropdownItem {
    var title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: NSColor? = nil
    var checked = false
    var destructive = false
    var isSeparator = false
    var action: () -> Void = {}

    static func separator() -> DropdownItem { DropdownItem(title: "", isSeparator: true) }
}

private func dropdownIcon(_ name: String, _ size: CGFloat, _ color: NSColor) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))?
        .withSymbolConfiguration(.init(paletteColors: [color]))
}

/// One row of the list.
private final class DropdownRow: NSView {
    let item: DropdownItem
    var onPick: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let subFont = NSFont.systemFont(ofSize: 11.5)

    init(item: DropdownItem) {
        self.item = item
        super.init(frame: .zero)
        setAccessibilityRole(item.isSeparator ? .unknown : .menuItem)
        setAccessibilityLabel(item.title)
    }
    required init?(coder: NSCoder) { fatalError() }

    static func height(_ it: DropdownItem) -> CGFloat { it.isSeparator ? 9 : (it.subtitle != nil ? 52 : 34) }

    static func naturalWidth(_ it: DropdownItem) -> CGFloat {
        guard !it.isSeparator else { return 0 }
        let t = ceil((it.title as NSString).size(withAttributes: [.font: titleFont]).width)
        let s = it.subtitle.map { ceil(($0 as NSString).size(withAttributes: [.font: subFont]).width) } ?? 0
        let lead: CGFloat = it.subtitle != nil ? 12 + 32 + 12 : (it.symbol != nil ? 12 + 18 + 10 : 14)
        return lead + max(t, s) + 40
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        if item.isSeparator {
            p.divider.setFill()
            NSRect(x: 10, y: 4, width: bounds.width - 20, height: 1).fill()
            return
        }
        let r = bounds.insetBy(dx: 5, dy: 2)
        if hovered {
            let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            if item.destructive {
                p.danger.withAlphaComponent(0.14).setFill(); path.fill()
            } else {
                p.drawSelected(path)
            }
        }
        let color: NSColor = item.destructive ? p.danger : p.text
        var x: CGFloat = 14
        if item.subtitle != nil {
            // Rich row: tinted tile · title / subtitle.
            let tint = item.tint ?? p.accent
            let tr = NSRect(x: 12, y: (bounds.height - 32) / 2, width: 32, height: 32)
            let tp = NSBezierPath(roundedRect: tr, xRadius: 9, yRadius: 9)
            tint.withAlphaComponent(0.14).setFill(); tp.fill()
            tint.withAlphaComponent(0.45).setStroke(); tp.lineWidth = 1; tp.stroke()
            if let s = item.symbol, let img = dropdownIcon(s, 14, tint.blended(withFraction: 0.25, of: .white) ?? tint) {
                let sz = img.size
                img.draw(in: NSRect(x: tr.midX - sz.width / 2, y: tr.midY - sz.height / 2, width: sz.width, height: sz.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            x = tr.maxX + 12
            (item.title as NSString).draw(at: NSPoint(x: x, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: .semibold), .foregroundColor: color])
            if let sub = item.subtitle {
                let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
                (sub as NSString).draw(in: NSRect(x: x, y: 28, width: bounds.width - x - 12, height: 16),
                                       withAttributes: [.font: Self.subFont, .foregroundColor: p.textSecondary, .paragraphStyle: para])
            }
            return
        }
        if let s = item.symbol, let img = dropdownIcon(s, 12.5, item.destructive ? p.danger : (item.tint ?? p.textSecondary)) {
            let sz = img.size
            img.draw(in: NSRect(x: 12 + (18 - sz.width) / 2, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x = 12 + 18 + 10
        }
        let f = item.checked ? NSFont.systemFont(ofSize: 13, weight: .semibold) : Self.titleFont
        let th = ceil(f.ascender - f.descender) + 1
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        (item.title as NSString).draw(in: NSRect(x: x, y: (bounds.height - th) / 2, width: bounds.width - x - 34, height: th),
                                      withAttributes: [.font: f, .foregroundColor: item.checked ? p.text : color, .paragraphStyle: para])
        if item.checked, let img = dropdownIcon("checkmark", 11.5, p.accent) {
            let sz = img.size
            img.draw(in: NSRect(x: bounds.width - 14 - sz.width, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard !item.isSeparator else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        guard !item.isSeparator, NSPointInRect(convert(event.locationInWindow, from: nil), bounds) else { return }
        onPick?()
    }
    override func resetCursorRects() { if !item.isSeparator { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// Glass card that hosts the list (or any custom content, like a calendar).
private final class DropdownChrome: NSView {
    private let blur = NSVisualEffectView()
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let p = Pal
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = p.accentBorder.cgColor
        blur.material = p.blurMaterial
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur)
        let wash = NSView(frame: bounds)
        wash.wantsLayer = true
        wash.layer?.backgroundColor = p.surfaceElevated.withAlphaComponent(0.94).cgColor
        wash.autoresizingMask = [.width, .height]
        addSubview(wash)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Opens / closes the one dropdown that can be up at a time.
@MainActor
final class ZeraDropdown {
    static let shared = ZeraDropdown()

    private var window: FloatingPanel?
    private var monitors: [Any] = []
    private weak var anchor: NSView?
    private weak var returnKeyWindow: NSWindow?
    var isOpen: Bool { window != nil }
    /// The anchor that opened the current dropdown (a second click on it just closes it).
    func isShowing(from view: NSView) -> Bool { isOpen && anchor === view }

    /// A list of choices / actions under `anchor`.
    func show(_ items: [DropdownItem], below anchor: NSView, width: CGFloat? = nil) {
        if isShowing(from: anchor) { dismiss(); return }
        let natural = items.map { DropdownRow.naturalWidth($0) }.max() ?? 200
        let w = max(width ?? anchor.bounds.width, min(360, max(200, natural)))
        let content = FlippedView()
        var y: CGFloat = 6
        for it in items {
            let row = DropdownRow(item: it)
            let h = DropdownRow.height(it)
            row.frame = NSRect(x: 0, y: y, width: w, height: h)
            row.onPick = { [weak self] in
                self?.dismiss()
                it.action()
            }
            content.addSubview(row)
            y += h
        }
        y += 6
        let maxH: CGFloat = 340
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: min(y, maxH)))
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = y > maxH
        scroll.autohidesScrollers = true
        content.frame = NSRect(x: 0, y: 0, width: w, height: y)
        scroll.documentView = content
        // Start scrolled to the checked row.
        if let i = items.firstIndex(where: { $0.checked }), y > maxH {
            let rowY = items.prefix(i).reduce(6) { $0 + DropdownRow.height($1) }
            content.scroll(NSPoint(x: 0, y: max(0, rowY - maxH / 2)))
        }
        present(scroll, size: NSSize(width: w, height: min(y, maxH)), below: anchor, keyable: false)
    }

    /// Any view (e.g. a calendar) under `anchor`.
    func show(content: NSView, size: NSSize, below anchor: NSView) {
        if isShowing(from: anchor) { dismiss(); return }
        content.frame = NSRect(origin: .zero, size: size)
        present(content, size: size, below: anchor, keyable: true)
    }

    private func present(_ content: NSView, size: NSSize, below anchor: NSView, keyable: Bool) {
        dismiss()
        guard let host = anchor.window else { return }
        let rectInWindow = anchor.convert(anchor.bounds, to: nil)
        let onScreen = host.convertToScreen(rectInWindow)
        let vf = (host.screen ?? NSScreen.main)?.visibleFrame ?? onScreen
        var origin = NSPoint(x: onScreen.minX, y: onScreen.minY - 6 - size.height)
        if origin.y < vf.minY + 8 { origin.y = onScreen.maxY + 6 }              // no room below: open upwards
        origin.x = max(vf.minX + 8, min(vf.maxX - size.width - 8, origin.x))

        let panel = FloatingPanel.make(size: size, level: .popUpMenu, keyable: keyable)
        panel.appearance = Pal.nsAppearance
        panel.hasShadow = true
        let chrome = DropdownChrome(frame: NSRect(origin: .zero, size: size))
        content.frame = NSRect(origin: .zero, size: size)
        chrome.addSubview(content)
        panel.contentView = chrome
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        host.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if keyable {
            returnKeyWindow = host
            panel.makeKey()
        }
        window = panel
        self.anchor = anchor

        // Click anywhere else (in Zera or another app) or press Esc: close.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] e in
            guard let self = self, let w = self.window else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { self.dismiss(); return nil }
                return e
            }
            if e.window === w { return e }
            // A click on the control that opened it toggles it shut (don't reopen it).
            if let a = self.anchor, e.window === a.window,
               NSPointInRect(a.convert(e.locationInWindow, from: nil), a.bounds) {
                self.dismiss(); return nil
            }
            self.dismiss()
            return e
        }) { monitors.append(m) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }) { monitors.append(g) }
    }

    func dismiss() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let w = window {
            w.parent?.removeChildWindow(w)
            w.orderOut(nil)
            // It may still be handling the click that closed it: let it go after this event.
            DispatchQueue.main.async { _ = w }
        }
        window = nil
        anchor = nil
        if let k = returnKeyWindow { k.makeKey() }
        returnKeyWindow = nil
    }
}

// MARK: - Select field

/// Field-styled choice: "[icon] Every day  ⌄". Opens Zera's dropdown, never a native menu.
final class ZeraSelect: NSView {
    struct Option { var title: String; var symbol: String? = nil }
    var options: [Option] { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true; setAccessibilityValue(selectedTitle) } }
    var onChange: ((Int) -> Void)?
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.5 } }
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(_ titles: [String], symbols: [String?]? = nil) {
        options = titles.enumerated().map { i, t in Option(title: t, symbol: symbols.flatMap { i < $0.count ? $0[i] : nil }) }
        super.init(frame: .zero)
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    var selectedTitle: String { options.indices.contains(selectedIndex) ? options[selectedIndex].title : "" }

    func select(_ i: Int) { selectedIndex = max(0, min(options.count - 1, i)) }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.m, yRadius: Radius.m)
        (hovered && isEnabled ? p.surfaceHover : p.field).setFill(); path.fill()
        (hovered && isEnabled ? p.accentBorder : p.fieldBorder).setStroke(); path.lineWidth = 1; path.stroke()
        var x: CGFloat = 12
        if options.indices.contains(selectedIndex), let s = options[selectedIndex].symbol, let img = dropdownIcon(s, 12, p.textSecondary) {
            let sz = img.size
            img.draw(in: NSRect(x: x + (16 - sz.width) / 2, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 16 + 8
        }
        let f = NSFont.systemFont(ofSize: 13, weight: .medium)
        let th = ceil(f.ascender - f.descender) + 1
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        (selectedTitle as NSString).draw(in: NSRect(x: x, y: (bounds.height - th) / 2, width: bounds.width - x - 32, height: th),
                                         withAttributes: [.font: f, .foregroundColor: p.text, .paragraphStyle: para])
        if let c = dropdownIcon("chevron.down", 10, p.textSecondary) {
            let sz = c.size
            c.draw(in: NSRect(x: bounds.width - 14 - sz.width, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let items: [DropdownItem] = options.enumerated().map { i, o in
            DropdownItem(title: o.title, symbol: o.symbol, checked: i == selectedIndex) { [weak self] in
                guard let self = self else { return }
                self.selectedIndex = i
                self.onChange?(i)
            }
        }
        ZeraDropdown.shared.show(items, below: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}
