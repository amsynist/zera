import AppKit

struct AppShortcut: Codable, Equatable {
    var name: String
    var bundle: String
    var path: String
    var shortcut: HotKeyShortcut?
}

struct AppShortcutPreferences: Codable, Equatable {
    var enabled = false
    var apps: [AppShortcut] = []
    static let key = "zera.appShortcuts.v1"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Self.self, from: data) { return saved }
        // Read only the launch bindings from either retired manager. Keep original
        // preferences intact for rollback; workspace assignments are not imported.
        struct Legacy: Decodable { var enabled: Bool; var apps: [AppShortcut]?; var rules: [AppShortcut]? }
        for key in ["zera.scrollingWorkspaces.v1", "zera.windowArrangement.v1"] {
            if let data = defaults.data(forKey: key), let old = try? JSONDecoder().decode(Legacy.self, from: data) {
                var seen: Set<String> = []
                let apps = (old.apps ?? old.rules ?? []).filter { !$0.bundle.isEmpty && seen.insert($0.bundle).inserted }
                let migrated = Self(enabled: old.enabled, apps: apps)
                migrated.save(to: defaults)
                return migrated
            }
        }
        return .init()
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
    var hasValidBindings: Bool {
        var seen: Set<String> = []
        return apps.allSatisfy { app in
            guard let key = app.shortcut else { return true }
            return key.isUsable && seen.insert("\(key.keyCode):\(key.modifiers)").inserted
        }
    }
}

/// Launch/activate only. No AX window discovery, frame writes, gestures or polling.
@MainActor
final class AppShortcuts {
    static let shared = AppShortcuts()
    static let changed = Notification.Name("ZeraAppShortcutsChanged")
    private(set) var preferences: AppShortcutPreferences
    private(set) var message = "Choose apps and record their shortcuts."
    private let defaults: UserDefaults
    private var keys: [GlobalHotKey] = []
    private(set) var unavailableApps: [String] = []
    var registeredCount: Int { keys.count }
    private var paused = false
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; preferences = .load(from: defaults) }
    func start() {
        if !register() { message = "Shortcut unavailable: \(unavailableApps.joined(separator: ", ")). Other app shortcuts remain active." }
        else { message = preferences.enabled ? "\(keys.count) app shortcuts are active." : "App shortcuts are off." }
        post()
    }
    func stop() { keys.removeAll() }
    @discardableResult func update(_ change: (inout AppShortcutPreferences) -> Void) -> Bool {
        let previous = preferences
        change(&preferences)
        // Recording pauses live bindings, but the proposed keys must still be
        // checked with Carbon before persisting them. Release probes immediately.
        guard preferences.hasValidBindings, register(checkWhilePaused: true) else {
            preferences = previous; _ = register()
            message = "That shortcut is already in use or needs ⌘, ⌥ or ⌃."; post(); return false
        }
        preferences.save(to: defaults); message = preferences.enabled ? "App shortcuts are enabled." : "App shortcuts are off."; post(); return true
    }
    func pause(_ value: Bool) {
        paused = value
        if !register() { message = "A shortcut became unavailable. Change it below."; post() }
    }
    @discardableResult func add(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app", let app = Bundle(url: url), let id = app.bundleIdentifier else {
            message = "Choose a macOS application."; post(); return false
        }
        return update { p in
            let name = (app.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (app.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
            if let index = p.apps.firstIndex(where: { $0.bundle == id }) { p.apps[index].path = url.path; p.apps[index].name = name }
            else { p.apps.append(.init(name: name, bundle: id, path: url.path)) }
        }
    }
    func launch(_ bundle: String) {
        guard let rule = preferences.apps.first(where: { $0.bundle == bundle }) else { return }
        let started = ProcessInfo.processInfo.systemUptime
        // Resolve a fresh process by bundle ID first. The common running-app path
        // needs neither LaunchServices discovery nor per-process symlink I/O.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: rule.bundle).first { !$0.isTerminated }
        let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundle) ?? URL(fileURLWithPath: rule.path)
        guard running != nil || FileManager.default.fileExists(atPath: url.path) else { message = "Add \(rule.name) again to update its location."; post(); return }
        if #available(macOS 14.0, *), NSApp.isActive, let running { NSApp.yieldActivation(to: running) }
        // Match native `open -a`, including reopen/restore semantics. Activating
        // just the process can do nothing when its windows are hidden/minimized.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true; configuration.createsNewApplicationInstance = false
        Diag.log("app shortcut open requested: \(rule.bundle), running \(running != nil)")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            Diag.log("app shortcut open completed: \(rule.bundle), \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))ms, success \(error == nil)")
            guard error != nil else { return }
            Task { @MainActor in self?.message = "The application could not open."; self?.post() }
        }
    }
    private func register(checkWhilePaused: Bool = false) -> Bool {
        keys.removeAll()
        unavailableApps.removeAll()
        guard preferences.enabled, !paused || checkWhilePaused else { return true }
        var pending: [GlobalHotKey] = []
        for app in preferences.apps {
            guard let shortcut = app.shortcut else { continue }
            guard shortcut.isUsable else { unavailableApps.append(app.name); continue }
            guard let key = GlobalHotKey(shortcut, handler: { [weak self] in self?.launch(app.bundle) }) else {
                unavailableApps.append(app.name); continue
            }
            pending.append(key)
        }
        if !paused { keys = pending }
        return unavailableApps.isEmpty
    }
    private func post() { NotificationCenter.default.post(name: Self.changed, object: self) }
}
