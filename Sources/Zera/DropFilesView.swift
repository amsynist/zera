import AppKit
import PDFKit

// MARK: - Drop Files · Shelf · Drop Bin
//
//  ┌── Drop Files (380) ──┐ ┌────────── Selected file ──────────┐ ┌─ Dropped Files (270) ─┐
//  │ [doc] Drop Files     │ │ [PDF] Project-spec.pdf  [Finder][🗑][•••] │ [tray] 3 files [Clear] │
//  │   (Zera) ╭bubble╮    │ │ [Summary|Key Points|Full Text|Q&A|Chat] │ ┌ row ──────────┐ │
//  │ ┌╌╌ drop zone ╌╌╌╌┐  │ │ (Zera) ╭ Here's what I found ✨ ╮        │ │ debug-log.txt │ │
//  │ └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘  │ │ ┌ content ──────────────── Copy ┐      │ └───────────────┘ │
//  │ [Summarize][Explain] │ │ │ markdown…                     │      │ …                 │
//  │ [Extract]  [Ask]     │ │ └───────────────────────────────┘      │ ┌╌╌ Drop Bin ╌╌╌┐ │
//  │ Recent files [Clear] │ │ [Ask a question about this file… ➤ ⌄]  │ │  drop to remove │ │
//  │ rows…                │ │ [suggestion][suggestion][suggestion]   │ └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘ │
//  └──────────────────────┘ └────────────────────────────────────────┘ └───────────────────┘
//
// One source of truth: ShelfStore (Shelf, Recent, per-file results) + ZeraAssistant (the live
// request). Dropping a file only adds a reference; nothing goes to Claude until you pick an
// action, and removing a file (row, menu, Clear all, Drop Bin) never touches the file on disk.

private enum D {
    static let gap: CGFloat = 14
    static let pad: CGFloat = Metrics.sidePad
    static let leftW: CGFloat = 380
    static let rightW: CGFloat = 270
    static let maxWidth: CGFloat = 1260
    static let threePaneMin: CGFloat = 1180
    static let maxHeight: CGFloat = 820
    static let minHeight: CGFloat = 600
}

/// Pasteboard type that marks a drag as one of Zera's own file rows (for the Drop Bin).
private let shelfDragType = NSPasteboard.PasteboardType("ai.zera.shelf-item")

@MainActor
private func dlabel(_ font: NSFont, _ color: NSColor, lines: Int = 1) -> NSTextField {
    let l = lines == 1 ? NSTextField(labelWithString: "") : NSTextField(wrappingLabelWithString: "")
    l.font = font
    l.textColor = color
    l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    if lines > 1 { l.maximumNumberOfLines = lines }
    return l
}

private func dsymbol(_ name: String, _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight = .semibold) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))?
        .withSymbolConfiguration(.init(paletteColors: [color]))
}

private func ddraw(_ img: NSImage?, centeredIn r: NSRect) {
    guard let img = img else { return }
    let s = img.size
    img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

private func fileSize(_ path: String) -> String? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    return byteString((attrs[.size] as? NSNumber)?.int64Value ?? 0)
}

// MARK: - File kinds

/// What a file is, for its colour, icon, label and the action Zera suggests first.
enum ShelfKind {
    case pdf, image, code, docs, text, link, other

    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": self = .pdf
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp": self = .image
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm",
             "cs", "php", "sh", "zsh", "json", "yml", "yaml", "toml", "html", "css", "scss", "sql", "xml", "gradle", "lua", "dart":
            self = .code
        case "md", "markdown", "doc", "docx", "rtf", "rtfd", "pages", "odt", "html5", "webarchive": self = .docs
        case "txt", "log", "csv", "tsv", "text": self = .text
        case "webloc", "url": self = .link
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "Image"
        case .code: return "Code"
        case .docs: return "Docs"
        case .text: return "Text"
        case .link: return "Link"
        case .other: return "File"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext.fill"
        case .image: return "photo.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .docs: return "doc.text.fill"
        case .text: return "doc.plaintext.fill"
        case .link: return "link"
        case .other: return "doc.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .pdf: return NSColor(srgbRed: 0.95, green: 0.38, blue: 0.40, alpha: 1)
        case .image: return NSColor(srgbRed: 0.35, green: 0.68, blue: 1.00, alpha: 1)
        case .code: return NSColor(srgbRed: 0.58, green: 0.48, blue: 1.00, alpha: 1)
        case .docs: return NSColor(srgbRed: 1.00, green: 0.72, blue: 0.30, alpha: 1)
        case .text, .other: return NSColor(srgbRed: 0.62, green: 0.60, blue: 0.76, alpha: 1)
        case .link: return NSColor(srgbRed: 0.35, green: 0.70, blue: 1.00, alpha: 1)
        }
    }

    /// Text Zera can show locally (no Claude) on the Full Text tab.
    var hasLocalText: Bool { self == .pdf || self == .code || self == .text || self == .docs }

    /// The first thing worth doing with it (Recent rows show this as their button).
    var suggested: (title: String, symbol: String, action: FileAction?) {
        switch self {
        case .pdf, .docs: return ("Summarize", "sparkles", .summarize)
        case .image: return ("Extract text", "text.viewfinder", .extract)
        case .code: return ("Explain", "text.magnifyingglass", .explain)
        case .text, .other, .link: return ("Ask Zera", "bubble.left.fill", nil)
        }
    }

    var suggestions: [String] {
        switch self {
        case .code: return ["What does this code do?", "Find likely bugs", "Suggest improvements"]
        case .image: return ["Describe this image", "Read the text in it", "What stands out?"]
        default: return ["What are the main points?", "Explain it simply", "List the action items"]
        }
    }
}

// MARK: - File tile

/// Rounded square in the file's colour with its glyph — or a small thumbnail for images.
final class FileTypeTile: NSView {
    private var kind: ShelfKind = .other
    private var thumb: NSImage?
    private var path = ""
    override var isFlipped: Bool { true }

    func set(path p: String) {
        guard p != path else { return }
        path = p
        kind = ShelfKind(path: p)
        thumb = nil
        needsDisplay = true
        if kind == .image, FileManager.default.fileExists(atPath: p) {
            // Finder icon first, then a QuickLook preview when one is ready.
            Thumbnails.shared.thumbnail(for: URL(fileURLWithPath: p)) { [weak self] img in
                guard let self = self, self.path == p else { return }
                self.thumb = img
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: bounds.width * 0.27, yRadius: bounds.width * 0.27)
        if let t = thumb, kind == .image {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            t.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.18).setStroke(); path.lineWidth = 1; path.stroke()
            return
        }
        kind.color.withAlphaComponent(Pal.isDark ? 0.22 : 0.18).setFill(); path.fill()
        kind.color.withAlphaComponent(0.35).setStroke(); path.lineWidth = 1; path.stroke()
        ddraw(dsymbol(kind.symbol, bounds.width * 0.38, kind.color), centeredIn: bounds)
    }
}

/// Lightweight drag picture: tile + name in a rounded pill.
@MainActor
private func shelfDragImage(path: String) -> NSImage {
    let name = (path as NSString).lastPathComponent
    let font = Typo.bodyStrong
    let textW = min(220, ceil((name as NSString).size(withAttributes: [.font: font]).width))
    let size = NSSize(width: 10 + 26 + 8 + textW + 14, height: 38)
    return NSImage(size: size, flipped: true) { rect in
        let p = Pal
        let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        p.surfaceElevated.withAlphaComponent(0.96).setFill(); bg.fill()
        p.accentBorder.setStroke(); bg.lineWidth = 1; bg.stroke()
        let kind = ShelfKind(path: path)
        let tile = NSRect(x: 10, y: 6, width: 26, height: 26)
        kind.color.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7).fill()
        ddraw(dsymbol(kind.symbol, 11, kind.color), centeredIn: tile)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingMiddle
        (name as NSString).draw(in: NSRect(x: 44, y: 11, width: textW, height: 17), withAttributes: [.font: font, .foregroundColor: p.text, .paragraphStyle: para])
        return true
    }
}

// MARK: - Drop zone

/// The dashed "Drop files here" target: cloud, title, a line of help, and the file types.
final class FileDropZone: NSView {
    var isTargeted = false { didSet { if isTargeted != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    private let kinds: [ShelfKind] = [.pdf, .image, .code, .docs, .other]

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: Radius.l + 2, yRadius: Radius.l + 2)
        p.accent.withAlphaComponent(isTargeted ? 0.16 : (p.isDark ? 0.06 : 0.05)).setFill()
        path.fill()
        path.lineWidth = isTargeted ? 2 : 1.5
        if !isTargeted { path.setLineDash([7, 5], count: 2, phase: 0) }
        (isTargeted ? p.accent : p.accent.withAlphaComponent(0.55)).setStroke()
        path.stroke()

        let symbol = isTargeted ? "arrow.down.circle.fill" : "icloud.and.arrow.up"
        // Slim (the notch island): one line — icon, title, a short line of help.
        if bounds.height < 100 {
            ddraw(dsymbol(symbol, 18, p.accent, .medium), centeredIn: NSRect(x: 14, y: 0, width: 26, height: bounds.height))
            let ta: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13.5, weight: .semibold), .foregroundColor: p.text]
            let title = isTargeted ? "Drop it here! ✨" : "Drop files here"
            let ts = (title as NSString).size(withAttributes: ta)
            (title as NSString).draw(at: NSPoint(x: 50, y: bounds.midY - ts.height / 2), withAttributes: ta)
            let sub = isTargeted ? "Let go and it goes on your Shelf." : "They wait on the Shelf. I only read one when you ask."
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            let sx = 50 + ts.width + 10
            (sub as NSString).draw(in: NSRect(x: sx, y: bounds.midY - 8, width: max(0, bounds.width - sx - 14), height: 16),
                                   withAttributes: [.font: Typo.meta, .foregroundColor: p.textSecondary, .paragraphStyle: para])
            return
        }
        ddraw(dsymbol(symbol, isTargeted ? 28 : 24, p.accent, .medium), centeredIn: NSRect(x: 0, y: 24, width: bounds.width, height: 30))
        let title = isTargeted ? "Drop it here! ✨" : "Drop files here"
        let ta: [NSAttributedString.Key: Any] = [.font: Typo.detailTitle, .foregroundColor: p.text]
        let ts = (title as NSString).size(withAttributes: ta)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: 60), withAttributes: ta)
        let sub = isTargeted ? "Let go and I'll put it on your Shelf." : "I'll summarize, explain or extract the text for you."
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
        (sub as NSString).draw(in: NSRect(x: 12, y: 84, width: bounds.width - 24, height: 16),
                               withAttributes: [.font: Typo.meta, .foregroundColor: p.textSecondary, .paragraphStyle: para])

        // File types: tile + label each, centred as a group.
        let col: CGFloat = min(60, (bounds.width - 24) / CGFloat(kinds.count)), tile: CGFloat = 34
        var x = bounds.midX - col * CGFloat(kinds.count) / 2
        let la: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: p.textSecondary]
        for k in kinds {
            let tr = NSRect(x: x + (col - tile) / 2, y: 112, width: tile, height: tile)
            let tp = NSBezierPath(roundedRect: tr, xRadius: 10, yRadius: 10)
            k.color.withAlphaComponent(p.isDark ? 0.22 : 0.16).setFill(); tp.fill()
            ddraw(dsymbol(k == .other ? "doc" : k.symbol, 13, k.color), centeredIn: tr)
            let name = k == .other ? "Any file" : k.label
            let ls = (name as NSString).size(withAttributes: la)
            (name as NSString).draw(at: NSPoint(x: x + (col - ls.width) / 2, y: tr.maxY + 5), withAttributes: la)
            x += col
        }
    }
}

// MARK: - Action tile

/// A big action: coloured icon tile + label. Dimmed with nothing selected.
final class FileActionTile: NSView {
    var onTap: (() -> Void)?
    var enabled = true { didSet { if enabled != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    private let title: String
    private let symbol: String
    private let color: NSColor
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String, symbol: String, color: NSColor) {
        self.title = title; self.symbol = symbol; self.color = color
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        // Compact pill (the notch island): a tinted icon chip and the action's name.
        let r = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
        (pressed ? p.surfacePressed : (hovered && enabled ? p.surfaceHover : p.surfaceRow)).setFill(); path.fill()
        (hovered && enabled ? p.accentBorder : p.border).setStroke(); path.lineWidth = 1; path.stroke()
        let alpha: CGFloat = enabled ? 1 : 0.45
        let s = min(26, bounds.height - 12)
        let tile = NSRect(x: 7, y: (bounds.height - s) / 2, width: s, height: s)
        let chip = NSBezierPath(ovalIn: tile)
        color.withAlphaComponent(0.18 * alpha).setFill(); chip.fill()
        color.withAlphaComponent(0.5 * alpha).setStroke(); chip.lineWidth = 1; chip.stroke()
        ddraw(dsymbol(symbol, 11.5, (color.blended(withFraction: 0.25, of: .white) ?? color).withAlphaComponent(alpha)), centeredIn: tile)
        let font = Typo.bodyStrong
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let th = ceil(font.ascender - font.descender) + 1
        let tx = tile.maxX + 8
        (title as NSString).draw(in: NSRect(x: tx, y: (bounds.height - th) / 2, width: bounds.width - tx - 10, height: th),
                                 withAttributes: [.font: font, .foregroundColor: p.text.withAlphaComponent(alpha), .paragraphStyle: para])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { if enabled { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        let was = pressed
        pressed = false
        if was, enabled, NSPointInRect(convert(event.locationInWindow, from: nil), bounds) { onTap?() }
    }
    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

// MARK: - File rows

/// A file in Recent (with its suggested action) or on the Shelf (with its state). Click to
/// select, double-click to open, drag to copy it out — or into the Drop Bin to remove it.
final class ShelfFileRow: NSView, NSDraggingSource {
    enum Style { case recent, dropped }
    let path: String
    let style: Style
    /// A tap: copy the item. The row's whole job is "see → tap → copied".
    var onCopy: (() -> Void)?
    /// › : open the file's page (summary, key points, Q&A).
    var onSelect: (() -> Void)?
    var onAction: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    /// The item you last tapped: a quiet accent edge (the Summarize / Explain tiles act on it).
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }

    private let tile = FileTypeTile()
    private let name = dlabel(Typo.rowTitle, Pal.text)
    private let meta = dlabel(Typo.meta, Pal.textSecondary)
    private var action: PRActionButton?
    private let copyButton = ShelfRowButton(symbol: "doc.on.doc", label: "Copy")
    private let openButton = ShelfRowButton(symbol: "chevron.right", label: "Details")
    private let more = ShelfRowButton(symbol: "ellipsis", label: "More")
    private let sweep = CAGradientLayer()
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true; updateButtons() } } }
    private var pressedDown = false { didSet { if pressedDown != oldValue { needsDisplay = true } } }
    private var copiedUntil: Date?
    private var downPoint: NSPoint = .zero
    private var dragged = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    static func height(_ s: Style) -> CGFloat { RowTier.standard.height }

    init(path: String, style: Style) {
        self.path = path
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 0.75, y: 0.5)
        sweep.cornerRadius = Radius.l
        sweep.opacity = 0
        layer?.insertSublayer(sweep, at: 0)
        tile.set(path: path)
        name.lineBreakMode = .byTruncatingMiddle
        name.stringValue = (path as NSString).lastPathComponent
        name.toolTip = path
        meta.lineBreakMode = .byTruncatingTail
        copyButton.onTap = { [weak self] in self?.onCopy?() }
        openButton.onTap = { [weak self] in self?.onSelect?() }
        more.onTap = { [weak self] in guard let self = self else { return }; self.onMenu?(self.more) }
        copyButton.toolTip = "Copy (↩)"
        openButton.toolTip = "Details (⌘↩)"
        [tile, name, meta, copyButton, openButton, more].forEach { addSubview($0) }
        if style == .recent {
            let sug = ShelfKind(path: path).suggested
            let b = PRActionButton(sug.title, style: .secondary, symbol: sug.symbol, target: self, action: #selector(actionTapped))
            action = b
            addSubview(b)
        }
        setAccessibilityRole(.button)
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func actionTapped() { onAction?() }
    override func accessibilityPerformPress() -> Bool { onCopy?(); return true }

    /// `status`: nil = show the time; otherwise a state line and its colour.
    func update(addedAt: Date, status: (String, NSColor)?) {
        let p = Pal
        let kind = ShelfKind(path: path)
        let exists = FileManager.default.fileExists(atPath: path)
        let base = [kind.label, exists ? fileSize(path) : nil].compactMap { $0 }.joined(separator: " · ")
        let text: String, color: NSColor
        if !exists { text = "No longer available"; color = p.warning }
        else if let s = status { text = "\(base) · \(s.0)"; color = s.1 }
        else { text = "\(base) · \(relativeTime(addedAt))"; color = p.textSecondary }
        // A shelf refresh touches every row: only what actually changed is redrawn and relaid.
        guard text != meta.stringValue || color != meta.textColor || exists != copyButton.isEnabled else { return }
        meta.stringValue = text
        meta.textColor = color
        action?.isEnabled = exists
        copyButton.isEnabled = exists
        name.textColor = exists ? p.text : p.textSecondary
        setAccessibilityLabel("\(name.stringValue), \(meta.stringValue). Press to copy.")
        needsLayout = true
    }

    /// Feedback after a copy: the copy icon turns into a green check, a green sweep crosses the
    /// row and its edge turns green for a moment.
    func flashCopied() {
        copiedUntil = Date().addingTimeInterval(1.4)
        updateButtons()
        needsDisplay = true
        let c = Pal.success
        sweep.colors = [c.withAlphaComponent(0.24).cgColor, c.withAlphaComponent(0).cgColor]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.25, 1]
        fade.duration = Motion.reduced ? 0.4 : 0.9
        sweep.add(fade, forKey: "fade")
        if !Motion.reduced {
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = -bounds.width * 0.3
            move.toValue = bounds.width * 0.1
            move.duration = 0.9
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sweep.add(move, forKey: "move")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) { [weak self] in
            guard let self = self, let until = self.copiedUntil, until <= Date() else { return }
            self.copiedUntil = nil
            self.updateButtons()
            self.needsDisplay = true
        }
    }

    private var isCopied: Bool { (copiedUntil ?? .distantPast) > Date() }

    private func updateButtons() {
        let p = Pal
        if isCopied {
            copyButton.symbol = "checkmark"
            copyButton.tint = p.success
            copyButton.wash = p.success.withAlphaComponent(0.16)
        } else {
            copyButton.symbol = "doc.on.doc"
            // Always there, faint until you point at the row, then the accent.
            copyButton.tint = hovered ? p.accent : p.textTertiary
            copyButton.wash = hovered ? p.accent.withAlphaComponent(0.14) : nil
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        sweep.frame = bounds
        let b = Metrics.rowButton
        more.frame = NSRect(x: w - 8 - b, y: (h - b) / 2, width: b, height: b)
        openButton.frame = NSRect(x: more.frame.minX - 2 - b, y: (h - b) / 2, width: b, height: b)
        copyButton.frame = NSRect(x: openButton.frame.minX - 2 - b, y: (h - b) / 2, width: b, height: b)
        var right = copyButton.frame.minX - 8
        let ts = RowTier.standard.tile
        tile.frame = NSRect(x: 10, y: (h - ts) / 2, width: ts, height: ts)
        if let a = action {
            // The name gets at least 150 pt; otherwise the button folds to its icon.
            let title = ShelfKind(path: path).suggested.title
            a.setTitleText(title)
            var aw = min(132, a.fittedWidth)
            if right - aw - 10 - 58 < 150 { a.setTitleText(""); a.toolTip = title; aw = Metrics.rowButton + 4 } else { a.toolTip = nil }
            a.frame = NSRect(x: right - aw, y: (h - Metrics.rowButton) / 2, width: aw, height: Metrics.rowButton)
            right = a.frame.minX - 10
        }
        let tx = tile.frame.maxX + 12
        name.frame = NSRect(x: tx, y: (h / 2 - 18).rounded(), width: max(40, right - tx), height: 18)
        meta.frame = NSRect(x: tx, y: (h / 2 + 1).rounded(), width: max(40, right - tx), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5).pressed(pressedDown), xRadius: Radius.l, yRadius: Radius.l)
        (hovered || pressedDown ? p.surfaceHover : p.surfaceRow).setFill(); path.fill()
        let edge: NSColor = isCopied ? p.success.withAlphaComponent(0.5) : (selected ? p.selectedEdge : p.divider)
        edge.setStroke(); path.lineWidth = 1; path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressedDown = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragged = false
        pressedDown = true
        if event.clickCount == 2, FileManager.default.fileExists(atPath: path) {
            pressedDown = false
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            dragged = true          // swallow the mouse-up
        }
    }

    /// A tap (press and release without moving) copies; a drag only carries the file.
    override func mouseUp(with event: NSEvent) {
        pressedDown = false
        guard !dragged, NSPointInRect(convert(event.locationInWindow, from: nil), bounds) else { return }
        onCopy?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, FileManager.default.fileExists(atPath: path) else { return }
        let dx = event.locationInWindow.x - downPoint.x, dy = event.locationInWindow.y - downPoint.y
        guard dx * dx + dy * dy > 12 else { return }
        dragged = true
        pressedDown = false
        let pbItem = NSPasteboardItem()
        pbItem.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        pbItem.setString(path, forType: shelfDragType)
        let di = NSDraggingItem(pasteboardWriter: pbItem)
        let img = shelfDragImage(path: path)
        let start = convert(event.locationInWindow, from: nil)
        di.setDraggingFrame(NSRect(x: start.x - 22, y: start.y - img.size.height / 2, width: img.size.width, height: img.size.height), contents: img)
        onDragBegan?()
        let session = beginDraggingSession(with: [di], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    // Inside Zera a drag means "move to the Drop Bin"; outside it copies the file.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .generic] : [.copy, .generic]
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?()
    }
}

/// A 28 pt symbol button inside a row (copy, details, more): quiet until you point at it.
final class ShelfRowButton: NSView {
    var symbol: String { didSet { if symbol != oldValue { needsDisplay = true } } }
    /// The glyph's colour; nil = secondary text.
    var tint: NSColor? { didSet { needsDisplay = true } }
    /// A soft fill behind the glyph (the copy button's accent / success wash).
    var wash: NSColor? { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onTap: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbol: String, label: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let r = bounds.pressed(pressed)
        let shape = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        if isEnabled, hovered || pressed { (pressed ? p.surfacePressed : p.surfaceStrong).setFill(); shape.fill() }
        else if let w = wash { w.setFill(); shape.fill() }
        let color = (isEnabled ? (hovered && tint == nil ? p.text : (tint ?? p.textSecondary)) : p.textTertiary)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [color]))) else { return }
        let s = img.size
        img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { if isEnabled { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        let inside = NSPointInRect(convert(event.locationInWindow, from: nil), bounds)
        pressed = false
        if inside, isEnabled { onTap?() }
    }
    override func accessibilityPerformPress() -> Bool { if isEnabled { onTap?() }; return isEnabled }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

// MARK: - Drop Bin

/// Drop a row here to take it off the Shelf (or out of Recent). Never deletes the file itself.
final class DropBin: NSView {
    var onDropPaths: (([String]) -> Void)?
    var onTargetChange: ((Bool) -> Void)?
    private var targeted = false { didSet { if targeted != oldValue { needsDisplay = true; onTargetChange?(targeted) } } }
    private var hovered = false { didSet { needsDisplay = true } }
    private var flash = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([shelfDragType])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drop Bin — drop files here to remove them from the Shelf")
    }
    required init?(coder: NSCoder) { fatalError() }

    private func paths(_ info: NSDraggingInfo) -> [String] {
        info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: shelfDragType) } ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !paths(sender).isEmpty else { return [] }
        targeted = true
        return .move
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { paths(sender).isEmpty ? [] : .move }
    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !paths(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ps = paths(sender)
        targeted = false
        guard !ps.isEmpty else { return false }
        onDropPaths?(ps)
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.flash = false }
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { targeted = false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let rose = p.danger
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: Radius.l + 2, yRadius: Radius.l + 2)
        if flash { p.success.withAlphaComponent(0.12).setFill(); path.fill() }
        else if targeted { rose.withAlphaComponent(0.14).setFill(); path.fill() }
        path.lineWidth = targeted ? 2 : 1.5
        if !targeted { path.setLineDash([7, 5], count: 2, phase: 0) }
        (flash ? p.success.withAlphaComponent(0.7) : (targeted ? rose : (hovered ? p.accentBorder : p.accent.withAlphaComponent(0.4)))).setStroke()
        path.stroke()

        let symbol = flash ? "checkmark.circle.fill" : (targeted ? "trash.fill" : "trash")
        let tint = flash ? p.success : (targeted ? rose : p.accent.blended(withFraction: 0.3, of: p.text) ?? p.accent)
        let midY = bounds.height / 2
        ddraw(dsymbol(symbol, targeted ? 26 : 22, tint, .medium), centeredIn: NSRect(x: 0, y: midY - 36, width: bounds.width, height: 32))
        let text = flash ? "Removed from Shelf" : (targeted ? "Release to remove" : "Drop files here to\nquickly remove them")
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let color = flash ? p.success : (targeted ? (rose.blended(withFraction: 0.25, of: .white) ?? rose) : p.text(0.85))
        (text as NSString).draw(in: NSRect(x: 12, y: midY + 2, width: bounds.width - 24, height: 40),
                                withAttributes: [.font: Typo.control, .foregroundColor: color, .paragraphStyle: para])
    }
}

// MARK: - Zera's reaction

/// Zera beside a bubble card: what she found, what she's doing, or what went wrong.
final class ZeraFileReaction: NSView {
    private let figure = NSImageView()
    private let bubble = FlippedView()
    private let title = dlabel(Typo.rowTitle, Pal.text)
    private let detail = dlabel(Typo.body, Pal.textSecondary, lines: 2)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let p = Pal
        figure.imageScaling = .scaleProportionallyUpOrDown
        figure.imageAlignment = .alignBottom
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = Radius.l + 2
        bubble.layer?.cornerCurve = .continuous
        bubble.layer?.backgroundColor = p.surfaceElevated.cgColor
        bubble.layer?.borderWidth = 1
        bubble.layer?.borderColor = p.accentBorder.withAlphaComponent(0.5).cgColor
        addSubview(bubble)
        bubble.addSubview(title)
        bubble.addSubview(detail)
        addSubview(figure)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(pose: String, title t: String, detail d: String) {
        figure.image = SpriteLibrary.shared.sprite(pose)?.image ?? SpriteLibrary.shared.sprite("idle")?.image
        title.stringValue = t
        detail.stringValue = d
        setAccessibilityLabel("Zera: \(t). \(d)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, fs: CGFloat = 84
        figure.frame = NSRect(x: 0, y: h - fs, width: fs, height: fs)
        let bx = fs + 6
        let textW = max(ceil((title.stringValue as NSString).size(withAttributes: [.font: title.font!]).width),
                        min(380, ceil((detail.stringValue as NSString).size(withAttributes: [.font: detail.font!]).width)))
        let bw = min(bounds.width - bx, textW + 34)
        bubble.frame = NSRect(x: bx, y: (h - 62) / 2, width: bw, height: 62)
        title.frame = NSRect(x: 16, y: 10, width: bw - 32, height: 19)
        detail.frame = NSRect(x: 16, y: 30, width: bw - 32, height: 30)
    }
}

// MARK: - Result content

/// The result card in the centre: a section header with Copy, then — scrolling — the processing
/// panel while Claude works, the rendered answer, and any buttons for what to do next.
final class FileResultContent: NSView {
    var onCopy: (() -> Void)?
    private let headIcon = NSImageView()
    private let headTitle = dlabel(Typo.detailTitle, Pal.text)
    private var copy: PRActionButton!
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private var processing: ProcessingBlock?
    private var buttons: [PRActionButton] = []
    private var attributed = NSAttributedString()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        copy = PRActionButton("Copy", style: .secondary, symbol: "doc.on.doc", target: self, action: #selector(copyTapped))
        headIcon.imageScaling = .scaleProportionallyUpOrDown
        [headIcon, headTitle, copy!].forEach { addSubview($0) }
        text.isSelectable = true
        text.lineBreakMode = .byWordWrapping
        text.cell?.wraps = true
        text.cell?.isScrollable = false
        doc.addSubview(text)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = doc
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func copyTapped() { onCopy?() }

    func set(title: String, symbol: String, body: NSAttributedString, canCopy: Bool,
             processing p: (stage: ZeraAssistant.Stage, progress: Double, action: FileAction?, file: String)?,
             buttons newButtons: [PRActionButton]) {
        headTitle.stringValue = title
        headIcon.image = dsymbol(symbol, 14, Pal.accent)
        copy.isHidden = !canCopy
        attributed = body
        text.attributedStringValue = body
        if let p = p {
            if processing == nil {
                let pb = ProcessingBlock(symbol: ShelfKind(path: p.file).symbol)
                doc.addSubview(pb)
                processing = pb
            }
            processing?.update(stage: p.stage, progress: p.progress, action: p.action, fileLabel: (p.file as NSString).lastPathComponent)
        } else {
            processing?.removeFromSuperview()
            processing = nil
        }
        buttons.forEach { $0.removeFromSuperview() }
        buttons = newButtons
        buttons.forEach { doc.addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        headIcon.frame = NSRect(x: 18, y: 18, width: 22, height: 22)
        let cw = copy.isHidden ? 0 : max(72, copy.fittedWidth)
        copy.frame = NSRect(x: w - 14 - cw, y: 13, width: cw, height: 30)
        headTitle.frame = NSRect(x: 48, y: 19, width: max(40, w - 48 - 14 - cw - 10), height: 20)
        let sx: CGFloat = 18, sw = w - 36
        scroll.frame = NSRect(x: sx, y: 54, width: sw, height: max(0, h - 54 - 12))
        var y: CGFloat = 4
        if let pb = processing {
            pb.frame = NSRect(x: 0, y: y, width: sw - 6, height: ProcessingBlock.height)
            y += ProcessingBlock.height + 12
        }
        let tw = sw - 10
        let th = attributed.length == 0 ? 0 : ceil(attributed.boundingRect(with: NSSize(width: tw, height: 100_000),
                                                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 6
        text.frame = NSRect(x: 0, y: y, width: tw, height: th)
        y += th + (th > 0 ? 12 : 0)
        // Buttons flow left to right, wrapping.
        var bx: CGFloat = 0
        for b in buttons {
            let bw = min(tw, b.fittedWidth)
            if bx > 0, bx + bw > tw { bx = 0; y += 34 + 8 }
            b.frame = NSRect(x: bx, y: y, width: bw, height: 34)
            bx += bw + 8
        }
        if !buttons.isEmpty { y += 34 + 8 }
        doc.frame = NSRect(x: 0, y: 0, width: sw, height: max(y, scroll.frame.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l + 2, yRadius: Radius.l + 2)
        p.surfaceRow.setFill(); path.fill()
        p.border.setStroke(); path.lineWidth = 1; path.stroke()
        p.accent.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: NSRect(x: 14, y: 14, width: 30, height: 30)).fill()
    }
}

// MARK: - Undo strip

private final class UndoStrip: NSView {
    let message = dlabel(Typo.bodyMedium, Pal.text)
    var button: PRActionButton? { didSet { oldValue?.removeFromSuperview(); if let b = button { addSubview(b) }; needsLayout = true } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.m + 2
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Pal.success.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Pal.success.withAlphaComponent(0.3).cgColor
        addSubview(message)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let h = bounds.height
        var right = bounds.width - 4
        if let b = button { let bw = max(64, b.fittedWidth); b.frame = NSRect(x: right - bw, y: (h - 28) / 2, width: bw, height: 28); right -= bw + 8 }
        message.frame = NSRect(x: 12, y: (h - 16) / 2, width: max(20, right - 12), height: 16)
    }
}

// MARK: - The screen

final class DropFilesView: NSView, CardContent {
    weak var delegate: ShelfViewDelegate?
    var onHeightChange: (() -> Void)?
    var onEscape: (() -> Void)?

    private static var selectedPath: String?
    /// True once you've tapped or opened an item: only then does it show a (quiet) highlight.
    /// The first item is still the default target for Summarize / Explain / Extract.
    private static var userFocused = false
    private static var tab = 0
    /// The file the current request was started for (before its payload exists).
    private static var runningPath: String?

    private let left = GlassPanel()
    private let center = GlassPanel()
    private let right = GlassPanel()

    // Left
    private let docTile = ScreenIconTile.dropFiles()
    private let leftTitle = dlabel(Typo.screenTitle, Pal.text)
    private let leftSub = dlabel(Typo.screenSubtitle, Pal.textSecondary)
    private let peek = NSImageView()
    private let bubble = ZeraGitHubBubble()
    private let zone = FileDropZone()
    private var actionTiles: [FileActionTile] = []
    private let recentTitle = dlabel(Typo.sectionLabel, Pal.textTertiary)
    private var clearRecent: PRActionButton!
    private let recentScroll = NSScrollView()
    private let recentList = FlippedView()
    private var recentRows: [String: ShelfFileRow] = [:]
    private var recentOrder: [String] = []
    private let recentEmpty = dlabel(Typo.body, Pal.textTertiary)
    // Fresh: what's new in the watched folders (Downloads, Desktop…), one tab over from the Shelf.
    private static let freshKey = "zera.shelf.freshTab"
    private var freshTab: Bool { UserDefaults.standard.bool(forKey: Self.freshKey) && FreshFiles.shared.enabled }
    private let leftTabs = GitHubSegmentedControl(items: [])
    private let freshScroll = NSScrollView()
    private let freshList = FlippedView()
    private var freshRows: [String: ShelfFileRow] = [:]
    private var freshOrder: [String] = []
    private let freshInfo = dlabel(Typo.meta, Pal.textTertiary)
    private var addFolder: PRActionButton!
    private let freshEmpty = dlabel(Typo.body, Pal.textTertiary)

    // Centre
    private let fileTile = FileTypeTile()
    private let fileName = dlabel(Typo.detailTitle, Pal.text)
    private let fileMeta = dlabel(Typo.body, Pal.textSecondary)
    private var finder: PRActionButton!
    private var removeButton: PRActionButton!
    private var fileMore: GHSquareButton!
    private var collapseButton: GHSquareButton!
    private let tabs = GitHubSegmentedControl(items: [])
    private let reaction = ZeraFileReaction()
    private let content = FileResultContent()
    private let input = ClaudeFollowUpInput()
    private var suggestionButtons: [PRActionButton] = []
    /// What the data says should show; layout only adds "and there's room".
    private var wantsReaction = false
    private var wantsSuggestions = false
    private var suggestionKind: ShelfKind?
    private let centerState = GHStateView()
    private var localText: [String: String] = [:]
    private var loadingLocal: Set<String> = []

    // Right
    private let trayTile = NSImageView()
    private let shelfTitle = dlabel(Typo.rowTitle, Pal.text)
    private let shelfCount = dlabel(Typo.meta, Pal.textSecondary)
    private var clearShelf: PRActionButton!
    private let undo = UndoStrip()
    private var undoItems: [ShelfItem] = []
    private var undoWork: DispatchWorkItem?
    private let shelfSearch = SearchBox(placeholder: "Search the Shelf…")
    private var shelfQuery = ""
    private let shelfScroll = NSScrollView()
    private let shelfList = FlippedView()
    private var shelfRows: [String: ShelfFileRow] = [:]
    private var shelfOrder: [String] = []
    private let shelfEmpty = GHStateView()
    private let bin = DropBin()

    private var ticker: Timer?
    private var lastShelfPaths: [String] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var store: ShelfStore { ShelfStore.shared }

    // MARK: Size

    private var screen: NSRect { (window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875) }
    /// Collapsed: just the Drop Files panel (what tapping Zera opens). Expanded: the selected
    /// file and the Shelf join it — when you drop a file, pick one, or run an action.
    private(set) var expanded = false
    /// A drop or a finished answer while the card was closed: open expanded next time.
    private var pendingExpand = false
    private var fullWidth: CGFloat { min(D.maxWidth, screen.width - 40) }
    /// One compact island width for the Shelf and the file view.
    var cardWidth: CGFloat { min(Isle.lensWidth, fullWidth) }
    var desiredHeight: CGFloat {
        guard !expanded else { return Isle.maxContentHeight }
        // Header, slim drop zone, one row of actions, up to three dropped files (more scroll).
        let rowH = ShelfFileRow.height(.dropped) + Metrics.rowGap
        let tabs: CGFloat = FreshFiles.shared.enabled ? Metrics.segment + 12 : 0
        if freshTab {
            // Up to five fresh files before the list scrolls.
            let n = min(5, freshOrder.count)
            return Isle.headerHeight + tabs + Metrics.chip + 10 + (n == 0 ? 60 : CGFloat(n) * rowH - Metrics.rowGap) + 16
        }
        let rows = min(3, recentOrder.count)
        let list: CGFloat = rows == 0 ? 40 : CGFloat(rows) * rowH - Metrics.rowGap
        return Isle.headerHeight + tabs + 60 + 12 + 40 + 16 + (tabs > 0 ? 0 : 26) + list + 16
    }
    /// The island shows one panel at a time: the Shelf, or the file you picked.
    private var threePane: Bool { false }
    /// The left list is the Shelf (dropped files you can pick up and drag anywhere). Only in the
    /// three-panel workspace, where the Shelf has its own panel, does it show Recent instead.
    private var leftShowsRecent: Bool { threePane }

    func setExpanded(_ on: Bool) {
        guard on != expanded else { return }
        expanded = on
        reload()
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
        delegate?.shelfHeightChanged()
        // The file's page slides in; Back slides the Shelf back from the left.
        Motion.open(on ? center : left, forward: on)
    }

    /// Called each time the card is shown: tapping Zera opens just Drop Files; a fresh drop or
    /// an answer that finished while the card was closed opens the full workspace.
    func willShow() {
        expanded = pendingExpand && selectedPath != nil
        pendingExpand = false
        if freshTab { FreshFiles.shared.start() }
        reload()
    }

    // MARK: Fresh

    /// Shelf ↔ Fresh. The first time Fresh opens, the watched folders are read (macOS asks for
    /// access then) and watched from then on.
    private func showFresh(_ on: Bool) {
        guard on != freshTab else { return }
        UserDefaults.standard.set(on, forKey: Self.freshKey)
        if on { FreshFiles.shared.start() }
        reload()
        layoutSubtreeIfNeeded()
        onHeightChange?()
        delegate?.shelfHeightChanged()
        Motion.page(on ? freshScroll : recentScroll, forward: on)
    }

    @objc private func freshChanged() {
        reloadLeft()
        needsLayout = true
        guard freshTab else { return }
        layoutSubtreeIfNeeded()
        onHeightChange?()
        delegate?.shelfHeightChanged()
    }

    @objc private func addFolderTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        panel.message = "New files in this folder show up in the Shelf's Fresh tab."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { r in
            guard r == .OK, let u = panel.url else { return }
            FreshFiles.shared.addFolder(u)
        }
    }

    /// Rows for the fresh files, newest first; a file that just arrived slides in.
    private func reloadFresh() {
        let fresh = FreshFiles.shared
        let items = fresh.items
        let ids = items.map(\.path)
        for (id, r) in freshRows where !ids.contains(id) { r.removeFromSuperview(); freshRows.removeValue(forKey: id) }
        let firstFill = freshRows.isEmpty
        for item in items {
            let r: ShelfFileRow
            if let existing = freshRows[item.path] { r = existing } else {
                r = makeRow(path: item.path, style: .dropped)
                freshList.addSubview(r)
                freshRows[item.path] = r
                if !firstFill { Motion.arrive(r, direction: 0) }
            }
            r.selected = Self.userFocused && item.path == selectedPath
            r.update(addedAt: item.added, status: ("\(item.source) · \(relativeTime(item.added))", Pal.textSecondary))
        }
        freshOrder = ids
        let names = fresh.folders.filter(\.on).map(\.name)
        freshInfo.stringValue = names.isEmpty ? "No folders watched" : "From " + names.joined(separator: ", ") + " · newest first"
        freshEmpty.stringValue = !fresh.started || fresh.scanning && items.isEmpty ? "Looking…"
            : (names.isEmpty ? "Add a folder to see what lands in it." : "Nothing new in the last \(fresh.windowTitle).")
        freshEmpty.isHidden = !items.isEmpty
    }

    // MARK: Init

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1240, height: 760))
        let p = Pal
        [left, center, right].forEach { addSubview($0) }
        registerForDraggedTypes([.fileURL, .png, .tiff, .pdf, .rtf, .string, .URL])

        // Left.
        left.addSubview(docTile)
        leftTitle.stringValue = "Shelf"
        left.addSubview(leftTitle)
        left.addSubview(leftSub)
        left.addSubview(zone)
        peek.imageScaling = .scaleProportionallyUpOrDown
        peek.imageAlignment = .alignBottom
        left.addSubview(peek)                    // over the zone: she leans on its top edge
        left.addSubview(bubble)
        let specs: [(String, String, NSColor, Selector)] = [
            ("Summarize", "sparkles", p.accent, #selector(summarizeTapped)),
            ("Explain", "text.magnifyingglass", p.info, #selector(explainTapped)),
            ("Extract text", "doc.text", p.tileNote, #selector(extractTapped)),
            ("Ask Zera", "bubble.left.fill", NSColor(srgbRed: 0.55, green: 0.40, blue: 0.98, alpha: 1), #selector(askTapped))
        ]
        for (t, sym, color, sel) in specs {
            let a = FileActionTile(title: t, symbol: sym, color: color)
            a.onTap = { [weak self] in _ = self?.perform(sel) }
            actionTiles.append(a)
            left.addSubview(a)
        }
        recentTitle.stringValue = "RECENT FILES"
        left.addSubview(recentTitle)
        clearRecent = PRActionButton("Clear all", style: .secondary, target: self, action: #selector(clearRecentTapped))
        left.addSubview(clearRecent)
        configure(recentScroll, recentList)
        left.addSubview(recentScroll)
        recentEmpty.stringValue = "Files you drop wait here — drag them anywhere."
        recentEmpty.alignment = .center
        left.addSubview(recentEmpty)
        leftTabs.onSelect = { [weak self] i in self?.showFresh(i == 1) }
        left.addSubview(leftTabs)
        configure(freshScroll, freshList)
        left.addSubview(freshScroll)
        freshInfo.lineBreakMode = .byTruncatingTail
        left.addSubview(freshInfo)
        addFolder = PRActionButton("Folder", style: .secondary, symbol: "plus", target: self, action: #selector(addFolderTapped))
        addFolder.toolTip = "Watch another folder for new files"
        left.addSubview(addFolder)
        freshEmpty.alignment = .center
        left.addSubview(freshEmpty)
        NotificationCenter.default.addObserver(self, selector: #selector(freshChanged), name: FreshFiles.changed, object: nil)

        // Centre.
        center.addSubview(fileTile)
        center.addSubview(fileName)
        fileName.lineBreakMode = .byTruncatingMiddle
        center.addSubview(fileMeta)
        finder = PRActionButton("Open in Finder", style: .secondary, symbol: "arrow.up.forward.square", target: self, action: #selector(finderTapped))
        removeButton = PRActionButton("", style: .destructive, symbol: "trash", target: self, action: #selector(removeSelectedTapped))
        removeButton.toolTip = "Remove from Shelf (the file stays on your Mac)"
        removeButton.setAccessibilityLabel("Remove from Shelf")
        fileMore = GHSquareButton(symbol: "ellipsis", label: "More", target: self, action: #selector(fileMoreTapped))
        collapseButton = GHSquareButton(symbol: "chevron.left", label: "Back to the Shelf", target: self, action: #selector(collapseTapped))
        [finder!, removeButton!, fileMore!, collapseButton!].forEach { center.addSubview($0) }
        tabs.onSelect = { [weak self] i in Self.tab = i; self?.reloadCenter() }
        tabs.switches = { [weak self] in self.map { [$0.content] } ?? [] }
        center.addSubview(tabs)
        center.addSubview(reaction)
        content.onCopy = { [weak self] in self?.copyContent() }
        center.addSubview(content)
        input.setPlaceholder("Ask a question about this file…")
        input.onSend = { [weak self] q in self?.ask(q) }
        input.onMenu = { [weak self] v in self?.showSuggestionMenu(from: v) }
        center.addSubview(input)
        center.addSubview(centerState)

        // Right.
        trayTile.image = dsymbol("tray.full", 15, p.text(0.85), .medium)
        trayTile.imageScaling = .scaleNone
        trayTile.wantsLayer = true
        trayTile.layer?.cornerRadius = 10
        trayTile.layer?.backgroundColor = p.surfaceRow.cgColor
        trayTile.layer?.borderWidth = 1
        trayTile.layer?.borderColor = p.border.cgColor
        right.addSubview(trayTile)
        shelfTitle.stringValue = "Dropped Files"
        right.addSubview(shelfTitle)
        right.addSubview(shelfCount)
        clearShelf = PRActionButton("", style: .secondary, symbol: "trash", target: self, action: #selector(clearShelfTapped))
        clearShelf.toolTip = "Clear all — takes everything off the Shelf (files stay on your Mac)"
        clearShelf.setAccessibilityLabel("Clear all")
        right.addSubview(clearShelf)
        undo.isHidden = true
        right.addSubview(undo)
        shelfSearch.field.delegate = self
        shelfSearch.layer?.backgroundColor = p.surfaceRow.cgColor
        right.addSubview(shelfSearch)
        configure(shelfScroll, shelfList)
        right.addSubview(shelfScroll)
        right.addSubview(shelfEmpty)
        bin.onDropPaths = { [weak self] paths in self?.binRemove(paths) }
        bin.onTargetChange = { [weak self] on in
            guard let self = self else { return }
            if on { self.delegate?.shelfSays("let go to take it off the Shelf 🗑", mood: .surprised, for: 0) }
            else { self.delegate?.shelfSettles() }
        }
        right.addSubview(bin)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reloadIfVisible), name: ShelfStore.changed, object: nil)
        nc.addObserver(self, selector: #selector(assistantChanged), name: ZeraAssistant.changed, object: nil)
        lastShelfPaths = store.items.map { $0.path }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        NotificationCenter.default.removeObserver(self)
        ticker?.invalidate()
    }

    private func configure(_ s: NSScrollView, _ doc: NSView) {
        s.hasVerticalScroller = false
        s.hasHorizontalScroller = false
        s.borderType = .noBorder
        s.drawsBackground = false
        s.contentView.drawsBackground = false
        s.verticalScrollElasticity = .allowed
        s.documentView = doc
    }

    /// Relative times ("2m ago") refresh while the screen is up.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker?.invalidate(); ticker = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.reloadIfVisible() } }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    // MARK: Compatibility with the old shelf API

    /// Home → Notes used to filter the grid; the Shelf is small enough to show everything.
    func select(filter f: ShelfFilter) { reload() }

    func paste() {
        let before = Set(store.items.map { $0.path })
        let n = store.ingest(pasteboard: .general)
        if n > 0 {
            selectNewest(excluding: before)
            delegate?.shelfSays(n == 1 ? "got it! drag it wherever you need it 💜" : "got all \(n)! ✨", mood: .happy, for: 2)
            delegate?.shelfDidAcceptDrop()
        } else {
            delegate?.shelfSays("clipboard's empty 🤔", mood: .thinking, for: 1.6)
        }
    }

    // MARK: Data

    private var selectedItem: ShelfItem? {
        guard let p = Self.selectedPath else { return nil }
        return store.items.first { $0.path == p }
    }

    /// The selected path even if it's only in Recent (not on the Shelf any more).
    private var selectedPath: String? {
        guard let p = Self.selectedPath else { return nil }
        if store.items.contains(where: { $0.path == p }) || store.recent.contains(where: { $0.path == p }) { return p }
        return nil
    }

    private var visibleShelf: [ShelfItem] {
        let q = shelfQuery.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.items : store.items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// Is Claude working on this file right now?
    private func isRunning(_ path: String) -> Bool {
        let a = ZeraAssistant.shared
        guard a.isBusy else { return false }
        if let u = a.session?.payload?.url { return u.standardizedFileURL.path == path }
        return Self.runningPath == path
    }

    /// The conversation for a file: the live one if it's the assistant's current file, else the
    /// last one kept in memory.
    private func turns(for path: String) -> [FileResultTurn] {
        let a = ZeraAssistant.shared
        if let s = a.session, let u = s.payload?.url, u.standardizedFileURL.path == path { return Self.convert(s.turns) }
        return store.thread(for: path)
    }

    private static func convert(_ turns: [AnalysisSession.Turn]) -> [FileResultTurn] {
        var out: [FileResultTurn] = []
        for t in turns {
            switch t {
            case .request(let a): out.append(FileResultTurn(request: a, answer: nil, failure: nil))
            case .answer(let text): if !out.isEmpty { out[out.count - 1].answer = text }
            case .failure(let m): if !out.isEmpty { out[out.count - 1].failure = m }
            }
        }
        return out
    }

    private func status(for path: String) -> (String, NSColor)? {
        let p = Pal
        if isRunning(path) { return ("●  Analyzing…", p.accent) }
        let t = turns(for: path)
        if let last = t.last {
            if last.failure != nil { return ("⚠︎  Didn't work — try again", p.warning) }
            if last.answer != nil { return ("✓  \(last.request.title) ready", p.success) }
        }
        return nil
    }

    // MARK: Reload

    @objc private func assistantChanged() {
        let a = ZeraAssistant.shared
        // Keep each file's conversation so it can be shown again after switching files.
        if let s = a.session, let u = s.payload?.url {
            store.saveThread(Self.convert(s.turns), for: u.standardizedFileURL.path)
        }
        if !a.isBusy, Self.runningPath != nil {
            // Finished while the card was closed: show the answer in the workspace next time.
            if window?.isVisible != true { pendingExpand = true }
            Self.runningPath = nil
        }
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        for (path, r) in shelfRows { r.update(addedAt: store.items.first { $0.path == path }?.addedAt ?? Date(), status: status(for: path)) }
        reloadCenter()
    }

    @objc func reload() {
        let paths = store.items.map { $0.path }
        // A new drop selects the newest file and asks what to do with it.
        if let newest = paths.first, !lastShelfPaths.contains(newest) {
            Self.selectedPath = newest
            Self.tab = 0
            // A drop only puts the file on the Shelf — ready to drag out or pick. The workspace
            // opens when you click the file or an action.
        }
        lastShelfPaths = paths
        if selectedPath == nil { Self.selectedPath = store.items.first?.path ?? store.recent.first?.path }
        // Nothing left to show in the workspace: fold back to Drop Files.
        if expanded, selectedPath == nil { expanded = false; DispatchQueue.main.async { [weak self] in self?.onHeightChange?(); self?.delegate?.shelfHeightChanged() } }

        reloadLeft()
        reloadRight()
        reloadCenter()
        needsLayout = true
    }

    @objc private func reloadIfVisible() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        reload()
    }

    private func reloadLeft() {
        let hasSel = selectedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        actionTiles.forEach { $0.enabled = hasSel }
        // Two-pane: the left list shows the Shelf (there's no right panel); otherwise Recent.
        recentTitle.stringValue = leftShowsRecent ? "RECENT FILES" : "DROPPED FILES"
        let entries: [(String, Date)] = leftShowsRecent ? store.recent.map { ($0.path, $0.addedAt) } : store.items.map { ($0.path, $0.addedAt) }
        let ids = entries.map { $0.0 }
        for (id, r) in recentRows where !ids.contains(id) { r.removeFromSuperview(); recentRows.removeValue(forKey: id) }
        for (path, at) in entries {
            let style: ShelfFileRow.Style = leftShowsRecent ? .recent : .dropped
            let r: ShelfFileRow
            if let existing = recentRows[path], existing.style == style { r = existing } else {
                recentRows[path]?.removeFromSuperview()
                r = makeRow(path: path, style: style)
                recentList.addSubview(r)
                recentRows[path] = r
            }
            r.selected = Self.userFocused && path == selectedPath
            r.update(addedAt: at, status: style == .dropped ? status(for: path) : nil)
        }
        recentOrder = ids
        recentEmpty.isHidden = !entries.isEmpty
        clearRecent.isHidden = entries.isEmpty

        // Shelf · Fresh.
        let fresh = freshTab, tabsOn = FreshFiles.shared.enabled && !leftShowsRecent
        leftTabs.isHidden = !tabsOn
        if tabsOn {
            let f = FreshFiles.shared
            leftTabs.items = [.init(symbol: "tray.full", title: "Shelf", count: store.items.count, tint: nil),
                              .init(symbol: "clock.arrow.circlepath", title: "Fresh · \(f.windowTitle)", count: f.started ? f.items.count : 0, tint: nil)]
            leftTabs.selected = fresh ? 1 : 0
        }
        if fresh { reloadFresh() }
        ([zone, recentScroll, recentEmpty, clearRecent, undo] as [NSView]).forEach { $0.isHidden = $0.isHidden || fresh }
        actionTiles.forEach { $0.isHidden = fresh }
        if !fresh { zone.isHidden = false; recentScroll.isHidden = false }
        recentTitle.isHidden = tabsOn
        ([freshScroll, freshInfo, addFolder] as [NSView]).forEach { $0.isHidden = !fresh }
        freshEmpty.isHidden = !fresh || !freshOrder.isEmpty

        // Zera over the zone: excited when files are on the Shelf, peeking when it's empty.
        peek.image = SpriteLibrary.shared.sprite(zone.isTargeted ? "card_catch_pdf" : "card_peek_down")?.image
            ?? SpriteLibrary.shared.sprite("peek")?.image
        bubble.text = zone.isTargeted ? "Drop it here! ✨" : (store.items.isEmpty ? "Drop a file here\nand I'll take a look! ✨" : "Tap a file to copy it,\nor drag it out 👇")
        let n = store.items.count
        if freshTab {
            let k = FreshFiles.shared.items.count
            leftSub.stringValue = "\(k) new in the last \(FreshFiles.shared.windowTitle) · tap to copy"
        } else {
            leftSub.stringValue = n == 0 ? "Drop files on Zera or below" : "\(n) file\(n == 1 ? "" : "s") · tap to copy, drag to use"
        }
        recentTitle.stringValue = leftShowsRecent ? "RECENT FILES" : "DROPPED FILES"
    }

    private func reloadRight() {
        let p = Pal
        let n = store.items.count
        shelfCount.stringValue = n == 1 ? "1 file" : "\(n) files"
        clearShelf.isHidden = n == 0
        shelfSearch.isHidden = n <= 8
        let shown = visibleShelf
        let ids = shown.map { $0.path }
        for (id, r) in shelfRows where !ids.contains(id) { r.removeFromSuperview(); shelfRows.removeValue(forKey: id) }
        for item in shown {
            let r: ShelfFileRow
            if let existing = shelfRows[item.path] { r = existing } else {
                r = makeRow(path: item.path, style: .dropped)
                shelfList.addSubview(r)
                shelfRows[item.path] = r
            }
            r.selected = Self.userFocused && item.path == selectedPath
            r.update(addedAt: item.addedAt, status: status(for: item.path))
        }
        shelfOrder = ids
        shelfEmpty.isHidden = n > 0
        if n == 0 {
            shelfEmpty.set(pose: "card_sleepy_sit", title: "Your Shelf is empty.", subtitle: "Drop something here and I'll help.")
        }
        _ = p
    }

    private func makeRow(path: String, style: ShelfFileRow.Style) -> ShelfFileRow {
        let r = ShelfFileRow(path: path, style: style)
        r.onCopy = { [weak self] in self?.copyItem(path) }
        r.onSelect = { [weak self] in self?.select(path) }
        r.onAction = { [weak self] in self?.runSuggested(path) }
        r.onMenu = { [weak self] v in self?.showRowMenu(path: path, style: style, from: v) }
        r.onDragBegan = { [weak self] in
            self?.delegate?.shelfDragOutBegan()
            self?.delegate?.shelfSays("drag it to the Drop Bin to remove — or out to copy it 💜", mood: .giving, for: 0)
        }
        r.onDragEnded = { [weak self] in
            self?.delegate?.shelfDragOutEnded()
            self?.delegate?.shelfSettles()
        }
        return r
    }

    // MARK: Centre content

    private func reloadCenter() {
        let p = Pal
        guard let path = selectedPath else {
            [fileTile, fileName, fileMeta, finder, removeButton, fileMore, tabs, reaction, content, input].forEach { $0.isHidden = true }
            suggestionButtons.forEach { $0.isHidden = true }
            wantsReaction = false
            wantsSuggestions = false
            centerState.isHidden = false
            centerState.set(pose: "card_point_sparkle", title: "Pick a file to get started",
                            subtitle: "Drop a file on the left — or right on me — then choose an action. Nothing is sent to Claude until you do.")
            return
        }
        centerState.isHidden = true
        [fileTile, fileName, fileMeta, finder, fileMore, tabs, reaction, content, input].forEach { $0.isHidden = false }
        let onShelf = store.items.contains { $0.path == path }
        removeButton.isHidden = !onShelf
        let kind = ShelfKind(path: path)
        let exists = FileManager.default.fileExists(atPath: path)
        let running = isRunning(path)
        let thread = turns(for: path)
        let a = ZeraAssistant.shared

        // Header.
        fileTile.set(path: path)
        fileName.stringValue = (path as NSString).lastPathComponent
        fileName.toolTip = path
        var meta = [kind.label, fileSize(path)].compactMap { $0 }.joined(separator: "  ·  ")
        if !exists { meta = "No longer available at its original location" }
        else if running { meta += "  ·  Analyzing with Claude…" }
        else if !onShelf { meta += "  ·  In Recent (not on the Shelf)" }
        fileMeta.stringValue = meta
        fileMeta.textColor = exists ? p.textSecondary : p.warning
        finder.isEnabled = exists

        // Tabs with real counts.
        let qa = thread.filter { if case .ask = $0.request { return true } else { return false } }.count
        tabs.items = [
            .init(symbol: "", title: "Summary", count: 0, tint: nil),
            .init(symbol: "", title: "Key Points", count: 0, tint: nil),
            .init(symbol: "", title: "Full Text", count: 0, tint: nil),
            .init(symbol: "", title: "Q&A", count: qa, tint: nil),
            .init(symbol: "", title: "Chat", count: thread.count, tint: nil)
        ]
        tabs.selected = Self.tab

        // Zera.
        let lastFailure = thread.last?.failure
        if !exists {
            reaction.set(pose: "worried", title: "This file is no longer available.", detail: "It moved or was deleted. You can remove it from the Shelf.")
        } else if running {
            reaction.set(pose: a.phase == .streaming ? "card_writing" : "reading", title: "Reading \(fileName.stringValue)…",
                         detail: "Claude is working on it through your Claude Code login — nothing opens.")
        } else if let f = lastFailure {
            reaction.set(pose: "worried", title: "That didn't work 😕", detail: ClaudeActivityService.oneLine(f, max: 120))
        } else if thread.contains(where: { $0.answer != nil }) {
            reaction.set(pose: "holding_doc", title: "Here's what I found ✨", detail: "You can ask me anything about it.")
        } else {
            reaction.set(pose: "excited", title: "What should we do with this? 👀", detail: "Nothing is sent to Claude until you pick an action.")
        }

        // Content for the tab.
        let (title, symbol, md, buttons, copyable) = tabContent(path: path, kind: kind, thread: thread, running: running, exists: exists)
        let theme = MarkdownLite.Theme(text: p.text, secondary: p.textSecondary, code: p.isDark ? p.codeText : p.text,
                                       codeBackground: p.isDark ? p.codeBox : p.surfaceStrong, accent: p.accent,
                                       body: NSFont.systemFont(ofSize: 13.5), bold: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
                                       mono: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                       h1: NSFont.systemFont(ofSize: 16, weight: .bold), h2: Typo.detailTitle,
                                       h3: NSFont.systemFont(ofSize: 13.5, weight: .semibold))
        let body = md.isEmpty ? NSAttributedString() : MarkdownLite.render(md, theme: theme, width: max(200, content.bounds.width - 46))
        let proc: (stage: ZeraAssistant.Stage, progress: Double, action: FileAction?, file: String)? = running ? (a.stage, a.progress, a.currentAction, path) : nil
        content.set(title: title, symbol: symbol, body: body, canCopy: copyable && !md.isEmpty, processing: proc, buttons: buttons)
        currentCopyText = copyable ? md : ""

        // Suggestions under the input, per kind.
        if suggestionKind != kind {
            suggestionKind = kind
            suggestionButtons.forEach { $0.removeFromSuperview() }
            suggestionButtons = kind.suggestions.map { q in
                let b = PRActionButton(q, style: .secondary, symbol: "sparkles", target: self, action: #selector(suggestionTapped(_:)))
                b.toolTip = q
                center.addSubview(b)
                return b
            }
        }
        wantsReaction = true
        wantsSuggestions = true
        suggestionButtons.forEach { $0.isEnabled = exists && !a.isBusy }
        needsLayout = true
    }

    private var currentCopyText = ""

    private func button(_ title: String, _ symbol: String, primary: Bool = false, _ action: FileAction?) -> PRActionButton {
        let b = PRActionButton(title, style: primary ? .primary : .secondary, symbol: symbol, target: self, action: #selector(ctaTapped(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(Self.encode(action))
        b.isEnabled = !ZeraAssistant.shared.isBusy
        return b
    }

    private static func encode(_ a: FileAction?) -> String {
        switch a {
        case .summarize?: return "summarize"
        case .explain?: return "explain"
        case .extract?: return "extract"
        case .ask(let q)?: return "ask:" + q
        case nil: return "focus"
        }
    }

    private static func decode(_ s: String) -> FileAction? {
        switch s {
        case "summarize": return .summarize
        case "explain": return .explain
        case "extract": return .extract
        default: return s.hasPrefix("ask:") ? .ask(String(s.dropFirst(4))) : nil
        }
    }

    /// (section title, icon, markdown, buttons, copyable) for the current tab — all from real
    /// results; empty tabs offer the action that would fill them.
    private func tabContent(path: String, kind: ShelfKind, thread: [FileResultTurn], running: Bool, exists: Bool)
        -> (String, String, String, [PRActionButton], Bool) {
        let a = ZeraAssistant.shared
        let live = running ? (a.liveText ?? "") : ""
        guard exists else {
            return ("File missing", "exclamationmark.triangle", "The file isn't at **\(path)** any more.",
                    store.items.contains { $0.path == path } ? [button("Remove from Shelf", "trash", nil)] : [], false)
        }
        func latest(_ match: (FileAction) -> Bool) -> FileResultTurn? { thread.last { match($0.request) && ($0.answer != nil || $0.failure != nil) } }
        let isSummary: (FileAction) -> Bool = { $0 == .summarize || $0 == .explain }
        let runningAction = running ? a.currentAction : nil

        switch Self.tab {
        case 0:
            if let r = runningAction, isSummary(r) { return (r == .summarize ? "Summary" : "Explanation", "sparkles", live, [], false) }
            if let t = latest(isSummary) {
                if let f = t.failure { return ("Summary", "sparkles", "⚠️ \(f)", [button("Try again", "arrow.clockwise", primary: true, t.request)], false) }
                return (t.request == .summarize ? "Summary" : "Explanation", "sparkles", t.answer ?? "", [], true)
            }
            return ("Summary", "sparkles", "No summary yet. Pick what you'd like — Zera sends the file to Claude only when you click.",
                    [button("Summarize", "sparkles", primary: true, .summarize), button("Explain", "text.magnifyingglass", .explain),
                     button("Extract text", "doc.text", .extract)], false)
        case 1:
            let source = latest(isSummary)?.answer ?? thread.last(where: { $0.answer != nil })?.answer
            if let s = source {
                let bullets = Self.bullets(in: s)
                if !bullets.isEmpty {
                    return ("Key points", "list.bullet", bullets.map { "- " + $0 }.joined(separator: "\n"), [], true)
                }
            }
            if running { return ("Key points", "list.bullet", live, [], false) }
            return ("Key points", "list.bullet", "No key points yet.",
                    [button("Get key points", "list.bullet", primary: true, .ask("List the key points of this file as short bullet points."))], false)
        case 2:
            if runningAction == .extract { return ("Full text", "doc.text", live, [], false) }
            if let t = latest({ $0 == .extract }), let ans = t.answer { return ("Full text", "doc.text", ans, [], true) }
            if kind.hasLocalText {
                if let text = localText[path] {
                    let note = "_Local preview — read on your Mac, not sent to Claude._\n\n"
                    return ("Full text", "doc.text", note + "```\n" + text + "\n```", [button("Extract with Claude", "doc.text", .extract)], true)
                }
                loadLocalText(path, kind: kind)
                return ("Full text", "doc.text", "Reading the file…", [], false)
            }
            return ("Full text", "doc.text", kind == .image ? "Images need Claude to read the text in them." : "There's no text preview for this file type.",
                    [button("Extract text", "doc.text", primary: true, .extract)], false)
        case 3:
            var md = ""
            for t in thread { if case .ask(let q) = t.request, let ans = t.answer ?? t.failure.map({ "⚠️ " + $0 }) { md += "**Q: \(q)**\n\n\(ans)\n\n" } }
            if let r = runningAction, case .ask(let q) = r { md += "**Q: \(q)**\n\n\(live)" }
            if md.isEmpty {
                return ("Questions & answers", "questionmark.bubble", "Ask anything about this file in the box below — or try one of these:",
                        kind.suggestions.map { button($0, "sparkles", .ask($0)) }, false)
            }
            return ("Questions & answers", "questionmark.bubble", md, [], true)
        default:
            var md = ""
            for t in thread {
                let ask: String
                if case .ask(let q) = t.request { ask = q } else { ask = t.request.title }
                md += "**You:** \(ask)\n\n" + (t.answer ?? t.failure.map { "⚠️ " + $0 } ?? "…") + "\n\n"
            }
            if running, let r = runningAction {
                let ask: String
                if case .ask(let q) = r { ask = q } else { ask = r.title }
                if !(thread.last.map { $0.request == r && $0.answer == nil && $0.failure == nil } ?? false) { md += "**You:** \(ask)\n\n" }
                md += live
            }
            if md.isEmpty { return ("Chat", "bubble.left.and.bubble.right", "No messages yet. Pick an action or ask a question below.", [], false) }
            return ("Chat", "bubble.left.and.bubble.right", md, [], true)
        }
    }

    /// Bullet / numbered lines of an answer, without their markers.
    private static func bullets(in text: String) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(String(line.dropFirst(2)))
            } else if let dot = line.firstIndex(of: "."), line[line.startIndex..<dot].allSatisfy({ $0.isNumber }), dot != line.startIndex {
                out.append(String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return out.filter { !$0.isEmpty }
    }

    /// Text shown on Full Text without Claude: plain/code/markdown files and PDFs, read
    /// locally off the main thread, capped so huge files never load whole.
    private func loadLocalText(_ path: String, kind: ShelfKind) {
        guard !loadingLocal.contains(path) else { return }
        loadingLocal.insert(path)
        DispatchQueue.global(qos: .userInitiated).async {
            var text = ""
            let limit = 20_000
            if kind == .pdf, let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
                var out = ""
                for i in 0..<min(doc.pageCount, 30) {
                    out += (doc.page(at: i)?.string ?? "") + "\n"
                    if out.count > limit { break }
                }
                text = out
            } else if let fh = FileHandle(forReadingAtPath: path) {
                let data = (try? fh.read(upToCount: 200_000)) ?? Data()
                try? fh.close()
                text = String(decoding: data, as: UTF8.self)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > limit { text = String(text.prefix(limit)) + "\n…" }
            if text.isEmpty { text = "(No text found — try Extract with Claude.)" }
            let result = text.replacingOccurrences(of: "```", with: "ʼʼʼ")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loadingLocal.remove(path)
                    self.localText[path] = result
                    if self.selectedPath == path { self.reloadCenter() }
                }
            }
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        center.isHidden = !expanded
        right.isHidden = true
        // The island shows one panel at a time.
        left.isHidden = expanded
        if !expanded {
            left.frame = NSRect(x: 0, y: 0, width: w, height: h)
            layoutLeft(left.bounds.size)
            return
        }
        center.frame = NSRect(x: 0, y: 0, width: w, height: h)
        layoutCenter(center.bounds.size)
    }

    private func layoutLeft(_ size: NSSize) {
        let w = size.width, h = size.height, x = D.pad, iw = w - D.pad * 2
        // Island header: title and count left of Zera; Clear all on the right. Her own pictures
        // stay hidden — she hangs in the middle of the header.
        [docTile, peek, bubble].forEach { $0.isHidden = true }
        leftTitle.frame = ScreenHeader.titleFrame(width: w, padding: x)
        leftSub.frame = ScreenHeader.subtitleFrame(width: w, padding: x)
        let cw = clearRecent.isHidden ? 0 : max(80, clearRecent.fittedWidth)
        clearRecent.frame = NSRect(x: w - x - cw, y: ScreenHeader.controlY(Metrics.control), width: cw, height: Metrics.control)

        // Shelf · Fresh under the header.
        var top = Isle.headerHeight
        if !leftTabs.isHidden {
            leftTabs.frame = NSRect(x: x, y: top, width: iw, height: Metrics.segment)
            top += Metrics.segment + 12
        }
        if freshTab {
            let bw = addFolder.fittedWidth
            addFolder.frame = NSRect(x: x + iw - bw, y: top, width: bw, height: Metrics.chip)
            freshInfo.frame = NSRect(x: x + 2, y: top + 6, width: iw - bw - 12, height: 16)
            top += Metrics.chip + 10
            freshScroll.frame = NSRect(x: x - 4, y: top, width: iw + 8, height: max(0, h - 12 - top))
            freshEmpty.frame = NSRect(x: x, y: top + 16, width: iw, height: 18)
            var fy: CGFloat = 0
            for path in freshOrder {
                guard let r = freshRows[path] else { continue }
                let rh = ShelfFileRow.height(.dropped)
                r.frame = NSRect(x: 4, y: fy, width: iw, height: rh)
                fy += rh + Metrics.rowGap
            }
            freshList.frame = NSRect(x: 0, y: 0, width: iw + 8, height: max(fy, freshScroll.frame.height))
            return
        }

        // Slim drop zone, then the four actions in one row.
        let zoneY = top
        zone.frame = NSRect(x: x, y: zoneY, width: iw, height: 60)
        let ay = zone.frame.maxY + 12, ah: CGFloat = 40
        let aw = (iw - 8 * 3) / 4
        for (i, t) in actionTiles.enumerated() {
            t.frame = NSRect(x: x + CGFloat(i) * (aw + 8), y: ay, width: aw, height: ah)
        }

        // The dropped files.
        let ry = ay + ah + 16
        recentTitle.frame = NSRect(x: x, y: ry, width: iw, height: 18)
        var ly = recentTitle.isHidden ? ry : ry + 26
        if !leftShowsRecent, !undo.isHidden {
            if undo.superview !== left { left.addSubview(undo) }
            undo.frame = NSRect(x: x, y: ly, width: iw, height: 38)
            ly += 38 + 8
        }
        recentScroll.frame = NSRect(x: x - 4, y: ly, width: iw + 8, height: max(0, h - 12 - ly))
        recentEmpty.frame = NSRect(x: x, y: ly + 10, width: iw, height: 18)
        var y: CGFloat = 0
        for path in recentOrder {
            guard let r = recentRows[path] else { continue }
            let rh = ShelfFileRow.height(r.style)
            r.frame = NSRect(x: 4, y: y, width: iw, height: rh)
            y += rh + Metrics.rowGap
        }
        recentList.frame = NSRect(x: 0, y: 0, width: iw + 8, height: max(y, recentScroll.frame.height))
    }

    private func layoutCenter(_ size: NSSize) {
        let w = size.width, h = size.height, x = D.pad, iw = w - D.pad * 2
        centerState.frame = NSRect(x: x, y: Isle.headerHeight, width: iw, height: max(0, h - Isle.headerHeight - 20))

        // Island header: back · name / meta on the left of Zera; Finder, remove, ••• on the right.
        collapseButton.frame = NSRect(x: x, y: ScreenHeader.controlY(Metrics.headerButton), width: Metrics.headerButton, height: Metrics.headerButton)
        collapseButton.setAccessibilityLabel("Back to the Shelf")
        fileTile.isHidden = true
        fileMore.frame = NSRect(x: w - x - 34, y: ScreenHeader.controlY(Metrics.headerButton), width: Metrics.headerButton, height: Metrics.headerButton)
        var right = fileMore.frame.minX - 8
        if !removeButton.isHidden {
            removeButton.frame = NSRect(x: right - 34, y: ScreenHeader.controlY(Metrics.headerButton), width: Metrics.headerButton, height: Metrics.headerButton)
            right = removeButton.frame.minX - 8
        }
        finder.setTitleText("")
        finder.frame = NSRect(x: right - 34, y: ScreenHeader.controlY(Metrics.headerButton), width: Metrics.headerButton, height: Metrics.headerButton)
        fileName.frame = ScreenHeader.detailTitleFrame(width: w, padding: x)
        fileMeta.frame = ScreenHeader.detailSubtitleFrame(width: w, padding: x)

        tabs.frame = NSRect(x: x, y: Isle.headerHeight, width: iw, height: Metrics.segment)

        // Bottom: suggestions, then the input.
        let suggestions = FlowLayout.frames(widths: suggestionButtons.map(\.fittedWidth), available: iw, height: Metrics.button)
        let sy = h - Space.l - (suggestions.last?.maxY ?? 0)
        for (b, frame) in zip(suggestionButtons, suggestions) {
            b.isHidden = !wantsSuggestions
            b.frame = frame.offsetBy(dx: x, dy: sy)
        }
        let anySuggestion = suggestionButtons.contains { !$0.isHidden }
        let inputY = (anySuggestion ? sy - Space.m : h - Space.l) - Metrics.field
        input.frame = NSRect(x: x, y: inputY, width: iw, height: Metrics.field)

        // The answer fills the rest; Zera's reaction lives in the header now (she hangs there).
        reaction.isHidden = true
        let cy = Isle.headerHeight + Metrics.segment + Space.m
        content.frame = NSRect(x: x, y: cy, width: iw, height: max(80, inputY - Space.m - cy))
    }

    private func layoutRight(_ size: NSSize) {
        let w = size.width, h = size.height, x: CGFloat = 16, iw = w - 32
        trayTile.frame = NSRect(x: x, y: 22, width: 36, height: 36)
        let cw: CGFloat = clearShelf.isHidden ? 0 : 34
        clearShelf.frame = NSRect(x: w - x - cw, y: 23, width: cw, height: 34)
        shelfTitle.frame = NSRect(x: x + 46, y: 21, width: iw - 46 - cw - 6, height: 19)
        shelfCount.frame = NSRect(x: x + 46, y: 41, width: iw - 46 - cw - 6, height: 16)
        var y: CGFloat = 72
        if !undo.isHidden {
            if undo.superview !== right { right.addSubview(undo) }
            undo.frame = NSRect(x: x, y: y, width: iw, height: 38); y += 38 + 10
        }
        if !shelfSearch.isHidden { shelfSearch.frame = NSRect(x: x, y: y, width: iw, height: 32); y += 32 + 10 }
        let binH: CGFloat = 132
        bin.frame = NSRect(x: x, y: h - 16 - binH, width: iw, height: binH)
        let listBottom = bin.frame.minY - 12
        shelfScroll.frame = NSRect(x: x, y: y, width: iw, height: max(0, listBottom - y))
        shelfEmpty.frame = shelfScroll.frame
        var ry: CGFloat = 0
        for path in shelfOrder {
            guard let r = shelfRows[path] else { continue }
            r.frame = NSRect(x: 0, y: ry, width: iw, height: ShelfFileRow.height(.dropped))
            ry += ShelfFileRow.height(.dropped) + Metrics.rowGap
        }
        shelfList.frame = NSRect(x: 0, y: 0, width: iw, height: max(ry, shelfScroll.frame.height))
    }

    // MARK: Actions

    /// Opens the item's page (summary, key points, Q&A): › on a row, ⌘↩, or "Open details".
    private func select(_ path: String) {
        Self.selectedPath = path
        Self.userFocused = true
        reload()
        setExpanded(true)
    }

    /// The Shelf's main gesture: tap an item and it's on your clipboard, in the form that pastes
    /// best (see `ShelfCopier`). The row confirms it; Zera says what was copied.
    private func copyItem(_ path: String) {
        guard let how = ShelfCopier.copy(path) else {
            NSSound.beep()
            delegate?.shelfSays("that file isn't there any more 😕", mood: .worried, for: 2)
            return
        }
        Self.selectedPath = path
        Self.userFocused = true
        for (p, r) in recentRows { r.selected = p == path; if p == path { r.flashCopied() } }
        for (p, r) in shelfRows { r.selected = p == path; if p == path { r.flashCopied() } }
        for (p, r) in freshRows { r.selected = p == path; if p == path { r.flashCopied() } }
        SoundService.shared.play(.clipCopy)
        var name = (path as NSString).lastPathComponent
        if name.count > 28 { name = String(name.prefix(25)) + "…" }
        let line: String
        switch how {
        case .file: line = "copied “\(name)” ✓"
        case .image: line = "copied the image ✓"
        case .text: line = "copied the note's text ✓"
        case .link: line = "copied the link ✓"
        }
        delegate?.shelfSays(line, mood: .happy, for: 1.6)
    }

    private func selectNewest(excluding before: Set<String>) {
        if let p = store.items.first(where: { !before.contains($0.path) })?.path { Self.selectedPath = p; Self.tab = 0 }
        reload()
    }

    /// Runs an action on a file inside Zera (the answer appears in the centre panel).
    private func run(_ action: FileAction, on path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            delegate?.shelfSays("that file isn't there any more 😕", mood: .worried, for: 2)
            return
        }
        // Recent files go back on the Shelf when you work with them.
        let item = store.items.first { $0.path == path }
            ?? store.recent.first { $0.path == path }.flatMap { store.reshelve($0) }
        guard let it = item else { return }
        if ZeraAssistant.shared.isBusy {
            delegate?.shelfSays("still working on \(ZeraAssistant.shared.currentFileName ?? "the last one") — one sec ⏳", mood: .focused, for: 2.5)
            return
        }
        Self.selectedPath = path
        Self.runningPath = path
        switch action {
        case .summarize, .explain: Self.tab = 0
        case .extract: Self.tab = 2
        case .ask: Self.tab = 3
        }
        store.setLastAction(action.title, for: path)
        delegate?.shelfRunsInPlace(action, on: it)
        reload()
        setExpanded(true)
    }

    private func runSuggested(_ path: String) {
        if let a = ShelfKind(path: path).suggested.action { run(a, on: path) } else { select(path); focusAsk() }
    }

    private func focusAsk() {
        Self.tab = 3
        setExpanded(true)
        reloadCenter()
        window?.makeFirstResponder(input.field)
    }

    @objc private func collapseTapped() { setExpanded(false) }

    @objc private func summarizeTapped() { if let p = selectedPath { run(.summarize, on: p) } }
    @objc private func explainTapped() { if let p = selectedPath { run(.explain, on: p) } }
    @objc private func extractTapped() { if let p = selectedPath { run(.extract, on: p) } }
    @objc private func askTapped() { focusAsk() }

    @objc private func ctaTapped(_ sender: PRActionButton) {
        guard let path = selectedPath, let id = sender.identifier?.rawValue else { return }
        if id == "focus" {
            if !FileManager.default.fileExists(atPath: path) { removePaths([path]) } else { focusAsk() }
            return
        }
        if let a = Self.decode(id) { run(a, on: path) }
    }

    @objc private func suggestionTapped(_ sender: PRActionButton) {
        guard let q = sender.toolTip else { return }
        ask(q)
    }

    /// A question about the selected file: a follow-up in its conversation when there is one,
    /// otherwise a new request.
    private func ask(_ q: String) {
        guard let path = selectedPath else { return }
        let a = ZeraAssistant.shared
        if let s = a.session, let u = s.payload?.url, u.standardizedFileURL.path == path, !a.isBusy {
            Self.tab = 3
            Self.runningPath = path
            a.ask(q)
            reload()
            return
        }
        run(.ask(q), on: path)
    }

    private func showSuggestionMenu(from v: NSView) {
        let kind = selectedPath.map { ShelfKind(path: $0) } ?? .other
        NSMenu.make(kind.suggestions.map { q in ClosureMenuItem(q, symbol: "sparkles") { [weak self] in self?.ask(q) } }).pop(below: v)
    }

    private func copyContent() {
        guard !currentCopyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentCopyText, forType: .string)
        delegate?.shelfSays("copied! 📋", mood: .happy, for: 1.2)
    }

    @objc private func finderTapped() {
        guard let p = selectedPath, FileManager.default.fileExists(atPath: p) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    @objc private func removeSelectedTapped() { if let p = selectedPath { removePaths([p]) } }

    @objc private func fileMoreTapped() {
        guard let p = selectedPath else { return }
        showRowMenu(path: p, style: store.items.contains { $0.path == p } ? .dropped : .recent, from: fileMore)
    }

    private func showRowMenu(path: String, style: ShelfFileRow.Style, from v: NSView) {
        let exists = FileManager.default.fileExists(atPath: path)
        let onShelf = store.items.contains { $0.path == path }
        let analyze = NSMenuItem(title: "Analyze", action: nil, keyEquivalent: "")
        analyze.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        analyze.submenu = NSMenu.make([
            ClosureMenuItem("Summarize", symbol: "sparkles", enabled: exists) { [weak self] in self?.run(.summarize, on: path) },
            ClosureMenuItem("Explain", symbol: "text.magnifyingglass", enabled: exists) { [weak self] in self?.run(.explain, on: path) },
            ClosureMenuItem("Extract text", symbol: "doc.text", enabled: exists) { [weak self] in self?.run(.extract, on: path) }
        ])
        analyze.isEnabled = exists
        var items: [NSMenuItem] = [
            ClosureMenuItem("Copy", symbol: "doc.on.doc", enabled: exists) { [weak self] in self?.copyItem(path) },
            ClosureMenuItem("Open details", symbol: "doc.text.magnifyingglass", enabled: exists) { [weak self] in self?.select(path) },
            .separator(),
            ClosureMenuItem("Open in app", symbol: "arrow.up.forward.app", enabled: exists) { _ = NSWorkspace.shared.open(URL(fileURLWithPath: path)) },
            analyze,
            ClosureMenuItem("Reveal in Finder", symbol: "folder", enabled: exists) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
            ClosureMenuItem("Copy path", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            .separator()
        ]
        if onShelf {
            items.append(ClosureMenuItem("Remove from Shelf", symbol: "tray.and.arrow.up") { [weak self] in self?.removePaths([path]) })
        } else {
            items.append(ClosureMenuItem("Add to Shelf", symbol: "tray.and.arrow.down", enabled: exists) { [weak self] in
                guard let self = self else { return }
                if let r = self.store.recent.first(where: { $0.path == path }) { self.store.reshelve(r) }
                else { self.store.add(urls: [URL(fileURLWithPath: path)]) }
            })
        }
        if style == .recent || !onShelf {
            items.append(ClosureMenuItem("Remove from Recent", symbol: "clock.arrow.circlepath") { [weak self] in
                self?.store.removeRecent(path: path)
            })
        }
        NSMenu.make(items).pop(below: v)
    }

    // MARK: Removing (references only — never the files)

    private func binRemove(_ paths: [String]) {
        let onShelf = paths.filter { p in store.items.contains { $0.path == p } }
        let recentOnly = paths.filter { !onShelf.contains($0) }
        if !onShelf.isEmpty { removePaths(onShelf) }
        for p in recentOnly { store.removeRecent(path: p) }
        if onShelf.isEmpty, !recentOnly.isEmpty { delegate?.shelfSays("removed from Recent ✨", mood: .happy, for: 1.4) }
    }

    private func removePaths(_ paths: [String]) {
        let ids = Set(store.items.filter { paths.contains($0.path) }.map { $0.id })
        let removed = store.remove(ids: ids)
        guard !removed.isEmpty else { return }
        offerUndo(removed, message: removed.count == 1 ? "Removed from Shelf" : "Removed \(removed.count) files")
        delegate?.shelfSays(removed.count == 1 ? "taken off the Shelf — the file's still on your Mac ✨" : "Shelf tidied ✨", mood: .happy, for: 1.8)
    }

    @objc private func clearShelfTapped() {
        let removed = store.clear()
        guard !removed.isEmpty else { return }
        offerUndo(removed, message: "Removed \(removed.count) file\(removed.count == 1 ? "" : "s") from the Shelf")
        delegate?.shelfSays("all tidy! Your files are still on your Mac ✨", mood: .happy, for: 2)
    }

    @objc private func clearRecentTapped() {
        if leftShowsRecent { store.clearRecent() } else { clearShelfTapped() }
    }

    private func offerUndo(_ items: [ShelfItem], message: String) {
        undoItems = items
        undo.message.stringValue = message
        undo.button = PRActionButton("Undo", style: .secondary, symbol: "arrow.uturn.backward", target: self, action: #selector(undoTapped))
        undo.isHidden = false
        undoWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.undo.isHidden = true
            self?.undoItems = []
            self?.needsLayout = true
        }
        undoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        needsLayout = true
    }

    @objc private func undoTapped() {
        store.restore(undoItems)
        undoItems = []
        undo.isHidden = true
        undoWork?.cancel()
        needsLayout = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: onEscape?()
        case 51, 117: if let p = selectedPath, store.items.contains(where: { $0.path == p }) { removePaths([p]) }
        // ↩ copies the item you're on; ⌘↩ opens its page.
        case 36, 76:
            if !expanded, let p = selectedPath { if cmd { select(p) } else { copyItem(p) } } else { super.keyDown(with: event) }
        case 9 where cmd: paste()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Drop in (Finder, Desktop, other apps)

    private func isInternal(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.types?.contains(shelfDragType) ?? false
    }

    private func setTargeted(_ on: Bool) {
        guard zone.isTargeted != on else { return }
        zone.isTargeted = on
        delegate?.shelfDragOverChanged(on)
        if on { delegate?.shelfSays("toss it here! 🙌", mood: .excited, for: 0) } else { delegate?.shelfSettles() }
        reloadLeft()
        needsLayout = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isInternal(sender) else { return [] }
        setTargeted(true)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { isInternal(sender) ? [] : .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setTargeted(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !isInternal(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        guard !isInternal(sender) else { return false }
        let pb = sender.draggingPasteboard
        let before = Set(store.items.map { $0.path })
        // Files land at once; a picture or text is written off the main thread and lands after.
        if let payload = ShelfStore.payload(from: pb), !store.alreadyHas(pasteboard: pb) {
            store.ingest(payload) { [weak self] added in
                guard let self = self else { return }
                guard added > 0 else { self.delegate?.shelfSays("hmm, I can't hold that", mood: .thinking, for: 1.6); return }
                self.selectNewest(excluding: before)
                self.delegate?.shelfSays(added == 1 ? "got it! drag it wherever you need it 💜" : "got all \(added)! ✨", mood: .happy, for: 2)
                self.delegate?.shelfDidAcceptDrop()
            }
            return true
        }
        if store.alreadyHas(pasteboard: pb) {
            if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
                Self.selectedPath = url.standardizedFileURL.path
                reload()
            }
            delegate?.shelfSays("already on your Shelf 😊", mood: .happy, for: 1.4)
            return true
        }
        delegate?.shelfSays("hmm, I can't hold that", mood: .thinking, for: 1.6)
        return false
    }
}

extension DropFilesView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === shelfSearch.field else { return }
        shelfQuery = shelfSearch.field.stringValue
        reloadRight()
        needsLayout = true
    }
}
