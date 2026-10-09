import AppKit

// MARK: - Markdown-lite

/// Enough Markdown for Claude's answers: headings, bullets, numbered lists, bold, inline code
/// and fenced code. Everything else is shown as-is. Pure function, so it is unit-testable.
enum MarkdownLite {
    struct Theme {
        var text: NSColor, secondary: NSColor, code: NSColor, codeBackground: NSColor, accent: NSColor
        var body: NSFont = Typo.body, bold: NSFont = Typo.bodyStrong, mono: NSFont = Typo.mono
        var h1: NSFont = NSFont.systemFont(ofSize: 14.5, weight: .bold)
        var h2: NSFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        var h3: NSFont = Typo.bodyStrong
    }

    static func render(_ markdown: String, theme t: Theme, width: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var inCode = false
        var codeBuffer: [String] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        func paragraph(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 4, indent: CGFloat = 0, head: CGFloat = 0) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = spacingBefore
            p.paragraphSpacing = spacingAfter
            p.headIndent = indent
            p.firstLineHeadIndent = head
            p.lineSpacing = 1.5
            p.lineBreakMode = .byWordWrapping
            if indent > 0 { p.tabStops = [NSTextTab(textAlignment: .left, location: indent, options: [:])] }
            return p
        }
        func flushCode() {
            guard !codeBuffer.isEmpty else { return }
            let text = codeBuffer.joined(separator: "\n") + "\n"
            out.append(NSAttributedString(string: text, attributes: [
                .font: t.mono, .foregroundColor: t.code, .backgroundColor: t.codeBackground,
                .paragraphStyle: paragraph(spacingBefore: 2, spacingAfter: 6, indent: 8, head: 8)]))
            codeBuffer = []
        }

        for raw in lines {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { flushCode() }
                inCode.toggle()
                continue
            }
            if inCode { codeBuffer.append(raw); continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: paragraph(spacingAfter: 0)]))
                continue
            }
            // Headings
            if let m = line.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
                let level = line[m].filter { $0 == "#" }.count
                let font = level == 1 ? t.h1 : (level == 2 ? t.h2 : t.h3)
                out.append(inline(String(line[m.upperBound...]), base: font, bold: font, t: t,
                                  style: paragraph(spacingBefore: out.length == 0 ? 0 : 8, spacingAfter: 4)))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // Bullets
            if let m = line.range(of: "^([-*•]|\\d{1,3}[.)])\\s+", options: .regularExpression) {
                let marker = line[m].trimmingCharacters(in: .whitespaces)
                let bullet = marker.first.map { "-*•".contains($0) } == true ? "•" : marker
                let body = String(line[m.upperBound...])
                let style = paragraph(spacingAfter: 3, indent: 18, head: 4)
                let a = NSMutableAttributedString(string: bullet + "\t", attributes: [.font: t.body, .foregroundColor: t.accent, .paragraphStyle: style])
                a.append(inline(body, base: t.body, bold: t.bold, t: t, style: style))
                a.append(NSAttributedString(string: "\n"))
                out.append(a)
                continue
            }
            if line.hasPrefix("> ") {
                out.append(inline(String(line.dropFirst(2)), base: t.body, bold: t.bold, t: t, style: paragraph(indent: 12, head: 12), color: t.secondary))
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            if line == "---" || line == "***" {
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 3)]))
                continue
            }
            out.append(inline(line, base: t.body, bold: t.bold, t: t, style: paragraph()))
            out.append(NSAttributedString(string: "\n"))
        }
        flushCode()
        // Trim the trailing newline so the text view does not keep an empty last line.
        while out.length > 0, out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// **bold**, `code`, *italic* (shown plain), [text](url) → text.
    static func inline(_ s: String, base: NSFont, bold: NSFont, t: Theme, style: NSParagraphStyle, color: NSColor? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: color ?? t.text, .paragraphStyle: style]
        var i = s.startIndex
        var plain = ""
        func flushPlain() { if !plain.isEmpty { out.append(NSAttributedString(string: plain, attributes: baseAttrs)); plain = "" } }
        while i < s.endIndex {
            let rest = s[i...]
            if rest.hasPrefix("**"), let close = rest.dropFirst(2).range(of: "**") {
                flushPlain()
                let inner = String(rest[rest.index(i, offsetBy: 2)..<close.lowerBound])
                out.append(NSAttributedString(string: inner, attributes: [.font: bold, .foregroundColor: color ?? t.text, .paragraphStyle: style]))
                i = close.upperBound
                continue
            }
            if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
                flushPlain()
                let inner = String(rest[rest.index(after: i)..<close])
                out.append(NSAttributedString(string: inner, attributes: [.font: t.mono, .foregroundColor: t.code, .backgroundColor: t.codeBackground, .paragraphStyle: style]))
                i = s.index(after: close)
                continue
            }
            if rest.hasPrefix("["), let mid = rest.range(of: "]("), let close = rest[mid.upperBound...].firstIndex(of: ")") {
                flushPlain()
                let label = String(rest[rest.index(after: i)..<mid.lowerBound])
                let link = String(rest[mid.upperBound..<close])
                var attrs = baseAttrs
                attrs[.foregroundColor] = t.accent
                if let u = URL(string: link) { attrs[.link] = u }
                out.append(NSAttributedString(string: label, attributes: attrs))
                i = s.index(after: close)
                continue
            }
            if rest.hasPrefix("*"), !rest.hasPrefix("**"), let close = rest.dropFirst().firstIndex(of: "*"), close > rest.index(after: i) {
                flushPlain()
                out.append(NSAttributedString(string: String(rest[rest.index(after: i)..<close]), attributes: baseAttrs))
                i = s.index(after: close)
                continue
            }
            plain.append(s[i])
            i = s.index(after: i)
        }
        flushPlain()
        return out
    }
}

// MARK: - Thread blocks

/// One rounded block in the conversation: Zera's answer (left, surface), your question (right,
/// accent), or a problem (amber). Height follows the text.
final class ThreadBlock: NSView {
    enum Kind { case answer, question, problem }
    let kind: Kind
    override var isFlipped: Bool { true }
    private let text = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private(set) var button: CardButton?

    static let pad = Space.m

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        let p = Pal
        roundLayer(Radius.l)
        switch kind {
        case .answer: layer?.backgroundColor = p.surface.cgColor
        case .question: layer?.backgroundColor = p.accentSoft.cgColor
        case .problem: layer?.backgroundColor = p.warning.withAlphaComponent(p.isDark ? 0.16 : 0.20).cgColor
        }
        text.isSelectable = true
        text.allowsEditingTextAttributes = false
        text.lineBreakMode = .byWordWrapping
        text.cell?.wraps = true
        text.cell?.isScrollable = false
        text.setAccessibilityLabel(kind == .question ? "Your question" : (kind == .problem ? "Problem" : "Zera's answer"))
        addSubview(text)
        icon.isHidden = kind != .problem
        if kind == .problem {
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Problem")
            icon.contentTintColor = p.isDark ? p.warning : NSColor(srgbRed: 0.55, green: 0.35, blue: 0.0, alpha: 1)
        }
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ attributed: NSAttributedString) { text.attributedStringValue = attributed }

    /// Width the text wants on one line (short questions get short bubbles).
    var naturalTextWidth: CGFloat { text.attributedStringValue.size().width }

    func setButton(_ title: String?, target: AnyObject, action: Selector) {
        button?.removeFromSuperview(); button = nil
        guard let t = title else { return }
        let b = CardButton(t, style: .primary, target: target, action: action)
        addSubview(b)
        button = b
    }

    private var textInsetLeft: CGFloat { kind == .problem ? Self.pad + 26 : Self.pad }
    private var buttonWidth: CGFloat { button.map { $0.fittedWidth + Space.m } ?? 0 }

    /// Height for a given block width.
    func height(for width: CGFloat) -> CGFloat {
        let tw = max(20, width - textInsetLeft - Self.pad - buttonWidth)
        let bound = text.attributedStringValue.boundingRect(with: NSSize(width: tw, height: .greatestFiniteMagnitude),
                                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        var h = ceil(bound.height) + 2
        if button != nil { h = max(h, Metrics.control) }
        return h + Self.pad * 2
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let y = Self.pad
        icon.frame = NSRect(x: Self.pad, y: Self.pad - 1, width: 18, height: 18)
        if let b = button {
            let bw = b.fittedWidth
            b.frame = NSRect(x: w - Self.pad - bw, y: (h - Metrics.control) / 2, width: bw, height: Metrics.control)
        }
        text.frame = NSRect(x: textInsetLeft, y: y, width: w - textInsetLeft - Self.pad - buttonWidth, height: h - y - Self.pad)
    }
}

// MARK: - Processing panel

/// "Analyzing file… · Summarizing with Claude", a progress bar and the four-step checklist,
/// shown at the top of the thread while a request runs.
final class ProcessingBlock: NSView {
    override var isFlipped: Bool { true }
    private let tile: IconTile
    private let title = NSTextField(labelWithString: "Analyzing file…")
    private let subtitle = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var stepLabels: [NSTextField] = []
    private var stepDots: [NSView] = []
    private var stage: ZeraAssistant.Stage = .reading
    private var progress: Double = 0
    private let zera = NSImageView()

    static let steps = ["Reading file", "Analyzing content", "Generating", "Done"]
    static let height: CGFloat = Space.m + 34 + Space.m + 4 + Space.m + 4 * 22 + Space.s

    init(symbol: String) {
        tile = IconTile(symbol: symbol, color: Pal.tileFile, size: 34, pointSize: 15)
        super.init(frame: .zero)
        let p = Pal
        roundLayer(Radius.l)
        layer?.backgroundColor = p.surface.cgColor
        addSubview(tile)
        title.font = Typo.bodyStrong; title.textColor = p.text; addSubview(title)
        subtitle.font = Typo.caption; subtitle.textColor = p.textSecondary; addSubview(subtitle)
        track.wantsLayer = true; track.layer?.cornerRadius = 2; track.layer?.backgroundColor = p.surfaceStrong.cgColor; addSubview(track)
        fill.wantsLayer = true; fill.layer?.cornerRadius = 2; fill.layer?.backgroundColor = p.accent.cgColor; addSubview(fill)
        for name in Self.steps {
            let dot = NSView(); dot.wantsLayer = true; dot.layer?.cornerRadius = 5; dot.layer?.borderWidth = 1.5
            addSubview(dot); stepDots.append(dot)
            let l = NSTextField(labelWithString: name); l.font = Typo.secondary; addSubview(l); stepLabels.append(l)
        }
        zera.imageScaling = .scaleProportionallyUpOrDown
        zera.imageAlignment = .alignBottomRight
        addSubview(zera)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(stage: ZeraAssistant.Stage, progress: Double, action: FileAction?, fileLabel: String) {
        self.stage = stage
        self.progress = progress
        let p = Pal
        let what: String
        switch action {
        case .summarize?: what = "Summarizing"
        case .explain?: what = "Explaining"
        case .extract?: what = "Extracting text"
        case .ask?: what = "Answering"
        case nil: what = "Working"
        }
        title.stringValue = stage == .done ? "Done" : (fileLabel.isEmpty ? "Thinking…" : "Analyzing \(fileLabel)…")
        subtitle.stringValue = "\(what) with Claude"
        let generating: String
        switch action {
        case .summarize?: generating = "Generating summary"
        case .explain?: generating = "Writing explanation"
        case .extract?: generating = "Extracting text"
        default: generating = "Writing answer"
        }
        for (i, l) in stepLabels.enumerated() {
            l.stringValue = i == 2 ? generating : Self.steps[i]
            let doneStep = i < stage.rawValue || stage == .done
            let active = i == stage.rawValue && stage != .done
            l.textColor = doneStep ? p.textSecondary : (active ? p.text : p.textTertiary)
            l.font = active ? NSFont.systemFont(ofSize: 11.5, weight: .semibold) : Typo.secondary
            let dot = stepDots[i]
            dot.layer?.backgroundColor = (doneStep ? p.accent : (active ? p.accentSoft : NSColor.clear)).cgColor
            dot.layer?.borderColor = (doneStep || active ? p.accent : p.muted).cgColor
        }
        setAccessibilityValue("\(Int(progress * 100)) percent")
        // She works at her laptop while reading, writes while generating, cheers when done.
        let pose: String
        switch stage {
        case .reading: pose = "card_read_q"
        case .analyzing: pose = "card_laptop_side"
        case .generating: pose = "card_writing"
        case .done: pose = "card_cheer"
        }
        zera.image = SpriteLibrary.shared.sprite(pose)?.image ?? SpriteLibrary.shared.sprite("laptop")?.image
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let x = Space.m, w = bounds.width - x * 2
        tile.frame = NSRect(x: x, y: Space.m, width: 34, height: 34)
        title.frame = NSRect(x: x + 44, y: Space.m, width: w - 44, height: 18)
        subtitle.frame = NSRect(x: x + 44, y: Space.m + 18, width: w - 44, height: 16)
        let ty = Space.m + 34 + Space.m
        track.frame = NSRect(x: x, y: ty, width: w, height: 4)
        fill.frame = NSRect(x: x, y: ty, width: max(6, w * CGFloat(progress)), height: 4)
        var y = ty + 4 + Space.m
        let zw: CGFloat = 104
        for i in 0..<Self.steps.count {
            stepDots[i].frame = NSRect(x: x + 2, y: y + 5, width: 10, height: 10)
            stepLabels[i].frame = NSRect(x: x + 22, y: y + 1, width: w - 22 - zw, height: 16)
            y += 22
        }
        zera.frame = NSRect(x: bounds.width - x - zw, y: ty + 4 + Space.s, width: zw, height: y - (ty + 4 + Space.s) - 2)
    }
}

// MARK: - Result panel

/// Zera's answer about a file (or a question), as a tidy thread: what you asked on the right,
/// her answers on the left, streaming in as Claude writes. Copy, save as a note, ask a follow-up
/// — all in here. Nothing in this card ever opens a terminal.
final class ResultCard: CardBase, CardContent, NSTextFieldDelegate {
    var cardWidth: CGFloat { 580 }
    var say: ((String, ZeraMood) -> Void)?
    var onClose: (() -> Void)?
    var onOpenClaudeSettings: (() -> Void)?

    private var tile: IconTile
    private let close: IconButton
    private let topRule = NSView()
    private let bottomRule = NSView()
    private let scroll = NSScrollView()
    private let thread = FlippedView()
    private var blocks: [ThreadBlock] = []
    private var processing: ProcessingBlock?
    private let askField = ThemedField(placeholder: "Ask a follow-up…")
    private let send: IconButton
    private let copyButton: CardButton
    private let saveNote: CardButton
    private let stop: CardButton

    private var threadHeight: CGFloat = 60
    private var caretOn = false
    private var caretTimer: Timer?
    private var wasBusy = false
    /// The answer scrolls inside the island rather than growing it.
    private let maxThreadHeight: CGFloat = Isle.maxContentHeight - 190

    init() {
        tile = IconTile(symbol: "sparkles", color: Pal.tileClaude, size: 28, pointSize: 13)
        close = IconButton(symbol: "xmark", label: "Close", target: nil, action: #selector(ResultCard.closeTapped))
        send = IconButton(symbol: "arrow.up.circle.fill", label: "Send question", target: nil, action: #selector(ResultCard.sendTapped))
        copyButton = CardButton("Copy", style: .secondary, symbol: "doc.on.doc", target: nil, action: #selector(ResultCard.copyTapped))
        saveNote = CardButton("Save Note", style: .secondary, symbol: "note.text", target: nil, action: #selector(ResultCard.saveNoteTapped))
        stop = CardButton("Stop", style: .destructive, symbol: "stop.fill", target: nil, action: #selector(ResultCard.stopTapped))
        super.init(width: 580, title: "Zera")
        let p = Pal
        for b in [close, send] { b.target = self }
        for b in [copyButton, saveNote, stop] { b.target = self }
        addSubview(tile); addSubview(close)

        for r in [topRule, bottomRule] {
            r.wantsLayer = true
            r.layer?.backgroundColor = p.divider.cgColor
            addSubview(r)
        }

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = thread
        addSubview(scroll)

        askField.delegate = self
        addSubview(askField)
        addSubview(send)
        addSubview(copyButton); addSubview(saveNote); addSubview(stop)

        NotificationCenter.default.addObserver(self, selector: #selector(reloadIfVisible), name: ZeraAssistant.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { caretTimer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopCaret() }
        else if busy && ZeraAssistant.shared.liveText != nil { startCaret() }
    }

    @objc private func reloadIfVisible() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        reload()
    }

    // MARK: Sizing

    private var busy: Bool { ZeraAssistant.shared.isBusy }
    private let footerHeight: CGFloat = Metrics.button

    var desiredHeight: CGFloat {
        headerBottom + 1 + threadHeight + 1 + Space.m + Metrics.control + Space.m + footerHeight + Metrics.cardPad
    }

    private var threadWidth: CGFloat { cardWidth - Metrics.cardPad * 2 }

    // MARK: Content

    @objc func reload() {
        let a = ZeraAssistant.shared, p = Pal
        let s = a.session
        tile.removeFromSuperview()
        tile = IconTile(symbol: s?.isGeneral == false ? Self.symbol(for: s?.payload?.kind) : "sparkles", color: p.tileClaude, size: 28, pointSize: 13)
        addSubview(tile)
        titleLabel.stringValue = s?.fileName ?? a.currentFileName ?? "Zera"

        var sub: [String] = []
        if let act = a.currentAction { sub.append(act.title) }
        if let pl = s?.payload {
            if let pages = pl.pageCount { sub.append("\(pages) page\(pages == 1 ? "" : "s")") } else { sub.append(byteString(pl.byteCount)) }
        }
        if let prov = a.activeProvider { sub.append(prov == .anthropicAPI ? "Anthropic API" : "Claude Code") }
        setSubtitle(sub.isEmpty ? nil : sub.joined(separator: " · "))

        rebuildThread(session: s, assistant: a)

        let hasAnswer = s?.turns.contains { if case .answer = $0 { return true } else { return false } } ?? false
        askField.isEnabled = !busy && s != nil
        send.isEnabled = askField.isEnabled
        askField.alphaValue = askField.isEnabled ? 1 : 0.55
        askField.setThemedPlaceholder(s?.isGeneral == false ? "Ask about \(s?.fileName ?? "this file")…" : "Ask Zera anything…")
        copyButton.isHidden = !hasAnswer
        saveNote.isHidden = !hasAnswer || s?.isGeneral == true
        stop.isHidden = !busy

        if busy && a.liveText != nil { startCaret() } else { stopCaret() }
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()

        // Keep the newest words in view while streaming; when an answer lands, show its top.
        if busy {
            thread.scroll(NSPoint(x: 0, y: max(0, thread.frame.height - scroll.contentSize.height)))
        } else if wasBusy, let last = blocks.last(where: { $0.kind == .answer }) {
            thread.scroll(NSPoint(x: 0, y: max(0, min(last.frame.minY - Space.s, thread.frame.height - scroll.contentSize.height))))
        }
        wasBusy = busy
    }

    private var markdownTheme: MarkdownLite.Theme {
        let p = Pal
        return MarkdownLite.Theme(text: p.text, secondary: p.textSecondary, code: p.isDark ? p.codeText : p.text,
                                  codeBackground: p.isDark ? p.codeBox : p.surfaceStrong, accent: p.accent)
    }

    /// Lays the conversation out as blocks: questions right, answers left, problems amber.
    private func rebuildThread(session s: AnalysisSession?, assistant a: ZeraAssistant) {
        blocks.forEach { $0.removeFromSuperview() }
        blocks = []
        processing?.removeFromSuperview()
        let w = threadWidth
        let theme = markdownTheme
        let caret = (busy && a.liveText != nil && caretOn) ? "▌" : ""

        func add(_ kind: ThreadBlock.Kind, _ text: NSAttributedString) -> ThreadBlock {
            let b = ThreadBlock(kind: kind)
            b.set(text)
            thread.addSubview(b)
            blocks.append(b)
            return b
        }
        func answer(_ md: String) -> ThreadBlock { add(.answer, MarkdownLite.render(md, theme: theme, width: w - ThreadBlock.pad * 2)) }
        func question(_ q: String) -> ThreadBlock {
            let st = NSMutableParagraphStyle(); st.lineBreakMode = .byWordWrapping; st.lineSpacing = 1.5
            return add(.question, NSAttributedString(string: q, attributes: [.font: Typo.bodyMedium, .foregroundColor: Pal.text, .paragraphStyle: st]))
        }

        if let s = s {
            for t in s.turns {
                switch t {
                case .request(let act):
                    if case .ask(let q) = act { _ = question(q) }
                case .answer(let text): _ = answer(text)
                case .failure: break   // shown from `phase` below, with its button
                }
            }
        }
        if busy {
            // The checklist panel first, then the answer as it streams in under it.
            let pb = ProcessingBlock(symbol: Self.symbol(for: s?.payload?.kind))
            pb.update(stage: a.stage, progress: a.progress, action: a.currentAction, fileLabel: s?.isGeneral == true ? "" : (a.currentFileName ?? "file"))
            thread.addSubview(pb)
            processing = pb
            if let live = a.liveText, !live.isEmpty { _ = answer(live + caret) }
        } else {
            processing = nil
        }
        if case .failed(let err) = a.phase {
            let st = NSMutableParagraphStyle(); st.lineBreakMode = .byWordWrapping
            let b = add(.problem, NSAttributedString(string: err.message, attributes: [.font: Typo.body, .foregroundColor: Pal.text, .paragraphStyle: st]))
            b.setButton(err.buttonTitle, target: self, action: #selector(errorActionTapped))
        }
        if blocks.isEmpty, processing == nil {
            let st = NSMutableParagraphStyle(); st.alignment = .center
            _ = add(.answer, NSAttributedString(string: "Drop a file on the shelf and pick Summarize, Explain or Extract — or just ask.",
                                                attributes: [.font: Typo.body, .foregroundColor: Pal.textSecondary, .paragraphStyle: st]))
        }

        // Measure & place: processing panel on top, then the thread.
        var y: CGFloat = Space.s
        if let pb = processing {
            pb.frame = NSRect(x: 0, y: y, width: w, height: ProcessingBlock.height)
            y += ProcessingBlock.height + Space.s
        }
        for b in blocks {
            let bw: CGFloat = b.kind == .question ? min(w * 0.78, Self.questionWidth(b, max: w * 0.78)) : w
            let h = b.height(for: bw)
            b.frame = NSRect(x: b.kind == .question ? w - bw : 0, y: y, width: bw, height: h)
            y += h + Space.s
        }
        let total = y
        thread.frame = NSRect(x: 0, y: 0, width: w, height: max(total, 1))
        threadHeight = min(maxThreadHeight, max(72, total))
    }

    /// Short questions get a short bubble.
    private static func questionWidth(_ b: ThreadBlock, max limit: CGFloat) -> CGFloat {
        let natural = ceil(b.naturalTextWidth) + ThreadBlock.pad * 2 + 2
        return max(80, min(limit, natural))
    }

    private static func symbol(for kind: FilePayload.Kind?) -> String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .markdown, .text, .document: return "doc.text"
        default: return "doc"
        }
    }

    /// Markdown for the whole conversation (Copy / Save Note).
    static func transcript(for s: AnalysisSession?, live: String?) -> String {
        guard let s = s else { return live ?? "" }
        var parts: [String] = []
        for t in s.turns {
            switch t {
            case .request(let a):
                if case .ask(let q) = a { parts.append("**You:** \(q)") }
            case .answer(let text): parts.append(text)
            case .failure: break
            }
        }
        if let l = live, !l.isEmpty { parts.append(l) }
        return parts.joined(separator: "\n\n")
    }

    private func startCaret() {
        guard caretTimer == nil, window != nil else { return }
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
                self.caretOn.toggle()
                self.reload()
            }
        }
    }

    private func stopCaret() {
        caretTimer?.invalidate(); caretTimer = nil
        caretOn = false
    }

    func focusAsk() { window?.makeFirstResponder(askField) }

    // MARK: Actions

    @objc private func closeTapped() {
        let a = ZeraAssistant.shared
        if a.isBusy { a.cancel() }
        a.clearSession()
        onClose?()
    }

    @objc private func stopTapped() {
        ZeraAssistant.shared.cancel()
        say?("okay, stopped", .idle)
    }

    /// Copies the latest answer.
    @objc private func copyTapped() {
        guard let s = ZeraAssistant.shared.session else { return }
        var latest = ""
        for t in s.turns { if case .answer(let text) = t { latest = text } }
        guard !latest.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latest, forType: .string)
        say?("copied ✨", .happy)
    }

    /// Saves the whole thread as a note on the shelf.
    @objc private func saveNoteTapped() {
        let a = ZeraAssistant.shared
        guard let s = a.session else { return }
        let text = Self.transcript(for: s, live: nil)
        guard !text.isEmpty else { return }
        let title = "\(a.currentAction?.title ?? "Notes") — \(s.fileName)"
        if a.saveNote(text, title: title) { say?("saved to the shelf 📝", .happy) }
        else { say?("couldn't save that 😬", .worried) }
    }

    @objc private func sendTapped() {
        let q = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { focusAsk(); return }
        askField.stringValue = ""
        let a = ZeraAssistant.shared
        if a.session?.isGeneral == true { a.askGeneral(q) } else { a.ask(q) }
    }

    @objc private func errorActionTapped() {
        guard case .failed(let err) = ZeraAssistant.shared.phase else { return }
        switch err.action {
        case .retry, .tryAgainFile: ZeraAssistant.shared.retry()
        case .openClaudeSettings, .configureAPIKey, .updateAPIKey: onOpenClaudeSettings?()
        case .none: break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === askField, commandSelector == #selector(NSResponder.insertNewline(_:)) { sendTapped(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onEscape?(); return true }
        return false
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        // Island header: the file and what Zera did with it, left of her; close on the right.
        let x = Metrics.cardPad, w = bounds.width - x * 2
        let half = bounds.width / 2 - Isle.zeraGap / 2
        tile.frame = NSRect(x: x, y: 30, width: 28, height: 28)
        titleLabel.frame = NSRect(x: x + 36, y: 24, width: max(0, half - x - 36), height: 22)
        subtitleLabel.frame = NSRect(x: x + 36, y: 46, width: max(0, half - x - 36), height: 16)
        close.frame = NSRect(x: bounds.width - x - Metrics.control, y: 30, width: Metrics.control, height: Metrics.control)
        var y = headerBottom
        topRule.frame = NSRect(x: x, y: y, width: w, height: 1); y += 1
        scroll.frame = NSRect(x: x, y: y, width: w, height: threadHeight); y += threadHeight
        bottomRule.frame = NSRect(x: x, y: y, width: w, height: 1); y += 1 + Space.m
        askField.frame = NSRect(x: x, y: y, width: w - Metrics.control - Space.s, height: Metrics.control)
        send.frame = NSRect(x: bounds.width - x - Metrics.control, y: y, width: Metrics.control, height: Metrics.control)
        y += Metrics.control + Space.m
        var bx = x
        for b in [copyButton, saveNote] where !b.isHidden {
            let bw = b.fittedWidth
            b.frame = NSRect(x: bx, y: y, width: bw, height: footerHeight)
            bx += bw + Space.s
        }
        if !stop.isHidden {
            let sw = stop.fittedWidth
            stop.frame = NSRect(x: bounds.width - x - sw, y: y, width: sw, height: footerHeight)
        }
    }
}
