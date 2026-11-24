import AppKit
import ImageIO

// MARK: - Wallpapers (the launcher's ">wallpaper" command)
//
// Everything here is local: pictures are read from folders on this Mac, previews are drawn in
// Zera's own windows, and macOS is only asked to change the desktop picture when you press ⏎.

/// A picture the launcher can set as the desktop.
struct WallpaperEntry: Equatable {
    let url: URL
    /// The file name without its extension ("city-horizon").
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum WallpaperLibrary {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp"]
    /// Enough for a strip you move through with the arrow keys.
    static let limit = 400

    private static let foldersKey = "launcher.wallpaperFolders"
    /// Folders you added (Settings › General, or ">folders" in the launcher). While there are
    /// any, the strip shows pictures from these only; with none it falls back to the defaults.
    static var folders: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: foldersKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set {
            var seen = Set<String>()
            let paths = newValue.map(\.standardizedFileURL.path).filter { seen.insert($0).inserted }
            if paths.isEmpty { UserDefaults.standard.removeObject(forKey: foldersKey) }
            else { UserDefaults.standard.set(paths, forKey: foldersKey) }
        }
    }
    static func addFolders(_ urls: [URL]) { folders += urls }
    static func resetFolders() { folders = [] }

    /// The default place for your own pictures.
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Wallpapers", isDirectory: true)
    }
    /// The pictures that come with macOS, after yours (defaults only).
    static let systemFolders = [URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
                                URL(fileURLWithPath: "/Library/Desktop Pictures", isDirectory: true)]

    /// "~/Walls, ~/Pictures/Anime" or the defaults, in words, for Settings and the empty note.
    static var sourceSummary: String {
        let chosen = folders
        guard !chosen.isEmpty else { return "\(tilde(defaultFolder)), then the pictures that come with macOS" }
        return "only " + chosen.map(tilde).joined(separator: ", ")
    }
    static func tilde(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    /// Asks which folders to use (one or several) and adds them. From Settings the picker is a
    /// sheet on the island's own window (`owner`), so the island neither folds away under it nor
    /// sits on top of it; from the launcher, which has already gone, it stands on its own.
    static func chooseFolders(owner: NSWindow? = nil, done: @escaping (_ added: Int) -> Void) {
        if let owner, owner.attachedSheet != nil { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Use for Wallpapers"
        panel.message = "The launcher's >wallpaper will show pictures from the folders you add, and only those."
        let finish: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, !panel.urls.isEmpty else { done(0); return }
            let before = folders.count
            addFolders(panel.urls)
            done(folders.count - before)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let owner {
            panel.beginSheetModal(for: owner, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// The pictures the strip shows, each folder's by name. With folders added: those folders
    /// only (subfolders included). With none: `~/Pictures/Wallpapers`, then the system's own.
    /// Reads directories only; call off the main thread.
    static func scan(chosen: [URL] = folders, user: URL = defaultFolder, system: [URL] = systemFolders) -> [WallpaperEntry] {
        var seen = Set<String>()
        var out: [WallpaperEntry] = []
        let sources: [(URL, Bool)] = chosen.isEmpty ? [(user, true)] + system.map { ($0, false) } : chosen.map { ($0, true) }
        for (folder, deep) in sources {
            let found = pictures(in: folder, deep: deep).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for entry in found where seen.insert(entry.url.standardizedFileURL.path).inserted {
                out.append(entry)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    static func pictures(in folder: URL, deep: Bool) -> [WallpaperEntry] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !deep { options.insert(.skipsSubdirectoryDescendants) }
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: options) else { return [] }
        var out: [WallpaperEntry] = []
        for case let url as URL in walk where extensions.contains(url.pathExtension.lowercased()) {
            out.append(WallpaperEntry(url: url))
            if out.count >= limit { break }
        }
        return out
    }

    /// Names that match what was typed after ">wallpaper ", best first; everything when empty.
    static func filter(_ all: [WallpaperEntry], _ query: String) -> [WallpaperEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.compactMap { e in AppMatcher.match(e.name, q).map { (e, $0.score) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: Pictures

    private static let thumbs: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 160
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()
    private static let work = DispatchQueue(label: "zera.wallpapers", qos: .userInitiated, attributes: .concurrent)

    /// A downsampled copy, decoded off the main thread (never the whole 6K picture).
    static func downsampled(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxPixel))]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func cachedThumbnail(_ url: URL) -> NSImage? { thumbs.object(forKey: url.path as NSString) }

    /// The strip's thumbnail; `done` runs on the main thread (at once when it is cached).
    static func thumbnail(_ url: URL, done: @escaping (NSImage?) -> Void) {
        if let hit = cachedThumbnail(url) { done(hit); return }
        work.async {
            let image = downsampled(url, maxPixel: 480).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            DispatchQueue.main.async {
                if let image { thumbs.setObject(image, forKey: url.path as NSString, cost: Int(image.size.width * image.size.height * 4)) }
                done(image)
            }
        }
    }

    // MARK: The desktop

    /// The picture on the main screen right now, to start the strip on.
    static var current: URL? {
        (NSScreen.main ?? NSScreen.screens.first).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    /// Sets the picture on every screen (their current Space), keeping each one's fill options.
    /// Returns false when macOS refused it for any screen.
    @discardableResult
    static func apply(_ url: URL) -> Bool {
        var ok = true
        for screen in NSScreen.screens {
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options) } catch { ok = false }
        }
        if ok { WallpaperTint.shared.refresh(force: true) }
        return ok
    }
}

/// The live preview while you move through the strip: the picture, full screen, in a window just
/// above the real desktop picture and below the desktop's icons and every app. The real
/// wallpaper is untouched until ⏎; Esc simply takes these windows away again.
final class WallpaperPreview {
    static let shared = WallpaperPreview()
    private var windows: [NSWindow] = []
    private var request = 0
    private var hideWork: DispatchWorkItem?
    private init() {}

    var isShowing: Bool { !windows.isEmpty }

    func show(_ url: URL) {
        hideWork?.cancel(); hideWork = nil
        request += 1
        let id = request
        let screens = NSScreen.screens
        let pixels = screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2560
        DispatchQueue.global(qos: .userInitiated).async {
            let image = WallpaperLibrary.downsampled(url, maxPixel: pixels)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == id, let image else { return }
                self.present(image, on: screens)
            }
        }
    }

    private func present(_ image: CGImage, on screens: [NSScreen]) {
        if windows.count != screens.count {
            windows.forEach { $0.orderOut(nil) }
            windows = screens.map { Self.makeWindow(for: $0) }
        }
        for (window, screen) in zip(windows, screens) {
            if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
            guard let layer = window.contentView?.layer else { continue }
            if !Motion.reduced {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.28
                layer.add(fade, forKey: "contents")
            }
            layer.contents = image
            if !window.isVisible {
                window.alphaValue = 0
                window.orderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.duration(0.22)
                    window.animator().alphaValue = 1
                }
            }
        }
    }

    /// Takes the preview away. After a real change, `settle` leaves it up for a moment so the
    /// desktop underneath has swapped before it fades.
    func end(settle: Bool = false) {
        request += 1
        hideWork?.cancel()
        guard !windows.isEmpty else { return }
        let closing = windows
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.duration(0.25)
                closing.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: {
                closing.forEach { $0.orderOut(nil); $0.contentView?.layer?.contents = nil }
            })
            self.windows.removeAll { w in closing.contains { $0 === w } }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (settle ? 0.7 : 0), execute: work)
    }

    private static func makeWindow(for screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        // One step above the desktop picture: under the desktop's icons, widgets and all apps.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.hasShadow = false
        w.backgroundColor = .black
        w.animationBehavior = .none
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.masksToBounds = true
        w.contentView = view
        return w
    }
}
