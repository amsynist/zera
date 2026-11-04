import AppKit
import AVFoundation
#if canImport(WhisperKit)
import WhisperKit
#endif

// MARK: - Murmur: Zera's own speech model
//
// Dictation can run on Apple's recogniser, or on Murmur: an OpenAI Whisper model (Core ML,
// through WhisperKit) downloaded once to ~/Library/Application Support/Zera/Models and run on
// this Mac's Neural Engine. Nothing you say leaves the Mac. While you hold right ⌥ the words
// are re-read from what you've said so far about once a second, so they appear in the notch as
// you speak; on release the whole take is read once more and typed. A first-launch intro offers
// the download; Settings → Notch → Voice can change, re-download or remove it.

enum MurmurModel: String, CaseIterable {
    case quick = "openai_whisper-base"
    case balanced = "openai_whisper-small"
    case best = "openai_whisper-large-v3-v20240930_turbo_632MB"

    var title: String {
        switch self {
        case .quick: return "Quick · about 145 MB"
        case .balanced: return "Balanced · about 480 MB"
        case .best: return "Best · about 630 MB"
        }
    }

    var blurb: String {
        switch self {
        case .quick: return "Fast on any Mac. Fine for short notes and messages."
        case .balanced: return "Fewer mistakes with names and longer sentences."
        case .best: return "Whisper large-v3 turbo: the most accurate, in 99 languages. Wants Apple silicon."
        }
    }

    static var recommended: MurmurModel {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return machine.hasPrefix("arm64") ? .best : .quick
    }
}

final class Murmur {
    static let shared = Murmur()
    static let stateChanged = Notification.Name("zera.murmur.stateChanged")

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case loading
        case ready
        case failed(String)

        var summary: String {
            switch self {
            case .notInstalled: return "Not downloaded"
            case .downloading(let p): return "Downloading… \(Int(p * 100))%"
            case .loading: return "Getting ready…"
            case .ready: return "Ready · on this Mac"
            case .failed(let why): return "Couldn't finish: \(why)"
            }
        }
    }

    private enum Key {
        static let model = "zera.murmur.model"
        static let folder = "zera.murmur.folder"
        static let intro = "zera.murmur.introSeen"
        static let use = "zera.murmur.use"
    }

    /// Whether this build carries the speech model runtime at all.
    static var isAvailable: Bool {
        #if canImport(WhisperKit)
        return true
        #else
        return false
        #endif
    }

    private(set) var state: State = .notInstalled {
        didSet {
            guard state != oldValue else { return }
            if case .downloading = state, case .downloading = oldValue {} else { Diag.log("murmur: \(state.summary)") }
            NotificationCenter.default.post(name: Self.stateChanged, object: nil)
        }
    }
    private var job: Task<Void, Never>?
    #if canImport(WhisperKit)
    private var pipe: WhisperKit?
    #endif

    private init() {}

    var model: MurmurModel {
        get { MurmurModel(rawValue: UserDefaults.standard.string(forKey: Key.model) ?? "") ?? MurmurModel.recommended }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.model) }
    }

    /// Dictation uses Murmur when it's ready (on by default; off = Apple's recogniser).
    var useForDictation: Bool {
        get { UserDefaults.standard.object(forKey: Key.use) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.use) }
    }

    var introSeen: Bool {
        get { UserDefaults.standard.bool(forKey: Key.intro) }
        set { UserDefaults.standard.set(newValue, forKey: Key.intro) }
    }

    var isReady: Bool { state == .ready }
    var isBusy: Bool {
        switch state {
        case .downloading, .loading: return true
        default: return false
        }
    }

    static var modelsBase: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Zera/Models", isDirectory: true)
    }

    /// The downloaded model's folder, when it is still there.
    var installedFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: Key.folder) else { return nil }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &dir), dir.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// At launch: loads a model that is already on disk (in the background).
    func start() {
        guard Self.isAvailable, installedFolder != nil else { return }
        load()
    }

    /// Downloads `m` (replacing any other) and loads it. Progress goes to `state`.
    func download(_ m: MurmurModel) {
        #if canImport(WhisperKit)
        job?.cancel()
        model = m
        pipe = nil
        state = .downloading(0)
        let base = Self.modelsBase
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        job = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let folder = try await WhisperKit.download(variant: m.rawValue, downloadBase: base, progressCallback: { p in
                    let f = p.fractionCompleted
                    DispatchQueue.main.async {
                        guard let self = self, case .downloading = self.state else { return }
                        self.state = .downloading(max(0, min(1, f)))
                    }
                })
                try Task.checkCancellation()
                await MainActor.run {
                    let old = UserDefaults.standard.string(forKey: Key.folder)
                    UserDefaults.standard.set(folder.path, forKey: Key.folder)
                    if let old = old, old != folder.path { try? FileManager.default.removeItem(atPath: old) }
                    self?.load()
                }
            } catch is CancellationError {
                await MainActor.run { self?.state = self?.installedFolder == nil ? .notInstalled : .failed("cancelled") }
            } catch {
                let why = error.localizedDescription
                await MainActor.run { self?.state = .failed(why) }
            }
        }
        #else
        state = .failed("this build has no speech model runtime")
        #endif
    }

    func cancelDownload() {
        job?.cancel()
        job = nil
        state = installedFolder == nil ? .notInstalled : .ready
        if installedFolder != nil { load() }
    }

    /// Deletes the model from disk; dictation falls back to Apple's recogniser.
    func remove() {
        job?.cancel(); job = nil
        #if canImport(WhisperKit)
        pipe = nil
        #endif
        if let f = installedFolder { try? FileManager.default.removeItem(at: f) }
        UserDefaults.standard.removeObject(forKey: Key.folder)
        state = .notInstalled
    }

    private func load() {
        #if canImport(WhisperKit)
        guard let folder = installedFolder else { state = .notInstalled; return }
        state = .loading
        let variant = model.rawValue
        job = Task.detached(priority: .utility) { [weak self] in
            do {
                let config = WhisperKitConfig(model: variant, modelFolder: folder.path, verbose: false,
                                              logLevel: .error, prewarm: true, load: true, download: false)
                let kit = try await WhisperKit(config)
                await MainActor.run {
                    self?.pipe = kit
                    self?.state = .ready
                }
            } catch {
                let why = error.localizedDescription
                await MainActor.run { self?.state = .failed(why) }
            }
        }
        #endif
    }

    /// What was said in `samples` (16 kHz mono), or nil. Runs off the main thread; `done` is
    /// called on the main thread.
    func transcribe(_ samples: [Float], done: @escaping (String?) -> Void) {
        #if canImport(WhisperKit)
        guard let kit = pipe, samples.count > 8000 else { done(nil); return }
        Task.detached(priority: .userInitiated) {
            var options = DecodingOptions()
            options.skipSpecialTokens = true
            options.withoutTimestamps = true
            options.suppressBlank = true
            let results = try? await kit.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map { Murmur.clean($0.map(\.text).joined(separator: " ")) }
            await MainActor.run { done(text) }
        }
        #else
        done(nil)
        #endif
    }

    /// Drops Whisper's markers ("[BLANK_AUDIO]", "(music)", "<|en|>") and tidies spaces.
    static func clean(_ raw: String) -> String {
        var s = raw
        for pattern in ["<\\|[^|]*\\|>", "\\[[^\\]]*\\]", "\\((?:music|applause|silence|blank audio|inaudible)[^)]*\\)"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Microphone → 16 kHz mono

/// Records the microphone as 16 kHz mono floats (what Whisper reads) and reports how loud you
/// are. The microphone is only open between `start` and `stop`.
final class MurmurRecorder {
    static let shared = MurmurRecorder()
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastLevelAt: CFTimeInterval = 0
    private(set) var isRunning = false
    /// 0…1, about 20 times a second, on the main thread.
    var onLevel: ((Double) -> Void)?
    /// Whisper reads at most 30 s at once; longer takes keep the last 30 s for the live read.
    static let rate: Double = 16000

    private init() {}

    static var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func askForMic(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func start() -> Bool {
        _ = stop()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return false }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self = self, buffer.frameLength > 0 else { return }
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let db = 20 * log10(max((sum / Float(n)).squareRoot(), 1e-6))
                let level = Double(max(0, min(1, (db + 50) / 45)))
                DispatchQueue.main.async {
                    let now = CACurrentMediaTime()
                    guard now - self.lastLevelAt > 0.05 else { return }
                    self.lastLevelAt = now
                    self.onLevel?(level)
                }
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / inFormat.sampleRate + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
            let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            self.lock.lock(); self.samples.append(contentsOf: chunk); self.lock.unlock()
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); return false }
        isRunning = true
        return true
    }

    /// Everything recorded so far (the microphone stays open).
    func snapshot(lastSeconds: Double? = nil) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if let s = lastSeconds {
            let keep = Int(s * Self.rate)
            if samples.count > keep { return Array(samples.suffix(keep)) }
        }
        return samples
    }

    /// Closes the microphone and returns the whole take.
    @discardableResult
    func stop() -> [Float] {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        lock.lock(); defer { lock.unlock() }
        let all = samples
        samples.removeAll()
        return all
    }
}

// MARK: - First-launch intro

/// "Meet Murmur": shown once at launch (after the welcome window) while no model is on disk.
/// Pick a size, download with progress, and dictation switches over by itself when it's ready.
final class MurmurIntroController: NSWindowController, NSWindowDelegate {
    private(set) static var current: MurmurIntroController?
    static let size = NSSize(width: 500, height: 380)

    private let choice = ZeraSelect(MurmurModel.allCases.map(\.title))
    private let blurb = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var primary: CardButton!
    private var secondary: CardButton!
    private var observer: Any?

    /// Shows the intro if it hasn't been seen and no model is installed.
    static func presentIfNeeded() {
        guard Murmur.isAvailable, !Murmur.shared.introSeen, Murmur.shared.installedFolder == nil else { return }
        present()
    }

    static func present() {
        if let c = current { c.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let c = MurmurIntroController()
        current = c
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Murmur"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.appearance = NSAppearance(named: .darkAqua)
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: w)
        w.delegate = self
        build()
        observer = NotificationCenter.default.addObserver(forName: Murmur.stateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    private func build() {
        let root = MurmurIntroBackdrop(frame: NSRect(origin: .zero, size: Self.size))
        window?.contentView = root
        let pad: CGFloat = 32
        let width = Self.size.width - pad * 2

        let title = NSTextField(labelWithString: "Meet Murmur")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: pad, y: 292, width: width, height: 32)

        let sub = NSTextField(wrappingLabelWithString: "Hold right ⌥ or right ⇧ and talk — your words appear in the notch as you speak, and are typed where your cursor is when you let go. Murmur is a speech model that runs on this Mac, so nothing you say leaves it. It needs a one-time download.")
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = NSColor(white: 1, alpha: 0.75)
        sub.frame = NSRect(x: pad, y: 210, width: width, height: 76)

        let label = NSTextField(labelWithString: "Model")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor(white: 1, alpha: 0.6)
        label.frame = NSRect(x: pad, y: 176, width: 80, height: 18)
        choice.frame = NSRect(x: pad + 70, y: 170, width: 230, height: 28)
        choice.select(MurmurModel.allCases.firstIndex(of: Murmur.shared.model) ?? 0)
        choice.onChange = { [weak self] _ in self?.refresh() }

        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = NSColor(white: 1, alpha: 0.6)
        blurb.frame = NSRect(x: pad, y: 124, width: width, height: 36)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.frame = NSRect(x: pad, y: 98, width: width, height: 12)

        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = NSColor(white: 1, alpha: 0.75)
        status.frame = NSRect(x: pad, y: 74, width: width, height: 18)

        primary = CardButton("Download", style: .primary, symbol: "arrow.down.circle", target: self, action: #selector(primaryTapped))
        primary.frame = NSRect(x: Self.size.width - pad - 150, y: 24, width: 150, height: 32)
        secondary = CardButton("Not now", style: .tertiary, target: self, action: #selector(secondaryTapped))
        secondary.frame = NSRect(x: Self.size.width - pad - 150 - 12 - 110, y: 24, width: 110, height: 32)

        for v in [title, sub, label, choice, blurb, bar, status, primary!, secondary!] as [NSView] { root.addSubview(v) }
    }

    private var picked: MurmurModel {
        MurmurModel.allCases[max(0, min(MurmurModel.allCases.count - 1, choice.selectedIndex))]
    }

    private func refresh() {
        let m = Murmur.shared
        blurb.stringValue = picked.blurb + (picked == MurmurModel.recommended ? " Recommended for this Mac." : "")
        status.stringValue = m.state == .notInstalled ? "Downloads from Hugging Face (argmaxinc/whisperkit-coreml) once." : m.state.summary
        switch m.state {
        case .downloading(let p):
            bar.isHidden = false; bar.doubleValue = p
            primary.isEnabled = false
            choice.isEnabled = false
            secondary.setTitleText("Cancel")
        case .loading:
            bar.isHidden = false; bar.doubleValue = 1
            primary.isEnabled = false
            choice.isEnabled = false
            secondary.setTitleText("Close")
        case .ready:
            bar.isHidden = true
            primary.isEnabled = true
            primary.setTitleText(picked == m.model ? "Done" : "Switch model")
            choice.isEnabled = true
            secondary.isHidden = true
            status.stringValue = "Murmur (\(m.model.title)) is ready. Hold \(Dictation.shared.trigger.short) anywhere and talk."
        case .notInstalled, .failed:
            bar.isHidden = true
            primary.isEnabled = true
            primary.setTitleText(m.state == .notInstalled ? "Download" : "Try again")
            choice.isEnabled = true
            secondary.setTitleText("Not now")
            secondary.isHidden = false
        }
    }

    @objc private func primaryTapped() {
        if Murmur.shared.isReady, picked == Murmur.shared.model { close(); return }
        MurmurRecorder.askForMic { _ in }
        if !Dictation.shared.enabled { Dictation.shared.enabled = true }
        Murmur.shared.download(picked)
    }

    @objc private func secondaryTapped() {
        if case .downloading = Murmur.shared.state { Murmur.shared.cancelDownload(); return }
        close()
    }

    func windowWillClose(_ notification: Notification) {
        // The self-test tour opens it too; that doesn't count as you having seen it.
        if ProcessInfo.processInfo.environment["ZERA_TOUR"] == nil { Murmur.shared.introSeen = true }
        Self.current = nil
    }
}

/// Navy glass with a violet glow at the top, Zera's voice colour.
private final class MurmurIntroBackdrop: NSView {
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.14, alpha: 1).setFill()
        b.fill()
        let violet = NSColor(srgbRed: 0.69, green: 0.48, blue: 1, alpha: 1)
        if let g = NSGradient(colors: [violet.withAlphaComponent(0.45), violet.withAlphaComponent(0)]) {
            g.draw(fromCenter: NSPoint(x: b.midX, y: b.maxY + 30), radius: 0,
                   toCenter: NSPoint(x: b.midX, y: b.maxY + 30), radius: b.width * 0.7, options: [])
        }
        // A few voice bars under the title, like the notch while you dictate.
        let heights: [CGFloat] = [6, 14, 22, 12, 18, 8, 15]
        for (i, h) in heights.enumerated() {
            let r = NSRect(x: b.maxX - 32 - CGFloat(heights.count - i) * 6, y: 300 + (22 - h) / 2, width: 3, height: h)
            violet.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
