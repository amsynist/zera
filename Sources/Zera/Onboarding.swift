import AppKit
import QuartzCore
import ApplicationServices

// MARK: - State

enum OnboardingState {
    private static let key = "zera.onboarded"
    static var step: Int {
        get { min(4, max(0, UserDefaults.standard.integer(forKey: "zera.onboarding.step"))) }
        set { UserDefaults.standard.set(min(4, max(0, newValue)), forKey: "zera.onboarding.step") }
    }
    /// True once the first-run window was finished or explicitly skipped.
    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - Window controller

/// First-run setup: Welcome → Accessibility → optional capture → speech → Done.
/// `presentIfNeeded()` at launch shows it once; `present()` shows it again from Settings/Help.
/// Explicit Skip finishes setup; closing preserves the current step for next launch.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 720, height: 520)
    /// The one on screen, if any.
    private(set) static var current: OnboardingWindowController?

    /// Finished or skipped; the window is already closing.
    var onFinish: (() -> Void)?

    private let root: OnboardingView

    /// Shows the window on a first run; returns it so the caller can set `onFinish`.
    @discardableResult
    static func presentIfNeeded() -> OnboardingWindowController? {
        guard !OnboardingState.done else { return nil }
        return present()
    }

    @discardableResult
    static func present() -> OnboardingWindowController {
        if let c = current {
            c.showWindow(nil)
            c.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return c
        }
        let c = OnboardingWindowController()
        current = c
        c.showWindow(nil)
        c.window?.center()
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return c
    }

    init() {
        root = OnboardingView(frame: NSRect(origin: .zero, size: Self.size))
        let w = OnboardingWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.titled, .fullSizeContentView, .closable],
                                 backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Welcome to Zera"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.minSize = Self.size
        w.maxSize = Self.size
        w.contentView = root
        w.delegate = self
        w.onEscape = { [weak self] in self?.skip() }
        w.onKey = { [weak self] event in self?.root.handle(key: event) ?? false }
        root.onFinish = { [weak self] in self?.finish() }
        root.onSkip = { [weak self] in self?.skip() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var finishing = false

    /// "Open Zera": done, close, tell the owner.
    private func finish() {
        guard !finishing else { return }
        finishing = true
        OnboardingState.done = true
        SoundService.shared.play(.button)
        close()
        onFinish?()
    }

    /// Esc / explicit Skip completes setup without requiring optional permissions.
    private func skip() {
        guard !finishing else { return }
        finishing = true
        OnboardingState.done = true
        close()
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) {
        root.willClose()
        // Closing mid-setup keeps progress; only Open Zera or explicit Skip completes it.
        if Self.current === self { Self.current = nil }
    }
}

/// Keyboard: Esc skips, ⏎ / → go on, ← goes back.
private final class OnboardingWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Root view

/// Navy glass, the pages in the middle, dots and Back / Next at the bottom.
private final class OnboardingView: NSView {
    var onFinish: (() -> Void)?
    var onSkip: (() -> Void)?

    private let tint = CAGradientLayer()
    private let rim = CALayer()
    private let pageHost = FlippedView()
    private let dots = PageDots(count: 4)
    private let back: CardButton
    private let next: CardButton
    private let skipButton: CardButton
    private var pages: [OnboardingPage?] = Array(repeating: nil, count: 5)
    private var index = 0
    private var current: OnboardingPage?
    private var transitioning = false

    override var isFlipped: Bool { true }

    private static let footerH: CGFloat = 72
    private static let topInset: CGFloat = 36

    override init(frame: NSRect) {
        back = CardButton("Back", style: .tertiary, symbol: "chevron.left", target: nil, action: #selector(OnboardingView.backTapped))
        next = CardButton("Next", style: .primary, target: nil, action: #selector(OnboardingView.nextTapped))
        skipButton = CardButton("Skip", style: .tertiary, target: nil, action: #selector(OnboardingView.skipTapped))
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        layer?.backgroundColor = Pal.cardBottom.cgColor
        tint.colors = [Pal.cardBottom.cgColor, Pal.cardBottom.cgColor]
        tint.startPoint = CGPoint(x: 0.5, y: 0)
        tint.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(tint)
        rim.borderWidth = 1
        rim.borderColor = Pal.border.cgColor
        rim.cornerRadius = 14
        rim.cornerCurve = .continuous
        layer?.addSublayer(rim)

        pageHost.wantsLayer = true
        pageHost.layer?.masksToBounds = true
        addSubview(pageHost)
        addSubview(dots)
        back.target = self
        next.target = self
        skipButton.target = self
        addSubview(back)
        addSubview(next)
        addSubview(skipButton)
        show(OnboardingState.done ? 0 : OnboardingState.step, direction: 0, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func page(_ i: Int) -> OnboardingPage {
        if let p = pages[i] { return p }
        let p: OnboardingPage
        switch i {
        case 0: p = WelcomePage()
        case 1: p = AccessPage(kind: .accessibility)
        case 2: p = AccessPage(kind: .speech) // Reserved persisted step; show() skips it.
        case 3: p = AccessPage(kind: .speech)
        default:
            p = DonePage()
        }
        pages[i] = p
        return p
    }

    // MARK: Paging

    private func show(_ savedIndex: Int, direction: CGFloat, animated: Bool) {
        // Keep persisted IDs stable after removing the Screen Recording step.
        let i = savedIndex == 2 ? 3 : savedIndex
        guard pages.indices.contains(i), !transitioning else { return }
        let old = current
        let new = page(i)
        index = i
        if !OnboardingState.done { OnboardingState.step = i }
        current = new
        dots.selected = i >= 3 ? i - 1 : i
        back.isHidden = i == 0
        next.setTitleText(i == pages.count - 1 ? "Open Zera" : i == 0 ? "Get Started" : "Continue")
        skipButton.isHidden = i == pages.count - 1
        needsLayout = true

        let w = pageHost.bounds.width
        new.frame = pageHost.bounds
        new.wantsLayer = true
        pageHost.addSubview(new)
        new.layoutSubtreeIfNeeded()
        new.didShow()

        guard let old = old, old !== new else { return }
        old.willHide()
        let dur = Motion.duration(0.28)
        guard animated, dur > 0, direction != 0, window != nil, w > 0 else {
            old.removeFromSuperview()
            return
        }
        transitioning = true
        old.wantsLayer = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(dur)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self, weak old] in
            old?.removeFromSuperview()
            old?.layer?.removeAllAnimations()
            self?.transitioning = false
        }
        let leave = CABasicAnimation(keyPath: "transform.translation.x")
        leave.fromValue = 0; leave.toValue = -direction * w; leave.duration = dur
        leave.fillMode = .forwards; leave.isRemovedOnCompletion = false
        old.layer?.add(leave, forKey: "slide")
        let leaveFade = CABasicAnimation(keyPath: "opacity")
        leaveFade.fromValue = 1; leaveFade.toValue = 0; leaveFade.duration = dur
        leaveFade.fillMode = .forwards; leaveFade.isRemovedOnCompletion = false
        old.layer?.add(leaveFade, forKey: "fade")
        let enter = CABasicAnimation(keyPath: "transform.translation.x")
        enter.fromValue = direction * w; enter.toValue = 0; enter.duration = dur
        new.layer?.add(enter, forKey: "slide")
        let enterFade = CABasicAnimation(keyPath: "opacity")
        enterFade.fromValue = 0; enterFade.toValue = 1; enterFade.duration = dur
        new.layer?.add(enterFade, forKey: "fade")
        CATransaction.commit()
    }

    @objc private func backTapped() {
        SoundService.shared.play(.tab)
        let previous = index == 3 ? 1 : index - 1
        show(previous, direction: -1, animated: true)
    }

    @objc private func nextTapped() {
        if index == pages.count - 1 { onFinish?(); return }
        SoundService.shared.play(.tab)
        var nextStep = index + 1
        if nextStep == 1, AXIsProcessTrusted() { nextStep += 1 }
        if nextStep == 2 { nextStep += 1 }
        show(nextStep, direction: 1, animated: true)
    }

    @objc private func skipTapped() { onSkip?() }

    /// ⏎ / → forward, ← back. Returns whether the key was used.
    func handle(key event: NSEvent) -> Bool {
        if current?.wantsKeys == true { return false }
        switch event.keyCode {
        case 36, 76, 124: nextTapped(); return true   // return, enter, →
        case 123: if index > 0 { backTapped() }; return true
        default: return false
        }
    }

    func willClose() {
        pages.forEach { $0?.willHide() }
    }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.frame = b
        rim.frame = b
        CATransaction.commit()
        pageHost.frame = NSRect(x: 0, y: Self.topInset, width: b.width, height: b.height - Self.topInset - Self.footerH)
        current?.frame = pageHost.bounds
        let fy = b.height - Self.footerH
        let bh = Metrics.button
        let by = fy + (Self.footerH - bh) / 2
        let bw = max(80, back.fittedWidth)
        back.frame = NSRect(x: Space.xxl, y: by, width: bw, height: bh)
        let sw = max(70, skipButton.fittedWidth)
        skipButton.frame = NSRect(x: back.isHidden ? Space.xxl : back.frame.maxX + Space.s, y: by, width: sw, height: bh)
        let nw = max(110, next.fittedWidth + 12)
        next.frame = NSRect(x: b.width - Space.xxl - nw, y: by, width: nw, height: bh)
        dots.frame = NSRect(x: (b.width - 120) / 2, y: fy + (Self.footerH - 12) / 2, width: 120, height: 12)
    }
}

// MARK: - Dots

private final class PageDots: NSView {
    let count: Int
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(count: Int) {
        self.count = count
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let d: CGFloat = 7, gap: CGFloat = 8, wide: CGFloat = 20
        let total = CGFloat(count - 1) * (d + gap) + wide
        var x = (bounds.width - total) / 2
        let y = (bounds.height - d) / 2
        for i in 0..<count {
            let w = i == selected ? wide : d
            let r = NSRect(x: x, y: y, width: w, height: d)
            (i == selected ? p.accent : p.textTertiary.withAlphaComponent(0.5)).setFill()
            NSBezierPath(roundedRect: r, xRadius: d / 2, yRadius: d / 2).fill()
            x += w + gap
        }
    }
}

// MARK: - Pages

/// One step. Content starts at `Space.xxl * 2` from the sides; `layoutBody` places it.
private class OnboardingPage: NSView {
    override var isFlipped: Bool { true }
    /// Pages with text fields keep ⏎ / arrows to themselves.
    var wantsKeys: Bool { false }
    static let inset: CGFloat = 48

    let heading = NSTextField(labelWithString: "")
    let lede = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        heading.font = Typo.screenTitle
        heading.textColor = Pal.text
        heading.lineBreakMode = .byTruncatingTail
        addSubview(heading)
        lede.font = Typo.screenSubtitle
        lede.textColor = Pal.textSecondary
        lede.isSelectable = false
        addSubview(lede)
    }
    required init?(coder: NSCoder) { fatalError() }

    func didShow() {}
    func willHide() {}

    /// Title + lede at the top; returns the y where the body starts.
    func layoutHeader() -> CGFloat {
        let w = bounds.width - Self.inset * 2
        heading.frame = NSRect(x: Self.inset, y: Space.l, width: w, height: 32)
        let hasLede = !lede.stringValue.isEmpty
        lede.isHidden = !hasLede
        guard hasLede else { return heading.frame.maxY + Space.l }
        let h = (lede.stringValue as NSString).boundingRect(with: NSSize(width: w, height: 80), options: [.usesLineFragmentOrigin],
                                                            attributes: [.font: Typo.screenSubtitle]).height
        lede.frame = NSRect(x: Self.inset, y: heading.frame.maxY + Space.xs, width: w, height: ceil(h) + 2)
        return lede.frame.maxY + Space.l
    }
}

// MARK: Welcome

private final class WelcomePage: OnboardingPage {
    private let zera = ZeraCompanion(pose: "card_greet", size: 150, side: .bubbleRight)
    private let props: [PropRow] = [
        PropRow(symbol: "macbook", color: Pal.info, text: "Your Mac at a glance — vitals, media, weather and what's next"),
        PropRow(symbol: "sparkles", color: Pal.tileClaude, text: "Your agents, approvals and alerts, right under the notch"),
        PropRow(symbol: "tray.full.fill", color: Pal.tileNote, text: "Files, clipboard, focus, reminders and a teleprompter")
    ]

    override init() {
        super.init()
        heading.stringValue = "Welcome to Zera"
        lede.stringValue = "She lives at the top of your screen and keeps the useful things one hover away."
        zera.line = "hi! 👋"
        addSubview(zera)
        props.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let y0 = layoutHeader()
        let w = bounds.width - Self.inset * 2
        let figW: CGFloat = 230
        let avail = bounds.height - y0 - Space.l
        zera.frame = NSRect(x: Self.inset, y: y0 + max(0, (avail - 170) / 2), width: figW, height: 170)
        let rowH: CGFloat = 50, gap = Space.m
        let listH = CGFloat(props.count) * rowH + CGFloat(props.count - 1) * gap
        var y = y0 + max(0, (avail - listH) / 2)
        let x = Self.inset + figW + Space.xl
        for r in props {
            r.frame = NSRect(x: x, y: y, width: w - figW - Space.xl, height: rowH)
            y += rowH + gap
        }
    }
}

/// Icon tile + one line.
private final class PropRow: NSView {
    private let tile: IconTile
    private let label = NSTextField(wrappingLabelWithString: "")
    override var isFlipped: Bool { true }

    init(symbol: String, color: NSColor, text: String) {
        tile = IconTile(symbol: symbol, color: color, size: 36, pointSize: 15)
        super.init(frame: .zero)
        addSubview(tile)
        label.stringValue = text
        label.font = Typo.rowTitle
        label.textColor = Pal.text
        label.maximumNumberOfLines = 2
        label.isSelectable = false
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        tile.frame = NSRect(x: 0, y: (h - 36) / 2, width: 36, height: 36)
        let tx = 36 + Space.m
        let tw = bounds.width - tx
        let th = (label.stringValue as NSString).boundingRect(with: NSSize(width: tw, height: h), options: [.usesLineFragmentOrigin],
                                                              attributes: [.font: Typo.rowTitle]).height
        label.frame = NSRect(x: tx, y: ((h - ceil(th)) / 2).rounded(), width: tw, height: ceil(th) + 2)
    }
}

// MARK: Permission steps

private final class AccessPage: OnboardingPage {
    private let setup: PermissionSetupView
    init(kind: PermissionAccess.Kind) {
        setup = PermissionSetupView(kind: kind)
        super.init()
        heading.stringValue = kind == .speech ? "Choose how you speak to Zera" : "Set up access, at your pace"
        lede.stringValue = "Each step is optional. Continue when you're ready, or repair access later in Settings → Permissions & Diagnostics."
        addSubview(setup)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func didShow() { setup.refresh() }
    override func layout() {
        super.layout()
        let top = layoutHeader()
        setup.frame = NSRect(x: Self.inset, y: top, width: bounds.width - Self.inset * 2, height: setup.preferredHeight)
    }
}

// MARK: Done

private final class DonePage: OnboardingPage {
    private let zera = ZeraCompanion(pose: "card_cheer", size: 150, side: .bubbleRight)
    private let hint = NSTextField(wrappingLabelWithString: "")

    override init() {
        super.init()
        heading.stringValue = "You're ready"
        lede.stringValue = "Hover Zera at the notch to return to your work. Home and Settings are always in reach. Hold your dictation key to speak into an editable field."
        zera.line = "see you up top ✨"
        addSubview(zera)
        hint.stringValue = "Repair access in Settings → Permissions & Diagnostics. Run this welcome again from About."
        hint.font = Typo.caption
        hint.textColor = Pal.textTertiary
        hint.isSelectable = false
        hint.alignment = .center
        addSubview(hint)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let y0 = layoutHeader()
        let avail = bounds.height - y0 - Space.l
        let figH: CGFloat = 170
        let block = figH + Space.l + 36
        var y = y0 + max(0, (avail - block) / 2)
        zera.frame = NSRect(x: (bounds.width - 300) / 2, y: y, width: 300, height: figH)
        y += figH + Space.l
        hint.frame = NSRect(x: Self.inset, y: y, width: bounds.width - Self.inset * 2, height: 36)
    }
}
