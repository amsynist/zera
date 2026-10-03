import Foundation
import AppKit

/// One line in the GitHub feed.
struct GHEvent: Equatable {
    enum Kind: String {
        case prOpened, reviewRequested, ciRunning, ciPassed, ciFailed, needsApproval
        /// Activity on a PR you raised in the last 24 hours.
        case prApproved, prChangesRequested, prCommented
    }

    let id: String
    let kind: Kind
    let title: String
    /// "owner/repo #123"
    let subtitle: String
    let date: Date
    let url: URL
    /// Set for runs that can be approved from here.
    let approval: Approval?
    /// A PR you authored (or activity on one).
    var mine = false

    struct Approval: Equatable {
        let owner: String
        let repo: String
        let runID: Int
        /// `waiting` = deployment protection rule; otherwise a first-time-contributor hold.
        let waiting: Bool
    }

    static func == (a: GHEvent, b: GHEvent) -> Bool { a.id == b.id }

    var symbol: String {
        switch kind {
        case .prOpened: return "arrow.triangle.pull"
        case .reviewRequested: return "eye"
        case .ciRunning: return "circle.dotted"
        case .ciPassed: return "checkmark.circle.fill"
        case .ciFailed: return "xmark.octagon.fill"
        case .needsApproval: return "hand.raised.fill"
        case .prApproved: return "checkmark.seal.fill"
        case .prChangesRequested: return "exclamationmark.bubble.fill"
        case .prCommented: return "text.bubble.fill"
        }
    }

    var tint: NSColor {
        let p = Pal
        switch kind {
        case .prOpened: return p.accent
        case .reviewRequested: return p.info
        case .ciRunning: return p.warning
        case .ciPassed: return p.success
        case .ciFailed: return p.danger
        case .needsApproval: return p.warning
        case .prApproved: return p.success
        case .prChangesRequested: return p.warning
        case .prCommented: return p.info
        }
    }

    var isCI: Bool { kind == .ciRunning || kind == .ciPassed || kind == .ciFailed }
    var isPR: Bool { kind == .prOpened || kind == .reviewRequested }
    /// Approvals, change requests and comments on your recent PRs.
    var isActivity: Bool { kind == .prApproved || kind == .prChangesRequested || kind == .prCommented }
}

enum GHError: LocalizedError {
    case noToken, http(Int, String), badResponse

    var errorDescription: String? {
        switch self {
        case .noToken: return "No GitHub token saved."
        case .http(let code, let msg): return "GitHub said \(code): \(msg)"
        case .badResponse: return "Unexpected response from GitHub."
        }
    }
}

/// Talks to the GitHub REST API with a personal access token, polls on a schedule, and
/// keeps a feed of what matters: PRs involving you, CI on your PRs, runs awaiting approval.
///
/// The token lives in `~/Library/Application Support/Zera/github.token` (mode 600) rather than
/// the Keychain, because an ad-hoc-signed dev build would re-prompt for Keychain access on
/// every rebuild. Move it to the Keychain once the app is signed with a real identity.
@MainActor
final class GitHubService {
    static let shared = GitHubService()

    nonisolated static let changed = Notification.Name("GitHubChanged")
    /// Posted with `userInfo["events"]: [GHEvent]` when a poll finds things you have not seen.
    nonisolated static let newEvents = Notification.Name("GitHubNewEvents")

    private(set) var login: String?
    private(set) var events: [GHEvent] = []
    private(set) var lastChecked: Date?
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    private(set) var unseen: Set<String> = []

    /// Every 2 minutes: ~20 small requests per poll, far inside the 5 000/hour limit.
    let pollInterval: TimeInterval = 120
    /// Approvals and comments are watched on PRs you raised within this window.
    static let activityWindow: TimeInterval = 24 * 3600
    private var timer: Timer?
    private var seen: Set<String> = []
    private static let seenKey = "zera.github.seen"
    private static let loginKey = "zera.github.login"

    private init() {
        seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        login = UserDefaults.standard.string(forKey: Self.loginKey)
    }

    // MARK: - Token

    private var tokenURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("github.token")
    }

    var token: String? {
        guard let s = try? String(contentsOf: tokenURL, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var isConnected: Bool { token != nil && login != nil }

    private func save(token: String) throws {
        try token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    }

    /// Verifies the token, remembers who you are, and starts polling.
    func connect(token raw: String) async throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw GHError.noToken }
        let user = try await get("/user", token: t)
        guard let name = user["login"] as? String else { throw GHError.badResponse }
        try save(token: t)
        login = name
        UserDefaults.standard.set(name, forKey: Self.loginKey)
        lastError = nil
        // First connect: everything that exists already is old news.
        let first = seen.isEmpty
        await refresh(quiet: first)
        startPolling(immediately: false)
        return name
    }

    func disconnect() {
        timer?.invalidate(); timer = nil
        try? FileManager.default.removeItem(at: tokenURL)
        login = nil
        events = []
        unseen = []
        lastChecked = nil
        lastError = nil
        UserDefaults.standard.removeObject(forKey: Self.loginKey)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: - Polling

    func startPolling(immediately: Bool = true) {
        timer?.invalidate()
        guard token != nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if immediately { Task { await refresh() } }
    }

    func markAllSeen() {
        guard !unseen.isEmpty else { return }
        unseen.removeAll()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Pulls everything and diffs against what you have already seen.
    func refresh(quiet: Bool = false) async {
        guard let token = token, !isRefreshing else { return }
        isRefreshing = true
        NotificationCenter.default.post(name: Self.changed, object: nil)
        defer {
            isRefreshing = false
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
        do {
            if login == nil {
                let user = try await get("/user", token: token)
                login = user["login"] as? String
                UserDefaults.standard.set(login, forKey: Self.loginKey)
            }
            var found: [GHEvent] = []

            // Two sources, because GitHub's search index can lag a new PR by minutes:
            //  1. the pull-request lists of the repos you pushed to most recently (real time),
            //  2. search for PRs involving you / in your repos (catches mentions anywhere).
            let (live, liveReviewIDs) = (try? await recentRepoPRs(token: token)) ?? ([], [])
            let involving = (try? await searchPRs("is:pr is:open involves:@me", token: token)) ?? []
            let mine = (try? await searchPRs("is:pr is:open user:@me", token: token)) ?? []
            let reviews = (try? await searchPRs("is:pr is:open review-requested:@me", token: token)) ?? []
            if live.isEmpty && involving.isEmpty && mine.isEmpty && reviews.isEmpty {
                // Everything failed at once — surface it rather than pretending the board is clear.
                _ = try await searchPRs("is:pr is:open involves:@me", token: token)
            }
            let reviewIDs = Set(reviews.map { $0.id }).union(liveReviewIDs)

            var prs: [PRRef] = []
            var seenIDs = Set<String>()
            for pr in live + involving + mine where !seenIDs.contains(pr.id) {
                seenIDs.insert(pr.id)
                prs.append(pr)
            }

            for pr in prs {
                let isReview = reviewIDs.contains(pr.id)
                let kind: GHEvent.Kind = isReview ? .reviewRequested : .prOpened
                let who = pr.author == login ? "" : " · by \(pr.author)"
                found.append(GHEvent(id: "pr-\(pr.id)", kind: kind,
                                     title: pr.title,
                                     subtitle: "\(pr.repo) #\(pr.number)\(who)",
                                     date: pr.updated, url: pr.url, approval: nil, mine: pr.author == login))
            }

            // Approvals, change requests and comments on the PRs you raised in the last day.
            let recentCutoff = Date().addingTimeInterval(-Self.activityWindow)
            for pr in prs.filter({ $0.author == login && $0.created > recentCutoff }).prefix(10) {
                if let acts = try? await activity(on: pr, since: recentCutoff, token: token) { found.append(contentsOf: acts) }
            }

            // CI and approvals on PRs you authored.
            for pr in prs.filter({ $0.author == login }).prefix(12) {
                guard let sha = try? await headSHA(pr, token: token) else { continue }
                let ci = try? await checkState(pr, sha: sha, token: token)
                if let ci = ci {
                    found.append(ci)
                }
                if let runs = try? await approvableRuns(pr, sha: sha, token: token) {
                    found.append(contentsOf: runs)
                }
            }

            found.sort { $0.date > $1.date }
            events = found
            lastChecked = Date()
            lastError = nil

            let fresh = found.filter { !seen.contains($0.id) }
            for e in found { seen.insert(e.id) }
            // Keep the seen set from growing forever.
            if seen.count > 2000 { seen = Set(found.map { $0.id }) }
            UserDefaults.standard.set(Array(seen), forKey: Self.seenKey)

            if !quiet && !fresh.isEmpty {
                for e in fresh { unseen.insert(e.id) }
                NotificationCenter.default.post(name: Self.newEvents, object: nil, userInfo: ["events": fresh])
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Actions

    func approve(_ e: GHEvent) async throws {
        guard let token = token, let a = e.approval else { throw GHError.noToken }
        let base = "/repos/\(a.owner)/\(a.repo)/actions/runs/\(a.runID)"
        if a.waiting {
            let pending = try await getArray("\(base)/pending_deployments", token: token)
            let envIDs = pending.compactMap { ($0["environment"] as? [String: Any])?["id"] as? Int }
            guard !envIDs.isEmpty else { throw GHError.badResponse }
            _ = try await post("\(base)/pending_deployments", token: token,
                               body: ["environment_ids": envIDs, "state": "approved", "comment": "Approved from Zera"])
        } else {
            _ = try await post("\(base)/approve", token: token, body: [:])
        }
        events.removeAll { $0.id == e.id }
        unseen.remove(e.id)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: - Pieces

    private struct PRRef {
        let id: String        // "owner/repo#123"
        let owner: String
        let repo: String
        let number: Int
        let title: String
        let author: String
        let updated: Date
        let created: Date
        let url: URL
        var fullRepo: String { "\(owner)/\(repo)" }
        var repoName: String { fullRepo }
        var repoDisplay: String { fullRepo }
    }

    private func searchPRs(_ q: String, token: String) async throws -> [PRRef] {
        let query = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let json = try await get("/search/issues?q=\(query)&sort=updated&per_page=20", token: token)
        let items = json["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let repoURL = item["repository_url"] as? String,
                  let number = item["number"] as? Int,
                  let title = item["title"] as? String,
                  let html = item["html_url"] as? String, let url = URL(string: html) else { return nil }
            let parts = repoURL.split(separator: "/")
            guard parts.count >= 2 else { return nil }
            let owner = String(parts[parts.count - 2]), repo = String(parts[parts.count - 1])
            let author = (item["user"] as? [String: Any])?["login"] as? String ?? "someone"
            let updated = Self.iso.date(from: item["updated_at"] as? String ?? "") ?? Date()
            let created = Self.iso.date(from: item["created_at"] as? String ?? "") ?? updated
            return PRRef(id: "\(owner)/\(repo)#\(number)", owner: owner, repo: repo, number: number,
                         title: title, author: author, updated: updated, created: created, url: url)
        }
    }

    /// Open PRs you authored, were assigned, or were asked to review, read straight from the
    /// repos you pushed to most recently. Unlike search this is not index-lagged, so the PR you
    /// just raised shows up on the next poll. Returns the refs and the ids that are review requests.
    private func recentRepoPRs(token: String) async throws -> ([PRRef], Set<String>) {
        guard let me = login else { return ([], []) }
        let repos = try await getArray("/user/repos?sort=pushed&direction=desc&per_page=15&affiliation=owner,collaborator,organization_member", token: token)
        var out: [PRRef] = []
        var reviewIDs = Set<String>()
        for r in repos {
            guard let full = r["full_name"] as? String else { continue }
            let parts = full.split(separator: "/")
            guard parts.count == 2 else { continue }
            let owner = String(parts[0]), repo = String(parts[1])
            let pulls = (try? await getArray("/repos/\(full)/pulls?state=open&sort=updated&direction=desc&per_page=30", token: token)) ?? []
            for p in pulls {
                let author = (p["user"] as? [String: Any])?["login"] as? String ?? ""
                let reviewers = (p["requested_reviewers"] as? [[String: Any]])?.compactMap { $0["login"] as? String } ?? []
                let assignees = (p["assignees"] as? [[String: Any]])?.compactMap { $0["login"] as? String } ?? []
                guard author == me || reviewers.contains(me) || assignees.contains(me) else { continue }
                guard let number = p["number"] as? Int, let title = p["title"] as? String,
                      let html = p["html_url"] as? String, let url = URL(string: html) else { continue }
                let updated = Self.iso.date(from: p["updated_at"] as? String ?? "") ?? Date()
                let created = Self.iso.date(from: p["created_at"] as? String ?? "") ?? updated
                let ref = PRRef(id: "\(owner)/\(repo)#\(number)", owner: owner, repo: repo, number: number,
                                title: title, author: author, updated: updated, created: created, url: url)
                out.append(ref)
                if reviewers.contains(me) { reviewIDs.insert(ref.id) }
            }
        }
        return (out, reviewIDs)
    }

    /// Reviews (approved / changes requested / commented) and comments by other people on one
    /// of your PRs, newer than `since`.
    private func activity(on pr: PRRef, since: Date, token: String) async throws -> [GHEvent] {
        guard let me = login else { return [] }
        var out: [GHEvent] = []
        let base = "/repos/\(pr.owner)/\(pr.repo)"
        let sinceISO = Self.iso.string(from: since)
        let sub = "\(pr.repo) #\(pr.number)"

        let reviews = (try? await getArray("\(base)/pulls/\(pr.number)/reviews?per_page=50", token: token)) ?? []
        for r in reviews {
            let who = (r["user"] as? [String: Any])?["login"] as? String ?? "someone"
            guard who != me, let id = r["id"] as? Int,
                  let at = Self.iso.date(from: r["submitted_at"] as? String ?? ""), at > since else { continue }
            let state = (r["state"] as? String ?? "").uppercased()
            let body = Self.snippet(r["body"] as? String)
            let url = URL(string: r["html_url"] as? String ?? "") ?? pr.url
            switch state {
            case "APPROVED":
                out.append(GHEvent(id: "review-\(id)", kind: .prApproved, title: "\(who) approved your PR", subtitle: sub, date: at, url: url, approval: nil, mine: true))
            case "CHANGES_REQUESTED":
                out.append(GHEvent(id: "review-\(id)", kind: .prChangesRequested, title: "\(who) requested changes" + (body.isEmpty ? "" : ": \(body)"), subtitle: sub, date: at, url: url, approval: nil, mine: true))
            case "COMMENTED" where !body.isEmpty:
                out.append(GHEvent(id: "review-\(id)", kind: .prCommented, title: "\(who): \(body)", subtitle: sub, date: at, url: url, approval: nil, mine: true))
            default: break
            }
        }
        // Conversation comments and inline review comments.
        for path in ["\(base)/issues/\(pr.number)/comments?since=\(sinceISO)&per_page=50",
                     "\(base)/pulls/\(pr.number)/comments?since=\(sinceISO)&per_page=50"] {
            let comments = (try? await getArray(path, token: token)) ?? []
            for c in comments {
                let who = (c["user"] as? [String: Any])?["login"] as? String ?? "someone"
                guard who != me, let id = c["id"] as? Int,
                      let at = Self.iso.date(from: c["created_at"] as? String ?? ""), at > since else { continue }
                let body = Self.snippet(c["body"] as? String)
                let url = URL(string: c["html_url"] as? String ?? "") ?? pr.url
                out.append(GHEvent(id: "comment-\(id)", kind: .prCommented, title: "\(who): \(body.isEmpty ? "commented" : body)", subtitle: sub, date: at, url: url, approval: nil, mine: true))
            }
        }
        return out
    }

    /// First meaningful line of a comment, trimmed for a row title.
    private static func snippet(_ body: String?) -> String {
        let one = (body ?? "").replacingOccurrences(of: "\r", with: "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") }.joined(separator: " ")
        return one.count > 90 ? String(one.prefix(88)) + "…" : one
    }

    private func headSHA(_ pr: PRRef, token: String) async throws -> String {
        let json = try await get("/repos/\(pr.owner)/\(pr.repo)/pulls/\(pr.number)", token: token)
        guard let sha = (json["head"] as? [String: Any])?["sha"] as? String else { throw GHError.badResponse }
        return sha
    }

    /// One summary line for all check runs on the PR's head commit.
    private func checkState(_ pr: PRRef, sha: String, token: String) async throws -> GHEvent? {
        let json = try await get("/repos/\(pr.owner)/\(pr.repo)/commits/\(sha)/check-runs?per_page=50", token: token)
        let runs = json["check_runs"] as? [[String: Any]] ?? []
        guard !runs.isEmpty else { return nil }
        var failed: [String] = [], running = 0
        var latest = Date.distantPast
        for r in runs {
            let status = r["status"] as? String ?? ""
            let conclusion = r["conclusion"] as? String ?? ""
            let name = r["name"] as? String ?? "check"
            if status != "completed" { running += 1 }
            else if ["failure", "timed_out", "cancelled", "action_required"].contains(conclusion) { failed.append(name) }
            if let d = Self.iso.date(from: (r["completed_at"] as? String) ?? (r["started_at"] as? String) ?? ""), d > latest { latest = d }
        }
        let url = URL(string: "\(pr.url.absoluteString)/checks") ?? pr.url
        let sub = "\(pr.fullRepo) #\(pr.number)"
        if !failed.isEmpty {
            let list = failed.prefix(2).joined(separator: ", ") + (failed.count > 2 ? " +\(failed.count - 2)" : "")
            return GHEvent(id: "ci-\(pr.id)-\(sha)-failed", kind: .ciFailed, title: "CI failed: \(list)",
                           subtitle: sub, date: latest == .distantPast ? pr.updated : latest, url: url, approval: nil)
        }
        if running > 0 {
            return GHEvent(id: "ci-\(pr.id)-\(sha)-running", kind: .ciRunning,
                           title: running == 1 ? "1 check running" : "\(running) checks running",
                           subtitle: sub, date: pr.updated, url: url, approval: nil)
        }
        return GHEvent(id: "ci-\(pr.id)-\(sha)-passed", kind: .ciPassed, title: "All \(runs.count) checks passed",
                       subtitle: sub, date: latest == .distantPast ? pr.updated : latest, url: url, approval: nil)
    }

    /// Workflow runs on the PR's head that are stuck waiting for someone to say yes.
    private func approvableRuns(_ pr: PRRef, sha: String, token: String) async throws -> [GHEvent] {
        let json = try await get("/repos/\(pr.owner)/\(pr.repo)/actions/runs?head_sha=\(sha)&per_page=20", token: token)
        let runs = json["workflow_runs"] as? [[String: Any]] ?? []
        return runs.compactMap { r in
            let status = r["status"] as? String ?? ""
            let conclusion = r["conclusion"] as? String ?? ""
            let waiting = status == "waiting"
            guard waiting || conclusion == "action_required",
                  let id = r["id"] as? Int,
                  let html = r["html_url"] as? String, let url = URL(string: html) else { return nil }
            let name = r["name"] as? String ?? "workflow"
            let date = Self.iso.date(from: r["updated_at"] as? String ?? "") ?? pr.updated
            return GHEvent(id: "approve-\(pr.id)-\(id)", kind: .needsApproval,
                           title: waiting ? "\(name) is waiting for approval" : "\(name) needs approval to run",
                           subtitle: "\(pr.fullRepo) #\(pr.number)", date: date, url: url,
                           approval: .init(owner: pr.owner, repo: pr.repo, runID: id, waiting: waiting))
        }
    }

    // MARK: - HTTP

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    private func request(_ path: String, token: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Zera-macOS", forHTTPHeaderField: "User-Agent")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GHError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
            throw GHError.http(http.statusCode, msg)
        }
        return data
    }

    private func get(_ path: String, token: String) async throws -> [String: Any] {
        let data = try await request(path, token: token)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GHError.badResponse }
        return json
    }

    private func getArray(_ path: String, token: String) async throws -> [[String: Any]] {
        let data = try await request(path, token: token)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GHError.badResponse }
        return json
    }

    @discardableResult
    private func post(_ path: String, token: String, body: [String: Any]) async throws -> Data {
        try await request(path, token: token, method: "POST", body: body)
    }
}

/// "2 min ago", "3 h ago", "yesterday"…
func relativeTime(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60) min ago" }
    if s < 86400 { return "\(s / 3600) h ago" }
    if s < 172800 { return "yesterday" }
    return "\(s / 86400) d ago"
}
