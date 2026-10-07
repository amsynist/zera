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
    /// "owner/repo#123" of the pull request this event belongs to, when there is one.
    var prID: String? = nil

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

/// One open pull request as the PR screen shows it: where it lives, who is on it, and what
/// state its checks and reviews are in.
struct GHPullRequest: Equatable {
    enum CI: Equatable { case none, running, passed, failed }
    enum Review: Equatable { case none, approved, changesRequested }
    struct Person: Equatable { let login: String; let avatar: URL? }
    struct Check: Equatable { let name: String; let title: String; let summary: String; let url: URL? }

    let id: String            // "owner/repo#123"
    let owner: String
    let repo: String
    let number: Int
    var title: String
    var author: Person
    var created: Date
    var updated: Date
    var url: URL
    var draft = false
    var labels: [String] = []
    var branch: String?
    var base: String?
    /// Requested reviewers plus everyone who has reviewed, without duplicates.
    var reviewers: [Person] = []
    var approvedBy: [String] = []
    var changesBy: [String] = []
    var comments = 0
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var ci: CI = .none
    var checksTotal = 0
    var failing: [Check] = []
    var review: Review = .none
    /// You were asked to review it.
    var reviewRequested = false
    /// You opened it.
    var mine = false
    /// Workflow runs on it waiting for someone to approve them.
    var approvalsWaiting = 0

    var fullRepo: String { "\(owner)/\(repo)" }
    var filesURL: URL { URL(string: url.absoluteString + "/files") ?? url }
    var checksURL: URL { URL(string: url.absoluteString + "/checks") ?? url }

    static func == (a: GHPullRequest, b: GHPullRequest) -> Bool {
        a.id == b.id && a.updated == b.updated && a.ci == b.ci && a.approvalsWaiting == b.approvalsWaiting && a.review == b.review
    }
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
/// The token lives in the login Keychain (`KeychainStore`, account `github-token`) and is only
/// ever sent to api.github.com. A token left by older builds in a plain file is moved into the
/// Keychain on launch and the file is deleted.
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
    /// Open PRs involving you, newest activity first — what the PR screen lists.
    private(set) var pulls: [GHPullRequest] = []

    /// PRs that have news you have not looked at yet (new PR, review, comment, CI change).
    var unseenPRIDs: Set<String> { Set(events.filter { unseen.contains($0.id) }.compactMap { $0.prID }) }
    /// The token was refused (expired / revoked) rather than GitHub being unreachable.
    var authExpired: Bool {
        guard let e = lastError else { return false }
        return e.contains("401") || e.localizedCaseInsensitiveContains("bad credentials")
    }
    /// How many PRs get the full treatment (details, reviews, checks) each poll.
    private static let maxTracked = 30
    /// The PR screen covers PRs opened in this window, across your repos.
    static let openedWindow: TimeInterval = 24 * 3600
    private struct PRDetail { let updated: Date; let pull: [String: Any]; let reviews: [[String: Any]] }
    /// PR details and reviews, reused until the PR's `updated_at` moves.
    private var detailCache: [String: PRDetail] = [:]
    private var reviewed: Set<String> = []
    private static let reviewedKey = "zera.github.reviewed"

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
        reviewed = Set(UserDefaults.standard.stringArray(forKey: Self.reviewedKey) ?? [])
        login = UserDefaults.standard.string(forKey: Self.loginKey)
        pruneBriefs(olderThan: 0)
    }

    // MARK: - Token

    /// Where builds before the Keychain move kept the token. Read once to migrate, then deleted.
    private var legacyTokenURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera/github.token")
    }

    /// Kept in memory after the first Keychain read so polling doesn't hit the Keychain each time.
    private var cachedToken: String??

    var token: String? {
        if let c = cachedToken { return c }
        migrateLegacyToken()
        let t = KeychainStore.read(.githubToken)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (t?.isEmpty ?? true) ? nil : t
        cachedToken = .some(value)
        return value
    }

    var isConnected: Bool { token != nil && login != nil }

    /// Shows sample PRs without a token or a request (the screen renders).
    func preview(login: String, pulls: [GHPullRequest]) {
        cachedToken = .some("preview")
        self.login = login
        self.pulls = pulls
        lastChecked = Date().addingTimeInterval(-60)
        lastError = nil
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func save(token: String) throws {
        guard KeychainStore.write(token, to: .githubToken) else { throw GHError.badResponse }
        cachedToken = .some(token)
    }

    private func migrateLegacyToken() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyTokenURL.path) else { return }
        if let s = try? String(contentsOf: legacyTokenURL, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !KeychainStore.has(.githubToken) { KeychainStore.write(t, to: .githubToken) }
        }
        try? fm.removeItem(at: legacyTokenURL)
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
        KeychainStore.delete(.githubToken)
        cachedToken = .some(nil)
        try? FileManager.default.removeItem(at: legacyTokenURL)
        login = nil
        events = []
        pulls = []
        detailCache = [:]
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
            // PRs opened in the last 24 hours, from two sources (GitHub's search index can lag a
            // new PR by minutes): every open PR in the repos you pushed to most recently (real
            // time), plus searches for ones involving you or in your repos anywhere else.
            let openedCutoff = Date().addingTimeInterval(-Self.openedWindow)
            let since = "created:>=" + Self.iso.string(from: openedCutoff)
            let (live, liveReviewIDs) = (try? await recentRepoPRs(token: token, since: openedCutoff)) ?? ([], [])
            let involving = (try? await searchPRs("is:pr is:open involves:@me \(since)", token: token)) ?? []
            let mine = (try? await searchPRs("is:pr is:open user:@me \(since)", token: token)) ?? []
            let reviews = (try? await searchPRs("is:pr is:open review-requested:@me \(since)", token: token)) ?? []
            // Your open PRs that someone approved, however old: they belong under Approvals.
            let approvedMine = (try? await searchPRs("is:pr is:open author:@me review:approved archived:false", token: token)) ?? []
            let approvedMineIDs = Set(approvedMine.map { $0.id })
            if live.isEmpty && involving.isEmpty && mine.isEmpty && reviews.isEmpty {
                // Everything failed at once — surface it rather than pretending the board is clear.
                _ = try await searchPRs("is:pr is:open involves:@me \(since)", token: token)
            }
            let reviewIDs = Set(reviews.map { $0.id }).union(liveReviewIDs)
            // Only PRs that concern you become notifications; the rest just appear on the screen.
            let relevantIDs = reviewIDs.union(involving.map { $0.id }).union(mine.map { $0.id })

            // Merge the sources; the live pull lists carry the most detail, so they win.
            var prs: [PRRef] = []
            var seenIDs = Set<String>()
            for pr in live + involving + mine + reviews + approvedMine
            where !seenIDs.contains(pr.id) && (pr.created >= openedCutoff || approvedMineIDs.contains(pr.id)) {
                seenIDs.insert(pr.id)
                prs.append(pr)
            }
            prs.sort { $0.updated > $1.updated }

            // Older approved PRs of yours are listed, not announced again.
            for pr in prs where pr.created >= openedCutoff && (pr.author == login || relevantIDs.contains(pr.id)) {
                let isReview = reviewIDs.contains(pr.id)
                let kind: GHEvent.Kind = isReview ? .reviewRequested : .prOpened
                let who = pr.author == login ? "" : " · by \(pr.author)"
                found.append(GHEvent(id: "pr-\(pr.id)", kind: kind,
                                     title: pr.title,
                                     subtitle: "\(pr.repo) #\(pr.number)\(who)",
                                     date: pr.updated, url: pr.url, approval: nil, mine: pr.author == login, prID: pr.id))
            }

            // Approvals, change requests and comments on the PRs you raised in the last day.
            let recentCutoff = Date().addingTimeInterval(-Self.activityWindow)
            for pr in prs.filter({ $0.author == login && $0.created > recentCutoff }).prefix(10) {
                if let acts = try? await activity(on: pr, since: recentCutoff, token: token) { found.append(contentsOf: acts) }
            }

            // Details, reviews and checks for the PR screen; CI events and approvable runs on
            // the PRs you authored.
            var built: [GHPullRequest] = []
            for pr in prs.prefix(Self.maxTracked) {
                var p = makePull(pr, reviewRequested: reviewIDs.contains(pr.id))
                var sha = pr.headSHA
                if let d = await detail(for: pr, token: token) {
                    apply(d, to: &p)
                    sha = sha ?? ((d.pull["head"] as? [String: Any])?["sha"] as? String)
                }
                if let sha = sha {
                    if let c = try? await checkSummary(pr, sha: sha, token: token) {
                        p.ci = c.ci; p.failing = c.failing; p.checksTotal = c.total
                        if p.mine, let e = c.event { found.append(e) }
                    }
                    if p.mine, let runs = try? await approvableRuns(pr, sha: sha, token: token) {
                        found.append(contentsOf: runs)
                        p.approvalsWaiting = runs.count
                    }
                }
                built.append(p)
            }
            // Anything beyond the tracked set still gets a row, just without checks.
            for pr in prs.dropFirst(Self.maxTracked) { built.append(makePull(pr, reviewRequested: reviewIDs.contains(pr.id))) }
            pulls = built
            detailCache = detailCache.filter { seenIDs.contains($0.key) }

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

    /// Approves every waiting workflow run on one PR.
    func approveRuns(for p: GHPullRequest) async throws {
        let runs = events.filter { $0.kind == .needsApproval && $0.prID == p.id }
        guard !runs.isEmpty else { throw GHError.badResponse }
        for e in runs { try await approve(e) }
        if let i = pulls.firstIndex(where: { $0.id == p.id }) { pulls[i].approvalsWaiting = 0 }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// "Mark reviewed" keeps a PR out of the Review tab until it changes again.
    func isMarkedReviewed(_ p: GHPullRequest) -> Bool { reviewed.contains(Self.reviewKey(p)) }

    func setReviewed(_ p: GHPullRequest, _ on: Bool) {
        if on { reviewed.insert(Self.reviewKey(p)) } else { reviewed.remove(Self.reviewKey(p)) }
        if reviewed.count > 500 { reviewed = Set(pulls.map { Self.reviewKey($0) }).intersection(reviewed) }
        UserDefaults.standard.set(Array(reviewed), forKey: Self.reviewedKey)
        for e in events where e.prID == p.id { unseen.remove(e.id) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private static func reviewKey(_ p: GHPullRequest) -> String { "\(p.id)@\(Int(p.updated.timeIntervalSince1970))" }

    func markSeen(_ p: GHPullRequest) {
        let ids = events.filter { $0.prID == p.id }.map { $0.id }
        guard ids.contains(where: { unseen.contains($0) }) else { return }
        ids.forEach { unseen.remove($0) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: - Briefs for Zera
    //
    // "Summarize" hands Claude a Markdown brief of the PR — description, checks, file list and
    // diff excerpts — written to Zera's caches folder (mode 600) and read like any dropped file.
    // Briefs are deleted after an hour (and on every launch): they can contain private source.

    private var briefsFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera/PRs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base
    }

    /// Removes briefs older than `age` seconds (0 = all).
    func pruneBriefs(olderThan age: TimeInterval = 3600) {
        BriefCleaner.prune(briefsFolder, olderThan: age)
    }

    private func writeBrief(_ text: String, name: String) throws -> URL {
        pruneBriefs()
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = briefsFolder.appendingPathComponent(safe)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func brief(for p: GHPullRequest) async throws -> URL {
        guard let token = token else { throw GHError.noToken }
        let base = "/repos/\(p.owner)/\(p.repo)/pulls/\(p.number)"
        let pull = (try? await get(base, token: token)) ?? [:]
        let files = (try? await getArray("\(base)/files?per_page=100", token: token)) ?? []
        var md = "# Pull request: \(p.title)\n\n"
        md += "- Repository: \(p.fullRepo) #\(p.number)\n- Author: @\(p.author.login)\n"
        if let b = p.branch { md += "- Branch: \(b) → \(p.base ?? "default")\n" }
        md += "- Opened: \(longAgo(p.created)), last update \(longAgo(p.updated))\n"
        md += "- CI: \(Self.ciText(p))\n"
        if !p.approvedBy.isEmpty { md += "- Approved by: \(p.approvedBy.joined(separator: ", "))\n" }
        if !p.changesBy.isEmpty { md += "- Changes requested by: \(p.changesBy.joined(separator: ", "))\n" }
        if let a = p.additions, let d = p.deletions { md += "- Size: +\(a) −\(d) in \(p.changedFiles ?? files.count) files\n" }
        if !p.labels.isEmpty { md += "- Labels: \(p.labels.joined(separator: ", "))\n" }
        let body = ((pull["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        md += "\n## Description\n\n" + (body.isEmpty ? "_No description._" : String(body.prefix(6000))) + "\n"
        if !p.failing.isEmpty {
            md += "\n## Failing checks\n"
            for c in p.failing.prefix(6) {
                md += "\n### \(c.name)\n" + (c.title.isEmpty ? "" : "\(c.title)\n") + String(c.summary.prefix(1500)) + "\n"
            }
        }
        if !files.isEmpty {
            md += "\n## Changed files\n\n"
            for f in files {
                md += "- \(f["filename"] as? String ?? "?") (\(f["status"] as? String ?? "changed"), +\(f["additions"] as? Int ?? 0) −\(f["deletions"] as? Int ?? 0))\n"
            }
            md += "\n## Diff excerpts\n"
            var budget = 40_000
            for f in files {
                guard budget > 0, let patch = f["patch"] as? String else { continue }
                let cut = String(patch.prefix(min(budget, 6000)))
                budget -= cut.count
                md += "\n### \(f["filename"] as? String ?? "?")\n```diff\n\(cut)\n```\n"
            }
        }
        return try writeBrief(md, name: "\(p.repo)-PR-\(p.number).md")
    }

    /// Every failing check across your open PRs, for "summarize the issues / check the logs".
    func failingChecksBrief() throws -> URL? {
        let bad = pulls.filter { $0.ci == .failed }
        guard !bad.isEmpty else { return nil }
        var md = "# Failing checks on open pull requests\n"
        for p in bad {
            md += "\n## \(p.fullRepo) #\(p.number): \(p.title)\n\(p.checksURL.absoluteString)\n"
            for c in p.failing.prefix(6) {
                md += "\n### \(c.name)\n" + (c.title.isEmpty ? "" : "\(c.title)\n") + String(c.summary.prefix(1500)) + "\n"
            }
        }
        return try writeBrief(md, name: "failing-checks.md")
    }

    static func ciText(_ p: GHPullRequest) -> String {
        switch p.ci {
        case .none: return "no checks"
        case .running: return "running"
        case .passed: return "all \(p.checksTotal) checks passed"
        case .failed: return "\(p.failing.count) of \(p.checksTotal) checks failing (\(p.failing.prefix(3).map { $0.name }.joined(separator: ", ")))"
        }
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
        var authorAvatar: URL? = nil
        var draft = false
        var labels: [String] = []
        var comments = 0
        var requested: [GHPullRequest.Person] = []
        var headSHA: String? = nil
        var branch: String? = nil
        var base: String? = nil
        var fullRepo: String { "\(owner)/\(repo)" }
        var repoName: String { fullRepo }
        var repoDisplay: String { fullRepo }
    }

    private static func person(_ any: Any?) -> GHPullRequest.Person? {
        guard let d = any as? [String: Any], let login = d["login"] as? String else { return nil }
        let avatar = (d["avatar_url"] as? String).flatMap { URL(string: $0.contains("?") ? "\($0)&s=64" : "\($0)?s=64") }
        return GHPullRequest.Person(login: login, avatar: avatar)
    }

    private static func labels(_ any: Any?) -> [String] {
        ((any as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    private func makePull(_ r: PRRef, reviewRequested: Bool) -> GHPullRequest {
        var p = GHPullRequest(id: r.id, owner: r.owner, repo: r.repo, number: r.number, title: r.title,
                              author: .init(login: r.author, avatar: r.authorAvatar),
                              created: r.created, updated: r.updated, url: r.url)
        p.draft = r.draft
        p.labels = r.labels
        p.comments = r.comments
        p.reviewers = r.requested
        p.branch = r.branch
        p.base = r.base
        p.mine = r.author == login
        p.reviewRequested = reviewRequested
        p.approvalsWaiting = events.filter { $0.kind == .needsApproval && $0.prID == r.id }.count
        // Keep last poll's checks for PRs outside the tracked set.
        if let old = pulls.first(where: { $0.id == r.id }) { p.ci = old.ci; p.failing = old.failing; p.checksTotal = old.checksTotal }
        return p
    }

    private func detail(for pr: PRRef, token: String) async -> PRDetail? {
        if let c = detailCache[pr.id], c.updated == pr.updated { return c }
        let base = "/repos/\(pr.owner)/\(pr.repo)/pulls/\(pr.number)"
        guard let pull = try? await get(base, token: token) else { return detailCache[pr.id] }
        let reviews = (try? await getArray("\(base)/reviews?per_page=100", token: token)) ?? []
        let d = PRDetail(updated: pr.updated, pull: pull, reviews: reviews)
        detailCache[pr.id] = d
        return d
    }

    private func apply(_ d: PRDetail, to p: inout GHPullRequest) {
        let j = d.pull
        p.branch = (j["head"] as? [String: Any])?["ref"] as? String ?? p.branch
        p.base = (j["base"] as? [String: Any])?["ref"] as? String ?? p.base
        p.comments = (j["comments"] as? Int ?? 0) + (j["review_comments"] as? Int ?? 0)
        p.additions = j["additions"] as? Int
        p.deletions = j["deletions"] as? Int
        p.changedFiles = j["changed_files"] as? Int
        p.draft = j["draft"] as? Bool ?? p.draft
        if let a = Self.person(j["user"]) { p.author = a }
        let ls = Self.labels(j["labels"]); if !ls.isEmpty { p.labels = ls }
        var people = ((j["requested_reviewers"] as? [[String: Any]]) ?? []).compactMap { Self.person($0) }
        // Latest decisive review per person.
        var latest: [String: String] = [:]
        for r in d.reviews {
            guard let who = Self.person(r["user"]), who.login != p.author.login else { continue }
            if !people.contains(where: { $0.login == who.login }) { people.append(who) }
            let state = (r["state"] as? String ?? "").uppercased()
            if state == "APPROVED" || state == "CHANGES_REQUESTED" || state == "DISMISSED" { latest[who.login] = state }
        }
        p.reviewers = people
        p.approvedBy = latest.filter { $0.value == "APPROVED" }.map { $0.key }.sorted()
        p.changesBy = latest.filter { $0.value == "CHANGES_REQUESTED" }.map { $0.key }.sorted()
        p.review = !p.changesBy.isEmpty ? .changesRequested : (!p.approvedBy.isEmpty ? .approved : .none)
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
            let user = Self.person(item["user"])
            let updated = Self.iso.date(from: item["updated_at"] as? String ?? "") ?? Date()
            let created = Self.iso.date(from: item["created_at"] as? String ?? "") ?? updated
            var ref = PRRef(id: "\(owner)/\(repo)#\(number)", owner: owner, repo: repo, number: number,
                            title: title, author: user?.login ?? "someone", updated: updated, created: created, url: url)
            ref.authorAvatar = user?.avatar
            ref.draft = item["draft"] as? Bool ?? false
            ref.labels = Self.labels(item["labels"])
            ref.comments = item["comments"] as? Int ?? 0
            return ref
        }
    }

    /// Every open PR opened since `since` in the repos you pushed to most recently (any author),
    /// read straight from each repo's pull list. Unlike search this is not index-lagged, so a
    /// PR raised a minute ago shows up on the next poll. Returns the refs and the ids that ask
    /// you for a review.
    private func recentRepoPRs(token: String, since: Date) async throws -> ([PRRef], Set<String>) {
        guard let me = login else { return ([], []) }
        let all = try await getArray("/user/repos?sort=pushed&direction=desc&per_page=30&affiliation=owner,collaborator,organization_member", token: token)
        // A repo nobody pushed to in a month is very unlikely to have a PR from today.
        let quiet = Date().addingTimeInterval(-30 * 86400)
        let repos = all.filter { (Self.iso.date(from: $0["pushed_at"] as? String ?? "") ?? Date()) > quiet }
        var out: [PRRef] = []
        var reviewIDs = Set<String>()
        for r in repos {
            guard let full = r["full_name"] as? String else { continue }
            let parts = full.split(separator: "/")
            guard parts.count == 2 else { continue }
            let owner = String(parts[0]), repo = String(parts[1])
            // Newest first, so we can stop at the first PR older than the window.
            let pulls = (try? await getArray("/repos/\(full)/pulls?state=open&sort=created&direction=desc&per_page=30", token: token)) ?? []
            for p in pulls {
                let author = (p["user"] as? [String: Any])?["login"] as? String ?? ""
                let reviewers = (p["requested_reviewers"] as? [[String: Any]])?.compactMap { $0["login"] as? String } ?? []
                guard let number = p["number"] as? Int, let title = p["title"] as? String,
                      let html = p["html_url"] as? String, let url = URL(string: html) else { continue }
                let updated = Self.iso.date(from: p["updated_at"] as? String ?? "") ?? Date()
                let created = Self.iso.date(from: p["created_at"] as? String ?? "") ?? updated
                if created < since { break }
                var ref = PRRef(id: "\(owner)/\(repo)#\(number)", owner: owner, repo: repo, number: number,
                                title: title, author: author, updated: updated, created: created, url: url)
                ref.authorAvatar = Self.person(p["user"])?.avatar
                ref.draft = p["draft"] as? Bool ?? false
                ref.labels = Self.labels(p["labels"])
                ref.requested = ((p["requested_reviewers"] as? [[String: Any]]) ?? []).compactMap { Self.person($0) }
                let head = p["head"] as? [String: Any]
                ref.headSHA = head?["sha"] as? String
                ref.branch = head?["ref"] as? String
                ref.base = (p["base"] as? [String: Any])?["ref"] as? String
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
                out.append(GHEvent(id: "review-\(id)", kind: .prApproved, title: "\(who) approved your PR", subtitle: sub, date: at, url: url, approval: nil, mine: true, prID: pr.id))
            case "CHANGES_REQUESTED":
                out.append(GHEvent(id: "review-\(id)", kind: .prChangesRequested, title: "\(who) requested changes" + (body.isEmpty ? "" : ": \(body)"), subtitle: sub, date: at, url: url, approval: nil, mine: true, prID: pr.id))
            case "COMMENTED" where !body.isEmpty:
                out.append(GHEvent(id: "review-\(id)", kind: .prCommented, title: "\(who): \(body)", subtitle: sub, date: at, url: url, approval: nil, mine: true, prID: pr.id))
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
                out.append(GHEvent(id: "comment-\(id)", kind: .prCommented, title: "\(who): \(body.isEmpty ? "commented" : body)", subtitle: sub, date: at, url: url, approval: nil, mine: true, prID: pr.id))
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

    private struct CheckSummary {
        var ci: GHPullRequest.CI
        var failing: [GHPullRequest.Check]
        var total: Int
        var event: GHEvent?
    }

    /// All check runs on the PR's head commit, folded into one state plus the failing ones.
    private func checkSummary(_ pr: PRRef, sha: String, token: String) async throws -> CheckSummary {
        let json = try await get("/repos/\(pr.owner)/\(pr.repo)/commits/\(sha)/check-runs?per_page=100", token: token)
        let runs = json["check_runs"] as? [[String: Any]] ?? []
        guard !runs.isEmpty else { return CheckSummary(ci: .none, failing: [], total: 0, event: nil) }
        var failed: [GHPullRequest.Check] = [], running = 0
        var latest = Date.distantPast
        for r in runs {
            let status = r["status"] as? String ?? ""
            let conclusion = r["conclusion"] as? String ?? ""
            let name = r["name"] as? String ?? "check"
            if status != "completed" { running += 1 }
            else if ["failure", "timed_out", "cancelled", "action_required"].contains(conclusion) {
                let out = r["output"] as? [String: Any]
                failed.append(.init(name: name, title: out?["title"] as? String ?? "",
                                    summary: (out?["summary"] as? String) ?? (out?["text"] as? String) ?? "",
                                    url: (r["html_url"] as? String).flatMap { URL(string: $0) }))
            }
            if let d = Self.iso.date(from: (r["completed_at"] as? String) ?? (r["started_at"] as? String) ?? ""), d > latest { latest = d }
        }
        let url = URL(string: "\(pr.url.absoluteString)/checks") ?? pr.url
        let sub = "\(pr.fullRepo) #\(pr.number)"
        let when = latest == .distantPast ? pr.updated : latest
        if !failed.isEmpty {
            let list = failed.prefix(2).map { $0.name }.joined(separator: ", ") + (failed.count > 2 ? " +\(failed.count - 2)" : "")
            let e = GHEvent(id: "ci-\(pr.id)-\(sha)-failed", kind: .ciFailed, title: "CI failed: \(list)",
                            subtitle: sub, date: when, url: url, approval: nil, prID: pr.id)
            return CheckSummary(ci: .failed, failing: failed, total: runs.count, event: e)
        }
        if running > 0 {
            let e = GHEvent(id: "ci-\(pr.id)-\(sha)-running", kind: .ciRunning,
                            title: running == 1 ? "1 check running" : "\(running) checks running",
                            subtitle: sub, date: pr.updated, url: url, approval: nil, prID: pr.id)
            return CheckSummary(ci: .running, failing: [], total: runs.count, event: e)
        }
        let e = GHEvent(id: "ci-\(pr.id)-\(sha)-passed", kind: .ciPassed, title: "All \(runs.count) checks passed",
                        subtitle: sub, date: when, url: url, approval: nil, prID: pr.id)
        return CheckSummary(ci: .passed, failing: [], total: runs.count, event: e)
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
                           approval: .init(owner: pr.owner, repo: pr.repo, runID: id, waiting: waiting), prID: pr.id)
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

/// "just now", "5 min ago", "9 hours ago", "yesterday", "15 days ago", "3 months ago".
func longAgo(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60) min ago" }
    if s < 7200 { return "1 hour ago" }
    if s < 86400 { return "\(s / 3600) hours ago" }
    if s < 172800 { return "yesterday" }
    if s < 86400 * 60 { return "\(s / 86400) days ago" }
    return "\(s / (86400 * 30)) months ago"
}

/// Deletes cached briefs (PR / session context written for Claude) older than a given age.
enum BriefCleaner {
    static func prune(_ folder: URL, olderThan age: TimeInterval) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for u in items {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if age <= 0 || m < cutoff { try? fm.removeItem(at: u) }
        }
    }
}
