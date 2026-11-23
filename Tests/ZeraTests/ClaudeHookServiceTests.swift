import XCTest
@testable import Zera

/// The approval spool: requests the hook script drops in, and the decisions Zera writes back.
/// Runs against the hooks folder of the (throwaway) home the test process uses.
final class ClaudeHookServiceTests: XCTestCase {
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("zera-hooks-\(UUID().uuidString)")
    private var requests: URL { base.appendingPathComponent("hooks/requests") }
    private var responses: URL { base.appendingPathComponent("hooks/responses") }

    private func liveID(_ time: Int, _ serial: Int) -> String { "\(time)-\(getpid())-\(serial)" }

    private func drop(_ id: String, command: String = "ls", session: String = "s1") throws {
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let json: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "session_id": session, "cwd": "/tmp"]
        try JSONSerialization.data(withJSONObject: json).write(to: requests.appendingPathComponent(id + ".json"))
    }

    private func clearSpool() { try? FileManager.default.removeItem(at: base) }

    @MainActor
    func testGhostRequestsAreDroppedAndTheRestComeOldestFirst() throws {
        clearSpool()
        defer { clearSpool() }
        let now = Int(Date().timeIntervalSince1970)
        let ghost = "\(now - 2000)-1-1"            // its script died long ago
        let older = liveID(now - 30, 2), newer = liveID(now - 5, 3)
        try drop(ghost, command: "rm -rf build")
        try drop(newer, command: "npm test")
        try drop(older, command: "git status")
        let hooks = ClaudeHookService(base: base)
        hooks.scan()
        XCTAssertEqual(hooks.pending.map(\.id), [older, newer], "oldest first, the ghost never shown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: requests.appendingPathComponent(ghost + ".json").path),
                       "the ghost's file is removed, so it is not asked about again at the next launch")
        XCTAssertEqual(hooks.pending.first?.receivedAt.timeIntervalSince1970 ?? 0, TimeInterval(now - 30), accuracy: 1)
    }

    @MainActor
    func testADecisionIsWrittenOnceAndTheNextRequestIsLockedOutBriefly() throws {
        clearSpool()
        defer { clearSpool() }
        let now = Int(Date().timeIntervalSince1970)
        let a = liveID(now - 10, 4), b = liveID(now - 9, 5)
        try drop(a); try drop(b)
        let hooks = ClaudeHookService(base: base)
        hooks.scan()
        let first = try XCTUnwrap(hooks.pending.first)
        XCTAssertEqual(first.id, a)
        XCTAssertTrue(hooks.respond(first, allow: true))
        XCTAssertFalse(hooks.respond(first, allow: false), "already answered")
        // The second tap of a double-click lands on b, which the user never read.
        let second = try XCTUnwrap(hooks.pending.first)
        XCTAssertEqual(second.id, b)
        XCTAssertFalse(hooks.respond(second, allow: true), "locked out right after a decision")
        XCTAssertFalse(FileManager.default.fileExists(atPath: responses.appendingPathComponent(b + ".json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: responses.appendingPathComponent(a + ".json").path))
        XCTAssertEqual(hooks.pending.map(\.id), [b])
    }

    @MainActor
    func testFailedResponseWriteKeepsRequestPendingAndRetryable() throws {
        clearSpool()
        defer { clearSpool() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        let id = liveID(Int(Date().timeIntervalSince1970), 91)
        try drop(id)
        let hooks = ClaudeHookService(base: base)
        hooks.scan()
        let request = try XCTUnwrap(hooks.pending.first)
        let obstruction = responses.appendingPathComponent(id + ".json")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: true)
        XCTAssertFalse(hooks.respond(request, allow: true))
        XCTAssertTrue(hooks.pending.contains(request))
        XCTAssertNotNil(hooks.lastResponseError)
        try FileManager.default.removeItem(at: obstruction)
        XCTAssertTrue(hooks.respond(request, allow: false))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: obstruction)) as! [String: Any]
        let output = json["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual((output["decision"] as! [String: Any])["behavior"] as? String, "deny")
        XCTAssertNil(hooks.lastResponseError)
    }

    @MainActor
    func testExternalDecisionRemovesOnlyItsMatchingRequest() throws {
        defer { clearSpool() }
        let hooks = ClaudeHookService(base: base)
        let now = Int(Date().timeIntervalSince1970)
        let done = liveID(now, 1), sameSession = liveID(now, 2), otherSession = liveID(now, 3)
        try drop(done, command: "pwd")
        try drop(sameSession, command: "echo sample")
        try drop(otherSession, command: "pwd", session: "s2")
        hooks.scan()
        hooks.resolveTool(sessionID: "s1", tool: "Bash", input: ["command": "pwd"])
        XCTAssertEqual(hooks.pending.map(\.id), [sameSession, otherSession])
        XCTAssertFalse(FileManager.default.fileExists(atPath: requests.appendingPathComponent(done + ".json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: responses.appendingPathComponent(done + ".json").path))
        hooks.resolveSession("s1")
        XCTAssertEqual(hooks.pending.map(\.id), [otherSession])
    }

    @MainActor
    func testCancelledHookDisappearsBeforeItsTimeout() throws {
        defer { clearSpool() }
        let hooks = ClaudeHookService(base: base)
        let now = Int(Date().timeIntervalSince1970)
        let dead = "\(now)-\(Int32.max)-2"
        let live = liveID(now, 3)
        try drop(dead)
        try drop(live)
        hooks.scan()
        XCTAssertEqual(hooks.pending.map(\.id), [live])
    }

    func testSettingsFileIsNeverReplacedWhenItCannotBeRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zera-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        XCTAssertNil(try ClaudeSettingsFile.read(url), "no file yet: start from nothing")
        try "{ \"permissions\": { \"allow\": [\"Bash(ls:*)\"".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeSettingsFile.read(url), "a cut-off file is the user's to fix, not Zera's to erase")
        try "[1, 2]".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeSettingsFile.read(url), "not an object")
        try "{ \"permissions\": { \"allow\": [\"Bash(ls:*)\"] } }".write(to: url, atomically: true, encoding: .utf8)
        var json = try XCTUnwrap(try ClaudeSettingsFile.read(url))
        json["hooks"] = ["Stop": []]
        try ClaudeSettingsFile.write(json, to: url)
        let backup = try String(contentsOf: ClaudeSettingsFile.backupURL(for: url), encoding: .utf8)
        XCTAssertTrue(backup.contains("Bash(ls:*)") && !backup.contains("hooks"), "the previous contents are kept beside the file")
        let written = try XCTUnwrap(try ClaudeSettingsFile.read(url))
        XCTAssertNotNil(written["hooks"])
        XCTAssertNotNil(written["permissions"])
    }

    func testHookScriptTidiesItsRequestWhenKilled() {
        let script = ClaudeHookService.script
        XCTAssertTrue(script.contains("trap 'rm -f"), "a killed hook removes its request file")
        XCTAssertTrue(script.contains("INT TERM HUP"))
        // 2750 × 0.2 s = 550 s: inside Claude Code's 600 s hook timeout.
        XCTAssertTrue(script.contains("-lt 2750"))
    }
}
