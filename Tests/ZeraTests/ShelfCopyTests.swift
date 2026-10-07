import XCTest
@testable import Zera

/// Tapping a shelf item copies it in the form that pastes best.
final class ShelfCopyTests: XCTestCase {
    private var dir: URL!
    private var pb: NSPasteboard!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pb = NSPasteboard(name: NSPasteboard.Name("zera.tests.\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        pb.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ data: Data) throws -> String {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    func testANoteCopiesItsText() throws {
        let p = try file("Note 7 Oct.txt", Data("Ship the theme picker".utf8))
        XCTAssertEqual(ShelfCopier.copy(p, to: pb), .text)
        XCTAssertEqual(pb.string(forType: .string), "Ship the theme picker")
    }

    func testAWeblocCopiesTheLink() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/a"], format: .xml, options: 0)
        let p = try file("example.webloc", plist)
        XCTAssertEqual(ShelfCopier.copy(p, to: pb), .link)
        XCTAssertEqual(pb.string(forType: .string), "https://example.com/a")
    }

    func testAWindowsUrlFileCopiesTheLink() throws {
        let p = try file("site.url", Data("[InternetShortcut]\r\nURL=https://example.org/\r\n".utf8))
        XCTAssertEqual(ShelfCopier.linkURL(p)?.absoluteString, "https://example.org/")
    }

    func testAPdfCopiesTheFile() throws {
        let p = try file("Q3 report.pdf", Data("%PDF-1.4\n".utf8))
        XCTAssertEqual(ShelfCopier.copy(p, to: pb), .file)
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.first?.standardizedFileURL.path, URL(fileURLWithPath: p).standardizedFileURL.path)
    }

    func testAnImageCopiesThePictureAndTheFile() throws {
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation))?.representation(using: .png, properties: [:]))
        let p = try file("shot.png", png)
        XCTAssertEqual(ShelfCopier.copy(p, to: pb), .image)
        XCTAssertNotNil(pb.data(forType: .tiff))
        XCTAssertNotNil(pb.string(forType: .fileURL))
    }

    func testAMissingFileCopiesNothing() {
        pb.clearContents()
        pb.setString("before", forType: .string)
        XCTAssertNil(ShelfCopier.copy(dir.appendingPathComponent("gone.pdf").path, to: pb))
        XCTAssertEqual(pb.string(forType: .string), "before", "the clipboard is left alone")
    }

    func testABigTextFileCopiesAsAFile() throws {
        let p = try file("huge.log", Data(repeating: 65, count: ShelfCopier.maxTextBytes + 1))
        XCTAssertEqual(ShelfCopier.plan(for: p), .file)
    }
}
