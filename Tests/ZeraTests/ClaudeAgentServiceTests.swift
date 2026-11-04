import XCTest
@testable import Zera

@MainActor
final class ClaudeAgentServiceTests: XCTestCase {
    private func request(_ id: String, tool: String = "Bash", input: [String: Any] = ["command": "/usr/bin/true"]) -> [String: Any] {
        ["type": "control_request", "request_id": id, "request": ["subtype": "can_use_tool", "tool_name": tool, "input": input]]
    }
    func testApprovalRepliesOnceWithOriginalRequestAndInput() throws {
        var frames: [[String: Any]] = []
        let service = ClaudeAgentService(writer: { frames.append(try JSONSerialization.jsonObject(with: $0) as! [String: Any]) })
        let id = service.create(cwd: "/tmp/fixture")
        XCTAssertTrue(service.send("test", to: id))
        service.receive(request("permission-1"), threadID: id)
        XCTAssertEqual(service.approvals.count, 1)
        let approval = try XCTUnwrap(service.approvals.first)
        XCTAssertTrue(service.decide(approval.id, allow: true))
        XCTAssertFalse(service.decide(approval.id, allow: true))
        let response = try XCTUnwrap(frames.last?["response"] as? [String: Any])
        XCTAssertEqual(response["request_id"] as? String, "permission-1")
        let result = try XCTUnwrap(response["response"] as? [String: Any])
        XCTAssertEqual(result["behavior"] as? String, "allow")
        XCTAssertEqual((result["updatedInput"] as? [String: String])?["command"], "/usr/bin/true")
        XCTAssertNil(result["updatedPermissions"])
    }
    func testFailedDecisionStaysPendingAndCanBeRetried() throws {
        var fail = false
        let service = ClaudeAgentService(writer: { _ in if fail { throw CocoaError(.fileWriteUnknown) } })
        let id = service.create(cwd: "/tmp/fixture"); _ = service.send("test", to: id)
        service.receive(request("permission-2"), threadID: id)
        let approval = try XCTUnwrap(service.approvals.first)
        fail = true
        XCTAssertFalse(service.decide(approval.id, allow: false))
        XCTAssertEqual(service.approvals.count, 1)
        fail = false
        XCTAssertTrue(service.decide(approval.id, allow: false))
        XCTAssertTrue(service.approvals.isEmpty)
    }
    func testForeignAndStoppedSessionsCannotReceiveApprovals() {
        let service = ClaudeAgentService(writer: { _ in })
        let id = service.create(cwd: "/tmp/fixture"); _ = service.send("test", to: id)
        service.receive(request("foreign"), threadID: "not-owned")
        XCTAssertTrue(service.approvals.isEmpty)
        service.stop(id)
        service.receive(request("stale"), threadID: id)
        XCTAssertTrue(service.approvals.isEmpty)
        XCTAssertEqual(service.threads.first?.status, "Stopped")
    }
    func testQuestionRequiresAllAnswersAndPreservesTheQuestion() throws {
        var output: [String: Any] = [:]
        let service = ClaudeAgentService(writer: { output = try JSONSerialization.jsonObject(with: $0) as! [String: Any] })
        let id = service.create(cwd: "/tmp/fixture"); _ = service.send("test", to: id)
        service.receive(request("question", tool: "AskUserQuestion", input: ["questions": [["question": "Which option?", "options": [["label": "One"]]]]]), threadID: id)
        let approval = try XCTUnwrap(service.approvals.first)
        XCTAssertFalse(service.decide(approval.id, allow: true))
        XCTAssertTrue(service.decide(approval.id, allow: true, answers: ["Which option?": "One"]))
        let response = try XCTUnwrap(output["response"] as? [String: Any])
        let result = try XCTUnwrap(response["response"] as? [String: Any])
        let input = try XCTUnwrap(result["updatedInput"] as? [String: Any])
        XCTAssertNotNil(input["questions"])
        XCTAssertEqual((input["answers"] as? [String: String])?["Which option?"], "One")
    }
    func testStreamingAndFinalResultDoNotDuplicateTheReply() {
        let service = ClaudeAgentService(writer: { _ in })
        let id = service.create(cwd: "/tmp/fixture"); _ = service.send("test", to: id)
        service.receive(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hello"]]], threadID: id)
        service.receive(["type": "assistant", "message": ["content": [["type": "text", "text": "Hello"]]]], threadID: id)
        service.receive(["type": "result", "subtype": "success", "result": "Hello", "session_id": id], threadID: id)
        XCTAssertEqual(service.threads.first?.status, "Completed")
        XCTAssertEqual(service.threads.first?.transcript.components(separatedBy: "Hello").count, 2)
        XCTAssertFalse(service.isWorking(id))
        XCTAssertTrue(service.threads.first?.hasHistory == true)
        XCTAssertTrue(service.send("another turn", to: id))
    }
    func testCancelledApprovalDisappearsAndCannotBeAnswered() throws {
        let service = ClaudeAgentService(writer: { _ in })
        let id = service.create(cwd: "/tmp/fixture"); _ = service.send("test", to: id)
        service.receive(request("cancelled"), threadID: id)
        let approval = try XCTUnwrap(service.approvals.first)
        service.receive(["type": "control_cancel_request", "request_id": "cancelled"], threadID: id)
        XCTAssertTrue(service.approvals.isEmpty)
        XCTAssertFalse(service.decide(approval.id, allow: true))
    }
    func testBackgroundAgentKeepsControlChannelUntilFollowUpAndIdle() {
        let service = ClaudeAgentService(writer: { _ in })
        let id = service.create(cwd: "/tmp/fixture"); _ = service.send("test", to: id)
        service.receive(["type": "system", "subtype": "session_state_changed", "state": "running"], threadID: id)
        service.receive(["type": "system", "subtype": "task_started", "task_id": "agent-1", "task_type": "local_agent"], threadID: id)
        service.receive(["type": "result", "subtype": "success", "result": "Delegated"], threadID: id)
        XCTAssertTrue(service.isWorking(id))
        service.receive(["type": "system", "subtype": "task_notification", "task_id": "agent-1"], threadID: id)
        service.receive(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Done"]]], threadID: id)
        service.receive(["type": "result", "subtype": "success", "result": "Done"], threadID: id)
        XCTAssertTrue(service.isWorking(id))
        service.receive(["type": "system", "subtype": "session_state_changed", "state": "idle"], threadID: id)
        XCTAssertFalse(service.isWorking(id))
        XCTAssertEqual(service.threads.first?.status, "Completed")
        XCTAssertTrue(service.threads.first?.transcript.contains("Delegated") == true)
        XCTAssertTrue(service.threads.first?.transcript.contains("Done") == true)
    }

}
