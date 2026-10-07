import AppKit

// MARK: - Themes
//
// Every colour on the island, the wings, Tasks and the app opener comes from the chosen theme.
// Seven are built in. More are JSON files in ~/Library/Application Support/Zera/Themes: each one
// starts from a built-in theme ("base") and changes only the colours it names, so a tweak can be
// a single line. Zera watches the folder and picks up saved changes straight away.
//
//   {
//     "name": "Night Owl",
//     "base": "tokyo-night",
//     "colors": { "accent": "#82aaff", "highlight": "#c792ea" }
//   }

/// The colours a theme sets, as "#RRGGBB" or "#RRGGBBAA". A custom theme leaves out whatever it
/// takes from its base.
struct ThemeColors: Codable, Equatable {
    /// The island and the wings: a vertical gradient, top to bottom.
    var glassTop: String?
    var glassBottom: String?
    /// The island's outline and the soft glow around it.
    var edge: String?
    /// Chips, secondary buttons, segmented controls.
    var surface: String?
    var surfaceHover: String?
    /// Pressed and raised states, tracks, popups.
    var surfaceStrong: String?
    /// List rows and tiles.
    var row: String?
    /// Text fields and search boxes.
    var field: String?
    /// Hairline edges around rows, fields and chips.
    var border: String?
    var divider: String?
    var text: String?
    var textSecondary: String?
    var textTertiary: String?
    /// Main actions, the selected tab, toggles, progress.
    var accent: String?
    /// Where the accent's gradient ends (main buttons, the Claude ring).
    var accentDeep: String?
    /// A second colour to pair with the accent (shown in the theme preview).
    var highlight: String?
    /// Text and icons on a filled accent button.
    var onAccent: String?
    var success: String?
    var warning: String?
    var danger: String?
    var info: String?

    static let keys: [WritableKeyPath<ThemeColors, String?>] = [
        \.glassTop, \.glassBottom, \.edge, \.surface, \.surfaceHover, \.surfaceStrong, \.row, \.field,
        \.border, \.divider, \.text, \.textSecondary, \.textTertiary, \.accent, \.accentDeep, \.highlight,
        \.onAccent, \.success, \.warning, \.danger, \.info
    ]

    /// `other`'s colours where it sets one, these everywhere else.
    func merged(with other: ThemeColors) -> ThemeColors {
        var out = self
        for k in Self.keys where other[keyPath: k] != nil { out[keyPath: k] = other[keyPath: k] }
        return out
    }
}

/// A theme file in the Themes folder.
struct ThemeFile: Codable {
    var name: String?
    /// A built-in theme's id ("zera", "tokyo-night", "dracula", "catppuccin-mocha", "nord",
    /// "rose-pine", "gruvbox"). Anything it doesn't name comes from there.
    var base: String?
    var colors: ThemeColors?
    /// Ignored; a note for whoever edits the file.
    var help: String?
}

/// One theme, its colours ready to draw with.
final class ZeraTheme {
    let id: String
    let name: String
    let builtIn: Bool
    /// For a custom theme: the built-in it starts from.
    let baseID: String?
    /// Every colour, as hex (a custom theme already merged over its base).
    let colors: ThemeColors

    let glassTop, glassBottom, edge: NSColor
    let surface, surfaceHover, surfaceStrong, row, field: NSColor
    let border, divider: NSColor
    let text, textSecondary, textTertiary: NSColor
    let accent, accentDeep, highlight, onAccent: NSColor
    let success, warning, danger, info: NSColor

    init(id: String, name: String, builtIn: Bool, baseID: String? = nil, colors: ThemeColors) {
        let full = BuiltInThemes.zera.colors.merged(with: colors)
        // A colour that doesn't parse falls back to Zera's own, so a typo never blanks the island.
        func pick(_ k: WritableKeyPath<ThemeColors, String?>) -> NSColor {
            NSColor(themeHex: full[keyPath: k]) ?? NSColor(themeHex: BuiltInThemes.zera.colors[keyPath: k]) ?? .gray
        }
        self.id = id
        self.name = name
        self.builtIn = builtIn
        self.baseID = baseID
        self.colors = full
        glassTop = pick(\.glassTop); glassBottom = pick(\.glassBottom); edge = pick(\.edge)
        surface = pick(\.surface); surfaceHover = pick(\.surfaceHover); surfaceStrong = pick(\.surfaceStrong)
        row = pick(\.row); field = pick(\.field)
        border = pick(\.border); divider = pick(\.divider)
        text = pick(\.text); textSecondary = pick(\.textSecondary); textTertiary = pick(\.textTertiary)
        accent = pick(\.accent); accentDeep = pick(\.accentDeep); highlight = pick(\.highlight); onAccent = pick(\.onAccent)
        success = pick(\.success); warning = pick(\.warning); danger = pick(\.danger); info = pick(\.info)
    }

    /// A few colours for a swatch strip: glass, accent, highlight, success, danger.
    var swatches: [NSColor] { [glassTop, accent, highlight, success, danger] }
}

// MARK: - The seven built-in themes

enum BuiltInThemes {
    struct Def {
        let id: String
        let name: String
        let colors: ThemeColors
    }

    /// Zera's own: plum-graphite glass, periwinkle actions, peach from her cheeks.
    static let zera = Def(id: "zera", name: "Zera", colors: ThemeColors(
        glassTop: "#17141F", glassBottom: "#0E0C13", edge: "#A094FF73",
        surface: "#1C1925", surfaceHover: "#262131", surfaceStrong: "#2E2839", row: "#201C2A", field: "#141119",
        border: "#FFFFFF17", divider: "#FFFFFF0F",
        text: "#F4F2FA", textSecondary: "#A8A3B8", textTertiary: "#77728A",
        accent: "#9D8CFF", accentDeep: "#7C6BF5", highlight: "#FFAA85", onAccent: "#17122B",
        success: "#5FE0B2", warning: "#F6C560", danger: "#FF6F7D", info: "#7FB2FF"))

    static let tokyoNight = Def(id: "tokyo-night", name: "Tokyo Night", colors: ThemeColors(
        glassTop: "#1A1B26", glassBottom: "#14141D", edge: "#7AA2F766",
        surface: "#1F2335", surfaceHover: "#292E42", surfaceStrong: "#343A55", row: "#1E2132", field: "#16161E",
        border: "#FFFFFF14", divider: "#FFFFFF0D",
        text: "#C0CAF5", textSecondary: "#9AA5CE", textTertiary: "#5F6890",
        accent: "#7AA2F7", accentDeep: "#BB9AF7", highlight: "#FF9E64", onAccent: "#16161E",
        success: "#9ECE6A", warning: "#E0AF68", danger: "#F7768E", info: "#7DCFFF"))

    static let dracula = Def(id: "dracula", name: "Dracula", colors: ThemeColors(
        glassTop: "#282A36", glassBottom: "#1E1F29", edge: "#BD93F966",
        surface: "#303341", surfaceHover: "#3A3D4F", surfaceStrong: "#44475A", row: "#2D2F3D", field: "#21222C",
        border: "#FFFFFF14", divider: "#FFFFFF0D",
        text: "#F8F8F2", textSecondary: "#BFC3D9", textTertiary: "#7A86B6",
        accent: "#BD93F9", accentDeep: "#FF79C6", highlight: "#8BE9FD", onAccent: "#21222C",
        success: "#50FA7B", warning: "#FFB86C", danger: "#FF5555", info: "#8BE9FD"))

    static let catppuccin = Def(id: "catppuccin-mocha", name: "Catppuccin Mocha", colors: ThemeColors(
        glassTop: "#1E1E2E", glassBottom: "#181825", edge: "#CBA6F766",
        surface: "#262637", surfaceHover: "#313244", surfaceStrong: "#45475A", row: "#232334", field: "#181825",
        border: "#FFFFFF14", divider: "#FFFFFF0D",
        text: "#CDD6F4", textSecondary: "#A6ADC8", textTertiary: "#7F849C",
        accent: "#CBA6F7", accentDeep: "#B4BEFE", highlight: "#FAB387", onAccent: "#1E1E2E",
        success: "#A6E3A1", warning: "#F9E2AF", danger: "#F38BA8", info: "#89DCEB"))

    static let nord = Def(id: "nord", name: "Nord", colors: ThemeColors(
        glassTop: "#2E3440", glassBottom: "#272C36", edge: "#88C0D066",
        surface: "#353B48", surfaceHover: "#3B4252", surfaceStrong: "#434C5E", row: "#323844", field: "#272C36",
        border: "#FFFFFF14", divider: "#FFFFFF0D",
        text: "#ECEFF4", textSecondary: "#B6BDCA", textTertiary: "#7B8597",
        accent: "#88C0D0", accentDeep: "#81A1C1", highlight: "#B48EAD", onAccent: "#2E3440",
        success: "#A3BE8C", warning: "#EBCB8B", danger: "#BF616A", info: "#8FBCBB"))

    static let rosePine = Def(id: "rose-pine", name: "Rosé Pine", colors: ThemeColors(
        glassTop: "#1F1D2E", glassBottom: "#191724", edge: "#EBBCBA59",
        surface: "#26233A", surfaceHover: "#312E48", surfaceStrong: "#403D52", row: "#221F33", field: "#191724",
        border: "#FFFFFF14", divider: "#FFFFFF0D",
        text: "#E0DEF4", textSecondary: "#908CAA", textTertiary: "#6E6A86",
        accent: "#EBBCBA", accentDeep: "#EB6F92", highlight: "#C4A7E7", onAccent: "#191724",
        success: "#9CCFD8", warning: "#F6C177", danger: "#EB6F92", info: "#9CCFD8"))

    static let gruvbox = Def(id: "gruvbox", name: "Gruvbox", colors: ThemeColors(
        glassTop: "#282828", glassBottom: "#1D2021", edge: "#FABD2F55",
        surface: "#32302F", surfaceHover: "#3C3836", surfaceStrong: "#504945", row: "#2E2C2B", field: "#1D2021",
        border: "#FFFFFF14", divider: "#FFFFFF0D",
        text: "#EBDBB2", textSecondary: "#BDAE93", textTertiary: "#928374",
        accent: "#FABD2F", accentDeep: "#FE8019", highlight: "#83A598", onAccent: "#1D2021",
        success: "#B8BB26", warning: "#FE8019", danger: "#FB4934", info: "#83A598"))

    static let all: [Def] = [zera, tokyoNight, dracula, catppuccin, nord, rosePine, gruvbox]
}

// MARK: - The store

/// The built-in themes, the custom ones from the Themes folder, and which one is in use.
/// Changing either posts `Palette.changed`, which repaints everything.
final class ThemeStore {
    static let shared = ThemeStore()

    private static let key = "zera.theme"
    /// Custom themes are named "custom:<file name>".
    private static let customPrefix = "custom:"

    let builtIns: [ZeraTheme]
    private(set) var custom: [ZeraTheme] = []
    private(set) var current: ZeraTheme
    /// Theme files that couldn't be read, and why ("Mine.json: line 4 …"), for Settings.
    private(set) var problems: [String] = []
    let folder: URL

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    var all: [ZeraTheme] { builtIns + custom }

    private init() {
        builtIns = BuiltInThemes.all.map { ZeraTheme(id: $0.id, name: $0.name, builtIn: true, colors: $0.colors) }
        current = builtIns[0]
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        loadCustom()
        current = theme(id: UserDefaults.standard.string(forKey: Self.key)) ?? builtIns[0]
        watch()
    }

    func theme(id: String?) -> ZeraTheme? {
        guard let id = id else { return nil }
        return all.first { $0.id == id }
    }

    func select(_ t: ZeraTheme) {
        UserDefaults.standard.set(t.id, forKey: Self.key)
        guard t.id != current.id || t.colors != current.colors else { return }
        let old = current
        current = t
        announce(from: old)
    }

    /// Reads the Themes folder again. A theme in use that was edited repaints; one that was
    /// deleted falls back to Zera's own.
    func reload() {
        let old = current, oldIDs = custom.map { $0.id }
        loadCustom()
        let wanted = UserDefaults.standard.string(forKey: Self.key) ?? current.id
        current = theme(id: wanted) ?? builtIns[0]
        if oldIDs != custom.map({ $0.id }) || old.colors != current.colors { announce(from: old) }
    }

    /// Writes the current theme out as a new custom file (every colour spelled out, so there is
    /// something to tweak), switches to it, and returns where it is.
    @discardableResult
    func makeCustom() -> URL? {
        let base = current.builtIn ? current.id : (current.baseID ?? builtIns[0].id)
        var n = 1
        var url = folder.appendingPathComponent("My \(current.name).json")
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent("My \(current.name) \(n).json")
        }
        let file = ThemeFile(name: url.deletingPathExtension().lastPathComponent, base: base, colors: current.colors,
                             help: "Colours are #RRGGBB or #RRGGBBAA. Delete any line to take that colour from \"base\". Save and Zera repaints.")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(file), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        loadCustom()
        if let t = theme(id: Self.customPrefix + url.lastPathComponent) { select(t) }
        return url
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: Reading the folder

    private func loadCustom() {
        var found: [ZeraTheme] = []
        var trouble: [String] = []
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in files {
            do {
                let file = try JSONDecoder().decode(ThemeFile.self, from: Data(contentsOf: url))
                let base = BuiltInThemes.all.first { $0.id == file.base } ?? BuiltInThemes.zera
                let colors = base.colors.merged(with: file.colors ?? ThemeColors())
                let bad = ThemeColors.keys.filter { k in (file.colors?[keyPath: k]).map { NSColor(themeHex: $0) == nil } ?? false }
                if !bad.isEmpty { trouble.append("\(url.lastPathComponent): \(bad.count) colour\(bad.count == 1 ? "" : "s") aren't #RRGGBB, so they use the base theme's") }
                let name = (file.name?.isEmpty == false ? file.name : nil) ?? url.deletingPathExtension().lastPathComponent
                found.append(ZeraTheme(id: Self.customPrefix + url.lastPathComponent, name: name, builtIn: false,
                                       baseID: base.id, colors: colors))
            } catch {
                trouble.append("\(url.lastPathComponent): not valid theme JSON")
            }
        }
        custom = found
        problems = trouble
    }

    /// Saving a file into the folder (or adding / removing one) reloads, a moment later.
    private func watch() {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.reloadWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.reload() }
            self.reloadWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    /// Repaints every open window (panels that stay alive between openings included), then tells
    /// the screens that rebuild themselves. Deferred, so the row you clicked in Settings finishes
    /// its own click before Settings is rebuilt around it.
    private func announce(from old: ZeraTheme) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for w in NSApp.windows { w.contentView?.adoptTheme(from: old, to: self.current) }
            NotificationCenter.default.post(name: Palette.changed, object: nil)
        }
    }
}

// MARK: - Repainting

extension NSView {
    /// After a theme change: redraw, and move text still in the old theme's text colours to the
    /// new theme's (keeping any transparency it was given).
    func adoptTheme(from old: ZeraTheme, to new: ZeraTheme) {
        let pairs = [(old.text, new.text), (old.textSecondary, new.textSecondary), (old.textTertiary, new.textTertiary)]
        func swap(_ c: NSColor?) -> NSColor? {
            guard let c = c else { return nil }
            for (o, n) in pairs where c.sameRGB(as: o) { return n.withAlphaComponent(c.alphaComponent) }
            return nil
        }
        if let f = self as? NSTextField, let c = swap(f.textColor) { f.textColor = c }
        if let t = self as? NSTextView, let c = swap(t.textColor) { t.textColor = c }
        needsDisplay = true
        subviews.forEach { $0.adoptTheme(from: old, to: new) }
    }
}

// MARK: - Hex colours

extension NSColor {
    /// Same colour, ignoring transparency.
    func sameRGB(as other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.004 && abs(a.greenComponent - b.greenComponent) < 0.004
            && abs(a.blueComponent - b.blueComponent) < 0.004
    }

    /// "#RRGGBB" or "#RRGGBBAA" (the # is optional); nil for anything else.
    convenience init?(themeHex s: String?) {
        guard var h = s?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, h.allSatisfy({ $0.isHexDigit }), let v = UInt64(h, radix: 16) else { return nil }
        let full = h.count == 6 ? (v << 8) | 0xFF : v
        self.init(srgbRed: CGFloat((full >> 24) & 0xFF) / 255, green: CGFloat((full >> 16) & 0xFF) / 255,
                  blue: CGFloat((full >> 8) & 0xFF) / 255, alpha: CGFloat(full & 0xFF) / 255)
    }
}

// MARK: - Picker row

/// One theme in Settings → Appearance: a little preview of its glass and colours, its name, and
/// a check on the one in use.
final class ThemeRow: NSView {
    static let height: CGFloat = 40
    let theme: ZeraTheme
    var selected = false { didSet { needsDisplay = true } }
    var onTap: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(theme: ZeraTheme) {
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(theme.name) theme")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l, yRadius: Radius.l)
        if selected { p.drawSelected(shape) } else {
            (hovered ? p.surfaceHover : p.surfaceRow).setFill(); shape.fill()
            p.border.setStroke(); shape.lineWidth = 1; shape.stroke()
        }
        // The preview: the theme's glass with its accent, highlight, success and danger as dots.
        let chip = NSRect(x: 8, y: (bounds.height - 26) / 2, width: 84, height: 26)
        let cp = NSBezierPath(roundedRect: chip, xRadius: 8, yRadius: 8)
        NSGradient(starting: theme.glassTop, ending: theme.glassBottom)?.draw(in: cp, angle: -90)
        theme.edge.setStroke(); cp.lineWidth = 1; cp.stroke()
        for (i, c) in [theme.accent, theme.highlight, theme.success, theme.danger].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: chip.minX + 9 + CGFloat(i) * 18, y: chip.midY - 5, width: 10, height: 10)).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: selected ? Typo.bodyStrong : Typo.bodyMedium, .foregroundColor: p.text]
        let name = theme.name as NSString
        let ns = name.size(withAttributes: attrs)
        name.draw(at: NSPoint(x: chip.maxX + 12, y: (bounds.height - ns.height) / 2), withAttributes: attrs)
        if selected, let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "In use")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold).applying(.init(paletteColors: [p.onAccent, p.accent]))) {
            let sz = img.size
            img.draw(in: NSRect(x: bounds.maxX - 12 - sz.width, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height),
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
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
