import AppKit
import XCTest
@testable import Zera

final class ZeraFaceTests: XCTestCase {
    func testSharedClockDoesNotRetainDetachedScreenMascots() {
        weak var retained: AnimatedZeraView?
        autoreleasepool {
            let mascot = AnimatedZeraView(frame: .zero)
            retained = mascot
            ZeraAnimationClock.shared.add(mascot)
        }
        XCTAssertNil(retained)
    }
    func testCursorFollowingUsesElapsedTimeAndRemainsBounded() {
        let slow = ZeraView(frame: .zero), fast = ZeraView(frame: .zero)
        slow.lookTarget = CGPoint(x: 1, y: -1); fast.lookTarget = slow.lookTarget
        slow.advanceAnimation(at: 0); fast.advanceAnimation(at: 0)
        for frame in 1...30 { slow.advanceAnimation(at: Double(frame) / 30) }
        for frame in 1...60 { fast.advanceAnimation(at: Double(frame) / 60) }
        XCTAssertEqual(slow.look.x, fast.look.x, accuracy: 0.001)
        XCTAssertEqual(slow.look.y, fast.look.y, accuracy: 0.001)
        XCTAssertGreaterThan(slow.look.x, 0.99)
        XCTAssertLessThanOrEqual(slow.look.x, 1)
        slow.lookTarget = .zero
        for frame in 31...60 { slow.advanceAnimation(at: Double(frame) / 30) }
        XCTAssertEqual(slow.look.x, 0, accuracy: 0.005)
    }

    func testBlinkClosesReopensAndResetsForReducedMotion() {
        var face = ZeraFace()
        face.advance(at: 0, reducedMotion: false, interval: 3)
        XCTAssertEqual(face.openness, 1)
        face.advance(at: 3, reducedMotion: false, interval: 3)
        face.advance(at: 3.08, reducedMotion: false, interval: 3)
        XCTAssertEqual(face.openness, 0)
        face.advance(at: 3.16, reducedMotion: false, interval: 3)
        XCTAssertEqual(face.openness, 0.5, accuracy: 0.001)
        face.advance(at: 3.23, reducedMotion: false, interval: 3)
        XCTAssertEqual(face.openness, 1)
        face.advance(at: 6, reducedMotion: false, interval: 3)
        face.advance(at: 6.08, reducedMotion: false, interval: 3)
        XCTAssertEqual(face.openness, 0)
        face.advance(at: 6.09, reducedMotion: true, interval: 3)
        XCTAssertEqual(face.openness, 1)
        face.advance(at: 100, reducedMotion: false, interval: 3)
        XCTAssertEqual(face.openness, 1)
    }
}
