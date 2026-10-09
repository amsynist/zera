import AppKit

extension TreeOpenerView: OpenerSurface { var searchField: NSTextField { field } }

// The App Opener's classic look, kept as a choice in Settings → General (Opener style):
// a window held by Zera whose search is the root of a tree — Your usual, Commands and Actions
// fold open under it, the chosen item's details sit on the right. Same data, commands, ⌘K
// actions and shortcuts as the orbit (`AppOpenerView`).

private enum OP {
    static let cardW: CGFloat = 780
    static let cardH: CGFloat = 560
    static let margin: CGFloat = 40           // room for the glow
    static let width: CGFloat = cardW + margin * 2
    static let ropeGap: CGFloat = 34          // notch → her head
    static let zeraW: CGFloat = 104
    static let paws: CGFloat = 9              // how far her paws overlap the window
    static let tiles = 6                      // ⌘1…⌘6
}

final class TreeOpenerView: NSView, NSTextFieldDelegate {
    private var exitAnimationID = 0
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
    private let card = OpenerGlass()
    /// v2: the search sits in a field box, and a bright hairline marks where she holds the window.
    private let fieldBox = OpenerGlass()
    private let rootLine = CAGradientLayer()
    // The search row: the root.
    private let rootDot = OpenerGlass()
    private let searchIcon = NSImageView()
    private let chip = OpenerPill()
    private let field = NSTextField()
    private let rightLabel = NSTextField(labelWithString: "")
    private let rootStem = NSView()
    // The tree.
    private let treeScroll = NSScrollView()
    private let treeDoc = OpenerFlipped()
    private let dimLines = CAShapeLayer()
    private let litLines = CAShapeLayer()
    private var lineViews: [NSView] = []
    // The chosen item, on the right.
    private let detail = OpenerFlipped()
    private let dIcon = NSImageView()
    private let dHalo = CAGradientLayer()
    private let dName = NSTextField(labelWithString: "")
    private let dBlurb = NSTextField(wrappingLabelWithString: "")
    private var dFacts: [(NSTextField, NSTextField, NSView)] = []
    private let dPrimary = TreeButton()
    private let dSecondary = TreeButton()
    /// Pin / Unpin for the chosen app, beside Actions, so the shortcut is in plain sight.
    private let dPin = TreeButton()
    private let dEmpty = NSTextField(wrappingLabelWithString: "")
    // The footer.
    private let footRule = NSView()
    private let paneRule = NSView()
    private let foot = NSTextField(labelWithString: "")
    private let footOpen = OpenerPill()
    private let footActions = OpenerPill()

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

    /// What the tree shows, top to bottom.
    private enum Line {
        case group(Branch, open: Bool, count: Int)
        case item(Int)          // results[i]
        case command(OpenerCommand)
        case child(Int)         // listItems[i]
        case leaf(Int)          // shownActions[i]
        case note(String)
    }
    private struct Placed {
        let line: Line
        let view: NSView
        let level: Int          // 0 group, 1 item, 2 child or leaf, 3 leaf of a child
        var lit: Bool
    }
    private var placed: [Placed] = []
    private var versions: [URL: String] = [:]

    var isShowingActions: Bool { actionsOpen }
    var chosenActionTitle: String? { actionsOpen ? shownActions[safe: leaf]?.title : nil }
    var openBranchTitle: String { effectiveBranch.title }
    var visibleRowTitles: [String] { placed.compactMap { ($0.view as? TreeRowView)?.accessibilityLabel() } }

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
    private var cardTop: CGFloat { band + OP.ropeGap + zeraH - OP.paws }
    private var cx: CGFloat { ropeX > 0 ? ropeX : bounds.width / 2 }
    func panelHeight(band: CGFloat) -> CGFloat { self.band = band; return cardTop + OP.cardH + OP.margin }

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

        card.radius = 30
        card.lineWidth = 1
        card.glow = 0.16
        fieldBox.radius = 14
        fieldBox.lineWidth = 1
        fieldBox.glow = 0
        card.addSubview(fieldBox)
        rootLine.startPoint = CGPoint(x: 0, y: 0.5)
        rootLine.endPoint = CGPoint(x: 1, y: 0.5)
        holder.addSubview(card)

        // The root: a glowing node with the magnifier, then the field.
        rootDot.radius = 15
        rootDot.lineWidth = 1
        rootDot.glow = 0
        card.addSubview(rootDot)
        rootDot.addSubview(searchIcon)
        chip.key = "‹"
        chip.ghost = true
        chip.isHidden = true
        chip.onClick = { [weak self] in self?.collapse() }
        card.addSubview(chip)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = OpenerLook.classicSearchFont
        field.placeholderAttributedString = NSAttributedString(string: "Open an app…", attributes: [
            .foregroundColor: Neon.textFaint, .font: OpenerLook.classicSearchFont])
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("App name")
        card.addSubview(field)
        rightLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        rightLabel.alignment = .right
        card.addSubview(rightLabel)
        rootStem.wantsLayer = true
        card.addSubview(rootStem)

        // The tree: rows in a scroll view (no scroll bar), branches drawn under them.
        treeScroll.drawsBackground = false
        treeScroll.contentView.drawsBackground = false
        treeScroll.borderType = .noBorder
        treeScroll.hasVerticalScroller = false
        treeScroll.documentView = treeDoc
        treeDoc.wantsLayer = true
        for (l, width) in [(dimLines, CGFloat(1.5)), (litLines, 1.8)] {
            l.fillColor = nil
            l.lineWidth = width
            l.lineCap = .round
            l.lineJoin = .round
            treeDoc.layer?.addSublayer(l)
        }
        card.addSubview(treeScroll)

        // The chosen item.
        dHalo.type = .radial
        dHalo.locations = [0, 0.5, 1]
        dHalo.startPoint = CGPoint(x: 0.5, y: 0.5)
        dHalo.endPoint = CGPoint(x: 1, y: 1)
        detail.wantsLayer = true
        detail.layer?.addSublayer(dHalo)
        dIcon.imageScaling = .scaleProportionallyUpOrDown
        detail.addSubview(dIcon)
        dName.font = OpenerLook.classicDetailFont
        dName.alignment = .center
        dName.lineBreakMode = .byTruncatingTail
        detail.addSubview(dName)
        dBlurb.font = NSFont.systemFont(ofSize: 13)
        dBlurb.alignment = .center
        dBlurb.maximumNumberOfLines = 2
        detail.addSubview(dBlurb)
        for _ in 0..<4 {
            let k = NSTextField(labelWithString: ""), v = NSTextField(labelWithString: ""), rule = NSView()
            k.font = NSFont.systemFont(ofSize: 12.5)
            v.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            v.alignment = .right
            v.lineBreakMode = .byTruncatingMiddle
            rule.wantsLayer = true
            [k, v, rule].forEach(detail.addSubview)
            dFacts.append((k, v, rule))
        }
        dPrimary.primary = true
        for button in [dPrimary, dSecondary, dPin] {
            button.openerAppearance = true
            button.labelFont = OpenerLook.buttonFont
        }
        dPrimary.onClick = { [weak self] in self?.primaryAction() }
        dSecondary.key = "⌘M"
        dSecondary.title = "Actions"
        dSecondary.onClick = { [weak self] in self?.toggleActions() }
        detail.addSubview(dPrimary)
        detail.addSubview(dSecondary)
        dPin.key = "⇧⌘P"
        dPin.onClick = { [weak self] in self?.togglePinChosen() }
        detail.addSubview(dPin)
        dEmpty.font = NSFont.systemFont(ofSize: 13.5)
        dEmpty.alignment = .center
        detail.addSubview(dEmpty)
        card.addSubview(detail)

        for r in [paneRule, footRule] {
            r.wantsLayer = true
            card.addSubview(r)
        }
        foot.font = NSFont.systemFont(ofSize: 12)
        foot.lineBreakMode = .byTruncatingTail
        card.addSubview(foot)
        footOpen.ghost = true
        footOpen.onClick = { [weak self] in self?.primaryAction() }
        footActions.ghost = true
        footActions.key = "⌘M"
        footActions.title = "Actions"
        footActions.onClick = { [weak self] in self?.toggleActions() }
        card.addSubview(footOpen)
        card.addSubview(footActions)

        zera.image = sprite?.image
        zera.imageScaling = .scaleProportionallyUpOrDown
        zera.wantsLayer = true
        holder.addSubview(zera)
        setAccessibilityRole(.group)
        setAccessibilityLabel("App opener")
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Colours from the current theme. Runs each time the opener opens, so a theme picked in
    /// Settings shows up here too.
    private func applyTheme() {
        card.fill = Neon.fillBottom.withAlphaComponent(0.98)
        card.edge = ThemeStore.shared.current.border
        fieldBox.fill = Neon.field
        fieldBox.edge = ThemeStore.shared.current.border
        rootLine.colors = [Neon.accent.withAlphaComponent(0).cgColor, Neon.accent.withAlphaComponent(0.9).cgColor, Neon.accent.withAlphaComponent(0).cgColor]
        rootDot.fill = Neon.cyan.withAlphaComponent(0.14)
        rootDot.edge = Neon.cyan.withAlphaComponent(0.6)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold).applying(.init(paletteColors: [Neon.cyan])))
        field.textColor = Neon.text
        rightLabel.textColor = Neon.textDim
        rootStem.layer?.backgroundColor = Neon.cyan.withAlphaComponent(0.9).cgColor
        dimLines.strokeColor = Neon.textFaint.withAlphaComponent(0.45).cgColor
        litLines.strokeColor = Neon.cyan.cgColor
        dHalo.colors = [Neon.accent.withAlphaComponent(0.22).cgColor, Neon.halo.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
        dName.textColor = Neon.text
        dBlurb.textColor = Neon.textDim
        for (k, v, rule) in dFacts {
            k.textColor = Neon.textDim
            v.textColor = Neon.text
            rule.layer?.backgroundColor = Neon.divider.cgColor
        }
        dEmpty.textColor = Neon.textDim
        for r in [paneRule, footRule] { r.layer?.backgroundColor = Neon.divider.cgColor }
        foot.textColor = Neon.textDim
        ([card, rootDot, chip, dPrimary, dSecondary, dPin, footOpen, footActions] as [NSView]).forEach { $0.needsDisplay = true }
    }

    // MARK: Data

    func prepare() {
        applyTheme()
        actionsOpen = false
        mode = .root
        commandScan = UUID()
        loading = false
        openBranch = .usual
        field.stringValue = ""
        setPlaceholder("Open an app…")
        selected = 0
        needsLayout = true
        layoutSubtreeIfNeeded()
        reload()
        treeScroll.contentView.scroll(to: .zero)
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

    /// Makes the rows for what's showing and lays them out; the branches are drawn to match.
    private func rebuild() {
        placed.forEach { $0.view.removeFromSuperview() }
        placed = []
        var lines: [(Line, Int, Bool)] = []          // line, level, on the lit path
        switch mode {
        case .root:
            let shown = Set(results.indices)
            var i = 0
            for b in branches {
                let open = typing || b.branch == effectiveBranch
                let holds = open && b.items.indices.map { i + $0 }.contains(selected) && !results.isEmpty
                lines.append((.group(b.branch, open: open, count: b.total), 0, holds))
                guard open else { continue }
                for _ in b.items {
                    guard shown.contains(i) else { i += 1; continue }
                    lines.append((.item(i), 1, i == selected))
                    if i == selected, actionsOpen {
                        for (k, _) in shownActions.enumerated() { lines.append((.leaf(k), 2, k == leaf)) }
                        if shownActions.isEmpty { lines.append((.note("No action called “\(query)”."), 2, false)) }
                    }
                    i += 1
                }
            }
            if branches.isEmpty { lines.append((.note("Nothing called “\(query)”. ⏎ searches the web."), 0, false)) }
        case .command(let entered):
            lines.append((.group(.commands, open: true, count: OpenerCommand.allCases.count), 0, true))
            for c in OpenerCommand.allCases {
                lines.append((.command(c), 1, c == entered))
                guard c == entered else { continue }
                if listItems.isEmpty { lines.append((.note(emptyNote(c)), 2, false)) }
                for (k, _) in listItems.enumerated() {
                    lines.append((.child(k), 2, k == selected))
                    if k == selected, actionsOpen {
                        for (a, _) in shownActions.enumerated() { lines.append((.leaf(a), 3, a == leaf)) }
                    }
                }
            }
        }
        for (line, level, lit) in lines {
            let v = makeRow(line)
            treeDoc.addSubview(v)
            placed.append(Placed(line: line, view: v, level: level, lit: lit))
        }
        layoutTree()
        updateDetail()
        updateFooter()
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

    private func makeRow(_ line: Line) -> NSView {
        switch line {
        case .group(let b, let open, let count):
            let g = TreeGroupView(title: typing && b == .usual ? "APPS" : b.title, count: open ? nil : count, open: open)
            g.onClick = { [weak self] in self?.openBranchTapped(b) }
            return g
        case .item(let i):
            let it = results[i]
            let r = TreeRowView(style: .item)
            r.icon = it.icon
            r.titleText = highlighted(it.name, it.hits, size: 14, weight: .medium)
            switch it {
            case .app(let a, _, let running):
                let pinned = AppCatalog.shared.isPinned(a)
                r.accessory = pinned ? (running ? "Pinned · running" : "Pinned") : (running ? "Running" : "")
                r.running = running
            case .command(let c, _): r.sub = c.subtitle.replacingOccurrences(of: "Command · ", with: ""); r.accessory = "Command"
            case .action(let a, _): r.sub = OpenerActions.subtitle(a).replacingOccurrences(of: "Action · ", with: ""); r.accessory = "Action"
            }
            r.setAccessibilityLabel(it.name)
            r.selected = i == selected && !actionsOpen
            r.onClick = { [weak self] in
                guard let self = self else { return }
                if i == self.selected, !self.actionsOpen { self.openSelected() } else { self.choose(i) }
            }
            return r
        case .command(let c):
            let r = TreeRowView(style: .item)
            r.icon = c.icon
            r.titleText = NSAttributedString(string: c.title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: Neon.text])
            r.sub = c.subtitle.replacingOccurrences(of: "Command · ", with: "")
            r.dimmed = mode != .command(c)
            r.setAccessibilityLabel(c.title)
            r.onClick = { [weak self] in
                guard let self = self else { return }
                if self.mode == .command(c) { self.back() } else { self.enter(c) }
            }
            return r
        case .child(let k):
            let it = listItems[k]
            let r = TreeRowView(style: .child)
            r.icon = it.app?.icon
            r.mono = it.port != nil
            r.titleText = NSAttributedString(string: it.title, attributes: [
                .font: it.port != nil ? NSFont.monospacedSystemFont(ofSize: 13.5, weight: .semibold) : NSFont.systemFont(ofSize: 13.5, weight: .medium),
                .foregroundColor: Neon.text])
            if mode == .command(.quitAll) {
                r.toggle = !it.keep
                r.sub = it.keep ? "stays open" : ""
                r.dimmed = it.keep
            } else {
                r.sub = it.detail
                r.accessory = it.trailing
            }
            r.setAccessibilityLabel(it.title)
            r.selected = k == selected && !actionsOpen
            r.onClick = { [weak self] in
                guard let self = self else { return }
                self.chooseChild(k)
                if self.mode == .command(.quitAll) { self.toggleKeep() }
            }
            return r
        case .leaf(let k):
            let a = shownActions[k]
            let r = TreeRowView(style: .leaf)
            let ask = confirming == k
            r.symbol = ask ? "exclamationmark.triangle.fill" : a.symbol
            r.tint = ask ? Neon.red : a.tint
            r.titleText = NSAttributedString(string: ask ? (a.confirm ?? a.title) : a.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: (ask ? Neon.red : (a.tint ?? Neon.text))])
            r.accessory = ask ? "⏎ confirm" : (a.shortcut?.label ?? "")
            r.selected = k == leaf
            r.setAccessibilityLabel(a.title)
            // Hover only tints the row: choosing on hover fought the arrow keys (the list scrolls
            // under a resting pointer, and the row under it took the highlight back).
            r.onClick = { [weak self] in self?.triggerLeaf(k) }
            return r
        case .note(let text):
            let r = TreeRowView(style: .note)
            r.titleText = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Neon.textDim])
            return r
        }
    }

    /// Rows top to bottom, then the branches: a trunk from the root, an elbow into each row,
    /// and a trunk under any row with children. The path to the chosen row is drawn lit.
    private func layoutTree() {
        let w = treeScroll.contentSize.width
        var y: CGFloat = 10
        var frames: [NSRect] = []
        for (n, p) in placed.enumerated() {
            if n > 0, case .group = p.line { y += 4 }
            let x = TV.rowX[p.level]
            let h: CGFloat
            switch p.line {
            case .group: h = 30
            case .item, .command: h = 40
            case .child: h = 38
            case .leaf: h = 32
            case .note: h = 30
            }
            let f = NSRect(x: x, y: y, width: w - x - 12, height: h)
            p.view.frame = f
            frames.append(f)
            y += h
        }
        treeDoc.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 14, treeScroll.contentSize.height))

        // Branches. Each row hangs from the nearest row above it one level up (or the root).
        let dim = CGMutablePath(), lit = CGMutablePath()
        var lastChild: [Int: CGFloat] = [:]                 // parent row index → its last child's mid y
        var parentOf: [Int] = Array(repeating: -1, count: placed.count)
        for (n, p) in placed.enumerated() {
            var parent = -1
            for m in stride(from: n - 1, through: 0, by: -1) where placed[m].level < p.level { parent = m; break }
            if p.level > 0, parent >= 0, placed[parent].level != p.level - 1 { parent = -1 }
            parentOf[n] = parent
            let mid = frames[n].midY
            lastChild[parent] = mid
            let tx = TV.trunkX[p.level]
            let end = frames[n].minX + (p.level == 0 ? -4 : 0)
            elbow(dim, x: tx, y: mid, to: end)
            if p.lit { elbow(lit, x: tx, y: mid, to: end) }
        }
        for (parent, last) in lastChild {
            let level = parent < 0 ? 0 : placed[parent].level + 1
            let tx = TV.trunkX[level]
            let top = parent < 0 ? 0 : frames[parent].maxY - (placed[parent].level == 0 ? 6 : 4)
            dim.move(to: CGPoint(x: tx, y: top)); dim.addLine(to: CGPoint(x: tx, y: last - 7))
        }
        // The lit trunk: from each lit row's parent down to it.
        for (n, p) in placed.enumerated() where p.lit {
            let parent = parentOf[n]
            let tx = TV.trunkX[p.level]
            let top = parent < 0 ? 0 : frames[parent].maxY - (placed[parent].level == 0 ? 6 : 4)
            lit.move(to: CGPoint(x: tx, y: top)); lit.addLine(to: CGPoint(x: tx, y: frames[n].midY - 7))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLines.frame = treeDoc.bounds
        litLines.frame = treeDoc.bounds
        dimLines.path = dim
        litLines.path = lit
        // Keep the lines under the rows.
        treeDoc.layer?.insertSublayer(litLines, at: 0)
        treeDoc.layer?.insertSublayer(dimLines, at: 0)
        CATransaction.commit()
        revealChosen()
    }

    private func elbow(_ p: CGMutablePath, x: CGFloat, y: CGFloat, to end: CGFloat) {
        p.move(to: CGPoint(x: x, y: y - 7))
        p.addQuadCurve(to: CGPoint(x: x + 7, y: y), control: CGPoint(x: x, y: y))
        p.addLine(to: CGPoint(x: max(x + 7, end - 2), y: y))
    }

    /// Scrolls the chosen row (or the chosen action) into view.
    private func revealChosen() {
        let target = placed.last { p in
            switch p.line {
            case .leaf(let k): return actionsOpen && k == leaf
            case .item(let i): return !actionsOpen && i == selected
            case .child(let k): return !actionsOpen && k == selected
            default: return false
            }
        }
        guard let v = target?.view else { return }
        v.scrollToVisible(v.bounds.insetBy(dx: 0, dy: -24))
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
        openBranch = b
        selected = 0
        SoundService.shared.play(.openerTick)
        reload()
        popRows()
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

    private func updateDetail() {
        var icon: NSImage?, name = "", blurb = "", facts: [(String, String)] = []
        var primary = "", primaryTint: NSColor? = nil
        switch mode {
        case .root:
            if let it = results[safe: selected] {
                icon = it.icon; name = it.name
                switch it {
                case .app(let a, _, let running):
                    blurb = "Application"
                    let opens = AppCatalog.shared.openCount(a)
                    facts = [("Status", running ? "Running" : "Not running"), ("Version", version(a)),
                             ("Opened from Zera", opens == 0 ? "Never yet" : (opens == 1 ? "Once" : "\(opens) times")), ("Where", a.folder)]
                    primary = "Open \(a.name)"
                case .command(let c, _):
                    blurb = c.subtitle.replacingOccurrences(of: "Command · ", with: "").capitalizedFirst
                    facts = [("Kind", "Command")]
                    primary = "Open command"
                case .action(let a, _):
                    blurb = OpenerActions.subtitle(a).replacingOccurrences(of: "Action · ", with: "").capitalizedFirst
                    facts = [("Kind", "Zera action")]
                    primary = "Run"
                }
            }
        case .command(let c):
            icon = c.icon; name = c.title
            blurb = c.subtitle.replacingOccurrences(of: "Command · ", with: "").capitalizedFirst
            let it = listItems[safe: selected]
            switch c {
            case .quitAll:
                let n = quitTargets.count
                facts = [("Open apps", "\(runningApps.count)"), ("Will quit", "\(n)"),
                         ("Stay open", "Finder, Zera" + (runningApps.count > n ? " + \(runningApps.count - n)" : ""))]
                primary = n == 1 ? "Quit 1 app" : "Quit \(n) apps"
                primaryTint = Neon.green
            case .killProcess:
                facts = [("Processes", loading ? "…" : "\(listItems.count)")]
                if let it = it { facts += [("Chosen", it.title), ("Process ID", "\(it.pid)")]; primary = "Quit \(it.title)" }
            case .killPort:
                facts = [("Listening", loading ? "…" : "\(listItems.count)")]
                if let it = it { facts += [("Chosen", it.title), ("Process ID", "\(it.pid)")]; primary = "Stop \(it.title)" }
            case .custom:
                facts = [("Kind", "Command"), ("Status", "Coming soon")]
            }
        }
        if actionsOpen, let a = shownActions[safe: leaf] {
            primary = confirming == leaf ? (a.confirm ?? a.title) : a.title
            primaryTint = a.tint
        }
        let has = icon != nil
        ([dIcon, dName, dBlurb, dPrimary, dSecondary] as [NSView]).forEach { $0.isHidden = !has }
        dEmpty.isHidden = has
        dEmpty.stringValue = typing ? "Nothing called “\(query)”.\n⏎ searches the web for it." : (AppCatalog.shared.apps.isEmpty ? "Looking for your apps…" : "")
        dIcon.image = icon
        dName.stringValue = name
        dBlurb.stringValue = blurb
        for (n, f) in dFacts.enumerated() {
            let fact = facts[safe: n]
            ([f.0, f.1, f.2] as [NSView]).forEach { $0.isHidden = fact == nil }
            f.0.stringValue = fact?.0 ?? ""
            f.1.stringValue = fact?.1 ?? ""
        }
        dPrimary.title = primary
        dPrimary.isHidden = !has || primary.isEmpty || (actionsOpen && shownActions.isEmpty)
        dPrimary.tint = primaryTint
        dSecondary.title = actionsOpen ? "Hide actions" : "Actions"
        dSecondary.key = actionsOpen ? "esc" : "⌘M"
        let pinnable = chosenApp
        dPin.isHidden = !has || actionsOpen || pinnable == nil
        if let a = pinnable { dPin.title = AppCatalog.shared.isPinned(a) ? "Unpin" : "Pin" }
        needsLayout = true
    }

    private func updateFooter() {
        switch mode {
        case .root where actionsOpen: foot.stringValue = "↑↓ choose   ⏎ run   type to search actions   esc back"
        case .root:
            if let a = chosenApp, AppCatalog.shared.isPinned(a) {
                foot.stringValue = "↑↓ choose   ⇥ next branch   ⇧⌘P unpin   ⌥⌘↑↓ move"
            } else {
                foot.stringValue = "↑↓ choose   ⇥ next branch   ⇧⌘P pin   ⌘1–⌘6 quick open"
            }
        case .command(.quitAll): foot.stringValue = "↑↓ choose   space or click to keep   esc back"
        case .command(.custom): foot.stringValue = "esc back"
        case .command: foot.stringValue = "↑↓ choose   ⌘⏎ force   ⌘R refresh   esc back"
        }
        footOpen.title = mode == .command(.quitAll) ? "Quit all" : (actionsOpen ? "Run" : (mode == .root ? (results.isEmpty ? "Search the web" : verb) : (mode == .command(.killPort) ? "Stop" : "Quit")))
        footOpen.isHidden = actionsOpen && shownActions.isEmpty
        footActions.isHidden = mode == .command(.custom) || (mode == .root && results.isEmpty)
        footActions.title = actionsOpen ? "Close" : "Actions"
        footActions.key = actionsOpen ? "esc" : "⌘M"
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
        popRows(from: 1)
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
        setPlaceholder("Open an app…")
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

    /// Grows the chosen item's actions under it; the search field now searches them.
    private func openActions(confirming ask: Int? = nil) {
        guard let (name, actions) = currentActions(), !actions.isEmpty else { NSSound.beep(); return }
        SoundService.shared.play(.openerTick)
        if !actionsOpen { savedQuery = field.stringValue }
        actionsOpen = true
        allActions = actions
        shownActions = actions
        leaf = ask ?? 0
        confirming = ask
        field.stringValue = ""
        setPlaceholder("Search actions for \(name)…")
        chip.title = name
        chip.isHidden = false
        rightLabel.textColor = Neon.textDim
        rightLabel.stringValue = "\(actions.count) ACTIONS"
        window?.makeFirstResponder(field)
        rebuild()
        popRows(leavesOnly: true)
    }

    private func closeActions(refocus: Bool = true, rebuildTree: Bool = true) {
        guard actionsOpen else { return }
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
            setPlaceholder("Open an app…")
        }
        if refocus { window?.makeFirstResponder(field) }
        if rebuildTree { reload() }
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
        treeScroll.contentView.scroll(to: .zero)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
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
        if mods == .command, key == "k" || key == "m" { toggleActions(); return true }
        if mods == .command, key == "r", case .command(let command) = mode, command != .custom {
            refreshCommand(command)
            return true
        }
        if runShortcut(event) { return true }
        // ⌘Q only ever quits the chosen app, never Zera herself.
        if mods.contains(.command), key == "q" { NSSound.beep(); return true }
        // ⌘1…⌘6: the first six showing, top to bottom.
        if !actionsOpen, mode == .root, mods == .command, let c = key, let n = Int(c), (1...OP.tiles).contains(n), n - 1 < results.count {
            selected = n - 1
            openSelected()
            return true
        }
        if !actionsOpen, event.keyCode == KeyCombo.returnKey, mods == .command { openSelected(finder: true); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // A click outside the window sends her back up.
        let p = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(p) { onClose?() }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let c = cx
        holder.frame = bounds
        // Her picture's own rope sits exactly on the drawn one.
        zera.frame = NSRect(x: (c - ropeFraction * OP.zeraW).rounded(), y: band + OP.ropeGap, width: OP.zeraW, height: zeraH)
        if rope.layer?.animation(forKey: "grow") == nil {
            rope.frame = NSRect(x: (c - ropeWidth / 2).rounded(), y: 0, width: ropeWidth, height: band + OP.ropeGap + 14)
        }
        let W = OP.cardW, H = OP.cardH
        card.frame = NSRect(x: (c - W / 2).rounded(), y: cardTop, width: W, height: H)
        if rootLine.superlayer == nil { card.layer?.addSublayer(rootLine) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rootLine.frame = CGRect(x: W / 2 - 150, y: 0, width: 300, height: 1)
        CATransaction.commit()

        // The root row.
        rootDot.frame = NSRect(x: TV.trunkX[0] - 15, y: 17, width: 30, height: 30)
        searchIcon.frame = NSRect(x: 8, y: 8, width: 14, height: 14)
        var fx = rootDot.frame.maxX + 20
        if !chip.isHidden {
            let w = min(260, chip.fittedWidth)
            chip.frame = NSRect(x: fx, y: 17, width: w, height: 30)
            fx = chip.frame.maxX + 12
        }
        let rw = rightLabel.stringValue.isEmpty ? 0 : min(260, ceil(rightLabel.attributedStringValue.size().width) + 4)
        rightLabel.frame = NSRect(x: W - 34 - rw, y: 25, width: rw, height: 14)
        field.frame = NSRect(x: fx, y: 20, width: max(60, W - 34 - rw - 12 - fx), height: 24)
        // The field box runs from just past the root to the right edge, under the chip and field.
        let bx = rootDot.frame.maxX + 6
        fieldBox.frame = NSRect(x: bx, y: 10, width: W - 18 - bx, height: 44)
        rootStem.frame = NSRect(x: TV.trunkX[0] - 0.75, y: rootDot.frame.maxY, width: 1.5, height: TV.headH - rootDot.frame.maxY)

        let bodyH = H - TV.headH - TV.footH
        treeScroll.frame = NSRect(x: 0, y: TV.headH, width: TV.treeW, height: bodyH)
        if treeDoc.frame.width != treeScroll.contentSize.width { layoutTree() }
        paneRule.frame = NSRect(x: TV.treeW, y: TV.headH, width: 1, height: bodyH)
        footRule.frame = NSRect(x: 0, y: H - TV.footH, width: W, height: 1)
        detail.frame = NSRect(x: TV.treeW + 1, y: TV.headH, width: W - TV.treeW - 1, height: bodyH)
        layoutDetail()

        // The footer: hints left, the two main keys right.
        let ow = footOpen.fittedWidth, aw = footActions.isHidden ? 0 : footActions.fittedWidth
        footActions.frame = NSRect(x: W - 16 - aw, y: H - TV.footH + 10, width: aw, height: 28)
        footOpen.frame = NSRect(x: (footActions.isHidden ? W - 16 : footActions.frame.minX - 8) - ow, y: H - TV.footH + 10, width: ow, height: 28)
        foot.frame = NSRect(x: 22, y: H - TV.footH + 16, width: footOpen.frame.minX - 34, height: 16)
    }

    private func layoutDetail() {
        let w = detail.bounds.width, h = detail.bounds.height, pad: CGFloat = 26
        dIcon.frame = NSRect(x: (w - 72) / 2, y: 28, width: 72, height: 72)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dHalo.frame = dIcon.frame.insetBy(dx: -40, dy: -40)
        dHalo.isHidden = dIcon.isHidden
        CATransaction.commit()
        dName.frame = NSRect(x: pad, y: 110, width: w - pad * 2, height: 24)
        dBlurb.frame = NSRect(x: pad, y: 137, width: w - pad * 2, height: 32)
        var y: CGFloat = 182
        for f in dFacts where !f.0.isHidden {
            let labelWidth = min(130, ceil(f.0.attributedStringValue.size().width))
            f.0.frame = NSRect(x: pad, y: y + 9, width: labelWidth, height: 16)
            f.1.frame = NSRect(x: pad + labelWidth + 12, y: y + 9, width: w - pad * 2 - labelWidth - 12, height: 16)
            f.2.frame = NSRect(x: pad, y: y + 34, width: w - pad * 2, height: 1)
            y += 35
        }
        if dPin.isHidden {
            dSecondary.frame = NSRect(x: pad, y: h - 22 - 34, width: w - pad * 2, height: 34)
        } else {
            let half = ((w - pad * 2 - 8) / 2).rounded(.down)
            dPin.frame = NSRect(x: pad, y: h - 22 - 34, width: half, height: 34)
            dSecondary.frame = NSRect(x: pad + half + 8, y: h - 22 - 34, width: w - pad * 2 - half - 8, height: 34)
        }
        dPrimary.frame = NSRect(x: pad, y: dSecondary.frame.minY - 8 - 34, width: w - pad * 2, height: 34)
        dEmpty.frame = NSRect(x: pad, y: h / 2 - 30, width: w - pad * 2, height: 60)
    }

    // MARK: Motion

    /// She rappels down holding the opener; the branches draw down from the root and the rows
    /// slide in after them.
    func animateIn() {
        exitAnimationID += 1
        holder.layer?.removeAllAnimations()
        rope.layer?.removeAllAnimations()
        window?.makeFirstResponder(field)
        guard !Motion.reduced, let hl = holder.layer else { holder.alphaValue = 1; return }
        holder.alphaValue = 1
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
        for (l, delay) in [(dimLines, 0.2), (litLines, 0.28)] {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0; draw.toValue = 1
            draw.duration = 0.35
            draw.beginTime = CACurrentMediaTime() + delay
            draw.fillMode = .backwards
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(draw, forKey: "draw")
        }
        popRows(delay: 0.22)
    }

    /// Rows slide in from their branch, one after another: on open, a new branch, a command's
    /// list, or the actions (`leavesOnly`).
    private func popRows(delay: Double = 0, from start: Int = 0, leavesOnly: Bool = false) {
        guard !Motion.reduced else { return }
        var n = 0
        for (i, p) in placed.enumerated() where i >= start && n < 14 {
            if leavesOnly, case .leaf = p.line {} else if leavesOnly { continue }
            guard let l = p.view.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.18
            let slide = CASpringAnimation(keyPath: "transform.translation.x")
            slide.fromValue = -10; slide.toValue = 0
            slide.stiffness = 300; slide.damping = 22
            slide.duration = slide.settlingDuration
            let g = CAAnimationGroup()
            g.animations = [fade, slide]
            g.duration = slide.duration
            g.beginTime = CACurrentMediaTime() + delay + Double(n) * 0.025
            g.fillMode = .backwards
            l.add(g, forKey: "pop")
            n += 1
        }
    }

    /// Back up the rope.
    func animateOut(_ done: @escaping () -> Void) {
        guard !Motion.reduced, let hl = holder.layer else { done(); return }
        exitAnimationID += 1
        let id = exitAnimationID
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
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.exitAnimationID == id else { return }
            self.holder.layer?.removeAllAnimations()
            self.rope.layer?.removeAllAnimations()
        }
    }

    /// The chosen app's icon flies up into Zera's paws; she hops; then `done`.
    func toss(_ app: AppEntry, _ done: @escaping () -> Void) {
        let source = detail.convert(dIcon.frame, to: self)
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

/// The tree's measurements, in the window.
private enum TV {
    static let headH: CGFloat = 64
    static let footH: CGFloat = 48
    static let treeW: CGFloat = 470
    /// Where each level's trunk runs, and where its rows start.
    static let trunkX: [CGFloat] = [35, 60, 89, 117]
    static let rowX: [CGFloat] = [50, 68, 97, 125]
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}


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
