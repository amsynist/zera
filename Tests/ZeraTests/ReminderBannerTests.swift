import XCTest
@testable import Zera

final class ReminderBannerTests: XCTestCase {
    private func alert(_ id: String, hydration: Bool = false) -> ReminderAlert {
        ReminderAlert(id: id, kind: .now, headline: id, detail: "", hydration: hydration)
    }
    func testNewEventReplacesOldWithoutReplayingBacklog() {
        var state = ReminderBannerState()
        let now = Date()
        state.offer(alert("first"), at: now)
        state.offer(alert("latest"), at: now.addingTimeInterval(1))
        XCTAssertEqual(state.current(at: now.addingTimeInterval(2))?.id, "latest")
        state.finish()
        XCTAssertNil(state.current(at: now.addingTimeInterval(3)))
    }
    func testStaleBannersExpireEvenWithoutDismissal() {
        var state = ReminderBannerState()
        let now = Date()
        state.offer(alert("old"), at: now)
        XCTAssertNotNil(state.current(at: now.addingTimeInterval(119)))
        XCTAssertNil(state.current(at: now.addingTimeInterval(120)))
        XCTAssertNil(state.current(at: now.addingTimeInterval(7200)))
        state.offer(alert("fresh"), at: now.addingTimeInterval(7200))
        XCTAssertEqual(state.current(at: now.addingTimeInterval(7201))?.id, "fresh")
    }
    func testWaterVisitDoesNotReplaceNotification() {
        var state = ReminderBannerState()
        let now = Date()
        state.offer(alert("meeting"), at: now)
        state.offer(alert("water", hydration: true), at: now)
        XCTAssertEqual(state.current(at: now)?.id, "meeting")
    }
}
