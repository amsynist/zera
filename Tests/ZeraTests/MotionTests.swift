import XCTest
@testable import Zera

final class MotionTests: XCTestCase {
    func testEveryCurvedLightStyleStopsItsAnimationsWhenRemoved() {
        func layers(_ root: CALayer) -> [CALayer] {
            [root] + (root.sublayers ?? []).flatMap(layers) + (root.mask.map(layers) ?? [])
        }
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 140)
        let path = NotchGeometry.topLightPath(bounds: bounds, notch: CGRect(x: 400, y: 102, width: 200, height: 38))
        for style in EdgeLightStyle.allCases {
            let glow = GlowStrip(frame: bounds, edge: .top, depth: 72, color: .systemBlue, style: style, contour: path)
            if !Motion.reduced { XCTAssertTrue(layers(glow.layer).contains { !($0.animationKeys() ?? []).isEmpty }, "\(style) retains its motion treatment") }
            glow.stopLoops()
            XCTAssertTrue(layers(glow.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "hidden \(style) stops all motion")
        }
    }

    func testControlSelectionNeverOvershootsAndCharacterRespectsReducedMotion() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.02).map(Motion.selectionProgress)
        XCTAssertEqual(samples.first, 0)
        XCTAssertEqual(samples.last, 1)
        XCTAssertEqual(samples, samples.sorted())
        for kind in [CompanionGesture.Kind.acknowledge, .receive, .attention, .greet] {
            for time in stride(from: 0.0, through: 0.7, by: 0.02) {
                let reduced = CompanionGesture.sample(kind, elapsed: time, reduced: true)
                XCTAssertEqual(reduced.lift, 0)
                XCTAssertEqual(reduced.squash, 0)
                XCTAssertEqual(reduced.tilt, 0)
                let moving = CompanionGesture.sample(kind, elapsed: time, reduced: false)
                XCTAssertLessThanOrEqual(abs(moving.lift), 0.12)
                XCTAssertLessThanOrEqual(abs(moving.squash), 0.07)
            }
        }
    }
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

    @MainActor
    func testRepeatedLayoutDoesNotRestartTheSameIndicatorAnimation() throws {
        guard !Motion.reduced else { throw XCTSkip("Reduce Motion skips indicator animation") }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let indicator = SlidingIndicator(view: view)
        indicator.move(to: NSRect(x: 0, y: 0, width: 60, height: 28), animated: false)
        let target = NSRect(x: 60, y: 0, width: 60, height: 28)
        indicator.move(to: target, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        indicator.move(to: target, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertFalse(indicator.isMoving)
        XCTAssertEqual(indicator.rect, target)
        window.contentView = nil
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
