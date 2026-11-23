import AppKit
import XCTest
@testable import Zera

final class ShelfDropTargetTests: XCTestCase {
    func testClosedNotchRegistersFinderFileDrops() {
        let buddy = NotchBuddyView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        XCTAssertTrue(buddy.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(buddy.acceptsDrop(at: NSPoint(x: 120, y: 17)))
    }

    func testIslandOnlyAcceptsDropsAlongItsNotchBand() {
        let island = IslandView(frame: NSRect(x: 0, y: 0, width: 850, height: 500))
        island.centerX = 425
        XCTAssertFalse(island.acceptsDrop(at: NSPoint(x: 425, y: 10)))
        island.peek()
        XCTAssertTrue(island.acceptsDrop(at: NSPoint(x: 425, y: 10)))
        XCTAssertFalse(island.acceptsDrop(at: NSPoint(x: 160, y: 10)))
        XCTAssertFalse(island.acceptsDrop(at: NSPoint(x: 425, y: 70)))
    }
}
