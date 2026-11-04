import AppKit
import ApplicationServices
import UniformTypeIdentifiers

/// A real window-plan thumbnail; tapping it applies the same geometry it previews.
final class ArrangePreview: NSButton {
    var layoutStyle: ArrangeLayout = .grid
    var count = 3
    var available = true
    var displayAspect: CGFloat = 1.6
    var chosen = false
    var onChoose: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityValue() -> Any? { NSNumber(value: chosen) }
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; title = ""
        target = self; action = #selector(choose); setButtonType(.radio)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func choose() { onChoose?() }
    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.m, yRadius: Radius.m)
        (chosen ? Pal.selectedFill : Pal.surfaceRow).setFill(); box.fill()
        (chosen ? Pal.accentBorder : Pal.divider).setStroke(); box.lineWidth = 1; box.stroke()
        let height = max(0, bounds.height - 42), width = min(bounds.width - 32, height * displayAspect)
        let screen = CGRect(x: (bounds.width - width) / 2, y: 12, width: width, height: height)
        let cells = layoutStyle.frames(count: max(1, count), in: screen, gap: 4)
        for (i, rect) in cells.enumerated() {
            (available ? (chosen ? Pal.accent.withAlphaComponent(i == 0 ? 0.5 : 0.24) : Pal.textSecondary.withAlphaComponent(0.12)) : Pal.textTertiary.withAlphaComponent(0.06)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
        ((count == 1 ? "Fill display" : layoutStyle.title) as NSString).draw(at: NSPoint(x: 16, y: bounds.height - 25), withAttributes: [.font: Typo.control, .foregroundColor: available ? Pal.text : Pal.textTertiary])
        if !available { ("Too small" as NSString).draw(at: NSPoint(x: bounds.width - 70, y: bounds.height - 24), withAttributes: [.font: Typo.caption, .foregroundColor: Pal.textTertiary]) }
        drawControlFocus()
    }
}

@MainActor
final class WindowArrangementView: NSView, @preconcurrency CardContent {
    private let service: WindowArrangementService
    private let heading = NSTextField(labelWithString: "Arrange")
    private let subtitle = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let enabled = Toggle()
    private let enabledLabel = NSTextField(labelWithString: "Enabled")
    private let pages = PillTabs(titles: ["Layouts", "Workspaces", "Shortcuts"])
    private let scroll = NSScrollView(), body = FlippedView(), footer = FlippedView()
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var page = min(2, max(0, NotchNavigation.shared.integer("arrange.page"))), selected: ArrangeLayout = .grid
    private var lastEngineLayout: ArrangeLayout = .grid
    private var bodyHeight: CGFloat = 0
    private var contentWidth: CGFloat = 0
    private var lastWindows: [ArrangeWindow] = []
    private var lastSettings: Data?
    private var lastState = ""
    private var observer: NSObjectProtocol?
    var onOpenPermissions: (() -> Void)?
    private var recorders: [ShortcutRecorder] = []
    private var previews: [ArrangePreview] = []
    var onHeightChange: (() -> Void)?
    var cardWidth: CGFloat { Isle.lensWidth }
    var desiredHeight: CGFloat { Isle.maxContentHeight }
    override var isFlipped: Bool { true }
    convenience init() { self.init(service: .shared) }
    init(service: WindowArrangementService) {
        self.service = service
        super.init(frame: .zero)
        heading.font = Typo.screenTitle; heading.textColor = Pal.text
        subtitle.font = Typo.screenSubtitle; subtitle.textColor = Pal.textSecondary; subtitle.lineBreakMode = .byTruncatingTail
        status.font = Typo.secondary; status.textColor = Pal.textSecondary; status.maximumNumberOfLines = 2
        status.setAccessibilityLabel("Window arrangement status")
        enabledLabel.font = Typo.control; enabledLabel.textColor = Pal.textSecondary
        enabled.setAccessibilityLabel("Enable window arrangements")
        enabled.onChange = { [weak self] yes in self?.service.setEnabled(yes) }
        pages.onSelect = { [weak self] index in
            guard let self else { return }
            self.recorders.forEach { $0.cancelRecording() }
            self.page = index; NotchNavigation.shared.set(index, for: "arrange.page"); self.lastState = ""
            self.scroll.contentView.scroll(to: .zero); self.reload()
        }
        scroll.documentView = body; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        [heading, subtitle, enabledLabel, enabled, pages, status, scroll, footer].forEach(addSubview)
        observer = NotificationCenter.default.addObserver(forName: WindowArrangementService.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window != nil, self?.isHiddenOrHasHiddenAncestor == false { self?.reload() } }
        }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func willShow() { selected = service.layout; reload(); service.refresh() }
    private func reload() {
        if service.layout != lastEngineLayout { selected = service.layout; lastEngineLayout = service.layout }
        enabled.isOn = service.enabled; enabled.isEnabled = service.enabled || !service.busy
        subtitle.stringValue = "\(service.currentWindows.count) \(service.currentWindows.count == 1 ? "window" : "windows") · Workspace \(service.workspace)"
        status.stringValue = service.resizeMode ? "Resize mode · H/L width · J/K height · Return or Esc finishes" : service.message
        guard !recorders.contains(where: \.isRecording), !ZeraDropdown.shared.isOpen else { return }
        let settings = try? JSONEncoder().encode(service.settings)
        let state = "\(page)|\(service.selectedDisplay)|\(service.active)|\(service.busy)|\(service.canUndo)|\(service.displays)|\(service.focused ?? "")"
        guard state != lastState || service.windows != lastWindows || settings != lastSettings else { return }
        lastState = state; lastWindows = service.windows; lastSettings = settings
        let offset = scroll.contentView.bounds.origin
        body.subviews.forEach { $0.removeFromSuperview() }; footer.subviews.forEach { $0.removeFromSuperview() }; actions.removeAll(); recorders = []; previews = []
        let width = max(240, contentWidth > 0 ? contentWidth : cardWidth - Metrics.sidePad * 2)
        var y: CGFloat = 0
        func text(_ value: String, height: CGFloat = 36, strong: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: value); label.font = strong ? Typo.rowTitleStrong : Typo.secondary
            label.textColor = strong ? Pal.text : Pal.textSecondary
            label.frame = CGRect(x: 0, y: y, width: width, height: height); body.addSubview(label); y += height + Space.s
        }
        if !service.enabled {
            text("Switch window groups together without sending windows through the Dock. Windows return when you switch back or turn this off. Your ⌘W, ⌘M and ⌘1–9 bindings override the usual app shortcuts while enabled.", height: 52)
        }
        if !AXIsProcessTrusted() {
            let b = button("Permissions & Diagnostics…") { [weak self] in self?.onOpenPermissions?() }
            b.frame = CGRect(x: 0, y: y, width: 200, height: Metrics.control); y += Metrics.control + Space.m
        }
        switch page {
        case 0:
            let display = ZeraSelect(service.displays.map(\.name)); display.setAccessibilityLabel("Arrange display")
            display.selectedIndex = service.displays.firstIndex(where: { $0.id == service.selectedDisplay }) ?? 0
            display.onChange = { [weak self] index in guard let self, self.service.displays.indices.contains(index) else { return }; self.service.selectDisplay(self.service.displays[index].id) }
            display.frame = CGRect(x: 0, y: y, width: width * 0.42, height: Metrics.control); body.addSubview(display)
            let apps = service.applications
            let scope = ZeraSelect(["All apps", service.settings.includedApps.map { "\($0.count) selected apps…" } ?? "Choose apps…"] + apps.map { $0.localizedName ?? "App" }); scope.setAccessibilityLabel("Window scope")
            scope.selectedIndex = service.settings.includedApps != nil ? 1 : service.settings.scope.flatMap { bundle in apps.firstIndex { $0.bundleIdentifier == bundle } }.map { $0 + 2 } ?? 0
            scope.onChange = { [weak self] index in
                if index == 1 { self?.chooseApps() }
                else { self?.service.updateScope(index == 0 ? nil : apps[index - 2].bundleIdentifier) }
            }
            scope.isEnabled = !service.busy
            scope.frame = CGRect(x: width * 0.42 + Space.m, y: y, width: width * 0.58 - Space.m, height: Metrics.control); body.addSubview(scope)
            y += Metrics.control + Space.m
            let visual = Toggle(); visual.isOn = service.settings.visualTransitions == true
            visual.setAccessibilityLabel("Visual window transitions"); visual.isEnabled = !service.busy
            if #available(macOS 14.0, *) {} else { visual.isEnabled = false }
            visual.onChange = { [weak self] yes in self?.service.setVisualTransitions(yes) }
            visual.frame = CGRect(x: width - 44, y: y, width: 44, height: 28); body.addSubview(visual)
            text("Visual transitions", height: 28, strong: true)
            text("Animate temporary window images for smoother movement. Live content pauses briefly; images stay in memory.", height: 40)
            if visual.isOn && !service.hasVisualAccess {
                let access = button("Permissions & Diagnostics…") { [weak self] in self?.onOpenPermissions?() }
                access.frame = CGRect(x: 0, y: y, width: 232, height: Metrics.control); y += Metrics.control + Space.m
            }
            let count = service.currentWindows.count, members = service.currentWindows
            if count == 0 { text("No resizable windows on this desktop. Leave full screen, switch to a desktop with apps, or change Window scope.", height: 40) }
            let choices: [ArrangeLayout] = count > 0 ? ArrangeLayout.choices(count: count) : []
            if count == 3 && selected == .grid { selected = .twoAbove }
            else if !choices.contains(selected), let first = choices.first { selected = first }
            let gap = Space.s, tileW = (width - 2 * gap) / 3
            for (i, choice) in choices.enumerated() {
                let preview = ArrangePreview(frame: CGRect(x: CGFloat(i % 3) * (tileW + gap), y: y + CGFloat(i / 3) * 104, width: tileW, height: 92))
                preview.layoutStyle = choice; preview.count = count; preview.displayAspect = service.display.map { $0.frame.width / max(1, $0.frame.height) } ?? 1.6; preview.chosen = selected == choice
                preview.available = service.display.map { ArrangeGeometry.fits(choice.frames(count: count, in: $0.area), windows: members, in: $0.area) } ?? false
                preview.isEnabled = service.enabled && !service.busy && preview.available
                preview.setAccessibilityLabel("\(count == 1 ? "Fill display" : choice.title), \(count) windows\(preview.available ? "" : ", too small")")
                preview.onChoose = { [weak self] in self?.selectLayout(choice) }
                previews.append(preview); body.addSubview(preview)
            }
            y += CGFloat((choices.count + 2) / 3) * 104 + Space.s
            let undo = button("Undo") { [weak self] in self?.service.undoLast() }; undo.isEnabled = service.canUndo && !service.busy && service.enabled
            footer.addSubview(undo)
            undo.frame = CGRect(x: 0, y: 0, width: 88, height: Metrics.control)
            let rotate = button("Rotate") { [weak self] in self?.service.rotate() }; rotate.isEnabled = count > 1 && service.enabled && !service.busy
            footer.addSubview(rotate)
            rotate.frame = CGRect(x: 100, y: 0, width: 88, height: Metrics.control)
            let sample = button("Preview motion") { [weak self] in self?.service.previewVisualMotion() }
            sample.isEnabled = !service.busy
            footer.addSubview(sample); sample.frame = CGRect(x: 200, y: 0, width: 152, height: Metrics.control)
            let refresh = button("Refresh") { [weak self] in self?.service.refresh() }; refresh.isEnabled = !service.busy
            footer.addSubview(refresh)
            refresh.frame = CGRect(x: width - 100, y: 0, width: 100, height: Metrics.control)
            if count > service.settings.capacity {
                let counts = ArrangeGeometry.distribution(count: count, capacity: service.settings.capacity)
                let split = button("Distribute · " + counts.map { String($0) }.joined(separator: " / ")) { [weak self] in self?.service.distribute() }
                split.isEnabled = service.enabled && !service.busy
                split.frame = CGRect(x: 0, y: y, width: min(width, 290), height: Metrics.control); y += Metrics.control + Space.m
            }
            text("Windows", height: 24, strong: true)
            for window in members {
                let row = SessionInfoRow(symbol: "macwindow", tint: Pal.textSecondary, title: window.title.isEmpty ? window.app : window.title, subtitle: window.app, trailing: "")
                row.setAccessibilityElement(true); row.setAccessibilityRole(.staticText); row.setAccessibilityLabel(window.title); row.setAccessibilityValue(window.app)
                row.frame = CGRect(x: 0, y: y, width: width - 180, height: 52); body.addSubview(row)
                let move = ZeraSelect((1...9).map { "Workspace \($0)" }); move.setAccessibilityLabel("Move \(window.title.isEmpty ? window.app : window.title) to workspace")
                move.selectedIndex = window.workspace - 1; move.isEnabled = service.enabled && !service.busy
                move.onChange = { [weak self] index in self?.service.moveWindow(window.id, to: index + 1) }
                move.frame = CGRect(x: width - 168, y: y + 8, width: 168, height: Metrics.control); body.addSubview(move); y += 60
            }
        case 1:
            text("Nine Zera window groups, independent of macOS Spaces. Workspaces 1–2 prefer the main display; 3–7 prefer the secondary display. Missing displays fall back to the main one.", height: 44)
            for group in 1...9 {
                let count = service.windows.filter { $0.workspace == group }.count
                let open = button("\(group)    \(count) \(count == 1 ? "window" : "windows")\(service.active.values.contains(group) ? " · visible" : "")") { [weak self] in self?.service.switchWorkspace(group) }
                open.isEnabled = service.enabled && !service.busy
                open.frame = CGRect(x: 0, y: y, width: width * 0.48, height: Metrics.control)
                let select = ZeraSelect(service.displays.map(\.name)); select.setAccessibilityLabel("Workspace \(group) display")
                select.selectedIndex = service.displays.firstIndex { $0.id == service.displayForWorkspace(group) } ?? 0
                select.onChange = { [weak self] index in guard let self, self.service.displays.indices.contains(index) else { return }; self.service.assignDisplay(group, to: self.service.displays[index].id) }
                select.isEnabled = service.enabled && !service.busy
                select.frame = CGRect(x: width * 0.5, y: y, width: width * 0.5, height: Metrics.control); body.addSubview(select)
                y += Metrics.control + Space.s
            }
            let restore = button("Restore Zera-hidden windows") { [weak self] in self?.service.setEnabled(false) }
            restore.isEnabled = !service.busy; restore.frame = CGRect(x: 0, y: y, width: 260, height: Metrics.control); y += Metrics.control + Space.s
            text("Turns arrangements off and restores only windows recorded by Zera, including interrupted sessions.", height: 36)
            y += Space.m; text("App assignment", height: 24, strong: true)
            text("Defaults for new windows. App shortcuts follow existing windows in their current workspaces.", height: 36)
            for (i, rule) in service.settings.rules.enumerated() {
                let name = NSTextField(labelWithString: rule.name); name.font = Typo.control; name.textColor = Pal.text
                name.frame = CGRect(x: 0, y: y + 8, width: width - 220, height: 24); body.addSubview(name)
                let select = ZeraSelect(["Current workspace"] + (1...9).map { "Workspace \($0)" }); select.setAccessibilityLabel("\(rule.name) workspace")
                select.selectedIndex = rule.workspace ?? 0
                select.onChange = { [weak self] value in self?.service.setRule(i, workspace: value == 0 ? nil : value) }
                select.frame = CGRect(x: width - 204, y: y, width: 204, height: Metrics.control); body.addSubview(select); y += Metrics.control + Space.s
            }
            y += Space.s
            let automatic = Toggle(); automatic.isOn = service.settings.automatic; automatic.setAccessibilityLabel("Automatically arrange new windows")
            automatic.onChange = { [weak self] value in self?.service.setAutomatic(value) }
            automatic.frame = CGRect(x: width - 44, y: y, width: 44, height: 28); body.addSubview(automatic)
            text("Automatically arrange new windows", height: 28)
            let limit = ZeraSelect(["2 windows", "3 windows", "4 windows", "5 windows", "6 windows"]); limit.selectedIndex = service.settings.capacity - 2
            limit.setAccessibilityLabel("Windows per workspace"); limit.onChange = { [weak self] value in self?.service.setCapacity(value + 2) }
            limit.frame = CGRect(x: width - 180, y: y, width: 180, height: Metrics.control); body.addSubview(limit)
            text("Distribution limit", height: Metrics.control)
        default:
            text("⌥Arrows focus · ⌥⇧Arrows resize the shared edge. Click a keycap to change it; Delete turns it off. A conflicting key leaves the previous binding in place.", height: 44)
            text("Open apps", height: 24, strong: true)
            for (i, rule) in service.settings.rules.enumerated() {
                let installed = FileManager.default.fileExists(atPath: rule.path)
                let title = NSTextField(labelWithString: rule.name + (installed ? "" : " · not installed")); title.font = Typo.control; title.textColor = Pal.text
                title.frame = CGRect(x: 0, y: y + 8, width: width - 310, height: 24); body.addSubview(title)
                let choose = button("Choose app…") { [weak self] in self?.chooseApp(i) }; choose.frame = CGRect(x: width - 300, y: y, width: 140, height: Metrics.control)
                let key = recorder(rule.shortcut) { [weak self] shortcut in self?.service.setRuleShortcut(i, shortcut: shortcut) ?? false }
                key.setAccessibilityLabel("\(rule.name) launch shortcut"); key.frame = CGRect(x: width - 148, y: y, width: 148, height: Metrics.control); y += Metrics.control + Space.s
            }
            let add = button("Add app…") { [weak self] in self?.chooseApp(nil) }; add.frame = CGRect(x: 0, y: y, width: 140, height: Metrics.control); y += Metrics.control + Space.l
            text("Window controls", height: 24, strong: true)
            for (id, title, fallback) in ArrangeSettings.bindings {
                let name = NSTextField(labelWithString: title); name.font = Typo.control; name.textColor = Pal.text
                name.frame = CGRect(x: 0, y: y + 8, width: width - 180, height: 24); body.addSubview(name)
                let key = recorder(service.binding(id, fallback: fallback)) { [weak self] shortcut in self?.service.setShortcut(id, shortcut) ?? false }
                key.setAccessibilityLabel(title + " shortcut"); key.frame = CGRect(x: width - 168, y: y, width: 168, height: Metrics.control); y += Metrics.control + Space.s
            }
        }
        bodyHeight = y + Space.m; needsLayout = true
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(offset.y, max(0, bodyHeight - scroll.contentSize.height)))); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func selectLayout(_ layout: ArrangeLayout) {
        guard service.enabled, !service.busy else { return }
        selected = layout
        for preview in previews {
            preview.chosen = preview.layoutStyle == layout
            preview.state = preview.chosen ? .on : .off
            preview.needsDisplay = true
        }
        // Let the click finish before the service's busy state rebuilds these controls.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.service.enabled, !self.service.busy else { return }
            self.service.apply(layout)
        }
    }
    private func recorder(_ shortcut: HotKeyShortcut?, changed: @escaping (HotKeyShortcut?) -> Bool) -> ShortcutRecorder {
        let recorder = ShortcutRecorder(); recorder.shortcut = shortcut; recorder.onChange = changed
        recorder.onRecording = { [weak self] paused in self?.service.pauseShortcuts(paused) }
        recorders.append(recorder); body.addSubview(recorder); return recorder
    }
    private func button(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> CardButton {
        let button = CardButton(title, style: primary ? .primary : .secondary, target: self, action: #selector(tapped(_:)))
        actions[ObjectIdentifier(button)] = action; body.addSubview(button); return button
    }
    @objc private func tapped(_ sender: NSControl) { actions[ObjectIdentifier(sender)]?() }
    private func chooseApps() {
        guard let window, window.attachedSheet == nil, !service.busy else { return }
        let alert = NSAlert(); alert.messageText = "Apps to arrange"; alert.informativeText = "Only checked apps are included in layouts and Zera workspaces"
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        let apps = service.applications, document = FlippedView()
        var choices: [(String, NSButton)] = []
        for (index, app) in apps.enumerated() {
            guard let id = app.bundleIdentifier else { continue }
            let check = NSButton(checkboxWithTitle: app.localizedName ?? id, target: nil, action: nil)
            check.font = Typo.control; check.state = service.settings.includedApps?.contains(id) == true || service.settings.scope == id ? .on : .off
            check.frame = CGRect(x: 8, y: CGFloat(index) * 32 + 8, width: 340, height: 28)
            document.addSubview(check); choices.append((id, check))
        }
        document.frame = CGRect(x: 0, y: 0, width: 360, height: CGFloat(apps.count) * 32 + 16)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: min(320, document.frame.height)))
        scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        alert.accessoryView = scroll
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.service.updateScope(nil, included: Set(choices.filter { $0.1.state == .on }.map(\.0))) }
        }
    }
    private func chooseApp(_ index: Int?) {
        guard let window, window.attachedSheet == nil, !service.busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose app"; NSApp.activate(ignoringOtherApps: true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.service.chooseApp(url, replacing: index) }
        }
    }
    override func layout() {
        super.layout()
        let x = Metrics.sidePad, w = max(0, bounds.width - 2 * x)
        heading.frame = CGRect(x: x, y: ScreenHeader.titleTop, width: max(0, bounds.width / 2 - Isle.zeraGap / 2 - x), height: ScreenHeader.titleHeight)
        subtitle.frame = ScreenHeader.subtitleFrame(width: bounds.width, padding: x)
        enabled.frame = CGRect(x: bounds.width - x - 44, y: ScreenHeader.controlY(28), width: 44, height: 28)
        enabledLabel.frame = CGRect(x: enabled.frame.minX - 76, y: enabled.frame.minY + 3, width: 68, height: 24)
        pages.frame = CGRect(x: x, y: Isle.headerHeight, width: w, height: Metrics.segment)
        status.frame = CGRect(x: x, y: pages.frame.maxY + Space.s, width: w, height: 40)
        footer.isHidden = page != 0
        footer.frame = CGRect(x: x, y: bounds.height - Space.m - Metrics.control, width: w, height: Metrics.control)
        scroll.frame = CGRect(x: x, y: status.frame.maxY + Space.s, width: w, height: max(0, (page == 0 ? footer.frame.minY - Space.m : bounds.height - Space.s) - status.frame.maxY - Space.s))
        if abs(contentWidth - scroll.contentSize.width) > 1 { contentWidth = scroll.contentSize.width; lastState = ""; reload() }
        body.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(bodyHeight, scroll.contentSize.height))
    }
}
