import XCTest
@testable import Zera

@MainActor
final class CodexAgentServiceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("zera-codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func service(writer: @escaping (Data) throws -> Void) throws -> CodexAgentService {
        let file = directory.appendingPathComponent("managed.json")
        let thread = CodexAgentService.Thread(id: "owned", title: "Test project", cwd: directory.path)
        try JSONEncoder().encode([thread]).write(to: file)
        let service = CodexAgentService(writer: writer, storage: file)
        service.receive(["method": "turn/started", "params": ["threadId": "owned", "turn": ["id": "turn1"]]])
        return service
    }
    private func approval(_ id: Int, thread: String = "owned", method: String = "item/commandExecution/requestApproval") -> [String: Any] {
        ["id": id, "method": method, "params": ["threadId": thread, "turnId": "turn1", "itemId": "item\(id)", "command": "printf fixture", "reason": "Harmless protocol fixture"]]
    }
    func testApprovalsRequireExplicitDecisionAndAreSentOnlyOnce() throws {
        var messages: [[String: Any]] = []
        let service = try service { messages.append(try JSONSerialization.jsonObject(with: $0) as! [String: Any]) }
        service.receive(approval(7)); service.receive(approval(7)); service.receive(approval(8))
        XCTAssertEqual(service.approvals.count, 2)
        XCTAssertTrue(messages.isEmpty, "An arriving request must never auto-approve")
        XCTAssertTrue(service.decide("7", allow: true))
        XCTAssertEqual((messages.first?["result"] as? [String: Any])?["decision"] as? String, "accept")
        XCTAssertFalse(service.decide("7", allow: true))
        XCTAssertFalse(service.decide("8", allow: true), "A double tap must not approve the next request")
        XCTAssertEqual(service.approvals.map(\.id), ["8"])
    }
    func testForeignThreadsAndStaleTurnsCannotBeApproved() throws {
        var messages: [[String: Any]] = []
        let service = try service { messages.append(try JSONSerialization.jsonObject(with: $0) as! [String: Any]) }
        service.receive(approval(1, thread: "desktop-chat"))
        var stale = approval(2); var params = stale["params"] as! [String: Any]; params["turnId"] = "old"; stale["params"] = params
        service.receive(stale)
        XCTAssertTrue(service.approvals.isEmpty)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0["error"] != nil && $0["result"] == nil })
    }
    func testFailedDecisionWriteKeepsRequestWaiting() throws {
        let service = try service { _ in throw NSError(domain: "fixture", code: 1) }
        service.receive(approval(9))
        XCTAssertFalse(service.decide("9", allow: true))
        XCTAssertEqual(service.approvals.count, 1)
    }
    func testTurnCompletionClearsStaleApprovalsAndPreservesFailureState() throws {
        let service = try service { _ in }
        service.receive(approval(10))
        service.receive(["method": "turn/completed", "params": ["threadId": "owned", "turn": ["id": "turn1", "status": "failed", "error": ["message": "fixture failure"]]]])
        XCTAssertEqual(service.threads.first?.status, "Failed")
        XCTAssertNil(service.threads.first?.turnID)
        XCTAssertTrue(service.approvals.isEmpty)
        XCTAssertFalse(service.decide("10", allow: true))
    }
    func testFileApprovalIncludesProposedDiff() throws {
        let service = try service { _ in }
        service.receive(["method": "item/started", "params": ["threadId": "owned", "item": ["type": "fileChange", "id": "item11", "changes": [["path": "sample.txt", "diff": "+sample"]]]]])
        service.receive(approval(11, method: "item/fileChange/requestApproval"))
        XCTAssertTrue(service.approvals.first?.detail.contains("+sample") == true)
    }
    func testQuestionsRequireAllAnswersAndKeepOriginalRPCID() throws {
        var message: [String: Any] = [:]
        let service = try service { message = try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        service.receive(["id": "question-id", "method": "item/tool/requestUserInput", "params": ["threadId": "owned", "turnId": "turn1", "questions": [["id": "q1", "question": "Choose a direction"], ["id": "q2", "question": "Name it"]]]])
        XCTAssertFalse(service.answer("\"question-id\"", values: ["q1": "one"]))
        XCTAssertTrue(service.answer("\"question-id\"", values: ["q1": "one", "q2": "two"]))
        XCTAssertEqual(message["id"] as? String, "question-id")
        XCTAssertTrue(service.approvals.isEmpty)
    }
}
