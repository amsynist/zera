import AppKit
import ServiceManagement

/// Whether Zera keeps a Dock icon. On by default, so files can be dropped on it; off, she lives
/// only in the menu bar and at the notch. The bundle starts without one (LSUIElement), so there's
/// no icon flashing up at launch when it's off.
enum DockIcon {
    private static let key = "zera.showDockIcon"
    static var shown: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key); apply() }
    }
    static func apply() {
        let policy: NSApplication.ActivationPolicy = shown ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let wasActive = NSApp.isActive
        NSApp.setActivationPolicy(policy)
        // Changing it deactivates the app; keep Settings in front if that's where you were.
        if wasActive { DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: ZeraController!
    private var statusItem: NSStatusItem!
    private var showItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ControlFocusVisibility.install()
        // Regular (not accessory) so files can still be dropped on the Dock icon — unless you
        // turned the Dock icon off (Settings → General): then she lives in the menu bar and at the notch.
        DockIcon.apply()
        controller = ZeraController()
        buildMainMenu()
        BatteryAlerts.shared.start()
        // The alerts inbox listens from the start, so nothing that happens before you open
        // Alerts is missed. Command Echo, now playing and the weather are all event-driven.
        _ = AlertCenter.shared
        CommandEcho.shared.start()
        // Keyboard access is requested explicitly in Settings → Notch. Existing grants keep
        // working; a fresh launch should not stack privacy prompts over the welcome window.
        ShareShield.shared.start()
        WallpaperTint.shared.start()
        VoiceApproval.shared.start()
        Dictation.shared.start()
        Murmur.shared.start()
        AgentWatch.shared.start()
        WindowArrangementService.shared.startIfEnabled()
        LyricsService.shared.start()
        NowPlayingService.shared.start()
        WeatherService.shared.start()
        buildStatusItem()
        AndroidTransfer.shared.onTransferChange = { [weak self] in self?.controller.updateAndroidTransfer($0) }
        AndroidTransfer.shared.start()
        AndroidTransfer.shared.onStatusChange = { [weak self] in self?.refreshAndroidMenu() }
        if ProcessInfo.processInfo.environment["ZERA_ANDROP_PREVIEW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AndroidTransfer.shared.preview() }
        }
        refreshBadge()
        if let welcome = OnboardingWindowController.presentIfNeeded() {
            welcome.onFinish = { [weak self] in self?.controller.show(.home) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshBadge),
                                               name: ShelfStore.changed, object: nil)
        NSApp.dockTile.display()
        #if DEBUG
        // Opt-in review fixture: native feedback only, no system volume or clipboard writes.
        if ProcessInfo.processInfo.environment["ZERA_REVIEW_FEEDBACK"] == "volume" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Diag.log("review: pinned volume feedback scene")
                CommandEcho.shared.preview(.volume)
                if let content = CommandEcho.shared.currentFeedback {
                    CommandEcho.shared.present(content, hold: nil)
                    CommandEcho.shared.focusVisualReview()
                }
            }
        }
        #endif
    }

    // MARK: - Status item

    /// Programmatic AppKit apps do not get the application/Edit menus from a storyboard.
    /// Keep standard responder-chain commands available in every field and floating panel.
    private func buildMainMenu() {
        let main = NSMenu()
        let application = NSMenu(title: "Zera")
        application.addItem(withTitle: "About Zera", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        application.addItem(withTitle: "Welcome tour…", action: #selector(showWelcome), keyEquivalent: "").target = self
        application.addItem(.separator())
        let services = NSMenu(title: "Services")
        let serviceItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        serviceItem.submenu = services
        application.addItem(serviceItem)
        NSApp.servicesMenu = services
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Zera", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit Zera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Navigation", action: #selector(showNavigation), keyEquivalent: "").target = self
        view.addItem(withTitle: "Open an app…", action: #selector(showOpener), keyEquivalent: "").target = self
        view.addItem(.separator())
        for (title, action) in [("Home", #selector(showHome)), ("Agents", #selector(showClaude)),
                                ("Alerts", #selector(showAlerts)), ("Clipboard", #selector(showClipboard)),
                                ("Shelf", #selector(showShelf)), ("Reminders", #selector(showReminders)),
                                ("Focus", #selector(showFocus)), ("Teleprompter", #selector(showTeleprompter)),
                                ("Tasks", #selector(showTasks)), ("Pull requests", #selector(showGitHub)), ("Arrange windows (Beta)", #selector(showArrange))] {
            view.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        for menu in [application, edit, view] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = ZeraView.headImage(size: 20)
            img.isTemplate = false
            button.image = img
            button.imagePosition = .imageLeading
            button.toolTip = "Zera — she's up at the notch"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Say hello", action: #selector(sayHi), keyEquivalent: "").target = self
        // Hide her, or bring her back (say, after she tucked herself away for a full-screen app).
        showItem = menu.addItem(withTitle: "Hide Zera", action: #selector(toggleZera), keyEquivalent: "")
        showItem.target = self
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Navigation", action: #selector(showNavigation), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open an app…", action: #selector(showOpener), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Home", action: #selector(showHome), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Alerts", action: #selector(showAlerts), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Shelf", action: #selector(showShelf), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reminders", action: #selector(showReminders), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Focus", action: #selector(showFocus), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Teleprompter", action: #selector(showTeleprompter), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Tasks", action: #selector(showTasks), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pull requests", action: #selector(showGitHub), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Water this week…", action: #selector(showWaterWeek), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Welcome tour…", action: #selector(showWelcome), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Zera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let extras = NSMenuItem(title: "Extras", action: nil, keyEquivalent: "")
        extras.tag = 8988
        let extrasMenu = NSMenu(title: "Extras")
        extrasMenu.addItem(withTitle: "Manage Extras…", action: #selector(showExtras), keyEquivalent: "").target = self
        extrasMenu.addItem(withTitle: "Window Manager (Beta)…", action: #selector(showArrange), keyEquivalent: "").target = self
        extrasMenu.addItem(androidMenuItem())
        extras.submenu = extrasMenu
        menu.insertItem(extras, at: menu.numberOfItems - 1)
        statusItem.menu = menu
    }

    private func androidMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Android sharing", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: AndroidTransfer.shared.status, action: nil, keyEquivalent: "")
        status.tag = 89890; status.isEnabled = false
        menu.addItem(status)
        let toggle = menu.addItem(withTitle: "Receive from Android", action: #selector(toggleAndroidSharing), keyEquivalent: "")
        toggle.target = self; toggle.tag = 89891
        menu.addItem(withTitle: "Copy pairing code · \(AndroidTransfer.shared.pairingCode)", action: #selector(copyAndroidPairingCode), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open received files", action: #selector(openAndroidInbox), keyEquivalent: "").target = self
        let preview = menu.addItem(withTitle: "Preview arrival", action: #selector(previewAndroidArrival), keyEquivalent: "")
        preview.target = self; preview.tag = 89892
        root.submenu = menu
        root.tag = 8989
        return root
    }
    private func refreshAndroidMenu() {
        let service = AndroidTransfer.shared
        let menu = statusItem?.menu?.item(withTag: 8988)?.submenu?.item(withTag: 8989)?.submenu
        menu?.item(withTag: 89890)?.title = service.phoneConnected ? "Phone connected · \(service.status)" : service.status
        menu?.item(withTag: 89891)?.state = service.enabled ? .on : .off
        menu?.item(withTag: 89892)?.isEnabled = service.isRunning
    }
    @objc private func toggleAndroidSharing() {
        AndroidTransfer.shared.setEnabled(!AndroidTransfer.shared.enabled)
        refreshAndroidMenu()
    }
    @objc private func copyAndroidPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AndroidTransfer.shared.pairingCode, forType: .string)
    }
    @objc private func openAndroidInbox() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Androp", isDirectory: true))
    }
    @objc private func previewAndroidArrival() { AndroidTransfer.shared.preview() }

    @objc private func sayHi() { controller.greet() }
    @objc private func toggleZera() { controller.setZeraShowing(!controller.buddyEnabled) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAndroidMenu()
        showItem?.title = controller.buddyEnabled ? "Hide Zera" : "Bring Zera Back"
    }
    @objc private func showShelf() { controller.show(.shelf) }
    @objc private func showAlerts() { controller.show(.alerts) }
    @objc private func showFocus() { controller.show(.focus) }
    @objc private func showTeleprompter() { controller.show(.teleprompter) }
    @objc private func showTasks() { controller.show(.tasks) }
    @objc private func showWelcome() { OnboardingWindowController.present() }
    @objc private func showNavigation() { controller.showNavigation() }
    @objc private func showOpener() { controller.toggleOpener() }
    @objc private func showHome() { controller.show(.home) }
    @objc private func showClaude() { controller.show(.claude) }
    @objc private func showClipboard() { controller.show(.clipboard) }
    @objc private func showGitHub() { controller.show(.github) }
    @objc private func showReminders() { controller.show(.reminders) }
    @objc private func showSettings() { controller.show(.settings) }
    @objc private func showWaterWeek() { controller.showWaterWeek() }

    @objc private func refreshBadge() {
        let n = ShelfStore.shared.items.count
        statusItem?.button?.title = n > 0 ? " \(n)" : ""
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }


    // MARK: - Dock icon drops & reopen

    func application(_ application: NSApplication, open urls: [URL]) {
        controller.add(urls: urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        controller.add(urls: filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        controller.add(urls: [URL(fileURLWithPath: filename)])
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.toggleDefaultCard()
        return true
    }

    @objc private func showExtras() { controller.showExtras() }
    @objc private func showArrange() { controller.show(.arrange) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = WindowArrangementService.shared
        guard manager.enabled || manager.hiddenCount > 0 || manager.busy else { return .terminateNow }
        manager.prepareForTermination { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// No orphaned `claude` processes: stop any in-flight file analysis before quitting. A
    /// clipboard change still waiting for its debounced save is written now.
    func applicationWillTerminate(_ notification: Notification) {
        controller.prepareForTermination()
        TeleprompterStore.shared.flush()
        Dictation.shared.cancel(resumeApprovals: false)
        AndroidTransfer.shared.stop()
        CodexAgentService.shared.disconnect()
        ClaudeAgentService.shared.disconnectAll()
        MainActor.assumeIsolated { ZeraAssistant.shared.cancelAll() }
        ClipboardStore.shared.flush()
    }
}
