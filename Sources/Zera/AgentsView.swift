import AppKit

@MainActor
final class CodexAgentsView: NSView, @preconcurrency CardContent {
    var onHeightChange: (() -> Void)?
    var onBack: (() -> Void)?
    private var back: CardButton!
    var cardWidth: CGFloat { Isle.lensWidth }
    var desiredHeight: CGFloat { Isle.maxContentHeight }
    private let service = CodexAgentService.shared
    private let title = NSTextField(labelWithString: "Codex")
    private let subtitle = NSTextField(labelWithString: "")
    private let scope = GitHubSegmentedControl(items: [.init(symbol: "", title: "In Zera", count: 0, tint: nil), .init(symbol: "", title: "Monitored", count: 0, tint: nil)])
    private let chooser = ZeraSelect([])
    private let transcript = NSTextView()
    private let scroll = NSScrollView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let approvalTitle = NSTextField(labelWithString: "")
    private let approvalText = NSTextView()
    private let approvalScroll = NSScrollView()
    private let input = ThemedField(placeholder: "Message this Codex session…")
    private var connect: CardButton!, new: CardButton!, open: CardButton!, send: CardButton!, stop: CardButton!, accept: CardButton!, reject: CardButton!
    private var monitored = false
    private var selected: String?
    private var ids: [String] = []
    private var shownTranscript = ""
    private var choosingProject = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Typo.screenTitle; title.textColor = Pal.text
        subtitle.font = Typo.screenSubtitle; subtitle.textColor = Pal.textSecondary
        note.font = Typo.caption; note.textColor = Pal.textSecondary
        approvalTitle.font = Typo.rowTitleStrong; approvalTitle.textColor = Pal.warning
        back = CardButton("Agents", style: .tertiary, target: self, action: #selector(backTapped))
        addSubview(back)
        connect = CardButton("Connect", style: .secondary, target: self, action: #selector(connectTapped))
        new = CardButton("New session…", style: .primary, target: self, action: #selector(newTapped))
        open = CardButton("Open Codex", style: .secondary, target: self, action: #selector(openTapped))
        send = CardButton("Send", style: .primary, target: self, action: #selector(sendTapped))
        stop = CardButton("Stop", style: .destructive, target: self, action: #selector(stopTapped))
        accept = CardButton("Approve once", style: .success, target: self, action: #selector(acceptTapped))
        reject = CardButton("Reject", style: .destructive, target: self, action: #selector(rejectTapped))
        input.target = self; input.action = #selector(sendTapped)
        chooser.setAccessibilityLabel("Codex session")
        chooser.onChange = { [weak self] index in
            guard let self, self.ids.indices.contains(index) else { return }
            self.selected = self.ids[index]; self.reload()
        }
        scope.onSelect = { [weak self] index in self?.monitored = index == 1; self?.selected = nil; self?.reload() }
        for (text, container) in [(transcript, scroll), (approvalText, approvalScroll)] {
            text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
            text.font = Typo.body; text.textColor = Pal.text
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.isHorizontallyResizable = false; text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            container.documentView = text; container.drawsBackground = false; container.hasVerticalScroller = true
        }
        transcript.setAccessibilityLabel("Codex conversation")
        approvalText.setAccessibilityLabel("Codex approval details")
        [title, subtitle, scope, chooser, scroll, note, approvalTitle, approvalScroll, input,
         connect!, new!, open!, send!, stop!, accept!, reject!].forEach(addSubview)
        for name in [CodexAgentService.changed, AgentWatch.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(reloadIfVisible), name: name, object: nil)
        }
        reload()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { reload() } }
    @objc private func reloadIfVisible() { if window != nil, !isHiddenOrHasHiddenAncestor { reload() } }
    func beginNewSession() { newTapped() }
    func selectObserved(_ id: String) { monitored = true; scope.selected = 1; selected = id; reload() }
    @objc private func backTapped() { onBack?() }
    func selectThread(_ id: String) { monitored = false; scope.selected = 0; selected = id; reload() }
    private var current: CodexAgentService.Thread? { service.threads.first { $0.id == selected } }
    private var approval: CodexAgentService.Approval? { service.approvals.first { $0.threadID == selected } }
    @objc func reload() {
        let managedIDs = Set(service.threads.map(\.id))
        let observed = AgentWatch.shared.runs.values.filter { $0.agent == .codex && !managedIDs.contains($0.id) }.sorted { $0.lastEventAt > $1.lastEventAt }
        ids = monitored ? observed.map(\.id) : service.threads.map(\.id)
        if selected == nil || !ids.contains(selected!) { selected = ids.first }
        let names = monitored ? observed.map { $0.project + " · " + String(describing: $0.state) + " · " + $0.id.prefix(6) } : service.threads.map { $0.title + " · " + $0.status }
        chooser.options = (names.isEmpty ? [monitored ? "No monitored activity yet" : "Create a session to begin"] : names).map { .init(title: $0) }
        chooser.selectedIndex = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
        chooser.isEnabled = !ids.isEmpty
        subtitle.stringValue = monitored ? "Activity from existing Codex chats" : service.connection
        connect.title = service.ready ? "Disconnect" : service.connection == "Connecting…" ? "Cancel connection" : "Connect"
        connect.isHidden = monitored
        new.isHidden = monitored
        new.isEnabled = !choosingProject
        input.isHidden = monitored; send.isHidden = monitored; stop.isHidden = monitored
        let busy = current?.turnID != nil || current?.status == "Starting…"
        input.isEnabled = current != nil && !busy
        send.isEnabled = current != nil && !busy
        stop.isEnabled = current?.turnID != nil
        var content: String
        if monitored {
            let run = observed.first { $0.id == selected }
            content = run.map { "\($0.project)\n\n\($0.summary ?? "Activity is monitored from local session logs.")" } ?? "No recent Codex activity. New activity appears automatically."
            note.stringValue = "Monitored chats are read-only here. Open Codex to reply or approve; use In Zera for sessions you can control here."
        } else {
            content = current?.transcript ?? "Choose New session, select a project folder, then send a message. Zera uses your Codex CLI login."
            if content.isEmpty { content = "Ready in \(current?.cwd ?? "your project"). Send a message to begin." }
            note.stringValue = current.map { "\($0.status) · \($0.cwd)" } ?? "Project access and approval requests follow Codex’s sandbox policy."
        }
        if content != shownTranscript { shownTranscript = content; transcript.string = content }
        let pending = monitored ? nil : approval
        approvalTitle.isHidden = pending == nil; approvalScroll.isHidden = pending == nil
        accept.isHidden = pending == nil; reject.isHidden = pending == nil
        approvalTitle.stringValue = pending?.title ?? ""
        approvalText.string = pending?.detail ?? ""
        accept.isEnabled = pending.map { $0.canAccept || $0.isQuestion } ?? false
        accept.title = pending?.isQuestion == true ? "Answer…" : "Approve once"
        reject.title = pending?.canAccept == true ? "Reject" : "Cancel request"
        needsLayout = true
    }
    @objc private func connectTapped() { (service.ready || service.connection == "Connecting…") ? service.disconnect() : service.connect() }
    @objc private func newTapped() {
        guard !choosingProject, let owner = window, owner.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Start Codex here"; panel.message = "Choose the project for this Zera-managed Codex session."
        choosingProject = true; reload()
        NSApp.activate(ignoringOtherApps: true)
        panel.beginSheetModal(for: owner) { [weak self] response in
            guard let self else { return }
            self.choosingProject = false; self.reload()
            guard response == .OK, let url = panel.url else { return }
            self.monitored = false; self.scope.selected = 0
            self.service.create(cwd: url.path) { [weak self] id in
                self?.selectThread(id)
                self?.window?.makeFirstResponder(self?.input)
            }
        }
    }
    @objc private func openTapped() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        else { subtitle.stringValue = "Codex desktop app is not installed" }
    }
    @objc private func sendTapped() {
        guard let id = selected, !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, send.isEnabled else { return }
        let text = input.stringValue; input.stringValue = ""; service.sendText(text, threadID: id)
    }
    @objc private func stopTapped() { if let id = selected { service.interrupt(id) } }
    @objc private func acceptTapped() {
        guard let request = approval else { return }
        guard request.isQuestion else { _ = service.decide(request.id, allow: true); return }
        guard let questions = request.params["questions"] as? [[String: Any]], !questions.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Answer Codex"; alert.informativeText = "Your answers return to this session."
        alert.addButton(withTitle: "Send answers"); alert.addButton(withTitle: "Back")
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: CGFloat(questions.count) * 100))
        var readers: [(String, () -> String)] = []
        for (index, question) in questions.enumerated() {
            guard let id = question["id"] as? String else { continue }
            let y = CGFloat(index) * 100
            let label = NSTextField(wrappingLabelWithString: question["question"] as? String ?? "Answer")
            label.font = Typo.body; label.frame = NSRect(x: 0, y: y, width: 480, height: 54); document.addSubview(label)
            if question["isSecret"] as? Bool != true, let options = question["options"] as? [[String: Any]], !options.isEmpty, question["isOther"] as? Bool != true {
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: y + 58, width: 480, height: 28))
                picker.addItems(withTitles: options.compactMap { $0["label"] as? String }); document.addSubview(picker)
                readers.append((id, { picker.titleOfSelectedItem ?? "" }))
            } else {
                let field: NSTextField = question["isSecret"] as? Bool == true ? NSSecureTextField() : NSTextField()
                field.placeholderString = "Your answer"; field.frame = NSRect(x: 0, y: y + 58, width: 480, height: 28); document.addSubview(field)
                readers.append((id, { field.stringValue }))
            }
        }
        let container = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: min(400, document.frame.height)))
        container.documentView = document; container.hasVerticalScroller = true; alert.accessoryView = container
        if alert.runModal() == .alertFirstButtonReturn {
            let values = Dictionary(uniqueKeysWithValues: readers.map { ($0.0, $0.1()) })
            if !service.answer(request.id, values: values) { subtitle.stringValue = "Answer every question, then try again" }
        }
    }
    @objc private func rejectTapped() { if let request = approval { _ = service.decide(request.id, allow: false) } }
    override func layout() {
        super.layout()
        let x = Metrics.sidePad, w = max(0, bounds.width - 2 * x), h = bounds.height
        back.frame = NSRect(x: x, y: ScreenHeader.controlY(Metrics.control), width: back.fittedWidth, height: Metrics.control)
        title.frame = ScreenHeader.titleFrame(width: bounds.width, padding: x)
        title.frame.origin.x = back.frame.maxX + Space.m
        title.frame.size.width = max(0, bounds.width - x - new.fittedWidth - open.fittedWidth - 2 * Space.s - title.frame.minX)
        subtitle.frame = ScreenHeader.subtitleFrame(width: bounds.width, padding: x)
        let nw = new.fittedWidth, ow = open.fittedWidth, cw = connect.fittedWidth
        open.frame = NSRect(x: bounds.width - x - ow, y: ScreenHeader.controlY(Metrics.control), width: ow, height: Metrics.control)
        new.frame = NSRect(x: open.frame.minX - Space.s - nw, y: ScreenHeader.controlY(Metrics.control), width: nw, height: Metrics.control)
        connect.frame = NSRect(x: bounds.width - x - cw, y: ScreenHeader.subtitleTop, width: cw, height: Metrics.control)
        scope.frame = NSRect(x: x, y: 112, width: min(w, 280), height: Metrics.segment)
        chooser.frame = NSRect(x: x, y: 156, width: w, height: Metrics.control)
        note.frame = NSRect(x: x, y: 196, width: w, height: 38)
        let inputY = h - Metrics.field - Space.l
        send.frame = NSRect(x: bounds.width - x - 72, y: inputY, width: 72, height: Metrics.field)
        stop.frame = NSRect(x: send.frame.minX - 72 - Space.s, y: inputY, width: 72, height: Metrics.field)
        input.frame = NSRect(x: x, y: inputY, width: max(0, stop.frame.minX - x - Space.s), height: Metrics.field)
        var bottom = monitored ? h - Space.l : inputY - Space.m
        if !approvalTitle.isHidden {
            let top = max(240, bottom - 188)
            approvalTitle.frame = NSRect(x: x, y: top, width: w, height: 22)
            approvalScroll.frame = NSRect(x: x, y: top + 28, width: w, height: 100)
            accept.frame = NSRect(x: bounds.width - x - accept.fittedWidth, y: top + 140, width: accept.fittedWidth, height: Metrics.control)
            reject.frame = NSRect(x: accept.frame.minX - Space.s - reject.fittedWidth, y: top + 140, width: reject.fittedWidth, height: Metrics.control)
            bottom = top - Space.s
        }
        scroll.frame = NSRect(x: x, y: 240, width: w, height: max(0, bottom - 240))
        for text in [transcript, approvalText] {
            let width = text.enclosingScrollView?.contentSize.width ?? w
            text.setFrameSize(NSSize(width: width, height: max(1, text.frame.height)))
            text.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            text.sizeToFit()
        }
    }
}
