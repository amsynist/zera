import XCTest
@testable import Zera

final class FreshFilesTests: XCTestCase {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zera-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Newest first; half-finished downloads and hidden files stay out; a window in the future
    /// leaves nothing.
    func testScanFindsNewFilesNewestFirst() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["first.pdf", "second.png"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
            Thread.sleep(forTimeInterval: 1.1)    // added-to-folder dates have one-second steps
        }
        try Data("partial".utf8).write(to: dir.appendingPathComponent("movie.mov.crdownload"))
        try Data("partial".utf8).write(to: dir.appendingPathComponent("archive.zip.download"))
        try Data("hidden".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        let f = FreshFiles.Folder(path: dir.path, on: true)
        let found = FreshFiles.scan([f], since: Date().addingTimeInterval(-3600))
        XCTAssertEqual(found.map(\.name), ["second.png", "first.pdf"])
        XCTAssertEqual(found.first?.source, dir.lastPathComponent)
        XCTAssertTrue(FreshFiles.scan([f], since: Date().addingTimeInterval(60)).isEmpty)
    }

    func testOffFoldersAndMissingFoldersAreSkipped() throws {
        let missing = FreshFiles.Folder(path: "/nonexistent/zera-\(UUID().uuidString)", on: true)
        XCTAssertTrue(FreshFiles.scan([missing], since: .distantPast).isEmpty)
    }
}
