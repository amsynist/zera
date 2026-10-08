import AppKit
import XCTest
@testable import Zera

/// The final pass, kept as a test: every island screen lays out inside its own bounds, uses the
/// shared control sizes, and starts its header where the others do.
final class ScreenLayoutTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    /// Visible views that can't scroll: anything inside a scroll view's document may be taller
    /// (or, for previews, wider) than the screen by design.
    private func fixedVisible(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { v -> [NSView] in
            guard !v.isHidden, v.alphaValue > 0.01 else { return [] }
            if v is NSScrollView || v is NSClipView { return [v] }
            return [v] + fixedVisible(v)
        }
    }

    private func screens() -> [(String, NSView & CardContent)] {
        let store = TaskStore(url: nil)
        store.add("Write the launch post 30m")
        store.add("Plan next sprint")
        return [
            ("Home", HomeCard()),
            ("Claude", ClaudeSessionsView()),
            ("Shelf", DropFilesView()),
            ("Clipboard", ClipboardView()),
            ("Tasks", TasksCard(store: store)),
            ("Pull requests", GitHubCard()),
            ("Reminders", RemindersView()),
            ("Settings", SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false))
        ]
    }

    private func laidOut(_ screen: NSView & CardContent) {
        screen.frame = NSRect(x: 0, y: 0, width: screen.cardWidth, height: min(screen.desiredHeight, Isle.maxContentHeight))
        screen.needsLayout = true
        screen.layoutSubtreeIfNeeded()
    }

    func testEveryScreenStaysInsideItsBounds() {
        for (name, screen) in screens() {
            laidOut(screen)
            let bounds = screen.bounds
            for v in fixedVisible(screen) where v.frame.width > 0 && v.frame.height > 0 {
                guard v is NSControl || v is NSTextField || v is GitHubSegmentedControl || v is PillTabs || v is ChoiceChips
                        || v is ShelfFileRow || v is ListRow else { continue }
                let f = screen.convert(v.bounds, from: v)
                XCTAssertGreaterThanOrEqual(f.minX, bounds.minX - 1, "\(name): \(type(of: v)) starts left of the screen")
                XCTAssertLessThanOrEqual(f.maxX, bounds.maxX + 1, "\(name): \(type(of: v)) runs past the right edge")
            }
        }
    }

    func testEverySegmentedControlIsTheSharedHeight() {
        for (name, screen) in screens() {
            laidOut(screen)
            for seg in descendants(screen).compactMap({ $0 as? GitHubSegmentedControl }) where !seg.isHidden && seg.frame.height > 0 {
                XCTAssertEqual(seg.frame.height, Metrics.segment, accuracy: 0.5, "\(name): segmented control")
            }
        }
    }

    func testEveryCardHeaderStartsAtTheSamePlace() {
        for (name, screen) in screens() {
            guard let card = screen as? CardBase else { continue }
            laidOut(screen)
            XCTAssertEqual(card.titleLabel.frame.minX, Metrics.sidePad, accuracy: 0.5, "\(name): header title x")
        }
    }

    func testRowTiersAreTheSharedSizes() {
        XCTAssertEqual(RowTier.compact.height, 46)
        XCTAssertEqual(RowTier.standard.height, 58)
        XCTAssertEqual(RowTier.rich.height, 70)
        XCTAssertEqual(ShelfFileRow.height(.dropped), RowTier.standard.height)
        XCTAssertEqual(AgendaRow.height, RowTier.rich.height)
    }
}
