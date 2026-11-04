import AppKit
import CoreServices

struct ObservedAgentStep: Equatable {
    let id: String
    var tool: String
    var action: String
    let at: Date
    var finished = false
    var result: String? = nil
    var files: [String] = []
    var patch: String? = nil
}

/// Another coding agent's session, as far as Zera can see it from the files it writes.
struct AgentRun: Equatable {
    enum Agent: String { case codex = "Codex", cursor = "Cursor" }
    enum State: Equatable { case working, done, idle }
    let agent: Agent
    let id: String
    var project: String
    var state: State
    var lastEventAt: Date
    /// The agent's last words when it finished, if it said any.
    var summary: String?
    var activity: String? = nil
    var title: String? = nil
    var steps: [String] = []
    var records: [ObservedAgentStep] = []
}

// MARK: - Watching Codex and Cursor
//
// Read-only and event-driven: one FSEvents stream over Codex's session logs
// (~/.codex/sessions/…/rollout-*.jsonl) and Zera's own Cursor spool (written by the hook script
// installed with "Connect Cursor"). Only bytes appended since Zera started are read, on a
// background queue; nothing is sent anywhere. A run that goes quiet for two minutes counts as idle.
final class AgentWatch {
    static let shared = AgentWatch()
    static let changed = Notification.Name("ZeraAgentWatchChanged")
    /// userInfo["run"]: the `AgentRun` that just started or finished.
    static let started = Notification.Name("ZeraAgentStarted")
    static let finished = Notification.Name("ZeraAgentFinished")
    /// Codex's plan usage moved; read `codexUsage`.
    static let codexUsageChanged = Notification.Name("ZeraCodexUsageChanged")
    private static let key = "zera.agents.watch"
    private static let quietAfter: TimeInterval = 120

    private(set) var runs: [String: AgentRun] = [:]
    /// Codex's own rate-limit windows from its latest `token_count` event (percent used).
    private(set) var codexUsage: CodexUsage?

    struct CodexUsage: Equatable {
        var primary: Double?            // the short window (5 h)
        var secondary: Double?          // the weekly window
    }
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "zera.agentwatch", qos: .utility)
    /// Read offsets and unfinished last lines per file (touched on `queue` only).
    private var offsets: [String: UInt64] = [:]
    private var partial: [String: String] = [:]
    private var codexVisibility: [String: Bool] = [:]
    private var startedAt = Date()
    private var sweepTimer: Timer?
    private var reconcileTimer: Timer?

    private init() {}

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.key); newValue ? start() : stop() }
    }

    var working: [AgentRun] { runs.values.filter { $0.state == .working } }

    static var codexDir: URL {
        // Review isolates Zera's writable data, while monitoring the signed-in user's logs.
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) } ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/sessions")
    }
    static var spoolDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Zera/agents", isDirectory: true)
    }

    func start() {
        guard enabled, stream == nil else { return }
        try? FileManager.default.createDirectory(at: Self.spoolDir, withIntermediateDirectories: true)
        var paths = [Self.spoolDir.path]
        if FileManager.default.fileExists(atPath: Self.codexDir.path) { paths.append(Self.codexDir.path) }
        startedAt = Date()
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info = info else { return }
            let me = Unmanaged<AgentWatch>.fromOpaque(info).takeUnretainedValue()
            let list = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
            me.filesChanged(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        queue.async { [weak self] in self?.seedRecentCodex() }
        // FSEvents may coalesce app-server writes into directory notifications. Reconcile
        // only known file offsets as a bounded backstop, without replaying old log contents.
        let reconcile = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.filesChanged(Array(self.offsets.keys)) }
        }
        reconcile.tolerance = 1
        RunLoop.main.add(reconcile, forMode: .common); reconcileTimer = reconcile
    }

    private func seedRecentCodex() {
        let fm = FileManager.default
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        var files: [URL] = []
        for day in 0..<7 {
            guard let date = Calendar.current.date(byAdding: .day, value: -day, to: Date()) else { continue }
            let directory = Self.codexDir.appendingPathComponent(formatter.string(from: date))
            files += ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "jsonl" }
        }
        let dated = files.compactMap { url -> (URL, Date)? in
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }.prefix(96).filter { shouldShowCodex($0.0.path) }.prefix(24)
        for (url, date) in dated where offsets[url.path] == nil {
            guard shouldShowCodex(url.path) else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: 0)
            let head = handle.readData(ofLength: 65_536)
            let offset = size > 65_536 ? size - 65_536 : 0
            try? handle.seek(toOffset: offset)
            let tail = handle.readData(ofLength: 65_536)
            try? handle.close()
            offsets[url.path] = size
            var lines = String(decoding: tail, as: UTF8.self).components(separatedBy: "\n")
            if offset > 0 { lines.removeFirst() }
            if let header = String(decoding: head, as: UTF8.self).components(separatedBy: "\n").first { lines.insert(header, at: 0) }
            var seed: Event?
            var records: [ObservedAgentStep] = []
            for line in lines {
                guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let event = Self.codexEvent(json, path: url.path) else { continue }
                records = Self.mergeRecords(records, event.records)
                seed = Event(agent: .codex, id: event.id, project: event.project ?? seed?.project,
                             state: event.state ?? seed?.state, summary: event.summary ?? seed?.summary, activity: event.activity ?? seed?.activity, title: event.title ?? seed?.title)
            }
            if let seed {
                let state: AgentRun.State? = seed.state == .working && Date().timeIntervalSince(date) > Self.quietAfter ? .idle : seed.state
                let result = Event(agent: .codex, id: seed.id, project: seed.project, state: state, summary: seed.summary, activity: seed.activity, title: seed.title, records: records)
                DispatchQueue.main.async { self.apply(result, announce: false, at: date) }
            }
        }
    }

    func stop() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil
        sweepTimer?.invalidate(); sweepTimer = nil
        reconcileTimer?.invalidate(); reconcileTimer = nil
        queue.async { self.offsets.removeAll(); self.partial.removeAll(); self.codexVisibility.removeAll() }
        runs.removeAll()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Reading (on `queue`)

    private func filesChanged(_ paths: [String]) {
        if paths.contains(where: { $0.hasPrefix(Self.codexDir.path) && !$0.hasSuffix(".jsonl") }) { seedRecentCodex() }
        for path in Set(paths) where path.hasSuffix(".jsonl") {
            let isCodex = path.hasPrefix(Self.codexDir.path)
            if isCodex && !shouldShowCodex(path) { continue }
            let lines = readAppended(path)
            guard !lines.isEmpty else { continue }
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let event = isCodex ? Self.codexEvent(obj, path: path) : Self.cursorEvent(obj)
                if let e = event { DispatchQueue.main.async { self.apply(e) } }
                if isCodex, let usage = Self.codexUsage(obj) {
                    DispatchQueue.main.async {
                        guard usage != self.codexUsage else { return }
                        self.codexUsage = usage
                        NotificationCenter.default.post(name: Self.codexUsageChanged, object: nil)
                    }
                }
            }
        }
    }

    /// Internal permission-review workers are not chats or coding sub-agents. Read only the
    /// bounded metadata header once per file; genuine spawned coding agents stay visible.
    static func isCodingSession(_ metadata: [String: Any]) -> Bool {
        let payload = metadata["payload"] as? [String: Any] ?? metadata
        let source = payload["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        return (subagent?["other"] as? String) != "guardian"
    }
    private func shouldShowCodex(_ path: String) -> Bool {
        if let known = codexVisibility[path] { return known }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 65_536)
        guard let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first,
              let data = String(line).data(using: .utf8),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              metadata["type"] as? String == "session_meta" else { return true }
        let show = Self.isCodingSession(metadata)
        codexVisibility[path] = show
        return show
    }

    private func readAppended(_ path: String) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var from: UInt64
        if let known = offsets[path] {
            from = known
        } else {
            // A log from before Zera started: only what's written from now on.
            let created = (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? .distantPast
            from = created < startedAt ? size : 0
        }
        if size < from { from = 0 }            // truncated or replaced
        guard size > from else { offsets[path] = size; return [] }
        try? h.seek(toOffset: from)
        let data = h.readData(ofLength: Int(min(size - from, 4 * 1024 * 1024)))
        offsets[path] = from + UInt64(data.count)
        var text = (partial[path] ?? "") + String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        text = lines.removeLast()
        partial[path] = text.count > 200_000 ? "" : text
        return lines.filter { !$0.isEmpty }
    }

    struct Event {
        let agent: AgentRun.Agent
        let id: String
        let project: String?
        let state: AgentRun.State?
        let summary: String?
        var activity: String? = nil
        var title: String? = nil
        var records: [ObservedAgentStep] = []
    }

    static func mergeRecords(_ existing: [ObservedAgentStep], _ incoming: [ObservedAgentStep]) -> [ObservedAgentStep] {
        var records = existing
        for record in incoming {
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                if record.finished { records[index].finished = true; records[index].result = record.result }
            } else if !record.tool.isEmpty { records.append(record) }
        }
        return Array(records.suffix(80))
    }

    /// Codex rollout lines: `{"type": "event_msg" | "response_item" | "session_meta" | …, "payload": {…}}`.
    static func codexEvent(_ obj: [String: Any], path: String) -> Event? {
        let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let suffix = String(filename.suffix(36))
        let id = UUID(uuidString: suffix) == nil ? filename : suffix
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let kind = obj["type"] as? String ?? ""
        let ptype = payload["type"] as? String ?? ""
        let cwd = (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let time = (obj["timestamp"] as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) } ?? Date()
        switch (kind, ptype) {
        case ("session_meta", _), ("turn_context", _):
            guard kind != "session_meta" || isCodingSession(obj) else { return nil }
            return Event(agent: .codex, id: id, project: cwd, state: nil, summary: nil)
        case ("event_msg", "task_started"), ("event_msg", "user_message"):
            let prompt = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = prompt.flatMap { $0.count > 8 && !$0.hasPrefix("<") ? String($0.split(separator: "\n").first ?? "").prefix(100).description : nil }
            return Event(agent: .codex, id: id, project: cwd, state: .working, summary: nil, title: title)
        case ("event_msg", "task_complete"):
            return Event(agent: .codex, id: id, project: cwd, state: .done, summary: payload["last_agent_message"] as? String)
        case ("response_item", "reasoning"):
            return Event(agent: .codex, id: id, project: cwd, state: .working, summary: nil, activity: "Thinking through the request")
        case ("response_item", "message") where payload["role"] as? String == "assistant":
            return Event(agent: .codex, id: id, project: cwd, state: .working, summary: nil, activity: "Writing a reply")
        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"), ("event_msg", "exec_command_end"):
            guard let call = payload["call_id"] as? String else { return nil }
            let output = payload["output"] as? String ?? payload["aggregated_output"] as? String ?? "Completed"
            let record = ObservedAgentStep(id: call, tool: "", action: "", at: time, finished: true, result: String(output.prefix(2000)))
            return Event(agent: .codex, id: id, project: cwd, state: nil, summary: nil, records: [record])
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"), ("event_msg", "exec_command_begin"):
            let tool = (payload["name"] as? String ?? "").lowercased()
            let command = (payload["command"] as? [String])?.last ?? payload["command"] as? String
            let activity: String
            if ptype == "exec_command_begin", let command { activity = commandActivity(command) }
            else if tool.contains("patch") || tool.contains("edit") { activity = "Editing project files" }
            else if tool.contains("web") || tool.contains("search") { activity = "Searching for information" }
            else if tool.contains("cua") { activity = "Checking the live app" }
            else if tool == "exec" {
                let input = payload["input"] as? String ?? ""
                if input.contains("cua") { activity = "Checking the live app" }
                else if input.contains("web__") { activity = "Looking up information" }
                else { activity = commandActivity(input) }
            } else { activity = "Running a tool" }
            let raw = payload["input"] as? String ?? payload["arguments"] as? String ?? ""
            let args = (raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
            let patch = raw.hasPrefix("*** Begin Patch") ? raw : (args["patch"] as? String ?? args["input"] as? String).flatMap { $0.hasPrefix("*** Begin Patch") ? $0 : nil }
            var files = patch?.split(separator: "\n").compactMap { line -> String? in
                for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
                return nil
            } ?? []
            if let file = args["file_path"] as? String { files.append(file) }
            let call = payload["call_id"] as? String ?? payload["id"] as? String ?? UUID().uuidString
            let record = ObservedAgentStep(id: call, tool: payload["name"] as? String ?? "Terminal", action: activity, at: time, files: files, patch: patch.map { String($0.prefix(32000)) })
            return Event(agent: .codex, id: id, project: cwd, state: .working, summary: nil, activity: activity, records: [record])
        default:
            return nil
        }
    }

    private static func commandActivity(_ command: String) -> String {
        if command.contains("swift test") || command.contains("pytest") || command.contains("npm test") { return "Running tests" }
        if command.contains("swift build") || command.contains("xcodebuild") || command.contains("npm run build") { return "Building the project" }
        if command.contains("git diff") || command.contains("git status") { return "Reviewing changes" }
        if command.contains("cat ") || command.contains("sed ") || command.contains("head ") { return "Reading project files" }
        if command.contains("rg ") || command.contains("grep ") { return "Searching project files" }
        return "Running a terminal command"
    }

    /// `{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":…},"secondary":{…}}}}`
    static func codexUsage(_ obj: [String: Any]) -> CodexUsage? {
        guard let payload = obj["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let limits = (payload["rate_limits"] ?? payload["rateLimits"]) as? [String: Any] else { return nil }
        func used(_ key: String) -> Double? {
            guard let w = limits[key] as? [String: Any] else { return nil }
            return ((w["used_percent"] ?? w["usedPercent"]) as? NSNumber)?.doubleValue
        }
        let u = CodexUsage(primary: used("primary"), secondary: used("secondary"))
        return u.primary == nil && u.secondary == nil ? nil : u
    }

    /// Lines from Zera's Cursor hook: `{"event": "beforeSubmitPrompt" | "afterFileEdit" | "stop", "conversation_id": …, "workspace": …}`.
    static func cursorEvent(_ obj: [String: Any]) -> Event? {
        let id = obj["conversation_id"] as? String ?? "cursor"
        let project = (obj["workspace"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        switch obj["event"] as? String {
        case "beforeSubmitPrompt", "afterFileEdit", "beforeShellExecution":
            return Event(agent: .cursor, id: id, project: project, state: .working, summary: nil)
        case "stop":
            return Event(agent: .cursor, id: id, project: project, state: .done, summary: nil)
        default:
            return nil
        }
    }

    // MARK: State (main thread)

    private func apply(_ e: Event, announce: Bool = true, at: Date = Date()) {
        guard enabled, stream != nil else { return }
        let key = e.agent.rawValue + ":" + e.id
        var run = runs[key] ?? AgentRun(agent: e.agent, id: e.id, project: e.project ?? e.agent.rawValue, state: .idle, lastEventAt: Date())
        if let p = e.project { run.project = p }
        run.lastEventAt = at
        let before = run.state
        if let s = e.state { run.state = s }
        if let sum = e.summary { run.summary = sum }
        if let activity = e.activity {
            run.activity = activity
            if run.steps.last != activity { run.steps.append(activity); run.steps = Array(run.steps.suffix(12)) }
        }
        if let title = e.title { run.title = title }
        run.records = Self.mergeRecords(run.records, e.records)
        runs[key] = run
        if announce, before != .working, run.state == .working {
            NotificationCenter.default.post(name: Self.started, object: nil, userInfo: ["run": run])
        } else if announce, before == .working, run.state == .done {
            NotificationCenter.default.post(name: Self.finished, object: nil, userInfo: ["run": run])
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
        scheduleSweep()
    }

    /// While anything is working, a slow sweep turns runs that went quiet into idle ones.
    private func scheduleSweep() {
        guard sweepTimer == nil, !working.isEmpty else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.sweep() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        sweepTimer = t
    }

    private func sweep() {
        let now = Date()
        var changed = false
        for (k, r) in runs where r.state == .working && now.timeIntervalSince(r.lastEventAt) > Self.quietAfter {
            runs[k]?.state = .idle
            changed = true
        }
        runs = runs.filter { now.timeIntervalSince($0.value.lastEventAt) < 86_400 }
        if working.isEmpty { sweepTimer?.invalidate(); sweepTimer = nil }
        if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    // MARK: Cursor hooks (opt-in, from Settings)

    static var cursorHooksURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/hooks.json") }
    static var cursorScriptURL: URL { spoolDir.deletingLastPathComponent().appendingPathComponent("cursor-hook.sh") }
    private static let cursorEvents = ["beforeSubmitPrompt", "afterFileEdit", "stop"]

    /// Appends one line per hook call to the spool and answers what Cursor expects.
    static let cursorScript = """
    #!/bin/sh
    # Zera: tells the notch when Cursor's agent starts, edits and stops. Read-only for Cursor.
    EVENT="$1"
    SPOOL="$HOME/Library/Application Support/Zera/agents"
    mkdir -p "$SPOOL"
    INPUT=$(cat)
    CONV=$(printf '%s' "$INPUT" | /usr/bin/sed -n 's/.*"conversation_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -n 1)
    ROOT=$(printf '%s' "$INPUT" | /usr/bin/sed -n 's/.*"workspace_roots"[[:space:]]*:[[:space:]]*\\[[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -n 1)
    printf '{"event":"%s","conversation_id":"%s","workspace":"%s"}\\n' "$EVENT" "$CONV" "$ROOT" >> "$SPOOL/cursor.jsonl"
    if [ "$EVENT" = "beforeSubmitPrompt" ]; then printf '{"continue":true}\\n'; else printf '{}\\n'; fi
    exit 0
    """

    // MARK: Cursor approvals (opt-in)

    static var cursorApproveScriptURL: URL { spoolDir.deletingLastPathComponent().appendingPathComponent("cursor-approve.sh") }

    /// Cursor's beforeShellExecution hook: drops the request into Zera's approval spool (the
    /// same one Claude Code's hook uses, so the wings, Approve / Reject and voice answers all
    /// work) and waits up to two minutes. No Zera, no answer: Cursor asks as it normally would.
    static let cursorApproveScript = """
    #!/bin/bash
    umask 077
    BASE="$HOME/Library/Application Support/Zera/hooks"
    REQ="$BASE/requests"; RES="$BASE/responses"
    mkdir -p -m 700 "$BASE" "$REQ" "$RES"
    ask() { printf '{"permission":"ask"}\\n'; exit 0; }
    if ! pgrep -x Zera >/dev/null 2>&1; then ask; fi
    ID="$(date +%s)-$$-$RANDOM-cursor"
    trap 'rm -f "${REQ:?}/${ID:?}.json" "${RES:?}/${ID:?}.json"; exit 0' INT TERM HUP
    INPUT="$(cat)"
    printf '%s' "$INPUT" > "$REQ/$ID.json.tmp" && mv "$REQ/$ID.json.tmp" "$REQ/$ID.json"
    i=0
    while [ $i -lt 600 ]; do
      if [ -f "$RES/$ID.json" ]; then
        if grep -q '"behavior":"allow"' "$RES/$ID.json"; then
          printf '{"permission":"allow"}\\n'
        else
          printf '{"permission":"deny","userMessage":"Rejected in Zera","agentMessage":"The user rejected this command in Zera."}\\n'
        fi
        rm -f "${RES:?}/${ID:?}.json" "${REQ:?}/${ID:?}.json"
        exit 0
      fi
      sleep 0.2
      i=$((i+1))
    done
    rm -f "${REQ:?}/${ID:?}.json"
    ask
    """

    static var cursorApprovals: Bool {
        guard let data = try? Data(contentsOf: cursorHooksURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = (json["hooks"] as? [String: Any])?["beforeShellExecution"] as? [[String: Any]] else { return false }
        return list.contains { ($0["command"] as? String)?.contains("cursor-approve.sh") == true }
    }

    /// Adds or removes Zera's beforeShellExecution entry; everything else stays as it was.
    static func setCursorApprovals(_ on: Bool) throws {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: cursorHooksURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if on {
            try cursorApproveScript.write(to: cursorApproveScriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cursorApproveScriptURL.path)
        }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var list = (hooks["beforeShellExecution"] as? [[String: Any]] ?? []).filter { ($0["command"] as? String)?.contains("cursor-approve.sh") != true }
        if on { list.append(["command": "\"\(cursorApproveScriptURL.path)\""]) }
        if list.isEmpty { hooks.removeValue(forKey: "beforeShellExecution") } else { hooks["beforeShellExecution"] = list }
        json["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: cursorHooksURL, options: .atomic)
    }

    static var cursorConnected: Bool {
        guard let data = try? Data(contentsOf: cursorHooksURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { entries in
            (entries as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("cursor-hook.sh") == true } == true
        }
    }

    /// Adds Zera's three entries to ~/.cursor/hooks.json (a backup of the old file is kept next
    /// to it as hooks.json.zera-backup). Everything else in the file is left as it was.
    static func connectCursor() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cursorScriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cursorScript.write(to: cursorScriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cursorScriptURL.path)
        try fm.createDirectory(at: cursorHooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var json: [String: Any] = ["version": 1, "hooks": [String: Any]()]
        if let data = try? Data(contentsOf: cursorHooksURL) {
            guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)       // never overwrite a file we can't read
            }
            json = existing
            try? data.write(to: cursorHooksURL.appendingPathExtension("zera-backup"))
        }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for event in cursorEvents {
            var list = (hooks[event] as? [[String: Any]] ?? []).filter { ($0["command"] as? String)?.contains("cursor-hook.sh") != true }
            list.append(["command": "\"\(cursorScriptURL.path)\" \(event)"])
            hooks[event] = list
        }
        json["hooks"] = hooks
        if json["version"] == nil { json["version"] = 1 }
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: cursorHooksURL, options: .atomic)
    }

    static func disconnectCursor() throws {
        if cursorApprovals { try setCursorApprovals(false) }
        guard let data = try? Data(contentsOf: cursorHooksURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let kept = list.filter { ($0["command"] as? String)?.contains("cursor-hook.sh") != true }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        json["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: cursorHooksURL, options: .atomic)
    }
}
