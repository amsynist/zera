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

    func testNotchTakesPromisedFilesFromPhotosAndBrowsers() {
        let buddy = NotchBuddyView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        for type in FileDragCatch.promiseTypes { XCTAssertTrue(buddy.registeredDraggedTypes.contains(type)) }
        XCTAssertTrue(DropFilesView().registeredDraggedTypes.contains(FileDragCatch.promiseTypes[0]))
    }

    func testIslandOpenToCatchTakesADropAnywhereOnIt() {
        let island = IslandView(frame: NSRect(x: 0, y: 0, width: 850, height: 500))
        island.centerX = 425
        island.present(NSView(), size: NSSize(width: 600, height: 300), direction: 0, animated: false)
        let middle = NSPoint(x: island.islandRect.midX, y: island.islandRect.midY)
        XCTAssertFalse(island.acceptsDrop(at: middle))
        island.setCatching(true)
        XCTAssertTrue(island.catching)
        XCTAssertTrue(island.acceptsDrop(at: middle))
        XCTAssertFalse(island.acceptsDrop(at: NSPoint(x: island.islandRect.maxX + 40, y: middle.y)))
        island.catchLanded()
        XCTAssertFalse(island.catching)
        XCTAssertFalse(island.acceptsDrop(at: middle))
    }

    func testShelfStoreTakesFilesAndRefusesAnEmptyDrop() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("zera.tests.drop.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertFalse(ShelfStore.canTake(board))
        board.setString("a note", forType: .string)
        XCTAssertTrue(ShelfStore.canTake(board))
    }
}
