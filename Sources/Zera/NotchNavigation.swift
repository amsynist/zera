import AppKit

/// Durable destinations and non-sensitive view preferences. Views remain cached by the
/// controller; drafts, selections containing user text and model objects stay in memory.
final class NotchNavigation {
    static let shared = NotchNavigation()
    private let defaults: UserDefaults
    private let prefix = "zera.navigation."
    private var temporarySettingsReturn: CardKind?
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var remembersScreen: Bool {
        get { defaults.object(forKey: prefix + "remember") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "remember") }
    }
    static func isDestination(_ kind: CardKind) -> Bool {
        switch kind {
        case .home, .shelf, .github, .settings, .claude, .clipboard, .tasks,
             .alerts, .reminders, .teleprompter, .focus, .appShortcuts, .taskExport: return true
        default: return false
        }
    }
    func record(_ kind: CardKind) {
        guard remembersScreen, Self.isDestination(kind) else { return }
        defaults.set(kind.rawValue, forKey: prefix + "screen")
    }
    func destination(fallback: CardKind?) -> CardKind? {
        guard remembersScreen, let raw = defaults.object(forKey: prefix + "screen") as? Int,
              let kind = CardKind(rawValue: raw), Self.isDestination(kind) else { return fallback }
        return kind
    }
    func integer(_ key: String, fallback: Int = 0) -> Int {
        guard remembersScreen else { return fallback }
        return defaults.object(forKey: prefix + key) as? Int ?? fallback
    }
    func string(_ key: String) -> String? { remembersScreen ? defaults.string(forKey: prefix + key) : nil }
    func set(_ value: Int, for key: String) { if remembersScreen { defaults.set(value, forKey: prefix + key) } }
    func set(_ value: String?, for key: String) { if remembersScreen { defaults.set(value, forKey: prefix + key) } }

    func recordSettingsReturn(_ kind: CardKind) {
        guard Self.isDestination(kind), kind != .settings else { return }
        temporarySettingsReturn = kind
        set(kind.rawValue, for: "settings.return")
    }
    var settingsReturn: CardKind {
        let saved = temporarySettingsReturn ?? CardKind(rawValue: integer("settings.return", fallback: CardKind.home.rawValue)) ?? .home
        return Self.isDestination(saved) && saved != .settings ? saved : .home
    }

    /// Save only scroll coordinates, never the contents of fields or clipboard searches.
    func captureScroll(in view: NSView, screen: CardKind) {
        guard remembersScreen else { return }
        for (i, scroll) in scrollViews(in: view).enumerated() {
            let y = scroll.contentView.bounds.minY
            if y.isFinite { defaults.set(Double(y), forKey: prefix + "scroll.\(screen.rawValue).\(i)") }
        }
    }
    func restoreScroll(in view: NSView, screen: CardKind) {
        guard remembersScreen else { return }
        view.layoutSubtreeIfNeeded()
        for (i, scroll) in scrollViews(in: view).enumerated() {
            guard let y = defaults.object(forKey: prefix + "scroll.\(screen.rawValue).\(i)") as? Double, y.isFinite else { continue }
            let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: min(maxY, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }
}

/// Timesheets use the same island header and cached export implementation as Tasks.
final class TaskExportCard: CardBase, CardContent {
    var cardWidth: CGFloat { Isle.lensWidth }
    var desiredHeight: CGFloat { Isle.maxContentHeight }
    let exportView: TaskExportView
    private let back: CardButton
    var onBack: (() -> Void)?
    init(view: TaskExportView) {
        exportView = view
        back = CardButton("Tasks", style: .tertiary, symbol: "chevron.left", target: nil, action: #selector(goBack))
        super.init(width: Isle.lensWidth, title: "Timesheet export")
        setSubtitle("Choose a range, then copy a day or export your tasks")
        exportView.embedded = true
        addSubview(exportView)
        back.target = self
        addSubview(back)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func goBack() { onBack?() }
    override func layout() {
        super.layout()
        layoutHeader()
        let r = headerTrailingRect
        back.frame = NSRect(x: r.maxX - 100, y: r.minY, width: 100, height: Metrics.control)
        exportView.frame = NSRect(x: 0, y: headerBottom, width: bounds.width, height: max(0, bounds.height - headerBottom))
    }
}
