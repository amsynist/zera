import AppKit
import XCTest
@testable import Zera

final class SettingsLayoutTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testEveryPaneUsesSharedSelectsWithinItsRows() {
        let settings = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        settings.setFrameSize(NSSize(width: settings.cardWidth, height: Isle.maxContentHeight))
        for pane in SettingsCard.Pane.allCases {
            settings.select(pane)
            settings.layoutSubtreeIfNeeded()
            XCTAssertTrue(descendants(settings).compactMap { $0 as? NSPopUpButton }.isEmpty)
            for control in descendants(settings).compactMap({ $0 as? ZeraSelect }) {
                guard let row = control.superview else { XCTFail("missing row"); continue }
                XCTAssertLessThanOrEqual(control.frame.maxX, row.bounds.width, "\(pane): \(control.selectedTitle)")
                XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
                XCTAssertEqual(control.frame.height, Metrics.button)
                let labels = row.subviews.compactMap { $0 as? NSTextField }
                XCTAssertTrue(labels.allSatisfy { $0.frame.maxX + Space.m <= control.frame.minX + 0.5 }, "label and control overlap in \(pane)")
            }
        }
    }

    @MainActor
    func testSharedSelectDispatchesSettingsAndPersistsMenuChoice() throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: "appearance.dropdownStyle")
        defer { UserDefaults.standard.set(saved, forKey: "appearance.dropdownStyle") }
        let settings = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        var picked: CardKind?
        settings.onDefaultChanged = { picked = $0 }
        let defaultChoice = try XCTUnwrap(descendants(settings).compactMap { $0 as? ZeraSelect }
            .first { $0.accessibilityLabel() == "Tap on Zera opens" })
        defaultChoice.select(1)
        defaultChoice.onChange?(1)
        XCTAssertEqual(picked, .home)
        settings.select(.appearance)
        let menuChoice = try XCTUnwrap(descendants(settings).compactMap { $0 as? ZeraSelect }
            .first { $0.accessibilityLabel() == "Menu appearance" })
        menuChoice.select(DropdownStyle.native.rawValue)
        menuChoice.onChange?(DropdownStyle.native.rawValue)
        XCTAssertEqual(DropdownStyle.current, .native)
    }
    /// Every pane fits in the island; taller content scrolls inside it instead of being cut off.
    func testEveryPaneFitsTheIsland() {
        let s = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        s.setFrameSize(NSSize(width: 560, height: 400))
        for pane in SettingsCard.Pane.allCases {
            s.select(pane)
            XCTAssertLessThanOrEqual(s.desiredHeight, Isle.maxContentHeight, "\(pane)")
        }
    }
}
