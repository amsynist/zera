import XCTest
@testable import AndropKit

final class AndropTests: XCTestCase {
    func testFilesStayInsideInboxAndKeepOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiver = FileReceiver(directory: directory)
        let bytes = Data([0, 255, 1, 2, 3])
        for name in ["../../outside.txt", "C:\\private\\note", "...", "\u{0}bad.txt"] {
            let url = try receiver.saveFile(name: name, base64Data: bytes.base64EncodedString())
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertFalse(url.lastPathComponent.hasPrefix("."))
        }
        let first = try receiver.saveFile(name: "unique-note", base64Data: "")
        let second = try receiver.saveFile(name: "unique-note", base64Data: "")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "unique-note (1)")
    }
    func testInvalidAndOversizedPayloadsFail() throws {
        let receiver = FileReceiver()
        XCTAssertThrowsError(try receiver.saveFile(name: "bad", base64Data: "!not base64!"))
        XCTAssertThrowsError(try receiver.saveFile(name: "large", base64Data: String(repeating: "A", count: (FileReceiver.maximumBytes + 3) / 3 * 4 + 4)))
    }
    func testProtocolRejectsMalformedAndNonfiniteCoordinates() {
        for json in ["{}", "not json", "{\"type\":\"DRAG_UPDATE\",\"id\":\"a\",\"normalizedY\":NaN,\"crossRatio\":0.1}"] {
            if case .unknown = parseClientMessage(jsonString: json) {} else { XCTFail("Malformed packet was accepted") }
        }
        let valid = "{\"type\":\"DRAG_UPDATE\",\"id\":\"a\",\"normalizedY\":0.2,\"crossRatio\":0.3}"
        if case .update(let event) = parseClientMessage(jsonString: valid) { XCTAssertEqual(event.crossRatio, 0.3) }
        else { XCTFail("Valid update rejected") }
    }
    func testAllEdgesUseConsistentGeometry() {
        let size = CGSize(width: 1000, height: 800)
        let expected: [(EdgePosition, CGPoint, CGPoint)] = [
            (.left, CGPoint(x: 0, y: 200), CGPoint(x: 50, y: 200)),
            (.right, CGPoint(x: 1000, y: 200), CGPoint(x: 950, y: 200)),
            (.top, CGPoint(x: 250, y: 0), CGPoint(x: 250, y: 50)),
            (.bottom, CGPoint(x: 250, y: 800), CGPoint(x: 250, y: 750))
        ]
        for (edge, origin, inward) in expected {
            XCTAssertEqual(EdgeGeometry.origin(edge: edge, coordinate: 0.25, size: size), origin)
            XCTAssertEqual(EdgeGeometry.inward(edge: edge, origin: origin, distance: 50), inward)
        }
    }
}
