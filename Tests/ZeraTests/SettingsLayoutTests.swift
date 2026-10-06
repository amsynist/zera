import XCTest
@testable import Zera

final class SettingsLayoutTests: XCTestCase {
    /// Every pane fits in the island; taller content scrolls inside it instead of being cut off.
    func testEveryPaneFitsTheIsland() {
        let s = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        s.setFrameSize(NSSize(width: 560, height: 400))
        for pane in SettingsCard.Pane.allCases {
            s.select(pane)
            XCTAssertLessThanOrEqual(s.desiredHeight, Isle.maxContentHeight, "\(pane)")
        }
    }
}
