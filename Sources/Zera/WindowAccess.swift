import AppKit
import ApplicationServices

struct ArrangeApplication { var pid: pid_t; var bundle: String; var name: String }
struct ArrangeRecovery: Codable {
    var pid: pid_t; var bundle: String; var title: String; var frame: CGRect
    var parkedFrame: CGRect? = nil // nil preserves recovery of older minimized windows.
}

/// A failed batch must not turn one unresponsive app into six consecutive timeouts.
enum ArrangeAXRead {
    static func values(_ keys: [String], batch: () -> (AXError, [AnyObject]?), single: (String) -> AnyObject?) -> [AnyObject?] {
        let (error, values) = batch()
        if error == .success, let values, values.count == keys.count {
            return values.map { value in
                if value is NSNull { return nil }
                if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
                return value
            }
        }
        guard error == .notImplemented || error == .illegalArgument || error == .attributeUnsupported || error == .success else {
            return Array(repeating: nil, count: keys.count)
        }
        return keys.map(single)
    }
    static func frame(_ position: AnyObject?, _ size: AnyObject?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

/// One coalesced request, including events received while an arrangement is busy.
struct ArrangeRefreshRequests {
    private var full = false
    private var pids: Set<pid_t> = []
    private var adopt = false
    var pending: Bool { full || !pids.isEmpty }
    mutating func include(_ affectedPIDs: Set<pid_t>?, adopt: Bool = false) {
        self.adopt = self.adopt || adopt
        if let affectedPIDs { if !full { pids.formUnion(affectedPIDs) } }
        else { full = true; pids.removeAll() }
    }
    mutating func take() -> (pids: Set<pid_t>?, adopt: Bool)? {
        guard pending else { return nil }
        let request: (Set<pid_t>?, Bool) = (full ? nil : pids, adopt)
        self = .init()
        return request
    }
}

/// Used exclusively on WindowArrangementService.queue. No AX round trip runs on the UI thread.
final class ArrangeWindowAccess: @unchecked Sendable {
    // Mutable AX state is confined to the service serial queue. onEvent is set once before use.
    struct Entry { var element: AXUIElement; var window: ArrangeWindow; var serverID: CGWindowID? }
    private var entries: [String: Entry] = [:]
    private var serial = 0
    private(set) var hidden: Set<String> = []
    private var journal: [String: ArrangeRecovery] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var observedWindows: Set<String> = []
    private var screenFrames: [CGRect] = []
    private let journalURL: URL
    var onEvent: ((pid_t?, Bool) -> Void)?
    init(journalURL: URL) { self.journalURL = journalURL }
    var hasRecovery: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    private func flag(_ element: AXUIElement, _ key: String) -> Bool { (value(element, key) as? NSNumber)?.boolValue ?? false }
    private func values(_ element: AXUIElement, _ keys: [String]) -> [AnyObject?] {
        ArrangeAXRead.values(keys, batch: {
            var result: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result)
            return (error, result as? [AnyObject])
        }, single: { self.value(element, $0) })
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
        let attributes = values(element, [kAXPositionAttribute, kAXSizeAttribute])
        return ArrangeAXRead.frame(attributes[0], attributes[1])
    }
    private func settable(_ element: AXUIElement, _ key: String) -> Bool {
        var yes = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, key as CFString, &yes) == .success && yes.boolValue
    }
    func scan(apps: [ArrangeApplication], frontPID: pid_t?, recovery: Bool = false, affectedPIDs: Set<pid_t>? = nil, displays: [CGRect] = [], activatingPID: pid_t? = nil) -> (windows: [ArrangeWindow], focused: String?, knownIDs: Set<String>) {
        if !displays.isEmpty { screenFrames = displays }
        let began = ProcessInfo.processInfo.systemUptime
        var visible: [pid_t: [(id: CGWindowID, frame: CGRect)]] = [:]
        for item in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
            guard (item[kCGWindowLayer as String] as? Int) == 0, let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            guard let number = item[kCGWindowNumber as String] as? NSNumber else { continue }
            visible[pid, default: []].append((number.uint32Value, frame))
        }
        var result: [ArrangeWindow] = [], focused: String?, retained: Set<String> = [], known: Set<String> = []
        for app in apps where affectedPIDs?.contains(app.pid) ?? true {
            let root = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(root, 0.15)
            guard let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] else {
                continue
            }
            let focusedElement = app.pid == frontPID ? value(root, kAXFocusedWindowAttribute) : nil
            for element in windows.prefix(64) {
                let existing = entries.first { $0.value.window.pid == app.pid && CFEqual($0.value.element, element) }?.key
                if let existing { known.insert(existing) }
                // Messaging timeouts apply to this exact object, not its application root.
                AXUIElementSetMessagingTimeout(element, 0.15)
                let attributes = values(element, [kAXSubroleAttribute, "AXFullScreen", kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, kAXTitleAttribute])
                guard (attributes[0] as? String) == kAXStandardWindowSubrole,
                      (attributes[1] as? NSNumber)?.boolValue != true, let frame = ArrangeAXRead.frame(attributes[2], attributes[3]),
                      settable(element, kAXSizeAttribute), settable(element, kAXPositionAttribute), settable(element, kAXMinimizedAttribute) else { continue }
                let minimized = (attributes[4] as? NSNumber)?.boolValue ?? false
                let owned = existing.map { hidden.contains($0) } ?? false
                let matches = (visible[app.pid] ?? []).filter { ArrangeGeometry.near($0.frame, frame, tolerance: 6) }
                // Bind an unambiguous public WindowServer ID when first discovered.
                // Bounds metadata may trail an AX write; retain identity instead of
                // dropping and re-adopting a successfully resized window as a new one.
                let serverID = existing.flatMap { entries[$0]?.serverID } ?? (matches.count == 1 ? matches.first?.id : nil)
                let isOnScreen = serverID.map { id in visible[app.pid]?.contains { $0.id == id } ?? false } ?? !matches.isEmpty
                // Do not adopt user-minimized windows or documents on another native Space.
                guard owned || (recovery && (minimized || ArrangeParking.accepts(frame, displays: screenFrames))) || (!minimized && isOnScreen) else { continue }
                serial += existing == nil ? 1 : 0
                let id = existing ?? "\(app.pid):\(serial)"
                let title = (attributes[5] as? String) ?? app.name
                let previous = existing.flatMap { entries[$0]?.window }
                let window = ArrangeWindow(id: id, app: app.name, bundle: app.bundle, title: title, pid: app.pid,
                    frame: owned ? journal[id]?.frame ?? frame : frame, workspace: previous?.workspace ?? 1, minimized: owned || minimized, minimum: previous?.minimum ?? CGSize(width: 240, height: 160))
                entries[id] = .init(element: element, window: window, serverID: serverID); result.append(window); retained.insert(id)
                if let focus = focusedElement, CFEqual(focus, element),
                   !owned || activatingPID == app.pid || (journal[id]?.parkedFrame != nil && !ArrangeParking.accepts(frame, displays: screenFrames)) { focused = id }
            }
        }
        var journalChanged = false
        for id in Set(entries.keys).subtracting(retained.union(known)) {
            if let affectedPIDs, let entry = entries[id], !affectedPIDs.contains(entry.window.pid) { continue }
            if let entry = entries[id], apps.contains(where: { $0.pid == entry.window.pid }) {
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(entry.element, kAXPositionAttribute as CFString, &value)
                // A sleeping/unresponsive app can briefly report no windows. Keep ownership
                // until it explicitly invalidates the element or terminates.
                if error != .invalidUIElement {
                    if hidden.contains(id) {
                        var window = entry.window; window.minimized = true; result.append(window)
                    }
                    // Minimized, hidden, full-screen and other-Space windows keep their
                    // identity metadata, but never become frame-write targets here.
                    continue
                }
            }
            entries[id] = nil; hidden.remove(id); observedWindows.remove(id)
            if journal.removeValue(forKey: id) != nil { journalChanged = true }
        }
        if journalChanged { saveJournal() }
        Diag.log("arrange scan: \(affectedPIDs == nil ? "full" : "scoped"), \(apps.filter { affectedPIDs?.contains($0.pid) ?? true }.count) apps, \(result.count) windows, \(Int((ProcessInfo.processInfo.systemUptime - began) * 1000)) ms")
        return (result, focused, Set(entries.keys))
    }
    func watch(apps: [ArrangeApplication]) {
        let pids = Set(apps.map(\.pid))
        for pid in Set(observers.keys).subtracting(pids) { removeObserver(pid) }
        for app in apps where observers[app.pid] == nil {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, element, notification, context in
                guard let context else { return }
                var pid: pid_t = 0
                let known = AXUIElementGetPid(element, &pid) == .success && pid > 0
                Unmanaged<ArrangeWindowAccess>.fromOpaque(context).takeUnretainedValue().onEvent?(known ? pid : nil, notification as String == kAXFocusedWindowChangedNotification)
            }
            guard AXObserverCreate(app.pid, callback, &observer) == .success, let observer else { continue }
            let root = AXUIElementCreateApplication(app.pid); AXUIElementSetMessagingTimeout(root, 0.15)
            let context = Unmanaged.passUnretained(self).toOpaque()
            for name in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXFocusedWindowChangedNotification,
                         kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                _ = AXObserverAddNotification(observer, root, name as CFString, context)
            }
            observers[app.pid] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        for entry in entries.values where !observedWindows.contains(entry.window.id) {
            guard let observer = observers[entry.window.pid] else { continue }
            for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXMovedNotification, kAXResizedNotification] {
                _ = AXObserverAddNotification(observer, entry.element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            observedWindows.insert(entry.window.id)
        }
    }
    private func removeObserver(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
    }
    func stopWatching() { for pid in Array(observers.keys) { removeObserver(pid) }; observedWindows.removeAll() }
    deinit { stopWatching() }

    @discardableResult private func saveJournal() -> Bool {
        guard let data = try? JSONEncoder().encode(Array(journal.values)) else { return false }
        try? FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: journalURL, options: .atomic); return true } catch { return false }
    }
    private func writeFrame(_ id: String, _ frame: CGRect) -> CGRect? {
        guard let e = entries[id]?.element else { return nil }
        if let current = rect(e), ArrangeGeometry.near(current, frame) { return current }
        var point = frame.origin, size = frame.size
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return nil }
        let sizeResult = AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, s)
        let positionResult = AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, p)
        guard sizeResult == .success, positionResult == .success else { Diag.log("arrange write refused size \(sizeResult.rawValue) position \(positionResult.rawValue)"); return nil }
        var actual = rect(e)
        if let actual, ArrangeGeometry.near(actual, frame) { return actual }
        // Some apps move when resized or commit asynchronously. Retain the compatibility
        // retry only when the first pair has not already reached the requested geometry.
        _ = AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, s)
        _ = AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, p)
        // AX setters can acknowledge before the target app commits its frame. Wait only
        // during this command, off-main, rather than treating a stale read as a size limit.
        let deadline = Date().addingTimeInterval(0.6)
        actual = rect(e)
        while actual.map({ !ArrangeGeometry.near($0, frame) }) ?? true, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
            actual = rect(e)
        }
        if let actual, !ArrangeGeometry.near(actual, frame) { Diag.log("arrange frame mismatch target \(frame) actual \(actual)") }
        return actual
    }
    private func minimize(_ id: String, _ yes: Bool, restoreFrame: CGRect? = nil) -> Bool {
        guard let entry = entries[id] else { return false }
        if yes {
            if hidden.contains(id) { return true }
            guard !flag(entry.element, kAXMinimizedAttribute), let original = rect(entry.element) else { return false }
            let w = entry.window
            for target in ArrangeParking.candidates(size: original.size, displays: screenFrames) {
                journal[id] = .init(pid: w.pid, bundle: w.bundle, title: w.title, frame: original, parkedFrame: target)
                guard saveJournal() else { journal[id] = nil; return false }
                var point = target.origin
                guard let p = AXValueCreate(.cgPoint, &point) else { return false }
                let result = AXUIElementSetAttributeValue(entry.element, kAXPositionAttribute as CFString, p)
                if result == .success, let actual = rect(entry.element),
                   ArrangeParking.accepts(actual, displays: screenFrames),
                   abs(actual.width - original.width) <= 2, abs(actual.height - original.height) <= 2 {
                    journal[id]?.parkedFrame = actual; hidden.insert(id); saveJournal(); return true
                }
                // Keep recovery ownership if the target app also refuses rollback.
                guard let restored = writeFrame(id, original), ArrangeGeometry.near(restored, original) else { hidden.insert(id); return false }
            }
            journal[id] = nil; saveJournal(); return false
        }
        guard let saved = journal[id] else { return !flag(entry.element, kAXMinimizedAttribute) }
        if saved.parkedFrame != nil {
            let destination = restoreFrame ?? saved.frame
            guard let actual = writeFrame(id, destination), ArrangeGeometry.near(actual, destination) else { return false }
        }
        // Only older recovery records use native minimization. Normal workspace switches
        // never send windows through the Dock or wait for its animation.
        if flag(entry.element, kAXMinimizedAttribute) {
            guard AXUIElementSetAttributeValue(entry.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else { return false }
            let deadline = Date().addingTimeInterval(0.8)
            while flag(entry.element, kAXMinimizedAttribute), Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
            guard !flag(entry.element, kAXMinimizedAttribute) else { return false }
        }
        hidden.remove(id); journal[id] = nil; saveJournal()
        return true
    }
    /// A short-lived batch, not one animation/timer per app. Use elapsed time so slow
    /// AX clients skip missed samples rather than accumulating delayed frames.
    private func animateFrames(_ targets: [String: CGRect], isCurrent: () -> Bool) -> String? {
        guard !targets.isEmpty, targets.count <= 12 else { return nil }
        var starts: [String: CGRect] = [:]
        for id in targets.keys {
            guard let element = entries[id]?.element, let start = rect(element) else { return "A window closed before moving." }
            if !ArrangeGeometry.near(start, targets[id]!) { starts[id] = start }
        }
        guard !starts.isEmpty else { return nil }
        let ids = starts.keys.sorted(), began = ProcessInfo.processInfo.systemUptime
        var previous = starts, ticks = 0
        animation: while true {
            guard isCurrent() else { return "Desktop changed during window motion" }
            let tick = ProcessInfo.processInfo.systemUptime
            let progress = CGFloat((tick - began) / ArrangeMotion.duration)
            if progress >= 1 { break }
            for id in ids {
                guard isCurrent() else { return "Desktop changed during window motion" }
                if ProcessInfo.processInfo.systemUptime - began >= ArrangeMotion.duration { break animation }
                guard let element = entries[id]?.element else { return "A window closed while moving." }
                let frame = ArrangeMotion.frame(from: starts[id]!, to: targets[id]!, progress: progress)
                var size = CGSize(width: frame.width.rounded(), height: frame.height.rounded())
                var point = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded())
                if size != previous[id]!.size {
                    guard let value = AXValueCreate(.cgSize, &size), AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success else { return "A window refused resizing while moving." }
                }
                if point != previous[id]!.origin {
                    guard let value = AXValueCreate(.cgPoint, &point), AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success else { return "A window refused moving." }
                }
                previous[id] = CGRect(origin: point, size: size)
            }
            ticks += 1
            let cost = ProcessInfo.processInfo.systemUptime - tick
            let pause = min(1 / 60.0 - cost, began + ArrangeMotion.duration - ProcessInfo.processInfo.systemUptime)
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
        Diag.log("arrange motion: \(ids.count) windows, \(ticks) shared ticks, \(Int((ProcessInfo.processInfo.systemUptime - began) * 1000)) ms")
        return nil
    }
    /// A refused or clamped layout restores every touched window, including minimize state.
    func apply(windows: [ArrangeWindow], active: Set<Int>, frames: [String: CGRect], assistiveTechnologyActive: Bool, animated: Bool,
               isCurrent: @escaping () -> Bool = { true }) -> String? {
        let valid = { isCurrent() && AXIsProcessTrusted() }
        guard valid() else { return "Accessibility or desktop changed; refresh before arranging" }
        // Revalidate live geometry immediately before a transaction. Cached windows may
        // have moved to another Space, entered full screen, or been minimized since scan.
        let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where !hidden.contains(window.id) {
            guard let entry = entries[window.id], !flag(entry.element, "AXFullScreen"),
                  !flag(entry.element, kAXMinimizedAttribute), let current = rect(entry.element),
                  visible.contains(where: { info in
                      guard (info[kCGWindowOwnerPID as String] as? pid_t) == window.pid,
                            (info[kCGWindowLayer as String] as? Int) == 0,
                            let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                            let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
                      if let serverID = entry.serverID { return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == serverID }
                      return ArrangeGeometry.near(frame, current, tolerance: 6)
                  }) else { return "A window left this desktop or changed state. Refresh and try again." }
        }
        let animation: (([String: CGRect]) -> String?)? = animated && !assistiveTechnologyActive ? { self.animateFrames($0, isCurrent: valid) } : nil
        return ArrangeTransaction.apply(windows: windows, active: active, frames: frames, read: { id in
            guard let e = self.entries[id]?.element else { return nil }
            let attributes = self.values(e, [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute])
            guard let frame = ArrangeAXRead.frame(attributes[0], attributes[1]) else { return nil }
            return (self.hidden.contains(id) ? self.journal[id]?.frame ?? frame : frame,
                    self.hidden.contains(id) || (attributes[2] as? NSNumber)?.boolValue == true)
        }, setFrame: { self.writeFrame($0, $1)
        }, setMinimized: { self.minimize($0, $1, restoreFrame: frames[$0]) }, animate: animation, isCurrent: valid)
    }
    func restoreHidden() -> Int {
        var remaining = 0
        for id in Array(hidden) { if !minimize(id, false) { remaining += 1 } }
        stopWatching()
        return remaining
    }
    func recover(apps: [ArrangeApplication], displays: [CGRect] = []) -> Int {
        guard let data = try? Data(contentsOf: journalURL), let saved = try? JSONDecoder().decode([ArrangeRecovery].self, from: data), !saved.isEmpty else { return 0 }
        let relevant = apps.filter { app in saved.contains { $0.pid == app.pid && $0.bundle == app.bundle } }
        let scan = scan(apps: relevant, frontPID: nil, recovery: true, displays: displays)
        var unresolved: [ArrangeRecovery] = []
        for record in saved {
            guard apps.contains(where: { $0.pid == record.pid && $0.bundle == record.bundle }) else { continue }
            let matches = scan.windows.filter {
                guard $0.pid == record.pid, $0.bundle == record.bundle, $0.title == record.title else { return false }
                if record.parkedFrame != nil {
                    return ArrangeGeometry.near($0.frame, record.frame) || (ArrangeParking.accepts($0.frame, displays: screenFrames) && abs($0.frame.width - record.frame.width) <= 2 && abs($0.frame.height - record.frame.height) <= 2)
                }
                return ArrangeGeometry.near($0.frame, record.frame)
            }
            guard matches.count == 1, let window = matches.first, entries[window.id] != nil else { unresolved.append(record); continue }
            journal[window.id] = record; hidden.insert(window.id)
            if !minimize(window.id, false) { unresolved.append(record) }
        }
        if let data = try? JSONEncoder().encode(unresolved) { try? data.write(to: journalURL, options: .atomic) }
        return unresolved.count
    }
    func focusedWindow(pid: pid_t?) -> String? {
        guard let pid, entries.values.contains(where: { $0.window.pid == pid }) else { return nil }
        let root = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root, 0.15)
        guard let focused = value(root, kAXFocusedWindowAttribute) else { return nil }
        return entries.first { $0.value.window.pid == pid && CFEqual($0.value.element, focused) }?.key
    }
    func focus(_ id: String) -> pid_t? {
        guard let window = entries[id] else { return nil }
        let app = AXUIElementCreateApplication(window.window.pid); AXUIElementSetMessagingTimeout(app, 0.15)
        let front = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let main = AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focused = AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        Diag.log("arrange focus AX: front \(front.rawValue), main \(main.rawValue), focused \(focused.rawValue), raise \(raised.rawValue), foreground \(flag(app, kAXFrontmostAttribute))")
        guard main == .success || focused == .success || raised == .success else { return nil }
        return window.window.pid
    }
}
