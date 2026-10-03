import XCTest
@testable import Zera

final class ShelfKindTests: XCTestCase {
    func testKindsFromExtensions() {
        XCTAssertEqual(ShelfKind(path: "/a/Project-spec.pdf").label, "PDF")
        XCTAssertEqual(ShelfKind(path: "/a/Design-mockup.PNG").label, "Image")
        XCTAssertEqual(ShelfKind(path: "/a/main.swift").label, "Code")
        XCTAssertEqual(ShelfKind(path: "/a/Product-notes.md").label, "Docs")
        XCTAssertEqual(ShelfKind(path: "/a/debug-log.txt").label, "Text")
        XCTAssertEqual(ShelfKind(path: "/a/archive.zip").label, "File")
    }

    func testSuggestedActionMatchesKind() {
        XCTAssertEqual(ShelfKind(path: "x.pdf").suggested.action, .summarize)
        XCTAssertEqual(ShelfKind(path: "x.png").suggested.action, .extract)
        XCTAssertEqual(ShelfKind(path: "x.swift").suggested.action, .explain)
        XCTAssertNil(ShelfKind(path: "x.txt").suggested.action)   // Ask Zera: opens the question box
    }

    func testLocalTextOnlyForReadableKinds() {
        XCTAssertTrue(ShelfKind(path: "x.pdf").hasLocalText)
        XCTAssertTrue(ShelfKind(path: "x.py").hasLocalText)
        XCTAssertFalse(ShelfKind(path: "x.jpg").hasLocalText)
    }
}
