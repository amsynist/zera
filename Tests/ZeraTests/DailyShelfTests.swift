import AppKit
import XCTest
@testable import Zera

final class DailyShelfRulesTests: XCTestCase {
    func testFilesKnownLinksByRule() {
        let pr = DailyShelfRules.match(URL(string: "https://github.com/aurora/aurora-web/pull/214/files")!)
        XCTAssertEqual(pr?.kind, .pr)
        XCTAssertEqual(pr?.pr?.repo, "aurora-web")
        XCTAssertEqual(pr?.pr?.number, 214)
        XCTAssertEqual(DailyShelfRules.match(URL(string: "https://aurora.atlassian.net/browse/AUR-142")!)?.jiraKey, "AUR-142")
        XCTAssertEqual(DailyShelfRules.match(URL(string: "https://aurora.atlassian.net/jira/software/projects/AUR/boards/1?selectedIssue=AUR-9")!)?.jiraKey, "AUR-9")
        XCTAssertEqual(DailyShelfRules.match(URL(string: "https://aurora.atlassian.net/wiki/spaces/ENG/pages/1")!)?.kind, .doc)
        XCTAssertEqual(DailyShelfRules.match(URL(string: "https://docs.google.com/document/d/abc/edit")!)?.kind, .doc)
        XCTAssertEqual(DailyShelfRules.match(URL(string: "https://meet.google.com/abc-defg-hij")!)?.kind, .meeting)
        XCTAssertEqual(DailyShelfRules.match(URL(string: "https://us02web.zoom.us/j/123")!)?.kind, .meeting)
        XCTAssertNil(DailyShelfRules.match(URL(string: "https://github.com/aurora/aurora-web/issues/3")!))
        XCTAssertNil(DailyShelfRules.match(URL(string: "https://vercel.com/aurora")!))
    }

    func testLearnedHostsWinOverClaude() {
        let m = DailyShelfRules.match(URL(string: "https://www.vercel.com/aurora/deployments")!, learned: ["vercel.com": "Dashboards"])
        XCTAssertEqual(m?.kind, .site)
        XCTAssertEqual(m?.category, "Dashboards")
    }

    func testOnlyWebLinksCount() {
        XCTAssertNotNil(DailyShelfRules.link(in: "  https://example.com/a  "))
        XCTAssertNil(DailyShelfRules.link(in: "deploy at 4"))
        XCTAssertNil(DailyShelfRules.link(in: "file:///etc/hosts"))
        XCTAssertNil(DailyShelfRules.link(in: "https://example.com/a b"))
        XCTAssertTrue(DailyShelfRules.looksLikeCommand("gh pr checkout 214"))
        XCTAssertFalse(DailyShelfRules.looksLikeCommand("Ping Maya before merging"))
    }

    func testFallbackTitleReadsThePath() {
        XCTAssertEqual(DailyShelfRules.fallbackTitle(for: URL(string: "https://swift.org/blog/swift-6-2-released")!), "Swift 6 2 released · swift.org")
        XCTAssertEqual(DailyShelfRules.fallbackTitle(for: URL(string: "https://www.figma.com/")!), "figma.com")
    }

    func testPullRequestsGroupByWhatYouNeedToDo() {
        var g = DailyShelfPR(owner: "a", repo: "b", number: 1)
        g.ci = .failing; g.failing = 2
        XCTAssertEqual(DailyShelfPRStatus.of(g).group, .yourMove)
        XCTAssertEqual(DailyShelfPRStatus.of(g).label, "2 failing")
        g.ci = .passed; g.review = .changesRequested
        XCTAssertEqual(DailyShelfPRStatus.of(g).group, .yourMove)
        g.review = .requested
        XCTAssertEqual(DailyShelfPRStatus.of(g).label, "Your review")
        g.review = .approved
        XCTAssertEqual(DailyShelfPRStatus.of(g).group, .ready)
        g.ci = .running
        XCTAssertEqual(DailyShelfPRStatus.of(g).group, .waiting)
        g.draft = true
        XCTAssertEqual(DailyShelfPRStatus.of(g).label, "Draft")
        g.state = .merged
        XCTAssertEqual(DailyShelfPRStatus.of(g).group, .done)
    }
}

final class DailyShelfDayTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; return c }()
    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.timeZone = cal.timeZone; f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return f.date(from: s)!
    }

    func testDayTurnsOverAtTheRolloverHour() {
        XCTAssertEqual(DailyShelfClock.dayKey(for: date("2026-11-07T03:59:00"), rolloverHour: 4, calendar: cal), "2026-11-06")
        XCTAssertEqual(DailyShelfClock.dayKey(for: date("2026-11-07T04:00:00"), rolloverHour: 4, calendar: cal), "2026-11-07")
        XCTAssertEqual(DailyShelfClock.dayKey(for: date("2026-11-07T00:30:00"), rolloverHour: 0, calendar: cal), "2026-11-07")
    }

    func testPinnedAndOpenPRsStayTheRestLeave() {
        var pinned = DailyShelfItem(kind: .site, url: "https://a.com", title: "A", category: "Websites", categorySource: .rule); pinned.pinned = true
        var open = DailyShelfItem(kind: .pr, url: "https://github.com/a/b/pull/1", title: "PR", category: "Pull requests", categorySource: .rule)
        open.github = DailyShelfPR(owner: "a", repo: "b", number: 1)
        var merged = open; merged.id = UUID(); merged.github?.state = .merged
        let site = DailyShelfItem(kind: .site, url: "https://b.com", title: "B", category: "Websites", categorySource: .rule)
        let r = DailyShelfClock.carryOver([pinned, open, merged, site], carryOpenPRs: true)
        XCTAssertEqual(Set(r.kept.map(\.id)), [pinned.id, open.id])
        XCTAssertEqual(r.kept.first { $0.id == open.id }?.carried, true)
        XCTAssertNil(r.kept.first { $0.id == pinned.id }?.carried)
        XCTAssertEqual(DailyShelfClock.carryOver([pinned, open], carryOpenPRs: false).kept.map(\.id), [pinned.id])
    }
}

@MainActor
final class DailyShelfStoreTests: XCTestCase {
    private var folder: URL!
    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("zera-daily-shelf-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder); super.tearDown() }

    private func store(at d: Date, carry: Bool = true) -> DailyShelfStore {
        var s = DailyShelfSettings(); s.carryOpenPRs = carry; s.sortWithClaude = true
        return DailyShelfStore(folder: folder, now: d, settings: { s })
    }

    func testAddsOnceAndWritesTodaysJSON() throws {
        let now = Date()
        let st = store(at: now)
        let a = st.add(link: URL(string: "https://github.com/aurora/infra/pull/91/files#diff")!, title: nil)
        XCTAssertTrue(a.isNew)
        XCTAssertEqual(a.item.url, "https://github.com/aurora/infra/pull/91")
        XCTAssertEqual(a.item.title, "infra #91")
        XCTAssertFalse(st.add(link: URL(string: "https://github.com/aurora/infra/pull/91")!, title: "x").isNew)
        let site = st.add(link: URL(string: "https://vercel.com/aurora/deployments")!, title: "Vercel · deployments").item
        XCTAssertTrue(site.sorting)
        st.addNote("gh pr checkout 91")
        let data = try Data(contentsOf: st.fileURL)
        let day = try DailyShelfStore.decoder.decode(DailyShelfDay.self, from: data)
        XCTAssertEqual(day.items.count, 3)
        XCTAssertEqual(day.version, 1)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sorting"), "Transient state is not saved")
    }

    func testLocalRenamePersistsWithoutChangingLinksOrPRDetails() throws {
        let now = Date()
        let st = store(at: now)
        let pr = st.add(link: URL(string: "https://github.com/aurora/infra/pull/91")!, title: "Original PR").item
        let site = st.add(link: URL(string: "https://example.com/dashboard")!, title: "Original site").item
        XCTAssertTrue(st.rename(pr.id, to: "  Release checklist  "))
        XCTAssertTrue(st.rename(site.id, to: "My dashboard"))
        XCTAssertFalse(st.rename(site.id, to: " \n "))
        XCTAssertFalse(st.rename(UUID(), to: "Missing item"))
        let loaded = store(at: now)
        let renamedPR = try XCTUnwrap(loaded.items.first { $0.id == pr.id })
        XCTAssertEqual(renamedPR.title, "Release checklist")
        XCTAssertEqual(renamedPR.customTitle, true)
        XCTAssertEqual(renamedPR.url, pr.url)
        XCTAssertEqual(renamedPR.github, pr.github)
        XCTAssertEqual(loaded.items.first { $0.id == site.id }?.title, "My dashboard")
    }

    func testEveryAccentRoundTripsWithoutLosingAnItem() throws {
        XCTAssertEqual(DailyShelfAccent.allCases.count, 16)
        XCTAssertEqual(Set(DailyShelfAccent.allCases.map(\.rawValue)).count, 16)
        let now = Date()
        let st = store(at: now)
        let item = st.add(link: URL(string: "https://example.com/colors")!, title: "Colors").item
        for accent in DailyShelfAccent.allCases {
            st.setAccent(item.id, to: accent)
            let loaded = try XCTUnwrap(store(at: now).items.first { $0.id == item.id })
            XCTAssertEqual(loaded.accent, accent)
            XCTAssertEqual(loaded.title, "Colors")
        }
    }

    func testItemAccentPersistsAndDefaultRemovesIt() throws {
        let now = Date()
        let st = store(at: now)
        let item = st.add(link: URL(string: "https://example.com/dashboard")!, title: "Dashboard").item
        st.setAccent(item.id, to: .aurora)
        let loaded = store(at: now)
        XCTAssertEqual(loaded.items.first?.accent, .aurora)
        XCTAssertEqual(loaded.items.first?.url, item.url)
        loaded.setAccent(item.id, to: nil)
        XCTAssertNil(store(at: now).items.first?.accent)
    }

    func testMoveLearnsTheSite() {
        let st = store(at: Date())
        let it = st.add(link: URL(string: "https://grafana.com/d/api")!, title: nil).item
        st.move(it.id, to: "Dashboards")
        XCTAssertEqual(st.items.first?.categorySource, .user)
        XCTAssertEqual(st.learned["grafana.com"], "Dashboards")
        let next = st.add(link: URL(string: "https://grafana.com/d/other")!, title: nil).item
        XCTAssertEqual(next.category, "Dashboards")
        XCTAssertFalse(next.sorting)
    }

    func testRolloverKeepsPinnedAndOpenPRsAndShowsYesterday() {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let st = store(at: today)
        let pr = st.add(link: URL(string: "https://github.com/a/b/pull/1")!, title: "Fix it").item
        let site = st.add(link: URL(string: "https://example.com/x")!, title: "X").item
        let note = st.addNote("deploy at 4")
        st.togglePin(note.id)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        XCTAssertTrue(st.checkRollover(now: tomorrow))
        XCTAssertEqual(Set(st.items.map(\.id)), [pr.id, note.id])
        XCTAssertEqual(st.previousDay()?.items.map(\.id), [site.id])
        XCTAssertFalse(st.checkRollover(now: tomorrow))
        // Reopening the app on a later day starts from what the last day kept.
        let later = store(at: cal.date(byAdding: .day, value: 2, to: today)!)
        XCTAssertEqual(Set(later.items.map(\.id)), [pr.id, note.id])
    }

    func testClearTodayKeepsPinned() {
        let st = store(at: Date())
        let a = st.addNote("a"); _ = st.addNote("b")
        st.togglePin(a.id)
        st.clearToday()
        XCTAssertEqual(st.items.map(\.id), [a.id])
    }
}

final class DailyShelfPlacementTests: XCTestCase {
    private let area = NSRect(x: 0, y: 80, width: 1512, height: 870)

    func testEveryEdgeAttachesToItsSide() {
        var p = DailyShelfPlacement()
        p.edge = .left
        XCTAssertEqual(p.layout(in: area).frame.minX, area.minX)
        p.edge = .right
        XCTAssertEqual(p.layout(in: area).frame.maxX, area.maxX)
        p.edge = .top; p.align = .start
        XCTAssertEqual(p.layout(in: area).frame.maxY, area.maxY)
        p.edge = .bottom
        XCTAssertEqual(p.layout(in: area).frame.minY, area.minY)
        p.attached = false
        XCTAssertEqual(p.layout(in: area).frame.minY, area.minY + DailyShelfPlacement.floatGap)
    }

    func testHeightStaysWithinMinAndMaxAndTheScreen() {
        var p = DailyShelfPlacement()
        p.minHeight = 420; p.maxHeight = 700
        p.height = 2000
        XCTAssertEqual(p.layout(in: area).height, 700)
        p.height = 100
        XCTAssertEqual(p.layout(in: area).height, 420)
        p.maxHeight = 5000; p.height = 5000
        let l = p.layout(in: area)
        XCTAssertLessThanOrEqual(l.frame.height, area.height)
        XCTAssertGreaterThanOrEqual(l.frame.minY, area.minY)
    }

    func testCornersAlongTheEdge() {
        var p = DailyShelfPlacement()
        p.edge = .left; p.align = .start
        let top = p.layout(in: area)
        XCTAssertEqual(top.frame.maxY, area.maxY - DailyShelfPlacement.margin, accuracy: 0.5)
        p.align = .end
        XCTAssertEqual(p.layout(in: area).frame.minY, area.minY + DailyShelfPlacement.margin, accuracy: 0.5)
        p.align = .center
        XCTAssertEqual(p.layout(in: area).frame.midY, area.midY, accuracy: 0.5)
        p.edge = .bottom; p.align = .end
        XCTAssertEqual(p.layout(in: area).frame.maxX, area.maxX - DailyShelfPlacement.margin, accuracy: 0.5)
    }

    func testOutlineStaysInsideTheWindow() {
        for edge in DailyShelfEdge.allCases {
            var p = DailyShelfPlacement(); p.edge = edge; p.align = edge == .top ? .start : .center
            let l = p.layout(in: area)
            let box = DailyShelfPlacement.outline(l, edge: edge, attached: true, closed: true).boundingBox
            let win = NSRect(origin: .zero, size: l.frame.size)
            XCTAssertTrue(win.insetBy(dx: -0.5, dy: -0.5).contains(box), "\(edge): \(box) outside \(win)")
            XCTAssertEqual(box.width, win.width, accuracy: 0.5)
            XCTAssertEqual(box.height, win.height, accuracy: 0.5)
        }
    }
}

final class DailyShelfServiceTests: XCTestCase {
    func testParsesClaudesFilingThroughProse() {
        let text = """
        Here you go:
        ```json
        [{"i": 0, "category": "dev tools", "title": "Vercel deployments", "layout": "tile"},
         {"i": 1, "category": "Release notes", "title": "Swift 6.2", "layout": "row"},
         {"i": 7, "category": "Reading"}]
        ```
        """
        let picks = DailyShelfClassifier.parse(text, count: 2)
        XCTAssertEqual(picks[0], .init(category: "Dev tools", title: "Vercel deployments", layout: "tile"))
        XCTAssertEqual(picks[1]?.category, "Release notes")
        XCTAssertNil(picks[7])
        XCTAssertTrue(DailyShelfClassifier.parse("no json", count: 1).isEmpty)
    }

    @MainActor
    func testPromptSendsOnlyAddressAndTitle() {
        let it = DailyShelfItem(kind: .site, url: "https://vercel.com/a", title: "Vercel \"prod\"", category: "Websites", categorySource: .rule)
        let p = DailyShelfClassifier.prompt(for: [it])
        XCTAssertTrue(p.contains("0. https://vercel.com/a (title: \"Vercel 'prod'\")"))
    }

    func testReviewAndChecksMapping() {
        let reviews: [[String: Any]] = [
            ["user": ["login": "theo"], "state": "CHANGES_REQUESTED"],
            ["user": ["login": "maya"], "state": "APPROVED"],
            ["user": ["login": "theo"], "state": "APPROVED"],
        ]
        XCTAssertEqual(DailyShelfGitHub.review(reviews, requested: [], me: "you", mine: true).0, .approved)
        XCTAssertEqual(DailyShelfGitHub.review(reviews.prefix(2).map { $0 }, requested: [], me: "you", mine: true).0, .changesRequested)
        XCTAssertEqual(DailyShelfGitHub.review(reviews, requested: ["You"], me: "you", mine: false).0, .requested)
        XCTAssertEqual(DailyShelfGitHub.checks([]).0, .none)
        XCTAssertEqual(DailyShelfGitHub.checks([["status": "completed", "conclusion": "success"], ["status": "in_progress"]]).0, .running)
        let failing = DailyShelfGitHub.checks([["status": "completed", "conclusion": "failure"], ["status": "completed", "conclusion": "timed_out"], ["status": "in_progress"]])
        XCTAssertEqual(failing.0, .failing)
        XCTAssertEqual(failing.1, 2)
        XCTAssertEqual(DailyShelfGitHub.checks([["status": "completed", "conclusion": "success"]]).0, .passed)
    }

    func testFindsThePagesIcon() {
        let html = #"<head><link rel="stylesheet" href="/a.css"><link rel="icon" type="image/png" href="/icon.png"><link href='/touch.png' rel='apple-touch-icon'></head>"#
        XCTAssertEqual(DailyShelfFavicons.iconHref(in: html), "/touch.png")
        XCTAssertEqual(DailyShelfFavicons.iconHref(in: #"<link rel="shortcut icon" href="https://cdn.x/f.ico?a=1&amp;b=2">"#), "https://cdn.x/f.ico?a=1&b=2")
        XCTAssertNil(DailyShelfFavicons.iconHref(in: "<p>none</p>"))
        XCTAssertTrue(DailyShelfFavicons.isSafeHost("docs.github.com"))
        XCTAssertFalse(DailyShelfFavicons.isSafeHost("../etc"))
        XCTAssertFalse(DailyShelfFavicons.isSafeHost("a b.com"))
    }

    func testStandupDraftsFromTheShelf() {
        var merged = DailyShelfItem(kind: .pr, url: "u1", title: "Fix the flaky upload test", category: "Pull requests", categorySource: .rule)
        merged.github = DailyShelfPR(owner: "a", repo: "web", number: 209, state: .merged)
        var review = DailyShelfItem(kind: .pr, url: "u2", title: "Bump Node", category: "Pull requests", categorySource: .rule)
        review.github = DailyShelfPR(owner: "a", repo: "infra", number: 88, review: .requested, mine: false)
        var jira = DailyShelfItem(kind: .jira, url: "u3", title: "Keyboard nav", category: "Jira", categorySource: .rule)
        jira.jiraKey = "AUR-142"
        let d = DailyShelfStandup.draft([merged, review, jira])
        XCTAssertEqual(d.done, ["Merged web #209 Fix the flaky upload test"])
        XCTAssertEqual(d.reviewing, ["infra #88 Bump Node"])
        XCTAssertEqual(d.doing, ["AUR-142 Keyboard nav"])
        XCTAssertTrue(DailyShelfStandup.text(d, day: "Fri 6 Nov").hasPrefix("Standup, Fri 6 Nov\n\nDone\n- Merged"))
    }

    func testArcSidebarTabGivesItsLink() throws {
        let json = #"""
        {"sidebar": {"containers": [{"items": [
          {"id": "AAAA-1", "title": null, "data": {"list": {}}},
          {"id": "FADD6D6B-8E24", "title": "", "data": {"tab": {"savedURL": "https://github.com/aurora/infra/pull/91", "savedTitle": "Pin the runner image"}}},
          {"id": "BBBB-2", "title": "My renamed tab", "data": {"tab": {"savedURL": "https://vercel.com/aurora", "savedTitle": "Vercel"}}}
        ]}]}}
        """#
        let data = Data(json.utf8)
        let a = try XCTUnwrap(DailyShelfArc.link(for: "FADD6D6B-8E24", in: data))
        XCTAssertEqual(a.0.absoluteString, "https://github.com/aurora/infra/pull/91")
        XCTAssertEqual(a.1, "Pin the runner image")
        XCTAssertEqual(DailyShelfArc.link(for: "BBBB-2", in: data)?.1, "My renamed tab")
        XCTAssertNil(DailyShelfArc.link(for: "AAAA-1", in: data), "Folders and lists carry no link")
        XCTAssertNil(DailyShelfArc.link(for: "missing", in: data))
    }

    func testArcIDsComeFromTheDragPasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("zera.test.arc.\(UUID().uuidString)"))
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("FADD6D6B-8E24-4C17-8783-7F4FE903384C", forType: DailyShelfArc.pasteboardType)
        pb.writeObjects([item])
        XCTAssertEqual(DailyShelfArc.ids(on: pb), ["FADD6D6B-8E24-4C17-8783-7F4FE903384C"])
        pb.releaseGlobally()
    }

    func testShortcutDefaultsToControlSpaceAndCanBeCleared() throws {
        var s = DailyShelfSettings()
        XCTAssertEqual(s.effectiveHotKey?.label, "⌃Space")
        s.hotKey = nil; s.hotKeyOff = true
        let back = try JSONDecoder().decode(DailyShelfSettings.self, from: JSONEncoder().encode(s))
        XCTAssertNil(back.effectiveHotKey, "A cleared shortcut stays cleared")
        let old = try JSONDecoder().decode(DailyShelfSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.effectiveHotKey?.label, "⌃Space")
    }

    func testClaudeIsOfferedTheCategoriesAlreadyInUse() {
        let it = DailyShelfItem(kind: .site, url: "https://grafana.com/d/api", title: "API", category: "Websites", categorySource: .rule)
        let p = DailyShelfClassifier.prompt(for: [it], extra: ["Release notes", "dev tools"])
        XCTAssertTrue(p.contains("Websites, Release notes."), p)
        XCTAssertFalse(p.contains("dev tools"), "Known categories are not repeated")
    }

    func testSettingsSurviveMissingKeys() throws {
        let data = Data(#"{"edge": 1, "width": 420}"#.utf8)
        let s = try JSONDecoder().decode(DailyShelfSettings.self, from: data)
        XCTAssertEqual(s.edge, 1)
        XCTAssertEqual(s.width, 420)
        XCTAssertEqual(s.rolloverHour, 4)
        XCTAssertTrue(s.enabled)
    }
}

final class DailyShelfSnapTests: XCTestCase {
    private let a = NSRect(x: 0, y: 80, width: 1512, height: 870)
    private func card(midX: CGFloat, midY: CGFloat) -> NSRect { NSRect(x: midX - 180, y: midY - 324, width: 360, height: 648) }

    func testDraggedDownIntoTheBottomLeftCornerLandsOnTheBottomEdgeInTheLeftCorner() {
        // The pointer is a little closer to the left side, but the shelf was pulled downward.
        let p = DailyShelfPlacement.snap(frame: card(midX: 200, midY: 400), pointer: NSPoint(x: 70, y: 150),
                                         travel: CGPoint(x: -30, y: -420), area: a, current: DailyShelfPlacement())
        XCTAssertEqual(p.edge, .bottom)
        XCTAssertEqual(p.align, .start)
        XCTAssertEqual(p.offset, 0)
    }

    func testDraggedSidewaysPicksTheSide() {
        let p = DailyShelfPlacement.snap(frame: card(midX: 1300, midY: 520), pointer: NSPoint(x: 1490, y: 520),
                                         travel: CGPoint(x: 900, y: 10), area: a, current: DailyShelfPlacement())
        XCTAssertEqual(p.edge, .right)
        XCTAssertEqual(p.align, .center, "Dropped near the middle of the edge")
    }

    func testCornersAndExactSpots() {
        var cur = DailyShelfPlacement(); cur.height = 500
        let top = DailyShelfPlacement.snap(frame: NSRect(x: 0, y: 420, width: 360, height: 528), pointer: NSPoint(x: 4, y: 900),
                                           travel: .zero, area: a, current: cur)
        XCTAssertEqual(top.edge, .left); XCTAssertEqual(top.align, .start); XCTAssertEqual(top.offset, 0)
        let exact = DailyShelfPlacement.snap(frame: NSRect(x: 0, y: 300, width: 360, height: 528), pointer: NSPoint(x: 4, y: 700),
                                             travel: .zero, area: a, current: cur)
        XCTAssertEqual(exact.edge, .left); XCTAssertEqual(exact.align, .start)
        XCTAssertGreaterThan(exact.offset, DailyShelfPlacement.cornerSnap - 1)
        // The exact spot is kept: laying it out puts the card where it was dropped.
        XCTAssertEqual(exact.layout(in: a).frame.midY, 300 + 264, accuracy: 1)
    }

    func testYourOrderWinsAndMovesInsert() {
        XCTAssertEqual(DailyShelfOrder.apply(["site", "pr", "gone"], to: ["pr", "jira", "site", "note"]), ["site", "pr", "jira", "note"])
        XCTAssertEqual(DailyShelfOrder.move("note", before: "pr", in: ["pr", "jira", "note"]), ["note", "pr", "jira"])
        XCTAssertEqual(DailyShelfOrder.move("pr", before: nil, in: ["pr", "jira", "note"]), ["jira", "note", "pr"])
    }

    func testPinnedCategoriesAndSectionsSurviveTheReset() {
        let dev = DailyShelfItem(kind: .site, url: "https://vercel.com", title: "Vercel", category: "Dev tools", categorySource: .claude)
        let read = DailyShelfItem(kind: .site, url: "https://swift.org", title: "Swift", category: "Reading", categorySource: .claude)
        let jira = DailyShelfItem(kind: .jira, url: "https://x.atlassian.net/browse/A-1", title: "A-1", category: "Jira", categorySource: .rule)
        let r = DailyShelfClock.carryOver([dev, read, jira], carryOpenPRs: true, pinnedGroups: ["category:Dev tools", "section:jira"])
        XCTAssertEqual(Set(r.kept.map(\.id)), [dev.id, jira.id])
        XCTAssertNil(r.kept.first?.carried, "Kept by a pin, not carried as an open PR")
        let sites = DailyShelfClock.carryOver([dev, read, jira], carryOpenPRs: false, pinnedGroups: ["section:site"])
        XCTAssertEqual(Set(sites.kept.map(\.id)), [dev.id, read.id], "Pinning flat Sites keeps every site regardless of its old category")
        XCTAssertEqual(sites.left.map(\.id), [jira.id])
    }

    func testParentDomainsAreTriedForIcons() {
        XCTAssertEqual(DailyShelfFavicons.candidateHosts("stageportal.example.org"), ["stageportal.example.org", "example.org"])
        XCTAssertEqual(DailyShelfFavicons.candidateHosts("github.com"), ["github.com"])
        XCTAssertNil(DailyShelfFavicons.iconHref(in: #"<link rel="shortcut icon" href="/undefined.png">"#))
        XCTAssertEqual(DailyShelfFavicons.registrableDomain("stageportal.example.org"), "example.org")
        XCTAssertEqual(DailyShelfFavicons.registrableDomain("docs.example.co.uk"), "example.co.uk")
        XCTAssertEqual(DailyShelfFavicons.registrableDomain("github.com"), "github.com")
    }
}

@MainActor
final class DailyShelfRefileTests: XCTestCase {
    func testRefilingASiteLearnsItAndDocsMoveBothWays() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zera-refile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let st = DailyShelfStore(folder: folder, settings: { DailyShelfSettings() })
        let it = st.add(link: URL(string: "https://stageportal.example.org/home")!, title: "Stage portal").item
        st.refile(it.id, kind: .site, category: "Dashboards")
        XCTAssertEqual(st.items.first?.category, "Dashboards")
        XCTAssertEqual(st.learned["stageportal.example.org"], "Dashboards")
        st.refile(it.id, kind: .doc, category: "Docs")
        XCTAssertEqual(st.items.first?.kind, .doc)
        let pr = st.add(link: URL(string: "https://github.com/a/b/pull/1")!, title: nil).item
        st.refile(pr.id, kind: .site, category: "Dev tools")
        XCTAssertEqual(st.items.first { $0.id == pr.id }?.kind, .pr, "PRs and tickets stay where their link puts them")
    }
}
