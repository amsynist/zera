import Foundation

// MARK: - What this Mac's Claude Code can do
//
// System B (Zera's file assistant) talks to the `claude` CLI in print mode. Nothing here
// touches credentials: we only ask the CLI where it is, which flags it has, and whether it
// says it is logged in. The answer is cached for a few minutes so Settings can show it
// without re-running anything, and refreshed on demand ("Test Claude").

/// Flags Zera relies on, discovered from `claude --help` so nothing is assumed about the
/// installed version. Anything missing degrades gracefully (see `ClaudeCLI.arguments`).
struct ClaudeCLICapabilities: Equatable {
    var print = false                   // -p
    var outputFormat = false            // --output-format text|json|stream-json
    var streamJSON = false              // "stream-json" listed as a choice
    var partialMessages = false         // --include-partial-messages (token streaming)
    var resume = false                  // --resume <id>
    var sessionID = false               // --session-id <uuid>
    var tools = false                   // --tools (restrict built-in tools)
    var allowedTools = false            // --allowedTools
    var disallowedTools = false         // --disallowedTools
    var permissionPrompts = false       // --permission-prompts none
    var permissionMode = false          // --permission-mode
    var maxTurns = false                // --max-turns
    var systemPrompt = false            // --system-prompt
    var strictMCP = false               // --strict-mcp-config
    var noSessionPersistence = false    // --no-session-persistence
    var name = false                    // --name
    var model = false                   // --model
    var verbose = false                 // --verbose
    var authStatus = false              // `claude auth status`

    /// The minimum for in-app analysis: print mode with machine-readable output.
    var programmaticOK: Bool { print && outputFormat }
    /// True streaming (deltas as they arrive) rather than one message at the end.
    var streamingOK: Bool { programmaticOK && streamJSON && partialMessages }

    /// Parses the text of `claude --help`.
    static func parse(help: String) -> ClaudeCLICapabilities {
        var c = ClaudeCLICapabilities()
        func has(_ flag: String) -> Bool {
            // Flags are listed at the start of a line or after a comma ("-p, --print").
            help.range(of: "(^|[\\s,])\(NSRegularExpression.escapedPattern(for: flag))(\\s|,|$)",
                       options: .regularExpression) != nil
        }
        c.print = has("--print") || has("-p")
        c.outputFormat = has("--output-format")
        c.streamJSON = c.outputFormat && help.contains("stream-json")
        c.partialMessages = has("--include-partial-messages")
        c.resume = has("--resume")
        c.sessionID = has("--session-id")
        c.tools = has("--tools")
        c.allowedTools = has("--allowedTools") || has("--allowed-tools")
        c.disallowedTools = has("--disallowedTools") || has("--disallowed-tools")
        c.permissionPrompts = has("--permission-prompts")
        c.permissionMode = has("--permission-mode")
        c.maxTurns = has("--max-turns")
        c.systemPrompt = has("--system-prompt")
        c.strictMCP = has("--strict-mcp-config")
        c.noSessionPersistence = has("--no-session-persistence")
        c.name = has("--name")
        c.model = has("--model")
        c.verbose = has("--verbose")
        // Subcommands are listed under "Commands:" as "  auth   Manage authentication".
        if let r = help.range(of: "Commands:") {
            c.authStatus = help[r.upperBound...].range(of: "(?m)^\\s+auth\\b", options: .regularExpression) != nil
        }
        return c
    }
}

/// What Settings shows next to "Claude Code".
enum ClaudeCLIStatus: Equatable {
    case unknown              // not checked yet
    case checking
    case notDetected          // no executable found
    case programmaticUnavailable(String)  // found, but print mode / output format missing or broken
    case needsAuth            // found, but `auth status` says logged out
    case connected

    var label: String {
        switch self {
        case .unknown: return "Not checked"
        case .checking: return "Checking…"
        case .notDetected: return "Not detected"
        case .programmaticUnavailable: return "Programmatic execution unavailable"
        case .needsAuth: return "Authentication required"
        case .connected: return "Connected"
        }
    }

    var connection: ConnectionState {
        switch self {
        case .unknown: return .disconnected
        case .checking: return .connecting
        case .notDetected: return .disconnected
        case .programmaticUnavailable: return .error
        case .needsAuth: return .needsAuth
        case .connected: return .connected
        }
    }
}

/// Everything we learned about the installation.
struct ClaudeCLIInfo: Equatable {
    var executable: URL?
    var version: String?
    var capabilities = ClaudeCLICapabilities()
    var loggedIn: Bool?          // nil = could not determine (old CLI without `auth status`)
    var authMethod: String?      // "oauth_token", "api_key", "claude_ai", … as the CLI reports it
    var apiProvider: String?     // "firstParty", "bedrock", "vertex", …
    var status: ClaudeCLIStatus = .unknown
    var checkedAt: Date?
    var lastError: String?

    var executableDisplay: String {
        guard let e = executable else { return "Not found" }
        let home = NSHomeDirectory()
        return e.path.hasPrefix(home) ? "~" + e.path.dropFirst(home.count) : e.path
    }
}

/// Discovers and probes the Claude Code CLI. Thread-safe: probing runs on a background queue,
/// results are published on the main thread through `changed`.
final class ClaudeCLI {
    static let shared = ClaudeCLI()

    nonisolated static let changed = Notification.Name("ZeraClaudeCLIChanged")
    private static let overrideKey = "zera.claude.executable"
    private static let cacheTTL: TimeInterval = 10 * 60

    private let queue = DispatchQueue(label: "ai.zera.claude-cli", qos: .userInitiated)
    private let lock = NSLock()
    private var _info = ClaudeCLIInfo()
    private var probing = false
    private var waiters: [@MainActor (ClaudeCLIInfo) -> Void] = []

    /// The last probe result (may be stale; see `checkedAt`).
    var info: ClaudeCLIInfo {
        lock.lock(); defer { lock.unlock() }
        return _info
    }

    /// A path the user typed into Settings → Claude → Advanced. Empty = discover automatically.
    var executableOverride: String {
        get { UserDefaults.standard.string(forKey: Self.overrideKey) ?? "" }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: Self.overrideKey) }
            else { UserDefaults.standard.set(v, forKey: Self.overrideKey) }
            invalidate()
        }
    }

    private init() {}

    func invalidate() {
        lock.lock(); _info.checkedAt = nil; lock.unlock()
    }

    /// Fresh enough to use without re-probing.
    var isFresh: Bool {
        guard let t = info.checkedAt else { return false }
        return Date().timeIntervalSince(t) < Self.cacheTTL
    }

    /// Runs the probe (or returns the cached result) and calls back on the main actor.
    func ensureProbed(force: Bool = false, _ completion: @escaping @MainActor (ClaudeCLIInfo) -> Void) {
        if !force, isFresh {
            let i = info
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(i) } }
            return
        }
        lock.lock()
        waiters.append(completion)
        if probing { lock.unlock(); return }
        probing = true
        _info.status = .checking
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = self.probe()
            self.lock.lock()
            self._info = result
            self.probing = false
            let ws = self.waiters
            self.waiters = []
            self.lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.changed, object: nil)
                MainActor.assumeIsolated { ws.forEach { $0(result) } }
            }
        }
    }

    // MARK: - Discovery

    /// Where `claude` might be, most specific first. Nothing is assumed: every candidate is
    /// checked for an executable file before use.
    func candidatePaths() -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if !executableOverride.isEmpty { out.append(URL(fileURLWithPath: (executableOverride as NSString).expandingTildeInPath)) }
        // The user's shell PATH (login + interactive, so nvm/volta/homebrew shims count).
        for dir in ShellEnvironment.shared.path {
            out.append(URL(fileURLWithPath: dir).appendingPathComponent("claude"))
        }
        // Known installer locations.
        let known = [
            ".claude/local/claude",          // `claude install` (native, older layout)
            ".local/bin/claude",             // `claude install` (native)
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            ".npm-global/bin/claude", ".volta/bin/claude", ".bun/bin/claude", ".yarn/bin/claude",
        ]
        for k in known { out.append(k.hasPrefix("/") ? URL(fileURLWithPath: k) : home.appendingPathComponent(k)) }
        // nvm / fnm keep one bin dir per Node version.
        for versions in [home.appendingPathComponent(".nvm/versions/node"),
                         home.appendingPathComponent("Library/Application Support/fnm/node-versions")] {
            if let names = try? fm.contentsOfDirectory(atPath: versions.path) {
                for n in names.sorted().reversed() {
                    out.append(versions.appendingPathComponent(n).appendingPathComponent("bin/claude"))
                    out.append(versions.appendingPathComponent(n).appendingPathComponent("installation/bin/claude"))
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func findExecutable() -> URL? {
        let fm = FileManager.default
        for url in candidatePaths() {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    // MARK: - Probe

    private func probe() -> ClaudeCLIInfo {
        var info = ClaudeCLIInfo()
        info.checkedAt = Date()
        guard let exe = findExecutable() else {
            info.status = .notDetected
            return info
        }
        info.executable = exe
        let env = ShellEnvironment.shared.environment(extra: [:])

        // 1. Version — also proves the binary runs at all from a GUI app's environment.
        let v = ProcessRunner.run(exe, ["--version"], environment: env, timeout: 15)
        guard v.status == 0 || !v.stdout.isEmpty else {
            info.status = .programmaticUnavailable("`claude --version` failed: \(v.stderr.isEmpty ? "exit \(v.status)" : String(v.stderr.prefix(160)))")
            info.lastError = v.stderr
            return info
        }
        info.version = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init)?
            .replacingOccurrences(of: "(Claude Code)", with: "").trimmingCharacters(in: .whitespaces)

        // 2. Flags.
        let h = ProcessRunner.run(exe, ["--help"], environment: env, timeout: 15)
        info.capabilities = ClaudeCLICapabilities.parse(help: h.stdout + "\n" + h.stderr)
        guard info.capabilities.programmaticOK else {
            info.status = .programmaticUnavailable("This Claude Code build has no print mode with machine-readable output.")
            return info
        }

        // 3. Authentication — the CLI's own answer, no credentials read. Old builds without
        //    `auth status` leave this unknown and we find out on the first real request.
        if info.capabilities.authStatus {
            let a = ProcessRunner.run(exe, ["auth", "status", "--json"], environment: env, timeout: 15)
            if let data = a.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                info.loggedIn = json["loggedIn"] as? Bool
                info.authMethod = json["authMethod"] as? String
                info.apiProvider = json["apiProvider"] as? String
            } else if a.status != 0 {
                // Some builds exit non-zero when logged out and print text instead of JSON.
                let text = (a.stdout + a.stderr).lowercased()
                if text.contains("not logged in") || text.contains("logged out") || text.contains("login") { info.loggedIn = false }
            }
        }
        if info.loggedIn == false {
            info.status = .needsAuth
        } else {
            info.status = .connected
        }
        return info
    }
}

// MARK: - Login-shell environment

/// A GUI app inherits a bare PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so `claude`, `node`,
/// nvm shims and the user's `ANTHROPIC_*` / enterprise variables are invisible. We ask the
/// user's login shell once for its environment and keep a filtered copy — never printed, and
/// only the keys Claude Code itself is documented to read plus what a process needs to run.
final class ShellEnvironment {
    static let shared = ShellEnvironment()

    private let lock = NSLock()
    private var captured: [String: String]?

    /// Variable prefixes carried over from the login shell.
    static let allowedPrefixes = ["ANTHROPIC_", "CLAUDE_CODE_", "AWS_", "GOOGLE_", "CLOUD_ML_", "VERTEX_", "AZURE_",
                                  "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
                                  "NODE_", "NVM_", "VOLTA_", "SSL_CERT_", "LC_", "XDG_"]
    static let allowedKeys: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR", "TERM",
                                           "DISABLE_AUTOUPDATER", "DISABLE_TELEMETRY", "MAX_THINKING_TOKENS",
                                           "API_TIMEOUT_MS", "BASH_DEFAULT_TIMEOUT_MS"]
    /// Session markers a parent Claude Code process sets. Never forwarded, so Zera's requests
    /// cannot be mistaken for a nested session of something else that is running.
    static let blockedKeys: Set<String> = ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
                                           "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_REMOTE", "CLAUDE_CODE_REMOTE_SESSION_ID"]

    private init() {}

    /// The merged environment to launch `claude` with.
    func environment(extra: [String: String]) -> [String: String] {
        var env = base()
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// PATH entries, user shell first.
    var path: [String] {
        let p = base()["PATH"] ?? ""
        return p.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private func base() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let c = captured { return c }
        let c = Self.capture()
        captured = c
        return c
    }

    func refresh() { lock.lock(); captured = nil; lock.unlock() }

    private static func filtered(_ raw: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in raw {
            if blockedKeys.contains(k) { continue }
            if allowedKeys.contains(k) || allowedPrefixes.contains(where: { k.hasPrefix($0) }) { out[k] = v }
        }
        return out
    }

    private static func capture() -> [String: String] {
        let process = ProcessInfo.processInfo.environment
        var env = filtered(process)
        let shell = process["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        // Interactive login shell, like an editor does, so ~/.zshrc exports count too. A
        // sentinel separates the environment from anything the profile prints.
        let sentinel = "__ZERA_ENV_\(UInt32.random(in: 0...UInt32.max))__"
        let r = ProcessRunner.run(URL(fileURLWithPath: shell), ["-l", "-i", "-c", "printf '\\n\(sentinel)\\n'; /usr/bin/env"],
                                  environment: process, timeout: 8, currentDirectory: URL(fileURLWithPath: NSHomeDirectory()))
        if let range = r.stdout.range(of: sentinel + "\n") {
            var fromShell: [String: String] = [:]
            for line in r.stdout[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: true) {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let k = String(line[..<eq]), v = String(line[line.index(after: eq)...])
                guard !k.isEmpty, !k.contains(" ") else { continue }
                fromShell[k] = v
            }
            for (k, v) in filtered(fromShell) { env[k] = v }
        }
        // Make sure the usual bins are on PATH even if the shell did not answer.
        var parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for p in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                  NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.claude/local"] where !parts.contains(p) {
            parts.append(p)
        }
        env["PATH"] = parts.joined(separator: ":")
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["TERM"] = env["TERM"] ?? "dumb"
        return env
    }
}

// MARK: - One-shot process runs

/// Runs a short command to completion with a timeout, capturing both streams. For the
/// probes only; the streaming assistant uses `ClaudeProcessManager`.
enum ProcessRunner {
    struct Result { var status: Int32; var stdout: String; var stderr: String; var timedOut: Bool }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval, currentDirectory: URL? = nil, stdin: Data? = nil) -> Result {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = environment
        if let d = currentDirectory { p.currentDirectoryURL = d }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); group.enter()
        let q = DispatchQueue.global(qos: .userInitiated)
        q.async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        q.async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        
        let semaphore = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in semaphore.signal() }
        
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
        if let d = stdin {
            inPipe.fileHandleForWriting.write(d)
            try? inPipe.fileHandleForWriting.close()
        }
        
        var timedOut = false
        let deadline = DispatchTime.now() + timeout
        if semaphore.wait(timeout: deadline) == .timedOut {
            timedOut = true
            p.terminate()
            if semaphore.wait(timeout: .now() + 2) == .timedOut {
                _ = kill(p.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 2)
            }
        }
        _ = group.wait(timeout: .now() + 2)
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self),
                      timedOut: timedOut)
    }
}
