import AppKit
import XCTest
@testable import Zera

final class ReplyWingTests: XCTestCase {
    private func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }

    private func finished(reply: Bool) -> ClaudeSession {
        let s = ClaudeSession(id: "test-session", cwd: NSHomeDirectory(), at: Date())
        s.title = "Push the branch"
        s.status = .done
        s.promptAt = Date().addingTimeInterval(-60)
        if reply { s.replyUntil = Date().addingTimeInterval(20) }
        return s
    }

    func testDoneWingOffersReplyOnlyWhileTheSessionWaits() throws {
        let view = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        view.centerX = LiveActivityView.panelSize.width / 2
        view.update(session: finished(reply: false), pending: nil)
        view.layoutSubtreeIfNeeded()
        func replyButton() -> GlowPillButton? { descendants(view).compactMap { $0 as? GlowPillButton }.first { $0.accessibilityLabel() == "Reply" } }
        XCTAssertEqual(replyButton()?.isHidden, true, "no Reply once the session has really finished")
        view.update(session: finished(reply: true), pending: nil)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(replyButton()?.isHidden, false)
    }

    func testTypingAReplyAndPressingReturnSendsIt() throws {
        let view = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        view.centerX = LiveActivityView.panelSize.width / 2
        let s = finished(reply: true)
        view.update(session: s, pending: nil)
        var started = false, sent: String?, cancelled = false
        view.onReplyStart = { started = true; s.replyHeld = true }
        view.onReplySend = { sent = $0 }
        view.onReplyCancel = { cancelled = true }
        let reply = try XCTUnwrap(descendants(view).compactMap { $0 as? GlowPillButton }.first { $0.accessibilityLabel() == "Reply" })
        reply.onTap?()
        XCTAssertTrue(started)
        XCTAssertTrue(view.composing)
        view.update(session: s, pending: nil)          // the countdown pauses while you type
        XCTAssertTrue(view.composing)
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertFalse(field.superview?.isHidden ?? true)
        field.stringValue = "  cool, now tag it once merged  "
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(sent, "cool, now tag it once merged")
        XCTAssertFalse(view.composing)
        XCTAssertFalse(cancelled)
    }

    func testEscCancelsTheReply() throws {
        let view = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        let s = finished(reply: true)
        view.update(session: s, pending: nil)
        var cancelled = false
        view.onReplyStart = { s.replyHeld = true }
        view.onReplyCancel = { cancelled = true }
        try XCTUnwrap(descendants(view).compactMap { $0 as? GlowPillButton }.first { $0.accessibilityLabel() == "Reply" }).onTap?()
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(cancelled)
        XCTAssertFalse(view.composing)
    }
}
