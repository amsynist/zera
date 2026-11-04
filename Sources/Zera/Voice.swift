import AppKit
import ApplicationServices
import AVFoundation
import Speech

// MARK: - Speech listener
//
// One microphone session at a time, Apple's speech recogniser, on-device whenever the Mac
// supports it (nothing leaves the Mac then). Used by voice approvals and by dictation. The
// microphone is only open between `start` and `stop`. Use from the main thread.
final class SpeechListener {
    static let shared = SpeechListener()

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private(set) var isRunning = false
    /// How loud you are right now (0…1), about 20 times a second while listening.
    var onLevel: ((Double) -> Void)?
    private var lastLevelAt: CFTimeInterval = 0

    private init() {}

    /// Speech recognition and microphone both allowed (asks for whichever is still undecided).
    static func authorize(_ done: @escaping (Bool) -> Void) {
        func mic() {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: done(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
            default: done(false)
            }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: mic()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { status == .authorized ? mic() : done(false) }
            }
        default: done(false)
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Starts listening. `onText` gets the running transcript (and `true` once it is final);
    /// `onEnd` fires once when the session stops for any reason other than `stop()`.
    @discardableResult
    func start(hint: SFSpeechRecognitionTaskHint, phrases: [String] = [],
               onText: @escaping (String, Bool) -> Void, onEnd: (() -> Void)? = nil) -> Bool {
        stop()
        guard Self.isAuthorized else { return false }
        let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let rec = rec, rec.isAvailable else { return false }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = hint
        req.contextualStrings = phrases
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            guard let samples = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += samples[i] * samples[i] }
            let db = 20 * log10(max((sum / Float(n)).squareRoot(), 1e-6))
            let level = Double(max(0, min(1, (db + 50) / 45)))
            DispatchQueue.main.async {
                guard let self = self else { return }
                let now = CACurrentMediaTime()
                guard now - self.lastLevelAt > 0.05 else { return }
                self.lastLevelAt = now
                self.onLevel?(level)
            }
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); tapInstalled = false; return false }

        generation += 1
        let gen = generation
        recognizer = rec
        request = req
        isRunning = true
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation else { return }
                // Tear down this take before callbacks can start the next microphone
                // owner (for example voice approvals resuming after dictation).
                if final || error != nil { self.teardown() }
                if let t = text { onText(t, final) }
                if final || error != nil { onEnd?() }
            }
        }
        return true
    }

    /// Stops the microphone now; any result still in flight is dropped.
    func stop() {
        generation += 1
        task?.cancel()
        teardown()
    }

    /// Stops the microphone but lets the recogniser deliver its final transcript.
    func finish() {
        guard isRunning else { return }
        request?.endAudio()
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        request = nil
        task = nil
        recognizer = nil
        isRunning = false
    }
}

// MARK: - Voice approvals
//
// While a Claude Code permission card is waiting, and only then, Zera listens for a short
// answer: "approve" / "allow" / "yes" / "okay", "deny" / "reject" / "no", or "open". Longer
// sentences are ignored, so a conversation in the room doesn't answer for you. The notch shows
// that it is listening. Off by default.
final class VoiceApproval {
    static let shared = VoiceApproval()
    private static let key = "zera.voice.approvals"

    /// Same path as tapping Approve / Reject on the wings.
    var onDecide: ((HookRequest, Bool) -> Void)?
    var onOpen: (() -> Void)?
    /// The notch light / pill while listening.
    var onListening: ((Bool) -> Void)?

    private var listeningFor: String?
    private var restarts = 0
    private var observer: NSObjectProtocol?

    private init() {}

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
            if newValue { SpeechListener.authorize { [weak self] _ in self?.sync() } } else { sync() }
        }
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: ClaudeHookService.changed, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
        sync()
    }

    private var firstPending: HookRequest? { MainActor.assumeIsolated { ClaudeHookService.shared.pending.first } }

    func resumeAfterDictation() { listeningFor = nil; sync() }
    func pauseForDictation() {
        listeningFor = nil
        SpeechListener.shared.stop()
        onListening?(false)
    }

    private func sync() {
        guard !Dictation.shared.isActive, !Dictation.shared.isProcessing else { return }
        guard enabled, let req = firstPending else {
            if listeningFor != nil { listeningFor = nil; SpeechListener.shared.stop(); onListening?(false) }
            return
        }
        guard listeningFor != req.id else { return }
        listeningFor = req.id
        restarts = 0
        listen(for: req)
    }

    private func listen(for req: HookRequest) {
        let ok = SpeechListener.shared.start(hint: .confirmation, phrases: ["approve", "allow", "deny", "reject", "open"],
            onText: { [weak self] text, _ in self?.heard(text, for: req) },
            onEnd: { [weak self] in
                // The recogniser stops itself after a while; keep listening while the card waits.
                guard let self = self, self.listeningFor == req.id, self.restarts < 8 else { return }
                self.restarts += 1
                self.listen(for: req)
            })
        onListening?(ok)
        if !ok { listeningFor = nil }
    }

    enum Answer: Equatable { case allow, deny, open }

    /// The answer in a short utterance (four words at most), from its last word.
    static func answer(in text: String) -> Answer? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let last = words.last, words.count <= 4 else { return nil }
        switch last {
        case "approve", "approved", "allow", "yes", "yeah", "yep", "ok", "okay", "go", "sure": return .allow
        case "deny", "denied", "reject", "no", "nope", "stop", "cancel": return .deny
        case "open": return .open
        default: return nil
        }
    }

    private func heard(_ text: String, for req: HookRequest) {
        guard listeningFor == req.id, let a = Self.answer(in: text) else { return }
        listeningFor = nil
        SpeechListener.shared.stop()
        onListening?(false)
        switch a {
        case .allow: onDecide?(req, true)
        case .deny: onDecide?(req, false)
        case .open: onOpen?()
        }
        // The next waiting card (if any) gets its own session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.sync() }
    }
}

// MARK: - Dictation
//
// Hold the right Option key on its own and speak; let go and the words are typed where your
// cursor is. Recognition is on-device when the Mac supports it. Text is inserted into the
// original field through native accessibility or targeted Unicode events. Esc while holding cancels.
// Any other key pressed with the right Option makes it a normal shortcut instead.
/// Which key you hold to dictate (Settings → Notch → Voice).
enum DictationKey: Int, CaseIterable {
    case rightOptionOrShift = 0, rightOption = 1, rightShift = 2, fn = 3
    var title: String {
        switch self {
        case .rightOptionOrShift: return "Right ⌥ or right ⇧"
        case .rightOption: return "Right ⌥ Option"
        case .rightShift: return "Right ⇧ Shift"
        case .fn: return "fn / Globe"
        }
    }
    var short: String {
        switch self {
        case .rightOptionOrShift: return "right ⌥ or right ⇧"
        case .rightOption: return "right ⌥"
        case .rightShift: return "right ⇧"
        case .fn: return "fn"
        }
    }
    /// Hardware key codes this choice listens to, with the modifier each one sets.
    var keys: [(UInt16, NSEvent.ModifierFlags)] {
        switch self {
        case .rightOptionOrShift: return [(61, .option), (60, .shift)]
        case .rightOption: return [(61, .option)]
        case .rightShift: return [(60, .shift)]
        case .fn: return [(63, .function)]
        }
    }
}

final class Dictation {
    static let shared = Dictation()
    private static let triggerKey = "zera.dictation.trigger"
    /// The key that started this hold (released → end).
    private var heldKey: (UInt16, NSEvent.ModifierFlags)?
    private static let key = "zera.dictation.enabled"
    /// Marks the ⌘V we post ourselves, so Command Echo doesn't echo it.
    static let eventTag: Int64 = 0x5A45_5241
    private static let holdDelay: TimeInterval = 0.3

    /// Live words for the pill under the notch; nil when it should go away.
    var onTranscript: ((String?) -> Void)?
    /// Inserted (or failed): a short status for the pill.
    var onDone: ((String) -> Void)?

    private var monitors: [Any] = []
    private var holdWork: DispatchWorkItem?
    private(set) var isActive = false
    private var transcript = ""
    private var cancelled = false
    /// The last few voice levels (oldest first), for the bars in the notch.
    private(set) var bars: [Double] = Array(repeating: 0.08, count: 7)
    private var finishWork: DispatchWorkItem?
    /// This take runs on Murmur (the downloaded model) rather than Apple's recogniser.
    private var usingMurmur = false
    private var liveTimer: Timer?
    private var liveBusy = false
    private var session = 0
    private(set) var isProcessing = false
    private(set) var lastUninsertedText: String?
    private var transcriptionJob: Task<Void, Never>?
    private var liveTranscriptionJob: Task<Void, Never>?
    // MARK: Typing as you speak
    private static let liveKey = "zera.dictation.live"
    /// Words go into the field you're in while you talk (off: all at once when you let go).
    var typesLive: Bool {
        get { UserDefaults.standard.object(forKey: Self.liveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.liveKey) }
    }
    /// What this take has already typed into the field.
    private var typed = ""
    /// The previous partial transcript: words that agree across two reads are settled.
    private var lastPartial = ""
    private var insertionTestWork: DispatchWorkItem?
    private var typingTarget: DictationInsertionTarget?
    private var typingAccessObserver: NSObjectProtocol?
    private var sentTypingEvents = false

    /// A new partial transcript: type the settled words that aren't in the field yet. A word only
    /// goes in once two reads agree on it, and the last word waits (it may still change), so the
    /// field almost never needs correcting.
    private func liveUpdate(_ text: String) {
        guard typesLive, isActive else { lastPartial = text; return }
        let settled = Self.settled(previous: lastPartial, current: text)
        lastPartial = text
        guard !settled.isEmpty, settled.count > typed.count, settled.hasPrefix(typed) else { return }
        var add = String(settled.dropFirst(typed.count))
        if typed.isEmpty { add = add.trimmingCharacters(in: .whitespaces) }
        add += " "
        guard let result = typingTarget?.insert(add, allowPaste: false), result != .unavailable else { return }
        if result == .sent { sentTypingEvents = true }
        Diag.log("dictation: typed \(add.count) characters live")
        typed = settled + " "
        if typed.hasPrefix(" ") { typed.removeFirst() }
    }

    /// The words two reads agree on, from the start, never including the newest word.
    static func settled(previous: String, current: String) -> String {
        let now = current.split(separator: " ").map(String.init)
        let before = previous.split(separator: " ").map(String.init)
        var n = 0
        while n < min(now.count - 1, before.count), now[n] == before[n] { n += 1 }
        return now.prefix(n).joined(separator: " ")
    }

    /// Release: bring the field in line with the final transcript — type what's left, or, when the
    /// last read changed a recent word, step back over just that part first (at most 60 characters).
    private func liveFinish(_ final: String) -> Bool {
        guard !typed.isEmpty else { return false }
        let target = final.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        var common = 0
        let a = Array(typed), b = Array(target)
        while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
        let back = a.count - common
        guard back <= 60, let typingTarget else { return false }
        let rest = String(b[common...])
        let result = back > 0
            ? typingTarget.replaceTrailing(String(a[common...]), with: rest)
            : typingTarget.insert(rest)
        guard result != .unavailable else { return false }
        if result == .sent { sentTypingEvents = true }
        typed = target
        return true
    }

    /// The self-test sets this: a hold is recognised and logged, but the microphone stays shut.
    var dryRun = false
    /// When a hold last started dictation (or would have, in a dry run).
    private(set) var lastTrigger: Date?

    private init() {}

    var trigger: DictationKey {
        get { DictationKey(rawValue: UserDefaults.standard.object(forKey: Self.triggerKey) as? Int ?? 0) ?? .rightOptionOrShift }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.triggerKey) }
    }

    /// Holding right ⇧ belongs to dictation, so Command Echo shouldn't show its Shift peek.
    var claimsRightShift: Bool { enabled && trigger.keys.contains { $0.0 == 60 } }

    /// On by default: the first hold asks for the microphone.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
            if newValue { install() } else { uninstall() }
        }
    }

    func start() { if enabled { install() } }

    private func install() {
        guard monitors.isEmpty else { return }
        monitors.append(GlobalKeys.shared.subscribe([.flagsChanged, .keyDown]) { [weak self] e in self?.handle(e) })
        typingAccessObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
                DictationInsertionTarget.prepareAccessibility(for: notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
        DictationInsertionTarget.prepareAccessibility(for: NSWorkspace.shared.frontmostApplication)
    }

    private func uninstall() {
        if let typingAccessObserver { NSWorkspace.shared.notificationCenter.removeObserver(typingAccessObserver) }
        typingAccessObserver = nil
        DictationInsertionTarget.cancelAccessibilityPreparation()
        monitors.compactMap { $0 as? Int }.forEach { GlobalKeys.shared.unsubscribe($0) }
        monitors.removeAll()
        holdWork?.cancel(); holdWork = nil
        if isActive || isProcessing { cancel() }
    }

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown {
            // Another key while holding: a shortcut or a capital letter, not dictation.
            holdWork?.cancel(); holdWork = nil
            if !isActive { heldKey = nil }
            if (isActive || isProcessing), e.keyCode == 53 { cancel() }
            return
        }
        let flags = e.modifierFlags.intersection([.command, .control, .shift, .option, .function])
        if let held = heldKey {
            // Released (its modifier is gone): finish, or drop a hold that never started.
            if e.keyCode == held.0, !flags.contains(held.1) {
                heldKey = nil
                holdWork?.cancel(); holdWork = nil
                if isActive { end() }
            } else if !isActive, flags != held.1 {
                // Another modifier joined in: a shortcut, not dictation.
                heldKey = nil
                holdWork?.cancel(); holdWork = nil
            }
            return
        }
        guard let match = trigger.keys.first(where: { $0.0 == e.keyCode }) else {
            holdWork?.cancel(); holdWork = nil
            return
        }
        // Only that one modifier down.
        guard flags == match.1 else {
            Diag.log("dictation: key \(e.keyCode) with other modifiers (\(String(flags.rawValue, radix: 16))), ignored")
            holdWork?.cancel(); holdWork = nil; return
        }
        guard !isActive, holdWork == nil else { return }
        heldKey = match
        Diag.log("dictation: key \(e.keyCode) down alone, waiting \(Self.holdDelay) s")
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.holdWork = nil
            guard self.heldKey != nil else { return }
            self.lastTrigger = Date()
            Diag.log("dictation: hold recognised (murmur \(Murmur.shared.state.summary), mic \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), speech \(SFSpeechRecognizer.authorizationStatus().rawValue))")
            if self.dryRun { return }
            self.begin()
        }
        holdWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: w)
    }

    /// Only explicit Settings actions may ask for permission. Starting a take must never
    /// activate Settings and steal the very field we're about to type into.
    static var typingAccessConfirmed: Bool { CGPreflightPostEventAccess() || AXIsProcessTrusted() }

    static func requestTypingAccess() {
        guard !typingAccessConfirmed else { return }
        _ = CGRequestPostEventAccess()
    }

    /// Uses the production insertion path without recording or recognizing speech.
    func testInsertion() {
        onDone?("Focus a blank text field within 8 seconds")
        insertionTestWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isActive else { return }
            self.insertionTestWork = nil
            let result = DictationInsertionTarget.capture()?.insert("Zera dictation test.") ?? .unavailable
            Diag.log("dictation test: insertion \(result)")
            self.onDone?(result == .inserted ? "Test text inserted" : result == .sent ? "Test text sent to the field" : "Couldn’t insert — check typing access for this app")
        }
        insertionTestWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func begin() {
        insertionTestWork?.cancel(); insertionTestWork = nil
        guard !isProcessing else { onDone?("Finishing dictation · Esc cancels"); return }
        session += 1
        typingTarget = DictationInsertionTarget.capture()
        sentTypingEvents = false
        if Murmur.shared.useForDictation {
            guard Murmur.shared.isReady else {
                onDone?("Murmur isn’t ready · set up speech in Settings → Permissions & Diagnostics")
                return
            }
            Diag.log("dictation: starting with Murmur")
            beginMurmur()
            return
        }
        Diag.log("dictation: starting with Apple speech")
        guard SpeechListener.isAuthorized else {
            Diag.log("dictation: microphone or speech recognition not allowed — asking")
            SpeechListener.authorize { ok in Diag.log("dictation: permission answer \(ok)") }
            onDone?("Allow Microphone and Speech Recognition for Zera")
            return
        }
        VoiceApproval.shared.pauseForDictation()
        isActive = true
        cancelled = false
        transcript = ""
        typed = ""; lastPartial = ""
        bars = Array(repeating: 0.08, count: 7)
        SpeechListener.shared.onLevel = { [weak self] level in
            guard let self = self, self.isActive else { return }
            self.bars = Array((self.bars + [level]).suffix(7))
            self.onTranscript?(self.transcript)
        }
        onTranscript?("")
        let take = session
        let ok = SpeechListener.shared.start(hint: .dictation,
            onText: { [weak self] text, final in
                guard let self = self, self.session == take else { return }
                self.transcript = text
                if self.isActive { self.onTranscript?(text); self.liveUpdate(text) }
                if final { self.deliver() }
            },
            onEnd: { [weak self] in guard let self, self.session == take else { return }; self.deliver() })
        if !ok { isActive = false; VoiceApproval.shared.resumeAfterDictation(); onTranscript?(nil); onDone?("The microphone isn't available"); Diag.log("dictation: Apple speech failed to start") }
    }

    // MARK: Murmur takes

    private func beginMurmur() {
        guard MurmurRecorder.micAllowed else {
            Diag.log("dictation: microphone not allowed — asking")
            MurmurRecorder.askForMic { ok in Diag.log("dictation: microphone answer \(ok)") }
            onDone?("Allow the Microphone for Zera")
            return
        }
        session += 1
        VoiceApproval.shared.pauseForDictation()
        isActive = true
        usingMurmur = true
        cancelled = false
        transcript = ""
        typed = ""; lastPartial = ""
        bars = Array(repeating: 0.08, count: 7)
        MurmurRecorder.shared.onLevel = { [weak self] level in
            guard let self = self, self.isActive else { return }
            self.bars = Array((self.bars + [level]).suffix(7))
            self.onTranscript?(self.transcript)
        }
        guard MurmurRecorder.shared.start() else {
            Diag.log("dictation: Murmur recorder failed to start")
            isActive = false; usingMurmur = false
            VoiceApproval.shared.resumeAfterDictation()
            onTranscript?(nil); onDone?("The microphone isn't available")
            return
        }
        onTranscript?("")
        // Words appear as you speak: what you've said so far is read again about once a second.
        let t = Timer(timeInterval: 0.9, repeats: true) { [weak self] _ in self?.liveRead() }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    private func liveRead() {
        guard isActive, usingMurmur, !liveBusy else { return }
        // Keep the transcript anchored at the start; a sliding 28-second suffix
        // cannot be reconciled with words already inserted into the original field.
        guard MurmurRecorder.shared.duration <= 28 else { return }
        let audio = MurmurRecorder.shared.snapshot()
        guard audio.count > Int(MurmurRecorder.rate * 0.6) else { return }
        liveBusy = true
        let s = session
        liveTranscriptionJob = Murmur.shared.transcribe(audio) { [weak self] text in
            guard let self = self else { return }
            guard s == self.session else { return }
            self.liveBusy = false
            guard self.isActive, let t = text, !t.isEmpty else { return }
            self.transcript = t
            self.onTranscript?(t)
            self.liveUpdate(t)
        }
    }

    private func endMurmur() {
        isActive = false
        isProcessing = true
        liveTimer?.invalidate(); liveTimer = nil
        liveTranscriptionJob?.cancel(); liveTranscriptionJob = nil
        let audio = MurmurRecorder.shared.stop()
        let s = session
        onTranscript?(transcript.isEmpty ? "…" : transcript)
        // A long take is read in 30-second pieces by the model itself.
        transcriptionJob = Murmur.shared.transcribe(audio) { [weak self] text in
            guard let self = self, s == self.session else { return }
            guard let text else {
                self.lastUninsertedText = self.transcript.isEmpty ? nil : self.transcript
                self.cancel()
                self.onDone?("Couldn’t finish transcription · check speech setup in Permissions & Diagnostics")
                return
            }
            self.transcript = text
            self.deliver()
        }
        guard isProcessing, session == s else { return }
        finishWork?.cancel()
        let take = session
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.session == take, self.isProcessing else { return }
            self.lastUninsertedText = self.transcript.isEmpty ? nil : self.transcript
            self.cancel()
            self.onDone?("Transcription timed out · partial text is in Permissions & Diagnostics")
        }
        finishWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
    }

    /// Key released: stop the microphone and wait (≤ 1.5 s) for the final words.
    private func end() {
        if usingMurmur { endMurmur(); return }
        isActive = false
        isProcessing = true
        SpeechListener.shared.finish()
        finishWork?.cancel()
        let take = session
        let w = DispatchWorkItem { [weak self] in guard let self, self.session == take else { return }; self.deliver() }
        finishWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func cancel(resumeApprovals: Bool = true) {
        session += 1
        transcriptionJob?.cancel(); transcriptionJob = nil
        liveTranscriptionJob?.cancel(); liveTranscriptionJob = nil
        liveBusy = false
        isProcessing = false
        cancelled = true
        isActive = false
        finishWork?.cancel(); finishWork = nil
        if usingMurmur {
            session += 1
            liveTimer?.invalidate(); liveTimer = nil
            MurmurRecorder.shared.stop()
            usingMurmur = false
        }
        SpeechListener.shared.stop()
        onTranscript?(nil)
        typingTarget = nil
        onDone?(typed.isEmpty ? "Dictation cancelled" : "Stopped · kept what was typed")
        if resumeApprovals { VoiceApproval.shared.resumeAfterDictation() }
    }

    private func deliver() {
        finishWork?.cancel(); finishWork = nil
        guard !cancelled else { return }
        defer { VoiceApproval.shared.resumeAfterDictation() }
        cancelled = true            // once per session
        isProcessing = false
        transcriptionJob?.cancel(); transcriptionJob = nil
        liveTranscriptionJob?.cancel(); liveTranscriptionJob = nil
        liveBusy = false
        isActive = false
        if usingMurmur {
            usingMurmur = false
            session += 1
            liveTimer?.invalidate(); liveTimer = nil
            if MurmurRecorder.shared.isRunning { MurmurRecorder.shared.stop() }
        }
        SpeechListener.shared.stop()
        onTranscript?(nil)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        Diag.log("dictation: delivered \(text.split(separator: " ").count) words")
        guard !text.isEmpty else { onDone?("Didn't catch that"); return }
        let result: Bool
        if !typed.isEmpty {
            result = liveFinish(text)
        } else {
            let insertion = typingTarget?.insert(text) ?? .unavailable
            if insertion == .sent { sentTypingEvents = true }
            Diag.log("dictation: final insertion \(insertion)")
            result = insertion != .unavailable
        }
        typingTarget = nil
        guard result else {
            lastUninsertedText = text
            Diag.log("dictation: original field unavailable; transcript retained without changing clipboard")
            onDone?("Original field changed · recover text in Settings → Permissions & Diagnostics")
            return
        }
        lastUninsertedText = nil
        let count = text.split(separator: " ").count
        onDone?(sentTypingEvents ? "Sent \(count) words to the field" : "Typed \(count) words")
    }

    // MARK: Typing keystrokes

    /// Existing self-test entry point, using the same target-bound insertion as dictation.
    /// The clipboard is never touched.
    static func typeKeys(_ text: String) {
        _ = DictationInsertionTarget.capture()?.insert(text)
    }

    // MARK: Recovering text when insertion is unavailable

    func copyUninsertedText() {
        guard let text = lastUninsertedText else { return }
        NSPasteboard.general.setPlainText(text)
    }

}
