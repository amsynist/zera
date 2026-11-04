import XCTest
@testable import AndropKit

final class ArrivalTests: XCTestCase {
    func testPhotosAndVideosOpenOnArrivalOnlyWhenAllowed() {
        let overlay = OverlayWindowController.shared
        let previous = overlay.autoOpenReceivedMedia
        defer { overlay.autoOpenReceivedMedia = previous }
        overlay.autoOpenReceivedMedia = true
        XCTAssertTrue(overlay.opensOnArrival(name: "IMG_2041.HEIC", mime: ""))
        XCTAssertTrue(overlay.opensOnArrival(name: "clip.mp4", mime: "video/mp4"))
        // A Gallery drag names the item only at the drop; its type is known from the start.
        XCTAssertTrue(overlay.opensOnArrival(name: "Incoming file", mime: "image/jpeg"))
        XCTAssertFalse(overlay.opensOnArrival(name: "report.pdf", mime: "application/pdf"))
        XCTAssertFalse(overlay.opensOnArrival(name: "archive.zip", mime: "application/octet-stream"))
        overlay.autoOpenReceivedMedia = false
        XCTAssertFalse(overlay.opensOnArrival(name: "IMG_2041.HEIC", mime: "image/heic"))
    }

    func testPicturesKeepTheirShapeWhileCrossing() {
        XCTAssertTrue(TransferCard.isPicture(name: "Incoming file", mime: "image/png"))
        XCTAssertTrue(TransferCard.isVideo(name: "Incoming file", mime: "video/quicktime"))
        XCTAssertFalse(TransferCard.isPicture(name: "notes.pdf", mime: "application/pdf"))
        // A picture without its preview yet is picture-shaped; a file card adds its details row.
        XCTAssertEqual(TransferCard.height(nil, name: "Incoming file", mime: "image/jpeg"), TransferCard.previewHeight(nil))
        XCTAssertGreaterThan(TransferCard.height(nil, name: "notes.pdf", mime: "application/pdf"), TransferCard.previewHeight(nil))
    }
}
