import AppKit
import XCTest
@testable import Zera

/// Renders every screen to PNGs so the UI can be reviewed without running the app:
/// `ZERA_RENDER_SCREENS=/some/folder swift test --filter ScreenRenderTests`.
/// CI's render job runs this on every pull request and publishes the images.
@MainActor
final class ScreenRenderTests: XCTestCase {
    private var out: URL!
    private let band: CGFloat = 34
    private let desk = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1)

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["ZERA_RENDER_SCREENS"] else { throw XCTSkip("set ZERA_RENDER_SCREENS to render") }
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    // MARK: Capturing

    private func shot(_ v: NSView, _ name: String) {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: v.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = desk
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = v
        w.orderFrontRegardless()
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        v.display()
        // Let fades, springs and the tab pill settle.
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        v.display()
        var data: Data?
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), .bestResolution) {
            data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        if data == nil, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        try? data?.write(to: out.appendingPathComponent(name + ".png"))
        w.orderOut(nil)
    }

    /// A screen inside the real island: glass, edge, the tab bar in the notch band.
    private func island(_ screen: NSView & CardContent, tab: CardKind?, _ name: String) {
        screen.frame = NSRect(x: 0, y: 0, width: screen.cardWidth, height: 400)
        screen.layoutSubtreeIfNeeded()
        let h = min(screen.desiredHeight, Isle.maxContentHeight)
        let width = Isle.maxWidth + 120
        let iv = IslandView(frame: NSRect(x: 0, y: 0, width: width, height: band + h + 40))
        iv.band = band
        iv.notchWidth = 190
        iv.centerX = width / 2
        iv.present(screen, size: NSSize(width: screen.cardWidth, height: h), direction: 0, animated: false)
        iv.activeTab = tab
        shot(iv, name)
    }

    private func panel(_ v: NSView, _ name: String) { shot(v, name) }

    // MARK: Sample data

    private func sampleTasks() -> TaskStore {
        let s = TaskStore(url: nil)
        s.add("Ship the dark mode toggle #Aurora 45m")
        s.add("Review Theo's avatar cache PR #Aurora 20m")
        s.add("Write the launch post #Website 30m")
        s.add("Plan next sprint")
        return s
    }

    private func sampleShelf() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zera-render-shelf", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("Q3 report.pdf"); try Data("%PDF-1.4\n".utf8).write(to: pdf)
        let note = dir.appendingPathComponent("Note 7 Oct.txt"); try Data("Ship the theme picker before Friday.".utf8).write(to: note)
        let link = dir.appendingPathComponent("Zera releases.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://github.com/amsynist/zera/releases"], format: .xml, options: 0).write(to: link)
        let img = NSImage(size: NSSize(width: 64, height: 40))
        img.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 64, height: 40).fill(); img.unlockFocus()
        let png = dir.appendingPathComponent("hero-shot.png")
        if let tiff = img.tiffRepresentation, let p = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try p.write(to: png) }
        _ = ShelfStore.shared.add(urls: [pdf, png, note, link])
    }

    // MARK: Renders

    func testRenderEveryScreen() throws {
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])
        let tasks = sampleTasks()

        island(HomeCard(), tab: .home, "01-home")
        island(ClaudeSessionsView(), tab: .claude, "02-claude")
        island(DropFilesView(), tab: .shelf, "03-shelf-empty")
        try sampleShelf()
        let shelf = DropFilesView()
        island(shelf, tab: .shelf, "04-shelf")
        let detail = DropFilesView()
        detail.setExpanded(true)
        island(detail, tab: .shelf, "05-shelf-file")
        island(ClipboardView(), tab: .clipboard, "06-clipboard")
        island(TasksCard(store: tasks), tab: .tasks, "07-tasks")
        island(GitHubCard(), tab: .github, "08-pull-requests")
        island(RemindersView(), tab: .reminders, "09-reminders")
        let settings = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        island(settings, tab: .settings, "10-settings-general")
        let appearance = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        appearance.select(.appearance)
        island(appearance, tab: .settings, "11-settings-appearance")
        let claudePane = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        claudePane.select(.claude)
        island(claudePane, tab: .settings, "12-settings-claude")

        // Banners: a meeting with a call link (the one that was cut off), and a PR toast.
        ReminderService.shared.preview(ReminderAlert(id: "render-meeting", kind: .calendarHeadsUp,
            headline: "You have a meeting in 5 minutes", detail: "Review discussion on the Q3 roadmap · 3:00 PM",
            eventID: "render", joinURL: URL(string: "https://meet.example.com/abc")))
        island(ReminderAlertCard(), tab: .reminders, "13-banner-meeting")
        ReminderService.shared.preview(ReminderAlert(id: "render-water", kind: .now, headline: "Drink water",
            detail: "Every 2 hours · next 1:00 PM", hydration: true))
        island(ReminderAlertCard(), tab: nil, "14-banner-water")
        let toast = ToastCard()
        toast.show(event: GHEvent(id: "render", kind: .prOpened, title: "Add themes: seven built in, plus your own",
            subtitle: "amsynist/zera #11", date: Date(), url: URL(string: "https://example.com/pr/11")!, approval: nil))
        island(toast, tab: nil, "15-banner-pr")

        // The Claude wings.
        let session = ClaudeSession(id: "render", cwd: "/Users/you/aurora", at: Date())
        session.title = "Fix the theme picker"
        session.status = .running
        session.promptAt = Date().addingTimeInterval(-90)
        let wings = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        wings.centerX = LiveActivityView.panelSize.width / 2
        wings.update(session: session, pending: HookRequest(id: "r", receivedAt: Date(), sessionID: session.id, toolName: "Bash",
            command: "npm test -- --watch=false", detail: nil, cwd: "/Users/you/aurora"))
        panel(wings, "16-wings-approval")
        let running = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        running.centerX = LiveActivityView.panelSize.width / 2
        running.update(session: session, pending: nil)
        panel(running, "17-wings-running")

        // Floating panels.
        let export = TaskExportView(store: tasks)
        export.frame = NSRect(origin: .zero, size: TaskExportView.size)
        panel(export, "18-export")
        panel(FocusCardView(store: tasks), "19-focus-card")
        let opener = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 860, height: 760))
        opener.prepare()
        panel(opener, "20-app-opener")

        // Every theme on two busy screens.
        for t in ThemeStore.shared.builtIns {
            ThemeStore.shared.select(t)
            island(HomeCard(), tab: .home, "theme-\(t.id)-home")
            island(TasksCard(store: tasks), tab: .tasks, "theme-\(t.id)-tasks")
        }
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])
    }
}
