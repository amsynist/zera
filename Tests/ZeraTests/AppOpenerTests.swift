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

    func testYourUsualPutsPinsFirstThenTheAppYouWereJustIn() {
        func app(_ n: String) -> AppEntry {
            let u = URL(fileURLWithPath: "/Applications/\(n).app")
            return AppEntry(name: n, url: u, bundleID: "test.\(n)", canonicalURL: u)
        }
        let apps = ["Safari", "Code", "Terminal", "Mail", "Slack"].map(app)
        let now = Date().timeIntervalSince1970
        let recent = ["/Applications/Code.app": now - 5, "/Applications/Terminal.app": now - 60, "/Applications/Slack.app": now - 1]
        // You're in Slack: Code (the app before it) comes first, Slack goes to the end.
        var order = AppCatalog.rankUsual(apps, pins: [], recent: recent, weights: ["/Applications/Mail.app": 9], running: [],
                                         current: URL(fileURLWithPath: "/Applications/Slack.app"), runningFirst: true).map(\.name)
        XCTAssertEqual(order.first, "Code")
        XCTAssertEqual(order[1], "Terminal")
        XCTAssertEqual(order.last, "Slack")
        XCTAssertEqual(order.firstIndex(of: "Mail"), 2, "often opened from Zera comes after recently used")
        // Pins lead, in your order, even the app you're in.
        order = AppCatalog.rankUsual(apps, pins: ["/Applications/Slack.app", "/Applications/Safari.app"], recent: recent, weights: [:],
                                     running: [], current: URL(fileURLWithPath: "/Applications/Slack.app"), runningFirst: true).map(\.name)
        XCTAssertEqual(Array(order.prefix(3)), ["Slack", "Safari", "Code"])
        // Long ago doesn't count as recent.
        order = AppCatalog.rankUsual(apps, pins: [], recent: ["/Applications/Terminal.app": now - 30 * 86400], weights: [:],
                                     running: [], current: nil, runningFirst: true).map(\.name)
        XCTAssertNotEqual(order.first, "Terminal")
    }

    func testPinUnpinAndReorder() {
        let cat = AppCatalog.shared
        let saved = UserDefaults.standard.object(forKey: "appOpener.pinned")
        defer { UserDefaults.standard.set(saved, forKey: "appOpener.pinned") }
        UserDefaults.standard.removeObject(forKey: "appOpener.pinned")
        func app(_ n: String) -> AppEntry {
            let u = URL(fileURLWithPath: "/Applications/\(n).app")
            return AppEntry(name: n, url: u, bundleID: nil, canonicalURL: u)
        }
        let a = app("A"), b = app("B"), c = app("C")
        [a, b, c, a].forEach(cat.pin)
        XCTAssertEqual(cat.pins.count, 3, "pinning twice doesn't add twice")
        cat.movePin(c, by: -1)
        XCTAssertEqual(cat.pins.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }, ["A", "C", "B"])
        cat.movePin(a, by: -1)
        XCTAssertEqual(cat.pinIndex(a), 0, "the top one can't go higher")
        cat.unpin(c)
        XCTAssertFalse(cat.isPinned(c))
        XCTAssertEqual(KeyCombo.code(KeyCombo.upKey, [.command, .option]).label, "⌥⌘↑")
    }

    func testHelperAppsStayOutOfTheList() {
        func ok(_ p: String) -> Bool { AppCatalog.isUserFacing(URL(fileURLWithPath: p), nil) }
        XCTAssertTrue(ok("/Applications/Safari.app"))
        XCTAssertTrue(ok("/Applications/Utilities/Some Tool.app"))
        XCTAssertTrue(ok("/System/Applications/Notes.app"))
        XCTAssertTrue(ok("/System/Applications/Utilities/Terminal.app"))
        XCTAssertTrue(ok("/System/Cryptexes/App/System/Applications/Safari.app"))
        XCTAssertTrue(ok("/System/Library/CoreServices/Finder.app"))
        XCTAssertTrue(ok("/System/Library/CoreServices/Applications/Archive Utility.app"))
        XCTAssertTrue(ok(NSHomeDirectory() + "/Applications/Mine.app"))
        XCTAssertTrue(ok(NSHomeDirectory() + "/Code/zera/dist/Zera.app"), "an app you built yourself still shows")
        XCTAssertFalse(ok("/System/Library/PrivateFrameworks/Notes.framework/LinkedNotesUIService.app"))
        XCTAssertFalse(ok("/System/Library/CoreServices/iCloudUserNotificationsd.app"))
        XCTAssertFalse(ok("/Library/Application Support/Vendor/Updater.app"))
        XCTAssertFalse(ok(NSHomeDirectory() + "/Library/Application Support/Vendor/Helper.app"))
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

    private func opener() throws -> (AppOpenerView, NSTextField) {
        let view = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 860, height: 760))
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        view.prepare()
        return (view, field)
    }

    private func type(_ text: String, _ view: AppOpenerView, _ field: NSTextField) {
        field.stringValue = text
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    func testEmptyCommandArrowNavigationAndReopeningRestoreAppPlaceholder() throws {
        let (view, field) = try opener()
        type("Custom Commands", view, field)
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(field.placeholderAttributedString?.string, "Coming soon")
        XCTAssertTrue(view.visibleRowTitles.contains("Custom Commands"))
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:))))
        view.prepare()
        XCTAssertEqual(field.placeholderAttributedString?.string, "Open an app…")
        XCTAssertEqual(field.stringValue, "")
    }

    func testTabOpensTheNextBranchAndQuickOpenUsesWhatShows() throws {
        let (view, field) = try opener()
        var seen: [String] = []
        for _ in 0..<3 {
            seen.append(view.openBranchTitle)
            if view.openBranchTitle == "ACTIONS" { break }
            XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        }
        XCTAssertEqual(view.openBranchTitle, "ACTIONS")
        XCTAssertEqual(Set(seen).count, seen.count, "each ⇥ opens a different branch")
        for a in OpenerActions.all { XCTAssertTrue(view.visibleRowTitles.contains(OpenerActions.title(a))) }
        XCTAssertFalse(view.visibleRowTitles.contains("Kill Port"), "other branches stay folded")
        var opened: QuickAction?
        view.onAction = { opened = $0 }
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil, characters: "2", charactersIgnoringModifiers: "2",
            isARepeat: false, keyCode: 19))
        XCTAssertTrue(view.performKeyEquivalent(with: key))
        guard case .screenshot? = opened else { return XCTFail("⌘2 opens the second item showing") }
    }

    func testTypingOpensEveryBranchWithItsMatches() throws {
        let (view, field) = try opener()
        type("kill", view, field)
        XCTAssertTrue(view.visibleRowTitles.contains("Kill Process"))
        XCTAssertTrue(view.visibleRowTitles.contains("Kill Port"))
        XCTAssertFalse(view.visibleRowTitles.contains("Clipboard History"))
    }

    func testShortcutLabelsAndMatching() throws {
        XCTAssertEqual(KeyCombo.cmd("c", .shift).label, "⇧⌘C")
        XCTAssertEqual(KeyCombo.code(KeyCombo.deleteKey, [.command, .control]).label, "⌃⌘⌫")
        XCTAssertEqual(KeyCombo.code(KeyCombo.returnKey, .command).label, "⌘⏎")
        func key(_ c: String, _ mods: NSEvent.ModifierFlags, code: UInt16 = 0) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(KeyCombo.cmd("c", .shift).matches(try key("C", [.command, .shift], code: 8)))
        XCTAssertFalse(KeyCombo.cmd("c", .shift).matches(try key("c", [.command], code: 8)), "plain ⌘C stays copy")
        XCTAssertTrue(KeyCombo.cmd("q", .option).matches(try key("q", [.command, .option], code: 12)))
        XCTAssertFalse(KeyCombo.cmd("q").matches(try key("q", [.command, .option], code: 12)))
    }

    func testQuitAllIsACommandAndNeverQuitsZeraOrFinder() {
        XCTAssertTrue(OpenerCommand.allCases.contains(.quitAll))
        XCTAssertNotNil(OpenerCommand.quitAll.match("quit"))
        XCTAssertNotNil(OpenerCommand.quitAll.match("clean"))
        XCTAssertFalse(OpenerCommand.quitAll.loadsInBackground)
        let candidates = AppTools.quitCandidates()
        XCTAssertFalse(candidates.contains { $0.processIdentifier == getpid() })
        XCTAssertFalse(candidates.contains { $0.bundleIdentifier == "com.apple.finder" })
        XCTAssertTrue(candidates.allSatisfy { $0.activationPolicy == .regular })
    }

    func testSystemAppsCantBeUninstalled() {
        let mail = URL(fileURLWithPath: "/System/Applications/Mail.app")
        XCTAssertNotNil(AppTools.uninstallBlocker(AppEntry(name: "Mail", url: mail, bundleID: "com.apple.mail", canonicalURL: mail)))
        let other = URL(fileURLWithPath: "/Applications/Some Editor.app")
        XCTAssertNil(AppTools.uninstallBlocker(AppEntry(name: "Some Editor", url: other, bundleID: "test.editor", canonicalURL: other)))
    }

    func testCommandKGrowsActionsUnderTheChosenItemAndEscFoldsThem() throws {
        let (view, field) = try opener()
        type("Kill Port", view, field)
        let cmdK = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        XCTAssertTrue(view.performKeyEquivalent(with: cmdK))
        XCTAssertTrue(view.isShowingActions)
        let titles = view.visibleRowTitles
        let i = try XCTUnwrap(titles.firstIndex(of: "Kill Port"))
        XCTAssertEqual(titles[safe: i + 1], "Open Command", "the action hangs right under its item")
        XCTAssertEqual(field.stringValue, "", "the field now searches the actions")
        XCTAssertEqual(view.chosenActionTitle, "Open Command")
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(view.isShowingActions)
        XCTAssertEqual(field.stringValue, "Kill Port", "folding them brings your search back")
        XCTAssertTrue(view.performKeyEquivalent(with: cmdK))
        XCTAssertTrue(view.performKeyEquivalent(with: cmdK), "⌘K again folds them")
        XCTAssertFalse(view.isShowingActions)
    }

    func testArrowsMoveThroughTheActionsAndEnterRunsTheChosenOne() throws {
        let (view, field) = try opener()
        type("Kill Process", view, field)
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(field.placeholderAttributedString?.string, "Search processes…")
        // Wait for the process list, then open the first process's actions.
        let deadline = Date().addingTimeInterval(5)
        while !view.visibleRowTitles.contains(where: { $0 != "COMMANDS" && !OpenerCommand.allCases.map(\.title).contains($0) }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let cmdK = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        XCTAssertTrue(view.performKeyEquivalent(with: cmdK))
        XCTAssertEqual(view.chosenActionTitle, "Quit Process")
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(view.chosenActionTitle, "Force Quit Process")
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(view.chosenActionTitle, "Copy Process ID")
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(view.chosenActionTitle, "Force Quit Process")
        // Typing narrows them; ⏎ runs the chosen one (copying the PID here) and folds them away.
        type("copy process", view, field)
        XCTAssertEqual(view.chosenActionTitle, "Copy Process ID")
        let before = NSPasteboard.general.string(forType: .string)
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(view.isShowingActions)
        XCTAssertNotNil(Int32(NSPasteboard.general.string(forType: .string) ?? ""), "the PID was copied")
        if let before = before { AppTools.copy(before) }
    }

    func testCommandQNeverQuitsZera() throws {
        let view = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        view.prepare()
        let cmdQ = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        XCTAssertTrue(view.performKeyEquivalent(with: cmdQ), "swallowed, not passed on to the Quit Zera item")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
