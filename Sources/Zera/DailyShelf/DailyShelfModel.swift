import AppKit

// MARK: - Daily Shelf: model
//
// The day's working links: pull requests, Jira tickets, docs, meetings, sites and notes. Only what
// you add is here (dragged to the screen edge, pasted, or typed). Known links are filed by rules,
// the rest by Claude; your own "Move to…" choices win and are remembered per site. One JSON file
// per day under ~/Library/Application Support/Zera/DailyShelf/. See docs/design/daily-shelf/DESIGN.md.

enum DailyShelfKind: String, Codable, CaseIterable {
    case pr, jira, doc, meeting, site, note
}

/// Optional local gradient accent for an item. Nil keeps the active theme's default surface.
enum DailyShelfAccent: String, Codable, CaseIterable {
    case ocean, aurora, sunset, mint, gold, rose
    case lagoon, sapphire, lavender, orchid, cherry, coral, ember, citrus, emerald, moonstone
    var title: String { rawValue.capitalized }
}

enum DailyShelfCategorySource: String, Codable {
    case rule, claude, user
}

/// A pull request's state, from GitHub, using the same words as the PRs screen.
struct DailyShelfPR: Codable, Equatable {
    enum State: String, Codable { case open, merged, closed }
    enum CI: String, Codable { case none, running, passed, failing }
    enum Review: String, Codable { case none, requested, approved, changesRequested }

    var owner: String
    var repo: String
    var number: Int
    var state: State = .open
    var draft = false
    var ci: CI = .none
    var failing = 0
    var review: Review = .none
    /// Who asked for changes / approved, for the meta line.
    var reviewer: String?
    var author: String?
    var mine: Bool?
    var additions: Int?
    var deletions: Int?
    var checkedAt: Date?

    var fullRepo: String { "\(owner)/\(repo)" }
}

struct DailyShelfItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: DailyShelfKind
    /// Nil for notes.
    var url: String?
    var title: String
    /// A local rename must survive later GitHub or Claude title refreshes.
    var customTitle: Bool?
    var accent: DailyShelfAccent?
    var category: String
    var categorySource: DailyShelfCategorySource
    var addedAt = Date()
    var pinned = false
    var opens = 0
    /// Kept from an earlier day (pinned, or an open PR carried over).
    var carried: Bool?
    var github: DailyShelfPR?
    var jiraKey: String?
    /// Claude's layout hint for sites: places are tiles, pages are rows.
    var layout: String?
    /// Waiting for Claude to file it. Not saved.
    var sorting = false

    enum CodingKeys: String, CodingKey {
        case id, kind, url, title, customTitle, accent, category, categorySource, addedAt, pinned, opens, carried, github, jiraKey, layout
    }

    var host: String? { url.flatMap(DailyShelfRules.host(of:)) }
    /// The group it sits in: a site category, or its section.
    var groupKey: String { kind == .site ? "category:\(category)" : "section:\(kind.rawValue)" }
    var link: URL? { url.flatMap(URL.init(string:)) }
}

struct DailyShelfDay: Codable, Equatable {
    var version = 1
    var day: String
    var rollsOverAt: String
    var items: [DailyShelfItem]
}

// MARK: - Rules

/// Files links whose kind is obvious from the URL. Everything else goes to Claude (or "Websites").
enum DailyShelfRules {
    struct Match: Equatable {
        var kind: DailyShelfKind
        var category: String
        var pr: (owner: String, repo: String, number: Int)?
        var jiraKey: String?
        static func == (a: Match, b: Match) -> Bool {
            a.kind == b.kind && a.category == b.category && a.jiraKey == b.jiraKey
                && a.pr?.owner == b.pr?.owner && a.pr?.repo == b.pr?.repo && a.pr?.number == b.pr?.number
        }
    }

    static let sectionTitles: [DailyShelfKind: String] = [
        .pr: "Pull requests", .jira: "Jira", .meeting: "Meetings", .doc: "Docs", .site: "Sites", .note: "Notes",
    ]
    /// Site categories Claude may choose from, in display order. Places are shown as tiles.
    static let siteCategories = ["Dev tools", "Dashboards", "Design", "Reference", "Reading", "Websites"]
    static let tileCategories: Set<String> = ["Dev tools", "Dashboards", "Design"]
    static let fallbackCategory = "Websites"

    /// An http(s) link in what was pasted or dropped, if it is one.
    static func link(in text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: { $0.isWhitespace }), let u = URL(string: t),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host?.isEmpty == false else { return nil }
        return u
    }

    static func host(of url: String) -> String? {
        guard let h = URL(string: url)?.host?.lowercased() else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func match(_ url: URL, learned: [String: String] = [:]) -> Match? {
        guard let rawHost = url.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "github.com", parts.count >= 4, parts[2] == "pull", let n = Int(parts[3]) {
            return Match(kind: .pr, category: "Pull requests", pr: (parts[0], parts[1], n))
        }
        if host.hasSuffix(".atlassian.net") || host.hasPrefix("jira.") {
            if let i = parts.firstIndex(of: "browse"), i + 1 < parts.count, isJiraKey(parts[i + 1]) {
                return Match(kind: .jira, category: "Jira", jiraKey: parts[i + 1].uppercased())
            }
            if let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "selectedIssue" })?.value, isJiraKey(key) {
                return Match(kind: .jira, category: "Jira", jiraKey: key.uppercased())
            }
            if parts.first == "wiki" { return Match(kind: .doc, category: "Docs") }
        }
        if host == "docs.google.com" || host == "notion.so" || host.hasSuffix(".notion.site") || host == "dropbox.com" && parts.first == "paper" {
            return Match(kind: .doc, category: "Docs")
        }
        if host == "meet.google.com" || host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "teams.microsoft.com" || host == "teams.live.com" {
            return Match(kind: .meeting, category: "Meetings")
        }
        if let c = learned[host] { return Match(kind: .site, category: c) }
        return nil
    }

    static func isJiraKey(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z][A-Za-z0-9_]+-\d+$"#, options: .regularExpression) != nil
    }

    /// A readable title when the drag or paste brought none.
    static func fallbackTitle(for url: URL) -> String {
        let host = host(of: url.absoluteString) ?? url.absoluteString
        let last = url.path.split(separator: "/").last.map(String.init) ?? ""
        guard !last.isEmpty, last.count < 80 else { return host }
        let words = (last.removingPercentEncoding ?? last)
            .replacingOccurrences(of: #"\.(html?|php|aspx?)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-_+]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, words.range(of: #"^[0-9a-f]{12,}$"#, options: .regularExpression) == nil else { return host }
        return "\(words.prefix(1).uppercased())\(words.dropFirst()) · \(host)"
    }

    /// Notes that look like a command use the monospace face.
    static func looksLikeCommand(_ s: String) -> Bool {
        s.range(of: #"^(\$ |gh |git |npm |pnpm |yarn |swift |xcodebuild |cd |\./|make |docker |kubectl |brew )"#, options: .regularExpression) != nil
    }
}

// MARK: - Pull request status

enum DailyShelfTone { case danger, warning, success, info, accent, muted }

struct DailyShelfPRStatus: Equatable {
    enum Group: Int, CaseIterable {
        case yourMove, ready, waiting, done
        var title: String {
            switch self {
            case .yourMove: return "Your move"
            case .ready: return "Ready to merge"
            case .waiting: return "Waiting on others"
            case .done: return "Done today"
            }
        }
        var tone: DailyShelfTone {
            switch self {
            case .yourMove: return .danger
            case .ready: return .success
            case .waiting: return .muted
            case .done: return .accent
            }
        }
    }
    var label: String
    var tone: DailyShelfTone
    var symbol: String
    var group: Group

    static func of(_ g: DailyShelfPR) -> DailyShelfPRStatus {
        switch g.state {
        case .merged: return .init(label: "Merged", tone: .accent, symbol: "arrow.triangle.merge", group: .done)
        case .closed: return .init(label: "Closed", tone: .muted, symbol: "xmark.circle", group: .done)
        case .open: break
        }
        if g.draft { return .init(label: "Draft", tone: .muted, symbol: "circle.dashed", group: .waiting) }
        if g.ci == .failing { return .init(label: "\(max(1, g.failing)) failing", tone: .danger, symbol: "xmark.octagon", group: .yourMove) }
        if g.review == .changesRequested { return .init(label: "Changes asked", tone: .warning, symbol: "exclamationmark.bubble", group: .yourMove) }
        if g.review == .requested { return .init(label: "Your review", tone: .info, symbol: "eye", group: .yourMove) }
        if g.ci == .running { return .init(label: "Checks running", tone: .muted, symbol: "clock", group: .waiting) }
        if g.review == .approved { return .init(label: "Ready to merge", tone: .success, symbol: "checkmark.circle", group: .ready) }
        return .init(label: "In review", tone: .muted, symbol: "arrow.triangle.pull", group: .waiting)
    }
}

// MARK: - The day

enum DailyShelfClock {
    /// The shelf's day for `date`: before the rollover hour it is still the previous day.
    static func dayKey(for date: Date, rolloverHour: Int, calendar: Calendar = .current) -> String {
        let shifted = calendar.date(byAdding: .hour, value: -max(0, min(23, rolloverHour)), to: date) ?? date
        let c = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(fromKey key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    /// Which items stay when a new day starts: pinned ones, everything in a pinned section or category,
    /// and open PRs when you carry them.
    static func carryOver(_ items: [DailyShelfItem], carryOpenPRs: Bool, pinnedGroups: Set<String> = []) -> (kept: [DailyShelfItem], left: [DailyShelfItem]) {
        var kept: [DailyShelfItem] = [], left: [DailyShelfItem] = []
        for var it in items {
            let openPR = it.kind == .pr && (it.github?.state ?? .open) == .open
            let inPinnedGroup = pinnedGroups.contains(it.groupKey) || pinnedGroups.contains("section:\(it.kind.rawValue)")
            if it.pinned || inPinnedGroup || (carryOpenPRs && openPR) {
                it.carried = it.pinned || inPinnedGroup ? nil : true
                kept.append(it)
            } else {
                left.append(it)
            }
        }
        return (kept, left)
    }
}

// MARK: - Placement

/// Where the shelf sits: an edge, a spot along it, and its size. Pure, so every edge and clamp is testable.
enum DailyShelfEdge: Int, CaseIterable {
    case left, right, top, bottom
    var title: String { ["Left", "Right", "Top", "Bottom"][rawValue] }
    var isVertical: Bool { self == .left || self == .right }
}

enum DailyShelfAlign: Int, CaseIterable {
    case start, center, end
    func title(for edge: DailyShelfEdge) -> String {
        edge.isVertical ? ["Top", "Middle", "Bottom"][rawValue] : ["Left", "Center", "Right"][rawValue]
    }
}

struct DailyShelfPlacement: Equatable {
    var edge: DailyShelfEdge = .left
    var align: DailyShelfAlign = .center
    var offset: CGFloat = 0
    var attached = true
    var width: CGFloat = 360
    var minHeight: CGFloat = 420
    var maxHeight: CGFloat = 820
    var height: CGFloat = 620
    var radius: CGFloat = 22

    /// The concave shoulders where an attached shelf meets the screen edge.
    static let shoulder: CGFloat = 14
    static let floatGap: CGFloat = 12
    static let margin: CGFloat = 10

    struct Layout: Equatable {
        /// The window, in screen coordinates (y up).
        var frame: NSRect
        /// The card inside the window (window coordinates, y up).
        var body: NSRect
        /// The card's height after the min / max and screen clamps.
        var height: CGFloat
        var radius: CGFloat
        var shoulder: CGFloat
    }

    /// `area` is the screen's visible frame (menu bar and Dock excluded).
    func layout(in area: NSRect) -> Layout {
        let f = attached ? Self.shoulder : 0
        let gap = attached ? 0 : Self.floatGap
        let m = Self.margin
        let availH = edge.isVertical ? area.height - 2 * m - 2 * f : area.height - gap - m
        let lo = min(minHeight, availH), hi = max(lo, min(maxHeight, availH))
        let h = min(max(height, lo), hi)
        let w = min(width, edge.isVertical ? area.width - gap - m : area.width - 2 * m - 2 * f)
        let depth = edge.isVertical ? w : h, along = edge.isVertical ? h : w
        let a0 = (edge.isVertical ? area.minY : area.minX) + m + f
        let a1 = (edge.isVertical ? area.maxY : area.maxX) - m - f
        // Start is the top for side edges (y runs up) and the left for top / bottom.
        var pos: CGFloat
        switch (align, edge.isVertical) {
        case (.start, true): pos = a1 - along - offset
        case (.end, true): pos = a0 + offset
        case (.start, false): pos = a0 + offset
        case (.end, false): pos = a1 - along - offset
        case (.center, _): pos = (a0 + a1) / 2 - along / 2 + (edge.isVertical ? -offset : offset)
        }
        pos = min(max(pos, a0), max(a0, a1 - along))
        let r = max(0, min(radius, min(depth, along) / 2 - 1))
        var frame: NSRect, body: NSRect
        switch edge {
        case .left:
            frame = NSRect(x: area.minX + gap, y: pos - f, width: depth, height: along + 2 * f)
            body = NSRect(x: 0, y: f, width: depth, height: along)
        case .right:
            frame = NSRect(x: area.maxX - gap - depth, y: pos - f, width: depth, height: along + 2 * f)
            body = NSRect(x: 0, y: f, width: depth, height: along)
        case .top:
            frame = NSRect(x: pos - f, y: area.maxY - gap - depth, width: along + 2 * f, height: depth)
            body = NSRect(x: f, y: 0, width: along, height: depth)
        case .bottom:
            frame = NSRect(x: pos - f, y: area.minY + gap, width: along + 2 * f, height: depth)
            body = NSRect(x: f, y: 0, width: along, height: depth)
        }
        return Layout(frame: frame, body: body, height: h, radius: r, shoulder: f)
    }

    /// The outline in window coordinates (y up). Attached: open along the screen edge, with
    /// concave shoulders. Floating: a rounded rectangle. `closed` adds the edge side for filling.
    static func outline(_ l: Layout, edge: DailyShelfEdge, attached: Bool, closed: Bool) -> CGPath {
        let b = l.body, r = l.radius
        guard attached else { return CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil) }
        let f = l.shoulder
        // Built for the left edge (x = 0 is the screen edge, y up), then mapped to the real edge.
        let D = edge.isVertical ? b.width : b.height, L = edge.isVertical ? b.height : b.width
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addArc(center: CGPoint(x: f, y: 0), radius: f, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: D - r, y: f))
        p.addArc(center: CGPoint(x: D - r, y: f + r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        p.addLine(to: CGPoint(x: D, y: f + L - r))
        p.addArc(center: CGPoint(x: D - r, y: f + L - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: f, y: f + L))
        p.addArc(center: CGPoint(x: f, y: L + 2 * f), radius: f, startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
        if closed { p.closeSubpath() }
        var t: CGAffineTransform
        switch edge {
        case .left: t = .identity
        case .right: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: D, ty: 0)
        case .bottom: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .top: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: D)
        }
        return p.copy(using: &t) ?? p
    }
}

// MARK: - Standup

/// Done / Doing / Reviewing / Ready to merge, drafted from the shelf only.
enum DailyShelfStandup {
    struct Draft: Equatable { var done: [String] = []; var doing: [String] = []; var reviewing: [String] = []; var ready: [String] = [] }

    static func draft(_ items: [DailyShelfItem]) -> Draft {
        var d = Draft()
        for it in items {
            if it.kind == .pr, let g = it.github {
                let line = "\(g.repo) #\(g.number) \(it.title == "\(g.repo) #\(g.number)" ? "" : it.title)".trimmingCharacters(in: .whitespaces)
                let s = DailyShelfPRStatus.of(g)
                switch s.group {
                case .done: d.done.append(g.state == .merged ? "Merged \(line)" : "Closed \(line)")
                case .ready: d.ready.append(line)
                case .yourMove:
                    if g.review == .requested { d.reviewing.append(line) }
                    else { d.doing.append(line + (g.ci == .failing ? " (fixing failing checks)" : g.review == .changesRequested ? " (addressing review)" : "")) }
                case .waiting: if g.mine != false { d.doing.append(line) }
                }
            } else if it.kind == .jira, let key = it.jiraKey {
                d.doing.append(it.title == key ? key : "\(key) \(it.title)")
            }
        }
        return d
    }

    static func text(_ d: Draft, day: String) -> String {
        var parts = ["Standup, \(day)"]
        for (t, a) in [("Done", d.done), ("Doing", d.doing), ("Reviewing", d.reviewing), ("Ready to merge", d.ready)] where !a.isEmpty {
            parts.append(t + "\n" + a.map { "- " + $0 }.joined(separator: "\n"))
        }
        if parts.count == 1 { parts.append("Nothing on the shelf yet.") }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Dropping the shelf somewhere new

extension DailyShelfPlacement {
    /// Within this distance of a corner the shelf locks into it; near the middle, into the middle.
    static let cornerSnap: CGFloat = 96
    static let middleSnap: CGFloat = 48

    /// Where a shelf dragged by `travel` and let go at `frame` (pointer at `pointer`) settles: the edge
    /// the pointer is nearest to, leaning toward the way it was dragged, then a corner or the middle when
    /// it lands near one, else the exact spot along that edge.
    static func snap(frame f: NSRect, pointer p: NSPoint, travel d: CGPoint, area a: NSRect, current: DailyShelfPlacement) -> DailyShelfPlacement {
        var dist: [DailyShelfEdge: CGFloat] = [.left: p.x - a.minX, .right: a.maxX - p.x, .bottom: p.y - a.minY, .top: a.maxY - p.y]
        let len = (d.x * d.x + d.y * d.y).squareRoot()
        if len > 24 {
            let ux = d.x / len, uy = d.y / len, lean: CGFloat = 120
            dist[.left]! -= lean * max(0, -ux); dist[.right]! -= lean * max(0, ux)
            dist[.bottom]! -= lean * max(0, -uy); dist[.top]! -= lean * max(0, uy)
        }
        let edge = DailyShelfEdge.allCases.min { dist[$0]! < dist[$1]! } ?? current.edge
        var out = current
        out.edge = edge
        out.align = .start
        out.offset = 0
        let l = out.layout(in: a)
        let L = edge.isVertical ? l.body.height : l.body.width
        let sh = current.attached ? shoulder : 0
        let a0 = (edge.isVertical ? a.minY : a.minX) + margin + sh
        let a1 = (edge.isVertical ? a.maxY : a.maxX) - margin - sh
        let dropped = edge.isVertical ? f.midY : f.midX
        let pos = min(max(dropped - L / 2, a0), max(a0, a1 - L))
        let mid = (a0 + a1) / 2
        if edge.isVertical {
            if (a1 - L) - pos < cornerSnap { out.align = .start }                 // top corner
            else if pos - a0 < cornerSnap { out.align = .end }                    // bottom corner
            else if abs(pos + L / 2 - mid) < middleSnap { out.align = .center }
            else { out.align = .start; out.offset = ((a1 - L) - pos).rounded() }
        } else {
            if pos - a0 < cornerSnap { out.align = .start }                       // left corner
            else if (a1 - L) - pos < cornerSnap { out.align = .end }              // right corner
            else if edge != .top, abs(pos + L / 2 - mid) < middleSnap { out.align = .center }
            else { out.align = .start; out.offset = (pos - a0).rounded() }
        }
        return out
    }
}

// MARK: - Your order

enum DailyShelfOrder {
    /// `items` in your saved order first, the rest after in their default order.
    static func apply(_ saved: [String], to items: [String]) -> [String] {
        let known = saved.filter(items.contains)
        return known + items.filter { !known.contains($0) }
    }

    /// `shown` with `moving` placed before `before` (nil: at the end).
    static func move(_ moving: String, before: String?, in shown: [String]) -> [String] {
        var out = shown.filter { $0 != moving }
        if let b = before, let i = out.firstIndex(of: b) { out.insert(moving, at: i) } else { out.append(moving) }
        return out
    }
}
