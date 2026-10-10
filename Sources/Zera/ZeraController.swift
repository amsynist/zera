import AppKit
import ServiceManagement

/// Owns everything on screen: Zera dangling from the notch, her speech bubble, the live wings,
/// and the notch island every screen opens in. Polls the pointer so she can watch it,
/// greet you when you come close, and doze off when you have been away for a while.
final class ZeraController: NSObject, ShelfViewDelegate {

    // MARK: Windows & views

    private var geometry = NotchGeometry.detect()
    private let buddyPanel: FloatingPanel
    private let buddy = BuddyView()
    private let bubblePanel: FloatingPanel
    private let bubble = BubbleView()
    private var waterVisit: WaterReminderVisit?
    /// The glass under the notch (today's water) and the weekly card it opens.
    private let waterCounterPanel = FloatingPanel.make(size: WaterGlassCounterView.size, level: .popUpMenu, keyable: false)
    private let waterCounter = WaterGlassCounterView(frame: NSRect(origin: .zero, size: WaterGlassCounterView.size))
    private lazy var waterWeek = WaterWeekPanel()
    /// The glass under the notch only shows for a moment after a sip (and while a reminder waits).
    private var waterGlassUntil = Date.distantPast
    private var waterGlassTimer: Timer?
    /// Claude Code's live readout: two wings hanging off her on either side of the rope.
    private let livePanel: FloatingPanel
    private let live = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
    private var liveVisible = false
    private var liveHideWork: DispatchWorkItem?
    /// Minimize keeps the readout hidden until something needs you (an approval, or a finished
    /// turn you can reply to) or you open the Claude tab; then it stays up until the next minimize.
    private var liveDismissed = false
    /// The finished turn ("session id|prompt time") that last brought minimized wings back, so
    /// minimizing again keeps that same turn tucked away.
    private var surfacedFinish: String?
    /// A finished session has already had its ten seconds on screen.
    private var finishedLiveHidden = false
    /// The notch island: every screen opens out of the notch inside this window. It is a fixed
    /// transparent canvas; only the island's shape is drawn and takes the pointer.
    private let cardPanel: FloatingPanel
    private let island = IslandView()

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
    /// Whether the pointer has been on the open island yet. Until it has, the island stays put:
    /// you opened it from somewhere else (a wing's chevron, a tab, a notification) and haven't
    /// reached it yet. A click elsewhere or esc still closes it.
    private var islandVisited = false
    private var isDraggingOut = false
    private var externalDragOver = false
    private var buddyDragActive = false
    private var autoHideWork: DispatchWorkItem?
    private var bannerCountdown: BannerCountdown?
    private var isPresenting = false
    private(set) var cardVisible = false
    private var suppressUntil = Date.distantPast
    
    private var hoverPokes = 0
    private var lastHelloSound: CFTimeInterval = 0
    private var lastHoverPokeTime: TimeInterval = 0

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

    /// Settings › "Show Zera at the notch".
    var buddySetting: Bool {
        UserDefaults.standard.object(forKey: Self.buddyDefaultsKey) as? Bool ?? true
    }
    /// Whether she's out right now: the setting, unless she's tucked away for a full-screen app.
    var buddyEnabled: Bool { buddySetting && !fullScreenHidden }

    // MARK: Full screen

    private let fullScreen = FullScreenWatcher()
    /// Tucked away while another app is full screen (Settings › In full-screen apps).
    private var fullScreenHidden = false
    /// Brought back from the menu bar during this full-screen stretch: stay out until it ends.
    private var fullScreenKeep = false
    private var fullScreenWork: DispatchWorkItem?

    private func startFullScreenWatch() {
        fullScreen.screen = { [weak self] in self?.geometry.screen }
        fullScreen.onChange = { [weak self] _ in self?.fullScreenChanged() }
        fullScreen.start()
    }

    /// Full screen came or went, or the setting changed: hide her after the chosen delay, or
    /// bring her back.
    func fullScreenChanged() {
        fullScreenWork?.cancel()
        fullScreenWork = nil
        guard fullScreen.isFullScreen, FullScreenHide.enabled, !fullScreenKeep else {
            if !fullScreen.isFullScreen { fullScreenKeep = false }
            setFullScreenHidden(false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.fullScreen.isFullScreen, !self.fullScreenKeep else { return }
            self.setFullScreenHidden(true)
        }
        fullScreenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(max(0, FullScreenHide.delay)), execute: work)
    }

    private func setFullScreenHidden(_ hidden: Bool) {
        guard hidden != fullScreenHidden else { return }
        fullScreenHidden = hidden
        guard buddySetting else { return }
        setBuddy(visible: !hidden, animated: true)
        if hidden { hideBubble(); hidePill(); hideLive(); if cardVisible { hideCard() } }
        else { updateLive() }
    }

    /// Menu bar › Hide Zera / Bring Zera Back.
    func setZeraShowing(_ on: Bool) {
        if on {
            if fullScreenHidden { fullScreenKeep = true; fullScreenWork?.cancel(); setFullScreenHidden(false) }
            if !buddySetting { setBuddyEnabled(true) }
        } else {
            setBuddyEnabled(false)
        }
    }

    /// What a tap on her opens. A saved value of -1 means Nothing.
    var defaultCard: CardKind? {
        get {
            let rawValue = UserDefaults.standard.integer(forKey: Self.defaultCardKey)
            return rawValue == -1 ? nil : (CardKind(rawValue: rawValue) ?? .shelf)
        }
        set { UserDefaults.standard.set(newValue?.rawValue ?? -1, forKey: Self.defaultCardKey) }
    }

    // MARK: - Setup

    override init() {
        // Island over the menu bar, Zera above the island, her speech bubble above her.
        let level = { (n: Int) in NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + n) }
        buddyPanel = FloatingPanel.make(size: NSSize(width: Theme.buddyWidth, height: 90), level: level(2), keyable: false)
        bubblePanel = FloatingPanel.make(size: NSSize(width: 120, height: 30), level: level(3), keyable: false)
        livePanel = FloatingPanel.make(size: LiveActivityView.panelSize, level: .floating, keyable: false)
        cardPanel = FloatingPanel.make(size: NSSize(width: Theme.panelWidth, height: 240), level: level(1), keyable: true)
        super.init()

        buddyPanel.contentView = buddy
        // Her window is much bigger than she is; a window shadow would trace its see-through
        // parts as she moves. She draws her own soft shadow instead.
        buddyPanel.hasShadow = false
        buddy.bottomPad = Theme.figurePad
        buddyPanel.alphaValue = 0
        buddy.onActivate = { [weak self] in
            guard let self = self else { return }
            guard !self.zera.isReactingToPokes else { return }
            if self.zera.poke() {
                self.sound(.huff)
                self.say("Hey! Gentle taps, please 😠", mood: .error, for: ZeraPokeReaction.duration)
                return
            }
            self.sound(.tap)
            if self.zera.mood == .error || self.zera.mood == .worried { return }
            
            // Tap her: open the default card, or tuck away whatever is open so you can get back
            // to your work (the tabs beside the notch still let you jump straight to another screen).
            if self.cardVisible {
                self.dismissCardByUser()
            } else {
                guard let defaultCard = self.defaultCard else { return }
                self.suppressUntil = .distantPast
                let answerWaiting = self.userHidResult && MainActor.assumeIsolated { !ZeraAssistant.shared.isBusy && ZeraAssistant.shared.session != nil }
                self.userHidResult = false
                self.show(answerWaiting ? (self.resultsInShelf ? .shelf : .result) : defaultCard)
            }
        }
        buddy.onDrop = { [weak self] pb in
            guard let self = self else { return false }
            // One motion: she catches it and the Shelf is there in the same frame. The drop's
            // contents are read now; a picture or text is written to disk after, off the main thread.
            guard let payload = ShelfStore.payload(from: pb) else {
                self.sound(.fileReject)
                self.say("hmm, can't hold that", mood: .thinking, for: 1.6)
                return false
            }
            let already = ShelfStore.shared.alreadyHas(pasteboard: pb)
            self.sound(.fileCatch)
            self.suppressUntil = .distantPast
            self.show(.shelf, instant: true)
            ShelfStore.shared.ingest(payload) { [weak self] n in
                guard let self = self else { return }
                if n == 0 && !already {
                    self.say("hmm, can't hold that", mood: .thinking, for: 1.6)
                    return
                }
                self.say(n == 1 ? "got it! ✨" : (n > 1 ? "got all \(n)! ✨" : "already have that one 😊"), mood: .happy, for: 1.6)
                self.shelfDidAcceptDrop()
            }
            return true
        }
        buddy.onDragStateChange = { [weak self] active in
            guard let self = self else { return }
            self.buddyDragActive = active
            if active {
                self.sound(.fileHover)
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
            self.sound(.lift)
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
            self.sound(.land)
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
        bubblePanel.hasShadow = false // the capsule draws its own subtle edge; no second black ring
        bubblePanel.alphaValue = 0

        island.onClose = { [weak self] in self?.dismissCardByUser() }
        island.onSearch = { [weak self] in
            guard let self = self else { return }
            self.suppressUntil = .distantPast
            if self.cardVisible { self.hideCard() }
            if self.pillVisible { self.hidePill() }
            self.toggleOpener()
        }
        island.onTab = { [weak self] kind in
            guard let self = self else { return }
            self.suppressUntil = .distantPast
            // The open screen's tab puts the island away; any other tab switches to it.
            if self.cardVisible, let c = self.currentCard, Isle.tab(for: c) == kind { self.dismissCardByUser() } else { self.show(kind) }
        }

        livePanel.contentView = live
        livePanel.hasShadow = false         // the wings draw their own glow
        livePanel.appearance = NSAppearance(named: .darkAqua)   // the wings are always dark glass
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
            // A second tap right after a decision (a double-click) answers nothing.
            guard MainActor.assumeIsolated({ ClaudeHookService.shared.respond(req, allow: allow) }) else { return }
            self.sound(allow ? .claudeApproved : .claudeRejected)
            // The wing folds with the answer; she just looks pleased (or thoughtful).
            self.react(allow ? .happy : .thinking, for: 1.8)
            self.updateLive()
        }
        // Reply from a finished session's wing: Claude carries on in that same session — the one
        // the field was opened for, even if another session has become current meanwhile.
        live.onReplyStart = { [weak self] in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                guard let s = ClaudeActivityService.shared.current else { return }
                self.replySession = s
                ClaudeActivityService.shared.holdReply(s)
            }
            // The wings take keyboard focus only while you type a reply.
            self.livePanel.keyable = true
            self.livePanel.makeKey()
        }
        live.onReplySend = { [weak self] text in
            guard let self = self else { return }
            self.livePanel.keyable = false
            MainActor.assumeIsolated {
                guard let s = self.replySession ?? ClaudeActivityService.shared.current else { return }
                self.replySession = nil
                ClaudeActivityService.shared.sendReply(s, text) { [weak self] sent in
                    guard let self = self else { return }
                    if sent {
                        self.sound(.claudeStart)
                        self.say("sent ✨ Claude's on it", mood: .happy, for: 2.2)
                    } else {
                        NSSound.beep()
                        self.say("too late, that session already finished", mood: .thinking, for: 2.6)
                    }
                    self.updateLive()
                }
            }
        }
        live.onReplyCancel = { [weak self] in
            guard let self = self else { return }
            self.livePanel.keyable = false
            self.releaseReplySession()
            self.updateLive()
        }
        live.onMinimize = { [weak self] in
            guard let self = self else { return }
            self.liveDismissed = true
            self.liveHideWork?.cancel()
            self.liveHideWork = nil
            self.hideLive()
            self.settle()
        }

        cardPanel.contentView = island
        cardPanel.hasShadow = false          // the island draws its own glow
        cardPanel.appearance = NSAppearance(named: .darkAqua)
        cardPanel.ignoresMouseEvents = true

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(storeChanged), name: ShelfStore.changed, object: nil)
        nc.addObserver(self, selector: #selector(githubChanged), name: GitHubService.changed, object: nil)
        nc.addObserver(self, selector: #selector(vitalsChanged), name: SystemVitals.changed, object: nil)
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
        // Find `claude` in the background now, so the first Summarize does not wait for it; the
        // same for whether an API key is saved (a Keychain read that can stall the UI thread).
        ClaudeCLI.shared.ensureProbed { _ in }
        _ = AnthropicAPIClient.shared.isConfigured

        // A click anywhere else on the screen puts the card away at once — no waiting for the
        // pointer to wander off. (Our own panels get local events, so this never fires for them.)
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.cardVisible, !self.dragging, !self.buddyDragActive, !self.isDraggingOut else { return }
            if self.currentCard == .approval, self.approvalPending { return }
            // Notification banners keep their reading time while you work in other apps.
            if self.isNotificationBanner { return }
            let m = NSEvent.mouseLocation
            if NSPointInRect(m, self.islandScreenRect) || NSPointInRect(m, self.figureRect.insetBy(dx: -8, dy: -6))
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
        _ = ClipboardStore.shared   // starts watching the clipboard, if history is on
        registerClipboardHotKey()
        setUpOpener()
        tasks.onSay = { [weak self] line in self?.say(line, mood: .happy, for: 2.6) }
        tasks.onShowList = { [weak self] in self?.suppressUntil = .distantPast; self?.show(.tasks) }
        tasks.onShortcutChanged = { [weak self] label in (self?.cards[.tasks] as? TasksCard)?.shortcutLabel = label }
        tasks.start()
        MainActor.assumeIsolated {
            GitHubService.shared.startPolling()
            startFullScreenWatch()
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
        if cardVisible || pillVisible { positionIsland() }
        if liveVisible { positionLive() }
        positionBubble()
    }

    func setBuddyEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.buddyDefaultsKey)
        setBuddy(visible: buddyEnabled, animated: true)
        if !on { hideBubble(); hidePill(); hideLive(); if cardVisible { hideCard() } }
    }

    private func setBuddy(visible: Bool, animated: Bool) {
        defer { refreshWaterGlass() }
        let visible = visible && !(waterVisit?.isActive ?? false)
        if visible {
            if buddyPanel.alphaValue < 0.05 { buddyPanel.orderFrontRegardless() }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = animated ? 0.3 : 0
                buddyPanel.animator().alphaValue = 1
            }, completionHandler: { ZeraAnimationClock.shared.refresh() })
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

    /// Keep speech beside Zera and clear of the hover rail, wings and menu bar.
    private func positionBubble() {
        let screen = geometry.screen.frame
        // Reserve the menu bar even when macOS has it hidden.
        let safeFrame = NSRect(x: screen.minX + 8, y: screen.minY + 8,
                               width: screen.width - 16, height: geometry.notchRect.minY - screen.minY - 8)
        let size = BubbleView.size(for: bubble.text.isEmpty ? " " : bubble.text, maxWidth: safeFrame.width)
        var obstacles: [NSRect] = []
        if cardVisible || pillVisible {
            let panel = cardPanel.frame
            obstacles += island.captionObstacles.map {
                NSRect(x: panel.minX + $0.minX, y: panel.maxY - $0.maxY, width: $0.width, height: $0.height)
            }
        }
        if liveVisible { obstacles.append(livePanel.frame) }
        // Holding the rope with both hands, her body sits off the rope's line.
        let bodyX = figureRect.midX + (zera.activity != .none ? zera.claudeBodyOffset : 0)
        let tag = BubbleView.frame(for: size, figure: figureRect, bodyX: bodyX, safeFrame: safeFrame, obstacles: obstacles)
        let panel = BubbleView.panelFrame(for: tag)
        bubblePanel.setFrame(panel, display: true)
        bubble.frame = NSRect(origin: .zero, size: panel.size)
        bubble.pointToward(NSPoint(x: bodyX - panel.minX, y: panel.maxY - (figureRect.minY + figureRect.height * 0.45)))
    }

    /// Spans the screen around her at chest height: the left wing ends in a tendril just left
    /// of her, the right wing just right. Near a screen edge the panel is clamped and the wing
    /// on that side gets shorter (or folds away when there is no room).
    private func positionLive() {
        let scr = geometry.screen.frame
        let size = NSSize(width: min(LiveActivityView.panelSize.width, scr.width), height: LiveActivityView.panelSize.height)
        // The tendrils reach into her body, which hangs beside the rope in the Claude pose.
        let cx = figureRect.midX + (zera.activity == .none ? 0 : zera.claudeBodyOffset)
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

    /// The finished session a reply is being typed for (held open until it is sent or dropped).
    private var replySession: ClaudeSession?

    /// The reply field went away without a send: let that session's hook finish.
    private func releaseReplySession() {
        guard let s = replySession else { return }
        replySession = nil
        MainActor.assumeIsolated { ClaudeActivityService.shared.releaseReply(s) }
    }

    /// Shows / updates / hides the wings from the current Claude session and pending approvals.
    private func updateLive() {
        let (show, done, quiet): (Bool, Bool, Bool) = MainActor.assumeIsolated {
            let s = ClaudeActivityService.shared.current
            let hooks = ClaudeHookService.shared.pending
            let pending = s.flatMap { s in hooks.first { $0.sessionID == s.id } } ?? hooks.first
            // Idle sessions stay visible for a few minutes after their last activity.
            let stale = s.map { $0.status == .ended || ($0.status == .idle && Date().timeIntervalSince($0.lastEventAt) > 600) } ?? true
            // A turn that just finished brings minimized wings back (once), so you can see it and reply.
            if let s = s, s.status == .done, !stale {
                let key = "\(s.id)|\(s.promptAt?.timeIntervalSince1970 ?? 0)"
                if key != self.surfacedFinish {
                    self.surfacedFinish = key
                    self.liveDismissed = false
                }
            }
            // Nothing running, nothing waiting on you, no reply still on offer.
            let quiet = ClaudeActivityService.shared.active.isEmpty && hooks.isEmpty && !(s?.canReply ?? false)
            if stale && pending == nil { return (false, false, quiet) }
            self.live.replyWindow = Double(ClaudeActivityService.shared.replyWindow)
            // An approval from another session is shown on its own, never under this session's
            // task line, so the words and the command on the wings always belong together.
            let foreign = pending.map { !$0.sessionID.isEmpty && $0.sessionID != s?.id } ?? false
            self.live.update(session: stale || foreign ? nil : s, pending: pending)
            // The field folded away on its own (the session moved on): the reply is dropped.
            if self.replySession != nil, !self.live.composing { self.livePanel.keyable = false; self.releaseReplySession() }
            // While it can still take a reply, a finished session's wings stay up.
            return (true, pending == nil && s?.status == .done && !(s?.canReply ?? false), quiet)
        }
        // Nothing live and nothing waiting: the per-second refresh stops until the next event.
        if quiet, !show { liveTicker?.invalidate(); liveTicker = nil }
        // She hugs her rope and acts out what Claude is doing: working, waiting on you, done.
        switch show ? live.mode : .idle {
        case .running: zera.activity = .running
        case .approval: zera.activity = .approval
        case .done: zera.activity = .done
        default: zera.activity = .none
        }
        if !done {
            liveHideWork?.cancel()
            liveHideWork = nil
            finishedLiveHidden = false
        }
        // Folded away while a card is open (the card carries the same information), while the
        // notch has widened to show the tabs, and after minimizing until an approval or a finished
        // turn needs you (or the Claude tab is opened).
        // Also folded away while she's down with the app opener.
        guard buddyEnabled, show, !cardVisible, !dragging, !pillVisible, !liveDismissed, !finishedLiveHidden, !openerOpen else {
            // Put away for good (minimized, or she is hidden): let a session waiting on a reply
            // finish now. A passing hover, toast or drag keeps the offer, so it is still there
            // when the wings come back.
            if !buddyEnabled || liveDismissed || finishedLiveHidden, !live.composing {
                MainActor.assumeIsolated {
                    for s in ClaudeActivityService.shared.ordered where s.replyUntil != nil && !s.replyHeld {
                        ClaudeActivityService.shared.releaseReply(s)
                    }
                }
            }
            hideLive()
            return
        }
        showLive()
        if done, liveHideWork == nil {
            // Let the green bar be seen, then tidy away.
            let w = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.finishedLiveHidden = true
                self.liveHideWork = nil
                self.hideLive()
            }
            liveHideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
        }
    }

    private func showLive() {
        positionLive()
        positionBubble()
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

    /// The island's window: a fixed transparent canvas hanging from the top of the screen,
    /// centred on her (clamped to the screen). The island itself is centred under her rope.
    private func positionIsland() {
        let scr = geometry.screen.frame
        let w = min(scr.width, Isle.maxWidth + Isle.margin * 2)
        let h = geometry.notchRect.height + Isle.maxContentHeight + Isle.margin
        let rope = buddyPanel.frame.midX
        let x = max(scr.minX, min(scr.maxX - w, rope - w / 2))
        let frame = NSRect(x: x, y: scr.maxY - h, width: w, height: h)
        if cardPanel.frame != frame { cardPanel.setFrame(frame, display: false) }
        island.frame = NSRect(origin: .zero, size: frame.size)
        island.band = geometry.notchRect.height
        island.notchWidth = geometry.notchRect.width
        island.centerX = rope - x
        island.layoutSubtreeIfNeeded()
    }

    /// The island's shape on screen (empty when it is closed).
    private var islandScreenRect: NSRect {
        guard island.mode != .closed, cardPanel.isVisible else { return .zero }
        let r = island.hoverRect, f = cardPanel.frame
        return NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Brings the island's window up with Zera kept above it.
    private func orderIslandFront() {
        if !cardPanel.isVisible { cardPanel.orderFrontRegardless() }
        if buddyPanel.alphaValue > 0.05 { buddyPanel.orderFrontRegardless() }
        if bubblePanel.alphaValue > 0.05 { bubblePanel.orderFrontRegardless() }
    }

    // MARK: - Pointer polling

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        // The motes and the rail's rings follow the clock too (a meeting comes within the hour).
        badgeTimer?.invalidate()
        let b = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refreshBadges() }
        b.tolerance = 5
        RunLoop.main.add(b, forMode: .common)
        badgeTimer = b
        refreshBadges()
    }
    private var badgeTimer: Timer?

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
        // The island's window is a big transparent canvas: only the island takes the pointer.
        if cardPanel.isVisible {
            let p = island.convert(cardPanel.convertPoint(fromScreen: mouse), from: nil)
            cardPanel.ignoresMouseEvents = !island.islandContains(p)
        }
        if cardVisible { evaluateHide(mouse) }
    }

    private func updateLook(_ mouse: NSPoint) {
        let head = headPoint
        // Respond near the face and ease towards a bounded gaze farther away.
        let x = tanh((mouse.x - head.x) / 260)
        let y = tanh((mouse.y - head.y) / 200)
        zera.lookTarget = CGPoint(x: x, y: y)
    }

    private func updateHover(_ mouse: NSPoint, _ now: Date) {
        guard buddyEnabled, buddyPanel.alphaValue > 0.5, !dragging else { return }
        let onHer = NSPointInRect(mouse, figureRect.insetBy(dx: -8, dy: -6))
        let onPill = pillVisible && NSPointInRect(mouse, islandScreenRect.insetBy(dx: -6, dy: -8))
        let bridge = pillVisible && NSPointInRect(mouse, figureRect.union(islandScreenRect).insetBy(dx: 0, dy: -6))

        if onHer != hovering {
            hovering = onHer
            zera.hovered = onHer
            buddy.setRadar(active: onHer)
            if zera.isReactingToPokes { return }
            let nowInterval = CACurrentMediaTime()
            if onHer {
                if nowInterval - lastHoverPokeTime < 1.0 {
                    hoverPokes += 1
                } else {
                    hoverPokes = 1
                }
                lastHoverPokeTime = nowInterval
                if hoverPokes >= 5 {
                    say("dizzy! 😵‍💫", mood: .worried, for: 4.0)
                    hoverPokes = 0
                    return
                }
            }
            if onHer, !asleep, !buddyDragActive, zera.mood != .error, zera.mood != .worried, zera.mood != .excited, !cardVisible {
                if CACurrentMediaTime() - lastHelloSound > 20 { sound(.hello); lastHelloSound = CACurrentMediaTime() }
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

    /// Hovering her: the notch widens to show the tabs (an open island already shows them).
    private func showPill() {
        pillVisible = true
        refreshWaterGlass()
        railVitals(true)
        hideLive()
        refreshBadges()
        guard !cardVisible else { return }
        positionIsland()
        orderIslandFront()
        island.peek()
        positionBubble()
    }

    private func hidePill() {
        pillVisible = false
        refreshWaterGlass()
        pillLeftAt = nil
        if !cardVisible { closeIsland() }
        updateLive()
        positionBubble()
    }

    /// Folds the island back into the notch, then takes its window away.
    private func closeIsland() {
        island.close { [weak self] in
            guard let self = self, !self.cardVisible, !self.pillVisible else { return }
            self.railVitals(false)
            self.cardPanel.orderOut(nil)
        }
    }

    /// Amber dots on the tabs: unseen GitHub activity, Claude Code requests, reminder alerts.
    private func refreshBadges() {
        island.badges = MainActor.assumeIsolated { () -> Set<CardKind> in
            var b: Set<CardKind> = []
            if !GitHubService.shared.unseen.isEmpty { b.formUnion([.home, .github]) }
            if !ClaudeHookService.shared.pending.isEmpty { b.formUnion([.home, .claude]) }
            if ClaudeActivityService.shared.active.contains(where: { $0.status == .waiting }) { b.insert(.claude) }
            if !ReminderService.shared.pendingAlerts.isEmpty { b.formUnion([.home, .reminders]) }
            return b
        }
        // How many Claude sessions are running: with the wings minimized, this is where you see them.
        island.counts[.claude] = MainActor.assumeIsolated { ClaudeActivityService.shared.active.count }
        island.counts[.shelf] = ShelfStore.shared.items.count
        island.counts[.github] = MainActor.assumeIsolated { GitHubService.shared.pulls.filter { $0.reviewRequested }.count }
        island.instruments = MainActor.assumeIsolated { Self.railInstruments() }
        zera.motes = MainActor.assumeIsolated { Self.motes() }
    }

    /// What needs you, as motes round her: one per kind.
    @MainActor
    private static func motes(now: Date = Date()) -> [NSColor] {
        var out: [NSColor] = []
        if !ClaudeHookService.shared.pending.isEmpty || ClaudeActivityService.shared.active.contains(where: { $0.status == .waiting }) {
            out.append(Neon.warning)
        }
        if GitHubService.shared.pulls.contains(where: { $0.reviewRequested }) || !GitHubService.shared.unseen.isEmpty { out.append(Neon.violet) }
        if ReminderService.shared.nextEvent(within: 3600, now: now) != nil || !ReminderService.shared.pendingAlerts.isEmpty {
            out.append(Neon.cyan.blended(withFraction: 0.5, of: NSColor.systemBlue) ?? Neon.cyan)
        }
        if let b = SystemVitals.readBattery(), b.percent <= 20, !b.charging, !b.onPower { out.append(Neon.red) }
        return out
    }

    /// The nodes' live rings (v2): CPU with the battery inside on Home, the running session's
    /// progress on Claude, today's tasks done, minutes to the next event within the hour.
    @MainActor
    private static func railInstruments(now: Date = Date()) -> [CardKind: IslandInstrument] {
        var out: [CardKind: IslandInstrument] = [:]
        let v = SystemVitals.shared.now
        if v.cpu > 0 || v.battery != nil {
            out[.home] = IslandInstrument(progress: CGFloat(v.cpu), text: v.battery.map { "\($0.percent)" },
                                          tone: (v.battery?.percent ?? 100) <= 20 && !(v.battery?.charging ?? false) ? Neon.red : nil)
        }
        if let s = ClaudeActivityService.shared.active.first {
            out[.claude] = IslandInstrument(progress: CGFloat(s.progress), text: nil, tone: s.status == .waiting ? Neon.warning : nil)
        }
        let tasks = TaskStore.shared.today
        if !tasks.isEmpty {
            out[.tasks] = IslandInstrument(progress: CGFloat(TaskStore.shared.doneToday.count) / CGFloat(tasks.count), text: nil, tone: Neon.green)
        }
        if let next = ReminderService.shared.nextEvent(within: 3600, now: now) {
            let m = max(1, Int(ceil(next.start.timeIntervalSince(now) / 60)))
            out[.reminders] = IslandInstrument(progress: 1 - CGFloat(m) / 60, text: "\(m)m", tone: m <= 15 ? Neon.warning : nil)
        }
        return out
    }

    /// The rail's Home ring reads the CPU: sample while the island is out.
    private var railWatchesVitals = false
    private func railVitals(_ on: Bool) {
        guard on != railWatchesVitals else { return }
        railWatchesVitals = on
        if on { SystemVitals.shared.watch() } else { SystemVitals.shared.unwatch() }
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
        sound(.wake)
        if firstTime && !UserDefaults.standard.bool(forKey: Self.greetedKey) {
            UserDefaults.standard.set(true, forKey: Self.greetedKey)
            say("Hi! 👋 I'm Zera!", mood: .hello, for: 3.5)
        } else {
            say(greetingForNow(), mood: .hello, for: 3.0)
        }
    }

    /// The line she's saying right now, wherever it shows.
    private var captionLine: String?
    private var captionTone: NSColor = Neon.cyan

    /// A line from her: under her feet, or in the open island's header. Lines that would repeat
    /// what the wings, a banner or the approval screen already show go through `react` instead.
    func say(_ line: String, mood: ZeraMood? = nil, for seconds: TimeInterval = 2.5) {
        sayResetWork?.cancel()
        if let m = mood { zera.mood = m }
        let changed = line != captionLine
        captionLine = line
        captionTone = Self.tone(for: mood ?? zera.mood)
        routeCaption()
        if changed {
            zera.nudge()
            if buddyEnabled { SoundService.shared.playIfQuiet(.caption) }
        }
        guard seconds > 0 else { return }
        // Long lines get time to be read: about 40 ms a character, up to six seconds.
        let hold = max(seconds, min(6, 1.4 + Double(line.count) * 0.04))
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        sayResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    // MARK: - Clipboard

    private var clipboardHotKey: GlobalHotKey?

    /// A recorded shortcut kept in defaults under `key`: the default until you record another,
    /// nil once you turn it off.
    static func storedShortcut(_ key: String, default d: HotKeyShortcut) -> HotKeyShortcut? {
        let u = UserDefaults.standard
        if u.bool(forKey: key + "Off") { return nil }
        return u.data(forKey: key).flatMap { try? JSONDecoder().decode(HotKeyShortcut.self, from: $0) } ?? d
    }
    static func store(_ s: HotKeyShortcut?, _ key: String) {
        let u = UserDefaults.standard
        u.set(s == nil, forKey: key + "Off")
        if let s = s, let data = try? JSONEncoder().encode(s) { u.set(data, forKey: key) }
    }

    /// The shortcut that opens Clipboard from any app (⇧⌘V unless you recorded another); nil is off.
    var clipboardShortcut: HotKeyShortcut? {
        get { Self.storedShortcut("clipboard.shortcut", default: .default) }
        set { Self.store(newValue, "clipboard.shortcut") }
    }

    // MARK: - Tasks

    /// The menu bar list, the focus orb, quick add and export.
    let tasks = TasksController()

    // MARK: - App opener

    private let opener = AppOpener()
    /// The opener is down: the wings and the hanging Zera step aside until it's gone.
    private var openerOpen = false
    private var openerHotKey: GlobalHotKey?

    /// ⌥Space unless you recorded another; nil is off.
    var openerShortcut: HotKeyShortcut? {
        get { Self.storedShortcut("appOpener.shortcut", default: AppOpenerSettings.defaultShortcut) }
        set { Self.store(newValue, "appOpener.shortcut") }
    }

    /// Registers the opener's shortcut (when the opener is on). False if macOS refused it.
    @discardableResult
    func registerOpenerHotKey() -> Bool {
        openerHotKey = nil
        guard AppOpenerSettings.enabled, let s = openerShortcut else { return true }
        openerHotKey = GlobalHotKey(s) { [weak self] in self?.toggleOpener() }
        return openerHotKey != nil
    }

    private func setOpenerShortcut(_ s: HotKeyShortcut?) -> Bool {
        let old = openerShortcut
        openerShortcut = s
        if registerOpenerHotKey() { return true }
        openerShortcut = old
        registerOpenerHotKey()
        return false
    }

    func toggleOpener() {
        if cardVisible { hideCard() }
        opener.toggle(notch: geometry.notchRect, screen: geometry.screen.frame)
    }

    /// While she's down with the opener, the hanging Zera steps aside (there's only one of her).
    private func setUpOpener() {
        opener.onOpenChanged = { [weak self] open in
            guard let self = self else { return }
            self.openerOpen = open
            guard self.buddyEnabled else { self.updateLive(); return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(open ? 0.12 : 0.25)
                self.buddyPanel.animator().alphaValue = open ? 0 : 1
                if open { self.bubblePanel.animator().alphaValue = 0 }
            }
            if !open { self.updateLive() } else { self.hideLive() }
        }
        opener.onLaunched = { [weak self] app in
            self?.say("opening \(app.name) ✨", mood: .happy, for: 2)
        }
        opener.onNotice = { [weak self] line in self?.say(line, mood: .happy, for: 2.6) }
        registerOpenerHotKey()
        // Load the app list now, in the background, so the first ⌥Space is instant.
        AppCatalog.shared.refreshIfNeeded()
    }

    /// Registers the clipboard shortcut. Returns false if macOS refused it (another app owns it).
    @discardableResult
    func registerClipboardHotKey() -> Bool {
        clipboardHotKey = nil
        guard let s = clipboardShortcut else { return true }
        clipboardHotKey = GlobalHotKey(s) { [weak self] in
            guard let self = self else { return }
            if self.cardVisible, self.currentCard == .clipboard { self.dismissCardByUser() }
            else { self.suppressUntil = .distantPast; self.show(.clipboard) }
        }
        return clipboardHotKey != nil
    }

    /// From the recorder in Settings: try the new shortcut, keep the old one if it can't be used.
    private func setClipboardShortcut(_ s: HotKeyShortcut?) -> Bool {
        let old = clipboardShortcut
        clipboardShortcut = s
        if registerClipboardHotKey() { return true }
        clipboardShortcut = old
        registerClipboardHotKey()
        return false
    }

    /// Something went back on the clipboard: she says so, and the island folds away so ⌘V can
    /// paste it into the app underneath (unless you chose to keep it open).
    private func clipboardCopied() {
        say("copied ✨ press ⌘V to paste", mood: .happy, for: 2.4)
        guard ClipboardStore.shared.foldAfterCopy else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self = self, self.cardVisible, self.currentCard == .clipboard else { return }
            self.hideCard()
        }
    }

    private func sound(_ s: ZeraSound) {
        guard buddyEnabled else { return }
        SoundService.shared.play(s)
    }

    /// Her face and pose only, for news the screen already shows.
    func react(_ mood: ZeraMood, for seconds: TimeInterval = 2.5) {
        sayResetWork?.cancel()
        captionLine = nil
        routeCaption()
        zera.mood = mood
        guard seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        sayResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func settle() {
        sayResetWork?.cancel()
        zera.mood = asleep ? .sleepy : .idle
        captionLine = nil
        routeCaption()
    }

    static func tone(for mood: ZeraMood) -> NSColor {
        switch mood {
        case .happy, .celebrate, .excited, .love, .approved, .giving: return Neon.green
        case .thinking, .focused: return Neon.warning
        case .error, .worried, .sad: return Neon.red
        default: return Neon.cyan
        }
    }

    /// Banners and the approval screen are about one thing; she keeps quiet over them.
    private var islandTakesCaption: Bool {
        cardVisible && !isNotificationBanner && currentCard != .approval
    }

    /// Puts the current line where it belongs: the island header while a screen is open,
    /// otherwise the speech capsule beside her.
    private func routeCaption() {
        guard let line = captionLine, buddyEnabled else {
            hideBubble()
            island.whisper(nil)
            return
        }
        if cardVisible {
            hideBubble()
            island.whisper(islandTakesCaption ? line : nil, tone: captionTone)
        } else {
            island.whisper(nil)
            bubble.text = line
            bubble.tone = captionTone
            positionBubble()
            showBubble()
        }
    }

    private func showBubble() {
        guard buddyEnabled else { return }
        if bubblePanel.alphaValue < 0.05 || !bubblePanel.isVisible {
            // Ease the capsule into place beside her.
            let target = bubblePanel.frame
            bubblePanel.setFrame(target.offsetBy(dx: 0, dy: 8), display: false)
            bubblePanel.alphaValue = 0
            bubblePanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(0.34)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bubblePanel.animator().alphaValue = 1
                bubblePanel.animator().setFrame(target, display: true)
            }
        } else {
            bubblePanel.orderFrontRegardless()
        }
    }

    private func hideBubble() {
        guard bubblePanel.isVisible, bubblePanel.alphaValue > 0.01 else { return }
        let target = bubblePanel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(0.16)
            bubblePanel.animator().alphaValue = 0
            bubblePanel.animator().setFrame(target.offsetBy(dx: 0, dy: 4), display: true)
        }, completionHandler: { [weak self] in
            guard let self = self, self.bubblePanel.alphaValue < 0.05 else { return }
            self.bubblePanel.orderOut(nil)
        })
    }

    private func fallAsleep() { asleep = true; settle() }
    private func wake() { asleep = false; sound(.wake); say("oh! hi again 👋", mood: .hello, for: 2.0) }

    // MARK: - Events from services

    @objc private func githubChanged() { refreshBadges() }
    @objc private func vitalsChanged() { if pillVisible || cardVisible { refreshBadges() } }

    @objc private func githubNews(_ note: Notification) {
        guard let fresh = note.userInfo?["events"] as? [GHEvent], let top = fresh.first else { return }
        // A sound only when the toast will show it (not over approvals or reminder alerts).
        if !(cardVisible && (currentCard == .approval || currentCard == .reminderAlert)) {
            switch top.kind {
            case .ciFailed: sound(.ciFailed)
            case .ciPassed, .prApproved: sound(.ciPassed)
            default: sound(.githubPing)
            }
        }
        // The toast (or the pull request screen) shows the news; she only reacts to it.
        switch top.kind {
        case .prOpened: react(top.mine ? .celebrate : .surprised, for: 6)
        case .prApproved, .ciPassed: react(.celebrate, for: 6)
        case .prChangesRequested, .reviewRequested, .needsApproval: react(.thinking, for: 6)
        case .prCommented: react(.hello, for: 4)
        case .ciFailed: react(.worried, for: 6)
        case .ciRunning: react(.focused, for: 4)
        }
        if cardVisible, currentCard == .github { (cards[.github] as? GitHubCard)?.reload(); return }
        // A toast, unless something more important is on screen.
        if cardVisible, currentCard == .approval || currentCard == .reminderAlert { return }
        pendingToast = top
        show(.toast)
    }

    @objc private func hookRequest(_ note: Notification) {
        guard note.userInfo?["request"] is HookRequest else { return }
        sound(.claudeApproval)
        // An approval brings minimized wings back; they stay up until the next minimize.
        liveDismissed = false
        finishedLiveHidden = false
        if cardVisible && currentCard == .approval {
            react(.thinking, for: 0)
            (cards[.approval] as? ApprovalCard)?.reload()
            return
        }
        // The wing (or the approval screen) shows the command; she just perks up.
        react(.thinking, for: 0)
        // Approve / Reject right on the wing when it can show it; otherwise the approval card.
        if liveCanApprove {
            if pillVisible { hidePill() } else { updateLive() }
        } else {
            show(.approval)
        }
    }

    @objc private func hookChanged() {
        refreshBadges()
        ensureLiveTicker()
        updateLive()
        if cardVisible, currentCard == .approval { (cards[.approval] as? ApprovalCard)?.reload() }
    }

    private var approvalPending: Bool { MainActor.assumeIsolated { !ClaudeHookService.shared.pending.isEmpty } }

    /// Keeps the wings' clock and reply countdown moving while something is live; `updateLive`
    /// stops it again once nothing is.
    private var liveTicker: Timer?
    private func ensureLiveTicker() {
        guard liveTicker == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateLive() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        liveTicker = t
    }

    @objc private func activityChanged() {
        refreshBadges()
        ensureLiveTicker()
        updateLive()
        if cardVisible, currentCard == .claude { (cards[.claude] as? ClaudeSessionsView)?.reload() }
    }

    /// Prompt sent / Claude waiting / task finished: a word from her, and her face follows.
    @objc private func activityMilestone(_ note: Notification) {
        guard let event = note.userInfo?["event"] as? String, let s = note.userInfo?["session"] as? ClaudeSession else { return }
        let title = s.title.isEmpty ? "that" : "“\(ClaudeActivityService.oneLine(s.title, max: 40))”"
        switch event {
        case "prompt": sound(.claudeStart)
        case "waiting": if !approvalPending { sound(.claudeApproval) }
        case "done": sound(.claudeDone)
        default: break
        }
        // The wings already show each of these, as does the Claude screen.
        if liveVisible || (cardVisible && currentCard == .claude) {
            switch event {
            case "prompt": react(.focused, for: 3)
            case "waiting": if !approvalPending { react(.thinking, for: 6) }
            case "done": react(.celebrate, for: 5)
            default: break
            }
            return
        }
        switch event {
        case "prompt": say("on it — Claude's working on \(title) 👩‍💻", mood: .focused, for: 3)
        case "waiting": if !approvalPending { say("Claude needs you in \(s.folderName) 🙋", mood: .thinking, for: 6) }
        case "done": say("Claude finished \(title) 🎉", mood: .celebrate, for: 5)
        default: break
        }
    }
    @objc private func reminderFired(_ note: Notification) {
        guard let a = note.userInfo?["alert"] as? ReminderAlert else { return }
        if a.hydration {
            showWaterVisit()
            return
        }
        let mood: ZeraMood
        switch a.kind {
        case .breakTime: mood = .cozy
        case .battery: mood = .worried
        case .calendarHeadsUp, .headsUp: mood = .hello
        case .calendarNow, .now, .snoozed: mood = .excited
        }
        if a.hydration { sound(.water) }
        else if a.kind == .battery { sound(.batteryLow) }
        else if a.kind == .breakTime { sound(.breakTime) }
        else if a.isEvent { sound(.calendar) }
        else { sound(.reminder) }
        react(mood, for: 6)   // the reminder banner shows the headline
        if cardVisible, currentCard == .approval, approvalPending { return }
        if !(cardVisible && currentCard == .reminderAlert) { show(.reminderAlert) }
        else { (cards[.reminderAlert] as? ReminderAlertCard)?.reload() }
    }

    /// Splash: a glass pops up beside the pointer and Zera jumps from the notch into it.
    /// Today's glasses against the day's goal.
    private var waterToday: (count: Int, goal: Int) {
        MainActor.assumeIsolated {
            let svc = ReminderService.shared, now = Date()
            return (WaterStats.glasses(on: now, in: svc.completions), WaterStats.goal(on: now, reminders: svc.reminders))
        }
    }

    /// The glass under the notch: not always there. It shows for a few seconds after a sip, so you
    /// see it fill, and while a water reminder waits as the bead; hovering it keeps it up.
    private func refreshWaterGlass() {
        let moment = Date() < waterGlassUntil || (waterVisit?.isBeadShowing ?? false) || waterCounter.hovered
        let show = moment && buddyEnabled && !cardVisible && !pillVisible && !(waterVisit?.isActive ?? false)
        guard show else { waterCounterPanel.orderOut(nil); return }
        let today = waterToday
        waterCounter.count = today.count; waterCounter.goal = today.goal
        if waterCounterPanel.contentView !== waterCounter {
            waterCounterPanel.hasShadow = false
            waterCounterPanel.contentView = waterCounter
            waterCounter.onClick = { [weak self] in self?.toggleWaterWeek() }
            waterCounter.onHover = { [weak self] inside in if !inside { self?.refreshWaterGlass() } }
        }
        let n = geometry.notchRect, s = WaterGlassCounterView.size
        waterCounterPanel.setFrameOrigin(CGPoint(x: n.maxX - s.width - 12, y: n.minY - s.height - 4))
        if !waterCounterPanel.isVisible { waterCounterPanel.orderFrontRegardless() }
    }

    /// Shows the glass for `seconds`, then tucks it away again.
    private func flashWaterGlass(for seconds: TimeInterval = 6) {
        waterGlassUntil = Date().addingTimeInterval(seconds)
        refreshWaterGlass()
        waterGlassTimer?.invalidate()
        waterGlassTimer = Timer.scheduledTimer(withTimeInterval: seconds + 0.05, repeats: false) { [weak self] _ in self?.refreshWaterGlass() }
    }

    /// Menu bar › Water this week…
    func showWaterWeek() { if !waterWeek.isVisible { toggleWaterWeek() } }

    private func toggleWaterWeek() {
        if waterWeek.isVisible { waterWeek.close(); return }
        let (week, goal, streak) = MainActor.assumeIsolated { () -> ([WaterStats.Day], Int, Int) in
            let svc = ReminderService.shared, now = Date()
            return (WaterStats.week(ending: now, in: svc.completions), WaterStats.goal(on: now, reminders: svc.reminders),
                    WaterStats.streak(ending: now, in: svc.completions))
        }
        waterWeek.onSaved = { [weak self] _ in self?.say("saved to Downloads 💧", mood: .happy, for: 2.4) }
        waterWeek.show(week: week, goal: goal, streak: streak, below: geometry.notchRect)
    }

    /// After a sip on a Friday (or the day a 7-day streak lands), mention the weekly card once.
    private func offerWaterWeekIfDue() {
        let key = "water.cardOfferedWeek", now = Date()
        let streak = MainActor.assumeIsolated { WaterStats.streak(ending: now, in: ReminderService.shared.completions) }
        guard WaterStats.shouldOfferCard(now: now, streak: streak, offeredWeek: UserDefaults.standard.string(forKey: key)) else { return }
        UserDefaults.standard.set(WaterStats.weekKey(now), forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.say("your water week is ready ✨ click the glass by the notch", mood: .happy, for: 4)
        }
    }

    private func showWaterVisit() {
        if waterVisit == nil {
            let visit = WaterReminderVisit()
            visit.onDrank = { [weak self] in
                // A newer occurrence can replace one already visiting; complete every waiting
                // water nudge together, without a second Zera.
                MainActor.assumeIsolated {
                    for alert in ReminderService.shared.pendingAlerts.filter(\.hydration) {
                        ReminderService.shared.complete(alert)
                    }
                }
                self?.offerWaterWeekIfDue()
            }
            visit.onLater = {
                MainActor.assumeIsolated {
                    for alert in ReminderService.shared.pendingAlerts.filter(\.hydration) {
                        ReminderService.shared.snooze(alert, minutes: 10)
                    }
                }
            }
            visit.onReturn = { [weak self] outcome in
                guard let self else { return }
                // Left alone: she's back on her rope and a bead under the notch keeps the reminder.
                if outcome == .ignored, MainActor.assumeIsolated({ ReminderService.shared.pendingAlerts.contains(where: \.hydration) }) {
                    self.waterVisit?.showBead(below: self.geometry.notchRect)
                }
                self.setBuddy(visible: self.buddyEnabled, animated: false)
                // After a sip the glass shows for a moment so you see it fill.
                if outcome == .drank { self.flashWaterGlass() }
                self.settle()
            }
            visit.onBead = { [weak self] in self?.showWaterVisit() }
            waterVisit = visit
        }
        guard waterVisit?.isActive != true else { return }
        // Zera is tucked away (full screen, or turned off): just the bead under the notch.
        guard buddyEnabled else { waterVisit?.showBead(below: geometry.notchRect); return }
        sound(.water); hideBubble()
        let today = waterToday
        waterVisit?.show(from: headPoint, detail: WaterStats.todayLine(count: today.count, goal: today.goal))
        // She leaves her rope for the jump; the notch Zera hides until she's back.
        setBuddy(visible: false, animated: false)
    }

    @objc private func remindersChanged() {
        if MainActor.assumeIsolated({ !ReminderService.shared.pendingAlerts.contains(where: \.hydration) }) {
            if waterVisit?.isActive == true, waterVisit?.view.motion.stage == .waiting { waterVisit?.drank() }
            waterVisit?.hideBead()
        }
        refreshWaterGlass()
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
        live.themeChanged()
        island.themeChanged()
        buddy.needsDisplay = true
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
                say("new note on the shelf 📝", mood: .happy, for: 2)
            }
        case .takeBreak:
            MainActor.assumeIsolated { ReminderService.shared.triggerBreakNow() }
        case .screenshot:
            hideCard()
            // Interactive capture to the clipboard, then onto the shelf.
            DispatchQueue.global().async { [weak self] in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-i", "-c"]
                try? p.run()
                p.waitUntilExit()
                DispatchQueue.main.async {
                    let n = ShelfStore.shared.ingest(pasteboard: .general)
                    if n > 0 {
                        self?.sound(.screenshot)
                        self?.show(.shelf)
                        self?.say("screenshot's on the shelf 📸", mood: .happy, for: 2)
                    }
                }
            }
        case .startTimer:
            // A 25-minute focus timer: a one-off reminder Zera will announce.
            let due = Date().addingTimeInterval(25 * 60)
            MainActor.assumeIsolated {
                ReminderService.shared.addOneOff(title: "Timer's up — 25 min focus done", at: due)
            }
            sound(.timerSet)
            say("timer set — I'll tell you at \(ReminderService.timeFormatter.string(from: due)) ⏱", mood: .focused, for: 3)
            hideCard()
        case .clipboard:
            show(.clipboard)
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
            let s = SettingsCard(defaultKind: defaultCard, showingZera: buddySetting,
                                 loginEnabled: SMAppService.mainApp.status == .enabled)
            s.onDefaultChanged = { [weak self] k in self?.defaultCard = k }
            s.onHoverMenuChanged = { [weak self] style in self?.island.hoverStyle = style }
            s.onShowZeraChanged = { [weak self] on in self?.setBuddyEnabled(on) }
            s.onFullScreenHideChanged = { [weak self] in self?.fullScreenChanged() }
            s.clipboardShortcut = clipboardShortcut
            s.onClipboardShortcutChanged = { [weak self] c in self?.setClipboardShortcut(c) ?? false }
            // While you record, the current shortcut is paused so pressing it gets recorded.
            s.onClipboardShortcutRecording = { [weak self] on in
                if on { self?.clipboardHotKey = nil } else { self?.registerClipboardHotKey() }
            }
            s.openerShortcut = openerShortcut
            s.onOpenerShortcutChanged = { [weak self] c in self?.setOpenerShortcut(c) ?? false }
            s.onOpenerShortcutRecording = { [weak self] on in
                if on { self?.openerHotKey = nil } else { self?.registerOpenerHotKey() }
            }
            s.onOpenerEnabledChanged = { [weak self] _ in self?.registerOpenerHotKey() }
            s.tasksShortcut = tasks.shortcut
            s.onTasksShortcutChanged = { [weak self] c in self?.tasks.setShortcut(c) ?? false }
            s.onTasksShortcutRecording = { [weak self] on in self?.tasks.pauseHotKey(on) }
            s.onTasksSettingsChanged = { [weak self] in self?.tasks.applySettings() }
            s.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 3) }
            c = s
        case .tasks:
            let t = TasksCard(store: tasks.store)
            t.shortcutLabel = tasks.shortcut?.label
            t.orbShown = TasksSettings.orb
            t.onToggleOrb = { [weak self, weak t] in
                self?.tasks.toggleOrbSetting()
                t?.orbShown = TasksSettings.orb
            }
            t.onExport = { [weak self] in
                self?.dismissCardByUser()
                self?.tasks.openExport()
            }
            t.onLinkFolder = { [weak self] p in
                self?.dismissCardByUser()
                self?.tasks.linkFolder(for: p)
            }
            t.onSync = { [weak self] p in self?.tasks.syncCommits(project: p, quiet: p == nil) }
            t.onRebuild = { [weak self] p, days in self?.tasks.rebuildFromCommits(p, days: days) }
            t.onAdded = { [weak self] task, focus in
                self?.sound(.tap)
                if focus { self?.say("focusing on “\(task.title)” ✨", mood: .happy, for: 2.4) }
            }
            c = t
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
            r.onAlertChange = { [weak self] in
                guard let self = self, self.cardVisible, self.currentCard == .reminderAlert else { return }
                self.startBannerCountdown()
            }
            r.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 2.5) }
            r.onDrained = { [weak self] in
                guard let self = self, self.cardVisible, self.currentCard == .reminderAlert else { return }
                self.hideCard(); self.settle()
            }
            r.onView = { [weak self] a in
                guard let self = self else { return }
                // Open the screen straight on that reminder's (or event's) details.
                let ref = a.reminderID?.uuidString ?? a.eventID
                (self.content(for: .reminders) as? RemindersView)?.focusOnShow = ref.map { (refID: $0, occurrence: a.occurrence) }
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
        case .clipboard:
            let v = ClipboardView()
            v.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 2.5) }
            v.onCopied = { [weak self] _ in self?.clipboardCopied() }
            v.onOpenSettings = { [weak self] in
                self?.show(.settings)
                (self?.cards[.settings] as? SettingsCard)?.select(.clipboard)
            }
            c = v
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

    func toggleDefaultCard() { cardVisible ? dismissCardByUser() : show(defaultCard ?? .shelf) }

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

        let swapping = currentCard != kind
        let previous = cardVisible ? currentCard : nil
        if !cardVisible { sound(.islandOpen) } else if swapping { sound(.tab) }
        if kind == .claude {
            // Going through the Claude tab is how minimized wings come back (once the island closes).
            liveDismissed = false
            finishedLiveHidden = false
        }
        if swapping {
            let c = content(for: kind)
            c.onHeightChange = { [weak self] in self?.cardHeightChanged() }
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
            // The screen shows the counts; her face follows them.
            if swapping, connected { react(reviews > 0 ? .thinking : (open > 0 ? .hello : .happy), for: 2.5) }
        case .home: (cards[.home] as? HomeCard)?.willShow()
        case .approval: (cards[.approval] as? ApprovalCard)?.reload()
        case .reminders: (cards[.reminders] as? RemindersView)?.willShow()
        case .reminderAlert: (cards[.reminderAlert] as? ReminderAlertCard)?.reload()
        case .toast: if let e = pendingToast { (cards[.toast] as? ToastCard)?.show(event: e) }
        case .result: (cards[.result] as? ResultCard)?.reload()
        case .claude:
            (cards[.claude] as? ClaudeSessionsView)?.willShow(expanded: claudeOpenExpanded)
            claudeOpenExpanded = false
        case .settings: break
        case .clipboard: (cards[.clipboard] as? ClipboardView)?.willShow()
        case .tasks:
            let t = cards[.tasks] as? TasksCard
            t?.orbShown = TasksSettings.orb
            t?.willShow()
        }

        if !cardVisible { islandVisited = false }
        cardVisible = true
        refreshWaterGlass()
        railVitals(true)
        refreshBadges()
        hideLive()   // the island takes the space; the readout comes back when it closes
        positionIsland()
        orderIslandFront()
        // Screens to the right of the open one slide in from the right, and the other way round.
        let order = Isle.leftTabs + Isle.rightTabs
        var direction: CGFloat = 0
        if let prev = previous, swapping,
           let i = order.firstIndex(of: Isle.tab(for: prev)), let j = order.firstIndex(of: Isle.tab(for: kind)) {
            direction = j == i ? 1 : (j > i ? 1 : -1)
        }
        presentCurrent(direction: direction, animated: !instant)
        island.activeTab = Isle.tab(for: kind)
        zera.islandPose = Isle.pose(for: kind)
        routeCaption()
        if isNotificationBanner { startBannerCountdown() }
        else { bannerCountdown = nil }
        if kind == .approval { cardPanel.makeKey() }
        if kind == .tasks, let t = cards[.tasks] as? TasksCard {
            // Type a task straight away (the panel doesn't take focus from your app).
            cardPanel.makeKey()
            cardPanel.makeFirstResponder(t.field)
        }
        if kind == .clipboard {
            // Arrow keys, ⏎ and ⌘1–⌘9 work straight away. The panel doesn't activate Zera, so the
            // app you came from is still the one ⌘V pastes into once the island folds away.
            cardPanel.makeKey()
            cardPanel.makeFirstResponder(currentContent)
        }
    }

    /// Sizes the current screen for the island (compact: capped width and height) and shows it.
    private func presentCurrent(direction: CGFloat, animated: Bool) {
        guard let c = currentContent else { return }
        let w = min(c.cardWidth, Isle.maxWidth, geometry.screen.frame.width - 24)
        c.setFrameSize(NSSize(width: w, height: max(c.frame.height, 100)))
        isPresenting = true
        c.needsLayout = true
        c.layoutSubtreeIfNeeded()
        isPresenting = false
        let h = min(c.desiredHeight, Isle.maxContentHeight, geometry.screen.visibleFrame.height - 40)
        island.present(c, size: NSSize(width: w, height: h), direction: direction, animated: animated)
    }

    func hideCard() {
        guard cardVisible else { return }
        sound(.islandClose)
        MainActor.assumeIsolated { ZeraDropdown.shared.dismiss() }
        cardVisible = false
        refreshWaterGlass()
        bannerCountdown = nil
        outsideSince = nil
        externalDragOver = false
        autoHideWork?.cancel()
        zera.islandPose = nil
        cardPanel.ignoresMouseEvents = true
        if pillVisible {
            island.close(animated: false)
            island.peek()
        } else {
            closeIsland()
        }
        routeCaption()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, !self.cardVisible else { return }
            self.updateLive()
        }
    }

    private func evaluateHide(_ mouse: NSPoint) {
        if isNotificationBanner {
            guard var countdown = bannerCountdown else { startBannerCountdown(); return }
            let interacting = NSPointInRect(mouse, islandScreenRect)
                || MainActor.assumeIsolated { ZeraDropdown.shared.isOpen }
            countdown.advance(to: CACurrentMediaTime(), paused: interacting)
            bannerCountdown = countdown
            (currentContent as? TimedNotificationBanner)?.countdownLine.progress = countdown.progress
            if countdown.expired { hideCard(); settle() }
            return
        }
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
        if currentCard == .result, MainActor.assumeIsolated({ ZeraAssistant.shared.isBusy }) {
            outsideSince = nil   // she is still working on it; do not pull the answer away
            return
        }
        let grace: TimeInterval = currentCard == .result ? 4 : leaveGrace
        let zone = islandScreenRect.insetBy(dx: -hoverPadding, dy: -hoverPadding)
            .union(figureRect.insetBy(dx: -10, dy: -10))
        if NSPointInRect(mouse, zone) {
            islandVisited = true
            outsideSince = nil
        } else if !islandVisited {
            // Not reached yet (banners still fold away on their own).
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) >= grace { hideCard() }
        } else {
            outsideSince = Date()
        }
    }

    private var isNotificationBanner: Bool {
        cardVisible && (currentCard == .toast || currentCard == .reminderAlert)
    }

    private func startBannerCountdown() {
        bannerCountdown = BannerCountdown(at: CACurrentMediaTime())
        (currentContent as? TimedNotificationBanner)?.countdownLine.progress = 1
    }

    @objc private func storeChanged() {
        if cardVisible { cardHeightChanged() }
    }

    private func cardHeightChanged() {
        guard cardVisible, !isPresenting else { return }
        presentCurrent(direction: 0, animated: true)
        positionBubble()
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
            let zone = self.islandScreenRect.insetBy(dx: -14, dy: -14).union(self.figureRect)
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

    func shelfDragOutBegan() { isDraggingOut = true; sound(.fileDragOut) }
    func shelfDragOutEnded() { isDraggingOut = false; outsideSince = Date() }
    func shelfRequestsHide() { suppressUntil = Date().addingTimeInterval(0.8); hideCard() }
    func shelfHeightChanged() { cardHeightChanged() }
    func shelfSays(_ line: String, mood: ZeraMood, for seconds: TimeInterval) { say(line, mood: mood, for: seconds) }
    func shelfSettles() { settle() }

    // MARK: - External entry points

    func add(urls: [URL]) {
        let n = ShelfStore.shared.add(urls: urls)
        if n > 0 {
            if !(cardVisible && currentCard == .shelf) { show(.shelf) }
            say(n == 1 ? "got it! ✨" : "got all \(n)! ✨", mood: .happy, for: 1.6)
            shelfDidAcceptDrop()
        }
    }
}
