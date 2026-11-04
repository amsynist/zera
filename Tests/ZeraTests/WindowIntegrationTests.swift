import AppKit
import ApplicationServices
import XCTest
@testable import Zera

@MainActor
final class WindowIntegrationTests: XCTestCase {
    func testLiveTwoThreeFourWindowLayoutsAndRestore() async throws {
        guard let path = ProcessInfo.processInfo.environment["ZERA_WINDOW_FIXTURE"] else { throw XCTSkip("opt-in disposable native window test") }
        let url = URL(fileURLWithPath: path)
        guard Bundle(url: url)?.bundleIdentifier == "io.github.amsynist.zera.media-windows" else { throw XCTSkip("only synthetic fixture windows are allowed") }
        guard AXIsProcessTrusted() else { throw XCTSkip("Accessibility not granted to test runner") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true; configuration.arguments = ["--four-windows"]
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 700_000_000)
        let display = try XCTUnwrap(ArrangeDisplay.current().first(where: \.main))
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("zera-window-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: journal) }
        let access = ArrangeWindowAccess(journalURL: journal)
        let apps = [ArrangeApplication(pid: app.processIdentifier, bundle: "io.github.amsynist.zera.media-windows", name: "Fixture")]
        let initial = await Task.detached { access.scan(apps: apps, frontPID: app.processIdentifier, displays: [display.frame]).windows }.value
        XCTAssertEqual(initial.count, 4)
        guard initial.count == 4 else { return }
        for count in 2...4 {
            for layout in [ArrangeLayout.columns, .grid] {
                let windows = Array(initial.prefix(count))
                let frames = Dictionary(uniqueKeysWithValues: zip(windows.map(\.id), layout.frames(count: count, in: display.area)))
                let failure = await Task.detached { access.apply(windows: windows, active: [1], frames: frames, assistiveTechnologyActive: false, animated: false) }.value
                XCTAssertNil(failure)
                let actual = await Task.detached { access.scan(apps: apps, frontPID: app.processIdentifier, displays: [display.frame]).windows }.value
                XCTAssertEqual(actual.count, 4)
                for window in actual where frames[window.id] != nil {
                    XCTAssertTrue(ArrangeGeometry.near(window.frame, try XCTUnwrap(frames[window.id]), tolerance: 1), "settled native bounds must match within one point")
                }
            }
        }
        let originals = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0.frame) })
        let error = await Task.detached { access.apply(windows: initial, active: [1], frames: originals, assistiveTechnologyActive: false, animated: false) }.value
        XCTAssertNil(error)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var elements: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &elements), .success)
        let element = try XCTUnwrap((elements as? [AXUIElement])?.first)
        var title: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        let original = try XCTUnwrap(initial.first { $0.title == title as? String })
        XCTAssertEqual(AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue), .success)
        try await Task.sleep(nanoseconds: 700_000_000)
        let minimized = await Task.detached { access.scan(apps: apps, frontPID: app.processIdentifier, displays: [display.frame]) }.value
        XCTAssertFalse(minimized.windows.contains { $0.id == original.id })
        XCTAssertTrue(minimized.knownIDs.contains(original.id), "minimizing must retain identity without arranging the hidden window")
        XCTAssertEqual(AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse), .success)
        try await Task.sleep(nanoseconds: 700_000_000)
        let restored = await Task.detached { access.scan(apps: apps, frontPID: app.processIdentifier, displays: [display.frame]) }.value
        XCTAssertTrue(restored.windows.contains { $0.id == original.id }, "restoring must retain the original window/group identity")
    }
}
