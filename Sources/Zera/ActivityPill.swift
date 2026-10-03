import AppKit

/// The compact Claude readout beside Zera, laid out like the mock: her avatar at the laptop,
/// "Zera" + status chip, elapsed time and a round chevron; the command in a terminal box; a
/// thick gradient progress bar with a glowing head and a percentage; and a step track — done
/// (green check) → active (violet sparkle) → pending (grey) — with labels and durations.
final class LiveActivityView: NSView {
    var onTap: (() -> Void)?
    /// Chevron: collapse ↔ expand. ✕: hide until Claude has something new.
    var onToggle: (() -> Void)?
    var onClose: (() -> Void)?

    static let compactSize = NSSize(width: 640, height: 60)
    static let expandedSize = NSSize(width: 640, height: 200)

    /// Compact row, left→right. Every slot is a fixed width except the command box, which takes
    /// whatever is left; the row is built so the sum always equals the panel width.
    private enum Compact {
        static let edge: CGFloat = 12       // left/right inset
        static let avatar: CGFloat = 44
        static let title: CGFloat = 40      // "Zera" at 15pt bold
        static let chipMax: CGFloat = 170
        static let elapsed: CGFloat = 50    // "12m 34s" at 12pt
        static let bar: CGFloat = 100
        static let percent: CGFloat = 38    // "100%"
        static let button: CGFloat = 28     // chevron / ✕
        static let gap: CGFloat = 8
        static let group: CGFloat = 12      // between the three groups
        static let commandMin: CGFloat = 110
    }
    var expanded = false { didSet { chevron.pointsUp = expanded; needsLayout = true; needsDisplay = true } }
    var size: NSSize { expanded ? Self.expandedSize : Self.compactSize }

    private let avatar = NSImageView()
    private let title = NSTextField(labelWithString: "Zera")
    private let chip = StatusChip()
    private let elapsed = NSTextField(labelWithString: "")
    private let chevron = RoundChevron()
    private let closeButton = IconButton(symbol: "xmark", label: "Hide", target: nil, action: #selector(LiveActivityView.closeTapped))
    private let commandBox = FlippedView()
    private let promptGlyph = NSTextField(labelWithString: ">_")
    private let command = NSTextField(labelWithString: "")
    private let track = ProgressTrack()
    private let percent = NSTextField(labelWithString: "")
    private var stepViews: [StepNode] = []
    private var rail: [NSView] = []
    private var hovered = false { didSet { needsDisplay = true } }
    private var lastCommand = ""

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let left: CGFloat = 136
    private let pad: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 28
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.imageAlignment = .alignBottom
        addSubview(avatar)
        title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        addSubview(title)
        addSubview(chip)
        elapsed.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        elapsed.alignment = .right
        addSubview(elapsed)
        chevron.onTap = { [weak self] in self?.onToggle?() }
        addSubview(chevron)
        closeButton.target = self
        addSubview(closeButton)
        commandBox.wantsLayer = true
        commandBox.layer?.cornerRadius = Radius.m
        commandBox.layer?.cornerCurve = .continuous
        promptGlyph.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        commandBox.addSubview(promptGlyph)
        command.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        command.lineBreakMode = .byTruncatingTail
        command.wantsLayer = true
        commandBox.addSubview(command)
        addSubview(commandBox)
        addSubview(track)
        percent.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        percent.alignment = .right
        addSubview(percent)
        setAccessibilityRole(.button)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() { onClose?() }

    private func restyle() {
        let p = Pal
        layer?.backgroundColor = p.cardBottom.withAlphaComponent(1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.border.cgColor
        title.textColor = p.text
        elapsed.textColor = p.textSecondary
        commandBox.layer?.backgroundColor = p.surface.cgColor
        promptGlyph.textColor = p.accent
        command.textColor = p.text
        percent.textColor = p.text
    }

    /// Everything from the session; safe to call every second.
    func update(session s: ClaudeSession, pendingCommand: String?) {
        restyle()
        let p = Pal
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let pose: String, chipText: String, chipColor: NSColor
        switch s.status {
        case .running: (pose, chipText, chipColor) = ("card_laptop_side", "Running", p.success)
        case .waiting: (pose, chipText, chipColor) = ("card_bell", "Needs your approval", p.warning)
        case .done: (pose, chipText, chipColor) = ("card_cheer", "Completed", p.success)
        case .idle, .ended: (pose, chipText, chipColor) = ("card_sleepy_sit", "Idle", p.muted)
        }
        avatar.image = SpriteLibrary.shared.sprite(pose)?.image
        chip.set(text: chipText, color: chipColor)
        elapsed.stringValue = s.promptAt == nil ? "" : ClaudeActivityCard.clock(s.elapsed)

        let cmd: String
        if s.status == .waiting, let c = pendingCommand { cmd = "Run: \(ClaudeActivityService.oneLine(c, max: 48))" }
        else if s.title.isEmpty { cmd = s.status == .idle ? "Ready for your next command" : "Thinking…" }
        else { cmd = "claude \"\(ClaudeActivityService.oneLine(s.title, max: 44))\"" }
        if cmd != lastCommand {
            lastCommand = cmd
            if !reduce {
                let t = CATransition(); t.type = .fade; t.duration = 0.25
                command.layer?.add(t, forKey: "text")
            }
            command.stringValue = cmd
        }

        let prog = s.progress
        track.set(progress: prog, status: s.status, animated: !reduce)
        percent.stringValue = s.status == .idle ? "" : "\(Int((prog * 100).rounded()))%"

        rebuildTrack(for: s)
        setAccessibilityLabel("Zera — \(chipText): \(cmd), \(percent.stringValue)")
        needsLayout = true
    }

    /// Up to five nodes: Claude's plan when it keeps one, otherwise the last tool steps.
    private func rebuildTrack(for s: ClaudeSession) {
        stepViews.forEach { $0.removeFromSuperview() }; stepViews = []
        rail.forEach { $0.removeFromSuperview() }; rail = []
        var nodes: [(String, String, StepNode.State)] = []
        if !s.plan.isEmpty {
            // Window the plan around the active item so five fit.
            let items = s.plan
            let activeIdx = items.firstIndex { $0.state == .active } ?? items.lastIndex { $0.state == .done } ?? 0
            let start = max(0, min(activeIdx - 2, items.count - 5))
            for it in items[start..<min(items.count, start + 5)] {
                let state: StepNode.State = it.state == .done ? .done : (it.state == .active ? .active : .pending)
                nodes.append((it.title, it.state == .done ? "Done" : (it.state == .active ? "Now" : "Pending"), state))
            }
        } else {
            for st in s.steps.suffix(5) {
                let d = st.duration.map { ClaudeActivityCard.clock($0) } ?? ClaudeActivityCard.clock(Date().timeIntervalSince(st.at))
                nodes.append((st.verb == "Running" ? "Run" : st.verb, st.finished ? d : d, st.finished ? .done : .active))
            }
            if nodes.isEmpty { nodes.append((s.status == .done ? "Done" : "Starting", s.status == .done ? "" : "…", s.status == .done ? .done : .active)) }
        }
        for (i, n) in nodes.enumerated() {
            if i > 0 { let r = NSView(); r.wantsLayer = true; r.layer?.backgroundColor = Pal.divider.cgColor; addSubview(r); rail.append(r) }
            let v = StepNode(title: n.0, sub: n.1, state: n.2)
            addSubview(v); stepViews.append(v)
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        layer?.cornerRadius = expanded ? 28 : h / 2
        if !expanded { layoutCompact(w: w, h: h); return }
        chip.compact = false
        track.isHidden = false; percent.isHidden = false; elapsed.isHidden = false; commandBox.isHidden = false
        stepViews.forEach { $0.isHidden = false }; rail.forEach { $0.isHidden = false }
        avatar.frame = NSRect(x: 14, y: 22, width: 108, height: 110)
        title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        title.frame = NSRect(x: left, y: 22, width: 64, height: 28)
        let cw = min(200, chip.fittedWidth)
        chip.frame = NSRect(x: left + 70, y: 24, width: cw, height: 26)
        closeButton.frame = NSRect(x: w - pad - 28, y: 22, width: 28, height: 28)
        chevron.frame = NSRect(x: closeButton.frame.minX - 8 - 36, y: 18, width: 36, height: 36)
        elapsed.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        elapsed.frame = NSRect(x: chevron.frame.minX - 8 - 60, y: 27, width: 60, height: 18)
        commandBox.frame = NSRect(x: left, y: 60, width: w - left - pad, height: 34)
        promptGlyph.frame = NSRect(x: 12, y: 8, width: 26, height: 18)
        command.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        command.frame = NSRect(x: 48, y: 8, width: commandBox.frame.width - 60, height: 18)
        let pw: CGFloat = 52
        percent.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        track.frame = NSRect(x: left, y: 108, width: w - left - pad - pw - 10, height: 14)
        percent.frame = NSRect(x: w - pad - pw, y: 105, width: pw, height: 20)
        // Step track: nodes spread across the full width under everything.
        let n = CGFloat(max(1, stepViews.count))
        let x0: CGFloat = 20, x1 = w - 20
        let slot = n > 1 ? (x1 - x0 - 56) / (n - 1) : 0
        for (i, v) in stepViews.enumerated() {
            let cx = n > 1 ? x0 + 28 + CGFloat(i) * slot : w / 2
            v.frame = NSRect(x: cx - 48, y: 136, width: 96, height: 60)
            if i > 0 {
                let prev = x0 + 28 + CGFloat(i - 1) * slot
                rail[i - 1].frame = NSRect(x: prev + 15, y: 148, width: cx - prev - 30, height: 2)
            }
        }
    }

    /// One row — three groups whose widths are summed explicitly so nothing can overlap:
    ///   [edge] avatar ·gap· Zera ·gap· chip  [group]  command (flex)  [group]  elapsed ·gap· bar ·gap· % [group] ⌄ ·gap· ✕ [edge]
    /// When the chip is long (e.g. "Needs your approval") the progress bar and % step aside so
    /// the command keeps a readable width; the elapsed time always stays.
    private func layoutCompact(w: CGFloat, h: CGFloat) {
        typealias C = Compact
        chip.compact = true
        stepViews.forEach { $0.isHidden = true }; rail.forEach { $0.isHidden = true }
        func mid(_ height: CGFloat) -> CGFloat { ((h - height) / 2).rounded() }

        // Left group.
        var x = C.edge
        avatar.frame = NSRect(x: x, y: 6, width: C.avatar, height: h - 10)
        x += C.avatar + C.gap
        title.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        title.frame = NSRect(x: x, y: mid(20), width: C.title, height: 20)
        x += C.title + C.gap
        let cw = min(C.chipMax, chip.fittedWidth)
        chip.frame = NSRect(x: x, y: mid(24), width: cw, height: 24)
        let leftEnd = x + cw

        // Right group, packed from the right edge.
        var r = w - C.edge
        r -= C.button
        closeButton.frame = NSRect(x: r, y: mid(C.button), width: C.button, height: C.button)
        r -= C.gap + C.button
        chevron.frame = NSRect(x: r, y: mid(C.button), width: C.button, height: C.button)
        r -= C.group                                   // right edge of the status cluster

        let progressW = C.percent + C.gap + C.bar + C.gap   // % · bar, in front of the elapsed time
        var clusterW = C.elapsed + progressW
        var commandW = r - clusterW - C.group - leftEnd - C.group
        let showProgress = commandW >= C.commandMin
        if !showProgress { clusterW = C.elapsed; commandW = r - clusterW - C.group - leftEnd - C.group }
        track.isHidden = !showProgress
        percent.isHidden = !showProgress

        var cx = r
        if showProgress {
            cx -= C.percent
            percent.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            percent.frame = NSRect(x: cx, y: mid(16), width: C.percent, height: 16)
            cx -= C.gap + C.bar
            track.frame = NSRect(x: cx, y: mid(10), width: C.bar, height: 10)
            cx -= C.gap
        }
        cx -= C.elapsed
        elapsed.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        elapsed.frame = NSRect(x: cx, y: mid(16), width: C.elapsed, height: 16)

        // Middle: the command box takes exactly what is left between the two groups.
        let showCommand = commandW >= 60
        commandBox.isHidden = !showCommand
        if showCommand {
            commandBox.frame = NSRect(x: leftEnd + C.group, y: mid(32), width: commandW, height: 32)
            promptGlyph.frame = NSRect(x: 10, y: 8, width: 20, height: 16)
            command.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            command.frame = NSRect(x: 32, y: 8, width: commandW - 42, height: 16)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered { Pal.surfaceHover.withAlphaComponent(0.3).setFill(); bounds.fill() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Pieces

/// Thick rounded bar: hatched empty track, blue→violet gradient fill with a soft sweep while
/// running, a glowing head dot; amber when waiting, green when done.
final class ProgressTrack: NSView {
    private let fill = CAGradientLayer()
    private let sweep = CAGradientLayer()
    private let head = CALayer()
    private let glow = CALayer()
    private var progress: Double = 0
    private var status: ClaudeSession.Status = .running
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        fill.startPoint = CGPoint(x: 0, y: 0.5); fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.masksToBounds = true
        layer?.addSublayer(fill)
        sweep.startPoint = CGPoint(x: 0, y: 0.5); sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.45).cgColor, NSColor.clear.cgColor]
        sweep.locations = [0, 0.5, 1]
        fill.addSublayer(sweep)
        glow.cornerRadius = 11
        layer?.addSublayer(glow)
        head.cornerRadius = 7
        head.borderWidth = 2.5
        layer?.addSublayer(head)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(progress p: Double, status st: ClaudeSession.Status, animated: Bool) {
        let p = max(0.03, min(1, p))
        let statusChanged = st != status
        progress = p; status = st
        let pal = Pal
        let colors: [CGColor]
        switch st {
        case .waiting: colors = [pal.warning.cgColor, pal.warning.cgColor]
        case .done: colors = [pal.success.cgColor, pal.success.cgColor]
        default: colors = [NSColor(srgbRed: 0.36, green: 0.52, blue: 0.98, alpha: 1).cgColor, pal.accent.cgColor, NSColor(srgbRed: 0.72, green: 0.45, blue: 0.98, alpha: 1).cgColor]
        }
        fill.colors = colors
        head.backgroundColor = (colors.last ?? pal.accent.cgColor)
        head.borderColor = NSColor.white.cgColor
        glow.backgroundColor = (st == .waiting ? pal.warning : (st == .done ? pal.success : pal.accent)).withAlphaComponent(0.35).cgColor
        head.isHidden = st == .done || st == .idle
        glow.isHidden = head.isHidden
        if statusChanged || sweep.animation(forKey: "sweep") == nil {
            sweep.removeAllAnimations()
            if st == .running, animated {
                let a = CABasicAnimation(keyPath: "locations")
                a.fromValue = [-1.0, -0.5, 0.0]; a.toValue = [1.0, 1.5, 2.0]
                a.duration = 1.8; a.repeatCount = .infinity
                sweep.add(a, forKey: "sweep")
            }
            glow.removeAllAnimations()
            if st != .done, animated {
                let b = CABasicAnimation(keyPath: "transform.scale")
                b.fromValue = 0.8; b.toValue = 1.25; b.duration = 0.9; b.autoreverses = true; b.repeatCount = .infinity
                glow.add(b, forKey: "pulse")
            }
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.45 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        place()
        CATransaction.commit()
    }

    private func place() {
        let h = bounds.height, w = bounds.width
        let fw = max(h, w * CGFloat(progress))
        fill.cornerRadius = h / 2
        fill.frame = CGRect(x: 0, y: 0, width: fw, height: h)
        sweep.frame = CGRect(x: 0, y: 0, width: fw, height: h)
        let hx = min(w - 8, fw - 2)
        head.frame = CGRect(x: hx - 7, y: h / 2 - 7, width: 14, height: 14)
        glow.frame = CGRect(x: hx - 11, y: h / 2 - 11, width: 22, height: 22)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); place(); CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        p.surfaceStrong.setFill(); path.fill()
        // Faint hatching on the empty part.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        p.border.withAlphaComponent(0.5).setStroke()
        var x: CGFloat = -bounds.height
        while x < bounds.width {
            let l = NSBezierPath(); l.move(to: NSPoint(x: x, y: bounds.height)); l.line(to: NSPoint(x: x + bounds.height, y: 0)); l.lineWidth = 1; l.stroke()
            x += 8
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A step on the track: circle (check / sparkle / dots), label, duration or "Pending".
final class StepNode: NSView {
    enum State { case done, active, pending }
    private let state: State
    private let label = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let ring = CAShapeLayer()
    override var isFlipped: Bool { true }

    init(title: String, sub s: String, state: State) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        let p = Pal
        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 12, weight: state == .active ? .bold : .semibold)
        label.textColor = state == .pending ? p.textSecondary : p.text
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        sub.stringValue = s
        sub.font = Typo.caption
        sub.textColor = state == .active ? p.accent : p.textTertiary
        sub.alignment = .center
        addSubview(sub)
        if state == .active, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 30, height: 30), transform: nil)
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = p.accent.cgColor
            ring.lineWidth = 2
            layer?.addSublayer(ring)
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1; grow.toValue = 1.5
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.8; fade.toValue = 0
            let g = CAAnimationGroup(); g.animations = [grow, fade]; g.duration = 1.5; g.repeatCount = .infinity
            ring.add(g, forKey: "pulse")
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        label.frame = NSRect(x: 0, y: 36, width: w, height: 16)
        sub.frame = NSRect(x: 0, y: 52, width: w, height: 14)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = CGRect(x: w / 2 - 15, y: 0, width: 30, height: 30)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let c = NSRect(x: bounds.midX - 15, y: 0, width: 30, height: 30)
        let symbol: String, bg: NSColor, fg: NSColor
        switch state {
        case .done: (symbol, bg, fg) = ("checkmark", p.success.withAlphaComponent(0.2), p.success)
        case .active: (symbol, bg, fg) = ("sparkle", p.accent, .white)
        case .pending: (symbol, bg, fg) = ("ellipsis", p.surfaceStrong, p.textTertiary)
        }
        bg.setFill(); NSBezierPath(ovalIn: c).fill()
        if state == .done { p.success.setFill(); NSBezierPath(ovalIn: c.insetBy(dx: 4, dy: 4)).fill() }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: state == .done ? 10 : 12, weight: .bold))?
            .withSymbolConfiguration(.init(paletteColors: [state == .done ? .white : fg])) {
            let s = img.size
            img.draw(in: NSRect(x: c.midX - s.width / 2, y: c.midY - s.height / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// The round "expand / collapse" button in the corner.
final class RoundChevron: NSView {
    var onTap: (() -> Void)?
    var pointsUp = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        p.surface.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        p.border.setStroke()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).stroke()
        if let img = NSImage(systemSymbolName: pointsUp ? "chevron.up" : "chevron.down", accessibilityDescription: pointsUp ? "Collapse" : "Expand")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [p.accent])) {
            let s = img.size
            img.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// "● Running" — dot + label in a soft tinted pill.
final class StatusChip: NSView {
    private let label = NSTextField(labelWithString: "")
    private var color: NSColor = .gray
    /// Smaller type and tighter padding for the one-row bar.
    var compact = false {
        didSet { guard compact != oldValue else { return }; label.font = font; needsLayout = true; needsDisplay = true }
    }
    override var isFlipped: Bool { true }

    private var font: NSFont { NSFont.systemFont(ofSize: compact ? 12 : 13, weight: .semibold) }
    private var dotX: CGFloat { compact ? 9 : 11 }      // dot inset; 8pt dot
    private var textX: CGFloat { compact ? 22 : 26 }    // where the label starts
    private var trailing: CGFloat { compact ? 10 : 12 } // after the label
    private var dotSize: CGFloat { compact ? 8 : 9 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 13
        label.font = font
        label.lineBreakMode = .byClipping
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, color c: NSColor) {
        color = c
        label.stringValue = text
        label.textColor = Pal.isDark ? c : (c.blended(withFraction: 0.35, of: .black) ?? c)
        layer?.backgroundColor = c.withAlphaComponent(Pal.isDark ? 0.18 : 0.15).cgColor
        needsDisplay = true; needsLayout = true
    }

    /// Exact width for the current text — dot inset + text + trailing padding, rounded up.
    var fittedWidth: CGFloat {
        ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + textX + trailing
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let th: CGFloat = compact ? 15 : 16
        label.frame = NSRect(x: textX, y: ((bounds.height - th) / 2).rounded(), width: max(0, bounds.width - textX - trailing), height: th)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: dotX, y: bounds.midY - dotSize / 2, width: dotSize, height: dotSize)).fill()
    }
}
