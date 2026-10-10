import AppKit
import XCTest
@testable import Zera

final class BubbleLayoutTests: XCTestCase {
    /// The screen minus the menu bar band, as the controller passes it.
    private let safeFrame = NSRect(x: 8, y: 8, width: 1496, height: 934)
    private let figure = NSRect(x: 724, y: 866, width: 64, height: 84)

    func testCaptionSitsBesideHerFace() {
        let size = BubbleView.size(for: "Hi! 👋")
        let frame = BubbleView.frame(for: size, figure: figure, safeFrame: safeFrame)
        XCTAssertTrue(safeFrame.contains(frame))
        XCTAssertFalse(frame.intersects(figure))
        XCTAssertEqual(frame.minX - figure.maxX, BubbleView.gap, accuracy: 1)
        XCTAssertEqual(frame.midY, figure.minY + figure.height * 0.45, accuracy: 1)
    }

    func testCaptionClearsWingsAndMenuBar() {
        let wings = NSRect(x: 0, y: 856, width: 1512, height: 92)
        let size = BubbleView.size(for: "got it! ✨")
        let frame = BubbleView.frame(for: size, figure: figure, bodyX: 740, safeFrame: safeFrame, obstacles: [wings])
        XCTAssertTrue(safeFrame.contains(frame))
        XCTAssertFalse(frame.intersects(wings))
        XCTAssertGreaterThanOrEqual(wings.minY - frame.maxY, BubbleView.gap - 0.5)
        XCTAssertEqual(frame.midX, 740, accuracy: 1)
    }

    func testCaptionClearsPeekingIsland() {
        let island = NSRect(x: 536, y: 904, width: 440, height: 46)
        let tall = NSRect(x: 724, y: 916, width: 64, height: 34)
        let frame = BubbleView.frame(for: BubbleView.size(for: "toss it here! 🙌"), figure: tall,
                                     safeFrame: safeFrame, obstacles: [island])
        XCTAssertFalse(frame.intersects(island))
        XCTAssertLessThanOrEqual(frame.maxY, island.minY - BubbleView.gap + 0.5)
    }

    func testCaptionStaysOnScreenAtTheEdge() {
        let edgeFigure = NSRect(x: 1470, y: 866, width: 64, height: 84)
        let frame = BubbleView.frame(for: NSSize(width: 280, height: 46), figure: edgeFigure, safeFrame: safeFrame)
        XCTAssertTrue(safeFrame.contains(frame))
        XCTAssertEqual(edgeFigure.minX - frame.maxX, BubbleView.gap, accuracy: 1)
        XCTAssertGreaterThan(frame.maxY, edgeFigure.minY)
    }

    func testCaptionUsesEmptySpaceBesideTheArc() {
        let island = IslandView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))
        island.centerX = 450; island.hoverStyle = .arc; island.peek()
        let obstacles = island.captionObstacles.map {
            NSRect(x: $0.minX, y: 1000 - $0.maxY, width: $0.width, height: $0.height)
        }
        let zera = NSRect(x: 418, y: 882, width: 64, height: 84)
        let frame = BubbleView.frame(for: BubbleView.size(for: "Yes? 👀"), figure: zera,
                                     safeFrame: NSRect(x: 8, y: 8, width: 884, height: 958), obstacles: obstacles)
        XCTAssertFalse(obstacles.contains { $0.intersects(frame) })
        XCTAssertGreaterThan(frame.maxY, zera.minY)
    }

    func testLongCaptionsWrapToTwoLinesAtMost() {
        let short = BubbleView.size(for: "Hi! 👋")
        let long = BubbleView.size(for: "timer set — I'll tell you at 4:15, and here is a much longer line that keeps going ⏱")
        XCTAssertLessThan(short.width, long.width)
        XCTAssertLessThanOrEqual(long.width, BubbleView.maxWidth)
        XCTAssertGreaterThan(long.height, short.height)
        let line = ceil(BubbleView.font.ascender - BubbleView.font.descender + BubbleView.font.leading)
        XCTAssertLessThanOrEqual(long.height, line * CGFloat(BubbleView.maxLines) + BubbleView.vPad * 2)
        XCTAssertLessThanOrEqual(BubbleView.size(for: String(repeating: "long-repository-name", count: 100), maxWidth: 240).width, 240)
    }

    func testComicTailFacesZeraAndFitsTheTransparentMargin() {
        let bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: 140, height: 58))
        for (point, side) in [(NSPoint(x: -30, y: 29), BubbleView.TailSide.left),
                              (NSPoint(x: 170, y: 29), .right), (NSPoint(x: 70, y: -20), .top)] {
            bubble.pointToward(point)
            XCTAssertEqual(bubble.tailSide, side)
            XCTAssertTrue(bubble.bounds.contains(bubble.speechPath.bounds))
            XCTAssertTrue(bubble.speechPath.contains(NSPoint(x: 70, y: 29)))
        }
    }

    func testPanelLeavesRoomForTheShadow() {
        let tag = NSRect(x: 100, y: 100, width: 120, height: 30)
        XCTAssertEqual(BubbleView.panelFrame(for: tag), tag.insetBy(dx: -BubbleView.halo, dy: -BubbleView.halo))
    }
}
