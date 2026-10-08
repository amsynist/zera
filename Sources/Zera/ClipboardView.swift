import AppKit

// MARK: - Clipboard island
//
//  Clipboard                      (Zera)            [⏸ Pause] [⋯]
//  38 items · kept for 7 days
//  [ All 38 | Text 24 | Images 6 | Files 5 | Pinned 2 ]  [🔍 Search copies]
//  PINNED
//  [≡] Standup notes: ship dark mode…            📌 ⌘1
//  TODAY                                 1 private copy skipped
//  [<>] git rebase -i HEAD~3                          ⌘2
//  ↑↓ move · ⏎ copy · Space preview · ⌘1–⌘9 quick copy     🔒 Stays on this Mac
//
// Click a row to copy it again; the controller folds the island away afterwards (a setting).
// Images get a grid; Space or ⋯ opens one item in place with a back button.

private enum CL {
    static let pad: CGFloat = Metrics.sidePad
    static let rowH: CGFloat = 52
    static let rowGap: CGFloat = 6
    static let groupH: CGFloat = 26
    static let toolsH: CGFloat = Metrics.segment
    static let footH: CGFloat = 26
    /// Tallest the list gets; longer lists scroll.
    static let listMax: CGFloat = 296
    static let thumbCols = 4
}

final class ClipboardView: CardBase, CardContent, NSTextFieldDelegate {
    var cardWidth: CGFloat { Isle.lensWidth }
    /// Copied back to the clipboard: the controller says so and folds the island away.
    var onCopied: ((ClipItem) -> Void)?
    var onOpenSettings: (() -> Void)?

    private enum Mode: Equatable { case intro, list, detail(UUID) }
    private var mode: Mode = .list
    private let store = ClipboardStore.shared
    private var filter: ClipboardStore.Filter = .all
    private var shown: [ClipItem] = []
    /// Keyboard selection in `shown`.
    private var cursor = 0

    // List.
    private let filters = GitHubSegmentedControl(items: [])
    private let search = SearchBox(placeholder: "Search copies")
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private var rows: [ClipRow] = []
    private var thumbs: [ClipThumb] = []
    private var headers: [String: ClipGroupHeader] = [:]
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let foot = NSTextField(labelWithString: "↑↓ move · ⏎ copy · Space preview · ⌘1–⌘9 quick copy")
    private let local = NSTextField(labelWithString: "Stays on this Mac")
    private let lockIcon = NSImageView()
    private var pauseButton: PRActionButton!
    private var moreButton: GHSquareButton!

    // Detail.
    private var backButton: GHSquareButton!
    private var pinButton: GHSquareButton!
    private var deleteButton: GHSquareButton!
    private let preview = NSScrollView()
    private let previewText = NSTextView()
    private let previewImage = NSImageView()
    private let previewBox = NSView()
    private let facts = NSTextField(labelWithString: "")
    private var copyButton: PRActionButton!
    private var plainButton: PRActionButton!
    private var shelfButton: PRActionButton!

    // First run.
    private let introText = NSTextField(wrappingLabelWithString: "Zera can remember what you copy, so you can grab it again later.")
    private var introBullets: [NSTextField] = []
    private var introButton: PRActionButton!

    init() {
        super.init(width: 600, title: "Clipboard")
        let p = Pal
        pauseButton = PRActionButton("Pause", style: .secondary, symbol: "pause.fill", target: self, action: #selector(pauseTapped))
        moreButton = GHSquareButton(symbol: "ellipsis", label: "More", target: self, action: #selector(moreTapped))
        backButton = GHSquareButton(symbol: "chevron.left", label: "Back", target: self, action: #selector(backTapped))
        pinButton = GHSquareButton(symbol: "pin", label: "Pin", target: self, action: #selector(pinTapped))
        deleteButton = GHSquareButton(symbol: "trash", label: "Delete", target: self, action: #selector(deleteTapped))
        copyButton = PRActionButton("Copy", style: .primary, symbol: "doc.on.doc", target: self, action: #selector(copyTapped))
        plainButton = PRActionButton("Copy as plain text", style: .secondary, target: self, action: #selector(plainTapped))
        shelfButton = PRActionButton("Add to Shelf", style: .secondary, symbol: "tray.and.arrow.down", target: self, action: #selector(shelfTapped))
        introButton = PRActionButton("Turn on clipboard history", style: .primary, target: self, action: #selector(turnOnTapped))
        [pauseButton, moreButton, backButton, pinButton, deleteButton].forEach { addSubview($0!) }

        filters.fitToContent = true
        filters.chipStyle = true
        filters.onSelect = { [weak self] i in
            guard let self = self else { return }
            self.filter = ClipboardStore.Filter(rawValue: i) ?? .all
            self.cursor = 0
            self.reload()
        }
        filters.switches = { [weak self] in self.map { [$0.scroll] } ?? [] }
        addSubview(filters)
        search.field.delegate = self
        addSubview(search)

        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = doc
        addSubview(scroll)

        empty.font = Typo.body
        empty.textColor = p.textSecondary
        empty.alignment = .center
        addSubview(empty)
        foot.font = Typo.caption
        foot.textColor = p.textTertiary
        foot.lineBreakMode = .byTruncatingTail
        addSubview(foot)
        local.font = Typo.caption
        local.textColor = p.textTertiary
        local.alignment = .right
        addSubview(local)
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        lockIcon.contentTintColor = p.textTertiary
        addSubview(lockIcon)

        // Detail.
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = Radius.l
        previewBox.layer?.cornerCurve = .continuous
        previewBox.layer?.backgroundColor = p.field.cgColor
        previewBox.layer?.borderWidth = 1
        previewBox.layer?.borderColor = p.border.cgColor
        addSubview(previewBox)
        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.drawsBackground = false
        previewText.textColor = p.text
        previewText.textContainerInset = NSSize(width: 6, height: 8)
        previewText.isVerticallyResizable = true
        previewText.textContainer?.widthTracksTextView = true
        preview.documentView = previewText
        preview.hasVerticalScroller = true
        preview.scrollerStyle = .overlay
        preview.drawsBackground = false
        preview.borderType = .noBorder
        previewBox.addSubview(preview)
        previewImage.imageScaling = .scaleProportionallyDown
        previewBox.addSubview(previewImage)
        facts.font = Typo.body
        facts.textColor = p.textSecondary
        facts.maximumNumberOfLines = 3
        addSubview(facts)
        [copyButton, plainButton, shelfButton].forEach { addSubview($0!) }

        // First run.
        introText.font = Typo.bodyMedium
        introText.textColor = p.text
        introText.alignment = .center
        addSubview(introText)
        for line in ["Text, links, code, images and files you copy",
                     "Kept on this Mac only, for 7 days (you choose)",
                     "Passwords and apps like 1Password are always skipped"] {
            let l = NSTextField(labelWithString: "✓  " + line)
            l.font = Typo.body
            l.textColor = p.textSecondary
            addSubview(l)
            introBullets.append(l)
        }
        addSubview(introButton)

        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: ClipboardStore.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Each time the island opens: back to the list, search cleared, first item ready for ⏎.
    func willShow() {
        filter = .all
        search.field.stringValue = ""
        if case .detail = mode { mode = .list }
        cursor = 0
        resetTitle()
        reload()
        scroll.contentView.scroll(to: .zero)
    }

    @objc private func storeChanged() {
        guard window?.isVisible == true else { return }
        reload()
    }

    // MARK: Data

    private func reload() {
        if !store.enabled { mode = .intro }
        else if mode == .intro { mode = .list }
        if case .detail(let id) = mode, !store.items.contains(where: { $0.id == id }) { mode = .list }

        let n = store.items.count
        let keep = store.keepDays == 0 ? "kept until the limit" : "kept for \(store.keepDays) day\(store.keepDays == 1 ? "" : "s")"
        switch mode {
        case .intro: setSubtitle("History is off")
        case .list: setSubtitle(store.paused ? "Paused · \(n) item\(n == 1 ? "" : "s")" : "\(n) item\(n == 1 ? "" : "s") · \(keep)")
        case .detail: break
        }
        pauseButton.setTitleText(store.paused ? "Resume" : "Pause")
        pauseButton.setSymbol(store.paused ? "play.fill" : "pause.fill")

        let groups: [(ClipboardStore.Filter, String, String)] = [
            (.all, "", "All"), (.text, "text.alignleft", "Text"), (.images, "photo", "Images"), (.files, "doc", "Files"), (.pinned, "pin", "Pinned")]
        // Only All carries a count, so all five segments fit beside the search box.
        filters.items = groups.map { .init(symbol: "", title: $0.2, count: $0.0 == .all ? store.count(.all) : 0, tint: nil) }
        filters.selected = filter.rawValue
        shown = store.items(filter, matching: search.field.stringValue)
        cursor = min(cursor, max(0, shown.count - 1))
        rebuildList()
        if case .detail(let id) = mode, let item = store.items.first(where: { $0.id == id }) { fillDetail(item) }
        applyMode()
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    private func rebuildList() {
        // Views for items that haven't changed are kept and moved; only new or changed items get
        // new views. Opening the tab with nothing new builds nothing.
        if filter == .images {
            rows.forEach { $0.removeFromSuperview() }
            rows.removeAll()
            var pool = Dictionary(thumbs.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
            thumbs = shown.enumerated().map { i, item in
                let t: ClipThumb
                if let old = pool.removeValue(forKey: item.id), old.item == item { t = old } else {
                    t = ClipThumb(item: item)
                    t.onCopy = { [weak self, weak t] in self?.copy(item, row: nil, thumb: t) }
                    t.onPreview = { [weak self] in self?.open(item) }
                }
                t.selected = i == cursor
                if t.superview !== doc { doc.addSubview(t) }
                return t
            }
            pool.values.forEach { $0.removeFromSuperview() }
        } else {
            thumbs.forEach { $0.removeFromSuperview() }
            thumbs.removeAll()
            var pool = Dictionary(rows.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
            rows = shown.enumerated().map { i, item in
                let r: ClipRow
                if let old = pool.removeValue(forKey: item.id), old.item == item {
                    r = old
                    r.index = i
                    r.refreshMeta()
                } else {
                    r = ClipRow(item: item, index: i)
                    r.onCopy = { [weak self, weak r] in self?.copy(item, row: r, thumb: nil) }
                    r.onPin = { [weak self] in self?.store.togglePin(item.id) }
                    r.onPreview = { [weak self] in self?.open(item) }
                }
                r.selected = i == cursor
                if r.superview !== doc { doc.addSubview(r) }
                return r
            }
            pool.values.forEach { $0.removeFromSuperview() }
        }
        // Removed layer-backed tiles can leave pixels in the scroll view's backing store.
        doc.needsDisplay = true
        if shown.isEmpty {
            let q = search.field.stringValue
            empty.stringValue = !q.isEmpty ? "Nothing matches “\(q)”."
                : (store.items.isEmpty ? (store.paused ? "History is paused. Resume to keep new copies."
                                                         : "Copy something in any app and it shows up here.")
                   : "Nothing here yet.")
        }
    }

    /// Group headers ("Pinned", "Today", "Yesterday", "Earlier") in front of the rows.
    private func group(of item: ClipItem) -> String {
        if item.pinned { return "Pinned" }
        let cal = Calendar.current
        if cal.isDateInToday(item.lastCopied) { return "Today" }
        if cal.isDateInYesterday(item.lastCopied) { return "Yesterday" }
        return "Earlier"
    }

    private func applyMode() {
        let list = mode == .list, intro = mode == .intro
        var detail = false
        if case .detail = mode { detail = true }
        [filters, search, scroll, foot, local, lockIcon, pauseButton, moreButton].forEach { $0?.isHidden = !list }
        empty.isHidden = !list || !shown.isEmpty
        [backButton, pinButton, deleteButton, previewBox, facts, copyButton, plainButton, shelfButton].forEach { $0?.isHidden = !detail }
        introText.isHidden = !intro
        introBullets.forEach { $0.isHidden = !intro }
        introButton.isHidden = !intro
        if detail { plainButton.isHidden = !detailAllowsPlain; shelfButton.isHidden = !detailAllowsShelf }
        else { previewImage.image = nil }
    }

    private var detailItem: ClipItem? {
        if case .detail(let id) = mode { return store.items.first { $0.id == id } }
        return nil
    }
    private var detailAllowsPlain: Bool { [.link, .files].contains(detailItem?.kind) }
    private var detailAllowsShelf: Bool { [.image, .files].contains(detailItem?.kind) }

    // MARK: Actions

    private func copy(_ item: ClipItem, row: ClipRow?, thumb: ClipThumb?, plain: Bool = false) {
        guard store.copy(item, plainText: plain) else {
            SoundService.shared.play(.fileReject)
            row?.flash(ok: false); thumb?.flash()
            return
        }
        SoundService.shared.play(.clipCopy)
        row?.flash(ok: true); thumb?.flash()
        onCopied?(item)
    }

    private func open(_ item: ClipItem) {
        mode = .detail(item.id)
        fillDetail(item)
        reload()
        window?.makeFirstResponder(self)
        Motion.page(self, forward: true)
    }

    private func fillDetail(_ item: ClipItem) {
        titleLabel.stringValue = item.kindName
        let from = item.sourceApp.map { "\($0) · " } ?? ""
        setSubtitle(from + relativeTime(item.lastCopied))
        pinButton.toolTip = item.pinned ? "Unpin" : "Pin"
        pinButton.setAccessibilityLabel(item.pinned ? "Unpin" : "Pin")
        let p = Pal
        if item.kind == .image, store.imageURL(item) != nil {
            // The preview is only 150pt tall; never decode a full screenshot for this tile.
            let size = min(cardWidth, 640)
            previewImage.image = store.cachedThumbnail(item, size: size)
            store.loadThumbnail(item, size: size) { [weak self] image in
                guard let self = self, self.detailItem?.id == item.id else { return }
                self.previewImage.image = image
            }
            previewImage.isHidden = false
            preview.isHidden = true
        } else {
            previewImage.image = nil
            previewImage.isHidden = true
            preview.isHidden = false
            let mono = item.kind == .code || item.kind == .files || item.kind == .color
            previewText.font = mono ? NSFont.monospacedSystemFont(ofSize: 12, weight: .medium) : NSFont.systemFont(ofSize: 13)
            previewText.textColor = p.text
            previewText.string = item.text
        }
        var lines: [String] = []
        let when = DateFormatter.localizedString(from: item.firstCopied, dateStyle: .medium, timeStyle: .short)
        lines.append("First copied \(when)" + (item.copyCount > 1 ? " · copied \(item.copyCount) times" : ""))
        switch item.kind {
        case .image:
            let size = item.imageSize.map { "\(Int($0.width)) × \(Int($0.height)) px · " } ?? ""
            lines.append(size + ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
        case .files:
            let missing = item.paths.filter { !FileManager.default.fileExists(atPath: $0) }.count
            lines.append("\(item.paths.count) file\(item.paths.count == 1 ? "" : "s") · "
                         + ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)
                         + (missing > 0 ? " · \(missing) moved or deleted" : ""))
        default:
            let words = item.text.split { $0.isWhitespace || $0.isNewline }.count
            let lineCount = item.text.split(separator: "\n", omittingEmptySubsequences: false).count
            lines.append("\(lineCount) line\(lineCount == 1 ? "" : "s") · \(words) word\(words == 1 ? "" : "s") · \(item.text.count) characters")
        }
        facts.stringValue = lines.joined(separator: "\n")
    }

    @objc private func copyTapped() { if let i = detailItem { copy(i, row: nil, thumb: nil) } }
    @objc private func plainTapped() { if let i = detailItem { copy(i, row: nil, thumb: nil, plain: true) } }
    @objc private func pinTapped() { if let i = detailItem { store.togglePin(i.id) } }
    @objc private func deleteTapped() {
        guard let i = detailItem else { return }
        mode = .list
        store.delete(i.id)
        resetTitle()
    }
    @objc private func shelfTapped() {
        guard let i = detailItem else { return }
        let urls: [URL] = i.kind == .image ? [store.imageURL(i)].compactMap { $0 } : i.paths.map { URL(fileURLWithPath: $0) }
        _ = ShelfStore.shared.add(urls: urls)
        SoundService.shared.play(.fileCatch)
        say?("on the shelf ✨", .happy)
    }
    var say: ((String, ZeraMood) -> Void)?

    @objc private func backTapped() {
        mode = .list
        resetTitle()
        reload()
        Motion.page(self, forward: false)
    }
    private func resetTitle() { titleLabel.stringValue = "Clipboard" }

    @objc private func pauseTapped() { store.paused.toggle() }
    @objc private func turnOnTapped() {
        store.enabled = true
        SoundService.shared.play(.reminderDone)
        say?("I'll remember what you copy ✨", .happy)
    }

    @objc private func moreTapped() {
        var items: [DropdownItem] = [
            DropdownItem(title: "Clipboard settings", symbol: "gearshape") { [weak self] in self?.onOpenSettings?() },
            DropdownItem(title: "", isSeparator: true),
            DropdownItem(title: "Clear history", subtitle: "Pinned items stay", symbol: "trash", destructive: true) { [weak self] in
                self?.store.clear()
                SoundService.shared.play(.clipClear)
            },
        ]
        if store.items.isEmpty { items.removeLast(2) }
        ZeraDropdown.shared.show(items, below: moreButton, width: 220)
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        if case .detail(let id) = mode {
            switch event.keyCode {
            case 53, 51: backTapped()                                   // esc / ⌫ back
            case 36, 76: if let i = store.items.first(where: { $0.id == id }) { copy(i, row: nil, thumb: nil) }
            default: super.keyDown(with: event)
            }
            return
        }
        guard mode == .list else { super.keyDown(with: event); return }
        if cmd, let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            if n - 1 < shown.count { copy(shown[n - 1], row: rows[safe: n - 1], thumb: thumbs[safe: n - 1]) }
            return
        }
        if cmd, event.charactersIgnoringModifiers == "f" { window?.makeFirstResponder(search.field); return }
        switch event.keyCode {
        case 125: move(filter == .images ? CL.thumbCols : 1)              // ↓
        case 126: move(filter == .images ? -CL.thumbCols : -1)            // ↑
        case 124 where filter == .images: move(1)
        case 123 where filter == .images: move(-1)
        case 36, 76: if let i = shown[safe: cursor] { copy(i, row: rows[safe: cursor], thumb: thumbs[safe: cursor]) }
        case 49: if let i = shown[safe: cursor] { open(i) }               // Space
        case 51, 117: if let i = shown[safe: cursor] { store.delete(i.id) } // ⌫
        default:
            // Typing starts a search.
            if let c = event.characters, !c.isEmpty, !cmd, c.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                window?.makeFirstResponder(search.field)
                search.field.currentEditor()?.insertText(c)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        cursor = max(0, min(shown.count - 1, cursor + d))
        for (i, r) in rows.enumerated() { r.selected = i == cursor }
        for (i, t) in thumbs.enumerated() { t.selected = i == cursor }
        if let v: NSView = rows[safe: cursor] ?? thumbs[safe: cursor] { v.scrollToVisible(v.bounds.insetBy(dx: 0, dy: -8)) }
    }

    func controlTextDidChange(_ obj: Notification) { cursor = 0; reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let i = shown[safe: cursor] { copy(i, row: rows[safe: cursor], thumb: thumbs[safe: cursor]) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if search.field.stringValue.isEmpty { onEscape?() } else { search.field.stringValue = ""; reload() }
            return true
        default: return false
        }
    }

    // MARK: Layout

    private var listTop: CGFloat { headerBottom + CL.toolsH + 10 }

    private var listContentHeight: CGFloat {
        if shown.isEmpty { return 90 }
        if filter == .images {
            let w = cardWidth - CL.pad * 2
            let tw = (w - CGFloat(CL.thumbCols - 1) * 8) / CGFloat(CL.thumbCols)
            let rowsN = (shown.count + CL.thumbCols - 1) / CL.thumbCols
            return CGFloat(rowsN) * (tw * 0.75 + 8)
        }
        var h: CGFloat = 0, last: String?
        for item in shown {
            let g = group(of: item)
            if g != last { h += CL.groupH; last = g }
            h += CL.rowH + CL.rowGap
        }
        return h
    }

    var desiredHeight: CGFloat {
        switch mode {
        case .intro: return headerBottom + 190
        case .detail: return headerBottom + 280
        case .list: return listTop + min(CL.listMax, listContentHeight) + 6 + CL.footH + 10
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, x = CL.pad, iw = w - CL.pad * 2
        let trailing = headerTrailingRect
        let mid = trailing.midY
        switch mode {
        case .detail:
            backButton.frame = NSRect(x: x, y: mid - 17, width: 34, height: 34)
            layoutHeader()
            let shift: CGFloat = 44
            titleLabel.frame.origin.x += shift - 4
            titleLabel.frame.size.width -= shift
            subtitleLabel.frame.origin.x += shift - 4
            subtitleLabel.frame.size.width -= shift
            deleteButton.frame = NSRect(x: w - x - 34, y: mid - 17, width: 34, height: 34)
            pinButton.frame = NSRect(x: deleteButton.frame.minX - 8 - 34, y: mid - 17, width: 34, height: 34)
            var y = headerBottom
            previewBox.frame = NSRect(x: x, y: y, width: iw, height: 150)
            preview.frame = previewBox.bounds.insetBy(dx: 4, dy: 4)
            previewText.frame = NSRect(x: 0, y: 0, width: preview.contentSize.width, height: max(preview.contentSize.height, previewText.frame.height))
            previewImage.frame = previewBox.bounds.insetBy(dx: 8, dy: 8)
            y = previewBox.frame.maxY + 12
            facts.frame = NSRect(x: x + 2, y: y, width: iw - 4, height: 34)
            y += 46
            var bx = x
            for b in [copyButton!, plainButton!, shelfButton!] where !b.isHidden {
                let bw = max(80, b.fittedWidth)
                b.frame = NSRect(x: bx, y: y, width: bw, height: 32)
                bx += bw + 8
            }
        case .intro:
            layoutHeader()
            var y = headerBottom + 4
            introText.frame = NSRect(x: x, y: y, width: iw, height: 20); y += 32
            let bw: CGFloat = 400
            for l in introBullets { l.frame = NSRect(x: (w - bw) / 2, y: y, width: bw, height: 18); y += 24 }
            y += 12
            let tw = max(200, introButton.fittedWidth)
            introButton.frame = NSRect(x: (w - tw) / 2, y: y, width: tw, height: 34)
        case .list:
            let mw: CGFloat = 34, pw = max(86, pauseButton.fittedWidth)
            moreButton.frame = NSRect(x: w - x - mw, y: mid - 17, width: mw, height: 34)
            pauseButton.frame = NSRect(x: moreButton.frame.minX - 8 - pw, y: mid - 16, width: pw, height: 32)
            layoutHeader(trailingWidth: pw + mw + 8)
            let ty = headerBottom
            let fw = min(iw - 170, filters.preferredWidth)
            filters.frame = NSRect(x: x, y: ty, width: fw, height: CL.toolsH)
            search.frame = NSRect(x: x + fw + 10, y: ty, width: max(0, iw - fw - 10), height: CL.toolsH)
            let lh = min(CL.listMax, listContentHeight)
            scroll.frame = NSRect(x: x - 4, y: listTop, width: iw + 8, height: lh)
            // More below: the last row fades out instead of being cut.
            scroll.wantsLayer = true
            if listContentHeight > lh + 1 {
                let fade = (scroll.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
                fade.frame = scroll.bounds
                fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
                fade.locations = [0, NSNumber(value: Double((lh - 28) / max(1, lh))), 1]
                scroll.layer?.mask = fade
            } else {
                scroll.layer?.mask = nil
            }
            empty.frame = NSRect(x: x, y: listTop + 30, width: iw, height: 40)
            layoutList(width: iw)
            let fy = listTop + lh + 6
            foot.frame = NSRect(x: x + 2, y: fy + 5, width: iw - 140, height: 16)
            local.frame = NSRect(x: w - x - 120, y: fy + 5, width: 120, height: 16)
            let lw = ceil(local.attributedStringValue.size().width)
            lockIcon.frame = NSRect(x: w - x - lw - 16, y: fy + 6, width: 12, height: 12)
        }
    }

    private func layoutList(width iw: CGFloat) {
        // Headers are kept between layouts and only rebuilt when their text changes.
        var unusedHeaders = headers
        headers = [:]
        defer { unusedHeaders.values.forEach { $0.removeFromSuperview() } }
        var y: CGFloat = 0
        if filter == .images {
            let tw = (iw - CGFloat(CL.thumbCols - 1) * 8) / CGFloat(CL.thumbCols)
            for (i, t) in thumbs.enumerated() {
                t.frame = NSRect(x: 4 + CGFloat(i % CL.thumbCols) * (tw + 8), y: CGFloat(i / CL.thumbCols) * (tw * 0.75 + 8),
                                 width: tw, height: tw * 0.75)
            }
            y = CGFloat((thumbs.count + CL.thumbCols - 1) / CL.thumbCols) * (tw * 0.75 + 8)
        } else {
            var last: String?
            var first = true
            for (i, r) in rows.enumerated() {
                let g = group(of: shown[i])
                if g != last {
                    let note = first && store.skipped > 0
                        ? "\(store.skipped) private cop\(store.skipped == 1 ? "y" : "ies") skipped" : nil
                    let key = g + "|" + (note ?? "")
                    let h = unusedHeaders.removeValue(forKey: key) ?? ClipGroupHeader(title: g, note: note)
                    headers[key] = h
                    h.frame = NSRect(x: 6, y: y, width: iw - 4, height: CL.groupH)
                    if h.superview !== doc { doc.addSubview(h) }
                    y += CL.groupH
                    last = g
                    first = false
                }
                r.frame = NSRect(x: 4, y: y, width: iw, height: CL.rowH)
                y += CL.rowH + CL.rowGap
            }
        }
        doc.frame = NSRect(x: 0, y: 0, width: iw + 8, height: max(y, scroll.frame.height))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Pieces

/// "TODAY" in small caps, with an optional note on the right ("1 private copy skipped").
private final class ClipGroupHeader: NSView {
    override var isFlipped: Bool { true }
    init(title: String, note: String?) {
        super.init(frame: .zero)
        let p = Pal
        let t = NSTextField(labelWithString: "")
        t.attributedStringValue = Typo.sectionText(title, color: p.textTertiary)
        t.frame = NSRect(x: 0, y: 7, width: 200, height: 14)
        addSubview(t)
        if let note = note {
            let n = NSTextField(labelWithString: note)
            n.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
            n.textColor = p.textTertiary
            n.alignment = .right
            n.autoresizingMask = [.minXMargin]
            n.frame = NSRect(x: 0, y: 7, width: 0, height: 14)
            n.identifier = NSUserInterfaceItemIdentifier("note")
            addSubview(n)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        subviews.first { $0.identifier?.rawValue == "note" }?.frame = NSRect(x: bounds.width - 240, y: 7, width: 236, height: 14)
    }
}

/// One copy: tile (thumbnail, swatch or glyph), what it is, where it came from, ⌘n on the right.
/// Click copies; hover shows pin and preview.
final class ClipRow: NSView {
    var onCopy: (() -> Void)?
    var onPin: (() -> Void)?
    var onPreview: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    let item: ClipItem
    /// Position in the list: ⌘1–⌘9 for the first nine.
    var index: Int { didSet { if index != oldValue { key.stringValue = index < 9 ? "⌘\(index + 1)" : "" } } }
    private let tile = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let key = NSTextField(labelWithString: "")
    private let pinMark = NSImageView()
    private var pinButton: GHSquareButton!
    private var previewButton: GHSquareButton!
    private let copiedTag = NSTextField(labelWithString: "✓ Copied")
    private var flashState: Bool?    // true copied, false couldn't
    private var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            pinButton.isHidden = !hovered
            previewButton.isHidden = !hovered
            key.isHidden = hovered
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(item: ClipItem, index: Int) {
        self.item = item
        self.index = index
        super.init(frame: .zero)
        let p = Pal
        wantsLayer = true
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 10
        tile.layer?.cornerCurve = .continuous
        tile.layer?.masksToBounds = true
        tile.imageScaling = .scaleAxesIndependently
        addSubview(tile)
        configureTile()
        title.stringValue = item.title
        title.font = item.kind == .code || item.kind == .color
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .medium) : NSFont.systemFont(ofSize: 13, weight: .medium)
        title.textColor = p.text
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        lineCount = item.kind == .code ? item.text.split(separator: "\n").count : 0
        meta.stringValue = ClipRow.meta(item, lines: lineCount)
        meta.font = Typo.caption
        meta.textColor = p.textSecondary
        meta.lineBreakMode = .byTruncatingTail
        addSubview(meta)
        key.stringValue = index < 9 ? "⌘\(index + 1)" : ""
        key.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        key.textColor = p.textTertiary
        key.alignment = .right
        addSubview(key)
        pinMark.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        pinMark.contentTintColor = p.warning
        pinMark.isHidden = !item.pinned
        addSubview(pinMark)
        pinButton = GHSquareButton(symbol: item.pinned ? "pin.slash" : "pin", label: item.pinned ? "Unpin" : "Pin",
                                   target: self, action: #selector(pinTapped))
        previewButton = GHSquareButton(symbol: "ellipsis", label: "Preview", target: self, action: #selector(previewTapped))
        [pinButton, previewButton].forEach { $0!.isHidden = true; addSubview($0!) }
        copiedTag.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        copiedTag.textColor = p.success
        copiedTag.alignment = .center
        copiedTag.wantsLayer = true
        copiedTag.drawsBackground = false
        copiedTag.isHidden = true
        addSubview(copiedTag)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy \(item.kindName.lowercased()): \(item.title)")
        toolTip = item.kind == .files ? item.paths.joined(separator: "\n") : (item.text.count > 400 ? String(item.text.prefix(400)) + "…" : item.text)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Counted once: code can be long, and the row's age line is redone every time the list shows.
    private var lineCount = 0
    /// "5 min ago" moves on; a reused row brings it up to date.
    func refreshMeta() {
        let m = ClipRow.meta(item, lines: lineCount)
        if meta.stringValue != m { meta.stringValue = m }
    }

    static func meta(_ item: ClipItem, lines: Int? = nil) -> String {
        var parts: [String] = []
        if let app = item.sourceApp { parts.append(app) }
        parts.append(relativeTime(item.lastCopied))
        switch item.kind {
        case .image, .files: if item.bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)) }
        case .code:
            let n = lines ?? item.text.split(separator: "\n").count
            if n > 1 { parts.append("\(n) lines") }
        default: break
        }
        if item.copyCount > 1 { parts.append("×\(item.copyCount)") }
        return parts.joined(separator: " · ")
    }

    private func configureTile() {
        let p = Pal
        tile.layer?.borderWidth = 1
        tile.layer?.borderColor = p.border.cgColor
        switch item.kind {
        case .image:
            // Decoded off the main thread unless it's already cached; the tile is black till then.
            let store = ClipboardStore.shared
            tile.image = store.cachedThumbnail(item, size: 40)
            if tile.image == nil { store.loadThumbnail(item, size: 40) { [weak self] img in self?.tile.image = img } }
            tile.imageScaling = .scaleProportionallyUpOrDown
            tile.layer?.backgroundColor = NSColor.black.cgColor
        case .color:
            tile.image = nil
            tile.layer?.backgroundColor = ClipRow.color(item.text)?.cgColor ?? p.surfaceHover.cgColor
        default:
            let (symbol, tint): (String, NSColor) = {
                switch item.kind {
                case .code: return ("chevron.left.forwardslash.chevron.right", Neon.violet)
                case .link: return ("link", p.info)
                case .files: return (item.paths.count > 1 ? "doc.on.doc" : "doc", p.warning)
                default: return ("text.alignleft", Neon.glyph)
                }
            }()
            tile.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold).applying(.init(paletteColors: [tint])))
            tile.imageScaling = .scaleNone
            tile.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
            tile.layer?.borderColor = tint.withAlphaComponent(0.3).cgColor
        }
    }

    /// "#4DBDFF", "4dbdff", "#abc", "rgb(…)" → a colour for the swatch.
    static func color(_ s: String) -> NSColor? {
        var h = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.lowercased().hasPrefix("rgb") {
            let nums = h.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init)
            guard nums.count >= 3 else { return nil }
            return NSColor(srgbRed: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: nums.count > 3 ? min(1, nums[3]) : 1)
        }
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let r, g, b, a: Double
        if h.count == 8 { r = Double((v >> 24) & 255); g = Double((v >> 16) & 255); b = Double((v >> 8) & 255); a = Double(v & 255) / 255 }
        else { r = Double((v >> 16) & 255); g = Double((v >> 8) & 255); b = Double(v & 255); a = 1 }
        return NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    /// A green "✓ Copied" for a moment (or a red edge if the item couldn't be copied).
    func flash(ok: Bool) {
        flashState = ok
        copiedTag.stringValue = ok ? "✓ Copied" : "Gone"
        copiedTag.textColor = ok ? Pal.success : Pal.danger
        copiedTag.isHidden = false
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.flashState = nil
            self?.copiedTag.isHidden = true
            self?.needsDisplay = true
        }
    }

    @objc private func pinTapped() { onPin?() }
    @objc private func previewTapped() { onPreview?() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, mid = (h / 2).rounded()
        tile.frame = NSRect(x: 8, y: mid - 18, width: 36, height: 36)
        previewButton.frame = NSRect(x: w - 8 - 28, y: mid - 14, width: 28, height: 28)
        pinButton.frame = NSRect(x: previewButton.frame.minX - 6 - 28, y: mid - 14, width: 28, height: 28)
        key.frame = NSRect(x: w - 10 - 30, y: mid - 7, width: 30, height: 14)
        pinMark.frame = NSRect(x: key.frame.minX - 16, y: mid - 7, width: 14, height: 14)
        let right = pinButton.frame.minX - 8
        title.frame = NSRect(x: 54, y: mid - 17, width: max(0, right - 54), height: 18)
        meta.frame = NSRect(x: 54, y: mid + 2, width: max(0, right - 54), height: 15)
        copiedTag.frame = NSRect(x: w - 108, y: mid - 9, width: 96, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: Radius.l, yRadius: Radius.l)
        if let ok = flashState {
            (ok ? p.success : p.danger).withAlphaComponent(0.08).setFill(); path.fill()
            (ok ? p.success : p.danger).withAlphaComponent(0.6).setStroke(); path.lineWidth = 1.25; path.stroke()
            return
        }
        (hovered ? p.surfaceHover : p.surfaceRow).setFill(); path.fill()
        if selected { p.selectedFill.setFill(); path.fill() }
        (selected ? p.selectedEdge : p.divider).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onCopy?() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { onCopy?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// An image in the Images grid: click copies it, double-click previews.
final class ClipThumb: NSView {
    var onCopy: (() -> Void)?
    var onPreview: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { updateEdge() } } }
    let item: ClipItem
    private let image = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovered = false { didSet { updateEdge() } }
    private var flashing = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(item: ClipItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderWidth = 1
        image.image = ClipboardStore.shared.cachedThumbnail(item, size: 140)
        if image.image == nil { ClipboardStore.shared.loadThumbnail(item, size: 140) { [weak self] img in self?.image.image = img } }
        image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        if let s = item.imageSize { label.stringValue = "\(Int(s.width))×\(Int(s.height))" }
        label.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.wantsLayer = true
        label.drawsBackground = true
        label.backgroundColor = NSColor(white: 0, alpha: 0.6)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy \(item.title)")
        updateEdge()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateEdge() {
        let p = Pal
        layer?.borderColor = (flashing ? p.success : (selected ? p.selectedEdge : p.divider)).cgColor
        layer?.borderWidth = flashing ? 1.5 : 1
    }

    func flash() {
        flashing = true; updateEdge()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.flashing = false; self?.updateEdge() }
    }

    override func layout() {
        super.layout()
        image.frame = bounds
        let lw = ceil(label.attributedStringValue.size().width) + 8
        label.frame = NSRect(x: 6, y: bounds.height - 22, width: lw, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount >= 2 { onPreview?() } else { onCopy?() }
    }
    override func accessibilityPerformPress() -> Bool { onCopy?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
