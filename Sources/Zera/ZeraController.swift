import AppKit
import AVFoundation
import ServiceManagement

/// Owns everything on screen: Zera dangling from the notch, her speech bubble, the live wings,
/// and the notch island every screen opens in. Polls the pointer so she can watch it,
/// greet you when you come close, and doze off when you have been away for a while.
final class ZeraController: NSObject {

    // MARK: Windows & views

    private var geometry = NotchGeometry.detect()
    private let buddyPanel: FloatingPanel
    private let buddy = BuddyView()
    /// Zera in the notch (the default style): her face in a black ear of the notch.
    private let notchBuddyPanel: FloatingPanel
    private let notchBuddy = NotchBuddyView()
    private var notchStyle: Bool { BuddyStyle.current == .notch }
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
    private var eventMonitors: [Any] = []
    private var notificationObservers: [NSObjectProtocol] = []
    /// Minimize keeps the readout hidden until something needs you (an approval, or a finished
    /// turn you can reply to) or you open the Claude tab; then it stays up until the next minimize.
    private var liveDismissed = false
    /// The finished turn ("session id|prompt time") that last brought minimized wings back, so
    /// minimizing again keeps that same turn tucked away.
    private var surfacedFinish: String?
    /// A finished session has already had its five seconds on screen.
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
    private var pillVisible = false { didSet { if pillVisible != oldValue { syncNotchBuddy(animated: true) } } }
    private var navigationPinned = false
    private var navigationPinOrigin: NSPoint?
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
    private(set) var cardVisible = false {
        // In the notch, her ear steps aside while a screen is open (the rail sits there).
        didSet { if cardVisible != oldValue { syncNotchBuddy(animated: true) } }
    }
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
        notchBuddyPanel = FloatingPanel.make(size: NSSize(width: 48, height: 32), level: level(2), keyable: false)
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
                guard let defaultCard = NotchNavigation.shared.destination(fallback: self.defaultCard) else { return }
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

        tasks.onOpenExport = { [weak self] in self?.show(.taskExport) }
        island.onClose = { [weak self] in self?.dismissCardByUser() }
        island.onSettings = { [weak self] in
            guard let self = self else { return }
            self.suppressUntil = .distantPast
            self.show(.settings)
        }
        // The notch light answers what you do on the Mac: ⌘C sweeps, volume draws an arc…
        MainActor.assumeIsolated {
            CommandEcho.shared.onReaction = { [weak self] r, tint in
                self?.reactLight(r, tint: tint)
                self?.echoMood(for: r)
            }
        }
        island.onSearch = { [weak self] in
            self?.suppressUntil = .distantPast
            self?.show(.arrange)
        }
        island.deck.onOpen = { [weak self] kind in
            guard let self = self else { return }
            self.suppressUntil = .distantPast
            self.show(kind)
        }
        island.onTab = { [weak self] kind in
            guard let self = self else { return }
            self.suppressUntil = .distantPast
            // The open screen's tab puts the island away; any other tab switches to it.
            if self.cardVisible, self.currentCard == kind { self.dismissCardByUser() } else { self.show(kind) }
        }

        live.companion.source = buddy.zera
        livePanel.contentView = live
        livePanel.hasShadow = false         // the wings draw their own glow
        livePanel.appearance = NSAppearance(named: .darkAqua)   // the wings are always dark glass
        livePanel.alphaValue = 0
        live.onTap = { [weak self] in
            guard let self = self else { return }
            if let request = self.live.request, request.id.hasPrefix("managed-") { self.openManagedApproval(request); return }
            if let id = self.liveObservedID {
                self.show(.claude)
                MainActor.assumeIsolated { (self.cards[.claude] as? AgentsView)?.openObserved(provider: "codex", id: id) }
                return
            }
            self.suppressUntil = .distantPast
            // From the live bar you want the session itself, so the live view opens too.
            self.claudeOpenExpanded = true
            self.show(.claude)
        }
        live.onDecide = { [weak self] req, allow in
            guard let self = self else { return }
            if req.id.hasPrefix("managed-") {
                let needsReview = MainActor.assumeIsolated { AgentOverview.managedApproval.map { $0.request.id == req.id && $0.review } ?? false }
                if allow, needsReview { self.openManagedApproval(req); return }
                guard MainActor.assumeIsolated({ AgentOverview.decideManaged(req, allow: allow) }) else { return }
                self.reactLight(allow ? .success : .danger); self.updateLive(); return
            }
            // A second tap right after a decision (a double-click) answers nothing.
            guard MainActor.assumeIsolated({ ClaudeHookService.shared.respond(req, allow: allow) }) else { return }
            self.sound(allow ? .claudeApproved : .claudeRejected)
            self.reactLight(allow ? .success : .danger)
            // The wing folds with the answer; she just looks pleased (or thoughtful).
            self.react(allow ? .happy : .thinking, for: 1.8)
            self.updateLive()
        }
        wireExtras()
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

        island.companion.source = buddy.zera
        island.companion.onTap = { [weak self] in
            self?.sound(.tap)
            let mood: ZeraMood = self?.zera.isReactingToPokes == true ? .error : .hello
            EdgeLight.shared.react(.shortcut, tint: CompanionGlyph.tint(for: mood))
        }
        cardPanel.edgeAnchored = true
        cardPanel.contentView = island
        cardPanel.hasShadow = false          // the island draws its own glow
        cardPanel.appearance = NSAppearance(named: .darkAqua)
        cardPanel.ignoresMouseEvents = true

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(storeChanged), name: ShelfStore.changed, object: nil)
        nc.addObserver(self, selector: #selector(githubChanged), name: GitHubService.changed, object: nil)
        nc.addObserver(self, selector: #selector(vitalsChanged), name: SystemVitals.changed, object: nil)
        nc.addObserver(self, selector: #selector(powerFlipped(_:)), name: BatteryAlerts.powerFlipped, object: nil)
        nc.addObserver(self, selector: #selector(githubNews(_:)), name: GitHubService.newEvents, object: nil)
        nc.addObserver(self, selector: #selector(hookRequest(_:)), name: ClaudeHookService.newRequest, object: nil)
        nc.addObserver(self, selector: #selector(hookChanged), name: ClaudeHookService.changed, object: nil)
        nc.addObserver(self, selector: #selector(reminderFired(_:)), name: ReminderService.alert, object: nil)
        nc.addObserver(self, selector: #selector(remindersChanged), name: ReminderService.changed, object: nil)
        nc.addObserver(self, selector: #selector(paletteChanged), name: Palette.changed, object: nil)
        nc.addObserver(self, selector: #selector(assistantChanged), name: ZeraAssistant.changed, object: nil)
        nc.addObserver(self, selector: #selector(activityChanged), name: ClaudeActivityService.changed, object: nil)
        nc.addObserver(self, selector: #selector(activityMilestone(_:)), name: ClaudeActivityService.milestone, object: nil)
        nc.addObserver(self, selector: #selector(alertsChanged), name: AlertCenter.changed, object: nil)
        nc.addObserver(self, selector: #selector(taskStoreChanged), name: TaskStore.changed, object: nil)
        // Find `claude` in the background now, so the first Summarize does not wait for it; the
        // same for whether an API key is saved (a Keychain read that can stall the UI thread).
        ClaudeCLI.shared.ensureProbed { _ in }
        _ = AnthropicAPIClient.shared.isConfigured

        // A click anywhere else on the screen puts the card away at once — no waiting for the
        // pointer to wander off. (Our own panels get local events, so this never fires for them.)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self = self, self.cardVisible, !self.dragging, !self.buddyDragActive, !self.isDraggingOut else { return }
            if self.currentCard == .approval, self.approvalPending { return }
            if self.currentCard == .claude || self.currentCard == .phoneTransfer { return }
            // Notification banners keep their reading time while you work in other apps.
            if self.isNotificationBanner { return }
            let m = NSEvent.mouseLocation
            if NSPointInRect(m, self.islandScreenRect) || NSPointInRect(m, self.figureRect.insetBy(dx: -8, dy: -6))
                || (self.liveVisible && NSPointInRect(m, self.livePanel.frame)) { return }
            self.dismissCardByUser()
        }) { eventMonitors.append(monitor) }

        // Esc closes whichever card is up, wherever focus is inside it.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self = self, self.cardVisible || self.pillVisible,
                  event.keyCode == 53, event.window === self.cardPanel else { return event }
            if !self.cardVisible { self.hidePill(); return nil }
            if self.currentCard == .approval, self.approvalPending { return event }   // Esc = Reject there
            self.dismissCardByUser()
            return nil
        }) { eventMonitors.append(monitor) }

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
            ClaudeUsageService.shared.start()
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

    /// Her ear: grown out of the right side of the notch, flush with the top of the screen.
    private func positionNotchBuddy() {
        let f = NotchBuddyView.frame(around: geometry.notchRect)
        if notchBuddyPanel.frame != f { notchBuddyPanel.setFrame(f, display: true) }
        notchBuddy.frame = NSRect(origin: .zero, size: f.size)
    }

    /// Shows her ear when she lives in the notch, is enabled, and no screen covers the notch.
    private func syncNotchBuddy(animated: Bool) {
        let show = notchStyle && buddyEnabled && !liveVisible && !cardVisible && !pillVisible && !openerOpen && !(waterVisit?.isActive ?? false)
        if show {
            positionNotchBuddy()
            if notchBuddyPanel.alphaValue < 0.05 { notchBuddyPanel.orderFrontRegardless() }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated ? Motion.duration(show ? 0.3 : 0.15) : 0
            notchBuddyPanel.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            ZeraAnimationClock.shared.refresh()
            guard let self = self, self.notchBuddyPanel.alphaValue < 0.05 else { return }
            self.notchBuddyPanel.orderOut(nil)
        })
    }

    private func placeBuddy(centerX x: CGFloat) {
        positionNotchBuddy()
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
        syncNotchBuddy(animated: animated)
        // In the notch she has no rope: the hanging figure stays hidden.
        let visible = visible && !notchStyle && !(waterVisit?.isActive ?? false)
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

    private var figureRect: NSRect {
        guard notchStyle else { return geometry.figureRect(centerX: buddyPanel.frame.midX) }
        // The notch and her ear (from the geometry, never from a window that may not be placed yet).
        return NotchBuddyView.frame(around: geometry.notchRect)
    }
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
        let cx = notchStyle ? geometry.notchRect.midX : figureRect.midX + (zera.activity == .none ? 0 : zera.claudeBodyOffset)
        let x = max(scr.minX, min(scr.maxX - size.width, cx - size.width / 2))
        let y = notchStyle ? (geometry.notchRect.minY - size.height * 0.62).rounded()
                           : (figureRect.minY + Theme.figureHeight * 0.43 - size.height / 2).rounded()
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
    private var liveObservedID: String?
    private var liveObservedPresentation: ClaudeSession?
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
            let managed = AgentOverview.managedApproval
            let pending = s.flatMap { s in hooks.first { $0.sessionID == s.id } } ?? hooks.first ?? managed?.request
            // Idle sessions stay visible for a few minutes after their last activity.
            let stale = s.map { $0.status == .ended || ($0.status == .idle && Date().timeIntervalSince($0.lastEventAt) > 600) } ?? true
            if pending == nil, s?.status != .running, s?.status != .waiting,
               let run = AgentWatch.shared.working.filter({ $0.agent == .codex }).max(by: { $0.lastEventAt < $1.lastEventAt }) {
                if self.liveObservedID != run.id {
                    self.liveObservedID = run.id
                    self.liveObservedPresentation = ClaudeSession(id: run.id, cwd: run.project, at: Date())
                    self.liveObservedPresentation?.promptAt = Date()
                }
                if let presentation = self.liveObservedPresentation {
                    presentation.title = run.title ?? run.project; presentation.status = .running; presentation.monitoredOnly = true
                    presentation.steps = [ActivityStep(id: "current", kind: .run, verb: "", target: run.activity ?? "Thinking through the request", detail: nil, at: run.lastEventAt, finished: false)]
                    self.live.update(session: presentation, pending: nil, provider: "Codex")
                    self.ensureLiveTicker()
                    return (true, false, false)
                }
            }
            self.liveObservedID = nil; self.liveObservedPresentation = nil
            // A turn that just finished brings minimized wings back (once), so you can see it and reply.
            if let s = s, s.status == .done, !stale {
                let key = "\(s.id)|\(s.promptAt?.timeIntervalSince1970 ?? 0)"
                if key != self.surfacedFinish {
                    self.surfacedFinish = key
                    self.liveHideWork?.cancel(); self.liveHideWork = nil
                    self.finishedLiveHidden = false
                    self.liveDismissed = false
                }
            }
            // Nothing running, nothing waiting on you, no reply still on offer.
            let quiet = ClaudeActivityService.shared.active.isEmpty && hooks.isEmpty && managed == nil && !(s?.canReply ?? false)
            if stale && pending == nil { return (false, false, quiet) }
            self.live.replyWindow = Double(ClaudeActivityService.shared.replyWindow)
            AwakeKeeper.shared.agentsWorking = !ClaudeActivityService.shared.active.isEmpty
            if self.claudeActiveCount != ClaudeActivityService.shared.active.count {
                self.claudeActiveCount = ClaudeActivityService.shared.active.count
                self.refreshTroupe()
            }
            // An approval from another session is shown on its own, never under this session's
            // task line, so the words and the command on the wings always belong together.
            let foreign = pending.map { !$0.sessionID.isEmpty && $0.sessionID != s?.id } ?? false
            let isManaged = pending?.id == managed?.request.id && managed != nil
            self.live.update(session: stale || foreign || isManaged ? nil : s, pending: pending,
                             provider: isManaged ? managed!.provider : "Claude", review: isManaged && managed!.review)
            // The field folded away on its own (the session moved on): the reply is dropped.
            if self.replySession != nil, !self.live.composing { self.livePanel.keyable = false; self.releaseReplySession() }
            // While it can still take a reply, a finished session's wings stay up.
            return (true, pending == nil && s?.status == .done && !self.live.composing, quiet)
        }
        // Nothing live and nothing waiting: the per-second refresh stops until the next event.
        if quiet, !show || finishedLiveHidden { liveTicker?.invalidate(); liveTicker = nil }
        if quiet {
            AwakeKeeper.shared.agentsWorking = false
            if claudeActiveCount != 0 { claudeActiveCount = 0; refreshTroupe() }
        }
        // She hugs her rope and acts out what Claude is doing: working, waiting on you, done.
        switch show && !finishedLiveHidden ? live.mode : .idle {
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
            let finish = surfacedFinish
            let w = DispatchWorkItem { [weak self] in
                guard let self = self, self.surfacedFinish == finish else { return }
                self.liveHideWork = nil
                guard self.live.mode == .done, !self.live.composing, !self.approvalPending else { return }
                self.finishedLiveHidden = true
                self.liveTicker?.invalidate(); self.liveTicker = nil
                self.zera.activity = .none
                self.refreshBadges()
                self.hideLive()
            }
            liveHideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
        }
    }

    private func showLive() {
        positionLive()
        positionBubble()
        guard !liveVisible else { return }
        liveVisible = true
        syncNotchBuddy(animated: true)
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
        syncNotchBuddy(animated: true)
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
        if notchBuddyPanel.alphaValue > 0.05 { notchBuddyPanel.orderFrontRegardless() }
        if bubblePanel.alphaValue > 0.05 { bubblePanel.orderFrontRegardless() }
    }

    // MARK: - Pointer polling

    /// 30 Hz while the pointer moves or a screen is up; 10 Hz once everything has been still for a
    /// moment. The first move after a calm spell is caught within 100 ms and switches straight back.
    private static let fastPoll: TimeInterval = 1.0 / 30.0
    private static let calmPoll: TimeInterval = 1.0 / 10.0
    private static let calmAfter: TimeInterval = 1.5
    private var pollIsCalm = false

    private func schedulePoll(calm: Bool) {
        pollTimer?.invalidate()
        pollIsCalm = calm
        let interval = calm ? Self.calmPoll : Self.fastPoll
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func startPolling() {
        schedulePoll(calm: false)
        // The motes and the rail's rings follow the clock too (a meeting comes within the hour).
        badgeTimer?.invalidate()
        let b = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refreshBadges() }
        b.tolerance = 5
        RunLoop.main.add(b, forMode: .common)
        badgeTimer = b
        refreshBadges()
    }
    private var badgeTimer: Timer?
    private var lastReportedIdle = false

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
        let still = now.timeIntervalSince(lastMoveAt)
        let idle = still > 180
        if idle != lastReportedIdle {
            lastReportedIdle = idle
            MainActor.assumeIsolated { ReminderService.shared.userIsIdle = idle }
        }
        let calm = still > Self.calmAfter && !cardVisible && !openerOpen && !dragging && !liveVisible
            && !hovering && !mouseButtonDown
        if calm != pollIsCalm { schedulePoll(calm: calm) }
        trackFileDrag()

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
        // In the app opener she watches the app you're on: under the pointer, or the selection.
        let mouse = openerOpen ? (opener.focusPoint ?? mouse) : mouse
        // Respond near the face and ease towards a bounded gaze farther away.
        let x = tanh((mouse.x - head.x) / 260)
        let y = tanh((mouse.y - head.y) / 200)
        zera.lookTarget = CGPoint(x: x, y: y)
    }

    private func updateHover(_ mouse: NSPoint, _ now: Date) {
        let present = notchStyle ? (notchBuddyPanel.alphaValue > 0.5 || cardVisible || pillVisible) : buddyPanel.alphaValue > 0.5
        // The self-test tour drives the notch itself; the pointer stays out of it.
        guard buddyEnabled, present, !dragging, !isTouring else { return }
        // A keyboard-opened menu stays reachable until the pointer moves again.
        if navigationPinned, let origin = navigationPinOrigin,
           abs(mouse.x - origin.x) + abs(mouse.y - origin.y) > 4 {
            navigationPinned = false; navigationPinOrigin = nil
        }
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
            // In the notch she greets you with a hop and sparkles instead of a caption.
            if onHer, !notchStyle, !asleep, !buddyDragActive, zera.mood != .error, zera.mood != .worried, zera.mood != .excited, !cardVisible {
                if CACurrentMediaTime() - lastHelloSound > 20 { sound(.hello); lastHelloSound = CACurrentMediaTime() }
                say(Self.helloLines.randomElement()!, mood: .hello, for: 2.2)
            }
        }
        if onHer || onPill || bridge {
            pillLeftAt = nil
            if !pillVisible { showPill() }   // also while a card is up, to switch cards directly
        } else if pillVisible && !navigationPinned {
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
    /// Keyboard navigation stays open while the pointer is stationary; pointer use restores
    /// the usual leave grace, including when opening from the native View menu.
    func showNavigation() {
        suppressUntil = .distantPast
        if cardVisible { hideCard() }
        navigationPinned = ControlFocusVisibility.keyboard
        navigationPinOrigin = navigationPinned ? NSEvent.mouseLocation : nil
        showPill(restore: false)
        cardPanel.makeKey()
        cardPanel.recalculateKeyViewLoop()
        cardPanel.selectNextKeyView(nil)
    }

    private func showPill(restore: Bool = true) {
        if restore, !cardVisible, Date() >= suppressUntil,
           let remembered = NotchNavigation.shared.destination(fallback: nil) {
            show(remembered)
            return
        }
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
        navigationPinned = false
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
            if !ClaudeHookService.shared.pending.isEmpty || !CodexAgentService.shared.approvals.isEmpty || !ClaudeAgentService.shared.approvals.isEmpty { b.formUnion([.home, .claude]) }
            if ClaudeActivityService.shared.active.contains(where: { $0.status == .waiting }) { b.insert(.claude) }
            if !ReminderService.shared.pendingAlerts.isEmpty { b.formUnion([.home, .reminders]) }
            if AlertCenter.shared.needsYou > 0 { b.insert(.alerts) }
            return b
        }
        island.counts[.alerts] = MainActor.assumeIsolated { AlertCenter.shared.unread }
        // How many Claude sessions are running: with the wings minimized, this is where you see them.
        island.counts[.claude] = MainActor.assumeIsolated {
            let agents = AgentOverview.snapshot()
            let activity = AgentOverview.notchActivity(for: agents)
            if currentCard != .phoneTransfer || !cardVisible { island.companion.activityOverride = activity }
            notchBuddy.activityOverride = activity
            return agents.filter { $0.state == .working || $0.needsApproval }.count
        }
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
        if let f = FocusView.instrument(now: now) { out[.focus] = f }
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

    /// The shortcut that opens Clipboard from any app (⇧⌘V unless you recorded another); nil is off.
    var clipboardShortcut: HotKeyShortcut? {
        get { HotKeyShortcut.load("clipboard.shortcut", default: .default) }
        set { HotKeyShortcut.save(newValue, "clipboard.shortcut") }
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
        get { HotKeyShortcut.load("appOpener.shortcut", default: AppOpenerSettings.defaultShortcut) }
        set { HotKeyShortcut.save(newValue, "appOpener.shortcut") }
    }

    /// Registers the opener's shortcut (when the opener is on). False if macOS refused it.
    @discardableResult
    func registerOpenerHotKey() -> Bool {
        openerHotKey = nil
        guard AppOpenerSettings.enabled, let s = openerShortcut else { return true }
        openerHotKey = GlobalHotKey(s) { [weak self] in
            MainActor.assumeIsolated { CommandEcho.shared.configuredShortcut(keys: s.label, label: "App opener", symbol: "square.grid.2x2") }
            self?.toggleOpener()
        }
        return openerHotKey != nil
    }

    private func setOpenerShortcut(_ s: HotKeyShortcut?) -> Bool {
        HotKeyShortcut.swap(to: s, from: openerShortcut, save: { openerShortcut = $0 }, register: { registerOpenerHotKey() })
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
            self.setBuddy(visible: !open, animated: true)
            if open { self.bubblePanel.alphaValue = 0 }
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
            MainActor.assumeIsolated { CommandEcho.shared.configuredShortcut(keys: s.label, label: "Clipboard", symbol: "doc.on.clipboard") }
            if self.cardVisible, self.currentCard == .clipboard { self.dismissCardByUser() }
            else { self.suppressUntil = .distantPast; self.show(.clipboard) }
        }
        return clipboardHotKey != nil
    }

    /// From the recorder in Settings: try the new shortcut, keep the old one if it can't be used.
    private func setClipboardShortcut(_ s: HotKeyShortcut?) -> Bool {
        HotKeyShortcut.swap(to: s, from: clipboardShortcut, save: { clipboardShortcut = $0 }, register: { registerClipboardHotKey() })
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
            dismissNotchCaption()
            island.whisper(nil)
            return
        }
        if cardVisible {
            hideBubble()
            dismissNotchCaption()
            island.whisper(islandTakesCaption ? line : nil, tone: captionTone)
        } else if notchStyle {
            // She speaks out of the notch: it grows and says it, in her mood's colour.
            hideBubble()
            island.whisper(nil)
            let symbol = Self.moodSymbol(zera.mood), tone = captionTone
            MainActor.assumeIsolated {
                if let revision = CommandEcho.shared.presentCaption(
                    EchoContent(symbol: symbol, keys: "", text: line, tint: tone), replacing: notchCaptionRevision, hold: 6) {
                    notchCaptionRevision = revision
                }
            }
        } else {
            island.whisper(nil)
            bubble.text = line
            bubble.tone = captionTone
            positionBubble()
            showBubble()
        }
    }

    private var notchCaptionRevision: Int?
    private func dismissNotchCaption() {
        guard let revision = notchCaptionRevision else { return }
        notchCaptionRevision = nil
        MainActor.assumeIsolated { CommandEcho.shared.dismissPresented(revision: revision) }
    }

    static func moodSymbol(_ mood: ZeraMood) -> String {
        switch mood {
        case .happy, .celebrate, .love, .approved, .giving, .excited: return "face.smiling"
        case .hello: return "hand.wave.fill"
        case .worried, .sad, .error: return "exclamationmark.bubble.fill"
        case .sleepy, .cozy: return "moon.zzz.fill"
        case .thinking, .focused: return "ellipsis.bubble.fill"
        case .surprised: return "sparkles"
        default: return "bubble.left.fill"
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
    private func wake() {
        asleep = false
        sound(.wake)
        // Welcome back: what the agents finished while you were away, if anything.
        guard !missedWhileAway.isEmpty else { say("oh! hi again 👋", mood: .hello, for: 2.0); return }
        let news = missedWhileAway.suffix(3).joined(separator: " · ")
        missedWhileAway.removeAll()
        reactLight(.success)
        say("welcome back! \(news)", mood: .happy, for: 4.5)
    }

    // MARK: - Events from services

    @objc private func githubChanged() { refreshBadges() }
    @objc private func alertsChanged() {
        refreshBadges()
        if cardVisible, currentCard == .alerts { (cards[.alerts] as? AlertsView)?.willShow() }
    }
    @objc private func taskStoreChanged() { if pillVisible || cardVisible { refreshBadges() } }

    /// The notch light answers an event (nothing runs between events; off with Reduce Motion).
    func reactLight(_ r: NotchLightReaction, tint: NSColor? = nil) {
        island.companion.react(r)
        live.companion.react(r)
        // One halo renderer owns every event, including notch-only mode.
        // Zera in the notch answers with a small beat of her own.
        if notchStyle, !asleep {
            switch r {
            case .copy, .paste, .save, .success: notchBuddy.beat(.sparkle)
            case .cut, .screenshot, .capsLock, .approvalNeeded, .danger: notchBuddy.beat(.surprise)
            case .agentArrival, .notification: notchBuddy.beat(.hop)
            case .undo, .redo, .shortcut, .shiftHeld: notchBuddy.beat(.nod)
            default: break
            }
        }
        // …and beyond it: arms along the top edge, or the whole screen's edges (Settings › Light).
        EdgeLight.shared.react(r, tint: tint)
    }

    /// Zera answers your shortcuts with a quick face: a grin for a copy, a gasp for a cut, a
    /// thoughtful look for undo, a nod for save. Only while she's idle, awake and quiet, and at
    /// most once every 0.7 s so a run of ⌘Z doesn't make her twitch. Volume and brightness leave
    /// her alone (the level owns the edge).
    private func echoMood(for r: NotchLightReaction) {
        guard buddyEnabled, !asleep, !cardVisible, !dragging, captionLine == nil,
              zera.mood == .idle, !zera.isReactingToPokes else { return }
        let mood: ZeraMood
        switch r {
        case .copy, .paste: mood = .happy
        case .cut, .screenshot: mood = .surprised
        case .undo, .redo: mood = .thinking
        case .save: mood = .approved
        case .shortcut: mood = .hello
        case .capsLock(let on): mood = on ? .excited : .idle
        default: return
        }
        guard mood != .idle else { return }
        let now = CACurrentMediaTime()
        guard now - lastEchoMoodAt > 0.7 else { return }
        lastEchoMoodAt = now
        react(mood, for: 0.9)
    }
    private var lastEchoMoodAt: CFTimeInterval = 0
    private var dictationFeedbackRevision: Int?
    @objc private func vitalsChanged() { if pillVisible || cardVisible { refreshBadges() } }

    // MARK: Voice, dictation, other agents, music

    private var micLit = false
    private var claudeActiveCount = 0
    private var musicWaveKey: String?

    private func setMicLight(_ on: Bool) {
        guard on != micLit else { return }
        micLit = on
        reactLight(.listening(active: on))
    }

    private func wireExtras() {
        notchBuddyPanel.contentView = notchBuddy
        notchBuddyPanel.hasShadow = false
        notchBuddyPanel.alphaValue = 0
        notchBuddy.source = buddy.zera
        notchBuddy.onActivate = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if let request = ClaudeAgentService.shared.approvals.first {
                    self.show(.claude)
                    (self.cards[.claude] as? AgentsView)?.openClaudeThread(request.threadID)
                } else if let request = CodexAgentService.shared.approvals.first {
                    self.show(.claude)
                    (self.cards[.claude] as? AgentsView)?.openCodexThread(request.threadID)
                } else { self.buddy.onActivate?() }
            }
        }
        notchBuddy.onShowNavigation = { [weak self] in self?.showNavigation() }
        startTourIfAsked()
        observe(BuddyStyle.changed) { [weak self] _ in
            guard let self = self else { return }
            self.hideBubble()
            self.dismissNotchCaption()
            self.layoutBuddy()
        }
        let voice = VoiceApproval.shared
        voice.onDecide = { [weak self] req, allow in self?.live.onDecide?(req, allow) }
        voice.onOpen = { [weak self] in
            guard let self = self else { return }
            self.suppressUntil = .distantPast
            self.claudeOpenExpanded = true
            self.show(.claude)
        }
        voice.onListening = { [weak self] on in
            self?.setMicLight(on)
            MainActor.assumeIsolated {
                if on {
                    CommandEcho.shared.present(EchoContent(symbol: "mic.fill", keys: "", text: "Listening",
                                                           detail: "say approve or deny", tint: Pal.danger), hold: 2.5)
                }
            }
        }

        let dictation = Dictation.shared
        dictation.onTranscript = { [weak self] text in
            guard let self else { return }
            self.setMicLight(text != nil)
            MainActor.assumeIsolated {
                guard let text = text else {
                    if let revision = self.dictationFeedbackRevision {
                        CommandEcho.shared.dismissPresented(revision: revision)
                        self.dictationFeedbackRevision = nil
                    }
                    return
                }
                // Your last words on the left of the camera, your voice on the right.
                let tail = text.count > 34 ? "…" + String(text.suffix(34)) : text
                let violet = NSColor(srgbRed: 0.69, green: 0.48, blue: 1, alpha: 1)
                self.dictationFeedbackRevision = CommandEcho.shared.present(EchoContent(symbol: "waveform", keys: "", text: tail.isEmpty ? "Listening…" : tail,
                                                       tint: violet, bars: Dictation.shared.bars), hold: nil)
            }
        }
        SecureInputWatch.shared.onNotice = { text in
            MainActor.assumeIsolated {
                _ = CommandEcho.shared.present(EchoContent(symbol: "lock.fill", keys: "", text: "Keyboard hidden", detail: text,
                                                       tint: NSColor(srgbRed: 1, green: 0.7, blue: 0.28, alpha: 1)), hold: 4)
            }
        }
        SecureInputWatch.shared.start()
        Diag.log("launch: dictation \(Dictation.shared.enabled) key \(Dictation.shared.trigger.title), echo \(MainActor.assumeIsolated { CommandEcho.shared.isEnabled }), accessibility \(AXIsProcessTrusted()), murmur \(Murmur.shared.state.summary)")
        dictation.onDone = { status in
            MainActor.assumeIsolated {
                _ = CommandEcho.shared.present(EchoContent(symbol: "text.cursor", keys: "", text: "Dictation", detail: status), hold: 1.6)
            }
        }

        for name in [ClaudeAgentService.created, CodexAgentService.created] {
            observe(name) { [weak self] _ in self?.reactLight(.agentArrival) }
        }
        observe(CodexAgentService.changed) { [weak self] _ in
            guard let self else { return }
            self.refreshBadges()
            MainActor.assumeIsolated {
                let service = CodexAgentService.shared
                let approvals = Set(service.approvals.map(\.id))
                if !approvals.subtracting(self.managedApprovalIDs).isEmpty { self.surfaceManagedApproval() }
                else if service.threads.contains(where: { $0.status == "Completed" && self.managedAgentStates[$0.id] != "Completed" }) { self.reactLight(.success) }
                else if service.threads.contains(where: { $0.turnID != nil && self.managedAgentStates[$0.id] != "Working" && $0.status == "Working" }) { self.reactLight(.agentArrival) }
                self.managedApprovalIDs = approvals
                self.managedAgentStates = Dictionary(uniqueKeysWithValues: service.threads.map { ($0.id, $0.status) })
                self.updateLive()
            }
        }
        observe(ClaudeAgentService.changed) { [weak self] _ in
            guard let self else { return }
            self.refreshBadges()
            MainActor.assumeIsolated {
                let service = ClaudeAgentService.shared
                let approvals = Set(service.approvals.map(\.id))
                if !approvals.subtracting(self.managedClaudeApprovalIDs).isEmpty { self.surfaceManagedApproval() }
                else if service.threads.contains(where: { $0.status == "Completed" && self.managedClaudeStates[$0.id] != "Completed" }) { self.reactLight(.success) }
                else if service.threads.contains(where: { $0.status == "Working" && self.managedClaudeStates[$0.id] != "Working" }) { self.reactLight(.agentArrival) }
                self.managedClaudeApprovalIDs = approvals
                self.managedClaudeStates = Dictionary(uniqueKeysWithValues: service.threads.map { ($0.id, $0.status) })
                self.updateLive()
            }
        }
        observe(AgentWatch.started) { [weak self] note in
            guard let self = self, let run = note.userInfo?["run"] as? AgentRun else { return }
            self.reactLight(.agentArrival)
            if self.buddyEnabled, !self.cardVisible { self.say("\(run.agent.rawValue.lowercased()) is on it · \(run.project)", mood: .focused, for: 2.5) }
        }
        observe(AgentWatch.finished) { [weak self] note in
            guard let self = self, let run = note.userInfo?["run"] as? AgentRun else { return }
            self.reactLight(.success)
            self.sound(.claudeApproved)
            if self.buddyEnabled { self.say("\(run.agent.rawValue) finished ✓ \(run.project)", mood: .happy, for: 3) }
        }
        observe(AgentWatch.changed) { [weak self] _ in
            AwakeKeeper.shared.otherAgentsWorking = !AgentWatch.shared.working.isEmpty
            self?.refreshTroupe()
            self?.refreshBadges()
            self?.updateLive()
        }
        observe(NowPlayingService.changed) { [weak self] _ in
            self?.syncMusicWave()
        }
        observe(AgentWatch.finished) { [weak self] note in
            guard let self = self, self.asleep, let run = note.userInfo?["run"] as? AgentRun else { return }
            self.missedWhileAway.append("\(run.agent.rawValue.lowercased()) finished \(run.project)")
        }
        observe(AgentWatch.codexUsageChanged) { [weak self] _ in
            self?.codexUsageChanged()
        }
        observe(WeatherService.changed) { [weak self] _ in
            self?.checkRain()
        }
    }

    private func observe(_ name: Notification.Name, using handler: @escaping (Notification) -> Void) {
        notificationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: handler))
    }

    func prepareForTermination() {
        if let kind = currentCard, let c = currentContent { NotchNavigation.shared.captureScroll(in: c, screen: kind) }
        (cards[.teleprompter] as? TeleprompterView)?.willHide()
    }

    deinit {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
        pollTimer?.invalidate()
        badgeTimer?.invalidate()
        waterGlassTimer?.invalidate()
        liveTicker?.invalidate()
        liveHideWork?.cancel()
        autoHideWork?.cancel()
        sayResetWork?.cancel()
        fullScreenWork?.cancel()
    }

    // MARK: Welcome back, Codex limits, rain

    /// Agent news that landed while she was asleep (you were away); told when you come back.
    private var managedAgentStates: [String: String] = [:]
    private var managedApprovalIDs = Set<String>()
    private var managedClaudeStates: [String: String] = [:]
    private var managedClaudeApprovalIDs = Set<String>()
    private func openManagedApproval(_ request: HookRequest) {
        show(.claude)
        MainActor.assumeIsolated {
            let agents = cards[.claude] as? AgentsView
            if request.id.hasPrefix("managed-claude:") { agents?.openClaudeThread(request.sessionID) }
            else if request.id.hasPrefix("managed-codex:") { agents?.openCodexThread(request.sessionID) }
        }
    }
    private func surfaceManagedApproval() {
        reactLight(.approvalNeeded); sound(.claudeApproval)
        liveDismissed = false; finishedLiveHidden = false
        if !cardVisible, liveCanApprove {
            if pillVisible { hidePill() } else { updateLive() }
        } else {
            show(.approval)
        }
    }
    private var missedWhileAway: [String] = []
    private var codexWarnedAt: Double = 0
    private var lastRainAlert = Date.distantPast

    private func codexUsageChanged() {
        guard let used = AgentWatch.shared.codexUsage?.primary else { return }
        // Once at 80 %, once more at 95 %; reset when the window rolls over.
        if used < 50 { codexWarnedAt = 0; return }
        let mark: Double = used >= 95 ? 95 : (used >= 80 ? 80 : 0)
        guard mark > codexWarnedAt else { return }
        codexWarnedAt = mark
        reactLight(.notification)
        if buddyEnabled { say("codex: \(Int(used.rounded()))% of your 5-hour limit used", mood: .worried, for: 3.5) }
    }

    private func checkRain() {
        let hour: WeatherHour? = MainActor.assumeIsolated {
            WeatherService.shared.snapshot.flatMap { RainWatch.upcoming($0) }
        }
        guard let h = hour, Date().timeIntervalSince(lastRainAlert) > 3 * 3600 else { return }
        lastRainAlert = Date()
        let time = DateFormatter.localizedString(from: h.time, dateStyle: .none, timeStyle: .short)
        reactLight(.notification)
        MainActor.assumeIsolated {
            _ = CommandEcho.shared.present(EchoContent(symbol: "cloud.rain.fill", keys: "", text: "Rain soon",
                                                   detail: "around \(time) · \(h.precipitationChance ?? 0)%", tint: Pal.accent), hold: 4)
        }
        if buddyEnabled, !cardVisible { say("rain around \(time) ☔", mood: .worried, for: 3) }
    }

    /// One little friend per extra Claude session and per Codex / Cursor run at work.
    private func refreshTroupe() {
        var colors: [NSColor] = Array(repeating: Pal.tileClaude, count: max(0, claudeActiveCount - 1))
        for run in AgentWatch.shared.working.sorted(by: { $0.id < $1.id }) {
            colors.append(run.agent == .codex ? NSColor(srgbRed: 0.35, green: 0.85, blue: 0.80, alpha: 1)
                                              : NSColor(srgbRed: 0.92, green: 0.94, blue: 1.0, alpha: 1))
        }
        // With anyone else at work, Claude's own session counts as a friend too.
        if claudeActiveCount == 1, !AgentWatch.shared.working.isEmpty { colors.insert(Pal.tileClaude, at: 0) }
        buddy.setCompanions(colors)
    }

    /// The wave runs while a track plays (if turned on), in the colour of its artwork.
    private func syncMusicWave() {
        MainActor.assumeIsolated {
            let track = NowPlayingService.shared.track
            let key = (MusicWave.enabled && track?.isPlaying == true) ? track?.id : nil
            guard key != self.musicWaveKey else { return }
            self.musicWaveKey = key
            guard key != nil else { self.reactLight(.music(active: false)); return }
            let image = track?.artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            self.reactLight(.music(active: true), tint: image.flatMap { WallpaperTint.glowColor(of: $0) })
        }
    }

    /// Plug in or unplug: the outline fills green to the charge level, then fades.
    @objc private func powerFlipped(_ note: Notification) {
        guard let percent = note.userInfo?["percent"] as? Int else { return }
        reactLight(.level(kind: .battery, value: Double(percent) / 100))
    }

    // MARK: File drags
    //
    // While the mouse button is down, the drag pasteboard's change counter is read each tick (it
    // is only touched when a press begins and while it lasts). Files picked up anywhere make the
    // notch breathe amber until the drop, so you know where the Shelf is.
    private let dragBoard = NSPasteboard(name: .drag)
    private var dragBoardCount = 0
    private var buttonWasDown = false
    private var fileDragLit = false

    private func trackFileDrag() {
        let down = mouseButtonDown
        defer { buttonWasDown = down }
        if down {
            if !buttonWasDown { dragBoardCount = dragBoard.changeCount; return }
            guard !fileDragLit else { return }
            let count = dragBoard.changeCount
            guard count != dragBoardCount else { return }
            dragBoardCount = count
            guard !isDraggingOut, !dragging, dragBoard.types?.contains(.fileURL) == true else { return }
            fileDragLit = true
            reactLight(.fileDrag(active: true))
        } else if fileDragLit {
            fileDragLit = false
            reactLight(.fileDrag(active: false))
        }
    }

    @objc private func githubNews(_ note: Notification) {
        guard let fresh = note.userInfo?["events"] as? [GHEvent], let top = fresh.first else { return }
        switch top.kind {
        case .ciFailed: reactLight(.danger)
        case .ciPassed, .prApproved: reactLight(.success)
        default: reactLight(.notification)
        }
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
        reactLight(.approvalNeeded)
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
        // Nothing waiting any more: the orange breathing on the notch stops.
        if !approvalPending { island.clearStickyLight() }
        refreshBadges()
        ensureLiveTicker()
        updateLive()
        if cardVisible, currentCard == .approval { (cards[.approval] as? ApprovalCard)?.reload() }
    }

    private var approvalPending: Bool { MainActor.assumeIsolated { !ClaudeHookService.shared.pending.isEmpty || AgentOverview.managedApproval != nil } }

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
        if cardVisible, currentCard == .claude { MainActor.assumeIsolated { (cards[.claude] as? AgentsView)?.reload() } }
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
        case .battery: mood = BatteryAlerts.isChargingAlert(a) ? .happy : .worried
        case .calendarHeadsUp, .headsUp: mood = .hello
        case .calendarNow, .now, .snoozed: mood = .excited
        }
        if a.hydration { sound(.water) }
        else if a.kind == .battery { sound(BatteryAlerts.isChargingAlert(a) ? .reminderDone : .batteryLow) }
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
        if let kind = currentCard, let c = currentContent { NotchNavigation.shared.captureScroll(in: c, screen: kind) }
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
                (content(for: .shelf) as? DropFilesView)?.showShelfItems()
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
        case .tasks: show(.tasks)
        case .pullRequests: show(.github)
        case .settings: show(.settings)
        case .focus: show(.focus)
        case .teleprompter: show(.teleprompter)
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

    /// From the Drop Files screen: the answer streams into its own result panel, so the card
    /// stays put. If you close it meanwhile, the Drop Files screen comes back when it's done.
    private func shelfRunsInPlace(_ action: FileAction, on item: ShelfItem) {
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

    // The receipt uses the existing island: one outline, one morph, one Zera companion.
    private var phoneReceiptID: String?
    private var phoneReceiptPhase: PhoneTransferState.Phase?
    private var phonePreviousCard: CardKind?
    /// Photos and videos skip the panel unless their transfer is still running after a moment.
    private var phoneSlowID: String?
    private var phoneSlowCheck: DispatchWorkItem?

    func updateAndroidTransfer(_ receipt: PhoneTransferState?) {
        guard let receipt else {
            if currentCard == .phoneTransfer, cardVisible {
                if let previous = phonePreviousCard { show(previous) }
                else { hideCard(); settle() }
            }
            phoneReceiptID = nil
            phoneReceiptPhase = nil
            phonePreviousCard = nil
            phoneSlowCheck?.cancel(); phoneSlowCheck = nil; phoneSlowID = nil
            island.companion.releasePhone()
            return
        }
        if receipt.opensDirectly, phoneReceiptID != receipt.id, phoneSlowID != receipt.id, receipt.phase != .failed {
            // Like one picture across two screens: it lands on the desktop and opens, with no panel
            // in the way. A transfer still running after a moment gets the panel and its progress.
            if receipt.phase == .receiving, phoneSlowCheck == nil {
                let id = receipt.id
                let check = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.phoneSlowCheck = nil
                    guard let current = AndroidTransfer.shared.transfer, current.id == id, current.phase == .receiving else { return }
                    self.phoneSlowID = id
                    self.updateAndroidTransfer(current)
                }
                phoneSlowCheck = check
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: check)
            }
            return
        }
        let isNew = phoneReceiptID != receipt.id
        if isNew {
            if currentCard != .phoneTransfer { phonePreviousCard = cardVisible ? currentCard : nil }
            phoneReceiptID = receipt.id
            phoneReceiptPhase = nil
            let card = content(for: .phoneTransfer) as? AndroidTransferCard
            card?.update(receipt)
            show(.phoneTransfer)
            island.companion.enterFromNotch()
        } else { (cards[.phoneTransfer] as? AndroidTransferCard)?.update(receipt) }
        guard currentCard == .phoneTransfer, cardVisible else { return }
        island.setPhoneTransfer(receipt)
        if phoneReceiptPhase != receipt.phase {
            phoneReceiptPhase = receipt.phase
            switch receipt.phase {
            case .approaching:
                // The panel's own edge glows (PhoneLiquidLayer); no light outside the island.
                react(.excited, for: 0)
                island.companion.activityOverride = nil
                island.companion.awaitPhone(from: receipt.side)
            case .receiving:
                react(.happy, for: 0)
                island.companion.activityOverride = nil
                // She comes out of the notch with the card in her raised hands, then cheers it in.
                island.companion.catchFromPhone()
            case .saved:
                island.companion.releasePhone()
                react(.celebrate, for: 2)
                island.companion.activityOverride = .done
                island.react(.success)
            case .failed:
                island.companion.releasePhone()
                react(.worried, for: 2)
                island.companion.activityOverride = nil
                island.react(.danger)
            }
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
            s.onAcceptDrop = { [weak self] in self?.shelfDidAcceptDrop() }
            s.onDragOverChanged = { [weak self] over in self?.shelfDragOverChanged(over) }
            s.onDragOutBegan = { [weak self] in self?.isDraggingOut = true; self?.sound(.fileDragOut) }
            s.onDragOutEnded = { [weak self] in self?.isDraggingOut = false; self?.outsideSince = Date() }
            s.onSay = { [weak self] line, mood, seconds in self?.say(line, mood: mood, for: seconds) }
            s.onSettle = { [weak self] in self?.settle() }
            s.onRunInPlace = { [weak self] action, item in self?.shelfRunsInPlace(action, on: item) }
            c = s
        case .taskExport:
            let export = tasks.exportView
            let screen = TaskExportCard(view: export)
            screen.onBack = { [weak self] in self?.show(.tasks) }
            export.onClose = { [weak self] in self?.show(.tasks) }
            export.onExport = { [weak self] span, format, project in self?.tasks.export(span, format, project) }
            c = screen
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
            s.onReturn = { [weak self] in
                let saved = CardKind(rawValue: NotchNavigation.shared.integer("settings.return", fallback: CardKind.home.rawValue)) ?? .home
                self?.show(NotchNavigation.isDestination(saved) && saved != .settings ? saved : .home)
            }
            s.onOpenArrangement = { [weak self] in self?.show(.arrange) }
            s.onOpenAgents = { [weak self] in self?.show(.claude) }
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
            t.onExport = { [weak self] in self?.show(.taskExport) }
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
        case .alerts:
            let v = AlertsView()
            v.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 2.5) }
            v.onOpen = { [weak self] a in
                guard let self = self else { return }
                if let u = a.url, a.kind == .pullRequest { self.open(u); return }
                if let k = a.opens { self.show(k) } else if let u = a.url { self.open(u) }
            }
            c = v
        case .teleprompter:
            let t = TeleprompterView()
            c = t
        case .arrange:
            c = MainActor.assumeIsolated {
                let view = WindowArrangementView()
                view.onOpenPermissions = { [weak self] in
                    self?.show(.settings)
                    (self?.cards[.settings] as? SettingsCard)?.select(.permissions)
                }
                return view
            }
        case .focus:
            let f = FocusView(store: tasks.store)
            f.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 2.5) }
            f.onOpenTasks = { [weak self] in self?.show(.tasks) }
            c = f
        case .approval:
            let a = ApprovalCard()
            a.onReviewManaged = { [weak self] request in self?.openManagedApproval(request) }
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
        case .phoneTransfer:
            let receipt = AndroidTransferCard()
            receipt.onReveal = { AndroidTransfer.shared.reveal() }
            c = receipt
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
            let a = MainActor.assumeIsolated {
            let a = AgentsView()
            a.claude.say = { [weak self] line, mood in self?.say(line, mood: mood, for: 2.5) }
            a.claude.onOpenSettings = { [weak self] in
                self?.show(.settings)
                (self?.cards[.settings] as? SettingsCard)?.select(.claude)
            }
            // The one external action here, and only when you press it.
            a.claude.onNewSession = { [weak self] in self?.openClaudeCode() }
            a.claude.onOpenClaudeCode = { [weak self] in self?.openClaudeCode() }
            a.onReviewApproval = { [weak self] in self?.show(.approval) }
            a.claude.onReviewApproval = a.onReviewApproval
            a.claude.onReviewSessionApproval = { [weak self] id in
                self?.show(.approval)
                (self?.cards[.approval] as? ApprovalCard)?.selectSession(id)
            }
            a.claude.onAsk = { [weak self] url, question in self?.assist(.ask(question), on: url) }
                return a
            }
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
        MainActor.assumeIsolated { (c as? AgentsView)?.onEscape = escape }
        (c as? DropFilesView)?.onEscape = escape
        (c as? RemindersView)?.onEscape = escape
        cards[kind] = c
        return c
    }

    func toggleDefaultCard() { cardVisible ? dismissCardByUser() : show(NotchNavigation.shared.destination(fallback: defaultCard) ?? .shelf) }

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
        if kind != .phoneTransfer { island.companion.activityOverride = nil }
        navigationPinned = false
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
        if let previous = currentCard, let view = currentContent { NotchNavigation.shared.captureScroll(in: view, screen: previous) }
        if kind == .settings, let previous = currentCard, previous != .settings, NotchNavigation.isDestination(previous) {
            NotchNavigation.shared.set(previous.rawValue, for: "settings.return")
        }
        NotchNavigation.shared.record(kind)
        if swapping {
            (currentContent as? TeleprompterView)?.willHide()
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
        case .approval: (cards[.approval] as? ApprovalCard)?.selectSession(nil)
        case .reminders: (cards[.reminders] as? RemindersView)?.willShow()
        case .reminderAlert: (cards[.reminderAlert] as? ReminderAlertCard)?.reload()
        case .toast: if let e = pendingToast { (cards[.toast] as? ToastCard)?.show(event: e) }
        case .result: (cards[.result] as? ResultCard)?.reload()
        case .claude:
            MainActor.assumeIsolated { (cards[.claude] as? AgentsView)?.willShow(expanded: claudeOpenExpanded) }
            claudeOpenExpanded = false
        case .taskExport:
            if !NotchNavigation.shared.remembersScreen {
                tasks.exportView.project = tasks.store.shownProject
                tasks.exportView.span = .today
            }
            tasks.exportView.refresh()
            tasks.syncCommits(quiet: true) { [weak self] in self?.tasks.exportView.refresh() }
        case .settings: (cards[.settings] as? SettingsCard)?.willShow()
        case .phoneTransfer:
            if let receipt = AndroidTransfer.shared.transfer { (cards[.phoneTransfer] as? AndroidTransferCard)?.update(receipt); island.setPhoneTransfer(receipt) }
        case .clipboard: (cards[.clipboard] as? ClipboardView)?.willShow()
        case .tasks:
            let t = cards[.tasks] as? TasksCard
            t?.orbShown = TasksSettings.orb
            t?.willShow()
        case .alerts: (cards[.alerts] as? AlertsView)?.willShow()
        case .teleprompter: (cards[.teleprompter] as? TeleprompterView)?.willShow()
        case .focus: (cards[.focus] as? FocusView)?.willShow()
        case .arrange: MainActor.assumeIsolated { (cards[.arrange] as? WindowArrangementView)?.willShow() }
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
        if let c = currentContent { NotchNavigation.shared.restoreScroll(in: c, screen: kind) }
        island.activeTab = Isle.tab(for: kind)
        zera.islandPose = Isle.pose(for: kind)
        routeCaption()
        if isNotificationBanner { startBannerCountdown() }
        else { bannerCountdown = nil }
        if kind == .claude {
            cardPanel.makeKey()
            cardPanel.makeFirstResponder(currentContent)
            cardPanel.recalculateKeyViewLoop()
        }
        if kind == .approval { cardPanel.makeKey() }
        if kind == .tasks, let t = cards[.tasks] as? TasksCard {
            // Type a task straight away (the panel doesn't take focus from your app).
            cardPanel.makeKey()
            cardPanel.makeFirstResponder(t.field)
        }
        if kind == .focus, let f = cards[.focus] as? FocusView {
            cardPanel.makeKey()
            cardPanel.makeFirstResponder(f.field)
        }
        if kind == .taskExport {
            cardPanel.makeKey()
            cardPanel.makeFirstResponder(tasks.exportView)
        }
        if kind == .teleprompter {
            // Space, ↑↓ and ←→ drive the roll straight away.
            cardPanel.makeKey()
            cardPanel.makeFirstResponder(currentContent)
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
        isPresenting = true
        c.setFrameSize(NSSize(width: w, height: max(c.frame.height, 100)))
        c.needsLayout = true
        c.layoutSubtreeIfNeeded()
        isPresenting = false
        let h = min(c.desiredHeight, Isle.maxContentHeight, geometry.screen.visibleFrame.height - 40)
        island.present(c, size: NSSize(width: w, height: h), direction: direction, animated: animated)
    }

    func hideCard() {
        island.companion.activityOverride = nil
        guard cardVisible else { return }
        if let kind = currentCard, let c = currentContent { NotchNavigation.shared.captureScroll(in: c, screen: kind) }
        sound(.islandClose)
        (currentContent as? TeleprompterView)?.willHide()
        MainActor.assumeIsolated { ZeraDropdown.shared.dismiss() }
        cardVisible = false
        if currentCard == .reminderAlert { MainActor.assumeIsolated { ReminderService.shared.finishBanner() } }
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
        if currentCard == .phoneTransfer, AndroidTransfer.shared.transfer != nil { outsideSince = nil; return }
        if isNotificationBanner {
            if currentCard == .reminderAlert, MainActor.assumeIsolated({ ReminderService.shared.currentBanner == nil }) {
                hideCard(); settle(); return
            }
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
        // Folder pickers belong to this panel. Leaving its bounds to use a sheet must
        // not collapse the owner or strand a modal session behind another app.
        if cardPanel.attachedSheet != nil || NSApp.modalWindow != nil {
            outsideSince = nil
            return
        }
        if NSApp.isActive, cardPanel.isKeyWindow, let field = cardPanel.firstResponder as? NSTextView, field.isEditable {
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

    // MARK: - Shelf

    private func shelfDidAcceptDrop() {
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

    private func shelfDragOverChanged(_ over: Bool) {
        externalDragOver = over
        if over { autoHideWork?.cancel(); outsideSince = nil }
    }


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

// MARK: - Self-test tour
//
// `ZERA_TOUR=/some/folder Zera.app/Contents/MacOS/Zera`: she walks through every notch feature
// on her own (the same code paths real events take), saves a picture of her own windows after
// each step into that folder with a log, puts your clipboard back, and quits. Capturing only
// Zera's own windows needs no Screen Recording permission. The desktop, menu bar and hardware
// notch in the pictures are painted in, since those aren't hers to capture.
extension ZeraController {
    private static var touring = false

    func startTourIfAsked() {
        guard let path = ProcessInfo.processInfo.environment["ZERA_TOUR"], !path.isEmpty else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.touring = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.runTour(dir) }
    }

    var isTouring: Bool { Self.touring }

    private struct TourShot {
        let name: String
        let wait: TimeInterval
        let tall: Bool
        let action: () -> Void
    }

    private func runTour(_ dir: URL) {
        let saved = NSPasteboard.general.string(forType: .string)
        let echoOn = MainActor.assumeIsolated { CommandEcho.shared.isEnabled && CommandEcho.shared.hudEnabled }
        var log: [String] = [
            "Zera self-test tour",
            "buddy style: \(BuddyStyle.current == .notch ? "notch" : "hanging")",
            "hover menu: \(HoverMenuStyle.current.title)",
            "notch: \(geometry.notchRect) real notch: \(geometry.isReal)",
            "command echo on: \(echoOn)",
            "light reactions on: \(NotchLightStyle.reactionsEnabled)",
            "buddy enabled: \(buddyEnabled)",
            "accessibility trusted: \(AXIsProcessTrusted())",
            "input monitoring: \(GlobalKeys.listenAllowed) post events: \(GlobalKeys.postAllowed) key tap: \(GlobalKeys.shared.usingTap)",
            "frontmost app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")",
            "secure keyboard entry on: \(GlobalKeys.secureInputOn)",
            "microphone: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = allowed)",
            "dictation on: \(Dictation.shared.enabled) key: \(Dictation.shared.trigger.title)",
            "edge: \(EdgeLight.shared.mode.title) / \(EdgeLight.shared.style.title)",
        ]
        let echo = { (s: CommandEcho.TourStep) in MainActor.assumeIsolated { CommandEcho.shared.tour(s) } }
        let present = { (c: EchoContent) in MainActor.assumeIsolated { CommandEcho.shared.present(c, hold: 2) } }
        var steps: [TourShot] = []
        func add(_ name: String, wait: TimeInterval = 0.7, tall: Bool = false, _ action: @escaping () -> Void) {
            steps.append(TourShot(name: name, wait: wait, tall: tall, action: action))
        }
        // Real keys: post ⌘C into the system like a keyboard would and see whether the monitors
        // deliver it (they only do with Accessibility allowed for this exact build).
        var keysBefore = 0
        add("00-real-key-post", wait: 0.6) {
            keysBefore = MainActor.assumeIsolated { CommandEcho.shared.keysSeen }
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: down)
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
        }
        add("00b-real-key-result", wait: 0.1) {
            let after = MainActor.assumeIsolated { CommandEcho.shared.keysSeen }
            log.append("real ⌘C reached Command Echo: \(after > keysBefore ? "YES" : "NO") (\(after - keysBefore) key-downs, tap: \(GlobalKeys.shared.usingTap), delivered total: \(GlobalKeys.shared.delivered))")
        }
        // The dictation key: hold right ⇧ like a person would (the microphone stays shut: dry run).
        var triggerBefore: Date?
        add("00c-right-shift-hold", wait: 1.0) {
            triggerBefore = Dictation.shared.lastTrigger
            Dictation.shared.dryRun = true
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 60, keyDown: true)
            down?.flags = .maskShift
            down?.post(tap: .cghidEventTap)
        }
        add("00d-right-shift-result", wait: 0.1) {
            let src = CGEventSource(stateID: .hidSystemState)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 60, keyDown: false)
            up?.flags = []
            up?.post(tap: .cghidEventTap)
            Dictation.shared.dryRun = false
            let fired = Dictation.shared.lastTrigger != triggerBefore
            log.append("right ⇧ hold started dictation: \(fired ? "YES" : "NO") (secure input \(GlobalKeys.secureInputOn), held by \(SecureInputWatch.holder ?? "nobody"))")
        }
        // Typing for real: a text field in a window of our own, focused, then keystrokes posted the
        // way dictation posts them. Proves the words reach a field (with this run's permissions).
        var typeWindow: NSWindow?
        let typeField = NSTextField(frame: NSRect(x: 20, y: 20, width: 360, height: 24))
        add("00e-type-into-field", wait: 0.9) {
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 64), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Zera typing test"
            w.contentView?.addSubview(typeField)
            w.level = .floating
            typeWindow = w
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(typeField)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Dictation.typeKeys("zera typed this ") }
        }
        add("00f-type-result", wait: 0.1) {
            let got = typeField.stringValue
            log.append("dictation keystrokes reached a text field: \(got.contains("zera typed this") ? "YES" : "NO") (field: \"\(got)\", accessibility \(AXIsProcessTrusted()))")
            typeWindow?.orderOut(nil)
        }
        add("01-closed-notch-zera") {}
        add("02-zera-happy") { self.react(.happy, for: 3) }
        add("03-zera-surprised") { self.react(.surprised, for: 3) }
        add("04-zera-claude-working", wait: 0.9) { self.settle(); self.zera.activity = .running }
        add("05-zera-needs-approval", wait: 0.9) { self.zera.activity = .approval }
        add("06-zera-sleepy") { self.zera.activity = .none; self.react(.sleepy, for: 3) }
        add("07-hover-hop", wait: 0.3) { self.settle(); self.zera.hovered = true; self.showPill() }
        add("07b-hover-notch-bar", wait: 0.9) {}
        add("08-closed-again", wait: 0.9) { self.zera.hovered = false; self.hidePill() }
        add("09-copy-colour-growing", wait: 0.08) { echo(.copyColour) }
        add("10-copy-colour", wait: 0.5) {}
        add("11-copy-text", wait: 0.55) { echo(.copyText) }
        add("12-paste", wait: 0.55) { echo(.paste) }
        add("13-cut", wait: 0.55) { echo(.cut) }
        add("14-undo", wait: 0.55) { echo(.undo) }
        add("15-save", wait: 0.55) { echo(.save) }
        add("16-caps-lock-on", wait: 0.55) { echo(.capsOn) }
        add("17-caps-lock-off", wait: 0.55) { echo(.capsOff) }
        add("18-shift-held", wait: 0.55) { echo(.shift) }
        add("19-volume", wait: 0.55) { echo(.volume) }
        add("20-brightness", wait: 0.55) { echo(.brightness) }
        add("21-mute", wait: 0.55) { echo(.mute) }
        add("22-light-music-wave", wait: 1.4) {
            self.reactLight(.music(active: true), tint: NSColor(srgbRed: 1, green: 0.45, blue: 0.3, alpha: 1))
        }
        add("23-light-battery-gauge", wait: 0.6) { self.reactLight(.music(active: false)); self.reactLight(.level(kind: .battery, value: 0.8)) }
        add("24-light-file-drag", wait: 1.2) { self.reactLight(.fileDrag(active: true)) }
        add("25-zera-says", wait: 0.8) { self.reactLight(.fileDrag(active: false)); self.say("hi from the notch 👋", mood: .hello, for: 3) }
        add("26-dictation-look", wait: 0.6) {
            self.settle()
            Dictation.shared.onTranscript?("ship the build tonight and")
        }
        add("27-rain-soon", wait: 0.6) {
            Dictation.shared.onTranscript?(nil)
            _ = present(EchoContent(symbol: "cloud.rain.fill", keys: "", text: "Rain soon", detail: "around 4:30 PM · 70%", tint: Pal.accent))
        }
        add("28-home-open", wait: 1.3, tall: true) {
            MainActor.assumeIsolated { CommandEcho.shared.dismissPresented() }
            self.show(.home)
        }
        // Every screen, for the design review.
        for (i, kind) in [CardKind.claude, .clipboard, .shelf, .tasks, .alerts, .reminders, .github, .settings, .focus, .teleprompter].enumerated() {
            add("28-\(String(format: "%02d", i))-screen-\(kind.title.lowercased().replacingOccurrences(of: " ", with: "-"))", wait: 1.1, tall: true) {
                self.show(kind)
            }
        }
        add("29-closed-final", wait: 1.0) { self.dismissCardByUser() }
        let savedMode = EdgeLight.shared.mode
        add("30-edge-top-volume-arms", wait: 0.5) {
            EdgeLight.shared.mode = .top
            echo(.volume)
        }
        add("31-edge-top-copy-sweep", wait: 0.3) { echo(.copyColour) }
        add("32-edge-screen-agent-wave", wait: 0.7, tall: true) {
            EdgeLight.shared.mode = .screen
            self.reactLight(.agentArrival)
        }
        add("33-edge-screen-approval-wave", wait: 0.7, tall: true) { self.reactLight(.approvalNeeded) }
        let savedStyle = EdgeLight.shared.style, savedEntrance = EdgeLight.shared.entrance
        for (i, st) in EdgeLightStyle.allCases.enumerated() {
            let slug = st.title.lowercased().replacingOccurrences(of: " ", with: "-")
            add("35-\(i)-style-\(slug)-brightness", wait: 0.5) {
                EdgeLight.shared.mode = .top
                EdgeLight.shared.entrance = .sweep
                EdgeLight.shared.style = st
                echo(.brightness)
            }
        }
        add("36-entrance-trace-prism", wait: 0.5) {
            EdgeLight.shared.style = .prism
            EdgeLight.shared.entrance = .trace
            echo(.copyColour)
        }
        add("37-entrance-burst-glow", wait: 0.2) {
            EdgeLight.shared.style = .glow
            EdgeLight.shared.entrance = .burst
            self.reactLight(.agentArrival)
        }
        add("38-screen-glitch-wave", wait: 0.8, tall: true) {
            EdgeLight.shared.mode = .screen
            EdgeLight.shared.entrance = .sweep
            EdgeLight.shared.style = .glitch
            self.reactLight(.notification)
        }
        add("39-murmur-intro", wait: 0.8, tall: true) {
            EdgeLight.shared.mode = savedMode
            MurmurIntroController.present()
        }
        add("39b-murmur-state", wait: 0.3) {
            MurmurIntroController.current?.close()
            log.append("murmur available: \(Murmur.isAvailable), state: \(Murmur.shared.state.summary), model: \(Murmur.shared.model.rawValue)")
        }
        add("40-done", wait: 1.2) {
            self.island.clearStickyLight()
            EdgeLight.shared.mode = savedMode
            EdgeLight.shared.style = savedStyle
            EdgeLight.shared.entrance = savedEntrance
        }

        func run(_ i: Int) {
            guard i < steps.count else {
                if let s = saved { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
                log.append("done: \(steps.count) steps")
                try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("tour.log"), atomically: true, encoding: .utf8)
                Self.touring = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                return
            }
            let step = steps[i]
            step.action()
            DispatchQueue.main.asyncAfter(deadline: .now() + step.wait) {
                log.append("\(step.name): \(self.tourCapture(step.name, tall: step.tall, dir: dir))")
                try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("tour.log"), atomically: true, encoding: .utf8)
                run(i + 1)
            }
        }
        run(0)
    }

    /// Zera's own visible windows around the notch, composited back to front over a painted
    /// desktop, menu bar and notch.
    private func tourCapture(_ name: String, tall: Bool, dir: URL) -> String {
        let n = geometry.notchRect
        let top = geometry.screen.frame.maxY
        let scr = geometry.screen.frame
        let height: CGFloat = tall ? scr.height : 260
        let region = NSRect(x: scr.minX, y: top - height, width: scr.width, height: height)
        let scale: CGFloat = 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(region.width * scale), height: Int(region.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no context" }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor(srgbRed: 0.16, green: 0.19, blue: 0.29, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: region.size))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.1).cgColor)
        ctx.fill(CGRect(x: 0, y: region.height - n.height, width: region.width, height: n.height))
        // The hardware notch (black, rounded at the bottom).
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: n.minX - region.minX, y: n.minY - region.minY, width: n.width, height: n.height + 20),
                           cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()
        let windows = NSApp.windows
            .filter { $0.isVisible && $0.alphaValue > 0.01 && $0.windowNumber > 0 && $0.frame.intersects(region) }
            .sorted { ($0.level.rawValue, -$0.orderedIndex) < ($1.level.rawValue, -$1.orderedIndex) }
        var drawn = 0
        for w in windows {
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(truncatingIfNeeded: w.windowNumber),
                                                    [.boundsIgnoreFraming, .bestResolution]) else { continue }
            let f = w.frame
            ctx.saveGState()
            ctx.setAlpha(w.alphaValue)
            ctx.draw(img, in: CGRect(x: f.minX - region.minX, y: f.minY - region.minY, width: f.width, height: f.height))
            ctx.restoreGState()
            drawn += 1
        }
        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "no image" }
        do {
            try png.write(to: dir.appendingPathComponent(name + ".png"))
            return "ok (\(drawn) windows)"
        } catch {
            return "write failed: \(error.localizedDescription)"
        }
    }
}
