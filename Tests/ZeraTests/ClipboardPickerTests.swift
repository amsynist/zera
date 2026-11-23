import AppKit
import XCTest
@testable import Zera

final class ClipboardPickerTests: XCTestCase {
    func testPickerStaysBesidePointerOnAnOffsetDisplay() {
        let visible = NSRect(x: -1680, y: 48, width: 1680, height: 1000)
        let center = NSPoint(x: visible.midX, y: visible.midY)
        let normal = ClipboardPicker.frame(near: center, in: visible)
        XCTAssertTrue(visible.contains(normal))
        XCTAssertGreaterThan(normal.minX, center.x)
        XCTAssertLessThan(normal.maxY, center.y)

        let corner = NSPoint(x: visible.maxX - 2, y: visible.minY + 2)
        let flipped = ClipboardPicker.frame(near: corner, in: visible)
        XCTAssertTrue(visible.contains(flipped))
        XCTAssertLessThan(flipped.maxX, corner.x)
        XCTAssertGreaterThan(flipped.minY, corner.y)
    }

    func testPickerFitsWithinSmallerDisplay() {
        let visible = NSRect(x: 0, y: 0, width: 320, height: 340)
        let frame = ClipboardPicker.frame(near: .zero, in: visible)
        XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(frame))
        XCTAssertEqual(frame.width, 304)
        XCTAssertEqual(frame.height, 324)
    }
}

extension ClipboardPickerTests {
    func testCopiedMediaFilesCanRequestThumbnails() {
        func file(_ name: String) -> ClipItem {
            ClipItem(kind: .files, text: name, paths: ["/tmp/" + name], fingerprint: name)
        }
        XCTAssertEqual(file("mountains.png").mediaFile?.lastPathComponent, "mountains.png")
        XCTAssertEqual(file("walkthrough.mov").mediaFile?.lastPathComponent, "walkthrough.mov")
        XCTAssertNil(file("notes.md").mediaFile)
    }
}
