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
        if recent.count > maxRecent {
            // A file that drops off Recent takes Claude's answers about it with it.
            for gone in recent[maxRecent...] { threads.removeValue(forKey: gone.path) }
            recent.removeLast(recent.count - maxRecent)
        }
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
        // Files that are not there right now stay listed as "missing": a disk or share that is
        // not mounted at launch is not a reason to forget what was on the Shelf.
        items = decoded
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

    /// What a drop or paste carries, read straight away (a drag's pasteboard doesn't outlive
    /// the drop). Real files are referenced in place; raw content becomes a file in staging.
    enum Payload {
        case files([URL])
        case png(Data), tiff(Data), pdf(Data), rtf(Data), link(URL), text(String)
    }

    /// Cheap: copies the bytes out, converts and writes nothing.
    static func payload(from pb: NSPasteboard) -> Payload? {
        if let objs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !objs.isEmpty {
            return .files(objs)
        }
        if let d = pb.data(forType: .png) { return .png(d) }
        if let d = pb.data(forType: .tiff) { return .tiff(d) }
        if let d = pb.data(forType: .pdf) { return .pdf(d) }
        if let d = pb.data(forType: .rtf) { return .rtf(d) }
        if let str = pb.string(forType: .string), !str.isEmpty {
            if let u = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme, scheme == "http" || scheme == "https" {
                return .link(u)
            }
            return .text(str)
        }
        return nil
    }

    /// Pulls everything usable out of a pasteboard, right now.
    func ingest(pasteboard pb: NSPasteboard) -> Int {
        guard let p = Self.payload(from: pb) else { return 0 }
        if case .files(let urls) = p { return add(urls: urls) }
        return add(urls: stage(p))
    }

    /// The same, without holding up the screen: files are added at once (and `done` runs before
    /// this returns); pictures, PDFs and text are converted and written off the main thread,
    /// then added. `done` gets how many were added, on the main thread.
    func ingest(_ p: Payload, done: @escaping (Int) -> Void) {
        if case .files(let urls) = p { done(add(urls: urls)); return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let urls = stage(p)
            DispatchQueue.main.async { done(self.add(urls: urls)) }
        }
    }

    /// Writes raw content into the staging folder (any thread).
    private func stage(_ p: Payload) -> [URL] {
        let stamp = Self.stampFormatter.string(from: Date())
        switch p {
        case .files(let urls): return urls
        case .png(let d): return [write(d, "Image \(stamp).png")]
        case .tiff(let d):
            guard let png = NSBitmapImageRep(data: d)?.representation(using: .png, properties: [:]) else { return [] }
            return [write(png, "Image \(stamp).png")]
        case .pdf(let d): return [write(d, "Document \(stamp).pdf")]
        case .rtf(let d): return [write(d, "Note \(stamp).rtf")]
        case .link(let u): return [writeWebloc(u, "\(u.host ?? "Link") \(stamp).webloc")]
        case .text(let s): return [write(Data(s.utf8), "Note \(stamp).txt")]
        }
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

    // DateFormatter is safe to use from several threads (macOS 10.9+).
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

// MARK: - Copying a shelf item

/// Puts a shelf item on the clipboard in the form that pastes best where you're going:
/// a picture as the image itself (and the file, for Finder), a note as its text, a link as its
/// URL, anything else as the file (so Slack, Mail and Finder attach it).
enum ShelfCopier {
    enum Copied: Equatable {
        case file, image, text, link
        /// "the file", for "Copied the file ✓".
        var phrase: String {
            switch self {
            case .file: return "the file"
            case .image: return "the image"
            case .text: return "its text"
            case .link: return "the link"
            }
        }
    }

    /// Notes up to this size paste as text; bigger text files paste as the file.
    static let maxTextBytes = 256 * 1024

    /// What copying `path` would put on the clipboard; nil when the file is gone.
    static func plan(for path: String) -> Copied? { resolve(path)?.how }

    /// The plan, plus the note's text when it pastes as text (read once, for plan and copy both).
    private static func resolve(_ path: String) -> (how: Copied, text: String?)? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        switch ShelfKind(path: path) {
        case .image: return (.image, nil)
        case .link: return (linkURL(path) == nil ? .file : .link, nil)
        case .text:
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? Int.max
            if size <= maxTextBytes, let t = text(path) { return (.text, t) }
            return (.file, nil)
        default: return (.file, nil)
        }
    }

    /// Copies `path` onto `pasteboard` and says how; nil (and nothing changed) when it's gone.
    /// Instant whatever the size: a picture's pixels are only produced if an app pastes them.
    @discardableResult
    static func copy(_ path: String, to pasteboard: NSPasteboard = .general) -> Copied? {
        guard let (how, noteText) = resolve(path) else { return nil }
        let fileURL = URL(fileURLWithPath: path)
        pasteboard.clearContents()
        switch how {
        case .image:
            // One item carrying both: apps that take pictures paste the image, Finder the file.
            // The image data is promised, not made: a PNG goes over as its own bytes, anything
            // else is converted only when it's asked for.
            let item = NSPasteboardItem()
            item.setString(fileURL.absoluteString, forType: .fileURL)
            let provider = ShelfImageProvider(url: fileURL)
            var types: [NSPasteboard.PasteboardType] = [.png, .tiff]
            // Its own format too (JPEG, HEIC…): apps that take it paste the file's bytes as they are.
            if let own = UTType(filenameExtension: fileURL.pathExtension), own.conforms(to: .image), own != .png, own != .tiff {
                types.insert(NSPasteboard.PasteboardType(own.identifier), at: 0)
            }
            item.setDataProvider(provider, forTypes: types)
            ShelfImageProvider.current = provider
            pasteboard.writeObjects([item])
        case .text:
            pasteboard.setString(noteText ?? "", forType: .string)
        case .link:
            let u = linkURL(path)!
            pasteboard.writeObjects([u as NSURL])
            pasteboard.setString(u.absoluteString, forType: .string)
        case .file:
            pasteboard.writeObjects([fileURL as NSURL])
        }
        return how
    }

    /// A note's text (UTF-8, or whatever Foundation can read it as).
    static func text(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var used = String.Encoding.utf8
        return try? String(contentsOf: url, usedEncoding: &used)
    }

    /// The address inside a .webloc (a property list) or a .url (an INI file).
    static func linkURL(_ path: String) -> URL? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let s = plist["URL"] as? String, let u = URL(string: s) {
            return u
        }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("url=") {
            if let u = URL(string: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)) { return u }
        }
        return nil
    }
}

/// Hands a shelf picture to whichever app pastes it, in the form it asks for, at that moment.
final class ShelfImageProvider: NSObject, NSPasteboardItemDataProvider {
    /// The pasteboard doesn't keep its provider alive; the latest copy's is kept here until replaced.
    static var current: ShelfImageProvider?
    let url: URL
    init(url: URL) { self.url = url }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let data = Self.data(url, as: type) { item.setData(data, forType: type) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        if Self.current === self { Self.current = nil }
    }

    /// The file's own bytes when it's already in the asked-for format; otherwise converted with ImageIO.
    static func data(_ url: URL, as type: NSPasteboard.PasteboardType) -> Data? {
        if let own = UTType(filenameExtension: url.pathExtension), own.identifier == type.rawValue {
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let uti = (type == .png ? UTType.png : UTType.tiff).identifier as CFString
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, uti, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dst, src, 0, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
