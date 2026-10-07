import XCTest
@testable import Zera

final class TaskGitSyncTests: XCTestCase {
    private func at(_ h: Int, _ m: Int, day: Int = 7) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }
    private func commit(_ h: String, _ date: Date, _ s: String) -> GitCommit { GitCommit(hash: h + "0000000000", date: date, subject: s, body: "") }

    func testCommitTitlesLoseTheirPrefixes() {
        XCTAssertEqual(GitCommits.title(fromSubject: "feat(tasks): add project chips"), "Add project chips")
        XCTAssertEqual(GitCommits.title(fromSubject: "fix: orb centring"), "Orb centring")
        XCTAssertEqual(GitCommits.title(fromSubject: "Ship the menu"), "Ship the menu")
    }

    func testTimeComesFromTheGapsBetweenCommits() {
        let cs = [commit("a", at(9, 0), "one"), commit("b", at(9, 40), "two"), commit("c", at(9, 42), "three"),
                  commit("d", at(14, 0), "four"), commit("e", at(16, 30), "five")]
        let m = GitCommits.minutes(cs)
        XCTAssertEqual(cs.map { m[$0.hash]! }, [30, 40, 5, 30, 90], "first of a stretch 30, at least 5, at most 90")
    }

    func testClaudesGroupingIsCheckedAndGapsFilled() {
        let cs = [commit("aaaaaaa", at(9, 0), "add chips"), commit("bbbbbbb", at(9, 30), "fix chip spacing"),
                  commit("ccccccc", at(10, 0), "export column")]
        let reply = """
        Sure:
        1, 2 | Add project chips
        9 | Ghost
        2 | Used twice
        """
        let g = CommitGrouper.parse(reply, commits: cs)!
        XCTAssertEqual(g.map(\.0), ["Add project chips", "Export column"], "an unknown number is dropped, a reused one ignored; a missed commit gets its own task")
        XCTAssertEqual(g[0].1.count, 2)
        XCTAssertNil(CommitGrouper.parse("sorry, no", commits: cs))
    }

    func testCommitsBecomeDoneTasksADayAtATime() {
        let cs = [commit("a", at(9, 0, day: 6), "Tree opener"), commit("b", at(9, 0), "Reply wing"), commit("c", at(9, 20), "Fix reply")]
        let t = TaskGitSync.tasks(from: cs, project: "Zera", calendar: .current, claude: false)
        XCTAssertEqual(t.map(\.title), ["Tree opener", "Reply wing", "Fix reply"])
        XCTAssertTrue(t.allSatisfy { $0.done && $0.project == "Zera" && $0.fromCommits })
        XCTAssertEqual(t[0].log, ["2026-10-06": 1800])
        XCTAssertEqual(t[2].log, ["2026-10-07": 1200])
    }

    func testAFolderOfReposSyncsEveryRepo() throws {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("zera-repos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: top) }
        func git(_ dir: URL, _ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        for (name, msg) in [("app", "Add login screen"), ("clients/api", "Add rate limits")] {
            let d = top.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            git(d, ["init", "-q"]); git(d, ["config", "user.email", "me@example.com"]); git(d, ["config", "user.name", "Me"])
            git(d, ["commit", "-q", "--allow-empty", "-m", msg])
        }
        try FileManager.default.createDirectory(at: top.appendingPathComponent("node_modules/junk"), withIntermediateDirectories: true)
        XCTAssertEqual(GitCommits.repos(in: top.path).map { ($0 as NSString).lastPathComponent }.sorted(), ["api", "app"])
        XCTAssertEqual(GitCommits.repos(in: top.appendingPathComponent("app").path).count, 1, "a repo itself")

        let store = TaskStore(url: nil)
        let p = store.addProject("Client")
        store.link(p, to: top.path)
        store.link(p, to: top.appendingPathComponent("app").path)
        XCTAssertEqual(store.links[p]?.paths.count, 1, "a folder inside a linked one adds nothing")
        let was = TaskGitSync.useClaude
        TaskGitSync.useClaude = false
        defer { TaskGitSync.useClaude = was }
        let done = expectation(description: "sync")
        TaskGitSync.shared.sync(store) { added, _ in XCTAssertEqual(added["Client"], 2); done.fulfill() }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(Set(store.tasks.map(\.title)), ["Add login screen", "Add rate limits"])
    }

    func testALinkedRepoSyncsOnceAndOnlyYourCommits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zera-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func git(_ args: [String], env: [String: String] = [:]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path] + args
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        git(["init", "-q"])
        git(["config", "user.email", "me@example.com"])
        git(["config", "user.name", "Sam Lee"])
        git(["commit", "-q", "--allow-empty", "-m", "feat: add project chips"])
        git(["commit", "-q", "--allow-empty", "-m", "Someone else's work"],
            env: ["GIT_AUTHOR_EMAIL": "other@example.com", "GIT_AUTHOR_NAME": "Other"])
        git(["commit", "-q", "--allow-empty", "-m", "fix: chip spacing"])
        // Made on GitHub's website: a noreply address, but your name.
        git(["commit", "-q", "--allow-empty", "-m", "Update README on GitHub"],
            env: ["GIT_AUTHOR_EMAIL": "123+me@users.noreply.github.com", "GIT_AUTHOR_NAME": "Sam Lee"])

        let store = TaskStore(url: nil)
        let p = store.addProject("Zera")
        let root = try XCTUnwrap(GitCommits.repoRoot(dir.path))
        store.link(p, to: root)
        let was = TaskGitSync.useClaude
        TaskGitSync.useClaude = false
        defer { TaskGitSync.useClaude = was }

        let first = expectation(description: "sync")
        TaskGitSync.shared.sync(store) { added, _ in
            XCTAssertEqual(added["Zera"], 3)
            first.fulfill()
        }
        wait(for: [first], timeout: 20)
        XCTAssertEqual(Set(store.tasks.map(\.title)), ["Add project chips", "Chip spacing", "Update README on GitHub"],
                       "the other author's commit stays out; your website commit comes in")
        XCTAssertTrue(store.tasks.allSatisfy { $0.done && store.project(of: $0) == "Zera" })

        let again = expectation(description: "again")
        TaskGitSync.shared.sync(store) { added, _ in
            XCTAssertTrue(added.isEmpty, "nothing comes in twice")
            again.fulfill()
        }
        wait(for: [again], timeout: 20)
        XCTAssertEqual(store.tasks.count, 3)
        XCTAssertEqual(TaskExport.rows(store, span: .today, project: "Zera").count, 3, "and they export like any task")
    }
}

final class TaskGitSyncLiveTests: XCTestCase {
    /// ZERA_LIVE_CLAUDE=1 swift test --filter TaskGitSyncLiveTests: one real Claude call.
    func testClaudeGroupsRealCommits() throws {
        guard ProcessInfo.processInfo.environment["ZERA_LIVE_CLAUDE"] != nil else { throw XCTSkip("set ZERA_LIVE_CLAUDE to call Claude") }
        let probed = expectation(description: "probe")
        ClaudeCLI.shared.ensureProbed { _ in probed.fulfill() }
        wait(for: [probed], timeout: 60)
        let d = Date()
        let cs = ["Add the tree-view app opener with ⌘K actions", "Fix ⌘K arrow keys getting stuck", "Filter helper apps out of the opener",
                  "Reply to a finished Claude session from the wings", "Hide the clock while the reply countdown shows"]
            .enumerated().map { GitCommit(hash: String(format: "%07x", 0xabc0000 + $0.offset) + "000", date: d.addingTimeInterval(Double($0.offset) * 600), subject: $0.element, body: "") }
        let g = try XCTUnwrap(CommitGrouper.group(project: "Zera", commits: cs), "Claude answered with usable JSON")
        for (t, c) in g { print("TASK:", t, "<-", c.map(\.short)) }
        XCTAssertEqual(g.flatMap(\.1).count, cs.count, "every commit placed once")
        XCTAssertLessThan(g.count, cs.count, "related commits grouped")
    }
}

final class TaskGitSyncDebugTests: XCTestCase {
    /// ZERA_DEBUG_REPOS=<folder> swift test --filter TaskGitSyncDebugTests: times one real grouping call.
    func testGroupARealChunk() throws {
        guard let dir = ProcessInfo.processInfo.environment["ZERA_DEBUG_REPOS"] else { throw XCTSkip("set ZERA_DEBUG_REPOS") }
        let probed = expectation(description: "probe")
        ClaudeCLI.shared.ensureProbed { _ in probed.fulfill() }
        wait(for: [probed], timeout: 60)
        let since = Date().addingTimeInterval(-31 * 86400)
        let cs = GitCommits.repos(in: dir).flatMap { GitCommits.commits(in: $0, since: since) }.sorted { $0.date < $1.date }
        let chunk = Array(cs.prefix(CommitGrouper.maxPerCall))  // the whole month: one call
        let prompt = CommitGrouper.prompt(project: "VIDA", commits: chunk)
        print("DEBUG commits:", cs.count, "chunk:", chunk.count, "prompt chars:", prompt.count)
        let t0 = Date()
        let g = CommitGrouper.group(project: "VIDA", commits: chunk)
        print("DEBUG seconds:", Int(Date().timeIntervalSince(t0)), "groups:", g?.count ?? -1)
        for (t, c) in (g ?? []).prefix(6) { print("DEBUG TASK:", t, c.count) }
    }
}
