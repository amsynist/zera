import AppKit

// MARK: - Launcher (the default opener look)
//
//  ╭──────────────────────────────────────────╮
//  │ [S] Safari                               │   apps, best first; ↑↓ choose, ⏎ opens
//  │     Running · Productivity               │
//  │ [C] Code                                 │
//  │ …                                        │
//  │ (🔍  Type ">" for commands           ×)  │   the search sits at the bottom
//  ╰──────────────────────────────────────────╯   risen from the bottom edge of the screen
//
// One list above one field. Type to find an app. Type ">" and the list becomes commands
// (Wallpaper, Theme, Lock, Sleep, Quit All, Kill Process, Kill Port and Zera's actions). A
// command with its own list opens it in place: ">wallpaper " turns the card into a strip of
// pictures you move through with ← →, previewed live behind everything and set with ⏎.
// Same data, shortcut and controller as the other looks (`OpenerSurface`).
//
// The flow (a list over a bottom search field, ">" for commands, the wallpaper strip) is inspired
// by Caelestia shell for Hyprland (github.com/caelestia-dots/shell). Written from scratch for
// AppKit in the Signal style; none of its code is used.

private enum LM {
    static let listW: CGFloat = 560
    static let wallW: CGFloat = 920
    static let rowH: CGFloat = 50
    static let rows = 8                       // rows visible at once; the rest scroll
    static let pad: CGFloat = 10
    static let gap: CGFloat = 8               // list → search
    static let searchH: CGFloat = 42
    static let stripH: CGFloat = 156
    static let margin: CGFloat = 40           // room for the glow
    static let radius: CGFloat = 20
    static let dockGap: CGFloat = 10          // floating above a Dock
}

/// Something to run after ">".
struct LauncherCommand {
    enum Kind { case wallpaper, wallpaperFolders, theme, lock, sleep, quitAll, killProcess, killPort, action(QuickAction) }
    /// What you type after ">" ("wallpaper").
    let key: String
    let title: String
    let subtitle: String
    let symbol: String
    let kind: Kind

    /// Opens its own list in place, typed as ">key filter".
    var opensList: Bool {
        switch kind {
        case .wallpaper, .theme, .killProcess, .killPort: return true
        default: return false
        }
    }
    /// Asks for a second ⏎ before it runs.
    var confirms: Bool { if case .quitAll = kind { return true }; return false }
}

/// What the field's text means.
enum LauncherQuery: Equatable {
    case apps(String)
    case commands(String)
    case list(key: String, filter: String)
}

enum LauncherCommands {
    static let all: [LauncherCommand] = [
        LauncherCommand(key: "wallpaper", title: "Wallpaper", subtitle: "Change the desktop picture", symbol: "photo", kind: .wallpaper),
        LauncherCommand(key: "folders", title: "Wallpaper Folders", subtitle: "Choose the folders >wallpaper shows pictures from", symbol: "folder.badge.plus", kind: .wallpaperFolders),
        LauncherCommand(key: "theme", title: "Theme", subtitle: "Change Zera's colours", symbol: "paintpalette", kind: .theme),
        LauncherCommand(key: "lock", title: "Lock", subtitle: "Turn the display off; it asks for your password if your Mac is set to", symbol: "lock", kind: .lock),
        LauncherCommand(key: "sleep", title: "Sleep", subtitle: "Put the Mac to sleep", symbol: "moon", kind: .sleep),
        LauncherCommand(key: "quit", title: "Quit All Apps", subtitle: "Quit every open app for a clean desk", symbol: "sparkles.rectangle.stack", kind: .quitAll),
        LauncherCommand(key: "kill", title: "Kill Process", subtitle: "Stop a running process by name", symbol: "xmark.octagon", kind: .killProcess),
        LauncherCommand(key: "port", title: "Kill Port", subtitle: "Free a port by stopping what listens on it", symbol: "network.slash", kind: .killPort),
    ] + OpenerActions.all.map { a in
        let title = OpenerActions.title(a)
        let subtitle = OpenerActions.subtitle(a).replacingOccurrences(of: "Action · ", with: "").capitalizedFirst
        return LauncherCommand(key: title.lowercased().replacingOccurrences(of: " ", with: "-"), title: title,
                               subtitle: subtitle, symbol: a.symbol, kind: .action(a))
    }

    static func parse(_ text: String) -> LauncherQuery {
        guard text.hasPrefix(">") else { return .apps(text.trimmingCharacters(in: .whitespaces)) }
        let rest = text.dropFirst().drop(while: { $0 == " " })
        if let space = rest.firstIndex(of: " ") {
            let word = rest[..<space].lowercased()
            if let c = all.first(where: { $0.opensList && $0.key == word }) {
                return .list(key: c.key, filter: rest[rest.index(after: space)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return .commands(rest.trimmingCharacters(in: .whitespaces))
    }

    /// Commands for what was typed after ">", best first; all of them, in order, when empty.
    static func matches(_ query: String) -> [(command: LauncherCommand, hits: [Int])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all.map { ($0, []) } }
        return all.compactMap { c -> (LauncherCommand, [Int], Int)? in
            if let m = AppMatcher.match(c.title, q) { return (c, m.hits, m.score + (c.key.hasPrefix(q.lowercased()) ? 200 : 0)) }
            if c.key.hasPrefix(q.lowercased()) { return (c, [], 700) }
            return nil
        }.sorted { $0.2 > $1.2 }.map { ($0.0, $0.1) }
    }
}

/// "Developer Tools" for an app, from its bundle, read once.
private enum LauncherAppInfo {
    private static var cache: [URL: String] = [:]
    static func category(_ app: AppEntry) -> String {
        if let hit = cache[app.url] { return hit }
        var text = ""
        if let raw = Bundle(url: app.url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
           let last = raw.split(separator: ".").last, last != "app-category" {
            text = last.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        if cache.count > 600 { cache.removeAll() }
        cache[app.url] = text
        return text
    }
}

final class LauncherOpenerView: NSView, NSTextFieldDelegate, OpenerSurface {
    var onLaunch: ((AppEntry, Bool) -> Void)?
    var onSearchWeb: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onAction: ((QuickAction) -> Void)?
    var onFinish: ((String?) -> Void)?
    var onQuitAll: (([NSRunningApplication]) -> Void)?
    var band: CGFloat = 32
    var ropeX: CGFloat = 0
    var searchField: NSTextField { field }

    /// Flush with the bottom edge of the screen, or floating just above a Dock.
    var flush = true { didSet { if flush != oldValue { needsLayout = true } } }

    // The desktop is only touched through these, so tests can stand in for it.
    var wallpaperSource: () -> [WallpaperEntry] = { WallpaperLibrary.scan() }
    var currentWallpaper: () -> URL? = { WallpaperLibrary.current }
    var previewWallpaper: (URL) -> Void = { WallpaperPreview.shared.show($0) }
    var endWallpaperPreview: (_ applied: Bool) -> Void = { WallpaperPreview.shared.end(settle: $0) }
    var applyWallpaper: (URL) -> Bool = { WallpaperLibrary.apply($0) }
    var runTool: (_ path: String, _ arguments: [String]) -> Void = { path, arguments in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        try? p.run()
    }

    private let card = OpenerGlass()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let strip = WallpaperStripView()
    private let fieldBox = SignalInputView()
    private let glyph = NSImageView()
    private let field = NSTextField()
    private let clear = LauncherClearButton()

    private enum Entry {
        case app(AppEntry, hits: [Int], running: Bool)
        case command(LauncherCommand, hits: [Int])
        case theme(ZeraTheme)
        case process(ProcessEntry)
        case port(PortEntry)
        case web(String)
        case note(String)
        var chooses: Bool { if case .note = self { return false }; return true }
    }
    private var entries: [Entry] = []
    private var rows: [LauncherRowView] = []
    private var selected = 0
    /// A destructive row waiting for its second ⏎.
    private var armed: Int?

    private var showingWallpapers = false
    private var wallpapers: [WallpaperEntry]?
    private var shownWallpapers: [WallpaperEntry] = []
    private var wallpaperScan = UUID()
    private var previewWork: DispatchWorkItem?
    private var previewed = false
    private var processes: [ProcessEntry]?
    private var ports: [PortEntry]?
    private var toolScan = UUID()

    // The card's size and how far it has still to rise; eased between states.
    private struct Shape { var w: CGFloat, h: CGFloat, rise: CGFloat }
    private var shape = Shape(w: LM.listW, h: 200, rise: 0)
    private var morphFrom = Shape(w: LM.listW, h: 200, rise: 0)
    private var morphTo = Shape(w: LM.listW, h: 200, rise: 0)
    private var morphStart: TimeInterval = 0
    private var morphDuration: TimeInterval = 0
    private var morphTimer: Timer?
    private var morphDone: (() -> Void)?

    // For tests and recordings.
    var visibleTitles: [String] { rows.map(\.plainTitle) }
    var selectedTitle: String? { showingWallpapers ? shownWallpapers[safe: strip.selected]?.name : rows[safe: selected]?.plainTitle }
    var isShowingWallpapers: Bool { showingWallpapers }
    var cardSize: NSSize { NSSize(width: morphTo.w, height: morphTo.h) }
    func previewType(_ text: String) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    func previewMove(_ by: Int) { move(by) }
    func previewActivate() { activate() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The panel that holds every state of the card: the widest (wallpapers) and the tallest (a full list).
    static func panelSize(available: NSSize) -> NSSize {
        let w = min(LM.wallW, available.width - 80) + LM.margin * 2
        let h = LM.pad * 2 + CGFloat(LM.rows) * LM.rowH + LM.gap + LM.searchH + LM.margin + LM.dockGap
        return NSSize(width: w, height: min(h, available.height - 80))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        card.radius = LM.radius
        card.lineWidth = 1
        card.glow = 0.3
        addSubview(card)

        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.documentView = doc
        card.addSubview(scroll)

        strip.isHidden = true
        strip.onPick = { [weak self] i in self?.pickWallpaper(i) }
        strip.onChoose = { [weak self] in self?.activate() }
        card.addSubview(strip)

        fieldBox.radius = LM.searchH / 2
        card.addSubview(fieldBox)
        glyph.imageScaling = .scaleNone
        card.addSubview(glyph)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = ZFont.ui(ofSize: 15)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("Search apps, or type > for commands")
        card.addSubview(field)
        clear.isHidden = true
        clear.onClick = { [weak self] in
            guard let self else { return }
            self.previewType("")
            self.window?.makeFirstResponder(self.field)
        }
        card.addSubview(clear)

        setAccessibilityRole(.group)
        setAccessibilityLabel("App launcher")
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { morphTimer?.invalidate(); previewWork?.cancel() }

    private func applyTheme() {
        card.fill = Neon.fillBottom
        card.edge = Neon.edge.withAlphaComponent(0.55)
        card.needsDisplay = true
        fieldBox.needsDisplay = true
        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [Neon.textDim])))
        field.textColor = Neon.text
        field.placeholderAttributedString = NSAttributedString(string: "Type \">\" for commands", attributes: [
            .foregroundColor: Neon.textFaint, .font: ZFont.ui(ofSize: 15)])
        clear.needsDisplay = true
        strip.applyTheme()
        rows.forEach { $0.needsDisplay = true }
    }

    // MARK: Layout

    private var contentHeight: CGFloat {
        showingWallpapers ? LM.stripH : CGFloat(max(1, min(LM.rows, entries.count))) * LM.rowH
    }
    private var targetShape: Shape {
        let w = showingWallpapers ? min(LM.wallW, bounds.width - LM.margin * 2) : min(LM.listW, bounds.width - LM.margin * 2)
        let roomy = bounds.height - LM.margin - LM.dockGap
        return Shape(w: w, h: min(roomy, LM.pad * 2 + contentHeight + LM.gap + LM.searchH), rise: 0)
    }

    override func layout() {
        super.layout()
        if morphTimer == nil { shape = targetShape; morphTo = shape }
        layoutCard()
    }

    private func layoutCard() {
        let bottom = flush ? 0 : LM.dockGap
        // Flush: the card runs past the bottom of its window, so its lower corners are the screen's edge.
        let under = flush ? LM.radius + 6 : 0
        let x = ((bounds.width - shape.w) / 2).rounded()
        let y = (bounds.height - bottom - shape.h + shape.rise).rounded()
        card.frame = NSRect(x: x, y: y, width: shape.w.rounded(), height: (shape.h + under).rounded())
        let inner = NSRect(x: LM.pad, y: LM.pad, width: card.bounds.width - LM.pad * 2, height: max(0, shape.h - LM.pad * 2 - LM.gap - LM.searchH))
        scroll.frame = inner
        strip.frame = inner
        doc.frame = NSRect(x: 0, y: 0, width: inner.width, height: max(inner.height, CGFloat(rows.count) * LM.rowH))
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * LM.rowH, width: inner.width, height: LM.rowH)
        }
        let box = NSRect(x: LM.pad, y: shape.h - LM.pad - LM.searchH, width: card.bounds.width - LM.pad * 2, height: LM.searchH)
        fieldBox.frame = box
        glyph.frame = NSRect(x: box.minX + 12, y: box.midY - 9, width: 18, height: 18)
        clear.frame = NSRect(x: box.maxX - 34, y: box.midY - 12, width: 24, height: 24)
        let fh = ceil(field.font?.boundingRectForFont.height ?? 20)
        field.frame = NSRect(x: box.minX + 38, y: (box.midY - fh / 2).rounded(), width: box.width - 38 - 40, height: fh)
    }

    /// Eases the card from where it is to `to`. Reduce Motion: it is simply there.
    private func morph(to: Shape, duration: TimeInterval, done: (() -> Void)? = nil) {
        morphTimer?.invalidate(); morphTimer = nil
        let pending = morphDone
        morphDone = nil
        pending?()
        morphTo = to
        let d = Motion.duration(duration)
        guard d > 0, window != nil else {
            shape = to
            layoutCard()
            done?()
            return
        }
        morphFrom = shape
        morphStart = CACurrentMediaTime()
        morphDuration = d
        morphDone = done
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.morphStep() }
        RunLoop.main.add(t, forMode: .common)
        morphTimer = t
    }

    private func morphStep() {
        let p = min(1, (CACurrentMediaTime() - morphStart) / morphDuration)
        let e = CGFloat(1 - pow(1 - p, 3))
        shape = Shape(w: morphFrom.w + (morphTo.w - morphFrom.w) * e,
                      h: morphFrom.h + (morphTo.h - morphFrom.h) * e,
                      rise: morphFrom.rise + (morphTo.rise - morphFrom.rise) * e)
        layoutCard()
        guard p >= 1 else { return }
        morphTimer?.invalidate(); morphTimer = nil
        let done = morphDone
        morphDone = nil
        done?()
    }

    // MARK: Data

    func prepare() {
        applyTheme()
        leaveWallpapers()
        wallpapers = nil
        processes = nil
        ports = nil
        toolScan = UUID()
        wallpaperScan = UUID()
        armed = nil
        selected = 0
        field.stringValue = ""
        clear.isHidden = true
        card.alphaValue = 1
        needsLayout = true
        layoutSubtreeIfNeeded()
        evaluate(animated: false)
    }

    func reload() { evaluate(animated: true, keepSelection: true) }

    /// Reads the field and shows what it asks for.
    private func evaluate(animated: Bool, keepSelection: Bool = false) {
        let text = field.stringValue
        clear.isHidden = text.isEmpty
        if !keepSelection { selected = 0 }
        armed = nil
        var wall = false
        switch LauncherCommands.parse(text) {
        case .apps(let q):
            let found = AppCatalog.shared.results(for: q, runningFirst: AppOpenerSettings.runningFirst, limit: q.isEmpty ? 40 : 24)
            entries = found.map { .app($0.app, hits: $0.hits, running: $0.running) }
            if entries.isEmpty { entries = q.isEmpty ? [.note("Looking for your apps…")] : [.web(q)] }
        case .commands(let q):
            entries = LauncherCommands.matches(q).map { .command($0.command, hits: $0.hits) }
            if entries.isEmpty { entries = [.note("No command called “\(q)”.")] }
        case .list(let key, let filter):
            switch key {
            case "wallpaper": wall = loadWallpapers(filter)
            case "theme":
                let all = ThemeStore.shared.all
                let shown = filter.isEmpty ? all : all.filter { AppMatcher.match($0.name, filter) != nil }
                entries = shown.isEmpty ? [.note("No theme called “\(filter)”.")] : shown.map { .theme($0) }
            case "kill": loadProcesses(filter)
            default: loadPorts(filter)
            }
        }
        if wall {
            enterWallpapers()
        } else {
            leaveWallpapers()
            selected = min(selected, max(0, entries.count - 1))
            rebuildRows()
        }
        let to = targetShape
        if animated { morph(to: to, duration: 0.2) } else { morph(to: to, duration: 0) }
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = entries.enumerated().map { i, entry in
            let row = LauncherRowView(frame: .zero)
            configure(row, entry, index: i)
            row.isSelected = i == selected && entry.chooses
            row.onClick = { [weak self] in
                guard let self else { return }
                self.select(i)
                self.activate()
            }
            doc.addSubview(row)
            return row
        }
        layoutCard()
        scrollToSelected()
    }

    private func configure(_ row: LauncherRowView, _ entry: Entry, index: Int) {
        row.icon = nil; row.symbol = nil; row.swatch = nil; row.trailing = ""; row.warns = false; row.muted = false
        switch entry {
        case .app(let app, let hits, let running):
            row.icon = AppCatalog.shared.icon(app)
            row.title = highlighted(app.name, hits, size: 13.5, weight: .medium)
            let kind = LauncherAppInfo.category(app)
            row.subtitle = (running ? "Running · " : "") + (kind.isEmpty ? app.folder : kind)
        case .command(let c, let hits):
            row.symbol = c.symbol
            row.title = highlighted(c.title, hits, size: 13.5, weight: .medium)
            row.subtitle = c.subtitle
            row.trailing = ">" + c.key
            if armed == index {
                row.warns = true
                row.subtitle = "Press ⏎ again to quit \(quitTargets.count) app\(quitTargets.count == 1 ? "" : "s")"
            }
        case .theme(let t):
            row.swatch = [t.accent, t.accentDeep, t.glassBottom]
            row.title = highlighted(t.name, [], size: 13.5, weight: .medium)
            row.subtitle = t.id == ThemeStore.shared.current.id ? "In use" : (t.builtIn ? "Built in" : "Yours")
        case .process(let p):
            row.symbol = "cpu"
            row.title = highlighted(p.name, [], size: 13.5, weight: .medium)
            row.subtitle = armed == index ? "Press ⏎ again to stop it" : p.path
            row.warns = armed == index
            row.trailing = String(format: "%.0f%%  ", p.cpu) + ProcessTools.memory(p.memoryKB)
        case .port(let p):
            row.symbol = "network"
            row.title = highlighted(":\(p.port)", [], size: 13.5, weight: .medium)
            row.subtitle = armed == index ? "Press ⏎ again to stop \(p.command)" : "\(p.command) · pid \(p.pid) · \(p.address)"
            row.warns = armed == index
        case .web(let q):
            row.symbol = "globe"
            row.title = highlighted("Search the web for “\(q)”", [], size: 13.5, weight: .medium)
            row.subtitle = "Nothing on this Mac is called that"
        case .note(let text):
            row.muted = true
            row.title = NSAttributedString(string: text, attributes: [.font: ZFont.ui(ofSize: 13), .foregroundColor: Neon.textDim])
            row.subtitle = ""
        }
        row.needsDisplay = true
    }

    private func select(_ i: Int) {
        guard entries.indices.contains(i), i != selected || armed != nil else { return }
        let old = selected
        selected = i
        if let was = armed {
            armed = nil
            if let row = rows[safe: was], let entry = entries[safe: was] { configure(row, entry, index: was) }
        }
        rows[safe: old]?.isSelected = false
        rows[safe: i]?.isSelected = entries[i].chooses
        scrollToSelected()
    }

    private func scrollToSelected() {
        guard let row = rows[safe: selected] else { return }
        doc.scrollToVisible(row.frame)
    }

    private func move(_ by: Int) {
        if showingWallpapers { pickWallpaper(strip.selected + by); return }
        guard !entries.isEmpty else { return }
        let next = max(0, min(entries.count - 1, selected + by))
        guard next != selected else { return }
        SoundService.shared.play(.openerTick)
        select(next)
    }

    // MARK: Wallpapers

    /// True when there are pictures to show for ">wallpaper filter".
    private func loadWallpapers(_ filter: String) -> Bool {
        guard let all = wallpapers else {
            entries = [.note("Looking for pictures…")]
            let id = UUID()
            wallpaperScan = id
            let source = wallpaperSource
            DispatchQueue.global(qos: .userInitiated).async {
                let found = source()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.wallpaperScan == id else { return }
                    self.wallpapers = found
                    self.evaluate(animated: true)
                }
            }
            return false
        }
        let shown = WallpaperLibrary.filter(all, filter)
        guard !shown.isEmpty else {
            let empty = WallpaperLibrary.folders.isEmpty
                ? "No pictures yet. Put some in \(WallpaperLibrary.tilde(WallpaperLibrary.defaultFolder)), or run >folders."
                : "No pictures in your wallpaper folders. Run >folders to add another."
            entries = [.note(all.isEmpty ? empty : "No picture called “\(filter)”.")]
            return false
        }
        shownWallpapers = shown
        return true
    }

    private func enterWallpapers() {
        let fresh = !showingWallpapers
        showingWallpapers = true
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        scroll.isHidden = true
        strip.isHidden = false
        var start = 0
        if fresh, let now = currentWallpaper()?.standardizedFileURL.path,
           let at = shownWallpapers.firstIndex(where: { $0.url.standardizedFileURL.path == now }) { start = at }
        else if !fresh { start = min(strip.selected, shownWallpapers.count - 1) }
        strip.show(shownWallpapers, selected: start)
        // A filter that moves the choice is a move like any other: show it.
        if !fresh { schedulePreview() }
    }

    private func leaveWallpapers() {
        guard showingWallpapers else { return }
        showingWallpapers = false
        previewWork?.cancel(); previewWork = nil
        strip.isHidden = true
        scroll.isHidden = false
        if previewed { previewed = false; endWallpaperPreview(false) }
    }

    private func pickWallpaper(_ i: Int) {
        let next = max(0, min(shownWallpapers.count - 1, i))
        guard next != strip.selected else { return }
        SoundService.shared.play(.openerTick)
        strip.setSelected(next, animated: true)
        schedulePreview()
    }

    /// The desktop follows the strip once the choice rests for a moment (not on every key repeat).
    private func schedulePreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.showingWallpapers, let entry = self.shownWallpapers[safe: self.strip.selected] else { return }
            self.previewed = true
            self.previewWallpaper(entry.url)
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    // MARK: Processes and ports

    private func loadProcesses(_ filter: String) {
        guard let all = processes else {
            entries = [.note("Listing processes…")]
            let id = UUID()
            toolScan = id
            DispatchQueue.global(qos: .userInitiated).async {
                let found = ProcessTools.processes()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.toolScan == id else { return }
                    self.processes = found
                    self.evaluate(animated: true)
                }
            }
            return
        }
        let q = filter.lowercased()
        let shown = (q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }).prefix(60)
        entries = shown.isEmpty ? [.note("No process called “\(filter)”.")] : shown.map { .process($0) }
    }

    private func loadPorts(_ filter: String) {
        guard let all = ports else {
            entries = [.note("Listing ports…")]
            let id = UUID()
            toolScan = id
            DispatchQueue.global(qos: .userInitiated).async {
                let found = ProcessTools.listeningPorts()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.toolScan == id else { return }
                    self.ports = found
                    self.evaluate(animated: true)
                }
            }
            return
        }
        let q = filter.lowercased()
        let shown = q.isEmpty ? all : all.filter { String($0.port).hasPrefix(q) || $0.command.lowercased().contains(q) }
        entries = shown.isEmpty ? [.note(all.isEmpty ? "Nothing is listening on a port." : "Nothing on “\(filter)”.")] : shown.map { .port($0) }
    }

    private var quitTargets: [NSRunningApplication] {
        let keep = AppOpenerSettings.keepRunning
        return AppTools.quitCandidates().filter { !keep.contains(AppTools.keepKey($0)) }
    }

    // MARK: Running the choice

    private func activate() {
        if showingWallpapers {
            guard let entry = shownWallpapers[safe: strip.selected] else { return }
            previewWork?.cancel(); previewWork = nil
            // Bring the picture up behind the launcher first, so the swap underneath is never seen.
            if !previewed { previewWallpaper(entry.url) }
            let ok = applyWallpaper(entry.url)
            previewed = false
            endWallpaperPreview(ok)
            SoundService.shared.play(.openerLaunch)
            onFinish?(ok ? nil : "macOS wouldn’t change the wallpaper")
            return
        }
        guard let entry = entries[safe: selected] else { return }
        switch entry {
        case .app(let app, _, _): onLaunch?(app, false)
        case .web(let q): onSearchWeb?(q)
        case .note: break
        case .theme(let t):
            ThemeStore.shared.select(t)
            SoundService.shared.play(.openerLaunch)
            onFinish?("\(t.name) it is ✨")
        case .process(let p): stop(pid: p.pid, name: p.name)
        case .port(let p): stop(pid: p.pid, name: "\(p.command) on :\(p.port)")
        case .command(let c, _): run(c)
        }
    }

    private func run(_ c: LauncherCommand) {
        if c.opensList { previewType(">\(c.key) "); moveCaretToEnd(); return }
        switch c.kind {
        case .quitAll:
            let apps = quitTargets
            guard !apps.isEmpty else { onFinish?("nothing else is open ✨"); return }
            guard armed == selected else { arm(); return }
            onQuitAll?(apps)
        case .lock:
            onFinish?(nil)
            runTool("/usr/bin/pmset", ["displaysleepnow"])
        case .sleep:
            onFinish?(nil)
            let tool = runTool
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tool("/usr/bin/pmset", ["sleepnow"]) }
        case .action(let a): onAction?(a)
        case .wallpaperFolders:
            let say = onFinish
            onFinish?(nil)
            // After the launcher has gone down, so the picker is not behind it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                WallpaperLibrary.chooseFolders { added in
                    if added > 0 { say?("wallpapers come from \(added == 1 ? "that folder" : "those folders") now ✨") }
                }
            }
        case .wallpaper, .theme, .killProcess, .killPort: break
        }
    }

    /// The first ⏎ on something that cannot be undone only asks; the second does it.
    private func arm() {
        armed = selected
        SoundService.shared.play(.openerTick)
        if let row = rows[safe: selected], let entry = entries[safe: selected] { configure(row, entry, index: selected) }
    }

    private func stop(pid: Int32, name: String) {
        guard armed == selected else { arm(); return }
        switch ProcessTools.kill(pid, force: false) {
        case .done: onFinish?("stopped \(name)")
        case .gone: onFinish?("\(name) had already stopped")
        case .notAllowed: onFinish?("macOS wouldn’t let me stop \(name)")
        }
    }

    private func moveCaretToEnd() {
        guard let editor = window?.fieldEditor(false, for: field) as? NSTextView, window?.firstResponder === editor else { return }
        editor.setSelectedRange(NSRange(location: (field.stringValue as NSString).length, length: 0))
    }

    // MARK: Keys

    func controlTextDidChange(_ obj: Notification) { evaluate(animated: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): if showingWallpapers { return true }; move(1); return true
        case #selector(NSResponder.moveUp(_:)): if showingWallpapers { return true }; move(-1); return true
        case #selector(NSResponder.moveRight(_:)):
            guard showingWallpapers else { return false }
            move(1); return true
        case #selector(NSResponder.moveLeft(_:)):
            guard showingWallpapers else { return false }
            move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activate(); return true
        case #selector(NSResponder.insertTab(_:)):
            // ⇥ completes the chosen command into the field.
            if case .command(let c, _)? = entries[safe: selected], !showingWallpapers {
                previewType(">\(c.key)" + (c.opensList ? " " : ""))
                moveCaretToEnd()
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)): return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // ⌘⏎: show the chosen app in Finder.
        if mods == .command, event.keyCode == 36, case .app(let app, _, _)? = entries[safe: selected], !showingWallpapers {
            onLaunch?(app, true)
            return true
        }
        // ⌃N / ⌃P move like ↓ / ↑.
        if mods == .control, event.keyCode == 45 { move(1); return true }
        if mods == .control, event.keyCode == 35 { move(-1); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard showingWallpapers else { super.scrollWheel(with: event); return }
        strip.scrollWheel(with: event)
    }

    // A click beside the card sends it back down.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    // MARK: Coming and going

    func animateIn() {
        window?.makeFirstResponder(field)
        let to = targetShape
        shape = Shape(w: to.w, h: to.h, rise: to.h + LM.dockGap + 12)
        layoutCard()
        card.alphaValue = Motion.reduced ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(0.16)
            card.animator().alphaValue = 1
        }
        morph(to: to, duration: 0.26)
    }

    func animateOut(_ done: @escaping () -> Void) {
        leaveWallpapers()
        toolScan = UUID()
        wallpaperScan = UUID()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(0.18)
            card.animator().alphaValue = 0
        }
        morph(to: Shape(w: shape.w, h: shape.h, rise: shape.h + LM.dockGap + 12), duration: 0.22, done: done)
    }

    /// The chosen row lights once, then the app opens.
    func toss(_ app: AppEntry, _ done: @escaping () -> Void) {
        guard let row = rows[safe: selected], !Motion.reduced else { done(); return }
        row.flash()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: done)
    }
}

// MARK: - Rows

/// One line of the launcher: an icon, a name, a quieter line under it.
final class LauncherRowView: NSView {
    var icon: NSImage?
    var symbol: String?
    /// A theme's colours, in place of an icon.
    var swatch: [NSColor]?
    var title = NSAttributedString()
    var subtitle = ""
    var trailing = ""
    /// The subtitle is a warning ("Press ⏎ again…").
    var warns = false
    /// A note, not a choice.
    var muted = false
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    private var flashing = false
    var plainTitle: String { title.string }

    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityLabel() -> String? { subtitle.isEmpty ? title.string : "\(title.string), \(subtitle)" }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if !muted, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    func flash() {
        flashing = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.flashing = false
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        if isSelected {
            let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 2), xRadius: 13, yRadius: 13)
            if flashing { Neon.accent.withAlphaComponent(0.3).setFill(); pill.fill() }
            p.drawSelected(pill)
        }
        if muted {
            let size = title.size()
            title.draw(at: NSPoint(x: 16, y: (bounds.height - size.height) / 2))
            return
        }
        let box = NSRect(x: 12, y: (bounds.height - 30) / 2, width: 30, height: 30)
        if let icon {
            icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                      hints: [.interpolation: NSImageInterpolation.high])
        } else if let swatch {
            let w = box.width / CGFloat(swatch.count)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 4), xRadius: 6, yRadius: 6).addClip()
            for (i, c) in swatch.enumerated() {
                c.setFill()
                NSRect(x: box.minX + CGFloat(i) * w, y: box.minY, width: w + 1, height: box.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            Neon.divider.setStroke()
            let rim = NSBezierPath(roundedRect: box.insetBy(dx: 1.5, dy: 4.5), xRadius: 6, yRadius: 6)
            rim.lineWidth = 1; rim.stroke()
        } else if let symbol {
            Neon.symbol(symbol, in: box, size: 16, weight: .medium, color: isSelected ? Neon.accent : Neon.text.withAlphaComponent(0.86))
        }
        var right = bounds.width - 14
        if !trailing.isEmpty {
            let t = NSAttributedString(string: trailing, attributes: [.font: ZFont.mono(ofSize: 10.5, weight: .medium), .foregroundColor: Neon.textFaint])
            let size = t.size()
            t.draw(at: NSPoint(x: right - size.width, y: (bounds.height - size.height) / 2))
            right -= size.width + 12
        }
        let x: CGFloat = 54
        let width = max(40, right - x)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let name = NSMutableAttributedString(attributedString: title)
        name.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: name.length))
        let sub = NSAttributedString(string: subtitle, attributes: [
            .font: ZFont.ui(ofSize: 11.5), .foregroundColor: warns ? Neon.warning : Neon.textDim, .paragraphStyle: para])
        let nh = ceil(name.size().height), sh = subtitle.isEmpty ? 0 : ceil(sub.size().height)
        let top = ((bounds.height - nh - sh - (sh > 0 ? 1 : 0)) / 2).rounded()
        name.draw(with: NSRect(x: x, y: top, width: width, height: nh), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if sh > 0 {
            sub.draw(with: NSRect(x: x, y: top + nh + 1, width: width, height: sh), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

/// The × at the end of the search field: clears what was typed.
final class LauncherClearButton: NSView {
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Clear")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        Neon.symbol("xmark", in: bounds, size: 10.5, weight: .bold, color: Neon.textDim)
    }
}

// MARK: - The wallpaper strip

/// Pictures side by side, the chosen one in the middle and a little larger; ← → (or a click, or
/// the scroll wheel) moves along. Only the few tiles on screen exist at any time.
final class WallpaperStripView: NSView {
    var onPick: ((Int) -> Void)?
    var onChoose: (() -> Void)?
    private(set) var selected = 0
    private var entries: [WallpaperEntry] = []
    private var tiles: [Int: WallpaperTile] = [:]
    private var wheel: CGFloat = 0
    private static let tile = NSSize(width: 176, height: 124)      // picture 176 × 104, name under it
    private static let step: CGFloat = 192
    private static let reach = 3                                   // tiles kept each side of the chosen one

    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityRole(.list)
        setAccessibilityLabel("Wallpapers")
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() { tiles.values.forEach { $0.applyTheme() } }

    func show(_ list: [WallpaperEntry], selected index: Int) {
        tiles.values.forEach { $0.removeFromSuperview() }
        tiles = [:]
        entries = list
        selected = max(0, min(list.count - 1, index))
        place(around: selected, animated: false)
    }

    func setSelected(_ index: Int, animated: Bool) {
        let old = selected
        selected = max(0, min(entries.count - 1, index))
        guard selected != old else { return }
        // New tiles start where they would have been, then everything slides together.
        for i in range(selected) where tiles[i] == nil { addTile(i, around: old) }
        place(around: selected, animated: animated)
    }

    private func range(_ centre: Int) -> ClosedRange<Int> {
        guard !entries.isEmpty else { return 0...0 }
        return max(0, centre - Self.reach)...min(entries.count - 1, centre + Self.reach)
    }

    private func frame(for i: Int, around centre: Int) -> NSRect {
        let chosen = i == centre
        let scale: CGFloat = chosen ? 1.16 : 1
        let size = NSSize(width: (Self.tile.width * scale).rounded(), height: (Self.tile.height * scale).rounded())
        let cx = bounds.midX + CGFloat(i - centre) * Self.step + (i == centre ? 0 : (i < centre ? -14 : 14))
        return NSRect(x: (cx - size.width / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    private func addTile(_ i: Int, around centre: Int) {
        guard entries.indices.contains(i) else { return }
        let tile = WallpaperTile(entry: entries[i])
        tile.frame = frame(for: i, around: centre)
        tile.alphaValue = 0
        tile.onClick = { [weak self] in
            guard let self else { return }
            if i == self.selected { self.onChoose?() } else { self.onPick?(i) }
        }
        addSubview(tile)
        tiles[i] = tile
    }

    private func place(around centre: Int, animated: Bool) {
        let keep = range(centre)
        for i in keep where tiles[i] == nil { addTile(i, around: centre) }
        let move = {
            for (i, tile) in self.tiles {
                let target = animated ? tile.animator() : tile
                target.frame = self.frame(for: i, around: centre)
                let far = abs(i - centre)
                target.alphaValue = keep.contains(i) ? (far == 0 ? 1 : (far == 1 ? 0.92 : (far == 2 ? 0.7 : 0.35))) : 0
                tile.isChosen = i == centre
            }
        }
        if animated, !Motion.reduced {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                move()
            }, completionHandler: { [weak self] in self?.prune() })
        } else {
            move()
            prune()
        }
    }

    private func prune() {
        let keep = range(selected)
        for (i, tile) in tiles where !keep.contains(i) {
            tile.removeFromSuperview()
            tiles[i] = nil
        }
    }

    override func layout() {
        super.layout()
        guard !entries.isEmpty else { return }
        for (i, tile) in tiles { tile.frame = frame(for: i, around: selected) }
    }

    override func scrollWheel(with event: NSEvent) {
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        wheel += event.hasPreciseScrollingDeltas ? d : d * 12
        let notch: CGFloat = 36
        guard abs(wheel) >= notch else { return }
        let steps = Int(wheel / notch)
        wheel -= CGFloat(steps) * notch
        onPick?(selected - steps)
    }
}

/// One picture in the strip, with its name under it.
final class WallpaperTile: NSView {
    let entry: WallpaperEntry
    var onClick: (() -> Void)?
    var isChosen = false { didSet { if isChosen != oldValue { restyle() } } }
    private let picture = CALayer()
    private let label = NSTextField(labelWithString: "")
    private static let labelH: CGFloat = 20

    override var isFlipped: Bool { true }

    init(entry: WallpaperEntry) {
        self.entry = entry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.cornerRadius = 10
        picture.cornerCurve = .continuous
        picture.borderWidth = 1
        layer?.addSublayer(picture)
        label.stringValue = entry.name
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.name)
        applyTheme()
        if let hit = WallpaperLibrary.cachedThumbnail(entry.url) {
            picture.contents = hit
        } else {
            WallpaperLibrary.thumbnail(entry.url) { [weak self] image in
                guard let self, let image else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.picture.contents = image
                CATransaction.commit()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        picture.backgroundColor = Neon.track.cgColor
        restyle()
    }

    private func restyle() {
        picture.borderColor = (isChosen ? Neon.accent.withAlphaComponent(0.85) : Neon.divider).cgColor
        picture.borderWidth = isChosen ? 1.5 : 1
        label.font = ZFont.ui(ofSize: isChosen ? 12 : 10.5, weight: isChosen ? .medium : .regular)
        label.textColor = isChosen ? Neon.text : Neon.textDim
    }

    override func layout() {
        super.layout()
        picture.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.labelH))
        label.frame = NSRect(x: 0, y: bounds.height - Self.labelH + 3, width: bounds.width, height: Self.labelH - 3)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
