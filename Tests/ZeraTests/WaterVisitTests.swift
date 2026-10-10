import XCTest
@testable import Zera

@MainActor
final class WaterVisitTests: XCTestCase {
    func testViewAcknowledgementAndReturnCallbacksFireOnce() {
        let view = WaterVisitView(frame: .zero)
        let now = CACurrentMediaTime()
        view.begin(at: now - WaterVisitMotion.arrivalDuration - 0.1)
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
        motion.advance(at: 10 + WaterVisitMotion.arrivalDuration, reduced: false)
        XCTAssertEqual(motion.stage, .waiting)
        motion.advance(at: 43_200, reduced: false)
        XCTAssertEqual(motion.stage, .waiting)
        XCTAssertTrue(motion.acknowledge(at: 43_200))
        XCTAssertFalse(motion.acknowledge(at: 43_201))
        motion.advance(at: 43_202.2, reduced: false)
        XCTAssertEqual(motion.stage, .returning)
        motion.advance(at: 43_202.2 + WaterVisitMotion.returnDuration + 0.01, reduced: false)
        XCTAssertEqual(motion.stage, .finished)
    }
    func testJumpEndsAtExactLandingWithNoLateAdjustment() {
        let motion = WaterVisitMotion(at: 0)
        let home = CGPoint(x: 700, y: 900), cursor = CGPoint(x: 130, y: 400)
        XCTAssertEqual(motion.position(at: 0, from: home, to: cursor), home)
        XCTAssertEqual(motion.position(at: WaterVisitMotion.arrivalDuration, from: home, to: cursor), cursor)
        let almost = motion.position(at: WaterVisitMotion.arrivalDuration - 0.001, from: home, to: cursor)
        XCTAssertLessThan(hypot(almost.x - cursor.x, almost.y - cursor.y), 0.01)
    }
    func testFlightAndReturnBodySettleWithoutAPop() {
        var motion = WaterVisitMotion(at: 0)
        let crouch = motion.body(at: 0.08)
        XCTAssertLessThan(crouch.sy, 1)
        XCTAssertGreaterThan(crouch.sx, 1)
        func settled(_ body: AnimatedZeraView.BodyMotion, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(body.sx, 1, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(body.sy, 1, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(body.y, 0, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(body.angle, 0, accuracy: 0.0001, file: file, line: line)
        }
        settled(motion.body(at: WaterVisitMotion.arrivalDuration - 0.00001))
        motion.advance(at: WaterVisitMotion.arrivalDuration, reduced: false)
        settled(motion.body(at: WaterVisitMotion.arrivalDuration))
        motion.acknowledge(at: 2)
        motion.advance(at: 4.2, reduced: false)
        settled(motion.body(at: 4.2 + WaterVisitMotion.returnDuration - 0.00001))
        motion.advance(at: 4.2 + WaterVisitMotion.returnDuration, reduced: false)
        XCTAssertEqual(motion.stage, .finished)
        settled(motion.body(at: 5.2))
    }
    func testWaitingChangesExpressionWithoutSwappingOrDismissingTheCharacter() {
        let view = WaterVisitView(frame: .zero)
        view.begin(at: 10)
        let waitingAt = 10 + WaterVisitMotion.arrivalDuration
        view.advanceAnimation(at: waitingAt)
        for (index, expression) in [ZeraExpression.neutral, .pleading, .unimpressed, .sleepy, .happy, .thoughtful].enumerated() {
            view.advanceAnimation(at: waitingAt + Double(index) * 12 + 1)
            XCTAssertEqual(view.motion.stage, .waiting)
            XCTAssertEqual(view.waitingExpression, expression)
            XCTAssertEqual(view.figure.pose, "boba")
        }
    }
    func testLandingStaysOnCursorDisplayIncludingNegativeCoordinates() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 875), CGRect(x: -1440, y: -900, width: 1440, height: 875)] {
            for cursor in [CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.maxX, y: screen.maxY), CGPoint(x: screen.midX, y: screen.midY)] {
                let size = WaterVisitView.size
                let origin = WaterVisitMotion.landing(cursor: cursor, visibleFrame: screen, size: size)
                XCTAssertTrue(screen.contains(CGRect(origin: origin, size: size)))
            }
        }
    }
    func testOneMomentPausesActingWithoutCompletingTheReminder() {
        let view = WaterVisitView(frame: NSRect(origin: .zero, size: WaterVisitView.size))
        view.begin(at: 0); view.advanceAnimation(at: WaterVisitMotion.arrivalDuration)
        var completions = 0
        view.onAcknowledge = { completions += 1 }
        view.pauseForAMoment(at: 2)
        view.advanceAnimation(at: 15)
        XCTAssertEqual(view.motion.stage, .waiting)
        XCTAssertEqual(view.figure.bodyMotion.angle, 0)
        XCTAssertEqual(view.waitingExpression, .happy)
        XCTAssertEqual(completions, 0)
        view.advanceAnimation(at: 26)
        XCTAssertEqual(view.waitingExpression, .unimpressed)
        view.acknowledge()
        XCTAssertEqual(completions, 1)
    }
    func testAnimationCanvasReservesSpaceWithoutShrinkingTheBuddy() {
        for mirrored in [false, true] {
            let view = WaterVisitView(frame: NSRect(origin: .zero, size: WaterVisitView.size))
            view.bubbleOnLeft = mirrored; view.layoutSubtreeIfNeeded()
            XCTAssertTrue(view.bounds.contains(view.figure.frame))
            XCTAssertEqual(view.figure.artworkBounds.size, CGSize(width: 102, height: 152))
            XCTAssertEqual(view.figure.animationPadding, 22)
            // The sprite retains its original scale; the extra transparent canvas
            // catches lean, bounce, squash and breathing outside the old rectangle.
            XCTAssertEqual(view.figure.frame.width, 146)
        }
    }
    func testBuddyDrawingStaysInsideCanvasDuringFlightWaitingAndRepeatedTaps() throws {
        let view = WaterVisitView(frame: NSRect(origin: .zero, size: WaterVisitView.size))
        view.layoutSubtreeIfNeeded()
        let figure = view.figure, start = CACurrentMediaTime()
        var motion = WaterVisitMotion(at: start)
        for elapsed in stride(from: 0.0, through: 72.0, by: 0.2) {
            // Include the strongest poke reaction alongside the visit's acting.
            if elapsed == 0 { for offset in [0.0, 0.04, 0.08, 0.12] { figure.tap(at: start + offset) } }
            motion.advance(at: start + elapsed, reduced: false)
            figure.bodyMotion = motion.body(at: start + elapsed)
            figure.advanceAnimation(at: start + elapsed)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(figure.bounds.width), pixelsHigh: Int(figure.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            figure.draw(figure.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
            for x in 0..<width {
                XCTAssertLessThan(bitmap.colorAt(x: x, y: 0)!.alphaComponent, 0.02)
                XCTAssertLessThan(bitmap.colorAt(x: x, y: height - 1)!.alphaComponent, 0.02)
            }
            for y in 0..<height {
                XCTAssertLessThan(bitmap.colorAt(x: 0, y: y)!.alphaComponent, 0.02)
                XCTAssertLessThan(bitmap.colorAt(x: width - 1, y: y)!.alphaComponent, 0.02)
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
