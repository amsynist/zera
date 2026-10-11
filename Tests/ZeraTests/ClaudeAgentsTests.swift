import XCTest
@testable import Zera

/// Agents Claude hands work to: each on its own timeline, matched to the call that started it.
final class ClaudeAgentsTests: XCTestCase {
    func testAgentsTakeTheirCallsInTheOrderTheyWereMade() {
        let s = ClaudeSession(id: "agents-order", cwd: "/tmp", at: Date())
        s.pendingAgentCalls = [(id: "c1", type: "general-purpose", task: "Research Bun", background: false),
                               (id: "c2", type: "Explore", task: "Map the repo", background: false),
                               (id: "c3", type: "general-purpose", task: "Research Deno", background: true)]
        XCTAssertEqual(s.agent("a1", type: "general-purpose", at: Date()).task, "Research Bun")
        XCTAssertEqual(s.agent("x1", type: "Explore", at: Date()).task, "Map the repo", "an agent takes a call of its own type")
        let third = s.agent("a2", type: "general-purpose", at: Date())
        XCTAssertEqual(third.task, "Research Deno")
        XCTAssertTrue(third.background)
        XCTAssertTrue(s.agent("a1", type: "general-purpose", at: Date()) === s.agents[0], "the same agent, not a new one")
        XCTAssertEqual(s.agent("late", type: "general-purpose", at: Date()).title, "general-purpose", "no call left: named by its type")
    }

    func testWorkingAgentsComeFirst() {
        let s = ClaudeSession(id: "agents-sort", cwd: "/tmp", at: Date())
        let now = Date()
        for (id, ended) in [("old", -300.0), ("run1", 0), ("recent", -10), ("run2", 0)] {
            let a = s.agent(id, type: "general-purpose", at: now.addingTimeInterval(-600))
            if ended != 0 { a.finish(at: now.addingTimeInterval(ended)) }
        }
        XCTAssertEqual(s.agentsByActivity.map(\.id), ["run1", "run2", "recent", "old"], "working first, then the latest to finish")
    }

    func testAnAgentFirstSeenFinishingTakesItsStartFromItsTranscript() throws {
        let data = Data("""
        {"type":"user","timestamp":"2026-10-11T07:00:00.000Z","message":{"role":"user","content":"Research Bun"}}
        {"type":"assistant","timestamp":"2026-10-11T07:01:30.000Z","message":{"role":"assistant","content":[]}}
        """.utf8)
        let start = try XCTUnwrap(ClaudeActivityService.transcriptStart(data))
        XCTAssertEqual(start.timeIntervalSince1970, 1_791_702_000, accuracy: 0.001)
        XCTAssertNil(ClaudeActivityService.transcriptStart(Data("not json".utf8)))
    }

    func testAnAgentsTranscriptReadsLikeTheTerminal() throws {
        XCTAssertEqual(ClaudeActivityService.agentTranscriptPath(session: "/Users/me/.claude/projects/-Users-me-app/abc-123.jsonl", agent: "a9f"),
                       "/Users/me/.claude/projects/-Users-me-app/abc-123/subagents/agent-a9f.jsonl")
        func line(_ o: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
        let jsonl = [
            "ent\":\"cut off by the 256 KB window\"}",
            try line(["type": "user", "timestamp": "2026-10-11T07:00:00.000Z", "message": ["role": "user", "content": [["type": "text", "text": "Research Bun"]]]]),
            try line(["type": "assistant", "timestamp": "2026-10-11T07:00:01.000Z", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "I'll start with the docs.\n\nThen benchmarks."],
                ["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["file_path": "/tmp/bun.md"]]]]]),
            try line(["type": "user", "timestamp": "2026-10-11T07:00:03.500Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_1", "content": "…"]]]]),
            try line(["type": "assistant", "timestamp": "2026-10-11T07:00:04.000Z", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_2", "name": "Bash", "input": ["command": "bun run bench"]]]]])
        ].joined(separator: "\n")
        let steps = ClaudeActivityService.transcriptSteps(Data(jsonl.utf8), cutAtStart: true)
        XCTAssertEqual(steps.map(\.verb), [ClaudeAgent.says, "Read", "Running"], "its prompt isn't a step; what it says is")
        XCTAssertEqual(steps[0].target, "I'll start with the docs. Then benchmarks.")
        XCTAssertTrue(steps[1].finished, "finished once its result came back")
        XCTAssertEqual(steps[1].duration ?? 0, 2.5, accuracy: 0.01)
        XCTAssertFalse(steps[2].finished, "still running")
    }

    private func event(_ sid: String, _ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["session_id": sid, "cwd": "/tmp", "hook_event_name": name].merging(extra) { $1 }
    }

    @MainActor
    private func runOneAgent(_ sid: String) -> ClaudeSession? {
        let svc = ClaudeActivityService.shared
        svc.apply(event(sid, "UserPromptSubmit", ["prompt": "Compare runtimes"]))
        svc.apply(event(sid, "PreToolUse", ["tool_name": "Agent", "tool_use_id": "call-1",
                                            "tool_input": ["description": "Research Bun", "prompt": "…", "subagent_type": "general-purpose"]]))
        svc.apply(event(sid, "SubagentStart", ["agent_id": "ag-1", "agent_type": "general-purpose"]))
        svc.apply(event(sid, "PreToolUse", ["agent_id": "ag-1", "agent_type": "general-purpose", "tool_name": "Read",
                                            "tool_use_id": "read-1", "tool_input": ["file_path": "/tmp/bun.md"]]))
        svc.apply(event(sid, "PostToolUse", ["agent_id": "ag-1", "agent_type": "general-purpose", "tool_name": "Read",
                                             "tool_use_id": "read-1", "tool_input": ["file_path": "/tmp/bun.md"]]))
        svc.apply(event(sid, "SubagentStop", ["agent_id": "ag-1", "agent_type": "general-purpose",
                                              "last_assistant_message": "Bun starts 3× faster.\nDetails follow."]))
        svc.apply(event(sid, "PostToolUse", ["tool_name": "Agent", "tool_use_id": "call-1", "tool_input": ["description": "Research Bun"]]))
        return svc.sessions[sid]
    }

    @MainActor
    func testEachAgentGetsItsOwnTimeline() throws {
        let svc = ClaudeActivityService.shared
        let was = svc.showAgents
        svc.showAgents = true
        defer { svc.showAgents = was }
        XCTAssertTrue(ClaudeActivityService.events.contains("SubagentStart") && ClaudeActivityService.events.contains("SubagentStop"))
        let s = try XCTUnwrap(runOneAgent("agents-own-\(UUID().uuidString)"))
        XCTAssertEqual(s.steps.map(\.verb), ["Delegate"], "the session's timeline keeps the hand-off, not the agent's reads")
        let a = try XCTUnwrap(s.agents.first)
        XCTAssertEqual(a.title, "Research Bun")
        XCTAssertEqual(a.steps.map(\.verb), ["Read"])
        XCTAssertTrue(a.steps.allSatisfy(\.finished))
        XCTAssertFalse(a.isRunning)
        XCTAssertEqual(a.result, "Bun starts 3× faster. Details follow.")
        XCTAssertEqual(s.filesTouched, ["/tmp/bun.md"], "files and tools still count for the whole session")
        XCTAssertEqual(s.runningAgents, 0)
    }

    @MainActor
    func testWithAgentsOffTheirStepsJoinTheSession() throws {
        let svc = ClaudeActivityService.shared
        let was = svc.showAgents
        svc.showAgents = false
        defer { svc.showAgents = was }
        let s = try XCTUnwrap(runOneAgent("agents-off-\(UUID().uuidString)"))
        XCTAssertEqual(s.steps.map(\.verb), ["Delegate", "Read"], "as it always was")
        XCTAssertEqual(s.agents.count, 1, "still followed, so turning it on mid-session shows them")
    }
}
