import AppKit

/// The expanded Claude view (mock "Expanded View"): header with Zera + status, the current
/// command in a code box, folder / branch / started chips, the live activity timeline with
/// outcomes and durations, an approval block when Claude is blocked, and recent history.
final class ClaudeActivityCard: CardBase, CardContent {
    var cardWidth: CGFloat { 480 }
    var say: ((String, ZeraMood) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onClose: (() -> Void)?

    // Header
    private let avatar = NSImageView()
    private let chip = StatusChip()
    private let elapsed = NSTextField(labelWithString: "")
    private let close: IconButton
    // Command
    private let commandHeader = NSTextField(labelWithString: "CURRENT COMMAND")
    private let commandBox = FlippedView()
    private let commandText = NSTextField(wrappingLabelWithString: "")
    private let copyButton: IconButton
    private var tags: [TagChip] = []
    // Timeline
    private let activityHeader = NSTextField(labelWithString: "LIVE ACTIVITY")
    private var stepRows: [TimelineRow] = []
    private let noSteps = NSTextField(labelWithString: "Waiting for Claude's first step…")
    // Approval
    private let approvalBox = FlippedView()
    private let approvalTitle = NSTextField(labelWithString: "APPROVAL REQUIRED")
    private let approvalCommand = NSTextField(labelWithString: "")
    private let approvalDetail = NSTextField(labelWithString: "")
    private let reject: CardButton
    private let approve: CardButton
    // History
    private let historyHeader = NSTextField(labelWithString: "RECENT HISTORY")
    private var historyRows: [HistoryRow] = []
    // Empty / not installed
    private let zera = ZeraCompanion(pose: "card_point_sparkle", size: 68)
    private let install: CardButton

    private var pendingRequest: HookRequest?
    private var ticker: Timer?
    private let maxSteps = 6
    private let maxHistory = 3

    init() {
        close = IconButton(symbol: "xmark", label: "Close", target: nil, action: #selector(ClaudeActivityCard.closeTapped))
        copyButton = IconButton(symbol: "doc.on.doc", label: "Copy command", target: nil, action: #selector(ClaudeActivityCard.copyTapped))
        reject = CardButton("Reject", style: .destructive, target: nil, action: #selector(ClaudeActivityCard.rejectTapped))
        approve = CardButton("Approve & Run", style: .success, symbol: "checkmark", target: nil, action: #selector(ClaudeActivityCard.approveTapped))
        install = CardButton("Follow Claude's work", style: .primary, symbol: "sparkles", target: nil, action: #selector(ClaudeActivityCard.installTapped))
        super.init(width: 480, title: "Zera")
        let p = Pal
        for b in [close, copyButton] { b.target = self }
        for b in [reject, approve, install] { b.target = self }
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.imageAlignment = .alignBottom
        addSubview(avatar); addSubview(chip); addSubview(close)
        elapsed.font = Typo.caption; elapsed.textColor = p.textTertiary; addSubview(elapsed)
        for h in [commandHeader, activityHeader, historyHeader, approvalTitle] {
            h.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
            h.textColor = p.textSecondary
        }
        addSubview(commandHeader)
        commandBox.wantsLayer = true
        commandBox.layer?.cornerRadius = Radius.m
        commandBox.layer?.cornerCurve = .continuous
        commandBox.layer?.backgroundColor = p.codeBox.cgColor
        commandText.font = Typo.mono
        commandText.textColor = p.codeText
        commandText.maximumNumberOfLines = 3
        commandText.isSelectable = true
        commandBox.addSubview(commandText)
        copyButton.contentTintColor = p.codeText.withAlphaComponent(0.8)
        commandBox.addSubview(copyButton)
        addSubview(commandBox)
        addSubview(activityHeader)
        noSteps.font = Typo.body; noSteps.textColor = p.textTertiary; addSubview(noSteps)

        approvalBox.wantsLayer = true
        approvalBox.layer?.cornerRadius = Radius.l
        approvalBox.layer?.cornerCurve = .continuous
        approvalBox.layer?.backgroundColor = p.warning.withAlphaComponent(p.isDark ? 0.14 : 0.16).cgColor
        approvalTitle.textColor = p.isDark ? p.warning : NSColor(srgbRed: 0.72, green: 0.42, blue: 0.0, alpha: 1)
        approvalCommand.font = Typo.bodyStrong; approvalCommand.textColor = p.text; approvalCommand.lineBreakMode = .byTruncatingTail
        approvalDetail.font = Typo.secondary; approvalDetail.textColor = p.textSecondary; approvalDetail.lineBreakMode = .byTruncatingTail
        for v in [approvalTitle, approvalCommand, approvalDetail, reject, approve] as [NSView] { approvalBox.addSubview(v) }
        addSubview(approvalBox)
        addSubview(historyHeader)
        addSubview(zera); addSubview(install)

        for name in [ClaudeActivityService.changed, ClaudeHookService.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { ticker?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker?.invalidate(); ticker = nil
        guard window != nil else { return }
        // Elapsed time and step durations tick once a second while the card is up.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let s = session, s.status == .running || s.status == .waiting else { return }
        elapsed.stringValue = "· \(Self.clock(s.elapsed))"
        for r in stepRows { r.tick() }
    }

    // MARK: Data

    private var session: ClaudeSession? { ClaudeActivityService.shared.current }
    private var steps: [ActivityStep] { Array((session?.steps ?? []).suffix(maxSteps)) }
    private var history: [ActivityHistoryItem] { Array(ClaudeActivityService.shared.recentHistory.prefix(maxHistory)) }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    private var commandHeight: CGFloat {
        let text = commandText.stringValue
        let b = (text as NSString).boundingRect(with: NSSize(width: cardWidth - Metrics.cardPad * 2 - Space.m * 2 - 36, height: 80),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Typo.mono])
        return min(64, max(20, ceil(b.height))) + Space.m * 2
    }

    var desiredHeight: CGFloat {
        let svc = ClaudeActivityService.shared
        guard svc.isInstalled, session != nil else {
            return headerBottom + zera.preferredHeight + Space.m + (svc.isInstalled ? 0 : Metrics.button + Space.m) + Metrics.cardPad - Space.m
        }
        var h: CGFloat = Space.l + 48 + Space.l                      // header with avatar
        h += 14 + Space.s + commandHeight + Space.s + 26 + Space.l     // command + chips
        h += 14 + Space.s + (stepRows.isEmpty ? 22 : CGFloat(stepRows.count) * TimelineRow.height) + Space.l
        if pendingRequest != nil { h += approvalHeight + Space.l }
        if !historyRows.isEmpty { h += 14 + Space.s + CGFloat(historyRows.count) * HistoryRow.height }
        else { h -= Space.l - Space.xs }
        return h + Metrics.cardPad
    }

    private let approvalHeight: CGFloat = Space.m + 14 + Space.xs + 18 + 2 + 16 + Space.m + Metrics.button + Space.m

    @objc func reload() {
        let svc = ClaudeActivityService.shared, p = Pal
        stepRows.forEach { $0.removeFromSuperview() }; stepRows = []
        historyRows.forEach { $0.removeFromSuperview() }; historyRows = []
        let installed = svc.isInstalled
        install.isHidden = installed
        let main: [NSView] = [avatar, chip, elapsed, commandHeader, commandBox, activityHeader, noSteps, historyHeader]
        tags.forEach { $0.removeFromSuperview() }; tags = []
        guard installed, let s = session else {
            titleLabel.stringValue = "Zera"
            setSubtitle(installed ? "No Claude Code session right now" : "Not connected")
            main.forEach { $0.isHidden = true }
            approvalBox.isHidden = true
            zera.isHidden = false
            zera.set(pose: installed ? "card_read_q" : "card_point_sparkle")
            zera.line = installed ? "Start Claude Code in a terminal and I'll follow along here 👀"
                                  : "Let me show what Claude is doing — live, step by step."
            needsLayout = true; layoutSubtreeIfNeeded(); onHeightChange?()
            return
        }
        zera.isHidden = true
        main.forEach { $0.isHidden = false }
        titleLabel.stringValue = "Zera"
        setSubtitle(nil)

        // Header: avatar by mood, chip, elapsed.
        let (pose, chipText, chipColor): (String, String, NSColor)
        switch s.status {
        case .running: (pose, chipText, chipColor) = ("card_laptop_side", "Running", p.success)
        case .waiting: (pose, chipText, chipColor) = ("card_bell", "Needs your approval", p.warning)
        case .done: (pose, chipText, chipColor) = ("card_cheer", "Completed", p.success)
        case .idle: (pose, chipText, chipColor) = ("card_sleepy_sit", "Idle", p.muted)
        case .ended: (pose, chipText, chipColor) = ("card_sleepy_sit", "Ended", p.muted)
        }
        avatar.image = SpriteLibrary.shared.sprite(pose)?.image
        chip.set(text: chipText, color: chipColor)
        elapsed.stringValue = s.promptAt == nil ? "" : "· \(Self.clock(s.elapsed))"

        // Command
        let prompt = s.fullPrompt.isEmpty ? (s.title.isEmpty ? "Waiting for your first prompt…" : s.title) : ClaudeActivityService.oneLine(s.fullPrompt, max: 160)
        commandText.stringValue = "$ claude \u{201C}\(prompt)\u{201D}"
        var chipsSpec: [(String, String)] = [("folder", s.folderName)]
        if let b = s.branch { chipsSpec.append(("arrow.triangle.branch", b)) }
        if let at = s.promptAt { chipsSpec.append(("clock", "Started \(Self.time(at))")) }
        for (sym, text) in chipsSpec {
            let t = TagChip(symbol: sym, text: text)
            addSubview(t); tags.append(t)
        }

        // Timeline
        let visible = steps
        noSteps.isHidden = !visible.isEmpty
        for st in visible {
            let r = TimelineRow(step: st, isLast: st == visible.last)
            addSubview(r); stepRows.append(r)
        }

        // Approval
        pendingRequest = ClaudeHookService.shared.pending.first { $0.sessionID == s.id } ?? (s.status == .waiting ? ClaudeHookService.shared.pending.first : nil)
        approvalBox.isHidden = pendingRequest == nil
        if let req = pendingRequest {
            approvalCommand.stringValue = "Run: \(ClaudeActivityService.oneLine(req.command, max: 70))"
            approvalDetail.stringValue = req.detail ?? "Claude wants to run this in \(req.cwdDisplay)."
            reject.isEnabled = true; approve.isEnabled = true
        }

        // History
        let items = history
        historyHeader.isHidden = items.isEmpty
        for it in items {
            let r = HistoryRow(item: it)
            addSubview(r); historyRows.append(r)
        }

        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }

    // MARK: Actions

    @objc private func closeTapped() { if let c = onClose { c() } else { onEscape?() } }
    @objc private func copyTapped() {
        guard let s = session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.fullPrompt.isEmpty ? s.title : s.fullPrompt, forType: .string)
        say?("copied ✨", .happy)
    }
    @objc private func approveTapped() {
        guard let r = pendingRequest else { return }
        approve.isEnabled = false; reject.isEnabled = false
        ClaudeHookService.shared.respond(r, allow: true); say?("approved — running ✅", .approved)
    }
    @objc private func rejectTapped() {
        guard let r = pendingRequest else { return }
        approve.isEnabled = false; reject.isEnabled = false
        ClaudeHookService.shared.respond(r, allow: false); say?("okay, skipped that", .sad)
    }
    @objc private func installTapped() {
        do { try ClaudeActivityService.shared.install(); say?("I'll follow Claude's work from here 💜 Restart open sessions.", .approved) }
        catch { say?("couldn't edit ~/.claude/settings.json 😬", .worried) }
        reload()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let x = Metrics.cardPad, w = bounds.width - x * 2
        close.frame = NSRect(x: bounds.width - x - Metrics.control, y: Space.l - 3, width: Metrics.control, height: Metrics.control)
        if !zera.isHidden {
            layoutHeader(trailingWidth: 40)
            var y = headerBottom
            zera.frame = NSRect(x: x, y: y, width: w, height: zera.preferredHeight)
            y += zera.preferredHeight + Space.m
            install.frame = NSRect(x: x, y: y, width: install.fittedWidth, height: Metrics.button)
            return
        }
        // Header row: avatar · "Zera" · chip · elapsed … ✕
        avatar.frame = NSRect(x: x - 4, y: Space.m, width: 56, height: 52)
        titleLabel.frame = NSRect(x: x + 60, y: Space.l + 10, width: 50, height: 22)
        subtitleLabel.frame = .zero
        let cw = min(180, chip.fittedWidth)
        chip.frame = NSRect(x: x + 60 + 54, y: Space.l + 11, width: cw, height: 20)
        elapsed.frame = NSRect(x: chip.frame.maxX + Space.s, y: Space.l + 13, width: 80, height: 16)
        var y = Space.l + 48 + Space.l

        commandHeader.frame = NSRect(x: x, y: y, width: w, height: 14); y += 14 + Space.s
        let ch = commandHeight
        commandBox.frame = NSRect(x: x, y: y, width: w, height: ch)
        commandText.frame = NSRect(x: Space.m, y: Space.m, width: w - Space.m * 2 - 36, height: ch - Space.m * 2)
        copyButton.frame = NSRect(x: w - Space.s - Metrics.control, y: Space.s, width: Metrics.control, height: Metrics.control)
        y += ch + Space.s
        var tx = x
        for t in tags {
            let tw = t.fittedWidth
            t.frame = NSRect(x: tx, y: y, width: tw, height: 26)
            tx += tw + Space.s
        }
        y += 26 + Space.l

        activityHeader.frame = NSRect(x: x, y: y, width: w, height: 14); y += 14 + Space.s
        if stepRows.isEmpty {
            noSteps.frame = NSRect(x: x + 4, y: y, width: w, height: 18); y += 22
        } else {
            for r in stepRows { r.frame = NSRect(x: x, y: y, width: w, height: TimelineRow.height); y += TimelineRow.height }
        }
        y += Space.l

        if !approvalBox.isHidden {
            approvalBox.frame = NSRect(x: x, y: y, width: w, height: approvalHeight)
            var ay = Space.m
            approvalTitle.frame = NSRect(x: Space.m + 14, y: ay, width: w - Space.m * 2, height: 14); ay += 14 + Space.xs
            approvalCommand.frame = NSRect(x: Space.m, y: ay, width: w - Space.m * 2, height: 18); ay += 18 + 2
            approvalDetail.frame = NSRect(x: Space.m, y: ay, width: w - Space.m * 2, height: 16); ay += 16 + Space.m
            let half = (w - Space.m * 2 - Space.s) / 2
            reject.frame = NSRect(x: Space.m, y: ay, width: half, height: Metrics.button)
            approve.frame = NSRect(x: Space.m + half + Space.s, y: ay, width: half, height: Metrics.button)
            y += approvalHeight + Space.l
        }

        if !historyRows.isEmpty {
            historyHeader.frame = NSRect(x: x, y: y, width: w, height: 14); y += 14 + Space.s
            for r in historyRows { r.frame = NSRect(x: x, y: y, width: w, height: HistoryRow.height); y += HistoryRow.height }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The amber dot in front of "APPROVAL REQUIRED".
        if !approvalBox.isHidden {
            Pal.warning.setFill()
            let f = approvalBox.frame
            NSBezierPath(ovalIn: NSRect(x: f.minX + Space.m, y: f.minY + Space.m + 3, width: 8, height: 8)).fill()
        }
    }
}

// MARK: - Pieces

/// Small rounded tag: icon + text ("portal-utils", "main", "Started 10:24:13").
final class TagChip: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    init(symbol: String, text: String) {
        super.init(frame: .zero)
        let p = Pal
        wantsLayer = true
        layer?.cornerRadius = Radius.s + 2
        layer?.backgroundColor = p.surface.cgColor
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .medium))
        icon.contentTintColor = p.textSecondary
        addSubview(icon)
        label.stringValue = text
        label.font = Typo.caption
        label.textColor = p.text(0.85)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    var fittedWidth: CGFloat { min(180, ceil((label.stringValue as NSString).size(withAttributes: [.font: Typo.caption]).width) + 36) }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 9, y: (bounds.height - 13) / 2, width: 13, height: 13)
        label.frame = NSRect(x: 26, y: (bounds.height - 14) / 2, width: bounds.width - 34, height: 14)
    }
}

/// One timeline entry: status circle on a vertical rail, **Verb** target, outcome line, duration.
final class TimelineRow: NSView {
    static let height: CGFloat = 50
    private let step: ActivityStep
    private let isLast: Bool
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let ring = CAShapeLayer()
    override var isFlipped: Bool { true }

    init(step: ActivityStep, isLast: Bool) {
        self.step = step; self.isLast = isLast
        super.init(frame: .zero)
        wantsLayer = true
        let p = Pal
        let a = NSMutableAttributedString(string: step.verb + " ", attributes: [.font: Typo.bodyStrong, .foregroundColor: p.text])
        a.append(NSAttributedString(string: step.target, attributes: [.font: step.kind == .run ? Typo.mono : Typo.body, .foregroundColor: p.text(0.9)]))
        title.attributedStringValue = a
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        sub.font = Typo.caption; sub.textColor = p.textSecondary; sub.lineBreakMode = .byTruncatingTail
        sub.stringValue = step.finished ? (step.result ?? "Done") : step.progressLine
        addSubview(sub)
        time.font = Typo.caption; time.textColor = p.textTertiary; time.alignment = .right
        addSubview(time)
        tick()
        setAccessibilityLabel("\(step.text), \(sub.stringValue)")
        // Running indicator pulses.
        if !step.finished, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 20, height: 20), transform: nil)
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = p.accent.cgColor
            ring.lineWidth = 1.5
            ring.opacity = 0.9
            layer?.addSublayer(ring)
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1; grow.toValue = 1.6
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.9; fade.toValue = 0
            let g = CAAnimationGroup(); g.animations = [grow, fade]; g.duration = 1.4; g.repeatCount = .infinity
            ring.add(g, forKey: "pulse")
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Duration label: frozen once finished, counting while running.
    func tick() {
        let d = step.duration ?? Date().timeIntervalSince(step.at)
        time.stringValue = step.kind == .waiting ? "" : ClaudeActivityCard.clock(d)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 36, y: 6, width: w - 36 - 60, height: 18)
        sub.frame = NSRect(x: 36, y: 26, width: w - 36 - 60, height: 15)
        time.frame = NSRect(x: w - 56, y: 8, width: 56, height: 14)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = CGRect(x: 2, y: 6, width: 20, height: 20)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        // Rail
        if !isLast {
            p.divider.setFill()
            NSRect(x: 11, y: 28, width: 2, height: bounds.height - 28).fill()
        }
        let c = NSRect(x: 2, y: 6, width: 20, height: 20)
        switch (step.finished, step.kind) {
        case (true, _):
            (step.kind == .waiting ? p.warning : p.success).setFill()
            NSBezierPath(ovalIn: c).fill()
            if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))?.withSymbolConfiguration(.init(paletteColors: [.white])) {
                let s = img.size
                img.draw(in: NSRect(x: c.midX - s.width / 2, y: c.midY - s.height / 2, width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        case (false, .waiting):
            p.warning.withAlphaComponent(0.25).setFill(); NSBezierPath(ovalIn: c).fill()
            p.warning.setFill(); NSBezierPath(ovalIn: c.insetBy(dx: 6, dy: 6)).fill()
        case (false, _):
            p.accentSoft.setFill(); NSBezierPath(ovalIn: c).fill()
            p.accent.setFill(); NSBezierPath(ovalIn: c.insetBy(dx: 6, dy: 6)).fill()
        }
    }
}

/// One finished prompt: check · title · "2 min ago" · duration.
final class HistoryRow: NSView {
    static let height: CGFloat = 36
    private let title = NSTextField(labelWithString: "")
    private let when = NSTextField(labelWithString: "")
    private let dur = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    init(item: ActivityHistoryItem) {
        super.init(frame: .zero)
        let p = Pal
        title.stringValue = item.title; title.font = Typo.body; title.textColor = p.text; title.lineBreakMode = .byTruncatingTail
        when.stringValue = relativeTime(item.at); when.font = Typo.caption; when.textColor = p.textTertiary; when.alignment = .right
        dur.stringValue = ClaudeActivityCard.clock(item.duration); dur.font = Typo.caption; dur.textColor = p.textSecondary; dur.alignment = .right
        for v in [title, when, dur] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        dur.frame = NSRect(x: w - 56, y: 10, width: 56, height: 14)
        when.frame = NSRect(x: w - 56 - 8 - 80, y: 10, width: 80, height: 14)
        title.frame = NSRect(x: 30, y: 9, width: w - 30 - 150, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        p.divider.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        p.success.setFill()
        let c = NSRect(x: 2, y: 9, width: 18, height: 18)
        NSBezierPath(ovalIn: c).fill()
        if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))?.withSymbolConfiguration(.init(paletteColors: [.white])) {
            let s = img.size
            img.draw(in: NSRect(x: c.midX - s.width / 2, y: c.midY - s.height / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
