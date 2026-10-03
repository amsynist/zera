import Foundation

// MARK: - Events Zera understands

/// What the parser hands the UI. Transport details (JSON envelopes, usage, uuids) never
/// leave this file.
enum ClaudeStreamEvent: Equatable {
    /// The CLI started a conversation (print mode `system/init`).
    case sessionStarted(id: String, model: String?)
    /// A slice of assistant text as it is being written (needs `--include-partial-messages`).
    case textDelta(String)
    /// A complete assistant message. `text` is authoritative for that message; `usedTools`
    /// is true when it also asked for a tool (so the text was a preamble, not the answer).
    case assistantMessage(text: String, usedTools: Bool)
    /// Claude is using a tool — shown as a status line ("Reading spec.pdf…").
    case toolUse(name: String, target: String?)
    /// The final answer. `result` may be empty when Claude only used tools.
    case completed(result: String, sessionID: String?, costUSD: Double?, turns: Int?)
    /// A failure reported by the CLI itself.
    case failed(message: String, kind: ClaudeFailureKind)
}

enum ClaudeFailureKind: Equatable {
    case authentication, maxTurns, budget, network, resumeMissing, malformed, other
}

// MARK: - Parser

/// Turns Claude Code's print-mode output into `ClaudeStreamEvent`s.
///
/// Handles all three `--output-format`s: `stream-json` (one JSON object per line, the normal
/// path), `json` (one object at the end) and `text` (plain). Unknown or malformed lines are
/// skipped, never fatal — the CLI adds event types over time and the UI must not care.
final class ClaudeCodeOutputParser {
    enum Format { case streamJSON, json, text }

    let format: Format
    private var buffer = Data()
    private var textOutput = ""
    private var sawResult = false
    private(set) var sessionID: String?
    private(set) var lastModel: String?

    init(format: Format) { self.format = format }

    /// Feed raw stdout bytes; returns the events completed by this chunk.
    func feed(_ data: Data) -> [ClaudeStreamEvent] {
        buffer.append(data)
        switch format {
        case .streamJSON:
            var events: [ClaudeStreamEvent] = []
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                events.append(contentsOf: parse(line: line))
            }
            return events
        case .json, .text:
            return []   // whole output is interpreted in `finish`
        }
    }

    /// Call when stdout closes. Flushes a trailing line and synthesises `completed` for the
    /// non-streaming formats (or when the stream ended without a `result`).
    func finish(exitStatus: Int32, stderr: String) -> [ClaudeStreamEvent] {
        var events: [ClaudeStreamEvent] = []
        switch format {
        case .streamJSON:
            if !buffer.isEmpty { events.append(contentsOf: parse(line: buffer)); buffer.removeAll() }
            if !sawResult {
                if exitStatus != 0 || !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    events.append(Self.failure(from: stderr, exitStatus: exitStatus))
                } else if !textOutput.isEmpty {
                    events.append(.completed(result: textOutput, sessionID: sessionID, costUSD: nil, turns: nil))
                } else {
                    events.append(.failed(message: "Claude finished without an answer.", kind: .malformed))
                }
            }
        case .json:
            let text = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if let obj = Self.jsonObject(text) {
                events.append(contentsOf: interpret(obj))
            } else if exitStatus != 0 {
                events.append(Self.failure(from: stderr.isEmpty ? text : stderr, exitStatus: exitStatus))
            } else {
                events.append(.failed(message: "Claude returned something I couldn't read.", kind: .malformed))
            }
        case .text:
            let text = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            if exitStatus != 0 && text.isEmpty {
                events.append(Self.failure(from: stderr, exitStatus: exitStatus))
            } else {
                events.append(.completed(result: text, sessionID: sessionID, costUSD: nil, turns: nil))
            }
        }
        return events
    }

    // MARK: Line → events

    private func parse(line: Data) -> [ClaudeStreamEvent] {
        guard !line.isEmpty else { return [] }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            // Not JSON: a stray warning on stdout. Keep it only if it looks like an answer in text mode.
            return []
        }
        return interpret(obj)
    }

    private func interpret(_ obj: [String: Any]) -> [ClaudeStreamEvent] {
        if let sid = obj["session_id"] as? String, !sid.isEmpty { sessionID = sid }
        guard let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            guard (obj["subtype"] as? String) == "init" else { return [] }
            lastModel = obj["model"] as? String
            return [.sessionStarted(id: sessionID ?? "", model: lastModel)]

        case "stream_event":
            guard let ev = obj["event"] as? [String: Any], (ev["type"] as? String) == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], (delta["type"] as? String) == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            // Only top-level assistant text; sub-agent chatter has parent_tool_use_id set.
            if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return [] }
            return [.textDelta(text)]

        case "assistant":
            if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return [] }
            guard let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return [] }
            var text = "", tools: [ClaudeStreamEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let t = block["text"] as? String ?? ""
                    text += (text.isEmpty || t.isEmpty ? "" : "\n") + t
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    let target = (input["file_path"] as? String) ?? (input["path"] as? String) ?? (input["pattern"] as? String)
                    tools.append(.toolUse(name: name, target: target.map { ($0 as NSString).lastPathComponent }))
                default: break
                }
            }
            var out: [ClaudeStreamEvent] = []
            if !text.isEmpty || !tools.isEmpty { out.append(.assistantMessage(text: text, usedTools: !tools.isEmpty)) }
            out.append(contentsOf: tools)
            if tools.isEmpty { textOutput = text }
            return out

        case "result":
            sawResult = true
            let subtype = obj["subtype"] as? String ?? ""
            let isError = obj["is_error"] as? Bool ?? false
            let result = obj["result"] as? String ?? ""
            let cost = obj["total_cost_usd"] as? Double
            let turns = obj["num_turns"] as? Int
            if isError || subtype.hasPrefix("error") {
                let detail = Self.errorText(obj) ?? result
                switch subtype {
                case "error_max_turns": return [.failed(message: "Claude ran out of steps before finishing.", kind: .maxTurns)]
                case "error_max_budget_usd": return [.failed(message: "Claude hit the spending limit for this request.", kind: .budget)]
                default:
                    if let status = obj["api_error_status"] as? Int, status == 401 || status == 403 {
                        return [.failed(message: "Claude Code needs authentication.", kind: .authentication)]
                    }
                    return [Self.failure(from: detail, exitStatus: 1)]
                }
            }
            return [.completed(result: result.isEmpty ? textOutput : result, sessionID: sessionID, costUSD: cost, turns: turns)]

        default:
            // user (tool results), rate_limit_event, autocompact_state, post_turn_summary, …
            return []
        }
    }

    private static func errorText(_ obj: [String: Any]) -> String? {
        if let errs = obj["errors"] as? [String], !errs.isEmpty { return errs.joined(separator: "\n") }
        if let errs = obj["errors"] as? [[String: Any]] {
            let msgs = errs.compactMap { $0["message"] as? String }
            if !msgs.isEmpty { return msgs.joined(separator: "\n") }
        }
        if let e = obj["error"] as? String { return e }
        return nil
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        // `json` output may be preceded by warnings; find the first '{'.
        guard let start = text.firstIndex(of: "{"), let data = String(text[start...]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Classifies stderr / error text into something Zera can act on.
    static func failure(from text: String, exitStatus: Int32) -> ClaudeStreamEvent {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = t.lowercased()
        if l.contains("not logged in") || l.contains("please run /login") || l.contains("please log in") || l.contains("authentication_error")
            || l.contains("invalid api key") || l.contains("oauth token") && l.contains("expired") || l.contains("401") {
            return .failed(message: "Claude Code needs authentication.", kind: .authentication)
        }
        if l.contains("no conversation found") || l.contains("--resume requires") {
            return .failed(message: "That conversation is gone — ask again to start fresh.", kind: .resumeMissing)
        }
        if l.contains("enotfound") || l.contains("econnrefused") || l.contains("econnreset") || l.contains("network") || l.contains("fetch failed")
            || l.contains("etimedout") || l.contains("socket hang up") || l.contains("529") || l.contains("overloaded") {
            return .failed(message: "Claude couldn't be reached.", kind: .network)
        }
        if l.contains("max turns") || l.contains("max_turns") { return .failed(message: "Claude ran out of steps before finishing.", kind: .maxTurns) }
        if t.isEmpty { return .failed(message: "Claude exited unexpectedly (code \(exitStatus)).", kind: .other) }
        let firstLine = t.split(separator: "\n").first.map(String.init) ?? t
        return .failed(message: String(firstLine.prefix(200)), kind: .other)
    }
}

// MARK: - Text accumulator

/// Keeps the text the result panel shows while a request runs: committed message text plus
/// the in-flight partial. Pure value type so it can be unit-tested.
struct ClaudeTranscriptBuilder: Equatable {
    private(set) var committed = ""
    private(set) var partial = ""
    private(set) var status: String?
    private(set) var isDone = false
    private(set) var finalText: String?

    var display: String { finalText ?? (committed + partial) }

    mutating func apply(_ e: ClaudeStreamEvent, fileName: String) {
        switch e {
        case .sessionStarted:
            status = "Reading \(fileName)…"
        case .textDelta(let t):
            partial += t
            status = nil
        case .assistantMessage(let text, let usedTools):
            partial = ""
            if usedTools {
                // A preamble before a tool call ("Let me read the file") is not the answer.
                committed = ""
            } else {
                committed = text
            }
        case .toolUse(_, let target):
            status = "Reading \(target ?? fileName)…"
        case .completed(let result, _, _, _):
            isDone = true
            status = nil
            finalText = result.isEmpty ? (committed + partial) : result
        case .failed:
            isDone = true
            status = nil
        }
    }
}
