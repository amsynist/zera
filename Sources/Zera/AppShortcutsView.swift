import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppShortcutsView: NSView, @preconcurrency CardContent {
    private let service: AppShortcuts
    private let heading = NSTextField(labelWithString: "App Shortcuts")
    private let detail = NSTextField(wrappingLabelWithString: "Open or focus your apps with a shortcut. Window layouts and workspaces stay with your window manager.")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let enabled = Toggle()
    private let add = CardButton("Add app…", style: .secondary, target: nil, action: #selector(chooseApp))
    private let scroll = NSScrollView()
    private let body = FlippedView()
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var observer: NSObjectProtocol?
    private var contentHeight: CGFloat = 0
    private var recorders: [ShortcutRecorder] = []
    override var isFlipped: Bool { true }
    var cardWidth: CGFloat { Isle.lensWidth }
    var desiredHeight: CGFloat { 520 }
    var onHeightChange: (() -> Void)?

    convenience init() { self.init(service: .shared) }
    init(service: AppShortcuts) {
        self.service = service
        super.init(frame: .zero)
        heading.font = Typo.paneTitle; heading.textColor = Pal.text
        detail.font = Typo.body; detail.textColor = Pal.textSecondary
        status.font = Typo.caption; status.textColor = Pal.textSecondary
        enabled.setAccessibilityLabel("Enable App Shortcuts")
        enabled.onChange = { [weak self] yes in _ = self?.service.update { $0.enabled = yes } }
        add.target = self
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = body
        [heading, detail, status, enabled, add, scroll].forEach(addSubview)
        observer = NotificationCenter.default.addObserver(forName: AppShortcuts.changed, object: service, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func willShow() { reload() }
    private func reload() {
        // Keep the recording control alive while its callback commits the binding.
        if recorders.contains(where: \.isRecording) { status.stringValue = service.message; return }
        enabled.isOn = service.preferences.enabled; status.stringValue = service.message
        body.subviews.forEach { $0.removeFromSuperview() }; recorders.removeAll(); actions.removeAll()
        let width = max(360, scroll.contentSize.width)
        var y: CGFloat = 0
        if service.preferences.apps.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Add an application, then click its shortcut field to record keys. No Accessibility permission is needed.")
            empty.font = Typo.body; empty.textColor = Pal.textSecondary; empty.frame = CGRect(x: 0, y: 12, width: width - 16, height: 60); body.addSubview(empty); y = 84
        }
        for app in service.preferences.apps {
            let label = NSTextField(labelWithString: app.name); label.font = Typo.control; label.textColor = Pal.text
            label.lineBreakMode = .byTruncatingTail; label.frame = CGRect(x: 0, y: y + 9, width: width - 290, height: 24); body.addSubview(label)
            let recorder = ShortcutRecorder(frame: CGRect(x: width - 280, y: y, width: 160, height: 36))
            recorder.shortcut = app.shortcut; recorder.setAccessibilityLabel(app.name + " shortcut")
            recorder.onRecording = { [weak self, weak service] yes in
                // The view can already be gone when its child recorder tears
                // down. Resume the service independently of the view's lifetime.
                service?.pause(yes)
                if !yes { DispatchQueue.main.async { [weak self] in self?.reload() } }
            }
            recorder.onChange = { [weak self] shortcut in
                self?.service.update { p in if let index = p.apps.firstIndex(where: { $0.bundle == app.bundle }) { p.apps[index].shortcut = shortcut } } ?? false
            }
            body.addSubview(recorder); recorders.append(recorder)
            let open = CardButton("Open", style: .secondary, target: self, action: #selector(tapped(_:)))
            open.setAccessibilityLabel("Open " + app.name); open.frame = CGRect(x: width - 108, y: y, width: 62, height: 36)
            actions[ObjectIdentifier(open)] = { [weak self] in self?.service.launch(app.bundle) }; body.addSubview(open)
            let remove = IconButton(symbol: "minus", label: "Remove " + app.name, target: self, action: #selector(tapped(_:)))
            remove.frame = CGRect(x: width - 36, y: y + 3, width: 30, height: 30)
            actions[ObjectIdentifier(remove)] = { [weak self] in _ = self?.service.update { $0.apps.removeAll { $0.bundle == app.bundle } } }; body.addSubview(remove)
            y += 48
        }
        contentHeight = y; needsLayout = true
    }
    @objc private func tapped(_ sender: NSControl) { actions[ObjectIdentifier(sender)]?() }
    @objc private func chooseApp() {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.prompt = "Add app"
        NSApp.activate(ignoringOtherApps: true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { _ = self?.service.add(url) }
        }
    }
    override func layout() {
        super.layout()
        let x = Metrics.sidePad, width = max(0, bounds.width - 2 * x)
        heading.frame = CGRect(x: x, y: ScreenHeader.titleTop, width: max(0, bounds.width / 2 - Isle.zeraGap / 2 - x), height: ScreenHeader.titleHeight)
        enabled.frame = CGRect(x: bounds.width - x - 44, y: ScreenHeader.controlY(28), width: 44, height: 28)
        detail.frame = CGRect(x: x, y: Isle.headerHeight + 8, width: width, height: 44)
        status.frame = CGRect(x: x, y: detail.frame.maxY + 8, width: width - 124, height: 40)
        add.frame = CGRect(x: bounds.width - x - 112, y: detail.frame.maxY + 8, width: 112, height: 36)
        let oldWidth = scroll.contentSize.width
        scroll.frame = CGRect(x: x, y: status.frame.maxY + 12, width: width, height: max(0, bounds.height - status.frame.maxY - 28))
        if abs(oldWidth - scroll.contentSize.width) > 1 { reload() }
        body.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(contentHeight, scroll.contentSize.height))
    }
}
