import AppKit

// MARK: - GitHub status for the shelf's pull requests
//
// Only the PRs you put on the shelf are checked, with the token already saved for the PRs screen
// (Keychain, api.github.com only). No discovery queries.

@MainActor
final class DailyShelfGitHub {
    static let shared = DailyShelfGitHub()
    nonisolated static let changed = Notification.Name("ZeraDailyShelfGitHubChanged")

    private var task: Task<Void, Never>?
    private(set) var lastChecked: Date?
    private(set) var lastError: String?
    var isConnected: Bool { GitHubService.shared.token != nil }

    /// Fetches status for the shelf's PRs (or just `ids`). Quietly does nothing without a token.
    func refresh(only ids: Set<UUID>? = nil) {
        guard task == nil, let token = GitHubService.shared.token else { return }
        let me = GitHubService.shared.login
        let targets = DailyShelfStore.shared.items.filter { $0.kind == .pr && $0.github != nil && (ids?.contains($0.id) ?? true) }
        guard !targets.isEmpty else { return }
        task = Task { [weak self] in
            var firstError: String?
            for it in targets {
                guard let g = it.github else { continue }
                do {
                    let (pr, title) = try await Self.fetch(g, token: token, me: me)
                    let placeholder = "\(g.repo) #\(g.number)"
                    let moved = DailyShelfPRStatus.of(g).group != DailyShelfPRStatus.of(pr).group && g.checkedAt != nil
                    DailyShelfStore.shared.update(it.id, landed: moved) { item in
                        item.github = pr
                        if item.customTitle != true, let t = title, !t.isEmpty, item.title == placeholder || item.title.isEmpty { item.title = t }
                    }
                } catch {
                    firstError = firstError ?? error.localizedDescription
                }
            }
            guard let self = self else { return }
            self.task = nil
            self.lastChecked = Date()
            self.lastError = firstError
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    nonisolated static func fetch(_ g: DailyShelfPR, token: String, me: String?) async throws -> (DailyShelfPR, String?) {
        let base = "/repos/\(g.owner)/\(g.repo)/pulls/\(g.number)"
        let pull = try await object(base, token: token)
        let reviews = (try? await array("\(base)/reviews?per_page=100", token: token)) ?? []
        var pr = g
        let merged = (pull["merged"] as? Bool) == true || pull["merged_at"] is String
        pr.state = merged ? .merged : ((pull["state"] as? String) == "closed" ? .closed : .open)
        pr.draft = (pull["draft"] as? Bool) ?? false
        pr.additions = pull["additions"] as? Int
        pr.deletions = pull["deletions"] as? Int
        let author = (pull["user"] as? [String: Any])?["login"] as? String
        pr.author = author
        pr.mine = me.map { $0.caseInsensitiveCompare(author ?? "") == .orderedSame }
        let requested = ((pull["requested_reviewers"] as? [[String: Any]]) ?? []).compactMap { $0["login"] as? String }
        (pr.review, pr.reviewer) = review(reviews, requested: requested, me: me, mine: pr.mine ?? false)
        if pr.state == .open, let sha = (pull["head"] as? [String: Any])?["sha"] as? String {
            let runs = ((try? await object("/repos/\(g.owner)/\(g.repo)/commits/\(sha)/check-runs?per_page=100", token: token))?["check_runs"] as? [[String: Any]]) ?? []
            (pr.ci, pr.failing) = checks(runs)
        } else {
            pr.ci = .none; pr.failing = 0
        }
        pr.checkedAt = Date()
        return (pr, pull["title"] as? String)
    }

    /// Your review requested beats everything; then the latest review per person.
    nonisolated static func review(_ reviews: [[String: Any]], requested: [String], me: String?, mine: Bool) -> (DailyShelfPR.Review, String?) {
        if !mine, let me = me, requested.contains(where: { $0.caseInsensitiveCompare(me) == .orderedSame }) { return (.requested, nil) }
        var latest: [String: String] = [:]
        var order: [String] = []
        for r in reviews {
            guard let who = (r["user"] as? [String: Any])?["login"] as? String, let state = r["state"] as? String,
                  state == "APPROVED" || state == "CHANGES_REQUESTED" || state == "DISMISSED" else { continue }
            if latest[who] == nil { order.append(who) }
            latest[who] = state
        }
        if let who = order.last(where: { latest[$0] == "CHANGES_REQUESTED" }) { return (.changesRequested, who) }
        if let who = order.last(where: { latest[$0] == "APPROVED" }) { return (.approved, who) }
        return (.none, nil)
    }

    nonisolated static func checks(_ runs: [[String: Any]]) -> (DailyShelfPR.CI, Int) {
        guard !runs.isEmpty else { return (.none, 0) }
        let bad: Set<String> = ["failure", "timed_out", "cancelled", "action_required", "startup_failure"]
        let failing = runs.filter { bad.contains(($0["conclusion"] as? String) ?? "") }.count
        if failing > 0 { return (.failing, failing) }
        if runs.contains(where: { ($0["status"] as? String) != "completed" }) { return (.running, 0) }
        return (.passed, 0)
    }

    private nonisolated static func request(_ path: String, token: String) async throws -> Data {
        guard let url = URL(string: "https://api.github.com" + path) else { throw GHError.badResponse }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Zera-macOS", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GHError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
            throw GHError.http(http.statusCode, msg)
        }
        return data
    }
    private nonisolated static func object(_ path: String, token: String) async throws -> [String: Any] {
        guard let j = try JSONSerialization.jsonObject(with: try await request(path, token: token)) as? [String: Any] else { throw GHError.badResponse }
        return j
    }
    private nonisolated static func array(_ path: String, token: String) async throws -> [[String: Any]] {
        guard let j = try JSONSerialization.jsonObject(with: try await request(path, token: token)) as? [[String: Any]] else { throw GHError.badResponse }
        return j
    }
}

// MARK: - Claude files the links no rule knows

@MainActor
final class DailyShelfClassifier {
    static let shared = DailyShelfClassifier()

    private var pending: Set<UUID> = []
    private var work: DispatchWorkItem?
    private var running = false
    private(set) var lastError: String?

    struct Pick: Equatable { var category: String; var title: String?; var layout: String? }

    func enqueue(_ id: UUID) {
        pending.insert(id)
        schedule(after: 1.2)
    }

    private func schedule(after delay: TimeInterval) {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.run() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func run() {
        guard !running else { return }
        let store = DailyShelfStore.shared
        let batch = store.items.filter { pending.contains($0.id) && $0.sorting }.prefix(12)
        pending.subtract(batch.map(\.id))
        guard !batch.isEmpty else { return }
        let items = Array(batch)
        guard DailyShelfSettings.current.sortWithClaude else { finish(items, picks: [:]); return }
        running = true
        // Categories already in use today and the ones you taught it, so Claude reuses yours.
        let inUse = store.items.filter { $0.kind == .site && !$0.sorting }.map(\.category) + Array(store.learned.values)
        ZeraAssistant.shared.quickAnswer(Self.prompt(for: items, extra: inUse), system: Self.system) { [weak self] result in
            guard let self = self else { return }
            self.running = false
            switch result {
            case .success(let text): self.lastError = nil; self.finish(items, picks: Self.parse(text, count: items.count))
            case .failure(let e): self.lastError = e.message; self.finish(items, picks: [:])
            }
            if !self.pending.isEmpty { self.schedule(after: 0.3) }
        }
    }

    private func finish(_ items: [DailyShelfItem], picks: [Int: Pick]) {
        for (i, it) in items.enumerated() {
            let p = picks[i]
            DailyShelfStore.shared.update(it.id, landed: true) { item in
                guard item.sorting else { return }
                item.sorting = false
                if let p = p {
                    item.category = p.category
                    item.categorySource = .claude
                    item.layout = p.layout
                    if item.customTitle != true, let t = p.title, !t.isEmpty, item.title == DailyShelfRules.fallbackTitle(for: item.link ?? URL(fileURLWithPath: "/")) { item.title = t }
                } else {
                    item.category = DailyShelfRules.fallbackCategory
                }
            }
        }
    }

    nonisolated static let system = "You file links on a developer's daily shelf. Reply with JSON only, no prose."

    /// Only each link's address and title are sent; never page contents.
    nonisolated static func prompt(for items: [DailyShelfItem], extra: [String] = []) -> String {
        let list = items.enumerated().map { i, it in "\(i). \(it.url ?? "") (title: \"\(it.title.replacingOccurrences(of: "\"", with: "'"))\")" }
        var cats = DailyShelfRules.siteCategories
        for c in extra where !cats.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) { cats.append(c) }
        return """
        File each link into one category. Use one of: \(cats.joined(separator: ", ")). \
        Only if none fits, invent one short category of one or two words.
        Give a short title (at most six words, keep product and project names) and a layout: "tile" for a place \
        the person keeps returning to (an app, dashboard, console or design file), "row" for a page to read \
        (docs, an article, a question).
        Reply with only a JSON array, one object per link: [{"i": 0, "category": "Dev tools", "title": "Vercel deployments", "layout": "tile"}]

        Links:
        \(list.joined(separator: "\n"))
        """
    }

    /// Reads Claude's array, tolerating prose or a code fence around it.
    nonisolated static func parse(_ text: String, count: Int) -> [Int: Pick] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [Int: Pick] = [:]
        for (n, o) in arr.enumerated() {
            let i = (o["i"] as? Int) ?? n
            guard i >= 0, i < count, var cat = (o["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !cat.isEmpty else { continue }
            if let known = DailyShelfRules.siteCategories.first(where: { $0.caseInsensitiveCompare(cat) == .orderedSame }) { cat = known }
            else { cat = String(cat.prefix(22)) }
            let title = (o["title"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
            let layout = (o["layout"] as? String).flatMap { $0 == "tile" || $0 == "row" ? $0 : nil }
            out[i] = Pick(category: cat, title: title, layout: layout)
        }
        return out
    }
}

// MARK: - Favicons, from each site itself

@MainActor
final class DailyShelfFavicons {
    static let shared = DailyShelfFavicons()
    nonisolated static let loaded = Notification.Name("ZeraDailyShelfFaviconLoaded")

    /// Off in render fixtures and tests: no network, monograms only.
    var fetchEnabled = true
    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var failed: [String: Date] = [:]
    private let folder: URL
    private static let maxAge: TimeInterval = 30 * 86_400
    private nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        return URLSession(configuration: c)
    }()

    private init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Zera/Favicons", isDirectory: true)
    }

    /// The cached icon, or nil while it is fetched (a `loaded` notification follows).
    func image(for host: String) -> NSImage? {
        guard Self.isSafeHost(host) else { return nil }
        if let m = memory[host] { return m }
        let file = folder.appendingPathComponent(host + ".png")
        if let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < Self.maxAge, let img = NSImage(contentsOf: file) {
            memory[host] = img
            return img
        }
        fetch(host, into: file)
        return nil
    }

    private func fetch(_ host: String, into file: URL) {
        guard fetchEnabled, !inFlight.contains(host), failed[host].map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true else { return }
        inFlight.insert(host)
        let service = DailyShelfSettings.current.iconService
        Task { [weak self] in
            let png = await Self.download(host: host, iconService: service)
            guard let self = self else { return }
            self.inFlight.remove(host)
            guard let png = png, let img = NSImage(data: png) else { self.failed[host] = Date(); return }
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
            self.memory[host] = img
            NotificationCenter.default.post(name: Self.loaded, object: nil, userInfo: ["host": host])
        }
    }

    nonisolated static func isSafeHost(_ host: String) -> Bool {
        !host.isEmpty && host.count < 254 && host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil && !host.hasPrefix(".")
    }

    /// The site's own icon, else its parent domain's (a portal under a company domain often has
    /// none of its own). For each: `/favicon.ico`, the page's `<link rel="icon">`, then
    /// `/apple-touch-icon.png`. Returned as PNG.
    nonisolated static func download(host: String, iconService: Bool) async -> Data? {
        for h in candidateHosts(host) {
            if let png = await icon(of: h) { return png }
        }
        // Last resort: DuckDuckGo's icon service, asked for the public domain only (never an internal host).
        if iconService, let u = URL(string: "https://icons.duckduckgo.com/ip3/\(registrableDomain(host)).ico") { return await image(at: u) }
        return nil
    }

    /// `stageportal.example.org` → `example.org`; `docs.example.co.uk` → `example.co.uk`.
    nonisolated static func registrableDomain(_ host: String) -> String {
        let p = host.split(separator: ".").map(String.init)
        guard p.count > 2 else { return host }
        let twoLevel = p[p.count - 1].count == 2 && ["co", "com", "org", "net", "gov", "ac", "edu"].contains(p[p.count - 2])
        return p.suffix(twoLevel ? 3 : 2).joined(separator: ".")
    }

    /// `stage.portal.example.com` → itself, `portal.example.com`, `example.com`.
    nonisolated static func candidateHosts(_ host: String) -> [String] {
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return [host] }
        return (0...(parts.count - 2)).map { parts[$0...].joined(separator: ".") }
    }

    private nonisolated static func icon(of host: String) async -> Data? {
        if let u = URL(string: "https://\(host)/favicon.ico"), let png = await image(at: u) { return png }
        if let page = URL(string: "https://\(host)/"),
           let (data, resp) = try? await session.data(from: page), (resp as? HTTPURLResponse)?.statusCode == 200 {
            let html = String(decoding: data.prefix(512 * 1024), as: UTF8.self)
            if let href = iconHref(in: html), let u = URL(string: href, relativeTo: (resp.url ?? page))?.absoluteURL,
               u.scheme == "https", let png = await image(at: u) { return png }
        }
        if let u = URL(string: "https://\(host)/apple-touch-icon.png"), let png = await image(at: u) { return png }
        return nil
    }

    private nonisolated static func image(at url: URL) async -> Data? {
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              data.count > 0, data.count < 1_000_000, let img = NSImage(data: data), img.isValid else { return nil }
        // Largest representation, drawn into 64 × 64 PNG.
        let target = NSSize(width: 64, height: 64)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let best = img.representations.max(by: { $0.pixelsWide < $1.pixelsWide })
        if let best = best { best.draw(in: NSRect(origin: .zero, size: target)) } else { img.draw(in: NSRect(origin: .zero, size: target)) }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The best `<link rel="…icon…" href="…">` in a page: apple-touch-icon, then icon.
    nonisolated static func iconHref(in html: String) -> String? {
        let pattern = #"<link\b[^>]*>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        var touch: String?, icon: String?
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html) else { continue }
            let tag = String(html[r])
            guard let rel = attribute("rel", in: tag)?.lowercased(), let href = attribute("href", in: tag), !href.isEmpty else { continue }
            if rel.contains("apple-touch-icon") { touch = touch ?? href }
            else if rel.split(separator: " ").contains("icon"), !href.lowercased().contains("undefined") { icon = icon ?? href }
        }
        return touch ?? icon
    }

    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for i in 1...3 { if let r = Range(m.range(at: i), in: tag) { return String(tag[r]).replacingOccurrences(of: "&amp;", with: "&") } }
        return nil
    }
}

// MARK: - Arc sidebar tabs
//
// Dragging a tab out of Arc's sidebar carries only Arc's own item id, never the link. The link is
// read for that one id from Arc's sidebar file (no permission needed); a tab Arc has not saved yet
// is asked of Arc itself through AppleScript (macOS asks you once).

enum DailyShelfArc {
    static let pasteboardType = NSPasteboard.PasteboardType("company.thebrowser.SidebarItemID")
    static let bundleID = "company.thebrowser.Browser"

    static var sidebarFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
    }

    /// The Arc item ids on a drag pasteboard.
    static func ids(on pb: NSPasteboard) -> [String] {
        (pb.pasteboardItems ?? []).compactMap { $0.string(forType: pasteboardType)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.range(of: #"^[A-Fa-f0-9-]{8,64}$"#, options: .regularExpression) != nil }
    }

    /// The link and title for `id` in Arc's sidebar data, if the item is a saved tab.
    static func link(for id: String, in data: Data) -> (URL, String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: [String: Any]?
        func walk(_ o: Any) {
            guard found == nil else { return }
            if let d = o as? [String: Any] {
                if d["id"] as? String == id, (d["data"] as? [String: Any])?["tab"] != nil { found = d; return }
                d.values.forEach(walk)
            } else if let a = o as? [Any] { a.forEach(walk) }
        }
        walk(root)
        guard let item = found, let tab = (item["data"] as? [String: Any])?["tab"] as? [String: Any],
              let raw = tab["savedURL"] as? String, let url = DailyShelfRules.link(in: raw) else { return nil }
        let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (tab["savedTitle"] as? String)
        return (url, title)
    }

    static func fromSidebarFile(_ id: String) -> (URL, String?)? {
        guard let data = try? Data(contentsOf: sidebarFile) else { return nil }
        return link(for: id, in: data)
    }

    /// Asks Arc for the tab's link off the main thread. Calls back on the main queue (nil if Arc does not know it).
    static func askArc(_ id: String, completion: @escaping @Sendable (URL?, String?) -> Void) {
        let script = """
        on run argv
          set wanted to item 1 of argv
          tell application id "\(bundleID)"
            repeat with w in windows
              try
                set t to (first tab of w whose id is wanted)
                return (URL of t) & linefeed & (title of t)
              end try
            end repeat
          end tell
          return ""
        end run
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-", id]
            let input = Pipe(), output = Pipe()
            p.standardInput = input; p.standardOutput = output; p.standardError = Pipe()
            var answer = ""
            do {
                try p.run()
                input.fileHandleForWriting.write(Data(script.utf8))
                try? input.fileHandleForWriting.close()
                let deadline = Date().addingTimeInterval(6)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if p.isRunning { p.terminate() }
                answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            } catch {}
            let lines = answer.split(separator: "\n", maxSplits: 1).map(String.init)
            let url = lines.first.flatMap { DailyShelfRules.link(in: $0) }
            let title = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            DispatchQueue.main.async { completion(url, title) }
        }
    }
}
