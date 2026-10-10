import AppKit
import XCTest
@testable import Zera

final class NavigationStateTests: XCTestCase {
    @MainActor
    func testRapidScreenSwitchesCleanUpOutgoingViewsAndKeepTheCurrentOne() {
        _ = NSApplication.shared
        let island = IslandView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))
        let window = NSWindow(contentRect: island.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = island
        let a = NSView(), b = NSView(), c = NSView()
        let size = NSSize(width: 880, height: 400)
        island.present(a, size: size, direction: 0, animated: false)
        let host = a.superview
        for _ in 0..<10 {
            island.present(b, size: size, direction: 1, animated: true)
            island.present(a, size: size, direction: -1, animated: true)
            island.present(c, size: size, direction: 1, animated: true)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(island.content === c)
        XCTAssertEqual(host?.subviews.count, 1)
        XCTAssertNil(a.superview)
        XCTAssertNil(b.superview)
        XCTAssertEqual(c.layer?.opacity, 1)
        island.close(animated: false)
        XCTAssertNil(c.superview, "an immediate close must not leave a fading view attached")
        XCTAssertTrue(host?.subviews.isEmpty == true)
        window.contentView = nil
    }

    @MainActor
    func testHoverStylesKeepEveryDestinationAndClearSpaceForZera() throws {
        _ = NSApplication.shared
        for style in HoverMenuStyle.allCases {
            for band: CGFloat in [24, 34] {
                let island = IslandView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))
                island.centerX = 450; island.band = band; island.notchWidth = band == 34 ? 190 : 180
                island.hoverStyle = style
                let window = NSWindow(contentRect: island.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = island
                island.peek()
                RunLoop.main.run(until: Date().addingTimeInterval(0.85))
                island.layoutSubtreeIfNeeded()
                let tabs = descendants(island).compactMap { $0 as? IslandTab }
                XCTAssertEqual(tabs.count, 8)
                var activated: [CardKind] = []
                island.onTab = { activated.append($0) }
                let figure = NSRect(x: 418, y: band, width: 64, height: 84)
                for (i, tab) in tabs.enumerated() {
                    XCTAssertTrue(tab.accessibilityPerformPress())
                    XCTAssertFalse(tab.frame.intersects(figure))
                    if style == .tiles { XCTAssertTrue(island.islandRect.contains(tab.frame)) }
                    for other in tabs.dropFirst(i + 1) {
                        let a = style == .tiles ? tab.frame : tab.disc.offsetBy(dx: tab.frame.minX, dy: tab.frame.minY)
                        let b = style == .tiles ? other.frame : other.disc.offsetBy(dx: other.frame.minX, dy: other.frame.minY)
                        XCTAssertFalse(a.intersects(b))
                    }
                }
                XCTAssertEqual(activated, tabs.map(\.kind))
                if style == .tiles {
                    let search = try XCTUnwrap(descendants(island).compactMap { $0 as? IslandClose }.first { $0.expanded })
                    XCTAssertFalse(island.islandContains(NSPoint(x: island.islandRect.minX + 10, y: 4)), "transparent shoulders pass menu-bar clicks through")
                    var searched = false
                    island.onSearch = { searched = true }
                    XCTAssertTrue(search.accessibilityPerformPress())
                    XCTAssertTrue(searched)
                    XCTAssertTrue(island.islandRect.contains(search.frame))
                    XCTAssertGreaterThanOrEqual(search.frame.minY, tabs.map { $0.frame.maxY }.max()! + Space.m)
                }
                island.close(animated: false)
                window.contentView = nil
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testClipboardReturnsToAllWithSearchCleared() throws {
        let view = ClipboardView()
        let filters = try XCTUnwrap(descendants(view).compactMap { $0 as? GitHubSegmentedControl }.first)
        let search = try XCTUnwrap(descendants(view).compactMap { $0 as? SearchBox }.first)
        filters.onSelect?(ClipboardStore.Filter.pinned.rawValue)
        search.field.stringValue = "old search"
        XCTAssertEqual(filters.selected, ClipboardStore.Filter.pinned.rawValue)
        view.willShow()
        XCTAssertEqual(filters.selected, ClipboardStore.Filter.all.rawValue)
        XCTAssertEqual(search.field.stringValue, "")
    }

    func testRemindersReturnToTodayAndAllSourcesButKeepAnUnfinishedForm() throws {
        let view = RemindersView()
        let tabs = try XCTUnwrap(descendants(view).compactMap { $0 as? GitHubSegmentedControl }.first)
        let sources = try XCTUnwrap(descendants(view).compactMap { $0 as? ChoiceChips }.first)
        tabs.onSelect?(2)
        sources.onChange?([AgendaFilter.outlook.rawValue])
        XCTAssertEqual(tabs.selected, 2)
        XCTAssertEqual(sources.selection, [AgendaFilter.outlook.rawValue])
        view.willShow()
        XCTAssertEqual(tabs.selected, 0)
        XCTAssertEqual(sources.selection, [AgendaFilter.all.rawValue])
        let add = try XCTUnwrap(descendants(view).compactMap { $0 as? GHSplitButton }.first)
        add.onMain?()
        let form = try XCTUnwrap(descendants(view).compactMap { $0 as? ReminderFormBase }.first)
        let title = try XCTUnwrap(descendants(form).compactMap { $0 as? ThemedField }.first)
        title.stringValue = "Unfinished meeting"
        view.willShow()
        XCTAssertTrue(descendants(view).contains { $0 === form })
        XCTAssertEqual(title.stringValue, "Unfinished meeting")
    }
}
