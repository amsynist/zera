import AppKit

@MainActor
final class ClaudeAgentsView: NSView, @preconcurrency CardContent {
    var onHeightChange: (() -> Void)?
    var onBack: (() -> Void)?
    var cardWidth: CGFloat { Isle.lensWidth }
    var desiredHeight: CGFloat { Isle.maxContentHeight }
    private let service: ClaudeAgentService
    private let heading = NSTextField(labelWithString: "Claude")
    private let subtitle = NSTextField(labelWithString: "")
    private let chooser = ZeraSelect([])
    private let pulse = AgentPulse()
    private let activity = NSTextField(labelWithString: "")
    private let transcript = NSTextView(), timeline = NSTextView(), permission = NSTextView()
    private let conversationScroll = NSScrollView(), timelineScroll = NSScrollView(), permissionScroll = NSScrollView()
    private let timelineTitle = NSTextField(labelWithString: "Activity")
    private let permissionTitle = NSTextField(labelWithString: "")
    private let input = ThemedField(placeholder: "Message this Claude session…")
    private var back: CardButton!, new: CardButton!, send: CardButton!, stop: CardButton!, allow: CardButton!, deny: CardButton!
    private var selected: String?
    private var ids: [String] = []
    private var approval: ClaudeAgentService.Approval?
    override var isFlipped: Bool { true }
    convenience init() { self.init(service: .shared) }
    init(service: ClaudeAgentService) {
        self.service = service
        super.init(frame: .zero)
        heading.font = Typo.screenTitle; heading.textColor = Pal.text
        subtitle.font = Typo.screenSubtitle; subtitle.textColor = Pal.textSecondary
        subtitle.lineBreakMode = .byTruncatingMiddle
        activity.font = Typo.body; activity.textColor = Pal.textSecondary; activity.lineBreakMode = .byTruncatingTail
        timelineTitle.font = Typo.rowTitleStrong; timelineTitle.textColor = Pal.textSecondary
        permissionTitle.font = Typo.rowTitleStrong; permissionTitle.textColor = Pal.warning
        back = CardButton("Agents", style: .tertiary, target: self, action: #selector(backTapped))
        new = CardButton("New session…", style: .secondary, target: self, action: #selector(newTapped))
        send = CardButton("Send", style: .primary, target: self, action: #selector(sendTapped))
        stop = CardButton("Stop", style: .destructive, target: self, action: #selector(stopTapped))
        allow = CardButton("Approve once", style: .primary, target: self, action: #selector(allowTapped))
        deny = CardButton("Reject", style: .secondary, target: self, action: #selector(denyTapped))
        input.target = self; input.action = #selector(sendTapped)
        chooser.setAccessibilityLabel("Claude session")
        chooser.onChange = { [weak self] index in guard let self, self.ids.indices.contains(index) else { return }; self.selected = self.ids[index]; self.reload() }
        configure(transcript, in: conversationScroll, label: "Claude conversation", mono: false)
        configure(timeline, in: timelineScroll, label: "Claude current activity", mono: false)
        configure(permission, in: permissionScroll, label: "Claude permission request", mono: true)
        [heading, subtitle, chooser, pulse, activity, conversationScroll, timelineTitle, timelineScroll, permissionTitle, permissionScroll, input, back!, new!, send!, stop!, allow!, deny!].forEach(addSubview)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: ClaudeAgentService.changed, object: nil)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func configure(_ text: NSTextView, in scroll: NSScrollView, label: String, mono: Bool) {
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.font = mono ? Typo.mono : Typo.body; text.textColor = Pal.text
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel(label)
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { reload() } }
    @objc private func changed() { if window != nil, !isHiddenOrHasHiddenAncestor { reload() } }
    func selectThread(_ id: String) { selected = id; reload() }
    func beginNewSession() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Create Claude session"; panel.message = "Choose the project for this conversation in Zera."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selected = service.create(cwd: url.path); reload(); window?.makeFirstResponder(input)
    }
    private func reload() {
        ids = service.threads.map(\.id)
        if selected == nil || !ids.contains(selected!) { selected = ids.first }
        let thread = service.threads.first { $0.id == selected }
        chooser.options = (ids.isEmpty ? ["Create a session to begin"] : service.threads.map { $0.title + " · " + $0.status }).map { .init(title: $0) }
        chooser.selectedIndex = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
        chooser.isEnabled = !ids.isEmpty
        let working = selected.map(service.isWorking) ?? false
        subtitle.stringValue = thread.map { $0.status + " · " + $0.cwd } ?? "Your Claude Code login, inside Zera"
        activity.stringValue = thread?.activity ?? "Choose New session and a project, then send a message."
        let waiting = service.approvals.contains { $0.threadID == selected }
        pulse.state = waiting ? .waiting : working ? .working : thread?.status == "Failed" ? .failed : .idle
        pulse.tone = waiting ? Pal.warning : Pal.accent
        let text = thread.map { $0.transcript.isEmpty ? "Send a message to begin. Claude will work in this project and ask here when permission is needed." : $0.transcript } ?? "Create a session to start a conversation with Claude. Your existing chats remain available from Agents."
        if transcript.string != text { transcript.string = text; transcript.scrollToEndOfDocument(nil) }
        timeline.string = thread?.steps.suffix(12).map { "• " + $0 }.joined(separator: "\n\n") ?? ""
        if timeline.string.isEmpty { timeline.string = working ? "Claude is thinking through your request." : "Reads, edits and commands appear here as they happen." }
        approval = service.approvals.first { $0.threadID == selected }
        permissionTitle.stringValue = approval.map { $0.isQuestion ? "Claude has a question" : "Permission · " + $0.tool } ?? ""
        permission.string = approval?.detail ?? ""
        allow.setTitleText(approval?.isQuestion == true ? "Answer…" : "Approve once")
        [permissionTitle, permissionScroll, allow!, deny!].forEach { $0.isHidden = approval == nil }
        input.isEnabled = thread != nil && !working; send.isEnabled = input.isEnabled; stop.isEnabled = working
        if let error = service.lastError, approval != nil { subtitle.stringValue = error }
        needsLayout = true
    }
    @objc private func newTapped() { beginNewSession() }
    @objc private func backTapped() { onBack?() }
    @objc private func sendTapped() {
        guard let selected, service.send(input.stringValue, to: selected) else { return }
        input.stringValue = ""; reload()
    }
    @objc private func stopTapped() { if let selected { service.stop(selected) } }
    @objc private func denyTapped() { if let approval { _ = service.decide(approval.id, allow: false); reload() } }
    @objc private func allowTapped() {
        guard let approval else { return }
        if !approval.isQuestion { _ = service.decide(approval.id, allow: true); reload(); return }
        let questions = approval.input["questions"] as? [[String: Any]] ?? []
        guard !questions.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Reply to Claude"; alert.addButton(withTitle: "Send answers"); alert.addButton(withTitle: "Cancel")
        let document = FlippedView(); var y: CGFloat = 0
        var readers: [(String, () -> String)] = []
        for question in questions.prefix(8) {
            guard let title = question["question"] as? String else { continue }
            let label = NSTextField(wrappingLabelWithString: title); label.font = Typo.body
            label.frame = NSRect(x: 0, y: y, width: 440, height: 42); document.addSubview(label); y += 46
            let options = question["options"] as? [[String: Any]] ?? []
            if question["multiSelect"] as? Bool == true {
                var checks: [(NSButton, String)] = []
                for option in options {
                    guard let text = option["label"] as? String else { continue }
                    let button = NSButton(checkboxWithTitle: text, target: nil, action: nil)
                    button.frame = NSRect(x: 0, y: y, width: 440, height: 26); document.addSubview(button); y += 28; checks.append((button, text))
                }
                readers.append((title, { checks.filter { $0.0.state == .on }.map(\.1).joined(separator: ", ") }))
            } else if !options.isEmpty {
                let popup = NSPopUpButton(frame: NSRect(x: 0, y: y, width: 440, height: 28)); popup.addItem(withTitle: "Choose an answer…")
                popup.addItems(withTitles: options.compactMap { $0["label"] as? String }); document.addSubview(popup); y += 32
                readers.append((title, { popup.indexOfSelectedItem > 0 ? popup.titleOfSelectedItem ?? "" : "" }))
            } else {
                let field = NSTextField(frame: NSRect(x: 0, y: y, width: 440, height: 28)); document.addSubview(field); y += 32
                readers.append((title, { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }))
            }
            y += 12
        }
        document.frame = NSRect(x: 0, y: 0, width: 440, height: y)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: min(440, y))); scroll.documentView = document; scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        if alert.runModal() == .alertFirstButtonReturn {
            let answers = Dictionary(readers.map { ($0.0, $0.1()) }, uniquingKeysWith: { _, last in last })
            if !service.decide(approval.id, allow: true, answers: answers) { subtitle.stringValue = "Answer each question, then try again" }
        }
        reload()
    }
    override func layout() {
        super.layout()
        let x = Metrics.sidePad, w = max(0, bounds.width - 2 * x)
        back.frame = NSRect(x: x, y: ScreenHeader.controlY(Metrics.control), width: back.fittedWidth, height: Metrics.control)
        heading.frame = ScreenHeader.titleFrame(width: bounds.width, padding: x)
        heading.frame.origin.x = back.frame.maxX + Space.m
        heading.frame.size.width = max(0, bounds.width - x - new.fittedWidth - Space.m - heading.frame.minX)
        subtitle.frame = ScreenHeader.subtitleFrame(width: bounds.width, padding: x)
        new.frame = NSRect(x: bounds.width - x - new.fittedWidth, y: ScreenHeader.controlY(Metrics.control), width: new.fittedWidth, height: Metrics.control)
        chooser.frame = NSRect(x: x, y: 132, width: w, height: Metrics.control)
        pulse.frame = NSRect(x: x, y: 174, width: 22, height: 22)
        activity.frame = NSRect(x: x + 28, y: 174, width: w - 28, height: 24)
        let bottom = bounds.height - 18 - Metrics.field
        let composerWidth = max(0, w - send.fittedWidth - stop.fittedWidth - Space.s * 2)
        input.frame = NSRect(x: x, y: bottom, width: composerWidth, height: Metrics.field)
        stop.frame = NSRect(x: input.frame.maxX + Space.s, y: bottom, width: stop.fittedWidth, height: Metrics.field)
        send.frame = NSRect(x: stop.frame.maxX + Space.s, y: bottom, width: send.fittedWidth, height: Metrics.field)
        let permissionH: CGFloat = approval == nil ? 0 : 160
        let contentBottom = bottom - Space.m - permissionH, side: CGFloat = min(210, w * 0.27)
        conversationScroll.frame = NSRect(x: x, y: 210, width: max(0, w - side - Space.m), height: max(0, contentBottom - 210))
        timelineTitle.frame = NSRect(x: conversationScroll.frame.maxX + Space.m, y: 212, width: side, height: 22)
        timelineScroll.frame = NSRect(x: timelineTitle.frame.minX, y: 240, width: side, height: max(0, contentBottom - 240))
        permissionTitle.frame = NSRect(x: x, y: contentBottom + 4, width: w - 240, height: 24)
        allow.frame = NSRect(x: bounds.width - x - allow.fittedWidth, y: contentBottom, width: allow.fittedWidth, height: Metrics.button)
        deny.frame = NSRect(x: allow.frame.minX - Space.s - deny.fittedWidth, y: contentBottom, width: deny.fittedWidth, height: Metrics.button)
        permissionScroll.frame = NSRect(x: x, y: contentBottom + 40, width: w, height: max(0, permissionH - 48))
        for (text, scroll) in [(transcript, conversationScroll), (timeline, timelineScroll), (permission, permissionScroll)] {
            text.frame.size.width = scroll.contentSize.width
            text.textContainer?.containerSize.width = scroll.contentSize.width
        }
    }
}
