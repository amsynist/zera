import AppKit
import XCTest
@testable import Zera

final class FileDragCatchTests: XCTestCase {
    private let notch = NSRect(x: 660, y: 950, width: 190, height: 32)
    private var zone: NSRect { FileDragCatch.zone(notch: notch) }
    private let far = NSPoint(x: 200, y: 300)

    private func step(_ c: inout FileDragCatch, down: Bool, count: Int, file: Bool = true, at p: NSPoint,
                      keep: NSRect = .zero, now: TimeInterval = 0) -> [FileDragCatch.Event] {
        c.update(buttonDown: down, changeCount: count, holdsFile: { file }, pointer: p, zone: zone, keep: keep, now: now)
    }

    func testAnyKindOfFileCounts() {
        XCTAssertTrue(FileDragCatch.holdsFile([.fileURL]))
        XCTAssertTrue(FileDragCatch.holdsFile([.tiff, .string]))
        XCTAssertTrue(FileDragCatch.holdsFile([.pdf]))
        // Photos, Mail and browsers promise a file rather than naming one on disk.
        XCTAssertFalse(FileDragCatch.promiseTypes.isEmpty)
        XCTAssertTrue(FileDragCatch.holdsFile([FileDragCatch.promiseTypes[0]]))
        // Dragging a word around a document is not a file.
        XCTAssertFalse(FileDragCatch.holdsFile([.string, .rtf]))
        XCTAssertFalse(FileDragCatch.holdsFile(nil))
        XCTAssertTrue(FileDragCatch.dropTypes.contains(.string))
    }

    func testDragThatBeginsBetweenReadingsIsStillSeen() {
        var c = FileDragCatch()
        XCTAssertEqual(step(&c, down: false, count: 7, at: far), [])
        // The press and the pickup both happened before this reading.
        XCTAssertEqual(step(&c, down: true, count: 8, at: far), [.began])
        XCTAssertTrue(c.active)
    }

    func testPlainClickAndTextDragDoNothing() {
        var c = FileDragCatch()
        _ = step(&c, down: false, count: 3, at: far)
        XCTAssertEqual(step(&c, down: true, count: 3, at: far), [])
        XCTAssertEqual(step(&c, down: false, count: 3, at: far), [])
        XCTAssertEqual(step(&c, down: true, count: 4, file: false, at: far), [])
        XCTAssertFalse(c.active)
        // The same text drag wandering under the notch still opens nothing.
        XCTAssertEqual(step(&c, down: true, count: 4, file: false, at: NSPoint(x: notch.midX, y: notch.midY)), [])
    }

    func testReachingTheNotchOpensOnceAndReleaseEnds() {
        var c = FileDragCatch()
        _ = step(&c, down: false, count: 1, at: far)
        XCTAssertEqual(step(&c, down: true, count: 2, at: far), [.began])
        XCTAssertEqual(step(&c, down: true, count: 2, at: NSPoint(x: notch.midX, y: notch.minY - 300)), [])
        let under = NSPoint(x: notch.midX + 40, y: notch.minY - 30)
        XCTAssertEqual(step(&c, down: true, count: 2, at: under), [.reached])
        XCTAssertEqual(step(&c, down: true, count: 2, at: under), [])
        XCTAssertEqual(step(&c, down: false, count: 2, at: under), [.ended])
        XCTAssertFalse(c.active)
        XCTAssertFalse(c.reached)
    }

    func testPickedUpUnderTheNotchReachesAtOnce() {
        var c = FileDragCatch()
        let under = NSPoint(x: notch.midX, y: notch.minY - 10)
        _ = step(&c, down: false, count: 1, at: under)
        XCTAssertEqual(step(&c, down: true, count: 2, at: under), [.began, .reached])
    }

    func testCarriedAwayFoldsAfterAGraceAndCanComeBack() {
        var c = FileDragCatch()
        let under = NSPoint(x: notch.midX, y: notch.minY - 20)
        let shelf = NSRect(x: 400, y: 500, width: 700, height: 480)
        _ = step(&c, down: false, count: 1, at: far)
        _ = step(&c, down: true, count: 2, at: under)
        XCTAssertTrue(c.reached)
        // Roaming over the open Shelf is staying.
        XCTAssertEqual(step(&c, down: true, count: 2, at: NSPoint(x: 600, y: 600), keep: shelf, now: 1), [])
        XCTAssertEqual(step(&c, down: true, count: 2, at: far, keep: shelf, now: 2), [])
        // A brief stray and back does not fold it.
        XCTAssertEqual(step(&c, down: true, count: 2, at: under, keep: shelf, now: 2.3), [])
        XCTAssertEqual(step(&c, down: true, count: 2, at: far, keep: shelf, now: 3), [])
        XCTAssertEqual(step(&c, down: true, count: 2, at: far, keep: shelf, now: 3 + FileDragCatch.leaveGrace + 0.01), [.left])
        XCTAssertTrue(c.active)
        XCTAssertEqual(step(&c, down: true, count: 2, at: under, keep: .zero, now: 5), [.reached])
    }

    func testAnswersWithAnOperationTheSourceAllows() {
        XCTAssertEqual(FileDragCatch.operation(for: [.copy, .move]), .copy)
        XCTAssertEqual(FileDragCatch.operation(for: [.generic]), .generic)
        XCTAssertEqual(FileDragCatch.operation(for: [.move]), .move)
        XCTAssertEqual(FileDragCatch.operation(for: []), [])
    }
}
