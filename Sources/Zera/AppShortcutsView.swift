import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppShortcutsView: NSView, @preconcurrency CardContent {
    private let service: AppShortcuts
    private let heading = NSTextField(labelWithString: "App Shortcuts")
    private let detail = NSTextField(labelWithString: "Open or focus each app with a shortcut")
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
        heading.font = Typo.screenTitle; heading.textColor = Pal.text
        detail.font = Typo.screenSubtitle; detail.textColor = Pal.textSecondary; detail.lineBreakMode = .byTruncatingTail
        status.font = Typo.caption; status.textColor = Pal.textSecondary; status.maximumNumberOfLines = 2
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
        if recorders.contains(where: \.isRecording) { status.stringValue = Self.caption(service.message); return }
        enabled.isOn = service.preferences.enabled; status.stringValue = Self.caption(service.message)
        body.subviews.forEach { $0.removeFromSuperview() }; recorders.removeAll(); actions.removeAll()
        let width = max(360, scroll.contentSize.width)
        var y: CGFloat = 0
        if service.preferences.apps.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Add an application, then click its shortcut field to record keys. No Accessibility permission is needed.")
            empty.font = Typo.body; empty.textColor = Pal.textSecondary; empty.frame = CGRect(x: 0, y: Space.s, width: width - Space.l, height: 60); body.addSubview(empty); y = 76
        }
        for app in service.preferences.apps {
            let label = NSTextField(labelWithString: app.name); label.font = Typo.control; label.textColor = Pal.text
            label.lineBreakMode = .byTruncatingTail; label.frame = CGRect(x: 0, y: y + 6, width: width - 288, height: 20); body.addSubview(label)
            let recorder = ShortcutRecorder(frame: CGRect(x: width - 276, y: y, width: 160, height: Metrics.button))
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
            open.setAccessibilityLabel("Open " + app.name); open.frame = CGRect(x: width - 108, y: y, width: 64, height: Metrics.button)
            actions[ObjectIdentifier(open)] = { [weak self] in self?.service.launch(app.bundle) }; body.addSubview(open)
            let remove = IconButton(symbol: "minus", label: "Remove " + app.name, target: self, action: #selector(tapped(_:)))
            remove.frame = CGRect(x: width - 32, y: y, width: Metrics.button, height: Metrics.button)
            actions[ObjectIdentifier(remove)] = { [weak self] in _ = self?.service.update { $0.apps.removeAll { $0.bundle == app.bundle } } }; body.addSubview(remove)
            y += Metrics.button + Space.s
        }
        contentHeight = y; needsLayout = true
    }
    /// A one-sentence status reads as a caption, so it drops its full stop.
    static func caption(_ message: String) -> String {
        guard message.hasSuffix("."), !message.dropLast().contains(". ") else { return message }
        return String(message.dropLast())
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
        heading.frame = ScreenHeader.titleFrame(width: bounds.width, padding: x)
        detail.frame = ScreenHeader.subtitleFrame(width: bounds.width, padding: x)
        enabled.frame = CGRect(x: bounds.width - x - 44, y: ScreenHeader.blockControlY(28), width: 44, height: 28)
        // The status and Add app share one row, centred on each other.
        let addWidth = max(112, add.fittedWidth), rowTop = Isle.headerHeight
        add.frame = CGRect(x: bounds.width - x - addWidth, y: rowTop, width: addWidth, height: Metrics.button)
        let statusWidth = max(0, width - addWidth - Space.l)
        let statusHeight = min(Metrics.button, ceil(status.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: statusWidth, height: 200)).height ?? 16))
        status.frame = CGRect(x: x, y: rowTop + (Metrics.button - statusHeight) / 2, width: statusWidth, height: statusHeight)
        let oldWidth = scroll.contentSize.width
        scroll.frame = CGRect(x: x, y: add.frame.maxY + Space.m, width: width, height: max(0, bounds.height - add.frame.maxY - Space.m - Space.l))
        if abs(oldWidth - scroll.contentSize.width) > 1 { reload() }
        body.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(contentHeight, scroll.contentSize.height))
    }
}
