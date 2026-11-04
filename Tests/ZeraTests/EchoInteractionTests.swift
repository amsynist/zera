import AppKit
import XCTest
@testable import Zera

@MainActor
final class EchoInteractionTests: XCTestCase {
    private func shortcut(_ key: String, code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    func testReroutingAnOlderCaptionCannotReplaceANewerCommand() throws {
        let echo = CommandEcho()
        defer { echo.stop() }
        let caption = try XCTUnwrap(echo.presentCaption(EchoContent(symbol: "face.smiling", keys: "", text: "Hello"), replacing: nil, hold: 6))
        echo.present(EchoContent(symbol: "doc.on.doc", keys: "⌘C", text: "Copy"), hold: nil)
        XCTAssertNil(echo.presentCaption(EchoContent(symbol: "face.smiling", keys: "", text: "Hello"), replacing: caption, hold: 6))
        echo.dismissPresented(revision: caption)
        XCTAssertEqual(echo.currentFeedback?.text, "Copy")
    }

    func testOldHudFadeCannotClearANewerFeedbackContour() async throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("native WindowServer needed for HUD fade") }
        let hud = EchoHUD()
        defer { hud.hide(animated: false) }
        hud.show(EchoContent(symbol: "doc.on.doc", keys: "⌘C", text: "Copy"))
        hud.hide(animated: true)
        hud.show(EchoContent(symbol: "doc.on.clipboard", keys: "⌘V", text: "Paste again"))
        let width = try XCTUnwrap(hud.contourWidth)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(hud.isVisible)
        XCTAssertEqual(hud.currentContent?.text, "Paste again")
        XCTAssertEqual(hud.contourWidth, width)
    }

    func testLocalKeysAndMediaCannotClaimGlobalKeyboardAccess() {
        XCTAssertFalse(GlobalKeys.isGlobalKeyDelivery(.systemDefined, frontmostPID: 200, ownPID: 100))
        XCTAssertFalse(GlobalKeys.isGlobalKeyDelivery(.flagsChanged, frontmostPID: 200, ownPID: 100))
        XCTAssertFalse(GlobalKeys.isGlobalKeyDelivery(.keyDown, frontmostPID: 100, ownPID: 100))
        XCTAssertFalse(GlobalKeys.isGlobalKeyDelivery(.keyDown, frontmostPID: nil, ownPID: 100))
        XCTAssertFalse(GlobalKeys.isGlobalKeyDelivery(.keyDown, frontmostPID: 200, ownPID: 100, ownsKeyWindow: true),
                       "a nonactivating Zera panel can own the key window while another app is frontmost")
        XCTAssertTrue(GlobalKeys.isGlobalKeyDelivery(.keyDown, frontmostPID: 200, ownPID: 100))
    }

    func testLaterPresentationCancelsCopyPollingAndItsReaction() async throws {
        _ = NSApplication.shared
        let echo = CommandEcho()
        defer { echo.stop() }
        var reactions: [NotchLightReaction] = []
        echo.onReaction = { reaction, _ in reactions.append(reaction) }
        echo.handle(try shortcut("c", code: 8))
        echo.present(EchoContent(symbol: "mic", keys: "", text: "Listening"), hold: nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(echo.currentFeedback?.text, "Listening")
        XCTAssertFalse(reactions.contains(.copy), "an old copy must not react over a newer event")
    }

    func testAnOlderHideCannotDismissANewerPersistentPresentation() async throws {
        _ = NSApplication.shared
        let echo = CommandEcho()
        defer { echo.stop() }
        echo.present(EchoContent(symbol: "checkmark", keys: "", text: "Saved"), hold: 0.05)
        echo.present(EchoContent(symbol: "mic", keys: "", text: "Listening"), hold: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(echo.currentFeedback?.text, "Listening")
    }

    func testEndingAnOlderCaptionDoesNotDismissANewerCommand() {
        _ = NSApplication.shared
        let echo = CommandEcho()
        defer { echo.stop() }
        let caption = echo.present(EchoContent(symbol: "face.smiling", keys: "", text: "Hello"), hold: nil)
        let command = echo.present(EchoContent(symbol: "doc.on.doc", keys: "⌘C", text: "Copy"), hold: nil)
        echo.dismissPresented(revision: caption)
        XCTAssertEqual(echo.currentFeedback?.keys, "⌘C")
        echo.dismissPresented(revision: command)
        XCTAssertNil(echo.currentFeedback)
    }

    func testConfiguredOptionShortcutUsesItsActionLabelAndRespectsDisable() {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: "zera.echo.enabled")
        defer { UserDefaults.standard.set(saved, forKey: "zera.echo.enabled") }
        let echo = CommandEcho()
        defer { echo.stop() }
        UserDefaults.standard.set(true, forKey: "zera.echo.enabled")
        echo.configuredShortcut(keys: "⌥Space", label: "App opener", symbol: "square.grid.2x2")
        XCTAssertEqual(echo.currentFeedback?.keys, "⌥Space")
        XCTAssertEqual(echo.currentFeedback?.text, "App opener")
        echo.dismissPresented()
        UserDefaults.standard.set(false, forKey: "zera.echo.enabled")
        echo.configuredShortcut(keys: "⌥Space", label: "App opener", symbol: "square.grid.2x2")
        XCTAssertNil(echo.currentFeedback)
    }

    func testFeedbackStaysOnNotchedNotchlessAndExternalDisplayFrames() {
        for screen in [NSRect(x: 0, y: 0, width: 1512, height: 982),
                       NSRect(x: -1920, y: 120, width: 1920, height: 1080),
                       NSRect(x: 1512, y: -800, width: 640, height: 800)] {
            for height: CGFloat in [24, 38] {
                let notch = NSRect(x: screen.midX - 90, y: screen.maxY - height, width: 180, height: height)
                let hud = NotchGeometry.feedbackFrame(screen: screen, notch: notch)
                XCTAssertTrue(screen.contains(hud))
                XCTAssertEqual(hud.maxY, screen.maxY)
                XCTAssertEqual(hud.midX, notch.midX, accuracy: 0.5)
            }
        }
    }

    func testOpeningIslandClearsPixelChromeEvenWhenVisibilityChangesFirst() {
        let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                          cornerWidth: 20, cornerHeight: 20, transform: nil)
        func shapes(_ layer: CALayer) -> [CAShapeLayer] {
            (layer as? CAShapeLayer).map { [$0] } ?? []
                + (layer.sublayers ?? []).flatMap(shapes)
        }
        let light = NotchLightLayer()
        light.quietWhenExpanded = true
        light.lightStyle = .pixel
        light.apply(path: path, bounds: path.boundingBox, mode: .closed, animated: false)
        light.setVisible(true)
        light.apply(path: path, bounds: path.boundingBox, mode: .open, animated: false)
        light.accent = .red
        let visible = shapes(light).filter { !$0.isHidden && $0.strokeColor != nil }
        XCTAssertFalse(visible.isEmpty)
        XCTAssertTrue(visible.allSatisfy { $0.lineDashPattern == nil })
        XCTAssertTrue(visible.allSatisfy { $0.strokeColor == NSColor.white.withAlphaComponent(0.10).cgColor })
        let preview = NotchLightLayer()
        preview.lightStyle = .pixel
        preview.apply(path: path, bounds: path.boundingBox, mode: .open, animated: false)
        XCTAssertTrue(shapes(preview).contains { !$0.isHidden && $0.lineDashPattern != nil },
                      "the style picker must still show the actual pixel style")
    }

    func testLevelRevealAdvancesFromNotchToBothScreenEdges() throws {
        let mask = LightLevelMask()
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 140)
        let notch = CGRect(x: 400, y: 0, width: 200, height: 38)
        for value: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            mask.update(bounds: bounds, notch: notch, value: value)
            let solids = try XCTUnwrap(mask.layer.sublayers).filter { !($0 is CAGradientLayer) }
            XCTAssertEqual(solids[0].frame.minX, 400 * (1 - value), accuracy: 0.01)
            XCTAssertEqual(solids[1].frame.maxX, 600 + 400 * value, accuracy: 0.01)
            XCTAssertEqual(solids[2].frame.width, notch.width, "the curved notch bridge never disconnects")
        }
    }

    func testTopLightIsOneContinuousContourAroundNotch() {
        for height: CGFloat in [24, 34, 38] {
            let bounds = CGRect(x: 0, y: 0, width: 1512, height: 140)
            let notch = CGRect(x: 600, y: 140 - height, width: 312, height: height)
            let path = NotchGeometry.topLightPath(bounds: bounds, notch: notch)
            var moves = 0, curves = 0
            path.applyWithBlock { element in
                if element.pointee.type == .moveToPoint { moves += 1 }
                if [.addQuadCurveToPoint, .addCurveToPoint].contains(element.pointee.type) { curves += 1 }
            }
            XCTAssertEqual(moves, 1, "no detached screen strip or second border")
            XCTAssertEqual(curves, 4)
            XCTAssertEqual(path.boundingBoxOfPath.width, bounds.width, accuracy: 0.001)
            XCTAssertEqual(path.boundingBoxOfPath.height, height, accuracy: 0.01)
            XCTAssertEqual(path.currentPoint.x, bounds.maxX, accuracy: 0.001)
            let rim = NotchGeometry.topLightPath(bounds: bounds, notch: notch, withArms: false)
            XCTAssertEqual(rim.boundingBoxOfPath.width, notch.width)
        }
    }

    func testOneLinePrompterIsReadableWithoutScrolling() {
        let store = TeleprompterStore(url: nil)
        _ = store.newScript(title: "One line", text: "Ready to read")
        let roll = TeleprompterRoll(store: store)
        roll.script = store.current
        roll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        roll.layoutSubtreeIfNeeded()
        XCTAssertEqual(roll.remainingSeconds, 0)
        roll.script = TeleprompterScript(title: "Empty", text: "")
        XCTAssertNil(roll.remainingSeconds)
    }
}
