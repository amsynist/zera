import Foundation
import AppKit

/// A tool call Claude Code wants to make and is waiting on.
struct HookRequest: Equatable {
    let id: String
    let receivedAt: Date
    let sessionID: String
    let toolName: String
    /// The shell command for Bash; a one-line summary for other tools.
    let command: String
    let detail: String?
    let cwd: String

    static func == (a: HookRequest, b: HookRequest) -> Bool { a.id == b.id }

    var cwdDisplay: String {
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
}

/// Lets Zera answer Claude Code's permission prompts.
///
/// No API keys involved: Claude Code's own `PreToolUse` hook runs a tiny script we install.
/// The script drops the tool call as JSON into a spool folder and waits; Zera shows it,
/// you tap Approve or Reject, Zera writes the answer next to it, the script prints that
/// answer for Claude Code and exits. If Zera is not running, or you take too long, the
/// script quietly exits and Claude Code asks in the terminal as it always did.
@MainActor
final class ClaudeHookService {
    static let shared = ClaudeHookService()

    nonisolated static let changed = Notification.Name("ClaudeHookChanged")
    /// Posted with `userInfo["request"]: HookRequest` when a new one arrives.
    nonisolated static let newRequest = Notification.Name("ClaudeHookNewRequest")

    private(set) var pending: [HookRequest] = []
    private(set) var answeredCount = 0

    private var timer: Timer?
    private var seen: Set<String> = []
    private let fm = FileManager.default

    // MARK: Paths

    private var base: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera", isDirectory: true)
    }
    private var hooksDir: URL { base.appendingPathComponent("hooks", isDirectory: true) }
    private var requestsDir: URL { hooksDir.appendingPathComponent("requests", isDirectory: true) }
    private var responsesDir: URL { hooksDir.appendingPathComponent("responses", isDirectory: true) }
    var scriptURL: URL { base.appendingPathComponent("zera-hook.sh") }
    private var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    private init() {
        for d in [requestsDir, responsesDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    // MARK: - Watching the spool

    func start() {
        refreshScriptIfNeeded()
        trimHookLog()
        // The hook drops each request into the spool with a rename, which wakes the watcher at
        // once; the timer is only a safety net (and expires requests nobody waits on any more).
        watcher = FolderWatcher(requestsDir) { [weak self] in
            Task { @MainActor in self?.scan() }
        }
        timer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scan()
    }
    private var watcher: FolderWatcher?

    /// The hook's own log (request IDs and decisions) is kept short: the last ~200 lines.
    private func trimHookLog() {
        let log = hooksDir.appendingPathComponent("hook.log")
        guard let data = try? Data(contentsOf: log), data.count > 32_000,
              let text = String(data: data, encoding: .utf8) else { return }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n")
        try? tail.write(to: log, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
    }

    /// A request this old has no script waiting on it any more (the hook gives up well inside
    /// Claude Code's 600 s timeout): its file was left behind by a session that was killed.
    static let requestLifetime: TimeInterval = 600

    /// The epoch the hook script put at the front of the id ("1759999999-412-23811").
    static func queuedAt(id: String) -> Date? {
        id.split(separator: "-").first.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
    }

    func scan() {
        guard var files = try? fm.contentsOfDirectory(at: requestsDir, includingPropertiesForKeys: nil) else { return }
        // Oldest first, so "1 of N" and the wing show the request Claude has waited on longest.
        files = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        // Ghosts: the script that wrote these is gone (Claude Code was quit or killed while it
        // waited), so nobody could act on an answer. Never shown, never answered.
        let now = Date()
        files.removeAll { url in
            let id = url.deletingPathExtension().lastPathComponent
            guard let at = Self.queuedAt(id: id), now.timeIntervalSince(at) > Self.requestLifetime else { return false }
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: responsesDir.appendingPathComponent(id + ".json"))
            return true
        }
        seen.formIntersection(Set(files.map { $0.deletingPathExtension().lastPathComponent }))
        var changed = false
        for url in files {
            let id = url.deletingPathExtension().lastPathComponent
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let req = Self.parse(id: id, json: json)
            pending.append(req)
            changed = true
            NotificationCenter.default.post(name: Self.newRequest, object: nil, userInfo: ["request": req])
        }
        // Requests whose script has given up (file gone) drop out of the queue.
        let before = pending.count
        pending.removeAll { !fm.fileExists(atPath: requestsDir.appendingPathComponent($0.id + ".json").path) }
        if pending.count != before { changed = true }
        if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    private static func parse(id: String, json: [String: Any]) -> HookRequest {
        let tool = json["tool_name"] as? String ?? "Tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        var command = ""
        var detail: String? = nil
        switch tool {
        case "Bash":
            command = input["command"] as? String ?? ""
            detail = input["description"] as? String
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            command = "\(tool.lowercased()) \(input["file_path"] as? String ?? "")"
        case "WebFetch":
            command = "fetch \(input["url"] as? String ?? "")"
        default:
            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                command = "\(tool) \(s.prefix(300))"
            } else {
                command = tool
            }
        }
        return HookRequest(id: id, receivedAt: queuedAt(id: id) ?? Date(),
                           sessionID: json["session_id"] as? String ?? "",
                           toolName: tool, command: command, detail: detail,
                           cwd: json["cwd"] as? String ?? "")
    }

    // MARK: - Answering

    /// After a decision goes out, the next request is not answerable for this long, so a
    /// double-click (or a key repeat) on Approve cannot reach the request that slid in under it.
    static let decisionLockout: TimeInterval = 0.6
    private var lastDecisionAt = Date.distantPast
    private var answered: Set<String> = []

    /// False when nothing was written: the request was already answered, or another decision
    /// went out a moment ago.
    @discardableResult
    func respond(_ req: HookRequest, allow: Bool) -> Bool {
        let now = Date()
        guard !answered.contains(req.id), now.timeIntervalSince(lastDecisionAt) >= Self.decisionLockout else { return false }
        lastDecisionAt = now
        answered.insert(req.id)
        if answered.count > 200 { answered = answered.filter { id in pending.contains { $0.id == id } } }
        let decision: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": allow ? ["behavior": "allow"] : ["behavior": "deny", "message": "Rejected in Zera"]
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: decision) {
            let final = responsesDir.appendingPathComponent(req.id + ".json")
            let tmp = responsesDir.appendingPathComponent(req.id + ".tmp")
            try? data.write(to: tmp)
            try? fm.moveItem(at: tmp, to: final)
        }
        pending.removeAll { $0.id == req.id }
        answeredCount += 1
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return true
    }

    // MARK: - Installing the hook into Claude Code

    static let script = """
    #!/bin/bash
    # Zera — Claude Code PermissionRequest hook.
    # Claude Code runs it only when it is about to ask you for permission, so auto mode, bypass
    # mode and your allow rules are respected. Shows the request in Zera and waits for Approve /
    # Reject. If Zera is not running or nobody answers, exits silently so Claude Code asks in the
    # terminal instead.
    umask 077
    BASE="$HOME/Library/Application Support/Zera/hooks"
    REQ="$BASE/requests"; RES="$BASE/responses"
    LOG="$BASE/hook.log"
    mkdir -p -m 700 "$BASE" "$REQ" "$RES"
    log() { printf '%s %s\\n' "$(date '+%H:%M:%S')" "$1" >> "$LOG"; }
    # Zera's own file-assistant requests (Summarize / Explain / …) set this; they never need approval here.
    if [ -n "$ZERA_ASSISTANT" ]; then exit 0; fi
    if ! pgrep -x Zera >/dev/null 2>&1; then log "Zera not running - deferring to Claude Code"; exit 0; fi
    ID="$(date +%s)-$$-$RANDOM"
    # Claude Code ending the session (Ctrl-C, a closed terminal, its own hook timeout) must not
    # leave a request behind for Zera to keep asking about.
    trap 'rm -f "${REQ:?}/${ID:?}.json" "${RES:?}/${ID:?}.json"; exit 0' INT TERM HUP
    INPUT="$(cat)"
    printf '%s' "$INPUT" > "$REQ/$ID.json.tmp" && mv "$REQ/$ID.json.tmp" "$REQ/$ID.json"
    log "request $ID queued"
    # Stays under Claude Code's 600 s hook timeout, so this script always tidies its request away.
    i=0
    while [ $i -lt 2750 ]; do
      if [ -f "$RES/$ID.json" ]; then
        cat "$RES/$ID.json"
        log "request $ID answered: $(cat "$RES/$ID.json" | tr -d '\\n' | cut -c1-120)"
        rm -f "${RES:?}/${ID:?}.json" "${REQ:?}/${ID:?}.json"
        exit 0
      fi
      if [ $((i % 10)) -eq 0 ] && ! pgrep -x Zera >/dev/null 2>&1; then log "Zera quit while waiting"; rm -f "${REQ:?}/${ID:?}.json"; exit 0; fi
      sleep 0.2
      i=$((i+1))
    done
    log "request $ID timed out - deferring to Claude Code"
    rm -f "${REQ:?}/${ID:?}.json"
    exit 0
    """

    /// Keeps an installed hook script current when Zera ships a newer one, and puts it back if
    /// it went missing while `settings.json` still points at it.
    private func refreshScriptIfNeeded() {
        guard settingsHasEntry else { return }
        migrateIfNeeded()
        let current = try? String(contentsOf: scriptURL, encoding: .utf8)
        guard current != Self.script else { return }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        try? Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// The event the approval hook hangs off. Earlier versions used `PreToolUse`, which fires on
    /// every tool call, so Zera asked even in auto mode and for commands you had already allowed.
    private static let event = "PermissionRequest"
    private static let legacyEvent = "PreToolUse"

    private func settingsJSON() -> [String: Any]? { (try? ClaudeSettingsFile.read(settingsURL)) ?? nil }

    private func hasEntry(_ event: String, in json: [String: Any]?) -> Bool {
        let list = (json?["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return list.contains { Self.entryIsOurs($0) }
    }

    private var settingsHasEntry: Bool {
        let json = settingsJSON()
        return hasEntry(Self.event, in: json) || hasEntry(Self.legacyEvent, in: json)
    }

    /// Moves an install from the old `PreToolUse` hook to `PermissionRequest`, once.
    private func migrateIfNeeded() {
        guard var json = settingsJSON(), hasEntry(Self.legacyEvent, in: json) else { return }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        Self.removeOurs(Self.legacyEvent, from: &hooks)
        Self.addOurs(to: &hooks, script: scriptURL)
        json["hooks"] = hooks
        try? ClaudeSettingsFile.write(json, to: settingsURL)
    }

    private static func removeOurs(_ event: String, from hooks: inout [String: Any]) {
        guard var list = hooks[event] as? [[String: Any]] else { return }
        list.removeAll { entryIsOurs($0) }
        if list.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = list }
    }

    /// Every tool: the hook only runs when Claude Code would show you a permission prompt anyway.
    private static func addOurs(to hooks: inout [String: Any], script: URL) {
        var list = hooks[event] as? [[String: Any]] ?? []
        list.removeAll { entryIsOurs($0) }
        list.append([
            "matcher": "*",
            "hooks": [["type": "command", "command": "\"\(script.path)\"", "timeout": 600]]
        ])
        hooks[event] = list
    }

    var isInstalled: Bool { fm.fileExists(atPath: scriptURL.path) && settingsHasEntry }

    private static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains { ($0["command"] as? String ?? "").contains("zera-hook") }
    }

    /// Writes the script and registers it as the `PermissionRequest` hook in
    /// `~/.claude/settings.json`, leaving everything else in that file untouched.
    func install() throws {
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var json = try ClaudeSettingsFile.read(settingsURL) ?? [:]
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        Self.removeOurs(Self.legacyEvent, from: &hooks)
        Self.addOurs(to: &hooks, script: scriptURL)
        json["hooks"] = hooks
        try ClaudeSettingsFile.write(json, to: settingsURL)
        start()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func uninstall() throws {
        guard var json = try ClaudeSettingsFile.read(settingsURL) else { return }
        if var hooks = json["hooks"] as? [String: Any] {
            Self.removeOurs(Self.event, from: &hooks)
            Self.removeOurs(Self.legacyEvent, from: &hooks)
            if hooks.isEmpty { json.removeValue(forKey: "hooks") } else { json["hooks"] = hooks }
        }
        try ClaudeSettingsFile.write(json, to: settingsURL)
        try? fm.removeItem(at: scriptURL)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

/// `~/.claude/settings.json` is the user's own Claude Code configuration. Zera only ever adds
/// or removes its own hook entries in it: it never starts from an empty file over one it
/// cannot read, and it keeps the previous contents beside it before each write.
enum ClaudeSettingsFile {
    struct Unreadable: Error {}

    /// nil when there is no file yet; throws when there is one that is not a JSON object.
    static func read(_ url: URL) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Unreadable() }
        return json
    }

    static func backupURL(for url: URL) -> URL { url.appendingPathExtension("zera-backup") }

    static func write(_ json: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = backupURL(for: url)
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }
}
