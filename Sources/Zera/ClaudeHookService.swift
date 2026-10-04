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
        timer?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scan()
    }

    /// The hook's own log (request IDs and decisions) is kept short: the last ~200 lines.
    private func trimHookLog() {
        let log = hooksDir.appendingPathComponent("hook.log")
        guard let data = try? Data(contentsOf: log), data.count > 32_000,
              let text = String(data: data, encoding: .utf8) else { return }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n")
        try? tail.write(to: log, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
    }

    private func scan() {
        guard let files = try? fm.contentsOfDirectory(at: requestsDir, includingPropertiesForKeys: nil) else { return }
        var changed = false
        for url in files where url.pathExtension == "json" {
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
        return HookRequest(id: id, receivedAt: Date(),
                           sessionID: json["session_id"] as? String ?? "",
                           toolName: tool, command: command, detail: detail,
                           cwd: json["cwd"] as? String ?? "")
    }

    // MARK: - Answering

    func respond(_ req: HookRequest, allow: Bool) {
        let decision: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": allow ? "allow" : "deny",
                "permissionDecisionReason": allow ? "Approved in Zera" : "Rejected in Zera"
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
    }

    // MARK: - Installing the hook into Claude Code

    static let script = """
    #!/bin/bash
    # Zera — Claude Code PreToolUse hook.
    # Shows the pending tool call in Zera and waits for Approve / Reject. If Zera is not
    # running or nobody answers, exits silently so Claude Code asks in the terminal instead.
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
    INPUT="$(cat)"
    printf '%s' "$INPUT" > "$REQ/$ID.json.tmp" && mv "$REQ/$ID.json.tmp" "$REQ/$ID.json"
    log "request $ID queued"
    i=0
    while [ $i -lt 2900 ]; do
      if [ -f "$RES/$ID.json" ]; then
        cat "$RES/$ID.json"
        log "request $ID answered: $(cat "$RES/$ID.json" | tr -d '\\n' | cut -c1-120)"
        rm -f "$RES/$ID.json" "$REQ/$ID.json"
        exit 0
      fi
      if ! pgrep -x Zera >/dev/null 2>&1; then log "Zera quit while waiting"; rm -f "$REQ/$ID.json"; exit 0; fi
      sleep 0.2
      i=$((i+1))
    done
    log "request $ID timed out - deferring to Claude Code"
    rm -f "$REQ/$ID.json"
    exit 0
    """

    /// Keeps an installed hook script current when Zera ships a newer one, and puts it back if
    /// it went missing while `settings.json` still points at it.
    private func refreshScriptIfNeeded() {
        guard settingsHasEntry else { return }
        let current = try? String(contentsOf: scriptURL, encoding: .utf8)
        guard current != Self.script else { return }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        try? Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private var settingsHasEntry: Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]] else { return false }
        return pre.contains { Self.entryIsOurs($0) }
    }

    var isInstalled: Bool { fm.fileExists(atPath: scriptURL.path) && settingsHasEntry }

    private static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains { ($0["command"] as? String ?? "").contains("zera-hook") }
    }

    /// Writes the script and registers it for Bash calls in `~/.claude/settings.json`,
    /// leaving everything else in that file untouched.
    func install() throws {
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
        pre.removeAll { Self.entryIsOurs($0) }
        pre.append([
            "matcher": "Bash",
            "hooks": [[
                "type": "command",
                "command": "\"\(scriptURL.path)\"",
                "timeout": 600
            ]]
        ])
        hooks["PreToolUse"] = pre
        json["hooks"] = hooks
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
        start()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if var hooks = json["hooks"] as? [String: Any],
           var pre = hooks["PreToolUse"] as? [[String: Any]] {
            pre.removeAll { Self.entryIsOurs($0) }
            if pre.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = pre }
            if hooks.isEmpty { json.removeValue(forKey: "hooks") } else { json["hooks"] = hooks }
        }
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
        try? fm.removeItem(at: scriptURL)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
