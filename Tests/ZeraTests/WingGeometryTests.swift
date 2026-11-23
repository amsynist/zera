import AppKit
import XCTest
@testable import Zera

final class WingGeometryTests: XCTestCase {
    func testApprovalExpansionAndCollapseInvalidateTheWingFaceAfterLayout() throws {
        let view = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        let session = ClaudeSession(id: "wing-layout", cwd: "/tmp", at: Date())
        session.status = .running
        let request = HookRequest(id: "wing-layout", receivedAt: Date(), sessionID: session.id,
                                  toolName: "Bash", command: "echo Review sample checks", detail: nil, cwd: "/tmp")
        view.update(session: session, pending: nil)
        view.layoutSubtreeIfNeeded()
        let face = try XCTUnwrap(view.subviews.compactMap { $0 as? WingFace }.first)
        let beyondRunningWing = NSPoint(x: 1400, y: view.bounds.midY)
        XCTAssertFalse(view.wingContains(beyondRunningWing))

        for pending: HookRequest? in [request, nil] {
            view.update(session: session, pending: pending)
            // The existing face can already have been painted before the new geometry is laid out.
            face.needsDisplay = false
            face.layer?.displayIfNeeded()
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.wingContains(beyondRunningWing), pending != nil)
            XCTAssertTrue(face.layer?.needsDisplay() == true, "A changed outline must invalidate the painted face")
        }
    }

    func testLeftAndRightOutlinesAreMirrored() {
        let left = LiveActivityView.wing(body: NSRect(x: 260, y: 16, width: 430, height: 60),
                                         inward: 1, tip: NSPoint(x: 746, y: 46))
        let right = LiveActivityView.wing(body: NSRect(x: 830, y: 16, width: 430, height: 60),
                                          inward: -1, tip: NSPoint(x: 774, y: 46))
        for x in stride(from: 250.5, through: 750, by: 4) {
            for y in stride(from: 10.5, through: 82, by: 4) {
                XCTAssertEqual(left.contains(NSPoint(x: x, y: y)),
                               right.contains(NSPoint(x: 1520 - x, y: y)), "Mismatch at \(x), \(y)")
            }
        }
    }

    func testCenterCurveIsSymmetricAboveAndBelowWingMidline() {
        let wing = LiveActivityView.wing(body: NSRect(x: 260, y: 16, width: 430, height: 60),
                                         inward: 1, tip: NSPoint(x: 746, y: 46))
        for x in stride(from: 680.25, through: 749, by: 2) {
            for y in stride(from: 10.25, through: 46, by: 2) {
                XCTAssertEqual(wing.contains(NSPoint(x: x, y: y)),
                               wing.contains(NSPoint(x: x, y: 92 - y)), "Mismatch at \(x), \(y)")
            }
        }
    }
}
