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
    static let m: CGFloat = 8      // buttons, fields, tabs
    static let l: CGFloat = 12     // rows, tiles
    static let card: CGFloat = 18  // the card itself
}

/// Shared island header geometry, including controls centred on the title row.
enum ScreenHeader {
    static let titleTop: CGFloat = 56
    static let titleHeight: CGFloat = 32
    static let subtitleTop = titleTop + 34
    static let subtitleHeight: CGFloat = 18
    /// Actions beside a title and subtitle align to the centre of that whole block.
    static func blockControlY(_ height: CGFloat) -> CGFloat {
        titleTop + (subtitleTop + subtitleHeight - titleTop - height) / 2
    }
    static func controlY(_ height: CGFloat) -> CGFloat { titleTop + (titleHeight - height) / 2 }
    static func titleFrame(width: CGFloat, padding: CGFloat = Metrics.cardPad) -> NSRect {
        NSRect(x: padding, y: titleTop, width: max(0, width / 2 - Isle.zeraGap / 2 - padding), height: titleHeight)
    }
    static func subtitleFrame(width: CGFloat, padding: CGFloat = Metrics.cardPad) -> NSRect {
        var frame = titleFrame(width: width, padding: padding)
        frame.origin.y = subtitleTop; frame.size.height = subtitleHeight
        return frame
    }
    static func trailingRect(width: CGFloat) -> NSRect {
        let x = width / 2 + Isle.zeraGap / 2
        return NSRect(x: x, y: controlY(Metrics.headerButton), width: max(0, width - Metrics.cardPad - x), height: Metrics.headerButton)
    }
    static func detailTitleFrame(width: CGFloat, padding: CGFloat) -> NSRect {
        var frame = titleFrame(width: width, padding: padding)
        let leading = Metrics.headerButton + Space.m
        frame.origin.x += leading; frame.size.width = max(0, frame.width - leading)
        frame.origin.y = controlY(22); frame.size.height = 22
        return frame
    }
    static func detailSubtitleFrame(width: CGFloat, padding: CGFloat) -> NSRect {
        var frame = detailTitleFrame(width: width, padding: padding)
        frame.origin.y = subtitleTop; frame.size.height = subtitleHeight
        return frame
    }
}

/// Wrap content-sized controls, sharing unused row width equally between them.
enum FlowLayout {
    static func frames(widths: [CGFloat], available: CGFloat, height: CGFloat, gap: CGFloat = Space.s) -> [NSRect] {
        guard available > 0 else { return [] }
        var result: [NSRect] = [], row: [CGFloat] = []
        var used: CGFloat = 0, y: CGFloat = 0
        func finishRow() {
            guard !row.isEmpty else { return }
            let extra = max(0, available - used) / CGFloat(row.count)
            var x: CGFloat = 0
            for (index, width) in row.enumerated() {
                let edge = index == row.count - 1 ? available : (x + width + extra).rounded(.down)
                result.append(NSRect(x: x, y: y, width: max(0, edge - x), height: height))
                x = edge + gap
            }
            y += height + gap; row = []; used = 0
        }
        for natural in widths {
            let width = min(natural, available)
            if !row.isEmpty && used + gap + width > available { finishRow() }
            used += (row.isEmpty ? 0 : gap) + width
            row.append(width)
        }
        finishRow()
        return result
    }
}

/// Filters and search share a row when both fit; compact screens keep both on separate rows.
struct SearchToolbarLayout {
    let filters: NSRect
    let search: NSRect
    let bottom: CGFloat
    init(width: CGFloat, filtersWidth: CGFloat, top: CGFloat) {
        let leading = min(width, filtersWidth)
        if width - leading - Space.m >= 160 {
            filters = NSRect(x: 0, y: top + (Metrics.field - Metrics.segment) / 2, width: leading, height: Metrics.segment)
            search = NSRect(x: leading + Space.m, y: top, width: width - leading - Space.m, height: Metrics.field)
        } else {
            filters = NSRect(x: 0, y: top, width: leading, height: Metrics.segment)
            search = NSRect(x: 0, y: top + Metrics.segment + Space.s, width: width, height: Metrics.field)
        }
        bottom = search.maxY
    }
}

enum Metrics {
    static let row: CGFloat = 44        // list rows
    static let control: CGFloat = 28    // fields, popups, inline buttons
    static let button: CGFloat = 32     // every text button
    static let icon: CGFloat = 30       // icon tile in a row
    /// Side padding of island screens built on CardBase: the same 20 pt as every other screen.
    static let cardPad: CGFloat = sidePad

    // v2: one set of sizes every screen shares.
    /// Side padding inside the island.
    static let sidePad: CGFloat = 32
    /// Segmented controls (Clipboard, Claude, GitHub, Reminders, file tabs, Tasks, Export).
    static let segment: CGFloat = 36
    static let segmentInset: CGFloat = 3
    /// Filter and project chips.
    static let chip: CGFloat = 30
    /// Search boxes and single-line fields.
    static let field: CGFloat = 38
    /// Square icon buttons in a header, and the smaller ones inside a row.
    static let headerButton: CGFloat = 34
    static let rowButton: CGFloat = 28
    /// Gap between list rows.
    static let settingRow: CGFloat = 54
    static let rowGap: CGFloat = 8
}

/// The three list-row heights, each with its icon-tile size.
enum RowTier {
    case compact, standard, rich
    /// Tasks, settings, themes, clipboard · home, shelf · Claude sessions, pull requests, agenda.
    var height: CGFloat {
        switch self {
        case .compact: return 46
        case .standard: return 58
        case .rich: return 70
        }
    }
    var tile: CGFloat {
        switch self {
        case .compact: return 30
        case .standard: return 40
        case .rich: return 44
        }
    }
    /// Corner radius for this tier's icon tile.
    var tileRadius: CGFloat { (tile * 0.28).rounded() }
}

enum Typo {
    static let detailTitle = NSFont.systemFont(ofSize: 16, weight: .medium)
    static let paneTitle = NSFont.systemFont(ofSize: 17, weight: .medium)
    static let settingLabel = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let control = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// Dashboard readings: stable digit widths, with the same quiet weight as controls.
    static let metricValue = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .medium)
    static let title = NSFont.systemFont(ofSize: 15, weight: .medium)
    static let body = NSFont.systemFont(ofSize: 12.5, weight: .regular)
    static let bodyMedium = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let bodyStrong = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let secondary = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let button = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let badge = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let nav = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
    /// Compact branch labels, shared by both opener styles.
    static let branchLabel = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
    static let branchKern: CGFloat = 0

    // v2: the seven roles every screen shares.
    /// The screen title uses size and space, rather than a heavier weight, for hierarchy.
    static let screenTitle = NSFont.systemFont(ofSize: 24, weight: .medium)
    static let screenSubtitle = NSFont.systemFont(ofSize: 13, weight: .regular)
    /// The line under a banner's headline.
    static let bannerDetail = NSFont.systemFont(ofSize: 13, weight: .regular)
    /// Sentence-case section labels share one weight and baseline.
    static let sectionLabel = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let sectionKern: CGFloat = 0
    static let rowTitle = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let rowTitleStrong = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let meta = NSFont.systemFont(ofSize: 12.5, weight: .regular)
    /// Segments and chips: the same weight selected or not, so nothing shifts when you pick one.
    static let chip = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let count = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    /// Preserve the supplied casing, including product names and acronyms.
    static func sectionText(_ text: String, color: NSColor? = nil) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: sectionLabel, .foregroundColor: color ?? Pal.textTertiary, .kern: sectionKern])
    }
}

/// Semantic colours, from the chosen theme (Settings → Appearance; see `ThemeStore`). Zera only
/// has a dark look — every screen lives in the black notch island — so each colour forwards to
/// the theme. Surfaces are opaque so stacking never washes out.
struct Palette {
    private var t: ZeraTheme { ThemeStore.shared.current }

    // Card chrome — the theme's glass, top to bottom.
    var cardTop: NSColor { t.glassTop.withAlphaComponent(0.97) }
    var cardBottom: NSColor { t.glassBottom.withAlphaComponent(0.97) }
    /// Hairline edges: soft, so rows and fields read as glass, not as outlines.
    var border: NSColor { t.border }
    var blurMaterial: NSVisualEffectView.Material { .hudWindow }
    var nsAppearance: NSAppearance? { NSAppearance(named: .darkAqua) }

    // Text — then muted for metadata.
    var text: NSColor { t.text }
    func text(_ alpha: CGFloat) -> NSColor { text.withAlphaComponent(alpha) }
    var textSecondary: NSColor { t.textSecondary }
    var textTertiary: NSColor { t.textTertiary }

    // Surfaces — neutral steps above the glass.
    var surface: NSColor { t.surface }
    var surfaceHover: NSColor { t.surfaceHover }
    var surfaceStrong: NSColor { t.surfaceStrong }
    var surfacePressed: NSColor { t.glassBottom }
    var field: NSColor { t.field }
    var fieldBorder: NSColor { t.border }
    var divider: NSColor { t.divider }
    var codeBox: NSColor { t.glassBottom.blended(withFraction: 0.35, of: .black) ?? t.glassBottom }
    var codeText: NSColor { t.success.blended(withFraction: 0.55, of: t.text) ?? t.text }

    // Accent — main actions, the selected tab, toggles; a gradient from `accent` to `accentDeep`.
    var accent: NSColor { t.accent }
    /// The accent washed into the surface: selected chips, tabs and rows.
    var accentSoft: NSColor { t.surface.blended(withFraction: 0.16, of: t.accent) ?? t.surface }
    /// Water keeps its blue identity across themes; the surrounding glass remains themed.
    var water: NSColor { rgb(0.24, 0.67, 0.98) }
    var waterDeep: NSColor { rgb(0.08, 0.39, 0.82) }
    /// The far end of the accent gradient.
    var accentDeep: NSColor { t.accentDeep }
    /// Edge for selected / highlighted surfaces.
    var accentBorder: NSColor { accent.withAlphaComponent(0.55) }
    /// The theme's second colour, paired with the accent.
    var highlight: NSColor { t.highlight }
    /// List rows on the island: one step up from the glass.
    var surfaceRow: NSColor { t.row }
    /// Raised panels (insight card, speech bubble).
    var surfaceElevated: NSColor { t.surfaceHover }
    /// Text and icons on a filled accent.
    var onAccent: NSColor { t.onAccent }
    var success: NSColor { t.success }
    var warning: NSColor { t.warning }
    var danger: NSColor { t.danger }
    var info: NSColor { t.info }
    var muted: NSColor { t.textTertiary }
    /// The island's outline and glow.
    var edge: NSColor { t.edge }

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

    /// Posted when the theme changes; every screen repaints.
    nonisolated static let changed = Notification.Name("ZeraPaletteChanged")

    static var current: Palette { Palette() }
}

var Pal: Palette { Palette.current }

// MARK: - Buttons

/// The island's one button family: rounded 32 pt buttons. A quiet chip by default. The main
/// action uses a muted theme-tinted surface gradient and done / approve is tinted green, so what
/// to press stands out; stop / reject / delete and warnings stay a soft tint with an edge.
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

    /// Dark ink or white, whichever reads better on `c`.
    func ink(on c: NSColor) -> NSColor {
        guard let rgb = c.usingColorSpace(.sRGB) else { return .white }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let lum = 0.2126 * lin(rgb.redComponent) + 0.7152 * lin(rgb.greenComponent) + 0.0722 * lin(rgb.blueComponent)
        return lum > 0.3 ? (cardBottom.blended(withFraction: 0.4, of: .black) ?? .black).withAlphaComponent(1) : .white
    }

    /// Draws a button and returns the colour its title should use.
    @discardableResult
    func drawButton(_ path: NSBezierPath, tone t: ButtonTone, hovered: Bool, pressed: Bool, enabled: Bool = true) -> NSColor {
        let dim: CGFloat = enabled ? 1 : 0.45
        let lit = hovered && enabled
        switch t {
        case .neutral:
            (pressed ? surfacePressed : (lit ? surfaceHover : surface)).withAlphaComponent(dim).setFill(); path.fill()
            border.withAlphaComponent(min(1, border.alphaComponent * (lit ? 2 : 1.3)) * dim).setStroke()
            path.lineWidth = 1; path.stroke()
            return text.withAlphaComponent(enabled ? 1 : 0.55)
        case .accent:
            let fill = pressed && enabled ? surfacePressed : (lit ? surfaceStrong : surfaceElevated)
            fill.withAlphaComponent(dim).setFill(); path.fill()
            accent.withAlphaComponent((lit ? 0.5 : 0.28) * dim).setStroke()
            path.lineWidth = 1; path.stroke()
            return text.withAlphaComponent(enabled ? 1 : 0.55)
        case .success:
            // Done / approve: a tint of green with a green edge, like the design's quiet "good".
            let c = success
            c.withAlphaComponent((pressed ? 0.28 : (lit ? 0.24 : 0.18)) * dim).setFill(); path.fill()
            c.withAlphaComponent((lit ? 0.6 : 0.4) * dim).setStroke(); path.lineWidth = 1; path.stroke()
            return c.withAlphaComponent(enabled ? 1 : 0.55)
        case .danger, .warning:
            let c = t == .danger ? danger : warning
            c.withAlphaComponent((pressed ? 0.26 : (lit ? 0.2 : 0.13)) * dim).setFill(); path.fill()
            c.withAlphaComponent((lit ? 0.6 : 0.35) * dim).setStroke(); path.lineWidth = 1; path.stroke()
            return c.withAlphaComponent(enabled ? 1 : 0.55)
        }
    }
}

// MARK: - The selected look

extension Palette {
    /// Shared solid selection background for chips, list rows, navigation and theme rows.
    /// Overlays use GlideWash's translucent variant so labels remain visible.
    var selectedFill: NSColor { surfaceStrong }
    var selectedEdge: NSColor { border }

    func drawSelected(_ path: NSBezierPath) {
        selectedFill.setFill(); path.fill()
        selectedEdge.setStroke(); path.lineWidth = 1; path.stroke()
    }

    /// The sliding pill inside a segmented control: one step up from the track, with a soft
    /// accent edge and a little depth.
    func drawSegmentIndicator(_ path: NSBezierPath) {
        // A segment can redraw between removal and its next layout pass. AppKit's
        // `bounds` raises an Objective-C exception for an empty path (not CGRect.zero).
        guard path.elementCount > 0 else { return }
        let b = path.bounds
        guard b.width > 0, b.height > 0, b.width.isFinite, b.height.isFinite else { return }
        // v2: one step up from the track, with a hairline of light along its top edge.
        NSGraphicsContext.saveGraphicsState()
        let depth = NSShadow()
        depth.shadowColor = NSColor.black.withAlphaComponent(0.28)
        depth.shadowBlurRadius = 4
        depth.shadowOffset = NSSize(width: 0, height: -1)
        depth.set()
        surfaceStrong.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSRect(x: b.minX, y: flipped ? b.minY : b.maxY - 1, width: b.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Honour the system "Reduce motion" switch: no sway, no cross-fades, instant panels.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let selectionDuration: TimeInterval = 0.3
    static func selectionProgress(_ t: Double) -> Double {
        let p = min(1, max(0, t))
        return 1 - pow(1 - p, 3)
    }
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
        focusRingType = .exterior
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
        let box = bounds.insetBy(dx: 0.5, dy: 0.5).pressed(pressed && isEnabled)
        let radius = min(Radius.m, box.height / 2)
        let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
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
        (titleText as NSString).draw(in: NSRect(x: x, y: (bounds.height - th) / 2, width: max(0, textW), height: th), withAttributes: attrs)
        drawControlFocus()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetHoverTracking()
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

    /// A clean line icon (`LineIcon`) in place of the symbol.
    func setLine(_ name: String) {
        if let g = LineIcon.image(name, size: 15) { image = g; needsDisplay = true }
    }

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
        drawControlFocus()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetHoverTracking()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Segmented pill tabs: the same look and gliding indicator as the island's segmented controls.
final class PillTabs: NSView {
    var titles: [String] { didSet { needsDisplay = true; needsLayout = true } }
    var selected = 0 {
        didSet {
            guard selected != oldValue else { return }
            indicator.move(to: slot(selected), animated: true)
            needsDisplay = true; needsLayout = true
        }
    }
    var onSelect: ((Int) -> Void)?
    /// What each tab shows: after a switch these page in from the side you moved toward.
    var switches: (() -> [NSView])?
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private lazy var indicator = SlidingIndicator(view: self)
    private lazy var targets = SegmentTargets(owner: self)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        targets.update(labels: titles, selected: [selected], frame: slot) { [weak self] index in
            guard let self else { return }
            let old = self.selected
            self.selected = index
            self.onSelect?(index)
            if let views = self.switches?() { Motion.tabSwitch(views, from: old, to: index) }
        }
    }

    private func slot(_ i: Int) -> NSRect {
        let n = CGFloat(max(1, titles.count)), inset = Metrics.segmentInset
        let w = (bounds.width - inset * 2) / n
        return NSRect(x: inset + CGFloat(i) * w, y: inset, width: w, height: bounds.height - inset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let radius = Radius.m + 2, inner = Radius.m - 1
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        p.surface.setFill(); box.fill()
        p.divider.setStroke(); box.lineWidth = 1; box.stroke()
        if let h = hoverIndex, h != selected {
            p.surfaceHover.setFill()
            NSBezierPath(roundedRect: slot(h), xRadius: inner, yRadius: inner).fill()
        }
        if !titles.isEmpty {
            indicator.settle(at: slot(selected))
            p.drawSegmentIndicator(NSBezierPath(roundedRect: indicator.rect, xRadius: inner, yRadius: inner))
        }
        for (i, t) in titles.enumerated() {
            let r = slot(i)
            let attrs: [NSAttributedString.Key: Any] = [.font: Typo.chip, .foregroundColor: i == selected ? p.text : p.textSecondary]
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
            let old = selected
            selected = i
            onSelect?(i)
            if let views = switches?() { Motion.tabSwitch(views, from: old, to: i) }
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
        let tint = color.blended(withFraction: 0.12, of: .white) ?? color
        layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        icon.contentTintColor = tint
        icon.frame = bounds.insetBy(dx: size * 0.2, dy: size * 0.2)
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A clean line icon (`LineIcon`) in place of the symbol.
    func setLine(_ name: String) {
        guard let g = LineIcon.image(name, size: bounds.width * 0.5) else { return }
        icon.image = g
        icon.imageScaling = .scaleNone
        icon.frame = bounds
    }
}

/// On/off switch in the accent colour. 40 × 22.
final class Toggle: NSButton {
    var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off; needsDisplay = true }
    }
    var onChange: ((Bool) -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 22) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
        title = ""
        isBordered = false
        setButtonType(.switch)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changed() { onChange?(isOn) }

    override func accessibilityValue() -> Any? { NSNumber(value: isOn) }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let dim: CGFloat = isEnabled ? 1 : 0.4
        let box = bounds.insetBy(dx: 1, dy: 1)
        let track = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
        (isOn ? p.accent : p.surfaceStrong).withAlphaComponent(dim).setFill(); track.fill()
        p.border.withAlphaComponent(dim).setStroke(); track.lineWidth = 1; track.stroke()
        let d = box.height - 4
        NSColor.white.withAlphaComponent(dim).setFill()
        NSBezierPath(ovalIn: NSRect(x: isOn ? box.maxX - d - 2 : box.minX + 2, y: box.minY + 2, width: d, height: d)).fill()
        drawControlFocus(radius: box.height / 2)
    }
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
