import XCTest
@testable import Zera

final class SoundKitTests: XCTestCase {
    private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Resources/Sounds").standardizedFileURL

    func testEverySoundHasItsFile() {
        for sound in ZeraSound.allCases {
            for name in sound.files {
                XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name + ".wav").path), name)
            }
        }
    }

    func testTapsRotateThroughThreePitches() {
        XCTAssertEqual(ZeraSound.tap.files.count, 3)
    }

    func testGitHubIsTheOnlyFamilyOffByDefault() {
        XCTAssertEqual(ZeraSound.Family.allCases.filter { !$0.onByDefault }, [.github])
    }

    func testAlertsAreLouderThanWhispers() {
        XCTAssertGreaterThan(ZeraSound.claudeApproval.gain, ZeraSound.tab.gain)
        XCTAssertGreaterThan(ZeraSound.reminder.gain, ZeraSound.caption.gain)
    }
}
