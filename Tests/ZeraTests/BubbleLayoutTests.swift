import AppKit
import XCTest
@testable import Zera

final class BubbleLayoutTests: XCTestCase {
    private let safeFrame = NSRect(x: 12, y: 12, width: 1488, height: 926)
    private let figure = NSRect(x: 724, y: 866, width: 64, height: 84)

    func testApprovalCaptionClearsWingsAndMenuBar() {
        let wings = NSRect(x: 0, y: 856, width: 1512, height: 92)
        let size = BubbleView.size(for: "Allow Claude to run a command? 🤔")
        let frame = BubbleView.frame(for: size, figure: figure, safeFrame: safeFrame,
                                     obstacle: wings, below: true)
        XCTAssertTrue(safeFrame.contains(frame))
        XCTAssertFalse(frame.intersects(wings))
        XCTAssertFalse(frame.intersects(figure))
        XCTAssertGreaterThanOrEqual(wings.minY - frame.maxY, BubbleView.gap)
        XCTAssertEqual(frame.midX, figure.midX, accuracy: 1)
    }

    func testIslandAtScreenEdgeUsesClearSide() {
        let island = NSRect(x: 830, y: 470, width: 660, height: 480)
        let edgeFigure = NSRect(x: 1200, y: 866, width: 64, height: 84)
        let frame = BubbleView.frame(for: NSSize(width: 320, height: 54), figure: edgeFigure,
                                     safeFrame: safeFrame, obstacle: island)
        XCTAssertTrue(safeFrame.contains(frame))
        XCTAssertFalse(frame.intersects(island))
        XCTAssertLessThanOrEqual(frame.maxX, island.minX - BubbleView.gap)
    }

    func testNarrowDisplayPlacesCaptionBelowIsland() {
        let safe = NSRect(x: -788, y: 12, width: 776, height: 926)
        let island = NSRect(x: -730, y: 470, width: 660, height: 480)
        let buddy = NSRect(x: -432, y: 866, width: 64, height: 84)
        let frame = BubbleView.frame(for: NSSize(width: 320, height: 54), figure: buddy,
                                     safeFrame: safe, obstacle: island)
        XCTAssertTrue(safe.contains(frame))
        XCTAssertFalse(frame.intersects(island))
        XCTAssertLessThanOrEqual(frame.maxY, island.minY - BubbleView.gap)
    }

    func testLongCaptionsWrapWithinBoundedPanel() {
        let short = BubbleView.size(for: "Hi! 👋")
        let long = BubbleView.size(for: "Claude finished “Review the pull requests and summarize all the changes across repositories” 🎉")
        XCTAssertLessThan(short.width, long.width)
        XCTAssertLessThanOrEqual(long.width, BubbleView.maxWidth)
        XCTAssertGreaterThan(long.height, short.height)
        XCTAssertLessThanOrEqual(long.height, ceil(BubbleView.font.ascender - BubbleView.font.descender + BubbleView.font.leading) * 3 + BubbleView.vPad * 2)
        XCTAssertLessThanOrEqual(BubbleView.size(for: String(repeating: "long-repository-name", count: 100), maxWidth: 240).width, 240)
    }
}
