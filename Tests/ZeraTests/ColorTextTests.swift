import XCTest
import AppKit
@testable import Zera

/// Command Echo's colour detection: what you copy as text turns into a swatch and a coloured comet.
final class ColorTextTests: XCTestCase {
    private func hex(_ s: String) -> String? { ColorText.parse(s).map(ColorText.hex) }

    func testHexForms() {
        XCTAssertEqual(hex("#4dbdff"), "#4DBDFF")
        XCTAssertEqual(hex("  #4DBDFF\n"), "#4DBDFF")
        XCTAssertEqual(hex("#fff"), "#FFFFFF")
        XCTAssertEqual(hex("#f008"), "#FF000088")
        XCTAssertEqual(hex("#11223380"), "#11223380")
        XCTAssertEqual(hex("0x00FF00"), "#00FF00")
    }

    func testFunctionalForms() {
        XCTAssertEqual(hex("rgb(255, 0, 0)"), "#FF0000")
        XCTAssertEqual(hex("rgba(0,0,255,0.5)"), "#0000FF80")
        XCTAssertEqual(hex("rgb(0 128 255 / 50%)"), "#0080FF80")
        XCTAssertEqual(hex("hsl(120, 100%, 50%)"), "#00FF00")
        XCTAssertEqual(hex("hsl(240deg 100% 50%)"), "#0000FF")
        XCTAssertEqual(hex("hsl(-120, 100%, 50%)"), "#0000FF")
    }

    func testOrdinaryTextIsNotAColour() {
        for s in ["fff", "#ggg", "#12345", "hello world", "rgb(1,2)", "Ship the build tonight", "#", ""] {
            XCTAssertNil(ColorText.parse(s), s)
        }
    }

    func testCaseKeysLightEachHaveTheirOwnKey() {
        XCTAssertEqual(NotchLightReaction.capsLock(on: true).key, "capsLock")
        XCTAssertEqual(NotchLightReaction.shiftHeld.key, "shiftHeld")
    }
}
