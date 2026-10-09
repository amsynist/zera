import XCTest
@testable import Zera

final class ActivityBufferTests: XCTestCase {
    func testLargeEventBatchPreservesOrderAndTheSplitFinalLine() {
        let lines = (0..<2_000).map { "{\"event\":\($0),\"text\":\"hello ✨\"}" }
        let batch = Data((lines.joined(separator: "\n") + "\n{\"partial\":").utf8)
        var received: [String] = []
        let remainder = ClaudeActivityService.consumeLines(batch) { received.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(received, lines)
        XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "{\"partial\":")
        let end = ClaudeActivityService.consumeLines(remainder + Data("true}\n".utf8)) { received.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(received.last, "{\"partial\":true}")
        XCTAssertTrue(end.isEmpty)
    }
}
