import AppKit

// MARK: - App opener
//
//                      ┃  (her rope, from the notch)
//                   (Zera)  paws on the window
//  ╭──────────────────────────────────────────────────────────╮
//  │ (🔍) Open an app…                                         │  ← the root
//  │  ┃                                │                      │
//  │  ┣━ YOUR USUAL                    │      [ Safari ]      │
//  │  ┃   ┣━ [S] Safari       ● Running│      Application     │
//  │  ┃   ┗━ [C] Code                  │  Status   Running    │
//  │  ┣━ COMMANDS · 4                  │  Version  18.0       │
//  │  ┗━ ACTIONS · 8                   │  [ Open Safari  ⏎ ]  │
//  │ ↑↓ choose  ⇥ next branch          │  [ Actions     ⌘K ]  │
//  ╰──────────────────────────────────────────────────────────╯
//
// Its own floating window, held by Zera from the notch. The search is the root of a tree: the
// branches fold open under it, the path to the chosen item is lit, ⌘K grows the item's
// actions as its children, and a command (Kill Process, Quit All…) opens into its own list.

private enum OP {
    static let cardW: CGFloat = 780
    static let cardH: CGFloat = 560
    static let margin: CGFloat = 40           // room for the glow
    static let width: CGFloat = cardW + margin * 2
    static let ropeGap: CGFloat = 34          // notch → her head
    static let zeraW: CGFloat = 96
    static let paws: CGFloat = 9              // how far her paws overlap the window
    static let tiles = 9                      // visible items, numbered left to right
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
    /// The look: the orbit in the middle of a dimmed screen (v2), or the classic tree window.
    enum Style: Int { case orbit, tree }
    private static let styleKey = "appOpener.style"
    static var style: Style {
        get { Style(rawValue: UserDefaults.standard.integer(forKey: styleKey)) ?? .orbit }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }
    private static let keepKey = "appOpener.keepRunning"
    /// Apps Quit All leaves open (bundle IDs), remembered between runs.
    static var keepRunning: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: keepKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: keepKey) }
    }
}

/// Owns the opener's panel: shows it under the notch, closes it, launches apps.
final class AppOpener: NSObject, NSWindowDelegate {
    let panel: FloatingPanel
    private lazy var orbitView = AppOpenerView()
    private lazy var treeView = TreeOpenerView()
    /// The look chosen in Settings, picked each time it opens.
    private var view: OpenerSurface?
    private(set) var isOpen = false
    private var presentationID = 0
    private var closeWork: DispatchWorkItem?
    /// Hide / show the hanging Zera while this Zera is down.
    var onOpenChanged: ((Bool) -> Void)?
    var onLaunched: ((AppEntry) -> Void)?
    /// Something for Zera to say once she's back up ("copied the path ✨").
    var onNotice: ((String) -> Void)?
    /// One of Zera's actions was chosen; it runs once she's back up.
    var onAction: ((QuickAction) -> Void)?

    override init() {
        panel = FloatingPanel.make(size: NSSize(width: OP.width, height: 700),
                                   level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 4), keyable: true)
        super.init()
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.onKeyDown = { [weak self] event in
            guard let self = self else { return false }
            if !self.isOpen {
                // A second Esc can dismiss an exit animation immediately.
                if event.keyCode == 53, self.panel.isVisible { self.finishClose(self.presentationID); return true }
                return false
            }
            return self.view?.handleKeyEvent(event) ?? false
        }
    }

    deinit { closeWork?.cancel() }

    private func wire(_ view: OpenerSurface) {
        view.onLaunch = { [weak self] app, finder in self?.launch(app, inFinder: finder) }
        view.onSearchWeb = { [weak self] q in self?.searchWeb(q) }
        view.onClose = { [weak self] in self?.close() }
        view.onFinish = { [weak self] notice in
            self?.close()
            guard let notice = notice else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.onNotice?(notice) }
        }
        view.onQuitAll = { [weak self] apps in self?.quitAll(apps) }
        view.onAction = { [weak self] a in
            SoundService.shared.play(.openerLaunch)
            self?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.onAction?(a) }
        }
    }

    func toggle(notch: NSRect, screen: NSRect) { isOpen ? close() : open(notch: notch, screen: screen) }

    func open(notch: NSRect, screen: NSRect) {
        guard !isOpen else { return }
        closeWork?.cancel(); closeWork = nil
        presentationID += 1
        let id = presentationID
        isOpen = true
        // The app you're in now goes to the end of Your usual (its panel never takes focus).
        AppCatalog.shared.current = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0.bundleURL }
        onOpenChanged?(true)
        let band = max(24, notch.height)
        let tree = AppOpenerSettings.style == .tree
        let view: OpenerSurface = tree ? treeView : orbitView
        self.view = view
        wire(view)
        if panel.contentView !== view { panel.contentView = view }
        if tree {
            // Classic: a window held by Zera under the notch.
            let size = NSSize(width: OP.width, height: treeView.panelHeight(band: band))
            let x = max(screen.minX, min(screen.maxX - size.width, notch.midX - size.width / 2))
            panel.setFrame(NSRect(x: x, y: screen.maxY - size.height, width: size.width, height: size.height), display: false)
            view.ropeX = notch.midX - x
        } else {
            // v2: it covers the whole screen — dimmed and blurred — with the search in the middle.
            panel.setFrame(screen, display: false)
            view.ropeX = notch.midX - screen.minX
        }
        view.band = band
        view.prepare()
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        view.animateIn()
        SoundService.shared.play(.openerDrop)
        AppCatalog.shared.refreshIfNeeded { [weak self] in
            guard let self = self, self.isOpen, self.presentationID == id else { return }
            self.view?.reload()
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        let id = presentationID
        view?.animateOut {}
        // Closing cannot depend on a Core Animation completion: it can be interrupted.
        let work = DispatchWorkItem { [weak self] in self?.finishClose(id) }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration(0.3), execute: work)
    }

    private func finishClose(_ id: Int) {
        guard !isOpen, presentationID == id, closeWork != nil else { return }
        closeWork?.cancel(); closeWork = nil
        panel.orderOut(nil)
        // Detach hidden content so its layers and field editor do not keep rendering.
        panel.contentView = nil
        onOpenChanged?(false)
    }

    private func launch(_ app: AppEntry, inFinder: Bool) {
        if inFinder {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
            close()
            return
        }
        AppCatalog.shared.noteOpened(app)
        SoundService.shared.play(.openerLaunch)
        let id = presentationID
        view?.toss(app) { [weak self] in
            guard let self = self, self.isOpen, self.presentationID == id else { return }
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
            self.close()
            self.onLaunched?(app)
        }
    }

    /// Asks each app to quit (they can still ask to save), then says which ones held out.
    private func quitAll(_ apps: [NSRunningApplication]) {
        apps.forEach { $0.terminate() }
        SoundService.shared.play(.clipClear)
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.onNotice?("quitting \(apps.count) app\(apps.count == 1 ? "" : "s") 🧹")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            let left = apps.filter { !$0.isTerminated }.compactMap(\.localizedName)
            guard !left.isEmpty else { self?.onNotice?("all clean ✨"); return }
            let names = left.count <= 2 ? left.joined(separator: " and ") : "\(left[0]) and \(left.count - 1) more"
            self?.onNotice?("\(names) still open, maybe unsaved work")
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

/// The content: rope, Zera holding the opener, and the opener itself: a window whose search
/// is the root of a tree. Branches (Your usual, Commands, Actions) fold open under it, the path
/// to the chosen item lights up, ⌘K grows the chosen item's actions as its children, and a
/// command opens into its own list. The chosen item's details sit on the right.
final class AppOpenerView: NSView, NSTextFieldDelegate {
    var onLaunch: ((AppEntry, Bool) -> Void)?
    var onSearchWeb: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onAction: ((QuickAction) -> Void)?
    /// Done here: close, and have Zera say this (if anything) once she's back up.
    var onFinish: ((String?) -> Void)?
    var onQuitAll: (([NSRunningApplication]) -> Void)?
    var band: CGFloat = 32
    var ropeX: CGFloat = 0

    private let rope = NSView()
    private let holder = OpenerFlipped()
    private let zera = NSImageView()
    private let mascotMask = CAGradientLayer()
    /// The dimmed, blurred screen behind it all.
    private let veil = OpenerVeil()
    // The search: a glowing pill under her paws.
    private let searchBar = OpenerGlass()
    private let searchIcon = NSImageView()
    private let chip = OpenerPill()
    private let field = NSTextField()
    private let rightLabel = NSTextField(labelWithString: "")
    private let settingsButton = TreeButton()
    // Your usual · Commands · Actions.
    private let lanes = OpenerLanes()
    // The arc of results. ⌘K opens the chosen item's actions as a list node.
    private let orbit = OpenerFlipped()
    private let arcLine = CAShapeLayer()
    private let arcFade = CAGradientLayer()
    private let arcNodes = CAShapeLayer()
    private let arcSelectedNode = CAShapeLayer()
    private var tiles: [String: OrbitTile] = [:]
    private var captions: [String: OrbitCaption] = [:]
    private var quickIndices: [Int] = []
    private var commandHints = false
    private var modifierMonitor: Any?
    private let actionPanel = OpenerGlass()
    private let actionIcon = NSImageView()
    private let actionHeading = NSTextField(labelWithString: "")
    private let actionCount = NSTextField(labelWithString: "")
    private let actionDivider = NSView()
    private let actionScroll = NSScrollView()
    private let actionDoc = OpenerFlipped()
    private let actionBranch = CAShapeLayer()
    private let actionEmpty = NSTextField(labelWithString: "No matching actions")
    private var actionRows: [TreeRowView] = []
    private var orbitBounds = NSRect.zero
    // The chosen item, under the arc.
    private let dName = NSTextField(labelWithString: "")
    private let dMeta = NSTextField(labelWithString: "")
    private let detailCard = OpenerGlass()
    private let detailIcon = NSImageView()
    private let dPrimary = TreeButton()
    private let dSecondary = TreeButton()
    /// Pin / Unpin for the chosen app, beside Actions, so the shortcut is in plain sight.
    private let dPin = TreeButton()
    private let dEmpty = NSTextField(wrappingLabelWithString: "")
    // Quiet keyboard guidance below the primary actions.
    private let foot = OpenerFooter(labelWithString: "")

    /// The branches under the root.
    private enum Branch: Int, CaseIterable {
        case usual, commands, actions
        var title: String { ["YOUR USUAL", "COMMANDS", "ACTIONS"][rawValue] }
    }
    /// Each branch with what's in it (matches, while typing) and how many there are in all.
    private var branches: [(branch: Branch, items: [OpenerItem], total: Int)] = []
    /// The open branch (every branch opens while you type).
    private var openBranch: Branch = .usual
    /// Everything you can choose, top to bottom: the items of the open branches.
    private var results: [OpenerItem] = []
    /// The chosen item (or, inside a command, the chosen row of its list).
    private var selected = 0
    private var typing: Bool { !query.isEmpty }
    private var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    /// Browsing the tree, or inside a command (Kill Process, Kill Port, Quit All, Custom).
    private enum Mode: Equatable { case root, command(OpenerCommand) }
    private var mode: Mode = .root
    private var processes: [ProcessEntry] = []
    private var ports: [PortEntry] = []
    /// One row in a command's list.
    private struct ListItem {
        var title: String, detail: String, trailing: String
        var pid: Int32
        var path = ""
        var port: Int?
        var app: NSRunningApplication?
        var keep = false
    }
    private var listItems: [ListItem] = []
    /// Quit All: the open apps it would close (kept ones included, marked).
    private var runningApps: [NSRunningApplication] = []
    private var loading = false
    private var commandScan = UUID()

    /// ⌘K: the chosen item's actions, grown as its children. The search field filters them.
    private var actionsOpen = false
    private var allActions: [PanelAction] = []
    private var shownActions: [PanelAction] = []
    private var leaf = 0
    private var confirming: Int?
    private var savedQuery = ""
    private var flashToken = UUID()
    private var exitAnimationID = 0
    private var deferringOrbitLayout = false
    private var actionTransitionID = 0
    private var actionFlight: NSImageView?

    private var versions: [URL: String] = [:]

    var isShowingActions: Bool { actionsOpen }
    var chosenActionTitle: String? { actionsOpen ? shownActions[safe: leaf]?.title : nil }
    var openBranchTitle: String { effectiveBranch.title }
    /// What's on the arc, in order, with the chosen item's actions right after it when open.
    var visibleRowTitles: [String] {
        switch mode {
        case .root:
            var t = results.map(\.name)
            if actionsOpen { t.insert(contentsOf: shownActions.map(\.title), at: min(t.count, selected + 1)) }
            return t
        case .command(let c):
            var t = [c.title] + listItems.map(\.title)
            if actionsOpen { t.insert(contentsOf: shownActions.map(\.title), at: min(t.count, selected + 2)) }
            return t
        }
    }

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
    private var verticalOffset: CGFloat { min(100, max(-60, (bounds.height - 760) / 2)) }
    private var cardTop: CGFloat {
        let below: CGFloat = actionsOpen ? min(72 + actionContentHeight, bounds.height - 220) + 40 : 392
        return max(104, (bounds.height - (zeraH + OV.searchH + below)) / 2 + zeraH - OP.paws)
    }
    private var cx: CGFloat { ropeX > 0 ? ropeX : bounds.width / 2 }
    func panelHeight(band: CGFloat) -> CGFloat { self.band = band; return cardTop + OP.cardH + OP.margin }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        veil.frame = bounds
        veil.autoresizingMask = [.width, .height]
        veil.onClick = { [weak self] in self?.onClose?() }
        addSubview(veil)

        // The same rope her picture holds: a strip of it, repeated all the way up to the notch.
        rope.wantsLayer = true
        rope.layer?.backgroundColor = (ropePattern().map { NSColor(patternImage: $0) }
            ?? sprite?.ropeColor ?? NSColor(srgbRed: 0.36, green: 0.23, blue: 0.13, alpha: 1)).cgColor
        rope.isHidden = true
        addSubview(rope)
        holder.wantsLayer = true
        holder.layer?.masksToBounds = false
        addSubview(holder)

        settingsButton.symbol = "gearshape"
        settingsButton.key = ""
        settingsButton.openerAppearance = true
        settingsButton.setAccessibilityLabel("Settings")
        settingsButton.onClick = { [weak self] in
            self?.onClose?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.sendAction(NSSelectorFromString("showSettings"), to: NSApp.delegate, from: nil)
            }
        }
        holder.addSubview(settingsButton)

        // The search pill.
        searchBar.radius = OV.searchH / 2
        searchBar.lineWidth = 1
        searchBar.glow = 0
        holder.addSubview(searchBar)
        searchBar.addSubview(searchIcon)
        chip.key = "‹"
        chip.ghost = true
        chip.isHidden = true
        chip.onClick = { [weak self] in self?.collapse() }
        searchBar.addSubview(chip)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = OpenerLook.searchFont
        field.placeholderAttributedString = NSAttributedString(string: "Search apps, commands, or actions…", attributes: [
            .foregroundColor: OpenerLook.muted, .font: OpenerLook.searchFont])
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("App name")
        searchBar.addSubview(field)
        rightLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        rightLabel.alignment = .right
        searchBar.addSubview(rightLabel)

        lanes.onSelect = { [weak self] i in self?.laneTapped(i) }
        holder.addSubview(lanes)

        // The arc: a faint line the items ride on.
        orbit.wantsLayer = true
        orbit.layer?.masksToBounds = false
        arcLine.fillColor = nil
        arcLine.lineWidth = 1
        arcLine.lineCap = .round
        arcFade.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        arcFade.locations = [0, 0.08, 0.92, 1]
        arcFade.startPoint = CGPoint(x: 0, y: 0.5)
        arcFade.endPoint = CGPoint(x: 1, y: 0.5)
        arcLine.mask = arcFade
        orbit.layer?.addSublayer(arcLine)
        arcNodes.fillColor = NSColor.white.withAlphaComponent(0.3).cgColor
        arcSelectedNode.fillColor = OpenerLook.accent.cgColor
        arcSelectedNode.shadowColor = OpenerLook.accent.cgColor
        arcSelectedNode.shadowOpacity = 0.85
        arcSelectedNode.shadowRadius = 8
        arcSelectedNode.shadowOffset = .zero
        orbit.layer?.addSublayer(arcNodes)
        orbit.layer?.addSublayer(arcSelectedNode)
        holder.addSubview(orbit)

        actionPanel.radius = 18
        actionPanel.lineWidth = 1
        actionPanel.glow = 0.06
        actionPanel.isHidden = true
        holder.addSubview(actionPanel)
        actionIcon.imageScaling = .scaleProportionallyUpOrDown
        actionPanel.addSubview(actionIcon)
        actionHeading.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        actionHeading.wantsLayer = true
        actionHeading.lineBreakMode = .byTruncatingTail
        actionPanel.addSubview(actionHeading)
        actionCount.font = Typo.count
        actionCount.wantsLayer = true
        actionCount.alignment = .right
        actionPanel.addSubview(actionCount)
        actionDivider.wantsLayer = true
        actionPanel.addSubview(actionDivider)
        actionScroll.drawsBackground = false
        actionScroll.borderType = .noBorder
        actionScroll.hasVerticalScroller = true
        actionScroll.autohidesScrollers = true
        actionDoc.wantsLayer = true
        actionBranch.fillColor = nil
        actionBranch.lineWidth = 1
        actionDoc.layer?.addSublayer(actionBranch)
        actionScroll.documentView = actionDoc
        actionPanel.addSubview(actionScroll)
        actionEmpty.font = Typo.body
        actionEmpty.alignment = .center
        actionDoc.addSubview(actionEmpty)

        detailCard.radius = OpenerLook.cardRadius
        detailCard.lineWidth = 1
        detailCard.glow = 0
        detailCard.isHidden = true
        holder.addSubview(detailCard)
        detailIcon.imageScaling = .scaleProportionallyUpOrDown
        detailIcon.isHidden = true
        holder.addSubview(detailIcon)
        dName.font = OpenerLook.detailFont
        dName.alignment = .center
        dName.lineBreakMode = .byTruncatingTail
        holder.addSubview(dName)
        dMeta.alignment = .center
        dMeta.lineBreakMode = .byTruncatingMiddle
        holder.addSubview(dMeta)
        dPrimary.primary = true
        dPrimary.labelFont = OpenerLook.buttonFont
        dPrimary.onClick = { [weak self] in self?.primaryAction() }
        dSecondary.key = "⌘K"
        dSecondary.title = "Actions"
        dSecondary.labelFont = Typo.bodyMedium
        dSecondary.onClick = { [weak self] in self?.toggleActions() }
        dPin.key = "⇧⌘P"
        dPin.labelFont = Typo.bodyMedium
        dPin.onClick = { [weak self] in self?.togglePinChosen() }
        [dPrimary, dSecondary, dPin].forEach { $0.openerAppearance = true; holder.addSubview($0) }
        dEmpty.font = NSFont.systemFont(ofSize: 14)
        dEmpty.alignment = .center
        holder.addSubview(dEmpty)

        foot.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        foot.alignment = .center
        foot.lineBreakMode = .byTruncatingTail
        holder.addSubview(foot)

        zera.image = sprite?.image
        zera.imageScaling = .scaleProportionallyUpOrDown
        zera.wantsLayer = true
        mascotMask.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor]
        mascotMask.locations = [0, 0.28, 1]
        mascotMask.startPoint = CGPoint(x: 0.5, y: 1)
        mascotMask.endPoint = CGPoint(x: 0.5, y: 0)
        zera.layer?.mask = mascotMask
        holder.addSubview(zera)
        setAccessibilityRole(.group)
        setAccessibilityLabel("App opener")
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Colours from the current theme. Runs each time the opener opens, so a theme picked in
    /// Settings shows up here too.
    private func applyTheme() {
        searchBar.fill = OpenerLook.surface.withAlphaComponent(0.72)
        searchBar.edge = NSColor.white.withAlphaComponent(0.10)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular).applying(.init(paletteColors: [OpenerLook.muted])))
        field.textColor = Neon.text
        rightLabel.textColor = Neon.textDim
        arcLine.strokeColor = NSColor.white.withAlphaComponent(0.06).cgColor
        actionPanel.fill = OpenerLook.surface.withAlphaComponent(0.96)
        actionPanel.edge = OpenerLook.edge
        actionHeading.textColor = Neon.text
        actionCount.textColor = Neon.textFaint
        actionDivider.layer?.backgroundColor = Neon.divider.cgColor
        actionBranch.strokeColor = Neon.accent.withAlphaComponent(0.28).cgColor
        actionEmpty.textColor = Neon.textDim
        detailCard.fill = NSColor.white.withAlphaComponent(0.04)
        detailCard.gradient = nil
        detailCard.edge = OpenerLook.edge
        dName.textColor = Neon.text
        dEmpty.textColor = Neon.textDim
        foot.textColor = Neon.textDim
        tiles.values.forEach { $0.needsDisplay = true }
        captions.values.forEach { $0.needsDisplay = true }
        ([searchBar, chip, lanes, actionPanel, detailCard, dPrimary, dSecondary, dPin, veil] as [NSView]).forEach { $0.needsDisplay = true }
    }

    // MARK: Data

    func prepare() {
        resetActionTransition()
        commandHints = NSEvent.modifierFlags.contains(.command)
        applyTheme()
        actionsOpen = false
        mode = .root
        commandScan = UUID()
        loading = false
        openBranch = .usual
        field.stringValue = ""
        setPlaceholder("Search apps, commands, or actions…")
        selected = 0
        needsLayout = true
        layoutSubtreeIfNeeded()
        reload()
    }

    // For the tour recording: what a person would do with the keyboard.
    func previewType(_ text: String) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    func previewActions() { toggleActions() }
    func previewMove(_ by: Int) { move(by) }

    private func setPlaceholder(_ text: String) {
        if let p = field.placeholderAttributedString?.mutableCopy() as? NSMutableAttributedString {
            p.mutableString.setString(text)
            field.placeholderAttributedString = p
        }
    }

    /// The open branch, or the first one with anything in it.
    private var effectiveBranch: Branch {
        if branches.contains(where: { $0.branch == openBranch }) { return openBranch }
        return branches.first?.branch ?? .usual
    }

    func reload() {
        if case .command(let c) = mode { reloadList(c); return }
        if actionsOpen { rebuild(); return }
        let q = query
        let apps = AppCatalog.shared.results(for: q, runningFirst: AppOpenerSettings.runningFirst, limit: typing ? 8 : 7)
            .map { OpenerItem.app($0.app, hits: $0.hits, running: $0.running) }
        let commands = OpenerCommand.allCases.compactMap { c -> (OpenerItem, Int)? in
            if !typing { return (.command(c, hits: []), 0) }
            return c.match(q).map { (.command(c, hits: $0.hits), $0.score) }
        }.sorted { $0.1 > $1.1 }.map(\.0)
        let actions = OpenerActions.all.compactMap { a -> (OpenerItem, Int)? in
            if !typing { return (.action(a, hits: []), 0) }
            return OpenerActions.match(a, q).map { (.action(a, hits: $0.hits), $0.score) }
        }.sorted { $0.1 > $1.1 }.map(\.0)
        branches = [(Branch.usual, apps, apps.count),
                    (Branch.commands, typing ? Array(commands.prefix(4)) : commands, commands.count),
                    (Branch.actions, typing ? Array(actions.prefix(4)) : actions, actions.count)].filter { !$0.1.isEmpty }
        results = branches.filter { typing || $0.branch == effectiveBranch }.flatMap(\.items)
        selected = min(selected, max(0, results.count - 1))
        zera.frameCenterRotation = results.isEmpty && typing ? 10 : 0     // a puzzled head-tilt
        rightLabel.textColor = Neon.textDim
        rightLabel.stringValue = typing ? (results.isEmpty ? "NO MATCHES" : "\(results.count) FOUND") : ""
        rebuild()
    }

    private var verb: String {
        if let r = results[safe: selected], !r.isApp { return "Run" }
        return "Open"
    }

    // MARK: The tree

    /// One thing on the arc.
    private struct OrbitEntry {
        let key: String
        let style: OrbitTile.Style
        let icon: NSImage?
        let title: String
        var detail = "", trailing = ""
        var running = false, pinned = false, kept = false
    }

    private func orbitEntry(at index: Int) -> OrbitEntry {
        switch mode {
        case .root:
            let it = results[index]
                switch it {
                case .app(let a, _, let running):
                    return OrbitEntry(key: "app:" + a.url.path, style: .icon, icon: it.icon, title: a.name,
                                      running: running, pinned: AppCatalog.shared.isPinned(a))
                case .command(let c, _): return OrbitEntry(key: "cmd:" + c.title, style: .icon, icon: it.icon, title: c.title)
                case .action(let a, _): return OrbitEntry(key: "act:" + OpenerActions.title(a), style: .icon, icon: it.icon, title: it.name)
                }
        case .command(let c):
            let it = listItems[index]
                if c == .quitAll {
                    return OrbitEntry(key: "quit:\(it.pid)", style: .icon, icon: it.app?.icon, title: it.title, kept: it.keep)
                }
                return OrbitEntry(key: "\(c.title):\(it.pid):\(it.port ?? 0)", style: .card, icon: nil, title: it.title,
                                  detail: it.detail, trailing: it.trailing)
        }
    }

    /// Puts what's showing on the arc, the chosen one in the middle; the chosen item's details
    /// and the hints follow.
    private func rebuild() {
        updateLanes()
        updateActionRows()
        updateDetail()
        updateFooter()
        deferringOrbitLayout = true
        layoutSubtreeIfNeeded()
        deferringOrbitLayout = false
        placeOrbit(animated: window != nil)
    }

    private func emptyNote(_ c: OpenerCommand) -> String {
        let q = query
        switch c {
        case .custom: return "Coming soon: your own scripts as commands."
        case .quitAll: return q.isEmpty ? "Nothing to quit: only Finder and Zera are open." : "No open app matches “\(q)”."
        case .killPort: return loading ? "Looking…" : (q.isEmpty ? "Nothing is listening on a port." : "Nothing is listening on \(q).")
        case .killProcess: return loading ? "Looking…" : "No process matches “\(q)”."
        }
    }

    /// The centre of the chosen tile, in the holder.
    private var orbitDrop: CGFloat { OV.orbitDrop }
    private var orbitCenter: NSPoint { NSPoint(x: orbit.frame.midX, y: orbit.frame.minY + orbitDrop) }

    /// Each item to its place on the arc (gliding there when `animated`), new ones fading in,
    /// ones that left fading out.
    private func placeOrbit(animated: Bool) {
        orbit.isHidden = actionsOpen
        if actionsOpen { return }
        let n = mode == .root ? results.count : listItems.count
        let anim = animated && !Motion.reduced
        let quick = mode == .root && !actionsOpen
        let compact = bounds.height < 700
        let c = NSPoint(x: orbit.bounds.midX, y: orbitDrop)
        var keep = Set<String>()
        var moves: [(OrbitTile, NSRect, CGFloat)] = []
        var captionKeep = Set<String>()
        var captionMoves: [(OrbitCaption, NSRect, CGFloat)] = []
        func arcIndex(_ i: Int) -> Int {
            var k = i - selected
            if n >= 3 {
                k = ((k % n) + n) % n
                if k > n / 2 { k -= n }
            }
            return k
        }
        quickIndices = (0..<n).filter { abs(arcIndex($0)) <= OrbitArc.reach }.sorted { arcIndex($0) < arcIndex($1) }
        for i in 0..<n {
            // The arc wraps round, so the chosen one always has neighbours on both sides.
            var k = i - selected
            if n >= 3 {
                k = ((k % n) + n) % n
                if k > n / 2 { k -= n }
            }
            guard abs(k) <= OrbitArc.reach else { continue }
            // Resolve Finder icons only for the visible arc, not every search result.
            let e = orbitEntry(at: i)
            keep.insert(e.key)
            let isNew = tiles[e.key] == nil
            let tile = tiles[e.key] ?? OrbitTile()
            tiles[e.key] = tile
            if tile.superview == nil { orbit.addSubview(tile) }
            tile.style = e.style
            tile.icon = e.icon
            tile.title = e.title
            tile.detail = e.detail
            tile.trailing = e.trailing
            tile.running = e.running
            tile.pinned = e.pinned
            tile.kept = e.kept
            tile.chosen = k == 0
            tile.quickKey = nil
            tile.onClick = { [weak self] in self?.tileTapped(i) }
            let off = OrbitArc.offset(k)
            let sc = OrbitArc.scale(k) * (e.style == .card ? (k == 0 ? 0.9 : 0.85) : 1)
            let base = OrbitTile.base(e.style)
            let spread: CGFloat = e.style == .card ? 1.75 : min(1, (orbit.bounds.width - 120) / (CGFloat(max(1, min(n / 2, OrbitArc.reach))) * OrbitArc.step * 2))
            let w = base.width * sc, h = base.height * sc
            let arcY = off.y
            let f = NSRect(x: (c.x + off.x * spread - w / 2).rounded(), y: (c.y + arcY - h / 2).rounded(), width: w.rounded(), height: h.rounded())
            let alpha = OrbitArc.alpha(k)
            let wrapsAcrossArc = anim && abs(tile.frame.midX - f.midX) > OrbitArc.step * 3
            if isNew {
                tile.frame = anim ? NSRect(x: c.x - w * 0.4, y: c.y - h * 0.4, width: w * 0.8, height: h * 0.8) : f
                tile.alphaValue = anim ? 0 : alpha
            } else if wrapsAcrossArc {
                tile.frame = f
                tile.alphaValue = 0
            } else if !anim {
                tile.frame = f
                tile.alphaValue = alpha
            }
            moves.append((tile, f, alpha))
            if quick, e.style == .icon {
                captionKeep.insert(e.key)
                let caption = captions[e.key] ?? OrbitCaption()
                let isNewCaption = captions[e.key] == nil
                captions[e.key] = caption
                if caption.superview == nil { orbit.addSubview(caption) }
                caption.title = e.title
                let rank = quickIndices.firstIndex(of: i).map { $0 + 1 } ?? 0
                caption.key = (1...OP.tiles).contains(rank) ? "⌘\(rank)" : ""
                caption.showKey = commandHints || k == 0
                caption.running = e.running
                caption.chosen = k == 0
                caption.compact = compact
                caption.onClick = { [weak self] in self?.tileTapped(i) }
                caption.setAccessibilityLabel(e.title)
                let cw: CGFloat = 96
                let ch: CGFloat = 54
                let cf = NSRect(x: f.midX - cw / 2, y: f.maxY + 4, width: cw, height: ch)
                let captionAlpha = max(0.82, alpha)
                if isNewCaption {
                    caption.frame = anim ? NSRect(x: c.x - cw / 2, y: c.y, width: cw, height: ch) : cf
                    caption.alphaValue = anim ? 0 : captionAlpha
                } else if wrapsAcrossArc { caption.frame = cf; caption.alphaValue = anim ? 0 : captionAlpha }
                else if !anim { caption.frame = cf; caption.alphaValue = captionAlpha }
                captionMoves.append((caption, cf, captionAlpha))
            }
        }
        // The chosen one sits on top.
        if let chosen = moves.first(where: { $0.0.chosen })?.0 { orbit.addSubview(chosen, positioned: .above, relativeTo: nil) }
        for (key, t) in tiles where !keep.contains(key) {
            tiles[key] = nil
            if anim {
                NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.18; t.animator().alphaValue = 0 },
                                                     completionHandler: { t.removeFromSuperview() })
            } else { t.removeFromSuperview() }
        }
        for (key, caption) in captions where !captionKeep.contains(key) {
            captions[key] = nil
            if anim {
                NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.18; caption.animator().alphaValue = 0 },
                                                     completionHandler: { caption.removeFromSuperview() })
            } else { caption.removeFromSuperview() }
        }
        if anim {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                for (t, f, a) in moves { t.animator().frame = f; t.animator().alphaValue = a }
                for (caption, f, a) in captionMoves { caption.animator().frame = f; caption.animator().alphaValue = a }
            }
        } else {
            for (t, f, a) in moves { t.frame = f; t.alphaValue = a }
            for (caption, f, a) in captionMoves { caption.frame = f; caption.alphaValue = a }
        }
        // The faint arc the items ride on.
        let arc = OrbitArc.path(under: moves.map(\.1))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arcLine.frame = orbit.bounds
        let firstX = moves.map { $0.1.midX }.min() ?? 0
        let lastX = moves.map { $0.1.midX }.max() ?? orbit.bounds.width
        arcFade.frame = CGRect(x: firstX, y: 0, width: max(1, lastX - firstX), height: orbit.bounds.height)
        arcLine.path = arc
        let markers = CGMutablePath(), selectedMarker = CGMutablePath()
        let lift = (moves.map { $0.1.height }.max() ?? 0) / 2 + 14
        for (tile, frame, _) in moves {
            let size: CGFloat = tile.chosen ? 5 : 3
            let dot = CGRect(x: frame.midX - size / 2, y: frame.midY - lift - size / 2, width: size, height: size)
            (tile.chosen ? selectedMarker : markers).addEllipse(in: dot)
        }
        arcNodes.frame = orbit.bounds
        arcNodes.path = markers
        arcSelectedNode.frame = orbit.bounds
        arcSelectedNode.path = selectedMarker
        arcLine.opacity = n == 0 ? 0 : 1
        CATransaction.commit()
    }

    /// ⌘K opens the chosen item's actions as a second, searchable tree node.
    private func updateActionRows() {
        actionPanel.isHidden = !actionsOpen
        guard actionsOpen else { return }
        actionHeading.stringValue = chip.title
        switch mode {
        case .root: actionIcon.image = results[safe: selected]?.icon
        case .command(let command): actionIcon.image = listItems[safe: selected]?.app?.icon ?? command.icon
        }
        actionCount.stringValue = "\(shownActions.count) \(shownActions.count == 1 ? "ACTION" : "ACTIONS")"
        let changed = actionRows.count != shownActions.count || zip(actionRows, shownActions).contains { $0.0.accessibilityLabel() != $0.1.title }
        if changed {
            actionRows.forEach { $0.removeFromSuperview() }
            actionRows = shownActions.map { _ in TreeRowView(style: .leaf) }
            actionRows.forEach { actionDoc.addSubview($0) }
        }
        for (k, a) in shownActions.enumerated() {
            let row = actionRows[k]
            let ask = confirming == k
            row.symbol = ask ? "exclamationmark.triangle.fill" : a.symbol
            row.tint = ask ? Neon.red : a.tint
            row.titleText = NSAttributedString(string: ask ? (a.confirm ?? a.title) : a.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: ask ? Neon.red : (a.tint ?? Neon.text)])
            row.accessoryKeycap = true
            row.accessory = ask ? "⏎ confirm" : (a.shortcut?.label ?? (k == leaf ? "⏎" : ""))
            row.selected = k == leaf
            row.capturesContentClicks = true
            row.setAccessibilityElement(true)
            row.setAccessibilityLabel(a.title)
            row.onClick = { [weak self] in self?.triggerLeaf(k) }
        }
        actionEmpty.isHidden = !shownActions.isEmpty
        needsLayout = true
    }

    private func tileTapped(_ i: Int) {
        switch mode {
        case .root:
            if i == selected, !actionsOpen { openSelected() } else { choose(i) }
        case .command(let c):
            chooseChild(i)
            if c == .quitAll { toggleKeep() }
        }
    }

    /// The lanes: which branch shows (typing shows them all; a lane then jumps to its matches).
    private func updateLanes() {
        let show = mode == .root && !actionsOpen && !branches.isEmpty
        lanes.isHidden = !show
        guard show else { return }
        lanes.lanes = branches.map { OpenerLanes.Lane(title: typing && $0.branch == .usual ? "Apps" : $0.branch.title.capitalized, count: typing ? $0.items.count : $0.total) }
        if typing {
            var start = 0, lane = 0
            for (n, b) in branches.enumerated() { if selected >= start { lane = n }; start += b.items.count }
            lanes.selected = lane
        } else {
            lanes.selected = branches.firstIndex { $0.branch == effectiveBranch } ?? 0
        }
        needsLayout = true
    }

    private func laneTapped(_ i: Int) {
        guard let b = branches[safe: i] else { return }
        if typing {
            var start = 0
            for n in 0..<i { start += branches[n].items.count }
            choose(start)
            return
        }
        openBranchTapped(b.branch)
    }

    private func choose(_ i: Int) {
        guard results.indices.contains(i) else { return }
        let wasOpen = actionsOpen
        if wasOpen { closeActions(refocus: true, rebuildTree: false) }
        guard i != selected || wasOpen else { return }
        selected = i
        SoundService.shared.play(.openerTick)
        rebuild()
    }

    private func chooseChild(_ k: Int) {
        guard listItems.indices.contains(k), k != selected || actionsOpen else { return }
        if actionsOpen { closeActions(refocus: true, rebuildTree: false) }
        selected = k
        SoundService.shared.play(.openerTick)
        rebuild()
    }

    private func openBranchTapped(_ b: Branch) {
        if case .command = mode { back(); return }
        guard !typing else { return }
        closeActions(refocus: true, rebuildTree: false)
        let from = branches.firstIndex { $0.branch == effectiveBranch } ?? 0
        openBranch = b
        selected = 0
        SoundService.shared.play(.openerTick)
        reload()
        // Like every tab switch: the new lane's items come in from the side you moved toward.
        let to = branches.firstIndex { $0.branch == effectiveBranch } ?? 0
        Motion.tabSwitch([orbit], from: from, to: to)
    }

    /// ⇥: the next branch along opens (while typing, the chosen item jumps to its first match).
    private func nextBranch(_ d: Int) {
        guard mode == .root, !branches.isEmpty else { return }
        if typing {
            var start = 0, starts: [Int] = []
            for b in branches { starts.append(start); start += b.items.count }
            let cur = starts.lastIndex { $0 <= selected } ?? 0
            choose(starts[(cur + d + starts.count) % starts.count])
            return
        }
        let ids = branches.map(\.branch)
        let cur = ids.firstIndex(of: effectiveBranch) ?? 0
        openBranchTapped(ids[(cur + d + ids.count) % ids.count])
    }

    private func move(_ d: Int) {
        if actionsOpen {
            guard !shownActions.isEmpty else { return }
            leaf = (leaf + d + shownActions.count) % shownActions.count
            confirming = nil
            SoundService.shared.play(.openerTick)
            rebuild()
            return
        }
        if case .command = mode {
            guard !listItems.isEmpty else { return }
            chooseChild(max(0, min(listItems.count - 1, selected + d)))
            return
        }
        guard !results.isEmpty else { return }
        choose((selected + d + results.count) % results.count)
    }

    // MARK: The chosen item

    private func version(_ app: AppEntry) -> String {
        if let v = versions[app.url] { return v }
        let v = (Bundle(url: app.url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
        versions[app.url] = v
        return v
    }

    /// Under the arc: the chosen item's name, a line about it, and its buttons.
    private func updateDetail() {
        if actionsOpen {
            ([detailCard, detailIcon, dName, dMeta, dPrimary, dSecondary, dPin, dEmpty] as [NSView])
                .forEach { $0.isHidden = true }
            needsLayout = true
            return
        }
        var name = "", status: (String, NSColor)? = nil, facts: [String] = []
        var primary = "", primaryTint: NSColor? = nil
        switch mode {
        case .root:
            if let it = results[safe: selected] {
                name = it.name
                switch it {
                case .app(let a, _, let running):
                    status = running ? ("Running", Neon.green) : ("Not running", OpenerLook.muted)
                    let v = version(a)
                    facts = (v == "—" ? [] : ["v" + v]) + [a.folder]
                    primary = "Open app"
                case .command(let c, _):
                    status = ("Command", Neon.accent)
                    facts = [c.subtitle.replacingOccurrences(of: "Command · ", with: "").capitalizedFirst]
                    primary = "Open command"
                case .action(let a, _):
                    status = ("Zera action", Neon.accent)
                    facts = [OpenerActions.subtitle(a).replacingOccurrences(of: "Action · ", with: "").capitalizedFirst]
                    primary = "Run"
                }
            }
        case .command(let c):
            let it = listItems[safe: selected]
            name = it?.title ?? c.title
            switch c {
            case .quitAll:
                let n = quitTargets.count
                if let it = it { status = it.keep ? ("Stays open", Neon.textFaint) : ("Will quit", Neon.warning) }
                facts = ["\(runningApps.count) open", "\(n) will quit", "Finder and Zera stay"]
                primary = n == 1 ? "Quit 1 app" : "Quit \(n) apps"
                primaryTint = Neon.green
            case .killProcess:
                if let it = it { status = (it.trailing, Neon.warning); facts = ["pid \(it.pid)", it.detail.components(separatedBy: " · ").last ?? ""]; primary = "Quit \(it.title)" }
            case .killPort:
                if let it = it { status = ("Listening", Neon.green); facts = [it.detail, it.trailing]; primary = "Stop \(it.title)" }
            case .custom:
                facts = ["Coming soon"]
            }
            if it == nil { name = c.title }
        }
        let has = !name.isEmpty && !(mode == .root && results.isEmpty)
        let cardApp = chosenApp
        let useCard = cardApp != nil && bounds.width >= 700
        detailCard.isHidden = !useCard
        detailIcon.isHidden = !useCard
        detailIcon.image = cardApp.map { AppCatalog.shared.icon($0) }
        dName.alignment = useCard ? .left : .center
        dMeta.alignment = useCard ? .left : .center
        ([dName, dMeta, dPrimary, dSecondary] as [NSView]).forEach { $0.isHidden = !has }
        dEmpty.isHidden = has && !(mode != .root && listItems.isEmpty)
        if case .command(let c) = mode, listItems.isEmpty {
            dEmpty.stringValue = emptyNote(c)
            dPrimary.isHidden = true
        } else {
            dEmpty.stringValue = typing ? "Nothing called “\(query)”.\n⏎ searches the web for it."
                : (AppCatalog.shared.apps.isEmpty ? "Looking for your apps…" : "")
        }
        dName.stringValue = name
        dName.textColor = Neon.text
        // "● Running · v27.0.1 · /Applications · opened 41 times from Zera"
        let meta = NSMutableAttributedString()
        let mf = NSFont.systemFont(ofSize: 13, weight: .regular)
        if let (t, c) = status {
            meta.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: c, .baselineOffset: 1.5]))
            meta.append(NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: c]))
        }
        for f in facts where !f.isEmpty {
            if meta.length > 0 { meta.append(NSAttributedString(string: "  ·  ", attributes: [.font: mf, .foregroundColor: OpenerLook.muted])) }
            meta.append(NSAttributedString(string: f, attributes: [.font: f.hasPrefix("pid") ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular) : mf,
                                                                   .foregroundColor: OpenerLook.muted]))
        }
        let centred = NSMutableParagraphStyle()
        centred.alignment = useCard ? .left : .center
        centred.lineBreakMode = .byTruncatingMiddle
        meta.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: meta.length))
        dMeta.maximumNumberOfLines = 1
        dMeta.attributedStringValue = meta
        dPrimary.title = primary
        dPrimary.key = "⏎"
        dPrimary.isHidden = !has || primary.isEmpty || dPrimary.isHidden
        dPrimary.tint = primaryTint
        dSecondary.title = useCard ? "" : "Actions"
        dSecondary.symbol = useCard ? "ellipsis" : nil
        dSecondary.key = useCard ? "" : "⌘M"
        dSecondary.setAccessibilityLabel("Actions, Command M or Command K")
        dSecondary.isHidden = !has || mode == .command(.custom)
        let pinnable = chosenApp
        dPin.isHidden = !has || actionsOpen || pinnable == nil
        if let a = pinnable {
            let pinned = AppCatalog.shared.isPinned(a)
            dPin.title = useCard ? "" : (pinned ? "Unpin" : "Pin")
            dPin.symbol = pinned ? "pin.fill" : "pin"
            dPin.setAccessibilityLabel(pinned ? "Unpin app" : "Pin app")
        }
        dPin.openerIconOnly = false
        dPin.tint = nil
        dPin.openerPinned = pinnable.map { AppCatalog.shared.isPinned($0) } ?? false
        dPin.toolTip = dPin.accessibilityLabel()
        dPin.key = useCard ? "" : "⇧⌘P"
        needsLayout = true
    }

    private func updateFooter() {
        if actionsOpen {
            foot.hints = [(["↑", "↓"], "Browse actions"), (["↵"], "Run"), (["esc"], "Back")]
        } else {
            switch mode {
            case .root: foot.hints = results.isEmpty ? [(["↵"], "Search the web"), (["esc"], "Close")]
                : [(["←", "→"], "Navigate"), (["⇥"], "Switch tab"), (["↵"], "Open"), (["⌘M"], "Actions"), (["esc"], "Close")]
            case .command(.quitAll): foot.hints = [(["↑", "↓"], "Navigate"), (["space"], "Keep open"), (["esc"], "Back")]
            case .command(.custom): foot.hints = [(["esc"], "Back")]
            case .command: foot.hints = [(["↑", "↓"], "Navigate"), (["⌘↵"], "Force"), (["⌘R"], "Refresh"), (["⌘M"], "Actions"), (["esc"], "Back")]
            }
        }
        if actionsOpen {
            foot.stringValue = "↑ ↓ Browse actions    ·    ⏎ Run    ·    esc Back"
            needsLayout = true
            return
        }
        switch mode {
        case .root:
            foot.stringValue = results.isEmpty ? "⏎ Search the web    ·    esc Close" : "← → Browse    ·    ⇥ Switch tab    ·    ⏎ Open    ·    ⌘M Actions    ·    esc Close"
        case .command(.quitAll): foot.stringValue = "↑ ↓ Browse    ·    space Keep open    ·    esc Back"
        case .command(.custom): foot.stringValue = "esc Back"
        case .command: foot.stringValue = "↑ ↓ Browse    ·    ⌘⏎ Force    ·    ⌘R Refresh    ·    esc Back"
        }
        needsLayout = true
    }

    /// ⏎ (or the big button): the chosen item's main thing.
    private func primaryAction() {
        if actionsOpen { triggerLeaf(leaf); return }
        if case .command(let c) = mode {
            if c == .quitAll { quitAllApps() } else { killSelected(force: false) }
            return
        }
        openSelected()
    }

    private func openSelected(finder: Bool = false) {
        if case .command = mode { killSelected(force: finder); return }
        guard let r = results[safe: selected] else {
            if !query.isEmpty, !finder { onSearchWeb?(query) }
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
        if actionsOpen { closeActions(refocus: true, rebuildTree: false) }
        mode = .command(c)
        SoundService.shared.play(.openerTick)
        field.stringValue = ""
        selected = 0
        switch c {
        case .killPort: setPlaceholder("Port number…")
        case .killProcess: setPlaceholder("Search processes…")
        case .quitAll: setPlaceholder("Search open apps…")
        case .custom: setPlaceholder("Coming soon")
        }
        chip.title = c.title
        chip.isHidden = false
        processes = []; ports = []
        runningApps = c == .quitAll ? AppTools.quitCandidates() : []
        loading = c.loadsInBackground
        reloadList(c)
        Motion.page(orbit, forward: true)
        guard c.loadsInBackground else { return }
        refreshCommand(c)
    }

    private func refreshCommand(_ c: OpenerCommand) {
        if c == .quitAll {
            runningApps = AppTools.quitCandidates()
            reloadList(c)
            return
        }
        guard c.loadsInBackground else { return }
        commandScan = UUID()
        let scan = commandScan
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let procs = c == .killProcess ? ProcessTools.processes() : []
            let listening = c == .killPort ? ProcessTools.listeningPorts() : []
            DispatchQueue.main.async {
                guard let self = self, self.mode == .command(c), self.commandScan == scan else { return }
                self.loading = false
                self.processes = procs
                self.ports = listening
                self.reloadList(c)
            }
        }
    }

    /// Fold a command (or the actions) back up.
    private func collapse() {
        if actionsOpen { closeActions(); return }
        back()
    }

    private func back() {
        if actionsOpen { closeActions(refocus: true, rebuildTree: false) }
        mode = .root
        commandScan = UUID()
        loading = false
        chip.isHidden = true
        field.stringValue = ""
        setPlaceholder("Search apps, commands, or actions…")
        openBranch = .commands
        selected = 0
        reload()
    }

    private func reloadList(_ c: OpenerCommand) {
        if actionsOpen { rebuild(); return }
        let q = query.lowercased()
        switch c {
        case .killProcess:
            let filtered = q.isEmpty ? processes : processes.filter {
                $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q) || String($0.pid).hasPrefix(q)
            }
            listItems = filtered.map { p in
                ListItem(title: p.name, detail: "pid \(p.pid) · \(ProcessTools.memory(p.memoryKB))",
                         trailing: String(format: "%.1f%% CPU", p.cpu), pid: p.pid, path: p.path)
            }
        case .killPort:
            let filtered = q.isEmpty ? ports : ports.filter { String($0.port).hasPrefix(q) || $0.command.lowercased().contains(q) }
            listItems = filtered.map { p in
                ListItem(title: ":\(p.port)", detail: "\(p.command) · pid \(p.pid)", trailing: p.address == "*" ? "all addresses" : p.address,
                         pid: p.pid, port: p.port)
            }
        case .quitAll:
            let keep = AppOpenerSettings.keepRunning
            let filtered = q.isEmpty ? runningApps : runningApps.filter { ($0.localizedName ?? "").localizedCaseInsensitiveContains(q) }
            listItems = filtered.map { r in
                let k = keep.contains(AppTools.keepKey(r))
                return ListItem(title: r.localizedName ?? "App", detail: k ? "stays open" : "will quit",
                                trailing: k ? "KEEP" : "QUIT", pid: r.processIdentifier, path: r.bundleURL?.path ?? "", app: r, keep: k)
            }
        case .custom:
            listItems = []
        }
        selected = min(selected, max(0, listItems.count - 1))
        rightLabel.textColor = Neon.textDim
        switch c {
        case .killProcess, .killPort:
            rightLabel.stringValue = loading ? "LOADING…" : "\(listItems.count) \(c == .killPort ? "PORT" : "PROCESS")\(listItems.count == 1 ? "" : (c == .killPort ? "S" : "ES"))"
        case .quitAll: rightLabel.stringValue = "\(quitTargets.count) OF \(runningApps.count) WILL QUIT"
        case .custom: rightLabel.stringValue = "SOON"
        }
        rebuild()
    }

    private func killSelected(force: Bool) {
        guard case .command(let c) = mode, c.loadsInBackground, let it = listItems[safe: selected] else { return }
        kill(it, force: force)
    }

    private func kill(_ it: ListItem, force: Bool) {
        guard case .command(let c) = mode else { return }
        if it.pid == getpid(), !force {
            NSApp.terminate(nil) // Let Zera cancel her background tasks before quitting.
            return
        }
        switch ProcessTools.kill(it.pid, force: force) {
        case .done:
            SoundService.shared.play(.clipClear)
            processes.removeAll { $0.pid == it.pid }
            ports.removeAll { $0.pid == it.pid }
            reloadList(c)
            flash(force ? "FORCE QUIT \(it.title.uppercased())" : "STOPPED \(it.title.uppercased())")
        case .notAllowed:
            NSSound.beep()
            flash("NOT ALLOWED: OWNED BY THE SYSTEM", tint: Neon.red)
        case .gone:
            processes.removeAll { $0.pid == it.pid }
            ports.removeAll { $0.pid == it.pid }
            reloadList(c)
        }
    }

    // MARK: Quit All

    /// The open apps Quit All will close: every one you haven't kept.
    private var quitTargets: [NSRunningApplication] {
        let keep = AppOpenerSettings.keepRunning
        return runningApps.filter { !keep.contains(AppTools.keepKey($0)) && !$0.isTerminated }
    }

    /// Keep the chosen app open (or let it go again). Remembered for next time.
    private func toggleKeep() {
        guard mode == .command(.quitAll), let app = listItems[safe: selected]?.app else { return }
        var keep = AppOpenerSettings.keepRunning
        let key = AppTools.keepKey(app)
        if keep.contains(key) { keep.remove(key) } else { keep.insert(key) }
        AppOpenerSettings.keepRunning = keep
        SoundService.shared.play(.openerTick)
        reloadList(.quitAll)
    }

    private func quitAllApps() {
        let targets = quitTargets
        guard !targets.isEmpty else { NSSound.beep(); flash("NOTHING TO QUIT", tint: Neon.warning); return }
        onQuitAll?(targets)
    }

    // MARK: ⌘K actions

    /// The chosen result, by name, with everything you can do to it.
    private func currentActions() -> (name: String, actions: [PanelAction])? {
        switch mode {
        case .root:
            guard let item = results[safe: selected] else { return nil }
            switch item {
            case .app(let a, _, let running): return (a.name, appActions(a, running: running))
            case .command(let c, _):
                return (c.title, [PanelAction("Open Command", c.symbol, .code(KeyCombo.returnKey), section: 0) { [weak self] in self?.enter(c) }])
            case .action(let a, _):
                return (OpenerActions.title(a), [PanelAction("Run Action", a.symbol, .code(KeyCombo.returnKey), section: 0) { [weak self] in self?.onAction?(a) }])
            }
        case .command(let c):
            guard let it = listItems[safe: selected] else { return nil }
            switch c {
            case .killProcess: return (it.title, processActions(it))
            case .killPort: return (it.title, portActions(it))
            case .quitAll: return (it.title, quitAllActions(it))
            case .custom: return nil
            }
        }
    }

    private func appActions(_ app: AppEntry, running: Bool) -> [PanelAction] {
        var list: [PanelAction] = [
            PanelAction("Open Application", "arrow.up.forward.app", .code(KeyCombo.returnKey), section: 0) { [weak self] in self?.onLaunch?(app, false) },
            PanelAction("Show in Finder", "folder", .code(KeyCombo.returnKey, .command), section: 0) { [weak self] in self?.onLaunch?(app, true) },
            PanelAction("Show Package Contents", "shippingbox", .cmd("o", .shift), section: 0) { [weak self] in
                NSWorkspace.shared.activateFileViewerSelecting([app.url.appendingPathComponent("Contents")])
                self?.onFinish?(nil)
            },
            PanelAction("Copy Path", "doc.on.doc", .cmd("c", .shift), section: 1) { [weak self] in
                AppTools.copy(app.url.path)
                self?.onFinish?("copied the path to \(app.name) ✨")
            },
            PanelAction("Copy Name", "textformat", .cmd(".", .shift), section: 1) { [weak self] in
                AppTools.copy(app.name)
                self?.onFinish?("copied “\(app.name)” ✨")
            },
        ]
        if let id = app.bundleID {
            list.append(PanelAction("Copy Bundle Identifier", "barcode", .cmd("b", .shift), section: 1) { [weak self] in
                AppTools.copy(id)
                self?.onFinish?("copied \(id) ✨")
            })
        }
        if running {
            list += [
                PanelAction("Hide Application", "eye.slash", .cmd("h"), section: 2) { [weak self] in
                    AppTools.running(app).forEach { $0.hide() }
                    self?.onFinish?(nil)
                },
                PanelAction("Quit Application", "xmark.circle", .cmd("q"), section: 2) { [weak self] in
                    AppTools.running(app).forEach { $0.terminate() }
                    SoundService.shared.play(.clipClear)
                    self?.flash("QUITTING \(app.name.uppercased())")
                    self?.reloadSoon()
                },
                PanelAction("Force Quit Application", "bolt.circle", .cmd("q", .option), section: 2, tint: Neon.red) { [weak self] in
                    AppTools.running(app).forEach { $0.forceTerminate() }
                    SoundService.shared.play(.clipClear)
                    self?.flash("FORCE QUIT \(app.name.uppercased())")
                    self?.reloadSoon()
                },
            ]
        }
        let cat = AppCatalog.shared
        if let i = cat.pinIndex(app) {
            list.append(PanelAction("Unpin from Your Usual", "pin.slash", .cmd("p", .shift), section: 3) { [weak self] in
                cat.unpin(app); self?.keepChosen(app, "UNPINNED \(app.name.uppercased())")
            })
            if i > 0 {
                list.append(PanelAction("Move Up in Your Usual", "arrow.up", .code(KeyCombo.upKey, [.command, .option]), section: 3) { [weak self] in
                    cat.movePin(app, by: -1); self?.keepChosen(app, "MOVED UP")
                })
            }
            if i < cat.pins.count - 1 {
                list.append(PanelAction("Move Down in Your Usual", "arrow.down", .code(KeyCombo.downKey, [.command, .option]), section: 3) { [weak self] in
                    cat.movePin(app, by: 1); self?.keepChosen(app, "MOVED DOWN")
                })
            }
        } else {
            list.append(PanelAction("Pin to Your Usual", "pin", .cmd("p", .shift), section: 3) { [weak self] in
                cat.pin(app); self?.keepChosen(app, "PINNED \(app.name.uppercased())")
            })
            if cat.hasUsage(app) {
                list.append(PanelAction("Remove from Your Usual", "star.slash", section: 3) { [weak self] in
                    cat.forgetUsage(app); self?.keepChosen(app, "REMOVED FROM YOUR USUAL")
                })
            }
        }
        if AppTools.uninstallBlocker(app) == nil {
            list.append(PanelAction("Uninstall Application", "trash", .code(KeyCombo.deleteKey, [.command, .control]), section: 3,
                                    tint: Neon.red, confirm: "Move \(app.name) to the Trash?") { [weak self] in self?.uninstall(app) })
        }
        return list
    }

    /// The chosen app, when the chosen item is one (not a command or action).
    private var chosenApp: AppEntry? {
        guard mode == .root, case .app(let a, _, _)? = results[safe: selected] else { return nil }
        return a
    }

    private func togglePinChosen() {
        guard let a = chosenApp else { return }
        let cat = AppCatalog.shared
        if cat.isPinned(a) { cat.unpin(a); keepChosen(a, "UNPINNED \(a.name.uppercased())") }
        else { cat.pin(a); keepChosen(a, "PINNED \(a.name.uppercased())") }
    }

    /// After pinning or reordering: the list re-sorts and the same app stays chosen.
    private func keepChosen(_ app: AppEntry, _ note: String) {
        SoundService.shared.play(.openerTick)
        reload()
        if let i = results.firstIndex(where: { if case .app(let a, _, _) = $0 { return a.url == app.url }; return false }), i != selected {
            selected = i
            rebuild()
        }
        flash(note)
    }

    private func uninstall(_ app: AppEntry) {
        flash("MOVING \(app.name.uppercased()) TO THE TRASH…", tint: Neon.warning, for: 8)
        AppTools.moveToTrash(app) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .trashed:
                SoundService.shared.play(.clipClear)
                AppCatalog.shared.remove(app)
                self.reload()
                self.onFinish?("\(app.name) is in the Trash 🗑️ Put Back brings it home")
            case .stillRunning:
                NSSound.beep()
                self.flash("\(app.name.uppercased()) IS STILL OPEN: SAVE AND QUIT IT FIRST", tint: Neon.red)
            case .needsFinder:
                NSWorkspace.shared.activateFileViewerSelecting([app.canonicalURL])
                self.onFinish?("\(app.name) needs your password: it's selected in Finder, press ⌘⌫")
            }
        }
    }

    private func processActions(_ it: ListItem) -> [PanelAction] {
        var list: [PanelAction] = [
            PanelAction("Quit Process", "xmark.circle", .code(KeyCombo.returnKey), section: 0) { [weak self] in self?.kill(it, force: false) },
            PanelAction("Force Quit Process", "bolt.circle", .code(KeyCombo.returnKey, .command), section: 0, tint: Neon.red) { [weak self] in self?.kill(it, force: true) },
            PanelAction("Copy Process ID", "number", .cmd("c", .shift), section: 1) { [weak self] in
                AppTools.copy(String(it.pid)); self?.flash("COPIED PID \(it.pid)")
            },
        ]
        if it.path.hasPrefix("/") {
            list.append(PanelAction("Copy Path", "doc.on.doc", .cmd("p", .shift), section: 1) { [weak self] in
                AppTools.copy(it.path); self?.flash("COPIED THE PATH")
            })
            list.append(PanelAction("Show in Finder", "folder", .cmd("f", .shift), section: 1) { [weak self] in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)])
                self?.onFinish?(nil)
            })
        }
        return list
    }

    private func portActions(_ it: ListItem) -> [PanelAction] {
        guard let port = it.port else { return [] }
        let url = "http://localhost:\(port)"
        return [
            PanelAction("Stop Listener", "xmark.circle", .code(KeyCombo.returnKey), section: 0) { [weak self] in self?.kill(it, force: false) },
            PanelAction("Force Stop Listener", "bolt.circle", .code(KeyCombo.returnKey, .command), section: 0, tint: Neon.red) { [weak self] in self?.kill(it, force: true) },
            PanelAction("Open in Browser", "globe", .cmd("o"), section: 1) { [weak self] in
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                self?.onFinish?(nil)
            },
            PanelAction("Copy URL", "link", .cmd("c", .shift), section: 1) { [weak self] in
                AppTools.copy(url); self?.flash("COPIED \(url.uppercased())")
            },
            PanelAction("Copy Process ID", "number", .cmd("i", .shift), section: 1) { [weak self] in
                AppTools.copy(String(it.pid)); self?.flash("COPIED PID \(it.pid)")
            },
        ]
    }

    private func quitAllActions(_ it: ListItem) -> [PanelAction] {
        guard let app = it.app else { return [] }
        let n = quitTargets.count
        return [
            PanelAction(n == 1 ? "Quit 1 App" : "Quit All \(n) Apps", "sparkles", .code(KeyCombo.returnKey), section: 0) { [weak self] in self?.quitAllApps() },
            PanelAction(it.keep ? "Quit It Too" : "Keep It Open", it.keep ? "minus.circle" : "pin", .code(49), section: 1) { [weak self] in self?.toggleKeep() },
            PanelAction("Quit Only \(it.title)", "xmark.circle", .code(KeyCombo.returnKey, .command), section: 1) { [weak self] in
                app.terminate()
                SoundService.shared.play(.clipClear)
                self?.flash("QUITTING \(it.title.uppercased())")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refreshCommand(.quitAll) }
            },
        ]
    }

    private func toggleActions() {
        actionsOpen ? closeActions() : openActions()
    }

    /// Opens the chosen item's action node; the search field now filters its rows.
    private func openActions(confirming ask: Int? = nil) {
        guard let (name, actions) = currentActions(), !actions.isEmpty else { NSSound.beep(); return }
        let oldFrames = actionMotionFrames()
        let source = actionFlight.map { renderedFrame($0, in: holder) } ?? selectedIconFrame()
        let image = actionFlight?.image ?? tiles.values.first(where: { $0.chosen })?.icon
        resetActionTransition()
        let outgoing = actionBrowsingViews.filter { !$0.isHidden }
        let wasOpen = actionsOpen
        SoundService.shared.play(.openerTick)
        if !actionsOpen { savedQuery = field.stringValue }
        actionsOpen = true
        allActions = actions
        shownActions = actions
        leaf = ask ?? 0
        confirming = ask
        field.stringValue = ""
        setPlaceholder("Search actions…")
        chip.title = name
        chip.isHidden = false
        rightLabel.textColor = Neon.textDim
        rightLabel.stringValue = ""
        window?.makeFirstResponder(field)
        rebuild()
        if !wasOpen, !Motion.reduced, window != nil {
            animateActionLayout(from: oldFrames)
            outgoing.forEach { fadeActionSurface($0, entering: false) }
            fadeActionSurface(actionPanel, entering: true, delay: 0.08)
            fadeActionSurface(actionHeading, entering: true, delay: 0.18)
            fadeActionSurface(actionCount, entering: true, delay: 0.18)
            for (index, row) in actionRows.enumerated() {
                let delay = 0.16 + Double(min(index, 7)) * 0.025
                fadeActionSurface(row, entering: true, delay: delay)
                actionShift(row, from: CGPoint(x: 0, y: -10), duration: 0.28, delay: delay)
            }
            let grow = CABasicAnimation(keyPath: "strokeEnd")
            grow.fromValue = 0; grow.toValue = 1; grow.duration = 0.32
            grow.beginTime = CACurrentMediaTime() + 0.16
            grow.fillMode = .backwards
            actionBranch.add(grow, forKey: "actionGrow")
            if let source = source, let image = image {
                flyActionIcon(image, from: source, to: holder.convert(actionIcon.bounds, from: actionIcon), opening: true)
            }
        }
    }

    private func closeActions(refocus: Bool = true, rebuildTree: Bool = true) {
        guard actionsOpen else { return }
        let oldFrames = actionMotionFrames()
        let source = renderedFrame(actionFlight ?? actionIcon, in: holder)
        let image = actionFlight?.image ?? actionIcon.image
        resetActionTransition()
        actionsOpen = false
        confirming = nil
        field.stringValue = savedQuery
        if case .command(let c) = mode {
            chip.title = c.title
            switch c {
            case .killPort: setPlaceholder("Port number…")
            case .killProcess: setPlaceholder("Search processes…")
            case .quitAll: setPlaceholder("Search open apps…")
            case .custom: setPlaceholder("Coming soon")
            }
        } else {
            chip.isHidden = true
            setPlaceholder("Search apps, commands, or actions…")
        }
        if refocus { window?.makeFirstResponder(field) }
        if rebuildTree {
            reload()
            if !Motion.reduced, window != nil {
                animateActionLayout(from: oldFrames)
                fadeActionSurface(actionPanel, entering: false)
                actionBrowsingViews.filter { !$0.isHidden }.forEach { fadeActionSurface($0, entering: true, delay: 0.12) }
                if let destination = selectedIconFrame(), let image = image {
                    flyActionIcon(image, from: source, to: destination, opening: false)
                }
            }
        }
    }

    // Keep the selected app continuous between the arc and its action header. Animate
    // presentation layers only: filtering and keyboard navigation remain immediately usable.
    private var actionMotionViews: [NSView] { [searchBar, zera, rope, foot] }
    private var actionBrowsingViews: [NSView] { [orbit, lanes, detailCard, detailIcon, dName, dMeta, dPrimary, dSecondary, dPin, dEmpty] }

    private let actionMotionDuration = 0.48
    private var actionMotionTiming: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1) }

    private func renderedFrame(_ view: NSView, in parent: NSView) -> NSRect {
        if let model = view.layer, let visible = model.presentation(), let owner = view.superview {
            // AppKit inserts flipped hosting layers. Read the presentation delta in the
            // view's own layer space, then let NSView convert between view hierarchies.
            let base = CGRect(x: model.position.x - model.anchorPoint.x * model.bounds.width,
                              y: model.position.y - model.anchorPoint.y * model.bounds.height,
                              width: model.bounds.width, height: model.bounds.height)
            let frame = visible.frame
            let rect = NSRect(x: view.frame.minX + frame.minX - base.minX,
                              y: view.frame.minY + frame.minY - base.minY,
                              width: view.frame.width * frame.width / max(1, base.width),
                              height: view.frame.height * frame.height / max(1, base.height))
            return parent.convert(rect, from: owner)
        }
        return parent.convert(view.bounds, from: view)
    }

    private func actionMotionFrames() -> [NSRect] {
        actionMotionViews.map { view in view.superview.map { renderedFrame(view, in: $0) } ?? view.frame }
    }

    private func animateActionLayout(from frames: [NSRect]) {
        for (view, frame) in zip(actionMotionViews, frames) {
            actionShift(view, from: CGPoint(x: frame.minX - view.frame.minX, y: frame.minY - view.frame.minY), duration: actionMotionDuration)
        }
        let id = actionTransitionID
        DispatchQueue.main.asyncAfter(deadline: .now() + actionMotionDuration + 0.08) { [weak self] in
            guard let self = self, self.actionTransitionID == id else { return }
            for view in self.actionBrowsingViews + [self.actionPanel] where view.alphaValue == 0 {
                view.isHidden = true
                view.alphaValue = 1
            }
        }
    }

    private func actionShift(_ view: NSView, from offset: CGPoint, duration: Double, delay: Double = 0) {
        guard let layer = view.layer else { return }
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: NSPoint(x: layer.position.x + offset.x, y: layer.position.y + offset.y))
        move.toValue = NSValue(point: layer.position)
        move.duration = duration
        move.beginTime = CACurrentMediaTime() + delay
        move.fillMode = .backwards
        move.timingFunction = actionMotionTiming
        layer.add(move, forKey: "actionMove")
    }

    private func fadeActionSurface(_ view: NSView, entering: Bool, delay: Double = 0) {
        view.isHidden = false
        view.alphaValue = entering ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = entering ? 0 : 1
        fade.toValue = entering ? 1 : 0
        fade.duration = entering ? 0.28 : 0.16
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(fade, forKey: "actionFade")
    }

    private func selectedIconFrame() -> NSRect? {
        guard let tile = tiles.values.first(where: { $0.chosen }), tile.style == .icon else { return nil }
        let frame = renderedFrame(tile, in: holder)
        return frame.insetBy(dx: frame.width * 0.125, dy: frame.height * 0.125)
    }

    private func flyActionIcon(_ image: NSImage, from source: NSRect, to destination: NSRect, opening: Bool) {
        let flight = NSImageView(frame: destination)
        flight.image = image
        flight.imageScaling = .scaleProportionallyUpOrDown
        flight.wantsLayer = true
        flight.setAccessibilityElement(false)
        holder.addSubview(flight, positioned: .above, relativeTo: nil)
        actionFlight = flight
        if opening { actionIcon.alphaValue = 0 }
        else if let tile = tiles.values.first(where: { $0.chosen }) { fadeActionSurface(tile, entering: true, delay: 0.3) }
        guard let layer = flight.layer else { return }
        // AppKit owns this layer's anchor and position. Keep them intact so the moving
        // image and real header icon have identical geometry at the handoff.
        let end = layer.position
        let anchor = layer.anchorPoint
        let start = CGPoint(x: end.x + source.minX - destination.minX + anchor.x * (source.width - destination.width),
                            y: end.y + source.minY - destination.minY + anchor.y * (source.height - destination.height))
        let dx = end.x - start.x, dy = end.y - start.y
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + dx * 0.22, y: start.y + dy * 0.4),
                      control2: CGPoint(x: start.x + dx * 0.72, y: start.y + dy * 0.95))
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = path
        travel.calculationMode = .paced
        travel.duration = actionMotionDuration
        let size = CABasicAnimation(keyPath: "transform")
        size.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(source.width / destination.width, source.height / destination.height, 1))
        size.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        size.duration = actionMotionDuration
        let motion = CAAnimationGroup()
        motion.animations = [travel, size]
        motion.duration = actionMotionDuration
        motion.timingFunction = actionMotionTiming
        layer.add(motion, forKey: "actionFlight")
        let id = actionTransitionID
        DispatchQueue.main.asyncAfter(deadline: .now() + actionMotionDuration + 0.02) { [weak self, weak flight] in
            flight?.removeFromSuperview()
            guard let self = self, self.actionTransitionID == id else { return }
            self.actionFlight = nil
            self.actionIcon.alphaValue = 1
        }
    }

    private func resetActionTransition() {
        actionTransitionID += 1
        actionFlight?.removeFromSuperview(); actionFlight = nil
        let surfaces = actionMotionViews + actionBrowsingViews + [actionPanel, actionIcon, actionHeading, actionCount] + actionRows + Array(tiles.values)
        for view in surfaces {
            view.layer?.removeAnimation(forKey: "actionMove")
            view.layer?.removeAnimation(forKey: "actionFade")
            view.alphaValue = 1
        }
        actionBranch.removeAnimation(forKey: "actionGrow")
    }

    private func filterActions() {
        let q = query
        shownActions = q.isEmpty ? allActions : allActions.compactMap { a in AppMatcher.match(a.title, q).map { (a, $0.score) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
        leaf = 0
        confirming = nil
        rebuild()
    }

    /// Runs an action; ones that ask first (Uninstall) ask on the first ⏎ and go on the second.
    private func triggerLeaf(_ k: Int) {
        guard let a = shownActions[safe: k] else { return }
        if a.confirm != nil, confirming != k {
            leaf = k
            confirming = k
            SoundService.shared.play(.openerTick)
            rebuild()
            return
        }
        closeActions()
        a.run()
    }

    /// Runs the chosen result's action for this shortcut, if it has one. Ones that ask first
    /// (Uninstall) open the actions at their confirmation instead.
    private func runShortcut(_ event: NSEvent) -> Bool {
        guard let (_, actions) = currentActionsForShortcut(),
              let i = actions.firstIndex(where: { $0.shortcut?.matches(event) == true }) else { return false }
        if actions[i].confirm != nil {
            if actionsOpen, let k = shownActions.firstIndex(where: { $0.title == actions[i].title }) { leaf = k; confirming = k; rebuild(); return true }
            openActions(confirming: i)
            return true
        }
        closeActions()
        actions[i].run()
        return true
    }

    /// While the actions are open, shortcuts still act on the chosen item.
    private func currentActionsForShortcut() -> (name: String, actions: [PanelAction])? {
        actionsOpen ? ("", allActions) : currentActions()
    }

    /// Briefly says what just happened, top right.
    private func flash(_ text: String, tint: NSColor = Neon.cyan, for seconds: Double = 1.8) {
        let token = UUID()
        flashToken = token
        rightLabel.stringValue = text
        rightLabel.textColor = tint
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.flashToken == token else { return }
            self.rightLabel.textColor = Neon.textDim
            if case .command(let c) = self.mode { self.reloadList(c) } else { self.reload() }
        }
    }

    /// After a quit, once the app has had a moment to go: its running dot goes out.
    private func reloadSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self, self.mode == .root, !self.actionsOpen else { return }
            let keep = self.rightLabel.stringValue, tint = self.rightLabel.textColor
            self.reload()
            if tint != Neon.textDim { self.rightLabel.stringValue = keep; self.rightLabel.textColor = tint }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = modifierMonitor { NSEvent.removeMonitor(monitor); modifierMonitor = nil }
        guard window != nil else { return }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self, self.window?.isVisible == true else { return event }
            self.commandHints = event.modifierFlags.contains(.command)
            for caption in self.captions.values { caption.showKey = self.commandHints || caption.chosen }
            return event
        }
    }

    deinit { if let monitor = modifierMonitor { NSEvent.removeMonitor(monitor) } }

    func controlTextDidBeginEditing(_ obj: Notification) {
        searchBar.edge = OpenerLook.accent
        searchBar.lineWidth = 2
        searchBar.glow = Motion.reduced ? 0 : 0.12
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        searchBar.edge = NSColor.white.withAlphaComponent(0.10)
        searchBar.lineWidth = 1
        searchBar.glow = 0
    }

    func controlTextDidChange(_ obj: Notification) {
        if actionsOpen { filterActions(); return }
        // Quit All: space (on an empty search) keeps the chosen app open, or lets it go.
        if mode == .command(.quitAll), field.stringValue == " " {
            field.stringValue = ""
            toggleKeep()
            return
        }
        selected = 0
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        // Along the arc: arrows browse results even while a search query is present.
        case #selector(NSResponder.moveRight(_:)): move(1); return true
        case #selector(NSResponder.moveLeft(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true, !actionsOpen {
                if case .command = mode { killSelected(force: true) } else { openSelected(finder: true) }
                return true
            }
            primaryAction(); return true
        case #selector(NSResponder.insertTab(_:)):
            if mode == .root, !actionsOpen { nextBranch(1) }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if mode == .root, !actionsOpen { nextBranch(-1) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if actionsOpen {
                if confirming != nil { confirming = nil; rebuild() } else { closeActions() }
            } else if case .command = mode { back() } else { onClose?() }
            return true
        case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty:
            if actionsOpen { closeActions(); return true }
            if case .command = mode { back(); return true }
            return false
        default: return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.modifierFlags.intersection([.command, .control]).isEmpty else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods == .command, (key == "k" || key == "m") { toggleActions(); return true }
        if mods == .command, key == "r", case .command(let command) = mode, command != .custom {
            refreshCommand(command)
            return true
        }
        if runShortcut(event) { return true }
        // ⌘Q only ever quits the chosen app, never Zera herself.
        if mods.contains(.command), key == "q" { NSSound.beep(); return true }
        // Numbered shortcuts follow the displayed items from left to right.
        if !actionsOpen, mode == .root, mods == .command, let c = key, let n = Int(c), (1...OP.tiles).contains(n), n - 1 < quickIndices.count {
            selected = quickIndices[n - 1]
            openSelected()
            return true
        }
        if !actionsOpen, event.keyCode == KeyCombo.returnKey, mods == .command { openSelected(finder: true); return true }
        return super.performKeyEquivalent(with: event)
    }

    /// A swipe or scroll turns the arc, one item per notch.
    private var wheelLock = false
    override func scrollWheel(with event: NSEvent) {
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : -event.scrollingDeltaY
        guard abs(d) > 3, !wheelLock else { return }
        wheelLock = true
        move(d > 0 ? 1 : -1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in self?.wheelLock = false }
    }

    // MARK: Layout

    private var actionRowStep: CGFloat { bounds.height < 700 ? 36 : 44 }
    private var actionSectionGap: CGFloat { bounds.height < 700 ? 8 : 10 }
    private var actionContentHeight: CGFloat {
        guard !shownActions.isEmpty else { return 70 }
        var height: CGFloat = 14
        for k in shownActions.indices {
            if k > 0, shownActions[k].section != shownActions[k - 1].section { height += actionSectionGap }
            height += actionRowStep
        }
        return height
    }

    private func layoutActionRows() {
        let width = actionScroll.contentSize.width
        actionDoc.frame = NSRect(x: 0, y: 0, width: width, height: max(actionContentHeight, actionScroll.contentSize.height))
        actionEmpty.frame = NSRect(x: 18, y: 22, width: max(0, width - 36), height: 22)
        let path = CGMutablePath()
        var y: CGFloat = 10
        var centres: [CGFloat] = []
        for (k, row) in actionRows.enumerated() {
            if k > 0, shownActions[k].section != shownActions[k - 1].section { y += actionSectionGap }
            row.frame = NSRect(x: 38, y: y, width: max(0, width - 50), height: actionRowStep - 4)
            centres.append(row.frame.midY)
            y += actionRowStep
        }
        if let first = centres.first, let last = centres.last {
            path.move(to: CGPoint(x: 22, y: first))
            path.addLine(to: CGPoint(x: 22, y: last))
            for centre in centres {
                path.move(to: CGPoint(x: 22, y: centre))
                path.addLine(to: CGPoint(x: 34, y: centre))
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        actionBranch.frame = actionDoc.bounds
        actionBranch.path = path
        CATransaction.commit()
        if let row = actionRows[safe: leaf] { row.scrollToVisible(row.bounds) }
    }

    override func layout() {
        super.layout()
        let c = cx
        let compact = bounds.height < 700
        let sh = OV.searchH
        holder.frame = bounds
        veil.frame = bounds
        // Her picture's own rope sits exactly on the drawn one; her paws rest on the search.
        zera.frame = NSRect(x: (c - ropeFraction * OP.zeraW).rounded(), y: cardTop - zeraH + OP.paws, width: OP.zeraW, height: zeraH)
        mascotMask.frame = zera.bounds
        if rope.layer?.animation(forKey: "grow") == nil {
            rope.frame = NSRect(x: (c - ropeWidth / 2).rounded(), y: 0, width: ropeWidth, height: band + OP.ropeGap + verticalOffset + 14)
        }

        settingsButton.frame = NSRect(x: bounds.width - 56, y: 24, width: 32, height: 32)
        // The search.
        let sw = min(OV.searchW, bounds.width - 40)
        searchBar.frame = NSRect(x: (c - sw / 2).rounded(), y: cardTop, width: sw, height: sh)
        searchIcon.frame = NSRect(x: 20, y: (sh - 18) / 2, width: 18, height: 18)
        var fx: CGFloat = 50
        if !chip.isHidden {
            let w = min(220, chip.fittedWidth)
            chip.frame = NSRect(x: fx, y: (sh - 32) / 2, width: w, height: 32)
            fx = chip.frame.maxX + 10
        }
        let rw = rightLabel.stringValue.isEmpty ? 0 : min(140, ceil(rightLabel.attributedStringValue.size().width) + 4)
        rightLabel.frame = NSRect(x: sw - 20 - rw, y: (sh - 14) / 2, width: rw, height: 14)
        field.frame = NSRect(x: fx, y: (sh - 22) / 2, width: max(60, sw - 20 - rw - 12 - fx), height: 22)

        // The lanes, then the arc.
        let lw = lanes.fittedWidth
        lanes.frame = NSRect(x: (c - lw / 2).rounded(), y: searchBar.frame.maxY + 16, width: lw, height: 36)
        if actionsOpen {
            let panelW = min(620, bounds.width - 40)
            let panelY = searchBar.frame.maxY + 16
            let available = max(180, bounds.height - panelY - 48)
            let panelH = min(72 + actionContentHeight, available)
            actionPanel.frame = NSRect(x: (c - panelW / 2).rounded(), y: panelY, width: panelW, height: panelH)
            actionIcon.frame = NSRect(x: 20, y: 14, width: 34, height: 34)
            actionHeading.frame = NSRect(x: 66, y: 20, width: panelW - 178, height: 22)
            actionCount.frame = NSRect(x: panelW - 112, y: 23, width: 88, height: 16)
            actionDivider.frame = NSRect(x: 18, y: 60, width: panelW - 36, height: 1)
            actionScroll.frame = NSRect(x: 10, y: 65, width: panelW - 20, height: max(0, panelH - 73))
            layoutActionRows()
            let fw = min(OV.footW, bounds.width - 40)
            foot.frame = NSRect(x: c - fw / 2, y: actionPanel.frame.maxY + 12, width: fw, height: 20)
            return
        }
        let ow = min(OV.orbitW, bounds.width)
        let oy = lanes.frame.maxY + 24
        let rootCaptionRoom: CGFloat = mode == .root ? 112 : 70
        let oh = orbitDrop + rootCaptionRoom
        let newOrbit = NSRect(x: (c - ow / 2).rounded(), y: oy, width: ow, height: oh)
        if newOrbit != orbit.frame {
            orbit.frame = newOrbit
            if !deferringOrbitLayout { placeOrbit(animated: false) }
        }

        let buttons = [dPrimary, dSecondary, dPin].filter { !$0.isHidden }
        let fw = min(OV.footW, bounds.width - 40)
        if !detailCard.isHidden {
            let cardW = sw
            let card = NSRect(x: c - cardW / 2, y: orbit.frame.maxY + 24, width: cardW, height: OpenerLook.cardHeight)
            detailCard.frame = card
            detailIcon.frame = NSRect(x: card.minX + Space.xl, y: card.midY - 20, width: 40, height: 40)
            let by = card.midY - 16
            let bw: CGFloat = 112
            dPrimary.frame = NSRect(x: card.maxX - Space.xl - bw, y: by, width: bw, height: Metrics.button)
            dSecondary.frame = NSRect(x: dPrimary.frame.minX - Space.s - Metrics.button, y: by, width: Metrics.button, height: Metrics.button)
            dPin.frame = NSRect(x: dSecondary.frame.minX - Space.s - Metrics.button, y: by, width: Metrics.button, height: Metrics.button)
            let tx = detailIcon.frame.maxX + Space.l
            let tw = max(120, dPin.frame.minX - tx - Space.l)
            let font = OpenerLook.detailFont
            if dName.font != font { dName.font = font }
            dName.frame = NSRect(x: tx, y: card.minY + 16, width: tw, height: 20)
            dMeta.frame = NSRect(x: tx, y: card.minY + 40, width: tw, height: 18)
            foot.frame = NSRect(x: c - fw / 2, y: card.maxY + 24, width: fw, height: 20)
        } else {
            var y = orbit.frame.maxY + 8
            let font = NSFont.systemFont(ofSize: 18, weight: .semibold)
            if dName.font != font { dName.font = font }
            dName.frame = NSRect(x: c - 320, y: y, width: 640, height: 30); y += 34
            dMeta.frame = NSRect(x: c - 360, y: y, width: 720, height: 20); y += compact ? 26 : 34
            let widths = buttons.map { max(110, $0.fittedWidth) }
            var bx = c - (widths.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * 8) / 2
            for (button, width) in zip(buttons, widths) {
                button.frame = NSRect(x: bx.rounded(), y: y, width: width, height: 36)
                bx += width + 8
            }
            let footGap: CGFloat = compact ? 8 : (bounds.height < 820 ? 18 : 26)
            foot.frame = NSRect(x: c - fw / 2, y: y + 36 + footGap, width: fw, height: 20)
        }
        dEmpty.frame = NSRect(x: c - 260, y: orbit.frame.minY + 40, width: 520, height: 60)
    }

    // MARK: Motion

    /// The screen dims; she rappels down with the search; the items fan out from the middle.
    func animateIn() {
        exitAnimationID += 1
        holder.layer?.removeAllAnimations()
        rope.layer?.removeAllAnimations()
        veil.layer?.removeAllAnimations()
        window?.makeFirstResponder(field)
        holder.alphaValue = 1
        guard !Motion.reduced, let hl = holder.layer else { return }
        let dim = CABasicAnimation(keyPath: "opacity")
        dim.fromValue = 0; dim.toValue = 1; dim.duration = 0.32
        veil.layer?.add(dim, forKey: "dim")
        let drop = CASpringAnimation(keyPath: "transform.translation.y")
        drop.fromValue = -(cardTop + 40); drop.toValue = 0
        drop.stiffness = 170; drop.damping = 17; drop.mass = 1
        drop.duration = drop.settlingDuration
        hl.add(drop, forKey: "drop")
        if let rl = rope.layer {
            let grow = CABasicAnimation(keyPath: "bounds.size.height")
            grow.fromValue = 0; grow.toValue = rope.frame.height
            grow.duration = 0.35
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.3, 0.5, 1)
            rl.add(grow, forKey: "grow")
        }
        fanOut(delay: 0.18)
    }

    /// The items spring out from the chosen one to their places on the arc.
    private func fanOut(delay: Double) {
        guard !Motion.reduced else { return }
        let c = NSPoint(x: orbit.bounds.midX, y: orbitDrop)
        for view in tiles.values.map({ $0 as NSView }) + captions.values.map({ $0 as NSView }) {
            guard let l = view.layer else { continue }
            let dx = c.x - view.frame.midX
            let move = CASpringAnimation(keyPath: "transform.translation.x")
            move.fromValue = dx; move.toValue = 0
            move.stiffness = 220; move.damping = 20
            move.duration = move.settlingDuration
            move.beginTime = CACurrentMediaTime() + delay
            move.fillMode = .backwards
            l.add(move, forKey: "fan")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = view.alphaValue
            fade.duration = 0.25
            fade.beginTime = move.beginTime
            fade.fillMode = .backwards
            l.add(fade, forKey: "fanFade")
        }
    }

    /// Back up the rope; the screen brightens again.
    func animateOut(_ done: @escaping () -> Void) {
        resetActionTransition()
        guard !Motion.reduced, let hl = holder.layer else { done(); return }
        exitAnimationID += 1
        let animationID = exitAnimationID
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let up = CABasicAnimation(keyPath: "transform.translation.y")
        up.fromValue = 0; up.toValue = -(cardTop + 60)
        up.duration = 0.26
        up.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0)
        up.fillMode = .forwards; up.isRemovedOnCompletion = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.26
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        hl.add(up, forKey: "up")
        hl.add(fade, forKey: "fade")
        rope.layer?.add(fade, forKey: "fade")
        veil.layer?.add(fade, forKey: "fade")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.exitAnimationID == animationID else { return }
            self.holder.layer?.removeAllAnimations()
            self.rope.layer?.removeAllAnimations()
            self.veil.layer?.removeAllAnimations()
        }
    }

    /// The chosen app's icon flies up into Zera's paws; she hops; then `done`.
    func toss(_ app: AppEntry, _ done: @escaping () -> Void) {
        let chosenTile = tiles.values.first { $0.chosen }
        let source = chosenTile.map { orbit.convert($0.frame, to: self) } ?? NSRect(x: cx - 32, y: orbitCenter.y - 32, width: 64, height: 64)
        chosenTile?.alphaValue = 0
        let flyer = NSImageView(frame: source)
        flyer.image = AppCatalog.shared.icon(app)
        flyer.wantsLayer = true
        addSubview(flyer)
        guard !Motion.reduced else { flyer.removeFromSuperview(); done(); return }
        let target = NSRect(x: zera.frame.midX - 14, y: zera.frame.midY - 4, width: 28, height: 28)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
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

/// The orbit's measurements.
private enum OV {
    static let searchW: CGFloat = OpenerLook.width
    static let searchH: CGFloat = OpenerLook.searchHeight
    static let orbitW: CGFloat = 1200
    /// From the top of the arc's view to the chosen tile's centre.
    static let orbitDrop: CGFloat = 60
    static let footW: CGFloat = 900
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Keyboard guidance uses the same quiet keycaps as the search and app shortcuts.
private final class OpenerFooter: NSTextField {
    var hints: [([String], String)] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard !hints.isEmpty else { super.draw(dirtyRect); return }
        let groups = hints
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let keyFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        func keyWidth(_ key: String) -> CGFloat { max(20, ceil((key as NSString).size(withAttributes: [.font: keyFont]).width) + 10) }
        let widths = groups.map { $0.0.reduce(CGFloat(0)) { $0 + keyWidth($1) + 4 } + 2 + ($0.1 as NSString).size(withAttributes: [.font: font]).width }
        let total = widths.reduce(0, +) + 20 * CGFloat(groups.count - 1)
        var x = bounds.midX - total / 2
        for (keys, title) in groups {
            for key in keys {
                let box = NSRect(x: x, y: bounds.midY - 10, width: keyWidth(key), height: 20)
                let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
                NSColor.white.withAlphaComponent(0.06).setFill(); path.fill()
                OpenerLook.edge.setStroke(); path.lineWidth = 1; path.stroke()
                let attr: [NSAttributedString.Key: Any] = [.font: keyFont, .foregroundColor: OpenerLook.muted]
                let size = (key as NSString).size(withAttributes: attr)
                (key as NSString).draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attr)
                x += box.width + 4
            }
            let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: OpenerLook.muted])
            text.draw(at: NSPoint(x: x + 2, y: bounds.midY - text.size().height / 2))
            x += 2 + text.size().width + 20
        }
    }
}

/// A branch's name in the tree: "YOUR USUAL", "COMMANDS · 4" when folded.
final class TreeGroupView: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String, count: Int?, open: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        chevron.image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .bold).applying(.init(paletteColors: [Neon.textFaint])))
        addSubview(chevron)
        let s = NSMutableAttributedString(string: title, attributes: [
            .font: Typo.branchLabel, .foregroundColor: Neon.textDim, .kern: Typo.branchKern])
        if let n = count {
            s.append(NSAttributedString(string: "  · \(n)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: Neon.textFaint]))
        }
        label.attributedStringValue = s
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 2, y: (bounds.height - 10) / 2, width: 10, height: 10)
        label.frame = NSRect(x: 18, y: (bounds.height - 14) / 2, width: bounds.width - 18, height: 14)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A row in the tree: an app, command or action (item), a command's own row (child), one of
/// the chosen item's actions (leaf), or a quiet note.
final class TreeRowView: NSView {
    enum Style { case item, child, leaf, note }
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var capturesContentClicks = false
    var icon: NSImage? { didSet { iconView.image = icon; iconView.isHidden = icon == nil; needsLayout = true } }
    var symbol: String? { didSet { restyle() } }
    var tint: NSColor? { didSet { restyle() } }
    var titleText = NSAttributedString() { didSet { title.attributedStringValue = titleText; needsLayout = true } }
    var sub = "" { didSet { subLabel.stringValue = sub; needsLayout = true } }
    var accessory = "" { didSet { acc.stringValue = accessory; needsLayout = true; needsDisplay = true } }
    var accessoryKeycap = false {
        didSet {
            acc.alignment = accessoryKeycap ? .center : .right
            if accessoryKeycap { acc.font = NSFont.systemFont(ofSize: 11) }
            needsLayout = true; needsDisplay = true
        }
    }
    var running = false { didSet { dot.isHidden = !running } }
    var mono = false
    /// Quit All's switch: on = this app will quit.
    var toggle: Bool? { didSet { needsDisplay = true; needsLayout = true } }
    var dimmed = false { didSet { alphaValue = dimmed ? 0.5 : 1 } }
    var selected = false { didSet { restyle() } }
    private let style: Style
    private let iconView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let acc = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var hovered = false { didSet { restyle() } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = style == .leaf ? 9 : 11
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = true
        addSubview(iconView)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        subLabel.font = NSFont.systemFont(ofSize: 12)
        subLabel.textColor = Neon.textDim
        subLabel.lineBreakMode = .byTruncatingTail
        addSubview(subLabel)
        acc.font = style == .leaf ? NSFont.monospacedSystemFont(ofSize: 11, weight: .medium) : NSFont.systemFont(ofSize: 11.5, weight: .medium)
        acc.textColor = Neon.textDim
        acc.alignment = .right
        addSubview(acc)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = Neon.cyan.cgColor
        dot.isHidden = true
        addSubview(dot)
        setAccessibilityRole(.button)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let accent = tint ?? Neon.accent
        let on = selected && style != .note
        layer?.backgroundColor = (on ? accent.withAlphaComponent(0.14) : (hovered && style != .note ? Neon.chipHover.withAlphaComponent(0.55) : .clear)).cgColor
        layer?.borderColor = (on ? accent.withAlphaComponent(0.5) : .clear).cgColor
        if style == .leaf, let s = symbol {
            let c = tint ?? (selected ? Neon.cyan : Neon.glyph)
            iconView.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [c])))
            iconView.isHidden = false
            acc.textColor = tint?.withAlphaComponent(0.8) ?? Neon.textFaint
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let size: CGFloat = style == .leaf ? 16 : (style == .child ? 24 : 26)
        iconView.frame = NSRect(x: 8, y: (h - size) / 2, width: size, height: size)
        let tx: CGFloat = iconView.isHidden ? 10 : 8 + size + (style == .leaf ? 10 : 12)
        var right = w - 12
        if toggle != nil { right -= 34 }
        let aw = accessory.isEmpty ? 0 : ceil(acc.attributedStringValue.size().width) + (accessoryKeycap ? 12 : 4)
        acc.frame = NSRect(x: right - aw, y: (h - 15) / 2, width: aw, height: 15)
        if running { dot.frame = NSRect(x: acc.frame.minX - 11, y: (h - 6) / 2, width: 6, height: 6); right = dot.frame.minX - 8 } else { right = acc.frame.minX - 10 }
        let tw = min(right - tx, ceil(title.attributedStringValue.size().width) + 4)
        title.frame = NSRect(x: tx, y: (h - 18) / 2, width: max(0, tw), height: 18)
        subLabel.frame = NSRect(x: title.frame.maxX + 8, y: (h - 15) / 2 + 1, width: max(0, right - title.frame.maxX - 8), height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        if accessoryKeycap && !accessory.isEmpty {
            let box = NSRect(x: acc.frame.minX, y: bounds.midY - 10, width: acc.frame.width, height: 20)
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            NSColor.white.withAlphaComponent(0.06).setFill(); path.fill()
            OpenerLook.edge.setStroke(); path.lineWidth = 1; path.stroke()
        }
        guard let on = toggle else { return }
        let r = NSRect(x: bounds.width - 12 - 30, y: (bounds.height - 18) / 2, width: 30, height: 18)
        let track = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        (on ? Neon.red.withAlphaComponent(0.85) : Neon.track).setFill()
        track.fill()
        let knob = NSRect(x: on ? r.maxX - 16 : r.minX + 2, y: r.minY + 2, width: 14, height: 14)
        (on ? NSColor.white : Neon.textDim).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard style != .note else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?() }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return capturesContentClicks && target != nil ? self : target
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { if style != .note { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// The detail pane's buttons: "Open Safari ⏎" (primary), "Actions ⌘K".
final class TreeButton: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var key = "⏎" { didSet { needsDisplay = true } }
    var labelFont: NSFont? { didSet { needsDisplay = true } }
    var openerAppearance = false { didSet { needsDisplay = true } }
    var openerIconOnly = false { didSet { needsDisplay = true } }
    var openerPinned = false { didSet { needsDisplay = true } }
    /// An optional SF Symbol before the title.
    var symbol: String? { didSet { needsDisplay = true } }
    var primary = false { didSet { needsDisplay = true } }
    /// Green for Quit All, red for destructive actions.
    var tint: NSColor? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

    /// The shared button family (`Palette.drawButton`): the main action filled with the accent,
    /// a green tint filled green, a red one a soft red; the rest quiet.
    private var tone: ButtonTone {
        guard primary else { return .neutral }
        guard let t = tint else { return .accent }
        if t.sameRGB(as: Neon.green) { return .success }
        if t.sameRGB(as: Neon.red) { return .danger }
        if t.sameRGB(as: Neon.warning) { return .warning }
        return .accent
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5).pressed(pressed)
        let radius: CGFloat = openerAppearance ? OpenerLook.buttonRadius : Radius.m
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let ink: NSColor
        if openerAppearance && tint == nil {
            let fill = primary ? OpenerLook.primary : NSColor.white.withAlphaComponent(hovered ? 0.06 : 0)
            if primary {
                NSGradient(starting: fill.blended(withFraction: hovered ? 0.03 : 0, of: .white) ?? fill,
                           ending: OpenerLook.primaryBottom)?.draw(in: path, angle: -90)
            } else { fill.setFill(); path.fill() }
            (primary ? OpenerLook.accent.withAlphaComponent(0.22) : OpenerLook.edge).setStroke()
            path.lineWidth = 1; path.stroke()
            ink = primary ? .white : (openerPinned ? OpenerLook.accent : OpenerLook.muted)
        } else {
            ink = Pal.drawButton(path, tone: tone, hovered: hovered, pressed: pressed)
        }
        let filled = tone == .accent || tone == .success
        let t = NSAttributedString(string: title, attributes: [.font: labelFont ?? Typo.button, .foregroundColor: ink])
        // The shortcut reads like a menu's: the same line, quieter, no box of its own.
        let k = NSAttributedString(string: key, attributes: [.font: openerAppearance && primary ? NSFont.systemFont(ofSize: 10) : Self.keyFont,
                                                              .foregroundColor: openerAppearance ? ink : (filled ? ink.withAlphaComponent(0.6) : Pal.textTertiary)])
        let ts = t.size(), ks = k.size()
        let keyWidth = openerAppearance && primary ? max(16, ks.width + 4) : ks.width
        let iw = symbol == nil ? 0 : Self.iconBox + (title.isEmpty ? 0 : Self.iconGap)
        // Too narrow for the key as well: the icon and word alone, so nothing spills over the edge.
        let showKey = !key.isEmpty && iw + ts.width + Self.keyGap + keyWidth <= bounds.width - 24
        let x0 = (bounds.width - (iw + ts.width + (showKey ? Self.keyGap + keyWidth : 0))) / 2
        if let s = symbol {
            Neon.symbol(s, in: NSRect(x: x0, y: (bounds.height - Self.iconBox) / 2, width: Self.iconBox, height: Self.iconBox),
                        size: openerAppearance && title.isEmpty ? 16 : 12, weight: .medium, color: ink)
        }
        t.draw(at: NSPoint(x: x0 + iw, y: (bounds.height - ts.height) / 2))
        if showKey {
            let keyX = x0 + iw + ts.width + Self.keyGap
            if openerAppearance && primary {
                let chip = NSRect(x: keyX, y: bounds.midY - 8, width: keyWidth, height: 16)
                NSColor.white.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
                k.draw(at: NSPoint(x: chip.midX - ks.width / 2, y: chip.midY - ks.height / 2))
            } else { k.draw(at: NSPoint(x: keyX, y: (bounds.height - ks.height) / 2)) }
        }
    }
    private static let keyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let keyGap: CGFloat = 8
    private static let iconBox: CGFloat = 14
    private static let iconGap: CGFloat = 6
    /// The width that fits the icon, word and key with comfortable room either side.
    var fittedWidth: CGFloat {
        let t = (title as NSString).size(withAttributes: [.font: labelFont ?? Typo.button]).width
        let k = key.isEmpty ? 0 : (key as NSString).size(withAttributes: [.font: Self.keyFont]).width + Self.keyGap
        let i = symbol == nil ? 0 : Self.iconBox + Self.iconGap
        return ceil(i + t + k) + Space.l * 2
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
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

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

final class OpenerFlipped: NSView { override var isFlipped: Bool { true } }

/// A rounded panel that paints its own fill, edge and glow, so it's solid however it's layered.
final class OpenerGlass: NSView {
    var gradient: [NSColor]? { didSet { needsDisplay = true } }
    private let gradientLayer = CAGradientLayer()
    var radius: CGFloat = 26 { didSet { needsDisplay = true } }
    /// nil: the theme's glass and edge, read each time it draws.
    var fill: NSColor? { didSet { needsDisplay = true } }
    var edge: NSColor? { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 1.5 { didSet { needsDisplay = true } }
    var glow: Float = 0.75 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(gradientLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        guard let l = layer else { return }
        l.cornerRadius = radius
        l.cornerCurve = .continuous
        l.backgroundColor = (fill ?? Neon.fillBottom).cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradientLayer.isHidden = gradient == nil
        gradientLayer.frame = bounds
        gradientLayer.colors = gradient?.map(\.cgColor)
        gradientLayer.cornerRadius = radius
        gradientLayer.cornerCurve = .continuous
        gradientLayer.masksToBounds = true
        CATransaction.commit()
        l.borderWidth = lineWidth
        l.borderColor = (edge ?? Neon.edge).cgColor
        l.shadowColor = Neon.halo.cgColor
        l.shadowOpacity = glow
        l.shadowRadius = 22
        l.shadowOffset = .zero
        l.masksToBounds = false
    }
}

/// "⏎ Open", "⌘K Actions", "‹ Quit All Apps": a key and a word, centred both ways.
final class OpenerPill: NSView {
    var title = "Open" { didSet { needsDisplay = true; needsLayout = true } }
    var key = "⏎" { didSet { needsDisplay = true } }
    /// Quieter: dark fill, dim edge.
    var ghost = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let keyFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var text: NSAttributedString {
        let s = NSMutableAttributedString(string: key, attributes: [.font: Self.keyFont, .foregroundColor: Neon.glyph])
        s.append(NSAttributedString(string: "  " + title, attributes: [.font: Self.font, .foregroundColor: Neon.text]))
        return s
    }
    var fittedWidth: CGFloat { ceil(text.size().width) + 28 }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (ghost ? Neon.chip : Neon.accent.withAlphaComponent(0.16)).setFill(); path.fill()
        (ghost ? Neon.chipEdge : Neon.accent.withAlphaComponent(0.65)).setStroke(); path.lineWidth = 1.2; path.stroke()
        let t = text, sz = t.size()
        t.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}


/// What the controller needs from either look of the opener.
protocol OpenerSurface: NSView, NSTextFieldDelegate {
    var onLaunch: ((AppEntry, Bool) -> Void)? { get set }
    var onSearchWeb: ((String) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var onAction: ((QuickAction) -> Void)? { get set }
    var onFinish: ((String?) -> Void)? { get set }
    var onQuitAll: (([NSRunningApplication]) -> Void)? { get set }
    var band: CGFloat { get set }
    var ropeX: CGFloat { get set }
    var searchField: NSTextField { get }
    func prepare()
    func reload()
    func animateIn()
    func animateOut(_ done: @escaping () -> Void)
    func toss(_ app: AppEntry, _ done: @escaping () -> Void)
}
extension OpenerSurface {
    /// Navigation belongs to the opener window, not just to its search field's editor.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.contains(.command) || mods.contains(.control) { return performKeyEquivalent(with: event) }
        guard mods.isEmpty || (mods == .shift && event.keyCode == 48),
              let editor = window?.fieldEditor(true, for: searchField) as? NSTextView,
              !editor.hasMarkedText() else { return false }
        let command: Selector
        switch event.keyCode {
        case 53: command = #selector(NSResponder.cancelOperation(_:))
        case 125: command = #selector(NSResponder.moveDown(_:))
        case 126: command = #selector(NSResponder.moveUp(_:))
        case 123: command = #selector(NSResponder.moveLeft(_:))
        case 124: command = #selector(NSResponder.moveRight(_:))
        case 36, 76: command = #selector(NSResponder.insertNewline(_:))
        case 48: command = mods == .shift ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:))
        default: return false
        }
        return control?(searchField, textView: editor, doCommandBy: command) ?? false
    }
}
extension AppOpenerView: OpenerSurface { var searchField: NSTextField { field } }
