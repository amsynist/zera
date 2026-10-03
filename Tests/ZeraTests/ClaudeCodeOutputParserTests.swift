import XCTest
@testable import Zera

/// Event shapes below are copied from a real `claude -p --output-format stream-json --verbose
/// --include-partial-messages` run (Claude Code 2.1.x), trimmed to the fields Zera reads.
final class ClaudeCodeOutputParserTests: XCTestCase {

    private func line(_ json: String) -> Data { Data((json + "\n").utf8) }

    func testStreamJSONHappyPath() {
        let p = ClaudeCodeOutputParser(format: .streamJSON)
        var events: [ClaudeStreamEvent] = []
        events += p.feed(line(#"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"abc-123","model":"claude-sonnet-4-5","tools":[]}"#))
        events += p.feed(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}},"session_id":"abc-123","parent_tool_use_id":null}"#))
        events += p.feed(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}},"session_id":"abc-123","parent_tool_use_id":null}"#))
        events += p.feed(line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}]},"parent_tool_use_id":null,"session_id":"abc-123"}"#))
        events += p.feed(line(#"{"type":"result","subtype":"success","is_error":false,"result":"Hello","session_id":"abc-123","num_turns":1,"total_cost_usd":0.004}"#))
        events += p.finish(exitStatus: 0, stderr: "")

        XCTAssertEqual(events.first, .sessionStarted(id: "abc-123", model: "claude-sonnet-4-5"))
        XCTAssertTrue(events.contains(.textDelta("Hel")))
        XCTAssertTrue(events.contains(.textDelta("lo")))
        XCTAssertTrue(events.contains(.assistantMessage(text: "Hello", usedTools: false)))
        guard case .completed(let result, let sid, let cost, let turns)? = events.last else { return XCTFail("no completed event") }
        XCTAssertEqual(result, "Hello")
        XCTAssertEqual(sid, "abc-123")
        XCTAssertEqual(cost ?? 0, 0.004, accuracy: 0.0001)
        XCTAssertEqual(turns, 1)
        XCTAssertEqual(p.sessionID, "abc-123")

        var b = ClaudeTranscriptBuilder()
        events.forEach { b.apply($0, fileName: "spec.pdf") }
        XCTAssertTrue(b.isDone)
        XCTAssertEqual(b.display, "Hello")
    }

    func testChunksSplitMidLineProduceTheSameEvents() {
        let full = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ABC"}},"parent_tool_use_id":null}"# + "\n"
        let p = ClaudeCodeOutputParser(format: .streamJSON)
        let bytes = Array(full.utf8)
        var events: [ClaudeStreamEvent] = []
        events += p.feed(Data(bytes[0..<20]))
        XCTAssertTrue(events.isEmpty, "no newline yet → no event")
        events += p.feed(Data(bytes[20...]))
        XCTAssertEqual(events, [.textDelta("ABC")])
    }

    func testToolUsePreambleIsNotTheAnswer() {
        let p = ClaudeCodeOutputParser(format: .streamJSON)
        var events: [ClaudeStreamEvent] = []
        events += p.feed(line(#"{"type":"system","subtype":"init","session_id":"s1"}"#))
        events += p.feed(line(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me read it."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/Users/me/Docs/spec.pdf"}}]},"parent_tool_use_id":null,"session_id":"s1"}"#))
        events += p.feed(line(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"PDF file read"}]},"session_id":"s1"}"#))
        events += p.feed(line(#"{"type":"assistant","message":{"content":[{"type":"text","text":"## Summary\nIt is a spec."}]},"parent_tool_use_id":null,"session_id":"s1"}"#))
        events += p.feed(line(#"{"type":"result","subtype":"success","is_error":false,"result":"## Summary\nIt is a spec.","session_id":"s1","num_turns":2}"#))

        XCTAssertTrue(events.contains(.assistantMessage(text: "Let me read it.", usedTools: true)))
        XCTAssertTrue(events.contains(.toolUse(name: "Read", target: "spec.pdf")))
        var b = ClaudeTranscriptBuilder()
        var statuses: [String] = []
        for e in events {
            b.apply(e, fileName: "spec.pdf")
            if let s = b.status { statuses.append(s) }
        }
        XCTAssertTrue(statuses.contains("Reading spec.pdf…"))
        XCTAssertEqual(b.display, "## Summary\nIt is a spec.")
        XCTAssertFalse(b.display.contains("Let me read it"))
    }

    func testSubagentChatterIsIgnored() {
        let p = ClaudeCodeOutputParser(format: .streamJSON)
        let e = p.feed(line(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"inner"}},"parent_tool_use_id":"toolu_1"}"#))
        XCTAssertTrue(e.isEmpty)
    }

    func testMalformedAndUnknownLinesNeverCrash() {
        let p = ClaudeCodeOutputParser(format: .streamJSON)
        var events: [ClaudeStreamEvent] = []
        events += p.feed(Data("not json at all\n".utf8))
        events += p.feed(Data("{\"type\":\"rate_limit_event\",\"rate_limit_info\":{}}\n".utf8))
        events += p.feed(Data("{\"type\":\"autocompact_state\",\"value\":{}}\n".utf8))
        events += p.feed(Data("{truncated\n".utf8))
        events += p.feed(Data("[1,2,3]\n".utf8))
        XCTAssertTrue(events.isEmpty)
        let fin = p.finish(exitStatus: 1, stderr: "")
        guard case .failed(_, let kind)? = fin.last else { return XCTFail("expected failure") }
        XCTAssertEqual(kind, .other)
    }

    func testErrorResultSubtypes() {
        let p = ClaudeCodeOutputParser(format: .streamJSON)
        let e = p.feed(line(#"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s","num_turns":8}"#))
        XCTAssertEqual(e, [.failed(message: "Claude ran out of steps before finishing.", kind: .maxTurns)])

        let p2 = ClaudeCodeOutputParser(format: .streamJSON)
        let e2 = p2.feed(line(#"{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":401,"errors":["authentication_error: invalid token"]}"#))
        guard case .failed(_, let kind)? = e2.first else { return XCTFail() }
        XCTAssertEqual(kind, .authentication)
    }

    func testFailureClassification() {
        XCTAssertEqual(ClaudeCodeOutputParser.failure(from: "Not logged in. Please run /login", exitStatus: 1),
                       .failed(message: "Claude Code needs authentication.", kind: .authentication))
        XCTAssertEqual(ClaudeCodeOutputParser.failure(from: "No conversation found with session ID: 0000", exitStatus: 1),
                       .failed(message: "That conversation is gone — ask again to start fresh.", kind: .resumeMissing))
        XCTAssertEqual(ClaudeCodeOutputParser.failure(from: "TypeError: fetch failed (ENOTFOUND api.anthropic.com)", exitStatus: 1),
                       .failed(message: "Claude couldn't be reached.", kind: .network))
        if case .failed(let m, let k) = ClaudeCodeOutputParser.failure(from: "", exitStatus: 137) {
            XCTAssertEqual(k, .other); XCTAssertTrue(m.contains("137"))
        } else { XCTFail() }
    }

    func testJSONFormat() {
        let p = ClaudeCodeOutputParser(format: .json)
        _ = p.feed(Data(#"Warning: something on stdout first {"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"j1"}"#.utf8))
        let events = p.finish(exitStatus: 0, stderr: "")
        XCTAssertEqual(events, [.completed(result: "Done.", sessionID: "j1", costUSD: nil, turns: nil)])
    }

    func testTextFormat() {
        let p = ClaudeCodeOutputParser(format: .text)
        _ = p.feed(Data("Plain answer\n".utf8))
        XCTAssertEqual(p.finish(exitStatus: 0, stderr: ""), [.completed(result: "Plain answer", sessionID: nil, costUSD: nil, turns: nil)])
    }

    func testStreamWithoutResultButWithTextStillCompletes() {
        let p = ClaudeCodeOutputParser(format: .streamJSON)
        _ = p.feed(line(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Partial but final"}]},"parent_tool_use_id":null}"#))
        let fin = p.finish(exitStatus: 0, stderr: "")
        guard case .completed(let r, _, _, _)? = fin.last else { return XCTFail() }
        XCTAssertEqual(r, "Partial but final")
    }
}
