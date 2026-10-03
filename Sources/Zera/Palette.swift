import AppKit

// MARK: - Design tokens
//
// Everything the cards draw with comes from here: spacing, radii, type, colours. Zera herself,
// the pill and the bubble have their own fixed look and do not follow the light/dark palette.

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
}

enum Radius {
    static let s: CGFloat = 6      // chips, badges
    static let m: CGFloat = 10     // buttons, fields, tabs
    static let l: CGFloat = 14     // rows, tiles
    static let card: CGFloat = 18  // the card itself
}

enum Metrics {
    static let row: CGFloat = 44        // list rows
    static let control: CGFloat = 28    // fields, popups, inline buttons
    static let button: CGFloat = 32     // primary actions at the bottom of a card
    static let icon: CGFloat = 30       // icon tile in a row
    static let cardPad: CGFloat = Space.l
}

enum Typo {
    static let title = NSFont.systemFont(ofSize: 15, weight: .bold)
    static let section = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 12.5, weight: .regular)
    static let bodyMedium = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let bodyStrong = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let secondary = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let button = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let badge = NSFont.systemFont(ofSize: 10.5, weight: .bold)
    static let nav = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
}

/// Light / dark / follow-the-system, chosen in Settings → Appearance.
enum Appearance: Int, CaseIterable {
    case system, light, dark
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Semantic colours. Light is a soft lavender; dark is deep indigo. Surfaces are opaque so
/// stacking never washes out.
struct Palette {
    let isDark: Bool

    // Card chrome
    var cardTop: NSColor { isDark ? rgb(0.145, 0.145, 0.255, 0.90) : rgb(0.955, 0.950, 0.990, 0.97) }
    var cardBottom: NSColor { isDark ? rgb(0.105, 0.105, 0.200, 0.94) : rgb(0.925, 0.915, 0.980, 0.98) }
    var border: NSColor { isDark ? rgb(1, 1, 1, 0.12) : rgb(0.30, 0.25, 0.55, 0.12) }
    var blurMaterial: NSVisualEffectView.Material { isDark ? .hudWindow : .popover }
    var nsAppearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    // Text
    var text: NSColor { isDark ? rgb(0.965, 0.955, 1.0) : rgb(0.16, 0.15, 0.30) }
    func text(_ alpha: CGFloat) -> NSColor { text.withAlphaComponent(alpha) }
    var textSecondary: NSColor { text(0.62) }
    var textTertiary: NSColor { text(0.42) }

    // Surfaces
    var surface: NSColor { isDark ? rgb(0.19, 0.19, 0.32) : rgb(1, 1, 1, 0.80) }
    var surfaceHover: NSColor { isDark ? rgb(0.23, 0.23, 0.37) : rgb(0.93, 0.92, 0.99) }
    var surfaceStrong: NSColor { isDark ? rgb(0.25, 0.25, 0.40) : rgb(0.89, 0.88, 0.97) }
    var surfacePressed: NSColor { isDark ? rgb(0.16, 0.16, 0.28) : rgb(0.86, 0.85, 0.95) }
    var field: NSColor { isDark ? rgb(0.13, 0.13, 0.24) : rgb(1, 1, 1) }
    var fieldBorder: NSColor { isDark ? rgb(1, 1, 1, 0.10) : rgb(0.30, 0.25, 0.55, 0.12) }
    var divider: NSColor { isDark ? rgb(1, 1, 1, 0.08) : rgb(0.30, 0.25, 0.55, 0.10) }
    var codeBox: NSColor { isDark ? rgb(0.08, 0.08, 0.16) : rgb(0.16, 0.15, 0.30) }
    var codeText: NSColor { rgb(0.85, 0.95, 0.85) }

    // Accent (Zera violet) and the states
    var accent: NSColor { isDark ? rgb(0.561, 0.482, 1.0) : rgb(0.49, 0.42, 0.96) }
    var accentHover: NSColor { isDark ? rgb(0.62, 0.55, 1.0) : rgb(0.55, 0.48, 0.98) }
    var accentPressed: NSColor { isDark ? rgb(0.48, 0.41, 0.90) : rgb(0.42, 0.36, 0.88) }
    var accentSoft: NSColor { isDark ? rgb(0.36, 0.32, 0.62) : rgb(0.86, 0.84, 1.0) }
    /// Deeper end of the violet gradient on primary buttons and the selected segment.
    var accentDeep: NSColor { isDark ? rgb(0.43, 0.33, 0.96) : rgb(0.40, 0.31, 0.90) }
    /// Low-opacity violet edge for selected / highlighted surfaces.
    var accentBorder: NSColor { accent.withAlphaComponent(isDark ? 0.45 : 0.40) }
    /// List rows sitting on the card: a touch darker than `surface`, so the card reads as depth.
    var surfaceRow: NSColor { isDark ? rgb(0.15, 0.15, 0.27, 0.92) : rgb(1, 1, 1, 0.72) }
    /// Raised panels (insight card, speech bubble): slightly brighter indigo.
    var surfaceElevated: NSColor { isDark ? rgb(0.20, 0.19, 0.35) : rgb(1, 1, 1, 0.95) }
    var onAccent: NSColor { .white }
    var success: NSColor { rgb(0.30, 0.78, 0.50) }
    var warning: NSColor { rgb(1.00, 0.72, 0.30) }
    var danger: NSColor { rgb(1.00, 0.42, 0.46) }
    var dangerPressed: NSColor { rgb(0.88, 0.34, 0.38) }
    var info: NSColor { rgb(0.35, 0.70, 1.00) }
    var muted: NSColor { isDark ? rgb(0.45, 0.45, 0.58) : rgb(0.60, 0.58, 0.72) }

    // Fixed identity colours for icon tiles (same in both modes so they stay recognisable)
    var tileGitHub: NSColor { rgb(0.20, 0.20, 0.27) }
    var tileClaude: NSColor { rgb(0.85, 0.45, 0.35) }
    var tileNote: NSColor { rgb(1.00, 0.72, 0.30) }
    var tileFile: NSColor { rgb(0.95, 0.38, 0.38) }
    var tileLink: NSColor { rgb(0.35, 0.70, 1.00) }
    var tileCalendar: NSColor { rgb(1.00, 0.45, 0.50) }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // MARK: Current palette

    nonisolated static let changed = Notification.Name("ZeraPaletteChanged")
    private static let key = "zera.appearance"

    static var appearance: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            // Deferred so the control that changed it finishes its own event first.
            DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
        }
    }

    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static var current: Palette {
        switch appearance {
        case .light: return Palette(isDark: false)
        case .dark: return Palette(isDark: true)
        case .system: return Palette(isDark: systemIsDark)
        }
    }

    /// Call once at launch so "System" follows the macOS switch live.
    static func observeSystem() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            if appearance == .system { NotificationCenter.default.post(name: changed, object: nil) }
        }
    }
}

var Pal: Palette { Palette.current }

/// Honour the system "Reduce motion" switch: no sway, no cross-fades, instant panels.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func duration(_ d: TimeInterval) -> TimeInterval { reduced ? 0 : d }
}

// MARK: - Controls

/// The one button. Four styles, hover / pressed / disabled, title always fits (`fittedWidth`).
final class CardButton: NSButton {
    enum Style { case primary, secondary, tertiary, destructive }
    var style: Style { didSet { needsDisplay = true } }
    private var titleText: String
    private var hovered = false { didSet { needsDisplay = true } }

    init(_ title: String, style: Style = .secondary, symbol: String? = nil, target: AnyObject?, action: Selector) {
        self.style = style
        self.titleText = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        // We draw icon and title ourselves (see `draw`), as one centred group.
        imagePosition = .noImage
        self.title = ""
        if let s = symbol {
            glyph = NSImage(systemSymbolName: s, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold))
        }
        setAccessibilityLabel(title)
        restyle()
    }

    /// The optional leading symbol.
    private var glyph: NSImage?

    /// Kept for older call sites.
    convenience init(_ title: String, prominent: Bool, symbol: String? = nil, target: AnyObject?, action: Selector) {
        self.init(title, style: prominent ? .primary : .secondary, symbol: symbol, target: target, action: action)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTitleText(_ t: String) { titleText = t; setAccessibilityLabel(t); restyle() }

    private var textColor: NSColor {
        let p = Pal
        switch style {
        case .primary, .destructive: return p.onAccent
        case .secondary: return p.text
        case .tertiary: return p.textSecondary
        }
    }

    func restyle() { needsDisplay = true }

    private static let iconGap: CGFloat = 6
    private var iconWidth: CGFloat { glyph.map { ceil($0.size.width) } ?? 0 }

    /// Width the title (and icon) need, with side padding.
    var fittedWidth: CGFloat {
        let w = (titleText as NSString).size(withAttributes: [.font: Typo.button]).width
        return ceil(w) + Space.l * 2 - 4 + (glyph == nil ? 0 : iconWidth + Self.iconGap)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let pressed = isHighlighted
        var fill: NSColor
        switch style {
        case .primary: fill = pressed ? p.accentPressed : (hovered ? p.accentHover : p.accent)
        case .destructive: fill = pressed ? p.dangerPressed : p.danger
        case .secondary: fill = pressed ? p.surfacePressed : (hovered ? p.surfaceHover : p.surfaceStrong)
        case .tertiary: fill = pressed ? p.surfacePressed : (hovered ? p.surfaceHover : .clear)
        }
        if !isEnabled { fill = fill.withAlphaComponent(0.45) }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Radius.m, yRadius: Radius.m).fill()

        // Icon + title, centred together, title truncating before it can touch the edges.
        let color = isEnabled ? textColor : textColor.withAlphaComponent(0.6)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Typo.button, .foregroundColor: color, .paragraphStyle: para]
        let inset = Space.m
        let iconSpace = glyph == nil ? 0 : iconWidth + Self.iconGap
        let textW = min(bounds.width - inset * 2 - iconSpace, ceil((titleText as NSString).size(withAttributes: attrs).width))
        let total = iconSpace + max(0, textW)
        var x = (bounds.width - total) / 2
        if let g = glyph?.withSymbolConfiguration(.init(paletteColors: [color])) ?? glyph {
            let sz = g.size
            g.draw(in: NSRect(x: x, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconWidth + Self.iconGap
        }
        let th = ceil(Typo.button.ascender - Typo.button.descender) + 2
        (titleText as NSString).draw(in: NSRect(x: x, y: (bounds.height - th) / 2, width: textW, height: th), withAttributes: attrs)
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

/// Square symbol-only button with a round hover highlight. 28 × 28.
final class IconButton: NSButton {
    private var hovered = false { didSet { needsDisplay = true } }

    init(symbol: String, label: String, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.control, height: Metrics.control))
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        contentTintColor = Pal.textSecondary
        toolTip = label
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Swap the glyph (e.g. + ↔ ✕) and keep the label in step.
    func setSymbol(_ symbol: String, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        toolTip = label
        setAccessibilityLabel(label)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            (isHighlighted ? Pal.surfacePressed : Pal.surfaceHover).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Segmented pill tabs.
final class PillTabs: NSView {
    var titles: [String] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        setAccessibilityRole(.tabGroup)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func slot(_ i: Int) -> NSRect {
        let n = CGFloat(max(1, titles.count)), inset: CGFloat = 3
        let w = (bounds.width - inset * 2) / n
        return NSRect(x: inset + CGFloat(i) * w, y: inset, width: w, height: bounds.height - inset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        p.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Radius.m, yRadius: Radius.m).fill()
        for (i, t) in titles.enumerated() {
            let r = slot(i).insetBy(dx: 2, dy: 0)
            let on = i == selected
            if on || hoverIndex == i {
                (on ? (p.isDark ? p.surfaceStrong : NSColor.white) : p.surfaceHover).setFill()
                let path = NSBezierPath(roundedRect: r, xRadius: Radius.m - 2, yRadius: Radius.m - 2)
                path.fill()
                if on { p.border.setStroke(); path.lineWidth = 1; path.stroke() }
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: on ? Typo.bodyStrong : Typo.bodyMedium,
                .foregroundColor: on ? p.text : p.textSecondary
            ]
            let s = (t as NSString).size(withAttributes: attrs)
            (t as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoverIndex = titles.indices.first { NSPointInRect(pt, slot($0)) }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }
    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let i = titles.indices.first(where: { NSPointInRect(pt, slot($0)) }) {
            selected = i
            onSelect?(i)
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Cell that pads text away from the rounded edge and keeps the field editor transparent.
final class PaddedTextCell: NSTextFieldCell {
    var padding: CGFloat = 10
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let r = super.drawingRect(forBounds: rect)
        let h = cellSize(forBounds: rect).height
        let dy = max(0, (r.height - h) / 2)
        return NSRect(x: r.minX + padding, y: r.minY + dy, width: r.width - padding * 2, height: r.height - dy * 2)
    }
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let t = super.setUpFieldEditorAttributes(textObj)
        t.drawsBackground = false
        (t as? NSTextView)?.insertionPointColor = Pal.text
        return t
    }
}

final class PaddedSecureCell: NSSecureTextFieldCell {
    var padding: CGFloat = 10
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let r = super.drawingRect(forBounds: rect)
        let h = cellSize(forBounds: rect).height
        let dy = max(0, (r.height - h) / 2)
        return NSRect(x: r.minX + padding, y: r.minY + dy, width: r.width - padding * 2, height: r.height - dy * 2)
    }
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let t = super.setUpFieldEditorAttributes(textObj)
        t.drawsBackground = false
        (t as? NSTextView)?.insertionPointColor = Pal.text
        return t
    }
}

final class ThemedField: NSTextField {
    init(placeholder: String) {
        super.init(frame: .zero)
        let c = PaddedTextCell(textCell: "")
        c.isEditable = true; c.isSelectable = true; c.isScrollable = true; c.wraps = false
        cell = c
        styleThemedField(self, placeholder: placeholder)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ThemedSecureField: NSSecureTextField {
    init(placeholder: String) {
        super.init(frame: .zero)
        let c = PaddedSecureCell(textCell: "")
        c.isEditable = true; c.isSelectable = true; c.isScrollable = true; c.wraps = false
        cell = c
        styleThemedField(self, placeholder: placeholder)
    }
    required init?(coder: NSCoder) { fatalError() }
}

extension NSTextField {
    /// Themed fields use an attributed placeholder; change it through this so the colour sticks.
    func setThemedPlaceholder(_ text: String) {
        placeholderAttributedString = NSAttributedString(string: text, attributes: [.foregroundColor: Pal.textTertiary, .font: Typo.body])
    }
}

private func styleThemedField(_ f: NSTextField, placeholder: String) {
    let p = Pal
    f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: p.textTertiary, .font: Typo.body])
    f.font = Typo.body
    f.textColor = p.text
    f.isBordered = false
    f.isBezeled = false
    f.drawsBackground = false
    f.usesSingleLineMode = true
    f.lineBreakMode = .byTruncatingTail
    f.focusRingType = .none
    f.wantsLayer = true
    f.layer?.masksToBounds = true
    f.layer?.backgroundColor = p.field.cgColor
    f.layer?.cornerRadius = Radius.m
    f.layer?.cornerCurve = .continuous
    f.layer?.borderWidth = 1
    f.layer?.borderColor = p.fieldBorder.cgColor
    f.setAccessibilityLabel(placeholder)
}

/// System popup dressed like a secondary button.
func stylePopup(_ pop: NSPopUpButton) {
    let p = Pal
    pop.isBordered = false
    pop.font = Typo.nav
    pop.contentTintColor = p.text
    pop.wantsLayer = true
    pop.layer?.cornerRadius = Radius.m
    pop.layer?.cornerCurve = .continuous
    pop.layer?.backgroundColor = p.surfaceStrong.cgColor
    for item in pop.itemArray {
        item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: Typo.nav, .foregroundColor: p.text])
    }
}

/// Rounded search box: magnifier + text field on one surface.
final class SearchBox: NSView {
    let field = NSTextField()
    private let icon = NSImageView()
    override var isFlipped: Bool { true }

    init(placeholder: String) {
        super.init(frame: .zero)
        let p = Pal
        wantsLayer = true
        layer?.cornerRadius = Radius.m
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = p.field.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.fieldBorder.cgColor
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = p.textTertiary
        addSubview(icon)
        let c = PaddedTextCell(textCell: "")
        c.padding = 0
        c.isEditable = true; c.isSelectable = true; c.isScrollable = true; c.wraps = false
        c.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: p.textTertiary, .font: Typo.body])
        field.cell = c
        field.font = Typo.body
        field.textColor = p.text
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.focusRingType = .none
        field.setAccessibilityLabel(placeholder)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 11, y: (bounds.height - 16) / 2, width: 16, height: 16)
        field.frame = NSRect(x: 34, y: (bounds.height - 18) / 2, width: bounds.width - 44, height: 18)
    }
}

/// Rounded coloured square with a white symbol.
final class IconTile: NSView {
    private let icon = NSImageView()
    init(symbol: String, color: NSColor, size: CGFloat = Metrics.icon, pointSize: CGFloat = 13) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = size * 0.3
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = color.cgColor
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        icon.contentTintColor = .white
        icon.frame = bounds.insetBy(dx: size * 0.2, dy: size * 0.2)
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// On/off switch in the accent colour. 40 × 22.
final class Toggle: NSView {
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? "on" : "off") } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 22) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
        setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isOn ? p.accent : p.surfaceStrong).withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        track.fill()
        let d = bounds.height - 4
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: isOn ? bounds.maxX - d - 2 : 2, y: 2, width: d, height: d)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        onChange?(isOn)
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// Small coloured dot + label for connection states.
enum ConnectionState {
    case connected, disconnected, connecting, error, needsAuth
    var label: String {
        switch self {
        case .connected: return "Connected"
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .error: return "Error"
        case .needsAuth: return "Needs access"
        }
    }
    var color: NSColor {
        let p = Pal
        switch self {
        case .connected: return p.success
        case .disconnected: return p.muted
        case .connecting: return p.info
        case .error: return p.danger
        case .needsAuth: return p.warning
        }
    }
}

/// Draws a count badge inside `rect`'s right edge, returns the width used.
@discardableResult
func drawBadge(_ n: Int, rightEdge x: CGFloat, midY: CGFloat, color: NSColor? = nil) -> CGFloat {
    guard n > 0 else { return 0 }
    let p = Pal
    let s = n > 99 ? "99+" : String(n)
    let attrs: [NSAttributedString.Key: Any] = [.font: Typo.badge, .foregroundColor: p.onAccent]
    let sz = (s as NSString).size(withAttributes: attrs)
    let w = max(20, sz.width + 10)
    let r = NSRect(x: x - w, y: midY - 10, width: w, height: 20)
    (color ?? p.accent).setFill()
    NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
    (s as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    return w
}
