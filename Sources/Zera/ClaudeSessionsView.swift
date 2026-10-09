import AppKit

// MARK: - Claude Sessions
//
//  ┌──────── Sessions (≈48%) ────────┐  ┌──────────── Active session (≈52%) ────────────┐
//  │ [✳] Claude Sessions  ╭bubble╮(Z)│  │ [>_] Task title ● Running 3m 24s  [Stop][•••] │
//  │     Manage and monitor… [+ New] │  │      ~/Projects/zera · branch                 │
//  │ [All 6|Running 3|…]  [🔍 Search]│  │ [Live|Files 12|Changes 5|Tools 3|Timeline]    │
//  │ ┌ row ──────────────────────┐   │  │ ┌ 60%  Analyzing…  ▓▓▓▓░░  elapsed / ETA ┐    │
//  │ │ >_ title     ● Running 3m │   │  │ (Z) ╭ Claude is working on it… ╮          │
//  │ │    path·br   ▓▓▓░ 62% ■ … │   │  │ ┌ console ─────────────────────── ⧉ 🗑 ⤢ ┐    │
//  │ └───────────────────────────┘   │  │ │ > Reading … ✓                          │    │
//  │ …                               │  │ └────────────────────────────────────────┘    │
//  │ (Z) Zera's tip ✨ …          ×  │  │ Current task / Working directory / Model      │
//  └─────────────────────────────────┘  │ [Ask Claude about this session…      ➤ ⌄]    │
//                                       │ [Summarize][Explain][Find issues][Editor]     │
//                                       └───────────────────────────────────────────────┘
//
// Everything is driven by ClaudeActivityService (the same source as the live bar). Numbers are
// only shown when they are real: the percentage needs Claude's own plan (TodoWrite), the ETA
// needs finished plan items; otherwise the bar runs indeterminate.

private enum S {
    static let gap: CGFloat = 14
    static let pad: CGFloat = Metrics.sidePad
    static let radius: CGFloat = 22
    static let rowH: CGFloat = RowTier.rich.height
    static let rowGap: CGFloat = Metrics.rowGap
    static let tipH: CGFloat = 72
    static let maxWidth: CGFloat = 1240
    static let maxHeight: CGFloat = 840
    static let minHeight: CGFloat = 600
    static let singlePaneBelow: CGFloat = 980
    /// The sessions list on its own (what tapping Claude opens).
    static let leftWidth: CGFloat = 560
}

private func shortPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    let parts = p.split(separator: "/")
    return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : p
}

private func sessionTitle(_ s: ClaudeSession) -> String {
    s.title.isEmpty ? "New session in \(s.folderName)" : s.title
}

private func sessionMeta(_ s: ClaudeSession) -> String {
    shortPath(s.cwd) + (s.branch.map { "  ·  \($0)" } ?? "")
}

/// The status pill for a session, in the screen's semantic colours.
private func sessionChip(_ s: ClaudeSession) -> (symbol: String, text: String, color: NSColor) {
    let p = Pal
    if s.stopRequested { return ("stop.circle.fill", "Stopping…", p.warning) }
    switch s.status {
    case .running: return ("play.circle.fill", "Running", p.accent)
    case .waiting: return ("exclamationmark.circle.fill", "Waiting", p.warning)
    case .done: return ("checkmark.circle.fill", "Completed", p.success)
    case .idle: return s.promptAt == nil ? ("moon.zzz.fill", "Idle", p.muted) : ("checkmark.circle.fill", "Completed", p.success)
    case .ended: return ("power.circle.fill", "Ended", p.muted)
    }
}

private enum Bucket: Int { case running = 1, waiting = 2, completed = 3 }
private func bucket(_ s: ClaudeSession) -> Bucket {
    switch s.status {
    case .running: return .running
    case .waiting: return .waiting
    default: return .completed
    }
}

private func icon(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .semibold, _ color: NSColor) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))?
        .withSymbolConfiguration(.init(paletteColors: [color]))
}

private func drawIcon(_ img: NSImage?, centeredIn r: NSRect) {
    guard let img = img else { return }
    let s = img.size
    img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

@MainActor
private func label(_ font: NSFont, _ color: NSColor, lines: Int = 1) -> NSTextField {
    let l = lines == 1 ? NSTextField(labelWithString: "") : NSTextField(wrappingLabelWithString: "")
    l.font = font
    l.textColor = color
    l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    if lines > 1 { l.maximumNumberOfLines = lines }
    return l
}

// MARK: - Glass panel

/// One of the two big rounded panels: blur, the card wash, a hairline edge.
/// A pane inside a screen. The notch island draws the glass, so a pane is just a see-through
/// container that keeps its contents inside it.
final class GlassPanel: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Progress bar

/// Thin rounded bar. Determinate: violet gradient fill with a soft shimmer while running.
/// Indeterminate (`progress == nil`): a short segment glides back and forth — no fake number.
final class SessionProgressBar: NSView {
    private let fill = CAGradientLayer()
    private let shimmer = CAGradientLayer()
    private var progress: Double?
    private var tone: NSColor?
    private var running = false
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        fill.startPoint = CGPoint(x: 0, y: 0.5); fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.masksToBounds = true
        layer?.addSublayer(fill)
        shimmer.startPoint = CGPoint(x: 0, y: 0.5); shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.4).cgColor, NSColor.clear.cgColor]
        shimmer.locations = [0, 0.5, 1]
        fill.addSublayer(shimmer)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `tone` nil = the violet gradient; otherwise a flat semantic colour (amber, green).
    func set(progress p: Double?, tone t: NSColor?, running r: Bool) {
        let changedMode = (p == nil) != (progress == nil) || r != running
        progress = p.map { max(0.02, min(1, $0)) }
        tone = t
        running = r
        let pal = Pal
        if let t = t { fill.colors = [t.cgColor, t.cgColor] }
        else { fill.colors = [pal.accent.cgColor, (pal.accent.blended(withFraction: 0.5, of: pal.accentDeep) ?? pal.accent).cgColor, pal.accentDeep.cgColor] }
        let reduce = Motion.reduced
        if changedMode || fill.animation(forKey: "glide") == nil && progress == nil && running {
            fill.removeAllAnimations(); shimmer.removeAllAnimations()
            if running, !reduce {
                if progress == nil {
                    let a = CABasicAnimation(keyPath: "position.x")
                    a.fromValue = -bounds.width * 0.2; a.toValue = bounds.width * 1.2
                    a.duration = 1.6; a.repeatCount = .infinity
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    fill.add(a, forKey: "glide")
                } else {
                    let a = CABasicAnimation(keyPath: "locations")
                    a.fromValue = [-1.0, -0.5, 0.0]; a.toValue = [1.0, 1.5, 2.0]
                    a.duration = 1.8; a.repeatCount = .infinity
                    shimmer.add(a, forKey: "sweep")
                }
            }
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduce ? 0 : 0.45)
        place()
        CATransaction.commit()
        needsDisplay = true
    }

    private func place() {
        let w = bounds.width, h = bounds.height
        fill.cornerRadius = h / 2
        if let p = progress {
            fill.frame = CGRect(x: 0, y: 0, width: max(h, w * CGFloat(p)), height: h)
        } else {
            let sw = max(h * 4, w * 0.28)
            fill.frame = CGRect(x: running ? -sw : 0, y: 0, width: running ? sw : 0, height: h)
            if running { fill.position = CGPoint(x: w / 2, y: h / 2) }
        }
        shimmer.frame = fill.bounds
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); place(); CATransaction.commit()
        // The glide distance depends on the width.
        if progress == nil, running, !Motion.reduced { fill.removeAnimation(forKey: "glide"); set(progress: nil, tone: tone, running: true) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Neon.track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

// MARK: - Session icon

/// Dark rounded tile with a terminal / branch / chat glyph, tinted by state.
final class SessionIconTile: NSView {
    var symbol = "terminal" { didSet { needsDisplay = true } }
    var tint: NSColor = .white { didSet { needsDisplay = true } }
    /// v2: draw as a progress ring (0…1) instead of a tile; `ringText` replaces the glyph.
    var ring: Double? { didSet { needsDisplay = true } }
    var ringText: String? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    static func symbol(for s: ClaudeSession) -> String {
        let t = (s.fullPrompt.isEmpty ? s.title : s.fullPrompt).lowercased()
        if t.contains("review") || t.contains("pull request") { return "bubble.left.and.bubble.right" }
        if t.contains("git") || t.contains("branch") || t.contains("merge") { return "arrow.triangle.branch" }
        return "terminal"
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        if let progress = ring {
            let d = min(bounds.width, bounds.height) - 6
            let c = NSPoint(x: bounds.midX, y: bounds.midY)
            let track = NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            track.lineWidth = 3
            p.text.withAlphaComponent(0.1).setStroke(); track.stroke()
            let v = max(0, min(1, progress))
            if v > 0.005 {
                let arc = NSBezierPath()
                // Flipped view: clockwise from twelve o'clock.
                arc.appendArc(withCenter: c, radius: d / 2, startAngle: -90, endAngle: -90 + 360 * v, clockwise: false)
                arc.lineWidth = 3; arc.lineCapStyle = .round
                tint.setStroke(); arc.stroke()
            }
            if let t = ringText, !t.isEmpty {
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: t.count > 2 ? 10 : 11, weight: .bold), .foregroundColor: p.text]
                let sz = (t as NSString).size(withAttributes: a)
                (t as NSString).draw(at: NSPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: a)
            } else {
                drawIcon(icon(symbol, bounds.width * 0.3, .semibold, tint), centeredIn: bounds)
            }
            return
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.width * 0.26, yRadius: bounds.width * 0.26)
        (p.isDark ? p.surfaceStrong : p.tileGitHub).setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke(); path.lineWidth = 1; path.stroke()
        drawIcon(icon(symbol, bounds.width * 0.38, .semibold, tint), centeredIn: bounds)
    }
}

// MARK: - Session row

final class ClaudeSessionRow: NSView {
    let sessionID: String
    var onSelect: (() -> Void)?
    var onStop: (() -> Void)?
    var onReview: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var selected = false { didSet { if selected != oldValue { restyle() } } }

    private let tile = SessionIconTile()
    private let title = label(Typo.rowTitleStrong, Pal.text)
    private let meta = label(NSFont.systemFont(ofSize: 12), Pal.textSecondary)
    private let chip = PRStatusChip()
    private let time = label(NSFont.systemFont(ofSize: 12, weight: .medium), Pal.textSecondary)
    private let bar = SessionProgressBar()
    private let percent = label(NSFont.systemFont(ofSize: 12, weight: .semibold), Pal.text)
    private let note = label(NSFont.systemFont(ofSize: 12, weight: .medium), Pal.textSecondary)
    private var action: PRActionButton!
    private var more: GHSquareButton!
    private var kind: Bucket = .running
    private var hovered = false { didSet { if hovered != oldValue { restyle() } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(sessionID: String) {
        self.sessionID = sessionID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        action = PRActionButton("", style: .destructive, symbol: "stop.fill", target: self, action: #selector(actionTapped))
        more = GHSquareButton(symbol: "ellipsis", label: "More", target: self, action: #selector(moreTapped))
        percent.alignment = .right
        [tile, title, meta, chip, time, bar, percent, note, action, more].forEach { addSubview($0) }
        setAccessibilityRole(.button)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func actionTapped() { kind == .waiting ? onReview?() : onStop?() }
    @objc private func moreTapped() { onMenu?(more) }

    func update(_ s: ClaudeSession) {
        let p = Pal
        kind = bucket(s)
        tile.symbol = SessionIconTile.symbol(for: s)
        tile.tint = kind == .running ? p.accent : (kind == .waiting ? p.warning : p.success)
        // v2: the tile is the session's ring — progress while it runs, full when it's done.
        switch kind {
        case .running:
            tile.ring = s.hasRealProgress ? s.progress : 0.08
            tile.ringText = s.hasRealProgress ? "\(Int((s.progress * 100).rounded()))" : nil
        case .waiting: tile.ring = 0; tile.ringText = nil; tile.symbol = "hand.raised.fill"
        case .completed: tile.ring = 1; tile.ringText = nil; tile.symbol = "checkmark"
        }
        title.stringValue = sessionTitle(s)
        title.toolTip = s.fullPrompt.isEmpty ? nil : s.fullPrompt
        title.textColor = kind == .completed && !selected ? p.text(0.85) : p.text
        meta.stringValue = sessionMeta(s)
        let c = sessionChip(s)
        chip.set(symbol: c.symbol, text: c.text, color: c.color)
        switch kind {
        case .running:
            time.stringValue = ClaudeActivityCard.clock(s.elapsed)
            bar.isHidden = false
            bar.set(progress: s.hasRealProgress ? s.progress : nil, tone: nil, running: !s.stopRequested)
            percent.stringValue = s.hasRealProgress ? "\(Int((s.progress * 100).rounded()))%" : ""
            note.isHidden = true
            action.isHidden = s.stopRequested
            action.style = .destructive
            action.setSymbol("stop.fill")
            action.toolTip = "Stop — Claude halts at its next step"
        case .waiting:
            time.stringValue = "On hold"
            bar.isHidden = true
            percent.stringValue = ""
            note.isHidden = false
            note.stringValue = "Waiting for your approval…"
            note.textColor = p.warning
            action.isHidden = false
            action.style = .warning
            action.setSymbol("eye.fill")
            action.toolTip = "Review the approval"
        case .completed:
            time.stringValue = relativeTime(s.lastEventAt)
            bar.isHidden = true
            percent.stringValue = ""
            note.isHidden = s.promptAt == nil
            let n = s.filesChanged.count
            note.stringValue = n > 0 ? "✓  Updated \(n) file\(n == 1 ? "" : "s")" : "✓  No file changes"
            note.textColor = p.textSecondary
            action.isHidden = true
        }
        action.setTitleText("")
        action.setAccessibilityLabel(kind == .waiting ? "Review approval" : "Stop session")
        setAccessibilityLabel("\(title.stringValue), \(c.text), \(time.stringValue)")
        needsLayout = true
    }

    /// The shared selected look (accent wash and edge, drawn in `draw`). No glow: inside the
    /// list's scroll view a glow is clipped to a hard box around the row.
    private func restyle() { needsDisplay = true }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let mid = (h / 2).rounded()
        let ts = RowTier.rich.tile
        tile.frame = NSRect(x: 14, y: mid - ts / 2, width: ts, height: ts)
        more.frame = NSRect(x: w - 14 - 34, y: mid - 17, width: 34, height: 34)
        action.frame = NSRect(x: more.frame.minX - 8 - 34, y: mid - 17, width: 34, height: 34)
        // Without a stop / review button the status column moves up against the menu button.
        let actionsLeft = action.isHidden ? more.frame.minX : action.frame.minX
        // Chip and time side by side; the column grows so the time is never cut off.
        let cw = min(112, chip.fittedWidth)
        let timeW = ceil(time.attributedStringValue.size().width) + 4
        let statusW = max(128, cw + 8 + timeW)
        let sx = actionsLeft - 14 - statusW

        // Title and folder, plus a third line (progress or a note) when there is one, centred
        // as a block on the row so the text lines up with the tile and the buttons.
        // Title (18) and folder (16) are one block; a progress bar or a note adds a third line.
        // The block is centred on the row, so the space above and below it is the same.
        let running = kind == .running && !bar.isHidden, waiting = kind == .waiting
        // Split up so the type checker stays quick (CI's compiler gave up on the one-liner).
        let third: CGFloat = running ? 14 : (waiting ? 19 : 0)
        let block: CGFloat = 37 + third
        let top = (mid - block / 2).rounded()
        let tx: CGFloat = tile.frame.maxX + 12, tw = max(60, sx - 12 - tx)
        title.frame = NSRect(x: tx, y: top - 1, width: tw, height: 20)
        meta.frame = NSRect(x: tx, y: top + 21, width: tw, height: 16)
        // The chip sits on the title's line (two-line rows: on the row's middle); completed rows
        // put the note under it.
        let chipY: CGFloat
        if kind == .completed && !note.isHidden { chipY = (mid - 23).rounded() }
        else if running || waiting { chipY = top - 3 }
        else { chipY = mid - 12 }
        chip.frame = NSRect(x: sx, y: chipY, width: cw, height: 24)
        time.frame = NSRect(x: chip.frame.maxX + 8, y: chipY + 4, width: max(0, sx + statusW - chip.frame.maxX - 8), height: 16)
        switch kind {
        case .running:
            let pw: CGFloat = percent.stringValue.isEmpty ? 0 : 40
            let barRight = actionsLeft - 14 - pw
            bar.frame = NSRect(x: tx, y: top + 45, width: max(40, barRight - tx), height: 6)
            percent.frame = NSRect(x: barRight + 4, y: top + 40, width: pw - 4, height: 16)
        case .waiting:
            note.frame = NSRect(x: tx, y: top + 40, width: actionsLeft - 14 - tx, height: 16)
        case .completed:
            note.frame = NSRect(x: sx, y: chip.frame.maxY + 6, width: statusW, height: 16)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: Radius.l, yRadius: Radius.l)
        (hovered ? p.surfaceHover : p.surfaceRow).setFill(); path.fill()
        if selected { p.selectedFill.setFill(); path.fill() }
        (selected ? p.selectedEdge : p.divider).setStroke()
        path.lineWidth = 1
        path.stroke()
        // v2: a status stripe down the left edge — accent running, amber waiting, green done.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let tone = kind == .running ? p.accent : (kind == .waiting ? p.warning : p.success)
        tone.withAlphaComponent(kind == .completed ? 0.7 : 1).setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Live progress card

/// "60%  Analyzing files…  ▓▓▓▓░░  3m 24s elapsed / ETA ~ 1m 30s". The big number appears only
/// with a real plan; otherwise a state glyph sits in its place and the bar is indeterminate.
final class ClaudeSessionProgress: NSView {
    private let big = label(NSFont.systemFont(ofSize: 28, weight: .bold), Pal.text)
    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()
    private let stage = label(NSFont.systemFont(ofSize: 14, weight: .semibold), Pal.text)
    private let bar = SessionProgressBar()
    private let elapsed = label(NSFont.systemFont(ofSize: 12), Pal.textSecondary)
    private let eta = label(NSFont.systemFont(ofSize: 12), Pal.textSecondary)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        big.alignment = .center
        elapsed.alignment = .right
        eta.alignment = .right
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        [big, glyph, spinner, stage, bar, elapsed, eta].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ s: ClaudeSession) {
        let p = Pal
        let real = s.hasRealProgress
        big.isHidden = !real
        big.stringValue = "\(Int((s.progress * 100).rounded()))%"
        let running = s.status == .running && !s.stopRequested
        if !real && running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        glyph.isHidden = real || running
        switch s.status {
        case .waiting: glyph.image = icon("hand.raised.fill", 24, .semibold, p.warning)
        case .done: glyph.image = icon("checkmark.circle.fill", 26, .semibold, p.success)
        default: glyph.image = icon(s.stopRequested ? "stop.circle.fill" : "moon.zzz.fill", 24, .semibold, s.stopRequested ? p.warning : p.muted)
        }

        if s.stopRequested { stage.stringValue = "Stopping at Claude's next step…" }
        else {
            switch s.status {
            case .running:
                if let a = s.plan.first(where: { $0.state == .active }) { stage.stringValue = a.title + "…" }
                else if let c = s.currentStep { stage.stringValue = "\(c.text)…" }
                else { stage.stringValue = "Thinking…" }
            case .waiting: stage.stringValue = "Waiting for your approval"
            case .done: stage.stringValue = "Finished in \(ClaudeActivityCard.clock(s.elapsed))"
            case .idle: stage.stringValue = s.promptAt == nil ? "Ready for a prompt" : "Finished in \(ClaudeActivityCard.clock(s.elapsed))"
            case .ended: stage.stringValue = "Session ended"
            }
        }
        stage.toolTip = stage.stringValue
        let tone: NSColor? = s.status == .waiting || s.stopRequested ? p.warning : (s.status == .done ? p.success : nil)
        var value: Double? = s.progress
        if !real {
            if s.status == .running { value = nil }
            else if s.status == .waiting { value = 1 }
            else { value = s.promptAt == nil ? 0 : 1 }
        }
        bar.set(progress: value, tone: tone, running: running)
        elapsed.stringValue = s.promptAt == nil ? "" : "\(ClaudeActivityCard.clock(s.elapsed)) elapsed"
        eta.stringValue = s.eta.map { "ETA ~ \(ClaudeActivityCard.clock($0))" } ?? ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let leftW: CGFloat = 88
        big.frame = NSRect(x: 8, y: (h - 34) / 2, width: leftW - 8, height: 34)
        glyph.frame = NSRect(x: 8, y: (h - 32) / 2, width: leftW - 8, height: 32)
        spinner.frame = NSRect(x: 8 + (leftW - 8 - 24) / 2, y: (h - 24) / 2, width: 24, height: 24)
        let rightW: CGFloat = 132
        elapsed.frame = NSRect(x: w - 16 - rightW, y: 18, width: rightW, height: 16)
        eta.frame = NSRect(x: w - 16 - rightW, y: 42, width: rightW, height: 16)
        let x = leftW + 8
        stage.frame = NSRect(x: x, y: 16, width: w - 16 - rightW - 12 - x, height: 19)
        bar.frame = NSRect(x: x, y: 46, width: w - 16 - rightW - 12 - x, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l, yRadius: Radius.l)
        p.surfaceRow.setFill(); path.fill()
        p.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

// MARK: - Zera's reaction

/// Zera beside a bubble card saying what Claude is up to, in her own pose for the state.
final class ZeraSessionReaction: NSView {
    private let figure = NSImageView()
    private let bubble = FlippedView()
    private let title = label(NSFont.systemFont(ofSize: 14.5, weight: .semibold), Pal.text)
    private let detail = label(NSFont.systemFont(ofSize: 12.5), Pal.textSecondary, lines: 2)
    override var isFlipped: Bool { true }
    static let figureSize: CGFloat = 84

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
        bubble.layer?.borderColor = p.accentBorder.withAlphaComponent(0.3).cgColor
        addSubview(bubble)
        bubble.addSubview(title)
        bubble.addSubview(detail)
        addSubview(figure)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// What she says: from the kinds of work Claude has done so far.
    private static func doing(_ s: ClaudeSession) -> String {
        var seen: [String] = []
        for st in s.steps {
            let phrase: String?
            switch st.kind {
            case .read: phrase = "reading files"
            case .search: phrase = "searching the code"
            case .edit: phrase = "making changes"
            case .run: phrase = "running commands"
            case .fetch: phrase = "looking things up"
            case .delegate: phrase = "handing off subtasks"
            default: phrase = nil
            }
            if let ph = phrase, !seen.contains(ph) { seen.append(ph) }
        }
        guard !seen.isEmpty else { return "Thinking through your request." }
        let list = seen.count == 1 ? seen[0] : seen.dropLast().joined(separator: ", ") + " and " + seen.last!
        return list.prefix(1).uppercased() + list.dropFirst() + "."
    }

    func update(_ s: ClaudeSession, pendingCommand: String?) {
        let pose: String
        if s.stopRequested {
            pose = "surprised"; title.stringValue = "Stopping…"; detail.stringValue = "Claude will stop before its next step and tell you where it got to."
        } else {
            switch s.status {
            case .running:
                pose = s.steps.isEmpty ? "thinking" : "typing"
                title.stringValue = "Claude is working on it…"
                detail.stringValue = Self.doing(s)
            case .waiting:
                pose = "card_bell"
                title.stringValue = "Claude needs your OK 🙋"
                detail.stringValue = pendingCommand.map { "Wants to run: \(ClaudeActivityService.oneLine($0, max: 90))" } ?? "Review the request to let it continue."
            case .done:
                pose = "celebrate"
                let n = s.filesChanged.count
                title.stringValue = "All done! 🎉"
                detail.stringValue = n > 0 ? "Changed \(n) file\(n == 1 ? "" : "s") in \(ClaudeActivityCard.clock(s.elapsed))." : "Finished in \(ClaudeActivityCard.clock(s.elapsed)) — no files changed."
            case .idle:
                pose = s.promptAt == nil ? "idle" : "cheerful"
                title.stringValue = s.promptAt == nil ? "Ready when you are" : "Done — ready for more"
                detail.stringValue = "Send Claude a prompt and I'll follow along."
            case .ended:
                pose = "sleepy"
                title.stringValue = "Session ended"
                detail.stringValue = "Start a new one any time with New Session."
            }
        }
        figure.image = SpriteLibrary.shared.sprite(pose)?.image ?? SpriteLibrary.shared.sprite("idle")?.image
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, fs = Self.figureSize
        figure.frame = NSRect(x: 0, y: h - fs, width: fs, height: fs)
        let bx = fs + 4
        let bw = min(bounds.width - bx, 520)
        bubble.frame = NSRect(x: bx, y: (h - 64) / 2, width: bw, height: 64)
        title.frame = NSRect(x: 16, y: 11, width: bw - 32, height: 19)
        detail.frame = NSRect(x: 16, y: 31, width: bw - 32, height: 30)
    }
}

// MARK: - Activity console

/// Dark monospace log of Claude's steps: done lines get a green ✓, the current one a soft
/// highlight and a live timer. Copy, clear (hides what's there now) and expand.
final class ClaudeActivityConsole: NSView {
    struct Line { let verb: String; let target: String; let fileLike: Bool; let state: State; let duration: TimeInterval? }
    enum State { case done, active, waiting }
    var onExpand: (() -> Void)?
    private(set) var lines: [Line] = []
    private var clearedAt: Date?
    private var copyButton: GHSquareButton!
    private var clearButton: GHSquareButton!
    private var expandButton: GHSquareButton!
    var expanded = false { didSet { expandButton.toolTip = expanded ? "Collapse" : "Expand" } }
    override var isFlipped: Bool { true }
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let lineH: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        copyButton = GHSquareButton(symbol: "doc.on.doc", label: "Copy log", target: self, action: #selector(copyTapped))
        clearButton = GHSquareButton(symbol: "trash", label: "Clear", target: self, action: #selector(clearTapped))
        expandButton = GHSquareButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Expand", target: self, action: #selector(expandTapped))
        [copyButton!, clearButton!, expandButton!].forEach { addSubview($0) }
        setAccessibilityRole(.list)
        setAccessibilityLabel("Claude activity")
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ s: ClaudeSession) {
        let steps = s.steps.filter { st in st.kind != .prompt && clearedAt.map { st.at > $0 } ?? true }
        lines = steps.map { st in
            let state: State = st.kind == .waiting && !st.finished ? .waiting : (st.finished ? .done : .active)
            let dur = st.duration ?? (st.finished ? nil : Date().timeIntervalSince(st.at))
            return Line(verb: st.verb, target: st.target, fileLike: st.kind == .read || st.kind == .edit, state: state, duration: dur)
        }
        needsDisplay = true
    }

    /// New session selected: the clear applies to one session only.
    func resetClear() { clearedAt = nil }

    @objc private func copyTapped() {
        let text = lines.map { "> \($0.verb) \($0.target)" + ($0.state == .done ? " ✓" : "") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func clearTapped() { clearedAt = Date(); lines = []; needsDisplay = true }
    @objc private func expandTapped() { onExpand?() }

    override func layout() {
        super.layout()
        let w = bounds.width
        expandButton.frame = NSRect(x: w - 10 - 28, y: 10, width: 28, height: 28)
        clearButton.frame = NSRect(x: expandButton.frame.minX - 6 - 28, y: 10, width: 28, height: 28)
        copyButton.frame = NSRect(x: clearButton.frame.minX - 6 - 28, y: 10, width: 28, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l, yRadius: Radius.l)
        (p.isDark ? p.codeBox.withAlphaComponent(0.85) : p.codeBox).setFill(); box.fill()
        p.border.setStroke(); box.lineWidth = 1; box.stroke()

        let textColor = p.text.withAlphaComponent(0.9)
        let dim = textColor.withAlphaComponent(0.55)
        let fileColor = p.info
        let x0: CGFloat = 18, top: CGFloat = 16
        let rightLimit = copyButton.frame.minX - 10
        guard !lines.isEmpty else {
            ("> Waiting for Claude's first step…" as NSString).draw(at: NSPoint(x: x0, y: top), withAttributes: [.font: Self.font, .foregroundColor: dim])
            return
        }
        let fit = max(1, Int((bounds.height - top - 10) / Self.lineH))
        let shown = lines.suffix(fit)
        var y = top
        for (i, l) in shown.enumerated() {
            // The first line shares its row with the buttons, so it stops short of them.
            let maxX = i == 0 ? rightLimit : bounds.width - 16
            if l.state != .done {
                let band = NSRect(x: 8, y: y - 3, width: bounds.width - 16, height: Self.lineH)
                (l.state == .waiting ? p.warning : p.accent).withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
            }
            let lineColor: NSColor = l.state == .active ? (p.accent.blended(withFraction: 0.35, of: .white) ?? p.accent) : (l.state == .waiting ? p.warning : textColor)
            let s = NSMutableAttributedString(string: "> ", attributes: [.font: Self.font, .foregroundColor: dim])
            s.append(NSAttributedString(string: l.verb + (l.target.isEmpty ? "" : " "), attributes: [.font: Self.font, .foregroundColor: lineColor]))
            s.append(NSAttributedString(string: l.target, attributes: [.font: Self.font, .foregroundColor: l.fileLike && l.state == .done ? fileColor : lineColor]))
            if l.state != .done { s.append(NSAttributedString(string: "…", attributes: [.font: Self.font, .foregroundColor: lineColor])) }
            // Trailing: live timer on the current line, ✓ on finished ones.
            var trailingW: CGFloat = 0
            if l.state != .done, let d = l.duration {
                let t = String(format: "%.1fs", d) as NSString
                let ta: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: lineColor]
                let tw = ceil(t.size(withAttributes: ta).width)
                t.draw(at: NSPoint(x: maxX - tw - 4, y: y), withAttributes: ta)
                trailingW = tw + 16
            }
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
            let checkW: CGFloat = l.state == .done ? 18 : 0
            let textW = min(ceil(s.size().width) + 2, maxX - x0 - trailingW - checkW)
            s.draw(in: NSRect(x: x0, y: y, width: max(0, textW), height: Self.lineH))
            if l.state == .done { drawIcon(icon("checkmark", 10, .bold, p.success), centeredIn: NSRect(x: x0 + textW + 2, y: y, width: 14, height: 16)) }
            y += Self.lineH
        }
    }
}

// MARK: - Task details

/// Current task / working directory / model as aligned key-value rows.
final class ClaudeTaskDetails: NSView {
    private struct Row { let icon: NSImageView; let key: NSTextField; let value: NSTextField }
    private var rows: [Row] = []
    override var isFlipped: Bool { true }
    static let rowH: CGFloat = 42
    static var height: CGFloat { rowH * 3 + 8 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let p = Pal
        for (sym, key) in [("doc.text", "Current Task"), ("folder.fill", "Working Directory"), ("cpu", "Model")] {
            let iv = NSImageView(); iv.image = icon(sym, 14, .medium, p.textSecondary)
            let k = label(NSFont.systemFont(ofSize: 13, weight: .semibold), p.text); k.stringValue = key
            let v = label(NSFont.systemFont(ofSize: 13), p.text(0.85))
            [iv, k, v].forEach { addSubview($0) }
            rows.append(Row(icon: iv, key: k, value: v))
        }
        rows[1].value.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        rows[1].value.lineBreakMode = .byTruncatingHead
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ s: ClaudeSession) {
        let p = Pal
        let task = s.fullPrompt.isEmpty ? "No prompt yet" : ClaudeActivityService.oneLine(s.fullPrompt, max: 200)
        rows[0].value.stringValue = task
        rows[0].value.toolTip = s.fullPrompt.isEmpty ? nil : s.fullPrompt
        let home = NSHomeDirectory()
        rows[1].value.stringValue = s.cwd.hasPrefix(home) ? "~" + s.cwd.dropFirst(home.count) : s.cwd
        rows[1].value.toolTip = s.cwd
        rows[1].value.textColor = p.accent.blended(withFraction: 0.3, of: p.text) ?? p.accent
        rows[2].value.stringValue = s.modelName ?? "Claude Code"
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let keyX: CGFloat = 46, valX: CGFloat = 196
        for (i, r) in rows.enumerated() {
            let y = 4 + CGFloat(i) * Self.rowH
            r.icon.frame = NSRect(x: 16, y: y + (Self.rowH - 18) / 2, width: 18, height: 18)
            r.key.frame = NSRect(x: keyX, y: y + (Self.rowH - 17) / 2, width: valX - keyX - 8, height: 17)
            r.value.frame = NSRect(x: valX, y: y + (Self.rowH - 17) / 2, width: w - valX - 16, height: 17)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l, yRadius: Radius.l)
        p.surfaceRow.setFill(); path.fill()
        p.border.setStroke(); path.lineWidth = 1; path.stroke()
        p.divider.setFill()
        for i in 1..<3 { NSRect(x: 16, y: 4 + CGFloat(i) * Self.rowH, width: bounds.width - 32, height: 1).fill() }
    }
}

// MARK: - Follow-up input

/// "Ask Claude about this session…" with send and a menu of ready-made questions.
final class ClaudeFollowUpInput: NSView {
    var onSend: ((String) -> Void)?
    var onMenu: ((NSView) -> Void)?
    let field = NSTextField()
    private var send: GHSquareButton!
    private var chevron: GHSquareButton!
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let p = Pal
        wantsLayer = true
        layer?.cornerRadius = Radius.l
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = p.surfaceRow.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.accentBorder.withAlphaComponent(0.35).cgColor
        let c = PaddedTextCell(textCell: "")
        c.padding = 0
        c.isEditable = true; c.isSelectable = true; c.isScrollable = true; c.wraps = false
        c.placeholderAttributedString = NSAttributedString(string: "Ask Claude about this session…",
                                                           attributes: [.foregroundColor: p.textTertiary, .font: NSFont.systemFont(ofSize: 13.5)])
        field.cell = c
        field.font = NSFont.systemFont(ofSize: 13.5)
        field.textColor = p.text
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.focusRingType = .none
        field.target = self
        field.action = #selector(sendTapped)
        field.setAccessibilityLabel("Ask Claude about this session")
        addSubview(field)
        send = GHSquareButton(symbol: "paperplane.fill", label: "Send", target: self, action: #selector(sendTapped))
        chevron = GHSquareButton(symbol: "chevron.down", label: "Suggestions", target: self, action: #selector(menuTapped))
        addSubview(send)
        addSubview(chevron)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setPlaceholder(_ text: String) {
        (field.cell as? NSTextFieldCell)?.placeholderAttributedString = NSAttributedString(
            string: text, attributes: [.foregroundColor: Pal.textTertiary, .font: NSFont.systemFont(ofSize: 13.5)])
        field.setAccessibilityLabel(text)
    }

    @objc private func sendTapped() {
        let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        field.stringValue = ""
        onSend?(q)
    }
    @objc private func menuTapped() { onMenu?(chevron) }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        chevron.frame = NSRect(x: w - 8 - 30, y: (h - 30) / 2, width: 30, height: 30)
        send.frame = NSRect(x: chevron.frame.minX - 6 - 32, y: (h - 32) / 2, width: 32, height: 32)
        field.frame = NSRect(x: 16, y: (h - 20) / 2, width: send.frame.minX - 12 - 16, height: 20)
    }
}

// MARK: - Zera's tip

final class ZeraSessionTip: NSView {
    var onClose: (() -> Void)?
    private let title = label(NSFont.systemFont(ofSize: 14, weight: .semibold), Pal.text)
    private let body = label(NSFont.systemFont(ofSize: 12.5), Pal.textSecondary, lines: 2)
    private var close: GHSquareButton!
    override var isFlipped: Bool { true }
    /// Zera stands just outside this view (left), so her head can rise over the top edge.
    static let zeraRoom: CGFloat = 104

    override init(frame: NSRect) {
        super.init(frame: frame)
        close = GHSquareButton(symbol: "xmark", label: "Dismiss tip", target: self, action: #selector(closeTapped))
        [title, body, close!].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, body b: String) {
        title.stringValue = t
        body.stringValue = b
        setAccessibilityLabel("\(t). \(b)")
    }

    @objc private func closeTapped() { onClose?() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        close.frame = NSRect(x: w - 12 - 28, y: 12, width: 28, height: 28)
        let x = Self.zeraRoom
        title.frame = NSRect(x: x, y: 13, width: close.frame.minX - 8 - x, height: 19)
        body.frame = NSRect(x: x, y: 34, width: w - 16 - x, height: h - 34 - 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.l + 2, yRadius: Radius.l + 2)
        NSGradient(starting: p.accentSoft.withAlphaComponent(p.isDark ? 0.55 : 0.6), ending: p.surfaceElevated)?.draw(in: path, angle: 0)
        p.accentBorder.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

// MARK: - Info row (Files / Changes / Tools / Timeline)

final class SessionInfoRow: NSView {
    private let symbol: String
    private let tint: NSColor
    private let title: String
    private let subtitle: String
    private let trailing: String
    override var isFlipped: Bool { true }
    static let height: CGFloat = 46

    init(symbol: String, tint: NSColor, title: String, subtitle: String, trailing: String) {
        self.symbol = symbol; self.tint = tint; self.title = title; self.subtitle = subtitle; self.trailing = trailing
        super.init(frame: .zero)
        toolTip = subtitle.isEmpty ? title : "\(title)\n\(subtitle)"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.m + 2, yRadius: Radius.m + 2)
        p.surfaceRow.setFill(); path.fill()
        p.border.setStroke(); path.lineWidth = 1; path.stroke()
        let tile = NSRect(x: 10, y: (bounds.height - 28) / 2, width: 28, height: 28)
        tint.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8).fill()
        drawIcon(icon(symbol, 12, .semibold, tint), centeredIn: tile)
        let tf = NSFont.systemFont(ofSize: 13, weight: .semibold), sf = NSFont.systemFont(ofSize: 11.5), trf = NSFont.systemFont(ofSize: 12, weight: .medium)
        let tra: [NSAttributedString.Key: Any] = [.font: trf, .foregroundColor: p.textSecondary]
        let trW = trailing.isEmpty ? 0 : ceil((trailing as NSString).size(withAttributes: tra).width)
        (trailing as NSString).draw(at: NSPoint(x: bounds.width - 14 - trW, y: (bounds.height - 16) / 2), withAttributes: tra)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingMiddle
        let textW = bounds.width - 50 - 14 - (trW > 0 ? trW + 12 : 0)
        let ty: CGFloat = subtitle.isEmpty ? (bounds.height - 17) / 2 : 7
        (title as NSString).draw(in: NSRect(x: 50, y: ty, width: textW, height: 17), withAttributes: [.font: tf, .foregroundColor: p.text, .paragraphStyle: para])
        if !subtitle.isEmpty {
            (subtitle as NSString).draw(in: NSRect(x: 50, y: 25, width: textW, height: 15), withAttributes: [.font: sf, .foregroundColor: p.textTertiary, .paragraphStyle: para])
        }
    }
}

// MARK: - The screen

final class ClaudeSessionsView: NSView, CardContent, NSTextFieldDelegate {
    var onHeightChange: (() -> Void)?
    var onEscape: (() -> Void)?
    var say: ((String, ZeraMood) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Explicit only: opens Claude Code (desktop app, or Terminal running `claude`).
    var onNewSession: (() -> Void)?
    /// Opens Zera's approval card for a waiting request.
    var onReviewApproval: (() -> Void)?
    /// Hand Zera a session brief and a question about it.
    var onAsk: ((URL, String) -> Void)?

    // Filters survive the view being rebuilt (theme change).
    private static var filter = 0
    private static var query = ""
    private static let tipKey = "zera.sessions.tipDismissed"

    private let left = GlassPanel()
    private let right = GlassPanel()

    // Left
    private let claudeTile = ScreenIconTile.claude()
    private let leftTitle = label(Typo.screenTitle, Pal.text)
    private let leftSub = label(Typo.screenSubtitle, Pal.textSecondary)
    private let peek = NSImageView()
    private let bubble = ZeraGitHubBubble()
    private var newSession: PRActionButton!
    private let filters = GitHubSegmentedControl(items: [])
    private let search = SearchBox(placeholder: "Search sessions…")
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var rows: [String: ClaudeSessionRow] = [:]
    private var order: [String] = []
    private let leftState = GHStateView()
    private let tip = ZeraSessionTip()
    private let tipZera = NSImageView()

    // Right
    private var back: GHSquareButton!
    private let sessionTile = SessionIconTile()
    private let sessionTitleLabel = label(NSFont.systemFont(ofSize: 16, weight: .semibold), Pal.text)
    private let sessionChipView = PRStatusChip()
    private let sessionElapsed = label(NSFont.systemFont(ofSize: 13, weight: .medium), Pal.textSecondary)
    private let sessionMetaLabel = label(NSFont.systemFont(ofSize: 12.5), Pal.textSecondary)
    private var primary: PRActionButton!
    private var primaryKind = 0   // 0 stop · 1 review approval · 2 new session · -1 hidden
    private var sessionMore: GHSquareButton!
    private var collapse: GHSquareButton!
    private let tabs = GitHubSegmentedControl(items: [])
    private var tab = 0
    private let progressCard = ClaudeSessionProgress()
    private let reaction = ZeraSessionReaction()
    private let console = ClaudeActivityConsole()
    private var consoleExpanded = false
    private let infoScroll = NSScrollView()
    private let infoList = FlippedView()
    private var infoSignature = ""
    private let details = ClaudeTaskDetails()
    private let input = ClaudeFollowUpInput()
    private var quick: [PRActionButton] = []
    private let rightState = GHStateView()

    private var leftStateKey = ""
    private var rightStateKey = ""
    private var selectedID: String?
    private var showingDetail = false     // single-pane mode: the right panel replaces the list
    private var ticker: Timer?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var svc: ClaudeActivityService { ClaudeActivityService.shared }

    // MARK: Size

    private var screen: NSRect { (window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875) }
    /// Collapsed: just the sessions list. Expanded: the selected session's live view joins it —
    /// when you tap a session, or open this screen from the live bar.
    private(set) var expanded = false
    private var fullWidth: CGFloat { min(S.maxWidth, screen.width - 40) }
    /// One compact island width for the list and the session.
    var cardWidth: CGFloat { min(Isle.lensWidth, fullWidth) }
    var desiredHeight: CGFloat {
        // Session: header, tabs, progress, console, ask, quick asks.
        guard !expanded else { return Isle.maxContentHeight }
        // List: header, filters, up to four sessions (more scroll).
        let rows = CGFloat(max(1, min(4, order.count)))
        let list = order.isEmpty ? 190 : rows * (S.rowH + S.rowGap) - S.rowGap
        return Isle.headerHeight + 40 + 12 + list + 18
    }
    /// In the island the session always replaces the list (with a back button).
    private var singlePane: Bool { true }

    func setExpanded(_ on: Bool) {
        guard on != expanded else { return }
        expanded = on
        showingDetail = on && singlePane
        reload()
        layoutSubtreeIfNeeded()
        onHeightChange?()
        // The session comes in like a page; Back slides the list back in from the left.
        Motion.open(on ? right : left, forward: on)
    }

    /// Each time the screen opens: just the list, unless it was opened from the live bar.
    func willShow(expanded open: Bool) {
        expanded = open && selected != nil
        showingDetail = expanded && singlePane
        reload()
    }

    // MARK: Init

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
        let p = Pal
        addSubview(left)
        addSubview(right)

        // Left header.
        left.addSubview(claudeTile)
        leftTitle.stringValue = "Claude sessions"
        left.addSubview(leftTitle)
        left.addSubview(leftSub)
        peek.imageScaling = .scaleProportionallyUpOrDown
        peek.imageAlignment = .alignBottom
        peek.image = SpriteLibrary.shared.sprite("card_peek_down")?.image ?? SpriteLibrary.shared.sprite("peek")?.image
        left.addSubview(peek)                // behind the button: she peeks over it
        bubble.tailRight = true
        left.addSubview(bubble)
        newSession = PRActionButton("New", style: .primary, symbol: "plus", target: self, action: #selector(newSessionTapped))
        left.addSubview(newSession)

        filters.fitToContent = true
        filters.chipStyle = true
        filters.onSelect = { [weak self] i in Self.filter = i; self?.reload() }
        filters.switches = { [weak self] in self.map { [$0.scroll] } ?? [] }
        left.addSubview(filters)
        search.field.font = NSFont.systemFont(ofSize: 13)
        search.field.stringValue = Self.query
        search.field.delegate = self
        search.layer?.backgroundColor = p.surfaceRow.cgColor
        search.layer?.borderColor = p.border.cgColor
        left.addSubview(search)

        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = list
        left.addSubview(scroll)
        left.addSubview(leftState)
        tip.onClose = { [weak self] in
            guard let self = self else { return }
            UserDefaults.standard.set(self.tipText().body, forKey: Self.tipKey)
            self.reload()
        }
        left.addSubview(tip)
        tipZera.imageScaling = .scaleProportionallyUpOrDown
        tipZera.imageAlignment = .alignBottom
        tipZera.image = SpriteLibrary.shared.sprite("card_laptop_side")?.image ?? SpriteLibrary.shared.sprite("laptop")?.image
        left.addSubview(tipZera)

        // Right.
        back = GHSquareButton(symbol: "chevron.left", label: "All sessions", target: self, action: #selector(backTapped))
        right.addSubview(back)
        right.addSubview(sessionTile)
        right.addSubview(sessionTitleLabel)
        right.addSubview(sessionChipView)
        right.addSubview(sessionElapsed)
        right.addSubview(sessionMetaLabel)
        primary = PRActionButton("Stop", style: .destructive, symbol: "stop.fill", target: self, action: #selector(primaryTapped))
        right.addSubview(primary)
        sessionMore = GHSquareButton(symbol: "ellipsis", label: "More", target: self, action: #selector(sessionMoreTapped))
        right.addSubview(sessionMore)
        collapse = GHSquareButton(symbol: "xmark", label: "Close session view", target: self, action: #selector(collapseTapped))
        right.addSubview(collapse)
        tabs.onSelect = { [weak self] i in self?.tab = i; self?.infoSignature = ""; self?.reload() }
        tabs.switches = { [weak self] in self.map { [$0.console, $0.infoScroll, $0.details] } ?? [] }
        right.addSubview(tabs)
        right.addSubview(progressCard)
        right.addSubview(reaction)
        console.onExpand = { [weak self] in
            guard let self = self else { return }
            self.consoleExpanded.toggle()
            self.console.expanded = self.consoleExpanded
            self.needsLayout = true
        }
        right.addSubview(console)
        infoScroll.hasVerticalScroller = false
        infoScroll.borderType = .noBorder
        infoScroll.drawsBackground = false
        infoScroll.contentView.drawsBackground = false
        infoScroll.documentView = infoList
        right.addSubview(infoScroll)
        right.addSubview(details)
        input.onSend = { [weak self] q in self?.ask(q) }
        input.onMenu = { [weak self] v in self?.showSuggestions(from: v) }
        right.addSubview(input)
        let qa: [(String, String, Selector)] = [
            ("Summarize progress", "text.alignleft", #selector(summarizeTapped)),
            ("Explain changes", "plus.forwardslash.minus", #selector(explainTapped)),
            ("Find issues", "ladybug", #selector(issuesTapped)),
            ("Open in editor", "square.and.pencil", #selector(editorTapped))
        ]
        for (t, sym, sel) in qa {
            let b = PRActionButton(t, style: .secondary, symbol: sym, target: self, action: sel)
            quick.append(b)
            right.addSubview(b)
        }
        right.addSubview(rightState)

        for name in [ClaudeActivityService.changed, ClaudeHookService.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(reloadIfVisible), name: name, object: nil)
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        NotificationCenter.default.removeObserver(self)
        ticker?.invalidate()
    }

    // Elapsed times and the console timer tick while the screen is up.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker?.invalidate(); ticker = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfVisible() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    // MARK: Data

    private func sessions(in filter: Int) -> [ClaudeSession] {
        let all = svc.ordered
        switch filter {
        case 1: return all.filter { bucket($0) == .running }
        case 2: return all.filter { bucket($0) == .waiting }
        case 3: return all.filter { bucket($0) == .completed }
        default: return all
        }
    }

    private var visible: [ClaudeSession] {
        let q = Self.query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = sessions(in: Self.filter)
        guard !q.isEmpty else { return base }
        return base.filter { s in
            let hay = [s.title, s.fullPrompt, s.cwd, s.branch ?? ""].joined(separator: " ").lowercased()
            return hay.contains(q)
        }
    }

    private var selected: ClaudeSession? {
        if let id = selectedID, let s = svc.sessions[id] { return s }
        return nil
    }

    private func pendingCommand(for s: ClaudeSession) -> String? {
        let pending = ClaudeHookService.shared.pending
        return pending.first { $0.sessionID == s.id }?.command ?? (s.status == .waiting ? pending.first?.command : nil)
    }

    private func tipText() -> (title: String, body: String) {
        let all = svc.ordered
        let running = all.filter { bucket($0) == .running }.count
        let waiting = all.filter { bucket($0) == .waiting }.count
        if !svc.isInstalled { return ("Zera's tip ✨", "Turn on live progress and I'll follow every Claude Code session for you.") }
        if waiting > 0 { return ("Heads up 👋", "Claude is waiting on you in \(waiting) session\(waiting == 1 ? "" : "s") — tap ▶ to review.") }
        if running > 0 { return ("Zera's tip ✨", "You have \(running) session\(running == 1 ? "" : "s") running. I'll let you know if anything needs your attention!") }
        if all.isEmpty { return ("Zera's tip ✨", "Start a session with New Session — I'll follow along automatically.") }
        return ("Zera's tip ✨", "All quiet. I'll ping you the moment Claude needs you.")
    }

    // MARK: Reload

    @objc private func reloadIfVisible() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else { return }
        reload()
    }

    @objc func reload() {
        let p = Pal
        let all = svc.ordered
        let running = all.filter { bucket($0) == .running }.count
        let waiting = all.filter { bucket($0) == .waiting }.count
        let completed = all.filter { bucket($0) == .completed }.count

        // Selection: keep it while the session exists; otherwise the most relevant one.
        if selected == nil { selectedID = svc.current?.id }

        // Left header.
        if running > 0 { bubble.text = "\(running) session\(running == 1 ? "" : "s") running\nLet's check \(running == 1 ? "it" : "them")! 👀" }
        else if waiting > 0 { bubble.text = "Claude needs you 🙋" }
        else { bubble.text = all.isEmpty ? "No sessions yet ✨" : "All quiet here ✨" }

        filters.items = [
            .init(symbol: "", title: "All", count: all.count, tint: nil, badgeTint: nil, showsZero: true),
            .init(symbol: "", title: "Running", count: running, tint: nil, badgeTint: p.success, showsZero: true),
            .init(symbol: "", title: "Waiting", count: waiting, tint: nil, badgeTint: p.warning, showsZero: true),
            .init(symbol: "", title: "Completed", count: completed, tint: nil, badgeTint: nil, showsZero: true)
        ]
        filters.selected = Self.filter
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if waiting > 0 { parts.append("\(waiting) waiting on you") }
        if parts.isEmpty { parts.append(all.isEmpty ? "No sessions yet" : "\(completed) done") }
        leftSub.stringValue = parts.joined(separator: " · ")

        // Rows, reused by session id so hover and animation survive the 1-second tick.
        let shown = visible
        let ids = shown.map { $0.id }
        for (id, r) in rows where !ids.contains(id) { r.removeFromSuperview(); rows.removeValue(forKey: id) }
        for s in shown {
            let r: ClaudeSessionRow
            if let existing = rows[s.id] { r = existing } else {
                r = ClaudeSessionRow(sessionID: s.id)
                let id = s.id
                r.onSelect = { [weak self] in self?.select(id) }
                r.onStop = { [weak self] in self?.stop(id) }
                r.onReview = { [weak self] in self?.onReviewApproval?() }
                r.onMenu = { [weak self] v in self?.showRowMenu(id, from: v) }
                list.addSubview(r)
                rows[s.id] = r
            }
            r.selected = s.id == selectedID
            r.update(s)
        }
        let orderChanged = order != ids
        order = ids

        // Left empty state.
        leftState.isHidden = !shown.isEmpty
        let lkey = !svc.isInstalled ? "off" : (!Self.query.isEmpty || Self.filter != 0 ? "filtered" : "empty")
        if shown.isEmpty, orderChanged || lkey != leftStateKey {
            leftStateKey = lkey
            if !svc.isInstalled {
                leftState.set(pose: "card_sleepy_sit", title: "Live progress is off",
                              subtitle: "Turn it on and I'll follow every Claude Code session.",
                              button: PRActionButton("Turn on live progress", style: .primary, symbol: "dot.radiowaves.left.and.right", target: self, action: #selector(installTapped)))
            } else if !Self.query.isEmpty || Self.filter != 0 {
                leftState.set(pose: "card_read_q", title: "Nothing here", subtitle: "Try another filter or search.")
            } else {
                leftState.set(pose: "card_sleepy_sit", title: "No Claude sessions yet", subtitle: "Start one with New Session — I'll follow along.")
            }
        }

        // Tip.
        let t = tipText()
        // The island has no room for the tip; the subtitle carries the counts instead.
        let tipHidden = true || UserDefaults.standard.string(forKey: Self.tipKey) == t.body
        tip.isHidden = tipHidden
        tipZera.isHidden = tipHidden
        tip.set(title: t.title, body: t.body)

        reloadRight()
        needsLayout = true
        // The list-only card grows and shrinks with the number of sessions.
        if !expanded { onHeightChange?() }
    }

    private func reloadRight() {
        let p = Pal
        guard svc.isInstalled, let s = selected else {
            [sessionTile, sessionTitleLabel, sessionChipView, sessionElapsed, sessionMetaLabel, primary, sessionMore, tabs,
             progressCard, reaction, console, infoScroll, details, input].forEach { $0.isHidden = true }
            quick.forEach { $0.isHidden = true }
            rightState.isHidden = false
            let rkey = svc.isInstalled ? "none" : "off"
            guard rkey != rightStateKey else { return }
            rightStateKey = rkey
            if !svc.isInstalled {
                rightState.set(pose: "card_greet", title: "Follow Claude's work live",
                               subtitle: "Zera adds small hooks to Claude Code so you can see every session here — no API key, no Terminal.",
                               button: PRActionButton("Turn on live progress", style: .primary, symbol: "dot.radiowaves.left.and.right", target: self, action: #selector(installTapped)))
            } else {
                rightState.set(pose: "card_laptop_side", title: "No session selected",
                               subtitle: "Start Claude Code in any folder and its session shows up here as it works.",
                               button: PRActionButton("New Session", style: .primary, symbol: "plus", target: self, action: #selector(newSessionTapped)))
            }
            return
        }
        rightState.isHidden = true
        rightStateKey = ""
        [sessionTile, sessionTitleLabel, sessionChipView, sessionElapsed, sessionMetaLabel, sessionMore, tabs, details, input].forEach { $0.isHidden = false }
        quick.forEach { $0.isHidden = false }

        // Header.
        sessionTile.symbol = SessionIconTile.symbol(for: s)
        sessionTile.tint = s.status == .waiting ? p.warning : .white
        sessionTitleLabel.stringValue = sessionTitle(s)
        sessionTitleLabel.toolTip = s.fullPrompt.isEmpty ? nil : s.fullPrompt
        let c = sessionChip(s)
        sessionChipView.set(symbol: c.symbol, text: s.status == .waiting && !s.stopRequested ? "Waiting for approval" : c.text, color: c.color)
        sessionElapsed.stringValue = s.promptAt == nil ? "" : ClaudeActivityCard.clock(s.elapsed)
        sessionMetaLabel.stringValue = sessionMeta(s)

        let kind: Int
        if s.stopRequested { kind = -1 }
        else {
            switch s.status {
            case .running: kind = 0
            case .waiting: kind = 1
            default: kind = 2
            }
        }
        if kind != primaryKind {
            primaryKind = kind
            primary.removeFromSuperview()
            switch kind {
            case 0: primary = PRActionButton("Stop", style: .destructive, symbol: "stop.fill", target: self, action: #selector(primaryTapped))
            case 1: primary = PRActionButton("Review approval", style: .warning, symbol: "hand.raised.fill", target: self, action: #selector(primaryTapped))
            default: primary = PRActionButton("New Session", style: .secondary, symbol: "plus", target: self, action: #selector(primaryTapped))
            }
            right.addSubview(primary)
        }
        primary.isHidden = kind == -1

        // Tabs with real counts.
        tabs.items = [
            .init(symbol: "dot.radiowaves.left.and.right", title: "Live", count: 0, tint: nil),
            .init(symbol: "", title: "Files", count: s.filesTouched.count, tint: nil),
            .init(symbol: "", title: "Changes", count: s.filesChanged.count, tint: nil),
            .init(symbol: "", title: "Tools", count: s.toolUse.count, tint: nil),
            .init(symbol: "", title: "Timeline", count: 0, tint: nil)
        ]
        tabs.selected = tab

        let live = tab == 0
        progressCard.isHidden = !live
        reaction.isHidden = !live
        console.isHidden = !live
        infoScroll.isHidden = live
        if live {
            progressCard.update(s)
            reaction.update(s, pendingCommand: pendingCommand(for: s))
            console.update(s)
        } else {
            rebuildInfo(for: s)
        }
        details.update(s)
    }

    /// Files / Changes / Tools / Timeline as simple rows; rebuilt only when the content changes.
    private func rebuildInfo(for s: ClaudeSession) {
        let p = Pal
        let toolCalls: Int = s.toolUse.values.reduce(0, +)
        let lastDone: Bool = s.steps.last?.finished ?? true
        let counts: String = "\(s.filesTouched.count)|\(s.filesChanged.count)|\(toolCalls)|\(s.steps.count)|\(lastDone)"
        let sig = s.id + "|\(tab)|" + counts
        guard sig != infoSignature else { return }
        infoSignature = sig
        infoList.subviews.forEach { $0.removeFromSuperview() }
        func rel(_ path: String) -> String {
            let dir = (path as NSString).deletingLastPathComponent
            if !s.cwd.isEmpty, dir.hasPrefix(s.cwd) { let r = String(dir.dropFirst(s.cwd.count)); return r.isEmpty ? "./" : "." + r }
            return shortPath(dir)
        }
        var made: [SessionInfoRow] = []
        switch tab {
        case 1:
            for f in s.filesTouched.reversed() {
                let edited = s.filesChanged.contains(f)
                made.append(SessionInfoRow(symbol: edited ? "pencil" : "doc.text", tint: edited ? p.accent : p.info,
                                           title: (f as NSString).lastPathComponent, subtitle: rel(f), trailing: edited ? "Edited" : "Read"))
            }
        case 2:
            for f in s.filesChanged.reversed() {
                made.append(SessionInfoRow(symbol: "pencil", tint: p.accent, title: (f as NSString).lastPathComponent, subtitle: rel(f), trailing: "Changed"))
            }
        case 3:
            for (tool, n) in s.toolUse.sorted(by: { $0.value > $1.value }) {
                let kind = ClaudeActivityService.describe(tool: tool, input: [:]).0
                let sym = ActivityStep(id: "", kind: kind, verb: "", target: "", detail: nil, at: Date(), finished: true).symbol
                made.append(SessionInfoRow(symbol: sym, tint: p.accent, title: tool.hasPrefix("mcp__") ? tool.replacingOccurrences(of: "mcp__", with: "") : tool,
                                           subtitle: "", trailing: "×\(n)"))
            }
        default:
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            for st in s.steps.reversed() where st.kind != .prompt {
                let d = st.duration.map { " · \(ClaudeActivityCard.clock($0))" } ?? (st.finished ? "" : " · running")
                let tint: NSColor = st.kind == .waiting ? p.warning : (st.finished ? p.success : p.accent)
                made.append(SessionInfoRow(symbol: st.symbol, tint: tint, title: st.text, subtitle: st.result ?? "", trailing: f.string(from: st.at) + d))
            }
        }
        if made.isEmpty {
            let empty = label(NSFont.systemFont(ofSize: 13), p.textSecondary)
            empty.stringValue = ["", "No files yet.", "No changes yet.", "No tools used yet.", "Nothing on the timeline yet."][tab]
            empty.alignment = .center
            empty.frame = NSRect(x: 0, y: 24, width: 400, height: 18)
            empty.autoresizingMask = [.width]
            infoList.addSubview(empty)
        }
        made.forEach { infoList.addSubview($0) }
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let single = singlePane
        collapse.isHidden = !expanded || single
        if !expanded {
            left.isHidden = false
            right.isHidden = true
            left.frame = NSRect(x: 0, y: 0, width: w, height: h)
            layoutLeft(left.bounds.size)
            return
        }
        if single {
            left.isHidden = showingDetail
            right.isHidden = !showingDetail
            left.frame = NSRect(x: 0, y: 0, width: w, height: h)
            right.frame = NSRect(x: 0, y: 0, width: w, height: h)
        } else {
            left.isHidden = false
            right.isHidden = false
            let lw = (w * 0.48).rounded()
            left.frame = NSRect(x: 0, y: 0, width: lw, height: h)
            right.frame = NSRect(x: lw + S.gap, y: 0, width: w - lw - S.gap, height: h)
        }
        layoutLeft(left.bounds.size)
        layoutRight(right.bounds.size, single: single)
    }

    private func layoutLeft(_ size: NSSize) {
        let w = size.width, h = size.height, x = S.pad, iw = w - S.pad * 2

        // Island header: title and counts left of Zera, New on the right. Her own pictures stay
        // hidden — she hangs in the middle of the header.
        [claudeTile, peek, bubble, tipZera].forEach { $0.isHidden = true }
        leftTitle.frame = ScreenHeader.titleFrame(width: w, padding: x)
        leftSub.frame = ScreenHeader.subtitleFrame(width: w, padding: x)
        let bw = newSession.fittedWidth + 8
        newSession.frame = NSRect(x: w - x - bw, y: ScreenHeader.controlY(Metrics.button), width: bw, height: Metrics.button)

        // Filters and search on one line.
        var y = Isle.headerHeight
        let segW = min(iw, filters.preferredWidth)
        filters.frame = NSRect(x: x, y: y, width: segW, height: Metrics.segment)
        let besideW = iw - segW - 10
        search.isHidden = besideW < 120
        search.frame = NSRect(x: x + segW + 10, y: y, width: max(0, besideW), height: Metrics.field)
        y += Metrics.segment + 12

        tip.isHidden = true
        let listBottom = h - 14
        scroll.frame = NSRect(x: x - 4, y: y - 4, width: iw + 8, height: max(0, listBottom - y + 4))
        leftState.frame = NSRect(x: x, y: y, width: iw, height: max(0, listBottom - y))
        var ry: CGFloat = 4
        for id in order {
            guard let r = rows[id] else { continue }
            r.frame = NSRect(x: 4, y: ry, width: iw, height: S.rowH)
            ry += S.rowH + S.rowGap
        }
        list.frame = NSRect(x: 0, y: 0, width: iw + 8, height: max(ry, scroll.frame.height))
    }

    private func layoutRight(_ size: NSSize, single: Bool) {
        let w = size.width, h = size.height, x = S.pad, iw = w - S.pad * 2
        let half = w / 2 - Isle.zeraGap / 2

        rightState.frame = NSRect(x: x, y: Isle.headerHeight, width: iw, height: max(0, h - Isle.headerHeight - 20))
        // Island header: back · title / time and folder on the left; status, Stop, more on the right.
        back.isHidden = false
        back.frame = NSRect(x: x, y: CardBase.titleTop + 1, width: 34, height: 34)
        sessionTile.isHidden = true
        collapse.isHidden = true
        let tx = x + 44
        sessionTitleLabel.frame = NSRect(x: tx, y: CardBase.titleTop - 2, width: max(40, half - tx), height: 22)
        let elapsed = sessionElapsed.stringValue
        sessionElapsed.isHidden = true
        if !elapsed.isEmpty, !sessionMetaLabel.stringValue.hasPrefix(elapsed) {
            sessionMetaLabel.stringValue = elapsed + " · " + sessionMetaLabel.stringValue
        }
        sessionMetaLabel.frame = NSRect(x: tx, y: CardBase.titleTop + 20, width: max(40, half - tx), height: 16)
        sessionMore.frame = NSRect(x: w - x - 34, y: CardBase.titleTop + 1, width: 34, height: 34)
        let pw = primary.isHidden ? 0 : max(76, primary.fittedWidth)
        primary.frame = NSRect(x: sessionMore.frame.minX - 8 - pw, y: CardBase.titleTop + 2, width: pw, height: 32)
        let chipRight = (primary.isHidden ? sessionMore.frame.minX : primary.frame.minX) - 8
        let chipW = min(chipRight - (w / 2 + Isle.zeraGap / 2), sessionChipView.fittedWidth)
        sessionChipView.isHidden = chipW < 60
        sessionChipView.frame = NSRect(x: chipRight - chipW, y: CardBase.titleTop + 6, width: chipW, height: 24)

        // Tabs.
        tabs.frame = NSRect(x: x, y: Isle.headerHeight, width: iw, height: Metrics.segment)

        // Bottom: quick asks, then the ask field above them.
        let qh: CGFloat = 30
        let qy = h - 16 - qh
        let gaps = CGFloat(quick.count - 1) * 8
        let each = (iw - gaps) / CGFloat(quick.count)
        var bx = x
        for b in quick {
            b.frame = NSRect(x: bx, y: qy, width: each, height: qh)
            bx += each + 8
        }
        let inputY = qy - 10 - 40
        input.frame = NSRect(x: x, y: inputY, width: iw, height: 40)
        details.isHidden = true
        reaction.isHidden = true

        // Body between the tabs and the ask field.
        let bodyTop = Isle.headerHeight + Metrics.segment + 10
        let bodyBottom = inputY - 10
        let bodyH = max(0, bodyBottom - bodyTop)
        infoScroll.frame = NSRect(x: x, y: bodyTop, width: iw, height: bodyH)
        var iy: CGFloat = 0
        for v in infoList.subviews {
            if v is SessionInfoRow {
                v.frame = NSRect(x: 0, y: iy, width: iw, height: SessionInfoRow.height)
                iy += SessionInfoRow.height + 6
            } else {
                v.frame = NSRect(x: 0, y: 24, width: iw, height: 18)
            }
        }
        infoList.frame = NSRect(x: 0, y: 0, width: iw, height: max(iy, bodyH))

        // Live: progress card, then the console filling the rest.
        let progH: CGFloat = 70
        progressCard.frame = NSRect(x: x, y: bodyTop, width: iw, height: progH)
        let cy = bodyTop + progH + 8
        console.frame = NSRect(x: x, y: cy, width: iw, height: max(50, bodyBottom - cy))
    }

    // MARK: Actions

    private func select(_ id: String) {
        selectedID = id
        console.resetClear()
        infoSignature = ""
        if singlePane { showingDetail = true }
        if !expanded { setExpanded(true); return }
        reload()
    }

    @objc private func backTapped() { setExpanded(false) }
    @objc private func collapseTapped() { setExpanded(false) }

    private func stop(_ id: String) {
        guard let s = svc.sessions[id] else { return }
        svc.requestStop(s)
        say?("asking Claude to stop at its next step ✋", .focused)
    }

    @objc private func newSessionTapped() { onNewSession?() }

    @objc private func installTapped() {
        do {
            try ClaudeActivityService.shared.install()
            say?("I'll follow Claude's work from here 💜 Restart open sessions.", .approved)
        } catch {
            say?("couldn't update Claude settings 😕", .worried)
        }
        reload()
    }

    @objc private func primaryTapped() {
        guard let s = selected else { return }
        switch primaryKind {
        case 0: stop(s.id)
        case 1: onReviewApproval?()
        default: onNewSession?()
        }
    }

    @objc private func sessionMoreTapped() {
        guard let s = selected else { return }
        showMenu(for: s, from: sessionMore)
    }

    private func showRowMenu(_ id: String, from v: NSView) {
        guard let s = svc.sessions[id] else { return }
        showMenu(for: s, from: v)
    }

    private func showMenu(for s: ClaudeSession, from v: NSView) {
        let id = s.id
        var items: [NSMenuItem] = [
            ClosureMenuItem("Show details", symbol: "sidebar.right") { [weak self] in self?.select(id) },
            ClosureMenuItem("Open in editor", symbol: "square.and.pencil", enabled: !s.cwd.isEmpty) { [weak self] in self?.openEditor(s.cwd) },
            ClosureMenuItem("Show folder in Finder", symbol: "folder", enabled: !s.cwd.isEmpty) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)])
            },
            ClosureMenuItem("Copy prompt", symbol: "doc.on.doc", enabled: !s.fullPrompt.isEmpty) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s.fullPrompt, forType: .string)
            },
            .separator()
        ]
        if s.isActive && !s.stopRequested {
            items.append(ClosureMenuItem("Stop at next step", symbol: "stop.fill") { [weak self] in self?.stop(id) })
        }
        items.append(ClosureMenuItem("Open Claude Code", symbol: "terminal") { [weak self] in self?.onNewSession?() })
        items.append(ClosureMenuItem("Remove from list", symbol: "xmark.circle") { [weak self] in
            ClaudeActivityService.shared.remove(s)
            if self?.selectedID == id { self?.selectedID = nil }
        })
        NSMenu.make(items).pop(below: v)
    }

    /// The session folder in the first editor that's installed, else Finder.
    private func openEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let editors = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4"]
        if let app = editors.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static let questions: [(String, String)] = [
        ("Summarize progress", "Summarize this Claude Code session's progress: what's done, what's in progress, and what's left."),
        ("Explain changes", "Explain the code changes in this session (see the git diff): what changed and why it matters."),
        ("Find issues", "Review this session's changes (see the git diff) and list likely bugs, risks or missing tests, most important first."),
        ("What's Claude doing right now?", "In two or three sentences, what is Claude doing right now in this session and what's likely next?")
    ]

    /// Builds the session brief (task, timeline, files, git diff) and asks Zera about it —
    /// through your Claude Code login, inside Zera; nothing opens Terminal.
    private func ask(_ question: String) {
        guard let s = selected else { return }
        say?("reading the session… 📖", .thinking)
        svc.brief(for: s) { [weak self] url in
            guard let self = self else { return }
            guard let url = url else { self.say?("couldn't put the session together 😕", .worried); return }
            self.onAsk?(url, question)
        }
    }

    @objc private func summarizeTapped() { ask(Self.questions[0].1) }
    @objc private func explainTapped() { ask(Self.questions[1].1) }
    @objc private func issuesTapped() { ask(Self.questions[2].1) }
    @objc private func editorTapped() { if let s = selected, !s.cwd.isEmpty { openEditor(s.cwd) } }

    private func showSuggestions(from v: NSView) {
        NSMenu.make(Self.questions.map { q in
            ClosureMenuItem(q.0, symbol: "sparkles") { [weak self] in self?.ask(q.1) }
        }).pop(below: v)
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === search.field else { return }
        Self.query = search.field.stringValue
        reload()
    }
}
