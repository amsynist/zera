import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Zera

/// One still of everything on a desktop, for the README: the island open on Home, the Daily Shelf
/// on the left edge and the Clipboard picker's deck, over the Tidal wallpaper.
/// `CFFIXED_USER_HOME="$(mktemp -d)" ZERA_RENDER_HERO=/some/folder swift test --filter HeroRenderTests`.
///
/// Each surface is captured from its own clear, shadowless window (only windows this test
/// creates), so its PNG has real alpha, then CoreGraphics lays them on a 1440×900 pt desktop at 2x.
/// Fictional sample data only, a disposable shelf folder and no network.
@MainActor
final class HeroRenderTests: XCTestCase {
    private var out: URL!
    private var shelfFolder: URL!
    private var savedShelf: DailyShelfStore!
    private var usedFallback: [String] = []

    /// The desktop, in points with a top-left origin.
    private enum Desk {
        static let size = CGSize(width: 1440, height: 900)
        static let scale: CGFloat = 2
        static let menuBar: CGFloat = 32
        static let notch = CGSize(width: 190, height: 32)
        /// Home's height under the notch band: enough for the greeting and the quick actions, and
        /// short enough that the shelf and the picker fit below the island without touching it.
        static let homeHeight: CGFloat = 347
        /// Clear room round the island inside its window, for the rim's glow.
        static let islandPad: CGFloat = 60
        static let gap: CGFloat = 24
        static let edge: CGFloat = 28
    }

    private struct Surface {
        let name: String
        let image: CGImage
        /// The window on the desktop (points, top-left origin).
        let rect: CGRect
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["ZERA_RENDER_HERO"], !dir.isEmpty else { throw XCTSkip("set ZERA_RENDER_HERO to an output folder") }
        guard env["CFFIXED_USER_HOME"] != nil else { throw XCTSkip("use a disposable home (CFFIXED_USER_HOME)") }
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        shelfFolder = FileManager.default.temporaryDirectory.appendingPathComponent("zera-hero-shelf-\(UUID().uuidString)")
        savedShelf = DailyShelfStore.shared
        DailyShelfStore.shared = DailyShelfStore(folder: shelfFolder, settings: { DailyShelfSettings() })
        DailyShelfFavicons.shared.fetchEnabled = false
    }

    override func tearDown() {
        if let s = savedShelf { DailyShelfStore.shared = s }
        if let f = shelfFolder { try? FileManager.default.removeItem(at: f) }
        super.tearDown()
    }

    // MARK: Capturing

    private func clearWindow(_ size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.appearance = NSAppearance(named: .darkAqua)
        return w
    }

    /// One window of this process, alone, with its alpha. `prepare` runs after the last layout
    /// and before the draw that is captured.
    private func capture(_ window: NSWindow, _ name: String, prepare: (() -> Void)? = nil) throws -> CGImage {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        prepare?()
        view.display()
        CATransaction.flush()
        // The window's own frame rather than `.null`: a clear window's image would otherwise be
        // trimmed to what it draws, and the surface would lose its place in the window.
        let primary = try XCTUnwrap(NSScreen.screens.first).frame
        let bounds = CGRect(x: window.frame.minX, y: primary.maxY - window.frame.maxY, width: window.frame.width, height: window.frame.height)
        if let cg = CGWindowListCreateImage(bounds, .optionIncludingWindow, CGWindowID(window.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
           cg.width > 1, cg.height > 1 {
            return cg
        }
        usedFallback.append(name)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.cgImage)
    }

    private func write(_ image: CGImage, _ name: String) throws {
        let url = out.appendingPathComponent(name + ".png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "could not write \(name).png")
    }

    /// The alpha of one pixel (x, y from the top-left).
    private func alpha(_ image: CGImage, x: Int, y: Int) -> CGFloat {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y), width: CGFloat(image.width), height: CGFloat(image.height)))
        return CGFloat(px[3]) / 255
    }

    // MARK: The surfaces

    /// The island open on Home, flush with the top of the screen.
    private func islandHome() throws -> Surface {
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])
        // Sample readings and no sessions or pull requests: never this Mac's own.
        SystemVitals.shared.simulate()
        ClaudeActivityService.shared.preview([])
        GitHubService.shared.preview(login: "you", pulls: [])

        let card = HomeCard()
        card.frame = NSRect(x: 0, y: 0, width: card.cardWidth, height: 400)
        card.layoutSubtreeIfNeeded()
        let h = min(card.desiredHeight, Desk.homeHeight)
        let band = Desk.notch.height
        let size = NSSize(width: card.cardWidth + Desk.islandPad * 2, height: band + h + Isle.statusHeight + Desk.islandPad)
        let iv = IslandView(frame: NSRect(origin: .zero, size: size))
        iv.band = band
        iv.notchWidth = Desk.notch.width
        iv.centerX = size.width / 2
        iv.present(card, size: NSSize(width: card.cardWidth, height: h), direction: 0, animated: false)
        iv.activeTab = .home
        let w = clearWindow(size)
        w.contentView = iv
        w.orderFrontRegardless()
        defer { iv.close(animated: false); w.orderOut(nil); w.contentView = nil; SystemVitals.shared.unwatch() }
        iv.needsLayout = true
        iv.layoutSubtreeIfNeeded()
        iv.display()
        // Let her greeting, the rail and the rim's light settle.
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        // Home lays its list out for its full height; at this height the list ends where it
        // would on a screen this short, the usual margin above the pane's lower edge. Home's
        // own layout puts it back, so this goes in after the last layout.
        let image = try capture(w, "island-home") {
            guard let scroll = card.subviews.compactMap({ $0 as? NSScrollView }).first else { return }
            scroll.setFrameSize(NSSize(width: scroll.frame.width, height: h - scroll.frame.minY - Space.xl))
        }
        print("HERO island rect in its window (pt): \(iv.islandRect)")
        return Surface(name: "island-home", image: image,
                       rect: CGRect(x: (Desk.size.width - size.width) / 2, y: 0, width: size.width, height: size.height))
    }

    private func fillShelf() {
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
        st.addNote("gh pr checkout 218 && swift test --filter Settings")
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
        pr("aurora-web", 218, "Restore settings after a restart") { $0.ci = .failing; $0.failing = 2 }
        if let pinned = st.items.first(where: { $0.kind == .jira }) { st.togglePin(pinned.id) }
    }

    /// The Daily Shelf on the left edge, below the island (the two are wider together than the
    /// desktop, so it takes the room under the island's left end).
    private func dailyShelf(below top: CGFloat) throws -> Surface {
        fillShelf()
        var placement = DailyShelfPlacement()
        let area = NSRect(x: 0, y: 0, width: Desk.size.width, height: Desk.size.height - Desk.menuBar)
        let shoulder = DailyShelfPlacement.shoulder, margin = DailyShelfPlacement.margin
        placement.height = max(placement.minHeight, area.height - 2 * margin - 2 * shoulder - (top - Desk.menuBar - margin - shoulder))
        // Far enough down from the centre that it rests on the bottom margin.
        placement.offset = area.height
        let l = placement.layout(in: area)
        let holder = NSView(frame: NSRect(origin: .zero, size: l.frame.size))
        let root = DailyShelfRootView(frame: holder.bounds)
        root.apply(l, placement: placement)
        root.setFrameOrigin(.zero)
        holder.addSubview(root)
        let w = clearWindow(l.frame.size)
        w.contentView = holder
        w.orderFrontRegardless()
        defer { w.orderOut(nil); w.contentView = nil }
        root.content.reload()
        holder.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let image = try capture(w, "daily-shelf")
        return Surface(name: "daily-shelf", image: image,
                       rect: CGRect(x: l.frame.minX, y: Desk.size.height - l.frame.maxY, width: l.frame.width, height: l.frame.height))
    }

    /// The Clipboard picker: the app's own transparent panel, the pinned code card in front.
    private func clipboardPicker(top: CGFloat) throws -> Surface {
        let screen = try XCTUnwrap(NSScreen.main)
        let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("site/assets/v2/daily-shelf")
        let photo = assets.appendingPathComponent("poster.jpg")
        let video = assets.appendingPathComponent("daily-shelf.mp4")
        let store = ClipboardStore.shared, wasEnabled = store.enabled
        store.preview([
            ClipItem(kind: .text, text: "Review the first-run checklist", sourceApp: "Notes", fingerprint: "sample-text"),
            ClipItem(kind: .link, text: "https://example.com/aurora/releases?tag=v2", sourceApp: "Safari", fingerprint: "sample-link"),
            ClipItem(kind: .code, text: "func greet(_ name: String) -> String {\n    let hello = \"Hello, \\(name)\"\n    return hello\n}", sourceApp: "Xcode", pinned: true, fingerprint: "sample-code"),
            ClipItem(kind: .color, text: "#7BE1C2", sourceApp: "Figma", fingerprint: "sample-color"),
            ClipItem(kind: .files, text: "Site poster", paths: [photo.path], sourceApp: "Finder", fingerprint: "sample-photo"),
            ClipItem(kind: .files, text: "Daily Shelf film", paths: [video.path], sourceApp: "Finder", fingerprint: "sample-video"),
            ClipItem(kind: .files, text: "Release checklist.md", paths: ["/tmp/Release checklist.md"], sourceApp: "Finder", fingerprint: "sample-file"),
            ClipItem(kind: .text, text: "Zera keeps what you copy on this Mac. Open the clip with your shortcut, flip to the copy you want and press Return. Nothing leaves the machine.", sourceApp: "Mail", fingerprint: "sample-long"),
        ])
        store.enabled = true
        let picker = ClipboardPicker()
        defer { picker.close(); store.enabled = wasEnabled }
        picker.toggle(at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Clipboard Picker" && $0.isVisible })
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // The deal, the prompt's fade and the front card's bitmap.
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(picker.selected, 0)
        // A still: no insertion point caught mid-blink in the empty prompt.
        window.makeFirstResponder(nil)
        let image = try capture(window, "clipboard-picker")
        let size = window.frame.size
        let layout = ClipDeckLayout(bounds: size)
        // The front card's right edge sits `Desk.edge` in from the screen's; the prompt's top at `top`.
        return Surface(name: "clipboard-picker", image: image,
                       rect: CGRect(x: Desk.size.width - Desk.edge - layout.hero.maxX, y: top - layout.prompt.minY, width: size.width, height: size.height))
    }

    // MARK: The desktop

    private func wallpaper() throws -> CGImage {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("site/assets/v2/wallpaper/zera-tidal-5k.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func compose(_ surfaces: [Surface], shadows: [String: (blur: CGFloat, drop: CGFloat, alpha: CGFloat)]) throws -> CGImage {
        let s = Desk.scale, W = Int(Desk.size.width * s), H = Int(Desk.size.height * s)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.interpolationQuality = .high
        /// Points from the top-left → the context's pixels (y up).
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * s, y: (Desk.size.height - r.maxY) * s, width: r.width * s, height: r.height * s)
        }
        // The wallpaper, aspect-filled.
        let paper = try wallpaper()
        let fill = max(CGFloat(W) / CGFloat(paper.width), CGFloat(H) / CGFloat(paper.height))
        let pw = CGFloat(paper.width) * fill, ph = CGFloat(paper.height) * fill
        ctx.draw(paper, in: CGRect(x: (CGFloat(W) - pw) / 2, y: (CGFloat(H) - ph) / 2, width: pw, height: ph))
        // A plain menu-bar strip, and the hardware notch the island's band runs into.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.25))
        ctx.fill(px(CGRect(x: 0, y: 0, width: Desk.size.width, height: Desk.menuBar)))
        let notch = px(CGRect(x: (Desk.size.width - Desk.notch.width) / 2, y: 0, width: Desk.notch.width, height: Desk.notch.height))
        let r = 9 * s, path = CGMutablePath()
        path.move(to: CGPoint(x: notch.minX, y: notch.maxY))
        path.addLine(to: CGPoint(x: notch.minX, y: notch.minY + r))
        path.addQuadCurve(to: CGPoint(x: notch.minX + r, y: notch.minY), control: CGPoint(x: notch.minX, y: notch.minY))
        path.addLine(to: CGPoint(x: notch.maxX - r, y: notch.minY))
        path.addQuadCurve(to: CGPoint(x: notch.maxX, y: notch.minY + r), control: CGPoint(x: notch.maxX, y: notch.minY))
        path.addLine(to: CGPoint(x: notch.maxX, y: notch.maxY))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        // Each surface at its own pixels, with a soft shadow under it.
        for surface in surfaces {
            let rect = px(surface.rect)
            XCTAssertEqual(CGFloat(surface.image.width), rect.width, accuracy: 1, "\(surface.name) is not at \(s)x: it would be resampled")
            XCTAssertEqual(CGFloat(surface.image.height), rect.height, accuracy: 1, "\(surface.name) is not at \(s)x: it would be resampled")
            ctx.saveGState()
            if let sh = shadows[surface.name] {
                ctx.setShadow(offset: CGSize(width: 0, height: -sh.drop * s), blur: sh.blur * s, color: CGColor(gray: 0, alpha: sh.alpha))
            }
            ctx.draw(surface.image, in: rect)
            ctx.restoreGState()
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    func testRenderHeroDesktop() throws {
        let island = try islandHome()
        try write(island.image, island.name)
        let islandBottom = Desk.notch.height + Desk.homeHeight + Isle.statusHeight
        let top = islandBottom + Desk.gap
        let shelf = try dailyShelf(below: top)
        try write(shelf.image, shelf.name)
        let picker = try clipboardPicker(top: top)
        try write(picker.image, picker.name)

        // Real alpha outside each surface's own shape (a corner the shape never reaches).
        if usedFallback.isEmpty {
            XCTAssertLessThan(alpha(island.image, x: 2, y: island.image.height - 3), 0.02, "the island's window is not clear")
            XCTAssertLessThan(alpha(shelf.image, x: shelf.image.width - 3, y: 2), 0.02, "the shelf's window is not clear")
            XCTAssertLessThan(alpha(picker.image, x: 2, y: 2), 0.02, "the picker's window is not clear")
        }
        // Nothing overlaps and nothing leaves the desktop (the island's rect without its glow room).
        let desk = CGRect(origin: .zero, size: Desk.size)
        let islandBody = CGRect(x: island.rect.minX + Desk.islandPad, y: 0, width: island.rect.width - Desk.islandPad * 2, height: islandBottom)
        let deck = ClipDeckLayout(bounds: picker.rect.size)
        let pickerBody = CGRect(x: picker.rect.minX + deck.gutterX, y: picker.rect.minY + deck.prompt.minY,
                                width: deck.hero.maxX - deck.gutterX, height: deck.status.maxY - deck.prompt.minY)
        XCTAssertFalse(islandBody.intersects(shelf.rect))
        XCTAssertFalse(islandBody.intersects(pickerBody))
        XCTAssertFalse(shelf.rect.intersects(picker.rect))
        for surface in [shelf, picker] { XCTAssertTrue(desk.contains(surface.rect), "\(surface.name) leaves the desktop: \(surface.rect)") }

        let hero = try compose([island, shelf, picker],
                               shadows: ["island-home": (blur: 44, drop: 18, alpha: 0.45),
                                         "daily-shelf": (blur: 36, drop: 14, alpha: 0.42),
                                         "clipboard-picker": (blur: 30, drop: 12, alpha: 0.34)])
        try write(hero, "hero-desktop")
        XCTAssertEqual(hero.width, 2880)
        XCTAssertEqual(hero.height, 1800)

        print("HERO capture: \(usedFallback.isEmpty ? "CGWindowListCreateImage, alpha" : "cacheDisplay fallback for \(usedFallback)")")
        for surface in [island, shelf, picker] {
            print("HERO \(surface.name): \(surface.image.width)x\(surface.image.height) px, window at \(surface.rect) pt")
        }
        print("HERO island body: \(islandBody) pt; shelf body top \(shelf.rect.minY + DailyShelfPlacement.shoulder); picker deck \(pickerBody) pt")
        print("HERO hero-desktop: \(hero.width)x\(hero.height) px in \(out.path)")
    }
}
