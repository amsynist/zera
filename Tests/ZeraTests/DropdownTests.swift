import AppKit
import XCTest
@testable import Zera

@MainActor
final class DropdownTests: XCTestCase {
    func testNativeMenuRetainsActionsAndCheckedState() {
        var picked = 0
        let menu = ZeraDropdown.nativeMenu(for: [
            DropdownItem(title: "First", checked: true) { picked = 1 },
            .separator(),
            DropdownItem(title: "Second", subtitle: "Details", symbol: "gearshape") { picked = 2 }
        ])
        XCTAssertEqual(menu.items[0].state, .on)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].toolTip, "Details")
        XCTAssertNotNil(menu.items[2].image)
        menu.performActionForItem(at: 2)
        XCTAssertEqual(picked, 2)
    }

    func testCustomMenuKeyboardSkipsSeparatorsAndReleasesRows() throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: "appearance.dropdownStyle")
        defer { UserDefaults.standard.set(saved, forKey: "appearance.dropdownStyle") }
        DropdownStyle.current = .zera
        weak var releasedContent: NSView?
        try autoreleasepool {
            let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            let anchor = ZeraSelect(["First", "Second"])
            anchor.frame = NSRect(x: 20, y: 40, width: 180, height: Metrics.button)
            host.contentView?.addSubview(anchor)
            host.orderFront(nil)
            defer { host.orderOut(nil) }
            let dropdown = ZeraDropdown()
            defer { dropdown.dismiss() }
            var picked = 0
            dropdown.show([DropdownItem(title: "First", checked: true) { picked = 1 }, .separator(),
                           DropdownItem(title: "Second") { picked = 2 }], below: anchor)
            var panel: FloatingPanel? = try XCTUnwrap(dropdown.window)
            releasedContent = panel?.contentView
            func key(_ code: UInt16) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: panel?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            }
            panel?.sendEvent(try key(125))
            panel?.sendEvent(try key(36))
            XCTAssertEqual(picked, 2)
            XCTAssertFalse(dropdown.isOpen)
            panel = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            dropdown.show([DropdownItem(title: "First") { picked = 3 }], below: anchor)
            panel = dropdown.window
            panel?.sendEvent(try key(53))
            XCTAssertFalse(dropdown.isOpen)
            XCTAssertEqual(picked, 2, "Escape cancels without invoking a choice")
        }
        XCTAssertNil(releasedContent, "closed menus must release their row and hover closures after AppKit drains its autorelease pool")
    }
}
