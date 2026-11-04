import AppKit
import XCTest
@testable import Zera

@MainActor
final class OpenerLifecycleTests: XCTestCase {
    func testHoveredLaneCanDisappearWhileFiltering() throws {
        _ = NSApplication.shared
        let lanes = OpenerLanes(frame: NSRect(x: 0, y: 0, width: 720, height: 40))
        let window = NSWindow(contentRect: lanes.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = lanes
        defer { window.contentView = nil }
        let choices = [OpenerLanes.Lane(title: "Apps", count: 7), .init(title: "Commands", count: 4), .init(title: "Actions", count: 8)]
        lanes.lanes = choices
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
            location: NSPoint(x: lanes.fittedWidth - 10, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        lanes.mouseMoved(with: event)
        // Filtering can remove the lane without a mouse-exited event.
        lanes.lanes = [choices[0]]
        try draw(lanes)
        lanes.lanes = []
        try draw(lanes)
        for _ in 0..<100 {
            lanes.lanes = choices
            lanes.selected = 2
            lanes.mouseMoved(with: event)
            lanes.lanes = [choices[0]]
            XCTAssertEqual(lanes.selected, 0)
            lanes.selected = -1
            XCTAssertEqual(lanes.selected, 0)
            try draw(lanes)
            lanes.lanes = []
            lanes.selected = Int.max
            XCTAssertEqual(lanes.selected, 0)
            try draw(lanes)
        }
    }

    private func draw(_ view: NSView) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    func testScreensReleaseAfterDetachingFromWindow() {
        _ = NSApplication.shared
        let store = TaskStore(url: nil)
        let factories: [(String, () -> NSView)] = [
            ("Home", { HomeCard() }), ("Agents", { AgentsView(snapshot: { [] }) }),
            ("Claude", { ClaudeSessionsView() }), ("Codex detail", { ObservedAgentView(snapshot: { nil }) }),
            ("Shelf", { DropFilesView() }), ("Clipboard", { ClipboardView() }),
            ("Tasks", { TasksCard(store: store) }), ("Reminders", { RemindersView() }),
            ("Settings", { SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false) }),
            ("Launcher", { AppOpenerView() }), ("Classic launcher", { TreeOpenerView() }),
            ("Companion", { LivingCompanionView() }), ("Wings", { LiveActivityView() })
        ]
        for (name, make) in factories {
            weak var released: NSView?
            autoreleasepool {
                let view = make()
                view.frame = NSRect(x: 0, y: 0, width: 880, height: 600)
                released = view
                let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                window.contentView = nil
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertNil(released, "\(name) must not be retained by a timer, observer, or callback")
        }
    }
}
