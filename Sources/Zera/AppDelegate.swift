import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ZeraController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular (not accessory) so files can still be dropped on the Dock icon.
        NSApp.setActivationPolicy(.regular)
        controller = ZeraController()
        controller.prewarmScreens()
        BatteryAlerts.shared.start()
        buildStatusItem()
        refreshBadge()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshBadge),
                                               name: ShelfStore.changed, object: nil)
        NSApp.dockTile.display()
    }

    // MARK: - Status item

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
        menu.addItem(withTitle: "Say Hi 👋", action: #selector(sayHi), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Home", action: #selector(showHome), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Shelf", action: #selector(showShelf), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reminders", action: #selector(showReminders), keyEquivalent: "").target = self
        menu.addItem(withTitle: "GitHub", action: #selector(showGitHub), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Zera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func sayHi() { controller.greet() }
    @objc private func showShelf() { controller.show(.shelf) }
    @objc private func showHome() { controller.show(.home) }
    @objc private func showGitHub() { controller.show(.github) }
    @objc private func showReminders() { controller.show(.reminders) }
    @objc private func showSettings() { controller.show(.settings) }

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// No orphaned `claude` processes: stop any in-flight file analysis before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { ZeraAssistant.shared.cancelAll() }
    }
}

