import AppKit
import ServiceManagement

/// Owns everything on screen: Zera dangling from the notch, her speech bubble, the hover
/// pill, and whichever card is hanging under her. Polls the pointer so she can watch it,
/// greet you when you come close, and doze off when you have been away for a while.
final class ZeraController: NSObject, ShelfViewDelegate {

    // MARK: Windows & views

    private var geometry = NotchGeometry.detect()
    private let buddyPanel: FloatingPanel
    private let buddy = BuddyView()
    private let bubblePanel: FloatingPanel
    private let bubble = BubbleView()
    private let pillPanel: FloatingPanel
    private let pill = ActionPill()
    /// Claude Code's live readout: two wings hanging off her on either side of the rope.
    private let livePanel: FloatingPanel
    private let live = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
    private var liveVisible = false
    private var liveHideWork: DispatchWorkItem?
    /// ✕ on the readout hides it until Claude's next prompt / wait / finish.
    private var liveDismissed = false
    private let cardPanel: FloatingPanel

    /// Cards are built on demand and thrown away when the palette changes.
    private var cards: [CardKind: any CardContent] = [:]
    private var zera: ZeraView { buddy.zera }
    private(set) var currentCard: CardKind?
    private var currentContent: (any CardContent)?
    private var pendingToast: GHEvent?

    // MARK: State

    private var pollTimer: Timer?
    private var hovering = false
    private var pillVisible = false
    private var pillLeftAt: Date?
    private var lastMouse = NSPoint(x: -1, y: -1)
    private var lastMoveAt = Date()
    private var asleep = false
    private var sayResetWork: DispatchWorkItem?

    private var outsideSince: Date?
    private var isDraggingOut = false
    private var externalDragOver = false
    private var buddyDragActive = false
    private var autoHideWork: DispatchWorkItem?
    private var isPresenting = false
    private(set) var cardVisible = false
    private var suppressUntil = Date.distantPast
    
    private var annoyPokes = 0
    private var lastAnnoyTime: TimeInterval = 0

    private var dragging = false
    private var dragGrabOffset: CGFloat = 0

    private let leaveGrace: TimeInterval = 0.7
    private let hoverPadding: CGFloat = 40

    private static let anchorKey = "zera.anchorX"
    private static let buddyDefaultsKey = "zera.showBuddy"
    private static let greetedKey = "zera.hasGreeted"
    private static let defaultCardKey = "zera.defaultCard"

    /// Where she hangs along the top edge, as a fraction of the screen width. nil = the notch.
    private var anchorX: CGFloat? {
        get { (UserDefaults.standard.object(forKey: Self.anchorKey) as? Double).map { CGFloat($0) } }
        set {
            if let v = newValue { UserDefaults.standard.set(Double(v), forKey: Self.anchorKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.anchorKey) }
        }
    }

    var buddyEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.buddyDefaultsKey) as? Bool ?? true
    }

    /// What a tap on her opens.
    var defaultCard: CardKind {
        get { CardKind(rawValue: UserDefaults.standard.integer(forKey: Self.defaultCardKey)) ?? .shelf }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultCardKey); pill.defaultKind = newValue }
    }

    // MARK: - Setup

    override init() {
        let aboveMenuBar = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        buddyPanel = FloatingPanel.make(size: NSSize(width: Theme.buddyWidth, height: 90), level: aboveMenuBar, keyable: false)
        bubblePanel = FloatingPanel.make(size: NSSize(width: 120, height: 30), level: aboveMenuBar, keyable: false)
        pillPanel = FloatingPanel.make(size: ActionPill.preferredSize, level: aboveMenuBar, keyable: false)
        livePanel = FloatingPanel.make(size: LiveActivityView.panelSize, level: .floating, keyable: false)
        cardPanel = FloatingPanel.make(size: NSSize(width: Theme.panelWidth, height: 240), level: .floating, keyable: true)
        super.init()

        buddyPanel.contentView = buddy
        buddyPanel.alphaValue = 0
        buddy.onActivate = { [weak self] in
            guard let self = self else { return }
            let now = CACurrentMediaTime()
            if now - self.lastAnnoyTime < 1.0 {
                self.annoyPokes += 1
            } else {
                self.annoyPokes = 1
            }
            self.lastAnnoyTime = now
            if self.annoyPokes >= 4 {
                self.say("stop poking me! 😠", mood: .error, for: 4.0)
                self.annoyPokes = 0
                return
            }
            if self.zera.mood == .error || self.zera.mood == .worried { return }
            
            // Tap her: open the default card, or tuck away whatever is open so you can get back
            // to your work (the hover pill still lets you jump straight to another card).
            if self.cardVisible {
                self.dismissCardByUser()
            } else {
                self.suppressUntil = .distantPast
                let answerWaiting = self.userHidResult && MainActor.assumeIsolated { !ZeraAssistant.shared.isBusy && ZeraAssistant.shared.session != nil }
                self.userHidResult = false
                self.show(answerWaiting ? (self.resultsInShelf ? .shelf : .result) : self.defaultCard)
            }
        }
        buddy.onDrop = { [weak self] pb in
            guard let self = self else { return false }
            let n = ShelfStore.shared.ingest(pasteboard: pb)
            let ok = n > 0 || ShelfStore.shared.alreadyHas(pasteboard: pb)
            if ok {
                self.suppressUntil = .distantPast
                self.show(.shelf, instant: true)
                self.say(n == 1 ? "got it! ✨" : (n > 1 ? "got all \(n)! ✨" : "already have that one 😊"), mood: .happy, for: 1.6)
                self.shelfDidAcceptDrop()
            } else {
                self.say("hmm, can't hold that", mood: .thinking, for: 1.6)
            }
            return ok
        }
        buddy.onDragStateChange = { [weak self] active in
            guard let self = self else { return }
            self.buddyDragActive = active
            if active {
                self.suppressUntil = .distantPast
                self.say("toss it here! 🙌", mood: .excited, for: 0)
                self.show(.shelf, instant: true)
            } else {
                self.settle()
            }
        }
        buddy.onDragBegan = { [weak self] in
            guard let self = self else { return }
            self.dragging = true
            self.dragGrabOffset = self.buddyPanel.frame.midX - NSEvent.mouseLocation.x
            if self.cardVisible { self.hideCard() }
            self.hidePill()
            self.say("wheee~", mood: .excited, for: 0)
        }
        buddy.onDragMoved = { [weak self] x in
            guard let self = self else { return }
            let newX = self.geometry.clampedCenterX(x + self.dragGrabOffset)
            self.placeBuddy(centerX: newX)
        }
        buddy.onDragEnded = { [weak self] in
            guard let self = self else { return }
            self.dragging = false
            let mid = self.buddyPanel.frame.midX
            if abs(mid - self.geometry.notchRect.midX) < Theme.snapDistance {
                self.anchorX = nil
            } else {
                let f = self.geometry.screen.frame
                self.anchorX = (mid - f.minX) / f.width
            }
            self.layoutBuddy()
            self.settle()
        }

        bubblePanel.contentView = bubble
        bubblePanel.ignoresMouseEvents = true
        bubblePanel.alphaValue = 0
        bubble.tail = .right

        pillPanel.contentView = pill
        pillPanel.alphaValue = 0
        pill.defaultKind = defaultCard
        pill.onPick = { [weak self] kind in
            guard let self = self else { return }
            self.suppressUntil = .distantPast
            self.show(kind)
        }

        livePanel.contentView = live
        livePanel.hasShadow = false         // the wings draw their own glow
        livePanel.appearance = Pal.nsAppearance
        livePanel.alphaValue = 0
        live.onTap = { [weak self] in
            guard let self = self else { return }
            self.suppressUntil = .distantPast
            // From the live bar you want the session itself, so the live view opens too.
            self.claudeOpenExpanded = true
            self.show(.claude)
        }
        live.onDecide = { [weak self] req, allow in
            guard let self = self else { return }
            MainActor.assumeIsolated { ClaudeHookService.shared.respond(req, allow: allow) }
            self.say(allow ? "approved! ✅" : "rejected 🙅", mood: allow ? .happy : .thinking, for: 1.8)
            self.updateLive()
        }
        live.onClose = { [weak self] in
            guard let self = self else { return }
            self.liveDismissed = true
            self.hideLive()
        }

        cardPanel.hasShadow = true
        cardPanel.appearance = Pal.nsAppearance
        cardPanel.alphaValue = 0

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(storeChanged), name: ShelfStore.changed, object: nil)
        nc.addObserver(self, selector: #selector(githubChanged), name: GitHubService.changed, object: nil)
        nc.addObserver(self, selector: #selector(githubNews(_:)), name: GitHubService.newEvents, object: nil)
        nc.addObserver(self, selector: #selector(hookRequest(_:)), name: ClaudeHookService.newRequest, object: nil)
        nc.addObserver(self, selector: #selector(hookChanged), name: ClaudeHookService.changed, object: nil)
        nc.addObserver(self, selector: #selector(reminderFired(_:)), name: ReminderService.alert, object: nil)
        nc.addObserver(self, selector: #selector(remindersChanged), name: ReminderService.changed, object: nil)
        nc.addObserver(self, selector: #selector(paletteChanged), name: Palette.changed, object: nil)
        nc.addObserver(self, selector: #selector(assistantChanged), name: ZeraAssistant.changed, object: nil)
        nc.addObserver(self, selector: #selector(activityChanged), name: ClaudeActivityService.changed, object: nil)
        nc.addObserver(self, selector: #selector(activityMilestone(_:)), name: ClaudeActivityService.milestone, object: nil)
        Palette.observeSystem()
        // Find `claude` in the background now, so the first Summarize does not wait for it.
        ClaudeCLI.shared.ensureProbed { _ in }

        // A click anywhere else on the screen puts the card away at once — no waiting for the
        // pointer to wander off. (Our own panels get local events, so this never fires for them.)
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.cardVisible, !self.dragging, !self.buddyDragActive, !self.isDraggingOut else { return }
            if self.currentCard == .approval, self.approvalPending { return }
            let m = NSEvent.mouseLocation
            if NSPointInRect(m, self.cardPanel.frame) || NSPointInRect(m, self.figureRect.insetBy(dx: -8, dy: -6))
                || (self.pillVisible && NSPointInRect(m, self.pillPanel.frame))
                || (self.liveVisible && NSPointInRect(m, self.livePanel.frame)) { return }
            self.dismissCardByUser()
        }

        // Esc closes whichever card is up, wherever focus is inside it.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.cardVisible, event.keyCode == 53, event.window === self.cardPanel else { return event }
            if self.currentCard == .approval, self.approvalPending { return event }   // Esc = Reject there
            self.dismissCardByUser()
            return nil
        }

        layoutBuddy()
        startPolling()
        MainActor.assumeIsolated {
            GitHubService.shared.startPolling()
            ClaudeHookService.shared.start()
            ClaudeActivityService.shared.start()
            ReminderService.shared.start()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.greet(firstTime: true)
        }
    }

    // MARK: - Layout

    @objc private func screensChanged() {
        layoutBuddy()
        if cardVisible { cardHeightChanged() }
    }

    private var centerX: CGFloat {
        if let a = anchorX {
            let f = geometry.screen.frame
            return geometry.clampedCenterX(f.minX + a * f.width)
        }
        return geometry.notchRect.midX
    }

    private func layoutBuddy() {
        geometry = NotchGeometry.detect()
        placeBuddy(centerX: centerX)
        setBuddy(visible: buddyEnabled, animated: false)
    }

    private func placeBuddy(centerX x: CGFloat) {
        let frame = geometry.buddyPanelFrame(centerX: x)
        buddyPanel.setFrame(frame, display: true)
        buddy.hangInset = geometry.hangInset
        buddy.frame = NSRect(origin: .zero, size: frame.size)
        buddy.needsLayout = true
        buddy.layoutSubtreeIfNeeded()
        positionBubble()
        positionPill()
        if liveVisible { positionLive() }
    }

    func setBuddyEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.buddyDefaultsKey)
        setBuddy(visible: on, animated: true)
        if !on { hideBubble(); hidePill(); hideLive(); if cardVisible { hideCard() } }
    }

    private func setBuddy(visible: Bool, animated: Bool) {
        if visible {
            if buddyPanel.alphaValue < 0.05 { buddyPanel.orderFrontRegardless() }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animated ? 0.3 : 0
                buddyPanel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = animated ? 0.2 : 0
                buddyPanel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self = self, self.buddyPanel.alphaValue < 0.05 else { return }
                self.buddyPanel.orderOut(nil)
            })
        }
    }

    private var figureRect: NSRect { geometry.figureRect(centerX: buddyPanel.frame.midX) }
    private var headPoint: NSPoint { NSPoint(x: figureRect.midX, y: figureRect.minY + figureRect.height * 0.55) }

    private var pillOnRight: Bool {
        figureRect.maxX + 6 + ActionPill.preferredSize.width < geometry.screen.frame.maxX - 8
    }

    private func positionBubble() {
        let size = BubbleView.size(for: bubble.text.isEmpty ? " " : bubble.text)
        let f = figureRect
        let scr = geometry.screen.frame
        if liveVisible {
            // The wings fill the space beside her: the bubble perches above the right tendril.
            bubble.tail = .left
            let y = livePanel.frame.midY + 24
            bubblePanel.setFrame(NSRect(x: f.maxX - 6, y: y, width: size.width, height: size.height), display: true)
            bubble.frame = NSRect(origin: .zero, size: size)
            return
        }
        var left = pillOnRight
        if left, f.minX - 6 - size.width < scr.minX + 8 { left = false }
        if !left, f.maxX + 6 + size.width > scr.maxX - 8 { left = true }
        bubble.tail = left ? .right : .left
        let x = left ? f.minX - 6 - size.width : f.maxX + 6
        bubblePanel.setFrame(NSRect(x: x, y: headPoint.y - size.height / 2, width: size.width, height: size.height), display: true)
        bubble.frame = NSRect(origin: .zero, size: size)
    }

    /// Spans the screen around her at chest height: the left wing ends in a tendril just left
    /// of her, the right wing just right. Near a screen edge the panel is clamped and the wing
    /// on that side gets shorter (or folds away when there is no room).
    private func positionLive() {
        let size = LiveActivityView.panelSize
        let scr = geometry.screen.frame
        let cx = figureRect.midX
        let x = max(scr.minX, min(scr.maxX - size.width, cx - size.width / 2))
        let y = (figureRect.minY + Theme.figureHeight * 0.43 - size.height / 2).rounded()
        livePanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        live.frame = NSRect(origin: .zero, size: size)
        live.centerX = cx - x
        live.layoutSubtreeIfNeeded()
    }

    /// The wing shows approvals itself when there is room and nothing covers it.
    private var liveCanApprove: Bool {
        guard buddyEnabled, !cardVisible, !dragging else { return false }
        positionLive()
        return live.canShowApproval
    }

    /// Shows / updates / hides the wings from the current Claude session and pending approvals.
    private func updateLive() {
        let (show, done): (Bool, Bool) = MainActor.assumeIsolated {
            let s = ClaudeActivityService.shared.current
            let hooks = ClaudeHookService.shared.pending
            let pending = s.flatMap { s in hooks.first { $0.sessionID == s.id } } ?? hooks.first
            // Idle sessions stay visible for a few minutes after their last activity.
            let stale = s.map { $0.status == .ended || ($0.status == .idle && Date().timeIntervalSince($0.lastEventAt) > 600) } ?? true
            if stale && pending == nil { return (false, false) }
            self.live.update(session: stale ? nil : s, pending: pending)
            return (true, pending == nil && s?.status == .done)
        }
        liveHideWork?.cancel()
        // Folded away while a card is open (the card carries the same information), while the
        // hover pill is out (it sits where the wings do), and after right-click → hide until
        // Claude has something new to say.
        guard buddyEnabled, show, !cardVisible, !dragging, !pillVisible, !liveDismissed else { hideLive(); return }
        showLive()
        if done {
            // Let the green bar be seen, then tidy away.
            let w = DispatchWorkItem { [weak self] in self?.hideLive() }
            liveHideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
        }
    }

    private func showLive() {
        positionLive()
        guard !liveVisible else { return }
        liveVisible = true
        livePanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(0.22)
            livePanel.animator().alphaValue = 1
        }
        positionBubble()
    }

    private func hideLive() {
        guard liveVisible else { return }
        liveVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(0.18)
            livePanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.liveVisible else { return }
            self.livePanel.orderOut(nil)
        })
        positionBubble()
    }

    private func positionPill() {
        let size = ActionPill.preferredSize
        let f = figureRect
        let x = pillOnRight ? f.maxX + 6 : f.minX - 6 - size.width
        pillPanel.setFrame(NSRect(x: x, y: headPoint.y - size.height / 2, width: size.width, height: size.height), display: true)
        pill.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: - Pointer polling

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private var mouseButtonDown: Bool { NSEvent.pressedMouseButtons & 0x1 != 0 }

    @objc private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
        if mouse != lastMouse {
            lastMouse = mouse
            lastMoveAt = now
            if asleep { wake() }
        } else if !asleep, now.timeIntervalSince(lastMoveAt) > Theme.sleepAfter, !cardVisible {
            fallAsleep()
        }
        let idle = now.timeIntervalSince(lastMoveAt) > 180
        MainActor.assumeIsolated { ReminderService.shared.userIsIdle = idle }

        updateLook(mouse)
        updateHover(mouse, now)
        // The wings' panel is mostly transparent: only the wings themselves catch the pointer.
        if liveVisible {
            let p = live.convert(livePanel.convertPoint(fromScreen: mouse), from: nil)
            livePanel.ignoresMouseEvents = !live.wingContains(p)
        }
        if cardVisible { evaluateHide(mouse) }
    }

    private func updateLook(_ mouse: NSPoint) {
        let head = headPoint
        let f = geometry.screen.frame
        let x = max(-1, min(1, (mouse.x - head.x) / (f.width * 0.45)))
        let y = max(-1, min(1, (mouse.y - head.y) / (f.height * 0.7)))
        zera.lookTarget = CGPoint(x: x, y: y)
    }

    private func updateHover(_ mouse: NSPoint, _ now: Date) {
        guard buddyEnabled, buddyPanel.alphaValue > 0.5, !dragging else { return }
        let onHer = NSPointInRect(mouse, figureRect.insetBy(dx: -8, dy: -6))
        let onPill = pillVisible && NSPointInRect(mouse, pillPanel.frame.insetBy(dx: -6, dy: -8))
        let bridge = pillVisible && NSPointInRect(mouse, figureRect.union(pillPanel.frame).insetBy(dx: 0, dy: -6))

        if onHer != hovering {
            hovering = onHer
            buddy.setRadar(active: onHer)
            let nowInterval = CACurrentMediaTime()
            if onHer {
                if nowInterval - lastAnnoyTime < 1.0 {
                    annoyPokes += 1
                } else {
                    annoyPokes = 1
                }
                lastAnnoyTime = nowInterval
                if annoyPokes >= 5 {
                    say("dizzy! 😵‍💫", mood: .worried, for: 4.0)
                    annoyPokes = 0
                    return
                }
            }
            if onHer, !asleep, !buddyDragActive, zera.mood != .error, zera.mood != .worried, zera.mood != .excited, !cardVisible {
                say(Self.helloLines.randomElement()!, mood: .hello, for: 2.2)
            }
        }
        if onHer || onPill || bridge {
            pillLeftAt = nil
            if !pillVisible { showPill() }   // also while a card is up, to switch cards directly
        } else if pillVisible {
            if let left = pillLeftAt {
                if now.timeIntervalSince(left) > Theme.pillLinger { hidePill() }
            } else {
                pillLeftAt = now
            }
        }
        // (Opening is handled by `buddy.onActivate` on mouse-up, so a tap can toggle cleanly;
        // showing on mouse-down here would open and then immediately close the card.)
    }

    // MARK: - Pill

    private func showPill() {
        pillVisible = true
        hideLive()
        positionPill()
        refreshBadges()
        pill.activeKind = cardVisible ? currentCard : nil
        let target = pillPanel.frame
        pillPanel.setFrame(target.offsetBy(dx: -8, dy: 0), display: false)
        pillPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(0.18)
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
            pillPanel.animator().alphaValue = 1
            pillPanel.animator().setFrame(target, display: true)
        }
    }

    private func hidePill() {
        pillVisible = false
        pillLeftAt = nil
        updateLive()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(0.14)
            pillPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.pillVisible else { return }
            self.pillPanel.orderOut(nil)
        })
    }

    /// Red dots on the pill: unseen GitHub activity, Claude Code requests, reminder alerts.
    private func refreshBadges() {
        pill.badges = MainActor.assumeIsolated { () -> Set<CardKind> in
            var b: Set<CardKind> = []
            if !GitHubService.shared.unseen.isEmpty { b.formUnion([.home, .github]) }
            if !ClaudeHookService.shared.pending.isEmpty { b.formUnion([.home, .claude]) }
            if ClaudeActivityService.shared.active.contains(where: { $0.status == .waiting }) { b.insert(.claude) }
            if !ReminderService.shared.pendingAlerts.isEmpty { b.formUnion([.home, .reminders]) }
            return b
        }
    }

    // MARK: - Talking

    static let helloLines = ["Hi! 👋", "Hey there!", "Hi, I'm Zera 💜", "Need anything?", "Hello hello~", "Yes? 👀"]

    private func greetingForNow() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning! ☀️"
        case 12..<17: return "Hi! 👋 Afternoon already?"
        case 17..<22: return "Evening! 🌙"
        default: return "Late night, huh? 🌙"
        }
    }

    func greet(firstTime: Bool = false) {
        guard buddyEnabled else { return }
        if firstTime && !UserDefaults.standard.bool(forKey: Self.greetedKey) {
            UserDefaults.standard.set(true, forKey: Self.greetedKey)
            say("Hi! 👋 I'm Zera!", mood: .hello, for: 3.5)
        } else {
            say(greetingForNow(), mood: .hello, for: 3.0)
        }
    }

    func say(_ line: String, mood: ZeraMood? = nil, for seconds: TimeInterval = 2.5) {
        sayResetWork?.cancel()
        if let m = mood { zera.mood = m }
        bubble.text = line
        positionBubble()
        showBubble()
        guard seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        sayResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func settle() {
        sayResetWork?.cancel()
        zera.mood = asleep ? .sleepy : .idle
        hideBubble()
    }

    private func showBubble() {
        guard buddyEnabled else { return }
        if bubblePanel.alphaValue < 0.05 {
            let target = bubblePanel.frame
            bubblePanel.setFrame(target.offsetBy(dx: 6, dy: 0), display: false)
            bubblePanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(0.18)
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
                bubblePanel.animator().alphaValue = 1
                bubblePanel.animator().setFrame(target, display: true)
            }
        } else {
            bubblePanel.orderFrontRegardless()
        }
    }

    private func hideBubble() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(0.16)
            bubblePanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.bubblePanel.alphaValue < 0.05 else { return }
            self.bubblePanel.orderOut(nil)
        })
    }

    private func fallAsleep() { asleep = true; settle() }
    private func wake() { asleep = false; say("oh! hi again 👋", mood: .hello, for: 2.0) }

    // MARK: - Events from services

    @objc private func githubChanged() { refreshBadges() }

    @objc private func githubNews(_ note: Notification) {
        guard let fresh = note.userInfo?["events"] as? [GHEvent], let top = fresh.first else { return }
        let more = fresh.count > 1 ? " (+\(fresh.count - 1) more)" : ""
        switch top.kind {
        case .prOpened:
            if top.mine { say("Your PR is up! 🚀 \(top.subtitle)\(more)", mood: .celebrate, for: 6) }
            else { say("New PR! 👀 Want me to take a look?\(more)", mood: .surprised, for: 8) }
        case .prApproved: say("\(top.title) ✅ \(top.subtitle)\(more)", mood: .celebrate, for: 8)
        case .prChangesRequested: say("Changes requested on \(top.subtitle) 📝\(more)", mood: .thinking, for: 8)
        case .prCommented: say("New comment on \(top.subtitle) 💬\(more)", mood: .hello, for: 8)
        case .reviewRequested: say("Review requested on \(top.subtitle) 📝\(more)", mood: .thinking, for: 8)
        case .ciFailed: say("CI failed on \(top.subtitle) 😬\(more)", mood: .worried, for: 8)
        case .ciPassed: say("CI is green on \(top.subtitle) ✅\(more)", mood: .celebrate, for: 6)
        case .ciRunning: say("Checks running on \(top.subtitle) ⏳\(more)", mood: .focused, for: 5)
        case .needsApproval: say("A run on \(top.subtitle) needs your approval 🙋\(more)", mood: .thinking, for: 8)
        }
        if cardVisible, currentCard == .github { (cards[.github] as? GitHubCard)?.reload(); return }
        // A toast, unless something more important is on screen.
        if cardVisible, currentCard == .approval || currentCard == .reminderAlert { return }
        pendingToast = top
        show(.toast)
    }

    @objc private func hookRequest(_ note: Notification) {
        guard let req = note.userInfo?["request"] as? HookRequest else { return }
        let what = req.toolName == "Bash" ? "a command" : req.toolName
        say("Claude needs your approval — shall I run \(what)? 🤔", mood: .thinking, for: 0)
        if cardVisible && currentCard == .approval { (cards[.approval] as? ApprovalCard)?.reload(); return }
        // Approve / Reject right on the wing when it can show it; otherwise the approval card.
        if liveCanApprove {
            liveDismissed = false
            if pillVisible { hidePill() } else { updateLive() }
        } else {
            show(.approval)
        }
    }

    @objc private func hookChanged() {
        refreshBadges()
        updateLive()
        if cardVisible, currentCard == .approval { (cards[.approval] as? ApprovalCard)?.reload() }
    }

    private var approvalPending: Bool { MainActor.assumeIsolated { !ClaudeHookService.shared.pending.isEmpty } }

    private var liveTicker: Timer?

    @objc private func activityChanged() {
        refreshBadges()
        updateLive()
        if liveTicker == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateLive() }
            RunLoop.main.add(t, forMode: .common)
            liveTicker = t
        }
        if cardVisible, currentCard == .claude { (cards[.claude] as? ClaudeSessionsView)?.reload() }
    }

    /// Prompt sent / Claude waiting / task finished: a word from her, and her face follows.
    @objc private func activityMilestone(_ note: Notification) {
        guard let event = note.userInfo?["event"] as? String, let s = note.userInfo?["session"] as? ClaudeSession else { return }
        let title = s.title.isEmpty ? "that" : "“\(ClaudeActivityService.oneLine(s.title, max: 40))”"
        liveDismissed = false
        switch event {
        case "prompt": say("on it — Claude's working on \(title) 👩‍💻", mood: .focused, for: 3)
        case "waiting": if !approvalPending { say("Claude needs you in \(s.folderName) 🙋", mood: .thinking, for: 6) }
        case "done": say("Claude finished \(title) 🎉", mood: .celebrate, for: 5)
        default: break
        }
    }
    private var reminderAlertPending: Bool { MainActor.assumeIsolated { !ReminderService.shared.pendingAlerts.isEmpty } }

    @objc private func reminderFired(_ note: Notification) {
        guard let a = note.userInfo?["alert"] as? ReminderAlert else { return }
        let mood: ZeraMood
        switch a.kind {
        case .breakTime: mood = .cozy
        case .calendarHeadsUp, .headsUp: mood = .hello
        case .calendarNow, .now, .snoozed: mood = .excited
        }
        say(a.headline, mood: mood, for: 0)
        if cardVisible, currentCard == .approval, approvalPending { return }
        if !(cardVisible && currentCard == .reminderAlert) { show(.reminderAlert) }
        else { (cards[.reminderAlert] as? ReminderAlertCard)?.reload() }
    }

    @objc private func remindersChanged() {
        refreshBadges()
        if cardVisible, currentCard == .reminderAlert { (cards[.reminderAlert] as? ReminderAlertCard)?.reload() }
        if cardVisible, currentCard == .reminders { (cards[.reminders] as? RemindersView)?.reload() }
    }

    /// Light ↔ dark: throw the cards away and rebuild the visible one in the new colours.
    @objc private func paletteChanged() {
        let showing = cardVisible ? currentCard : nil
        let settingsPane = (cards[.settings] as? SettingsCard)?.current
        cards.removeAll()
        currentContent?.removeFromSuperview()
        currentContent = nil
        currentCard = nil
        cardPanel.appearance = Pal.nsAppearance
        livePanel.appearance = Pal.nsAppearance
        live.themeChanged()
        if let k = showing {
            show(k, instant: true)
            if k == .settings, let pane = settingsPane { (cards[.settings] as? SettingsCard)?.select(pane) }
        }
    }

    // MARK: - Quick actions & Claude

    /// The one deliberately external action: "Open Claude" opens the Claude desktop app, or —
    /// only if it is not installed — a Terminal window running plain `claude`. The command is a
    /// fixed string; nothing the user typed is ever placed in it. Summarize / Explain / Extract /
    /// Ask never come through here: they run inside Zera (`ZeraAssistant`).
    func openClaudeCode() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil { say("couldn't open Terminal 😬", mood: .worried, for: 3) }
    }

    func perform(_ action: QuickAction) {
        switch action {
        case .openClaude:
            openClaudeCode()
            say("opening Claude ✨", mood: .focused, for: 2)
        case .dropFiles:
            show(.shelf)
        case .newNote:
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
            let pb = NSPasteboard(name: NSPasteboard.Name("ai.zera.note"))
            pb.clearContents()
            pb.setString("# Note — \(stamp)\n\n", forType: .string)
            let n = ShelfStore.shared.ingest(pasteboard: pb)
            if n > 0, let item = ShelfStore.shared.items.first {
                NSWorkspace.shared.open(item.url)
                show(.shelf)
                (cards[.shelf] as? DropFilesView)?.select(filter: .notes)
                say("new note on the shelf 📝", mood: .happy, for: 2)
            }
        case .takeBreak:
            MainActor.assumeIsolated { ReminderService.shared.triggerBreakNow() }
        case .screenshot:
            hideCard()
            // Interactive capture to the clipboard, then onto the shelf.
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-i", "-c"]
                try? p.run()
                p.waitUntilExit()
                DispatchQueue.main.async { [weak self] in
                    let n = ShelfStore.shared.ingest(pasteboard: .general)
                    if n > 0 { self?.show(.shelf); self?.say("screenshot's on the shelf 📸", mood: .happy, for: 2) }
                }
            }
        case .startTimer:
            // A 25-minute focus timer: a one-off reminder Zera will announce.
            let due = Date().addingTimeInterval(25 * 60)
            MainActor.assumeIsolated {
                ReminderService.shared.addOneOff(title: "Timer's up — 25 min focus done", at: due)
            }
            say("timer set — I'll tell you at \(ReminderService.timeFormatter.string(from: due)) ⏱", mood: .focused, for: 3)
            hideCard()
        case .searchFiles:
            show(.home)
            (cards[.home] as? HomeCard)?.focusSearch()
        case .askZera(let q):
            MainActor.assumeIsolated { ZeraAssistant.shared.askGeneral(q) }
            resultsInShelf = false
            userHidResult = false
            show(.result)
        }
    }

    // MARK: - Zera's file assistant

    /// Summarize / Explain / Extract / Ask from the shelf: Zera thinks, Claude runs hidden in
    /// the background, the answer streams into the result card. No terminal, ever.
    func shelfRequests(_ action: FileAction, on item: ShelfItem) {
        let busyWith: String? = MainActor.assumeIsolated {
            let a = ZeraAssistant.shared
            if a.isBusy { return a.session?.fileName ?? "the last one" }
            a.run(action, on: item.url)
            return nil
        }
        if let name = busyWith { say("still working on \(name) — one sec ⏳", mood: .focused, for: 2.5) }
        resultsInShelf = false
        userHidResult = false
        show(.result)
    }

    /// From the Drop Files screen: the answer streams into its own result panel, so the card
    /// stays put. If you close it meanwhile, the Drop Files screen comes back when it's done.
    func shelfRunsInPlace(_ action: FileAction, on item: ShelfItem) {
        let busyWith: String? = MainActor.assumeIsolated {
            let a = ZeraAssistant.shared
            if a.isBusy { return a.session?.fileName ?? "the last one" }
            a.run(action, on: item.url)
            return nil
        }
        if let name = busyWith { say("still working on \(name) — one sec ⏳", mood: .focused, for: 2.5); return }
        resultsInShelf = true
        userHidResult = false
        say("sending \(item.name) to Claude via your Claude Code login… 🤔", mood: .thinking, for: 0)
    }

    /// Where a finished answer appears if no card is open: the Drop Files screen when the
    /// request started there, otherwise the result card.
    private var resultsInShelf = false
    /// The next Claude screen opens with the session's live view (set by the live bar).
    private var claudeOpenExpanded = false

    /// Same as the shelf, for files Zera made herself (a PR brief from the GitHub card).
    func assist(_ action: FileAction, on url: URL) {
        let busyWith: String? = MainActor.assumeIsolated {
            let a = ZeraAssistant.shared
            if a.isBusy { return a.session?.fileName ?? "the last one" }
            a.run(action, on: url)
            return nil
        }
        if let name = busyWith { say("still working on \(name) — one sec ⏳", mood: .focused, for: 2.5); return }
        resultsInShelf = false
        userHidResult = false
        show(.result)
    }

    private var lastAssistantPhase: ZeraAssistant.Phase = .idle

    /// Zera's face follows the request: thinking → focused → happy, worried on errors.
    @objc private func assistantChanged() {
        let (phase, name, hasFile) = MainActor.assumeIsolated { () -> (ZeraAssistant.Phase, String, Bool) in
            let a = ZeraAssistant.shared
            return (a.phase, a.currentFileName ?? "that", a.currentFileName != nil && a.session?.isGeneral != true)
        }
        if cardVisible, currentCard == .result { (cards[.result] as? ResultCard)?.reload() }
        guard phase != lastAssistantPhase else { return }
        lastAssistantPhase = phase
        switch phase {
        case .idle: break
        case .starting: say(hasFile ? "reading \(name)… 🤔" : "thinking… 🤔", mood: .thinking, for: 0)
        case .analyzing: say(hasFile ? "reading \(name)…" : "hmm…", mood: .focused, for: 0)
        case .streaming: say("here's what I've got ✍️", mood: .focused, for: 0)
        case .done:
            say(userHidResult ? "done! tap me to see it 🎉" : "done! 🎉", mood: .celebrate, for: userHidResult ? 4 : 2)
            if !cardVisible, !userHidResult { show(resultsInShelf ? .shelf : .result) }
        case .failed(let err):
            let needsSetup = err.action == .openClaudeSettings || err.action == .configureAPIKey || err.action == .updateAPIKey
            say(needsSetup ? "I need Claude connected first 👉" : "hmm, that didn't work 😬", mood: needsSetup ? .surprised : .worried, for: 4)
            if !cardVisible, !userHidResult { show(resultsInShelf ? .shelf : .result) }
        case .cancelled: settle()
        }
    }

    // MARK: - Cards

    private func open(_ url: URL) {
        hideCard()
        settle()
        NSWorkspace.shared.open(url)
    }

    private func content(for kind: CardKind) -> any CardContent {
        if let c = cards[kind] { return c }
        let c: any CardContent
        switch kind {
        case .shelf:
            let s = DropFilesView()
            s.delegate = self
            c = s
        case .home:
            let h = HomeCard()
            h.onOpen = { [weak self] k in self?.show(k) }
            h.onAction = { [weak self] a in self?.perform(a) }
            h.onOpenURL = { [weak self] u in self?.open(u) }
            c = h
        case .github:
            let g = GitHubCard()
            g.onOpenSettings = { [weak self] in
                self?.show(.settings)
                (self?.cards[.settings] as? SettingsCard)?.select(.github)
            }
            g.onOpenURL = { [weak self] u in self?.open(u) }
            g.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 3) }
            g.onSummarize = { [weak self] url, question in self?.assist(.ask(question), on: url) }
            c = g
        case .settings:
            let s = SettingsCard(defaultKind: defaultCard, showingZera: buddyEnabled,
                                 loginEnabled: SMAppService.mainApp.status == .enabled)
            s.onDefaultChanged = { [weak self] k in self?.defaultCard = k }
            s.onShowZeraChanged = { [weak self] on in self?.setBuddyEnabled(on) }
            s.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 3) }
            c = s
        case .approval:
            let a = ApprovalCard()
            a.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 2.5) }
            a.onDrained = { [weak self] in
                guard let self = self, self.cardVisible, self.currentCard == .approval else { return }
                self.hideCard(); self.settle()
            }
            c = a
        case .reminders:
            let r = RemindersView()
            r.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 2.5) }
            c = r
        case .reminderAlert:
            let r = ReminderAlertCard()
            r.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 2.5) }
            r.onDrained = { [weak self] in
                guard let self = self, self.cardVisible, self.currentCard == .reminderAlert else { return }
                self.hideCard(); self.settle()
            }
            r.onView = { [weak self] a in
                guard let self = self else { return }
                // Open the screen straight on that reminder's details.
                (self.content(for: .reminders) as? RemindersView)?.focusOnShow = a.reminderID
                self.show(.reminders)
            }
            c = r
        case .toast:
            let t = ToastCard()
            t.onDismiss = { [weak self] in
                guard let self = self, self.cardVisible, self.currentCard == .toast else { return }
                self.hideCard(); self.settle()
            }
            t.onOpenURL = { [weak self] u in self?.open(u) }
            c = t
        case .claude:
            let a = ClaudeSessionsView()
            a.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 2.5) }
            a.onOpenSettings = { [weak self] in
                self?.show(.settings)
                (self?.cards[.settings] as? SettingsCard)?.select(.claude)
            }
            // The one external action here, and only when you press it.
            a.onNewSession = { [weak self] in self?.openClaudeCode() }
            a.onReviewApproval = { [weak self] in self?.show(.approval) }
            a.onAsk = { [weak self] url, question in self?.assist(.ask(question), on: url) }
            c = a
        case .result:
            let r = ResultCard()
            r.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 2.5) }
            r.onClose = { [weak self] in
                guard let self = self else { return }
                self.suppressUntil = Date().addingTimeInterval(0.8)
                self.hideCard(); self.settle()
            }
            r.onOpenClaudeSettings = { [weak self] in
                self?.show(.settings)
                (self?.cards[.settings] as? SettingsCard)?.select(.claude)
            }
            c = r
        }
        let escape: () -> Void = { [weak self] in
            guard let self = self else { return }
            if self.currentCard == .approval, self.approvalPending { return }
            self.suppressUntil = Date().addingTimeInterval(0.8)
            self.hideCard(); self.settle()
        }
        (c as? CardBase)?.onEscape = escape
        (c as? ClaudeSessionsView)?.onEscape = escape
        (c as? DropFilesView)?.onEscape = escape
        (c as? RemindersView)?.onEscape = escape
        cards[kind] = c
        return c
    }

    func toggleDefaultCard() { cardVisible ? dismissCardByUser() : show(defaultCard) }

    /// Set when you put the result card away while Zera was still working, so the answer
    /// does not jump back in front of you — her bubble says when it is ready instead.
    private var userHidResult = false

    /// Hide on purpose (tap on her, click elsewhere, Esc): no bounce-back.
    private func dismissCardByUser() {
        if currentCard == .result, MainActor.assumeIsolated({ ZeraAssistant.shared.isBusy }) { userHidResult = true }
        suppressUntil = Date().addingTimeInterval(0.8)
        hideCard()
        settle()
    }

    func show(_ kind: CardKind, instant: Bool = false) {
        // Missing files stay listed (marked "no longer available") so you can see what happened.
        outsideSince = nil
        autoHideWork?.cancel()
        // The pill stays while the pointer is on it, so you can hop between cards; it folds
        // away on its own once the pointer leaves.

        let swapping = currentCard != kind
        if swapping {
            currentContent?.removeFromSuperview()
            let c = content(for: kind)
            c.onHeightChange = { [weak self] in self?.cardHeightChanged() }
            cardPanel.contentView = c
            currentContent = c
            currentCard = kind
        }
        switch kind {
        case .shelf: (cards[.shelf] as? DropFilesView)?.willShow()
        case .github:
            (cards[.github] as? GitHubCard)?.reload()
            let (reviews, open, connected) = MainActor.assumeIsolated { () -> (Int, Int, Bool) in
                let gh = GitHubService.shared
                gh.markAllSeen()
                return (gh.events.filter { $0.kind == .reviewRequested }.count, gh.events.filter { $0.kind == .prOpened }.count, gh.isConnected)
            }
            if swapping, connected {
                if reviews > 0 { say("\(reviews) PR\(reviews == 1 ? " needs" : "s need") your review! 👀", mood: .thinking, for: 3) }
                else if open > 0 { say("\(open) open PR\(open == 1 ? "" : "s") — want a look? 👀", mood: .hello, for: 2.5) }
                else { say("all quiet on GitHub ✨", mood: .happy, for: 2) }
            }
        case .home: (cards[.home] as? HomeCard)?.refresh()
        case .approval: (cards[.approval] as? ApprovalCard)?.reload()
        case .reminders: (cards[.reminders] as? RemindersView)?.willShow()
        case .reminderAlert: (cards[.reminderAlert] as? ReminderAlertCard)?.reload()
        case .toast: if let e = pendingToast { (cards[.toast] as? ToastCard)?.show(event: e) }
        case .result: (cards[.result] as? ResultCard)?.reload()
        case .claude:
            (cards[.claude] as? ClaudeSessionsView)?.willShow(expanded: claudeOpenExpanded)
            claudeOpenExpanded = false
        case .settings: break
        }

        let alreadyUp = cardVisible && cardPanel.isVisible
        cardVisible = true
        pill.activeKind = kind
        hideLive()   // the card takes the space; the readout comes back when it closes
        isPresenting = true
        currentContent?.needsLayout = true
        currentContent?.layoutSubtreeIfNeeded()
        isPresenting = false

        let frame = cardFrame()
        if instant || (alreadyUp && !swapping) {
            cardPanel.setFrame(frame, display: true)
            setCardAlpha(1, duration: 0)
            cardPanel.orderFrontRegardless()
            cardPanel.display()
            if kind == .approval { cardPanel.makeKey() }
            return
        }
        if alreadyUp {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(0.18)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cardPanel.animator().setFrame(frame, display: true)
            }
            if kind == .approval { cardPanel.makeKey() }
            return
        }
        cardPanel.setFrame(frame.offsetBy(dx: 0, dy: 10), display: false)
        setCardAlpha(0, duration: 0)
        cardPanel.orderFrontRegardless()
        if kind == .approval { cardPanel.makeKey() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(0.2)
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
            cardPanel.animator().alphaValue = 1
            cardPanel.animator().setFrame(frame, display: true)
        }
        if kind == .shelf, ShelfStore.shared.items.isEmpty, bubblePanel.alphaValue < 0.5 {
            say("drop files here — I'll help you work with them 💜", mood: .idle, for: 2.6)
        }
    }

    private func setCardAlpha(_ value: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            cardPanel.animator().alphaValue = value
        }
        if duration == 0 { cardPanel.alphaValue = value }
    }

    func hideCard() {
        guard cardVisible else { return }
        MainActor.assumeIsolated { ZeraDropdown.shared.dismiss() }
        cardVisible = false
        pill.activeKind = nil
        outsideSince = nil
        externalDragOver = false
        autoHideWork?.cancel()
        let resting = cardPanel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(0.16)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            cardPanel.animator().alphaValue = 0
            cardPanel.animator().setFrame(resting.offsetBy(dx: 0, dy: 8), display: true)
        }, completionHandler: { [weak self] in
            guard let self = self, !self.cardVisible else { return }
            self.cardPanel.orderOut(nil)
            self.cardPanel.setFrame(resting, display: false)
            self.updateLive()
        })
    }

    private func cardFrame() -> NSRect {
        guard let c = currentContent else { return cardPanel.frame }
        let vf = geometry.screen.visibleFrame
        let h = min(c.desiredHeight, vf.height - 40)
        let top = figureRect.minY - Theme.cardGap
        let x = max(vf.minX + 8, min(vf.maxX - c.cardWidth - 8, figureRect.midX - c.cardWidth / 2))
        return NSRect(x: x, y: top - h, width: c.cardWidth, height: h)
    }

    private func evaluateHide(_ mouse: NSPoint) {
        if isDraggingOut || externalDragOver || buddyDragActive || mouseButtonDown {
            outsideSince = nil
            return
        }
        if cardPanel.isKeyWindow, cardPanel.firstResponder is NSTextView {
            outsideSince = nil
            return
        }
        // One of Zera's dropdowns is open (it can hang below the card): keep the card up.
        if MainActor.assumeIsolated({ ZeraDropdown.shared.isOpen }) {
            outsideSince = nil
            return
        }
        if currentCard == .approval, approvalPending {
            outsideSince = nil
            return
        }
        if currentCard == .reminderAlert, reminderAlertPending, let since = outsideSince,
           Date().timeIntervalSince(since) < 20 {
            return
        }
        if currentCard == .result, MainActor.assumeIsolated({ ZeraAssistant.shared.isBusy }) {
            outsideSince = nil   // she is still working on it; do not pull the answer away
            return
        }
        let grace: TimeInterval = currentCard == .toast ? 6 : (currentCard == .result ? 4 : leaveGrace)
        let zone = cardPanel.frame.insetBy(dx: -hoverPadding, dy: -hoverPadding)
            .union(figureRect.insetBy(dx: -10, dy: -10))
        if NSPointInRect(mouse, zone) {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) >= grace { hideCard() }
        } else {
            outsideSince = Date()
        }
    }

    @objc private func storeChanged() {
        if cardVisible { cardHeightChanged() }
    }

    private func cardHeightChanged() {
        guard cardVisible, !isPresenting else { return }
        let frame = cardFrame()
        guard abs(frame.height - cardPanel.frame.height) > 0.5 || abs(frame.minX - cardPanel.frame.minX) > 0.5
                || abs(frame.width - cardPanel.frame.width) > 0.5 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(0.16)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cardPanel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - ShelfViewDelegate

    func shelfDidAcceptDrop() {
        cardHeightChanged()
        scheduleAutoHide(after: 1.0)
    }

    private func scheduleAutoHide(after delay: TimeInterval) {
        autoHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.cardVisible, self.currentCard == .shelf else { return }
            guard !self.isDraggingOut, !self.externalDragOver, !self.buddyDragActive, !self.mouseButtonDown else {
                self.scheduleAutoHide(after: 0.5)
                return
            }
            let zone = self.cardPanel.frame.insetBy(dx: -14, dy: -14).union(self.figureRect)
            guard !NSPointInRect(NSEvent.mouseLocation, zone) else { return }
            self.hideCard()
        }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func shelfDragOverChanged(_ over: Bool) {
        externalDragOver = over
        if over { autoHideWork?.cancel(); outsideSince = nil }
    }

    func shelfDragOutBegan() { isDraggingOut = true }
    func shelfDragOutEnded() { isDraggingOut = false; outsideSince = Date() }
    func shelfRequestsHide() { suppressUntil = Date().addingTimeInterval(0.8); hideCard() }
    func shelfHeightChanged() { cardHeightChanged() }
    func shelfSays(_ line: String, mood: ZeraMood, for seconds: TimeInterval) { say(line, mood: mood, for: seconds) }
    func shelfSettles() { settle() }

    // MARK: - External entry points

    func pasteFromClipboard() {
        if !(cardVisible && currentCard == .shelf) { show(.shelf) }
        (cards[.shelf] as? DropFilesView)?.paste()
    }

    func add(urls: [URL]) {
        let n = ShelfStore.shared.add(urls: urls)
        if n > 0 {
            if !(cardVisible && currentCard == .shelf) { show(.shelf) }
            say(n == 1 ? "got it! ✨" : "got all \(n)! ✨", mood: .happy, for: 1.6)
            shelfDidAcceptDrop()
        }
    }
}
