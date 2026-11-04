import AppKit
import XCTest
import ScreenCaptureKit
import ApplicationServices
@testable import Zera

final class WindowArrangementTests: XCTestCase {
    func testAppShortcutFollowsManuallyMovedWindowInsteadOfItsDefault() throws {
        let rule = try XCTUnwrap(ArrangeSettings.suppliedRules.first { $0.name == "Teams" })
        XCTAssertEqual(rule.workspace, 1)
        var teams = window("teams", workspace: 3); teams.bundle = rule.bundle; teams.minimized = true
        let rio = window("rio", workspace: 1), before = [rio, teams]
        for _ in 0..<5 {
            let target = ArrangeGeometry.appLaunchTarget(rule, windows: before, focused: rio.id, workspace: 1, active: [1])
            XCTAssertEqual(target.window?.id, teams.id); XCTAssertEqual(target.workspace, 3)
        }
        XCTAssertEqual(before[0], rio); XCTAssertEqual(before[1], teams)
        let newApp = ArrangeGeometry.appLaunchTarget(rule, windows: [rio], focused: rio.id, workspace: 4, active: [4])
        XCTAssertNil(newApp.window); XCTAssertEqual(newApp.workspace, 1)
        var current = rule; current.workspace = nil
        XCTAssertNil(ArrangeGeometry.appLaunchTarget(current, windows: [rio], focused: rio.id, workspace: 4, active: [4]).workspace)
    }
    func testAppShortcutSelectsTheExactExistingWindowAcrossWorkspacesAndDisplays() {
        let rule = ArrangeAppRule(name: "Editor", bundle: "test.fixture", path: "/invalid-but-already-running.app", workspace: 1)
        let a = window("hidden", workspace: 3), b = window("current", workspace: 5), c = window("other-display", workspace: 7)
        XCTAssertEqual(ArrangeGeometry.appLaunchTarget(rule, windows: [a,b,c], focused: a.id, workspace: 5, active: [5,7]).window?.id, a.id)
        XCTAssertEqual(ArrangeGeometry.appLaunchTarget(rule, windows: [a,b,c], focused: nil, workspace: 5, active: [5,7]).window?.id, b.id)
        XCTAssertEqual(ArrangeGeometry.appLaunchTarget(rule, windows: [a,c], focused: nil, workspace: 5, active: [5,7]).window?.id, c.id)
        XCTAssertEqual(ArrangeGeometry.appLaunchTarget(rule, windows: [a], focused: nil, workspace: 5, active: [5,7]).workspace, 3)
    }
    @MainActor func testWorkspaceSlideMovesGroupsAtOriginalScaleAndReversesDirection() throws {
        _ = NSApplication.shared
        let image = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { r in NSColor.orange.setFill(); r.fill(); return true }
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let display = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        let frame = CGRect(x: -1900, y: 0, width: 900, height: 700)
        for direction: CGFloat in [-1,1] {
            let scene = ArrangeVisualTransition(display: display, background: nil, tiles: [.init(id: "old", frame: frame, image: cg)])
            let targets = try XCTUnwrap(scene.stageWorkspace([.init(id: "new", frame: frame, image: cg)], direction: direction))
            XCTAssertEqual(targets["old"], frame.offsetBy(dx: -direction * display.width, dy: 0))
            XCTAssertEqual(targets["incoming:new"], frame)
            for step in 0...30 {
                let progress = CGFloat(step)/30
                let old = ArrangeMotion.frame(from: frame, to: targets["old"]!, progress: progress)
                let new = ArrangeMotion.frame(from: frame.offsetBy(dx: direction * display.width, dy: 0), to: frame, progress: progress)
                XCTAssertEqual(old.size, frame.size); XCTAssertEqual(new.size, frame.size)
                XCTAssertEqual(new.minX - old.minX, direction * display.width, accuracy: 0.001)
            }
            scene.cancel(); XCTAssertNil(scene.stageWorkspace([], direction: direction))
        }
    }
    func testWorkspaceParkingStaysOutsideEveryDisplayWithoutResizing() throws {
        for displays in [[CGRect(x: 0, y: 0, width: 1710, height: 1112)],
                         [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: -100, width: 1920, height: 1080)],
                         [CGRect(x: -100, y: 0, width: 1000, height: 1500), CGRect(x: 900, y: -1080, width: 1920, height: 1080)]] {
            let size = CGSize(width: 850, height: 650)
            let candidates = ArrangeParking.candidates(size: size, displays: displays)
            XCTAssertFalse(candidates.isEmpty)
            for frame in candidates {
                XCTAssertEqual(frame.size, size)
                XCTAssertTrue(ArrangeParking.accepts(frame, displays: displays))
                for display in displays {
                    let visible = frame.intersection(display)
                    XCTAssertTrue(visible.isNull || visible.width <= 2 || visible.height <= 2)
                }
            }
            XCTAssertFalse(ArrangeParking.accepts(displays[0].insetBy(dx: 40, dy: 80), displays: displays))
        }
        XCTAssertFalse(ArrangeParking.accepts(CGRect(x: 9000, y: 9000, width: 100, height: 100), displays: []))
    }
    func testParkingRecoveryRemainsCompatibleWithMinimizedWindowRecords() throws {
        let legacy = "{\"pid\":42,\"bundle\":\"test.fixture\",\"title\":\"Saved\",\"frame\":[[20,55],[700,600]]}"
        var record = try JSONDecoder().decode(ArrangeRecovery.self, from: Data(legacy.utf8))
        XCTAssertNil(record.parkedFrame)
        record.parkedFrame = CGRect(x: 1709, y: 1080, width: 700, height: 600)
        let restored = try JSONDecoder().decode(ArrangeRecovery.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.frame, CGRect(x: 20, y: 55, width: 700, height: 600))
        XCTAssertEqual(restored.parkedFrame, record.parkedFrame)
    }
    func testAXBatchUsesOneReadAndPreservesPerAttributeFailures() throws {
        let keys = [kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, "AXFullScreen"]
        var point = CGPoint(x: -120, y: 55), size = CGSize(width: 700, height: 900), error = AXError.attributeUnsupported
        let values: [AnyObject] = [try XCTUnwrap(AXValueCreate(.cgPoint, &point)), try XCTUnwrap(AXValueCreate(.cgSize, &size)), NSNull(), try XCTUnwrap(AXValueCreate(.axError, &error))]
        var batches = 0, singles = 0
        let result = ArrangeAXRead.values(keys, batch: { batches += 1; return (.success, values) }, single: { _ in singles += 1; return nil })
        XCTAssertEqual(batches, 1); XCTAssertEqual(singles, 0)
        XCTAssertEqual(ArrangeAXRead.frame(result[0], result[1]), CGRect(origin: point, size: size))
        XCTAssertNil(result[2]); XCTAssertNil(result[3])
        XCTAssertNil(ArrangeAXRead.frame(values[1], values[0]))
        XCTAssertNil(ArrangeAXRead.frame(NSString(string: "bad"), values[1]))
        point.x = .infinity
        XCTAssertNil(ArrangeAXRead.frame(AXValueCreate(.cgPoint, &point), values[1]))
    }
    func testAXCompatibilityFallbackDoesNotAmplifyTimeoutsOrClosedWindows() {
        let keys = [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute]
        for error in [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .failure] {
            var singles = 0
            let result = ArrangeAXRead.values(keys, batch: { (error, nil) }, single: { _ in singles += 1; return NSNumber(value: 1) })
            XCTAssertEqual(singles, 0); XCTAssertTrue(result.allSatisfy { $0 == nil })
        }
        for error in [AXError.notImplemented, .illegalArgument, .attributeUnsupported, .success] {
            var called: [String] = []
            let result = ArrangeAXRead.values(keys, batch: { (error, []) }, single: { called.append($0); return NSNumber(value: 1) })
            XCTAssertEqual(called, keys); XCTAssertEqual(result.count, keys.count)
            XCTAssertTrue(result.allSatisfy { ($0 as? NSNumber)?.intValue == 1 })
        }
    }
    func testRefreshBurstCoalescesAndFullReconciliationWinsWithoutLosingAdoption() throws {
        var requests = ArrangeRefreshRequests()
        XCTAssertFalse(requests.pending); XCTAssertNil(requests.take())
        for _ in 0..<100 { requests.include([11]); requests.include([22]) }
        let scoped = try XCTUnwrap(requests.take())
        XCTAssertEqual(scoped.pids, [11,22]); XCTAssertFalse(scoped.adopt); XCTAssertFalse(requests.pending)
        requests.include([11]); requests.include(nil, adopt: true); requests.include([22])
        let full = try XCTUnwrap(requests.take())
        XCTAssertNil(full.pids); XCTAssertTrue(full.adopt); XCTAssertFalse(requests.pending)
        requests.include([33]); XCTAssertEqual(requests.take()?.pids, [33])
    }
    private func window(_ id: String, workspace: Int = 1, frame: CGRect = CGRect(x: 20, y: 60, width: 600, height: 500)) -> ArrangeWindow {
        .init(id: id, app: "Test app", bundle: "test.fixture", title: id, pid: 1, frame: frame, workspace: workspace, minimized: false)
    }
    func testEveryLayoutHasExactCountAndNoOverlapAcrossDisplayShapes() {
        for area in [CGRect(x: 20, y: 55, width: 1472, height: 880), CGRect(x: -1920, y: 100, width: 1880, height: 980), CGRect(x: 1512, y: -900, width: 1000, height: 1500)] {
            for count in 1...20 {
                for layout in ArrangeLayout.allCases {
                    let rects = layout.frames(count: count, in: area)
                    XCTAssertEqual(rects.count, count, "\(layout), \(count)")
                    var windows = (0..<count).map { window(String($0)) }
                    for i in windows.indices { windows[i].minimum = CGSize(width: 1, height: 1) }
                    XCTAssertTrue(ArrangeGeometry.fits(rects, windows: windows, in: area), "\(layout), \(count), \(area)")
                    XCTAssertEqual(rects.map { $0.width * $0.height }.reduce(0,+) <= area.width * area.height, true)
                }
            }
        }
        XCTAssertTrue(ArrangeLayout.grid.frames(count: 0, in: .zero).isEmpty)
        XCTAssertTrue(ArrangeLayout.grid.frames(count: 65, in: CGRect(x: 0, y: 0, width: 1000, height: 800)).isEmpty)
    }
    func testThreeWindowPresetsUseSharedEdgesAndExpectedOrientation() {
        let area = CGRect(x: 20, y: 55, width: 1200, height: 800)
        let top = ArrangeLayout.twoAbove.frames(count: 3, in: area)
        XCTAssertEqual(top[0].minY, top[1].minY)
        XCTAssertEqual(top[0].maxX + 8, top[1].minX)
        XCTAssertEqual(top[0].maxY + 8, top[2].minY)
        XCTAssertEqual(top[2].width, area.width)
        let bottom = ArrangeLayout.twoBelow.frames(count: 3, in: area)
        XCTAssertEqual(bottom[0].width, area.width)
        XCTAssertEqual(bottom[1].minY, bottom[2].minY)
        XCTAssertEqual(ArrangeLayout.columns.frames(count: 3, in: area).map(\.height), [800,800,800])
        XCTAssertEqual(ArrangeLayout.rows.frames(count: 3, in: area).map(\.width), [1200,1200,1200])
    }
    func testUsableAreaRespectsNotchDockAndNegativeExternalOrigins() {
        let screen = ArrangeDisplay(id: "main", name: "Main", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 38, width: 1512, height: 880), main: true)
        XCTAssertEqual(screen.area, CGRect(x: 8, y: 46, width: 1496, height: 864))
        let external = ArrangeDisplay(id: "ext", name: "External", frame: CGRect(x: -1920, y: -100, width: 1920, height: 1080), visible: CGRect(x: -1880, y: -75, width: 1880, height: 1055), main: false)
        XCTAssertEqual(external.area.minX, -1872)
        XCTAssertEqual(external.area.minY, -67)
        XCTAssertEqual(external.area.maxX, -8)
        XCTAssertEqual(external.area.maxY, 972)
    }
    func testMinimumSizesRejectOvercrowdingWithoutOverlapping() {
        let area = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let windows = (0..<3).map { window(String($0)) }
        XCTAssertTrue(ArrangeGeometry.fits(ArrangeLayout.twoAbove.frames(count: 3, in: area), windows: windows, in: area))
        var large = windows; large[0].minimum = CGSize(width: 700, height: 600)
        XCTAssertFalse(ArrangeGeometry.fits(ArrangeLayout.twoAbove.frames(count: 3, in: area), windows: large, in: area))
        XCTAssertFalse(ArrangeGeometry.fits([area,area,area], windows: windows, in: area))
        XCTAssertEqual(ArrangeGeometry.distribution(count: 10, capacity: 4), [4,3,3])
        for n in 1...64 {
            let groups = ArrangeGeometry.distribution(count: n, capacity: 4)
            XCTAssertEqual(groups.reduce(0,+), n)
            XCTAssertLessThanOrEqual(groups.max() ?? 0, 4)
            XCTAssertLessThanOrEqual((groups.max() ?? 0) - (groups.min() ?? 0), 1)
        }
    }
    func testBusyShortcutsRetainOnlyLatestActionAndCancellationReleasesIt() {
        var pending = ArrangePendingShortcut(), executed: [Int] = []
        for value in 0..<100 { pending.replace { executed.append(value) } }
        XCTAssertNil(pending.take(ready: false))
        pending.take(ready: true)?()
        XCTAssertEqual(executed, [99]); XCTAssertNil(pending.take(ready: true))
        pending.replace { executed.append(100) }; pending.cancel()
        XCTAssertNil(pending.take(ready: true)); XCTAssertEqual(executed, [99])
    }
    func testClosedFocusRecoversWithoutSelectingAnotherHiddenWorkspace() {
        let visible = window("visible"), hidden = window("hidden", workspace: 2)
        XCTAssertEqual(ArrangeGeometry.resolvedFocus(observed: nil, previous: "closed", windows: [hidden, visible], active: [1]), "visible")
        XCTAssertNil(ArrangeGeometry.resolvedFocus(observed: nil, previous: "closed", windows: [hidden], active: [1]))
        let next = window("newly-focused")
        XCTAssertEqual(ArrangeGeometry.resolvedFocus(observed: next.id, previous: visible.id, windows: [visible, next], active: [1]), next.id)
    }
    func testDirectionalFocusWrapsWithinTheProvidedWorkspace() {
        let a = window("a", frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let b = window("b", frame: CGRect(x: 408, y: 0, width: 400, height: 800))
        let c = window("c", frame: CGRect(x: 816, y: 0, width: 400, height: 800))
        XCTAssertEqual(ArrangeGeometry.neighbor("a", windows: [a,b,c], dx: 1, dy: 0), "b")
        XCTAssertEqual(ArrangeGeometry.neighbor("c", windows: [a,b,c], dx: 1, dy: 0), "a")
        XCTAssertEqual(ArrangeGeometry.neighbor("a", windows: [a,b,c], dx: -1, dy: 0), "c")
        XCTAssertNil(ArrangeGeometry.neighbor("a", windows: [a], dx: -1, dy: 0))
    }
    func testAdjustedLayoutSurvivesWorkspaceReturnButRejectsMembershipOrderAndDisplayChanges() throws {
        let area = CGRect(x: 20, y: 55, width: 1200, height: 800)
        var windows = ArrangeLayout.columns.frames(count: 3, in: area).enumerated().map { window(String($0.offset), frame: $0.element) }
        let resized = try XCTUnwrap(ArrangeGeometry.resizedDivider("0", windows: windows, in: area, horizontal: true, delta: 50))
        windows = windows.map { var w = $0; w.frame = resized[w.id]!; w.minimized = true; return w }
        let saved = ArrangeManualLayout(area: area, ids: windows.map(\.id))
        XCTAssertEqual(saved.frames(for: windows, in: area), resized, "minimized groups must retain their adjusted geometry")
        XCTAssertNil(saved.frames(for: Array(windows.dropLast()), in: area), "closing a window must allow automatic reflow")
        XCTAssertNil(saved.frames(for: Array(windows.reversed()), in: area), "rotate and swap must not preserve frames by ID")
        XCTAssertNil(saved.frames(for: windows, in: CGRect(x: 20, y: 55, width: 1400, height: 800)), "display changes must replan")
        var invalid = windows; invalid[0].frame = invalid[1].frame
        XCTAssertNil(saved.frames(for: invalid, in: area), "overlapping geometry must never be reused")
    }
    func testDirectResizeBindingsPreserveFocusAndSwapShortcuts() {
        let bindings = ArrangeSettings.bindings
        for (name, arrow) in [("left", "←"), ("right", "→"), ("up", "↑"), ("down", "↓")] {
            XCTAssertEqual(bindings.first { $0.0 == "focus." + name }?.2.label, "⌥" + arrow)
            XCTAssertEqual(bindings.first { $0.0 == "resize." + name }?.2.label, "⌥⇧" + arrow)
        }
        XCTAssertEqual(bindings.first { $0.0 == "move.left" }?.2.label, "⌥⇧H")
        XCTAssertEqual(bindings.first { $0.0 == "resize" }?.2.label, "⌥R")
    }
    func testDirectResizeUsesTheInnerEdgeForLeftRightTopAndBottomTiles() throws {
        let area = CGRect(x: -1200, y: 55, width: 1200, height: 800)
        func tiles(_ layout: ArrangeLayout) -> [ArrangeWindow] {
            layout.frames(count: 2, in: area).enumerated().map { window(String($0.offset), frame: $0.element) }
        }
        let cols = tiles(.columns), rows = tiles(.rows)
        let leftGrow = try XCTUnwrap(ArrangeGeometry.resizedDivider("0", windows: cols, in: area, horizontal: true, delta: 50))
        XCTAssertEqual(leftGrow["0"]!.width, cols[0].frame.width + 50)
        XCTAssertEqual(leftGrow["0"]!.minX, area.minX)
        XCTAssertEqual(leftGrow["1"]!.minX - leftGrow["0"]!.maxX, 8)
        let rightGrow = try XCTUnwrap(ArrangeGeometry.resizedDivider("1", windows: cols, in: area, horizontal: true, delta: -50))
        XCTAssertEqual(rightGrow["1"]!.width, cols[1].frame.width + 50)
        XCTAssertEqual(rightGrow["1"]!.maxX, area.maxX)
        let topGrow = try XCTUnwrap(ArrangeGeometry.resizedDivider("0", windows: rows, in: area, horizontal: false, delta: 50))
        XCTAssertEqual(topGrow["0"]!.height, rows[0].frame.height + 50)
        XCTAssertEqual(topGrow["0"]!.minY, area.minY)
        let bottomGrow = try XCTUnwrap(ArrangeGeometry.resizedDivider("1", windows: rows, in: area, horizontal: false, delta: -50))
        XCTAssertEqual(bottomGrow["1"]!.height, rows[1].frame.height + 50)
        XCTAssertEqual(bottomGrow["1"]!.maxY, area.maxY)
    }
    func testDirectResizeMovesConnectedTJunctionButLeavesOtherGridRowsAlone() throws {
        let area = CGRect(x: 20, y: 55, width: 1200, height: 800)
        let top = ArrangeLayout.twoAbove.frames(count: 3, in: area).enumerated().map { window(String($0.offset), frame: $0.element) }
        let vertical = try XCTUnwrap(ArrangeGeometry.resizedDivider("0", windows: top, in: area, horizontal: false, delta: 50))
        XCTAssertEqual(vertical["0"]!.height, top[0].frame.height + 50)
        XCTAssertEqual(vertical["1"]!.height, top[1].frame.height + 50)
        XCTAssertEqual(vertical["2"]!.minY, top[2].frame.minY + 50)
        let horizontal = try XCTUnwrap(ArrangeGeometry.resizedDivider("0", windows: top, in: area, horizontal: true, delta: 50))
        XCTAssertEqual(horizontal["2"], top[2].frame)
        let grid = ArrangeLayout.grid.frames(count: 4, in: area).enumerated().map { window(String($0.offset), frame: $0.element) }
        let changed = try XCTUnwrap(ArrangeGeometry.resizedDivider("0", windows: grid, in: area, horizontal: true, delta: 50))
        XCTAssertEqual(changed["2"], grid[2].frame); XCTAssertEqual(changed["3"], grid[3].frame)
    }
    func testMiddleTileReversesTheSameEdgeAndMinimumSizesClampTheStep() throws {
        let area = CGRect(x: 0, y: 0, width: 1500, height: 900)
        var columns = ArrangeLayout.columns.frames(count: 3, in: area).enumerated().map { window(String($0.offset), frame: $0.element) }
        let original = columns
        let grown = try XCTUnwrap(ArrangeGeometry.resizedDivider("1", windows: columns, in: area, horizontal: true, delta: 50))
        columns = columns.map { var w = $0; w.frame = grown[w.id]!; return w }
        let reversed = try XCTUnwrap(ArrangeGeometry.resizedDivider("1", windows: columns, in: area, horizontal: true, delta: -50))
        for w in original { XCTAssertEqual(reversed[w.id], w.frame) }
        columns = original; columns[2].minimum.width = columns[2].frame.width - 17
        let clamped = try XCTUnwrap(ArrangeGeometry.resizedDivider("1", windows: columns, in: area, horizontal: true, delta: 50))
        XCTAssertEqual(clamped["1"]!.width, columns[1].frame.width + 17)
        columns = columns.map { var w = $0; w.frame = clamped[w.id]!; return w }
        XCTAssertNil(ArrangeGeometry.resizedDivider("1", windows: columns, in: area, horizontal: true, delta: 50))
    }
    func testDirectResizePreservesBoundsGapsAndNoOverlapForAllPresetShapes() throws {
        for area in [CGRect(x: 20, y: 55, width: 1600, height: 1000), CGRect(x: -1200, y: -900, width: 1100, height: 1500)] {
            for count in 1...10 {
                for layout in ArrangeLayout.allCases {
                    let windows = layout.frames(count: count, in: area).enumerated().map { item -> ArrangeWindow in
                        var w = window(String(item.offset), frame: item.element); w.minimum = CGSize(width: 80, height: 80); return w
                    }
                    guard ArrangeGeometry.fits(windows.map(\.frame), windows: windows, in: area) else { continue }
                    for source in windows {
                        for horizontal in [true, false] {
                            for delta: CGFloat in [-50,50] {
                                guard let resized = ArrangeGeometry.resizedDivider(source.id, windows: windows, in: area, horizontal: horizontal, delta: delta) else { continue }
                                XCTAssertTrue(ArrangeGeometry.fits(windows.map { resized[$0.id]! }, windows: windows, in: area), "\(layout) \(count)")
                                for w in windows {
                                    let r = resized[w.id]!
                                    if horizontal { XCTAssertEqual(r.minY, w.frame.minY); XCTAssertEqual(r.height, w.frame.height) }
                                    else { XCTAssertEqual(r.minX, w.frame.minX); XCTAssertEqual(r.width, w.frame.width) }
                                    if w.frame.minX == area.minX { XCTAssertEqual(r.minX, area.minX) }
                                    if w.frame.maxX == area.maxX { XCTAssertEqual(r.maxX, area.maxX) }
                                    if w.frame.minY == area.minY { XCTAssertEqual(r.minY, area.minY) }
                                    if w.frame.maxY == area.maxY { XCTAssertEqual(r.maxY, area.maxY) }
                                }
                            }
                        }
                    }
                }
            }
        }
        let area = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertNil(ArrangeGeometry.resizedDivider("one", windows: [window("one", frame: area)], in: area, horizontal: true, delta: 50))
    }
    func testSuppliedConfigurationPreservesLaunchAndWorkspaceIntent() throws {
        let settings = ArrangeSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.rules.count, 9)
        XCTAssertEqual(settings.rules.first { $0.name == "Rio" }?.workspace, 2)
        XCTAssertEqual(settings.rules.first { $0.name == "Arc" }?.workspace, 3)
        XCTAssertEqual(settings.rules.first { $0.name == "Xcode" }?.workspace, 5)
        XCTAssertEqual(settings.rules.first { $0.name == "Rio" }?.shortcut?.label, "⌘W")
        let bindings = ArrangeSettings.bindings
        XCTAssertEqual(bindings.first { $0.0 == "workspace.9" }?.2.label, "⌘9")
        XCTAssertEqual(bindings.first { $0.0 == "send.9" }?.2.label, "⇧⌘9")
        let all = bindings.map(\.2) + settings.rules.compactMap(\.shortcut)
        let identities = all.map { "\($0.keyCode)|\($0.modifiers)" }
        XCTAssertEqual(Set(identities).count, identities.count, "preset must not conflict with itself")
        let decoded = try JSONDecoder().decode(ArrangeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.rules, settings.rules)
    }
    func testClampedLayoutRollsBackFramesAndOwnedMinimization() {
        let a = window("a"), b = window("b", workspace: 2)
        var states: [String: (CGRect, Bool)] = ["a": (a.frame, false), "b": (b.frame, false)]
        let target = CGRect(x: 20, y: 60, width: 300, height: 800)
        let failure = ArrangeTransaction.apply(windows: [b,a], active: [1], frames: ["a": target], read: { states[$0] }, setFrame: { id, rect in
            if id == "a", rect == target { return CGRect(x: rect.minX, y: rect.minY, width: 600, height: 800) }
            states[id]?.0 = rect; return states[id]?.0
        }, setMinimized: { id, value in states[id]?.1 = value; return true })
        XCTAssertTrue(failure?.contains("Previous positions restored") == true)
        XCTAssertEqual(states["a"]?.0, a.frame)
        XCTAssertEqual(states["b"]?.0, b.frame)
        XCTAssertEqual(states["a"]?.1, false)
        XCTAssertEqual(states["b"]?.1, false, "failed switch must not strand a newly hidden window")
    }
    func testStaleWindowsDoNotStartAMutationAndRestoreFailureIsReported() {
        let a = window("a")
        var calls = 0
        let stale = ArrangeTransaction.apply(windows: [a], active: [1], frames: ["a": a.frame], read: { _ in nil }, setFrame: { _, _ in calls += 1; return nil }, setMinimized: { _,_ in calls += 1; return true })
        XCTAssertNotNil(stale); XCTAssertEqual(calls, 0)
        let refused = ArrangeTransaction.apply(windows: [a], active: [1], frames: ["a": a.frame], read: { _ in (a.frame, false) }, setFrame: { _,_ in nil }, setMinimized: { _,_ in false })
        XCTAssertTrue(refused?.contains("could not be restored") == true)
    }
    func testFinalReadbackCatchesAnAppChangingAnEarlierTile() {
        let a = window("a"), b = window("b")
        let targetA = CGRect(x: 0, y: 0, width: 500, height: 800), targetB = CGRect(x: 508, y: 0, width: 500, height: 800)
        var states = ["a": a.frame, "b": b.frame]
        let failure = ArrangeTransaction.apply(windows: [a,b], active: [1], frames: ["a": targetA, "b": targetB], read: { id in states[id].map { ($0, false) } }, setFrame: { id, rect in
            states[id] = rect
            if id == "b", rect == targetB { states["a"] = CGRect(x: 0, y: 0, width: 700, height: 800) }
            return rect
        }, setMinimized: { _,_ in true })
        XCTAssertTrue(failure?.contains("changed size while arranging") == true)
        XCTAssertEqual(states["a"], a.frame); XCTAssertEqual(states["b"], b.frame)
    }
    func testSharedMotionPreservesGapsAndSettlesWithoutOvershoot() {
        let from = ArrangeLayout.columns.frames(count: 2, in: CGRect(x: -1920, y: 55, width: 1880, height: 900))
        let to = ArrangeLayout.columns.frames(count: 2, in: CGRect(x: -1800, y: 80, width: 1400, height: 700))
        var previousDistance = CGFloat.infinity
        for step in 0...60 {
            let t = CGFloat(step) / 60
            let a = ArrangeMotion.frame(from: from[0], to: to[0], progress: t)
            let b = ArrangeMotion.frame(from: from[1], to: to[1], progress: t)
            XCTAssertEqual(b.minX - a.maxX, 8, accuracy: 0.001, "all windows must share the same progress")
            XCTAssertGreaterThanOrEqual(a.minX, min(from[0].minX, to[0].minX))
            XCTAssertLessThanOrEqual(a.maxX, max(from[0].maxX, to[0].maxX))
            let distance = abs(a.minX - to[0].minX)
            XCTAssertLessThanOrEqual(distance, previousDistance); previousDistance = distance
        }
        XCTAssertEqual(ArrangeMotion.frame(from: from[0], to: to[0], progress: -1), from[0])
        XCTAssertEqual(ArrangeMotion.frame(from: from[0], to: to[0], progress: 2), to[0])
    }
    func testAnimationFailureRestoresTheOriginalFramesAndMinimization() {
        let a = window("a"), b = window("b", workspace: 2)
        var states: [String: (CGRect, Bool)] = ["a": (a.frame, false), "b": (b.frame, false)]
        let target = CGRect(x: 30, y: 70, width: 500, height: 700)
        var animationCalls = 0
        let failure = ArrangeTransaction.apply(windows: [a,b], active: [1], frames: ["a": target, "b": target],
            read: { states[$0] }, setFrame: { id, frame in states[id]?.0 = frame; return frame },
            setMinimized: { id, hidden in states[id]?.1 = hidden; return true }, animate: { frames in
                animationCalls += 1
                XCTAssertEqual(Set(frames.keys), ["a"], "hidden workspaces must not animate")
                XCTAssertEqual(states["b"]?.1, true)
                states["a"]?.0 = CGRect(x: 25, y: 65, width: 550, height: 600)
                return "A window refused moving."
            })
        XCTAssertEqual(animationCalls, 1)
        XCTAssertTrue(failure?.contains("Previous positions restored") == true)
        XCTAssertEqual(states["a"]?.0, a.frame); XCTAssertEqual(states["b"]?.0, b.frame)
        XCTAssertEqual(states["a"]?.1, false); XCTAssertEqual(states["b"]?.1, false)
    }
    @MainActor func testArrangeCardFitsAndReleasesWithoutStartingManagement() {
        _ = NSApplication.shared
        let manager = WindowArrangementService.shared
        XCTAssertFalse(manager.enabled, "test home starts with optional management off")
        weak var released: WindowArrangementView?
        autoreleasepool {
            let view = WindowArrangementView(); released = view
            view.frame = CGRect(x: 0, y: 0, width: 880, height: 640); view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.cardWidth, Isle.lensWidth)
            for child in view.subviews { XCTAssertTrue(view.bounds.contains(child.frame), "\(type(of: child)) must fit") }
            let tabs = view.subviews.compactMap { $0 as? PillTabs }.first!
            let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
            tabs.onSelect?(1); view.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
            tabs.onSelect?(2); view.layoutSubtreeIfNeeded()
            XCTAssertEqual(scroll.contentView.bounds.minY, 0, "switching from a scrolled workspace list must show the new page's introduction")
        }
        XCTAssertNil(released)
        XCTAssertFalse(manager.enabled)
    }
    func testVisualTransitionPreferenceIsOptionalForExistingSettings() throws {
        let encoded = try JSONEncoder().encode(ArrangeSettings())
        let legacy = try JSONDecoder().decode(ArrangeSettings.self, from: encoded)
        XCTAssertNil(legacy.visualTransitions)
        var optedIn = legacy; optedIn.visualTransitions = true
        XCTAssertEqual(try JSONDecoder().decode(ArrangeSettings.self, from: JSONEncoder().encode(optedIn)).visualTransitions, true)
    }
    @MainActor func testArrangeSettingsLabelsDoNotCoverInteractiveControls() throws {
        _ = NSApplication.shared
        let manager = WindowArrangementService.shared
        let original = manager.settings.visualTransitions == true
        let saved = UserDefaults.standard.object(forKey: ArrangeSettings.key)
        defer {
            manager.setVisualTransitions(original)
            UserDefaults.standard.set(saved, forKey: ArrangeSettings.key)
        }
        for width: CGFloat in [720, 880] {
            let host = FlippedView(frame: CGRect(x: 0, y: 0, width: width, height: 640))
            let view = WindowArrangementView()
            view.frame = host.bounds
            host.addSubview(view)
            view.layoutSubtreeIfNeeded()
            let tabs = try XCTUnwrap(view.subviews.compactMap { $0 as? PillTabs }.first)
            let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
            for page in [0, 1] {
                tabs.onSelect?(page); view.layoutSubtreeIfNeeded()
                let body = try XCTUnwrap(scroll.documentView)
                let toggle = try XCTUnwrap(body.subviews.compactMap { $0 as? Toggle }.first)
                toggle.scrollToVisible(toggle.bounds)
                let point = view.convert(CGPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), from: toggle)
                XCTAssertTrue(view.hitTest(point) === toggle, "page \(page), width \(width): hit=\(String(describing: view.hitTest(point))) point=\(point) toggle=\(toggle.frame) clip=\(scroll.contentView.bounds) root=\(view.bounds)")
                if page == 0 {
                    let next = !toggle.isOn
                    XCTAssertTrue(toggle.accessibilityPerformPress())
                    XCTAssertEqual(manager.settings.visualTransitions, next)
                    XCTAssertEqual(ArrangeSettings.load().visualTransitions, next)
                } else {
                    let limit = try XCTUnwrap(body.subviews.compactMap { $0 as? ZeraSelect }.last)
                    limit.scrollToVisible(limit.bounds)
                    let point = view.convert(CGPoint(x: limit.bounds.midX, y: limit.bounds.midY), from: limit)
                    XCTAssertTrue(view.hitTest(point) === limit, "menu hit=\(String(describing: view.hitTest(point))) point=\(point) frame=\(limit.frame) clip=\(scroll.contentView.bounds)")
                }
            }
            XCTAssertTrue(view.superview === host)
        }
    }
    @MainActor func testVisualSurfaceReleasesAfterCancelAndCanFinishAfterCancellation() {
        _ = NSApplication.shared
        weak var released: ArrangeVisualTransition?
        var finishes = 0, closes = 0
        autoreleasepool {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let image = bitmap.cgImage!
            let scene = ArrangeVisualTransition(display: CGRect(x: -700, y: 0, width: 700, height: 430), background: image,
                tiles: [.init(id: "sample", frame: CGRect(x: -680, y: 60, width: 300, height: 300), image: image)], preview: true)
            released = scene; scene.onClose = { closes += 1 }
            scene.cancel(); scene.cancel()
            scene.animate(to: [:]) { finishes += 1 }
        }
        XCTAssertEqual(closes, 1); XCTAssertEqual(finishes, 1)
        XCTAssertNil(released, "temporary image layers and the surface must release after cancellation")
    }
    @MainActor func testVisualSurfaceHasTransparentHandoffAndNoInitialGeometryAnimation() throws {
        _ = NSApplication.shared
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        let area = CGRect(x: 0, y: 0, width: 700, height: 430)
        let scene = ArrangeVisualTransition(display: area, background: nil, tiles: [])
        defer { scene.cancel() }
        let panel = try XCTUnwrap(NSApp.windows.first { !previous.contains(ObjectIdentifier($0)) })
        XCTAssertFalse(panel.isOpaque, "Fading the scene must reveal real windows, never opaque black")
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertEqual(panel.animationBehavior, .none)
        let root = try XCTUnwrap(panel.contentView?.layer)
        XCTAssertEqual(root.frame, CGRect(origin: .zero, size: area.size))
        XCTAssertTrue(root.actions?["bounds"] is NSNull)
        XCTAssertTrue(root.actions?["position"] is NSNull)
        XCTAssertTrue(root.animationKeys()?.isEmpty ?? true, "Source scene must not zoom in from a zero frame")
    }
    @MainActor func testCaptureConfigurationSurvivesCopyingAfterAutoreleasePoolDrains() throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("image transitions require macOS 14") }
        var config = autoreleasepool { ArrangeVisualTransition.captureConfiguration(size: CGSize(width: 3000, height: 1800)) }
        for _ in 0..<25 {
            config = try autoreleasepool { try XCTUnwrap(config.copy() as? SCStreamConfiguration) }
            XCTAssertEqual(config.width, 1280); XCTAssertEqual(config.height, 768)
            XCTAssertFalse(config.showsCursor); XCTAssertFalse(config.capturesAudio)
        }
    }
}
