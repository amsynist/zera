import XCTest
@testable import Zera

/// Pure pieces of the Glance-inspired features: voice answers, lyrics, agent log parsing.
final class GlanceFeaturesTests: XCTestCase {
    func testVoiceAnswersNeedAShortUtterance() {
        XCTAssertEqual(VoiceApproval.answer(in: "Approve"), .allow)
        XCTAssertEqual(VoiceApproval.answer(in: "okay go"), .allow)
        XCTAssertEqual(VoiceApproval.answer(in: "no."), .deny)
        XCTAssertEqual(VoiceApproval.answer(in: "please deny"), .deny)
        XCTAssertEqual(VoiceApproval.answer(in: "open"), .open)
        XCTAssertNil(VoiceApproval.answer(in: "I said earlier that we should probably say yes"))
        XCTAssertNil(VoiceApproval.answer(in: "hmm"))
        XCTAssertNil(VoiceApproval.answer(in: ""))
    }

    func testLRCParsingAndLookup() {
        let lrc = "[ar:Someone]\n[00:01.00]First\n[00:05.50][01:00.00]Chorus\n[00:09.00]\n[00:10.25] Last  "
        let lines = LyricsService.parseLRC(lrc)
        XCTAssertEqual(lines.map(\.text), ["First", "Chorus", "", "Last", "Chorus"])
        XCTAssertEqual(lines.map(\.time), [1, 5.5, 9, 10.25, 60])
        XCTAssertNil(LyricsService.line(in: lines, at: 0.5))
        XCTAssertEqual(LyricsService.line(in: lines, at: 6)?.text, "Chorus")
        XCTAssertNil(LyricsService.line(in: lines, at: 9.5))          // an empty line is a gap
        XCTAssertEqual(LyricsService.line(in: lines, at: 30)?.text, "Last")
        XCTAssertEqual(LyricsService.line(in: lines, at: 61)?.index, 4)
    }

    func testCodexRolloutEvents() {
        let path = "/Users/me/.codex/sessions/2026/10/31/rollout-2026-10-31T10-00-00-abc.jsonl"
        let start = AgentWatch.codexEvent(["type": "event_msg", "payload": ["type": "task_started"]], path: path)
        XCTAssertEqual(start?.state, .working)
        XCTAssertEqual(start?.id, "rollout-2026-10-31T10-00-00-abc")
        let meta = AgentWatch.codexEvent(["type": "session_meta", "payload": ["cwd": "/Users/me/code/zera"]], path: path)
        XCTAssertEqual(meta?.project, "zera")
        XCTAssertNil(meta?.state)
        let done = AgentWatch.codexEvent(["type": "event_msg", "payload": ["type": "task_complete", "last_agent_message": "All set"]], path: path)
        XCTAssertEqual(done?.state, .done)
        XCTAssertEqual(done?.summary, "All set")
        XCTAssertNil(AgentWatch.codexEvent(["type": "event_msg", "payload": ["type": "token_count"]], path: path))
    }

    func testCursorSpoolEvents() {
        XCTAssertEqual(AgentWatch.cursorEvent(["event": "beforeSubmitPrompt", "conversation_id": "c1", "workspace": "/w/app"])?.state, .working)
        XCTAssertEqual(AgentWatch.cursorEvent(["event": "stop", "conversation_id": "c1"])?.state, .done)
        XCTAssertEqual(AgentWatch.cursorEvent(["event": "afterFileEdit", "workspace": "/w/app"])?.project, "app")
        XCTAssertNil(AgentWatch.cursorEvent(["event": "somethingElse"]))
    }
}

extension GlanceFeaturesTests {
    func testCursorApprovalScriptAnswersInCursorsFormat() {
        let s = AgentWatch.cursorApproveScript
        XCTAssertTrue(s.contains(#"{"permission":"allow"}"#))
        XCTAssertTrue(s.contains(#""permission":"deny""#))
        XCTAssertTrue(s.contains(#"{"permission":"ask"}"#))
        XCTAssertTrue(s.contains("-cursor\""))
    }
}

extension GlanceFeaturesTests {
    func testCodexUsageComesFromTokenCountEvents() {
        let obj: [String: Any] = ["type": "event_msg", "payload": ["type": "token_count",
            "rate_limits": ["primary": ["used_percent": 82.5, "window_minutes": 300], "secondary": ["used_percent": 40]]]]
        XCTAssertEqual(AgentWatch.codexUsage(obj), AgentWatch.CodexUsage(primary: 82.5, secondary: 40))
        XCTAssertNil(AgentWatch.codexUsage(["type": "event_msg", "payload": ["type": "task_started"]]))
    }

    func testRainSoonOnlyWhenDryNowAndWetWithinTwoHours() {
        let now = Date()
        func snap(code: Int, hours: [WeatherHour]) -> WeatherSnapshot {
            WeatherSnapshot(fetchedAt: now, placeName: "Here", latitude: 0, longitude: 0, temperature: 20, feelsLike: 20,
                            high: 22, low: 15, code: code, isDay: true, humidity: 50, windKmh: 5, precipitationChance: 10,
                            hours: hours, days: [])
        }
        let wetSoon = WeatherHour(time: now.addingTimeInterval(3600), temp: 18, code: 61, precipitationChance: 70)
        let wetLater = WeatherHour(time: now.addingTimeInterval(4 * 3600), temp: 18, code: 61, precipitationChance: 90)
        let unlikely = WeatherHour(time: now.addingTimeInterval(3600), temp: 18, code: 61, precipitationChance: 30)
        XCTAssertEqual(RainWatch.upcoming(snap(code: 1, hours: [wetSoon]), now: now), wetSoon)
        XCTAssertNil(RainWatch.upcoming(snap(code: 63, hours: [wetSoon]), now: now))     // already raining
        XCTAssertNil(RainWatch.upcoming(snap(code: 1, hours: [wetLater]), now: now))
        XCTAssertNil(RainWatch.upcoming(snap(code: 1, hours: [unlikely]), now: now))
    }
}

final class LiveDictationTests: XCTestCase {
    func testOnlyWordsTwoReadsAgreeOnAreSettled() {
        XCTAssertEqual(Dictation.settled(previous: "", current: "ship the"), "")
        XCTAssertEqual(Dictation.settled(previous: "ship the", current: "ship the build"), "ship the")
        // The newest word never counts, even when it matches.
        XCTAssertEqual(Dictation.settled(previous: "ship the build", current: "ship the build"), "ship the")
        // A revised word stops the settled run there.
        XCTAssertEqual(Dictation.settled(previous: "ship a build tonight", current: "ship the build tonight and"), "ship")
    }
}
