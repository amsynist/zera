import AppKit
import ApplicationServices
import XCTest
@testable import Zera

@MainActor
final class ProductionReadinessTests: XCTestCase {
    private var savedPreferences: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        savedPreferences = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("zera.navigation.") }
        for key in savedPreferences.keys { UserDefaults.standard.removeObject(forKey: key) }
    }
    override func tearDown() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("zera.navigation.") { UserDefaults.standard.removeObject(forKey: key) }
        for (key, value) in savedPreferences { UserDefaults.standard.set(value, forKey: key) }
        super.tearDown()
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    func testRememberedDestinationsSurviveRelaunchAndIgnoreTransientScreens() throws {
        let suite = "zera.navigation.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = NotchNavigation(defaults: defaults)
        XCTAssertTrue(first.remembersScreen)
        first.record(.taskExport)
        first.set(TaskExport.Span.yesterday.rawValue, for: "export.span")
        for transient in [CardKind.phoneTransfer, .toast, .approval, .result, .reminderAlert] { first.record(transient) }
        let relaunched = NotchNavigation(defaults: defaults)
        XCTAssertEqual(relaunched.destination(fallback: .home), .taskExport)
        XCTAssertEqual(relaunched.integer("export.span"), TaskExport.Span.yesterday.rawValue)
        relaunched.remembersScreen = false
        XCTAssertEqual(relaunched.destination(fallback: .shelf), .shelf)
        XCTAssertEqual(relaunched.integer("export.span"), 0)
        defaults.set(99999, forKey: "zera.navigation.screen")
        relaunched.remembersScreen = true
        XCTAssertEqual(relaunched.destination(fallback: .home), .home)
    }

    func testScrollRestoreClampsAfterDataShrinks() throws {
        let suite = "zera.scroll.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NotchNavigation(defaults: defaults)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let scroll = NSScrollView(frame: root.bounds)
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 1000))
        scroll.documentView = doc; root.addSubview(scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        navigation.captureScroll(in: root, screen: .tasks)
        doc.setFrameSize(NSSize(width: 500, height: 300))
        navigation.restoreScroll(in: root, screen: .tasks)
        XCTAssertEqual(scroll.contentView.bounds.minY, 100, accuracy: 1)
    }

    func testBackNavigationStillReturnsToItsSourceWithMemoryDisabled() throws {
        let suite = "zera.back.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = NotchNavigation(defaults: defaults)
        navigation.remembersScreen = false
        navigation.recordSettingsReturn(.taskExport)
        XCTAssertEqual(navigation.settingsReturn, .taskExport)
        XCTAssertNil(defaults.object(forKey: "zera.navigation.settings.return"), "temporary Back state must not require durable screen memory")
        navigation.recordSettingsReturn(.phoneTransfer)
        XCTAssertEqual(navigation.settingsReturn, .taskExport)
    }

    func testSettingsHoverControlIsClickableAndClearOfAllTabsAndCutout() throws {
        _ = NSApplication.shared
        for style in HoverMenuStyle.allCases {
            for width: CGFloat in [720, 900, 1200] {
                let island = IslandView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
                island.centerX = width / 2; island.band = 34; island.notchWidth = 190; island.hoverStyle = style
                island.peek()
                RunLoop.main.run(until: Date().addingTimeInterval(0.85))
                island.layoutSubtreeIfNeeded()
                let settings = try XCTUnwrap(descendants(island).compactMap { $0 as? IslandClose }.first { $0.accessibilityLabel() == "Settings" })
                XCTAssertFalse(settings.isHidden)
                XCTAssertGreaterThan(settings.alphaValue, 0.9)
                XCTAssertGreaterThanOrEqual(settings.frame.minY, island.band)
                XCTAssertGreaterThanOrEqual(settings.frame.width, 28)
                XCTAssertTrue(island.islandContains(NSPoint(x: settings.frame.midX, y: settings.frame.midY)))
                for tab in descendants(island).compactMap({ $0 as? IslandTab }) { XCTAssertFalse(tab.frame.intersects(settings.frame), "\(width), \(style), \(tab.kind)") }
                var tapped = false; island.onSettings = { tapped = true }
                XCTAssertTrue(settings.accessibilityPerformPress()); XCTAssertTrue(tapped)
                island.close(animated: false)
            }
        }
    }

    func testUsableDisplayGeometryUsesRealDockAndMenuBarInsets() {
        for frame in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: -200, width: 1920, height: 1080)] {
            for visible in [frame.insetBy(dx: 0, dy: 24), CGRect(x: frame.minX + 72, y: frame.minY + 38, width: frame.width - 72, height: frame.height - 38)] {
                let display = ArrangeDisplay(id: "fixture", name: "Fixture", frame: frame, visible: visible, main: true)
                XCTAssertEqual(display.area, visible.insetBy(dx: 8, dy: 8))
                for count in 2...4 {
                    for layout in [ArrangeLayout.columns, .rows, .grid] {
                        let frames = layout.frames(count: count, in: display.area)
                        XCTAssertEqual(frames.count, count)
                        XCTAssertTrue(frames.allSatisfy { display.area.contains($0) })
                        for (i, r) in frames.enumerated() { XCTAssertTrue(frames.dropFirst(i + 1).allSatisfy { !r.intersects($0) }) }
                    }
                }
            }
        }
    }

    func testInsertionRejectsSecureDisabledAndUnknownControls() {
        XCTAssertTrue(DictationInsertionTarget.permitsInsertion(role: kAXTextFieldRole, subrole: nil, enabled: true, writable: false))
        XCTAssertTrue(DictationInsertionTarget.permitsInsertion(role: kAXTextAreaRole, subrole: nil, enabled: true, writable: true))
        XCTAssertFalse(DictationInsertionTarget.permitsInsertion(role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, enabled: true, writable: true))
        XCTAssertFalse(DictationInsertionTarget.permitsInsertion(role: kAXTextFieldRole, subrole: nil, enabled: false, writable: true))
        XCTAssertFalse(DictationInsertionTarget.permitsInsertion(role: kAXButtonRole, subrole: nil, enabled: true, writable: false))
        XCTAssertFalse(DictationInsertionTarget.permitsInsertion(role: nil, subrole: nil, enabled: true, writable: false))
    }

    func testPermissionStatusesAndExportDestinationIdentity() {
        XCTAssertEqual(PermissionAccess.status(authorized: false, determined: false), .undecided)
        XCTAssertEqual(PermissionAccess.status(authorized: false, determined: true), .denied)
        XCTAssertEqual(PermissionAccess.status(authorized: true, determined: true), .allowed)
        XCTAssertEqual(CardKind.phoneTransfer.rawValue, 16)
        XCTAssertEqual(CardKind.taskExport.rawValue, 17)
        XCTAssertEqual(Isle.tab(for: .taskExport), .tasks)
        XCTAssertEqual(SettingsCard.Pane.codex.rawValue, 13)
    }

    func testNativeDesktopChangeStopsRemainingWritesAndRollback() {
        let epoch = ArrangeOperationEpoch(), ticket = epoch.ticket()
        let windows = (0..<3).map { i in ArrangeWindow(id: "\(i)", app: "Fixture", bundle: "fixture", title: "Synthetic", pid: 42, frame: CGRect(x: i * 300, y: 40, width: 300, height: 400), workspace: 1, minimized: false) }
        let targets = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame.offsetBy(dx: 10, dy: 20)) })
        var writes = 0
        let error = ArrangeTransaction.apply(windows: windows, active: [1], frames: targets, read: { id in
            windows.first { $0.id == id }.map { ($0.frame, false) }
        }, setFrame: { _, frame in
            writes += 1; epoch.invalidate(); return frame
        }, setMinimized: { _, _ in XCTFail("No minimize is needed"); return true }, isCurrent: { epoch.matches(ticket) })
        XCTAssertNotNil(error)
        XCTAssertEqual(writes, 1, "No later write or rollback may run after leaving the desktop")
    }

    func testRememberedClipboardAndReminderFiltersKeepTheirContext() throws {
        let previous = NotchNavigation.shared.remembersScreen
        NotchNavigation.shared.remembersScreen = true
        defer { NotchNavigation.shared.remembersScreen = previous }
        let clipboard = ClipboardView()
        let filters = try XCTUnwrap(descendants(clipboard).compactMap { $0 as? GitHubSegmentedControl }.first)
        filters.onSelect?(ClipboardStore.Filter.pinned.rawValue)
        let search = try XCTUnwrap(descendants(clipboard).compactMap { $0 as? SearchBox }.first)
        search.field.stringValue = "unfinished search"
        clipboard.willShow()
        XCTAssertEqual(filters.selected, ClipboardStore.Filter.pinned.rawValue)
        XCTAssertEqual(search.field.stringValue, "unfinished search")
        let reminders = RemindersView()
        let tabs = try XCTUnwrap(descendants(reminders).compactMap { $0 as? GitHubSegmentedControl }.first)
        tabs.onSelect?(2)
        reminders.willShow()
        XCTAssertEqual(tabs.selected, 2)
    }

    func testYesterdayExportUsesCalendarDayAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
        let range = TaskExport.Span.yesterday.range(now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: range.0), 8)
        XCTAssertEqual(calendar.component(.hour, from: range.0), 0)
        XCTAssertEqual(range.1.timeIntervalSince(range.0), 23 * 3600)
        XCTAssertTrue(TaskExport.fileName(.yesterday, .csv, now: now, calendar: calendar).contains("2026-03-08"))
    }

    func testClosingOnboardingPreservesProgressWithoutFinishing() throws {
        let savedDone = OnboardingState.done, savedStep = OnboardingState.step
        defer { OnboardingState.done = savedDone; OnboardingState.step = savedStep }
        OnboardingState.done = false; OnboardingState.step = 3
        let controller = OnboardingWindowController()
        controller.window?.close()
        XCTAssertFalse(OnboardingState.done)
        XCTAssertEqual(OnboardingState.step, 3)
    }

    func testFinishingOnboardingDoesNotPresentItAgain() throws {
        let savedDone = OnboardingState.done, savedStep = OnboardingState.step
        defer { OnboardingState.done = savedDone; OnboardingState.step = savedStep }
        OnboardingState.done = false; OnboardingState.step = 4
        let controller = OnboardingWindowController()
        let root = try XCTUnwrap(controller.window?.contentView)
        let open = try XCTUnwrap(descendants(root).compactMap { $0 as? CardButton }.first { $0.accessibilityLabel() == "Open Zera" })
        open.performClick(nil)
        XCTAssertTrue(OnboardingState.done)
        XCTAssertNil(OnboardingWindowController.presentIfNeeded())
    }

    func testCompactSettingsRebuildControlsInsideTheActualPaneWidth() throws {
        let settings = SettingsCard(defaultKind: .home, showingZera: true, loginEnabled: false)
        for width: CGFloat in [720, 880] {
            settings.setFrameSize(NSSize(width: width, height: 640))
            for pane in [SettingsCard.Pane.general, .permissions, .notch] {
                settings.select(pane); settings.layoutSubtreeIfNeeded()
                for control in descendants(settings).compactMap({ $0 as? ZeraSelect }) {
                    let parent = try XCTUnwrap(control.superview)
                    XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
                    XCTAssertLessThanOrEqual(control.frame.maxX, parent.bounds.width)
                }
            }
        }
    }

    func testEmptySegmentIndicatorDuringViewSwitchIsSafe() {
        // This used to raise "No current point for control point bounds" in AppKit,
        // terminating the application during rapid Clipboard grid/list switches.
        Pal.drawSegmentIndicator(NSBezierPath())
    }

    func testCancelledModelLoadCannotResurrectOrFailRemovedModel() async throws {
        guard Murmur.isAvailable else { throw XCTSkip("WhisperKit not linked") }
        let defaults = UserDefaults.standard, key = "zera.murmur.folder"
        let saved = defaults.object(forKey: key)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zera-empty-model-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { defaults.set(saved, forKey: key); try? FileManager.default.removeItem(at: folder) }
        defaults.set(folder.path, forKey: key)
        let model = Murmur()
        model.start()
        XCTAssertEqual(model.state, .loading)
        model.remove()
        XCTAssertEqual(model.state, .notInstalled)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(model.state, .notInstalled, "a cancelled loader must not publish failure or readiness")
    }

    func testProviderMigrationPreservesExistingAppleDictationWithoutModel() {
        let defaults = UserDefaults.standard
        let useKey = "zera.murmur.use", folderKey = "zera.murmur.folder"
        let use = defaults.object(forKey: useKey), folder = defaults.object(forKey: folderKey)
        defer { defaults.set(use, forKey: useKey); defaults.set(folder, forKey: folderKey) }
        defaults.removeObject(forKey: useKey); defaults.removeObject(forKey: folderKey)
        let model = Murmur()
        XCTAssertFalse(model.useForDictation)
        XCTAssertEqual(defaults.object(forKey: useKey) as? Bool, false)
        model.useForDictation = true
        XCTAssertTrue(Murmur().useForDictation, "an explicit model choice must not silently switch providers")
    }

    func testOlderCompletedTasksSurviveLoadingAndResaving() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zera-history-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TaskStore(url: url)
        store.now = { Date(timeIntervalSince1970: 1_000_000) }
        let task = try XCTUnwrap(store.add("Historical fixture task 20m"))
        store.toggleDone(task.id)
        store.flush()
        let reloaded = TaskStore(url: url)
        XCTAssertEqual(reloaded.tasks.map(\.id), [task.id], "loading years later must preserve the user's timesheet history")
        reloaded.flush()
        XCTAssertEqual(TaskStore(url: url).tasks.map(\.id), [task.id])
    }
}
