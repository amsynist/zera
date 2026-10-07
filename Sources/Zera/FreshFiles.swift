import AppKit

/// What's new in the folders you watch (Downloads and Desktop to start): files added in the last
/// day or so, newest first, so a fresh download can be tapped to copy or dragged straight into
/// Slack, Mail or Finder without opening Finder to find it.
///
/// Only names, sizes and dates are read. Nothing is touched until the Shelf's Fresh tab is
/// first opened (that's when macOS asks for folder access); after that the folders are watched
/// and re-read when they change.
final class FreshFiles {
    static let shared = FreshFiles()
    nonisolated static let changed = Notification.Name("ZeraFreshFilesChanged")

    struct Folder: Codable, Equatable {
        var path: String
        var on: Bool
        var name: String { FileManager.default.displayName(atPath: path) }
        var isDefault: Bool { FreshFiles.defaultFolders.contains { $0.path == path } }
    }

    struct Item: Equatable {
        let path: String
        let name: String
        /// The watched folder it's in ("Downloads").
        let source: String
        let added: Date
        let bytes: Int64
    }

    // MARK: Settings

    private let defaults = UserDefaults.standard
    private enum Key {
        static let enabled = "zera.fresh.enabled"
        static let window = "zera.fresh.window"
        static let folders = "zera.fresh.folders"
    }

    static var defaultFolders: [Folder] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [Folder(path: home.appendingPathComponent("Downloads").path, on: true),
                Folder(path: home.appendingPathComponent("Desktop").path, on: true)]
    }

    /// The Shelf shows a Fresh tab.
    var enabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled); restart() }
    }

    /// How far back "fresh" reaches.
    static let windows: [(String, TimeInterval)] = [("6 h", 6 * 3600), ("24 h", 24 * 3600), ("3 days", 3 * 86400), ("7 days", 7 * 86400)]
    var window: TimeInterval {
        get { defaults.object(forKey: Key.window) as? Double ?? 24 * 3600 }
        set { defaults.set(newValue, forKey: Key.window); rescan() }
    }
    var windowTitle: String { Self.windows.first { $0.1 == window }?.0 ?? "24 h" }

    var folders: [Folder] {
        get {
            guard let d = defaults.data(forKey: Key.folders), let f = try? JSONDecoder().decode([Folder].self, from: d) else { return Self.defaultFolders }
            return f
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { defaults.set(d, forKey: Key.folders) }
            restart()
        }
    }

    func setFolder(_ path: String, on: Bool) {
        folders = folders.map { $0.path == path ? Folder(path: $0.path, on: on) : $0 }
    }
    func addFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !folders.contains(where: { $0.path == path }) else { setFolder(path, on: true); return }
        folders = folders + [Folder(path: path, on: true)]
    }
    func removeFolder(_ path: String) { folders = folders.filter { $0.path != path } }

    // MARK: State

    /// Newest first.
    private(set) var items: [Item] = []
    /// The folders have been read at least once.
    private(set) var started = false
    private(set) var scanning = false
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "ai.zera.fresh", qos: .userInitiated)
    /// Still being written: shown once they're finished.
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]

    /// The first look at the folders, and watching from then on.
    func start() {
        guard !started else { rescan(); return }
        started = true
        restart()
    }

    private func restart() {
        sources.forEach { $0.cancel() }
        sources = []
        guard started else { return }
        guard enabled else { items = []; post(); return }
        for f in folders where f.on {
            let fd = open(f.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleRescan() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
        rescan()
    }

    /// A folder changed: read it again once it settles (a download writes many times).
    private func scheduleRescan() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.rescan() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Reads the watched folders off the main thread and publishes what's new.
    func rescan() {
        guard started, enabled else { return }
        let folders = self.folders.filter(\.on)
        let since = Date().addingTimeInterval(-window)
        scanning = true
        queue.async { [weak self] in
            let found = Self.scan(folders, since: since)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.scanning = false
                if found != self.items { self.items = found; self.post() }
            }
        }
    }

    static func scan(_ folders: [Folder], since: Date) -> [Item] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey,
                                      .totalFileSizeKey, .isHiddenKey, .isDirectoryKey, .isPackageKey]
        var out: [Item] = []
        for f in folders {
            let dir = URL(fileURLWithPath: f.path, isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for u in urls {
                guard !partialExtensions.contains(u.pathExtension.lowercased()),
                      let v = try? u.resourceValues(forKeys: Set(keys)), v.isHidden != true else { continue }
                // When it landed in the folder (a download, a move), else when it was made.
                let added = v.addedToDirectoryDate ?? v.creationDate ?? v.contentModificationDate ?? .distantPast
                guard added >= since else { continue }
                let bytes = Int64(v.totalFileSize ?? v.fileSize ?? 0)
                out.append(Item(path: u.path, name: u.lastPathComponent, source: f.name, added: added, bytes: bytes))
            }
        }
        return Array(out.sorted { $0.added > $1.added }.prefix(200))
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: nil) }
}
