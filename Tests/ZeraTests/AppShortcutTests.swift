import AppKit
import XCTest
@testable import Zera

@MainActor
final class AppShortcutTests: XCTestCase {
    private func temporaryDefaults() -> UserDefaults { UserDefaults(suiteName: "AppShortcutTests.\(UUID())")! }
    func testMigrateOnlyAppBindingsAndPreserveOriginal() throws {
        let defaults = temporaryDefaults()
        let original = Data(#"{"enabled":true,"apps":[{"name":"Notes","bundle":"com.apple.Notes","path":"/System/Applications/Notes.app","workspace":2,"shortcut":{"keyCode":45,"modifiers":768,"key":"N"}}],"workspaces":[{"id":2,"name":"Work"}]}"#.utf8)
        defaults.set(original, forKey: "zera.scrollingWorkspaces.v1")
        let migrated = AppShortcutPreferences.load(from: defaults)
        XCTAssertTrue(migrated.enabled); XCTAssertEqual(migrated.apps.count, 1)
        XCTAssertEqual(migrated.apps.first?.shortcut?.key, "N")
        XCTAssertEqual(defaults.data(forKey: "zera.scrollingWorkspaces.v1"), original)
        XCTAssertEqual(AppShortcutPreferences.load(from: defaults), migrated)
    }
    func testFreshInstallAndLegacyFallback() {
        let defaults = temporaryDefaults()
        XCTAssertEqual(AppShortcutPreferences.load(from: defaults), .init())
        defaults.set(Data(#"{"enabled":false,"rules":[{"name":"Notes","bundle":"com.apple.Notes","path":"/System/Applications/Notes.app"}]}"#.utf8), forKey: "zera.windowArrangement.v1")
        let value = AppShortcutPreferences.load(from: defaults)
        XCTAssertFalse(value.enabled); XCTAssertEqual(value.apps.first?.bundle, "com.apple.Notes")
    }
    func testDuplicateAndUnmodifiedBindingsRejected() {
        var value = AppShortcutPreferences()
        let key = HotKeyShortcut.default
        value.apps = [.init(name: "A", bundle: "a", path: "/a", shortcut: key), .init(name: "B", bundle: "b", path: "/b", shortcut: key)]
        XCTAssertFalse(value.hasValidBindings)
        value.apps[1].shortcut = nil; XCTAssertTrue(value.hasValidBindings)
        value.apps[0].shortcut?.modifiers = 0; XCTAssertFalse(value.hasValidBindings)
    }
    func testDisabledUpdatesPersistAndInvalidChangeRollsBack() {
        let defaults = temporaryDefaults(), service = AppShortcuts(defaults: temporaryDefaults())
        var value = AppShortcutPreferences(); value.apps = [.init(name: "Fixture", bundle: "fixture", path: "/fixture", shortcut: .default)]
        value.save(to: defaults); XCTAssertEqual(AppShortcutPreferences.load(from: defaults), value)
        XCTAssertTrue(service.update { $0.apps = value.apps })
        XCTAssertFalse(service.update { $0.apps[0].shortcut?.modifiers = 0 })
        XCTAssertEqual(service.preferences.apps, value.apps); XCTAssertFalse(service.preferences.enabled)
    }
    func testRecordingStillRejectsAHotkeyOwnedElsewhere() throws {
        let service = AppShortcuts(defaults: temporaryDefaults())
        let shortcut = HotKeyShortcut(keyCode: 105, modifiers: 6400, key: "F13")
        guard let occupied = GlobalHotKey(shortcut, handler: {}) else { throw XCTSkip("Test combination already reserved") }
        defer { withExtendedLifetime(occupied) {} }
        XCTAssertTrue(service.update { $0.enabled = true; $0.apps = [.init(name: "Fixture", bundle: "fixture", path: "/fixture")] })
        service.pause(true)
        XCTAssertFalse(service.update { $0.apps[0].shortcut = shortcut })
        XCTAssertNil(service.preferences.apps[0].shortcut)
        service.pause(false); service.stop()
    }
    func testExternalConflictDoesNotDisableUnrelatedApps() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutOwner-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("ShortcutOwner")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/ShortcutOwner/main.swift")
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", source.path, "-o", executable.path]
        try compiler.run(); compiler.waitUntilExit(); XCTAssertEqual(compiler.terminationStatus, 0)
        let owner = Process(), output = Pipe(), lifetime = Pipe()
        owner.executableURL = executable; owner.standardOutput = output; owner.standardInput = lifetime
        try owner.run()
        defer { try? lifetime.fileHandleForWriting.close(); owner.waitUntilExit() }
        let registration = String(data: output.fileHandleForReading.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard registration == "0" else { throw XCTSkip("Fixture combination already owned: \(registration ?? "no status")") }
        let defaults = temporaryDefaults()
        AppShortcutPreferences(enabled: true, apps: [
            .init(name: "Occupied", bundle: "fixture.occupied", path: "/fixture", shortcut: .init(keyCode: 105, modifiers: 6400, key: "F13")),
            .init(name: "Available", bundle: "fixture.available", path: "/fixture", shortcut: .init(keyCode: 107, modifiers: 6400, key: "F14"))
        ]).save(to: defaults)
        let service = AppShortcuts(defaults: defaults); service.start(); defer { service.stop() }
        XCTAssertEqual(service.unavailableApps, ["Occupied"])
        XCTAssertEqual(service.registeredCount, 1, "A conflict must not remove unrelated working app bindings")
    }
    func testLayoutControlsFitAndNavigationIdentitySurvives() {
        _ = NSApplication.shared
        let service = AppShortcuts(defaults: temporaryDefaults())
        XCTAssertTrue(service.update { $0.apps = [.init(name: "Fixture", bundle: "fixture", path: "/fixture")] })
        for width: CGFloat in [720, 880] {
            let view = AppShortcutsView(service: service)
            view.frame = CGRect(x: 0, y: 0, width: width, height: 600); view.layoutSubtreeIfNeeded()
            @MainActor func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
            let recorders = descendants(view).compactMap { $0 as? ShortcutRecorder }
            XCTAssertEqual(recorders.count, 1)
            for control in recorders { XCTAssertTrue(view.bounds.contains(view.convert(control.bounds, from: control))) }
        }
        XCTAssertEqual(CardKind.appShortcuts.rawValue, 15)
    }
    func testDiscardingARecordingScreenRestoresLiveBindings() throws {
        _ = NSApplication.shared
        let service = AppShortcuts(defaults: temporaryDefaults())
        guard service.update({ $0.enabled = true; $0.apps = [.init(name: "Fixture", bundle: "fixture", path: "/fixture", shortcut: .init(keyCode: 107, modifiers: 6400, key: "F14"))] }) else { throw XCTSkip("Test combination already owned") }
        defer { service.stop() }
        autoreleasepool {
            var view: AppShortcutsView? = AppShortcutsView(service: service)
            view?.frame = CGRect(x: 0, y: 0, width: 880, height: 600); view?.layoutSubtreeIfNeeded()
            @MainActor func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
            let recorder = descendants(view!).compactMap { $0 as? ShortcutRecorder }.first!
            XCTAssertTrue(recorder.accessibilityPerformPress())
            XCTAssertEqual(service.registeredCount, 0)
            view = nil
        }
        XCTAssertEqual(service.registeredCount, 1, "Closing a recording screen must not leave every app shortcut paused")
    }
}
