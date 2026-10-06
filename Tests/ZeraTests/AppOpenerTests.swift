import XCTest
@testable import Zera

final class AppOpenerTests: XCTestCase {
    func testPrefixBeatsInitialsBeatsAnywhere() throws {
        let prefix = try XCTUnwrap(AppMatcher.match("Safari", "saf"))
        let initials = try XCTUnwrap(AppMatcher.match("Visual Studio Code", "vsc"))
        let inside = try XCTUnwrap(AppMatcher.match("Microsoft Teams", "team"))
        let scattered = try XCTUnwrap(AppMatcher.match("Terminal", "tml"))
        XCTAssertGreaterThan(prefix.score, initials.score)
        XCTAssertGreaterThan(initials.score, inside.score)
        XCTAssertGreaterThan(inside.score, scattered.score)
        XCTAssertEqual(initials.hits, [0, 7, 14])
        XCTAssertNil(AppMatcher.match("Notes", "xyz"))
    }

    func testCapitalsCountAsWordStarts() throws {
        XCTAssertEqual(try XCTUnwrap(AppMatcher.match("PhpStorm", "ps")).hits, [0, 3])
    }

    func testKillFindsBothCommands() {
        XCTAssertNotNil(OpenerCommand.killProcess.match("kill"))
        XCTAssertNotNil(OpenerCommand.killPort.match("kill"))
        XCTAssertNotNil(OpenerCommand.killPort.match("port"))
        XCTAssertNil(OpenerCommand.killPort.match("safari"))
        XCTAssertGreaterThanOrEqual(OpenerCommand.killProcess.match("kill p")?.score ?? 0, 500)
    }

    func testDefaultShortcutIsOptionSpace() {
        XCTAssertEqual(AppOpenerSettings.defaultShortcut.label, "⌥Space")
        XCTAssertTrue(AppOpenerSettings.defaultShortcut.isUsable)
    }

    func testProcessListComesBackFast() {
        let start = Date()
        let list = ProcessTools.processes()
        XCTAssertFalse(list.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertFalse(list.contains { $0.pid == getpid() }, "never offers to kill Zera itself")
    }
}
