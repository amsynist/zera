import AppKit
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
        XCTAssertTrue(list.contains { $0.pid == getpid() }, "the opener includes its own running process")
    }

    func testScanFindsDeepAppsAndExternalAliasesWithoutBundleDuplicatesOrHelpers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ path: String, id: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": id, "CFBundleName": url.deletingPathExtension().lastPathComponent,
                        "CFBundlePackageType": "APPL", "CFBundleExecutable": "test"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let installed = root.appendingPathComponent("Applications")
        let editor = try app("Applications/Vendor/2026/Editor.app", id: "test.editor")
        _ = try app("Applications/Vendor/2026/Editor.app/Contents/Helpers/Hidden.app", id: "test.helper")
        let safari = try app("System/Cryptexes/Safari.app", id: "test.safari")
        _ = try app("Applications/Copy.app", id: "test.editor")
        let alias = root.appendingPathComponent("Safari.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: safari)
        let found = AppCatalog.scan(folders: [installed], additionalURLs: [alias, safari, editor])
        XCTAssertEqual(Set(found.compactMap(\.bundleID)), ["test.editor", "test.safari"])
        XCTAssertEqual(found.count, 2)
        let discoveredSafari = try XCTUnwrap(found.first { $0.bundleID == "test.safari" })
        XCTAssertEqual(discoveredSafari.url.path, alias.standardizedFileURL.path, "keep the launchable alias rather than its physical target")
        XCTAssertEqual(discoveredSafari.name, "Safari")
    }

    func testProcessAndPortParsersKeepAllEntriesAndExecutablePaths() {
        let processes = (2...102).map { "\($0)\t1.5 2048 /Applications/My App.app/Contents/MacOS/Worker\($0)" }.joined(separator: "\n")
        let parsed = ProcessTools.parseProcesses(processes)
        XCTAssertEqual(parsed.count, 101)
        XCTAssertTrue(parsed.contains { $0.name == "Worker102" && $0.path.contains("My App.app") })
        let ports = (3000...3100).map { "p42\ncnode\nn*:\($0)\nn[::1]:\($0)" }.joined(separator: "\n")
        let listening = ProcessTools.parseListeningPorts(ports)
        XCTAssertEqual(listening.count, 101, "IPv4/IPv6 duplicates are one row per process and port")
        XCTAssertEqual(listening.last?.port, 3100)
    }

    func testEmptyCommandArrowNavigationAndReopeningRestoreAppPlaceholder() throws {
        let view = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        view.prepare()
        field.stringValue = "Custom Commands"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        let tile = try XCTUnwrap(descendants(view).compactMap { $0 as? OpenerTile }.first { $0.accessibilityLabel() == "Custom Commands" })
        tile.onClick?()
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:))))
        view.prepare()
        XCTAssertEqual(field.placeholderAttributedString?.string, "Open an app…")
        XCTAssertEqual(field.stringValue, "")
    }

    func testArrowsReachActionsBeyondSixTilesAndQuickOpenUsesTheVisiblePage() throws {
        let view = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        view.prepare()
        for _ in 0..<3 {
            XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        }
        for _ in 0..<6 {
            XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        }
        let visible = descendants(view).compactMap { $0 as? OpenerTile }.filter { !$0.isHidden }
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible.first?.accessibilityLabel(), OpenerActions.title(.takeBreak))
        var opened: QuickAction?
        view.onAction = { opened = $0 }
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil, characters: "2", charactersIgnoringModifiers: "2",
            isARepeat: false, keyCode: 19))
        XCTAssertTrue(view.performKeyEquivalent(with: key))
        guard case .searchFiles? = opened else { return XCTFail("Quick-open should use the second slot on the visible page") }
    }
}
