import XCTest
@testable import Zera

/// Plan usage from Claude Code's status line: what Zera reads out of it, and how its script
/// takes the status line's place without losing yours.
final class ClaudeUsageTests: XCTestCase {
    private func statusLine(_ limits: [String: Any]?) throws -> Data {
        var json: [String: Any] = ["model": ["display_name": "Opus"], "cwd": "/tmp", "session_id": "s1"]
        if let limits = limits { json["rate_limits"] = limits }
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testBothWindowsAreReadFromTheStatusLine() throws {
        let data = try statusLine(["five_hour": ["used_percentage": 23.4, "resets_at": 1_738_425_600],
                                   "seven_day": ["used_percentage": 41, "resets_at": 1_738_857_600]])
        let now = Date(timeIntervalSince1970: 1_738_420_000)
        let u = try XCTUnwrap(ClaudeUsage.parse(statusLine: data, at: now))
        XCTAssertEqual(u.fiveHour?.used ?? 0, 0.234, accuracy: 0.0001)
        XCTAssertEqual(u.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_738_425_600))
        XCTAssertEqual(u.week?.percent, 41)
        XCTAssertEqual(u.readAt, now)
        XCTAssertEqual(u.summary, "5h 23% · week 41%")
    }

    func testNoPlanUsageMeansNoReading() throws {
        XCTAssertNil(ClaudeUsage.parse(statusLine: try statusLine(nil)), "an API key, or before the session's first reply")
        XCTAssertNil(ClaudeUsage.parse(statusLine: try statusLine([:])))
        XCTAssertNil(ClaudeUsage.parse(statusLine: Data("not json".utf8)))
        let weekOnly = try XCTUnwrap(ClaudeUsage.parse(statusLine: try statusLine(["seven_day": ["used_percentage": 12, "resets_at": 2_000_000_000]])))
        XCTAssertNil(weekOnly.fiveHour, "each window may be absent on its own")
        XCTAssertEqual(weekOnly.summary, "week 12%")
    }

    func testAWindowReadsZeroOnceItResets() {
        let now = Date()
        let u = ClaudeUsage(fiveHour: .init(used: 0.9, resetsAt: now.addingTimeInterval(-1)),
                            week: .init(used: 0.4, resetsAt: now.addingTimeInterval(3 * 86_400)), readAt: now.addingTimeInterval(-7200))
        let current = u.current(at: now)
        XCTAssertEqual(current.fiveHour?.used, 0, "a spent 5-hour window that has reset no longer reads 90%")
        XCTAssertTrue(current.fiveHour?.hasReset(at: now) ?? false)
        XCTAssertEqual(current.week, u.week)
        XCTAssertEqual(current.summary, "5h 0% · week 40%")
        XCTAssertEqual(ClaudeUsage.Window(used: 0.1, resetsAt: now.addingTimeInterval(20)).resetsIn(at: now), "1m", "never 0m before it resets")
    }

    func testReadingsFromSeveralSessionsKeepTheFullest() {
        let reset = Date().addingTimeInterval(3600), week = Date().addingTimeInterval(4 * 86_400)
        let busy = ClaudeUsage(fiveHour: .init(used: 0.6, resetsAt: reset), week: .init(used: 0.3, resetsAt: week), readAt: Date())
        // An idle session redraws its status line with what it saw an hour ago.
        let idle = ClaudeUsage(fiveHour: .init(used: 0.2, resetsAt: reset), week: nil, readAt: Date())
        let merged = busy.merged(with: idle)
        XCTAssertEqual(merged.fiveHour?.used, 0.6, "usage only goes up within a window")
        XCTAssertEqual(merged.week, busy.week, "a window the new reading leaves out stays")
        let next = ClaudeUsage(fiveHour: .init(used: 0.05, resetsAt: reset.addingTimeInterval(5 * 3600)), week: nil, readAt: Date())
        XCTAssertEqual(busy.merged(with: next).fiveHour, next.fiveHour, "a later window replaces the old one")
    }

    func testInstallingKeepsYourStatusLineAndRemovingPutsItBack() {
        let script = URL(fileURLWithPath: "/Users/me/Library/Application Support/Zera/zera-statusline.sh")
        let yours: [String: Any] = ["type": "command", "command": "~/.claude/statusline.sh", "padding": 2]
        let settings: [String: Any] = ["statusLine": yours, "model": "opus"]
        let (installed, previous) = ClaudeUsageService.installing(into: settings, script: script)
        let line = installed["statusLine"] as? [String: Any]
        XCTAssertEqual(line?["command"] as? String, "\"\(script.path)\"", "quoted: the path has a space in it")
        XCTAssertEqual(line?["padding"] as? Int, 2, "your status line's other settings stay")
        XCTAssertEqual(installed["model"] as? String, "opus", "everything else in the file is untouched")
        XCTAssertEqual(previous?["command"] as? String, "~/.claude/statusline.sh")
        XCTAssertTrue(ClaudeUsageService.isOurs(line))

        let again = ClaudeUsageService.installing(into: installed, script: script)
        XCTAssertNil(again.previous, "installing twice never mistakes Zera's own line for yours")

        let removed = ClaudeUsageService.removing(from: installed, restoring: previous)
        XCTAssertEqual((removed["statusLine"] as? [String: Any])?["command"] as? String, "~/.claude/statusline.sh")
        XCTAssertNil(ClaudeUsageService.removing(from: installed, restoring: nil)["statusLine"], "no status line before, none after")
    }

    func testRemovingLeavesAStatusLineSomeoneElseSetSince() {
        let theirs: [String: Any] = ["statusLine": ["type": "command", "command": "ccstatusline"]]
        let removed = ClaudeUsageService.removing(from: theirs, restoring: ["type": "command", "command": "old"])
        XCTAssertEqual((removed["statusLine"] as? [String: Any])?["command"] as? String, "ccstatusline")
    }

    /// The script hands Claude Code's JSON on to your own status line and prints what it prints.
    func testScriptRunsYourStatusLineAfterIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("zera-usage-\(UUID().uuidString)")
        let usage = home.appendingPathComponent("Library/Application Support/Zera/hooks/usage")
        try FileManager.default.createDirectory(at: usage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("zera-statusline.sh")
        try ClaudeUsageService.script.write(to: script, atomically: true, encoding: .utf8)
        try "tr a-z A-Z".write(to: usage.appendingPathComponent("next-command"), atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data("{\"model\":\"opus\"}".utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "{\"MODEL\":\"OPUS\"}\n",
                       "with a newline, so a status line that reads a line gets one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: usage.appendingPathComponent("latest.json").path),
                       "no plan usage in it: nothing is written")
    }
    func testConcurrentStatusLinesPublishEveryReadingAndDrainKeepsTheFullest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zera-usage-concurrent-\(UUID().uuidString)")
        let queue = root.appendingPathComponent("Library/Application Support/Zera/hooks/usage")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pgrep = bin.appendingPathComponent("pgrep")
        try "#!/bin/sh\nexit 0\n".write(to: pgrep, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pgrep.path)
        let script = root.appendingPathComponent("statusline.sh")
        try ClaudeUsageService.script.write(to: script, atomically: true, encoding: .utf8)
        var children: [(Process, Pipe)] = []
        let reset = Date().addingTimeInterval(3600).timeIntervalSince1970
        for i in 0..<24 {
            let child = Process(), input = Pipe(), error = Pipe()
            child.executableURL = URL(fileURLWithPath: "/bin/bash")
            child.arguments = [script.path]
            child.environment = ["HOME": root.path, "PATH": bin.path + ":/usr/bin:/bin"]
            child.standardInput = input; child.standardError = error
            try child.run()
            input.fileHandleForWriting.write(try statusLine(["five_hour": ["used_percentage": i * 4, "resets_at": reset]]))
            try input.fileHandleForWriting.close()
            children.append((child, error))
        }
        for (child, error) in children {
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0)
            XCTAssertTrue(error.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
        let sentinel = queue.appendingPathComponent("previous-statusline.json")
        try Data("{}".utf8).write(to: sentinel)
        let readings = ClaudeUsageService.drainReadings(in: queue)
        XCTAssertEqual(readings.count, 24)
        let merged = try XCTUnwrap(readings.first).merged(with: readings.dropFirst().reduce(readings[0]) { $0.merged(with: $1) })
        XCTAssertEqual(merged.fiveHour?.percent, 92)
        XCTAssertTrue(ClaudeUsageService.drainReadings(in: queue).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testSettingsFileRoundTripRestoresExistingStatusLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zera-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let original: [String: Any] = ["statusLine": ["type": "command", "command": "echo hello", "padding": 2], "model": "opus"]
        try ClaudeSettingsFile.write(original, to: file)
        let install = ClaudeUsageService.installing(into: try XCTUnwrap(ClaudeSettingsFile.read(file)), script: dir.appendingPathComponent("zera-statusline.sh"))
        try ClaudeSettingsFile.write(install.json, to: file)
        let restored = ClaudeUsageService.removing(from: try XCTUnwrap(ClaudeSettingsFile.read(file)), restoring: install.previous)
        try ClaudeSettingsFile.write(restored, to: file)
        let read = try XCTUnwrap(ClaudeSettingsFile.read(file))
        XCTAssertEqual(read["model"] as? String, "opus")
        XCTAssertEqual((read["statusLine"] as? [String: Any])?["command"] as? String, "echo hello")
        XCTAssertEqual((read["statusLine"] as? [String: Any])?["padding"] as? Int, 2)
    }

}
