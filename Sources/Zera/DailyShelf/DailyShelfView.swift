import AppKit

// MARK: - Daily Shelf: what is inside the card
//
// Header (companion, day, counts, search / standup / keep open / more), the add field, filter
// chips, the sectioned list, the footer and the resize grip. Rows draw themselves with the theme
// tokens; the list is rebuilt when the store changes (a day holds tens of items, not thousands).

extension DailyShelfTone {
    var color: NSColor {
        let p = Pal
        switch self {
        case .danger: return p.danger
        case .warning: return p.warning
        case .success: return p.success
        case .info: return p.info
        case .accent: return p.accent
        case .muted: return p.textSecondary
        }
    }
}

enum DSText {
    static let title = ZFont.ui(ofSize: 13, weight: .medium)
    static let meta = ZFont.ui(ofSize: 12, weight: .regular)
    static let pill = ZFont.ui(ofSize: 11, weight: .medium)
    static let key = ZFont.mono(ofSize: 11, weight: .medium)
    static let diff = ZFont.digits(ofSize: 11, weight: .regular)
    static let count = ZFont.digits(ofSize: 11, weight: .regular)
    static let section = ZFont.ui(ofSize: 13, weight: .medium)
    static let mono = ZFont.mono(ofSize: 12, weight: .regular)

    static func lineHeight(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) + 1 }

    static func attrs(_ f: NSFont, _ c: NSColor, wrap: Bool = false, align: NSTextAlignment = .left) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        p.alignment = align
        return [.font: f, .foregroundColor: c, .paragraphStyle: p]
    }

    static func height(_ s: String, _ f: NSFont, width: CGFloat, lines: Int) -> CGFloat {
        let r = (s as NSString).boundingRect(with: NSSize(width: max(1, width), height: 1000), options: [.usesLineFragmentOrigin],
                                             attributes: attrs(f, .white, wrap: true))
        return min(ceil(r.height), lineHeight(f) * CGFloat(lines))
    }

    static func draw(_ s: String, _ f: NSFont, _ c: NSColor, in r: NSRect, lines: Int = 1, align: NSTextAlignment = .left) {
        (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: attrs(f, c, wrap: lines > 1, align: align))
    }

    static func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }

    /// A soft tinted pill; returns its width.
    @discardableResult
    static func pill(_ s: String, tone: DailyShelfTone, rightEdge: CGFloat, midY: CGFloat) -> CGFloat {
        let w = width(s, pill) + 16, r = NSRect(x: rightEdge - w, y: midY - 10, width: w, height: 20)
        let c = tone.color
        (tone == .muted ? Pal.surfaceStrong : c.withAlphaComponent(0.14)).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        draw(s, pill, c, in: NSRect(x: r.minX + 8, y: r.minY + (20 - lineHeight(pill)) / 2 + 0.5, width: w - 16, height: lineHeight(pill)))
        return w
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color])))
    }

    static func drawSymbol(_ name: String, size: CGFloat, color: NSColor, center: NSPoint, weight: NSFont.Weight = .medium) {
        guard let img = symbol(name, size: size, weight: weight, color: color) else { return }
        let s = img.size
        img.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The site's icon on a rounded tile, or a themed monogram while it loads (or if it has none).
    @MainActor static func favicon(_ host: String?, in r: NSRect, icon: CGFloat) {
        let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.3, yRadius: r.width * 0.3)
        if let h = host, let img = DailyShelfFavicons.shared.image(for: h) {
            Pal.surfaceStrong.setFill(); path.fill()
            img.draw(in: NSRect(x: r.midX - icon / 2, y: r.midY - icon / 2, width: icon, height: icon), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            return
        }
        let name = host ?? "?"
        Pal.surfaceStrong.setFill(); path.fill()
        let parts = name.split(separator: ".")
        let letter = String((parts.count >= 2 ? parts[parts.count - 2] : parts.first ?? "?").prefix(1)).uppercased()
        let f = ZFont.ui(ofSize: (r.height * 0.44).rounded(), weight: .medium)
        let lh = lineHeight(f)
        draw(letter, f, Pal.textSecondary, in: NSRect(x: r.minX, y: r.midY - lh / 2, width: r.width, height: lh), align: .center)
    }
}

// MARK: - Dragging inside the shelf

enum DSDrag {
    /// An item being refiled (its id); it also carries the link so it can be dropped in other apps.
    static let item = NSPasteboard.PasteboardType("io.github.amsynist.zera.dailyshelf.item")
    /// A section ("section:pr") or site category ("category:Dev tools") being reordered.
    static let group = NSPasteboard.PasteboardType("io.github.amsynist.zera.dailyshelf.group")

    static func image(of v: NSView) -> NSImage {
        let img = NSImage(size: v.bounds.size)
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) { v.cacheDisplay(in: v.bounds, to: rep); img.addRepresentation(rep) }
        return img
    }
}

/// Starts a drag once the pointer has moved a few points with the button down.
final class DSDragStarter {
    private var down: NSPoint?
    private(set) var dragged = false
    func mouseDown(_ e: NSEvent) { down = e.locationInWindow; dragged = false }
    /// True when this event began a drag session.
    func mouseDragged(_ e: NSEvent, from view: NSView & NSDraggingSource, payload: NSPasteboardItem?) -> Bool {
        guard !dragged, let d = down, let item = payload, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 4 else { return false }
        dragged = true
        let di = NSDraggingItem(pasteboardWriter: item)
        di.setDraggingFrame(view.bounds, contents: DSDrag.image(of: view))
        view.beginDraggingSession(with: [di], event: e, source: view)
        return true
    }
    /// Whether the press ended as a click (no drag happened).
    func mouseUp() -> Bool { defer { down = nil }; return !dragged }
}

// MARK: - Local item accents

extension DailyShelfAccent {
    private var colors: (NSColor, NSColor) {
        let pair: (UInt32, UInt32)
        switch self {
        case .ocean: pair = (0x7aa2f7, 0x7dcfff)
        case .aurora: pair = (0xbb9af7, 0xf28bc7)
        case .sunset: pair = (0xf7768e, 0xffb86c)
        case .mint: pair = (0x9ece6a, 0x73daca)
        case .gold: pair = (0xe0af68, 0xffd580)
        case .rose: pair = (0xf28bc7, 0xf7768e)
        case .lagoon: pair = (0x24c6b8, 0x3288e6)
        case .sapphire: pair = (0x5c7cfa, 0x9b7efa)
        case .lavender: pair = (0xa7a0f6, 0xe0b9fa)
        case .orchid: pair = (0xc56cf0, 0xf78fb3)
        case .cherry: pair = (0xe65076, 0xb86acb)
        case .coral: pair = (0xff8b7b, 0xf7b38b)
        case .ember: pair = (0xf09655, 0xe65b65)
        case .citrus: pair = (0xd4db6b, 0x77c89a)
        case .emerald: pair = (0x52c49b, 0x4aa8a5)
        case .moonstone: pair = (0x96aecb, 0xc3b3d6)
        }
        func color(_ rgb: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        return (color(pair.0), color(pair.1))
    }

    var swatch: NSImage {
        let (start, end) = colors
        return NSImage(size: NSSize(width: 32, height: 16), flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            NSGradient(starting: start, ending: end)?.draw(in: shape, angle: 12)
            NSColor.white.withAlphaComponent(0.25).setStroke()
            shape.lineWidth = 0.75
            shape.stroke()
            return true
        }
    }

    /// Layered color, a soft upper sheen, and a recessed lower edge create depth without motion.
    func draw(in bounds: NSRect, selected: Bool, hovered: Bool = false) {
        let (start, end) = colors
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        guard rect.width > 4, rect.height > 4 else { return }
        let shape = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        let lift: CGFloat = selected ? 0.09 : hovered ? 0.045 : 0
        if let wash = NSGradient(colorsAndLocations:
            (start.withAlphaComponent(0.26 + lift), 0),
            (end.withAlphaComponent(0.15 + lift), 0.55),
            (end.withAlphaComponent(0.065 + lift), 1)) {
            wash.draw(in: shape, angle: 25)
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        shape.addClip()
        // Shade the surface vertically, with the brighter stop along the upper edge.
        NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(selected || hovered ? 0.095 : 0.065), 0),
            (NSColor.white.withAlphaComponent(0.012), 0.3),
            (NSColor.clear, 0.55),
            (NSColor.black.withAlphaComponent(0.12), 1))?.draw(in: rect, angle: 90)
        let sheen = NSBezierPath(roundedRect: NSRect(x: rect.minX + 10, y: rect.minY + 1,
                                                    width: max(0, rect.width - 20), height: 1), xRadius: 0.5, yRadius: 0.5)
        NSGradient(starting: start.withAlphaComponent(0.4), ending: NSColor.white.withAlphaComponent(0.05))?.draw(in: sheen, angle: 0)
        ctx.restoreGState()
        // A gradient hairline, stronger on keyboard selection, stays separate from the fill.
        ctx.saveGState()
        let line: CGFloat = selected ? 2 : hovered ? 1.25 : 0.85
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: line, dy: line),
                           cornerWidth: 10 - line, cornerHeight: 10 - line, transform: nil))
        ctx.clip(using: .evenOdd)
        let opacity: CGFloat = selected ? 0.95 : hovered ? 0.75 : 0.48
        NSGradient(starting: start.withAlphaComponent(opacity),
                   ending: end.withAlphaComponent(opacity * 0.8))?.draw(in: rect, angle: 15)
        ctx.restoreGState()
    }
}

// MARK: - A row

final class DailyShelfRowView: NSView, NSDraggingSource {
    enum Leading { case status(String, DailyShelfTone), favicon(String?), key(String), time(String), symbol(String) }
    enum Action { case open, button, copy, pin, remove }

    let itemID: UUID
    var accent: DailyShelfAccent? { didSet { needsDisplay = true } }
    var leading: Leading = .favicon(nil)
    /// Signal: a PR row shows its number in an index tile tinted with its status.
    var number: Int?
    var meta: String?
    var metaAbove = false
    var title = ""
    var titleLines = 1
    var mono = false
    var pill: (String, DailyShelfTone)?
    var diff: (Int, Int)?
    var buttonTitle: String?
    var pinned = false
    var carried = false
    var showsActions = true
    var onAction: ((Action) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    /// What a drag of this row carries (nil: not draggable).
    var dragPayload: (() -> NSPasteboardItem?)?
    private let starter = DSDragStarter()

    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true; layoutActions() } } }
    private var pressed = false { didSet { needsDisplay = true } }
    /// The keyboard selection: a quiet surface step and an accent hairline.
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    private lazy var actionButtons: [IconButton] = [
        IconButton(symbol: "doc.on.doc", label: "Copy link", target: self, action: #selector(copyTapped)),
        IconButton(symbol: pinned ? "pin.slash" : "pin", label: pinned ? "Unpin" : "Keep every day", target: self, action: #selector(pinTapped)),
        IconButton(symbol: "trash", label: "Remove from today", target: self, action: #selector(removeTapped)),
    ]
    private var trailingButton: CardButton?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(id: UUID) {
        itemID = id
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let pad: CGFloat = 12, lead: CGFloat = 24, gap: CGFloat = 12

    func fittedHeight(width: CGFloat) -> CGFloat {
        setAccessibilityLabel([title, meta, pill?.0].compactMap { $0 }.joined(separator: ", "))
        let textW = width - Self.pad * 2 - Self.lead - Self.gap - trailingWidth
        let font = mono ? DSText.mono : DSText.title
        var h = Self.pad + DSText.height(title, font, width: metaAbove ? width - Self.pad * 2 - Self.lead - Self.gap : textW, lines: titleLines)
        if meta != nil { h += DSText.lineHeight(DSText.meta) + 2 }
        if metaAbove { h = max(h, Self.pad + 20 + 4 + DSText.height(title, font, width: width - Self.pad * 2 - Self.lead - Self.gap, lines: titleLines)) }
        if diff != nil { h += DSText.lineHeight(DSText.diff) + 2 }
        return max(48, ceil((h + Self.pad) / 4) * 4)
    }

    private var trailingWidth: CGFloat {
        if let b = buttonTitle { return DSText.width(b, Typo.button) + 24 + 8 }
        if !metaAbove, let p = pill { return DSText.width(p.0, DSText.pill) + 16 + 8 }
        return 0
    }

    override func layout() {
        super.layout()
        if let b = buttonTitle {
            if trailingButton == nil {
                let btn = CardButton(b, style: .secondary, target: self, action: #selector(buttonTapped))
                addSubview(btn); trailingButton = btn
            }
            let w = DSText.width(b, Typo.button) + 24
            trailingButton?.frame = NSRect(x: bounds.width - Self.pad - w, y: (bounds.height - 28) / 2, width: w, height: 28)
        }
        layoutActions()
    }

    private func layoutActions() {
        let show = hovered && showsActions && buttonTitle == nil
        var x = bounds.width - 8
        for b in actionButtons.reversed() {
            if b.superview == nil { addSubview(b) }
            b.frame = NSRect(x: x - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
            x -= 24
            b.isHidden = !show
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 10, yRadius: 10)
        (pressed ? p.surfacePressed : (hovered || selected) ? p.surfaceHover : p.surfaceRow).setFill(); box.fill()
        if let accent { accent.draw(in: bounds, selected: selected, hovered: hovered) }
        else {
            (selected ? p.accent.withAlphaComponent(0.7) : p.border).setStroke()
            box.lineWidth = selected ? 1.5 : 1; box.stroke()
        }

        let multi = metaAbove || titleLines > 1
        let leadRect = NSRect(x: Self.pad, y: multi ? Self.pad : (bounds.height - Self.lead) / 2, width: Self.lead, height: Self.lead)
        switch leading {
        case .status(let symbol, let tone):
            if let n = number, n > 0 {
                SignalDraw.indexTile("\(n)", in: leadRect, color: tone.color, radius: 6)
            } else {
                p.surfaceStrong.setFill(); NSBezierPath(roundedRect: leadRect, xRadius: 6, yRadius: 6).fill()
                DSText.drawSymbol(symbol, size: 12, color: p.textSecondary, center: NSPoint(x: leadRect.midX, y: leadRect.midY))
            }
        case .favicon(let host):
            DSText.favicon(host, in: leadRect, icon: 16)
        case .key, .time:
            break
        case .symbol(let name):
            p.surfaceStrong.setFill(); NSBezierPath(roundedRect: leadRect, xRadius: 6, yRadius: 6).fill()
            DSText.drawSymbol(name, size: 12, color: p.textSecondary, center: NSPoint(x: leadRect.midX, y: leadRect.midY))
        }
        var x = leadRect.maxX + Self.gap
        // Key and time chips take the leading slot but are wider.
        if case .key(let k) = leading { x = chip(k, color: p.info, mono: true, at: leadRect) }
        if case .time(let t) = leading { x = chip(t, color: p.textSecondary, mono: true, at: leadRect) }

        let right = bounds.width - Self.pad - (hovered && showsActions && buttonTitle == nil ? 76 : trailingWidth)
        let font = mono ? DSText.mono : DSText.title
        var y = Self.pad
        let metaH = DSText.lineHeight(DSText.meta)
        if metaAbove {
            let pillW = pill.map { _ in hovered && showsActions ? 0 : 1 } ?? 0
            var metaRight = bounds.width - Self.pad
            if pillW > 0, let pl = pill { metaRight -= DSText.pill(pl.0, tone: pl.1, rightEdge: bounds.width - Self.pad, midY: y + 10) + 8 }
            else if hovered && showsActions { metaRight -= 80 }
            drawMeta(in: NSRect(x: x, y: y + (20 - metaH) / 2, width: metaRight - x, height: metaH))
            y += 24
            let th = DSText.height(title, font, width: bounds.width - Self.pad - x, lines: titleLines)
            DSText.draw(title, font, p.text, in: NSRect(x: x, y: y, width: bounds.width - Self.pad - x, height: th), lines: titleLines)
            y += th + 2
        } else {
            let th = DSText.height(title, font, width: right - x, lines: titleLines)
            let total = th + (meta != nil ? metaH + 2 : 0)
            y = multi ? Self.pad : (bounds.height - total) / 2
            DSText.draw(title, font, mono ? (p.codeText) : p.text, in: NSRect(x: x, y: y, width: right - x, height: th), lines: titleLines)
            y += th + 2
            if meta != nil { drawMeta(in: NSRect(x: x, y: y, width: right - x, height: metaH)); y += metaH }
            if buttonTitle == nil, !(hovered && showsActions), let pl = pill {
                DSText.pill(pl.0, tone: pl.1, rightEdge: bounds.width - Self.pad, midY: bounds.height / 2)
            }
        }
        if let (a, d) = diff {
            DSText.draw("+\(a)  \u{2212}\(d)", DSText.diff, p.textTertiary, in: NSRect(x: x, y: y, width: bounds.width - x - Self.pad, height: DSText.lineHeight(DSText.diff)))
        }
    }

    private func chip(_ s: String, color: NSColor, mono: Bool, at lead: NSRect) -> CGFloat {
        let f = mono ? DSText.key : DSText.pill
        let w = DSText.width(s, f) + 12, r = NSRect(x: lead.minX, y: lead.midY - 10, width: w, height: 20)
        Pal.surfaceStrong.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        DSText.draw(s, f, color, in: NSRect(x: r.minX + 6, y: r.minY + (20 - DSText.lineHeight(f)) / 2 + 0.5, width: w - 12, height: DSText.lineHeight(f)))
        return r.maxX + Self.gap
    }

    private func drawMeta(in r: NSRect) {
        guard let meta = meta else { return }
        let p = Pal
        var x = r.minX
        for (on, name) in [(pinned, "pin.fill"), (carried, "clock.arrow.circlepath")] where on {
            DSText.drawSymbol(name, size: 10, color: p.textTertiary, center: NSPoint(x: x + 6, y: r.midY))
            x += 16
        }
        DSText.draw(meta, DSText.meta, p.textTertiary, in: NSRect(x: x, y: r.minY, width: max(0, r.maxX - x), height: r.height))
    }

    // Interaction
    override func updateTrackingAreas() { super.updateTrackingAreas(); resetHoverTracking() }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true; starter.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) {
        if starter.mouseDragged(event, from: self, payload: dragPayload?()) { pressed = false; hovered = false }
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if starter.mouseUp(), inside { onAction?(.open) }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : .copy
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let m = contextMenu?() else { return }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }
    override func accessibilityPerformPress() -> Bool { onAction?(.open); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    @objc private func copyTapped() { onAction?(.copy) }
    @objc private func pinTapped() { onAction?(.pin) }
    @objc private func removeTapped() { onAction?(.remove) }
    @objc private func buttonTapped() { onAction?(.button) }

    /// A soft accent ring when the item lands or changes.
    func flash() {
        guard let layer = layer else { return }
        let ring = CAShapeLayer()
        ring.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10, cornerHeight: 10, transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = Pal.accent.withAlphaComponent(0.6).cgColor
        ring.lineWidth = 1
        ring.opacity = 0
        layer.addSublayer(ring)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 1, 0]; a.keyTimes = [0, 0.2, 0.55, 1]
        a.duration = 0.9
        a.isRemovedOnCompletion = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(a, forKey: "flash")
        CATransaction.commit()
    }
}

// MARK: - A tile (places: dashboards, consoles, design files)

final class DailyShelfTileView: NSView, NSDraggingSource {
    let itemID: UUID
    var accent: DailyShelfAccent? { didSet { needsDisplay = true } }
    var host: String?
    var name = ""
    var opens = 0
    var onOpen: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var dragPayload: (() -> NSPasteboardItem?)?
    var pinned = false
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var onPin: (() -> Void)?
    private let starter = DSDragStarter()
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(id: UUID) { itemID = id; super.init(frame: .zero); wantsLayer = true; setAccessibilityElement(true); setAccessibilityRole(.button) }
    private var pinRect: NSRect { NSRect(x: 4, y: 4, width: 20, height: 20) }
    override func mouseDown(with event: NSEvent) { starter.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { if starter.mouseDragged(event, from: self, payload: dragPayload?()) { hovered = false } }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : .copy
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        setAccessibilityLabel(name)
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 10, yRadius: 10)
        ((hovered || selected) ? p.surfaceHover : p.surfaceRow).setFill(); box.fill()
        if let accent { accent.draw(in: bounds, selected: selected, hovered: hovered) }
        else {
            (selected ? p.accent.withAlphaComponent(0.7) : p.border).setStroke()
            box.lineWidth = selected ? 1.5 : 1; box.stroke()
        }
        DSText.favicon(host, in: NSRect(x: bounds.midX - 14, y: 8, width: 28, height: 28), icon: 18)
        DSText.draw(name, ZFont.ui(ofSize: 11, weight: .regular), p.textSecondary,
                    in: NSRect(x: 4, y: 42, width: bounds.width - 8, height: 16), align: .center)
        if opens > 0 {
            DSText.draw("\(opens)\u{00D7}", DSText.count, p.textTertiary,
                        in: NSRect(x: bounds.width - 32, y: 4, width: 28, height: 14), align: .right)
        }
        if hovered || pinned {
            let r = pinRect
            if hovered { p.surfaceStrong.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
            DSText.drawSymbol(pinned ? "pin.fill" : "pin", size: 10, color: pinned ? p.textSecondary : p.textTertiary, center: NSPoint(x: r.midX, y: r.midY))
        }
    }
    override func updateTrackingAreas() { super.updateTrackingAreas(); resetHoverTracking() }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        guard starter.mouseUp() else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if onPin != nil, pinRect.insetBy(dx: -2, dy: -2).contains(pt) { onPin?(); return }
        if bounds.contains(pt) { onOpen?() }
    }
    override func rightMouseDown(with event: NSEvent) { if let m = contextMenu?() { NSMenu.popUpContextMenu(m, with: event, for: self) } }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Section header and group label

final class DailyShelfHeaderView: NSView, NSDraggingSource {
    var title = "", symbol = "", count = 0, collapsed = false, action: String?, claude = false, dotTone: DailyShelfTone?
    var onToggle: (() -> Void)?
    var onAction: (() -> Void)?
    var isGroup = false
    /// "section:pr" or "category:Dev tools" when it can be dragged to reorder.
    var groupKey: String?
    /// Kept every day with all its items; the pin shows on hover, and stays when on.
    var pinned = false
    var onPin: (() -> Void)?
    /// A site category label that folds like a section.
    var foldable = false
    /// The keyboard cursor is on this header.
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private let starter = DSDragStarter()
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() { super.updateTrackingAreas(); resetHoverTracking() }
    private func drawSelection() {
        guard selected else { return }
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 8, yRadius: 8)
        Pal.surfaceHover.setFill(); r.fill()
        Pal.accent.withAlphaComponent(0.7).setStroke(); r.lineWidth = 1.5; r.stroke()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    private var pinRect: NSRect {
        let right = action.map { actionRect($0).minX - 8 } ?? bounds.width - 4
        return NSRect(x: right - 20, y: bounds.midY - 10, width: 20, height: 20)
    }
    private func drawPin() {
        guard onPin != nil, hovered || pinned else { return }
        let r = pinRect
        if hovered { Pal.surfaceHover.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
        DSText.drawSymbol(pinned ? "pin.fill" : "pin", size: 10, color: pinned ? Pal.textSecondary : Pal.textTertiary,
                          center: NSPoint(x: r.midX, y: r.midY))
    }
    override func mouseDown(with event: NSEvent) { starter.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) {
        guard let k = groupKey else { return }
        let item = NSPasteboardItem()
        item.setString(k, forType: DSDrag.group)
        _ = starter.mouseDragged(event, from: self, payload: item)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        drawSelection()
        if isGroup {
            var x: CGFloat = 4
            if foldable {
                DSText.drawSymbol(collapsed ? "chevron.right" : "chevron.down", size: 8, color: p.textTertiary, center: NSPoint(x: 9, y: bounds.midY), weight: .medium)
                x = 20
            }
            if let t = dotTone {
                (t == .muted ? p.textTertiary : t.color).setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: bounds.midY - 3, width: 6, height: 6)).fill()
                x = 16
            }
            let s = NSMutableAttributedString(string: title, attributes: [.font: DSText.meta, .foregroundColor: p.textSecondary])
            if claude { s.append(NSAttributedString(string: "  by Claude", attributes: [.font: DSText.meta, .foregroundColor: p.textTertiary])) }
            if foldable { s.append(NSAttributedString(string: "  \(count)", attributes: [.font: DSText.count, .foregroundColor: p.textTertiary])) }
            s.draw(with: NSRect(x: x, y: bounds.midY - 8, width: bounds.width - x - 28, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            drawPin()
            return
        }
        DSText.drawSymbol(collapsed ? "chevron.right" : "chevron.down", size: 9, color: p.textTertiary, center: NSPoint(x: 8, y: bounds.midY), weight: .medium)
        DSText.drawSymbol(symbol, size: 12, color: p.textSecondary, center: NSPoint(x: 28, y: bounds.midY))
        let w = DSText.width(title, DSText.section)
        DSText.draw(title, DSText.section, p.text, in: NSRect(x: 44, y: bounds.midY - 9, width: w + 2, height: 18))
        DSText.draw("\(count)", DSText.count, p.textTertiary, in: NSRect(x: 44 + w + 8, y: bounds.midY - 7, width: 40, height: 14))
        if let a = action {
            DSText.draw(a, ZFont.ui(ofSize: 12, weight: .medium), p.accent, in: actionRect(a), align: .right)
        }
        drawPin()
    }
    private func actionRect(_ a: String) -> NSRect {
        let w = DSText.width(a, ZFont.ui(ofSize: 12, weight: .medium)) + 4
        return NSRect(x: bounds.width - w - 4, y: bounds.midY - 8, width: w, height: 16)
    }
    override func mouseUp(with event: NSEvent) {
        guard starter.mouseUp() else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if onPin != nil, pinRect.insetBy(dx: -4, dy: -4).contains(pt) { onPin?(); return }
        if isGroup { if foldable { onToggle?() }; return }
        if let a = action, actionRect(a).insetBy(dx: -6, dy: -6).contains(pt) { onAction?(); return }
        onToggle?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isGroup && !foldable ? (groupKey == nil ? .arrow : .openHand) : .pointingHand) }
}

// MARK: - Filter chips

final class DailyShelfChipsView: NSView {
    var chips: [(id: String, title: String, count: Int)] = [] { didSet { needsDisplay = true } }
    var selected = "all" { didSet { needsDisplay = true } }
    var onSelect: ((String) -> Void)?
    private var scrollX: CGFloat = 0
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rects() -> [NSRect] {
        var x: CGFloat = 2 - scrollX
        return chips.map { c in
            let w = DSText.width(c.title, Typo.nav) + DSText.width(" \(c.count)", Typo.nav) + 16
            defer { x += w + 2 }
            return NSRect(x: x, y: 2, width: w, height: bounds.height - 4)
        }
    }
    private var contentWidth: CGFloat { (rects().last?.maxX ?? 0) + scrollX + 3 }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        p.surface.setFill(); bg.fill()
        NSGraphicsContext.saveGraphicsState()
        bg.addClip()
        for (c, r) in zip(chips, rects()) {
            let on = c.id == selected
            if on { p.surfaceStrong.setFill(); NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill() }
            let s = NSMutableAttributedString(string: c.title, attributes: [.font: Typo.nav, .foregroundColor: on ? p.text : p.textSecondary])
            s.append(NSAttributedString(string: " \(c.count)", attributes: [.font: Typo.nav, .foregroundColor: p.textTertiary]))
            let sz = s.size()
            s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        if contentWidth - scrollX > bounds.width + 1 {
            let fade = NSGradient(starting: p.surface.withAlphaComponent(0), ending: p.surface)
            fade?.draw(in: NSRect(x: bounds.width - 28, y: 1, width: 27, height: bounds.height - 2), angle: 0)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        let maxX = max(0, contentWidth - bounds.width)
        scrollX = min(maxX, max(0, scrollX - (abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY)))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let i = rects().firstIndex(where: { $0.contains(pt) }) { selected = chips[i].id; onSelect?(chips[i].id) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Notes

final class DailyShelfNoteView: NSView {
    let itemID: UUID
    var accent: DailyShelfAccent? { didSet { needsDisplay = true } }
    var text = ""
    var mono = false
    var onCopy: (() -> Void)?
    var onPin: (() -> Void)?
    var onRemove: (() -> Void)?
    var pinned = false
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var contextMenu: (() -> NSMenu?)?
    private var hovered = false { didSet { needsDisplay = true; buttons.forEach { $0.isHidden = !hovered } } }
    private lazy var buttons: [IconButton] = [
        IconButton(symbol: pinned ? "pin.slash" : "pin", label: pinned ? "Unpin" : "Keep every day", target: self, action: #selector(pinTapped)),
        IconButton(symbol: "trash", label: "Remove from today", target: self, action: #selector(removeTapped)),
    ]
    override var isFlipped: Bool { true }
    init(id: UUID) { itemID = id; super.init(frame: .zero); wantsLayer = true }
    override func layout() {
        super.layout()
        var x = bounds.width - 8
        for b in buttons.reversed() {
            if b.superview == nil { addSubview(b); b.isHidden = true }
            b.frame = NSRect(x: x - 24, y: 6, width: 24, height: 24); x -= 24
        }
    }
    @objc private func pinTapped() { onPin?() }
    @objc private func removeTapped() { onRemove?() }
    required init?(coder: NSCoder) { fatalError() }
    private var font: NSFont { mono ? DSText.mono : ZFont.ui(ofSize: 12.5) }
    func fittedHeight(width: CGFloat) -> CGFloat { ceil((DSText.height(text, font, width: width - 24, lines: 4) + 24) / 4) * 4 }
    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 10, yRadius: 10)
        ((hovered || selected) ? p.surfaceHover : p.surfaceRow).setFill(); box.fill()
        if let accent { accent.draw(in: bounds, selected: selected, hovered: hovered) }
        else {
            (selected ? p.accent.withAlphaComponent(0.7) : p.border).setStroke()
            box.lineWidth = selected ? 1.5 : 1; box.stroke()
        }
        let right: CGFloat = hovered ? 60 : (pinned ? 20 : 0)
        DSText.draw(text, font, mono ? p.textSecondary : p.text, in: NSRect(x: 12, y: 12, width: bounds.width - 24 - right, height: bounds.height - 24), lines: 4)
        if pinned && !hovered { DSText.drawSymbol("pin.fill", size: 10, color: p.textTertiary, center: NSPoint(x: bounds.width - 18, y: 18)) }
    }
    override func updateTrackingAreas() { super.updateTrackingAreas(); resetHoverTracking() }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onCopy?() } }
    override func rightMouseDown(with event: NSEvent) { if let m = contextMenu?() { NSMenu.popUpContextMenu(m, with: event, for: self) } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Drop catcher: the themed liquid rises, then swallows the link

final class DailyShelfDropView: NSView {
    private let frameLayer = CAShapeLayer()
    private let liquid = CALayer()
    private let bulk = CAGradientLayer()
    private let wave = CAShapeLayer()
    private let label = NSTextField(labelWithString: "Drop to add to today")
    private let sub = NSTextField(labelWithString: "Zera files it and checks its status")
    override var isFlipped: Bool { true }
    var radius: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(frameLayer)
        layer?.addSublayer(liquid)
        liquid.masksToBounds = true
        liquid.addSublayer(bulk)
        liquid.addSublayer(wave)
        for (f, font) in [(label, ZFont.ui(ofSize: 13, weight: .medium)), (sub, DSText.meta)] {
            f.font = font; f.alignment = .center; addSubview(f)
        }
        alphaValue = 0
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let p = Pal
        let inner = bounds.insetBy(dx: 8, dy: 8)
        frameLayer.frame = bounds
        frameLayer.path = CGPath(roundedRect: inner, cornerWidth: radius, cornerHeight: radius, transform: nil)
        frameLayer.fillColor = p.cardBottom.withAlphaComponent(0.78).cgColor
        frameLayer.strokeColor = p.accent.withAlphaComponent(0.6).cgColor
        frameLayer.lineDashPattern = [6, 5]
        frameLayer.lineWidth = 1.5
        label.textColor = p.text; sub.textColor = p.textSecondary
        label.frame = NSRect(x: 0, y: bounds.midY - 22, width: bounds.width, height: 20)
        sub.frame = NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 16)
        setLevel(0.28, animated: false)
    }

    private func setLevel(_ fraction: CGFloat, animated: Bool) {
        let p = Pal
        let inner = bounds.insetBy(dx: 9, dy: 9)
        let h = inner.height * fraction
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.45)
        liquid.frame = NSRect(x: inner.minX, y: inner.maxY - h, width: inner.width, height: h)
        liquid.cornerRadius = radius - 1
        liquid.maskedCorners = fraction > 0.95 ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        bulk.frame = NSRect(x: 0, y: 8, width: inner.width, height: max(0, h - 8))
        bulk.colors = [p.accent.withAlphaComponent(0.32).cgColor, p.accentDeep.withAlphaComponent(0.5).cgColor]
        let w = inner.width * 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 10))
        var x: CGFloat = 0
        while x < w { path.addQuadCurve(to: CGPoint(x: x + 25, y: 10), control: CGPoint(x: x + 12.5, y: 2)); path.addQuadCurve(to: CGPoint(x: x + 50, y: 10), control: CGPoint(x: x + 37.5, y: 18)); x += 50 }
        path.addLine(to: CGPoint(x: w, y: 12)); path.addLine(to: CGPoint(x: 0, y: 12)); path.closeSubpath()
        wave.path = path
        wave.frame = NSRect(x: 0, y: 0, width: w, height: 12)
        wave.fillColor = p.accent.withAlphaComponent(0.32).cgColor
        CATransaction.commit()
    }

    func show() {
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        setLevel(0.28, animated: false)
        if !Motion.reduced, wave.animation(forKey: "drift") == nil {
            let a = CABasicAnimation(keyPath: "position.x")
            a.byValue = -(bounds.width - 18)
            a.duration = 3.2
            a.repeatCount = .infinity
            wave.add(a, forKey: "drift")
        }
        NSAnimationContext.runAnimationGroup { $0.duration = Motion.duration(0.16); animator().alphaValue = 1 }
    }

    func hide(swallow: Bool) {
        guard !isHidden else { return }
        if swallow && !Motion.reduced { setLevel(1, animated: true) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(swallow ? 0.42 : 0.16)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
            self?.wave.removeAnimation(forKey: "drift")
        })
    }
}

// MARK: - Sheet: standup and yesterday

final class DailyShelfSheetView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private lazy var close = IconButton(symbol: "xmark", label: "Close", target: self, action: #selector(closeTapped))
    let scroll = NSScrollView()
    let doc = FlippedView()
    private var buttons: [NSView] = []
    var onClose: (() -> Void)?
    var radius: CGFloat = 16
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        titleLabel.font = ZFont.ui(ofSize: 14, weight: .medium)
        addSubview(titleLabel); addSubview(close)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, buttons: [NSView]) {
        titleLabel.stringValue = title
        self.buttons.forEach { $0.removeFromSuperview() }
        self.buttons = buttons
        buttons.forEach(addSubview)
        doc.subviews.forEach { $0.removeFromSuperview() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let p = Pal
        layer?.backgroundColor = p.cardBottom.cgColor
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderColor = p.edge.cgColor
        layer?.borderWidth = 1
        titleLabel.textColor = p.text
        titleLabel.frame = NSRect(x: 16, y: 16, width: bounds.width - 64, height: 20)
        close.frame = NSRect(x: bounds.width - 40, y: 12, width: 28, height: 28)
        let footer: CGFloat = buttons.isEmpty ? 0 : 52
        scroll.frame = NSRect(x: 0, y: 48, width: bounds.width, height: bounds.height - 48 - footer)
        var x: CGFloat = 16
        for b in buttons {
            let w = (b as? CardButton)?.fittedWidth ?? 90
            b.frame = NSRect(x: x, y: bounds.height - 44, width: w, height: 32)
            x += w + 8
        }
    }

    @objc private func closeTapped() { onClose?() }
}

// MARK: - Key hints

/// Small keycaps with what they do, for the footer while the shelf has the keyboard.
final class DailyShelfHintsView: NSView {
    var hints: [(key: String, label: String)] = [] { didSet { needsDisplay = true; setAccessibilityLabel(hints.map { "\($0.key) \($0.label)" }.joined(separator: ", ")) } }
    override var isFlipped: Bool { true }
    private static let keyFont = ZFont.mono(ofSize: 11, weight: .medium)
    private static let labelFont = ZFont.ui(ofSize: 11)

    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.staticText) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        var x: CGFloat = 0
        for h in hints {
            let kw = max(20, DSText.width(h.key, Self.keyFont) + 10), lw = DSText.width(h.label, Self.labelFont)
            guard x + kw + 4 + lw <= bounds.width else { break }
            let r = NSRect(x: x, y: (bounds.height - 18) / 2, width: kw, height: 18)
            let cap = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            p.surfaceStrong.setFill(); cap.fill()
            p.border.setStroke(); cap.stroke()
            DSText.draw(h.key, Self.keyFont, p.textSecondary, in: NSRect(x: r.minX, y: r.minY + 2, width: kw, height: 14), align: .center)
            DSText.draw(h.label, Self.labelFont, p.textTertiary, in: NSRect(x: r.maxX + 4, y: r.minY + 2, width: lw + 2, height: 14))
            x = r.maxX + 4 + lw + 12
        }
    }
}
