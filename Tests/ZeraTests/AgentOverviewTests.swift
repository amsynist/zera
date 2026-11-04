import XCTest
@testable import Zera

@MainActor
final class AgentOverviewTests: XCTestCase {
    func testClaudeStackReusesOriginalRowsAndDoesNotOfferCreation() throws {
        let service = ClaudeActivityService.shared
        let previous = service.ordered
        defer { service.preview(previous) }
        let session = ClaudeSession(id: "stack-test", cwd: "/tmp/Stack", at: Date())
        session.title = "Read the project"; session.status = .running
        service.preview([session])
        let view = AgentsView()
        view.frame = NSRect(x: 0, y: 0, width: view.cardWidth, height: view.desiredHeight)
        view.layoutSubtreeIfNeeded()
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        let row = try XCTUnwrap(descendants(view).compactMap { $0 as? ClaudeSessionRow }.first)
        session.status = .idle; view.reload(); view.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(view).contains { $0 === row })
        XCTAssertFalse(descendants(view).compactMap { $0 as? CardButton }.contains { !$0.isHiddenOrHasHiddenAncestor && $0.title.hasPrefix("New") })
        session.monitoredOnly = true
        service.requestStop(session)
        XCTAssertFalse(session.stopRequested)
        XCTAssertFalse(session.canReply)
    }
    private func item(_ provider: String, state: AgentOverviewItem.State) -> AgentOverviewItem {
        .init(id: provider + String(state.rawValue), provider: provider, providerName: provider.capitalized, title: "Test", project: "/fixture", activity: "Fixture activity", state: state, source: .observed(provider, "fixture"))
    }
    func testFinishedAndIdleSessionsClearNotchWhileOtherRunningWorkStaysVisible() {
        XCTAssertEqual(AgentOverview.notchActivity(for: [item("codex", state: .completed), item("claude", state: .idle)]), .none)
        XCTAssertEqual(AgentOverview.notchActivity(for: [item("codex", state: .completed), item("claude", state: .working)]), .running)
        XCTAssertEqual(AgentOverview.notchActivity(for: [item("codex", state: .waiting), item("claude", state: .working)]), .approval)
        let buddy = NotchBuddyView(frame: .zero)
        let source = ZeraView(frame: .zero); source.activity = .done
        buddy.source = source
        buddy.activityOverride = AgentOverview.notchActivity(for: [])
        XCTAssertEqual(buddy.activityOverride, ZeraActivity.none, "An explicit inactive state must mask stale completion on the source")
    }
    func testActiveOverviewGroupsProvidersAndIncludesFutureProviderWithoutComposerChanges() {
        let entries = [item("gemini", state: .working), item("codex", state: .waiting), item("claude", state: .working), item("claude", state: .completed)]
        let groups = AgentOverview.grouped(entries, provider: nil, state: 0)
        XCTAssertEqual(groups.map(\.0), ["claude", "codex", "gemini"])
        XCTAssertEqual(groups.flatMap(\.1).count, 3)
    }
    func testApprovalFilterCannotMixInOtherProvidersOrCompletedWork() {
        let entries = [item("codex", state: .waiting), item("claude", state: .waiting), item("codex", state: .working), item("codex", state: .completed)]
        let rows = AgentOverview.grouped(entries, provider: "codex", state: 2).flatMap(\.1)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.allSatisfy { $0.provider == "codex" && $0.needsApproval })
    }
}

final class CodexMonitoringIdentityTests: XCTestCase {
    func testToolPatchAndCompletionKeepStructuredDataWithoutDuplicates() throws {
        let patch = "*** Begin Patch\n*** Update File: Sources/Navigation.swift\n@@\n-old\n+new\n*** End Patch"
        let start = try XCTUnwrap(AgentWatch.codexEvent(["type": "response_item", "timestamp": "2026-11-02T00:00:00.000Z", "payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "call-1", "input": patch]], path: "/tmp/fixture.jsonl"))
        XCTAssertEqual(start.records.first?.files, ["Sources/Navigation.swift"])
        XCTAssertEqual(start.records.first?.patch, patch)
        let finish = try XCTUnwrap(AgentWatch.codexEvent(["type": "response_item", "payload": ["type": "custom_tool_call_output", "call_id": "call-1", "output": "Success"]], path: "/tmp/fixture.jsonl"))
        let merged = AgentWatch.mergeRecords(AgentWatch.mergeRecords([], start.records), finish.records + start.records)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.tool, "apply_patch")
        XCTAssertTrue(merged.first?.finished == true)
        XCTAssertEqual(merged.first?.result, "Success")
        XCTAssertEqual(merged.first?.files.count, 1)
    }
    func testReasoningAndRepliesRefreshActiveDesktopChat() {
        for payload: [String: Any] in [["type": "reasoning"], ["type": "message", "role": "assistant"]] {
            let event = AgentWatch.codexEvent(["type": "response_item", "payload": payload], path: "/tmp/session.jsonl")
            XCTAssertEqual(event?.state, .working)
            XCTAssertNotNil(event?.activity)
        }
        XCTAssertNil(AgentWatch.codexEvent(["type": "response_item", "payload": ["type": "message", "role": "user"]], path: "/tmp/session.jsonl"))
    }
    func testInternalPermissionWorkersAreExcludedButRealSubagentsRemain() {
        XCTAssertFalse(AgentWatch.isCodingSession(["source": ["subagent": ["other": "guardian"]]]))
        XCTAssertTrue(AgentWatch.isCodingSession(["source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]]]))
        XCTAssertTrue(AgentWatch.isCodingSession(["source": "cli"]))
    }
    func testCurrentProtocolReportsWorkInsteadOfRawWrapperCode() {
        let event = AgentWatch.codexEvent(["type": "response_item", "payload": ["type": "custom_tool_call", "name": "exec", "input": "text(await tools.exec_command({cmd: 'swift test'}))"]], path: "/tmp/session.jsonl")
        XCTAssertEqual(event?.activity, "Running tests")
        XCTAssertEqual(event?.state, .working)
    }
}
