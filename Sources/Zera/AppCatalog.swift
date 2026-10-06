import AppKit

/// An installed app the opener can launch.
struct AppEntry: Equatable {
    let name: String
    let url: URL
    let bundleID: String?
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
    private var icons: [URL: NSImage] = [:]
    private static let usageKey = "appOpener.usage"

    private static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                "/System/Library/CoreServices/Applications"].map { URL(fileURLWithPath: $0) }
            + [home.appendingPathComponent("Applications")]
    }

    /// Rescans in the background when the list is older than a few minutes (or empty).
    func refreshIfNeeded(_ done: (() -> Void)? = nil) {
        guard !scanning, apps.isEmpty || Date().timeIntervalSince(scannedAt) > 300 else { done?(); return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scan()
            DispatchQueue.main.async {
                self.apps = found
                self.scannedAt = Date()
                self.scanning = false
                done?()
            }
        }
    }

    private static func scan() -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [AppEntry] = []
        func add(_ url: URL) {
            let b = Bundle(url: url)
            let key = b?.bundleIdentifier ?? url.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            out.append(AppEntry(name: name, url: url, bundleID: b?.bundleIdentifier))
        }
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in items {
                if url.pathExtension == "app" { add(url) }
                else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                        let inner = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    // One level down: "Adobe Photoshop 2025/Adobe Photoshop.app".
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func icon(_ app: AppEntry) -> NSImage {
        if let i = icons[app.url] { return i }
        let i = NSWorkspace.shared.icon(forFile: app.url.path)
        icons[app.url] = i
        return i
    }

    var runningURLs: Set<URL> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL })
    }

    func isRunning(_ app: AppEntry, _ running: Set<URL>) -> Bool { running.contains(app.url.standardizedFileURL) }

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

    /// How much you use it from here: opens, fading over two weeks.
    private func weight(_ app: AppEntry) -> Double {
        guard let u = usage[app.url.path], u.count == 2 else { return 0 }
        let days = max(0, Date().timeIntervalSince1970 - u[1]) / 86400
        return u[0] * exp(-days / 14)
    }

    /// Results for a query: best first, with the letters that matched.
    func results(for query: String, runningFirst: Bool, limit: Int = 7) -> [(app: AppEntry, hits: [Int], running: Bool, score: Int)] {
        let running = runningURLs
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            // Your usual: most-opened from here, then running apps, then a few everyday ones.
            let everyday = ["Safari", "Mail", "Notes", "Calendar", "Messages", "Finder", "Music", "System Settings"]
            let ranked = apps.sorted { a, b in
                let wa = weight(a), wb = weight(b)
                if wa != wb { return wa > wb }
                let ra = isRunning(a, running), rb = isRunning(b, running)
                if ra != rb { return ra }
                let ea = everyday.firstIndex(of: a.name) ?? 99, eb = everyday.firstIndex(of: b.name) ?? 99
                if ea != eb { return ea < eb }
                return a.name < b.name
            }
            return ranked.prefix(limit).map { ($0, [], isRunning($0, running), 0) }
        }
        let scored = apps.compactMap { app -> (AppEntry, Int, [Int], Bool)? in
            guard let m = AppMatcher.match(app.name, q) else { return nil }
            let run = isRunning(app, running)
            let bonus = Int(min(150, weight(app) * 15)) + (runningFirst && run ? 60 : 0)
            return (app, m.score + bonus, m.hits, run)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { ($0.0, $0.2, $0.3, $0.1) }
    }
}
