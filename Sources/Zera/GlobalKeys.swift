import AppKit
import ApplicationServices
import Carbon

// MARK: - Global keys
//
// One listener for the keyboard everywhere on the Mac, shared by Command Echo (shortcuts, media
// keys, Caps Lock, Shift) and dictation (hold a key to talk). It is a listen-only Quartz event
// tap — it never changes or delays a key — which macOS allows once Zera has Input Monitoring or
// Accessibility. Without either it falls back to NSEvent monitors and quietly tries the tap
// again every few seconds, so granting the permission takes effect without a relaunch.
// Handlers are called on the main thread.
final class GlobalKeys {
    static let shared = GlobalKeys()
    typealias Handler = (NSEvent) -> Void

    private var handlers: [Int: (NSEvent.EventTypeMask, Handler)] = [:]
    private var nextID = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var monitors: [Any] = []
    private var retry: Timer?
    /// True only after the event tap has delivered a key while another app is active.
    private(set) var usingTap = false
    private var lastDelivery: (type: NSEvent.EventType, code: Int, time: TimeInterval, flags: UInt)?
    /// Events delivered so far (for the self-test).
    private(set) var delivered = 0

    private init() {}

    /// Some app (a password field, Terminal's Secure Keyboard Entry, a login prompt) has hidden
    /// the keyboard from every other app. Nothing can see shortcuts until it lets go.
    static var secureInputOn: Bool { IsSecureEventInputEnabled() }

    static var listenAllowed: Bool { CGPreflightListenEventAccess() }
    static var postAllowed: Bool { CGPreflightPostEventAccess() }

    /// Shows macOS's prompt for Input Monitoring (once; afterwards it only opens the setting).
    static func requestListen() { _ = CGRequestListenEventAccess() }

    @discardableResult
    func subscribe(_ mask: NSEvent.EventTypeMask, _ handler: @escaping Handler) -> Int {
        nextID += 1
        handlers[nextID] = (mask, handler)
        start()
        return nextID
    }

    func unsubscribe(_ id: Int) {
        handlers[id] = nil
        if handlers.isEmpty { stop() }
    }

    /// Preflight access or confirmed tap delivery. A created-but-silent tap is not evidence.
    static var keysAllowed: Bool { listenAllowed || AXIsProcessTrusted() || shared.usingTap }

    /// Asks once per launch for what's missing (macOS shows its own prompts).
    static func requestAccessIfNeeded() {
        guard !keysAllowed else { return }
        Diag.log("keys: asking for Accessibility and Input Monitoring")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        requestListen()
    }

    private func start() {
        guard !usingTap else { return }
        // A preflight result can lag the enabled macOS switch after a rebuild. The
        // listen-only API still enforces access; keep fallback monitors until real delivery.
        if tap == nil, makeTap() {
            Diag.log("keys: listen-only tap created; waiting for a key event")
        }
        if monitors.isEmpty {
            Diag.log("keys: no event tap yet (input monitoring \(Self.listenAllowed), accessibility \(AXIsProcessTrusted())) — using NSEvent monitors")
            let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .systemDefined]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.dispatch(e) }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.dispatch(e); return e }) { monitors.append(l) }
        }
        if retry == nil {
            let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                guard let self = self, !self.handlers.isEmpty else { return }
                self.start()
            }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            retry = t
        }
    }

    private func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil; usingTap = false
        lastDelivery = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        retry?.invalidate(); retry = nil
    }

    /// Media/modifier events and keys inside Zera do not prove cross-app keyboard access.
    static func isGlobalKeyDelivery(_ type: NSEvent.EventType, frontmostPID: Int32?, ownPID: Int32, ownsKeyWindow: Bool = false) -> Bool {
        guard !ownsKeyWindow, type == .keyDown, let frontmostPID, frontmostPID > 0 else { return false }
        return frontmostPID != ownPID
    }

    private func makeTap() -> Bool {
        var mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        mask |= 1 << 14   // NX_SYSDEFINED: volume, brightness and play keys
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<GlobalKeys>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if let ns = NSEvent(cgEvent: event) {
                if !me.usingTap, ns.type == .keyDown, GlobalKeys.isGlobalKeyDelivery(ns.type,
                    frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    ownPID: ProcessInfo.processInfo.processIdentifier,
                    ownsKeyWindow: NSApp.keyWindow?.isKeyWindow == true) {
                    me.usingTap = true
                    me.monitors.forEach { NSEvent.removeMonitor($0) }
                    me.monitors.removeAll()
                    me.retry?.invalidate(); me.retry = nil
                    Diag.log("keys: event tap delivered a key while another app was active")
                }
                me.dispatch(ns)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t; source = s
        return true
    }

    private func dispatch(_ e: NSEvent) {
        let code = e.type == .systemDefined ? e.data1 : Int(e.keyCode)
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        if let last = lastDelivery, last.type == e.type, last.code == code, last.flags == flags,
           abs(last.time - e.timestamp) < 0.000_001 { return }
        lastDelivery = (e.type, code, e.timestamp, flags)
        delivered += 1
        if delivered == 1 { Diag.log("keys: first event delivered") }
        // Modifier keys only (no characters): which one and the flags it left.
        if e.type == .flagsChanged, (54...63).contains(e.keyCode) {
            Diag.log("keys: modifier \(e.keyCode) flags \(String(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue, radix: 16))")
        }
        let type = NSEvent.EventTypeMask(type: e.type)
        for (mask, handler) in handlers.values where mask.contains(type) { handler(e) }
    }
}
