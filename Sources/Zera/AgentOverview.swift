import AppKit

struct AgentOverviewItem: Equatable {
    enum State: Int { case waiting, working, failed, idle, completed }
    enum Source: Equatable { case claude(String), managedClaude(String), managedCodex(String), observed(String, String), approval(String) }
    let id: String
    let provider: String
    let providerName: String
    let title: String
    let project: String
    let activity: String
    let state: State
    let source: Source
    var needsApproval: Bool { state == .waiting }
    var tone: NSColor {
        switch state {
        case .waiting: return Pal.warning
        case .working: return Pal.accent
        case .failed: return Pal.danger
        case .completed: return Pal.success
        case .idle: return Pal.textTertiary
        }
    }
    var status: String { ["Needs approval", "Working", "Needs attention", "Idle", "Completed"][state.rawValue] }
}

@MainActor
enum AgentOverview {
    /// Presentation adapter for the original notch wings/card. Decisions still go through
    /// the owning backend's live request validation; these are never written to hook files.
    static var managedApproval: (request: HookRequest, provider: String, review: Bool)? {
        if let r = ClaudeAgentService.shared.approvals.first {
            let cwd = ClaudeAgentService.shared.threads.first { $0.id == r.threadID }?.cwd ?? ""
            return (HookRequest(id: "managed-claude:" + r.id, receivedAt: Date(), sessionID: r.threadID, toolName: r.tool, command: r.detail, detail: "Claude · " + URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd), "Claude", r.isQuestion)
        }
        if let r = CodexAgentService.shared.approvals.first {
            let cwd = CodexAgentService.shared.threads.first { $0.id == r.threadID }?.cwd ?? ""
            return (HookRequest(id: "managed-codex:" + r.id, receivedAt: Date(), sessionID: r.threadID, toolName: r.title, command: r.detail, detail: "Codex · " + URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd), "Codex", r.isQuestion || !r.canAccept)
        }
        return nil
    }
    static func decideManaged(_ request: HookRequest, allow: Bool) -> Bool {
        if let r = ClaudeAgentService.shared.approvals.first(where: { "managed-claude:" + $0.id == request.id }) {
            return ClaudeAgentService.shared.decide(r.id, allow: allow)
        }
        if let r = CodexAgentService.shared.approvals.first(where: { "managed-codex:" + $0.id == request.id }) {
            return CodexAgentService.shared.decide(r.id, allow: allow)
        }
        return false
    }
    static func snapshot() -> [AgentOverviewItem] {
        let claude = ClaudeActivityService.shared
        let codex = CodexAgentService.shared
        let requests = ClaudeHookService.shared.pending
        let managedClaude = ClaudeAgentService.shared
        let ownedClaude = Set(managedClaude.threads.map(\.id))
        var items: [AgentOverviewItem] = claude.ordered.filter { !ownedClaude.contains($0.id) }.map { session in
            let waiting = requests.contains { $0.sessionID == session.id }
            let state: AgentOverviewItem.State = waiting || session.status == .waiting ? .waiting : session.status == .running ? .working : session.status == .done || session.status == .ended ? .completed : .idle
            let command = requests.first { $0.sessionID == session.id }?.command
            return AgentOverviewItem(id: "claude:" + session.id, provider: "claude", providerName: "Claude", title: session.title.isEmpty ? session.folderName : session.title,
                                     project: session.cwd, activity: command ?? session.steps.last?.text ?? (state == .working ? "Thinking through the task" : "Ready for your next prompt"),
                                     state: state, source: .claude(session.id))
        }
        let knownClaude = Set(claude.ordered.map(\.id))
        for request in requests where !knownClaude.contains(request.sessionID) {
            let cursor = request.sessionID.hasPrefix("cursor:")
            items.append(AgentOverviewItem(id: "approval:" + request.id, provider: cursor ? "cursor" : "claude", providerName: cursor ? "Cursor" : "Claude",
                                          title: URL(fileURLWithPath: request.cwd).lastPathComponent.isEmpty ? "Permission request" : URL(fileURLWithPath: request.cwd).lastPathComponent,
                                          project: request.cwd, activity: request.command, state: .waiting, source: .approval(request.sessionID)))
        }
        for thread in codex.threads {
            let waiting = codex.approvals.contains { $0.threadID == thread.id }
            let state: AgentOverviewItem.State = waiting ? .waiting : thread.turnID != nil || thread.status == "Starting…" ? .working : thread.status == "Completed" ? .completed : thread.status == "Failed" ? .failed : .idle
            items.append(AgentOverviewItem(id: "managed:" + thread.id, provider: "codex", providerName: "Codex", title: thread.title,
                                          project: thread.cwd, activity: codex.approvals.first { $0.threadID == thread.id }?.detail ?? thread.activity ?? thread.status,
                                          state: state, source: .managedCodex(thread.id)))
        }
        for thread in managedClaude.threads {
            let state: AgentOverviewItem.State = managedClaude.approvals.contains { $0.threadID == thread.id } ? .waiting : managedClaude.isWorking(thread.id) ? .working : thread.status == "Failed" ? .failed : thread.status == "Completed" ? .completed : .idle
            items.append(AgentOverviewItem(id: "claude-managed:" + thread.id, provider: "claude", providerName: "Claude", title: thread.title,
                                          project: thread.cwd, activity: thread.activity, state: state, source: .managedClaude(thread.id)))
        }
        let owned = Set(codex.threads.map(\.id))
        for run in AgentWatch.shared.runs.values where !owned.contains(run.id) && Date().timeIntervalSince(run.lastEventAt) < 3 * 3600 {
            let state: AgentOverviewItem.State = run.state == .working ? .working : run.state == .done ? .completed : .idle
            items.append(AgentOverviewItem(id: "observed:" + run.agent.rawValue + run.id, provider: run.agent.rawValue.lowercased(), providerName: run.agent.rawValue,
                                          title: run.title ?? run.project, project: run.project, activity: (state == .working ? run.activity : run.summary) ?? (state == .working ? "Agent is working" : state == .completed ? "Finished · monitored chat" : "Idle · monitored chat"),
                                          state: state, source: .observed(run.agent.rawValue.lowercased(), run.id)))
        }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "zera.agents.hiddenSessions") ?? [])
        return items.filter { !hidden.contains($0.id) }
    }
    static func notchActivity(for items: [AgentOverviewItem]) -> ZeraActivity {
        if items.contains(where: \.needsApproval) { return .approval }
        if items.contains(where: { $0.state == .working }) { return .running }
        return .none
    }
    static func grouped(_ items: [AgentOverviewItem], provider: String?, state: Int) -> [(String, [AgentOverviewItem])] {
        let filtered = items.filter { item in
            (provider == nil || item.provider == provider) && (state == 1 || (state == 0 && [.waiting, .working, .failed].contains(item.state)) || (state == 2 && item.needsApproval) || (state == 3 && item.state == .completed))
        }
        let groups = Dictionary(grouping: filtered, by: \.provider)
        let preferred = ["claude", "codex"]
        let keys = groups.keys.sorted { a, b in
            let ai = preferred.firstIndex(of: a) ?? 99, bi = preferred.firstIndex(of: b) ?? 99
            return ai == bi ? a < b : ai < bi
        }
        return keys.map { key in (key, groups[key]!.sorted { a, b in a.state.rawValue == b.state.rawValue ? a.title < b.title : a.state.rawValue < b.state.rawValue }) }
    }
}

/// Native motion indicator: one shared clock for visible rows, no per-row timers.
final class AgentPulse: NSView, ZeraAnimating {
    var state: AgentOverviewItem.State = .idle { didSet { needsDisplay = true } }
    var tone: NSColor = .white
    private var phase: TimeInterval = 0
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { ZeraAnimationClock.shared.add(self) } else { ZeraAnimationClock.shared.remove(self) } }
    func advanceAnimation(at now: TimeInterval) { if state == .working || state == .waiting { phase = now; needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let reduce = Motion.reduced
        if state == .working {
            for index in 0..<3 {
                let lift = reduce ? 4 : 3 + 5 * CGFloat((sin(phase * 5 - Double(index) * 0.9) + 1) / 2)
                ctx.setFillColor(tone.withAlphaComponent(0.55 + Double(index) * 0.15).cgColor)
                ctx.fill(CGRect(x: CGFloat(index) * 6 + 2, y: (bounds.height - lift) / 2, width: 3, height: lift))
            }
        } else {
            let pulse: CGFloat = state == .waiting && !reduce ? 0.6 + CGFloat((sin(phase * 3) + 1) / 2) * 0.4 : 0.8
            ctx.setFillColor(tone.withAlphaComponent(pulse).cgColor)
            ctx.fillEllipse(in: bounds.insetBy(dx: 7, dy: 7))
            if state == .waiting { ctx.setStrokeColor(tone.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(1); ctx.strokeEllipse(in: bounds.insetBy(dx: 3, dy: 3)) }
        }
    }
}

/// Both providers share the original Claude session row's layout and motion.
final class AgentOverviewRow: NSView {
    var onSelect: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReview: (() -> Void)?
    private let row: ClaudeSessionRow
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(_ item: AgentOverviewItem) {
        row = ClaudeSessionRow(sessionID: item.id)
        super.init(frame: .zero)
        addSubview(row)
        row.onSelect = { [weak self] in self?.onSelect?() }
        row.onReview = { [weak self] in self?.onReview?() }
        row.onMenu = { [weak self] _ in self?.onOpen?() }
        update(item)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ item: AgentOverviewItem) {
        let run = AgentWatch.shared.runs.values.first { "observed:" + $0.agent.rawValue + $0.id == item.id }
        let session = ClaudeSession(id: item.id, cwd: item.project, at: run?.lastEventAt ?? Date())
        session.title = item.title
        session.monitoredOnly = true
        session.status = item.state == .working ? .running : item.state == .waiting ? .waiting : item.state == .completed ? .done : .idle
        session.steps = [ActivityStep(id: "current", kind: item.activity.lowercased().contains("read") ? .read : .run, verb: "", target: item.activity, detail: nil, at: run?.lastEventAt ?? Date(), finished: item.state != .working)]
        row.update(session)
        row.setAccessibilityLabel("\(item.providerName), \(item.title), \(item.status), \(item.activity)")
    }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 36 || event.keyCode == 49 { onSelect?() } else { super.keyDown(with: event) } }
    override func layout() { super.layout(); row.frame = bounds }
}
