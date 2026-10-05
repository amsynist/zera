import AppKit
import XCTest
@testable import Zera

final class BannerCountdownTests: XCTestCase {
    func testNotificationGetsFifteenSecondsBeforeExpiring() {
        var timer = BannerCountdown(at: 100)
        timer.advance(to: 100.1, paused: false)
        XCTAssertFalse(timer.expired)
        XCTAssertEqual(timer.remaining, 14.9, accuracy: 0.001)
        timer.advance(to: 114.99, paused: false)
        XCTAssertFalse(timer.expired)
        timer.advance(to: 115, paused: false)
        XCTAssertTrue(timer.expired)
        XCTAssertEqual(timer.progress, 0, accuracy: 0.001)
    }

    func testHoverAndSnoozeInteractionsPauseWithoutResettingCountdown() {
        var timer = BannerCountdown(at: 0)
        timer.advance(to: 4, paused: false)
        timer.advance(to: 20, paused: true)
        XCTAssertEqual(timer.remaining, 11)
        timer.advance(to: 21, paused: false)
        XCTAssertEqual(timer.remaining, 10)
        timer.advance(to: 31, paused: false)
        XCTAssertTrue(timer.expired)
    }

    func testReplacementNotificationGetsItsOwnFullReadingTime() {
        var timer = BannerCountdown(at: 0)
        timer.advance(to: 14, paused: false)
        XCTAssertEqual(timer.remaining, 1)
        timer = BannerCountdown(at: 14)
        XCTAssertEqual(timer.progress, 1)
        timer.advance(to: 15, paused: false)
        XCTAssertFalse(timer.expired)
        XCTAssertEqual(timer.remaining, 14)
    }

    func testLateUpdateKeepsProgressAtZero() {
        var timer = BannerCountdown(at: 0)
        timer.advance(to: 100, paused: false)
        XCTAssertTrue(timer.expired)
        XCTAssertEqual(timer.remaining, 0)
        XCTAssertEqual(timer.progress, 0)
    }

    func testPRBannersHaveReachableDismissAndBottomCountdown() throws {
        let card = ToastCard()
        card.frame.size = NSSize(width: card.cardWidth, height: card.desiredHeight)
        for kind in [GHEvent.Kind.prOpened, .prCommented] {
            card.show(event: GHEvent(id: kind.rawValue, kind: kind, title: "Update the design",
                subtitle: "amsynist/zera #4", date: Date(), url: URL(string: "https://example.com/pr/4")!, approval: nil))
            card.layoutSubtreeIfNeeded()
            let dismiss = try XCTUnwrap(card.subviews.compactMap { $0 as? IconButton }
                .first { $0.accessibilityLabel() == "Dismiss notification" })
            XCTAssertFalse(dismiss.isHidden)
            XCTAssertTrue(card.bounds.contains(dismiss.frame))
            XCTAssertTrue(card.bounds.contains(card.countdownLine.frame))
            XCTAssertEqual(card.countdownLine.frame.height, 2)
            XCTAssertGreaterThan(card.countdownLine.frame.minY, 62)
            let point = NSPoint(x: dismiss.frame.midX, y: dismiss.frame.midY)
            XCTAssertTrue(card.hitTest(point) === dismiss)
        }
        var dismissed = false
        card.onDismiss = { dismissed = true }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        card.mouseUp(with: event)
        XCTAssertTrue(dismissed)
    }
}
