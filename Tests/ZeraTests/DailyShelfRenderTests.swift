import AppKit
import XCTest
@testable import Zera

/// Renders the Daily Shelf with fictional sample items so its look can be reviewed without the app:
/// `ZERA_RENDER_SCREENS=/some/folder swift test --filter DailyShelfRenderTests`.
/// Uses a disposable store folder and no network (monogram icons).
@MainActor
final class DailyShelfRenderTests: XCTestCase {
    private var out: URL!
    private var folder: URL!
    private var saved: DailyShelfStore!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["ZERA_RENDER_SCREENS"] else { throw XCTSkip("set ZERA_RENDER_SCREENS to render") }
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("zera-daily-shelf-render-\(UUID().uuidString)")
        saved = DailyShelfStore.shared
        DailyShelfStore.shared = DailyShelfStore(folder: folder, settings: { DailyShelfSettings() })
        DailyShelfFavicons.shared.fetchEnabled = false
    }

    override func tearDown() {
        if let s = saved { DailyShelfStore.shared = s }
        if let f = folder { try? FileManager.default.removeItem(at: f) }
        super.tearDown()
    }

    private func fill() {
        let st = DailyShelfStore.shared
        func pr(_ repo: String, _ n: Int, _ title: String, _ change: (inout DailyShelfPR) -> Void) {
            let it = st.add(link: URL(string: "https://github.com/aurora/\(repo)/pull/\(n)")!, title: title).item
            st.update(it.id) { item in
                var g = item.github!
                g.checkedAt = Date(); g.mine = true; g.additions = 40 + n % 200; g.deletions = n % 50
                change(&g)
                item.github = g
            }
        }
        st.addNote("gh pr checkout 214 && swift test --filter Settings")
        _ = st.add(link: URL(string: "https://developer.apple.com/documentation/appkit/nspanel")!, title: "NSPanel | Apple Developer Documentation")
        for (u, t, c) in [("https://vercel.com/aurora/aurora-web/deployments", "Vercel · deployments", "Dev tools"),
                          ("https://sentry.io/organizations/aurora/issues/", "Sentry · issues", "Dev tools"),
                          ("https://supabase.com/dashboard/project/aurora", "Supabase · aurora", "Dev tools"),
                          ("https://www.figma.com/file/aurora-settings-v3", "Figma · Settings v3", "Design")] {
            let it = st.add(link: URL(string: u)!, title: t).item
            st.update(it.id) { $0.sorting = false; $0.category = c; $0.categorySource = .claude; $0.opens = t.count % 9 }
        }
        if let ref = st.items.first(where: { $0.host == "developer.apple.com" }) {
            st.update(ref.id) { $0.sorting = false; $0.category = "Reference"; $0.categorySource = .claude; $0.opens = 3 }
        }
        _ = st.add(link: URL(string: "https://docs.google.com/document/d/aurora-q4")!, title: "Q4 planning: Aurora")
        _ = st.add(link: URL(string: "https://meet.google.com/abc-defg-hij")!, title: "Design review: settings v3")
        _ = st.add(link: URL(string: "https://aurora.atlassian.net/browse/AUR-142")!, title: "Settings: full keyboard navigation")
        pr("aurora-web", 209, "Fix the flaky upload test") { $0.state = .merged }
        pr("aurora", 412, "Add themes: seven built in, plus your own") { $0.review = .approved; $0.reviewer = "theo"; $0.ci = .passed }
        pr("aurora-web", 220, "Sidebar: keyboard focus ring follows the theme") { $0.ci = .running }
        pr("infra", 88, "Bump the build image to Node 22") { $0.review = .requested; $0.mine = false; $0.author = "dependabot" }
        pr("aurora", 418, "Cache favicons per host on disk") { $0.review = .changesRequested; $0.reviewer = "theo" }
        pr("aurora-web", 214, "Make the settings page work from the keyboard") { $0.ci = .failing; $0.failing = 2 }
        if let pinned = st.items.first(where: { $0.kind == .jira }) { st.togglePin(pinned.id) }
    }

    private func shot(_ placement: DailyShelfPlacement, _ name: String, empty: Bool = false, screenHeight: CGFloat = 820) {
        if !empty { fill() }
        let screen = NSRect(x: 0, y: 0, width: 1000, height: screenHeight)
        let l = placement.layout(in: screen)
        let backdrop = NSView(frame: screen)
        backdrop.wantsLayer = true
        let g = CAGradientLayer()
        g.frame = screen
        g.colors = [NSColor(srgbRed: 0.05, green: 0.24, blue: 0.25, alpha: 1).cgColor, NSColor(srgbRed: 0.10, green: 0.36, blue: 0.36, alpha: 1).cgColor]
        backdrop.layer?.addSublayer(g)
        let root = DailyShelfRootView(frame: NSRect(origin: .zero, size: l.frame.size))
        root.apply(l, placement: placement)
        root.setFrameOrigin(l.frame.origin)
        backdrop.addSubview(root)
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: screen.size), styleMask: .borderless, backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = backdrop
        w.orderFrontRegardless()
        root.content.reload()
        backdrop.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        backdrop.display()
        var data: Data?
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), .bestResolution) {
            data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        if data == nil, let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) {
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        try? data?.write(to: out.appendingPathComponent(name + ".png"))
        w.orderOut(nil)
    }

    func testRenderItemAccents() throws {
        let canvas = FlippedView(frame: NSRect(x: 0, y: 0, width: 860, height: CGFloat((DailyShelfAccent.allCases.count + 1) / 2) * 220 + 30))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(srgbRed: 0.06, green: 0.065, blue: 0.09, alpha: 1).cgColor
        canvas.appearance = NSAppearance(named: .darkAqua)
        for (i, accent) in DailyShelfAccent.allCases.enumerated() {
            let x = CGFloat(i % 2) * 420 + 20, y = CGFloat(i / 2) * 220 + 16
            let title = NSTextField(labelWithString: accent.title)
            title.font = .systemFont(ofSize: 16, weight: .semibold)
            title.textColor = .white
            title.frame = NSRect(x: x, y: y, width: 380, height: 24)
            canvas.addSubview(title)
            let row = DailyShelfRowView(id: UUID())
            row.title = "Prepare the release checklist"
            row.meta = "aurora #214"
            row.metaAbove = true
            row.leading = .symbol("arrow.triangle.pull")
            row.accent = accent
            row.frame = NSRect(x: x, y: y + 32, width: 400, height: 80)
            canvas.addSubview(row)
            let tile = DailyShelfTileView(id: UUID())
            tile.name = "Dashboard"
            tile.accent = accent
            tile.selected = true
            tile.frame = NSRect(x: x, y: y + 122, width: 100, height: 64)
            canvas.addSubview(tile)
            let note = DailyShelfNoteView(id: UUID())
            note.text = "Review notes before shipping."
            note.accent = accent
            note.frame = NSRect(x: x + 110, y: y + 122, width: 290, height: 64)
            canvas.addSubview(note)
        }
        canvas.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: out.appendingPathComponent("daily-shelf-item-accents.png"))
        let detail = NSRect(x: 0, y: 0, width: 860, height: 440)
        let detailRep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: detail))
        canvas.cacheDisplay(in: detail, to: detailRep)
        try XCTUnwrap(detailRep.representation(using: .png, properties: [:]))
            .write(to: out.appendingPathComponent("daily-shelf-accent-detail.png"))
    }

    func testRenderLeftRim() { shot(DailyShelfPlacement(), "daily-shelf-left") }

    func testRenderRightFloatingCompact() {
        var p = DailyShelfPlacement(); p.edge = .right; p.attached = false; p.align = .start; p.height = 560
        shot(p, "daily-shelf-right-floating")
    }

    func testRenderTallEverySection() {
        var p = DailyShelfPlacement(); p.maxHeight = 1700; p.height = 1700; p.minHeight = 420
        shot(p, "daily-shelf-tall", screenHeight: 1760)
    }

    /// Settings › Integrations and the Agents pane's tabs, tall enough to show every row.
    func testRenderAgentSettings() {
        for (name, open) in [("settings-integrations", { (c: SettingsCard) in c.select(.integrations) }),
                             ("settings-agents-claude", { (c: SettingsCard) in c.selectAgent(.claude) }),
                             ("settings-agents-codex", { (c: SettingsCard) in c.selectAgent(.codex) })] {
            let card = SettingsCard(defaultKind: .home, showingZera: true, loginEnabled: false)
            card.frame = NSRect(x: 0, y: 0, width: card.cardWidth, height: 1500)
            open(card)
            card.layoutSubtreeIfNeeded()
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: card.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)
            w.contentView = card
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            card.display()
            if let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) {
                card.cacheDisplay(in: card.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            }
            w.orderOut(nil)
        }
    }

    func testRenderBottomEmpty() {
        var p = DailyShelfPlacement(); p.edge = .bottom; p.align = .end; p.height = 460
        shot(p, "daily-shelf-bottom-empty", empty: true)
    }
}
