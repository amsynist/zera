import AppKit
import XCTest
@testable import Zera

@MainActor
final class ClaudeUsagePresentationTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testUsageBadgeHasActualReadingsWithoutShiftingFilters() throws {
        let usage = ClaudeUsageService.shared
        let was = usage.showInSessions
        usage.showInSessions = true
        usage.preview(ClaudeUsage(fiveHour: .init(used: 0.23, resetsAt: Date().addingTimeInterval(3600)), week: .init(used: 0.91, resetsAt: Date().addingTimeInterval(86400)), readAt: Date()))
        defer { usage.preview(nil); usage.showInSessions = was }
        let view = ClaudeSessionsView()
        view.frame = NSRect(x: 0, y: 0, width: view.cardWidth, height: view.desiredHeight)
        view.layoutSubtreeIfNeeded()
        let badge = try XCTUnwrap(descendants(view).compactMap { $0 as? PRStatusChip }.first { $0.accessibilityLabel()?.hasPrefix("Usage ·") == true })
        XCTAssertFalse(badge.isHidden)
        XCTAssertEqual(badge.accessibilityLabel(), "Usage · 5h 23% · week 91%")
        let filters = try XCTUnwrap(badge.superview?.subviews.compactMap { $0 as? GitHubSegmentedControl }.first)
        XCTAssertLessThanOrEqual(badge.frame.maxY + Space.s, filters.frame.minY + 0.5)
        XCTAssertEqual(filters.frame.minY, Isle.headerHeight + (Metrics.field - Metrics.segment) / 2)
        XCTAssertEqual(badge.frame.minY, ScreenHeader.subtitleTop)
        let before = filters.frame
        usage.showInSessions = false
        view.reload()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(filters.frame, before, "Usage must not consume session-list space")
        usage.showInSessions = true
        view.reload()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        capture(view, name: "sessions-usage")
        capture(ClaudeUsageStrip(frame: NSRect(x: 0, y: 0, width: 760, height: ClaudeUsageStrip.height)), name: "home-usage")
        capture(ClaudeUsageStrip(frame: NSRect(x: 0, y: 0, width: 380, height: ClaudeUsageStrip.height)), name: "home-usage-compact")
        usage.preview(nil)
        capture(ClaudeUsageStrip(frame: NSRect(x: 0, y: 0, width: 380, height: ClaudeUsageStrip.height)), name: "home-usage-empty")
    }

    func testBranchNameIsNotShownAndFourSessionsFit() throws {
        let svc = ClaudeActivityService.shared
        let ids = (0..<4).map { "usage-layout-\(UUID().uuidString)-\($0)" }
        defer { ids.compactMap { svc.sessions[$0] }.forEach(svc.remove) }
        for (i, id) in ids.enumerated() {
            svc.apply(["session_id": id, "cwd": "/tmp/zera", "hook_event_name": "UserPromptSubmit", "prompt": "Review feature \(i + 1)"])
            svc.sessions[id]?.branch = "claude_usage"
        }
        let view = ClaudeSessionsView()
        view.frame = NSRect(x: 0, y: 0, width: view.cardWidth, height: min(view.desiredHeight, Isle.maxContentHeight))
        view.layoutSubtreeIfNeeded()
        let rows = descendants(view).compactMap { $0 as? ClaudeSessionRow }.filter { ids.contains($0.sessionID) }
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            XCTAssertFalse(descendants(row).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("claude_usage") })
            let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first { $0.documentView === row.superview })
            XCTAssertLessThanOrEqual(row.frame.maxY, scroll.frame.height + 1, "The four-row session list must fit its viewport")
        }
        capture(view, name: "sessions-populated")
    }

    func testAgentRowCanBeActivatedByAccessibilityAndKeyboard() {
        let row = SessionInfoRow(symbol: "person.fill", tint: Pal.accent, title: "Review UI", subtitle: "Explore · running", trailing: "2 tools")
        var presses = 0
        row.onTap = { presses += 1 }
        XCTAssertEqual(row.accessibilityRole(), .button)
        XCTAssertEqual(row.accessibilityLabel(), "Review UI")
        XCTAssertTrue(row.acceptsFirstResponder)
        XCTAssertTrue(row.accessibilityPerformPress())
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        row.keyDown(with: event)
        XCTAssertEqual(presses, 2)
    }

    private func capture(_ view: NSView, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["ZERA_USAGE_REVIEW"] else { return }
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = NSColor(srgbRed: 0.065, green: 0.06, blue: 0.095, alpha: 1)
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), .bestResolution) {
            let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            try? data?.write(to: url.appendingPathComponent(name + ".png"))
        }
        window.orderOut(nil)
    }
}
