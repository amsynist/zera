import AppKit
import XCTest
@testable import Zera

final class LauncherTests: XCTestCase {
    func testFieldTextDecidesWhatTheListShows() {
        XCTAssertEqual(LauncherCommands.parse(""), .apps(""))
        XCTAssertEqual(LauncherCommands.parse(" saf "), .apps("saf"))
        XCTAssertEqual(LauncherCommands.parse(">"), .commands(""))
        XCTAssertEqual(LauncherCommands.parse(">wa"), .commands("wa"))
        // The command alone is still a row to choose; the space after it opens its list.
        XCTAssertEqual(LauncherCommands.parse(">wallpaper"), .commands("wallpaper"))
        XCTAssertEqual(LauncherCommands.parse(">wallpaper "), .list(key: "wallpaper", filter: ""))
        XCTAssertEqual(LauncherCommands.parse("> Wallpaper city "), .list(key: "wallpaper", filter: "city"))
        XCTAssertEqual(LauncherCommands.parse(">theme nord"), .list(key: "theme", filter: "nord"))
        // A command without a list never swallows what follows it.
        XCTAssertEqual(LauncherCommands.parse(">sleep now"), .commands("sleep now"))
    }

    func testCommandsListLeadsWithWallpaperAndMatchesByNameOrKey() {
        XCTAssertEqual(LauncherCommands.matches("").map(\.command.title).prefix(5), ["Wallpaper", "Wallpaper Folders", "Theme", "Lock", "Sleep"])
        XCTAssertEqual(LauncherCommands.matches("wallpaper").first?.command.key, "wallpaper")
        XCTAssertEqual(LauncherCommands.matches("fold").first?.command.key, "folders")
        XCTAssertEqual(LauncherCommands.matches("wa").first?.command.key, "wallpaper")
        XCTAssertEqual(LauncherCommands.matches("port").first?.command.key, "port")
        XCTAssertEqual(LauncherCommands.matches("kill").first?.command.key, "kill")
        XCTAssertTrue(LauncherCommands.matches("zzzz").isEmpty)
        XCTAssertEqual(Set(LauncherCommands.all.map(\.key)).count, LauncherCommands.all.count)
        XCTAssertTrue(LauncherCommands.all.contains { if case .action = $0.kind { return true }; return false })
    }

    func testLauncherIsTheDefaultLookOnce() {
        let d = UserDefaults.standard
        let saved = (d.object(forKey: "appOpener.style"), d.object(forKey: "appOpener.launcherDefault"))
        defer { d.set(saved.0, forKey: "appOpener.style"); d.set(saved.1, forKey: "appOpener.launcherDefault") }
        // An earlier choice made before the launcher existed gives way to it once…
        d.set(AppOpenerSettings.Style.minimal.rawValue, forKey: "appOpener.style")
        d.removeObject(forKey: "appOpener.launcherDefault")
        XCTAssertEqual(AppOpenerSettings.style, .launcher)
        // …and a look picked afterwards stays.
        AppOpenerSettings.style = .tree
        XCTAssertEqual(AppOpenerSettings.style, .tree)
        d.removeObject(forKey: "appOpener.style")
        XCTAssertEqual(AppOpenerSettings.style, .launcher)
    }

    @MainActor
    func testTypingAngleBracketSwapsAppsForCommands() {
        _ = NSApplication.shared
        let view = LauncherOpenerView(frame: NSRect(origin: .zero, size: LauncherOpenerView.panelSize(available: NSSize(width: 1440, height: 900))))
        view.prepare()
        view.previewType(">")
        XCTAssertEqual(view.visibleTitles.first, "Wallpaper")
        XCTAssertEqual(view.selectedTitle, "Wallpaper")
        view.previewMove(1)
        XCTAssertEqual(view.selectedTitle, "Wallpaper Folders")
        view.previewMove(1)
        XCTAssertEqual(view.selectedTitle, "Theme")
        view.previewType(">the")
        XCTAssertEqual(view.visibleTitles.first, "Theme")
        view.previewType(">theme ")
        XCTAssertEqual(view.visibleTitles, ThemeStore.shared.all.map(\.name))
        view.previewType(">nothing-like-this")
        XCTAssertEqual(view.visibleTitles.count, 1)
        XCTAssertNil(view.selectedTitle.flatMap { $0 == "Wallpaper" ? $0 : nil })
    }

    @MainActor
    func testWallpaperCommandPreviewsWhileBrowsingAndOnlySetsOnReturn() {
        _ = NSApplication.shared
        let view = LauncherOpenerView(frame: NSRect(origin: .zero, size: LauncherOpenerView.panelSize(available: NSSize(width: 1440, height: 900))))
        let pictures = ["dawn", "harbour", "violet"].map { WallpaperEntry(url: URL(fileURLWithPath: "/tmp/zera-test-wallpapers/\($0).jpg")) }
        var previews: [URL] = [], applied: [URL] = [], ended: [Bool] = [], finished = 0
        view.wallpaperSource = { pictures }
        view.currentWallpaper = { pictures[1].url }
        view.previewWallpaper = { previews.append($0) }
        view.applyWallpaper = { applied.append($0); return true }
        view.endWallpaperPreview = { ended.append($0) }
        view.onFinish = { _ in finished += 1 }
        view.prepare()
        let listWidth = view.cardSize.width

        // ⏎ on the Wallpaper row writes the command into the field and opens its strip.
        view.previewType(">wall")
        view.previewActivate()
        XCTAssertEqual(view.searchField.stringValue, ">wallpaper ")
        let until = Date().addingTimeInterval(3)
        while !view.isShowingWallpapers, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(view.isShowingWallpapers)
        XCTAssertGreaterThan(view.cardSize.width, listWidth)
        // It starts on the picture already on the desktop, and shows nothing new yet.
        XCTAssertEqual(view.selectedTitle, "harbour")
        XCTAssertTrue(previews.isEmpty)

        view.previewMove(1)
        XCTAssertEqual(view.selectedTitle, "violet")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(previews, [pictures[2].url])
        XCTAssertTrue(applied.isEmpty, "browsing must never change the real desktop")

        view.previewActivate()
        XCTAssertEqual(applied, [pictures[2].url])
        XCTAssertEqual(ended, [true])
        XCTAssertEqual(finished, 1)
    }

    @MainActor
    func testLeavingTheStripPutsTheDesktopBack() {
        _ = NSApplication.shared
        let view = LauncherOpenerView(frame: NSRect(origin: .zero, size: LauncherOpenerView.panelSize(available: NSSize(width: 1440, height: 900))))
        let pictures = ["a", "b"].map { WallpaperEntry(url: URL(fileURLWithPath: "/tmp/zera-test-wallpapers/\($0).png")) }
        var applied = 0, ended: [Bool] = []
        view.wallpaperSource = { pictures }
        view.currentWallpaper = { nil }
        view.previewWallpaper = { _ in }
        view.applyWallpaper = { _ in applied += 1; return true }
        view.endWallpaperPreview = { ended.append($0) }
        view.prepare()
        view.previewType(">wallpaper ")
        let until = Date().addingTimeInterval(3)
        while !view.isShowingWallpapers, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        view.previewMove(1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.animateOut {}
        XCTAssertFalse(view.isShowingWallpapers)
        XCTAssertEqual(ended, [false])
        XCTAssertEqual(applied, 0)
    }

    func testWallpaperLibraryFindsPicturesOnlyAndFiltersByName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zera-wall-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("anime", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["violet.jpg", "city-horizon.PNG", "notes.txt", ".hidden.jpg"] {
            try Data([0]).write(to: root.appendingPathComponent(name))
        }
        try Data([0]).write(to: nested.appendingPathComponent("room.heic"))
        let found = WallpaperLibrary.scan(chosen: [], user: root, system: [])
        XCTAssertEqual(found.map(\.name), ["city-horizon", "room", "violet"])
        XCTAssertEqual(WallpaperLibrary.filter(found, "vio").map(\.name), ["violet"])
        XCTAssertEqual(WallpaperLibrary.filter(found, "").count, 3)
        XCTAssertTrue(WallpaperLibrary.filter(found, "zzz").isEmpty)
    }

    func testAddedFoldersAreTheOnlySource() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("zera-wall-\(UUID().uuidString)", isDirectory: true)
        let mine = base.appendingPathComponent("mine", isDirectory: true)
        let other = base.appendingPathComponent("other", isDirectory: true)
        let usual = base.appendingPathComponent("usual", isDirectory: true)
        let system = base.appendingPathComponent("system", isDirectory: true)
        for folder in [mine, other, usual, system] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        try Data([0]).write(to: mine.appendingPathComponent("b-mine.jpg"))
        try Data([0]).write(to: other.appendingPathComponent("a-other.png"))
        try Data([0]).write(to: usual.appendingPathComponent("usual.jpg"))
        try Data([0]).write(to: system.appendingPathComponent("system.heic"))
        // Nothing added: the usual folder, then the system's.
        XCTAssertEqual(WallpaperLibrary.scan(chosen: [], user: usual, system: [system]).map(\.name), ["usual", "system"])
        // Folders added: those only, in the order they were added.
        XCTAssertEqual(WallpaperLibrary.scan(chosen: [mine, other], user: usual, system: [system]).map(\.name), ["b-mine", "a-other"])

        let d = UserDefaults.standard
        let saved = d.object(forKey: "launcher.wallpaperFolders")
        defer { d.set(saved, forKey: "launcher.wallpaperFolders") }
        WallpaperLibrary.resetFolders()
        XCTAssertTrue(WallpaperLibrary.folders.isEmpty)
        WallpaperLibrary.addFolders([mine, mine, other])
        XCTAssertEqual(WallpaperLibrary.folders.map(\.lastPathComponent), ["mine", "other"])
        XCTAssertTrue(WallpaperLibrary.sourceSummary.hasPrefix("only "))
        WallpaperLibrary.resetFolders()
        XCTAssertTrue(WallpaperLibrary.folders.isEmpty)
    }
}
