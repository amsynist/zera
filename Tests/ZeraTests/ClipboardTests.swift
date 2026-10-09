import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Zera

/// Pure parts of clipboard history only: these never touch the real clipboard or the history file.
final class ClipboardTests: XCTestCase {
    @MainActor
    func testSwitchingImageGridAndListReleasesTheInactiveViews() throws {
        _ = NSApplication.shared
        let store = ClipboardStore.shared
        let saved = store.items
        let enabled = store.enabled
        defer { store.preview(saved); store.enabled = enabled }
        store.enabled = true
        let images = (0..<2).map { i -> ClipItem in
            var item = ClipItem(kind: .image, text: "Image \(i)", fingerprint: "grid-\(i)")
            item.imageFile = "missing-test-image-\(i).png"
            return item
        }
        store.preview(images + [ClipItem(kind: .text, text: "A note", fingerprint: "note")])
        let view = autoreleasepool { ClipboardView() }
        view.frame = NSRect(x: 0, y: 0, width: 880, height: 640)
        view.willShow()
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        let filters = try XCTUnwrap(descendants(view).compactMap { $0 as? GitHubSegmentedControl }.first)
        weak var oldRow: ClipRow?
        autoreleasepool {
            oldRow = descendants(view).compactMap { $0 as? ClipRow }.first
            filters.onSelect?(ClipboardStore.Filter.images.rawValue)
        }
        XCTAssertNil(oldRow?.superview, "the inactive list must detach its rows")
        XCTAssertEqual(descendants(view).compactMap { $0 as? ClipThumb }.count, 2)
        weak var oldThumb: ClipThumb?
        autoreleasepool { oldThumb = descendants(view).compactMap { $0 as? ClipThumb }.first }
        for _ in 0..<10 { autoreleasepool {
            filters.onSelect?(ClipboardStore.Filter.all.rawValue)
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(descendants(view).compactMap { $0 as? ClipThumb }.isEmpty)
            XCTAssertEqual(descendants(view).compactMap { $0 as? ClipRow }.count, 3)
            filters.onSelect?(ClipboardStore.Filter.images.rawValue)
        } }
        XCTAssertNil(oldThumb, "the inactive image grid must release its layers")
    }

    func testSmallIconsKeepOnlyOneBoundedRetinaBitmap() throws {
        let source = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let icon = source.rasterizedIcon(size: 64)
        let bitmap = try XCTUnwrap(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(icon.representations.count, 1)
        XCTAssertEqual(bitmap.width, 128)
        XCTAssertEqual(bitmap.height, 128)
        XCTAssertEqual(bitmap.bitsPerComponent, 8)
        XCTAssertEqual(icon.size, NSSize(width: 64, height: 64))
    }

    func testLinksAreRecognised() {
        XCTAssertEqual(ClipboardStore.classify("https://github.com/aurora-app/aurora/pull/412"), .link)
        XCTAssertEqual(ClipboardStore.classify("  http://example.com  "), .link)
        XCTAssertEqual(ClipboardStore.classify("mailto:hello@example.com"), .link)
        XCTAssertEqual(ClipboardStore.classify("see https://example.com for more"), .text)
        XCTAssertEqual(ClipboardStore.classify("example.com"), .text)
    }

    func testColoursAreRecognised() {
        XCTAssertEqual(ClipboardStore.classify("#4DBDFF"), .color)
        XCTAssertEqual(ClipboardStore.classify("#abc"), .color)
        XCTAssertEqual(ClipboardStore.classify("rgb(77, 189, 255)"), .color)
        XCTAssertEqual(ClipboardStore.classify("4dbdff"), .color)
        XCTAssertEqual(ClipboardStore.classify("decade"), .text, "six letters with no digits is a word, not a colour")
        XCTAssertEqual(ClipboardStore.classify("123456"), .text, "six digits is a number, not a colour")
    }

    func testCodeIsRecognised() {
        XCTAssertEqual(ClipboardStore.classify("git rebase -i HEAD~3"), .code)
        XCTAssertEqual(ClipboardStore.classify("npm run build && npm test"), .code)
        XCTAssertEqual(ClipboardStore.classify("func hello() {\n    print(\"hi\")\n}"), .code)
        XCTAssertEqual(ClipboardStore.classify("const x = () => 1;"), .code)
        XCTAssertEqual(ClipboardStore.classify("Meeting moved to 4:30, same link as before"), .text)
        XCTAssertEqual(ClipboardStore.classify("Let me know if that works for you."), .text)
    }

    func testSwatchColoursParse() throws {
        let c = try XCTUnwrap(ClipRow.color("#4DBDFF")?.usingColorSpace(.sRGB))
        XCTAssertEqual(c.redComponent, 77 / 255, accuracy: 0.002)
        XCTAssertEqual(c.greenComponent, 189 / 255, accuracy: 0.002)
        XCTAssertEqual(c.blueComponent, 1, accuracy: 0.002)
        XCTAssertNotNil(ClipRow.color("#abc"))
        XCTAssertNotNil(ClipRow.color("rgb(10, 20, 30)"))
        XCTAssertNil(ClipRow.color("not a colour"))
    }

    func testTitlesStayOnOneLine() {
        let multi = ClipItem(kind: .code, text: "line one\nline two", fingerprint: "x")
        XCTAssertFalse(multi.title.contains("\n"))
        let files = ClipItem(kind: .files, text: "", paths: ["/tmp/a.pdf", "/tmp/b.png", "/tmp/c.md"], fingerprint: "y")
        XCTAssertEqual(files.title, "a.pdf and 2 more")
        XCTAssertEqual(files.filterGroup, .files)
        let image = ClipItem(kind: .image, text: "", imageSize: CGSize(width: 1440, height: 900), fingerprint: "z")
        XCTAssertEqual(image.title, "Image 1440 × 900")
        XCTAssertEqual(ClipItem(kind: .link, text: "https://a.b", fingerprint: "l").filterGroup, .text)
    }

    func testShortcutLabelsAndRules() {
        XCTAssertEqual(HotKeyShortcut.default.label, "⇧⌘V")
        let all = HotKeyShortcut(keyCode: 49, modifiers: UInt32(cmdKey | optionKey | shiftKey | controlKey), key: "Space")
        XCTAssertEqual(all.label, "⌃⌥⇧⌘Space")
        XCTAssertTrue(all.isUsable)
        XCTAssertFalse(HotKeyShortcut(keyCode: 9, modifiers: UInt32(shiftKey), key: "V").isUsable, "Shift alone would eat typing")
        XCTAssertFalse(HotKeyShortcut(keyCode: 9, modifiers: 0, key: "V").isUsable)
        XCTAssertEqual(HotKeyShortcut.carbonModifiers([.command, .option]), UInt32(cmdKey | optionKey))
        XCTAssertEqual(HotKeyShortcut.keyName(keyCode: UInt16(kVK_F5), characters: nil), "F5")
        XCTAssertEqual(HotKeyShortcut.keyName(keyCode: UInt16(kVK_ANSI_K), characters: "k"), "K")
        let data = try! JSONEncoder().encode(all)
        XCTAssertEqual(try! JSONDecoder().decode(HotKeyShortcut.self, from: data), all)
    }

    func testClipboardHasATabAndAPose() {
        XCTAssertTrue(Isle.leftTabs.contains(.clipboard))
        XCTAssertEqual(Isle.pose(for: .clipboard), "hang_upsidedown")
        XCTAssertEqual(Isle.tab(for: .clipboard), .clipboard)
    }
}
