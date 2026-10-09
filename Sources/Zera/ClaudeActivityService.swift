import Foundation
import AppKit

// MARK: - Live Claude Code activity (no API key)
//
// Claude Code's own hooks tell us what a session is doing: every tool call before and after
// it runs, each prompt you send, when Claude stops, when it is waiting on you. A tiny
// non-blocking script appends each event to a log; Zera tails the log and shows "Reading
// Foo.swift → Editing Bar.swift → Running npm test → Done" for the session you are working in.
// Separate from the approval hook (which blocks on Bash) and from the file assistant.

/// One thing Claude did or is doing.
struct ActivityStep: Equatable {
    enum Kind { case read, edit, run, search, fetch, delegate, plan, prompt, other, waiting, done }
    let id: String
    let kind: Kind
    /// "Read" / "Edit" / "Running" … (bold) and what it acted on (regular).
    let verb: String
    let target: String
    let detail: String?
    let at: Date
    var finished: Bool
    var endedAt: Date?
    /// One-line outcome once finished ("Read 184 lines", "4 matches found").
    var result: String?

    var text: String { target.isEmpty ? verb : "\(verb) \(target)" }
    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(at) } }
    /// What the row says under the title while running.
    var progressLine: String {
        switch kind {
        case .read: return "Reading…"
        case .edit: return "Applying changes…"
        case .run: return "Executing…"
        case .search: return "Searching…"
        case .fetch: return "Fetching…"
        case .delegate: return "Working on it…"
        case .plan: return "Planning…"
        case .waiting: return detail ?? "Waiting for you"
        default: return ""
        }
    }

    var symbol: String {
        switch kind {
        case .read: return "doc.text.magnifyingglass"
        case .edit: return "pencil"
        case .run: return "terminal"
        case .search: return "magnifyingglass"
        case .fetch: return "globe"
        case .delegate: return "person.2"
        case .plan: return "checklist"
        case .prompt: return "text.bubble"
        case .other: return "wrench"
        case .waiting: return "hand.raised"
        case .done: return "checkmark.circle.fill"
        }
    }
}

/// A Claude Code session as seen through its hooks.
/// A finished prompt, for the history list.
/// A planned step from Claude's own to-do list (TodoWrite), for the step track.
struct PlanItem: Equatable {
    enum State { case pending, active, done }
    let title: String
    let state: State
}

struct ActivityHistoryItem: Equatable {
    let title: String
    let at: Date
    let duration: TimeInterval
    let steps: Int
}

final class ClaudeSession {
    enum Status: Equatable { case running, waiting, idle, done, ended }
    let id: String
    var cwd: String
    var title: String                 // the latest prompt, trimmed
    var fullPrompt: String = ""
    var steps: [ActivityStep] = []
    var status: Status = .idle
    var startedAt: Date
    var lastEventAt: Date
    /// When the current prompt was sent.
    var promptAt: Date?
    var promptCount = 0
    var toolCount = 0
    /// Tool calls since the current prompt.
    var stepsThisPrompt = 0
    var branch: String?
    var history: [ActivityHistoryItem] = []
    /// Claude's plan for the current prompt, when it keeps one.
    var plan: [PlanItem] = []
    /// When Claude first wrote its plan for this prompt (for the ETA).
    var planStartedAt: Date?
    /// Model id from the hook payload or the transcript ("claude-sonnet-4-5-…"), when known.
    var model: String?
    var transcriptPath: String?
    /// You pressed Stop in Zera; the hook blocks Claude's next tool call until the turn ends.
    var stopRequested = false
    /// Just finished, and the hook is holding the session open for a reply from the wings
    /// until then. `replyHeld` while you're typing one (no deadline).
    var replyUntil: Date?
    var replyHeld = false
    /// Can a reply still reach Claude in this session right now?
    var canReply: Bool { status == .done && (replyHeld || (replyUntil.map { $0 > Date() } ?? false)) }
    /// Files Claude looked at / changed for the current prompt (full paths, first-seen order).
    var filesTouched: [String] = []
    var filesChanged: [String] = []
    /// Tool name → calls for the current prompt.
    var toolUse: [String: Int] = [:]

    /// The percentage is only real when Claude keeps a plan (or the task is finished).
    var hasRealProgress: Bool { status == .done || !plan.isEmpty }

    /// Remaining time from the pace of finished plan items; nil when it can't be worked out.
    var eta: TimeInterval? {
        guard status == .running, let start = planStartedAt else { return nil }
        let done = plan.filter { $0.state == .done }.count
        let left = plan.count - done
        guard done > 0, left > 0 else { return nil }
        return Date().timeIntervalSince(start) / Double(done) * Double(left)
    }

    /// "Claude Sonnet 4.5" from "claude-sonnet-4-5-20250929".
    var modelName: String? {
        guard let m = model, !m.isEmpty else { return nil }
        var parts = m.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        var out: [String] = []
        var numbers: [String] = []
        func flush() { if !numbers.isEmpty { out.append(numbers.joined(separator: ".")); numbers.removeAll() } }
        for p in parts {
            if Int(p) != nil { numbers.append(p) } else { flush(); out.append(p.prefix(1).uppercased() + p.dropFirst()) }
        }
        flush()
        return out.joined(separator: " ")
    }

    /// 0…1 — from the plan when there is one, otherwise a soft estimate from the steps.
    var progress: Double {
        if status == .done { return 1 }
        if !plan.isEmpty {
            let done = Double(plan.filter { $0.state == .done }.count), active = plan.contains { $0.state == .active } ? 0.5 : 0
            return min(0.97, (done + active) / Double(plan.count))
        }
        let n = Double(stepsThisPrompt)
        return n == 0 ? 0.05 : min(0.9, 1 - 1 / (1 + n / 6))
    }

    /// Seconds since the current prompt (frozen at the end once done).
    var elapsed: TimeInterval {
        guard let p = promptAt else { return 0 }
        return (status == .done || status == .ended ? lastEventAt : Date()).timeIntervalSince(p)
    }

    init(id: String, cwd: String, at: Date) {
        self.id = id; self.cwd = cwd; self.title = ""; self.startedAt = at; self.lastEventAt = at
    }

    var folderName: String {
        let home = NSHomeDirectory()
        let p = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
        return (p as NSString).lastPathComponent.isEmpty ? p : (p as NSString).lastPathComponent
    }
    var currentStep: ActivityStep? { steps.last { !$0.finished && $0.kind != .prompt } }
    var isActive: Bool { status == .running || status == .waiting }
}

@MainActor
final class ClaudeActivityService {
    static let shared = ClaudeActivityService()

    nonisolated static let changed = Notification.Name("ClaudeActivityChanged")
    /// Posted with `userInfo["session"]: ClaudeSession, "event": String` on prompt / waiting / stop.
    nonisolated static let milestone = Notification.Name("ClaudeActivityMilestone")

    private(set) var sessions: [String: ClaudeSession] = [:]
    /// Finished prompts across sessions, newest first (max 20).
    private(set) var recentHistory: [ActivityHistoryItem] = []
    /// Most recently active first.
    var ordered: [ClaudeSession] { sessions.values.sorted { $0.lastEventAt > $1.lastEventAt } }
    var active: [ClaudeSession] { ordered.filter { $0.isActive } }
    var current: ClaudeSession? { active.first ?? ordered.first }

    private var timer: Timer?
    private var carry = Data()
    private let fm = FileManager.default

    private var base: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zera", isDirectory: true)
    }
    private var activityDir: URL { base.appendingPathComponent("hooks/activity", isDirectory: true) }
    private var logURL: URL { activityDir.appendingPathComponent("events.jsonl") }
    /// The batch Zera is reading right now (renamed from `events.jsonl`, deleted once read).
    private var claimedURL: URL { activityDir.appendingPathComponent("events.reading.jsonl") }
    var scriptURL: URL { base.appendingPathComponent("zera-activity.sh") }
    private var settingsURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json") }

    private init() {
        try? fm.createDirectory(at: activityDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: Tailing

    func start() {
        refreshScriptIfNeeded()
        // Stop requests (and reply files) never outlive a launch.
        try? fm.removeItem(at: stopDir)
        try? fm.removeItem(at: repliesDir)
        try? fm.createDirectory(at: repliesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        writeReplyWindow()
        ensureStopTimeout()
        // History before launch is not "current" activity — and hook payloads can contain prompts,
        // code and command output, so nothing is kept: drop whatever is left from earlier runs.
        try? fm.removeItem(at: logURL)
        try? fm.removeItem(at: claimedURL)
        carry.removeAll()
        pruneSessionBriefs(olderThan: 0)
        // The hook's first append creates the events file (and its reply files appear in their
        // folder), which wakes the watchers at once; the timer is the safety net and the clock
        // for reply offers running out.
        watchers = [FolderWatcher(activityDir) { [weak self] in Task { @MainActor in self?.poll() } },
                    FolderWatcher(repliesDir) { [weak self] in Task { @MainActor in self?.poll() } }]
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private var watchers: [FolderWatcher] = []

    /// Hook payloads are parsed here: a `PostToolUse` event carries the whole tool result, so a
    /// session reading big files would otherwise stall the UI thread at every poll.
    private let parseQueue = DispatchQueue(label: "ai.zera.activity-parse", qos: .utility)
    private var parsing = false

    /// Claims what the hook wrote (rename → read → delete), so events live on disk for at most
    /// a second while Zera is running. The hook starts a fresh file on its next event.
    private func poll() {
        expireReplies()
        guard fm.fileExists(atPath: logURL.path) else {
            if prune() { NotificationCenter.default.post(name: Self.changed, object: nil) }
            return
        }
        // One batch at a time, in order: the next claim waits until this one has been applied.
        guard !parsing else { return }
        try? fm.removeItem(at: claimedURL)
        guard (try? fm.moveItem(at: logURL, to: claimedURL)) != nil else { return }
        parsing = true
        let claimed = claimedURL, carried = carry
        parseQueue.async {
            let data = (try? Data(contentsOf: claimed)) ?? Data()
            try? FileManager.default.removeItem(at: claimed)
            var events: [[String: Any]] = []
            let rest = Self.consumeLines(carried + data) { line in
                if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { events.append(obj) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.carry = rest
                    self.parsing = false
                    events.forEach { self.apply($0) }
                    _ = self.prune()
                    if !events.isEmpty { NotificationCenter.default.post(name: Self.changed, object: nil) }
                    // Events that arrived while this batch was parsed are claimed straight away.
                    if self.fm.fileExists(atPath: self.logURL.path) { self.poll() }
                }
            }
        }
    }

    /// Consume a batch without repeatedly copying the remaining tail for every event.
    nonisolated static func consumeLines(_ data: Data, _ body: (Data) -> Void) -> Data {
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            body(data.subdata(in: start..<newline))
            start = data.index(after: newline)
        }
        return data.subdata(in: start..<data.endIndex)
    }

    /// A session that was still "running" when its events stopped (Claude Code killed, the
    /// terminal closed) sends no Stop: after this long without a word it reads as idle, so it
    /// no longer shadows newer sessions in the wings.
    static let runningSilence: TimeInterval = 20 * 60

    /// Drops sessions that are long gone and settles ones that went quiet. True if anything changed.
    @discardableResult
    private func prune() -> Bool {
        let now = Date()
        var changed = false
        let cutoff = now.addingTimeInterval(-3 * 3600)
        for (id, s) in sessions {
            if s.lastEventAt < cutoff || (s.status == .ended && s.lastEventAt < now.addingTimeInterval(-600)) {
                sessions.removeValue(forKey: id)
                changed = true
            } else if s.status == .running, now.timeIntervalSince(s.lastEventAt) > Self.runningSilence {
                finishOpenSteps(s, at: s.lastEventAt)
                s.status = .idle
                changed = true
            }
        }
        return changed
    }

    /// Session briefs (task, timeline, git diff) are deleted after an hour and on every launch.
    func pruneSessionBriefs(olderThan age: TimeInterval = 3600) {
        BriefCleaner.prune(fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Zera/Sessions", isDirectory: true),
                           olderThan: age)
    }

    // MARK: Events → steps

    private func apply(_ e: [String: Any]) {
        guard let sid = e["session_id"] as? String, !sid.isEmpty else { return }
        let now = Date()
        let isNew = sessions[sid] == nil
        let s = sessions[sid] ?? ClaudeSession(id: sid, cwd: e["cwd"] as? String ?? "", at: now)
        sessions[sid] = s
        s.lastEventAt = now
        if let c = e["cwd"] as? String, !c.isEmpty, c != s.cwd || isNew { s.cwd = c; lookupBranch(for: s) }
        if let t = e["transcript_path"] as? String, !t.isEmpty { s.transcriptPath = t }
        if let m = e["model"] as? String, !m.isEmpty { s.model = m }
        else if let m = e["model"] as? [String: Any], let id = (m["id"] as? String) ?? (m["display_name"] as? String) { s.model = id }
        let event = e["hook_event_name"] as? String ?? ""
        let tool = e["tool_name"] as? String ?? ""
        let input = e["tool_input"] as? [String: Any] ?? [:]
        let useID = (e["tool_use_id"] as? String) ?? ""

        // Anything new from the session means it moved on: no reply is pending any more.
        if event != "Stop", event != "Notification", s.replyUntil != nil || s.replyHeld { clearReply(s) }
        switch event {
        case "SessionStart":
            s.status = .idle
        case "UserPromptSubmit":
            let prompt = (e["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            s.title = Self.oneLine(prompt, max: 90)
            s.fullPrompt = prompt
            s.promptCount += 1
            s.promptAt = now
            s.stepsThisPrompt = 0
            s.plan.removeAll()
            s.planStartedAt = nil
            s.filesTouched.removeAll()
            s.filesChanged.removeAll()
            s.toolUse.removeAll()
            clearStop(s)
            if s.model == nil { lookupModel(for: s) }
            // A new task starts a fresh timeline.
            s.steps.removeAll()
            s.status = .running
            post(milestone: "prompt", s)
        case "PreToolUse":
            if tool == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
                s.plan = todos.compactMap { t in
                    guard let title = t["content"] as? String else { return nil }
                    let st = (t["status"] as? String ?? "pending").lowercased()
                    return PlanItem(title: Self.oneLine(title, max: 28), state: st == "completed" ? .done : (st == "in_progress" ? .active : .pending))
                }
                if s.planStartedAt == nil, !s.plan.isEmpty { s.planStartedAt = now }
            }
            if !tool.isEmpty { s.toolUse[tool, default: 0] += 1 }
            if let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String), !path.isEmpty {
                if !s.filesTouched.contains(path) { s.filesTouched.append(path) }
                if ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool), !s.filesChanged.contains(path) { s.filesChanged.append(path) }
            }
            let (kind, verb, target, detail) = Self.describe(tool: tool, input: input)
            s.toolCount += 1
            s.stepsThisPrompt += 1
            if s.promptAt == nil { s.promptAt = now }
            // A step the user answered ("waiting") is over once Claude moves on.
            for i in s.steps.indices where s.steps[i].kind == .waiting && !s.steps[i].finished { s.steps[i].finished = true; s.steps[i].endedAt = now }
            s.steps.append(ActivityStep(id: useID.isEmpty ? "t-\(now.timeIntervalSince1970)-\(tool)" : useID, kind: kind, verb: verb, target: target, detail: detail, at: now, finished: false))
            if s.steps.count > 60 { s.steps.removeFirst(s.steps.count - 60) }
            s.status = .running
        case "PostToolUse":
            // Finish the matching step (by id when the CLI provides one, else the last open one of that tool).
            let idx = s.steps.lastIndex(where: { !$0.finished && (!useID.isEmpty ? $0.id == useID : Self.toolName(for: $0.kind) == tool) })
                ?? s.steps.lastIndex(where: { !$0.finished && $0.kind != .prompt })
            if let i = idx {
                s.steps[i].finished = true
                s.steps[i].endedAt = now
                s.steps[i].result = Self.outcome(kind: s.steps[i].kind, response: e["tool_response"])
            }
            s.status = .running
        case "Notification":
            // Two different notifications arrive here: a permission prompt (Claude is blocked
            // on you) and the idle nudge "Claude is waiting for your input" (its turn is over).
            let raw = e["message"] as? String ?? ""
            let msg = raw.lowercased()
            let isPermission = msg.contains("permission") || msg.contains("approve") || msg.contains("needs your")
            if isPermission {
                s.status = .waiting
                if !(s.steps.last.map { $0.kind == .waiting && !$0.finished } ?? false) {
                    s.steps.append(ActivityStep(id: "w-\(now.timeIntervalSince1970)", kind: .waiting, verb: "Waiting", target: "for you",
                                                detail: Self.oneLine(raw, max: 80), at: now, finished: false))
                }
                post(milestone: "waiting", s)
            } else if s.status == .running || s.status == .waiting {
                // Idle nudge: the turn finished without a Stop we saw — treat it as done.
                finishOpenSteps(s, at: now)
                s.status = s.promptAt == nil ? .idle : .done
            }
        case "Stop", "SubagentStop":
            guard event == "Stop" else { break }
            finishOpenSteps(s, at: now)
            let stoppedByYou = s.stopRequested
            if s.stopRequested {
                s.steps.append(ActivityStep(id: "stop-\(now.timeIntervalSince1970)", kind: .done, verb: "Stopped", target: "from Zera",
                                            detail: nil, at: now, finished: true, endedAt: now, result: "Stopped"))
            }
            clearStop(s)
            // The hook now waits a moment for a reply. Only the session the wings show can get
            // one; any other (or one you stopped) is let go as soon as its hook starts waiting.
            if replyWindow > 0, !stoppedByYou, current?.id == sid || current == nil {
                s.replyUntil = now.addingTimeInterval(TimeInterval(replyWindow))
                s.replyHeld = false
            } else {
                releaseReply(s)
            }
            s.status = .done
            if s.model == nil { lookupModel(for: s) }
            if let p = s.promptAt {
                let item = ActivityHistoryItem(title: s.title.isEmpty ? "Claude Code task" : s.title, at: p, duration: now.timeIntervalSince(p), steps: s.stepsThisPrompt)
                s.history.insert(item, at: 0)
                if s.history.count > 50 { s.history.removeLast(s.history.count - 50) }
                recentHistory.insert(item, at: 0)
                if recentHistory.count > 20 { recentHistory.removeLast(recentHistory.count - 20) }
            }
            post(milestone: "done", s)
        case "SessionEnd":
            // Nothing can be waiting in a session that no longer exists.
            s.steps.removeAll { $0.kind == .waiting && !$0.finished }
            finishOpenSteps(s, at: now)
            clearStop(s)
            s.status = .ended
        default:
            break
        }
    }

    // MARK: Replies
    //
    // When a turn ends, the activity hook drops `<session>.<token>.waiting` into `replies/` and
    // waits. Zera answers by writing a file with the same name ending `.reply` (a Stop-hook
    // "block" decision carrying your text, so Claude carries on), `.hold` (you're typing: no
    // deadline) or `.release` (let it finish now). The hook marks `.over` when it's done and
    // never deletes anything; Zera tidies the files away. Tokens keep one wait's files from
    // ever answering the next.

    private static let replyWindowKey = "claude.replyWindow"
    /// Seconds a finished session waits for a reply from the wings; 0 turns replies off.
    var replyWindow: Int {
        get { UserDefaults.standard.object(forKey: Self.replyWindowKey) as? Int ?? 20 }
        set {
            UserDefaults.standard.set(max(0, newValue), forKey: Self.replyWindowKey)
            writeReplyWindow()
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    private var repliesDir: URL { activityDir.appendingPathComponent("replies", isDirectory: true) }

    /// The hook reads this on every Stop, so the setting applies to sessions already running.
    private func writeReplyWindow() {
        try? fm.createDirectory(at: activityDir, withIntermediateDirectories: true)
        try? Data(String(replyWindow).utf8).write(to: activityDir.appendingPathComponent("reply-window"), options: .atomic)
    }

    /// The token of the wait the hook is in for this session, if it's still waiting.
    private func waitingToken(_ s: ClaudeSession) -> String? {
        guard stopFlag(s.id) != nil, let names = try? fm.contentsOfDirectory(atPath: repliesDir.path) else { return nil }
        let prefix = s.id + "."
        let tokens = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".waiting") }
            .map { String($0.dropFirst(prefix.count).dropLast(".waiting".count)) }
            .filter { t in !t.isEmpty && t.allSatisfy({ $0.isNumber || $0 == "-" }) && !names.contains(prefix + t + ".over") }
            // The hook gives up after ~10 minutes (or Claude Code stops it sooner).
            .filter { t in (t.split(separator: "-").first.flatMap { Double($0) }).map { Date().timeIntervalSince1970 - $0 < 600 } ?? false }
        return tokens.max()
    }

    private func replyFile(_ s: ClaudeSession, _ token: String, _ ext: String) -> URL {
        repliesDir.appendingPathComponent("\(s.id).\(token).\(ext)")
    }

    /// You started typing a reply: no deadline until you send or cancel.
    func holdReply(_ s: ClaudeSession) {
        guard let t = waitingToken(s) else { return }
        fm.createFile(atPath: replyFile(s, t, "hold").path, contents: Data())
        s.replyHeld = true
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Sends `text` to Claude in this session: the waiting hook tells Claude Code not to stop
    /// yet, with your reply as what to do next. `done(false)` if the session had already
    /// finished: nothing picked the reply up within a second and a half.
    func sendReply(_ s: ClaudeSession, _ text: String, done: @escaping @MainActor (Bool) -> Void) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let t = waitingToken(s) else { clearReply(s); done(false); return }
        let out: [String: Any] = ["decision": "block",
                                  "reason": "The user replied from Zera (a notch app showing this session): \(message)"]
        let tmp = replyFile(s, t, "reply.tmp"), reply = replyFile(s, t, "reply"), over = replyFile(s, t, "over")
        guard let data = try? JSONSerialization.data(withJSONObject: out), (try? data.write(to: tmp)) != nil,
              (try? fm.moveItem(at: tmp, to: reply)) != nil else { done(false); return }
        // The hook checks five times a second; once it has taken the reply it marks the wait over.
        func check(_ tries: Int) {
            if fm.fileExists(atPath: over.path) { began(s, message); done(true); return }
            guard tries > 0 else {
                try? fm.removeItem(at: reply)
                clearReply(s)
                NotificationCenter.default.post(name: Self.changed, object: nil)
                done(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { check(tries - 1) } }
        }
        check(10)
    }

    /// Your reply is the session's new task.
    private func began(_ s: ClaudeSession, _ message: String) {
        let now = Date()
        s.replyUntil = nil
        s.replyHeld = false
        s.title = Self.oneLine(message, max: 90)
        s.fullPrompt = message
        s.promptCount += 1
        s.promptAt = now
        s.stepsThisPrompt = 0
        s.plan.removeAll()
        s.planStartedAt = nil
        s.filesTouched.removeAll()
        s.filesChanged.removeAll()
        s.toolUse.removeAll()
        s.steps.removeAll()
        s.status = .running
        s.lastEventAt = now
        post(milestone: "prompt", s)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// No reply after all: the hook lets the session finish now. The hook may not have started
    /// waiting yet when the Stop event arrives, so a release is retried for a few seconds.
    func releaseReply(_ s: ClaudeSession) {
        clearReply(s)
        pendingRelease[s.id] = Date().addingTimeInterval(5)
        applyReleases()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private var pendingRelease: [String: Date] = [:]

    private func applyReleases() {
        let now = Date()
        for (id, until) in pendingRelease {
            guard until > now, let s = sessions[id] else { pendingRelease[id] = nil; continue }
            if let t = waitingToken(s) {
                fm.createFile(atPath: replyFile(s, t, "release").path, contents: Data())
                pendingRelease[id] = nil
            }
        }
    }

    private func clearReply(_ s: ClaudeSession) {
        s.replyUntil = nil
        s.replyHeld = false
        if let t = waitingToken(s) { try? fm.removeItem(at: replyFile(s, t, "hold")) }
    }

    /// Offers whose time ran out (and nobody is typing) fold away; the hook has let go too.
    /// Files of finished waits are tidied away.
    private func expireReplies() {
        applyReleases()
        let now = Date()
        var changed = false
        for s in sessions.values where !s.replyHeld {
            if let until = s.replyUntil, until <= now { clearReply(s); changed = true }
        }
        if let names = try? fm.contentsOfDirectory(atPath: repliesDir.path) {
            for over in names where over.hasSuffix(".over") {
                // Left a few seconds, so a reply being sent can see the hook took it.
                let age = (try? fm.attributesOfItem(atPath: repliesDir.appendingPathComponent(over).path)[.modificationDate] as? Date)
                    .map { Date().timeIntervalSince($0) } ?? 0
                guard age > 5 else { continue }
                let stem = String(over.dropLast(".over".count))
                for n in names where n.hasPrefix(stem + ".") { try? fm.removeItem(at: repliesDir.appendingPathComponent(n)) }
            }
        }
        if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    // MARK: Stop / remove

    private var stopDir: URL { activityDir.appendingPathComponent("stop", isDirectory: true) }

    private func stopFlag(_ id: String) -> URL? {
        // Session ids are UUIDs; anything else never becomes a path.
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return stopDir.appendingPathComponent(id)
    }

    /// Asks Claude to stop: the activity hook blocks its next tool call with a message, so it
    /// ends the turn. Nothing is killed; the flag clears when the turn ends or you prompt again.
    func requestStop(_ s: ClaudeSession) {
        guard s.isActive, let flag = stopFlag(s.id) else { return }
        try? fm.createDirectory(at: stopDir, withIntermediateDirectories: true)
        fm.createFile(atPath: flag.path, contents: Data("stop".utf8))
        s.stopRequested = true
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func clearStop(_ s: ClaudeSession) {
        s.stopRequested = false
        if let flag = stopFlag(s.id) { try? fm.removeItem(at: flag) }
    }

    /// Drops a session from Zera's list (it comes back if Claude sends new events).
    func remove(_ s: ClaudeSession) {
        clearStop(s)
        sessions.removeValue(forKey: s.id)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Reads the model id from the tail of the session transcript, off the main thread.
    private func lookupModel(for s: ClaudeSession) {
        guard let path = s.transcriptPath, path.hasSuffix(".jsonl"), fm.fileExists(atPath: path) else { return }
        let id = s.id
        DispatchQueue.global(qos: .utility).async {
            guard let fh = FileHandle(forReadingAtPath: path) else { return }
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            try? fh.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            let text = String(decoding: (try? fh.readToEnd()) ?? Data(), as: UTF8.self)
            guard let re = try? NSRegularExpression(pattern: "\"model\"\\s*:\\s*\"(claude-[A-Za-z0-9.\\-]+)\""),
                  let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  let r = Range(m.range(at: 1), in: text) else { return }
            let model = String(text[r])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let s = ClaudeActivityService.shared.sessions[id] else { return }
                    s.model = model
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                }
            }
        }
    }

    /// A Markdown brief of one session — task, plan, timeline, files, and the folder's git
    /// diff — for "Ask Claude about this session" and the quick actions. Written to Zera's
    /// caches folder (mode 600); built off the main thread because git can take a moment.
    func brief(for s: ClaudeSession, completion: @escaping @MainActor (URL?) -> Void) {
        var md = "# Claude Code session\n\n"
        md += "- Task: \(s.fullPrompt.isEmpty ? s.title : s.fullPrompt)\n"
        md += "- Folder: \(s.cwd)\n"
        if let b = s.branch { md += "- Branch: \(b)\n" }
        md += "- Status: \(s.status)\(s.promptAt == nil ? "" : ", \(Int(s.elapsed))s since the prompt")\n"
        if !s.plan.isEmpty {
            md += "\n## Plan\n\n"
            for p in s.plan { md += "- [\(p.state == .done ? "x" : (p.state == .active ? "~" : " "))] \(p.title)\n" }
        }
        md += "\n## Timeline\n\n"
        for st in s.steps {
            let dur = st.duration.map { " (\(Int($0))s)" } ?? (st.finished ? "" : " (running)")
            md += "- \(st.text)\(dur)" + (st.result.map { " → \($0)" } ?? "") + "\n"
        }
        if !s.filesChanged.isEmpty { md += "\n## Files changed\n\n" + s.filesChanged.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !s.filesTouched.isEmpty { md += "\n## Files read\n\n" + s.filesTouched.filter { !s.filesChanged.contains($0) }.prefix(40).map { "- \($0)" }.joined(separator: "\n") + "\n" }
        let cwd = s.cwd, name = s.folderName
        pruneSessionBriefs()
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Zera/Sessions", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            var text = md
            if !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) {
                let git = URL(fileURLWithPath: "/usr/bin/git"), env = ["PATH": "/usr/bin:/bin"]
                let status = ProcessRunner.run(git, ["-C", cwd, "status", "--short"], environment: env, timeout: 8)
                if status.status == 0 {
                    text += "\n## git status\n\n```\n\(status.stdout.prefix(4000))\n```\n"
                    let diff = ProcessRunner.run(git, ["-C", cwd, "diff", "HEAD", "--no-color"], environment: env, timeout: 10)
                    if diff.status == 0, !diff.stdout.isEmpty { text += "\n## git diff\n\n```diff\n\(diff.stdout.prefix(50_000))\n```\n" }
                }
            }
            var url: URL? = caches.appendingPathComponent("\(name.isEmpty ? "session" : name)-session.md")
            do {
                try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try text.write(to: url!, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url!.path)
            } catch { url = nil }
            let result = url
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    private func finishOpenSteps(_ s: ClaudeSession, at now: Date) {
        for i in s.steps.indices where !s.steps[i].finished {
            s.steps[i].finished = true
            s.steps[i].endedAt = now
            if s.steps[i].result == nil, s.steps[i].kind != .waiting { s.steps[i].result = "Done" }
        }
    }

    private func post(milestone: String, _ s: ClaudeSession) {
        NotificationCenter.default.post(name: Self.milestone, object: nil, userInfo: ["session": s, "event": milestone])
    }

    nonisolated static func oneLine(_ s: String, max: Int) -> String {
        let one = s.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return one.count > max ? String(one.prefix(max - 1)) + "…" : one
    }

    nonisolated private static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let name = (p as NSString).lastPathComponent
        return name.isEmpty ? p : name
    }

    /// Verb + target for a tool call, like the mock: **Read** src/handler.py.
    nonisolated static func describe(tool: String, input: [String: Any]) -> (ActivityStep.Kind, String, String, String?) {
        let path = (input["file_path"] as? String) ?? (input["path"] as? String) ?? (input["notebook_path"] as? String)
        switch tool {
        case "Read": return (.read, "Read", path.map(short) ?? "a file", path)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return (.edit, tool == "Write" ? "Write" : "Edit", path.map(short) ?? "a file", path)
        case "Bash":
            let cmd = oneLine(input["command"] as? String ?? "", max: 70)
            return (.run, "Running", cmd, input["description"] as? String)
        case "Grep", "Glob":
            return (.search, "Search", "for \(oneLine((input["pattern"] as? String) ?? "", max: 40))", input["path"] as? String)
        case "WebFetch", "WebSearch":
            let url = (input["url"] as? String) ?? (input["query"] as? String) ?? ""
            let host = URL(string: url)?.host ?? oneLine(url, max: 40)
            return (.fetch, tool == "WebSearch" ? "Web search" : "Fetch", host, url)
        case "Task", "Agent":
            return (.delegate, "Delegate", oneLine(input["description"] as? String ?? "a subtask", max: 60), input["prompt"] as? String)
        case "TodoWrite", "TaskCreate", "TaskUpdate", "EnterPlanMode", "ExitPlanMode":
            return (.plan, "Plan", "", nil)
        default:
            let name = tool.hasPrefix("mcp__") ? tool.split(separator: "_").filter { !$0.isEmpty }.dropFirst().joined(separator: " ") : tool
            return (.other, "Use", name, nil)
        }
    }

    /// Short outcome line from a PostToolUse response.
    nonisolated static func outcome(kind: ActivityStep.Kind, response: Any?) -> String? {
        var text = ""
        if let s = response as? String { text = s }
        else if let d = response as? [String: Any] {
            text = (d["stdout"] as? String) ?? (d["content"] as? String) ?? (d["output"] as? String) ?? (d["file"] as? [String: Any]).flatMap { $0["content"] as? String } ?? ""
            if text.isEmpty, let arr = d["content"] as? [[String: Any]] { text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n") }
            if let n = (d["numLines"] as? Int) ?? (d["num_lines"] as? Int), kind == .read { return "Read \(n) lines" }
        } else if let arr = response as? [[String: Any]] {
            text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        let lines = text.split(whereSeparator: { $0.isNewline })
        switch kind {
        case .read: return lines.isEmpty ? "Read" : "Read \(lines.count) lines"
        case .edit: return "Applied changes"
        case .search: return lines.isEmpty ? "No matches" : "\(lines.count) match\(lines.count == 1 ? "" : "es") found"
        case .run:
            let first = lines.first.map { oneLine(String($0), max: 60) } ?? ""
            return first.isEmpty ? "Done" : first
        case .fetch: return "Fetched"
        case .delegate: return "Finished"
        case .plan: return "Plan updated"
        default: return "Done"
        }
    }

    /// `git rev-parse --abbrev-ref HEAD` for the session folder, off the main thread.
    private func lookupBranch(for s: ClaudeSession) {
        let cwd = s.cwd
        guard !cwd.isEmpty, fm.fileExists(atPath: cwd) else { return }
        let id = s.id
        DispatchQueue.global(qos: .utility).async {
            let r = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                                      environment: ["PATH": "/usr/bin:/bin"], timeout: 5)
            let branch = r.status == 0 ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let s = ClaudeActivityService.shared.sessions[id] else { return }
                    s.branch = branch.isEmpty ? nil : branch
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                }
            }
        }
    }

    private static func toolName(for kind: ActivityStep.Kind) -> String {
        switch kind {
        case .read: return "Read"
        case .edit: return "Edit"
        case .run: return "Bash"
        case .search: return "Grep"
        case .fetch: return "WebFetch"
        case .delegate: return "Task"
        case .plan: return "TodoWrite"
        default: return ""
        }
    }

    // MARK: Installing the hooks

    static let script = """
    #!/bin/bash
    # Zera — Claude Code activity hook. Hands the event to Zera (which reads and deletes it within
    # a second) and exits at once. Nothing is written when Zera isn't running. It changes nothing
    # Claude does — except when you press Stop in Zera for this session: then the next tool call
    # is blocked with a short message, so Claude ends its turn. And when a turn finishes (Stop),
    # it waits a few seconds (reply-window) for a reply typed on Zera's wings; Zera writes it as
    # a Stop-hook "block" decision, so Claude carries on in the same session. Zera lets go at
    # once of any session the wings aren't showing. This script never deletes files.
    if [ -n "$ZERA_ASSISTANT" ]; then exit 0; fi
    pgrep -x Zera >/dev/null 2>&1 || exit 0
    umask 077
    BASE="$HOME/Library/Application Support/Zera/hooks/activity"
    mkdir -p -m 700 "$BASE"
    INPUT="$(cat)"
    printf '%s\\n' "$(printf '%s' "$INPUT" | tr -d '\\n')" >> "$BASE/events.jsonl"
    case "$INPUT" in
      *'"hook_event_name":"PreToolUse"'*|*'"hook_event_name": "PreToolUse"'*)
        SID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([A-Za-z0-9_-]*\\)".*/\\1/p' | head -n 1)"
        if [ -n "$SID" ] && [ -f "$BASE/stop/$SID" ]; then
          echo "Stopped from Zera: the user asked to stop this task. Don't run more tools; briefly say where you stopped." >&2
          exit 2
        fi ;;
      *'"hook_event_name":"Stop"'*|*'"hook_event_name": "Stop"'*)
        SID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([A-Za-z0-9_-]*\\)".*/\\1/p' | head -n 1)"
        WIN="$(cat "$BASE/reply-window" 2>/dev/null)"
        case "$WIN" in ''|*[!0-9]*) WIN=0 ;; esac
        if [ -z "$SID" ] || [ "$WIN" -le 0 ]; then exit 0; fi
        mkdir -p -m 700 "$BASE/replies"
        START=$(date +%s)
        W="$BASE/replies/$SID.$START-$$"
        : > "$W.waiting"
        END=$((START + WIN)); CAP=$((START + 590)); i=0
        while :; do
          if [ -f "$W.reply" ]; then cat "$W.reply"; : > "$W.over"; exit 0; fi
          [ -f "$W.release" ] && break
          NOW=$(date +%s)
          [ "$NOW" -ge "$CAP" ] && break
          if [ ! -f "$W.hold" ] && [ "$NOW" -ge "$END" ]; then break; fi
          i=$((i+1))
          if [ $((i % 10)) -eq 0 ] && ! pgrep -x Zera >/dev/null 2>&1; then break; fi
          sleep 0.2
        done
        : > "$W.over"
        ;;
    esac
    exit 0
    """

    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    private static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains { ($0["command"] as? String ?? "").contains("zera-activity") }
    }

    /// Stop waits for a reply (while you type one, up to ~10 minutes), so it needs more than 5 s.
    private static let stopTimeout = 600

    /// Installs from before replies gave Stop the same 5 s as every other event; raise it once.
    private func ensureStopTimeout() {
        guard var json = (try? ClaudeSettingsFile.read(settingsURL)) ?? nil,
              var hooks = json["hooks"] as? [String: Any],
              var list = hooks["Stop"] as? [[String: Any]] else { return }
        var changed = false
        for (i, entry) in list.enumerated() where Self.entryIsOurs(entry) {
            var inner = entry["hooks"] as? [[String: Any]] ?? []
            for (k, h) in inner.enumerated() where (h["command"] as? String ?? "").contains("zera-activity") && (h["timeout"] as? Int ?? 0) < Self.stopTimeout {
                inner[k]["timeout"] = Self.stopTimeout
                changed = true
            }
            list[i]["hooks"] = inner
        }
        guard changed else { return }
        hooks["Stop"] = list
        json["hooks"] = hooks
        try? ClaudeSettingsFile.write(json, to: settingsURL)
    }

    private var settingsHasEntry: Bool {
        guard let json = (try? ClaudeSettingsFile.read(settingsURL)) ?? nil,
              let hooks = json["hooks"] as? [String: Any] else { return false }
        return Self.events.contains { ((hooks[$0] as? [[String: Any]]) ?? []).contains(where: Self.entryIsOurs) }
    }

    var isInstalled: Bool { previewing || (fm.fileExists(atPath: scriptURL.path) && settingsHasEntry) }
    private var previewing = false

    /// Shows sample sessions without reading any hooks (the screen renders).
    func preview(_ list: [ClaudeSession]) {
        previewing = true
        sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func refreshScriptIfNeeded() {
        guard settingsHasEntry, (try? String(contentsOf: scriptURL, encoding: .utf8)) != Self.script else { return }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        try? Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Adds one non-blocking hook per event to ~/.claude/settings.json, leaving everything
    /// else (including Zera's approval hook) untouched.
    func install() throws {
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        var json = try ClaudeSettingsFile.read(settingsURL) ?? [:]
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for ev in Self.events {
            var list = hooks[ev] as? [[String: Any]] ?? []
            list.removeAll { Self.entryIsOurs($0) }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": "\"\(scriptURL.path)\"", "timeout": ev == "Stop" ? Self.stopTimeout : 5]]]
            if ev == "PreToolUse" || ev == "PostToolUse" { entry["matcher"] = "*" }
            list.append(entry)
            hooks[ev] = list
        }
        json["hooks"] = hooks
        try ClaudeSettingsFile.write(json, to: settingsURL)
        start()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func uninstall() throws {
        guard var json = try ClaudeSettingsFile.read(settingsURL) else { return }
        if var hooks = json["hooks"] as? [String: Any] {
            for ev in Self.events {
                var list = hooks[ev] as? [[String: Any]] ?? []
                list.removeAll { Self.entryIsOurs($0) }
                if list.isEmpty { hooks.removeValue(forKey: ev) } else { hooks[ev] = list }
            }
            if hooks.isEmpty { json.removeValue(forKey: "hooks") } else { json["hooks"] = hooks }
        }
        try ClaudeSettingsFile.write(json, to: settingsURL)
        try? fm.removeItem(at: scriptURL)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
