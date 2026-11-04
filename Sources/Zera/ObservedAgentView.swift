import AppKit

/// Existing Codex sessions use Claude's native detail components, with observed data only.
@MainActor
final class ObservedAgentView: NSView, @preconcurrency CardContent {
    var onBack: (() -> Void)?
    var onHeightChange: (() -> Void)?
    var cardWidth: CGFloat { Isle.lensWidth }
    var desiredHeight: CGFloat { Isle.maxContentHeight }
    private let title = NSTextField(labelWithString: "Session")
    private let project = NSTextField(labelWithString: "")
    private let status = PRStatusChip()
    private let tabs = GitHubSegmentedControl(items: [])
    private let progress = ClaudeSessionProgress()
    private let console = ClaudeActivityConsole()
    private let scroll = NSScrollView(), document = FlippedView()
    private let changes = NSTextView(), changesScroll = NSScrollView()
    private var back: CardButton!
    private var provider = "", sessionID = "", page = 0
    private var rows: [SessionInfoRow] = []
    private var signature = ""
    private let snapshot: (() -> AgentRun?)?
    override var isFlipped: Bool { true }
    init(snapshot: (() -> AgentRun?)? = nil) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        back = CardButton("Agents", style: .tertiary, target: self, action: #selector(backTapped))
        title.font = Typo.detailTitle; title.textColor = Pal.text; title.lineBreakMode = .byTruncatingTail
        project.font = Typo.screenSubtitle; project.textColor = Pal.textSecondary; project.lineBreakMode = .byTruncatingMiddle
        tabs.setAccessibilityLabel("Session detail sections")
        tabs.onSelect = { [weak self] index in self?.page = index; self?.signature = ""; self?.reload() }
        scroll.documentView = document; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        changes.font = Typo.mono; changes.textColor = Pal.text; changes.isEditable = false; changes.isSelectable = true
        changes.drawsBackground = false; changes.isVerticallyResizable = true; changes.isHorizontallyResizable = false
        changes.textContainerInset = NSSize(width: 12, height: 12); changes.textContainer?.widthTracksTextView = true
        changes.setAccessibilityLabel("Observed file changes")
        changesScroll.documentView = changes; changesScroll.drawsBackground = false; changesScroll.hasVerticalScroller = true
        [back!, title, project, status, tabs, progress, console, scroll, changesScroll].forEach(addSubview)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: AgentWatch.changed, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    func select(provider: String, id: String) { self.provider = provider; sessionID = id; page = 0; tabs.selected = 0; signature = ""; reload() }
    func selectPage(_ index: Int) { page = min(4, max(0, index)); tabs.selected = page; signature = ""; reload() }
    @objc private func changed() { if window != nil, !isHiddenOrHasHiddenAncestor { reload() } }
    @objc private func backTapped() { onBack?() }
    private func reload() {
        guard let run = snapshot?() ?? AgentWatch.shared.runs.values.first(where: { $0.id == sessionID && $0.agent.rawValue.lowercased() == provider }) else {
            title.stringValue = "Session unavailable"; return
        }
        title.stringValue = run.title ?? run.project; project.stringValue = run.agent.rawValue + " · " + run.project
        let state = run.state == .working ? "Working" : run.state == .done ? "Completed" : "Idle"
        status.set(symbol: "", text: state, color: run.state == .working ? Pal.accent : run.state == .done ? Pal.success : Pal.textSecondary)
        let files = Array(Set(run.records.flatMap(\.files))).sorted()
        let patches = run.records.compactMap(\.patch)
        tabs.items = ["Live", "Files", "Changes", "Tools", "Timeline"].enumerated().map { index, name in
            .init(symbol: "", title: name, count: index == 1 ? files.count : index == 2 ? patches.count : index == 3 ? run.records.count : 0, tint: nil)
        }
        let session = ClaudeSession(id: run.id, cwd: run.project, at: run.records.first?.at ?? run.lastEventAt)
        session.title = run.title ?? run.project; session.monitoredOnly = true
        session.status = run.state == .working ? .running : run.state == .done ? .done : .idle
        session.promptAt = run.records.first?.at
        session.steps = run.records.map { record in
            ActivityStep(id: record.id, kind: record.patch != nil ? .edit : record.action.contains("Read") ? .read : .run,
                         verb: "", target: record.action, detail: record.tool, at: record.at, finished: record.finished, result: record.finished ? "Completed" : nil)
        }
        if session.steps.isEmpty {
            session.steps = run.steps.enumerated().map { index, text in
                ActivityStep(id: String(index), kind: .other, verb: "", target: text, detail: nil, at: run.lastEventAt, finished: index < run.steps.count - 1 || run.state != .working)
            }
        }
        if run.state == .working, session.currentStep == nil {
            session.steps.append(ActivityStep(id: "live-state", kind: .other, verb: "", target: run.activity ?? "Thinking through the request", detail: nil, at: run.lastEventAt, finished: false))
        }
        if run.state == .done, let reply = run.summary, !reply.isEmpty {
            session.steps.append(ActivityStep(id: "reply", kind: .other, verb: "Reply", target: reply, detail: nil, at: run.lastEventAt, finished: true))
        }
        progress.update(session, stage: run.state == .working ? run.activity ?? "Thinking through the request" : state)
        console.update(session)
        progress.isHidden = page != 0; console.isHidden = page != 0
        scroll.isHidden = page == 0 || page == 2; changesScroll.isHidden = page != 2
        let contentSignature = "\(page)|\(run.records)|\(run.steps)"
        if signature != contentSignature {
            signature = contentSignature
            rows.forEach { $0.removeFromSuperview() }; rows = []
            func row(_ symbol: String, _ heading: String, _ detail: String, _ trailing: String = "") {
                let view = SessionInfoRow(symbol: symbol, tint: Pal.accent, title: heading, subtitle: detail, trailing: trailing)
                view.setAccessibilityElement(true); view.setAccessibilityRole(.staticText); view.setAccessibilityLabel(heading); view.setAccessibilityValue(detail)
                document.addSubview(view); rows.append(view)
            }
            if page == 1 {
                if files.isEmpty { row("doc", "No file paths observed yet", "Files appear when Codex emits structured file or patch data") }
                for file in files { row("doc.text", URL(fileURLWithPath: file).lastPathComponent, file) }
            } else if page == 3 {
                if run.records.isEmpty { row("wrench", "No tool calls observed yet", "Tool activity updates from this session's log") }
                for record in run.records.reversed() { row("terminal", record.tool, record.action, record.finished ? "Completed" : "Observed") }
            } else if page == 4 {
                if run.records.isEmpty { for step in run.steps { row("clock", step, "Observed session activity") } }
                for record in run.records.reversed() { row("clock", record.action, record.tool, record.at.formatted(date: .omitted, time: .standard)) }
            }
            changes.string = patches.isEmpty ? "No patch data observed yet. Changes appear when Codex emits a file patch." : patches.joined(separator: "\n\n")
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let x = Metrics.sidePad, w = max(0, bounds.width - 2 * x)
        back.frame = NSRect(x: x, y: ScreenHeader.controlY(Metrics.control), width: back.fittedWidth, height: Metrics.control)
        title.frame = NSRect(x: back.frame.maxX + Space.m, y: ScreenHeader.titleTop, width: max(0, bounds.width / 2 - Isle.zeraGap / 2 - back.frame.maxX - Space.m), height: ScreenHeader.titleHeight)
        project.frame = ScreenHeader.subtitleFrame(width: bounds.width, padding: x); project.frame.size.width = w
        status.frame = NSRect(x: bounds.width - x - status.fittedWidth, y: ScreenHeader.controlY(24), width: status.fittedWidth, height: 24)
        tabs.frame = NSRect(x: x, y: Isle.headerHeight, width: w, height: Metrics.segment)
        let top = tabs.frame.maxY + Space.m
        progress.frame = NSRect(x: x, y: top, width: w, height: 72)
        console.frame = NSRect(x: x, y: progress.frame.maxY + Space.m, width: w, height: max(0, bounds.height - progress.frame.maxY - 2 * Space.m))
        let content = NSRect(x: x, y: top, width: w, height: max(0, bounds.height - top - Space.m))
        scroll.frame = content; changesScroll.frame = content
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(index) * (SessionInfoRow.height + Space.s), width: scroll.contentSize.width, height: SessionInfoRow.height) }
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, CGFloat(rows.count) * (SessionInfoRow.height + Space.s)))
        changes.frame.size.width = changesScroll.contentSize.width; changes.textContainer?.containerSize.width = changesScroll.contentSize.width
    }
}
