import AppKit
import CoreAudio
import AudioToolbox

// MARK: - System audio levels
//
// What is actually playing, as one loudness value (0…1), for the music tile's bars. Uses a
// Core Audio process tap (macOS 14.2+): a private, unmuted stereo mix of everything playing,
// read through a private aggregate device. Only levels are computed; no sample is stored or
// sent anywhere. macOS asks once for "System Audio Recording". Off by default; while on, it
// runs only while a music tile is visible and a track plays (`retain` / `release`).
final class SystemAudioLevels {
    static let shared = SystemAudioLevels()
    private static let key = "zera.music.realBars"

    private var owners = 0
    private var engine: AnyObject?          // `TapEngine` on macOS 14.2+
    private let lock = NSLock()
    private var _level: Float = 0

    private init() {}

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set { UserDefaults.standard.set(newValue, forKey: Self.key); sync() }
    }

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true } else { return false }
    }

    /// Smoothed loudness, 0…1 (0 when off).
    var level: Float { lock.lock(); defer { lock.unlock() }; return _level }

    fileprivate func publish(_ rms: Float) {
        // Roughly perceptual: -50 dB → 0, 0 dB → 1; fast attack, slower release.
        let db = 20 * log10(max(rms, 1e-6))
        let target = max(0, min(1, (db + 50) / 50))
        lock.lock()
        _level = target > _level ? target : _level * 0.85 + target * 0.15
        lock.unlock()
    }

    func retain() { owners += 1; sync() }
    func release() { owners = max(0, owners - 1); sync() }

    private func sync() {
        let want = enabled && owners > 0
        if want, engine == nil {
            if #available(macOS 14.2, *) {
                let e = TapEngine(levels: self)
                if e.start() { engine = e }
            }
        } else if !want, let e = engine {
            if #available(macOS 14.2, *) { (e as? TapEngine)?.stop() }
            engine = nil
            lock.lock(); _level = 0; lock.unlock()
        }
    }
}

@available(macOS 14.2, *)
private final class TapEngine {
    private weak var levels: SystemAudioLevels?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "zera.audiolevels", qos: .userInitiated)

    init(levels: SystemAudioLevels) { self.levels = levels }

    func start() -> Bool {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.name = "Zera levels"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(tap, &tapID) == noErr, tapID != kAudioObjectUnknown else { return false }
        guard let outputUID = Self.defaultOutputUID() else { stop(); return false }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Zera Levels",
            kAudioAggregateDeviceUIDKey: "zera-levels-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: tap.uuid.uuidString]]
        ]
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID) == noErr else { stop(); return false }
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.measure(input)
        }
        guard status == noErr, let proc = procID, AudioDeviceStart(aggregateID, proc) == noErr else { stop(); return false }
        return true
    }

    /// RMS of every float sample in this buffer list.
    private func measure(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var sum: Float = 0
        var count = 0
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { sum += samples[i] * samples[i] }
            count += n
        }
        guard count > 0 else { return }
        levels?.publish((sum / Float(count)).squareRoot())
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let proc = procID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &uidSize, &uid) == noErr, let value = uid else { return nil }
        return value.takeRetainedValue() as String
    }
}

// MARK: - The bars

/// Five slim bars; heights follow `SystemAudioLevels` when it runs, otherwise a gentle idle sway.
final class LevelBarsView: NSView {
    private var phase: Double = 0
    private var heights: [CGFloat] = [0.3, 0.5, 0.4, 0.6, 0.35]
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Called from the tile's animation tick (≈30 fps, only while playing).
    func step(level: Float, now: TimeInterval) {
        phase = now
        let base = CGFloat(level)
        var next: [CGFloat] = []
        for i in 0..<heights.count {
            let wobble = CGFloat(0.5 + 0.5 * sin(now * (5.3 + Double(i) * 1.7) + Double(i)))
            let h = level > 0 ? base * (0.55 + 0.45 * wobble) : 0.15 + 0.12 * wobble
            next.append(max(0.08, min(1, h)))
        }
        if zip(next, heights).contains(where: { abs($0 - $1) * bounds.height >= 0.5 }) {
            heights = next
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = CGFloat(heights.count)
        let gap: CGFloat = 2
        let w = max(1.5, (bounds.width - gap * (n - 1)) / n)
        let accent = Pal.accent
        for (i, h) in heights.enumerated() {
            let bh = max(2, bounds.height * h)
            let r = NSRect(x: CGFloat(i) * (w + gap), y: bounds.height - bh, width: w, height: bh)
            accent.withAlphaComponent(0.55 + 0.45 * h).setFill()
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}
