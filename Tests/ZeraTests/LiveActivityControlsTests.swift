import AppKit
import XCTest
@testable import Zera

final class LiveActivityControlsTests: XCTestCase {
    private func minimizeButton(in view: LiveActivityView) throws -> GlowIconButton {
        try XCTUnwrap(view.subviews.compactMap { $0 as? GlowIconButton }
            .first { $0.accessibilityLabel() == "Minimize Claude activity" })
    }

    func testMinimizeRemainsReachableAcrossSessionStatesAndApprovals() throws {
        let view = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        let session = ClaudeSession(id: "test", cwd: "/tmp", at: Date())
        let request = HookRequest(id: "test", receivedAt: Date(), sessionID: session.id,
                                  toolName: "Bash", command: "pwd", detail: nil, cwd: "/tmp")
        var minimized = 0
        var opened = 0
        view.onMinimize = { minimized += 1 }
        view.onTap = { opened += 1 }
        for status in [ClaudeSession.Status.running, .waiting, .idle, .done] {
            session.status = status
            view.update(session: session, pending: nil)
            view.layoutSubtreeIfNeeded()
            let button = try minimizeButton(in: view)
            XCTAssertFalse(button.isHidden)
            XCTAssertTrue(view.bounds.contains(button.frame))
            XCTAssertTrue(button.accessibilityPerformPress())
        }
        view.update(session: session, pending: request)
        view.layoutSubtreeIfNeeded()
        let button = try minimizeButton(in: view)
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(minimized, 5)
        XCTAssertEqual(opened, 0)
    }

    func testMinimizeMovesToLeftWingWhenRightWingHasNoRoom() throws {
        let view = LiveActivityView(frame: NSRect(x: 0, y: 0, width: 800, height: 92))
        view.centerX = 650
        view.update(session: nil, pending: nil)
        view.layoutSubtreeIfNeeded()
        let button = try minimizeButton(in: view)
        XCTAssertFalse(button.isHidden)
        XCTAssertLessThan(button.frame.maxX, view.centerX)
        XCTAssertTrue(view.bounds.contains(button.frame))
        let files = try XCTUnwrap(view.subviews.compactMap { $0 as? GlowIconButton }
            .first { $0.accessibilityLabel() == "Open the session's files" })
        XCTAssertFalse(button.frame.intersects(files.frame))
        let point = NSPoint(x: button.frame.midX, y: button.frame.midY)
        XCTAssertTrue(view.hitTest(point) === button)
    }
}
