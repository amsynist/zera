import XCTest
@testable import Zera

final class MotionTests: XCTestCase {
    func testSpringStartsAtZeroAndSettlesAtOne() {
        XCTAssertEqual(Spring.curve(0), 0, accuracy: 0.0001)
        XCTAssertEqual(Spring.curve(1), 1, accuracy: 0.0001)
        XCTAssertEqual(Spring.curve(0.999), 1, accuracy: 0.01)
    }

    func testSpringOvershootStaysSubtle() {
        let peak = stride(from: 0.0, through: 1.0, by: 0.005).map(Spring.curve).max() ?? 0
        XCTAssertGreaterThan(peak, 1.0, "a little overshoot makes it feel springy")
        XCTAssertLessThan(peak, 1.05, "but never a bounce")
    }

    func testIndicatorJumpsWhenNotAnimated() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        let ind = SlidingIndicator(view: v)
        let r = NSRect(x: 3, y: 3, width: 60, height: 28)
        ind.move(to: r, animated: true)   // nothing shown yet, and not in a window: jumps
        XCTAssertEqual(ind.rect, r)
        XCTAssertFalse(ind.isMoving)
        let r2 = NSRect(x: 63, y: 3, width: 60, height: 28)
        ind.move(to: r2, animated: false)
        XCTAssertEqual(ind.rect, r2)
    }

    func testPressedRectShrinksAroundItsCentre() {
        let r = NSRect(x: 0, y: 0, width: 100, height: 32)
        XCTAssertEqual(r.pressed(false), r)
        let p = r.pressed(true)
        XCTAssertLessThan(p.width, r.width)
        XCTAssertEqual(p.midX, r.midX, accuracy: 0.001)
        XCTAssertEqual(p.midY, r.midY, accuracy: 0.001)
    }
}
