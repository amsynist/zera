import AppKit
import CryptoKit
import ImageIO

/// One thing you copied: text, a link, a colour, an image or some files.
struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, code, link, color, image, files }

    var id = UUID()
    var kind: Kind
    /// Text, code, link and colour items; a short summary for images and files.
    var text: String
    /// Images: the PNG's file name in the clipboard folder.
    var imageFile: String?
    var imageSize: CGSize?
    /// Files: full paths, in the order they were copied.
    var paths: [String] = []
    var bytes: Int = 0
    var sourceApp: String?
    var sourceBundle: String?
    var firstCopied = Date()
    var lastCopied = Date()
    var copyCount = 1
    var pinned = false
    /// What makes two copies "the same", for de-duplication.
    var fingerprint: String

    /// The filter an item falls under: links, code and colours are text.
    var filterGroup: ClipboardStore.Filter {
        switch kind {
        case .image: return .images
        case .files: return .files
        default: return .text
        }
    }

    var title: String {
        switch kind {
        case .image:
            if let s = imageSize { return "Image \(Int(s.width)) × \(Int(s.height))" }
            return "Image"
        case .files:
            let names = paths.map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
        default:
            return ClipItem.oneLine(text)
        }
    }

    var kindName: String {
        switch kind {
        case .text: return "Text"
        case .code: return "Code"
        case .link: return "Link"
        case .color: return "Colour"
        case .image: return "Image"
        case .files: return paths.count == 1 ? "File" : "Files"
        }
    }

    static func oneLine(_ s: String, max: Int = 200) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }
}

/// Clipboard history: watches the clipboard, keeps what you copy on this Mac, and puts any of it
/// back on the clipboard. Off until you turn it on. Passwords and other copies an app marks as
/// private or temporary are never kept, and neither is anything from apps you ignore.
/// Use from the main thread.
final class ClipboardStore {
    static let shared = ClipboardStore()
    static let changed = Notification.Name("ClipboardChanged")

    enum Filter: Int, CaseIterable { case all, text, images, files, pinned }

    // MARK: Settings

    private enum Key {
        static let enabled = "clipboard.enabled"
        static let paused = "clipboard.paused"
        static let days = "clipboard.days"
        static let max = "clipboard.max"
        static let fold = "clipboard.foldAfterCopy"
        static let ignored = "clipboard.ignoredApps"
    }
    private let defaults = UserDefaults.standard

    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled); restartWatching(); post() }
    }
    /// Paused for now (say, while sharing your screen); history stays, nothing new is kept.
    var paused: Bool {
        get { defaults.bool(forKey: Key.paused) }
        set { defaults.set(newValue, forKey: Key.paused); lastChange = pasteboard.changeCount; post() }
    }
    /// Days to keep unpinned items; 0 keeps them until the item limit pushes them out.
    var keepDays: Int {
        get { defaults.object(forKey: Key.days) as? Int ?? 7 }
        set { defaults.set(newValue, forKey: Key.days); prune(); post() }
    }
    var maxItems: Int {
        get { defaults.object(forKey: Key.max) as? Int ?? 200 }
        set { defaults.set(newValue, forKey: Key.max); prune(); post() }
    }
    /// Fold the island away after copying, so you can paste straight away.
    var foldAfterCopy: Bool {
        get { defaults.object(forKey: Key.fold) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.fold) }
    }
    /// Bundle ids whose copies are never kept. Password managers are in by default.
    var ignoredApps: [String] {
        get { defaults.stringArray(forKey: Key.ignored) ?? Self.defaultIgnored }
        set { defaults.set(newValue, forKey: Key.ignored) }
    }
    static let defaultIgnored = ["com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
                                 "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords",
                                 "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal"]

    static let keepChoices = [1, 7, 30, 0]
    static let maxChoices = [50, 100, 200, 500]

    // MARK: State

    private(set) var items: [ClipItem] = []

    /// Shows sample items without watching or saving anything (the screen renders).
    func preview(_ list: [ClipItem]) {
        items = list
        post()
    }
    /// Private copies skipped since launch (counted, never stored).
    private(set) var skipped = 0

    private let pasteboard = NSPasteboard.general
    private var lastChange = 0
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "ai.zera.clipboard-save", qos: .utility)
    private let fm = FileManager.default
    private let thumbs = NSCache<NSString, NSImage>()

    /// Types apps put on the clipboard to say "don't keep this" (nspasteboard.org).
    private static let privateTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"), .init("com.agilebits.onepassword"),
    ]
    /// Images bigger than this aren't kept.
    static let maxImageBytes = 10 * 1024 * 1024
    /// Text longer than this is kept shortened.
    static let maxTextChars = 100_000

    private lazy var folder: URL = {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera/Clipboard", isDirectory: true)
        try? fm.createDirectory(at: base.appendingPathComponent("images"), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        return base
    }()
    private var historyURL: URL { folder.appendingPathComponent("history.json") }
    func imageURL(_ item: ClipItem) -> URL? {
        item.imageFile.map { folder.appendingPathComponent("images").appendingPathComponent($0) }
    }

    private init() {
        thumbs.countLimit = 100
        load()
        prune()
        lastChange = pasteboard.changeCount
        restartWatching()
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    // MARK: Watching

    private func restartWatching() {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        lastChange = pasteboard.changeCount
        // The change counter is cheap to read; nothing else is touched until it moves.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        guard enabled, !paused else { return }
        capture()
    }

    /// Reads what's on the clipboard now and keeps it, unless it's private or from an ignored app.
    func capture() {
        let types = pasteboard.types ?? []
        let front = NSWorkspace.shared.frontmostApplication
        if types.contains(where: { Self.privateTypes.contains($0) })
            || front.flatMap({ $0.bundleIdentifier }).map({ ignoredApps.contains($0) }) == true {
            skipped += 1
            post()
            return
        }
        let app = front?.localizedName, bundle = front?.bundleIdentifier
        // A picture is converted, hashed and saved off the main thread (screenshots are big);
        // its bytes are copied off the clipboard now, while they're still there.
        if !hasFiles, let raw = rawImage(types) {
            let dir = folder.appendingPathComponent("images")
            Self.imageQueue.async { [weak self] in
                guard var item = Self.imageItem(raw, in: dir) else { return }
                DispatchQueue.main.async {
                    item.sourceApp = app
                    item.sourceBundle = bundle
                    self?.add(item)
                }
            }
            return
        }
        guard var item = read(types: types) else { return }
        item.sourceApp = app
        item.sourceBundle = bundle
        add(item)
    }

    private static let imageQueue = DispatchQueue(label: "ai.zera.clipboard-images", qos: .utility)

    /// Files on the clipboard (Finder also adds an icon picture, which isn't what was copied).
    private var hasFiles: Bool { pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) }

    private enum RawImage { case png(Data), tiff(Data) }
    private func rawImage(_ types: [NSPasteboard.PasteboardType]) -> RawImage? {
        if types.contains(.png), let d = pasteboard.data(forType: .png) { return .png(d) }
        if types.contains(.tiff), let d = pasteboard.data(forType: .tiff) { return .tiff(d) }
        return nil
    }

    /// PNG bytes → a stored image item (any thread).
    private static func imageItem(_ raw: RawImage, in dir: URL) -> ClipItem? {
        let data: Data
        switch raw {
        case .png(let d): data = d
        case .tiff(let t):
            guard let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) else { return nil }
            data = png
        }
        guard data.count <= maxImageBytes else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = digest.prefix(24) + ".png"
        let url = dir.appendingPathComponent(String(name))
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url, options: .atomic) }
        let size = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            .flatMap { p -> CGSize? in
                guard let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
                return CGSize(width: w, height: h)
            }
        return ClipItem(kind: .image, text: "", imageFile: String(name), imageSize: size, bytes: data.count, fingerprint: "image:" + digest)
    }

    private func read(types: [NSPasteboard.PasteboardType]) -> ClipItem? {
        // Files first: Finder also puts an icon image on the clipboard when you copy a file.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map(\.path)
            let bytes = paths.reduce(0) { $0 + ((try? fm.attributesOfItem(atPath: $1)[.size] as? Int) ?? 0) }
            return ClipItem(kind: .files, text: paths.joined(separator: "\n"), paths: paths, bytes: bytes,
                            fingerprint: "files:" + paths.joined(separator: "|"))
        }
        if types.contains(.png) || types.contains(.tiff), let data = pngData() {
            guard data.count <= Self.maxImageBytes else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let name = digest.prefix(24) + ".png"
            let url = folder.appendingPathComponent("images").appendingPathComponent(String(name))
            if !fm.fileExists(atPath: url.path) { try? data.write(to: url, options: .atomic) }
            let size = NSBitmapImageRep(data: data).map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            return ClipItem(kind: .image, text: "", imageFile: String(name), imageSize: size, bytes: data.count,
                            fingerprint: "image:" + digest)
        }
        guard let raw = pasteboard.string(forType: .string) else { return nil }
        let s = raw.count > Self.maxTextChars ? String(raw.prefix(Self.maxTextChars)) : raw
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let kind = Self.classify(s)
        return ClipItem(kind: kind, text: s, bytes: s.utf8.count, fingerprint: "text:" + s)
    }

    private func pngData() -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Link, colour, code or plain text, from the text itself.
    static func classify(_ s: String) -> ClipItem.Kind {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains(where: { $0.isWhitespace }) {
            if let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https", "mailto", "ftp"].contains(scheme), u.host != nil || scheme == "mailto" {
                return .link
            }
            if t.range(of: #"^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#, options: .regularExpression) != nil,
               t.hasPrefix("#") || t.count == 6 && t.contains(where: { $0.isLetter }) && t.contains(where: { $0.isNumber }) {
                return .color
            }
        }
        if t.range(of: #"^(rgb|rgba|hsl|hsla)\(\s*[\d.%\s,/]+\)$"#, options: [.regularExpression, .caseInsensitive]) != nil { return .color }
        let firstLine = t.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? t
        let commands = ["git ", "npm ", "npx ", "yarn ", "pnpm ", "brew ", "cd ", "ls ", "swift ", "python", "pip ", "curl ",
                        "docker ", "kubectl ", "make ", "cargo ", "go ", "sudo ", "ssh ", "$ ", "./", "export ", "echo "]
        if commands.contains(where: { firstLine.hasPrefix($0) }) { return .code }
        let codeMarks = ["{\n", "};", "=>", "();", "func ", "def ", "const ", "let ", "import ", "return ", "</", "#include"]
        let lines = t.split(separator: "\n").count
        if codeMarks.contains(where: { t.contains($0) }) && (lines > 1 || t.hasSuffix(";") || t.hasSuffix("}")) { return .code }
        if lines > 2, t.split(separator: "\n").filter({ $0.hasPrefix("    ") || $0.hasPrefix("\t") }).count >= 2 { return .code }
        return .text
    }

    private func add(_ new: ClipItem) {
        if let i = items.firstIndex(where: { $0.fingerprint == new.fingerprint }) {
            // Copied again: to the top, counted once more.
            var old = items.remove(at: i)
            old.lastCopied = Date()
            old.copyCount += 1
            if let app = new.sourceApp { old.sourceApp = app; old.sourceBundle = new.sourceBundle }
            items.insert(old, at: 0)
        } else {
            items.insert(new, at: 0)
        }
        prune()
        changed()
    }

    // MARK: Using items

    /// Puts an item back on the clipboard exactly as it was. Returns false if it's gone
    /// (an image file deleted, or every copied file moved).
    @discardableResult
    func copy(_ item: ClipItem, plainText: Bool = false) -> Bool {
        pasteboard.clearContents()
        var ok = true
        switch item.kind {
        case .image:
            if let url = imageURL(item), let img = NSImage(contentsOf: url) { pasteboard.writeObjects([img]) } else { ok = false }
        case .files:
            let urls = item.paths.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
            if plainText || urls.isEmpty {
                // As text: the paths. With every file gone, that's all there is left to give.
                pasteboard.setString(item.text, forType: .string)
                ok = plainText || !urls.isEmpty
            } else {
                pasteboard.writeObjects(urls as [NSURL])
            }
        case .link where !plainText:
            if let u = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pasteboard.writeObjects([u as NSURL])
                pasteboard.setString(item.text, forType: .string)
            } else { pasteboard.setString(item.text, forType: .string) }
        default:
            pasteboard.setString(item.text, forType: .string)
        }
        // Our own write isn't a new copy.
        lastChange = pasteboard.changeCount
        guard ok, let i = items.firstIndex(where: { $0.id == item.id }) else { return ok }
        var it = items.remove(at: i)
        it.lastCopied = Date()
        it.copyCount += 1
        items.insert(it, at: it.pinned ? 0 : (items.firstIndex(where: { !$0.pinned }) ?? items.count))
        changed()
        return true
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        changed()
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let gone = items.remove(at: i)
        removeImageIfUnused(gone)
        changed()
    }

    /// Clears everything except pinned items.
    func clear() {
        let gone = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        gone.forEach(removeImageIfUnused)
        skipped = 0
        changed()
    }

    // MARK: Lists

    func items(_ filter: Filter, matching query: String = "") -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ordered.filter { item in
            let inFilter: Bool
            switch filter {
            case .all: inFilter = true
            case .pinned: inFilter = item.pinned
            default: inFilter = item.filterGroup == filter
            }
            guard inFilter else { return false }
            guard !q.isEmpty else { return true }
            return item.text.localizedCaseInsensitiveContains(q) || item.title.localizedCaseInsensitiveContains(q)
                || (item.sourceApp?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    func count(_ filter: Filter) -> Int {
        switch filter {
        case .all: return items.count
        case .pinned: return items.lazy.filter(\.pinned).count
        default: return items.lazy.filter { $0.filterGroup == filter }.count
        }
    }

    /// Pinned first, then newest.
    var ordered: [ClipItem] { items.filter(\.pinned) + items.filter { !$0.pinned } }

    /// A small, cached thumbnail of an image item (decoded here, on the calling thread).
    func thumbnail(_ item: ClipItem, size: CGFloat) -> NSImage? {
        guard let url = imageURL(item) else { return nil }
        if let t = cachedThumbnail(item, size: size) { return t }
        let img = Self.decodeThumbnail(url, size: size)
        if let img = img { thumbs.setObject(img, forKey: Self.thumbKey(url, size)) }
        return img
    }

    /// The thumbnail if it's already decoded; nil otherwise (never touches the disk).
    func cachedThumbnail(_ item: ClipItem, size: CGFloat) -> NSImage? {
        guard let url = imageURL(item) else { return nil }
        return thumbs.object(forKey: Self.thumbKey(url, size))
    }

    /// Decodes the thumbnail off the main thread and hands it back on the main thread. Rows show a
    /// plain tile until it arrives, so a list full of screenshots opens without waiting for them.
    func loadThumbnail(_ item: ClipItem, size: CGFloat, done: @escaping (NSImage?) -> Void) {
        guard let url = imageURL(item) else { done(nil); return }
        if let t = thumbs.object(forKey: Self.thumbKey(url, size)) { done(t); return }
        let cache = thumbs
        Self.thumbQueue.async {
            let img = Self.decodeThumbnail(url, size: size)
            if let img = img { cache.setObject(img, forKey: Self.thumbKey(url, size)) }
            DispatchQueue.main.async { done(img) }
        }
    }

    private static let thumbQueue = DispatchQueue(label: "ai.zera.clipboard-thumbs", qos: .userInitiated, attributes: .concurrent)
    private static func thumbKey(_ url: URL, _ size: CGFloat) -> NSString { "\(url.lastPathComponent)@\(Int(size))" as NSString }
    private static func decodeThumbnail(_ url: URL, size: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size * 2,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }

    // MARK: Housekeeping

    /// Old items go after the time you chose, and the list stays under the limit; pinned items stay.
    private func prune() {
        var keep = items
        if keepDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
            keep.removeAll { !$0.pinned && $0.lastCopied < cutoff }
        }
        let unpinned = keep.filter { !$0.pinned }
        if unpinned.count > maxItems {
            let drop = Set(unpinned.suffix(unpinned.count - maxItems).map(\.id))
            keep.removeAll { drop.contains($0.id) }
        }
        guard keep.count != items.count else { return }
        let keptIDs = Set(keep.map(\.id))
        let gone = items.filter { !keptIDs.contains($0.id) }
        items = keep
        gone.forEach(removeImageIfUnused)
        scheduleSave()
    }

    private func removeImageIfUnused(_ item: ClipItem) {
        guard let f = item.imageFile, !items.contains(where: { $0.imageFile == f }),
              let url = imageURL(item) else { return }
        try? fm.removeItem(at: url)
    }

    private func changed() {
        scheduleSave()
        post()
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = list
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = items
        let url = historyURL
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        saveWork = work
        saveQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
