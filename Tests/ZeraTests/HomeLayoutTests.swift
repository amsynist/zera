import AppKit
import XCTest
@testable import Zera

final class HomeLayoutTests: XCTestCase {
    func testApprovalActionsAlignBelowNavigation() {
        let card = ApprovalCard()
        card.frame.size = NSSize(width: card.cardWidth, height: card.desiredHeight)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.cardWidth, Isle.lensWidth)
        let buttons = card.subviews.compactMap { $0 as? CardButton }
        XCTAssertEqual(buttons.count, 2)
        for button in buttons { XCTAssertEqual(button.frame.minY, ScreenHeader.controlY(Metrics.control)) }
        XCTAssertFalse(buttons[0].frame.intersects(buttons[1].frame))
    }
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testQuickActionsRemainReachableAtCompactAndNormalWidths() throws {
        let home = HomeCard()
        for width: CGFloat in [560, Isle.lensWidth] {
            home.setFrameSize(NSSize(width: width, height: Isle.maxContentHeight))
            home.layoutSubtreeIfNeeded()
            let actions = descendants(home).compactMap { $0 as? ActionTile }
            // The grid plus the "More" row (tasks, pull requests, focus, teleprompter, settings).
            XCTAssertEqual(actions.count, QuickAction.grid.count + QuickAction.more.count)
            let scroll = try XCTUnwrap(home.subviews.compactMap { $0 as? NSScrollView }.first)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertLessThanOrEqual(home.desiredHeight, Isle.maxContentHeight)
            for action in actions {
                XCTAssertFalse(action.isHidden)
                XCTAssertGreaterThanOrEqual(action.frame.minX, 0)
                XCTAssertLessThanOrEqual(action.frame.maxX, document.bounds.width)
                XCTAssertLessThanOrEqual(action.frame.maxY, document.bounds.height)
            }
            for pair in zip(actions, actions.dropFirst()) {
                XCTAssertFalse(pair.0.frame.intersects(pair.1.frame))
            }
            for rowY in Set(actions.map { $0.frame.minY }) {
                let row = actions.filter { $0.frame.minY == rowY }
                XCTAssertEqual(row.first!.frame.minX, 0, accuracy: 0.5)
                XCTAssertEqual(row.last!.frame.maxX, document.bounds.width, accuracy: 0.5)
            }
            let search = try XCTUnwrap(home.subviews.compactMap { $0 as? SearchBox }.first)
            XCTAssertEqual(search.frame.minY, home.headerBottom, accuracy: 0.5)
            XCTAssertEqual(search.frame.minX, Metrics.cardPad, accuracy: 0.5)
            XCTAssertEqual(search.frame.maxX, width - Metrics.cardPad, accuracy: 0.5)
            XCTAssertEqual(scroll.frame.minY - search.frame.maxY, Space.l, accuracy: 0.5)
        }
    }

    @MainActor
    func testClaudeUsageSitsUnderTheVitalsAndKeepsQuickActionsInView() throws {
        ClaudeUsageService.shared.preview(ClaudeUsage(fiveHour: .init(used: 0.23, resetsAt: Date().addingTimeInterval(3600)),
                                                      week: .init(used: 0.91, resetsAt: Date().addingTimeInterval(86_400)), readAt: Date()))
        defer { ClaudeUsageService.shared.preview(nil) }
        let home = HomeCard()
        home.setFrameSize(NSSize(width: home.cardWidth, height: Isle.maxContentHeight))
        home.refresh()
        home.layoutSubtreeIfNeeded()
        let strip = try XCTUnwrap(descendants(home).compactMap { $0 as? ClaudeUsageStrip }.first)
        let vitals = try XCTUnwrap(descendants(home).compactMap { $0 as? VitalsOrgans }.first)
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(strip.frame.minY - vitals.frame.maxY, Space.m, accuracy: 0.5)
        let scroll = try XCTUnwrap(home.subviews.compactMap { $0 as? NSScrollView }.first)
        // The primary quick actions stay visible; the separate More row remains in the scroll document.
        if descendants(home).filter({ $0 is ListRow && !$0.isHidden }).count <= 1 {
            let names = Set(QuickAction.grid.map(\.tileTitle))
            let primary = descendants(home).compactMap { $0 as? ActionTile }.filter { names.contains($0.accessibilityLabel() ?? "") }
            XCTAssertEqual(primary.count, QuickAction.grid.count)
            for action in primary {
                XCTAssertLessThanOrEqual(action.frame.maxY, scroll.contentView.bounds.height + 0.5)
            }
        }
    }

    func testThisMacAndBackRestoreHomeContent() throws {
        let home = HomeCard()
        home.setFrameSize(NSSize(width: home.cardWidth, height: Isle.maxContentHeight))
        home.setVitals(true, animated: false)
        home.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(home.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertTrue(scroll.isHidden)
        let vitals = try XCTUnwrap(home.subviews.compactMap { $0 as? VitalsPage }.first)
        XCTAssertFalse(vitals.isHidden)
        XCTAssertLessThanOrEqual(vitals.frame.maxY, home.desiredHeight)
        home.setVitals(false, animated: false)
        home.layoutSubtreeIfNeeded()
        XCTAssertFalse(scroll.isHidden)
        XCTAssertTrue(vitals.isHidden)
        XCTAssertTrue(descendants(home).compactMap { $0 as? ActionTile }.allSatisfy { !$0.isHidden })
    }
}
