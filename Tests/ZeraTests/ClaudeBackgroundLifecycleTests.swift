import XCTest
@testable import Zera
final class ClaudeBackgroundLifecycleTests: XCTestCase {
 @MainActor func testBackgroundAgentDoesNotResurrectCompletedParent() throws {
  let svc = ClaudeActivityService.shared
  let sid = "pr22-review-\(UUID().uuidString)"
  func ev(_ name:String, _ extra:[String:Any] = [:]) -> [String:Any] {
   ["session_id":sid,"cwd":"/tmp","hook_event_name":name].merging(extra){$1}
  }
  svc.apply(ev("UserPromptSubmit", ["prompt":"Review"] ))
  svc.apply(ev("PreToolUse", ["tool_name":"Agent","tool_use_id":"call","tool_input":["description":"Background review","run_in_background":true]]))
  svc.apply(ev("SubagentStart", ["agent_id":"bg","agent_type":"general-purpose"]))
  svc.apply(ev("Stop"))
  let s = try XCTUnwrap(svc.sessions[sid])
  defer { svc.remove(s) }
  XCTAssertEqual(s.status, .done)
  let replyDeadline = Date().addingTimeInterval(60)
  s.replyUntil = replyDeadline
  s.replyHeld = true
  svc.apply(ev("PreToolUse", ["agent_id":"bg","agent_type":"general-purpose","tool_name":"Read","tool_use_id":"r","tool_input":["file_path":"/tmp/demo"]]))
  svc.apply(ev("PostToolUse", ["agent_id":"bg","tool_name":"Read","tool_use_id":"r"]))
  svc.apply(ev("SubagentStop", ["agent_id":"bg","last_assistant_message":"Done"]))
  XCTAssertEqual(s.replyUntil, replyDeadline)
  XCTAssertTrue(s.replyHeld)
  XCTAssertEqual(s.runningAgents, 0)
  XCTAssertEqual(s.status, .done, "Parent should remain completed after background agent finishes")
 }
}
