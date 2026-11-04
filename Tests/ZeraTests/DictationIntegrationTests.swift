import AppKit
import ApplicationServices
import CryptoKit
import XCTest
@testable import Zera

@MainActor
final class DictationIntegrationTests: XCTestCase {
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func focused(_ app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateSystemWide()
        guard let value = attribute(root, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func clipboardFingerprint() -> [Data] {
        (NSPasteboard.general.pasteboardItems ?? []).flatMap { item in
            item.types.map { type in Data(SHA256.hash(data: Data(type.rawValue.utf8) + (item.data(forType: type) ?? Data()))) }
        }
    }

    func testCrossApplicationNativeWebSecureAndFocusChange() async throws {
        guard let path = ProcessInfo.processInfo.environment["ZERA_DICTATION_FIXTURE"] else { throw XCTSkip("set ZERA_DICTATION_FIXTURE to the disposable input app") }
        let url = URL(fileURLWithPath: path)
        guard Bundle(url: url)?.bundleIdentifier == "io.github.amsynist.zera.dictation-fixture" else { throw XCTSkip("only the synthetic dictation fixture is allowed") }
        guard AXIsProcessTrusted() else { throw XCTSkip("test runner lacks Accessibility; no permission prompt is triggered") }
        _ = NSApplication.shared
        var apps: [NSRunningApplication] = []
        defer { apps.forEach { $0.terminate() } }
        for mode in ["native", "web", "secure"] {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true; configuration.arguments = [mode]
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            apps.append(app)
            try await Task.sleep(nanoseconds: mode == "web" ? 2_000_000_000 : 700_000_000)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, app.processIdentifier)
            if mode == "secure" {
                XCTAssertNil(DictationInsertionTarget.capture(), "Secure fields must never become insertion targets")
                continue
            }
            var field = focused(app)
            for _ in 0..<30 where field == nil {
                try await Task.sleep(nanoseconds: 100_000_000)
                field = focused(app)
            }
            let element = try XCTUnwrap(field, "fixture field must be exposed by AX")
            let target = try XCTUnwrap(DictationInsertionTarget.capture(), "editable native/web field must be captured")
            let originalClipboard = clipboardFingerprint()
            let result = target.insert("Synthetic Zera dictation.")
            XCTAssertTrue(result == .inserted || result == .sent)
            try await Task.sleep(nanoseconds: 700_000_000)
            XCTAssertEqual(attribute(element, kAXValueAttribute) as? String, "Synthetic Zera dictation.")
            XCTAssertTrue(clipboardFingerprint() == originalClipboard, "Paste fallback must restore every original clipboard representation")
            let otherConfiguration = NSWorkspace.OpenConfiguration()
            otherConfiguration.createsNewApplicationInstance = true; otherConfiguration.arguments = ["native"]
            let other = try await NSWorkspace.shared.openApplication(at: url, configuration: otherConfiguration)
            apps.append(other)
            try await Task.sleep(nanoseconds: 700_000_000)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, other.processIdentifier)
            XCTAssertEqual(target.insert("Wrong app"), .unavailable)
            XCTAssertEqual(attribute(element, kAXValueAttribute) as? String, "Synthetic Zera dictation.")
            for _ in 0..<3 {
                XCTAssertTrue(ApplicationActivation.activate(app))
                try await Task.sleep(nanoseconds: 200_000_000)
                XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, app.processIdentifier)
                XCTAssertTrue(ApplicationActivation.activate(other))
                try await Task.sleep(nanoseconds: 200_000_000)
                XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, other.processIdentifier)
            }
        }
    }
}
