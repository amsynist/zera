import AppKit

// MARK: - Tasks from commits
//
// A project linked to code folders (each a repo, or a folder of repos) turns your commits into
// done tasks, a day at a time:
//
//   every repo in its folders → git log (yours, every branch, no merges, since the last sync,
//   at most a month back)
//     → by day → Claude groups each day's commits into a few task titles (or one task per
//       commit when Claude isn't there) → done tasks, timed from the gaps between commits.
//
// Commits already turned into tasks are remembered, so a sync never adds anything twice.

struct GitCommit: Equatable {
    var hash: String
    var date: Date
    var subject: String
    var body: String
    /// The repo's folder name ("zera-app").
    var repo: String = ""
    var short: String { String(hash.prefix(7)) }
}

enum GitCommits {
    /// Reads at most this far back the first time (and after a long gap).
    static let lookBackDays = 31
    /// How deep a linked folder is searched for repos, and how many are read.
    static let searchDepth = 4, maxRepos = 60
    /// Folders never worth looking inside.
    static let skip: Set<String> = ["node_modules", "Pods", "DerivedData", "build", "dist", "vendor", "target", "venv", "__pycache__"]

    /// The repos in a linked folder: the folder itself if it's in one, else every repo under it
    /// (not looking inside a repo once found).
    static func repos(in path: String) -> [String] {
        if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { return [path] }
        if let root = repoRoot(path) { return [root] }   // a folder inside one repo
        var out: [String] = []
        func walk(_ dir: String, _ depth: Int) {
            guard depth <= searchDepth, out.count < maxRepos else { return }
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) { out.append(dir); return }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for n in names.sorted() where !n.hasPrefix(".") && !skip.contains(n) {
                let sub = (dir as NSString).appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue else { continue }
                // Don't follow symlinks (they can loop).
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: sub)) != nil { continue }
                walk(sub, depth + 1)
            }
        }
        walk(path, 0)
        return out
    }

    private static func git(_ args: [String], in dir: String, timeout: TimeInterval = 15) -> ProcessRunner.Result {
        ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", dir] + args,
                          environment: ShellEnvironment.shared.environment(extra: ["GIT_TERMINAL_PROMPT": "0"]), timeout: timeout)
    }

    /// The repository's top folder, or nil when `path` isn't in one.
    static func repoRoot(_ path: String) -> String? {
        let r = git(["rev-parse", "--show-toplevel"], in: path)
        let top = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !top.isEmpty ? top : nil
    }

    /// Your commits since `since`, on any branch, merges left out. "Yours" is your git email or
    /// your git name in that repo, so commits made on GitHub's website (a noreply address) count too.
    static func commits(in path: String, since: Date) -> [GitCommit] {
        func config(_ k: String) -> String { git(["config", k], in: path).stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        var args = ["log", "--all", "--no-merges", "--since=\(Int(since.timeIntervalSince1970))",
                    "--format=%H%x1f%at%x1f%s%x1f%b%x1e"]
        // Several --author flags match any of them; they're regexes, so escape what's typed.
        for who in [config("user.email"), config("user.name")] where who.count >= 3 {
            args.append("--author=" + NSRegularExpression.escapedPattern(for: who))
        }
        let repo = (path as NSString).lastPathComponent
        // Merges made as plain commits (a fast-forwarded "Merge pull request #12…") aren't work either.
        return parse(git(args, in: path).stdout)
            .filter { !$0.subject.hasPrefix("Merge pull request ") && !$0.subject.hasPrefix("Merge branch ") && !$0.subject.hasPrefix("Merge remote-tracking ") }
            .map { var c = $0; c.repo = repo; return c }
    }

    /// `%H %at %s %b` records, as `commits` asks for them. Oldest first.
    static func parse(_ out: String) -> [GitCommit] {
        out.split(separator: "\u{1e}").compactMap { rec -> GitCommit? in
            let f = rec.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard f.count >= 3, f[0].count >= 7, let t = TimeInterval(f[1]) else { return nil }
            return GitCommit(hash: f[0], date: Date(timeIntervalSince1970: t), subject: f[2],
                             body: f.count > 3 ? f[3].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        }.sorted { $0.date < $1.date }
    }

    /// Minutes each commit took: the gap since your previous one, between 5 and 90; the first of a
    /// stretch (nothing in the 3 hours before) counts 30.
    static func minutes(_ commits: [GitCommit]) -> [String: Int] {
        var out: [String: Int] = [:]
        var prev: Date?
        for c in commits.sorted(by: { $0.date < $1.date }) {
            let gap = prev.map { c.date.timeIntervalSince($0) / 60 } ?? .infinity
            out[c.hash] = gap > 180 ? 30 : Int(min(90, max(5, gap)).rounded())
            prev = c.date
        }
        return out
    }

    /// "feat(tasks): add project chips" → "Add project chips".
    static func title(fromSubject s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let re = try? NSRegularExpression(pattern: #"^[a-zA-Z]+(\([^)]*\))?!?:\s*"#),
           let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range, in: t) {
            t.removeSubrange(r)
        }
        guard let first = t.first else { return s }
        return first.uppercased() + t.dropFirst()
    }

    /// One task per commit: what's used when Claude isn't there (or doesn't answer).
    static func oneEach(_ commits: [GitCommit]) -> [(String, [GitCommit])] {
        commits.map { (title(fromSubject: $0.subject), [$0]) }
    }
}

/// Asks Claude Code to group commits into tasks: one call for everything (thinking off, a compact
/// numbered list in and short lines out), so a month of commits takes seconds, not minutes.
enum CommitGrouper {
    /// Commits per call; more than this (rare) splits into a few calls.
    static let maxPerCall = 300

    static func prompt(project: String, commits: [GitCommit]) -> String {
        let several = Set(commits.map(\.repo)).count > 1
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let list = commits.enumerated().map { i, c -> String in
            let body = c.body.isEmpty ? "" : " — " + c.body.replacingOccurrences(of: "\n", with: " ").prefix(60)
            return "\(i + 1). \(f.string(from: c.date))|\(several ? c.repo + "|" : "")\(c.subject.prefix(120))\(body)"
        }.joined(separator: "\n")
        return """
        These are one developer's commits on the project "\(project)", numbered, as date|\(several ? "repo|" : "")subject. \
        Group them into the tasks they completed, for a timesheet: related commits together (a fix and its \
        follow-ups, the same ticket, the same feature across repos are one task), only commits from the same \
        date, every number used exactly once. Aim for 1 to 5 tasks per day; a timesheet line is a piece of \
        work, not a commit.
        Reply ONLY with lines like this, nothing else:
        3,4,7 | Fix nightly test failures on stage
        Titles: plain English, start with a verb, at most 60 characters, no prefixes like "feat:", no hashes.

        \(list)
        """
    }

    /// Reads "3,4,7 | Title" lines. Numbers out of range or used twice are ignored; commits it
    /// left out become tasks of their own. nil when nothing in the reply can be used.
    static func parse(_ reply: String, commits: [GitCommit]) -> [(String, [GitCommit])]? {
        var used = Set<Int>()
        var out: [(String, [GitCommit])] = []
        for line in reply.split(whereSeparator: \.isNewline) {
            guard let bar = line.firstIndex(of: "|") else { continue }
            let nums = line[..<bar].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                .filter { $0 >= 1 && $0 <= commits.count && !used.contains($0) }
            let title = line[line.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            guard !nums.isEmpty, !title.isEmpty else { continue }
            nums.forEach { used.insert($0) }
            out.append((String(title.prefix(80)), nums.sorted().map { commits[$0 - 1] }))
        }
        guard !out.isEmpty else { return nil }
        let left = commits.indices.filter { !used.contains($0 + 1) }.map { commits[$0] }
        return out + GitCommits.oneEach(left)
    }

    /// Runs `claude --print` with no tools, no thinking and no saved session. Blocks: call off the main thread.
    static func group(project: String, commits: [GitCommit]) -> [(String, [GitCommit])]? {
        guard commits.count > 1 else { return nil }
        let info = ClaudeCLI.shared.info
        guard let exe = info.executable, info.loggedIn != false else { return nil }
        switch info.status {
        case .notDetected, .needsAuth, .programmaticUnavailable: return nil
        default: break
        }
        let caps = info.capabilities
        var args = ["--print", "--output-format", "json"]
        if caps.noSessionPersistence { args.append("--no-session-persistence") }
        if caps.tools { args += ["--tools", ""] }
        if caps.permissionPrompts { args += ["--permission-prompts", "none"] }
        if caps.maxTurns { args += ["--max-turns", "1"] }
        if caps.strictMCP { args.append("--strict-mcp-config") }
        if caps.model { args += ["--model", "haiku"] }
        args.append(prompt(project: project, commits: commits))
        // ZERA_ASSISTANT keeps Zera's own hooks (approvals, the wings) out of this run; no
        // thinking makes it about five times faster for a job this simple.
        let env = ShellEnvironment.shared.environment(extra: ["ZERA_ASSISTANT": "1", "NO_COLOR": "1", "MAX_THINKING_TOKENS": "0"])
        let r = ProcessRunner.run(exe, args, environment: env, timeout: 120, currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        guard r.status == 0, !r.timedOut else { return nil }
        let text = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])?["result"] as? String ?? r.stdout
        return parse(text, commits: commits)
    }
}

/// How far a project's sync has got: reading its repos (no total yet), then grouping batches.
struct SyncProgress: Equatable {
    var stage: String          // "Reading repos", "Grouping commits"
    var done = 0, total = 0
    /// 0…1 once there's a total; nil while it's still counting.
    var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
}

/// Runs syncs in the background and files the results.
final class TaskGitSync {
    static let shared = TaskGitSync()
    static let progressChanged = Notification.Name("TaskGitSync.progressChanged")
    /// What each syncing project is doing (main thread).
    var progress: [String: SyncProgress] = [:]

    private func report(_ name: String, _ p: SyncProgress?) {
        let apply = {
            self.progress[name] = p
            NotificationCenter.default.post(name: Self.progressChanged, object: self)
        }
        Thread.isMainThread ? apply() : DispatchQueue.main.async(execute: apply)
    }
    /// Whether Claude groups commits (Settings); off: one task per commit.
    static var useClaude: Bool {
        get { UserDefaults.standard.object(forKey: "tasks.commitsWithClaude") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tasks.commitsWithClaude") }
    }
    private let queue = DispatchQueue(label: "ai.zera.task-sync", qos: .utility)
    private var busy: Set<String> = []
    private var lastRun: [String: Date] = [:]
    private var probed = false

    /// Projects being read right now.
    var running: Set<String> { busy }

    /// Syncs every linked project (or just one): always the last month, so an end-of-week or
    /// end-of-month timesheet has everything; commits already turned into tasks are skipped.
    /// `quiet` skips projects synced in the last 10 minutes. `done` gets how many tasks were added
    /// per project, and which projects were already being read, on the main thread.
    /// `days`: read that many days back (a rebuild); nil reads what's new since the last sync
    /// (a week, the first time).
    func sync(_ store: TaskStore, project only: String? = nil, quiet: Bool = false, days: Int? = nil,
              done: ((_ added: [String: Int], _ stillReading: [String]) -> Void)? = nil) {
        let now = store.now()
        let wanted = store.links.filter { only == nil || $0.key == only }
        let reading = wanted.keys.filter { busy.contains($0) }.sorted()
        let todo = wanted.filter { name, _ in
            !busy.contains(name) && !(quiet && (lastRun[name].map { now.timeIntervalSince($0) < 600 } ?? false))
        }
        guard !todo.isEmpty else { done?([:], reading); return }
        // Find Claude Code first (once in a while), so the grouping can use it.
        if Self.useClaude, ClaudeCLI.shared.info.checkedAt == nil, !probed {
            probed = true
            ClaudeCLI.shared.ensureProbed { _ in self.sync(store, project: only, quiet: quiet, days: days, done: done) }
            return
        }
        todo.keys.forEach { busy.insert($0); lastRun[$0] = now; report($0, SyncProgress(stage: "Reading repos")) }
        let cal = store.calendar, claude = Self.useClaude
        func daysBack(_ n: Int) -> Date { cal.startOfDay(for: cal.date(byAdding: .day, value: -n, to: now) ?? now) }
        let longest = daysBack(GitCommits.lookBackDays)
        let replaceFrom = days.map(daysBack)
        queue.async {
            var results: [(String, [FocusTask], [String])] = []
            for (name, link) in todo {
                // A rebuild reads its window; otherwise what's new (an hour of overlap, in case a
                // commit's date is a little behind), and a week the first time.
                let since = days.map(daysBack) ?? max(longest, link.syncedThrough.map { $0.addingTimeInterval(-3600) } ?? daysBack(6))
                let repos = Array(Set(link.paths.flatMap(GitCommits.repos(in:)))).sorted()
                // A rebuild re-reads its window from scratch (its old tasks are swapped out on import).
                let seen = replaceFrom == nil ? Set(link.seen) : Set<String>()
                // Worktrees of one repo share commits: each hash once.
                var once = Set<String>()
                let fresh = repos.flatMap { GitCommits.commits(in: $0, since: since) }
                    .filter { !seen.contains($0.hash) && once.insert($0.hash).inserted }.sorted { $0.date < $1.date }
                let n = fresh.count
                let made = Self.tasks(from: fresh, project: name, calendar: cal, claude: claude) { done, total in
                    // One call (the usual case): a sweep with the count; several: how many are back.
                    let stage = claude ? "Grouping \(n) commit\(n == 1 ? "" : "s")" : "Adding \(n) commits"
                    self.report(name, total > 1 ? SyncProgress(stage: stage, done: done, total: total) : SyncProgress(stage: stage))
                }
                results.append((name, made, fresh.map(\.hash)))
            }
            DispatchQueue.main.async {
                var added: [String: Int] = [:]
                for (name, made, seen) in results {
                    self.busy.remove(name)
                    self.report(name, nil)
                    store.importCommits(name, tasks: made, seen: seen, through: now, replacing: replaceFrom)
                    if !made.isEmpty { added[name] = made.count }
                }
                done?(added, reading)
            }
        }
    }

    /// Done tasks for these commits, each on its own day. Blocks (it may ask Claude: a few calls
    /// of up to 80 commits each, three at a time).
    static func tasks(from commits: [GitCommit], project: String, calendar cal: Calendar, claude: Bool,
                      progress: ((Int, Int) -> Void)? = nil) -> [FocusTask] {
        guard !commits.isEmpty else { return [] }
        let mins = GitCommits.minutes(commits)
        let sorted = commits.sorted { $0.date < $1.date }
        let chunks = stride(from: 0, to: sorted.count, by: CommitGrouper.maxPerCall).map {
            Array(sorted[$0..<min(sorted.count, $0 + CommitGrouper.maxPerCall)])
        }
        var grouped = [[(String, [GitCommit])]](repeating: [], count: chunks.count)
        var finished = 0
        progress?(0, chunks.count)
        let lock = NSLock()
        let gate = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: chunks.count) { i in
            gate.wait(); defer { gate.signal() }
            let g = (claude ? CommitGrouper.group(project: project, commits: chunks[i]) : nil) ?? GitCommits.oneEach(chunks[i])
            lock.lock(); grouped[i] = g; finished += 1; let n = finished; lock.unlock()
            progress?(n, chunks.count)
        }
        // A group never spans days: split any that does, keeping its title.
        var parts: [(String, [GitCommit])] = []
        for (title, cs) in grouped.flatMap({ $0 }) {
            for (_, dayCommits) in Dictionary(grouping: cs, by: { cal.startOfDay(for: $0.date) }) {
                parts.append((title, dayCommits.sorted { $0.date < $1.date }))
            }
        }
        var out: [FocusTask] = []
        for (title, cs) in parts.sorted(by: { $0.1[0].date < $1.1[0].date }) {
            let day = cal.dateComponents([.year, .month, .day], from: cs[0].date)
            let key = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
            let m = cs.reduce(0) { $0 + (mins[$1.hash] ?? 15) }
            var t = FocusTask(title: title, created: cs[0].date, estimate: 0)   // done work: nothing to aim for
            t.log = [key: TimeInterval(m * 60)]
            t.doneAt = cs.last!.date
            t.project = project
            t.commits = cs.map(\.short)
            t.commitNotes = cs.map { "\($0.repo.isEmpty ? "" : $0.repo + " · ")\($0.short) · \($0.subject)" }
            out.append(t)
        }
        return out
    }
}
