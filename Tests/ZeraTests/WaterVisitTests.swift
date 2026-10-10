import XCTest
@testable import Zera

@MainActor
final class WaterVisitTests: XCTestCase {
    func testJumpWaitThenDrinkAndGoHomeExactlyOnce() {
        var motion = WaterVisitMotion(at: 10)
        XCTAssertEqual(motion.stage, .jumping)
        motion.advance(at: 10 + WaterVisitMotion.jumpDuration, reduced: false)
        XCTAssertEqual(motion.stage, .waiting)
        XCTAssertTrue(motion.drank(at: 12))
        XCTAssertFalse(motion.drank(at: 12.1))
        XCTAssertFalse(motion.later(at: 12.1))
        motion.advance(at: 12 + WaterVisitMotion.drinkDuration + 0.001, reduced: false)
        XCTAssertEqual(motion.stage, .returning)
        motion.advance(at: 12 + WaterVisitMotion.drinkDuration + WaterVisitMotion.returnDuration + 0.002, reduced: false)
        XCTAssertEqual(motion.stage, .finished)
        XCTAssertEqual(motion.outcome, .drank)
    }
    func testLaterGoesHomeWithoutDrinking() {
        var motion = WaterVisitMotion(at: 0)
        XCTAssertFalse(motion.later(at: 0.2), "10 min only works once she's in the glass")
        motion.advance(at: WaterVisitMotion.jumpDuration, reduced: false)
        XCTAssertTrue(motion.later(at: 2))
        XCTAssertEqual(motion.stage, .returning)
        XCTAssertEqual(motion.outcome, .later)
    }
    func testLeftAloneSheGoesHomeAfterThirtySeconds() {
        var motion = WaterVisitMotion(at: 0)
        motion.advance(at: WaterVisitMotion.jumpDuration, reduced: false)
        motion.advance(at: WaterVisitMotion.jumpDuration + WaterVisitMotion.ignoreAfter - 0.01, reduced: false)
        XCTAssertEqual(motion.stage, .waiting)
        motion.advance(at: WaterVisitMotion.jumpDuration + WaterVisitMotion.ignoreAfter, reduced: false)
        XCTAssertEqual(motion.stage, .returning)
        XCTAssertEqual(motion.outcome, .ignored)
    }
    func testReducedMotionSkipsTheJumps() {
        var motion = WaterVisitMotion(at: 0)
        motion.advance(at: 0, reduced: true)
        XCTAssertEqual(motion.stage, .waiting)
        XCTAssertTrue(motion.drank(at: 1))
        motion.advance(at: 1, reduced: true)
        XCTAssertEqual(motion.stage, .returning)
        motion.advance(at: 1, reduced: true)
        XCTAssertEqual(motion.stage, .finished)
    }
    func testArcStartsAndEndsExactlyAndRisesAboveBothEnds() {
        let home = CGPoint(x: 700, y: 880), glass = CGPoint(x: 220, y: 400)
        XCTAssertEqual(WaterVisitMotion.arc(0, from: home, to: glass), home)
        XCTAssertEqual(WaterVisitMotion.arc(1, from: home, to: glass), glass)
        let low = CGPoint(x: 100, y: 300), high = CGPoint(x: 500, y: 320)
        let peak = (0...20).map { WaterVisitMotion.arc(CGFloat($0) / 20, from: low, to: high).y }.max()!
        XCTAssertGreaterThan(peak, high.y + 20)
    }
    func testGlassPopsUpAndSettlesAtFullSize() {
        XCTAssertEqual(WaterVisitMotion.popScale(0), 0)
        XCTAssertGreaterThan(WaterVisitMotion.popScale(WaterVisitMotion.popDuration * 0.6), 1)
        XCTAssertEqual(WaterVisitMotion.popScale(WaterVisitMotion.popDuration), 1, accuracy: 0.0001)
        XCTAssertEqual(WaterVisitMotion.squash(0.5).sx, 1)
        XCTAssertEqual(WaterVisitMotion.squash(0.5).sy, 1)
    }
    func testGlassStaysOnTheCursorsScreenAndNeverUnderThePointer() {
        let size = WaterVisitView.size
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 875), CGRect(x: -1440, y: -900, width: 1440, height: 875)] {
            for cursor in [CGPoint(x: screen.midX, y: screen.midY), CGPoint(x: screen.maxX - 4, y: screen.midY),
                           CGPoint(x: screen.minX + 4, y: screen.maxY - 4), CGPoint(x: screen.midX, y: screen.minY + 4)] {
                let place = WaterVisitView.placement(cursor: cursor, visibleFrame: screen)
                XCTAssertTrue(screen.contains(CGRect(origin: place.origin, size: size)), "\(cursor) on \(screen)")
            }
            // Away from the edges, the glass sits beside the pointer, not under it.
            let cursor = CGPoint(x: screen.midX, y: screen.midY)
            let place = WaterVisitView.placement(cursor: cursor, visibleFrame: screen)
            let g = WaterVisitView.glassRect(mirrored: place.mirrored)
            let glass = CGRect(x: place.origin.x + g.minX, y: place.origin.y + size.height - g.maxY, width: g.width, height: g.height)
            XCTAssertFalse(glass.contains(cursor))
            XCTAssertLessThan(hypot(glass.minX - cursor.x, glass.maxY - cursor.y), 40)
        }
        // Near the right edge the reminder goes on the glass's left.
        let edge = CGRect(x: 0, y: 0, width: 1440, height: 875)
        XCTAssertTrue(WaterVisitView.placement(cursor: CGPoint(x: 1400, y: 400), visibleFrame: edge).mirrored)
        XCTAssertFalse(WaterVisitView.placement(cursor: CGPoint(x: 400, y: 400), visibleFrame: edge).mirrored)
    }
    func testViewCallbacksFireOnceAndZeraFliesBothWays() {
        let view = WaterVisitView(frame: NSRect(origin: .zero, size: WaterVisitView.size))
        view.home = CGPoint(x: 720, y: 880); view.origin = CGPoint(x: 200, y: 300)
        view.reducedMotion = { false }   // CI machines can have Reduce Motion on
        var drank = 0, returns: [WaterVisitMotion.Outcome?] = [], flights: [CGPoint?] = []
        view.onDrank = { drank += 1 }
        view.onReturn = { returns.append($0) }
        view.onJumper = { point, _, _ in flights.append(point) }
        view.begin(at: 100)
        view.advanceAnimation(at: 100.3)
        XCTAssertNotNil(flights.last ?? nil, "she's in the air on the way down")
        view.advanceAnimation(at: 100 + WaterVisitMotion.jumpDuration + 0.01)
        XCTAssertEqual(view.motion.stage, .waiting)
        XCTAssertNil(flights.last ?? CGPoint(x: -1, y: -1), "she's landed")
        view.drank(); view.drank()
        XCTAssertEqual(drank, 1)
        let back = view.motion.changedAt + WaterVisitMotion.drinkDuration
        view.advanceAnimation(at: back + 0.01)
        view.advanceAnimation(at: back + 0.3)
        XCTAssertNotNil(flights.last ?? nil, "she's in the air on the way home")
        view.advanceAnimation(at: back + 2)
        view.advanceAnimation(at: back + 3)
        XCTAssertEqual(returns.count, 1)
        XCTAssertEqual(returns.first ?? nil, .drank)
    }
    func testOnlyTheButtonsTakeClicks() {
        let view = WaterVisitView(frame: NSRect(origin: .zero, size: WaterVisitView.size))
        view.begin(at: 0)
        view.advanceAnimation(at: 5)
        view.layoutSubtreeIfNeeded()
        // An empty corner of the window passes clicks through to whatever is underneath.
        XCTAssertNil(view.hitTest(NSPoint(x: 4, y: 4)))
    }
}
