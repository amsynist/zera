import XCTest
@testable import Zera

final class SoundKitTests: XCTestCase {
    func testOpeningSoundSettingsDoesNotPrepareTheEntireAudioLibrary() {
        let service = SoundService(directory: dir)
        _ = service.enabled
        _ = service.volume
        XCTAssertEqual(service.preparedFileCount, 0)
    }
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
