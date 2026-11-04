import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Optional, event-driven window groups. Disabled means no hotkeys, AX observers or polling.
@MainActor
final class WindowArrangementService {
    static let shared = WindowArrangementService()
    static let changed = Notification.Name("ZeraWindowArrangementChanged")
    private(set) var settings = ArrangeSettings.load()
    private(set) var windows: [ArrangeWindow] = []
    private(set) var displays = ArrangeDisplay.current()
    private(set) var active: [String: Int] = [:]
    private(set) var selectedDisplay = ""
    private(set) var focused: String?
    private(set) var message = "Window arrangements are off"
    private(set) var busy = false
    private(set) var resizeMode = false
    private(set) var canUndo = false
    private(set) var hiddenCount = 0
    private var assignments: [String: Int] = [:]
    private var displayRules: [Int: String] = [:]
    private var layouts: [Int: ArrangeLayout] = [:]
    private var ratios: [Int: CGFloat] = [:]
    private var manualLayouts: [Int: ArrangeManualLayout] = [:]
    private var order: [String] = []
    private var floating: Set<String> = []
    private var filled: [String: CGRect] = [:]
    private var previous: Int?
    private var hotkeys: [GlobalHotKey] = [], modeKeys: [GlobalHotKey] = []
    private var notices: [NSObjectProtocol] = []
    private var debounce: DispatchWorkItem?, resizeExit: DispatchWorkItem?
    private var generation = 0
    private var refreshRequests = ArrangeRefreshRequests()
    private var activatingPID: pid_t?
    private var pendingShortcut = ArrangePendingShortcut()
    private var focusTicket = UUID()
    private var lastFailure: String?
    private let queue = DispatchQueue(label: "zera.window-arrangement", qos: .userInitiated)
    private let access: ArrangeWindowAccess
    private typealias Snapshot = (windows: [ArrangeWindow], active: [String: Int], displays: [Int: String], manualLayouts: [Int: ArrangeManualLayout])
    private var undoStack: [Snapshot] = []
    private var visualScene: ArrangeVisualTransition?
    private var motionPreview: ArrangeVisualTransition?
    private var visualTicket: UUID?
    private var visualDeadline: DispatchWorkItem?
    var enabled: Bool { settings.enabled }
    var workspace: Int { active[selectedDisplay] ?? 1 }
    var display: ArrangeDisplay? { displays.first { $0.id == selectedDisplay } }
    var currentWindows: [ArrangeWindow] { windows.filter { $0.workspace == workspace && !$0.floating } }
    var layout: ArrangeLayout { layouts[workspace] ?? .grid }
    var competingManager: Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "bobko.aerospace" } }
    var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.bundleIdentifier != nil }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zera", isDirectory: true)
        access = ArrangeWindowAccess(journalURL: folder.appendingPathComponent("window-recovery.json"))
        access.onEvent = { [weak self] pid, focusChanged in DispatchQueue.main.async {
            guard let self else { return }
            // Follow deliberate selection of a parked window (including another window
            // in the same app), not focus notifications caused by our own transaction.
            if focusChanged, !self.busy { self.activatingPID = pid }
            self.scheduleRefresh(pid: pid)
        } }
    }
    private func appList(all: Bool = false) -> [ArrangeApplication] {
        applications.filter { app in
            if Bundle.main.bundleIdentifier?.hasSuffix(".review") == true, app.bundleIdentifier == "com.openai.codex" { return false }
            return all || (settings.includedApps.map { $0.contains(app.bundleIdentifier ?? "") } ?? (settings.scope == nil || app.bundleIdentifier == settings.scope))
        }.map {
            return .init(pid: $0.processIdentifier, bundle: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "App")
        }
    }
    private func post() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
        if let action = pendingShortcut.take(ready: enabled && !busy) { DispatchQueue.main.async(execute: action) }
    }
    func startIfEnabled() {
        if access.hasRecovery, AXIsProcessTrusted() {
            let apps = appList(all: true), access = access, screens = displays.map(\.frame)
            queue.async { [weak self] in let left = access.recover(apps: apps, displays: screens); DispatchQueue.main.async { [weak self] in
                if left > 0 { self?.message = "\(left) saved windows need manual recovery in their app" }
                self?.post()
            } }
        }
        if enabled { setEnabled(true) }
    }
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    var hasVisualAccess: Bool { CGPreflightScreenCaptureAccess() }
    func setVisualTransitions(_ yes: Bool) {
        settings.visualTransitions = yes; settings.save()
        if !yes { visualScene?.cancel(); visualScene = nil }
        message = yes && !hasVisualAccess ? "Visual transitions need Screen Recording access. Preview works without it." : "Window motion updated"
        post()
    }
    func requestVisualAccess() { _ = CGRequestScreenCaptureAccess(); post() }
    func previewVisualMotion() {
        motionPreview?.cancel(); motionPreview = ArrangeVisualTransition.preview()
        motionPreview?.onClose = { [weak self] in self?.motionPreview = nil }
    }
    func setEnabled(_ yes: Bool) {
        guard !yes || !busy else { return }
        lastFailure = nil
        if yes {
            guard AXIsProcessTrusted() else { settings.enabled = false; settings.save(); message = "Allow Accessibility to arrange windows, then enable this feature"; post(); return }
            guard !competingManager else { settings.enabled = false; settings.save(); message = "Quit AeroSpace before enabling Zera window arrangements"; post(); return }
            if !settings.enabled { assignments.removeAll() }
            settings.enabled = true; settings.save()
            if !registerShortcuts() { settings.enabled = false; settings.save(); message = "A shortcut is already taken. Edit Shortcuts or quit the competing app."; post(); return }
            installNotices(); refresh(adopt: true)
        } else {
            settings.enabled = false; settings.save(); stopListeners(); generation += 1
            busy = true; message = "Restoring Zera-hidden windows…"; post()
            let access = access, apps = appList(all: true)
            queue.async { [weak self] in _ = access.restoreHidden(); let remaining = access.hasRecovery ? access.recover(apps: apps) : 0; DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false; self.hiddenCount = remaining
                self.message = remaining == 0 ? "Window arrangements are off" : "\(remaining) windows refused restoring; use their Dock menu"
                self.post()
            } }
        }
    }
    func updateScope(_ bundle: String?, included: Set<String>? = nil) {
        guard !busy else { return }
        let resume = enabled
        settings.enabled = false; settings.save()
        stopListeners(); generation += 1; busy = true
        let access = access
        queue.async { [weak self] in let remaining = access.restoreHidden(); DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.busy = false; self.hiddenCount = remaining
            guard remaining == 0 else { self.message = "Restore hidden windows before changing scope"; self.post(); return }
            self.settings.scope = bundle; self.settings.includedApps = included; self.settings.save(); self.windows = []; self.assignments = [:]; self.order = []; self.undoStack.removeAll(); self.canUndo = false
            if resume { self.setEnabled(true) } else { self.refresh() }
        } }
    }
    func setAutomatic(_ yes: Bool) { settings.automatic = yes; settings.save(); post() }
    func setCapacity(_ count: Int) { settings.capacity = min(6, max(2, count)); settings.save(); post() }
    func selectDisplay(_ id: String) { guard displays.contains(where: { $0.id == id }) else { return }; selectedDisplay = id; post() }
    private func targetDisplay(_ group: Int) -> String {
        if let id = displayRules[group], displays.contains(where: { $0.id == id }) { return id }
        let main = displays.first(where: \.main) ?? displays.first
        return ((3...7).contains(group) ? displays.first(where: { !$0.main }) ?? main : main)?.id ?? ""
    }
    private func installNotices() {
        guard notices.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            notices.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.competingManager { self.setEnabled(false); self.message = "Paused because AeroSpace started"; self.post() }
                    else if name == NSWorkspace.didActivateApplicationNotification {
                        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                           self.appList().contains(where: { $0.pid == app.processIdentifier }) {
                            self.activatingPID = app.processIdentifier; self.scheduleRefresh(pid: app.processIdentifier)
                        }
                    } else { self.scheduleRefresh() }
                }
            })
        }
        notices.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelVisualForDisplayChange(); self?.refresh(adopt: true) }
        })
        notices.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelVisualForDisplayChange(); self?.scheduleRefresh()
            }
        })
    }
    private func cancelVisualForDisplayChange() {
        if visualTicket != nil {
            visualTicket = nil; visualDeadline?.cancel(); visualDeadline = nil
            generation += 1; busy = false
        }
        visualScene?.cancel(); visualScene = nil
    }
    private func stopListeners() {
        pendingShortcut.cancel()
        refreshRequests = .init()
        activatingPID = nil
        visualTicket = nil; visualDeadline?.cancel(); visualDeadline = nil
        visualScene?.cancel(); visualScene = nil
        debounce?.cancel(); debounce = nil; resizeExit?.cancel(); resizeExit = nil; resizeMode = false
        hotkeys.removeAll(); modeKeys.removeAll()
        for token in notices { NSWorkspace.shared.notificationCenter.removeObserver(token); NotificationCenter.default.removeObserver(token) }
        notices.removeAll()
        let access = access; queue.async { access.stopWatching() }
    }
    private func scheduleRefresh(pid: pid_t? = nil) {
        guard enabled else { return }
        refreshRequests.include(pid.map { Set([$0]) })
        schedulePendingRefresh()
    }
    private func schedulePendingRefresh() {
        guard enabled, refreshRequests.pending else { return }; debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushRefresh() }; debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    func refresh(adopt: Bool = false) {
        refreshRequests.include(nil, adopt: adopt)
        debounce?.cancel(); debounce = nil
        flushRefresh()
    }
    private func flushRefresh() {
        guard !busy, let request = refreshRequests.take() else { return }
        refreshWindows(adopt: request.adopt, affectedPIDs: request.pids)
    }
    private func refreshWindows(adopt: Bool, affectedPIDs: Set<pid_t>?) {
        displays = ArrangeDisplay.current()
        guard !displays.isEmpty else { return }
        if !displays.contains(where: { $0.id == selectedDisplay }) { selectedDisplay = displays[0].id }
        active = active.filter { key, _ in displays.contains { $0.id == key } }
        for d in displays where active[d.id] == nil {
            let candidate = (1...9).first { targetDisplay($0) == d.id && !active.values.contains($0) } ?? (1...9).first { !active.values.contains($0) } ?? 1
            active[d.id] = candidate; displayRules[candidate] = d.id
        }
        guard AXIsProcessTrusted() else { message = "Accessibility is needed to read and arrange windows"; post(); return }
        let apps = appList(), front = NSWorkspace.shared.frontmostApplication?.processIdentifier, epoch = generation, watch = enabled, access = access
        let screens = displays.map(\.frame), activation = activatingPID; activatingPID = nil
        busy = true; post()
        queue.async { [weak self] in let result = access.scan(apps: apps, frontPID: front, affectedPIDs: affectedPIDs, displays: screens, activatingPID: activation); if watch { access.watch(apps: apps) }
            let hidden = access.hidden.count
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch else { return }
                self.busy = false; self.hiddenCount = hidden
                let oldIDs = Set(self.windows.map(\.id))
                // Keep the latest committed model for other apps; cached AX entries can
                // predate a transaction. A partial scan must never discard those windows.
                let retained = affectedPIDs.map { pids in self.windows.filter { !pids.contains($0.pid) } } ?? []
                self.windows = (retained + result.windows).map { value in
                    var w = value
                    let screen = self.displays.max { $0.frame.intersection(w.frame).width * $0.frame.intersection(w.frame).height < $1.frame.intersection(w.frame).width * $1.frame.intersection(w.frame).height }
                    let rule = self.settings.rules.first { $0.bundle == w.bundle }?.workspace
                    w.workspace = self.assignments[w.id] ?? (self.enabled ? rule : nil) ?? self.active[screen?.id ?? self.selectedDisplay] ?? 1
                    self.assignments[w.id] = w.workspace; w.floating = self.floating.contains(w.id)
                    return w
                }
                self.order = self.order.filter { id in self.windows.contains { $0.id == id } }
                self.order += self.windows.map(\.id).filter { !self.order.contains($0) }
                self.windows.sort { (self.order.firstIndex(of: $0.id) ?? 0) < (self.order.firstIndex(of: $1.id) ?? 0) }
                self.assignments = self.assignments.filter { id, _ in self.windows.contains { $0.id == id } }
                self.focused = ArrangeGeometry.resolvedFocus(observed: result.focused, previous: self.focused, windows: self.windows, active: Set(self.active.values))
                if self.enabled, let id = result.focused, let focus = self.windows.first(where: { $0.id == id }), !self.active.values.contains(focus.workspace) {
                    self.switchWorkspace(focus.workspace); return
                }
                self.message = self.lastFailure ?? (self.enabled ? "\(self.windows.count) windows · notifications only, no polling" : "Off · previews available; enable to apply layouts")
                self.post()
                if self.enabled, self.settings.automatic, adopt || oldIDs != Set(self.windows.map(\.id)) { self.arrangeAll() }
                else if self.enabled, adopt { self.commit(self.windows, active: self.active) }
                else { self.schedulePendingRefresh() }
            }
        }
    }
    private func plannedFrames(_ target: [ArrangeWindow], active next: [String: Int], forced: ArrangeLayout? = nil) -> [String: CGRect]? {
        var frames: [String: CGRect] = [:]
        for (displayID, group) in next {
            let members = target.filter { $0.workspace == group && !$0.floating }
            guard !members.isEmpty, let screen = displays.first(where: { $0.id == displayID }) else { continue }
            if forced == nil, let saved = manualLayouts[group]?.frames(for: members, in: screen.area) {
                frames.merge(saved, uniquingKeysWith: { _, new in new }); continue
            }
            let selected = forced ?? layouts[group] ?? .grid
            let rects = selected.frames(count: members.count, in: screen.area, ratio: ratios[group] ?? 0.6)
            guard ArrangeGeometry.fits(rects, windows: members, in: screen.area) else { message = "This layout is too small. Choose another preset or distribute windows."; post(); return nil }
            for (w, frame) in zip(members, rects) { frames[w.id] = frame }
        }
        return frames
    }
    private func commit(_ target: [ArrangeWindow], active next: [String: Int], frames override: [String: CGRect]? = nil, saveUndo: Bool = true, allowMotion: Bool = true, completion: (() -> Void)? = nil) {
        guard enabled, !busy else { return }
        guard let frames = override ?? plannedFrames(target, active: next) else { return }
        let before = (windows: windows, active: active, displays: displayRules, manualLayouts: manualLayouts)
        lastFailure = nil; busy = true; message = "Arranging windows…"; post()
        let epoch = generation, access = access
        let assistive = NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        let switching = next != active
        let animated = allowMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let sceneDisplay = display
        let direction: CGFloat = (next[sceneDisplay?.id ?? ""] ?? 1) >= (active[sceneDisplay?.id ?? ""] ?? 1) ? 1 : -1
        let workspaceFrames = frames.merging(Dictionary(uniqueKeysWithValues: target.filter { $0.floating && next.values.contains($0.workspace) }.map { ($0.id, $0.frame) }), uniquingKeysWith: { first, _ in first })
        let finish: (String?, Int) -> Void = { [weak self] error, hidden in
                guard let self, self.generation == epoch else { return }
                self.visualScene?.cancel(); self.visualScene = nil
                self.busy = false; self.hiddenCount = hidden
                if let error { self.lastFailure = error; self.message = error; Diag.log("arrange failed: \(error)"); self.post(); self.schedulePendingRefresh(); return }
                Diag.log("arrange applied: \(target.count) windows, \(frames.count) frame targets, active \(Array(next.values).sorted())")
                if saveUndo { self.undoStack.append(before); if self.undoStack.count > 16 { self.undoStack.removeFirst() }; self.canUndo = true }
                self.active = next; self.assignments = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0.workspace) })
                self.windows = target.map { value in var w = value; w.frame = frames[w.id] ?? w.frame; w.minimized = !next.values.contains(w.workspace); return w }
                self.message = "Arranged · Workspace \(self.workspace)"; self.post(); completion?()
                self.schedulePendingRefresh()
        }
        let run: (ArrangeVisualTransition?) -> Void = { [weak self] scene in
            guard let self, self.generation == epoch, self.enabled else { scene?.cancel(); return }
            self.visualScene = scene; scene?.present()
            let nativeMotion = animated && !switching && scene == nil
            self.queue.async {
                let error = access.apply(windows: target, active: Set(next.values), frames: frames, assistiveTechnologyActive: assistive, animated: nativeMotion)
                let hidden = access.hidden.count
                DispatchQueue.main.async { [weak self] in
                    if error == nil, let scene, switching, #available(macOS 14.0, *) {
                        guard let self, self.generation == epoch else { scene.cancel(); return }
                        let ticket = UUID(); self.visualTicket = ticket
                        let fallback = DispatchWorkItem { [weak self] in
                            guard let self, self.visualTicket == ticket else { return }
                            self.visualTicket = nil; self.visualDeadline = nil; scene.cancel(); finish(nil, hidden)
                        }
                        self.visualDeadline = fallback
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: fallback)
                        let members = target.filter { next.values.contains($0.workspace) && workspaceFrames[$0.id].map { sceneDisplay?.frame.intersects($0) == true } == true }
                        Task { [weak self] in
                            let ready = await scene.prepareWorkspace(windows: members, frames: workspaceFrames, direction: direction)
                            guard let self, self.generation == epoch, self.visualTicket == ticket else { scene.cancel(); return }
                            self.visualTicket = nil; self.visualDeadline?.cancel(); self.visualDeadline = nil
                            if ready { scene.animateWorkspace { finish(nil, hidden) } }
                            else { scene.cancel(); finish(nil, hidden) }
                        }
                    }
                    else if error == nil, let scene { scene.animate(to: frames) { finish(nil, hidden) } }
                    else { scene?.cancel(); finish(error, hidden) }
                }
            }
        }
        if #available(macOS 14.0, *), settings.visualTransitions == true, animated, !assistive, hasVisualAccess,
           let display = sceneDisplay, switching || !frames.isEmpty {
            let members = switching ? windows.filter { active.values.contains($0.workspace) && !$0.minimized && display.frame.intersects($0.frame) }
                                   : target.filter { next.values.contains($0.workspace) && frames[$0.id] != nil }
            let captureFrames = switching ? Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.frame) }) : frames
            let ticket = UUID(); visualTicket = ticket
            let fallback = DispatchWorkItem { [weak self] in
                guard let self, self.visualTicket == ticket else { return }
                Diag.log("arrange visual capture timed out; native fallback")
                self.visualTicket = nil; self.visualDeadline = nil; run(nil)
            }
            visualDeadline = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: fallback)
            Task { [weak self] in
                let scene = await ArrangeVisualTransition.capture(windows: members, frames: captureFrames, display: display, allowEmpty: switching)
                guard let self, self.generation == epoch, self.visualTicket == ticket else { scene?.cancel(); return }
                self.visualTicket = nil; self.visualDeadline?.cancel(); self.visualDeadline = nil
                run(scene)
            }
        } else { run(nil) }
    }
    func apply(_ selected: ArrangeLayout) {
        layouts[workspace] = selected
        guard let screen = display else { return }
        let members = currentWindows, rects = selected.frames(count: members.count, in: screen.area, ratio: ratios[workspace] ?? 0.6)
        guard ArrangeGeometry.fits(rects, windows: members, in: screen.area) else { message = "Not enough space for this layout. Distribute windows instead."; post(); return }
        let group = workspace
        commit(windows, active: active, frames: Dictionary(uniqueKeysWithValues: zip(members.map(\.id), rects))) { [weak self] in self?.manualLayouts[group] = nil }
    }
    private func arrangeAll() { commit(windows, active: active) }
    func undoLast() {
        guard let undo = undoStack.last, !busy else { return }
        guard Set(undo.windows.map(\.id)) == Set(windows.map(\.id)) else { self.undoStack.removeAll(); canUndo = false; message = "The window list changed. Choose a fresh layout."; post(); return }
        commit(undo.windows.filter { old in windows.contains { $0.id == old.id } }, active: undo.active,
               frames: Dictionary(uniqueKeysWithValues: undo.windows.map { ($0.id, $0.frame) }), saveUndo: false) { [weak self] in
            self?.displayRules = undo.displays
            self?.manualLayouts = undo.manualLayouts
            self?.order = undo.windows.map(\.id)
            self?.floating = Set(undo.windows.filter(\.floating).map(\.id))
            if self?.undoStack.isEmpty == false { self?.undoStack.removeLast() }; self?.canUndo = self?.undoStack.isEmpty == false; self?.post()
        }
    }
    func switchWorkspace(_ group: Int, focusing id: String? = nil) {
        guard (1...9).contains(group), !busy else { return }
        let destination = targetDisplay(group)
        previous = workspace; selectedDisplay = destination
        var next = active; next[destination] = group
        commit(windows, active: next) { [weak self] in
            guard let self else { return }
            let target = self.windows.first { $0.workspace == group && $0.id == id } ?? self.windows.first { $0.workspace == group }
            if let target { self.focus(target.id) }
            else { self.focused = nil; self.post() }
        }
    }
    func moveWindow(_ id: String, to group: Int) {
        guard (1...9).contains(group) else { return }
        let target = windows.map { value in var w = value; if w.id == id { w.workspace = group }; return w }
        commit(target, active: active) { [weak self] in
            guard let self, self.focused == id else { return }
            if let window = self.currentWindows.first { self.focus(window.id) } else { self.focused = nil; self.post() }
        }
    }
    func distribute() {
        guard !busy, currentWindows.count > 1 else { return }
        let members = currentWindows
        let counts = ArrangeGeometry.distribution(count: members.count, capacity: settings.capacity)
        let candidates = (1...9).filter { group in group != workspace && !active.values.contains(group) && !windows.contains { $0.workspace == group } }
        let groups = [workspace] + candidates.sorted { (targetDisplay($0) == selectedDisplay ? 0 : 1, $0) < (targetDisplay($1) == selectedDisplay ? 0 : 1, $1) }
        guard counts.count <= groups.count else { message = "Not enough empty workspaces. Move existing windows or raise the per-workspace limit."; post(); return }
        var target = windows, start = 0
        var mapping = displayRules
        for (group, count) in zip(groups, counts) {
            let ids = Set(members[start..<(start + count)].map(\.id)); start += count
            for index in target.indices where ids.contains(target[index].id) { target[index].workspace = group }
            mapping[group] = selectedDisplay
        }
        commit(target, active: active) { [weak self] in
            self?.displayRules = mapping
            for group in groups.prefix(counts.count) { self?.layouts[group] = .grid }
        }
    }
    func assignDisplay(_ group: Int, to display: String) {
        guard !busy, displays.contains(where: { $0.id == display }) else { return }
        if active.values.contains(group) {
            var next = active.filter { $0.value != group }; next[display] = group
            commit(windows, active: next) { [weak self] in self?.displayRules[group] = display; self?.post() }
        } else { displayRules[group] = display; post() }
    }
    func displayForWorkspace(_ group: Int) -> String { targetDisplay(group) }
    func pauseShortcuts(_ yes: Bool) {
        if yes {
            pendingShortcut.cancel(); hotkeys.removeAll(); modeKeys.removeAll()
            resizeMode = false; resizeExit?.cancel(); resizeExit = nil
        }
        else if enabled, !registerShortcuts() { settings.enabled = false; settings.save(); stopListeners(); message = "A shortcut became unavailable; arrangements paused"; post() }
    }
    func chooseApp(_ url: URL, replacing index: Int?) {
        guard url.pathExtension == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { message = "Choose a macOS application"; post(); return }
        let old = settings
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
        if let index, settings.rules.indices.contains(index) { settings.rules[index].name = name; settings.rules[index].bundle = id; settings.rules[index].path = url.path }
        else { settings.rules.append(.init(name: name, bundle: id, path: url.path, workspace: nil, shortcut: nil)) }
        if enabled && !registerShortcuts() { settings = old; _ = registerShortcuts(); message = "Shortcut conflict; previous app retained" }
        settings.save(); post()
    }
    func setRule(_ index: Int, workspace: Int?) { guard settings.rules.indices.contains(index) else { return }; settings.rules[index].workspace = workspace; settings.save(); post() }
    func setRuleShortcut(_ index: Int, shortcut: HotKeyShortcut?) -> Bool {
        guard settings.rules.indices.contains(index) else { return false }; let old = settings.rules[index].shortcut
        settings.rules[index].shortcut = shortcut
        if enabled && !registerShortcuts() { settings.rules[index].shortcut = old; _ = registerShortcuts(); return false }
        settings.save(); post(); return true
    }
    func setShortcut(_ id: String, _ shortcut: HotKeyShortcut?) -> Bool {
        let old = settings
        settings.shortcuts[id] = shortcut
        if shortcut == nil { settings.disabled.insert(id) } else { settings.disabled.remove(id) }
        if enabled && !registerShortcuts() { settings = old; _ = registerShortcuts(); return false }
        settings.save(); post(); return true
    }
    func binding(_ id: String, fallback: HotKeyShortcut) -> HotKeyShortcut? { settings.disabled.contains(id) ? nil : settings.shortcuts[id] ?? fallback }
    private func registerShortcuts() -> Bool {
        hotkeys.removeAll(); modeKeys.removeAll(); resizeMode = false
        var registered: [GlobalHotKey] = []
        func add(_ shortcut: HotKeyShortcut?, _ action: @escaping () -> Void) -> Bool {
            guard let shortcut else { return true }
            guard let key = GlobalHotKey(shortcut, handler: action) else { return false }
            registered.append(key); return true
        }
        for (id, _, fallback) in ArrangeSettings.bindings {
            guard add(binding(id, fallback: fallback), { [weak self] in self?.perform(id) }) else { return false }
        }
        for i in settings.rules.indices {
            guard add(settings.rules[i].shortcut, { [weak self] in self?.launch(i) }) else { return false }
        }
        hotkeys = registered; Diag.log("arrange shortcuts registered: \(hotkeys.count)"); return true
    }
    private func followFocusedDisplay() {
        if let focused, let window = windows.first(where: { $0.id == focused }), let screen = active.first(where: { $0.value == window.workspace })?.key { selectedDisplay = screen }
    }
    func perform(_ id: String) {
        Diag.log("arrange shortcut: \(id), busy \(busy)")
        guard enabled else { return }
        if busy { pendingShortcut.replace { [weak self] in self?.perform(id) }; return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let epoch = generation, access = access
        queue.async { [weak self] in
            let observed = access.focusedWindow(pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.generation == epoch else { return }
                if self.busy { self.pendingShortcut.replace { [weak self] in self?.perform(id) }; return }
                self.focused = ArrangeGeometry.resolvedFocus(observed: observed, previous: self.focused, windows: self.windows, active: Set(self.active.values))
                self.performFocused(id)
            }
        }
    }
    private func performFocused(_ id: String) {
        followFocusedDisplay()
        if id.hasPrefix("workspace."), let group = Int(id.dropFirst(10)) { switchWorkspace(group); return }
        if id.hasPrefix("send."), let group = Int(id.dropFirst(5)), let focused { moveWindow(focused, to: group); return }
        if id.hasPrefix("resize.") {
            let direction = String(id.dropFirst(7))
            resizeDivider(direction); return
        }
        if id.hasPrefix("focus.") || id.hasPrefix("move.") {
            guard let focused, let source = windows.first(where: { $0.id == focused }) else { return }
            let dir = id.split(separator: ".").last ?? ""
            let dx: CGFloat = dir == "left" ? -1 : dir == "right" ? 1 : 0
            let dy: CGFloat = dir == "up" ? -1 : dir == "down" ? 1 : 0
            let members = windows.filter { $0.workspace == source.workspace && !$0.floating }
            guard let next = ArrangeGeometry.neighbor(focused, windows: members, dx: dx, dy: dy) else {
                Diag.log("arrange direction unavailable: \(members.count) candidates"); return
            }
            Diag.log("arrange direction: \(focused) -> \(next)")
            if id.hasPrefix("move."), let a = windows.firstIndex(where: { $0.id == focused }), let b = windows.firstIndex(where: { $0.id == next }) {
                var target = windows; target.swapAt(a, b); commit(target, active: active) { [weak self] in self?.order = target.map(\.id) }
            } else { focus(next) }; return
        }
        switch id {
        case "columns": apply(.columns)
        case "rows": apply(.rows)
        case "layout": let choices: [ArrangeLayout] = [.columns,.rows,.grid]; apply(choices[((choices.firstIndex(of: layout) ?? -1) + 1) % choices.count])
        case "back": if let previous { switchWorkspace(previous) }
        case "rotate": rotate()
        case "resize": enterResizeMode()
        case "monitor": if let index = displays.firstIndex(where: { $0.id == selectedDisplay }), displays.count > 1 { assignDisplay(workspace, to: displays[(index + 1) % displays.count].id) }
        case "float": if let focused { manualLayouts[workspace] = nil; if !floating.insert(focused).inserted { floating.remove(focused) }; windows = windows.map { var w = $0; w.floating = floating.contains(w.id); return w }; arrangeAll() }
        case "fill":
            guard let focused, let index = windows.firstIndex(where: { $0.id == focused }), let display else { return }
            let frame = filled.removeValue(forKey: focused) ?? display.area
            if frame == display.area { filled[focused] = windows[index].frame }
            commit(windows, active: active, frames: [focused: frame])
        default: break
        }
    }
    func rotate() {
        let ids = currentWindows.map(\.id); guard ids.count > 1 else { return }
        var rotated = ids; rotated.append(rotated.removeFirst())
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let target = rotated.compactMap { byID[$0] } + windows.filter { !ids.contains($0.id) }
        commit(target, active: active) { [weak self] in self?.order = target.map(\.id) }
    }
    func focus(_ id: String) {
        guard let target = windows.first(where: { $0.id == id }),
              let app = NSRunningApplication(processIdentifier: target.pid) else { return }
        let ticket = UUID(); focusTicket = ticket
        let epoch = generation, access = access
        let selectWindow = { [weak self] in
            guard let self, self.enabled, self.generation == epoch, self.focusTicket == ticket,
                  self.windows.contains(where: { $0.id == id }) else { return }
            self.queue.async { [weak self] in
                let pid = access.focus(id)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == epoch, self.focusTicket == ticket else { return }
                    if let pid {
                        self.focused = id; self.followFocusedDisplay()
                        Diag.log("arrange focus activation: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
                    } else { self.message = "The app refused keyboard focus" }
                    self.post()
                }
            }
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { selectWindow() }
        else if let url = app.bundleURL {
            // Use the same LaunchServices activation as the app opener. A successful
            // activate() request alone does not mean the app has become foreground.
            let config = NSWorkspace.OpenConfiguration(); config.activates = true; config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == epoch, self.focusTicket == ticket else { return }
                    if let error { self.message = error.localizedDescription; self.post() }
                    else { selectWindow() }
                }
            }
        } else { _ = app.activate(options: [.activateIgnoringOtherApps]); selectWindow() }
    }
    func launch(_ index: Int) {
        guard enabled, settings.rules.indices.contains(index) else { return }
        if busy { pendingShortcut.replace { [weak self] in self?.launch(index) }; return }
        followFocusedDisplay()
        let rule = settings.rules[index], url = URL(fileURLWithPath: settings.rules[index].path)
        let destination = ArrangeGeometry.appLaunchTarget(rule, windows: windows, focused: focused, workspace: workspace, active: Set(active.values))
        if let window = destination.window {
            // A launch rule is a default for new windows, never a reason to pull an
            // existing window out of the workspace the user explicitly chose.
            if active.values.contains(window.workspace) { focus(window.id) }
            else { switchWorkspace(window.workspace, focusing: window.id) }
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { message = "\(rule.name) isn’t installed at \(rule.path)"; post(); return }
        let open = { [weak self] in
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in DispatchQueue.main.async {
                if let error { self?.message = error.localizedDescription; self?.post() } else { self?.scheduleRefresh() }
            } }
        }
        if let group = destination.workspace {
            var next = active; let destination = targetDisplay(group); next[destination] = group; selectedDisplay = destination
            commit(windows, active: next, completion: open)
        } else { open() }
    }
    private func resizeDivider(_ direction: String) {
        guard let focused, let screen = display,
              let source = windows.first(where: { $0.id == focused && !$0.floating }) else { return }
        let horizontal = direction == "left" || direction == "right"
        let delta: CGFloat = direction == "left" || direction == "up" ? -50 : 50
        let members = windows.filter { $0.workspace == source.workspace && !$0.floating && !$0.minimized }
        guard let frames = ArrangeGeometry.resizedDivider(focused, windows: members, in: screen.area, horizontal: horizontal, delta: delta) else {
            message = "No shared edge on this axis, or a window reached its minimum size"; post(); return
        }
        let group = source.workspace
        // Keyboard steps use the real windows immediately, without capture or a
        // delayed proxy animation. Layout thumbnails retain their existing motion.
        commit(windows, active: active, frames: frames, allowMotion: false) { [weak self] in
            self?.manualLayouts[group] = ArrangeManualLayout(area: screen.area, ids: members.map(\.id))
        }
    }
    private func enterResizeMode() {
        modeKeys.removeAll(); resizeMode = true
        for (code, vertical, delta) in [(UInt32(4), false, CGFloat(-50)), (37, false, 50), (38, true, 50), (40, true, -50)] {
            if let key = GlobalHotKey(.init(keyCode: code, modifiers: 0, key: ""), handler: { [weak self] in
                self?.resizeWindow(vertical: vertical, delta: delta)
            }) { modeKeys.append(key) }
        }
        for code: UInt32 in [36, 53] { if let key = GlobalHotKey(.init(keyCode: code, modifiers: 0, key: ""), handler: { [weak self] in self?.leaveResizeMode() }) { modeKeys.append(key) } }
        guard modeKeys.count == 6 else { leaveResizeMode(); message = "Resize keys are unavailable; no keys were captured"; post(); return }
        Diag.log("arrange resize mode registered: \(modeKeys.count) keys")
        message = "Resize mode · H/L width · J/K height · Return or Esc finishes"; post()
        resizeExit?.cancel(); let work = DispatchWorkItem { [weak self] in self?.leaveResizeMode() }; resizeExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    private func resizeWindow(vertical: Bool, delta: CGFloat) {
        Diag.log("arrange resize step: vertical \(vertical), delta \(delta), busy \(busy)")
        guard enabled else { return }
        if busy { pendingShortcut.replace { [weak self] in self?.resizeWindow(vertical: vertical, delta: delta) }; return }
        guard let display, let focused,
              let master = windows.first(where: { $0.id == focused }) else { return }
        let axis = vertical ? display.area.height : display.area.width
        let length = vertical ? master.frame.height : master.frame.width
        ratios[workspace] = min(0.8, max(0.2, (length + delta) / max(1, axis - 8)))
        let target = [master] + windows.filter { $0.id != focused }
        layouts[workspace] = vertical ? .mainTop : .mainLeft
        guard let frames = plannedFrames(target, active: active, forced: vertical ? .mainTop : .mainLeft) else { return }
        let group = workspace
        commit(target, active: active, frames: frames) { [weak self] in self?.order = target.map(\.id); self?.manualLayouts[group] = nil }
    }
    private func leaveResizeMode() { modeKeys.removeAll(); resizeMode = false; resizeExit?.cancel(); resizeExit = nil; message = "Resize mode finished"; post() }
    func prepareForTermination(_ completion: @escaping () -> Void) {
        motionPreview?.cancel(); motionPreview = nil
        stopListeners(); generation += 1
        let access = access
        queue.async { _ = access.restoreHidden(); DispatchQueue.main.async(execute: completion) }
    }
}
