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
        // Sized the way TasksController sizes its panel.
        let focus = FocusCardView(store: tasks)
        focus.setFrameSize(NSSize(width: focus.frame.width, height: focus.desiredHeight))
        panel(focus, "19-focus-card")
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

    // MARK: Populated states

    /// A month of commit-made tasks across two projects, with the long repo names real work has.
    private func sampleMonth() -> TaskStore {
        let s = TaskStore(url: nil)
        let cal = Calendar.current
        let repos = ["portal-web-solutions", "portal-infrastructure", "database-migrations", "aurora-app"]
        let subjects = ["Fix the nightly export timing out on large studies", "Bump Datadog lambda extension and log sampling",
                        "Add CSV bill-of-materials endpoint", "Optimize Lambda images and cold starts",
                        "Restore sign-off flow after the auth refactor", "Normalize artifact spelling in the downloader"]
        for (n, name) in ["Aurora", "Website"].enumerated() {
            let p = s.addProject(name)
            s.link(p, to: "/tmp")
            var commits: [GitCommit] = []
            for d in 0..<12 {
                guard let day = cal.date(byAdding: .day, value: -(d * 2 + n), to: Date()) else { continue }
                for k in 0..<(1 + d % 3) {
                    let at = cal.date(bySettingHour: 10 + k * 2, minute: 0, second: 0, of: day) ?? day
                    commits.append(GitCommit(hash: String(format: "%010x", d * 10 + k + n * 1000), date: at,
                                             subject: subjects[(d + k + n) % subjects.count], body: "", repo: repos[(d + k + n) % repos.count]))
                }
            }
            s.importCommits(p, tasks: TaskGitSync.tasks(from: commits, project: p, calendar: cal, claude: false),
                            seen: commits.map(\.hash), through: Date())
        }
        s.add("Plan next sprint #Aurora 30m")
        return s
    }

    private func samplePRs() -> [GHPullRequest] {
        let now = Date()
        func person(_ l: String) -> GHPullRequest.Person { .init(login: l, avatar: nil) }
        var a = GHPullRequest(id: "acme/portal-web#6327", owner: "acme", repo: "portal-web", number: 6327,
            title: "Follow-up: direction-aware status axis in validateSubUploadStatusForm",
            author: person("rraj"), created: now.addingTimeInterval(-47 * 60), updated: now.addingTimeInterval(-5 * 60),
            url: URL(string: "https://github.com/acme/portal-web/pull/6327")!)
        a.branch = "fix-qa-shared-status-direction"; a.base = "dev"
        a.reviewers = [person("lbhatt"), person("theo")]; a.comments = 4
        a.additions = 13; a.deletions = 2; a.changedFiles = 1
        a.ci = .failed; a.checksTotal = 6
        a.failing = [.init(name: "PR Risk Assessment", title: "2 high-risk files changed", summary: "", url: nil),
                     .init(name: "unit-tests", title: "3 failed", summary: "", url: nil)]
        a.labels = ["qa", "follow-up"]; a.reviewRequested = true
        var b = GHPullRequest(id: "acme/aurora#412", owner: "acme", repo: "aurora", number: 412, title: "Add themes: seven built in, plus your own",
            author: person("you"), created: now.addingTimeInterval(-3 * 3600), updated: now.addingTimeInterval(-20 * 60),
            url: URL(string: "https://github.com/acme/aurora/pull/412")!)
        b.ci = .passed; b.review = .approved; b.approvedBy = ["theo"]; b.reviewers = [person("theo")]; b.mine = true
        b.additions = 812; b.deletions = 140; b.changedFiles = 22
        var c = GHPullRequest(id: "acme/infra#88", owner: "acme", repo: "infra", number: 88, title: "Bump strawberry-graphql and aiohttp",
            author: person("dependabot"), created: now.addingTimeInterval(-6 * 3600), updated: now.addingTimeInterval(-2 * 3600),
            url: URL(string: "https://github.com/acme/infra/pull/88")!)
        c.ci = .running; c.approvalsWaiting = 1
        return [a, b, c]
    }

    func testRenderPopulatedStates() throws {
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])

        // Pull requests: the list, and a PR's page.
        let prs = samplePRs()
        GitHubService.shared.preview(login: "you", pulls: prs)
        island(GitHubCard(), tab: .github, "21-pull-requests-list")
        let detail = GitHubCard()
        detail.openDetail(prs[0])
        island(detail, tab: .github, "22-pr-detail")

        // Claude sessions: running, waiting, done.
        func session(_ id: String, _ title: String, _ status: ClaudeSession.Status, _ ago: TimeInterval) -> ClaudeSession {
            let s = ClaudeSession(id: id, cwd: "/Users/you/\(id)", at: Date().addingTimeInterval(-ago))
            s.title = title; s.status = status; s.promptAt = Date().addingTimeInterval(-ago); s.branch = "main"
            return s
        }
        ClaudeActivityService.shared.preview([session("aurora", "Fix the theme picker", .running, 90),
                                              session("portal", "Why does the nightly export time out?", .waiting, 400),
                                              session("zera", "Write release notes for v0.1.4", .done, 3000)])
        island(ClaudeSessionsView(), tab: .claude, "23-claude-sessions")

        // Clipboard with a few kinds of copies.
        ClipboardStore.shared.preview([
            ClipItem(kind: .text, text: "Ship the theme picker before Friday — Theo has the review.", bytes: 60, sourceApp: "Slack", fingerprint: "a"),
            ClipItem(kind: .link, text: "https://github.com/amsynist/zera/pull/11", bytes: 40, sourceApp: "Safari", fingerprint: "b"),
            ClipItem(kind: .code, text: "swift test --filter ScreenRenderTests", bytes: 38, sourceApp: "Terminal", fingerprint: "c"),
            ClipItem(kind: .color, text: "#7AA2F7", bytes: 7, sourceApp: "Figma", fingerprint: "d")])
        island(ClipboardView(), tab: .clipboard, "24-clipboard")

        // Export, every format, on a month of commit work.
        let month = sampleMonth()
        for (i, f) in TaskExport.Format.allCases.enumerated() {
            let v = TaskExportView(store: month)
            v.frame = NSRect(origin: .zero, size: TaskExportView.size)
            v.span = .all
            v.format = f
            panel(v, "2\(5 + i)-export-\(f.title.lowercased())")
        }
        // Tasks, the week view.
        UserDefaults.standard.set(1, forKey: "tasks.viewSpan")
        island(TasksCard(store: month), tab: .tasks, "29-tasks-week")
        UserDefaults.standard.set(0, forKey: "tasks.viewSpan")
    }
}
