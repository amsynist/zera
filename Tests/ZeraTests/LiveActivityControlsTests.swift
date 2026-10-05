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
        let expand = try XCTUnwrap(view.subviews.compactMap { $0 as? GlowIconButton }
            .first { $0.accessibilityLabel() == "Open the Claude session" })
        XCTAssertFalse(button.frame.intersects(expand.frame))
        let point = NSPoint(x: button.frame.midX, y: button.frame.midY)
        XCTAssertTrue(view.hitTest(point) === button)
    }
}

final class LiveActivityExpandTests: XCTestCase {
    /// Only ⌄ opens the session; clicking the wing body or the copy button must not.
    func testOnlyTheChevronOpensTheSession() throws {
        let view = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        view.centerX = LiveActivityView.panelSize.width / 2
        let session = ClaudeSession(id: "test", cwd: "/tmp", at: Date())
        session.status = .running
        let request = HookRequest(id: "r", receivedAt: Date(), sessionID: session.id,
                                  toolName: "Bash", command: "echo hello", detail: nil, cwd: "/tmp")
        view.update(session: session, pending: request)
        view.layoutSubtreeIfNeeded()
        var opened = 0
        view.onTap = { opened += 1 }

        let copy = try XCTUnwrap(view.subviews.compactMap { $0 as? CommandCopyButton }.first)
        XCTAssertTrue(view.hitTest(NSPoint(x: copy.frame.midX, y: copy.frame.midY)) === copy)
        let expand = try XCTUnwrap(view.subviews.compactMap { $0 as? GlowIconButton }
            .first { $0.accessibilityLabel() == "Open the Claude session" })
        XCTAssertTrue(expand.accessibilityPerformPress())
        XCTAssertEqual(opened, 1)
    }
}

final class CommandCopyButtonDrawTests: XCTestCase {
    /// Drawing before the first layout (0 × 0) used to throw from NSBezierPath and crash the app.
    func testDrawsSafelyAtAnySize() {
        for size in [NSSize.zero, NSSize(width: 6, height: 6), NSSize(width: 44, height: 44)] {
            let b = CommandCopyButton(frame: NSRect(origin: .zero, size: size))
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 50, pixelsHigh: 50, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            b.draw(b.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
