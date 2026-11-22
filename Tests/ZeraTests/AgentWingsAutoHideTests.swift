import XCTest
@testable import Zera

final class AgentWingsAutoHideTests: XCTestCase {
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: AgentWingsAutoHide.key)
        UserDefaults.standard.removeObject(forKey: AgentWingsAutoHide.key)
    }

    override func tearDown() {
        if let saved = saved { UserDefaults.standard.set(saved, forKey: AgentWingsAutoHide.key) }
        else { UserDefaults.standard.removeObject(forKey: AgentWingsAutoHide.key) }
        super.tearDown()
    }

    func testDefaultsToThreeSecondsAndIsTheFirstChoice() {
        XCTAssertEqual(AgentWingsAutoHide.delay, 3)
        XCTAssertEqual(AgentWingsAutoHide.choices.first, 3)
        XCTAssertEqual(AgentWingsAutoHide.choices.count, AgentWingsAutoHide.titles.count)
    }

    func testStoresOnlyOfferedChoices() {
        AgentWingsAutoHide.delay = 10
        XCTAssertEqual(AgentWingsAutoHide.delay, 10)
        AgentWingsAutoHide.delay = 7
        XCTAssertEqual(AgentWingsAutoHide.delay, 3)
        UserDefaults.standard.set(42, forKey: AgentWingsAutoHide.key)
        XCTAssertEqual(AgentWingsAutoHide.delay, 3)
    }

    func testRunningTurnHidesOnlyAfterItHadItsSeconds() {
        XCTAssertFalse(AgentWingsAutoHide.hides(runningKey: "s1|100", hiddenTurn: nil, delay: 3))
        XCTAssertTrue(AgentWingsAutoHide.hides(runningKey: "s1|100", hiddenTurn: "s1|100", delay: 3))
        // A new turn in the same session shows the wings again.
        XCTAssertFalse(AgentWingsAutoHide.hides(runningKey: "s1|200", hiddenTurn: "s1|100", delay: 3))
    }

    func testApprovalsAndFinishedTurnsAreNeverHidden() {
        // Any mode other than running has no running key.
        XCTAssertFalse(AgentWingsAutoHide.hides(runningKey: nil, hiddenTurn: "s1|100", delay: 3))
        XCTAssertFalse(AgentWingsAutoHide.hides(runningKey: nil, hiddenTurn: nil, delay: 0))
    }

    func testKeepShowingAndOnlyWhenNeeded() {
        XCTAssertFalse(AgentWingsAutoHide.hides(runningKey: "s1|100", hiddenTurn: "s1|100", delay: -1))
        XCTAssertTrue(AgentWingsAutoHide.hides(runningKey: "s1|100", hiddenTurn: nil, delay: 0))
    }
}
