import AppKit
import XCTest
@testable import Zera

final class DictationClipboardTests: XCTestCase {
    private var board: NSPasteboard!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        board = try XCTUnwrap(NSPasteboard.withUniqueName(), "Native pasteboard service must be available")
    }
    override func tearDown() { board?.releaseGlobally(); board = nil }

    func testPasteRestoresOriginalRepresentationsAndMarksTranscriptTransient() {
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        original.setData(Data([1, 2, 3]), forType: .rtf)
        board.writeObjects([original])
        let lease = DictationClipboard(board: board)
        let restore = lease.stage("hello 🌿")
        XCTAssertEqual(board.string(forType: .string), "hello 🌿")
        XCTAssertNotNil(board.data(forType: .init("org.nspasteboard.TransientType")))
        restore()
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(board.data(forType: .rtf), Data([1, 2, 3]))
    }

    func testOlderRestoreCannotOverwriteNewerPasteAndOriginalIsPreserved() {
        board.setString("original", forType: .string)
        let lease = DictationClipboard(board: board)
        let first = lease.stage("first")
        let second = lease.stage("second")
        first()
        XCTAssertEqual(board.string(forType: .string), "second")
        second()
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testCopyMadeDuringPasteIsNeverOverwritten() {
        board.setString("original", forType: .string)
        let lease = DictationClipboard(board: board)
        let restore = lease.stage("transcript")
        board.clearContents()
        board.setString("new copy", forType: .string)
        restore()
        XCTAssertEqual(board.string(forType: .string), "new copy")
    }
}
