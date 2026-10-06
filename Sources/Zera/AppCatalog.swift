import AppKit

/// An installed app the opener can launch.
struct AppEntry: Equatable {
    let name: String
    let url: URL
    let bundleID: String?
    /// Resolved once during discovery, so running-state checks don't touch the file system per query.
    let canonicalURL: URL
    /// "/Applications", "/System/Applications/Utilities" … where it lives, for the hero line.
    var folder: String { url.deletingLastPathComponent().path }
}

/// Fuzzy matching for app names: whole-name starts first, then initials ("vsc" → Visual Studio
/// Code), then word starts, then anywhere, then letters in order. Returns the matched character
/// offsets so the field can light them up.
enum AppMatcher {
    static func match(_ name: String, _ query: String) -> (score: Int, hits: [Int])? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return (1, []) }
        let orig = Array(name)
        // One lowercase character per original one, so offsets line up with the name.
        let chars = orig.map { Character($0.lowercased().first.map(String.init) ?? String($0)) }
        let qc = Array(q)
        let n = String(chars)
        if n.hasPrefix(q) { return (1000 - chars.count, Array(0..<qc.count)) }
        // Word starts, in order: initials. "VS Code" and "PhpStorm" count their capitals too.
        let starts = orig.indices.filter { k in
            k == 0 || [" ", "-", "_", "."].contains(orig[k - 1]) || (orig[k].isUppercase && !orig[k - 1].isUppercase)
        }
        if qc.count <= starts.count, zip(qc, starts.prefix(qc.count)).allSatisfy({ chars[$1] == $0 }) {
            return (800 - chars.count, Array(starts.prefix(qc.count)))
        }
        if let s = starts.first(where: { n.dropFirst($0).hasPrefix(q) }) {
            return (600 - chars.count, Array(s..<(s + qc.count)))
        }
        if let r = n.range(of: q) {
            let s = n.distance(from: n.startIndex, to: r.lowerBound)
            return (400 - chars.count, Array(s..<(s + qc.count)))
        }
        var hits: [Int] = [], i = 0
        for (k, c) in chars.enumerated() where i < qc.count && c == qc[i] { hits.append(k); i += 1 }
        guard i == qc.count else { return nil }
        // Tighter clusters rank higher.
        let spread = (hits.last ?? 0) - (hits.first ?? 0)
        return (200 - spread - chars.count, hits)
    }
}

/// Every app in the usual folders, with icons and how often you open each one from Zera.
/// Use from the main thread.
final class AppCatalog {
    static let shared = AppCatalog()

    private(set) var apps: [AppEntry] = []
    private var scannedAt = Date.distantPast
    private var scanning = false
    private var refreshCallbacks: [() -> Void] = []
    private let icons = NSCache<NSURL, NSImage>()
    private static let usageKey = "appOpener.usage"

    private init() { icons.countLimit = 128 }

    private static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications",
                "/System/Library/CoreServices/Applications"].map { URL(fileURLWithPath: $0) }
            + [home.appendingPathComponent("Applications")]
    }

    /// Rescans in the background when the list is older than a few minutes (or empty).
    func refreshIfNeeded(_ done: (() -> Void)? = nil) {
        if scanning {
            if let done = done { refreshCallbacks.append(done) }
            return
        }
        guard apps.isEmpty || Date().timeIntervalSince(scannedAt) > 300 else { done?(); return }
        scanning = true
        if let done = done { refreshCallbacks.append(done) }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        DispatchQueue.global(qos: .userInitiated).async {
            // Spotlight finds apps outside the usual folders; direct scanning still works when
            // indexing is disabled. Finder lives outside Apple's Applications folders.
            let indexed = ProcessTools.run("/usr/bin/mdfind", ["-0", "kMDItemContentType == 'com.apple.application-bundle'"])
                .map { $0.split(separator: "\0").map { URL(fileURLWithPath: String($0)) } } ?? []
            let found = Self.scan(additionalURLs: [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")] + running + indexed)
            DispatchQueue.main.async {
                self.apps = found
                self.scannedAt = Date()
                self.scanning = false
                let callbacks = self.refreshCallbacks
                self.refreshCallbacks.removeAll()
                callbacks.forEach { $0() }
            }
        }
    }

    static func scan(folders: [URL] = AppCatalog.folders, additionalURLs: [URL] = []) -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [AppEntry] = []
        func add(_ candidate: URL) {
            // Keep the launchable alias: physical Cryptex paths can lose their Finder icons.
            let url = candidate.standardizedFileURL
            guard url.pathExtension.lowercased() == "app", fm.fileExists(atPath: url.path),
                  !url.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else { return }
            let b = Bundle(url: url)
            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            let key = b?.bundleIdentifier ?? canonicalURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            out.append(AppEntry(name: name, url: url, bundleID: b?.bundleIdentifier, canonicalURL: canonicalURL))
        }
        for folder in folders {
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isPackageKey],
                                                  options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "app" { add(url); enumerator.skipDescendants() }
            }
        }
        additionalURLs.forEach(add)
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func icon(_ app: AppEntry) -> NSImage {
        if let i = icons.object(forKey: app.url as NSURL) { return i }
        let i = NSWorkspace.shared.icon(forFile: app.url.path)
        icons.setObject(i, forKey: app.url as NSURL)
        return i
    }

    var runningURLs: Set<URL> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL })
    }

    func isRunning(_ app: AppEntry, _ running: Set<URL>) -> Bool {
        running.contains(app.canonicalURL)
    }

    // MARK: Usage

    private var usage: [String: [Double]] {
        get { (UserDefaults.standard.dictionary(forKey: Self.usageKey) as? [String: [Double]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.usageKey) }
    }

    func noteOpened(_ app: AppEntry) {
        var u = usage
        let key = app.url.path
        let count = (u[key]?.first ?? 0) + 1
        u[key] = [count, Date().timeIntervalSince1970]
        usage = u
    }

    /// Results for a query: best first, with the letters that matched.
    func results(for query: String, runningFirst: Bool, limit: Int = 7) -> [(app: AppEntry, hits: [Int], running: Bool, score: Int)] {
        let running = runningURLs
        let now = Date().timeIntervalSince1970
        // Read defaults once per query, rather than twice for every sorting comparison.
        let weights = usage.mapValues { u in
            u.count == 2 ? u[0] * exp(-max(0, now - u[1]) / (14 * 86400)) : 0
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            // Your usual: most-opened from here, then running apps, then a few everyday ones.
            let everyday = ["Safari", "Mail", "Notes", "Calendar", "Messages", "Finder", "Music", "System Settings"]
            let ranked = apps.map { app in
                (app: app, weight: weights[app.url.path] ?? 0, running: isRunning(app, running), everyday: everyday.firstIndex(of: app.name) ?? 99)
            }.sorted { a, b in
                if a.weight != b.weight { return a.weight > b.weight }
                if runningFirst, a.running != b.running { return a.running }
                if a.everyday != b.everyday { return a.everyday < b.everyday }
                return a.app.name < b.app.name
            }
            return ranked.prefix(limit).map { ($0.app, [], $0.running, 0) }
        }
        let scored = apps.compactMap { app -> (AppEntry, Int, [Int], Bool)? in
            guard let m = AppMatcher.match(app.name, q) else { return nil }
            let run = isRunning(app, running)
            let bonus = Int(min(150, (weights[app.url.path] ?? 0) * 15)) + (runningFirst && run ? 60 : 0)
            return (app, m.score + bonus, m.hits, run)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { ($0.0, $0.2, $0.3, $0.1) }
    }
}
