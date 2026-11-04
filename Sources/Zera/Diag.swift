import AppKit

// MARK: - Diagnostics log
//
// A small local log of what the keyboard listener, dictation and Murmur did (which modifier
// key went down, whether a hold started dictation, why it didn't). Never what you type or say:
// only key codes of modifier keys and states. ~/Library/Application Support/Zera/diag.log,
// trimmed to its last 200 KB. The local build script copies it into the project for debugging.
enum Diag {
    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("diag.log")
    }()
    private static let queue = DispatchQueue(label: "zera.diag")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                let size = h.offsetInFile
                try? h.close()
                if size > 200_000, let all = try? Data(contentsOf: url) {
                    try? all.suffix(100_000).write(to: url)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - Secure input watch
//
// When another app turns on Secure Keyboard Entry (a password field, a login or keychain prompt,
// Terminal's setting), macOS hides every key from Zera: shortcuts don't echo and the dictation
// key does nothing. This notices it (every 4 s, a cheap call) and, if it lasts, says so in the
// notch once per episode, naming the app.
final class SecureInputWatch {
    static let shared = SecureInputWatch()
    private var timer: Timer?
    private var onSince: Date?
    private var warned = false
    /// Shows the notice (set by the controller).
    var onNotice: ((String) -> Void)?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// The app holding secure input, when there is one.
    static var holder: String? {
        guard GlobalKeys.secureInputOn else { return nil }
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let pid = dict["kCGSSessionSecureInputPID"] as? Int32 ?? (dict["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
           let app = NSRunningApplication(processIdentifier: pid) {
            return app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
        }
        return "another app"
    }

    private func tick() {
        // Missing keyboard access is explained in Settings. A stale preflight result must
        // not raise a startup notice over ordinary feedback; secure-input notices stay here.
        guard let who = Self.holder else {
            if onSince != nil { Diag.log("secure input off") }
            onSince = nil; warned = false
            return
        }
        if onSince == nil { onSince = Date(); Diag.log("secure input ON, held by \(who)") }
        guard !warned, let since = onSince, Date().timeIntervalSince(since) > 8 else { return }
        warned = true
        let name = who == "SecurityAgent" ? "a macOS password prompt" : who
        onNotice?("Keys hidden by \(name) — answer or close it")
    }
}
