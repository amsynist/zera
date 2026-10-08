import AppKit

/// Claude Code's live readout as two dark glass wings hanging off Zera on either side of her rope:
///
///   ( ◯ Claude is working…       (⌄) )~~ Zera ~~( Running · 62%           4:12   ●  (–) )
///   ( ◯ Claude is ready          (⌄) )~~ Zera ~~( (>_) git commit -m "Update…  [✕ Reject] [✓ Approve]  ●  (–) )
///
/// Left wing — what Claude is doing: a gradient ring (spinning while it works), the headline,
/// the current step and ⌄ to open the session. Right wing — what it means for you: progress, session
/// time and the status orb while it runs, or the command waiting on you (up to two lines of it)
/// with Reject / Approve right there; `>_` (or the command itself) copies the whole command. The right wing springs wider to fit the command.
///
/// One transparent panel spans both wings. The gap in the middle is where she hangs (her window
/// sits above this one) and each wing tapers into a tendril that reaches into her. The wings
/// keep their navy-black look in light and dark mode.
final class LiveActivityView: NSView {
    enum Mode: Equatable { case idle, running, approval, attention, done }

    /// ⌄ on the left wing: open the session. The wing bodies themselves don't react to clicks.
    var onTap: (() -> Void)?
    /// Minimize button or right-click: hide until an approval, a finished turn or the Claude tab.
    var onMinimize: (() -> Void)?
    /// Approve (true) / Reject (false) on the right wing.
    var onDecide: ((HookRequest, Bool) -> Void)?
    /// Reply on a finished session's wing: you started typing (hold the session open), sent the
    /// reply, or cancelled it.
    var onReplyStart: (() -> Void)?
    var onReplySend: ((String) -> Void)?
    var onReplyCancel: (() -> Void)?

    /// The widest the panel gets; the controller narrows it to the screen.
    static let panelSize = NSSize(width: 1520, height: 92)

    /// Where she hangs, in this view's coordinates. The controller sets it after placing the panel.
    var centerX: CGFloat = LiveActivityView.panelSize.width / 2 { didSet { needsLayout = true; needsDisplay = true } }
    private(set) var mode: Mode = .idle
    private(set) var request: HookRequest?

    /// How long a finished session waits for a reply (for the draining bar).
    var replyWindow: Double = 20

    /// Wide enough for the command and both buttons; otherwise the approval card takes over.
    var canShowApproval: Bool { room(for: M.rightAsk) >= M.approvalMin }

    private enum M {
        static let wingH: CGFloat = 60
        static let tail: CGFloat = 70          // body end → her centre
        static let tip: CGFloat = 14           // the tendril ends this far from her centre (behind her)
        static let edge: CGFloat = 18          // outer margin, room for the glow
        static let leftMax: CGFloat = 430
        static let rightRun: CGFloat = 430     // right wing while Claude works
        static let rightAsk: CGFloat = 760     // right wing with a command, Reject and Approve
        static let minWing: CGFloat = 220
        static let approvalMin: CGFloat = 520
        static let button: CGFloat = 44        // round buttons, glow included
        static let orb: CGFloat = 34
    }

    // Left wing.
    private let ring = RingGlyph()
    private let leftTitle = LiveActivityView.label()
    private let leftSub = LiveActivityView.label()
    /// ⌄ on the left wing: the only way to expand the wings into the Claude screen.
    private let expand = GlowIconButton(symbol: "chevron.down")

    // Right wing.
    private let status = LiveActivityView.label()
    private let clock = LiveActivityView.label()
    private let bar = GlowProgressBar()
    private let orb = OrbView()
    /// The `>_` in front of the command; it turns into a copy button under the pointer.
    private let prompt = CommandCopyButton()
    private let command = LiveActivityView.label()
    private let reject = GlowPillButton(title: "Reject", symbol: "xmark", tint: .red)
    private let approve = GlowPillButton(title: "Approve", symbol: "checkmark", tint: .green)
    private let minimize = GlowIconButton(symbol: "minus")
    /// Done: "Reply" while the session still waits for one; then a field and Send in its place.
    private let replyButton = GlowPillButton(title: "Reply", symbol: "arrowshape.turn.up.left.fill", tint: .blue)
    private let replyBox = NSView()
    private let replyField = NSTextField()
    private let sendButton = GlowPillButton(title: "Send", symbol: "paperplane.fill", tint: .green)
    /// Typing a reply on the right wing.
    private(set) var composing = false

    /// A soft glow behind her in the state's colour. It lives here rather than in her window so
    /// her window's shadow never traces it.
    private let glow = CAGradientLayer()
    /// v2: energy running along each wing's top edge toward her, in the state's colour.
    private let energyClipL = CALayer(), energyClipR = CALayer()
    private let energyL = CAGradientLayer(), energyR = CAGradientLayer()
    /// Each wing's outline (a crisp line plus a soft bloom) masks its light, so the light
    /// traces the border round the rounded end and along the tail instead of running straight.
    private let energyMaskL = CALayer(), energyMaskR = CALayer()
    private let energyLineL = CAShapeLayer(), energyLineR = CAShapeLayer()
    private let energyBloomL = CAShapeLayer(), energyBloomR = CAShapeLayer()
    /// The state's colour: accent while Claude works, amber when it needs you, green when done.
    private var stateColor: NSColor = Neon.accent

    private var leftBody = NSRect.zero
    private var rightBody = NSRect.zero
    private var leftPath = NSBezierPath()
    private var rightPath = NSBezierPath()

    /// The right wing's width springs between `rightRun` and `rightAsk`.
    private var rightW: CGFloat = M.rightRun
    private var rightV: CGFloat = 0
    private var rightTarget: CGFloat = M.rightRun
    private var springTimer: Timer?
    private var lastSpringAt: CFTimeInterval = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        [ring, leftTitle, leftSub, expand, status, clock, bar, orb, prompt, command, reject, approve, minimize,
         replyButton, replyBox, sendButton].forEach { addSubview($0) }
        replyBox.wantsLayer = true
        replyBox.layer?.cornerRadius = 17
        replyBox.layer?.borderWidth = 1
        replyBox.layer?.borderColor = Neon.chipEdge.cgColor
        replyBox.layer?.backgroundColor = Neon.field.cgColor
        replyField.isBordered = false
        replyField.drawsBackground = false
        replyField.focusRingType = .none
        replyField.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        replyField.textColor = Neon.text
        replyField.cell?.usesSingleLineMode = true
        replyField.cell?.isScrollable = true
        replyField.placeholderAttributedString = NSAttributedString(string: "Reply to Claude…", attributes: [
            .foregroundColor: Neon.textFaint, .font: NSFont.systemFont(ofSize: 14, weight: .medium)])
        replyField.delegate = self
        replyField.setAccessibilityLabel("Reply to Claude")
        replyBox.addSubview(replyField)
        replyButton.onTap = { [weak self] in self?.startReply() }
        replyButton.toolTip = "Reply: Claude carries on in this session"
        sendButton.onTap = { [weak self] in self?.sendReply() }
        [replyButton, replyBox, sendButton].forEach { $0.isHidden = true }
        expand.onTap = { [weak self] in self?.onTap?() }
        expand.setAccessibilityLabel("Open the Claude session")
        expand.toolTip = "Open the session"
        minimize.onTap = { [weak self] in self?.onMinimize?() }
        minimize.setAccessibilityLabel("Minimize Claude activity")
        minimize.toolTip = "Minimize — back for approvals, finished sessions or the Claude tab"
        prompt.onTap = { [weak self] in self?.copyCommand() }
        // Clicking the command itself copies it too.
        command.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(commandClicked)))
        reject.onTap = { [weak self] in self?.decide(false) }
        approve.onTap = { [weak self] in self?.decide(true) }
        clock.alignment = .right
        // The command gets two lines, broken anywhere, so long shell lines stay readable.
        command.maximumNumberOfLines = 2
        command.lineBreakMode = .byCharWrapping
        command.cell?.truncatesLastVisibleLine = true
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(glow)
        for (clip, mask, crisp, bloom) in [(energyClipL, energyMaskL, energyLineL, energyBloomL),
                                           (energyClipR, energyMaskR, energyLineR, energyBloomR)] {
            for (l, w, a) in [(bloom, CGFloat(5), CGFloat(0.35)), (crisp, CGFloat(1.6), CGFloat(1))] {
                l.fillColor = nil
                l.strokeColor = NSColor.white.withAlphaComponent(a).cgColor
                l.lineWidth = w
                l.lineJoin = .round
                mask.addSublayer(l)
            }
            clip.mask = mask
        }
        for (clip, line) in [(energyClipL, energyL), (energyClipR, energyR)] {
            line.startPoint = CGPoint(x: 0, y: 0.5)
            line.endPoint = CGPoint(x: 1, y: 0.5)
            clip.addSublayer(line)
            layer?.addSublayer(clip)
        }
        if !Motion.reduced {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0.55; a.toValue = 1; a.duration = 1.3
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(a, forKey: "pulse")
        }
        setAccessibilityRole(.group)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { springTimer?.invalidate() }

    private static func label() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.wantsLayer = true
        return l
    }

    /// The whole command, not the two lines that fit on the wing.
    private var fullCommand = ""

    @objc private func commandClicked() { copyCommand() }

    /// Puts the full command on the clipboard; the `>_` turns into a green check for a moment.
    private func copyCommand() {
        guard !fullCommand.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullCommand, forType: .string)
        prompt.flashCopied()
        SoundService.shared.play(.button)
    }

    private func startReply() {
        guard !composing else { return }
        composing = true
        onReplyStart?()
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(replyField)
        SoundService.shared.play(.button)
    }

    private func sendReply() {
        let text = replyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard composing, !text.isEmpty else { NSSound.beep(); return }
        composing = false
        replyField.stringValue = ""
        window?.makeFirstResponder(nil)
        onReplySend?(text)
    }

    /// Esc, or the session moved on: fold the field away.
    func cancelReply(notify: Bool = true) {
        guard composing else { return }
        composing = false
        replyField.stringValue = ""
        window?.makeFirstResponder(nil)
        if notify { onReplyCancel?() }
        needsLayout = true
    }

    private func decide(_ allow: Bool) {
        guard let r = request else { return }
        onDecide?(r, allow)
    }

    /// Light ↔ dark: the wings keep their own look, but redraw so system colours settle.
    func themeChanged() {
        restyle()
        [ring, expand, bar, orb, prompt, reject, approve, minimize].forEach { $0.needsDisplay = true }
        ring.refresh(); bar.refresh(); orb.themeChanged()
        replyBox.layer?.borderColor = Neon.chipEdge.cgColor
        replyBox.layer?.backgroundColor = Neon.field.cgColor
        replyField.textColor = Neon.text
        replyField.placeholderAttributedString = NSAttributedString(string: "Reply to Claude…", attributes: [
            .foregroundColor: Neon.textFaint, .font: NSFont.systemFont(ofSize: 14, weight: .medium)])
        needsDisplay = true
    }

    private func restyle() {
        leftTitle.font = NSFont.systemFont(ofSize: 14.5, weight: .bold)
        leftTitle.textColor = Neon.text
        leftSub.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        leftSub.textColor = Neon.textDim
        command.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
        command.textColor = Neon.text
        clock.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        clock.textColor = Neon.textDim
    }

    // MARK: - Content

    /// Everything from the session and the first pending approval; safe to call every second.
    func update(session s: ClaudeSession?, pending: HookRequest?) {
        request = pending
        let newMode: Mode
        if pending != nil { newMode = .approval }
        else if let s = s {
            switch s.status {
            case .running: newMode = .running
            case .waiting: newMode = .attention
            case .done: newMode = .done
            case .idle, .ended: newMode = .idle
            }
        } else { newMode = .idle }
        let wasAsking = mode == .approval
        let modeChanged = newMode != mode
        mode = newMode

        let elapsed: String? = s?.promptAt == nil ? nil : s.map { ClaudeActivityCard.clock($0.elapsed) }
        let current = s?.steps.last(where: { !$0.finished }) ?? s?.steps.last
        let task = s.map { ClaudeActivityService.oneLine($0.title, max: 60) } ?? ""

        // Left wing.
        switch mode {
        case .idle:
            ring.set(.idle)
            set(leftTitle, "Claude is ready")
            set(leftSub, "Ask me anything…")
        case .running:
            ring.set(.spinning)
            set(leftTitle, "Claude is working…")
            let step: String? = current.map { $0.finished || $0.progressLine.isEmpty ? $0.text : "\($0.text)…" }
            set(leftSub, step ?? (task.isEmpty ? "Thinking…" : task))
        case .approval:
            ring.set(.breathing)
            set(leftTitle, "Claude is ready")
            set(leftSub, pending?.detail.map { ClaudeActivityService.oneLine($0, max: 60) }
                ?? (task.isEmpty ? "Waiting on your OK to continue" : task))
        case .attention:
            ring.set(.waiting)
            set(leftTitle, "Claude needs you")
            set(leftSub, task.isEmpty ? "Waiting for your reply" : task)
        case .done:
            ring.set(.done)
            set(leftTitle, "Claude is done")
            set(leftSub, task.isEmpty ? "All finished" : task)
        }

        // A finished session still waiting for a reply shows Reply (and the field once you tap it).
        let offering = mode == .done && (s?.canReply ?? false)
        if composing, mode != .done || !(s?.replyHeld ?? false) { cancelReply(notify: false) }
        let typing = composing && mode == .done

        // Right wing: status line, time and bar — or the command with its two buttons.
        // The orb and minimize stay in both.
        let asking = mode == .approval
        let runGroup: [NSView] = [status, clock, bar]
        let askGroup: [NSView] = [prompt, command, reject, approve]
        runGroup.forEach { $0.isHidden = asking || typing }
        askGroup.forEach { $0.isHidden = !asking }
        replyButton.isHidden = !offering || typing
        replyBox.isHidden = !typing
        sendButton.isHidden = !typing
        if asking != wasAsking { fadeIn(asking ? askGroup : runGroup) }

        let p = s?.progress ?? 0
        let real = s?.hasRealProgress ?? false
        // While a reply is offered the countdown needs the room; the session time steps aside.
        set(clock, mode == .idle || offering ? "" : (elapsed ?? ""))
        switch mode {
        case .idle:
            status.attributedStringValue = Self.statusLine("Ready", detail: "waiting for your next request")
            bar.set(progress: 0, tint: .accent)
            orb.set(.working)
        case .running:
            // The percentage is only real when Claude keeps a plan; otherwise the bar sweeps.
            status.attributedStringValue = Self.statusLine("Running", detail: real ? "\(Int((p * 100).rounded(.down)))%" : nil, strong: true)
            bar.set(progress: real ? p : 0, tint: .accent, indeterminate: !real)
            orb.set(.working)
        case .approval:
            set(command, ClaudeActivityService.oneLine(pending?.command ?? "", max: 240))
            command.toolTip = (pending?.command).map { "\($0)\n\nClick to copy" }
            fullCommand = pending?.command ?? ""
            orb.set(.waiting)
        case .attention:
            status.attributedStringValue = Self.statusLine("Waiting", detail: "reply in \(s?.folderName ?? "the terminal")", warn: true)
            bar.set(progress: p, tint: .warning)
            orb.set(.waiting)
        case .done:
            if offering, let until = s?.replyUntil, !(s?.replyHeld ?? false) {
                // The green bar drains while the session waits for a reply.
                let left = max(0, until.timeIntervalSinceNow)
                status.attributedStringValue = Self.statusLine("Done", detail: "reply · \(Int(left.rounded(.up)))s", strong: true, good: true)
                bar.set(progress: min(1, left / max(1, replyWindow)), tint: .success)
            } else {
                status.attributedStringValue = Self.statusLine("Done", detail: "100%", strong: true, good: true)
                bar.set(progress: 1, tint: .success)
            }
            orb.set(.done)
        }

        setAccessibilityLabel(asking
            ? "Claude needs your approval: \(command.stringValue)"
            : "\(leftTitle.stringValue), \(leftSub.stringValue). \(status.stringValue) \(clock.stringValue)")
        switch mode {
        case .approval, .attention: stateColor = Neon.warning
        case .done: stateColor = Neon.green
        case .idle, .running: stateColor = Neon.accent
        }
        // An eased falloff that reaches nothing well inside the layer, so no edge ever shows.
        glow.colors = [0.42, 0.3, 0.16, 0.06, 0.015, 0].map { stateColor.withAlphaComponent($0).cgColor }
        glow.locations = [0, 0.25, 0.5, 0.72, 0.88, 1]
        let hot = stateColor.blended(withFraction: 0.45, of: .white) ?? stateColor
        let line = [stateColor.withAlphaComponent(0).cgColor, stateColor.withAlphaComponent(0.9).cgColor,
                    hot.cgColor, stateColor.withAlphaComponent(0.9).cgColor, stateColor.withAlphaComponent(0).cgColor]
        energyL.colors = line; energyR.colors = line
        if modeChanged { restartEnergy() }
        springRight(to: asking || typing ? M.rightAsk : M.rightRun)
        needsLayout = true
        if modeChanged { needsDisplay = true }
    }

    /// "Running · 62%" — the word in the main colour, the detail in the accent.
    private static func statusLine(_ word: String, detail: String?, strong: Bool = false, warn: Bool = false, good: Bool = false) -> NSAttributedString {
        let tint = warn ? Neon.warning : (good ? Neon.green : Neon.accent)
        let s = NSMutableAttributedString(string: word, attributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .medium), .foregroundColor: Neon.text.withAlphaComponent(0.9)])
        guard let detail = detail else { return s }
        s.append(NSAttributedString(string: "  ·  ", attributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .bold), .foregroundColor: Neon.textDim]))
        s.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13.5, weight: strong ? .semibold : .regular),
            .foregroundColor: strong ? tint : Neon.textDim]))
        return s
    }

    /// Cross-fades a label only when its text actually changes.
    private func set(_ label: NSTextField, _ text: String) {
        guard label.stringValue != text else { return }
        if !Motion.reduced {
            let t = CATransition(); t.type = .fade; t.duration = 0.25
            label.layer?.add(t, forKey: "text")
        }
        label.stringValue = text
    }

    /// The incoming half of the right wing fades in once the wing has started to resize.
    private func fadeIn(_ views: [NSView]) {
        guard !Motion.reduced else { return }
        for v in views {
            v.wantsLayer = true
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0; a.toValue = 1
            a.beginTime = CACurrentMediaTime() + 0.16
            a.duration = 0.22
            a.fillMode = .backwards
            v.layer?.add(a, forKey: "fadeIn")
        }
    }

    // MARK: - Right wing spring

    private func springRight(to target: CGFloat) {
        guard target != rightTarget else { return }
        rightTarget = target
        if Motion.reduced || window == nil { rightW = target; rightV = 0; needsLayout = true; needsDisplay = true; return }
        guard springTimer == nil else { return }
        lastSpringAt = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepSpring() }
        RunLoop.main.add(t, forMode: .common)
        springTimer = t
    }

    private func stepSpring() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, now - lastSpringAt))
        lastSpringAt = now
        let force = (rightTarget - rightW) * 170 - rightV * 20
        rightV += force * dt
        rightW += rightV * dt
        if abs(rightTarget - rightW) < 0.3, abs(rightV) < 0.3 {
            rightW = rightTarget; rightV = 0
            springTimer?.invalidate(); springTimer = nil
        }
        needsLayout = true
        needsDisplay = true
    }

    /// How wide the right wing can be at `width`, after clamping to the panel edge.
    private func room(for width: CGFloat) -> CGFloat {
        let rx0 = centerX + M.tail
        return max(0, min(bounds.width - M.edge, rx0 + width) - rx0)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let y = ((bounds.height - M.wingH) / 2).rounded()
        let mid = y + M.wingH / 2

        let lx1 = centerX - M.tail
        let lx0 = max(M.edge, lx1 - M.leftMax)
        leftBody = NSRect(x: lx0, y: y, width: max(0, lx1 - lx0), height: M.wingH)
        rightBody = NSRect(x: centerX + M.tail, y: y, width: room(for: rightW), height: M.wingH)

        leftPath = Self.wing(body: leftBody, inward: 1, tip: NSPoint(x: centerX - M.tip, y: mid))
        rightPath = Self.wing(body: rightBody, inward: -1, tip: NSPoint(x: centerX + M.tip, y: mid))

        CATransaction.begin(); CATransaction.setDisableActions(true)
        // A wide, soft oval that fits inside the panel (a taller one was cut flat top and
        // bottom and read as a square); it reaches out along the wings for an ambient wash.
        glow.frame = CGRect(x: centerX - 170, y: 0, width: 340, height: bounds.height)
        // The energy runs round each wing's outline: the light sweeps across the wing and the
        // outline mask lets it show only on the border, curves and tail included.
        let oldL = energyClipL.frame, oldR = energyClipR.frame
        energyClipL.frame = CGRect(x: leftBody.minX - 4, y: 0, width: max(0, centerX - leftBody.minX + 4), height: bounds.height)
        energyClipR.frame = CGRect(x: centerX, y: 0, width: max(0, rightBody.maxX + 4 - centerX), height: bounds.height)
        for (clip, mask, crisp, bloom, path) in [(energyClipL, energyMaskL, energyLineL, energyBloomL, leftPath),
                                                 (energyClipR, energyMaskR, energyLineR, energyBloomR, rightPath)] {
            mask.frame = clip.bounds
            var t = CGAffineTransform(translationX: -clip.frame.minX, y: 0)
            let cg = path.cgPathCompat.copy(using: &t)
            for l in [crisp, bloom] { l.frame = clip.bounds; l.path = cg }
        }
        energyClipL.isHidden = leftBody.width < M.minWing
        energyClipR.isHidden = rightBody.width < M.minWing
        CATransaction.commit()
        if oldL.width != energyClipL.frame.width || oldR.width != energyClipR.frame.width { restartEnergy() }

        layoutLeft(mid: mid)
        layoutRight(mid: mid)
        window?.invalidateCursorRects(for: self)
    }

    private func layoutLeft(mid: CGFloat) {
        let b = leftBody
        let show = b.width >= M.minWing
        [ring, leftTitle, leftSub, expand].forEach { $0.isHidden = !show }
        guard show else { return }
        ring.frame = NSRect(x: b.minX + 10, y: mid - 22, width: 44, height: 44)
        // Keep minimize reachable when the right wing folds away near a screen edge.
        let minimizeOnLeft = rightBody.width < M.minWing
        if minimizeOnLeft {
            minimize.frame = NSRect(x: b.maxX - 4 - M.button, y: mid - M.button / 2, width: M.button, height: M.button)
        }
        expand.frame = NSRect(x: b.maxX - 4 - M.button - (minimizeOnLeft ? M.button : 0),
                             y: mid - M.button / 2, width: M.button, height: M.button)
        let textX = ring.frame.maxX + 12
        let textW = max(0, expand.frame.minX - 10 - textX)
        leftTitle.frame = NSRect(x: textX, y: mid - 21, width: textW, height: 21)
        leftSub.frame = NSRect(x: textX, y: mid + 2, width: textW, height: 18)
    }

    private func layoutRight(mid: CGFloat) {
        let b = rightBody
        let show = b.width >= M.minWing
        let all: [NSView] = [status, clock, bar, orb, prompt, command, reject, approve, replyButton, replyBox, sendButton]
        if !show {
            all.forEach { $0.isHidden = true }
            minimize.isHidden = leftBody.width < M.minWing
            return
        }
        minimize.isHidden = false
        orb.isHidden = false
        minimize.frame = NSRect(x: b.maxX - 8 - M.button, y: mid - M.button / 2, width: M.button, height: M.button)
        orb.frame = NSRect(x: minimize.frame.minX - 4 - M.orb, y: mid - M.orb / 2, width: M.orb, height: M.orb)
        if mode == .approval {
            let aw = approve.fittedWidth, rw = reject.fittedWidth
            approve.frame = NSRect(x: orb.frame.minX - 6 - aw, y: mid - 22, width: aw, height: 44)
            reject.frame = NSRect(x: approve.frame.minX - 2 - rw, y: mid - 22, width: rw, height: 44)
            prompt.frame = NSRect(x: b.minX + 26, y: mid - 22, width: 44, height: 44)
            let cx = prompt.frame.maxX + 8
            let cw = max(0, reject.frame.minX - 8 - cx)
            // One line when it fits, two when it is long; centred on the wing either way.
            let lines = command.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: cw, height: 100)).height ?? 17
            let ch = min(36, max(17, ceil(lines)))
            command.frame = NSRect(x: cx, y: (mid - ch / 2).rounded(), width: cw, height: ch)
        } else if composing, mode == .done {
            let sw = sendButton.fittedWidth
            sendButton.frame = NSRect(x: orb.frame.minX - 6 - sw, y: mid - 22, width: sw, height: 44)
            replyBox.frame = NSRect(x: b.minX + 30, y: mid - 17, width: max(0, sendButton.frame.minX - 10 - b.minX - 30), height: 34)
            replyField.frame = NSRect(x: 14, y: 7, width: max(0, replyBox.frame.width - 28), height: 20)
        } else {
            let sx = b.minX + 36
            var right = orb.frame.minX
            if !replyButton.isHidden {
                let rw = replyButton.fittedWidth
                replyButton.frame = NSRect(x: orb.frame.minX - 6 - rw, y: mid - 22, width: rw, height: 44)
                right = replyButton.frame.minX
            }
            let sw = max(0, right - 14 - sx)
            let clockW: CGFloat = clock.stringValue.isEmpty ? 0 : 56
            clock.frame = NSRect(x: sx + sw - 56, y: mid - 19, width: 56, height: 17)
            status.frame = NSRect(x: sx, y: mid - 22, width: max(0, sw - clockW - (clockW > 0 ? 4 : 0)), height: 21)
            bar.frame = NSRect(x: sx, y: mid + 8, width: sw, height: 6)
        }
    }

    /// A pill whose inner end swells into a tail and tapers to a point at `tip`.
    /// `inward` is +1 when the tail points right (the left wing), −1 for the right wing.
    static func wing(body b: NSRect, inward d: CGFloat, tip: NSPoint) -> NSBezierPath {
        let path = NSBezierPath()
        guard b.width > 0 else { return path }
        let r = b.height / 2
        let outer = d > 0 ? b.minX : b.maxX
        let inner = d > 0 ? b.maxX : b.minX
        let cap = outer + d * r
        let top = b.minY, bottom = b.maxY
        let cpOut: CGFloat = 28, cpIn: CGFloat = 20
        let tipRadius: CGFloat = 3
        let tipCenter = NSPoint(x: tip.x - d * tipRadius, y: tip.y)

        path.move(to: NSPoint(x: cap, y: top))
        path.line(to: NSPoint(x: inner, y: top))
        path.curve(to: NSPoint(x: tipCenter.x, y: tip.y - tipRadius), controlPoint1: NSPoint(x: inner + d * cpOut, y: top),
                   controlPoint2: NSPoint(x: tip.x - d * cpIn, y: tip.y - tipRadius))
        // A rounded nose joins the mirrored top and bottom curves without a sharp seam.
        path.appendArc(withCenter: tipCenter, radius: tipRadius, startAngle: 270, endAngle: 90, clockwise: d < 0)
        path.curve(to: NSPoint(x: inner, y: bottom), controlPoint1: NSPoint(x: tip.x - d * cpIn, y: tip.y + tipRadius),
                   controlPoint2: NSPoint(x: inner + d * cpOut, y: bottom))
        path.line(to: NSPoint(x: cap, y: bottom))
        // Round outer end: bottom (90°) → top (270°) through the outer side.
        path.appendArc(withCenter: NSPoint(x: cap, y: b.midY), radius: r, startAngle: 90, endAngle: 270, clockwise: d < 0)
        path.close()

        return path
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if leftBody.width >= M.minWing { drawWing(leftPath, body: leftBody, inward: 1) }
        if rightBody.width >= M.minWing { drawWing(rightPath, body: rightBody, inward: -1) }
    }

    private func drawWing(_ path: NSBezierPath, body: NSRect, inward d: CGFloat) {
        // Dark glass with a deep drop shadow and a soft halo in the state's colour.
        Neon.glowing(NSColor.black.withAlphaComponent(0.6), blur: 22) { Neon.fillBottom.setFill(); path.fill() }
        Neon.glowing(stateColor.withAlphaComponent(0.3), blur: 18) { Neon.fillBottom.setFill(); path.fill() }
        NSGradient(starting: Neon.fillTop.withAlphaComponent(1), ending: Neon.fillBottom.withAlphaComponent(1))?.draw(in: path, angle: -90)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The sinew: the tail toward her takes on the state's colour, so both wings read as
        // one body with her.
        let inner = d > 0 ? body.maxX : body.minX
        if let tail = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [Neon.fillBottom.withAlphaComponent(0).cgColor,
                                          (Neon.fillBottom.blended(withFraction: 0.35, of: stateColor) ?? stateColor).cgColor] as CFArray,
                                 locations: [0, 1]) {
            ctx.saveGState()
            ctx.addPath(path.cgPathCompat)
            ctx.clip()
            ctx.drawLinearGradient(tail, start: CGPoint(x: inner - d * 10, y: body.midY), end: CGPoint(x: centerX - d * M.tip, y: body.midY), options: [])
            ctx.restoreGState()
        }

        // The hairline edge: the theme's edge, warming into the state's colour toward her.
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                  colors: [Neon.edge.cgColor, stateColor.withAlphaComponent(0.75).cgColor,
                           stateColor.withAlphaComponent(0.55).cgColor] as CFArray,
                  locations: [0, 0.8, 1]) else { return }
        let from = inner - d * 130
        let to = centerX - d * M.tip
        ctx.saveGState()
        ctx.addPath(path.cgPathCompat)
        ctx.setLineWidth(1.3)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: from, y: body.midY),
                               end: CGPoint(x: to, y: body.midY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// The light that runs along the top edges toward her, again and again (none with Reduce Motion).
    private func restartEnergy() {
        for (clip, line, toward) in [(energyClipL, energyL, CGFloat(1)), (energyClipR, energyR, CGFloat(-1))] {
            line.removeAllAnimations()
            let w = clip.bounds.width
            CATransaction.begin(); CATransaction.setDisableActions(true)
            line.frame = CGRect(x: 0, y: 0, width: 180, height: clip.bounds.height)
            line.opacity = Motion.reduced || mode == .idle ? 0 : 1
            CATransaction.commit()
            guard !Motion.reduced, mode != .idle, w > 0 else { continue }
            let from = toward > 0 ? -90 : w + 90, to = toward > 0 ? w + 20 : -20
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = from; move.toValue = to
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]; fade.keyTimes = [0, 0.3, 0.85, 1]
            let g = CAAnimationGroup()
            g.animations = [move, fade]
            g.duration = mode == .approval || mode == .attention ? 1.6 : 2.2
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            line.add(g, forKey: "flow")
        }
    }

    // MARK: - Mouse

    /// Whether `p` (view coordinates) is on a wing, with a little slack for the glow.
    func wingContains(_ p: NSPoint) -> Bool {
        onWing(p) || onWing(NSPoint(x: p.x, y: p.y - 4)) || onWing(NSPoint(x: p.x, y: p.y + 4))
    }

    private func onWing(_ p: NSPoint) -> Bool {
        (leftBody.width >= M.minWing && leftPath.contains(p)) || (rightBody.width >= M.minWing && rightPath.contains(p))
    }

    /// Only the wings take clicks; the transparent rest of the panel lets them through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview.map { convert(point, from: $0) } ?? point
        guard onWing(p) else { return nil }
        // Buttons (and the command, which copies) take their own clicks; the rest of the wing
        // only holds the pointer so clicks don't fall through to the window behind.
        let v = super.hitTest(point)
        if let v = v, !replyBox.isHidden, v === replyBox || v.isDescendant(of: replyBox) { return v }
        return (v is GlowIconButton || v is GlowPillButton || v is CommandCopyButton || v === command) ? v : self
    }

    /// The wing body itself does nothing on click: ⌄ expands, the buttons act.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) { onMinimize?() }
    override func resetCursorRects() {
        if !command.isHidden { addCursorRect(command.frame, cursor: .pointingHand) }
    }
}

extension LiveActivityView: NSTextFieldDelegate {
    /// ⏎ sends the reply, Esc cancels it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): sendReply(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancelReply(); return true
        default: return false
        }
    }
}

private extension NSBezierPath {
    /// `cgPath` only arrived in macOS 14; build it by hand for 13.
    var cgPathCompat: CGPath {
        let path = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo: path.move(to: pts[0])
            case .lineTo: path.addLine(to: pts[0])
            case .curveTo: path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: path.closeSubpath()
            default: break
            }
        }
        return path
    }
}

// MARK: - Look

/// The wings' colours, from the chosen theme (`ThemeStore`): the theme's dark glass with its
/// accent as the glow. Tasks and the app opener share them. They keep this look whatever macOS
/// is set to: they sit on the desktop under the notch, where a dark wing reads best.
enum Neon {
    private static var t: ZeraTheme { ThemeStore.shared.current }

    static var fillTop: NSColor { t.glassTop.withAlphaComponent(0.97) }
    static var fillBottom: NSColor { t.glassBottom.withAlphaComponent(0.97) }
    static var edge: NSColor { t.edge }
    static var halo: NSColor { t.accent.withAlphaComponent(0.38) }
    /// The bright end of the accent gradient (rings, bars, glows).
    static var cyan: NSColor { t.accent }
    /// The far end of the accent gradient.
    static var violet: NSColor { t.accentDeep }
    static var accent: NSColor { t.accent }
    static var text: NSColor { t.text }
    static var textDim: NSColor { t.textSecondary }
    static var glyph: NSColor { t.textSecondary.blended(withFraction: 0.3, of: t.accent) ?? t.textSecondary }
    static var chip: NSColor { t.surface }
    static var chipHover: NSColor { t.surfaceHover }
    static var chipEdge: NSColor { t.border.withAlphaComponent(min(1, t.border.alphaComponent * 1.8)) }
    static var track: NSColor { t.surfaceStrong }
    static var red: NSColor { t.danger }
    static var green: NSColor { t.success }
    static var warning: NSColor { t.warning }
    /// The theme's second colour, paired with the accent.
    static var highlight: NSColor { t.highlight }
    /// Rows and tiles inside the panels.
    static var row: NSColor { t.row }
    static var field: NSColor { t.field }
    static var divider: NSColor { t.divider }
    static var textFaint: NSColor { t.textTertiary }
    static var onAccent: NSColor { t.onAccent }

    /// Draws an SF Symbol centred in `rect`.
    static func symbol(_ name: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) else { return }
        let s = img.size
        img.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Runs `body` with a coloured glow behind whatever it draws.
    static func glowing(_ color: NSColor, blur: CGFloat, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = color
        s.shadowBlurRadius = blur
        s.shadowOffset = .zero
        s.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The round chips' look: soft fill, hairline edge, faint glow.
    static func drawChip(_ shape: NSBezierPath, hovered: Bool) {
        glowing(halo.withAlphaComponent(hovered ? 0.8 : 0.4), blur: hovered ? 8 : 5) {
            (hovered ? chipHover : chip).setFill(); shape.fill()
        }
        chipEdge.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

// MARK: - Pieces

/// The ring at the start of the left wing: a thick cyan → violet arc, spinning while Claude
/// works, still and breathing its glow while a command waits on you, pulsing amber while Claude
/// waits for a reply, a full green ring when done.
final class RingGlyph: NSView {
    enum Style { case idle, spinning, breathing, waiting, done }
    private let track = CAShapeLayer()
    private let spinner = CALayer()           // rotates; holds the gradient masked to the arc
    private let gradient = CAGradientLayer()
    private let arc = CAShapeLayer()
    private var style: Style = .idle
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        track.fillColor = NSColor.clear.cgColor
        track.lineWidth = 6
        layer?.addSublayer(track)
        arc.fillColor = NSColor.clear.cgColor
        arc.strokeColor = NSColor.black.cgColor
        arc.lineWidth = 6
        arc.lineCap = .round
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.mask = arc
        spinner.addSublayer(gradient)
        spinner.shadowOpacity = 0.8
        spinner.shadowRadius = 4
        spinner.shadowOffset = .zero
        layer?.addSublayer(spinner)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ st: Style) {
        guard st != style else { return }
        style = st
        refresh()
    }

    /// Colours and motion for the current style.
    func refresh() {
        let colors: [NSColor]
        switch style {
        case .idle, .spinning, .breathing: colors = [Neon.violet, Neon.cyan, Neon.accent, Neon.violet]
        case .waiting: colors = [Neon.warning, Neon.warning.withAlphaComponent(0.6), Neon.warning]
        case .done: colors = [Neon.green, Neon.green]
        }
        track.strokeColor = Neon.track.cgColor
        gradient.colors = colors.map { $0.cgColor }
        spinner.shadowColor = (style == .done ? Neon.green : (style == .waiting ? Neon.warning : Neon.cyan)).cgColor
        arc.strokeEnd = style == .done ? 1 : 0.78
        spinner.removeAllAnimations()
        guard !Motion.reduced else { return }
        switch style {
        case .spinning:
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi
            a.duration = 1.2; a.repeatCount = .infinity
            spinner.add(a, forKey: "spin")
        case .breathing:
            let a = CABasicAnimation(keyPath: "shadowRadius")
            a.fromValue = 3; a.toValue = 10; a.duration = 1.0
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            spinner.add(a, forKey: "breathe")
        case .waiting:
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.45; a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
            spinner.add(a, forKey: "pulse")
        case .idle, .done: break
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = bounds
        let ring = CGPath(ellipseIn: b.insetBy(dx: 6, dy: 6), transform: nil)
        track.frame = b; track.path = ring
        spinner.frame = b
        gradient.frame = b
        arc.frame = b; arc.path = ring
        CATransaction.commit()
    }
}

/// Thin rounded progress bar: cyan → violet fill with a soft glow and a light sweeping across it.
/// Without a real percentage it runs indeterminate: a short segment gliding along the track.
final class GlowProgressBar: NSView {
    enum Tint { case accent, warning, success }
    private let fill = CAGradientLayer()
    private let sheenClip = CALayer()         // the fill's shape, clipping the sheen
    private let sheen = CAGradientLayer()
    private var progress: CGFloat = 0
    private var tint: Tint = .accent
    private var indeterminate = false
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        fill.startPoint = CGPoint(x: 0, y: 0.5); fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.shadowOpacity = 0.7
        fill.shadowRadius = 5
        fill.shadowOffset = .zero
        layer?.addSublayer(fill)
        sheenClip.masksToBounds = true
        sheen.startPoint = CGPoint(x: 0, y: 0.5); sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.55).cgColor,
                        NSColor.white.withAlphaComponent(0).cgColor]
        sheenClip.addSublayer(sheen)
        layer?.addSublayer(sheenClip)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(progress p: Double, tint t: Tint, indeterminate ind: Bool = false) {
        let np = CGFloat(max(0, min(1, p)))
        guard np != progress || t != tint || ind != indeterminate else { return }
        progress = np
        let restart = ind != indeterminate
        indeterminate = ind
        if t != tint { tint = t; refresh() }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.duration(0.45))
        place()
        CATransaction.commit()
        if restart { animate() }
    }

    func refresh() {
        let colors: [NSColor]
        switch tint {
        case .accent: colors = [Neon.cyan, Neon.accent, Neon.violet]
        case .warning: colors = [Neon.warning, Neon.warning]
        case .success: colors = [Neon.green.blended(withFraction: 0.3, of: Neon.cyan) ?? Neon.green, Neon.green]
        }
        fill.colors = colors.map { $0.cgColor }
        fill.shadowColor = colors[colors.count / 2].cgColor
        layer?.backgroundColor = Neon.track.cgColor
        sheenClip.isHidden = tint != .accent
    }

    private func place() {
        let h = bounds.height, w = bounds.width
        layer?.cornerRadius = h / 2
        fill.cornerRadius = h / 2
        let fw = indeterminate ? w * 0.3 : (progress == 0 ? 0 : max(h, w * progress))
        fill.frame = CGRect(x: 0, y: 0, width: fw, height: h)
        sheenClip.frame = fill.frame
        sheenClip.cornerRadius = h / 2
        sheen.frame = CGRect(x: 0, y: 0, width: max(h, fw * 0.4), height: h)
    }

    /// The sweep of light across the fill, or the gliding segment when indeterminate.
    private func animate() {
        fill.removeAnimation(forKey: "glide"); sheenClip.removeAnimation(forKey: "glide"); sheen.removeAnimation(forKey: "sheen")
        guard !Motion.reduced, window != nil, bounds.width > 0 else { return }
        let w = bounds.width
        if indeterminate {
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = -w * 0.3; a.toValue = w
            a.duration = 1.4; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fill.add(a, forKey: "glide"); sheenClip.add(a, forKey: "glide")
            layer?.masksToBounds = true
        } else {
            layer?.masksToBounds = false
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = -sheen.bounds.width; a.toValue = fill.bounds.width + sheen.bounds.width
            a.duration = 2.0; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sheen.add(a, forKey: "sheen")
        }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); place(); CATransaction.commit()
        animate()
    }
}

/// The status orb on the right wing: a small glass sphere with colour swirling inside.
/// The theme's accent gradient while Claude works, its warning colour while it waits on you, its
/// success colour when done. It eases
/// between colours, pulses its glow and spins faster under the pointer.
final class OrbView: NSView {
    enum Style { case working, waiting, done }

    private struct Colors {
        var a: [CGFloat], b: [CGFloat], c: [CGFloat], core: [CGFloat], glow: [CGFloat]
        var pulse: CGFloat
    }
    private static func colors(_ s: Style) -> Colors {
        func v(_ c: NSColor) -> [CGFloat] {
            let x = c.usingColorSpace(.sRGB) ?? c
            return [x.redComponent * 255, x.greenComponent * 255, x.blueComponent * 255]
        }
        func mix(_ a: NSColor, _ b: NSColor, _ f: CGFloat) -> NSColor { a.blended(withFraction: f, of: b) ?? a }
        switch s {
        case .working:
            let a = Neon.cyan, b = Neon.violet
            return Colors(a: v(a), b: v(b), c: v(mix(a, b, 0.5)), core: v(mix(.black, b, 0.22)), glow: v(mix(a, b, 0.4)), pulse: 1)
        case .waiting:
            let a = Neon.warning
            return Colors(a: v(a), b: v(mix(a, Neon.red, 0.4)), c: v(mix(a, .white, 0.3)), core: v(mix(.black, a, 0.2)), glow: v(a), pulse: 2.2)
        case .done:
            let a = Neon.green
            return Colors(a: v(a), b: v(mix(a, ThemeStore.shared.current.info, 0.5)), c: v(mix(a, .white, 0.4)), core: v(mix(.black, a, 0.15)),
                          glow: v(a), pulse: 0.5)
        }
    }

    private var cur = OrbView.colors(.working)
    private var target = OrbView.colors(.working)
    private var phase: CGFloat = CGFloat.random(in: 0...10)
    private var speed: CGFloat = 1
    private var wantSpeed: CGFloat = 1
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    override var isFlipped: Bool { true }

    private var style: Style = .working
    func set(_ s: Style) { style = s; target = Self.colors(s) }
    /// The theme changed: ease into its colours.
    func themeChanged() { target = Self.colors(style) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.1, now - lastTick))
        lastTick = now
        guard let w = window, w.isVisible, w.alphaValue > 0.02, !isHiddenOrHasHiddenAncestor else { return }
        let k: CGFloat = 0.08
        func ease(_ v: inout [CGFloat], _ t: [CGFloat]) { for i in 0..<3 { v[i] += (t[i] - v[i]) * k } }
        ease(&cur.a, target.a); ease(&cur.b, target.b); ease(&cur.c, target.c)
        ease(&cur.core, target.core); ease(&cur.glow, target.glow)
        cur.pulse += (target.pulse - cur.pulse) * k
        speed += (wantSpeed - speed) * 0.06
        if !Motion.reduced { phase += dt * speed }
        needsDisplay = true
    }

    private static func rgba(_ c: [CGFloat], _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: a)
    }

    private static func radial(_ ctx: CGContext, _ colors: [CGColor], _ locs: [CGFloat],
                               from c0: CGPoint, _ r0: CGFloat, to c1: CGPoint, _ r1: CGFloat) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locs) else { return }
        ctx.drawRadialGradient(g, startCenter: c0, startRadius: r0, endCenter: c1, endRadius: r1, options: [])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(bounds.width, bounds.height)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = s * 0.31
        let p = cur, t = phase
        let pulse = 0.5 + 0.5 * sin(t * 2.6 * p.pulse)

        // Glow around it.
        Self.radial(ctx, [Self.rgba(p.glow, 0.34 + 0.3 * pulse), Self.rgba(p.glow, 0)], [0, 1], from: c, r * 0.6, to: c, s / 2)

        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.clip()
        ctx.setFillColor(Self.rgba(p.core, 1))
        ctx.fill(bounds)
        // Three coloured blobs orbiting inside, added together.
        ctx.setBlendMode(.plusLighter)
        for (col, sp, off) in [(p.a, CGFloat(1), CGFloat(0)), (p.b, -1.35, 2.1), (p.c, 0.8, 4.2)] {
            let ang = t * 1.2 * sp + off
            let bc = CGPoint(x: c.x + cos(ang) * r * 0.5, y: c.y + sin(ang * 1.3) * r * 0.5)
            Self.radial(ctx, [Self.rgba(col, 0.95), Self.rgba(col, 0)], [0, 1], from: bc, 0, to: bc, r * 1.05)
        }
        ctx.setBlendMode(.normal)
        // Shading toward the rim, then a highlight up and to the left.
        let black = [CGFloat(0), 0, 0]
        Self.radial(ctx, [Self.rgba(black, 0), Self.rgba(black, 0.05), Self.rgba(black, 0.5)], [0, 0.72, 1],
                    from: CGPoint(x: c.x - r * 0.25, y: c.y - r * 0.3), r * 0.2, to: c, r)
        let hl = CGPoint(x: c.x - r * 0.38, y: c.y - r * 0.45)
        let white = [CGFloat(255), 255, 255]
        Self.radial(ctx, [Self.rgba(white, 0.85), Self.rgba(white, 0)], [0, 1], from: hl, 0, to: hl, r * 0.55)
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        ctx.setLineWidth(0.7)
        ctx.strokeEllipse(in: CGRect(x: c.x - r + 0.3, y: c.y - r + 0.3, width: r * 2 - 0.6, height: r * 2 - 0.6))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { wantSpeed = 3.4 }
    override func mouseExited(with event: NSEvent) { wantSpeed = 1 }
}

/// The rounded square with a `>_` prompt in front of the command waiting on you. Under the
/// pointer it becomes a copy button; after a copy it shows a green check for a moment.
final class CommandCopyButton: NSView {
    var onTap: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var copiedUntil: Date?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy the full command")
        toolTip = "Copy the full command"
    }
    required init?(coder: NSCoder) { fatalError() }

    func flashCopied() {
        let until = Date().addingTimeInterval(1.4)
        copiedUntil = until
        setAccessibilityLabel("Copied")
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self = self, self.copiedUntil == until else { return }
            self.copiedUntil = nil
            self.setAccessibilityLabel("Copy the full command")
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Before its first layout the button is 0 × 0, and insetting that gives a null rect
        // whose infinite coordinates make NSBezierPath throw. Draw nothing until it has a size.
        guard bounds.width > 12, bounds.height > 12 else { return }
        let r = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        if copiedUntil != nil {
            Neon.drawChip(path, hovered: true)
            Neon.symbol("checkmark", in: r, size: 14, weight: .bold, color: Neon.green)
            return
        }
        Neon.drawChip(path, hovered: hovered)
        if hovered {
            Neon.symbol("doc.on.doc", in: r, size: 14, weight: .semibold, color: Neon.accent)
            return
        }
        Neon.symbol("chevron.right", in: NSRect(x: r.minX + 6, y: r.minY, width: r.width / 2 - 2, height: r.height),
                    size: 13, weight: .bold, color: Neon.accent)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: r.midX + 1, y: r.midY + 6)); line.line(to: NSPoint(x: r.maxX - 9, y: r.midY + 6))
        line.lineWidth = 2; line.lineCapStyle = .round
        Neon.accent.setStroke(); line.stroke()
    }

    override func mouseDown(with event: NSEvent) { onTap?() }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

/// Round glyph button (📄 / ⌄) on the wings.
final class GlowIconButton: NSView {
    var onTap: (() -> Void)?
    private let symbol: String
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let c = bounds.insetBy(dx: 4, dy: 4)
        Neon.drawChip(NSBezierPath(ovalIn: c), hovered: hovered)
        Neon.symbol(symbol, in: c, size: 14, weight: .semibold, color: Neon.glyph)
    }

    override func mouseDown(with event: NSEvent) { onTap?() }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

/// Outlined, softly glowing "✕ Reject" / "✓ Approve".
final class GlowPillButton: NSView {
    enum Tint { case red, green, blue }
    var onTap: (() -> Void)?
    private let title: String
    private let symbol: String
    private let tint: Tint
    private var hovered = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 14.5, weight: .semibold)
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String, symbol: String, tint: Tint) {
        self.title = title; self.symbol = symbol; self.tint = tint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Glow inset + padding + icon + gap + text + padding.
    var fittedWidth: CGFloat {
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: Self.font]).width)
        return textWidth + 8 + 14 + 15 + 7 + 17
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = tint == .red ? Neon.red : (tint == .blue ? Neon.cyan : Neon.green)
        let r = bounds.insetBy(dx: 4, dy: 4)
        let shape = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        var ink = color
        if tint == .green {
            // Approve is the one to press: filled, like every main action in the island.
            Neon.glowing(color.withAlphaComponent(hovered ? 0.55 : 0.3), blur: hovered ? 12 : 7) {
                (hovered ? (color.blended(withFraction: 0.1, of: .white) ?? color) : color).setFill()
                shape.fill()
            }
            NSColor.white.withAlphaComponent(hovered ? 0.22 : 0.14).setStroke(); shape.lineWidth = 1; shape.stroke()
            ink = Pal.ink(on: color)
        } else {
            // Reject (and the rest) stay a soft tint with an edge, so they never shout.
            Neon.glowing(color.withAlphaComponent(hovered ? 0.4 : 0.15), blur: hovered ? 10 : 6) {
                color.withAlphaComponent(hovered ? 0.2 : 0.12).setFill()
                shape.fill()
            }
            shape.lineWidth = 1
            color.withAlphaComponent(hovered ? 0.6 : 0.4).setStroke(); shape.stroke()
        }
        let icon = NSRect(x: r.minX + 14, y: r.midY - 7.5, width: 15, height: 15)
        Neon.symbol(symbol, in: icon, size: 13, weight: .bold, color: ink)
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ink]
        let s = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: icon.maxX + 7, y: r.midY - s.height / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { onTap?() }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
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
