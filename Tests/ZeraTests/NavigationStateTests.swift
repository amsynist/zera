import AppKit
import XCTest
@testable import Zera

final class NavigationStateTests: XCTestCase {
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
