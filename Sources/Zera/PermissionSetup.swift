import AppKit
import ApplicationServices
import AVFoundation
import Speech

enum PermissionAccess {
    enum Kind { case accessibility, screen, speech }
    enum Status: String { case allowed = "Allowed", undecided = "Not requested", denied = "Not allowed" }
    static func status(authorized: Bool, determined: Bool) -> Status {
        authorized ? .allowed : (determined ? .denied : .undecided)
    }
    static var screenNeeded: Bool {
        MainActor.assumeIsolated { WindowArrangementService.shared.settings.visualTransitions == true }
    }
    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

/// Shared first-run and repair controls. Poll only while attached to a visible window;
/// TCC has no general public change notification. Never request access from refresh().
final class PermissionSetupView: NSView {
    let kind: PermissionAccess.Kind
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let actionButton: CardButton
    private let modelButton: CardButton
    private let providerRow = FlippedView()
    private let provider = ZeraSelect(["Murmur · on this Mac", "Apple speech"])
    private let progress = NSProgressIndicator()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    override var isFlipped: Bool { true }
    var preferredHeight: CGFloat { kind == .speech ? 280 : 180 }

    init(kind: PermissionAccess.Kind) {
        self.kind = kind
        actionButton = CardButton("Allow access", style: .secondary, target: nil, action: #selector(requestAccess))
        modelButton = CardButton("Download model", style: .secondary, target: nil, action: #selector(modelTapped))
        super.init(frame: .zero)
        title.font = Typo.paneTitle; title.textColor = Pal.text
        detail.font = Typo.body; detail.textColor = Pal.textSecondary
        status.font = Typo.caption; status.textColor = Pal.textSecondary
        actionButton.target = self; modelButton.target = self
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        provider.select(Murmur.shared.useForDictation ? 0 : 1)
        provider.setAccessibilityLabel("Speech provider")
        provider.onChange = { [weak self] i in
            // Selecting a provider never starts a download or permission prompt.
            Murmur.shared.useForDictation = i == 0
            self?.refresh()
        }
        providerRow.frame = NSRect(x: 0, y: 0, width: 280, height: 32)
        provider.frame = providerRow.bounds
        providerRow.addSubview(provider)
        [title, detail, status, actionButton, providerRow, modelButton, progress].forEach(addSubview)
        observer = NotificationCenter.default.addObserver(forName: Murmur.stateChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        refresh()
        guard window != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.refresh()
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    func refresh() {
        let speech = kind == .speech
        provider.select(Murmur.shared.useForDictation ? 0 : 1)
        providerRow.isHidden = !speech; modelButton.isHidden = !speech || !Murmur.shared.useForDictation
        progress.isHidden = true
        actionButton.isEnabled = true
        switch kind {
        case .accessibility:
            title.stringValue = "Accessibility"
            detail.stringValue = "Optional · arrange windows and insert dictation into editable fields. Enable Zera in System Settings; access can’t be granted here."
            let allowed = AXIsProcessTrusted()
            status.stringValue = allowed ? "Allowed · window and text access is ready" : "Not allowed · existing grants may need Zera to be restarted after an update"
            actionButton.setTitleText(allowed ? "Open Accessibility settings" : "Set up Accessibility")
        case .screen:
            title.stringValue = "Screen Recording"
            detail.stringValue = "Optional · used only for window image transitions. Native window positioning works without it. Captures stay in memory."
            status.stringValue = CGPreflightScreenCaptureAccess() ? "Allowed for this process" : (PermissionAccess.screenNeeded ? "Not allowed · macOS may require a restart after granting access" : "Not needed · visual transitions are off")
            actionButton.setTitleText("Open Screen Recording settings")
        case .speech:
            title.stringValue = "Microphone & speech"
            detail.stringValue = "Optional · hold the dictation key to speak, release to insert into the original field. Choose a provider; Murmur needs one model download."
            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            let speechAuth = SFSpeechRecognizer.authorizationStatus()
            let micStatus = PermissionAccess.status(authorized: mic == .authorized, determined: mic != .notDetermined).rawValue
            let providerStatus = Murmur.shared.useForDictation ? Murmur.shared.state.summary : "Apple speech: \(PermissionAccess.status(authorized: speechAuth == .authorized, determined: speechAuth != .notDetermined).rawValue)"
            status.stringValue = "Microphone: \(micStatus) · \(providerStatus)"
            actionButton.setTitleText(mic == .authorized && (Murmur.shared.useForDictation || speechAuth == .authorized) ? "Open microphone settings" : "Allow microphone & speech")
            modelButton.setTitleText(Murmur.shared.isBusy ? "Cancel setup" : Murmur.shared.isReady ? "Model ready" : "Download / retry model")
            modelButton.isEnabled = !Murmur.shared.isReady && !Murmur.shared.isRemoving
            if case .downloading(let value) = Murmur.shared.state { progress.isHidden = false; progress.doubleValue = value }
            if case .loading = Murmur.shared.state { progress.isHidden = false; progress.doubleValue = 1 }
        }
        needsLayout = true
    }

    @objc private func requestAccess() {
        switch kind {
        case .accessibility:
            if AXIsProcessTrusted() { PermissionAccess.openPrivacy("Privacy_Accessibility") }
            else { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
        case .screen:
            // Never request capture for a disabled feature.
            if PermissionAccess.screenNeeded && !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            else { PermissionAccess.openPrivacy("Privacy_ScreenCapture") }
        case .speech:
            if Murmur.shared.useForDictation {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { MurmurRecorder.askForMic { [weak self] _ in self?.refresh() } }
                else { PermissionAccess.openPrivacy("Privacy_Microphone") }
            } else if SpeechListener.isAuthorized { PermissionAccess.openPrivacy("Privacy_Microphone") }
            else if AVCaptureDevice.authorizationStatus(for: .audio) == .denied { PermissionAccess.openPrivacy("Privacy_Microphone") }
            else if SFSpeechRecognizer.authorizationStatus() == .denied { PermissionAccess.openPrivacy("Privacy_SpeechRecognition") }
            else { SpeechListener.authorize { [weak self] _ in self?.refresh() } }
        }
        refresh()
    }
    @objc private func modelTapped() {
        if Murmur.shared.isBusy { Murmur.shared.cancelDownload() }
        else { Murmur.shared.download(Murmur.shared.model) }
        refresh()
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        title.frame = NSRect(x: 0, y: 0, width: width, height: 26)
        detail.frame = NSRect(x: 0, y: 34, width: width, height: 56)
        status.frame = NSRect(x: 0, y: 96, width: width, height: 36)
        if kind == .speech {
            providerRow.frame = NSRect(x: 0, y: 140, width: min(width, 280), height: 32)
            provider.frame = providerRow.bounds
            actionButton.frame = NSRect(x: 0, y: 184, width: min(width, 260), height: 32)
            modelButton.frame = NSRect(x: 0, y: 228, width: min(width, 260), height: 32)
            progress.frame = NSRect(x: min(width, 280), y: 240, width: max(0, width - 280), height: 8)
        } else { actionButton.frame = NSRect(x: 0, y: 140, width: min(width, 280), height: 32) }
    }
}
