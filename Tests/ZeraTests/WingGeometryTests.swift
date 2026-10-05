import AppKit
import XCTest
@testable import Zera

final class WingGeometryTests: XCTestCase {
    func testLeftAndRightOutlinesAreMirrored() {
        let left = LiveActivityView.wing(body: NSRect(x: 260, y: 16, width: 430, height: 60),
                                         inward: 1, tip: NSPoint(x: 746, y: 46))
        let right = LiveActivityView.wing(body: NSRect(x: 830, y: 16, width: 430, height: 60),
                                          inward: -1, tip: NSPoint(x: 774, y: 46))
        for x in stride(from: 250.5, through: 750, by: 4) {
            for y in stride(from: 10.5, through: 82, by: 4) {
                XCTAssertEqual(left.contains(NSPoint(x: x, y: y)),
                               right.contains(NSPoint(x: 1520 - x, y: y)), "Mismatch at \(x), \(y)")
            }
        }
    }

    func testCenterCurveIsSymmetricAboveAndBelowWingMidline() {
        let wing = LiveActivityView.wing(body: NSRect(x: 260, y: 16, width: 430, height: 60),
                                         inward: 1, tip: NSPoint(x: 746, y: 46))
        for x in stride(from: 680.25, through: 749, by: 2) {
            for y in stride(from: 10.25, through: 46, by: 2) {
                XCTAssertEqual(wing.contains(NSPoint(x: x, y: y)),
                               wing.contains(NSPoint(x: x, y: 92 - y)), "Mismatch at \(x), \(y)")
            }
        }
    }
}
