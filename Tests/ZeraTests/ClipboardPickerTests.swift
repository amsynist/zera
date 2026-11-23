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

extension ClipboardPickerTests {
    func testDeckPeeksStepDownUnderTheFrontCard() {
        let layout = ClipDeckLayout(bounds: ClipDeckLayout.size)
        let hero = layout.hero
        XCTAssertEqual(layout.slot(0).top.y, hero.minY)
        for depth in 1...ClipDeckLayout.peeks {
            let slot = layout.slot(depth)
            // Each card's bottom edge sits one strip below the card in front of it.
            XCTAssertEqual(slot.top.y + layout.card.height * slot.scale, hero.maxY + ClipDeckLayout.peekStep * CGFloat(depth), accuracy: 0.001)
            XCTAssertLessThan(slot.scale, layout.slot(depth - 1).scale)
            XCTAssertEqual(slot.opacity, 1)
            let strip = layout.visibleRect(depth)
            XCTAssertEqual(strip.minY, layout.visibleRect(depth - 1).maxY, accuracy: 0.001)
            XCTAssertEqual(strip.height, ClipDeckLayout.peekStep)
        }
        XCTAssertEqual(layout.slot(-1).opacity, 0, "a flipped card is out of sight")
        XCTAssertEqual(layout.slot(ClipDeckLayout.peeks + 1).opacity, 0, "deeper cards wait unseen")
    }

    func testDeckFitsItsWindowAtAnySize() {
        for size in [ClipDeckLayout.size, NSSize(width: 304, height: 324)] {
            let layout = ClipDeckLayout(bounds: size)
            let window = NSRect(origin: .zero, size: size)
            XCTAssertTrue(window.contains(layout.hero))
            XCTAssertTrue(window.contains(layout.prompt))
            XCTAssertTrue(window.contains(layout.status))
            XCTAssertTrue(window.contains(layout.visibleRect(ClipDeckLayout.peeks)))
            XCTAssertLessThanOrEqual(layout.visibleRect(ClipDeckLayout.peeks).maxY, layout.status.minY)
            XCTAssertLessThan(layout.prompt.width, layout.card.width)
            XCTAssertLessThanOrEqual(layout.prompt.maxY, layout.hero.minY, "the prompt sits clear of the front card")
        }
    }

    func testTraceRunsFromThePromptIntoTheFrontCardsPort() {
        let layout = ClipDeckLayout(bounds: ClipDeckLayout.size)
        let box = layout.tracePath.boundingBoxOfPath
        // Out of the prompt's left edge, down the gutter beside the deck, into the port.
        XCTAssertEqual(box.maxX, layout.prompt.minX, accuracy: 0.001)
        XCTAssertEqual(box.minX, layout.gutterX, accuracy: 0.001)
        XCTAssertEqual(box.minY, layout.prompt.midY, accuracy: 0.001)
        XCTAssertEqual(box.maxY, layout.port.y, accuracy: 0.001)
        XCTAssertLessThan(layout.gutterX, layout.hero.minX)
        XCTAssertGreaterThan(layout.gutterX, 0)
        XCTAssertEqual(layout.tracePath.currentPoint, layout.port)

        XCTAssertNil(layout.railPath(0), "no rail when no card is waiting")
        for depth in 1...ClipDeckLayout.peeks {
            let dot = layout.railDot(depth), strip = layout.visibleRect(depth)
            XCTAssertTrue((strip.minY...strip.maxY).contains(dot.y), "each dot sits beside its card's strip")
            XCTAssertLessThan(dot.x, strip.minX)
            XCTAssertGreaterThan(dot.x, layout.gutterX)
        }
    }
}
