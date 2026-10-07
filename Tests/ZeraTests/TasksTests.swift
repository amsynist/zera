import AppKit
import XCTest
@testable import Zera

final class TasksTests: XCTestCase {
    /// 7 Oct 2026, 9:00 here, with a clock the test moves by hand.
    private var clock = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9))!

    private func store() -> TaskStore {
        let s = TaskStore(url: nil)
        s.now = { [unowned self] in self.clock }
        s.idleSeconds = { 0 }
        return s
    }

    /// A day's worth: two finished, one in focus 24 min in, two waiting.
    private func sampleDay() -> TaskStore {
        let s = store()
        let fix = s.add("Fix ⌘K arrow keys 20m")!
        s.focusOn(fix.id); clock += 18 * 60; s.toggleDone(fix.id)
        let readme = s.add("Record README videos 30m")!
        s.focusOn(readme.id); clock += 41 * 60; s.toggleDone(readme.id)
        let ship = s.add("Ship the Tasks menu 45m")!
        s.add("Review pull request #8 20m")
        s.add("Reply to design feedback 15m")
        s.focusOn(ship.id); clock += 24 * 60 + 10
        return s
    }

    func testQuickAddReadsAnEstimateOffTheEnd() {
        XCTAssertEqual(TaskStore.parse("Write docs 30m").0, "Write docs")
        XCTAssertEqual(TaskStore.parse("Write docs 30m").1, 30)
        XCTAssertEqual(TaskStore.parse("Deploy 1h30m").1, 90)
        XCTAssertEqual(TaskStore.parse("Deploy 2h").1, 120)
        XCTAssertEqual(TaskStore.parse("Call mum 15 min").1, 15)
        XCTAssertNil(TaskStore.parse("Read chapter 3").1, "a number that isn't a time stays in the title")
        XCTAssertEqual(TaskStore.parse("Read chapter 3").0, "Read chapter 3")
        XCTAssertNil(TaskStore.parse("30m").1, "a time alone is the title, not an empty task")
    }

    func testTheTimeYouTypeBecomesTheEstimate() {
        let s = store()
        for (typed, title, est) in [("Write docs 30m", "Write docs", 30), ("write docs 30 m", "write docs", 30), ("Deploy 1h", "Deploy", 60),
                                    ("Fix bug #zera 45m", "Fix bug", 45), ("Fix bug 45m #zera", "Fix bug", 45), ("Plan 1.5h", "Plan", 90),
                                    ("Write docs 30m ", "Write docs", 30), ("Write docs 30mins", "Write docs", 30)] {
            let t = s.add(typed)
            XCTAssertEqual(t?.title, title, typed)
            XCTAssertEqual(t?.estimate, est, typed)
            XCTAssertEqual(s.tasks.last?.estimate, est, "saved: " + typed)
        }
        XCTAssertEqual(s.add("Read the spec")?.estimate, 0, "no time typed: no made-up estimate")
    }

    func testFocusTimeAddsUpPausesAndFinishes() {
        let s = store()
        let a = s.add("Write docs 30m", focus: true)!
        XCTAssertTrue(s.isRunning)
        clock += 300
        XCTAssertEqual(s.spent(s.focus!), 300, accuracy: 0.5)
        XCTAssertEqual(s.progress, 300 / 1800, accuracy: 0.001)
        s.pause()
        clock += 600
        XCTAssertEqual(s.spent(s.tasks[0]), 300, accuracy: 0.5, "no time while paused")
        s.togglePause()
        clock += 60
        s.toggleDone(a.id)
        XCTAssertFalse(s.isRunning)
        XCTAssertNil(s.focus)
        XCTAssertEqual(s.tasks[0].spent, 360, accuracy: 0.5)
        XCTAssertEqual(s.focusedToday, 360, accuracy: 0.5)
        XCTAssertEqual(s.doneToday.count, 1)
    }

    func testNextMovesFocusAlongAndWalkingAwayPauses() {
        let s = store()
        let a = s.add("One")!, b = s.add("Two")!
        s.focusOn(a.id)
        s.next()
        XCTAssertEqual(s.focusID, b.id)
        s.next()
        XCTAssertEqual(s.focusID, a.id, "wraps round")
        clock += 600
        s.idleSeconds = { 400 }
        var paused: FocusTask?
        s.onIdlePause = { paused = $0 }
        s.tick()
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(paused?.id, a.id)
        XCTAssertEqual(s.spent(s.tasks[0]), 200, accuracy: 0.5, "the time away isn't counted")
    }

    func testTasksSurviveARelaunchPaused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zera-tasks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = TaskStore(url: url)
        s.now = { [unowned self] in self.clock }
        s.idleSeconds = { 0 }
        let t = s.add("Write docs 30m", focus: true)!
        clock += 120
        s.flush()
        let again = TaskStore(url: url)
        again.now = { [unowned self] in self.clock }
        XCTAssertEqual(again.tasks.map(\.title), ["Write docs"])
        XCTAssertEqual(again.focusID, t.id)
        XCTAssertFalse(again.isRunning, "a session from before a quit comes back paused")
        XCTAssertEqual(again.tasks[0].spent, 120, accuracy: 0.5)
    }

    func testExportGroupsByDateWithNumbersAndMinutes() {
        let s = sampleDay()
        let rows = TaskExport.rows(s, span: .today)
        XCTAssertEqual(rows.map(\.title), ["Fix ⌘K arrow keys", "Record README videos", "Ship the Tasks menu",
                                           "Review pull request #8", "Reply to design feedback"])
        XCTAssertEqual(rows.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(rows.map(\.minutes), [18, 41, 24, 0, 0])
        XCTAssertEqual(rows.map(\.status), ["Done", "Done", "Open", "Open", "Open"])
        let text = TaskExport.text(rows)
        XCTAssertTrue(text.hasPrefix("Wed, 7 Oct 2026\n  1. Fix ⌘K arrow keys ✓ 18m\n  2. Record README videos ✓ 41m\n  3. Ship the Tasks menu · 24m"), text)
        let csv = TaskExport.csv(rows)
        XCTAssertTrue(csv.hasPrefix("Date,#,Project,Repo,Task,Status,Minutes,Estimate\r\n2026-10-07,1,General,,Fix ⌘K arrow keys,Done,18,20\r\n"), csv)
        XCTAssertEqual(TaskExport.csv([TaskExport.Row(day: "2026-10-07", date: clock, index: 1, project: "General", title: "Say \"hi\", then go",
                                                       done: false, minutes: 1, estimate: 5)]).split(separator: "\r\n").last,
                       "2026-10-07,1,General,,\"Say \"\"hi\"\", then go\",Open,1,5")
        XCTAssertEqual(TaskExport.tsv(rows).split(separator: "\n").count, 6)
    }

    func testProjectsFileTasksFilterAndExportSeparately() {
        let s = store()
        XCTAssertEqual(s.projects, ["General"])
        let a = s.add("Write docs #Zera 30m")!
        XCTAssertEqual(a.title, "Write docs")
        XCTAssertEqual(a.estimate, 30)
        XCTAssertEqual(s.project(of: a), "Zera")
        let b = s.add("Invoice #zera")!
        XCTAssertEqual(s.project(of: b), "Zera", "the same project, whatever the case")
        let c = s.add("Call the bank")!
        XCTAssertEqual(s.project(of: c), "General", "no tag: the default")
        XCTAssertEqual(s.add("Review PR #8")?.title, "Review PR #8", "a number isn't a project")
        s.addProject("Client work")
        let d = s.add("Kickoff deck", project: "Client work")!
        XCTAssertEqual(s.project(of: d), "Client work")
        XCTAssertEqual(s.projects, ["General", "Zera", "Client work"])
        XCTAssertEqual(s.today(in: "Zera").map(\.title), ["Write docs", "Invoice"])
        XCTAssertEqual(s.today(in: "General").map(\.title), ["Call the bank", "Review PR #8"])

        s.setDefaultProject("Zera")
        XCTAssertEqual(s.project(of: s.add("Fix tests")!), "Zera")
        XCTAssertTrue(s.renameProject("Zera", to: "Zera app"))
        XCTAssertEqual(s.defaultProject, "Zera app")
        XCTAssertEqual(s.project(of: s.tasks[0]), "Zera app")
        XCTAssertFalse(s.renameProject("Zera app", to: "general"), "taken")
        s.deleteProject("Client work")
        XCTAssertEqual(s.project(of: s.tasks.first { $0.title == "Kickoff deck" }!), "Zera app", "its tasks move to the default")
        s.deleteProject("Zera app")
        XCTAssertTrue(s.projects.contains("Zera app"), "the default can't be deleted")

        let rows = TaskExport.rows(s, span: .today, project: "General")
        XCTAssertEqual(rows.map(\.title), ["Call the bank", "Review PR #8"])
        XCTAssertTrue(TaskExport.text(rows, project: "General").hasPrefix("General\n\nWed, 7 Oct 2026\n  1. Call the bank"))
        XCTAssertTrue(TaskExport.text(TaskExport.rows(s, span: .today)).contains("Call the bank [General]"), "mixed: each task tagged")
        XCTAssertEqual(TaskExport.fileName(.today, .csv, project: "A/B", now: clock), "Tasks A-B 2026-10-07.csv")
    }

    func testXlsxIsAZipThatUnpacksToTheSheet() throws {
        let rows = TaskExport.rows(sampleDay(), span: .all)
        let data = TaskExport.xlsx(rows)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zera-xlsx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.xlsx")
        try data.write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", "-t", file.path]
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "the archive tests clean")
        let u = Process()
        u.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        u.arguments = ["-q", file.path, "-d", dir.path]
        try u.run(); u.waitUntilExit()
        let sheet = try String(contentsOf: dir.appendingPathComponent("xl/worksheets/sheet1.xml"))
        XCTAssertTrue(sheet.contains("Ship the Tasks menu"))
        XCTAssertTrue(sheet.contains("<c r=\"G2\"><v>18</v></c>"), "minutes are numbers")
        XCTAssertNotNil(try? XMLDocument(data: Data(sheet.utf8)), "the sheet is well-formed XML")
    }

    func testCardButtonsKeepTheirWordsInside() {
        let s = sampleDay()
        s.pause()
        let card = FocusCardView(store: s)
        card.frame = NSRect(origin: .zero, size: NSSize(width: card.frame.width, height: card.desiredHeight))
        card.layoutSubtreeIfNeeded()
        func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
        let buttons = all(card).compactMap { $0 as? TreeButton }.filter { !$0.isHidden }
        XCTAssertEqual(buttons.map(\.title), ["Resume", "Done", "Next"])
        for b in buttons { XCTAssertGreaterThanOrEqual(b.frame.width, b.fittedWidth - 0.5, b.title) }
    }

    func testTimesheetRoundsToQuartersAndCopiesADay() {
        XCTAssertEqual([0, 4, 8, 22, 23, 44, 52].map { TaskExport.minutes($0, round: true) }, [0, 15, 15, 15, 30, 45, 45])
        XCTAssertEqual(TaskExport.minutes(44, round: false), 44)
        let d = clock
        let rows = [TaskExport.Row(day: "2026-10-07", date: d, index: 1, project: "VIDA", repo: "cerebrum", title: "Fix stage tests", done: true, minutes: 44, estimate: 30),
                    TaskExport.Row(day: "2026-10-07", date: d, index: 2, project: "VIDA", title: "Plan sprint", done: false, minutes: 0, estimate: 30)]
        XCTAssertEqual(TaskExport.dayText(rows, .init()), "• Fix stage tests\n• Plan sprint", "just what was done, by default")
        XCTAssertEqual(TaskExport.dayText(rows, .init(times: true, repos: true, round: true)),
                       "• Fix stage tests (cerebrum) — 45m\n• Plan sprint — 0m")
        XCTAssertEqual(TaskExport.sheetText(rows, .init()), "Wed 7 Oct 2026 · 45m\n• Fix stage tests\n• Plan sprint\n")
    }

    func testLastMonthIsThePreviousCalendarMonth() {
        let s = store()
        let p = s.addProject("VIDA")
        s.link(p, to: "/tmp")
        let sep = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10))!
        let made = TaskGitSync.tasks(from: [GitCommit(hash: "abcdef1000", date: sep, subject: "Fix stage tests", body: "", repo: "cerebrum")],
                                     project: p, calendar: .current, claude: false)
        s.importCommits(p, tasks: made, seen: ["abcdef1000"], through: clock)
        s.add("Today's thing")
        XCTAssertEqual(TaskExport.rows(s, span: .lastMonth).map(\.title), ["Fix stage tests"])
        XCTAssertEqual(TaskExport.rows(s, span: .lastMonth).first?.repo, "cerebrum", "where it came from")
        XCTAssertTrue(TaskExport.text(TaskExport.rows(s, span: .lastMonth)).contains("Fix stage tests [cerebrum]"))
        XCTAssertEqual(TaskExport.rows(s, span: .month).map(\.title), ["Today's thing"])
        XCTAssertEqual(s.tasks.first { $0.fromCommits }?.commitNotes, ["cerebrum · abcdef1 · Fix stage tests"])
        XCTAssertEqual(TasksCard.whatWasDone("portal-utils · 5b62e36 · feat: shorten expiry · and more"), "Shorten expiry · and more", "no repo, no hash, no prefix")
    }

    func testARebuildSwapsTasksInOneStep() {
        let s = store()
        let p = s.addProject("VIDA")
        s.link(p, to: "/tmp")
        let day = clock.addingTimeInterval(-2 * 86400)
        func make(_ subject: String, _ hash: String) -> [FocusTask] {
            TaskGitSync.tasks(from: [GitCommit(hash: hash, date: day, subject: subject, body: "")], project: p, calendar: .current, claude: false)
        }
        s.importCommits(p, tasks: make("Old title", "1111111aaa"), seen: ["1111111aaa"], through: clock)
        let mine = s.add("Written by hand")!
        let since = Calendar.current.startOfDay(for: clock.addingTimeInterval(-7 * 86400))
        s.importCommits(p, tasks: make("New title", "1111111aaa"), seen: ["1111111aaa"], through: clock, replacing: since)
        XCTAssertEqual(s.tasks.filter(\.fromCommits).map(\.title), ["New title"], "the old commit task is replaced, not doubled")
        XCTAssertTrue(s.tasks.contains { $0.id == mine.id }, "your own tasks stay")
    }

    // MARK: Pictures (ZERA_RENDER=<folder> swift test --filter TasksTests/testRender)

    func testRender() throws {
        guard let out = ProcessInfo.processInfo.environment["ZERA_RENDER"] else { throw XCTSkip("set ZERA_RENDER to render") }
        let s = sampleDay()
        func shot(_ v: NSView, _ name: String) {
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: v.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
            // Light enough that a clipped glow would show as a square edge.
            w.backgroundColor = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.62, alpha: 1)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = v
            w.orderFrontRegardless()
            v.layoutSubtreeIfNeeded()
            v.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), .bestResolution) {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent(name + ".png"))
            }
            w.orderOut(nil)
        }
        s.add("Kickoff deck #Client_work 40m")
        s.add("Invoice October #Client_work 15m")
        s.move(s.tasks[0].id, to: s.addProject("Zera"))
        s.move(s.tasks[1].id, to: "Zera")
        s.move(s.tasks[2].id, to: "Zera")
        let list = TasksCard(store: s)
        list.frame = NSRect(x: 0, y: 0, width: list.cardWidth, height: list.desiredHeight)
        let isle = OpenerGlass(frame: NSRect(x: 0, y: 0, width: list.cardWidth + 40, height: list.desiredHeight + 40))
        isle.radius = 30
        list.frame.origin = NSPoint(x: 20, y: 20)
        isle.addSubview(list)
        shot(isle, "list")
        s.link("Zera", to: "/tmp")
        TaskGitSync.shared.progress = ["Zera": SyncProgress(stage: "Grouping commits", done: 2, total: 5)]
        s.shownProject = "Zera"
        let syncing = TasksCard(store: s)
        syncing.frame = NSRect(x: 20, y: 20, width: syncing.cardWidth, height: syncing.desiredHeight)
        NotificationCenter.default.post(name: TaskGitSync.progressChanged, object: nil)
        let isle2 = OpenerGlass(frame: NSRect(x: 0, y: 0, width: syncing.cardWidth + 40, height: syncing.desiredHeight + 40))
        isle2.radius = 30
        isle2.addSubview(syncing)
        shot(isle2, "list-syncing")
        TaskGitSync.shared.progress = [:]
        s.shownProject = nil
        // Month view: done tasks by date, one commit task opened to show its commits.
        let back = clock.addingTimeInterval(-6 * 86400)
        let cs = [GitCommit(hash: "5b62e36000", date: back, subject: "PORT-10097: shorten credential expiry", body: "", repo: "portal-utils"),
                  GitCommit(hash: "bb91d17000", date: back.addingTimeInterval(1500), subject: "PORT-10097: gate on PORTAL_BRANCH", body: "", repo: "portal-infrastructure")]
        var made = TaskGitSync.tasks(from: cs, project: "Zera", calendar: .current, claude: false)
        made[0].title = "Add credential expiry test hooks"
        made[0].commits = cs.map(\.short)
        made[0].commitNotes = cs.map { "\($0.repo) · \($0.short) · \($0.subject)" }
        made[0].log = [made[0].log.keys.first!: 3300]
        s.importCommits("Zera", tasks: [made[0]], seen: [], through: clock)
        UserDefaults.standard.set(2, forKey: "tasks.viewSpan")
        let month = TasksCard(store: s)
        month.frame = NSRect(x: 20, y: 20, width: month.cardWidth, height: month.desiredHeight)
        month.layoutSubtreeIfNeeded()
        func rowsOf(_ v: NSView) -> [TaskRowView] { v.subviews.flatMap { ($0 as? TaskRowView).map { [$0] } ?? rowsOf($0) } }
        rowsOf(month).first { $0.task.fromCommits }?.onExpand?()
        month.frame.size.height = month.desiredHeight
        let isle3 = OpenerGlass(frame: NSRect(x: 0, y: 0, width: month.cardWidth + 40, height: month.desiredHeight + 40))
        isle3.radius = 30
        isle3.addSubview(month)
        shot(isle3, "list-month")
        UserDefaults.standard.removeObject(forKey: "tasks.viewSpan")
        let card = FocusCardView(store: s)
        card.frame.size.height = card.desiredHeight
        shot(card, "card")
        s.pause()
        let paused = FocusCardView(store: s)
        paused.frame.size.height = paused.desiredHeight
        shot(paused, "card-paused")
        s.resume()
        let orb = FocusOrbView(store: s)
        shot(orb, "orb")
        let calm = sampleDay()
        calm.toggleDone(calm.focusID!)
        for t in calm.open { calm.toggleDone(t.id) }
        shot(FocusOrbView(store: calm), "orb-done")
        let none = FocusCardView(store: calm)
        none.frame.size.height = none.desiredHeight
        shot(none, "card-none")
        let menu = NeonMenuView(frame: NSRect(x: 0, y: 0, width: 250, height: 312))
        menu.items = [.action("Pause", "pause.fill") {}, .action("Mark as Done", "checkmark.circle") {}, .separator, .header("MOVE TO"),
                      .action("General", "folder") {}, .action("Zera", "folder", checked: true) {}, .separator,
                      .info("From abc1234, def5678", "arrow.triangle.branch"), .separator, .action("Delete", "trash", destructive: true) {}]
        menu.cursor = 1
        shot(menu, "menu")
                let quick = QuickAddView()
        shot(quick, "quick")
        shot(OrbPlusView(), "plus")
        let keep = TaskExport.SheetOptions.saved
        TaskExport.SheetOptions.saved = .init()
        let ex = TaskExportView(store: s)
        TaskExport.SheetOptions.saved = keep
        shot(ex, "export")
        let was = TaskExport.SheetOptions.saved
        TaskExport.SheetOptions.saved = .init(times: true, repos: true, round: true)
        let exTimes = TaskExportView(store: s)
        shot(exTimes, "export-times")
        TaskExport.SheetOptions.saved = was
        ex.format = .text
        shot(ex, "export-text")
    }
}
