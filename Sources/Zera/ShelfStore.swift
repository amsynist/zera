import AppKit
import UniformTypeIdentifiers

struct ShelfItem: Codable, Equatable {
    let id: UUID
    let path: String
    let addedAt: Date
    /// true when the file lives in our own staging folder (pasted image / text),
    /// meaning we own it and may delete it when the item is removed.
    let staged: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var subtitle: String {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return "missing" }
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue { return "Folder" }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? byteString(size) : "\(ext) · \(byteString(size))"
    }

    static func == (a: ShelfItem, b: ShelfItem) -> Bool { a.id == b.id }
}

/// A file you dropped at some point — the Recent list. It outlives the Shelf entry.
struct RecentFile: Codable, Equatable {
    let path: String
    var addedAt: Date
    /// "Summary", "Explanation", "Extracted text", "Answer" — what Zera last did with it.
    var lastAction: String?
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// One request and its outcome, kept per file so the result panel can show it again later.
/// In memory only: Claude's answers about your documents are never written to disk.
struct FileResultTurn: Equatable {
    let request: FileAction
    var answer: String?
    var failure: String?
}

/// The one source of truth for files in Zera: the Shelf (what you're working with now), the
/// Recent history, and the results per file. Every view observes `changed`.
///
/// Removing a file — from a row, the menu, Clear all or the Drop Bin — only drops Zera's
/// reference. The original file on disk is never touched. (Zera only ever deletes copies it
/// made itself in its staging folder, for pasted images and text, once nothing refers to them.)
final class ShelfStore {
    static let shared = ShelfStore()
    static let changed = Notification.Name("ShelfStoreChanged")

    private(set) var items: [ShelfItem] = []
    private(set) var recent: [RecentFile] = []
    private(set) var threads: [String: [FileResultTurn]] = [:]
    private let recentKey = "zera.recent.v1"
    private let maxRecent = 30
    private let defaultsKey = "zera.items.v1"
    /// ShelfCorner's key — read once so an existing shelf carries over.
    private let legacyDefaultsKey = "shelf.items.v1"

    var stagingDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera/Staged", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private init() { load() }

    // MARK: - Mutation

    @discardableResult
    func add(urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let std = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: std.path) else { continue }
            if items.contains(where: { $0.path == std.path }) { continue }
            items.insert(ShelfItem(id: UUID(), path: std.path, addedAt: Date(),
                                   staged: std.path.hasPrefix(stagingDir.path)), at: 0)
            touchRecent(std.path)
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    /// Removes the Shelf references (never the files themselves) and returns what was removed,
    /// so the caller can offer Undo.
    @discardableResult
    func remove(ids: Set<UUID>) -> [ShelfItem] {
        guard !ids.isEmpty else { return [] }
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        cleanStaged(removed)
        save()
        return removed
    }

    @discardableResult
    func clear() -> [ShelfItem] {
        remove(ids: Set(items.map { $0.id }))
    }

    /// Undo for a removal: puts the references back where they were (newest first).
    func restore(_ restored: [ShelfItem]) {
        let fresh = restored.filter { r in r.exists && !items.contains { $0.path == r.path } }
        guard !fresh.isEmpty else { return }
        items = (fresh + items).sorted { $0.addedAt > $1.addedAt }
        save()
    }

    /// Adds a Recent file back onto the Shelf.
    @discardableResult
    func reshelve(_ r: RecentFile) -> ShelfItem? {
        if let existing = items.first(where: { $0.path == r.path }) { return existing }
        guard r.exists else { return nil }
        let item = ShelfItem(id: UUID(), path: r.path, addedAt: Date(), staged: r.path.hasPrefix(stagingDir.path))
        items.insert(item, at: 0)
        touchRecent(r.path)
        save()
        return item
    }

    // MARK: - Recent

    private func touchRecent(_ path: String) {
        var entry = recent.first { $0.path == path } ?? RecentFile(path: path, addedAt: Date(), lastAction: nil)
        entry.addedAt = Date()
        recent.removeAll { $0.path == path }
        recent.insert(entry, at: 0)
        if recent.count > maxRecent { recent.removeLast(recent.count - maxRecent) }
    }

    func setLastAction(_ title: String, for path: String) {
        guard let i = recent.firstIndex(where: { $0.path == path }) else { return }
        recent[i].lastAction = title
        save()
    }

    func removeRecent(path: String) {
        recent.removeAll { $0.path == path }
        threads.removeValue(forKey: path)
        cleanStaged([])
        save()
    }

    func clearRecent() {
        let onShelf = Set(items.map { $0.path })
        recent.removeAll { !onShelf.contains($0.path) }
        threads = threads.filter { onShelf.contains($0.key) }
        cleanStaged([])
        save()
    }

    /// Zera's own staged copies that nothing refers to any more.
    private func cleanStaged(_ candidates: [ShelfItem]) {
        let referenced = Set(items.map { $0.path }).union(recent.map { $0.path })
        let stage = stagingDir.path
        var paths = Set(candidates.filter { $0.staged }.map { $0.path })
        if let names = try? FileManager.default.contentsOfDirectory(atPath: stage) {
            for n in names { paths.insert((stage as NSString).appendingPathComponent(n)) }
        }
        for path in paths where path.hasPrefix(stage) && !referenced.contains(path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Results (memory only)

    func thread(for path: String) -> [FileResultTurn] { threads[path] ?? [] }

    func saveThread(_ turns: [FileResultTurn], for path: String) {
        guard threads[path] != turns else { return }
        threads[path] = turns
        NotificationCenter.default.post(name: ShelfStore.changed, object: nil)
    }

    // MARK: - Persistence

    private func load() {
        let data = UserDefaults.standard.data(forKey: defaultsKey)
            ?? UserDefaults.standard.data(forKey: legacyDefaultsKey)
        guard let data = data,
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = decoded.filter { $0.exists }
        if let r = UserDefaults.standard.data(forKey: recentKey), let rs = try? JSONDecoder().decode([RecentFile].self, from: r) {
            recent = rs
        }
        // Older shelves had no history: seed it with what's on the shelf.
        for item in items.reversed() where !recent.contains(where: { $0.path == item.path }) {
            recent.insert(RecentFile(path: item.path, addedAt: item.addedAt, lastAction: nil), at: 0)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: recentKey)
        }
        NSApp.dockTile.badgeLabel = items.isEmpty ? nil : String(items.count)
        NotificationCenter.default.post(name: ShelfStore.changed, object: nil)
    }

    // MARK: - Pasteboard ingestion

    /// Pulls everything usable out of a pasteboard. Real files are referenced in place;
    /// raw content (images, text, snippets) is written into the staging folder.
    func ingest(pasteboard pb: NSPasteboard) -> Int {
        if let objs = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !objs.isEmpty {
            return add(urls: objs)
        }
        var staged: [URL] = []
        let stamp = Self.stampFormatter.string(from: Date())

        if let data = pb.data(forType: .png) {
            staged.append(write(data, "Image \(stamp).png"))
        } else if let data = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: data),
                  let png = rep.representation(using: .png, properties: [:]) {
            staged.append(write(png, "Image \(stamp).png"))
        } else if let data = pb.data(forType: .pdf) {
            staged.append(write(data, "Document \(stamp).pdf"))
        } else if let data = pb.data(forType: .rtf) {
            staged.append(write(data, "Note \(stamp).rtf"))
        } else if let str = pb.string(forType: .string), !str.isEmpty {
            if let u = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines)),
               let scheme = u.scheme, scheme == "http" || scheme == "https" {
                staged.append(writeWebloc(u, "\(u.host ?? "Link") \(stamp).webloc"))
            } else {
                staged.append(write(Data(str.utf8), "Note \(stamp).txt"))
            }
        }
        return add(urls: staged)
    }

    /// True when the pasteboard holds only files the shelf already has. Lets a repeat drop
    /// be accepted quietly instead of bouncing back as if the drop had missed.
    func alreadyHas(pasteboard pb: NSPasteboard) -> Bool {
        guard let urls = pb.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let known = Set(items.map { $0.path })
        return urls.allSatisfy { known.contains($0.standardizedFileURL.path) }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    private func write(_ data: Data, _ name: String) -> URL {
        let url = uniqueURL(for: name)
        try? data.write(to: url)
        return url
    }

    private func writeWebloc(_ link: URL, _ name: String) -> URL {
        let url = uniqueURL(for: name)
        let plist: [String: Any] = ["URL": link.absoluteString]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: url)
        }
        return url
    }

    private func uniqueURL(for name: String) -> URL {
        var candidate = stagingDir.appendingPathComponent(name)
        var n = 2
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = stagingDir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
