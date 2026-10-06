import AppKit

// MARK: - App opener
//
//                 ┃  (her rope, from the notch)
//              (Zera)   paws on the capsule's edge
//  ╭───────────────────────────────────────────────╮
//  │ 🔍 Open an app…                          esc │
//  │ YOUR USUAL                      this afternoon │
//  │ [icon] Notes                         ⏎ Open   │
//  │ [N] [S] [V] [S] [F] [>_]   ⌘1…⌘6               │
//  │ ←→ choose · ⏎ open · ⌘1–⌘6 · ⌘⏎ show in Finder │
//  ╰───────────────────────────────────────────────╯
//
// Its own floating panel, not a tab: Zera rappels down from the notch carrying it, the apps pop
// in, and ⏎ tosses the chosen app up to her before she climbs back.

private enum OP {
    static let width: CGFloat = 640
    static let margin: CGFloat = 40          // room for the glow
    static let ropeGap: CGFloat = 34          // notch → her head
    static let zeraW: CGFloat = 104
    static let paws: CGFloat = 9              // how far her paws overlap the capsule
    static let pad: CGFloat = 16
    static let gap: CGFloat = 12
    static let fieldH: CGFloat = 48
    static let tabsH: CGFloat = 32
    static let heroH: CGFloat = 80
    static let tileH: CGFloat = 96
    static let footH: CGFloat = 16
    static let tiles = 6
}

/// One result: an app to open, or a command to run.
enum OpenerItem {
    case app(AppEntry, hits: [Int], running: Bool)
    case command(OpenerCommand, hits: [Int])
    case action(QuickAction, hits: [Int])

    var name: String {
        switch self {
        case .app(let a, _, _): return a.name
        case .command(let c, _): return c.title
        case .action(let a, _): return OpenerActions.title(a)
        }
    }
    var hits: [Int] {
        switch self {
        case .app(_, let h, _), .command(_, let h), .action(_, let h): return h
        }
    }
    var icon: NSImage {
        switch self {
        case .app(let a, _, _): return AppCatalog.shared.icon(a)
        case .command(let c, _): return c.icon
        case .action(let a, _): return OpenerIcon.glyph(a.symbol, a.color)
        }
    }
    var subtitle: String {
        switch self {
        case .app(let a, _, let running): return (running ? "Running · " : "") + a.folder
        case .command(let c, _): return c.subtitle
        case .action(let a, _): return OpenerActions.subtitle(a)
        }
    }
    var running: Bool { if case .app(_, _, let r) = self { return r }; return false }
    var isApp: Bool { if case .app = self { return true }; return false }
}

/// Settings for the opener, kept with its shortcut.
enum AppOpenerSettings {
    private static let enabledKey = "appOpener.enabled"
    private static let runningKey = "appOpener.runningFirst"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static var runningFirst: Bool {
        get { UserDefaults.standard.object(forKey: runningKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: runningKey) }
    }
    static let defaultShortcut = HotKeyShortcut(keyCode: 49, modifiers: UInt32(2048), key: "Space")   // ⌥Space
}

/// Owns the opener's panel: shows it under the notch, closes it, launches apps.
final class AppOpener: NSObject, NSWindowDelegate {
    private let panel: FloatingPanel
    private let view = AppOpenerView()
    private(set) var isOpen = false
    /// Hide / show the hanging Zera while this Zera is down.
    var onOpenChanged: ((Bool) -> Void)?
    var onLaunched: ((AppEntry) -> Void)?
    /// One of Zera's actions was chosen; it runs once she's back up.
    var onAction: ((QuickAction) -> Void)?

    override init() {
        panel = FloatingPanel.make(size: NSSize(width: OP.width + OP.margin * 2, height: 600),
                                   level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 4), keyable: true)
        super.init()
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        panel.delegate = self
        view.onLaunch = { [weak self] app, finder in self?.launch(app, inFinder: finder) }
        view.onSearchWeb = { [weak self] q in self?.searchWeb(q) }
        view.onClose = { [weak self] in self?.close() }
        view.onAction = { [weak self] a in
            SoundService.shared.play(.openerLaunch)
            self?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.onAction?(a) }
        }
    }

    func toggle(notch: NSRect, screen: NSRect) { isOpen ? close() : open(notch: notch, screen: screen) }

    func open(notch: NSRect, screen: NSRect) {
        guard !isOpen else { return }
        isOpen = true
        onOpenChanged?(true)
        let band = max(24, notch.height)
        let size = NSSize(width: OP.width + OP.margin * 2, height: view.panelHeight(band: band))
        let x = max(screen.minX, min(screen.maxX - size.width, notch.midX - size.width / 2))
        panel.setFrame(NSRect(x: x, y: screen.maxY - size.height, width: size.width, height: size.height), display: false)
        view.band = band
        view.ropeX = notch.midX - x
        view.prepare()
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        view.animateIn()
        SoundService.shared.play(.openerDrop)
        AppCatalog.shared.refreshIfNeeded { [weak self] in self?.view.reload() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        view.animateOut { [weak self] in
            guard let self = self, !self.isOpen else { return }
            self.panel.orderOut(nil)
            self.onOpenChanged?(false)
        }
    }

    private func launch(_ app: AppEntry, inFinder: Bool) {
        if inFinder {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
            close()
            return
        }
        AppCatalog.shared.noteOpened(app)
        SoundService.shared.play(.openerLaunch)
        view.toss(app) { [weak self] in
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
            self?.close()
            self?.onLaunched?(app)
        }
    }

    private func searchWeb(_ q: String) {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        if let u = c.url { NSWorkspace.shared.open(u) }
        close()
    }

    // A click in another app (or anywhere outside) sends her back up.
    func windowDidResignKey(_ notification: Notification) { close() }
}

/// The content: rope, Zera holding the capsule, and the capsule itself.
final class AppOpenerView: NSView, NSTextFieldDelegate {
    var onLaunch: ((AppEntry, Bool) -> Void)?
    var onSearchWeb: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onAction: ((QuickAction) -> Void)?
    var band: CGFloat = 32
    var ropeX: CGFloat = 0

    private let rope = NSView()
    private let holder = OpenerFlipped()
    private let zera = NSImageView()
    private let capsule = OpenerGlass()
    private let searchIcon = NSImageView()
    private let field = NSTextField()
    private let escHint = NSTextField(labelWithString: "esc")
    private let leftLabel = NSTextField(labelWithString: "YOUR USUAL")
    private let rightLabel = NSTextField(labelWithString: "")
    private let hero = OpenerHero()
    private var tiles: [OpenerTile] = []
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let foot = NSTextField(labelWithString: "")
    private let footRight = NSTextField(labelWithString: "")
    /// All · Apps · Commands · Actions.
    private enum Filter: Int, CaseIterable {
        case all, apps, commands, actions
        var title: String { ["All", "Apps", "Commands", "Actions"][rawValue] }
    }
    private var filter: Filter = .all
    private let tabs = GitHubSegmentedControl(items: Filter.allCases.map { .init(symbol: "", title: $0.title, count: 0, tint: nil) })
    private var results: [OpenerItem] = []
    private var selected = 0

    /// Opening apps, or inside a command (Kill Process, Kill Port, Custom Commands).
    private enum Mode: Equatable { case root, command(OpenerCommand) }
    private var mode: Mode = .root
    private let listScroll = NSScrollView()
    private let listDoc = OpenerFlipped()
    private var rows: [OpenerRow] = []
    private var processes: [ProcessEntry] = []
    private var ports: [PortEntry] = []
    private var listItems: [(title: String, detail: String, trailing: String, pid: Int32)] = []
    private var loading = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let sprite = SpriteLibrary.shared.sprite("hang_peek")
    /// Where the rope enters her picture, 0…1 of its width.
    private var ropeFraction: CGFloat { sprite?.ropeX ?? 0.5 }
    /// As thick as the rope in her picture at this size (ZeraView draws it the same way).
    private var ropeWidth: CGFloat { max(1.5, OP.zeraW * 0.035).rounded() }

    /// The top of the rope in her picture, cut out at the size she's drawn, to tile the long rope.
    private func ropePattern() -> NSImage? {
        guard let sp = sprite, let rx = sp.ropeX,
              let cg = sp.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pxW = CGFloat(cg.width)
        let scale = OP.zeraW / pxW                       // picture pixels → points
        let stripPx = max(2, (ropeWidth / scale).rounded())
        let rowsPx: CGFloat = min(CGFloat(cg.height) * 0.12, 40)
        let crop = CGRect(x: (rx * pxW - stripPx / 2).rounded(), y: 0, width: stripPx, height: rowsPx)
        guard let piece = cg.cropping(to: crop) else { return nil }
        let size = NSSize(width: ropeWidth, height: max(4, (rowsPx * scale).rounded()))
        return NSImage(cgImage: piece, size: size)
    }

    private var zeraH: CGFloat {
        guard let img = zera.image, img.size.width > 0 else { return 117 }
        return OP.zeraW * img.size.height / img.size.width
    }
    private var capsuleTop: CGFloat { band + OP.ropeGap + zeraH - OP.paws }
    private var capsuleH: CGFloat {
        OP.pad + OP.fieldH + OP.gap + OP.tabsH + OP.gap + OP.heroH + 10 + OP.tileH + OP.gap + OP.footH + 14
    }
    func panelHeight(band: CGFloat) -> CGFloat { self.band = band; return capsuleTop + capsuleH + OP.margin }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        // The same rope her picture holds: a strip of it, repeated all the way up to the notch.
        rope.wantsLayer = true
        rope.layer?.backgroundColor = (ropePattern().map { NSColor(patternImage: $0) }
            ?? sprite?.ropeColor ?? NSColor(srgbRed: 0.36, green: 0.23, blue: 0.13, alpha: 1)).cgColor
        addSubview(rope)

        holder.wantsLayer = true
        holder.layer?.masksToBounds = false
        addSubview(holder)

        capsule.radius = 26
        capsule.fill = NSColor(srgbRed: 0.027, green: 0.045, blue: 0.11, alpha: 1)
        capsule.edge = Neon.edge
        capsule.lineWidth = 1.5
        capsule.glow = 0.75
        holder.addSubview(capsule)
        zera.image = SpriteLibrary.shared.sprite("hang_peek")?.image
        zera.imageScaling = .scaleProportionallyUpOrDown
        zera.wantsLayer = true
        holder.addSubview(zera)

        let fieldBox = OpenerGlass()
        fieldBox.radius = 16
        fieldBox.fill = NSColor(srgbRed: 0.012, green: 0.024, blue: 0.065, alpha: 1)
        fieldBox.edge = Neon.chipEdge
        fieldBox.lineWidth = 1
        fieldBox.glow = 0
        fieldBox.identifier = NSUserInterfaceItemIdentifier("fieldBox")
        capsule.addSubview(fieldBox)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [Neon.cyan])))
        fieldBox.addSubview(searchIcon)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        field.textColor = Neon.text
        field.placeholderAttributedString = NSAttributedString(string: "Open an app…", attributes: [
            .foregroundColor: NSColor(srgbRed: 0.37, green: 0.41, blue: 0.59, alpha: 1), .font: NSFont.systemFont(ofSize: 18, weight: .medium)])
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("App name")
        fieldBox.addSubview(field)
        escHint.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        escHint.textColor = Neon.glyph
        escHint.alignment = .center
        escHint.wantsLayer = true
        escHint.layer?.cornerRadius = 6
        escHint.layer?.borderWidth = 1
        escHint.layer?.borderColor = Neon.chipEdge.cgColor
        fieldBox.addSubview(escHint)

        for l in [leftLabel, rightLabel] {
            l.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            l.textColor = Neon.textDim
            capsule.addSubview(l)
        }
        rightLabel.alignment = .right
        tabs.fitToContent = true
        tabs.onSelect = { [weak self] i in self?.setFilter(Filter(rawValue: i) ?? .all) }
        capsule.addSubview(tabs)
        hero.onOpen = { [weak self] in self?.openSelected() }
        capsule.addSubview(hero)
        for i in 0..<OP.tiles {
            let t = OpenerTile(index: i)
            t.onHover = { [weak self] in self?.select(i) }
            t.onClick = { [weak self] in self?.select(i); self?.openSelected() }
            capsule.addSubview(t)
            tiles.append(t)
        }
        listScroll.drawsBackground = false
        listScroll.contentView.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.hasVerticalScroller = true
        listScroll.scrollerStyle = .overlay
        listScroll.documentView = listDoc
        listScroll.isHidden = true
        capsule.addSubview(listScroll)
        empty.font = NSFont.systemFont(ofSize: 13)
        empty.textColor = Neon.textDim
        empty.alignment = .center
        capsule.addSubview(empty)
        for f in [foot, footRight] {
            f.font = NSFont.systemFont(ofSize: 11)
            f.textColor = Neon.textDim
            f.lineBreakMode = .byTruncatingTail
            capsule.addSubview(f)
        }
        footRight.alignment = .right
        setAccessibilityRole(.group)
        setAccessibilityLabel("App opener")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Data

    func prepare() {
        mode = .root
        filter = .all
        tabs.selected = 0
        field.stringValue = ""
        selected = 0
        needsLayout = true
        layoutSubtreeIfNeeded()
        reload()
    }

    func reload() {
        if case .command(let c) = mode { reloadList(c); return }
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        let typing = !q.isEmpty
        var scored: [(OpenerItem, Int)] = []
        if filter == .all || filter == .apps {
            scored += AppCatalog.shared.results(for: q, runningFirst: AppOpenerSettings.runningFirst, limit: OP.tiles)
                .map { (.app($0.app, hits: $0.hits, running: $0.running), $0.score) }
        }
        // Commands and actions: every one on their own tab, the matching ones on All once you type.
        if filter == .commands || (filter == .all && typing) {
            scored += OpenerCommand.allCases.compactMap { c in
                if !typing { return (.command(c, hits: []), 0) }
                return c.match(q).map { (.command(c, hits: $0.hits), $0.score) }
            }
        }
        if filter == .actions || (filter == .all && typing) {
            scored += OpenerActions.all.compactMap { a in
                if !typing { return (.action(a, hits: []), 0) }
                return OpenerActions.match(a, q).map { (.action(a, hits: $0.hits), $0.score) }
            }
        }
        if typing { scored.sort { $0.1 > $1.1 } }
        results = Array(scored.prefix(OP.tiles).map(\.0))
        selected = min(selected, max(0, results.count - 1))
        leftLabel.isHidden = true
        tabs.isHidden = false
        let hour = Calendar.current.component(.hour, from: Date())
        let when = hour < 12 ? "THIS MORNING" : (hour < 18 ? "THIS AFTERNOON" : "THIS EVENING")
        rightLabel.stringValue = typing ? "\(results.count) RESULT\(results.count == 1 ? "" : "S")"
            : (filter == .all || filter == .apps ? "YOUR USUAL · \(when)" : "\(results.count) \(filter == .commands ? "COMMANDS" : "ACTIONS")")
        let none = results.isEmpty
        setRootVisible(true)
        empty.isHidden = !none
        hero.isHidden = none
        empty.stringValue = AppCatalog.shared.apps.isEmpty && filter != .commands && filter != .actions ? "Looking for your apps…"
            : "Nothing called “\(q)”.\n⏎ searches the web for it."
        for (i, t) in tiles.enumerated() {
            if i < results.count {
                t.isHidden = false
                t.set(item: results[i], selected: i == selected)
            } else {
                t.isHidden = true
            }
        }
        if let r = results[safe: selected] { hero.set(item: r) }
        zera.frameCenterRotation = none && typing ? 10 : 0     // a puzzled head-tilt
        foot.stringValue = "←→ choose   ⏎ open   ⌘1–⌘6 quick open   ⌘⏎ show in Finder"
        footRight.stringValue = "⇥ next tab"
    }

    private func setFilter(_ f: Filter) {
        guard f != filter else { return }
        filter = f
        tabs.selected = f.rawValue
        selected = 0
        SoundService.shared.play(.openerTick)
        reload()
        popTiles()
    }

    private func setRootVisible(_ root: Bool) {
        hero.isHidden = !root
        tiles.forEach { $0.isHidden = !root }
        listScroll.isHidden = root
        if root { empty.isHidden = true }
    }

    private func select(_ i: Int) {
        guard i < results.count, i != selected else { return }
        selected = i
        SoundService.shared.play(.openerTick)
        for (k, t) in tiles.enumerated() where k < results.count { t.selected = k == i }
        hero.set(item: results[i])
    }

    private func openSelected(finder: Bool = false) {
        if case .command = mode { killSelected(force: finder); return }
        guard let r = results[safe: selected] else {
            let q = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty, !finder { onSearchWeb?(q) }
            return
        }
        switch r {
        case .app(let a, _, _): onLaunch?(a, finder)
        case .command(let c, _): enter(c)
        case .action(let a, _): onAction?(a)
        }
    }

    // MARK: Commands

    private func enter(_ c: OpenerCommand) {
        mode = .command(c)
        SoundService.shared.play(.openerTick)
        field.stringValue = ""
        selected = 0
        (field.placeholderAttributedString?.mutableCopy() as? NSMutableAttributedString).map { p in
            p.mutableString.setString(c == .killPort ? "Port number…" : (c == .killProcess ? "Search processes…" : "Coming soon"))
            field.placeholderAttributedString = p
        }
        leftLabel.stringValue = "‹  " + c.title.uppercased()
        leftLabel.isHidden = false
        tabs.isHidden = true
        rightLabel.stringValue = c == .custom ? "SOON" : "LOADING…"
        setRootVisible(false)
        processes = []; ports = []
        reloadList(c)
        guard c != .custom else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let procs = c == .killProcess ? ProcessTools.processes() : []
            let listening = c == .killPort ? ProcessTools.listeningPorts() : []
            DispatchQueue.main.async {
                guard let self = self, self.mode == .command(c) else { return }
                self.loading = false
                self.processes = procs
                self.ports = listening
                self.reloadList(c)
            }
        }
    }

    private func back() {
        mode = .root
        field.stringValue = ""
        selected = 0
        (field.placeholderAttributedString?.mutableCopy() as? NSMutableAttributedString).map { p in
            p.mutableString.setString("Open an app…")
            field.placeholderAttributedString = p
        }
        reload()
    }

    private func reloadList(_ c: OpenerCommand) {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        switch c {
        case .killProcess:
            let filtered = q.isEmpty ? processes : processes.filter { $0.name.lowercased().contains(q) || String($0.pid).hasPrefix(q) }
            listItems = filtered.prefix(60).map { p in
                (p.name, "pid \(p.pid) · \(ProcessTools.memory(p.memoryKB))", String(format: "%.1f%% CPU", p.cpu), p.pid)
            }
            foot.stringValue = "↑↓ choose   ⏎ quit   ⌘⏎ force quit"
            footRight.stringValue = "esc back"
        case .killPort:
            let filtered = q.isEmpty ? ports : ports.filter { String($0.port).hasPrefix(q) || $0.command.lowercased().contains(q) }
            listItems = filtered.prefix(60).map { p in
                (":\(p.port)", "\(p.command) · pid \(p.pid) · \(p.address == "*" ? "all addresses" : p.address)", "listening", p.pid)
            }
            foot.stringValue = "↑↓ choose   ⏎ stop what's on the port   ⌘⏎ force"
            footRight.stringValue = "esc back"
        case .custom:
            listItems = []
            foot.stringValue = ""
            footRight.stringValue = "esc back"
        }
        selected = min(selected, max(0, listItems.count - 1))
        if !loading, c != .custom {
            rightLabel.stringValue = "\(listItems.count) \(c == .killPort ? "PORT" : "PROCESS")\(listItems.count == 1 ? "" : (c == .killPort ? "S" : "ES"))"
        }
        empty.isHidden = !listItems.isEmpty
        empty.stringValue = c == .custom ? "Custom commands are coming soon: add your own scripts and run them from here."
            : (loading ? "Looking…" : (c == .killPort ? (q.isEmpty ? "Nothing is listening on a port." : "Nothing is listening on \(q).")
                                                      : "No process matches “\(q)”."))
        rows.forEach { $0.removeFromSuperview() }
        rows = listItems.enumerated().map { i, it in
            let r = OpenerRow(title: it.title, detail: it.detail, trailing: it.trailing, mono: c == .killPort)
            r.selected = i == selected
            r.onHover = { [weak self] in self?.selectRow(i) }
            r.onClick = { [weak self] in self?.selectRow(i); self?.killSelected(force: false) }
            listDoc.addSubview(r)
            return r
        }
        layoutList()
    }

    private func selectRow(_ i: Int) {
        guard i < rows.count, i != selected else { return }
        selected = i
        SoundService.shared.play(.openerTick)
        for (k, r) in rows.enumerated() { r.selected = k == i }
        rows[i].scrollToVisible(rows[i].bounds)
    }

    private func killSelected(force: Bool) {
        guard case .command(let c) = mode, c != .custom, let it = listItems[safe: selected] else { return }
        switch ProcessTools.kill(it.pid, force: force) {
        case .done:
            SoundService.shared.play(.clipClear)
            rightLabel.stringValue = force ? "FORCE QUIT \(it.title.uppercased())" : "STOPPED \(it.title.uppercased())"
            processes.removeAll { $0.pid == it.pid }
            ports.removeAll { $0.pid == it.pid }
            let keep = rightLabel.stringValue
            reloadList(c)
            rightLabel.stringValue = keep
        case .notAllowed:
            NSSound.beep()
            rightLabel.stringValue = "NOT ALLOWED: OWNED BY THE SYSTEM"
        case .gone:
            processes.removeAll { $0.pid == it.pid }
            ports.removeAll { $0.pid == it.pid }
            reloadList(c)
        }
    }

    func controlTextDidChange(_ obj: Notification) { selected = 0; reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if case .command = mode {
            switch sel {
            case #selector(NSResponder.moveDown(_:)): selectRow(min(rows.count - 1, selected + 1)); return true
            case #selector(NSResponder.moveUp(_:)): selectRow(max(0, selected - 1)); return true
            case #selector(NSResponder.insertNewline(_:)):
                killSelected(force: NSApp.currentEvent?.modifierFlags.contains(.command) == true); return true
            case #selector(NSResponder.cancelOperation(_:)): back(); return true
            case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty: back(); return true
            default: return false
            }
        }
        let n = min(results.count, OP.tiles)
        switch sel {
        case #selector(NSResponder.moveRight(_:)) where textView.selectedRange().location >= field.stringValue.count,
             #selector(NSResponder.moveDown(_:)):
            if n > 0 { select((selected + 1) % n) }; return true
        case #selector(NSResponder.moveLeft(_:)) where textView.selectedRange().location >= field.stringValue.count,
             #selector(NSResponder.moveUp(_:)):
            if n > 0 { select((selected - 1 + n) % n) }; return true
        case #selector(NSResponder.insertNewline(_:)):
            let finder = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            openSelected(finder: finder); return true
        case #selector(NSResponder.insertTab(_:)):
            setFilter(Filter(rawValue: (filter.rawValue + 1) % Filter.allCases.count) ?? .all); return true
        case #selector(NSResponder.insertBacktab(_:)):
            setFilter(Filter(rawValue: (filter.rawValue + Filter.allCases.count - 1) % Filter.allCases.count) ?? .all); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?(); return true
        default: return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        if mode == .root, let c = event.charactersIgnoringModifiers, let n = Int(c), (1...OP.tiles).contains(n), n - 1 < results.count {
            selected = n - 1
            reload()
            openSelected()
            return true
        }
        if event.keyCode == 36 { openSelected(finder: true); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the empty glass around the capsule closes it, like clicking anywhere else.
        let p = convert(event.locationInWindow, from: nil)
        if !capsule.frame.offsetBy(dx: holder.frame.minX, dy: holder.frame.minY).contains(p) { onClose?() }
    }

    private func layoutList() {
        let w = listScroll.contentSize.width
        var y: CGFloat = 0
        for r in rows { r.frame = NSRect(x: 0, y: y, width: w, height: 36); y += 40 }
        listDoc.frame = NSRect(x: 0, y: 0, width: w, height: max(y, listScroll.frame.height))
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        let zh = zeraH
        holder.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        let cx = ropeX > 0 ? ropeX : w / 2
        // Her picture's own rope sits exactly on the drawn one.
        zera.frame = NSRect(x: (cx - ropeFraction * OP.zeraW).rounded(), y: band + OP.ropeGap, width: OP.zeraW, height: zh)
        capsule.frame = NSRect(x: OP.margin, y: capsuleTop, width: OP.width, height: capsuleH)
        if rope.layer?.animation(forKey: "drop") == nil {
            // From the very top (into the notch) to a little way under her picture's own rope,
            // so the two read as one rope with no joint.
            rope.frame = NSRect(x: (cx - ropeWidth / 2).rounded(), y: 0, width: ropeWidth, height: band + OP.ropeGap + 14)
        }
        let iw = OP.width - OP.pad * 2
        var y = OP.pad
        if let box = capsule.subviews.first(where: { $0.identifier?.rawValue == "fieldBox" }) {
            box.frame = NSRect(x: OP.pad, y: y, width: iw, height: OP.fieldH)
            searchIcon.frame = NSRect(x: 16, y: (OP.fieldH - 18) / 2, width: 18, height: 18)
            escHint.frame = NSRect(x: iw - 14 - 34, y: (OP.fieldH - 18) / 2, width: 34, height: 18)
            field.frame = NSRect(x: 46, y: (OP.fieldH - 24) / 2, width: iw - 46 - 60, height: 24)
        }
        y += OP.fieldH + OP.gap
        let tw0 = min(iw - 170, tabs.preferredWidth)
        tabs.frame = NSRect(x: OP.pad, y: y, width: tw0, height: OP.tabsH)
        leftLabel.frame = NSRect(x: OP.pad + 4, y: y + (OP.tabsH - 14) / 2, width: iw / 2, height: 14)
        rightLabel.frame = NSRect(x: OP.pad + iw - 220, y: y + (OP.tabsH - 14) / 2, width: 216, height: 14)
        y += OP.tabsH + OP.gap
        hero.frame = NSRect(x: OP.pad, y: y, width: iw, height: OP.heroH)
        empty.frame = NSRect(x: OP.pad, y: y + 40, width: iw, height: 44)
        listScroll.frame = NSRect(x: OP.pad, y: y, width: iw, height: OP.heroH + 10 + OP.tileH)
        layoutList()
        y += OP.heroH + 10
        let tw = (iw - CGFloat(OP.tiles - 1) * 8) / CGFloat(OP.tiles)
        for (i, t) in tiles.enumerated() { t.frame = NSRect(x: OP.pad + CGFloat(i) * (tw + 8), y: y, width: tw, height: OP.tileH) }
        y += OP.tileH + OP.gap
        foot.frame = NSRect(x: OP.pad + 4, y: y, width: iw - 110, height: OP.footH)
        footRight.frame = NSRect(x: OP.pad + iw - 104, y: y, width: 100, height: OP.footH)
    }

    // MARK: Motion

    /// She rappels down carrying the capsule: the rope pays out, she and the capsule drop in with
    /// an overshoot, the capsule unfurls under her paws, the apps pop in one by one.
    func animateIn() {
        window?.makeFirstResponder(field)
        guard !Motion.reduced, let hl = holder.layer else { holder.alphaValue = 1; return }
        holder.alphaValue = 1
        let drop = CASpringAnimation(keyPath: "transform.translation.y")
        drop.fromValue = -(capsuleTop + 40); drop.toValue = 0
        drop.stiffness = 170; drop.damping = 17; drop.mass = 1
        drop.duration = drop.settlingDuration
        hl.add(drop, forKey: "drop")

        if let cl = capsule.layer {
            // Grows out from under her paws: scaled about the capsule's top centre.
            let sc: CGFloat = 0.25, w = capsule.bounds.width
            let from = CATransform3DConcat(CATransform3DMakeScale(sc, sc, 1), CATransform3DMakeTranslation(w * (1 - sc) / 2, 0, 0))
            let unfurl = CASpringAnimation(keyPath: "transform")
            unfurl.fromValue = NSValue(caTransform3D: from); unfurl.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            unfurl.stiffness = 200; unfurl.damping = 16
            unfurl.duration = unfurl.settlingDuration
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.18
            let g = CAAnimationGroup()
            g.animations = [unfurl, fade]
            g.duration = unfurl.duration
            g.beginTime = CACurrentMediaTime() + 0.12
            g.fillMode = .backwards
            cl.add(g, forKey: "unfurl")
        }

        if let rl = rope.layer {
            let grow = CABasicAnimation(keyPath: "bounds.size.height")
            grow.fromValue = 0; grow.toValue = rope.frame.height
            grow.duration = 0.35
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.3, 0.5, 1)
            rl.add(grow, forKey: "grow")
        }

        popTiles(delay: 0.24)
    }

    /// The slots pop in one after another (on open, and when you switch tabs).
    private func popTiles(delay: Double = 0) {
        guard !Motion.reduced else { return }
        for (i, t) in ([hero as NSView] + tiles).enumerated() where !t.isHidden {
            guard let tl = t.layer else { continue }
            let pop = CASpringAnimation(keyPath: "transform.translation.y")
            pop.fromValue = -10; pop.toValue = 0; pop.stiffness = 280; pop.damping = 16
            pop.duration = pop.settlingDuration
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.18
            let g = CAAnimationGroup()
            g.animations = [pop, fade]
            g.duration = pop.duration
            g.beginTime = CACurrentMediaTime() + delay + Double(i) * 0.025
            g.fillMode = .backwards
            tl.add(g, forKey: "pop")
        }
    }

    /// Back up the rope.
    func animateOut(_ done: @escaping () -> Void) {
        guard !Motion.reduced, let hl = holder.layer else { done(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let up = CABasicAnimation(keyPath: "transform.translation.y")
        up.fromValue = 0; up.toValue = -(capsuleTop + 60)
        up.duration = 0.26
        up.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0)
        up.fillMode = .forwards; up.isRemovedOnCompletion = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.26
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        hl.add(up, forKey: "up")
        hl.add(fade, forKey: "fade")
        rope.layer?.add(fade, forKey: "fade")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.holder.layer?.removeAllAnimations()
            self?.rope.layer?.removeAllAnimations()
        }
    }

    /// The chosen app's icon flies up into Zera's paws; she hops; then `done`.
    func toss(_ app: AppEntry, _ done: @escaping () -> Void) {
        let source = hero.iconFrame.offsetBy(dx: capsule.frame.minX + hero.frame.minX, dy: capsule.frame.minY + hero.frame.minY)
        let flyer = NSImageView(frame: source)
        flyer.image = AppCatalog.shared.icon(app)
        flyer.wantsLayer = true
        addSubview(flyer)
        guard !Motion.reduced else { flyer.removeFromSuperview(); done(); return }
        let target = NSRect(x: zera.frame.midX - 14, y: zera.frame.midY - 4, width: 28, height: 28)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.3, 1)
            flyer.animator().frame = target
            flyer.animator().alphaValue = 0.15
        }, completionHandler: { [weak self] in
            flyer.removeFromSuperview()
            guard let self = self, let zl = self.zera.layer else { done(); return }
            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = [0, -10, 2, 0]
            hop.keyTimes = [0, 0.35, 0.7, 1]
            hop.duration = 0.32
            zl.add(hop, forKey: "hop")
            self.sparkle(at: NSPoint(x: self.zera.frame.midX, y: self.zera.frame.midY))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: done)
        })
    }

    private func sparkle(at p: NSPoint) {
        guard let root = layer else { return }
        for k in 0..<10 {
            let s = CALayer()
            s.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            s.cornerRadius = 2.5
            s.backgroundColor = Neon.cyan.cgColor
            s.shadowColor = Neon.cyan.cgColor
            s.shadowOpacity = 1
            s.shadowRadius = 4
            s.shadowOffset = .zero
            s.position = p
            root.addSublayer(s)
            let a = Double(k) / 10 * 2 * .pi
            let move = CABasicAnimation(keyPath: "position")
            move.toValue = NSValue(point: NSPoint(x: p.x + cos(a) * 38, y: p.y + sin(a) * 38))
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [move, fade]
            g.duration = 0.5
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            s.add(g, forKey: "spark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { s.removeFromSuperlayer() }
        }
    }
}

/// "Notes" with the letters you typed lit up in cyan.
private func highlighted(_ name: String, _ hits: [Int], size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
    let s = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: Neon.text])
    let chars = Array(name)
    var offset = 0
    for (i, c) in chars.enumerated() {
        let len = String(c).utf16.count
        if hits.contains(i) {
            s.addAttributes([.foregroundColor: Neon.cyan, .font: NSFont.systemFont(ofSize: size, weight: .bold)],
                            range: NSRange(location: offset, length: len))
        }
        offset += len
    }
    return s
}

/// The big spot: the best (or chosen) match.
final class OpenerHero: NSView {
    var onOpen: (() -> Void)?
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let go = OpenerPill()
    override var isFlipped: Bool { true }
    var iconFrame: NSRect { icon.frame }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if let l = layer {
            l.cornerRadius = 18
            l.cornerCurve = .continuous
            let g = CAGradientLayer()
            g.colors = [Neon.accent.withAlphaComponent(0.16).cgColor, Neon.violet.withAlphaComponent(0.08).cgColor]
            g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5)
            g.cornerRadius = 18
            g.name = "bg"
            l.addSublayer(g)
            l.borderWidth = 1
            l.borderColor = Neon.accent.withAlphaComponent(0.55).cgColor
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        sub.font = NSFont.systemFont(ofSize: 12)
        sub.textColor = Neon.textDim
        sub.lineBreakMode = .byTruncatingMiddle
        addSubview(sub)
        addSubview(go)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(item: OpenerItem) {
        icon.image = item.icon
        name.attributedStringValue = highlighted(item.name, item.hits, size: 18, weight: .semibold)
        sub.stringValue = item.subtitle
        go.title = item.isApp ? "Open" : "Run"
        setAccessibilityLabel(go.title + " " + item.name)
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.first { $0.name == "bg" }?.frame = bounds
        let h = bounds.height
        icon.frame = NSRect(x: 14, y: (h - 56) / 2, width: 56, height: 56)
        let gw = go.fittedWidth
        go.frame = NSRect(x: bounds.width - 16 - gw, y: (h - 30) / 2, width: gw, height: 30)
        name.frame = NSRect(x: 84, y: h / 2 - 23, width: go.frame.minX - 96, height: 24)
        sub.frame = NSRect(x: 84, y: h / 2 + 3, width: go.frame.minX - 96, height: 16)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() } }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One of the six slots under the big spot: icon, name, ⌘n, a cyan dot when it's running.
final class OpenerTile: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { restyle() } } }
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let key = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var hovered = false { didSet { restyle() } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(index: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        key.stringValue = "⌘\(index + 1)"
        key.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
        key.textColor = Neon.textDim
        key.alignment = .right
        addSubview(key)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2
        dot.layer?.backgroundColor = Neon.cyan.cgColor
        dot.layer?.shadowColor = Neon.cyan.cgColor
        dot.layer?.shadowOpacity = 1
        dot.layer?.shadowRadius = 3
        dot.layer?.shadowOffset = .zero
        addSubview(dot)
        setAccessibilityRole(.button)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(item: OpenerItem, selected: Bool) {
        icon.image = item.icon
        name.attributedStringValue = highlighted(item.name, item.hits, size: 11.5, weight: .medium)
        if let p = name.attributedStringValue.mutableCopy() as? NSMutableAttributedString {
            let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
            p.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: p.length))
            name.attributedStringValue = p
        }
        dot.isHidden = !item.running
        self.selected = selected
        setAccessibilityLabel(item.name)
        restyle()
    }

    private func restyle() {
        let on = selected
        layer?.backgroundColor = (on ? Neon.accent.withAlphaComponent(0.14) : (hovered ? Neon.chipHover : Neon.chip.withAlphaComponent(0.55))).cgColor
        layer?.borderColor = (on ? Neon.accent.withAlphaComponent(0.55) : (hovered ? Neon.chipEdge : .clear)).cgColor
        layer?.shadowColor = Neon.halo.cgColor
        layer?.shadowOpacity = on ? 0.5 : 0
        layer?.shadowRadius = 10
        layer?.shadowOffset = .zero
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: (w - 44) / 2, y: 12, width: 44, height: 44)
        name.frame = NSRect(x: 4, y: 62, width: w - 8, height: 16)
        key.frame = NSRect(x: w - 36, y: 6, width: 30, height: 12)
        dot.frame = NSRect(x: (w - 4) / 2, y: 82, width: 4, height: 4)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?() }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

final class OpenerFlipped: NSView { override var isFlipped: Bool { true } }

/// A row in a command's list: "node · pid 4127 · 120 MB        3.2% CPU".
final class OpenerRow: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { restyle() } } }
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private var hovered = false { didSet { restyle() } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title t: String, detail d: String, trailing tr: String, mono: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        title.stringValue = t
        title.font = mono ? NSFont.monospacedSystemFont(ofSize: 13.5, weight: .semibold) : NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        title.textColor = Neon.text
        title.lineBreakMode = .byTruncatingTail
        detail.stringValue = d
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = Neon.textDim
        detail.lineBreakMode = .byTruncatingTail
        trailing.stringValue = tr
        trailing.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        trailing.textColor = Neon.glyph
        trailing.alignment = .right
        [title, detail, trailing].forEach(addSubview)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(t), \(d)")
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        layer?.backgroundColor = (selected ? Neon.accent.withAlphaComponent(0.14) : (hovered ? Neon.chipHover : Neon.chip.withAlphaComponent(0.5))).cgColor
        layer?.borderColor = (selected ? Neon.accent.withAlphaComponent(0.55) : .clear).cgColor
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let tw = min(220, ceil(title.attributedStringValue.size().width) + 6)
        title.frame = NSRect(x: 12, y: (h - 18) / 2, width: tw, height: 18)
        trailing.frame = NSRect(x: w - 12 - 100, y: (h - 15) / 2, width: 100, height: 15)
        detail.frame = NSRect(x: title.frame.maxX + 10, y: (h - 16) / 2 + 1, width: max(0, trailing.frame.minX - title.frame.maxX - 20), height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?() }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A rounded panel that paints its own fill, edge and glow, so it's solid however it's layered.
final class OpenerGlass: NSView {
    var radius: CGFloat = 26 { didSet { needsDisplay = true } }
    var fill: NSColor = Neon.fillBottom { didSet { needsDisplay = true } }
    var edge: NSColor = Neon.edge { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 1.5 { didSet { needsDisplay = true } }
    var glow: Float = 0.75 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        guard let l = layer else { return }
        l.cornerRadius = radius
        l.cornerCurve = .continuous
        l.backgroundColor = fill.cgColor
        l.borderWidth = lineWidth
        l.borderColor = edge.cgColor
        l.shadowColor = Neon.halo.cgColor
        l.shadowOpacity = glow
        l.shadowRadius = 22
        l.shadowOffset = .zero
        l.masksToBounds = false
    }
}

/// "⏎ Open": the hero's pill, text centred both ways.
final class OpenerPill: NSView {
    var title = "Open" { didSet { needsDisplay = true; needsLayout = true } }
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    override var isFlipped: Bool { true }
    var fittedWidth: CGFloat { ceil(("⏎  " + title as NSString).size(withAttributes: [.font: Self.font]).width) + 28 }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        Neon.accent.withAlphaComponent(0.14).setFill(); path.fill()
        Neon.accent.withAlphaComponent(0.65).setStroke(); path.lineWidth = 1.2; path.stroke()
        let text = "⏎  " + title
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Neon.text]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
    }
}
