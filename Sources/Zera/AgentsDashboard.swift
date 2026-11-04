import AppKit

/// Activity comes first. Provider-specific tools appear only after opening a run or choosing New.
@MainActor
final class AgentsView: NSView, @preconcurrency CardContent {
    let claude = ClaudeSessionsView()
    let codex = CodexAgentsView()
    let managedClaude = ClaudeAgentsView()
    private let observed = ObservedAgentView()
    var onHeightChange: (() -> Void)?
    var onEscape: (() -> Void)? { didSet { claude.onEscape = onEscape } }
    var onReviewApproval: (() -> Void)?
    private let snapshot: @MainActor () -> [AgentOverviewItem]
    private let dashboard = FlippedView()
    private let heading = NSTextField(labelWithString: "Agents")
    private let subtitle = NSTextField(labelWithString: "")
    private let providers = GitHubSegmentedControl(items: [])
    private let state = ZeraSelect(["Active", "All sessions", "Needs approval", "Completed"])
    private let currentBox = FlippedView()
    private let currentPulse = AgentPulse()
    private let currentTitle = NSTextField(labelWithString: "")
    private let currentDetail = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var new: CardButton!, approvals: CardButton!, currentReview: CardButton!, back: CardButton!
    private var providerIDs = ["all", "claude", "codex"]
    private var providerID: String?
    private var stateIndex = 1
    private var rowViews: [String: NSView] = [:]
    private var listOrder: [NSView] = []
    private var entries: [AgentOverviewItem] = []
    private var urgent: AgentOverviewItem?
    private var detail: NSView?
    private var signature = ""
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var cardWidth: CGFloat { Isle.lensWidth }
    var desiredHeight: CGFloat {
        if let detail = detail as? any CardContent { return detail.desiredHeight }
        let groups = AgentOverview.grouped(entries, provider: providerID, state: stateIndex)
        let count = groups.reduce(0) { $0 + $1.1.count }
        return groups.isEmpty ? 360 : min(Isle.maxContentHeight, 200 + CGFloat(min(4, count)) * (RowTier.rich.height + Metrics.rowGap) + CGFloat(groups.count) * 32)
    }
    init(snapshot: @escaping @MainActor () -> [AgentOverviewItem] = { AgentOverview.snapshot() }) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        addSubview(dashboard)
        heading.font = Typo.screenTitle; heading.textColor = Pal.text
        subtitle.font = Typo.screenSubtitle; subtitle.textColor = Pal.textSecondary
        currentTitle.font = Typo.rowTitleStrong; currentTitle.textColor = Pal.text
        currentDetail.font = Typo.body; currentDetail.textColor = Pal.textSecondary; currentDetail.lineBreakMode = .byTruncatingTail
        currentBox.wantsLayer = true; currentBox.layer?.cornerRadius = Radius.l
        currentBox.layer?.borderWidth = 1; currentBox.layer?.borderColor = Pal.divider.cgColor
        currentBox.layer?.backgroundColor = Pal.surfaceRow.cgColor
        new = CardButton("New…", style: .primary, target: self, action: #selector(newTapped))
        new.isHidden = true; currentBox.isHidden = true; state.selectedIndex = stateIndex
        approvals = CardButton("Approvals", style: .secondary, target: self, action: #selector(approvalsTapped))
        currentReview = CardButton("Review", style: .primary, target: self, action: #selector(currentTapped))
        state.setAccessibilityLabel("Agent status")
        state.onChange = { [weak self] index in self?.stateIndex = index; self?.reload() }
        providers.fitToContent = true; providers.setAccessibilityLabel("Filter agents by provider")
        providers.onSelect = { [weak self] index in
            guard let self, self.providerIDs.indices.contains(index) else { return }
            self.providerID = index == 0 ? nil : self.providerIDs[index]; self.reload()
        }
        scroll.documentView = list; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        [heading, subtitle, providers, state, currentBox, scroll, new!, approvals!].forEach(dashboard.addSubview)
        [currentPulse, currentTitle, currentDetail, currentReview!].forEach(currentBox.addSubview)
        claude.onHeightChange = { [weak self] in self?.onHeightChange?() }
        claude.onBackToAgents = { [weak self] in self?.showDashboard() }
        codex.onBack = { [weak self] in self?.showDashboard() }
        observed.onBack = { [weak self] in self?.showDashboard() }
        managedClaude.onBack = { [weak self] in self?.showDashboard() }
        managedClaude.onHeightChange = { [weak self] in self?.onHeightChange?() }
        for name in [ClaudeActivityService.changed, ClaudeHookService.changed, CodexAgentService.changed, ClaudeAgentService.changed, AgentWatch.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(reloadIfVisible), name: name, object: nil)
        }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { reload() } }
    @objc private func reloadIfVisible() {
        guard window != nil, detail == nil, !isHiddenOrHasHiddenAncestor else { return }
        if snapshot() != entries { reload() }
        else {
            for view in rowViews.values {
                if let row = view as? ClaudeSessionRow, let session = ClaudeActivityService.shared.sessions[row.sessionID] { row.update(session) }
            }
        }
    }
    func willShow(expanded: Bool) {
        if expanded, let session = ClaudeActivityService.shared.current {
            showDetail(claude); claude.openSession(session.id)
        } else { providerID = nil; showDashboard() }
    }
    func beginClaudeSession() { showDetail(managedClaude); managedClaude.beginNewSession() }
    func openClaudeThread(_ id: String) { showDetail(managedClaude); managedClaude.selectThread(id) }
    @objc private func startClaudeTapped() { beginClaudeSession() }
    @objc private func startCodexTapped() { showDetail(codex); codex.beginNewSession() }
    func openObserved(provider: String, id: String) { observed.select(provider: provider, id: id); showDetail(observed) }
    func openCodexThread(_ id: String) { showDetail(codex); codex.selectThread(id) }
    private func showDashboard() {
        detail?.removeFromSuperview(); detail = nil; dashboard.isHidden = false
        reload(); needsLayout = true; onHeightChange?()
    }
    private func showDetail(_ view: NSView) {
        detail?.removeFromSuperview(); dashboard.isHidden = true; detail = view
        addSubview(view); needsLayout = true; onHeightChange?()
    }
    @objc func reload() {
        let previousHeight = desiredHeight
        entries = snapshot()
        let working = entries.filter { $0.state == .working }.count
        let waiting = entries.filter(\.needsApproval).count
        subtitle.stringValue = "\(working) working · \(waiting) need\(waiting == 1 ? "s" : "") your approval"
        approvals.title = waiting > 0 ? "Approvals · \(waiting)" : "Approvals"
        approvals.isEnabled = waiting > 0
        let dynamic = Set(entries.map(\.provider)).subtracting(["claude", "codex"]).sorted()
        providerIDs = ["all", "claude", "codex"] + dynamic
        providers.items = providerIDs.map { id in
            let title = id == "all" ? "All" : entries.first { $0.provider == id }?.providerName ?? id.capitalized
            let count = entries.filter { (id == "all" || $0.provider == id) && [.working, .waiting, .failed].contains($0.state) }.count
            return .init(symbol: "", title: title, count: count, tint: nil, showsZero: true)
        }
        providers.selected = providerID.flatMap { providerIDs.firstIndex(of: $0) } ?? 0
        urgent = entries.filter { [.waiting, .working, .failed].contains($0.state) }.sorted { $0.state.rawValue < $1.state.rawValue }.first
        if let urgent {
            currentTitle.stringValue = urgent.needsApproval ? "\(urgent.providerName) is waiting for you" : "\(urgent.providerName) · \(urgent.title)"
            currentDetail.stringValue = urgent.activity.replacingOccurrences(of: "\n", with: " ")
            currentPulse.state = urgent.state; currentPulse.tone = urgent.tone
            currentReview.isHidden = false; currentReview.title = urgent.needsApproval ? "Review" : "View run"
        } else {
            currentTitle.stringValue = "Zera is keeping watch"
            currentDetail.stringValue = "Your agents appear here as they start working."
            currentPulse.state = .idle; currentPulse.tone = CompanionGlyph.tint(for: .idle)
            currentReview.isHidden = true
        }
        if detail === claude { claude.reload() }
        if detail === codex { codex.reload() }
        let newSignature = entries.map { "\($0.id)|\($0.state)|\($0.title)|\($0.activity)|\($0.project)" }.joined(separator: "\n") + "|\(providerID ?? "all")|\(stateIndex)"
        if newSignature != signature { signature = newSignature; rebuildList() }
        let visibleIDs = Set(AgentOverview.grouped(entries, provider: providerID, state: stateIndex).flatMap { $0.1.map(\.id) })
        for id in Array(rowViews.keys) where !visibleIDs.contains(id) { rowViews.removeValue(forKey: id)?.removeFromSuperview() }
        needsLayout = true
        if desiredHeight != previousHeight { onHeightChange?() }
    }
    private func rebuildList() {
        list.subviews.filter { view in !rowViews.values.contains(where: { $0 === view }) }.forEach { $0.removeFromSuperview() }
        listOrder = []
        let groups = AgentOverview.grouped(entries, provider: providerID, state: stateIndex)
        if groups.isEmpty {
            let title = NSTextField(labelWithString: stateIndex == 2 ? "No approvals waiting" : stateIndex == 1 ? "No sessions yet" : "No active agents")
            title.font = Typo.rowTitleStrong; title.textColor = Pal.text
            let detail = NSTextField(wrappingLabelWithString: "Claude Code sessions appear here through Live progress. Codex sessions are followed from their local activity. Check Integrations if a running session is missing.")
            detail.font = Typo.body; detail.textColor = Pal.textSecondary
            title.identifier = .init("empty-title"); detail.identifier = .init("empty-detail")
            list.addSubview(title); list.addSubview(detail); listOrder += [title, detail]

        }
        for (_, items) in groups {
            guard let first = items.first else { continue }
            let label = NSTextField(labelWithString: "\(first.providerName)  ·  \(items.count)")
            label.font = Typo.rowTitleStrong; label.textColor = Pal.textSecondary; label.identifier = .init("provider-heading")
            list.addSubview(label); listOrder.append(label)
            for item in items {
                let view: NSView
                if case .claude(let id) = item.source, let session = ClaudeActivityService.shared.sessions[id] {
                    let row = (rowViews[item.id] as? ClaudeSessionRow) ?? ClaudeSessionRow(sessionID: id)
                    row.update(session)
                    row.onSelect = { [weak self] in self?.open(item) }
                    row.onReview = { [weak self] in self?.review(item) }
                    row.onStop = { ClaudeActivityService.shared.requestStop(session) }
                    row.onMenu = { [weak self] _ in self?.open(item) }
                    view = row
                } else {
                    let row = (rowViews[item.id] as? AgentOverviewRow) ?? AgentOverviewRow(item)
                    row.update(item)
                    row.onSelect = { [weak self] in self?.open(item) }
                    row.onOpen = row.onSelect
                    row.onReview = { [weak self] in self?.review(item) }
                    view = row
                }
                rowViews[item.id] = view
                if view.superview == nil { list.addSubview(view) }
                listOrder.append(view)
            }
        }
    }
    private func open(_ item: AgentOverviewItem) {
        switch item.source {
        case .claude(let id): showDetail(claude); claude.openSession(id)
        case .managedClaude(let id): openClaudeThread(id)
        case .managedCodex(let id): showDetail(codex); codex.selectThread(id)
        case .observed(let provider, let id):
            observed.select(provider: provider, id: id); showDetail(observed)
        case .approval: review(item)
        }
    }
    private func review(_ item: AgentOverviewItem) {
        switch item.source {
        case .managedClaude(let id): openClaudeThread(id)
        case .managedCodex(let id): showDetail(codex); codex.selectThread(id)
        case .claude(let id), .approval(let id):
            if let action = claude.onReviewSessionApproval { action(id) } else { onReviewApproval?() }
        case .observed: open(item)
        }
    }
    @objc private func currentTapped() { if let urgent { urgent.needsApproval ? review(urgent) : open(urgent) } }
    @objc private func approvalsTapped() { if let first = entries.first(where: \.needsApproval) { review(first) } }
    @objc private func newTapped() {
        NSMenu.make([
            ClosureMenuItem("New Claude session…", symbol: "sparkles") { [weak self] in self?.beginClaudeSession() },
            ClosureMenuItem("New Codex session…", symbol: "plus") { [weak self] in
                guard let self else { return }; self.showDetail(self.codex); self.codex.beginNewSession()
            }
        ]).pop(below: new)
    }
    override func layout() {
        super.layout()
        dashboard.frame = bounds
        if let detail { detail.frame = bounds; return }
        let x = Metrics.sidePad, w = bounds.width, iw = max(0, w - 2 * x)
        heading.frame = ScreenHeader.titleFrame(width: w, padding: x)
        subtitle.frame = ScreenHeader.subtitleFrame(width: w, padding: x)
        new.frame = NSRect(x: w - x - new.fittedWidth, y: ScreenHeader.controlY(Metrics.control), width: new.fittedWidth, height: Metrics.control)
        approvals.frame = NSRect(x: w - x - approvals.fittedWidth, y: ScreenHeader.subtitleTop, width: approvals.fittedWidth, height: Metrics.control)
        let filterWidth = min(max(240, providers.preferredWidth), max(240, iw - 178))
        providers.frame = NSRect(x: x, y: Isle.headerHeight, width: filterWidth, height: Metrics.segment)
        state.frame = NSRect(x: w - x - 160, y: Isle.headerHeight, width: 160, height: Metrics.segment)
        currentBox.frame = NSRect(x: x, y: 180, width: iw, height: 68)
        currentPulse.frame = NSRect(x: 12, y: 18, width: 28, height: 28)
        let reserve: CGFloat = currentReview.isHidden ? 16 : 112
        currentTitle.frame = NSRect(x: 50, y: 12, width: max(0, iw - 50 - reserve), height: 21)
        currentDetail.frame = NSRect(x: 50, y: 37, width: max(0, iw - 50 - reserve), height: 19)
        currentReview.frame = NSRect(x: iw - 96, y: 18, width: 80, height: Metrics.control)
        scroll.frame = NSRect(x: x, y: 180, width: iw, height: max(0, bounds.height - 198))
        var y: CGFloat = 0
        for view in listOrder {
            let id = view.identifier?.rawValue
            var height: CGFloat = (view is AgentOverviewRow || view is ClaudeSessionRow) ? RowTier.rich.height : id == "empty-detail" ? 54 : 24
            if id == "start-actions" {
                let buttons = view.subviews.compactMap { $0 as? CardButton }
                let frames = FlowLayout.frames(widths: buttons.map(\.fittedWidth), available: max(0, scroll.contentSize.width - 2), height: Metrics.button)
                for (button, frame) in zip(buttons, frames) { button.frame = frame }
                height = (frames.last?.maxY ?? 0) + Space.s
            }
            view.frame = NSRect(x: 0, y: y, width: max(0, scroll.contentSize.width - 2), height: height)
            y += height + ((view is AgentOverviewRow || view is ClaudeSessionRow) ? Metrics.rowGap : 8)
        }
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(y, scroll.contentSize.height))
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { if detail != nil { showDashboard() } else { onEscape?() } }
        else { super.keyDown(with: event) }
    }
}
