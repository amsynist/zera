import AppKit
import CoreAudio
import IOKit.pwr_mgt
import ImageIO

// MARK: - Keep awake while Claude works
//
// One IOKit power assertion, held only while a Claude Code session is actively running. It stops
// idle *system* sleep; the display still dims, turns off and locks as usual. Released the moment
// nothing is running (or the setting goes off). Nothing polls: `ZeraController.updateLive` sets
// `agentsWorking` whenever it already refreshes the wings. Use from the main thread.
final class AwakeKeeper {
    static let shared = AwakeKeeper()
    private static let key = "zera.keepAwake.agents"
    private var assertion = IOPMAssertionID(0)
    private(set) var held = false

    private init() {}

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.key); sync() }
    }

    /// Claude Code sessions running (set from the wings' refresh).
    var agentsWorking = false {
        didSet { if agentsWorking != oldValue { sync() } }
    }
    /// Codex / Cursor runs at work (set from `AgentWatch`).
    var otherAgentsWorking = false {
        didSet { if otherAgentsWorking != oldValue { sync() } }
    }

    private func sync() {
        let want = enabled && (agentsWorking || otherAgentsWorking)
        if want, !held {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Zera: Claude Code is working" as CFString, &id)
            if result == kIOReturnSuccess { assertion = id; held = true }
        } else if !want, held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }
}

// MARK: - Screen-share shield
//
// Keeps Zera's panels out of screen shares and recordings: always, never, or (default) while
// another app is using the microphone — a call. You still see everything on your own screen.
// Every panel comes through `FloatingPanel.make`, which registers it here. The microphone is
// watched with CoreAudio property listeners (no polling): "is the default input running in any
// process", re-attached when the default input device changes. Use from the main thread.
final class ShareShield {
    static let shared = ShareShield()
    enum Mode: Int { case never = 0, duringCalls = 1, always = 2 }

    private static let key = "zera.shareShield"
    private let panels = NSHashTable<NSWindow>.weakObjects()
    private(set) var micInUse = false
    private var watchedInput = AudioObjectID(kAudioObjectUnknown)
    private var listening = false
    // Delivered on the main queue (see the `.main` passed when attaching).
    private lazy var runningListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.readMic() }
    private lazy var defaultInputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attachToDefaultInput() }

    private init() {}

    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.object(forKey: Self.key) as? Int ?? Mode.duringCalls.rawValue) ?? .duringCalls }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.key); syncListening(); apply() }
    }

    var hiding: Bool { mode == .always || (mode == .duringCalls && micInUse) }

    func register(_ window: NSWindow) {
        panels.add(window)
        window.sharingType = hiding ? .none : .readOnly
    }

    func start() { syncListening(); apply() }

    private func apply() {
        let type: NSWindow.SharingType = hiding ? .none : .readOnly
        for w in panels.allObjects where w.sharingType != type { w.sharingType = type }
    }

    // MARK: Microphone

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    /// Listens only in "during calls" mode; otherwise nothing is attached.
    private func syncListening() {
        let want = mode == .duringCalls
        guard want != listening else { return }
        listening = want
        let system = AudioObjectID(kAudioObjectSystemObject)
        if want {
            AudioObjectAddPropertyListenerBlock(system, &Self.defaultInputAddress, .main, defaultInputListener)
            attachToDefaultInput()
        } else {
            AudioObjectRemovePropertyListenerBlock(system, &Self.defaultInputAddress, .main, defaultInputListener)
            detachInput()
            micInUse = false
        }
    }

    private func attachToDefaultInput() {
        detachInput()
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInputAddress, 0, nil, &size, &device)
        if status == noErr, device != kAudioObjectUnknown {
            watchedInput = device
            AudioObjectAddPropertyListenerBlock(device, &Self.runningAddress, .main, runningListener)
        }
        readMic()
    }

    private func detachInput() {
        guard watchedInput != kAudioObjectUnknown else { return }
        AudioObjectRemovePropertyListenerBlock(watchedInput, &Self.runningAddress, .main, runningListener)
        watchedInput = AudioObjectID(kAudioObjectUnknown)
    }

    private func readMic() {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let ok = watchedInput != kAudioObjectUnknown
            && AudioObjectGetPropertyData(watchedInput, &Self.runningAddress, 0, nil, &size, &running) == noErr
        let inUse = ok && running != 0
        guard inUse != micInUse else { return }
        micInUse = inUse
        apply()
    }
}

// MARK: - Wallpaper-matched light
//
// Optional: the notch light takes its colour from the wallpaper (a vivid-weighted average, lifted
// so it glows; a grey or black wallpaper gives a cool white). Worked out once per wallpaper on a
// background queue from a 48 px thumbnail; refreshed when the Space, the screens or wake change it.
final class WallpaperTint {
    static let shared = WallpaperTint()
    static let changed = Notification.Name("ZeraWallpaperTintChanged")
    private static let key = "zera.light.wallpaper"

    private(set) var color: NSColor?
    private var lastURL: URL?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// What the notch light should use as its accent right now.
    static var lightAccent: NSColor { shared.color ?? Neon.accent }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
            if newValue { refresh(force: true) }
            else { color = nil; lastURL = nil; NotificationCenter.default.post(name: Self.changed, object: nil) }
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        refresh()
    }

    func refresh(force: Bool = false) {
        guard enabled, let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        if !force, url == lastURL { return }
        lastURL = url
        DispatchQueue.global(qos: .utility).async {
            let c = Self.average(of: url)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.enabled else { return }
                self.color = c
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }
    }

    static func average(of url: URL) -> NSColor? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 48,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return glowColor(of: image)
    }

    /// A colour that glows, from any picture (wallpaper, album art).
    static func glowColor(of image: CGImage) -> NSColor? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = 16, h = 16
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let pr = Double(px[i]) / 255, pg = Double(px[i + 1]) / 255, pb = Double(px[i + 2]) / 255
            let hi = max(pr, pg, pb), lo = min(pr, pg, pb)
            // Vivid pixels count more, so a grey sky doesn't wash out the sunset under it.
            let weight = 0.15 + (hi - lo) * 2 + hi * 0.2
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return nil }
        let avg = NSColor(srgbRed: CGFloat(r / total), green: CGFloat(g / total), blue: CGFloat(b / total), alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        avg.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        if sat < 0.08 { return NSColor(srgbRed: 0.92, green: 0.95, blue: 1, alpha: 1) }
        return NSColor(hue: hue, saturation: max(0.45, min(0.85, sat * 1.6)), brightness: max(0.85, bri), alpha: 1)
    }
}

// MARK: - AirDrop

enum AirDrop {
    static var service: NSSharingService? { NSSharingService(named: .sendViaAirDrop) }

    static func canSend(_ urls: [URL]) -> Bool { service?.canPerform(withItems: urls) ?? false }

    /// Opens the system AirDrop sheet with these files.
    static func send(_ urls: [URL]) {
        guard let s = service, s.canPerform(withItems: urls) else { return }
        NSApp.activate(ignoringOtherApps: true)
        s.perform(withItems: urls)
    }
}

// MARK: - Rain soon
//
// From the forecast Zera already fetches for Home: dry now, but rain likely (≥ 60 %) within the
// next two hours. At most once every three hours.
enum RainWatch {
    static func isWet(_ code: Int) -> Bool { (51...67).contains(code) || (80...82).contains(code) || code >= 95 }

    static func upcoming(_ s: WeatherSnapshot, now: Date = Date()) -> WeatherHour? {
        guard !isWet(s.code) else { return nil }
        return s.hours.first { h in
            h.time > now && h.time <= now.addingTimeInterval(2 * 3600) && (h.precipitationChance ?? 0) >= 60 && isWet(h.code)
        }
    }
}

// MARK: - Audio output
//
// The Mac's output devices and the current default, for "Play on…" on the music tile.
enum AudioOutputs {
    struct Device: Equatable { let id: AudioObjectID; let name: String }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddr = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr, let n = name else { return nil }
            let title = n.takeRetainedValue() as String
            // Our own private level-reading device never shows up here (it's private), but be sure.
            guard !title.hasPrefix("Zera Levels") else { return nil }
            return Device(id: id, name: title)
        }
    }

    static var current: AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    @discardableResult
    static func select(_ id: AudioObjectID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
    }
}
