import XCTest
@testable import Zera

final class PokeReactionTests: XCTestCase {
    func testOnlyFourthQuickClickTriggersAnger() {
        var reaction = ZeraPokeReaction()
        XCTAssertFalse(reaction.register(at: 10))
        XCTAssertFalse(reaction.register(at: 10.3))
        XCTAssertFalse(reaction.register(at: 10.6))
        XCTAssertTrue(reaction.register(at: 10.9))
        XCTAssertTrue(reaction.isActive(at: 11))
    }

    func testSpacedClicksStartANewCount() {
        var reaction = ZeraPokeReaction()
        for time in [10.0, 10.3, 12.0, 12.3, 12.6] {
            XCTAssertFalse(reaction.register(at: time))
        }
        XCTAssertTrue(reaction.register(at: 12.9))
    }

    func testTappingDuringReactionDoesNotExtendIt() {
        var reaction = ZeraPokeReaction()
        for time in [0.0, 0.2, 0.4, 0.6] { _ = reaction.register(at: time) }
        XCTAssertFalse(reaction.register(at: 1))
        XCTAssertFalse(reaction.register(at: 2))
        XCTAssertEqual(reaction.startedAt, 0.6)
        XCTAssertFalse(reaction.isActive(at: 0.6 + ZeraPokeReaction.duration + 0.001))
        XCTAssertFalse(reaction.register(at: 4))
        XCTAssertFalse(reaction.register(at: 4.2))
        XCTAssertFalse(reaction.register(at: 4.4))
        XCTAssertTrue(reaction.register(at: 4.6))
    }

    func testMotionStaysBoundedAndSettlesBackToNeutral() {
        var reaction = ZeraPokeReaction()
        for time in [0.0, 0.2, 0.4, 0.6] { _ = reaction.register(at: time) }
        var moved = false
        for elapsed in stride(from: 0.0, through: ZeraPokeReaction.duration, by: 1.0 / 30.0) {
            let frame = reaction.motion(at: 0.6 + elapsed, reduceMotion: false)
            moved = moved || abs(frame.angle) > 0.1
            XCTAssertLessThanOrEqual(abs(frame.angle), 6)
            XCTAssertLessThanOrEqual(abs(frame.dy), 2.5)
            XCTAssertGreaterThanOrEqual(frame.sx, 1)
            XCTAssertLessThanOrEqual(frame.sx, 1.045)
            XCTAssertGreaterThanOrEqual(frame.sy, 0.95)
            XCTAssertLessThanOrEqual(frame.sy, 1)
        }
        XCTAssertTrue(moved)
        let neutral = reaction.motion(at: 4, reduceMotion: false)
        XCTAssertEqual(neutral.angle, 0)
        XCTAssertEqual(neutral.dy, 0)
        XCTAssertEqual(neutral.sx, 1)
        XCTAssertEqual(neutral.sy, 1)
        XCTAssertEqual(reaction.intensity(at: 4), 0)
    }

    func testReduceMotionKeepsExpressionWithoutShakeOrSquash() {
        var reaction = ZeraPokeReaction()
        for time in [0.0, 0.2, 0.4, 0.6] { _ = reaction.register(at: time) }
        XCTAssertTrue(reaction.isActive(at: 1))
        let frame = reaction.motion(at: 1, reduceMotion: true)
        XCTAssertEqual(frame.angle, 0)
        XCTAssertEqual(frame.dy, 0)
        XCTAssertEqual(frame.sx, 1)
        XCTAssertEqual(frame.sy, 1)
    }
}
