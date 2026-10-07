import AppKit

// Building blocks for the GitHub PR screen. Everything reads its colours from `Pal` and its
// spacing from `Space` / `Radius`, so the screen stays in the same design system as the others.

// MARK: - Menus

/// Menu item that runs a closure — keeps the overflow / filter menus short to write.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
        if let s = symbol { image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

extension NSMenu {
    /// Builds a menu that respects each item's `isEnabled`.
    static func make(_ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        items.forEach { m.addItem($0) }
        return m
    }

    /// Opens under `view`, left-aligned with it.
    func pop(below view: NSView) {
        let y = view.isFlipped ? view.bounds.height + 4 : -4
        popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }
}

// MARK: - Screen icon

/// The square icon at the top-left of every screen: a gradient tile with a white glyph, the
/// same size, radius and edge everywhere so the screens read as one family. Drawn directly
/// (no subviews), so it can never end up blank or offset.
final class ScreenIconTile: NSView {
    var symbol: String { didSet { needsDisplay = true } }
    private let top: NSColor
    private let bottom: NSColor
    override var isFlipped: Bool { true }

    init(symbol: String, top: NSColor, bottom: NSColor) {
        self.symbol = symbol
        self.top = top
        self.bottom = bottom
        super.init(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Zera's screens, one colour each.
    static func dropFiles() -> ScreenIconTile {
        ScreenIconTile(symbol: "tray.and.arrow.down.fill", top: Pal.accent, bottom: Pal.accentDeep)
    }
    static func claude() -> ScreenIconTile {
        let c = Pal.tileClaude
        return ScreenIconTile(symbol: "sparkles", top: c.blended(withFraction: 0.12, of: .white) ?? c, bottom: c.blended(withFraction: 0.22, of: .black) ?? c)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = bounds.width * 0.29
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
        NSColor.white.withAlphaComponent(0.2).setStroke(); path.lineWidth = 1; path.stroke()
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: bounds.width * 0.42, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [.white])) else { return }
        let s = img.size
        img.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// MARK: - Avatars

/// Small in-memory cache for reviewer / author avatars. Images come only from GitHub's avatar
/// CDN and are fetched without any credentials — the token never leaves api.github.com.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()
    nonisolated static let loaded = Notification.Name("ZeraAvatarLoaded")

    private var images: [URL: NSImage] = [:]
    private var inflight: Set<URL> = []
    private var failed: Set<URL> = []

    func image(for url: URL?) -> NSImage? {
        guard let url = url else { return nil }
        if let i = images[url] { return i }
        guard !inflight.contains(url), !failed.contains(url),
              url.scheme == "https", url.host?.hasSuffix("githubusercontent.com") == true else { return nil }
        inflight.insert(url)
        Task { @MainActor in
            let result = try? await URLSession.shared.data(from: url)
            self.inflight.remove(url)
            guard let r = result, (r.1 as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: r.0) else {
                self.failed.insert(url)
                return
            }
            self.images[url] = img
            NotificationCenter.default.post(name: Self.loaded, object: nil)
        }
        return nil
    }

    /// Stable colour for a login's initials bubble while the picture loads.
    static func color(for login: String) -> NSColor {
        let palette: [NSColor] = [
            NSColor(srgbRed: 0.55, green: 0.47, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.30, green: 0.70, blue: 0.95, alpha: 1),
            NSColor(srgbRed: 0.95, green: 0.55, blue: 0.40, alpha: 1), NSColor(srgbRed: 0.35, green: 0.75, blue: 0.55, alpha: 1),
            NSColor(srgbRed: 0.90, green: 0.45, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.95, green: 0.72, blue: 0.30, alpha: 1)
        ]
        let sum = login.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    /// Draws one round avatar (picture or initials) into `rect`, with a ring in `ring`.
    static func draw(_ person: GHPullRequest.Person, in rect: NSRect, ring: NSColor?) {
        if let ring = ring {
            ring.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5)).fill()
        }
        let circle = NSBezierPath(ovalIn: rect)
        if let img = shared.image(for: person.avatar) {
            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            color(for: person.login).setFill()
            circle.fill()
            let initial = String(person.login.prefix(1)).uppercased()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: rect.height * 0.46, weight: .bold), .foregroundColor: NSColor.white]
            let s = (initial as NSString).size(withAttributes: attrs)
            (initial as NSString).draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2), withAttributes: attrs)
        }
    }
}

/// Up to three overlapping reviewer avatars, then "+n".
final class ReviewerAvatarGroup: NSView {
    var people: [GHPullRequest.Person] = [] { didSet { needsDisplay = true; toolTip = people.map { "@\($0.login)" }.joined(separator: ", ") } }
    var diameter: CGFloat = 22
    var ring: NSColor = Pal.surfaceRow { didSet { needsDisplay = true } }
    private let maxShown = 3
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(avatarLoaded), name: AvatarCache.loaded, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func avatarLoaded() { needsDisplay = true }

    private var step: CGFloat { diameter - 7 }
    private var extra: Int { max(0, people.count - maxShown) }

    var fittedWidth: CGFloat {
        let n = CGFloat(min(people.count, maxShown))
        guard n > 0 else { return 0 }
        return diameter + (n - 1) * step + (extra > 0 ? step + 6 : 0) + 3
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = (bounds.height - diameter) / 2
        var x: CGFloat = 1.5
        for p in people.prefix(maxShown) {
            AvatarCache.draw(p, in: NSRect(x: x, y: y, width: diameter, height: diameter), ring: ring)
            x += step
        }
        if extra > 0 {
            let r = NSRect(x: x, y: y, width: diameter + 6, height: diameter)
            ring.setFill(); NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: diameter / 2 + 1.5, yRadius: diameter / 2 + 1.5).fill()
            Pal.surfaceStrong.setFill(); NSBezierPath(roundedRect: r, xRadius: diameter / 2, yRadius: diameter / 2).fill()
            let s = "+\(extra)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: Pal.textSecondary]
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
        }
    }
}

// MARK: - Chips & small pieces

/// "✓ CI passing" — compact semantic pill: tinted fill, faint edge, icon + label in the colour.
final class PRStatusChip: NSView {
    private var symbol = "circle"
    private var text = ""
    private var color: NSColor = .gray
    override var isFlipped: Bool { true }
    static let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    func set(symbol s: String, text t: String, color c: NSColor) {
        symbol = s; text = t; color = c
        setAccessibilityLabel(t)
        toolTip = t
        needsDisplay = true
    }

    var fittedWidth: CGFloat { ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + 8 + 14 + 6 + 10 }

    private var labelColor: NSColor { Pal.isDark ? (color.blended(withFraction: 0.25, of: .white) ?? color) : (color.blended(withFraction: 0.35, of: .black) ?? color) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: Radius.s + 1, yRadius: Radius.s + 1)
        color.withAlphaComponent(Pal.isDark ? 0.16 : 0.14).setFill(); path.fill()
        color.withAlphaComponent(0.32).setStroke(); path.lineWidth = 1; path.stroke()
        var x: CGFloat = 8
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))?
            .withSymbolConfiguration(.init(paletteColors: [color])) {
            let s = img.size
            img.draw(in: NSRect(x: x + (14 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        x += 14 + 6
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: labelColor, .paragraphStyle: para]
        let th = ceil(Self.font.ascender - Self.font.descender) + 1
        (text as NSString).draw(in: NSRect(x: x, y: (bounds.height - th) / 2, width: max(0, bounds.width - x - 8), height: th), withAttributes: attrs)
    }
}

/// "💬 4" — comment count in a hairline pill.
final class CommentCount: NSView {
    var count = 0 { didSet { needsDisplay = true; isHidden = count == 0; setAccessibilityLabel("\(count) comments") } }
    override var isFlipped: Bool { true }
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    var fittedWidth: CGFloat { ceil(("\(count)" as NSString).size(withAttributes: [.font: Self.font]).width) + 8 + 14 + 4 + 8 }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.s + 1, yRadius: Radius.s + 1)
        p.border.setStroke(); path.lineWidth = 1; path.stroke()
        if let img = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [p.textSecondary])) {
            let s = img.size
            img.draw(in: NSRect(x: 8, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: p.textSecondary]
        let s = ("\(count)" as NSString).size(withAttributes: attrs)
        ("\(count)" as NSString).draw(at: NSPoint(x: 8 + 14 + 4, y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }
}

/// Rounded tile with the repo's glyph: lavender for your own repos, a warm tone per org.
final class PRRepoTile: NSView {
    private var fill: NSColor = .gray
    private var ink: NSColor = .white
    private var symbol = "arrow.triangle.pull"
    override var isFlipped: Bool { true }

    /// GitHub's mark, if you drop `github-mark.png` into Resources (see README) — otherwise a
    /// pull-request glyph. Zera does not ship GitHub's logo itself.
    static let mark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "github-mark", withExtension: "png"), let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }()

    func set(owner: String, mine: Bool) {
        let tones: [(NSColor, NSColor)] = [
            (NSColor(srgbRed: 1.00, green: 0.87, blue: 0.64, alpha: 1), NSColor(srgbRed: 0.45, green: 0.30, blue: 0.10, alpha: 1)),
            (NSColor(srgbRed: 0.70, green: 0.92, blue: 0.84, alpha: 1), NSColor(srgbRed: 0.10, green: 0.38, blue: 0.30, alpha: 1)),
            (NSColor(srgbRed: 0.72, green: 0.86, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.12, green: 0.30, blue: 0.55, alpha: 1)),
            (NSColor(srgbRed: 1.00, green: 0.80, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.55, green: 0.18, blue: 0.32, alpha: 1))
        ]
        if mine {
            fill = NSColor(srgbRed: 0.86, green: 0.83, blue: 1.00, alpha: 1)
            ink = NSColor(srgbRed: 0.40, green: 0.30, blue: 0.88, alpha: 1)
            symbol = "arrow.triangle.pull"
        } else {
            let t = tones[owner.unicodeScalars.reduce(0) { $0 + Int($1.value) } % tones.count]
            fill = t.0; ink = t.1
            symbol = "square.stack.3d.up.fill"
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width * 0.28, yRadius: bounds.width * 0.28).fill()
        let side = bounds.width * 0.52
        if let m = Self.mark {
            let ink = self.ink
            let tinted = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
                m.draw(in: r); ink.set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: bounds.width * 0.4, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [ink])) {
            let s = img.size
            img.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

// MARK: - Buttons

/// Square bordered icon button (refresh, •••). Can show a spinner in place of its glyph.
final class GHSquareButton: NSButton {
    private var hovered = false { didSet { needsDisplay = true } }
    private let spinner = NSProgressIndicator()
    private var glyph: NSImage?
    var spinning = false {
        didSet {
            guard spinning != oldValue else { return }
            if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            isEnabled = !spinning
            needsDisplay = true
        }
    }

    init(symbol: String, label: String, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        title = ""
        imagePosition = .noImage
        focusRingType = .none
        glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        toolTip = label
        setAccessibilityLabel(label)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        spinner.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5).pressed(isHighlighted && isEnabled), xRadius: Radius.m, yRadius: Radius.m)
        (isHighlighted ? p.surfacePressed : (hovered && isEnabled ? p.surfaceHover : p.surface)).setFill()
        path.fill()
        p.border.setStroke(); path.lineWidth = 1; path.stroke()
        guard !spinning, let g = glyph?.withSymbolConfiguration(.init(paletteColors: [hovered ? p.text : p.textSecondary])) else { return }
        let s = g.size
        g.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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

/// The island's text button, used on every screen: icon + title centred, hover / pressed /
/// disabled / keyboard-focus states.
class PRActionButton: NSButton {
    /// The island's button family (see `Palette.drawButton`): primary is filled with the accent
    /// gradient, secondary a quiet chip, success filled green (Done, Approve), destructive a soft
    /// red (Stop, Delete), warning a soft amber.
    enum Style { case primary, secondary, destructive, warning, success }
    var style: Style { didSet { needsDisplay = true } }
    /// Row hover: the primary button glows a little.
    var emphasized = false { didSet { if emphasized != oldValue { updateGlow() } } }
    private var titleText: String
    private var glyph: NSImage?
    private var hovered = false { didSet { needsDisplay = true; updateGlow() } }
    static let font = Typo.button

    init(_ title: String, style: Style, symbol: String? = nil, target: AnyObject?, action: Selector) {
        self.style = style
        self.titleText = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        self.title = ""
        imagePosition = .noImage
        focusRingType = .none
        wantsLayer = true
        layer?.masksToBounds = false
        if let s = symbol {
            glyph = NSImage(systemSymbolName: s, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        }
        setAccessibilityLabel(title)
        updateGlow()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitleText(_ t: String) { titleText = t; setAccessibilityLabel(t); needsDisplay = true }

    /// Main actions click softly; the rest stay silent so the island isn't noisy.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if style == .primary { SoundService.shared.play(.button) }
        return super.sendAction(action, to: target)
    }

    func setSymbol(_ name: String?) {
        glyph = name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) }
        needsDisplay = true
    }

    var fittedWidth: CGFloat {
        let w = ceil((titleText as NSString).size(withAttributes: [.font: Self.font]).width)
        return w + 36 + (glyph.map { ceil($0.size.width) + 7 } ?? 0)
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    private func updateGlow() {
        // The pill draws its own hover glow; a row's emphasis adds a faint one to the main action.
        guard style == .primary, emphasized, isEnabled else { layer?.shadowOpacity = 0; return }
        layer?.shadowColor = Pal.accent.cgColor
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 8
        layer?.shadowOpacity = 0.35
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let pressed = isHighlighted
        let r = bounds.insetBy(dx: 0.5, dy: 0.5).pressed(pressed && isEnabled)
        let radius = min(Radius.m, r.height / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let tone: ButtonTone
        switch style {
        case .primary: tone = .accent
        case .secondary: tone = .neutral
        case .destructive: tone = .danger
        case .warning: tone = .warning
        case .success: tone = .success
        }
        let color = p.drawButton(path, tone: tone, hovered: hovered || (emphasized && style == .primary), pressed: pressed, enabled: isEnabled)
        if window?.firstResponder === self {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: max(0, radius - 1), yRadius: max(0, radius - 1))
            p.accent.withAlphaComponent(0.9).setStroke(); ring.lineWidth = 2; ring.stroke()
        }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color, .paragraphStyle: para]
        // The gap after the icon only when a title follows, so icon-only buttons stay centred.
        let iconW = glyph.map { ceil($0.size.width) + (titleText.isEmpty ? 0 : 7) } ?? 0
        let textW = min(bounds.width - 24 - iconW, ceil((titleText as NSString).size(withAttributes: attrs).width))
        var x = (bounds.width - iconW - max(0, textW)) / 2
        if let g = glyph?.withSymbolConfiguration(.init(paletteColors: [color])) {
            let s = g.size
            g.draw(in: NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconW
        }
        let th = ceil(Self.font.ascender - Self.font.descender) + 1
        (titleText as NSString).draw(in: NSRect(x: x, y: (bounds.height - th) / 2, width: max(0, textW), height: th), withAttributes: attrs)
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

/// "Author ⌄" — compact filter control; shows the chosen value and a violet edge when active.
final class GitHubFilterButton: NSView {
    var onClick: ((GitHubFilterButton) -> Void)?
    private let base: String
    var value: String? { didSet { needsDisplay = true; setAccessibilityValue(value ?? "Any") } }
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    init(_ title: String) {
        base = title
        super.init(frame: .zero)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var shown: String { value ?? base }
    var fittedWidth: CGFloat {
        let textW: CGFloat = ceil((shown as NSString).size(withAttributes: [.font: Self.font]).width)
        return min(124, textW + 44)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.m, yRadius: Radius.m)
        (hovered ? p.surfaceHover : p.surfaceRow).setFill(); path.fill()
        (value != nil ? p.accentBorder : p.border).setStroke(); path.lineWidth = 1; path.stroke()
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: value != nil ? p.text : p.text(0.85), .paragraphStyle: para]
        let th = ceil(Self.font.ascender - Self.font.descender) + 1
        (shown as NSString).draw(in: NSRect(x: 14, y: (bounds.height - th) / 2, width: max(0, bounds.width - 14 - 30), height: th), withAttributes: attrs)
        if let c = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))?
            .withSymbolConfiguration(.init(paletteColors: [p.textSecondary])) {
            let s = c.size
            c.draw(in: NSRect(x: bounds.width - 12 - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Segmented control

/// [ Open 10 ] [ Review 4 ] [ CI 10 ] [ Approvals 3 ] — one control, equal segments, the
/// selected one in a violet gradient; icons drop out first if the card gets narrow.
final class GitHubSegmentedControl: NSView {
    struct Item {
        let symbol: String      // "" for no icon
        let title: String
        var count: Int
        var tint: NSColor?
        /// Colour of the count badge when the segment is not selected (e.g. green for Running).
        var badgeTint: NSColor? = nil
        /// Show the badge even when the count is 0.
        var showsZero = false
    }
    var items: [Item] { didSet { needsDisplay = true } }
    /// Segments sized to their content (proportionally) instead of equal widths.
    var fitToContent = false { didSet { needsDisplay = true } }
    /// The chosen segment. Changing it glides the indicator over (`setSelected(_:animated:)`).
    var selected = 0 {
        didSet {
            guard selected != oldValue else { return }
            indicator.move(to: slot(selected), animated: true)
            needsDisplay = true
        }
    }
    var onSelect: ((Int) -> Void)?
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private lazy var indicator = SlidingIndicator(view: self)
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private static let font = Typo.chip
    private static let badgeFont = Typo.count

    init(items: [Item]) {
        self.items = items
        super.init(frame: .zero)
        setAccessibilityRole(.tabGroup)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func icon(_ it: Item) -> NSImage? {
        it.symbol.isEmpty ? nil : NSImage(systemSymbolName: it.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    }

    private func hasBadge(_ it: Item) -> Bool { it.count > 0 || it.showsZero }

    /// Width one segment needs: icon · title · badge plus 24 pt of padding.
    private func contentWidth(_ it: Item) -> CGFloat {
        let titleW: CGFloat = ceil((it.title as NSString).size(withAttributes: [.font: Self.font]).width)
        let iconW: CGFloat = icon(it).map { ceil($0.size.width) + 6 } ?? 0
        let badgeW: CGFloat = hasBadge(it) ? badgeWidth(it.count) + 6 : 0
        return iconW + titleW + badgeW + 24
    }

    /// Smallest width that shows every segment in full.
    var preferredWidth: CGFloat { items.reduce(Metrics.segmentInset * 2) { $0 + contentWidth($1) } }

    private func slot(_ i: Int) -> NSRect {
        let inset = Metrics.segmentInset
        let avail = bounds.width - inset * 2
        guard !items.isEmpty else { return .zero }
        let i = min(max(0, i), items.count - 1)
        guard fitToContent else {
            let w = avail / CGFloat(items.count)
            return NSRect(x: inset + CGFloat(i) * w, y: inset, width: w, height: bounds.height - inset * 2)
        }
        let widths = items.map { contentWidth($0) }
        let scale = avail / max(1, widths.reduce(0, +))
        let x = widths.prefix(i).reduce(0, +) * scale
        return NSRect(x: inset + x, y: inset, width: widths[i] * scale, height: bounds.height - inset * 2)
    }

    private func badgeWidth(_ n: Int) -> CGFloat {
        max(18, ceil(("\(n)" as NSString).size(withAttributes: [.font: Self.badgeFont]).width) + 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let radius = Radius.m + 2, inner = Radius.m - 1
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        p.surface.setFill(); outer.fill()
        p.divider.setStroke(); outer.lineWidth = 1; outer.stroke()

        // Hover sits under the indicator; the indicator glides between segments.
        if let h = hoverIndex, h != selected {
            p.surfaceHover.setFill()
            NSBezierPath(roundedRect: slot(h), xRadius: inner, yRadius: inner).fill()
        }
        if !items.isEmpty {
            indicator.settle(at: slot(selected))
            p.drawSegmentIndicator(NSBezierPath(roundedRect: indicator.rect, xRadius: inner, yRadius: inner))
        }

        for (i, it) in items.enumerated() {
            let r = slot(i)
            let on = i == selected
            let textColor = on ? p.text : p.textSecondary
            let titleW = ceil((it.title as NSString).size(withAttributes: [.font: Self.font]).width)
            let bw = hasBadge(it) ? badgeWidth(it.count) : 0
            let icon = self.icon(it)
            let iconW = icon.map { ceil($0.size.width) } ?? 0
            let full = iconW + 6 + titleW + (bw > 0 ? 6 + bw : 0)
            let showIcon = icon != nil && full <= r.width - 16
            let total = (showIcon ? iconW + 6 : 0) + titleW + (bw > 0 ? 6 + bw : 0)
            var x = r.midX - min(total, r.width - 12) / 2
            // Hierarchical, not one flat colour: a filled "checkmark.circle" keeps its check.
            if showIcon, let ic = icon?.withSymbolConfiguration(.init(hierarchicalColor: on ? p.accent : (it.tint ?? p.textSecondary))) {
                let s = ic.size
                ic.draw(in: NSRect(x: x, y: r.midY - s.height / 2, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += iconW + 6
            }
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: textColor, .paragraphStyle: para]
            let th = ceil(Self.font.ascender - Self.font.descender) + 1
            let tw = min(titleW, r.maxX - 6 - x - (bw > 0 ? 6 + bw : 0))
            (it.title as NSString).draw(in: NSRect(x: x, y: r.midY - th / 2, width: max(0, tw), height: th), withAttributes: attrs)
            x += tw + 6
            if bw > 0 {
                let br = NSRect(x: x, y: r.midY - 9, width: bw, height: 18)
                (on ? p.accent.withAlphaComponent(0.18) : (it.badgeTint?.withAlphaComponent(0.2) ?? p.surfaceStrong)).setFill()
                NSBezierPath(roundedRect: br, xRadius: 9, yRadius: 9).fill()
                let s = "\(it.count)" as NSString
                let ba: [NSAttributedString.Key: Any] = [.font: Self.badgeFont,
                                                         .foregroundColor: on ? p.accent : (it.badgeTint ?? p.textSecondary)]
                let sz = s.size(withAttributes: ba)
                s.draw(at: NSPoint(x: br.midX - sz.width / 2, y: br.midY - sz.height / 2), withAttributes: ba)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoverIndex = items.indices.first { NSPointInRect(pt, slot($0)) }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }
    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let i = items.indices.first(where: { NSPointInRect(pt, slot($0)) }) {
            selected = i
            onSelect?(i)
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Zera's speech bubble

/// Lightweight assistant bubble with a little tail pointing back at Zera (bottom-left).
final class ZeraGitHubBubble: NSView {
    var text = "" { didSet { needsDisplay = true; setAccessibilityLabel(text) } }
    /// Tail on the bottom-right instead (Zera stands to the right of the bubble).
    var tailRight = false { didSet { needsDisplay = true } }
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let maxTextWidth: CGFloat = 140
    private static let padX: CGFloat = 12, padY: CGFloat = 8, tail: CGFloat = 7
    override var isFlipped: Bool { true }

    private var textSize: NSSize {
        let r = (text as NSString).boundingRect(with: NSSize(width: Self.maxTextWidth, height: 60),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Self.font])
        let one = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
        return NSSize(width: min(Self.maxTextWidth, one) + 1, height: min(36, ceil(r.height)))
    }
    var fittedSize: NSSize {
        let t = textSize
        return NSSize(width: t.width + Self.padX * 2, height: t.height + Self.padY * 2 + Self.tail)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let body = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: bounds.height - Self.tail - 1)
        let path = NSBezierPath(roundedRect: body, xRadius: 14, yRadius: 14)
        // Tail: a small wedge off the bottom-left edge, towards Zera.
        // Tail x positions: base from a to b, tip at t (mirrored when the tail is on the right).
        let w = bounds.width
        let a: CGFloat = tailRight ? w - 30 : 18, b: CGFloat = tailRight ? w - 18 : 30, t: CGFloat = tailRight ? w - 10 : 10
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: a, y: body.maxY - 1))
        tail.line(to: NSPoint(x: t, y: bounds.height - 0.5))
        tail.line(to: NSPoint(x: b, y: body.maxY - 1))
        tail.close()
        p.surfaceElevated.setFill(); path.fill(); tail.fill()
        p.accentBorder.setStroke(); path.lineWidth = 1; path.stroke()
        // Stroke only the two outer edges of the tail so the seam stays invisible.
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: a, y: body.maxY)); edge.line(to: NSPoint(x: t, y: bounds.height - 0.5)); edge.line(to: NSPoint(x: b, y: body.maxY))
        edge.lineWidth = 1; edge.stroke()
        p.surfaceElevated.setFill(); NSRect(x: min(a, b) + 0.5, y: body.maxY - 1.5, width: abs(b - a) - 1, height: 2).fill()
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: p.text, .paragraphStyle: para]
        (text as NSString).draw(with: NSRect(x: Self.padX, y: Self.padY, width: bounds.width - Self.padX * 2, height: body.height - Self.padY * 2 + 2),
                                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], attributes: attrs, context: nil)
    }
}

// MARK: - Split button

/// [ ↗ Open in Browser | ⌄ ] — primary action plus a menu of related ones.
final class GHSplitButton: NSView {
    var onMain: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    private let title: String
    private let symbol: String
    private var hoverPart: Int? { didSet { if hoverPart != oldValue { needsDisplay = true } } }
    private var pressedPart: Int? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let chevronW: CGFloat = 38

    init(title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    var fittedWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 16 + 7 + 32 + chevronW }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        // The main action as a blue outline pill, split before the ▾ menu part.
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        let label = p.drawButton(path, tone: .accent, hovered: hoverPart != nil, pressed: pressedPart != nil)
        let split = bounds.width - chevronW
        if let h = pressedPart ?? hoverPart {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            p.accent.withAlphaComponent(pressedPart != nil ? 0.18 : 0.10).setFill()
            (h == 0 ? NSRect(x: 0, y: 0, width: split, height: bounds.height) : NSRect(x: split, y: 0, width: chevronW, height: bounds.height)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        p.accent.withAlphaComponent(0.4).setFill()
        NSRect(x: split - 0.5, y: 8, width: 1, height: bounds.height - 16).fill()

        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: label]
        let tw = ceil((title as NSString).size(withAttributes: attrs).width)
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12.5, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [label]))
        let iw = icon.map { ceil($0.size.width) + 7 } ?? 0
        var x = max(12, (split - tw - iw) / 2)
        if let ic = icon {
            let s = ic.size
            ic.draw(in: NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iw
        }
        let th = ceil(Self.font.ascender - Self.font.descender) + 1
        (title as NSString).draw(in: NSRect(x: x, y: (bounds.height - th) / 2, width: min(tw, split - x - 8), height: th), withAttributes: attrs)
        if let c = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))?
            .withSymbolConfiguration(.init(paletteColors: [label])) {
            let s = c.size
            c.draw(in: NSRect(x: split + (chevronW - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func part(at event: NSEvent) -> Int {
        convert(event.locationInWindow, from: nil).x < bounds.width - chevronW ? 0 : 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { hoverPart = part(at: event) }
    override func mouseExited(with event: NSEvent) { hoverPart = nil }
    override func mouseDown(with event: NSEvent) { pressedPart = part(at: event) }
    override func mouseUp(with event: NSEvent) {
        let down = pressedPart
        pressedPart = nil
        guard let d = down, NSPointInRect(convert(event.locationInWindow, from: nil), bounds), part(at: event) == d else { return }
        if d == 0 { onMain?() } else { onMenu?(self) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - State view

/// Empty / loading / error / not-connected: Zera, a line, a smaller line, maybe a button.
final class GHStateView: NSView {
    private let figure = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private(set) var button: PRActionButton?
    override var isFlipped: Bool { true }
    static let height: CGFloat = 140

    override init(frame: NSRect) {
        super.init(frame: frame)
        figure.imageScaling = .scaleProportionallyUpOrDown
        figure.imageAlignment = .alignBottom
        addSubview(figure)
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        subtitle.font = NSFont.systemFont(ofSize: 12.5)
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        addSubview(subtitle)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(pose: String, title t: String, subtitle s: String, loading: Bool = false, button b: PRActionButton? = nil) {
        let p = Pal
        figure.image = SpriteLibrary.shared.sprite(pose)?.image ?? SpriteLibrary.shared.sprite("idle")?.image
        title.stringValue = t; title.textColor = p.text
        subtitle.stringValue = s; subtitle.textColor = p.textSecondary
        spinnerAnimating = loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        button?.removeFromSuperview()
        button = b
        if let b = b { addSubview(b) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let hasButton = button != nil
        let spin: CGFloat = spinnerAnimating ? 22 : 0
        let buttonH: CGFloat = hasButton ? 46 : 0
        // Zera already hangs in the island's header, so the empty state is just words (and a button).
        figure.isHidden = true
        let content: CGFloat = 20 + 4 + spin + 34 + buttonH
        var y = max(0, (bounds.height - content) / 2)
        title.frame = NSRect(x: Space.l, y: y, width: w - Space.l * 2, height: 20)
        y += 24
        spinner.frame = NSRect(x: (w - 16) / 2, y: y, width: 16, height: 16)
        y += spin
        subtitle.frame = NSRect(x: Space.xxl, y: y, width: w - Space.xxl * 2, height: 34)
        y += 34
        if let b = button {
            let bw = max(120, b.fittedWidth)
            b.frame = NSRect(x: (w - bw) / 2, y: y + 12, width: bw, height: 34)
        }
    }

    private var spinnerAnimating = false
}
