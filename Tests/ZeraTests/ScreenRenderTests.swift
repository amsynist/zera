import AppKit
import XCTest
@testable import Zera

/// Renders every screen to PNGs so the UI can be reviewed without running the app:
/// `ZERA_RENDER_SCREENS=/some/folder swift test --filter ScreenRenderTests`.
/// Run locally when a still image helps diagnose a layout.
@MainActor
final class ScreenRenderTests: XCTestCase {
    private var out: URL!
    private let band: CGFloat = 34
    private let desk = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1)

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["ZERA_RENDER_SCREENS"] else { throw XCTSkip("set ZERA_RENDER_SCREENS to render") }
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    // MARK: Capturing

    private func shot(_ v: NSView, _ name: String, afterShown: (() -> Void)? = nil) {
        if let only = ProcessInfo.processInfo.environment["ZERA_RENDER_ONLY"], !only.split(separator: ",").contains(Substring(name)) { return }
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: v.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = desk
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = v
        w.orderFrontRegardless()
        afterShown?()
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        v.display()
        // Let fades, springs and the tab pill settle.
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        v.display()
        var data: Data?
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), .bestResolution) {
            data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        if data == nil, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        try? data?.write(to: out.appendingPathComponent(name + ".png"))
        w.orderOut(nil)
    }

    /// A screen inside the real island: glass, edge, the tab bar in the notch band.
    private func island(_ screen: NSView & CardContent, tab: CardKind?, _ name: String, afterShown: (() -> Void)? = nil) {
        screen.frame = NSRect(x: 0, y: 0, width: screen.cardWidth, height: 400)
        screen.layoutSubtreeIfNeeded()
        let h = min(screen.desiredHeight, Isle.maxContentHeight)
        let width = Isle.maxWidth + 120
        let iv = IslandView(frame: NSRect(x: 0, y: 0, width: width, height: band + h + 40))
        iv.band = band
        iv.notchWidth = 190
        iv.centerX = width / 2
        iv.present(screen, size: NSSize(width: screen.cardWidth, height: h), direction: 0, animated: false)
        iv.activeTab = tab
        shot(iv, name, afterShown: afterShown)
    }

    private func panel(_ v: NSView, _ name: String) { shot(v, name) }

    // MARK: Sample data

    private func sampleTasks() -> TaskStore {
        let s = TaskStore(url: nil)
        s.add("Ship the dark mode toggle #Aurora 45m")
        s.add("Review Theo's avatar cache PR #Aurora 20m")
        s.add("Write the launch post #Website 30m")
        s.add("Plan next sprint")
        return s
    }

    private func sampleShelf() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zera-render-shelf", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("Q3 report.pdf"); try Data("%PDF-1.4\n".utf8).write(to: pdf)
        let note = dir.appendingPathComponent("Note 7 Oct.txt"); try Data("Ship the theme picker before Friday.".utf8).write(to: note)
        let link = dir.appendingPathComponent("Aurora releases.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/aurora/releases"], format: .xml, options: 0).write(to: link)
        let img = NSImage(size: NSSize(width: 64, height: 40))
        img.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 64, height: 40).fill(); img.unlockFocus()
        let png = dir.appendingPathComponent("hero-shot.png")
        if let tiff = img.tiffRepresentation, let p = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try p.write(to: png) }
        _ = ShelfStore.shared.add(urls: [pdf, png, note, link])
    }

    // MARK: Renders

    func testRenderMascotPoses() throws {
        guard ProcessInfo.processInfo.environment["ZERA_RENDER_FACE"] != nil else { throw XCTSkip("local animation review") }
        let grid = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        var figures: [AnimatedZeraView] = []
        for (index, name) in ["hang_wave", "hang_climb", "hang_peek", "hang_smile", "hang_think", "hang_swing", "hang_upsidedown", "boba"].enumerated() {
            let x = CGFloat(index % 4) * 190, y = CGFloat(1 - index / 4) * 260
            let figure = AnimatedZeraView(frame: NSRect(x: x + 10, y: y + 30, width: 170, height: 220))
            figure.pose = name; grid.addSubview(figure); figures.append(figure)
            let label = NSTextField(labelWithString: name)
            label.font = Typo.caption; label.textColor = .white; label.alignment = .center
            label.frame = NSRect(x: x, y: y + 5, width: 190, height: 20); grid.addSubview(label)
        }
        shot(grid, "zera-all-poses", afterShown: {
            figures.forEach { $0.advanceAnimation(at: CACurrentMediaTime()) }
        })
    }

    /// Local production-motion preview on a neutral desktop; no reminder data is changed.
    func testRenderWaterVisitMotion() async throws {
        guard ProcessInfo.processInfo.environment["ZERA_RENDER_WATER"] != nil else { throw XCTSkip("set ZERA_RENDER_WATER") }
        let scene = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let caption = NSTextField(labelWithString: "Zera's water visit · jump → tap → acknowledge → return")
        caption.font = Typo.detailTitle; caption.textColor = .white
        caption.frame = NSRect(x: 40, y: 30, width: 820, height: 24); scene.addSubview(caption)
        let water = WaterVisitView(frame: NSRect(origin: .zero, size: WaterVisitView.size))
        water.departure = CGPoint(x: 385, y: 410); water.landing = CGPoint(x: 155, y: 155)
        water.onPosition = { [weak water] point in water?.setFrameOrigin(point) }
        scene.addSubview(water)
        let window = NSWindow(contentRect: scene.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = scene; window.backgroundColor = desk; window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless(); water.layoutSubtreeIfNeeded(); water.begin()
        defer { window.orderOut(nil); window.contentView = nil }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(out.appendingPathComponent("zera-water-visit.gif") as CFURL, "com.compuserve.gif" as CFString, 175, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let started = CACurrentMediaTime()
        for frame in 0..<175 {
            if frame == 80 { water.acknowledge() }
            let now = CACurrentMediaTime()
            water.advanceAnimation(at: now); water.figure.advanceAnimation(at: now)
            scene.display(); CATransaction.flush()
            let bitmap = try XCTUnwrap(scene.bitmapImageRepForCachingDisplay(in: scene.bounds))
            scene.cacheDisplay(in: scene.bounds, to: bitmap)
            CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.04]] as CFDictionary)
            if frame == 45, let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: out.appendingPathComponent("zera-water-waiting.png")) }
            if frame == 95, let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: out.appendingPathComponent("zera-water-thanks.png")) }
            let remaining = started + Double(frame + 1) * 0.04 - CACurrentMediaTime()
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(water.motion.stage, .finished)
    }

    /// Accelerated local review of the six waiting lines; production timing stays 12s.
    func testRenderWaterWaitingExpressions() async throws {
        guard ProcessInfo.processInfo.environment["ZERA_RENDER_WATER"] != nil else { throw XCTSkip("set ZERA_RENDER_WATER") }
        let scene = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        let water = WaterVisitView(frame: NSRect(origin: CGPoint(x: 43, y: 18), size: WaterVisitView.size))
        scene.addSubview(water)
        let window = NSWindow(contentRect: scene.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = scene; window.backgroundColor = desk; window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless(); water.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil }
        let started = CACurrentMediaTime()
        water.begin(at: started - WaterVisitMotion.arrivalDuration)
        water.advanceAnimation(at: started)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(out.appendingPathComponent("zera-water-patience.gif") as CFURL, "com.compuserve.gif" as CFString, 180, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<180 {
            let phrase = frame / 30, beat = Double(frame % 30) / 12.5
            let now = started + Double(phrase) * 12 + beat
            water.advanceAnimation(at: now); water.figure.speak(for: 120); water.figure.advanceAnimation(at: now)
            scene.display(); CATransaction.flush()
            let bitmap = try XCTUnwrap(scene.bitmapImageRepForCachingDisplay(in: scene.bounds))
            scene.cacheDisplay(in: scene.bounds, to: bitmap)
            CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]] as CFDictionary)
            if frame % 30 == 15, let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent("zera-water-expression-\(phrase).png"))
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(water.motion.stage, .waiting)
    }

    /// On-demand preview of the hanging rig, stepping the production frame update.
    func testRenderZeraFace() async throws {
        guard ProcessInfo.processInfo.environment["ZERA_RENDER_FACE"] != nil else {
            throw XCTSkip("set ZERA_RENDER_FACE for a local character preview")
        }
        let view = ZeraView(frame: NSRect(x: 0, y: 0, width: 220, height: 340))
        view.style = .hanging; view.mood = .idle; view.bottomPad = 16
        panel(view, "zera-face-idle")
        view.lookTarget = CGPoint(x: -1, y: -0.5)
        shot(view, "zera-face-left", afterShown: {
            let now = CACurrentMediaTime()
            for frame in 0..<30 { view.advanceAnimation(at: now + Double(frame) / 30) }
        })
        XCTAssertLessThan(view.look.x, -0.9)
        view.lookTarget = CGPoint(x: 1, y: 0.6)
        shot(view, "zera-face-right", afterShown: {
            let now = CACurrentMediaTime()
            for frame in 0..<30 { view.advanceAnimation(at: now + Double(frame) / 30) }
        })
        XCTAssertGreaterThan(view.look.x, 0.9)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view; window.backgroundColor = desk; window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        let url = out.appendingPathComponent("zera-face-motion.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 150, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let started = CACurrentMediaTime()
        for frame in 0..<150 {
            let angle = Double(frame) / 150 * .pi * 2
            view.lookTarget = CGPoint(x: sin(angle), y: cos(angle) * 0.7)
            view.advanceAnimation(at: CACurrentMediaTime())
            view.display(); CATransaction.flush()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.04]] as CFDictionary)
            let remaining = started + Double(frame + 1) * 0.04 - CACurrentMediaTime()
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// Short local preview of the actual Core Animation transition; never runs in CI.
    func testRenderOpenerActionMotion() async throws {
        guard ProcessInfo.processInfo.environment["ZERA_RENDER_OPENER_MOTION"] != nil else {
            throw XCTSkip("set ZERA_RENDER_OPENER_MOTION for a local animated preview")
        }
        var ready = !AppCatalog.shared.apps.isEmpty
        AppCatalog.shared.refreshIfNeeded { ready = true }
        for _ in 0..<160 where !ready { try await Task.sleep(nanoseconds: 50_000_000) }
        let view = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        view.prepare(); view.previewType("safari")
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        view.layoutSubtreeIfNeeded(); view.display()
        let url = out.appendingPathComponent("opener-action-motion.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 60, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let started = CACurrentMediaTime()
        for frame in 0..<60 {
            if frame == 10 || frame == 36 { view.previewActions() }
            CATransaction.flush()
            let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), .bestResolution))
            let context = try XCTUnwrap(CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8,
                bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 960, height: 600))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.04]] as CFDictionary)
            let remaining = started + Double(frame + 1) * 0.04 - CACurrentMediaTime()
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testRenderClipboardAfterGridSwitch() throws {
        let name = "24b-clipboard-after-grid-switch"
        if let only = ProcessInfo.processInfo.environment["ZERA_RENDER_ONLY"], only != name { return }
        let store = ClipboardStore.shared
        store.enabled = true
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let items = try (0..<3).map { i -> ClipItem in
            var item = ClipItem(kind: .image, text: "Sample screenshot \(i)", fingerprint: "switch-\(i)")
            item.imageFile = "switch-\(i).png"
            let url = store.imageURL(item)!
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return item
        }
        store.preview(items + [ClipItem(kind: .text, text: "A sample note", fingerprint: "switch-note")])
        let view = ClipboardView()
        func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
        let filters = try XCTUnwrap(descendants(view).compactMap { $0 as? GitHubSegmentedControl }.first)
        island(view, tab: .clipboard, name, afterShown: {
            for _ in 0..<10 {
                filters.onSelect?(ClipboardStore.Filter.images.rawValue)
                view.display()
                filters.onSelect?(ClipboardStore.Filter.all.rawValue)
                view.display()
            }
        })
    }

    func testRenderEveryScreen() throws {
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])
        let tasks = sampleTasks()
        // Home's vitals strip shows this machine's readings.
        SystemVitals.shared.simulate()
        defer { SystemVitals.shared.unwatch() }
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))

        // Hovering her: the nodes bloom out round the rope.
        let bloomView = IslandView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
        bloomView.band = band
        bloomView.notchWidth = 190
        bloomView.centerX = 380
        bloomView.counts = [.claude: 1, .shelf: 4, .github: 2]
        bloomView.badges = [.claude]
        bloomView.instruments = [.home: IslandInstrument(progress: 0.34, text: "78", tone: nil),
                                 .claude: IslandInstrument(progress: 0.62, text: nil, tone: nil),
                                 .tasks: IslandInstrument(progress: 0.25, text: nil, tone: nil),
                                 .reminders: IslandInstrument(progress: 0.8, text: "12m", tone: nil)]
        bloomView.peek()
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        shot(bloomView, "00-bloom")
        island(HomeCard(), tab: .home, "01-home")
        island(ClaudeSessionsView(), tab: .claude, "02-claude")
        island(DropFilesView(), tab: .shelf, "03-shelf-empty")
        try sampleShelf()
        let shelf = DropFilesView()
        island(shelf, tab: .shelf, "04-shelf")
        let detail = DropFilesView()
        detail.setExpanded(true)
        island(detail, tab: .shelf, "05-shelf-file")
        // Sample copies only: the render never shows (or watches) the real clipboard.
        ClipboardStore.shared.preview([
            ClipItem(kind: .link, text: "https://example.com/aurora/pull/214", bytes: 40, sourceApp: "Safari", fingerprint: "s1"),
            ClipItem(kind: .text, text: "Ship the theme picker before Friday", bytes: 36, sourceApp: "Slack", fingerprint: "s2")])
        island(ClipboardView(), tab: .clipboard, "06-clipboard")
        island(TasksCard(store: tasks), tab: .tasks, "07-tasks")
        island(GitHubCard(), tab: .github, "08-pull-requests")
        island(RemindersView(), tab: .reminders, "09-reminders")
        let settings = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        island(settings, tab: .settings, "10-settings-general")
        let appearance = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        appearance.select(.appearance)
        island(appearance, tab: .settings, "11-settings-appearance")
        let claudePane = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        claudePane.select(.claude)
        island(claudePane, tab: .settings, "12-settings-claude")

        // Banners: a meeting with a call link (the one that was cut off), and a PR toast.
        ReminderService.shared.preview(ReminderAlert(id: "render-meeting", kind: .calendarHeadsUp,
            headline: "You have a meeting in 5 minutes", detail: "Review discussion on the Q3 roadmap · 3:00 PM",
            eventID: "render", joinURL: URL(string: "https://meet.example.com/abc")))
        island(ReminderAlertCard(), tab: .reminders, "13-banner-meeting")
        ReminderService.shared.preview(ReminderAlert(id: "render-water", kind: .now, headline: "Drink water",
            detail: "Every 2 hours · next 1:00 PM", hydration: true))
        let water = WaterVisitView(frame: NSRect(origin: .zero, size: WaterVisitView.size))
        water.begin(at: CACurrentMediaTime() - 1)
        panel(water, "14-banner-water")
        let toast = ToastCard()
        toast.show(event: GHEvent(id: "render", kind: .prOpened, title: "Add themes: seven built in, plus your own",
            subtitle: "acme/aurora #11", date: Date(), url: URL(string: "https://example.com/pr/11")!, approval: nil))
        toast.countdownLine.progress = 0.55   // part-way through its reading time
        island(toast, tab: nil, "15-banner-pr")

        // The Claude wings.
        let session = ClaudeSession(id: "render", cwd: "/Users/you/aurora", at: Date())
        session.title = "Fix the theme picker"
        session.status = .running
        session.promptAt = Date().addingTimeInterval(-90)
        let wings = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        wings.centerX = LiveActivityView.panelSize.width / 2
        wings.update(session: session, pending: HookRequest(id: "r", receivedAt: Date(), sessionID: session.id, toolName: "Bash",
            command: "npm test -- --watch=false", detail: nil, cwd: "/Users/you/aurora"))
        panel(wings, "16-wings-approval")
        let running = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        running.centerX = LiveActivityView.panelSize.width / 2
        running.update(session: session, pending: nil)
        panel(running, "17-wings-running")
        let bubble = BubbleView(frame: .zero)
        bubble.text = "all green! ✅"
        let tag = BubbleView.size(for: bubble.text)
        bubble.frame = NSRect(origin: .zero, size: BubbleView.panelFrame(for: NSRect(origin: .zero, size: tag)).size)
        bubble.tailX = bubble.frame.width / 2
        panel(bubble, "17b-caption")

        // Floating panels.
        let export = TaskExportView(store: tasks)
        export.frame = NSRect(origin: .zero, size: TaskExportView.size)
        panel(export, "18-export")
        // Sized the way TasksController sizes its panel.
        let focus = FocusCardView(store: tasks)
        focus.setFrameSize(NSSize(width: focus.frame.width, height: focus.desiredHeight))
        panel(focus, "19-focus-card")
        let orb = FocusOrbView(store: tasks)
        orb.frame = NSRect(x: 0, y: 0, width: FocusOrbView.size, height: FocusOrbView.size)
        panel(orb, "19b-focus-orb")
        let pill = OrbPlusView()
        pill.setInfo(big: orb.info.big, small: orb.info.small)
        pill.frame = NSRect(x: 0, y: 0, width: pill.fittedWidth, height: OrbPlusView.size)
        panel(pill, "19c-orb-pill")
        let quick = QuickAddView()
        quick.frame = NSRect(origin: .zero, size: QuickAddView.size)
        panel(quick, "19d-quick-add")
        // Capture the starting state after discovery, so Your Usual contains real apps.
        var catalogReady = !AppCatalog.shared.apps.isEmpty
        AppCatalog.shared.refreshIfNeeded { catalogReady = true }
        let until = Date().addingTimeInterval(8)
        while !catalogReady, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let opener = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        opener.prepare()
        panel(opener, "20-app-opener")
        let compactOpener = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 1024, height: 600))
        compactOpener.prepare()
        panel(compactOpener, "20g-app-opener-compact")
        let ring = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        ring.prepare()
        ring.previewType("safari")
        ring.previewActions()
        panel(ring, "20b-app-opener-actions")
        let compactRing = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 1024, height: 600))
        compactRing.prepare()
        compactRing.previewType("safari")
        compactRing.previewActions()
        panel(compactRing, "20f-app-opener-compact-actions")
        let lane = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        lane.prepare()
        lane.previewType("kill")
        panel(lane, "20c-app-opener-typing")
        let tree = TreeOpenerView(frame: NSRect(x: 0, y: 0, width: TreeOpenerView.panelWidth, height: 800))
        tree.prepare()
        tree.previewType("safari")
        panel(tree, "20d-app-opener-classic")
        let treeActions = TreeOpenerView(frame: NSRect(x: 0, y: 0, width: TreeOpenerView.panelWidth, height: 800))
        treeActions.prepare()
        treeActions.previewType("safari")
        treeActions.previewActions()
        panel(treeActions, "20e-app-opener-classic-actions")

        // Every theme on two busy screens.
        for t in ThemeStore.shared.builtIns {
            ThemeStore.shared.select(t)
            island(HomeCard(), tab: .home, "theme-\(t.id)-home")
            island(TasksCard(store: tasks), tab: .tasks, "theme-\(t.id)-tasks")
        }
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])
    }

    // MARK: Populated states

    /// A month of commit-made tasks across two projects, with the long repo names real work has.
    private func sampleMonth() -> TaskStore {
        let s = TaskStore(url: nil)
        let cal = Calendar.current
        let repos = ["aurora-app", "aurora-api", "design-system", "website"]
        let subjects = ["Add dark mode to the settings page", "Cache avatars on disk between launches",
                        "Fix the date picker on small screens", "Speed up the search index rebuild",
                        "Polish the onboarding copy", "Upgrade the charts library"]
        for (n, name) in ["Aurora", "Website"].enumerated() {
            let p = s.addProject(name)
            s.link(p, to: "/tmp")
            var commits: [GitCommit] = []
            for d in 0..<12 {
                guard let day = cal.date(byAdding: .day, value: -(d * 2 + n), to: Date()) else { continue }
                for k in 0..<(1 + d % 3) {
                    let at = cal.date(bySettingHour: 10 + k * 2, minute: 0, second: 0, of: day) ?? day
                    commits.append(GitCommit(hash: String(format: "%010x", d * 10 + k + n * 1000), date: at,
                                             subject: subjects[(d + k + n) % subjects.count], body: "", repo: repos[(d + k + n) % repos.count]))
                }
            }
            s.importCommits(p, tasks: TaskGitSync.tasks(from: commits, project: p, calendar: cal, claude: false),
                            seen: commits.map(\.hash), through: Date())
        }
        s.add("Plan next sprint #Aurora 30m")
        return s
    }

    private func samplePRs() -> [GHPullRequest] {
        let now = Date()
        func person(_ l: String) -> GHPullRequest.Person { .init(login: l, avatar: nil) }
        var a = GHPullRequest(id: "acme/aurora-web#214", owner: "acme", repo: "aurora-web", number: 214,
            title: "Make the settings page work from the keyboard",
            author: person("maya"), created: now.addingTimeInterval(-47 * 60), updated: now.addingTimeInterval(-5 * 60),
            url: URL(string: "https://github.com/acme/aurora-web/pull/214")!)
        a.branch = "settings-keyboard"; a.base = "main"
        a.reviewers = [person("sam"), person("theo")]; a.comments = 4
        a.additions = 13; a.deletions = 2; a.changedFiles = 1
        a.ci = .failed; a.checksTotal = 6
        a.failing = [.init(name: "Lint", title: "2 warnings treated as errors", summary: "", url: nil),
                     .init(name: "unit-tests", title: "3 failed", summary: "", url: nil)]
        a.labels = ["accessibility", "ui"]; a.reviewRequested = true
        var b = GHPullRequest(id: "acme/aurora#412", owner: "acme", repo: "aurora", number: 412, title: "Add themes: seven built in, plus your own",
            author: person("you"), created: now.addingTimeInterval(-3 * 3600), updated: now.addingTimeInterval(-20 * 60),
            url: URL(string: "https://github.com/acme/aurora/pull/412")!)
        b.ci = .passed; b.review = .approved; b.approvedBy = ["theo"]; b.reviewers = [person("theo")]; b.mine = true
        b.additions = 812; b.deletions = 140; b.changedFiles = 22
        var c = GHPullRequest(id: "acme/infra#88", owner: "acme", repo: "infra", number: 88, title: "Bump the build image to Node 22",
            author: person("dependabot"), created: now.addingTimeInterval(-6 * 3600), updated: now.addingTimeInterval(-2 * 3600),
            url: URL(string: "https://github.com/acme/infra/pull/88")!)
        c.ci = .running; c.approvalsWaiting = 1
        // Yours from last week, approved since: only under Approvals.
        var d = GHPullRequest(id: "acme/aurora#398", owner: "acme", repo: "aurora", number: 398, title: "Cache avatars on disk between launches",
            author: person("you"), created: now.addingTimeInterval(-6 * 86400), updated: now.addingTimeInterval(-40 * 60),
            url: URL(string: "https://github.com/acme/aurora/pull/398")!)
        d.mine = true; d.ci = .passed; d.review = .approved; d.approvedBy = ["sam", "theo"]; d.reviewers = [person("sam"), person("theo")]
        return [a, b, c, d]
    }

    func testRenderPopulatedStates() throws {
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])

        // Pull requests: the list, and a PR's page.
        let prs = samplePRs()
        GitHubService.shared.preview(login: "you", pulls: prs)
        island(GitHubCard(), tab: .github, "21-pull-requests-list")
        let detail = GitHubCard()
        detail.openDetail(prs[0])
        island(detail, tab: .github, "22-pr-detail")
        let approvals = GitHubCard()
        approvals.selectTab(3)
        island(approvals, tab: .github, "35-pr-approvals")
        approvals.selectTab(0)

        // Claude sessions: running, waiting, done.
        func session(_ id: String, _ title: String, _ status: ClaudeSession.Status, _ ago: TimeInterval) -> ClaudeSession {
            let s = ClaudeSession(id: id, cwd: "/Users/you/\(id)", at: Date().addingTimeInterval(-ago))
            s.title = title; s.status = status; s.promptAt = Date().addingTimeInterval(-ago); s.branch = "main"
            return s
        }
        ClaudeActivityService.shared.preview([session("aurora", "Fix the theme picker", .running, 90),
                                              session("website", "Why is the hero video so large?", .waiting, 400),
                                              session("zera", "Write release notes for v0.1.4", .done, 3000)])
        island(ClaudeSessionsView(), tab: .claude, "23-claude-sessions")

        // Clipboard with a few kinds of copies.
        ClipboardStore.shared.preview([
            ClipItem(kind: .text, text: "Ship the theme picker before Friday — Theo has the review.", bytes: 60, sourceApp: "Slack", fingerprint: "a"),
            ClipItem(kind: .link, text: "https://example.com/aurora/pull/214", bytes: 40, sourceApp: "Safari", fingerprint: "b"),
            ClipItem(kind: .code, text: "swift test --filter ScreenRenderTests", bytes: 38, sourceApp: "Terminal", fingerprint: "c"),
            ClipItem(kind: .color, text: "#7AA2F7", bytes: 7, sourceApp: "Figma", fingerprint: "d")])
        island(ClipboardView(), tab: .clipboard, "24-clipboard")

        // Export, every format, on a month of commit work.
        let month = sampleMonth()
        for (i, f) in TaskExport.Format.allCases.enumerated() {
            let v = TaskExportView(store: month)
            v.frame = NSRect(origin: .zero, size: TaskExportView.size)
            v.span = .all
            v.format = f
            panel(v, "2\(5 + i)-export-\(f.title.lowercased())")
        }
        // Home with this Mac's vitals, and the This Mac page (live readings from the machine).
        SystemVitals.shared.simulate()
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
        island(HomeCard(), tab: .home, "30-home-vitals")
        let mac = HomeCard()
        mac.setVitals(true, animated: false)
        island(mac, tab: .home, "31-this-mac")
        SystemVitals.shared.unwatch()

        // The low-battery banner.
        var w = false, c = false
        if let low = BatteryAlerts.lowAlert(VitalsSample.Battery(percent: 18, charging: false, onPower: false, toEmpty: 64),
                                            threshold: 20, enabled: true, warned: &w, warnedCritical: &c) {
            ReminderService.shared.preview(low)
            island(ReminderAlertCard(), tab: nil, "34-banner-battery")
        }

        // Shelf · Fresh: new files in the (render home's) Downloads and Desktop. Only ever into a
        // sample home (CFFIXED_USER_HOME), never a real Desktop or Downloads.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sampleHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil
        for (folder, names) in [("Downloads", ["Invoice-October.pdf", "team-offsite-photos.zip", "design-review.mov"]),
                                ("Desktop", ["Screenshot 2026-10-07 at 20.41.12.png", "Q3 roadmap.key"])] where sampleHome {
            let dir = home.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in names where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path) {
                try Data(repeating: 7, count: 180_000).write(to: dir.appendingPathComponent(n))
            }
        }
        UserDefaults.standard.set(true, forKey: "zera.shelf.freshTab")
        FreshFiles.shared.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let freshShelf = DropFilesView()
        freshShelf.willShow()
        island(freshShelf, tab: .shelf, "32-shelf-fresh")
        UserDefaults.standard.set(false, forKey: "zera.shelf.freshTab")
        let shelfSettings = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        shelfSettings.select(.shelf)
        island(shelfSettings, tab: .settings, "33-settings-shelf")

        // Reminders with a day in it (saved events: a sample home only).
        if sampleHome {
            let rs = ReminderService.shared, now = Date()
            var sync = CalendarEvent(title: "Design sync", startAt: now.addingTimeInterval(12 * 60))
            sync.url = "https://meet.example.com/design"
            rs.save(event: sync)
            rs.save(event: CalendarEvent(title: "1:1 with Theo", startAt: now.addingTimeInterval(3 * 3600)))
            rs.addOneOff(title: "Review the Q4 roadmap", at: now.addingTimeInterval(45 * 60))
            let rem = RemindersView()
            rem.willShow()
            island(rem, tab: .reminders, "36-reminders")
        }

        // Tasks, the week view.
        UserDefaults.standard.set(1, forKey: "tasks.viewSpan")
        island(TasksCard(store: month), tab: .tasks, "29-tasks-week")
        UserDefaults.standard.set(0, forKey: "tasks.viewSpan")
    }

    // MARK: Tour frames

    /// Records the new screens moving, for the site's film: `ZERA_TOUR_FRAMES=1` with
    /// ZERA_RENDER_SCREENS pointing at an empty folder. Writes frames/NNNNN.jpg, times.json and
    /// scenes.json (when each scene starts).
    func testRecordTour() throws {
        // It writes sample downloads into the home folder: only a sample one (CFFIXED_USER_HOME).
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else { throw XCTSkip("set CFFIXED_USER_HOME to a sample home") }
        guard ProcessInfo.processInfo.environment["ZERA_TOUR_FRAMES"] != nil else { throw XCTSkip("set ZERA_TOUR_FRAMES to record") }
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])
        let frames = out.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        // One window for everything: the island on top, room below for Export.
        let size = NSSize(width: 900, height: 860)
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = desk
        w.appearance = NSAppearance(named: .darkAqua)
        let root = FlippedView(frame: NSRect(origin: .zero, size: size))
        w.contentView = root
        w.orderFrontRegardless()
        let iv = IslandView(frame: NSRect(x: 0, y: 0, width: size.width, height: band + Isle.maxContentHeight + 40))
        iv.band = band
        iv.notchWidth = 190
        iv.centerX = size.width / 2
        root.addSubview(iv)

        var times: [Double] = []
        var scenes: [[String: Any]] = []
        let start = CACurrentMediaTime()
        let encode = DispatchQueue(label: "tour-encode")
        let group = DispatchGroup()
        func capture() {
            guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), .bestResolution) else { return }
            let n = times.count
            times.append(CACurrentMediaTime() - start)
            group.enter()
            encode.async {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.93])?
                    .write(to: frames.appendingPathComponent(String(format: "%05d.jpg", n)))
                group.leave()
            }
        }
        func run(_ seconds: Double) {
            let end = CACurrentMediaTime() + seconds
            var next = CACurrentMediaTime()
            while CACurrentMediaTime() < end {
                next += 1.0 / 30
                RunLoop.main.run(until: Date().addingTimeInterval(max(0.001, next - CACurrentMediaTime())))
                capture()
            }
        }
        func scene(_ name: String) { scenes.append(["name": name, "t": CACurrentMediaTime() - start]) }
        func show(_ c: NSView & CardContent, tab: CardKind?, direction: CGFloat) {
            c.setFrameSize(NSSize(width: c.cardWidth, height: 400))
            c.needsLayout = true
            c.layoutSubtreeIfNeeded()
            iv.present(c, size: NSSize(width: c.cardWidth, height: min(c.desiredHeight, Isle.maxContentHeight)), direction: direction, animated: true)
            iv.activeTab = tab
        }

        // Data: live vitals, sample PRs, sessions, clipboard, a month of tasks, fresh downloads.
        SystemVitals.shared.simulate()
        GitHubService.shared.preview(login: "you", pulls: samplePRs())
        let month = sampleMonth()
        ClipboardStore.shared.preview([
            ClipItem(kind: .text, text: "Ship the theme picker before Friday — Theo has the review.", bytes: 60, sourceApp: "Slack", fingerprint: "a"),
            ClipItem(kind: .link, text: "https://example.com/aurora/pull/214", bytes: 40, sourceApp: "Safari", fingerprint: "b"),
            ClipItem(kind: .code, text: "swift test --filter ScreenRenderTests", bytes: 38, sourceApp: "Terminal", fingerprint: "c"),
            ClipItem(kind: .color, text: "#9D8CFF", bytes: 7, sourceApp: "Figma", fingerprint: "d")])
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        for (folder, names) in [("Downloads", ["Invoice-October.pdf", "team-offsite-photos.zip", "design-review.mov"]),
                                ("Desktop", ["Q3 roadmap.key"])] {
            let dir = home.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in names where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path) {
                try Data(repeating: 7, count: 240_000).write(to: dir.appendingPathComponent(n))
            }
        }
        let arriving = downloads.appendingPathComponent("Screenshot 2026-10-08 at 09.41.12.png")
        try? FileManager.default.removeItem(at: arriving)
        UserDefaults.standard.set(true, forKey: "zera.shelf.freshTab")
        FreshFiles.shared.start()
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))   // vitals have a minute to fill in a little

        // 1. Home with the vitals strip.
        let homeCard = HomeCard()
        scene("home")
        show(homeCard, tab: .home, direction: 0)
        run(3.6)
        // 2. Tap the strip: This Mac.
        scene("thismac")
        homeCard.setVitals(true)
        homeCard.layoutSubtreeIfNeeded()
        show(homeCard, tab: .home, direction: 0)
        run(4.2)
        // 3. Shelf · Fresh, and a download lands.
        let shelf = DropFilesView()
        shelf.willShow()
        scene("fresh")
        show(shelf, tab: .shelf, direction: 1)
        run(1.6)
        try Data(repeating: 9, count: 1_900_000).write(to: arriving)
        run(2.8)
        // 4. Clipboard.
        let clip = ClipboardView()
        clip.willShow()
        scene("clipboard")
        show(clip, tab: .clipboard, direction: 1)
        run(2.4)
        // 5. Tasks, the week.
        UserDefaults.standard.set(1, forKey: "tasks.viewSpan")
        let tasksCard = TasksCard(store: month)
        scene("tasks")
        show(tasksCard, tab: .tasks, direction: 1)
        run(2.6)
        UserDefaults.standard.set(0, forKey: "tasks.viewSpan")
        // 6. Pull requests: Approvals, then a PR's page.
        let gh = GitHubCard()
        gh.selectTab(3)
        scene("approvals")
        show(gh, tab: .github, direction: 1)
        run(2.4)
        scene("prpage")
        gh.openDetail(samplePRs()[0])
        show(gh, tab: .github, direction: 0)
        run(2.6)
        gh.selectTab(0)
        // 7. Claude sessions.
        func session(_ id: String, _ title: String, _ status: ClaudeSession.Status, _ ago: TimeInterval) -> ClaudeSession {
            let s = ClaudeSession(id: id, cwd: "/Users/you/\(id)", at: Date().addingTimeInterval(-ago))
            s.title = title; s.status = status; s.promptAt = Date().addingTimeInterval(-ago); s.branch = "main"
            return s
        }
        ClaudeActivityService.shared.preview([session("aurora", "Fix the theme picker", .running, 90),
                                              session("website", "Why is the hero video so large?", .waiting, 400),
                                              session("zera", "Write release notes for v0.1.4", .done, 3000)])
        scene("claude")
        show(ClaudeSessionsView(), tab: .claude, direction: -1)
        run(2.6)
        // 8. The battery banner.
        var warned = false, critical = false
        if let low = BatteryAlerts.lowAlert(VitalsSample.Battery(percent: 18, charging: false, onPower: false, toEmpty: 64),
                                            threshold: 20, enabled: true, warned: &warned, warnedCritical: &critical) {
            ReminderService.shared.preview(low)
        }
        scene("battery")
        show(ReminderAlertCard(), tab: nil, direction: 0)
        run(2.8)
        // 9. Export: Timesheet, then Excel.
        let export = TaskExportView(store: month)
        export.span = .all
        export.frame = NSRect(x: (size.width - TaskExportView.size.width) / 2, y: (size.height - TaskExportView.size.height) / 2,
                              width: TaskExportView.size.width, height: TaskExportView.size.height)
        iv.isHidden = true
        root.addSubview(export)
        scene("export")
        run(1.8)
        export.format = .xlsx
        run(2.2)
        scene("end")
        run(0.3)

        group.wait()
        SystemVitals.shared.unwatch()
        UserDefaults.standard.set(false, forKey: "zera.shelf.freshTab")
        w.orderOut(nil)
        try JSONSerialization.data(withJSONObject: times).write(to: out.appendingPathComponent("times.json"))
        try JSONSerialization.data(withJSONObject: scenes).write(to: out.appendingPathComponent("scenes.json"))
        print("tour: \(times.count) frames, \(String(format: "%.1f", times.last ?? 0)) s")
    }

    /// The full tour: every screen of the current app, for the site and the README.
    /// `ZERA_FULL_TOUR=1` with ZERA_RENDER_SCREENS pointing at an empty folder.
    func testRecordFullTour() throws {
        // It writes sample downloads into the home folder: only a sample one (CFFIXED_USER_HOME).
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else { throw XCTSkip("set CFFIXED_USER_HOME to a sample home") }
        guard ProcessInfo.processInfo.environment["ZERA_FULL_TOUR"] != nil else { throw XCTSkip("set ZERA_FULL_TOUR to record") }
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])
        let frames = out.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        let size = NSSize(width: 1600, height: 900)
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 20, y: 20), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = desk
        w.appearance = NSAppearance(named: .darkAqua)
        let root = FlippedView(frame: NSRect(origin: .zero, size: size))
        w.contentView = root
        w.orderFrontRegardless()
        let iv = IslandView(frame: NSRect(x: 0, y: 0, width: size.width, height: band + Isle.maxContentHeight + 40))
        iv.band = band
        iv.notchWidth = 190
        iv.centerX = size.width / 2
        root.addSubview(iv)

        var times: [Double] = []
        var scenes: [[String: Any]] = []
        let start = CACurrentMediaTime()
        let encode = DispatchQueue(label: "full-tour-encode")
        let group = DispatchGroup()
        func capture() {
            guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), .bestResolution) else { return }
            let n = times.count
            times.append(CACurrentMediaTime() - start)
            group.enter()
            encode.async {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.93])?
                    .write(to: frames.appendingPathComponent(String(format: "%05d.jpg", n)))
                group.leave()
            }
        }
        func run(_ seconds: Double) {
            let end = CACurrentMediaTime() + seconds
            var next = CACurrentMediaTime()
            while CACurrentMediaTime() < end {
                next += 1.0 / 30
                RunLoop.main.run(until: Date().addingTimeInterval(max(0.001, next - CACurrentMediaTime())))
                capture()
            }
        }
        // `place`: island (hangs from the top, the island's own area), float (centred), top (the wings).
        func scene(_ name: String, _ place: String) { scenes.append(["name": name, "t": CACurrentMediaTime() - start, "place": place]) }
        var floating: NSView?
        func show(_ c: NSView & CardContent, tab: CardKind?, direction: CGFloat) {
            floating?.removeFromSuperview(); floating = nil
            iv.isHidden = false
            c.setFrameSize(NSSize(width: c.cardWidth, height: 400))
            c.needsLayout = true
            c.layoutSubtreeIfNeeded()
            iv.present(c, size: NSSize(width: c.cardWidth, height: min(c.desiredHeight, Isle.maxContentHeight)), direction: direction, animated: true)
            iv.activeTab = tab
        }
        func float(_ v: NSView, top: Bool = false) {
            floating?.removeFromSuperview()
            iv.isHidden = true
            v.setFrameOrigin(NSPoint(x: (size.width - v.frame.width) / 2, y: top ? 0 : (size.height - v.frame.height) / 2))
            root.addSubview(v)
            floating = v
            if !Motion.reduced { Motion.arrive(v, direction: 0) }
        }

        // Sample data, all in the throwaway home: vitals are this machine's.
        SystemVitals.shared.simulate()
        GitHubService.shared.preview(login: "you", pulls: samplePRs())
        let today = sampleTasks()
        let month = sampleMonth()
        ClipboardStore.shared.preview([
            ClipItem(kind: .text, text: "Ship the theme picker before Friday — Theo has the review.", bytes: 60, sourceApp: "Slack", fingerprint: "a"),
            ClipItem(kind: .link, text: "https://example.com/aurora/pull/214", bytes: 40, sourceApp: "Safari", fingerprint: "b"),
            ClipItem(kind: .code, text: "swift test --filter ScreenRenderTests", bytes: 38, sourceApp: "Terminal", fingerprint: "c"),
            ClipItem(kind: .color, text: "#9D8CFF", bytes: 7, sourceApp: "Figma", fingerprint: "d")])
        try sampleShelf()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        for (folder, names) in [("Downloads", ["Invoice-October.pdf", "team-offsite-photos.zip", "design-review.mov"]), ("Desktop", ["Q3 roadmap.key"])] {
            let dir = home.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in names where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path) {
                try Data(repeating: 7, count: 240_000).write(to: dir.appendingPathComponent(n))
            }
        }
        let arriving = downloads.appendingPathComponent("Screenshot 2026-10-08 at 09.41.12.png")
        try? FileManager.default.removeItem(at: arriving)
        UserDefaults.standard.set(false, forKey: "zera.shelf.freshTab")
        let rs = ReminderService.shared
        let now = Date()
        var review = CalendarEvent(title: "Design review", startAt: now.addingTimeInterval(50 * 60))
        review.url = "https://meet.example.com/design"
        rs.save(event: review)
        rs.save(event: CalendarEvent(title: "1:1 with Theo", startAt: now.addingTimeInterval(3 * 3600)))
        rs.addOneOff(title: "Send the October invoice", at: now.addingTimeInterval(2 * 3600))
        func session(_ id: String, _ title: String, _ status: ClaudeSession.Status, _ ago: TimeInterval) -> ClaudeSession {
            let s = ClaudeSession(id: id, cwd: "/Users/you/\(id)", at: Date().addingTimeInterval(-ago))
            s.title = title; s.status = status; s.promptAt = Date().addingTimeInterval(-ago); s.branch = "main"
            return s
        }
        // The opener's app list (only a built-in app is searched for on camera), with no history
        // from earlier test runs.
        UserDefaults.standard.removeObject(forKey: "appOpener.usage")
        var catalogReady = false
        AppCatalog.shared.refreshIfNeeded { catalogReady = true }
        let catalogDeadline = Date().addingTimeInterval(20)
        while !catalogReady && Date() < catalogDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let running = session("aurora", "Fix the theme picker", .running, 90)
        ClaudeActivityService.shared.preview([running, session("website", "Why is the hero video so large?", .waiting, 400),
                                              session("zera", "Write release notes for v0.1.4", .done, 3000)])
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))

        // Home, and This Mac.
        let homeCard = HomeCard()
        scene("home", "island"); show(homeCard, tab: .home, direction: 0); run(3.4)
        scene("thismac", "island"); homeCard.setVitals(true); homeCard.layoutSubtreeIfNeeded(); show(homeCard, tab: .home, direction: 0); run(3.4)
        // Claude: the sessions, then the wings.
        scene("claude", "island"); show(ClaudeSessionsView(), tab: .claude, direction: 1); run(2.8)
        let wings = LiveActivityView(frame: NSRect(origin: .zero, size: LiveActivityView.panelSize))
        wings.centerX = LiveActivityView.panelSize.width / 2
        wings.update(session: running, pending: HookRequest(id: "r", receivedAt: Date(), sessionID: running.id, toolName: "Bash",
            command: "npm test -- --watch=false", detail: nil, cwd: "/Users/you/aurora"))
        scene("wings", "top"); float(wings, top: true); run(3.0)
        wings.update(session: running, pending: nil)
        run(2.2)
        // Shelf, then Fresh with a download landing.
        let shelf = DropFilesView(); shelf.willShow()
        scene("shelf", "island"); show(shelf, tab: .shelf, direction: 1); run(2.6)
        UserDefaults.standard.set(true, forKey: "zera.shelf.freshTab")
        FreshFiles.shared.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let fresh = DropFilesView(); fresh.willShow()
        scene("fresh", "island"); show(fresh, tab: .shelf, direction: 1); run(1.4)
        try Data(repeating: 9, count: 1_900_000).write(to: arriving)
        run(2.4)
        UserDefaults.standard.set(false, forKey: "zera.shelf.freshTab")
        // Clipboard.
        let clip = ClipboardView(); clip.willShow()
        scene("clipboard", "island"); show(clip, tab: .clipboard, direction: 1); run(2.6)
        // Tasks: today, then the week.
        scene("tasks", "island"); show(TasksCard(store: today), tab: .tasks, direction: 1); run(2.6)
        UserDefaults.standard.set(1, forKey: "tasks.viewSpan")
        scene("week", "island"); show(TasksCard(store: month), tab: .tasks, direction: 0); run(2.6)
        UserDefaults.standard.set(0, forKey: "tasks.viewSpan")
        // The focus card.
        let focus = FocusCardView(store: today)
        focus.setFrameSize(NSSize(width: focus.frame.width, height: focus.desiredHeight))
        scene("focus", "float"); float(focus); run(2.8)
        // Export: Timesheet, then Excel.
        let export = TaskExportView(store: month)
        export.span = .all
        export.setFrameSize(TaskExportView.size)
        scene("export", "float"); float(export); run(1.8)
        export.format = .xlsx
        run(2.2)
        // Pull requests: the list, Approvals, a PR's page.
        let gh = GitHubCard(); gh.selectTab(0)
        scene("prs", "island"); show(gh, tab: .github, direction: 1); run(2.4)
        scene("approvals", "island"); gh.selectTab(3); show(gh, tab: .github, direction: 0); run(2.2)
        scene("prpage", "island"); gh.openDetail(samplePRs()[0]); show(gh, tab: .github, direction: 0); run(2.6)
        gh.selectTab(0)
        // Reminders, a meeting heads-up, the battery.
        let rem = RemindersView(); rem.willShow()
        scene("reminders", "island"); show(rem, tab: .reminders, direction: 1); run(2.6)
        rs.preview(ReminderAlert(id: "tour-meeting", kind: .calendarHeadsUp, headline: "You have a meeting in 5 minutes",
                                 detail: "Design review · 3:00 PM", eventID: "tour", joinURL: URL(string: "https://meet.example.com/design")))
        scene("meeting", "island"); show(ReminderAlertCard(), tab: .reminders, direction: 0); run(2.6)
        var warned = false, critical = false
        if let low = BatteryAlerts.lowAlert(VitalsSample.Battery(percent: 18, charging: false, onPower: false, toEmpty: 64),
                                            threshold: 20, enabled: true, warned: &warned, warnedCritical: &critical) { rs.preview(low) }
        scene("battery", "island"); show(ReminderAlertCard(), tab: nil, direction: 0); run(2.6)
        // Settings, then every theme.
        let settings = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
        scene("settings", "island"); show(settings, tab: .settings, direction: 1); run(2.2)
        settings.select(.appearance); settings.layoutSubtreeIfNeeded(); show(settings, tab: .settings, direction: 0); run(2.0)
        scene("themes", "island")
        for t in ThemeStore.shared.builtIns {
            ThemeStore.shared.select(t)
            iv.themeChanged()
            show(HomeCard(), tab: .home, direction: 0)
            run(0.75)
        }
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])
        iv.themeChanged()
        // The app opener: a search, then ⌘K.
        let opener = AppOpenerView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        opener.prepare()
        // Searched before it shows, so the list on camera is just Safari, not this Mac's apps.
        opener.previewType("safari")
        scene("opener", "float"); float(opener); run(2.0)
        opener.previewActions(); run(2.8)
        scene("end", "float"); run(0.3)

        group.wait()
        SystemVitals.shared.unwatch()
        w.orderOut(nil)
        try JSONSerialization.data(withJSONObject: times).write(to: out.appendingPathComponent("times.json"))
        try JSONSerialization.data(withJSONObject: scenes).write(to: out.appendingPathComponent("scenes.json"))
        print("full tour: \(times.count) frames, \(String(format: "%.1f", times.last ?? 0)) s")
    }
}
