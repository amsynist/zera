import AppKit
import XCTest
@testable import Zera

@MainActor
final class ControlInteractionTests: XCTestCase {
    func testNewCompanionCoversWingCenterAndReceivesPointer() {
        let wings = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        wings.centerX = 650
        wings.layoutSubtreeIfNeeded()
        XCTAssertEqual(wings.companion.frame.midX, 650, accuracy: 0.5)
        XCTAssertGreaterThan(wings.companion.frame.width, 28)
        XCTAssertTrue(wings.bounds.contains(wings.companion.frame))
        let center = NSPoint(x: wings.companion.frame.midX, y: wings.companion.frame.midY)
        XCTAssertTrue(wings.wingContains(center))
        XCTAssertTrue(wings.hitTest(center) === wings.companion)
    }
    func testManagedApprovalWingsUseProviderAndForwardExactRequest() throws {
        let wings = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        let request = HookRequest(id: "managed-codex:exact-id", receivedAt: Date(), sessionID: "owned-thread", toolName: "Question", command: "Which target?", detail: "Codex · Project", cwd: "/tmp/Project")
        var received: HookRequest?
        wings.onDecide = { request, _ in received = request }
        wings.update(session: nil, pending: request, provider: "Codex", review: true)
        XCTAssertEqual(wings.mode, .approval)
        XCTAssertTrue(wings.accessibilityLabel()?.contains("Codex needs your approval") == true)
        let review = try XCTUnwrap(wings.subviews.first { $0.accessibilityLabel() == "Review…" })
        XCTAssertTrue(review.accessibilityPerformPress())
        XCTAssertEqual(received?.id, request.id)
        XCTAssertEqual(received?.sessionID, request.sessionID)
        wings.update(session: nil, pending: nil)
        XCTAssertNil(wings.request)
        XCTAssertEqual(wings.mode, .idle)
    }
    func testCompanionExposesDefaultActionAndNavigationWithoutHovering() {
        let companion = NotchBuddyView(frame: NSRect(x: 0, y: 0, width: 300, height: 38))
        var opened = 0, navigated = 0
        companion.onActivate = { opened += 1 }
        companion.onShowNavigation = { navigated += 1 }
        XCTAssertEqual(companion.accessibilityRole(), .button)
        XCTAssertEqual(companion.accessibilityLabel(), "Zera companion")
        XCTAssertTrue(companion.accessibilityPerformPress())
        XCTAssertTrue(companion.accessibilityPerformShowMenu())
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(navigated, 1)
        let tile = DeckTile(symbol: "checkmark.circle")
        XCTAssertEqual(tile.accessibilityRole(), .button)
        XCTAssertTrue(tile.acceptsFirstResponder)
        XCTAssertTrue(IslandClose().acceptsFirstResponder)
        let tab = IslandTab(kind: .clipboard)
        XCTAssertTrue(tab.acceptsFirstResponder)
        var chosen = false
        tab.onTap = { chosen = true }
        tab.performClick(nil)
        XCTAssertTrue(chosen)
    }

    func testShortcutRecorderReportsTheAssignedShortcut() {
        let recorder = ShortcutRecorder(frame: .zero)
        recorder.shortcut = .default
        XCTAssertEqual(recorder.accessibilityValue() as? String, HotKeyShortcut.default.label)
        recorder.shortcut = nil
        XCTAssertEqual(recorder.accessibilityValue() as? String, "Off")
    }

    func testShortcutRecorderRestoresHotkeysWhenItsWindowLosesFocus() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = ShortcutRecorder(frame: CGRect(x: 10, y: 10, width: 160, height: 32))
        window.contentView?.addSubview(recorder)
        var paused: [Bool] = []; recorder.onRecording = { paused.append($0) }
        XCTAssertTrue(recorder.accessibilityPerformPress()); XCTAssertTrue(recorder.isRecording)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(recorder.isRecording, "Leaving the panel must not leave all global controls unregistered")
        XCTAssertEqual(paused, [true, false])
        window.close()
    }

    func testShortcutRecorderStopsOnDetachAndExplicitPageCancellation() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = ShortcutRecorder(frame: CGRect(x: 10, y: 10, width: 160, height: 32))
        window.contentView?.addSubview(recorder)
        var paused: [Bool] = []; recorder.onRecording = { paused.append($0) }
        _ = recorder.accessibilityPerformPress(); recorder.cancelRecording()
        XCTAssertFalse(recorder.isRecording); XCTAssertEqual(paused, [true, false])
        _ = recorder.accessibilityPerformPress(); recorder.removeFromSuperview()
        XCTAssertFalse(recorder.isRecording); XCTAssertEqual(paused, [true, false, true, false])
        window.close()
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }

    func testNativeToggleExposesItsStateAndDoesNotActivateWhenDisabled() {
        _ = NSApplication.shared
        let toggle = Toggle()
        toggle.setAccessibilityLabel("Echo shortcuts")
        var values: [Bool] = []
        toggle.onChange = { values.append($0) }
        XCTAssertTrue(toggle.isAccessibilityElement())
        XCTAssertEqual(toggle.accessibilityRole(), .checkBox)
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertTrue(toggle.isOn)
        XCTAssertEqual(toggle.accessibilityValue() as? NSNumber, true)
        XCTAssertEqual(values, [true])
        toggle.isEnabled = false
        XCTAssertFalse(toggle.accessibilityPerformPress())
        XCTAssertEqual(values, [true])
    }

    func testFiltersOfferAccessibleOptionsAndArrowSelection() throws {
        _ = NSApplication.shared
        let filters = GitHubSegmentedControl(items: [
            .init(symbol: "", title: "All", count: 4, tint: nil),
            .init(symbol: "", title: "Waiting", count: 1, tint: nil)])
        filters.frame = NSRect(x: 0, y: 0, width: 240, height: Metrics.segment)
        var selected: [Int] = []
        filters.onSelect = { selected.append($0) }
        filters.layoutSubtreeIfNeeded()
        let options = try XCTUnwrap(filters.accessibilityChildren() as? [NSButton])
        XCTAssertEqual(options.map { $0.accessibilityLabel() }, ["All, 4", "Waiting, 1"])
        let window = NSWindow(contentRect: filters.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = filters
        defer { window.contentView = nil }
        XCTAssertTrue(options[1].accessibilityPerformPress())
        XCTAssertEqual(filters.selected, 1)
        XCTAssertTrue(window.firstResponder === options[1])
        filters.layoutSubtreeIfNeeded()
        XCTAssertEqual(options[1].accessibilityValue() as? NSNumber, true)
        options[1].keyDown(with: try key(123))
        XCTAssertEqual(filters.selected, 0)
        XCTAssertEqual(selected, [1, 0])
    }

    func testMultiChoiceArrowMovesFocusWithoutTogglingAndPressKeepsASelection() throws {
        _ = NSApplication.shared
        let chips = ChoiceChips(items: [.init(title: "Mon"), .init(title: "Tue")])
        chips.multiple = true
        chips.frame = NSRect(x: 0, y: 0, width: 200, height: Metrics.chip)
        chips.layoutSubtreeIfNeeded()
        let options = try XCTUnwrap(chips.accessibilityChildren() as? [NSButton])
        options[0].keyDown(with: try key(124))
        XCTAssertEqual(chips.selection, [0])
        XCTAssertTrue(options[1].accessibilityPerformPress())
        XCTAssertEqual(chips.selection, [0, 1])
        XCTAssertTrue(options[0].accessibilityPerformPress())
        XCTAssertEqual(chips.selection, [1])
        XCTAssertTrue(options[1].accessibilityPerformPress())
        XCTAssertEqual(chips.selection, [1])
    }

    func testFloatingFocusCardHasAnAccessibleCollapseAction() throws {
        _ = NSApplication.shared
        let card = FocusCardView(store: TaskStore(url: nil))
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let close = try XCTUnwrap(descendants(card).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Collapse focus card" })
        var collapsed = false
        card.onClose = { collapsed = true }
        close.performClick(nil)
        XCTAssertTrue(collapsed)
    }

    func testContextMenuExposesOnlyActionTargets() throws {
        let menu = NeonMenuView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        menu.items = [.header("Project"), .action("Focus", "play") {}, .separator,
                      .action("Archive", "archivebox") {}]
        menu.layoutSubtreeIfNeeded()
        var chosen: String?
        menu.onChoose = { chosen = $0.title }
        let actions = try XCTUnwrap(menu.accessibilityChildren() as? [NSButton])
        XCTAssertEqual(actions.map { $0.accessibilityLabel() }, ["Focus", "Archive"])
        XCTAssertTrue(actions[1].accessibilityPerformPress())
        XCTAssertEqual(chosen, "Archive")
        XCTAssertTrue(actions.allSatisfy { $0.frame.width > 0 && menu.bounds.contains($0.frame) })
    }

    func testSplitButtonExposesSeparateMainAndMenuActions() throws {
        let split = GHSplitButton(title: "Add Event", symbol: "plus")
        split.frame = NSRect(x: 0, y: 0, width: 170, height: 34)
        split.layoutSubtreeIfNeeded()
        let actions = try XCTUnwrap(split.accessibilityChildren() as? [NSButton])
        XCTAssertEqual(actions.map { $0.accessibilityLabel() }, ["Add Event", "More Add Event options"])
        var main = 0, menu = 0
        split.onMain = { main += 1 }
        split.onMenu = { _ in menu += 1 }
        XCTAssertTrue(actions[0].accessibilityPerformPress())
        XCTAssertTrue(actions[1].accessibilityPerformPress())
        XCTAssertEqual(main, 1)
        XCTAssertEqual(menu, 1)
        XCTAssertFalse(actions[0].frame.intersects(actions[1].frame))
    }

    func testTabLeavesTheSingleChoiceGroupForTheNextField() throws {
        _ = NSApplication.shared
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let filters = PillTabs(titles: ["All", "Waiting"])
        filters.frame = NSRect(x: 0, y: 0, width: 250, height: 32)
        let field = ThemedField(placeholder: "Search")
        field.frame = NSRect(x: 0, y: 50, width: 250, height: 32)
        root.addSubview(filters); root.addSubview(field)
        let window = FloatingPanel.make(size: root.frame.size, level: .floating, keyable: true)
        window.contentView = root
        defer { window.contentView = nil }
        filters.layoutSubtreeIfNeeded()
        let options = try XCTUnwrap(filters.accessibilityChildren() as? [NSButton])
        XCTAssertTrue(options[1].accessibilityPerformPress())
        filters.layoutSubtreeIfNeeded()
        options[1].keyDown(with: try key(48))
        let focused = try XCTUnwrap(window.firstResponder)
        XCTAssertTrue(focused === field || field.currentEditor() === focused)
    }
}
