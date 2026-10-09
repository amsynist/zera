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
        XCTAssertEqual(field.placeholderAttributedString?.string, "Search apps, commands, or actions…")
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
        let captions = descendants(view).compactMap { $0 as? OrbitCaption }.sorted { $0.frame.midX < $1.frame.midX }
        XCTAssertEqual(captions.map(\.key), (1...captions.count).map { "⌘\($0)" }, "shortcuts follow the visual left-to-right order")
        let second = try XCTUnwrap(captions.first { $0.key == "⌘2" })
        XCTAssertEqual(opened.map { OpenerActions.title($0) }, second.title, "⌘2 opens the second visible tile")
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(view.openBranchTitle, "COMMANDS")
    }

    func testTypingOpensEveryBranchWithItsMatches() throws {
        let (view, field) = try opener()
        type("kill", view, field)
        XCTAssertTrue(view.visibleRowTitles.contains("Kill Process"))
        XCTAssertTrue(view.visibleRowTitles.contains("Kill Port"))
        XCTAssertFalse(view.visibleRowTitles.contains("Clipboard History"))
    }

    func testThreeSearchResultsSurroundTheSelectedTile() throws {
        let (view, field) = try opener()
        type("kill", view, field)
        let tiles = descendants(view).compactMap { $0 as? OrbitTile }.filter { $0.alphaValue > 0 }
        XCTAssertEqual(tiles.count, 3)
        let chosen = try XCTUnwrap(tiles.first { $0.chosen })
        XCTAssertEqual(tiles.filter { $0.frame.midX < chosen.frame.midX }.count, 1)
        XCTAssertEqual(tiles.filter { $0.frame.midX > chosen.frame.midX }.count, 1)
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveRight(_:))))
        XCTAssertNotEqual(tiles.first { $0.chosen }?.title, chosen.title, "arrows browse while a search query is present")
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertEqual(tiles.first { $0.chosen }?.title, chosen.title)
    }

    private func descendants(_ parent: NSView) -> [NSView] {
        parent.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor
    func testWindowRoutesKeysAfterSearchLosesFocus() throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: "appOpener.style")
        defer { UserDefaults.standard.set(saved, forKey: "appOpener.style") }
        AppOpenerSettings.style = .orbit
        let manager = AppOpener()
        manager.open(notch: NSRect(x: 340, y: 730, width: 180, height: 30), screen: NSRect(x: 0, y: 0, width: 860, height: 760))
        defer { manager.close(); RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
        let view = try XCTUnwrap(manager.panel.contentView as? AppOpenerView)
        let button = NSButton(title: "Focus elsewhere", target: nil, action: nil)
        view.addSubview(button)
        XCTAssertTrue(manager.panel.makeFirstResponder(button))
        func key(_ code: UInt16, _ characters: String, mods: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                windowNumber: manager.panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        manager.panel.sendEvent(try key(48, "\t"))
        XCTAssertEqual(view.openBranchTitle, "COMMANDS")
        manager.panel.sendEvent(try key(124, "\u{f703}"))
        XCTAssertTrue(manager.panel.performKeyEquivalent(with: try key(46, "m", mods: .command)))
        XCTAssertTrue(view.isShowingActions)
        XCTAssertFalse(manager.panel.isMiniaturized)
        XCTAssertTrue(manager.panel.makeFirstResponder(button))
        manager.panel.sendEvent(try key(53, "\u{1b}"))
        XCTAssertFalse(view.isShowingActions)
        XCTAssertTrue(manager.isOpen, "Esc leaves the action node before closing the opener")
        manager.panel.sendEvent(try key(53, "\u{1b}"))
        XCTAssertFalse(manager.isOpen)
        // A second Esc dismisses immediately even while the exit animation is running.
        manager.panel.sendEvent(try key(53, "\u{1b}"))
        XCTAssertFalse(manager.panel.isVisible)
        XCTAssertNil(manager.panel.contentView)
    }

    @MainActor
    func testRapidCloseReopenDoesNotHideTheNewPresentation() throws {
        _ = NSApplication.shared
        let manager = AppOpener()
        let screen = NSRect(x: 0, y: 0, width: 860, height: 760)
        let notch = NSRect(x: 340, y: 730, width: 180, height: 30)
        var changes: [Bool] = []
        manager.onOpenChanged = { changes.append($0) }
        manager.open(notch: notch, screen: screen)
        manager.close()
        manager.open(notch: notch, screen: screen)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(manager.isOpen)
        XCTAssertTrue(manager.panel.isVisible)
        manager.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(manager.panel.isVisible)
        XCTAssertNil(manager.panel.contentView)
        XCTAssertEqual(changes, [true, true, false])
    }

    func testHoverZoomKeepsTheIconCentreFixedAndReverses() throws {
        let tile = OrbitTile(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        let layer = try XCTUnwrap(tile.layer)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0))
        // AppKit's backing layer can use either anchor; both must grow from the centre.
        for anchor: CGFloat in [0, 0.5] {
            layer.anchorPoint = CGPoint(x: anchor, y: anchor)
            tile.mouseEntered(with: event)
            let t = layer.transform
            let centre = tile.bounds.width * (0.5 - anchor)
            XCTAssertGreaterThan(t.m11, 1)
            XCTAssertEqual(centre * t.m11 + t.m41, centre, accuracy: 0.001)
            XCTAssertEqual(centre * t.m22 + t.m42, centre, accuracy: 0.001)
            tile.mouseExited(with: event)
            XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
        }
    }

    func testOrbitGuidanceFitsOnShortDisplays() throws {
        for height: CGFloat in [600, 768, 900] {
            let view = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 1440, height: height))
            view.prepare()
            view.layoutSubtreeIfNeeded()
            let guidance = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }
                .first { $0.stringValue.contains("Browse") })
            XCTAssertLessThanOrEqual(guidance.frame.maxY, height - 16, "guidance fits at \(height) pt")
        }
    }

    func testActionListFitsOnCompactDisplay() throws {
        var ready = !AppCatalog.shared.apps.isEmpty
        AppCatalog.shared.refreshIfNeeded { ready = true }
        let deadline = Date().addingTimeInterval(8)
        while !ready, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(ready)
        let view = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 1024, height: 600))
        view.prepare()
        let otherCaption = try XCTUnwrap(descendants(view).compactMap { $0 as? OrbitCaption }.first { !$0.chosen })
        otherCaption.onClick?()
        XCTAssertTrue(descendants(view).compactMap { $0 as? OrbitCaption }.contains { $0.chosen && $0.title == otherCaption.title },
                      "clicking an app name selects its icon")
        view.previewType("safari")
        view.layoutSubtreeIfNeeded()
        let rootVisible = descendants(view).filter { !$0.isHidden }
        let rootGuidance = try XCTUnwrap(rootVisible.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("Browse") })
        XCTAssertLessThanOrEqual(rootGuidance.frame.maxY, 584)
        for caption in rootVisible.compactMap({ $0 as? OrbitCaption }) {
            XCTAssertLessThanOrEqual(caption.frame.maxY, 584)
            XCTAssertNotNil(caption.onClick)
        }
        view.previewActions()
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.isShowingActions)
        let visible = descendants(view).filter { !$0.isHidden }
        let guidance = try XCTUnwrap(visible.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("Browse actions") })
        XCTAssertLessThanOrEqual(guidance.frame.maxY, 584)
        let scroll = try XCTUnwrap(visible.compactMap { $0 as? NSScrollView }.first)
        XCTAssertLessThanOrEqual(scroll.convert(scroll.bounds, to: view).maxY, 584)
        let rows = descendants(view).compactMap { $0 as? TreeRowView }
        XCTAssertFalse(rows.isEmpty)
        if rows.count <= 7 {
            for row in rows { XCTAssertLessThanOrEqual(row.frame.maxY, scroll.documentVisibleRect.maxY + 1) }
        }
    }

    @MainActor
    func testActionTransitionCanReverseWithoutLeavingDuplicateIcons() async throws {
        _ = NSApplication.shared
        var ready = !AppCatalog.shared.apps.isEmpty
        AppCatalog.shared.refreshIfNeeded { ready = true }
        let deadline = Date().addingTimeInterval(8)
        while !ready, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(ready)
        let view = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        view.prepare()
        func flights() -> [NSImageView] {
            descendants(view).compactMap { $0 as? NSImageView }.filter { $0.layer?.animation(forKey: "actionFlight") != nil }
        }
        view.previewActions()
        if !Motion.reduced {
            XCTAssertEqual(flights().count, 1, "the selected icon moves continuously into the header")
            let rows = descendants(view).compactMap { $0 as? TreeRowView }
            let delays = rows.compactMap { $0.layer?.animation(forKey: "actionFade")?.beginTime }
            XCTAssertGreaterThan(delays.count, 1)
            XCTAssertEqual(delays, delays.sorted(), "options unfold in order")
            let flight = try XCTUnwrap(flights().first)
            let holder = try XCTUnwrap(flight.superview)
            let header = try XCTUnwrap(descendants(view).compactMap { $0 as? NSImageView }.first {
                $0 !== flight && $0.image === flight.image && $0.bounds.width == 34
            })
            let flyingLayer = try XCTUnwrap(flight.layer)
            let restingPosition = flyingLayer.position
            view.needsLayout = true
            view.layoutSubtreeIfNeeded(); window.display(); CATransaction.flush()
            try await Task.sleep(nanoseconds: 120_000_000)
            let target = holder.convert(header.bounds, from: header)
            XCTAssertEqual(flight.frame.minX, target.minX, accuracy: 0.01)
            XCTAssertEqual(flight.frame.minY, target.minY, accuracy: 0.01)
            XCTAssertEqual(flight.frame.size, target.size)
            XCTAssertEqual(flyingLayer.position, restingPosition, "AppKit must not readjust the landing position")
        }
        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 16_000_000)
            view.previewActions() // Reverse before the flight finishes.
            view.previewActions()
            XCTAssertLessThanOrEqual(flights().count, 1)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(view.isShowingActions)
        XCTAssertTrue(flights().isEmpty, "temporary moving icons are released")
        view.previewActions()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(view.isShowingActions)
        XCTAssertTrue(flights().isEmpty)
        XCTAssertEqual(descendants(view).compactMap { $0 as? OrbitTile }.filter { $0.chosen }.count, 1)
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
        type("no such action", view, field)
        XCTAssertNil(view.chosenActionTitle)
        XCTAssertTrue(descendants(view).compactMap { $0 as? TreeRowView }.isEmpty, "filtering removes stale clickable actions")
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(view.isShowingActions)
        XCTAssertEqual(field.stringValue, "Kill Port", "folding them brings your search back")
        XCTAssertTrue(view.performKeyEquivalent(with: cmdK))
        XCTAssertTrue(view.performKeyEquivalent(with: cmdK), "⌘K again folds them")
        XCTAssertFalse(view.isShowingActions)
        XCTAssertTrue(view.performKeyEquivalent(with: cmdK))
        let openRow = try XCTUnwrap(descendants(view).compactMap { $0 as? TreeRowView }.first { $0.accessibilityLabel() == "Open Command" })
        let parent = NSView(frame: view.frame)
        parent.addSubview(view)
        let titlePoint = openRow.convert(NSPoint(x: 80, y: openRow.bounds.midY), to: parent)
        let clickedView = view.hitTest(titlePoint)
        XCTAssertTrue(clickedView === openRow, "clicking an action label reaches its row")
        XCTAssertTrue(openRow.accessibilityPerformPress(), "the visible action row is an interactive button")
        XCTAssertFalse(view.isShowingActions)
        XCTAssertEqual(field.placeholderAttributedString?.string, "Port number…")
    }

    func testCommandMOpensActionsAndEscapeRestoresTheSearch() throws {
        let (view, field) = try opener()
        type("kill port", view, field)
        let cmdM = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46))
        XCTAssertTrue(view.performKeyEquivalent(with: cmdM))
        XCTAssertTrue(view.isShowingActions)
        XCTAssertEqual(view.chosenActionTitle, "Open Command")
        XCTAssertTrue(descendants(view).compactMap { $0 as? TreeRowView }.allSatisfy(\.accessoryKeycap))
        type("no such action", view, field)
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(view.isShowingActions)
        XCTAssertEqual(field.stringValue, "kill port")
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
        let rows = descendants(view).compactMap { $0 as? TreeRowView }
        XCTAssertGreaterThanOrEqual(rows.count, 3)
        XCTAssertEqual(rows.filter(\.selected).count, 1)
        XCTAssertEqual(rows.first(where: \.selected)?.accessibilityLabel(), "Force Quit Process")
        // Typing narrows them; ⏎ runs the chosen one (copying the PID here) and folds them away.
        type("copy process", view, field)
        XCTAssertEqual(view.chosenActionTitle, "Copy Process ID")
        let before = NSPasteboard.general.string(forType: .string)
        XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(view.isShowingActions)
        XCTAssertNotNil(Int32(NSPasteboard.general.string(forType: .string) ?? ""), "the PID was copied")
        if let before = before { AppTools.copy(before) }
    }

    func testClassicActionShortcutAliasesRestoreQueryAndEmptySearchCannotRun() throws {
        _ = NSApplication.shared
        let view = TreeOpenerView(frame: NSRect(x: 0, y: 0, width: 860, height: 760))
        view.prepare()
        view.previewType("Kill Process")
        let field = view.searchField
        for key in ["m", "k"] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: key == "m" ? 46 : 40))
            XCTAssertTrue(view.performKeyEquivalent(with: event))
            XCTAssertTrue(view.isShowingActions)
            XCTAssertFalse(view.visibleRowTitles.isEmpty)
            view.previewType("zzzz-no-action-matches")
            view.layoutSubtreeIfNeeded()
            XCTAssertNil(view.chosenActionTitle)
            let primary = try XCTUnwrap(descendants(view).compactMap { $0 as? TreeButton }.first { $0.primary })
            XCTAssertTrue(primary.isHidden, "an empty action search must not offer a Run button")
            XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            XCTAssertFalse(view.isShowingActions)
            XCTAssertEqual(field.stringValue, "Kill Process")
        }
    }

    func testCommandQNeverQuitsZera() throws {
        let view = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        view.prepare()
        // A real running app exposes a functioning ⌘Q action. Never dispatch that against
        // the user's Your Usual list: this test checks fallback routing, not app termination.
        view.previewType("Custom Commands")
        XCTAssertTrue(view.visibleRowTitles.contains("Custom Commands"))
        XCTAssertFalse(view.visibleRowTitles.contains("ChatGPT"))
        let cmdQ = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        XCTAssertTrue(view.performKeyEquivalent(with: cmdQ), "swallowed, not passed on to the Quit Zera item")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
