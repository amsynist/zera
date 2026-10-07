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

/// Semantic colours, from the chosen theme (Settings → Appearance; see `ThemeStore`). The notch
/// island is always dark. (The light values remain for the icon tool and older renders.)
/// Surfaces are opaque so stacking never washes out.
struct Palette {
    let isDark: Bool
    private var t: ZeraTheme { ThemeStore.shared.current }

    // Card chrome — the theme's glass, top to bottom.
    var cardTop: NSColor { isDark ? t.glassTop.withAlphaComponent(0.97) : rgb(0.955, 0.950, 0.995, 0.97) }
    var cardBottom: NSColor { isDark ? t.glassBottom.withAlphaComponent(0.97) : rgb(0.925, 0.915, 0.985, 0.98) }
    /// Hairline edges: soft, so rows and fields read as glass, not as outlines.
    var border: NSColor { isDark ? t.border : rgb(0.36, 0.26, 0.70, 0.14) }
    var blurMaterial: NSVisualEffectView.Material { isDark ? .hudWindow : .popover }
    var nsAppearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    // Text — then muted for metadata.
    var text: NSColor { isDark ? t.text : rgb(0.14, 0.12, 0.30) }
    func text(_ alpha: CGFloat) -> NSColor { text.withAlphaComponent(alpha) }
    var textSecondary: NSColor { isDark ? t.textSecondary : text(0.64) }
    var textTertiary: NSColor { isDark ? t.textTertiary : text(0.44) }

    // Surfaces — neutral steps above the glass.
    var surface: NSColor { isDark ? t.surface : rgb(1, 1, 1, 0.82) }
    var surfaceHover: NSColor { isDark ? t.surfaceHover : rgb(0.93, 0.91, 1.0) }
    var surfaceStrong: NSColor { isDark ? t.surfaceStrong : rgb(0.88, 0.86, 0.98) }
    var surfacePressed: NSColor { isDark ? t.glassBottom : rgb(0.85, 0.83, 0.96) }
    var field: NSColor { isDark ? t.field : rgb(1, 1, 1) }
    var fieldBorder: NSColor { isDark ? t.border : rgb(0.36, 0.26, 0.70, 0.14) }
    var divider: NSColor { isDark ? t.divider : rgb(0.36, 0.26, 0.70, 0.10) }
    var codeBox: NSColor { isDark ? (t.glassBottom.blended(withFraction: 0.35, of: .black) ?? t.glassBottom) : rgb(0.16, 0.14, 0.32) }
    var codeText: NSColor { isDark ? (t.success.blended(withFraction: 0.55, of: t.text) ?? t.text) : rgb(0.85, 0.95, 0.85) }

    // Accent — main actions, the selected tab, toggles; a gradient from `accent` to `accentDeep`.
    var accent: NSColor { isDark ? t.accent : rgb(0.447, 0.310, 0.980) }
    var accentHover: NSColor { isDark ? (t.accent.blended(withFraction: 0.15, of: .white) ?? t.accent) : rgb(0.520, 0.390, 1.0) }
    var accentPressed: NSColor { isDark ? (t.accent.blended(withFraction: 0.15, of: .black) ?? t.accent) : rgb(0.380, 0.250, 0.880) }
    /// The accent washed into the surface: selected chips, tabs and rows.
    var accentSoft: NSColor { isDark ? (t.surface.blended(withFraction: 0.16, of: t.accent) ?? t.surface) : rgb(0.88, 0.84, 1.0) }
    /// The far end of the accent gradient.
    var accentDeep: NSColor { isDark ? t.accentDeep : rgb(0.560, 0.300, 0.960) }
    /// Edge for selected / highlighted surfaces.
    var accentBorder: NSColor { accent.withAlphaComponent(isDark ? 0.55 : 0.45) }
    /// The theme's second colour, paired with the accent.
    var highlight: NSColor { isDark ? t.highlight : rgb(0.95, 0.45, 0.35) }
    /// List rows on the island: one step up from the glass.
    var surfaceRow: NSColor { isDark ? t.row : rgb(1, 1, 1, 0.74) }
    /// Raised panels (insight card, speech bubble).
    var surfaceElevated: NSColor { isDark ? t.surfaceHover : rgb(1, 1, 1, 0.96) }
    /// Text and icons on a filled accent.
    var onAccent: NSColor { isDark ? t.onAccent : .white }
    var success: NSColor { isDark ? t.success : rgb(0.21, 0.89, 0.67) }
    var warning: NSColor { isDark ? t.warning : rgb(1.00, 0.74, 0.26) }
    var danger: NSColor { isDark ? t.danger : rgb(1.00, 0.33, 0.41) }
    var dangerPressed: NSColor { danger.blended(withFraction: 0.15, of: .black) ?? danger }
    var info: NSColor { isDark ? t.info : rgb(0.30, 0.74, 1.00) }
    var muted: NSColor { isDark ? t.textTertiary : rgb(0.60, 0.58, 0.74) }
    /// The island's outline and glow.
    var edge: NSColor { isDark ? t.edge : rgb(0.36, 0.26, 0.70, 0.30) }

    // Fixed identity colours for icon tiles (same in every theme so they stay recognisable)
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

    /// Always the dark navy look: every screen lives in the notch island, beside the dark wings.
    static var current: Palette { Palette(isDark: true) }

    /// Call once at launch so "System" follows the macOS switch live.
    static func observeSystem() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            if appearance == .system { NotificationCenter.default.post(name: changed, object: nil) }
        }
    }
}

var Pal: Palette { Palette.current }

// MARK: - Buttons

/// The island's one button family: rounded pills. A quiet chip by default; colour only as an
/// outline with a soft tint — the theme's accent for the main action, green for done / approve,
/// red for stop / reject / delete, amber for a warning. No bright fills, so buttons never shout
/// over the content.
enum ButtonTone { case neutral, accent, success, danger, warning }

extension Palette {
    func tone(_ t: ButtonTone) -> NSColor? {
        switch t {
        case .neutral: return nil
        case .accent: return accent
        case .success: return success
        case .danger: return danger
        case .warning: return warning
        }
    }

    /// Draws a button pill and returns the colour its title should use.
    @discardableResult
    func drawButton(_ path: NSBezierPath, tone t: ButtonTone, hovered: Bool, pressed: Bool, enabled: Bool = true) -> NSColor {
        let dim: CGFloat = enabled ? 1 : 0.45
        guard let c = tone(t) else {
            (pressed ? surfacePressed : (hovered ? surfaceHover : surface)).withAlphaComponent(dim).setFill(); path.fill()
            fieldBorder.withAlphaComponent(fieldBorder.alphaComponent * (hovered ? 1 : 0.8) * dim).setStroke(); path.lineWidth = 1; path.stroke()
            return text.withAlphaComponent(enabled ? 1 : 0.55)
        }
        if hovered && enabled {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow(); glow.shadowColor = c.withAlphaComponent(0.35); glow.shadowBlurRadius = 10; glow.shadowOffset = .zero; glow.set()
            c.withAlphaComponent(pressed ? 0.26 : 0.18).setFill(); path.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            c.withAlphaComponent((pressed ? 0.24 : 0.09) * dim).setFill(); path.fill()
        }
        c.withAlphaComponent((hovered ? 0.8 : 0.58) * dim).setStroke(); path.lineWidth = 1; path.stroke()
        let label = c.blended(withFraction: 0.18, of: .white) ?? c
        return label.withAlphaComponent(enabled ? 1 : 0.55)
    }
}

// MARK: - The selected look

extension Palette {
    /// One "selected" look everywhere — segments, chips, settings nav, list rows: dark navy with a
    /// thin blue edge and a faint glow. Primary actions keep the blue → violet gradient; a
    /// selection never does, so "what's chosen" and "what to do" never look alike.
    var selectedFill: NSColor { accentSoft }
    var selectedEdge: NSColor { accent.withAlphaComponent(0.5) }
    /// Counts and icons inside a selected segment.
    var selectedAccent: NSColor { info }

    func drawSelected(_ path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.28)
        glow.shadowBlurRadius = 8
        glow.shadowOffset = .zero
        glow.set()
        selectedFill.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        selectedEdge.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

/// Honour the system "Reduce motion" switch: no sway, no cross-fades, instant panels.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func duration(_ d: TimeInterval) -> TimeInterval { reduced ? 0 : d }
}

// MARK: - Controls

/// The one button. Four styles, hover / pressed / disabled, title always fits (`fittedWidth`).
final class CardButton: NSButton {
    enum Style { case primary, secondary, tertiary, destructive, success }
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

    /// Main actions click softly; the rest stay silent so the island isn't noisy.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if style == .primary { SoundService.shared.play(.button) }
        return super.sendAction(action, to: target)
    }

    private var textColor: NSColor {
        let p = Pal
        switch style {
        case .primary: return p.accent
        case .destructive: return p.danger
        case .success: return p.success
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
        return ceil(w) + Space.l * 2 - 4 + (glyph == nil ? 0 : iconWidth + (titleText.isEmpty ? 0 : Self.iconGap))
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let pressed = isHighlighted
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        var titleColor: NSColor? = nil
        switch style {
        case .primary: titleColor = p.drawButton(shape, tone: .accent, hovered: hovered, pressed: pressed, enabled: isEnabled)
        case .destructive: titleColor = p.drawButton(shape, tone: .danger, hovered: hovered, pressed: pressed, enabled: isEnabled)
        case .success: titleColor = p.drawButton(shape, tone: .success, hovered: hovered, pressed: pressed, enabled: isEnabled)
        case .secondary: titleColor = p.drawButton(shape, tone: .neutral, hovered: hovered, pressed: pressed, enabled: isEnabled)
        case .tertiary:
            if hovered || pressed { (pressed ? p.surfacePressed : p.surfaceHover).setFill(); shape.fill() }
        }

        // Icon + title, centred together, title truncating before it can touch the edges.
        let color = titleColor ?? (isEnabled ? textColor : textColor.withAlphaComponent(0.6))
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Typo.button, .foregroundColor: color, .paragraphStyle: para]
        let inset = Space.m
        // No gap after the icon when there is no title, so icon-only buttons stay centred.
        let iconSpace = glyph == nil ? 0 : iconWidth + (titleText.isEmpty ? 0 : Self.iconGap)
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
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.m, yRadius: Radius.m)
        p.surface.setFill(); box.fill()
        p.divider.setStroke(); box.lineWidth = 1; box.stroke()
        for (i, t) in titles.enumerated() {
            let r = slot(i).insetBy(dx: 1, dy: 0)
            let on = i == selected
            let path = NSBezierPath(roundedRect: r, xRadius: Radius.m - 2, yRadius: Radius.m - 2)
            if on { p.drawSelected(path) } else if hoverIndex == i { p.surfaceHover.setFill(); path.fill() }
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

/// Centres a single line of text (and its placeholder, and the caret while typing) vertically,
/// and pads it away from the rounded edge. Drawing and the field editor (editing / selecting) use
/// the same rect, so the placeholder and caret never jump to the top-left corner on focus.
private func centeredTextRect(_ rect: NSRect, font: NSFont?, padding: CGFloat) -> NSRect {
    let f = font ?? Typo.body
    let lineH = ceil(f.ascender - f.descender + f.leading) + 2
    let h = min(rect.height, lineH)
    return NSRect(x: rect.minX + padding, y: rect.minY + floor((rect.height - h) / 2),
                  width: max(0, rect.width - padding * 2), height: h)
}

/// Cell that pads text away from the rounded edge and keeps the field editor transparent.
final class PaddedTextCell: NSTextFieldCell {
    var padding: CGFloat = 10
    override func drawingRect(forBounds rect: NSRect) -> NSRect { centeredTextRect(rect, font: font, padding: padding) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centeredTextRect(rect, font: font, padding: padding), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centeredTextRect(rect, font: font, padding: padding), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
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
    override func drawingRect(forBounds rect: NSRect) -> NSRect { centeredTextRect(rect, font: font, padding: padding) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centeredTextRect(rect, font: font, padding: padding), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centeredTextRect(rect, font: font, padding: padding), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
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
        layer?.cornerRadius = 15
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
        layer?.cornerRadius = bounds.height / 2
        icon.frame = NSRect(x: 13, y: (bounds.height - 16) / 2, width: 16, height: 16)
        field.frame = NSRect(x: 36, y: (bounds.height - 18) / 2, width: bounds.width - 48, height: 18)
    }
}

/// Rounded square tinted with a colour: soft fill, hairline edge, the symbol in that colour.
final class IconTile: NSView {
    private let icon = NSImageView()
    init(symbol: String, color: NSColor, size: CGFloat = Metrics.icon, pointSize: CGFloat = 13) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = size * 0.32
        layer?.cornerCurve = .continuous
        let tint = color.blended(withFraction: 0.25, of: .white) ?? color
        layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = color.withAlphaComponent(0.45).cgColor
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        icon.contentTintColor = tint
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
        if isOn {
            NSGradient(starting: p.accent.withAlphaComponent(isEnabled ? 1 : 0.45), ending: p.accentDeep.withAlphaComponent(isEnabled ? 1 : 0.45))?.draw(in: track, angle: 0)
        } else {
            p.surfaceStrong.withAlphaComponent(isEnabled ? 1 : 0.45).setFill(); track.fill()
            p.divider.setStroke(); track.lineWidth = 1; track.stroke()
        }
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
