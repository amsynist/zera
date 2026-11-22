import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Zera

/// Drives the shelf with real key events in an offscreen window, on a disposable store.
@MainActor
final class DailyShelfKeyboardTests: XCTestCase {
    private var savedSettings: DailyShelfSettings!
    private var savedFetchEnabled = true
    private var folder: URL!
    private var saved: DailyShelfStore!
    private var window: FloatingPanel!
    private var content: DailyShelfContentView!

    override func setUp() {
        super.setUp()
        savedSettings = DailyShelfSettings.current
        DailyShelfSettings.current = DailyShelfSettings()
        savedFetchEnabled = DailyShelfFavicons.shared.fetchEnabled
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("zera-shelf-keys-\(UUID().uuidString)")
        saved = DailyShelfStore.shared
        DailyShelfStore.shared = DailyShelfStore(folder: folder, settings: { DailyShelfSettings() })
        DailyShelfFavicons.shared.fetchEnabled = false
        let st = DailyShelfStore.shared
        for (u, c) in [("https://vercel.com/a", "Dev tools"), ("https://sentry.io/b", "Reading")] {
            let it = st.add(link: URL(string: u)!, title: nil).item
            st.update(it.id) { $0.sorting = false; $0.category = c; $0.layout = "row" }
        }
        _ = st.add(link: URL(string: "https://github.com/a/b/pull/1")!, title: "Fix it")
        window = FloatingPanel.make(size: NSSize(width: 360, height: 700), level: .normal, keyable: true)
        content = DailyShelfContentView(frame: NSRect(x: 0, y: 0, width: 360, height: 700))
        window.contentView = content
        content.reload()
        content.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        DailyShelfSettings.current = savedSettings
        DailyShelfFavicons.shared.fetchEnabled = savedFetchEnabled
        window.orderOut(nil)
        DailyShelfStore.shared = saved
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func press(_ code: Int, _ chars: String = "", mods: NSEvent.ModifierFlags = []) -> Bool {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: window.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
        return content.handleKey(e)
    }
    private func selected() -> DailyShelfItem? { DailyShelfStore.shared.items.first { $0.id == content.selectedID } }

    private var cursor: DailyShelfContentView.NavStop? { content.cursor }

    func testAllFourArrowsNavigateOnlyTheThreeItems() {
        XCTAssertTrue(press(kVK_DownArrow))
        XCTAssertEqual(selected()?.kind, .pr, "The first stop is the PR, not its title")
        let pr = content.selectedID
        XCTAssertTrue(press(kVK_RightArrow))
        XCTAssertEqual(selected()?.kind, .site)
        let firstSite = content.selectedID
        XCTAssertTrue(press(kVK_DownArrow))
        XCTAssertEqual(selected()?.kind, .site)
        XCTAssertNotEqual(content.selectedID, firstSite)
        XCTAssertTrue(press(kVK_LeftArrow))
        XCTAssertEqual(content.selectedID, firstSite)
        XCTAssertTrue(press(kVK_UpArrow))
        XCTAssertEqual(content.selectedID, pr)
        XCTAssertTrue(DailyShelfSettings.current.collapsed.isEmpty, "Arrows never fold a section")
        XCTAssertTrue(press(kVK_UpArrow))
        XCTAssertNil(cursor, "Up from the first item returns to the add field")
    }

    func testArrowsFollowCustomSectionOrder() {
        DailyShelfSettings.update { $0.sectionOrder = ["site", "pr"] }
        content.reload()
        _ = press(kVK_RightArrow)
        XCTAssertEqual(selected()?.kind, .site)
        let first = content.selectedID
        _ = press(kVK_RightArrow)
        XCTAssertEqual(selected()?.kind, .site)
        XCTAssertNotEqual(content.selectedID, first)
        _ = press(kVK_RightArrow)
        XCTAssertEqual(selected()?.kind, .pr)
    }

    func testSitesHaveNoCategoryHeadersOrIndependentCategoryFolds() {
        // Previously saved category folds must not hide links in the flat Sites list.
        DailyShelfSettings.update { $0.filter = "site"; $0.collapsed = ["category:Dev tools", "category:Reading"] }
        content.reload()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let headers = descendants(content).compactMap { $0 as? DailyShelfHeaderView }
        XCTAssertEqual(headers.map(\.title), ["Sites"])
        _ = press(kVK_DownArrow)
        let first = content.selectedID
        XCTAssertNotNil(first)
        _ = press(kVK_RightArrow)
        XCTAssertNotNil(content.selectedID)
        XCTAssertNotEqual(content.selectedID, first)
    }

    func testTabCyclesFiltersAndShiftTabTogglesTheCurrentSection() {
        _ = press(kVK_DownArrow)
        var seen: [String] = []
        for _ in 0..<3 { XCTAssertTrue(press(kVK_Tab, "\t")); seen.append(DailyShelfSettings.current.filter) }
        XCTAssertEqual(seen, ["pr", "site", "all"])
        XCTAssertEqual(selected()?.kind, .pr)
        let id = content.selectedID
        XCTAssertTrue(press(kVK_Tab, "\t", mods: .shift))
        XCTAssertEqual(DailyShelfSettings.current.filter, "all", "Shift-Tab does not switch tabs")
        XCTAssertTrue(DailyShelfSettings.current.collapsed.contains("pr"))
        XCTAssertEqual(content.selectedID, id, "The item anchors the fold without selecting a title")
        XCTAssertTrue(press(kVK_Tab, "\t", mods: .shift))
        XCTAssertFalse(DailyShelfSettings.current.collapsed.contains("pr"))
        XCTAssertEqual(content.selectedID, id)
    }

    func testFoldedSectionsAreSkippedAndCanBeReopened() {
        _ = press(kVK_DownArrow)
        let pr = content.selectedID
        _ = press(kVK_RightArrow)
        let site = content.selectedID
        _ = press(kVK_Tab, "\t", mods: .shift)
        XCTAssertTrue(DailyShelfSettings.current.collapsed.contains("site"))
        _ = press(kVK_LeftArrow)
        XCTAssertEqual(content.selectedID, pr, "Left skips the collapsed sites")
        _ = press(kVK_Tab, "\t", mods: .shift)
        XCTAssertTrue(DailyShelfSettings.current.collapsed.contains("pr"))
        _ = press(kVK_Tab, "\t", mods: .shift)
        XCTAssertFalse(DailyShelfSettings.current.collapsed.contains("pr"))
        XCTAssertTrue(DailyShelfSettings.current.collapsed.contains("site"))
        // Switching to an entirely collapsed filter still lets Shift-Tab reopen it.
        _ = press(kVK_Tab, "\t")
        _ = press(kVK_Tab, "\t")
        XCTAssertEqual(DailyShelfSettings.current.filter, "site")
        _ = press(kVK_Tab, "\t", mods: .shift)
        XCTAssertFalse(DailyShelfSettings.current.collapsed.contains("site"))
        XCTAssertEqual(content.selectedID, site)
    }

    func testSpaceStillFoldsAndPinKeepsItemSelection() {
        _ = press(kVK_DownArrow)
        let id = content.selectedID
        XCTAssertTrue(press(kVK_ANSI_P, "p"))
        content.reload()
        XCTAssertEqual(selected()?.pinned, true)
        XCTAssertEqual(content.selectedID, id)
        XCTAssertTrue(press(kVK_Space, " "))
        XCTAssertTrue(DailyShelfSettings.current.collapsed.contains("pr"))
        XCTAssertTrue(press(kVK_Space, " "))
        XCTAssertFalse(DailyShelfSettings.current.collapsed.contains("pr"))
        XCTAssertEqual(content.selectedID, id)
    }

    func testClearKeepsPinsAndUndoPutsEverythingBack() {
        DailyShelfStore.shared.addNote("deploy at 4")
        let before = DailyShelfStore.shared.items.map(\.id)
        let note = DailyShelfStore.shared.items.first { $0.kind == .note }!
        DailyShelfStore.shared.togglePin(note.id)
        XCTAssertTrue(press(kVK_Delete, "\u{8}", mods: .command))
        XCTAssertEqual(DailyShelfStore.shared.items.map(\.id), [note.id], "Only the pinned note stays")
        XCTAssertTrue(press(kVK_ANSI_Z, "z", mods: .command))
        XCTAssertEqual(DailyShelfStore.shared.items.map(\.id), before, "Undo restores the old order")
        XCTAssertFalse(press(kVK_ANSI_Z, "z", mods: .command), "Nothing left to undo")
    }

    func testSiteAndPRContextMenusOfferRename() throws {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let views = descendants(content)
        for kind in [DailyShelfKind.site, .pr] {
            let item = try XCTUnwrap(DailyShelfStore.shared.items.first { $0.kind == kind })
            let row = views.compactMap { $0 as? DailyShelfRowView }.first { $0.itemID == item.id }
            let menu = try XCTUnwrap(row?.contextMenu?())
            let index = menu.items.firstIndex { $0.title == "Rename\u{2026}" }
            XCTAssertNotNil(index)
            if let index { menu.performActionForItem(at: index) }
            XCTAssertEqual(content.renameField?.stringValue, item.title)
            content.closeSheet()
        }
    }

    func testAccentMenuAppliesToSiteTilesAndPRCards() throws {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        for kind in [DailyShelfKind.site, .pr] {
            let item = try XCTUnwrap(DailyShelfStore.shared.items.first { $0.kind == kind })
            if kind == .site { DailyShelfStore.shared.update(item.id) { $0.layout = "tile" } }
            content.reload()
            let views = descendants(content)
            let row = views.compactMap { $0 as? DailyShelfRowView }.first { $0.itemID == item.id }
            let tile = views.compactMap { $0 as? DailyShelfTileView }.first { $0.itemID == item.id }
            let menu = try XCTUnwrap(row?.contextMenu?() ?? tile?.contextMenu?())
            let accents = try XCTUnwrap(menu.items.first { $0.title == "Accent color" }?.submenu)
            XCTAssertEqual(accents.items.filter { $0.image != nil && $0.title != "Default" }.count, 16)
            let ocean = try XCTUnwrap(accents.items.firstIndex { $0.title == "Ocean" })
            accents.performActionForItem(at: ocean)
            XCTAssertEqual(DailyShelfStore.shared.items.first { $0.id == item.id }?.accent, .ocean)
            content.reload()
            let updated = descendants(content)
            if kind == .site {
                XCTAssertEqual(updated.compactMap { $0 as? DailyShelfTileView }.first { $0.itemID == item.id }?.accent, .ocean)
            } else {
                XCTAssertEqual(updated.compactMap { $0 as? DailyShelfRowView }.first { $0.itemID == item.id }?.accent, .ocean)
            }
            accents.performActionForItem(at: 0)
            XCTAssertNil(DailyShelfStore.shared.items.first { $0.id == item.id }?.accent)
        }
    }

    func testRenameEditorSavesAndDoesNotHandleShelfNavigationKeys() {
        let pr = DailyShelfStore.shared.items.first { $0.kind == .pr }!
        content.showRename(pr)
        XCTAssertEqual(content.renameField?.stringValue, pr.title)
        XCTAssertFalse(press(kVK_Tab, "\t"), "Tab belongs to the title editor while it is open")
        XCTAssertFalse(press(kVK_LeftArrow))
        content.renameField?.stringValue = " "
        content.saveRename()
        XCTAssertFalse(content.sheet.isHidden, "An empty name leaves the editor open")
        content.renameField?.stringValue = "My PR title"
        content.saveRename()
        XCTAssertEqual(DailyShelfStore.shared.items.first { $0.id == pr.id }?.title, "My PR title")
        XCTAssertNil(content.renameField)
    }

    func testCancellingRenameLeavesTheTitleAlone() {
        let site = DailyShelfStore.shared.items.first { $0.kind == .site }!
        content.showRename(site)
        content.renameField?.stringValue = "Unsaved name"
        content.closeSheet()
        XCTAssertEqual(DailyShelfStore.shared.items.first { $0.id == site.id }?.title, site.title)
    }

    func testRemoveMovesToTheNextItem() {
        _ = press(kVK_DownArrow)
        let first = content.selectedID
        XCTAssertNotNil(first)
        XCTAssertTrue(press(kVK_Delete))
        XCTAssertNil(DailyShelfStore.shared.items.first { $0.id == first })
        XCTAssertNotNil(content.selectedID)
        XCTAssertNotEqual(content.selectedID, first)
    }
}
