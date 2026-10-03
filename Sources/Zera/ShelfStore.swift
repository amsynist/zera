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

final class ShelfStore {
    static let shared = ShelfStore()
    static let changed = Notification.Name("ShelfStoreChanged")

    private(set) var items: [ShelfItem] = []
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
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) && item.staged {
            try? FileManager.default.removeItem(at: item.url)
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        remove(ids: Set(items.map { $0.id }))
    }

    func pruneMissing() {
        let before = items.count
        items.removeAll { !$0.exists }
        if items.count != before { save() }
    }

    // MARK: - Persistence

    private func load() {
        let data = UserDefaults.standard.data(forKey: defaultsKey)
            ?? UserDefaults.standard.data(forKey: legacyDefaultsKey)
        guard let data = data,
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = decoded.filter { $0.exists }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
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
