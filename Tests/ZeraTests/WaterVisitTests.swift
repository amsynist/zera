import XCTest
@testable import Zera

@MainActor
final class WaterVisitTests: XCTestCase {
    func testViewAcknowledgementAndReturnCallbacksFireOnce() {
        let view = WaterVisitView(frame: .zero)
        let now = CACurrentMediaTime()
        view.begin(at: now - 1)
        view.advanceAnimation(at: now)
        var acknowledgements = 0, returns = 0
        view.onAcknowledge = { acknowledgements += 1 }
        view.onReturn = { returns += 1 }
        view.acknowledge(); view.acknowledge()
        XCTAssertEqual(acknowledgements, 1)
        view.advanceAnimation(at: now + 3)
        view.advanceAnimation(at: now + 4)
        view.advanceAnimation(at: now + 5)
        XCTAssertEqual(returns, 1)
    }
    func testPersistsUntilAcknowledgedThenThanksAndReturnsExactlyOnce() {
        var motion = WaterVisitMotion(at: 10)
        motion.advance(at: 10.9, reduced: false)
        XCTAssertEqual(motion.stage, .waiting)
        motion.advance(at: 43_200, reduced: false)
        XCTAssertEqual(motion.stage, .waiting)
        XCTAssertTrue(motion.acknowledge(at: 43_200))
        XCTAssertFalse(motion.acknowledge(at: 43_201))
        motion.advance(at: 43_202.2, reduced: false)
        XCTAssertEqual(motion.stage, .returning)
        motion.advance(at: 43_203.1, reduced: false)
        XCTAssertEqual(motion.stage, .finished)
    }
    func testJumpEndsAtExactLandingWithNoLateAdjustment() {
        let motion = WaterVisitMotion(at: 0)
        let home = CGPoint(x: 700, y: 900), cursor = CGPoint(x: 130, y: 400)
        XCTAssertEqual(motion.position(at: 0, from: home, to: cursor), home)
        XCTAssertEqual(motion.position(at: 0.9, from: home, to: cursor), cursor)
        let almost = motion.position(at: 0.899, from: home, to: cursor)
        XCTAssertLessThan(hypot(almost.x - cursor.x, almost.y - cursor.y), 0.01)
    }
    func testLandingStaysOnCursorDisplayIncludingNegativeCoordinates() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 875), CGRect(x: -1440, y: -900, width: 1440, height: 875)] {
            for cursor in [CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.maxX, y: screen.maxY), CGPoint(x: screen.midX, y: screen.midY)] {
                let size = CGSize(width: 390, height: 180)
                let origin = WaterVisitMotion.landing(cursor: cursor, visibleFrame: screen, size: size)
                XCTAssertTrue(screen.contains(CGRect(origin: origin, size: size)))
            }
        }
    }
    func testReducedMotionKeepsAcknowledgementButSkipsFlights() {
        var motion = WaterVisitMotion(at: 0)
        motion.advance(at: 0, reduced: true)
        XCTAssertEqual(motion.stage, .waiting)
        XCTAssertTrue(motion.acknowledge(at: 1))
        motion.advance(at: 3.2, reduced: true)
        XCTAssertEqual(motion.stage, .returning)
        motion.advance(at: 3.2, reduced: true)
        XCTAssertEqual(motion.stage, .finished)
    }
}
