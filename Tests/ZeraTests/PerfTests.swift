import AppKit
import XCTest
@testable import Zera

/// How long each screen takes to come up, the way a tab press runs it (`willShow`, size, layout,
/// present), with a realistic amount of data. Prints a table; fails nothing.
/// `ZERA_PERF=1 swift test --filter PerfTests` (use a throwaway CFFIXED_USER_HOME).
@MainActor
final class PerfTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["ZERA_PERF"] != nil else { throw XCTSkip("set ZERA_PERF to measure") }
        _ = NSApplication.shared
    }

    private func ms(_ body: () -> Void) -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        body()
        return (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    /// 200 copies: 40 of them full-size screenshots on disk, the rest text, links, code, colours.
    private func fillClipboard() throws {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera/Clipboard/images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var items: [ClipItem] = []
        for i in 0..<200 {
            if i % 5 == 0 {
                let name = "perf-\(i).png"
                let url = folder.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1500, bitsPerSample: 8, samplesPerPixel: 4,
                                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    NSColor(hue: CGFloat(i) / 200, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                    NSRect(x: 0, y: 0, width: 2400, height: 1500).fill()
                    for k in 0..<40 { NSColor(white: CGFloat(k) / 40, alpha: 0.5).setFill(); NSRect(x: k * 60, y: k * 30, width: 300, height: 200).fill() }
                    NSGraphicsContext.restoreGraphicsState()
                    try rep.representation(using: .png, properties: [:])!.write(to: url)
                }
                var it = ClipItem(kind: .image, text: "Screenshot \(i)", bytes: 900_000, sourceApp: "Screenshot", fingerprint: "img\(i)")
                it.imageFile = name
                it.imageSize = CGSize(width: 2400, height: 1500)
                items.append(it)
            } else {
                let kinds: [ClipItem.Kind] = [.text, .link, .code, .color]
                let k = kinds[i % 4]
                let text = k == .color ? "#7AA2F7" : (k == .link ? "https://example.com/item/\(i)" : String(repeating: "Line of copied text \(i) ", count: 20))
                items.append(ClipItem(kind: k, text: text, bytes: text.utf8.count, sourceApp: "Notes", fingerprint: "t\(i)"))
            }
        }
        ClipboardStore.shared.enabled = true
        ClipboardStore.shared.preview(items)
    }

    /// 30 files on the Shelf, 10 of them big photos.
    private func fillShelf() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zera-perf-shelf-items", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4032, pixelsHigh: 3024, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
        for i in 0..<30 {
            let u = dir.appendingPathComponent(i % 3 == 0 ? "photo-\(i).jpg" : (i % 3 == 1 ? "notes-\(i).txt" : "report-\(i).pdf"))
            if !FileManager.default.fileExists(atPath: u.path) {
                try (i % 3 == 0 ? jpeg : Data("Some text for file \(i)".utf8)).write(to: u)
            }
            urls.append(u)
        }
        _ = ShelfStore.shared.add(urls: urls)
    }

    func testScreenTimings() throws {
        try fillClipboard()
        try fillShelf()
        let store = TaskStore(url: nil)
        for i in 0..<60 { store.add("Task number \(i) with a longer title #P\(i % 4) 30m") }

        let screens: [(String, () -> NSView & CardContent, (NSView & CardContent) -> Void)] = [
            ("Home", { HomeCard() }, { ($0 as! HomeCard).refresh() }),
            ("Claude", { ClaudeSessionsView() }, { ($0 as! ClaudeSessionsView).willShow(expanded: false) }),
            ("Shelf", { DropFilesView() }, { ($0 as! DropFilesView).willShow() }),
            ("Clipboard", { ClipboardView() }, { ($0 as! ClipboardView).willShow() }),
            ("Tasks", { TasksCard(store: store) }, { ($0 as! TasksCard).willShow() }),
            ("PRs", { GitHubCard() }, { ($0 as! GitHubCard).reload() }),
            ("Reminders", { RemindersView() }, { ($0 as! RemindersView).willShow() }),
            ("Settings", { SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false) }, { _ in }),
        ]
        let island = IslandView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        var report = "\nscreen      create   first show   tab switch (avg of 5)\n"
        for (name, make, willShow) in screens {
            var card: (NSView & CardContent)!
            let create = ms { card = make() }
            func show() {
                willShow(card)
                card.setFrameSize(NSSize(width: card.cardWidth, height: 400))
                card.needsLayout = true
                card.layoutSubtreeIfNeeded()
                island.present(card, size: NSSize(width: card.cardWidth, height: min(card.desiredHeight, Isle.maxContentHeight)), direction: 1, animated: true)
                island.layoutSubtreeIfNeeded()
                island.display()
            }
            let first = ms(show)
            var again: [Double] = []
            for _ in 0..<5 { again.append(ms(show)) }
            report += String(format: "%-10@ %7.1f   %9.1f   %9.1f ms\n", name as NSString, create, first, again.reduce(0, +) / Double(again.count))
        }
        print(report)
    }

    /// Tapping a shelf picture: how long until it's on the clipboard.
    func testShelfCopyTiming() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zera-perf-shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3024, pixelsHigh: 1964, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = folder.appendingPathComponent("shot.png"), jpg = folder.appendingPathComponent("photo.jpg")
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: jpg)
        let pb = NSPasteboard(name: NSPasteboard.Name("zera-perf"))
        var report = "\nshelf copy        old (encode now)   now (tap)   paste png\n"
        for url in [png, jpg] {
            let old = ms {
                pb.clearContents()
                let item = NSPasteboardItem()
                if let img = NSImage(contentsOf: url), let tiff = img.tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                    if let p = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { item.setData(p, forType: .png) }
                }
                pb.writeObjects([item])
            }
            let now = ms { ShelfCopier.copy(url.path, to: pb) }
            let paste = ms { _ = pb.data(forType: .png) }
            report += String(format: "%-16@ %10.1f   %10.1f   %8.1f ms\n", url.lastPathComponent as NSString, old, now, paste)
        }
        print(report)
        pb.releaseGlobally()
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Switching through every tab many times shouldn't keep growing memory.
    func testRepeatedNavigationMemory() throws {
        try fillClipboard()
        try fillShelf()
        let store = TaskStore(url: nil)
        for i in 0..<30 { store.add("Task \(i) #P\(i % 3)") }
        let cards: [NSView & CardContent] = [HomeCard(), ClaudeSessionsView(), DropFilesView(), ClipboardView(), TasksCard(store: store), GitHubCard(), RemindersView()]
        let island = IslandView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: island.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = island
        func round() {
            for c in cards {
                (c as? ClipboardView)?.willShow(); (c as? DropFilesView)?.willShow(); (c as? TasksCard)?.willShow()
                (c as? HomeCard)?.refresh(); (c as? GitHubCard)?.reload(); (c as? RemindersView)?.willShow()
                (c as? ClaudeSessionsView)?.willShow(expanded: false)
                c.setFrameSize(NSSize(width: c.cardWidth, height: 400))
                c.layoutSubtreeIfNeeded()
                island.present(c, size: NSSize(width: c.cardWidth, height: min(c.desiredHeight, Isle.maxContentHeight)), direction: 1, animated: false)
                island.display()
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            }
        }
        for _ in 0..<10 { round() }
        // Each screen on its own: 150 shows.
        var perScreen: [String] = []
        for c in cards {
            let m0 = footprintMB(), t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<100 { autoreleasepool {
                (c as? ClipboardView)?.willShow(); (c as? DropFilesView)?.willShow(); (c as? TasksCard)?.willShow()
                (c as? HomeCard)?.refresh(); (c as? GitHubCard)?.reload(); (c as? RemindersView)?.willShow()
                (c as? ClaudeSessionsView)?.willShow(expanded: false)
                c.layoutSubtreeIfNeeded()
                island.present(c, size: NSSize(width: c.cardWidth, height: min(c.desiredHeight, Isle.maxContentHeight)), direction: 1, animated: false)
                island.display()
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            } }
            perScreen.append(String(format: "%@ %+.1f MB %.1f ms", String(describing: type(of: c)), footprintMB() - m0, (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 100))
        }
        print("\nper screen (100 shows): " + perScreen.joined(separator: " · "))
        let warm = footprintMB()
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<60 { autoreleasepool { round() } }
        let per = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(60 * cards.count)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let after = footprintMB()
        print("island host views: \(island.subviews.map { $0.subviews.count })")
        print(String(format: "\nnavigation: %.0f MB after warm-up, %.0f MB after 420 more tab switches (%+.1f MB), %.1f ms per switch\n",
                     warm, after, after - warm, per))
    }
}
