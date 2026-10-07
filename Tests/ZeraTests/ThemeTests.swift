import XCTest
@testable import Zera

final class ThemeTests: XCTestCase {
    func testHexColoursParse() throws {
        let c = try XCTUnwrap(NSColor(themeHex: "#FF8000"))
        XCTAssertEqual(c.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(c.greenComponent, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(c.blueComponent, 0, accuracy: 0.001)
        XCTAssertEqual(c.alphaComponent, 1, accuracy: 0.001)
        let a = try XCTUnwrap(NSColor(themeHex: "ffffff80"))
        XCTAssertEqual(a.alphaComponent, 128.0 / 255, accuracy: 0.001)
        XCTAssertNil(NSColor(themeHex: "#FFF"))
        XCTAssertNil(NSColor(themeHex: "#GGGGGG"))
        XCTAssertNil(NSColor(themeHex: nil))
    }

    func testEveryBuiltInThemeSetsEveryColour() {
        XCTAssertEqual(BuiltInThemes.all.count, 7)
        XCTAssertEqual(Set(BuiltInThemes.all.map(\.id)).count, 7, "ids are unique")
        for def in BuiltInThemes.all {
            for k in ThemeColors.keys {
                XCTAssertNotNil(NSColor(themeHex: def.colors[keyPath: k]), "\(def.id) \(k)")
            }
        }
    }

    func testCustomThemeOverridesOnlyWhatItNames() throws {
        let json = ##"{ "name": "Mine", "base": "dracula", "colors": { "accent": "#00FF00" } }"##
        let file = try JSONDecoder().decode(ThemeFile.self, from: Data(json.utf8))
        let base = try XCTUnwrap(BuiltInThemes.all.first { $0.id == file.base })
        let merged = base.colors.merged(with: try XCTUnwrap(file.colors))
        XCTAssertEqual(merged.accent, "#00FF00")
        XCTAssertEqual(merged.glassTop, BuiltInThemes.dracula.colors.glassTop)
        XCTAssertEqual(merged.danger, BuiltInThemes.dracula.colors.danger)
    }

    func testABadColourFallsBackInsteadOfBlanking() {
        let t = ZeraTheme(id: "t", name: "T", builtIn: false, colors: ThemeColors(accent: "not a colour"))
        XCTAssertTrue(t.accent.sameRGB(as: NSColor(themeHex: BuiltInThemes.zera.colors.accent)!))
        XCTAssertTrue(t.glassTop.sameRGB(as: NSColor(themeHex: BuiltInThemes.zera.colors.glassTop)!))
    }
}
