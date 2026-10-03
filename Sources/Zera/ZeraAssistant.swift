import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - System B: Zera's file assistant
//
// Summarize / Explain / Extract / Ask on a shelf item, entirely inside Zera. Independent from
// the Claude Code *hook* integration (System A, `ClaudeHookService`), which only relays
// permission prompts from the user's own coding sessions.
//
// Provider order: the user's existing Claude Code CLI (print mode, their own login — no key
// ever leaves the CLI), or, if they chose it in Settings, the Anthropic API with a key from
// the Keychain. There is no silent fallback from one to the other.

/// What you can ask about a file.
enum FileAction: Equatable {
    case summarize, explain, extract, ask(String)

    var title: String {
        switch self {
        case .summarize: return "Summary"
        case .explain: return "Explanation"
        case .extract: return "Extracted text"
        case .ask: return "Answer"
        }
    }
    var verb: String {
        switch self {
        case .summarize: return "Summarizing"
        case .explain: return "Explaining"
        case .extract: return "Extracting text from"
        case .ask: return "Thinking about"
        }
    }
    var symbol: String {
        switch self {
        case .summarize: return "sparkles"
        case .explain: return "text.magnifyingglass"
        case .extract: return "doc.text"
        case .ask: return "questionmark.bubble"
        }
    }
}

/// Every word Zera sends to Claude lives here.
enum ZeraPrompts {
    static let system = """
    You are Zera's file assistant on a Mac. The user dropped a file onto Zera and asked about it. \
    Work only from the file you were given; if something is not in it, say so. Answer in Markdown \
    with short headings and bullet lists where they help, no preamble, no sign-off. Never run commands \
    or modify anything.
    """

    static let summarize = """
    Summarize this file clearly and concisely. Highlight key points, important decisions, numbers, \
    action items, and conclusions.
    """
    static let explain = """
    Explain this file in clear language. Preserve important technical meaning while making the \
    explanation easy to understand.
    """
    static let extract = """
    Extract the meaningful text from this file. Preserve useful structure and do not add interpretation.
    """

    static func instruction(for action: FileAction) -> String {
        switch action {
        case .summarize: return summarize
        case .explain: return explain
        case .extract: return extract
        case .ask(let q): return q
        }
    }

    /// Prompt for a file Claude Code reads itself with its Read tool.
    static func readPathPrompt(action: FileAction, path: String, kind: FilePayload.Kind) -> String {
        let what: String
        switch kind {
        case .pdf: what = "PDF"
        case .image: what = "image"
        default: what = "file"
        }
        return "Read the \(what) at \(path) with the Read tool (use the pages parameter in batches if it is long), then: \(instruction(for: action))"
    }

    /// Prompt + content for text Zera already extracted.
    static func inlinePrompt(action: FileAction, fileName: String, text: String, truncated: Bool) -> String {
        var s = instruction(for: action)
        s += "\n\n--- File: \(fileName)"
        if truncated { s += " (only the beginning is included; it was too large to send whole)" }
        s += " ---\n" + text + "\n--- End of file ---"
        return s
    }
}

// MARK: - What a file becomes before it is sent

/// How a dropped file is handed to Claude. Built only when the user picks an action — never
/// at drop time — and the original is never modified.
struct FilePayload {
    enum Kind: Equatable { case text, markdown, code, pdf, image, document, link, folder, other }
    enum Mode: Equatable {
        /// Text Zera read (or extracted) itself.
        case inlineText(String, truncated: Bool)
        /// Claude Code reads it with its Read tool (PDF pages, images, very large text).
        case readPath
    }

    let url: URL
    let kind: Kind
    let mode: Mode
    let byteCount: Int64
    let pageCount: Int?

    var fileName: String { url.lastPathComponent }

    /// Needs Claude Code's Read tool (vs. everything already being in the prompt).
    var needsReadTool: Bool { mode == .readPath }

    static let inlineLimit = 400_000            // characters sent inline
    static let maxFileBytes: Int64 = 50 * 1024 * 1024
    static let maxImageBytes: Int64 = 20 * 1024 * 1024
    static let minPDFTextChars = 200            // less than this = probably scanned → vision

    enum BuildError: LocalizedError {
        case missing, folder, tooLarge, unreadable, link, unsupported(String)
        var errorDescription: String? {
            switch self {
            case .missing: return "I couldn't find this file any more."
            case .folder: return "That's a folder — drop a file instead."
            case .tooLarge: return "This file is too large for me (50 MB max)."
            case .unreadable: return "I couldn't read this file."
            case .link: return "I can't read links yet — open it in your browser."
            case .unsupported(let ext): return "I can't read .\(ext) files yet."
            }
        }
    }

    static func build(for url: URL) throws -> FilePayload {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw BuildError.missing }
        if isDir.boolValue {
            // .rtfd and other bundles are directories to the file system.
            let ext = url.pathExtension.lowercased()
            if ext == "rtfd" { return try textutil(url, kind: .document) }
            throw BuildError.folder
        }
        guard fm.isReadableFile(atPath: url.path) else { throw BuildError.unreadable }
        let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxFileBytes else { throw BuildError.tooLarge }

        let ext = url.pathExtension.lowercased()
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: ext)

        if ext == "webloc" || ext == "url" { throw BuildError.link }

        if let t = type, t.conforms(to: .pdf) || ext == "pdf" {
            return try pdf(url, size: size)
        }
        if let t = type, t.conforms(to: .image) {
            guard size <= maxImageBytes else { throw BuildError.tooLarge }
            return FilePayload(url: url, kind: .image, mode: .readPath, byteCount: size, pageCount: nil)
        }
        if ["rtf", "doc", "docx", "odt", "html", "htm", "webarchive", "wordml"].contains(ext) {
            return try textutil(url, kind: .document)
        }
        if let t = type, t.conforms(to: .text) || t.conforms(to: .sourceCode) || t.conforms(to: .json) || t.conforms(to: .xml)
            || t.conforms(to: .yaml) || t.conforms(to: .propertyList) || t.conforms(to: .shellScript) || t.conforms(to: .script) {
            return try text(url, size: size, kind: textKind(ext, type: t))
        }
        if Self.textExtensions.contains(ext) || looksLikeText(url) {
            return try text(url, size: size, kind: textKind(ext, type: type))
        }
        throw BuildError.unsupported(ext.isEmpty ? "unknown" : ext)
    }

    private static let textExtensions: Set<String> = ["md", "markdown", "txt", "text", "log", "csv", "tsv", "json", "jsonl", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "env", "xml", "plist", "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "java", "kt", "c", "h",
        "cpp", "hpp", "cs", "m", "mm", "sh", "zsh", "bash", "fish", "sql", "graphql", "proto", "html", "css", "scss", "less", "vue", "svelte",
        "dart", "php", "pl", "lua", "r", "jl", "tex", "bib", "rst", "adoc", "org", "diff", "patch", "lock", "gradle", "make", "cmake", "dockerfile"]

    private static func textKind(_ ext: String, type: UTType?) -> Kind {
        if ["md", "markdown"].contains(ext) { return .markdown }
        if let t = type, t.conforms(to: .sourceCode) || t.conforms(to: .script) { return .code }
        if ["txt", "text", "log", "csv", "tsv", "rst", "adoc", "org"].contains(ext) { return .text }
        return .code
    }

    /// Reads the first 8 KB: text if it decodes as UTF-8 and has (almost) no control bytes.
    private static func looksLikeText(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 8192)
        guard !head.isEmpty, String(data: head, encoding: .utf8) != nil else { return false }
        let control = head.filter { $0 < 9 || ($0 > 13 && $0 < 32) }.count
        return control * 100 < head.count
    }

    private static func text(_ url: URL, size: Int64, kind: Kind) throws -> FilePayload {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw BuildError.unreadable }
        var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var truncated = false
        if text.count > inlineLimit {
            text = String(text.prefix(inlineLimit))
            truncated = true
        }
        return FilePayload(url: url, kind: kind, mode: .inlineText(text, truncated: truncated), byteCount: size, pageCount: nil)
    }

    private static func pdf(_ url: URL, size: Int64) throws -> FilePayload {
        guard let doc = PDFDocument(url: url) else { throw BuildError.unreadable }
        let pages = doc.pageCount
        // A text layer is cheaper and more exact than pictures of pages; scanned PDFs have none.
        let extracted = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if extracted.count >= minPDFTextChars {
            var text = extracted
            var truncated = false
            if text.count > inlineLimit { text = String(text.prefix(inlineLimit)); truncated = true }
            return FilePayload(url: url, kind: .pdf, mode: .inlineText(text, truncated: truncated), byteCount: size, pageCount: pages)
        }
        return FilePayload(url: url, kind: .pdf, mode: .readPath, byteCount: size, pageCount: pages)
    }

    /// macOS's own converter for rich text / Word / HTML — a fixed argv, no shell.
    private static func textutil(_ url: URL, kind: Kind) throws -> FilePayload {
        let r = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/textutil"), ["-convert", "txt", "-stdout", url.path],
                                  environment: ["PATH": "/usr/bin:/bin"], timeout: 20)
        let text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !text.isEmpty else { throw BuildError.unreadable }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let truncated = text.count > inlineLimit
        return FilePayload(url: url, kind: kind, mode: .inlineText(truncated ? String(text.prefix(inlineLimit)) : text, truncated: truncated),
                           byteCount: size, pageCount: nil)
    }

    // MARK: API content

    /// The same file as Messages-API content blocks (for the API provider).
    func apiBlocks(action: FileAction) throws -> [APIContentBlock] {
        switch mode {
        case .inlineText(let text, let truncated):
            return [APIContentBlock(kind: .text(ZeraPrompts.inlinePrompt(action: action, fileName: fileName, text: text, truncated: truncated)))]
        case .readPath:
            switch kind {
            case .pdf:
                guard byteCount <= 30 * 1024 * 1024, (pageCount ?? 0) <= 100 else {
                    throw BuildError.unsupported("pdf this large (the API takes 100 pages / 30 MB)")
                }
                let data = try Data(contentsOf: url)
                return [APIContentBlock(kind: .pdfBase64(data: data.base64EncodedString())),
                        APIContentBlock(kind: .text(ZeraPrompts.instruction(for: action)))]
            case .image:
                let (media, data) = try Self.imageForAPI(url)
                return [APIContentBlock(kind: .imageBase64(media: media, data: data.base64EncodedString())),
                        APIContentBlock(kind: .text(ZeraPrompts.instruction(for: action)))]
            default:
                // Very large text: send what fits.
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let text = String(String(decoding: data, as: UTF8.self).prefix(Self.inlineLimit))
                return [APIContentBlock(kind: .text(ZeraPrompts.inlinePrompt(action: action, fileName: fileName, text: text, truncated: true)))]
            }
        }
    }

    /// Re-encodes to JPEG under the API's 5 MB / 8000 px limits when needed.
    private static func imageForAPI(_ url: URL) throws -> (String, Data) {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let media = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][ext]
        if let m = media, data.count <= 4_500_000, let img = NSImage(data: data), max(img.size.width, img.size.height) <= 7000 {
            return (m, data)
        }
        guard let img = NSImage(data: data), let tiff = img.tiffRepresentation, var rep = NSBitmapImageRep(data: tiff) else {
            throw BuildError.unreadable
        }
        let longest = max(rep.pixelsWide, rep.pixelsHigh)
        if longest > 1568 {
            let scale = 1568.0 / Double(longest)
            let w = Int(Double(rep.pixelsWide) * scale), h = Int(Double(rep.pixelsHigh) * scale)
            if let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
                img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
                rep = scaled
            }
        }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { throw BuildError.unreadable }
        return ("image/jpeg", jpeg)
    }
}

// MARK: - Sessions & state

/// One file, one conversation: the first action and any follow-up questions.
final class AnalysisSession {
    /// Also the Claude Code session id (`--session-id`). Rotated when a conversation cannot be
    /// resumed, because Claude Code refuses to start a second session under a used id.
    private(set) var id = UUID()
    /// nil = a general question from Home, no file involved.
    let payload: FilePayload?
    let startedAt = Date()
    private(set) var turns: [Turn] = []
    /// Messages for the API provider (kept in memory only).
    var apiMessages: [APIMessage] = []
    /// Set once Claude Code has actually created the session, so follow-ups may `--resume`.
    var claudeSessionReady = false

    enum Turn: Equatable {
        case request(FileAction)
        case answer(String)
        case failure(String)
    }

    init(payload: FilePayload?) { self.payload = payload }
    func rotateSessionID() { id = UUID(); claudeSessionReady = false }
    var fileName: String { payload?.fileName ?? "Zera" }
    var isGeneral: Bool { payload == nil }
    func append(_ t: Turn) { turns.append(t) }
}

/// What went wrong, and the one thing the user can do about it.
struct ZeraAIError: Error, Equatable {
    enum Action: Equatable { case openClaudeSettings, configureAPIKey, updateAPIKey, retry, tryAgainFile, none }
    let message: String
    let action: Action
    var buttonTitle: String? {
        switch action {
        case .openClaudeSettings: return "Open Claude Settings"
        case .configureAPIKey: return "Configure API Key"
        case .updateAPIKey: return "Update API Key"
        case .retry: return "Retry"
        case .tryAgainFile: return "Try Again"
        case .none: return nil
        }
    }
}

@MainActor
final class ZeraAssistant {
    static let shared = ZeraAssistant()

    nonisolated static let changed = Notification.Name("ZeraAssistantChanged")

    enum Provider: Int { case claudeCode, anthropicAPI }
    enum Phase: Equatable {
        case idle, starting, analyzing, streaming, done, failed(ZeraAIError), cancelled
        var isBusy: Bool { self == .starting || self == .analyzing || self == .streaming }
    }

    private static let providerKey = "zera.ai.provider"
    private static let timeoutKey = "zera.ai.timeout"
    private static let modelKey = "zera.ai.model"          // Claude Code --model (empty = CLI default)
    private static let maxOutputKey = "zera.ai.maxOutput"  // API max_tokens
    private static let debugKey = "zera.ai.debug"

    var provider: Provider {
        get { Provider(rawValue: UserDefaults.standard.integer(forKey: Self.providerKey)) ?? .claudeCode }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.providerKey); post() }
    }
    /// Seconds before a request is stopped. 60…900.
    var timeout: TimeInterval {
        get { let t = UserDefaults.standard.double(forKey: Self.timeoutKey); return t == 0 ? 180 : t }
        set { UserDefaults.standard.set(max(60, min(900, newValue)), forKey: Self.timeoutKey) }
    }
    /// Model alias for Claude Code (`--model`), empty = whatever the CLI is set to.
    var cliModel: String {
        get { UserDefaults.standard.string(forKey: Self.modelKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Self.modelKey) }
    }
    var maxOutputTokens: Int {
        get { let n = UserDefaults.standard.integer(forKey: Self.maxOutputKey); return n == 0 ? 2048 : n }
        set { UserDefaults.standard.set(max(256, min(16000, newValue)), forKey: Self.maxOutputKey) }
    }
    /// Keeps the CLI's stderr for the diagnostics pane. Never logs document text.
    var debugLogging: Bool {
        get { UserDefaults.standard.bool(forKey: Self.debugKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.debugKey) }
    }

    private(set) var phase: Phase = .idle { didSet { post() } }

    /// Where a running request is, for the processing panel's checklist.
    enum Stage: Int { case reading, analyzing, generating, done }
    var stage: Stage {
        switch phase {
        case .starting: return .reading
        case .analyzing: return .analyzing
        case .streaming: return .generating
        case .done: return .done
        case .idle, .failed, .cancelled: return .reading
        }
    }
    /// 0…1 for the progress bar: coarse by stage, then creeping with the text as it streams.
    var progress: Double {
        switch stage {
        case .reading: return 0.12
        case .analyzing: return 0.42
        case .generating:
            let n = Double(liveText?.count ?? 0)
            return min(0.95, 0.72 + n / 6000 * 0.23)
        case .done: return 1
        }
    }
    private(set) var session: AnalysisSession?
    private(set) var currentAction: FileAction?
    /// Text as it streams (committed + partial) — `nil` once `session.turns` has the answer.
    private(set) var liveText: String?
    private(set) var statusLine: String?
    private(set) var lastStderr = ""
    private(set) var lastRunSummary = ""
    /// Which provider actually served the last request.
    private(set) var activeProvider: Provider?

    private var handle: ClaudeProcessHandle?
    private var apiTask: Task<Void, Never>?
    private var builder = ClaudeTranscriptBuilder()
    private var postScheduled = false
    private var runGeneration = UUID()
    /// The file whose payload could not be built (so "Try Again" knows what to retry).
    private var failedFile: URL?
    private var pendingFileName: String?
    /// The file being worked on, even before its payload exists.
    var currentFileName: String? { session?.fileName ?? pendingFileName }

    private init() {}

    // MARK: Public API

    var isBusy: Bool { phase.isBusy }

    /// Summarize / Explain / Extract a shelf item. Starts a new session for that file.
    func run(_ action: FileAction, on url: URL) {
        if isBusy {
            // One at a time — a second click on the same thing is just impatience.
            post(); return
        }
        currentAction = action
        session = nil
        pendingFileName = url.lastPathComponent
        statusLine = "Reading \(url.lastPathComponent)…"
        liveText = nil
        phase = .starting
        let generation = UUID()
        runGeneration = generation
        // Text extraction (PDFKit, textutil) can take a moment on big files: off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try FilePayload.build(for: url) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.runGeneration == generation, self.phase == .starting else { return }
                    switch result {
                    case .failure(let error):
                        let msg = (error as? LocalizedError)?.errorDescription ?? "I couldn't read this file."
                        var action: ZeraAIError.Action = .none
                        if case .unreadable? = error as? FilePayload.BuildError { action = .tryAgainFile }
                        self.failedFile = url
                        self.fail(ZeraAIError(message: msg, action: action))
                    case .success(let payload):
                        let s = AnalysisSession(payload: payload)
                        self.session = s
                        s.append(.request(action))
                        self.start(action: action, session: s, resume: false)
                    }
                }
            }
        }
    }

    /// A question with no file (Home search box). Continues the current general chat if there
    /// is one, otherwise starts a fresh one — never a file session.
    func askGeneral(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isBusy else { post(); return }
        if let s = session, s.isGeneral { ask(q); return }
        let s = AnalysisSession(payload: nil)
        session = s
        pendingFileName = nil
        let action = FileAction.ask(q)
        currentAction = action
        s.append(.request(action))
        statusLine = "Thinking…"
        liveText = nil
        phase = .starting
        start(action: action, session: s, resume: false)
    }

    /// A follow-up about the file of the current session.
    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let s = session, !isBusy else { post(); return }
        let action = FileAction.ask(q)
        currentAction = action
        s.append(.request(action))
        statusLine = "Thinking…"
        liveText = nil
        phase = .starting
        start(action: action, session: s, resume: s.claudeSessionReady)
    }

    /// Run the last request again (after an error).
    func retry() {
        guard let a = currentAction, !isBusy else { return }
        guard let s = session else {
            if let f = failedFile { run(a, on: f) }
            return
        }
        // Drop the failure turn so the transcript reads cleanly.
        if case .failure? = s.turns.last { s.removeLast() }
        statusLine = "Reading \(s.fileName)…"
        liveText = nil
        phase = .starting
        start(action: a, session: s, resume: s.claudeSessionReady && !isFirstRequest(a, in: s))
    }

    func cancel() {
        guard isBusy else { return }
        handle?.cancel(); handle = nil
        apiTask?.cancel(); apiTask = nil
        statusLine = nil
        liveText = nil
        if let s = session, case .request? = s.turns.last { s.removeLast() }
        phase = .cancelled
    }

    func cancelAll() {
        cancel()
        ClaudeProcessManager.shared.cancelAll()
    }

    /// Forget the current file (closing the result panel).
    func clearSession() {
        guard !isBusy else { return }
        session = nil
        pendingFileName = nil
        currentAction = nil
        liveText = nil
        statusLine = nil
        phase = .idle
    }

    /// Saves text to the shelf as a note; returns true if it landed.
    @discardableResult
    func saveNote(_ text: String, title: String) -> Bool {
        let pb = NSPasteboard(name: NSPasteboard.Name("ai.zera.note"))
        pb.clearContents()
        pb.setString("# \(title)\n\n\(text)\n", forType: .string)
        return ShelfStore.shared.ingest(pasteboard: pb) > 0
    }

    /// The Settings button: proves the active provider end to end with a one-word request.
    func testConnection(_ completion: @escaping (Result<String, ZeraAIError>) -> Void) {
        switch provider {
        case .anthropicAPI:
            Task { @MainActor in
                do {
                    let models = try await AnthropicAPIClient.shared.testConnection()
                    completion(.success("API key works · \(models.count) models available"))
                } catch {
                    let e = error as? AnthropicAPIError
                    completion(.failure(ZeraAIError(message: e?.errorDescription ?? error.localizedDescription,
                                                    action: e?.kind == .authentication ? .updateAPIKey : .retry)))
                }
            }
        case .claudeCode:
            ClaudeCLI.shared.ensureProbed(force: true) { [weak self] info in
                guard let self = self else { return }
                if let err = Self.error(for: info) { completion(.failure(err)); return }
                guard let exe = info.executable else { completion(.failure(Self.error(for: ClaudeCLIInfo(status: .notDetected))!)); return }
                // A real, tiny request through the user's own login. Cheap, and the only way to
                // know for sure that print mode answers from this app's environment.
                let req = self.cliRequest(executable: exe, info: info,
                                          arguments: self.cliArguments(info.capabilities, needsRead: false, resume: false, sessionID: nil, name: nil),
                                          stdin: Data("Reply with exactly: OK".utf8), cwd: nil)
                var ok = false
                let h = ClaudeProcessManager.shared.launch(req)
                h.onEvent = { e in if case .completed(let r, _, _, _) = e, r.localizedCaseInsensitiveContains("ok") { ok = true } }
                h.onEnd = { [weak self] end, stderr in
                    guard let self = self else { return }
                    self.lastStderr = stderr
                    if ok { completion(.success("Claude Code answered · v\(info.version ?? "?")" + (info.capabilities.streamingOK ? " · streaming" : ""))) }
                    else {
                        let ev = ClaudeCodeOutputParser.failure(from: stderr, exitStatus: { if case .exited(let s) = end { return s } else { return 1 } }())
                        if case .failed(let m, let k) = ev { completion(.failure(Self.error(fromFailure: m, kind: k))) }
                    }
                }
            }
        }
    }

    // MARK: Provider selection

    /// Maps the CLI probe to the error the user should see, or nil when it is usable.
    nonisolated static func error(for info: ClaudeCLIInfo) -> ZeraAIError? {
        switch info.status {
        case .connected, .unknown, .checking: return nil
        case .notDetected: return ZeraAIError(message: "Claude Code isn't installed on this Mac.", action: .openClaudeSettings)
        case .needsAuth: return ZeraAIError(message: "Claude Code needs authentication. Run `claude` once in a terminal and sign in.", action: .openClaudeSettings)
        case .programmaticUnavailable: return ZeraAIError(message: "This Claude Code installation can't be used for background file analysis.", action: .configureAPIKey)
        }
    }

    nonisolated static func error(fromFailure message: String, kind: ClaudeFailureKind) -> ZeraAIError {
        switch kind {
        case .authentication: return ZeraAIError(message: message, action: .openClaudeSettings)
        case .network: return ZeraAIError(message: message, action: .retry)
        case .resumeMissing: return ZeraAIError(message: message, action: .retry)
        case .maxTurns, .budget, .malformed, .other: return ZeraAIError(message: message, action: .retry)
        }
    }

    private func isFirstRequest(_ a: FileAction, in s: AnalysisSession) -> Bool {
        s.turns.first == .request(a) && s.turns.count <= 1
    }

    private func start(action: FileAction, session s: AnalysisSession, resume: Bool) {
        builder = ClaudeTranscriptBuilder()
        switch provider {
        case .anthropicAPI:
            guard AnthropicAPIClient.shared.isConfigured else {
                fail(ZeraAIError(message: "Add an Anthropic API key to use the API, or switch back to Claude Code.", action: .configureAPIKey)); return
            }
            activeProvider = .anthropicAPI
            startAPI(action: action, session: s)
        case .claudeCode:
            ClaudeCLI.shared.ensureProbed { [weak self] info in
                guard let self = self, self.phase == .starting, self.session === s else { return }
                if let err = Self.error(for: info) { self.fail(err); return }
                self.activeProvider = .claudeCode
                self.startCLI(action: action, session: s, info: info, resume: resume)
            }
        }
    }

    // MARK: Claude Code path

    /// argv for print mode, built from what this CLI supports — never a shell string.
    func cliArguments(_ caps: ClaudeCLICapabilities, needsRead: Bool, resume: Bool, sessionID: UUID?, name: String?) -> [String] {
        var a: [String] = ["--print"]
        if caps.streamJSON {
            a += ["--output-format", "stream-json", "--verbose"]
            if caps.partialMessages { a.append("--include-partial-messages") }
        } else {
            a += ["--output-format", "json"]
        }
        if let sid = sessionID {
            if resume, caps.resume { a += ["--resume", sid.uuidString] }
            else if caps.sessionID { a += ["--session-id", sid.uuidString] }
        } else if caps.noSessionPersistence {
            a.append("--no-session-persistence")   // the connection test leaves no trace
        }
        if needsRead {
            if caps.tools { a += ["--tools", "Read"] }
            if caps.allowedTools { a += ["--allowedTools", "Read"] }
        } else {
            if caps.tools { a += ["--tools", ""] }
            else if caps.disallowedTools { a += ["--disallowedTools", "Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task,Agent"] }
        }
        if caps.permissionPrompts { a += ["--permission-prompts", "none"] }
        if caps.maxTurns { a += ["--max-turns", needsRead ? "8" : "2"] }
        if caps.systemPrompt, !resume { a += ["--system-prompt", ZeraPrompts.system] }
        if caps.strictMCP { a.append("--strict-mcp-config") }
        if caps.name, !resume, let n = name { a += ["--name", n] }
        let m = cliModel
        if caps.model, !m.isEmpty { a += ["--model", m] }
        return a
    }

    private func cliRequest(executable: URL, info: ClaudeCLIInfo, arguments: [String], stdin: Data?, cwd: URL?) -> ClaudeProcessRequest {
        // ZERA_ASSISTANT tells Zera's own PreToolUse hook to stay out of the way, so a file
        // analysis never shows up in the approval card (System A).
        let env = ShellEnvironment.shared.environment(extra: ["ZERA_ASSISTANT": "1", "NO_COLOR": "1"])
        return ClaudeProcessRequest(executable: executable, arguments: arguments, stdin: stdin,
                                    currentDirectory: cwd ?? URL(fileURLWithPath: NSTemporaryDirectory()),
                                    environment: env, timeout: timeout,
                                    format: info.capabilities.streamJSON ? .streamJSON : .json)
    }

    private func startCLI(action: FileAction, session s: AnalysisSession, info: ClaudeCLIInfo, resume: Bool) {
        guard let exe = info.executable else { fail(Self.error(for: ClaudeCLIInfo(status: .notDetected))!); return }
        let p = s.payload
        let needsRead = p?.needsReadTool ?? false
        // Resume only when the CLI can and the conversation really exists; otherwise start over
        // under a fresh id (Claude Code refuses `--session-id` for an id it has already used) and
        // send the file again so the question still has its context.
        let effectiveResume = resume && info.capabilities.resume && s.claudeSessionReady
        if !effectiveResume, s.claudeSessionReady { s.rotateSessionID() }
        let args = cliArguments(info.capabilities, needsRead: needsRead, resume: effectiveResume, sessionID: s.id,
                                name: p.map { "Zera: \($0.fileName)" } ?? "Zera: question")
        // The prompt always goes through stdin: never a positional (a variadic flag could swallow
        // it on some CLI versions) and never visible in `ps`.
        let prompt: String
        if effectiveResume || p == nil {
            prompt = ZeraPrompts.instruction(for: action)
        } else if let p = p {
            switch p.mode {
            case .inlineText(let text, let truncated):
                prompt = ZeraPrompts.inlinePrompt(action: action, fileName: s.fileName, text: text, truncated: truncated)
            case .readPath:
                prompt = ZeraPrompts.readPathPrompt(action: action, path: p.url.path, kind: p.kind)
            }
        } else {
            prompt = ZeraPrompts.instruction(for: action)
        }
        // cwd = the file's folder so Read needs no extra permission; nothing is written there.
        let req = cliRequest(executable: exe, info: info, arguments: args, stdin: Data(prompt.utf8), cwd: p?.url.deletingLastPathComponent())
        phase = .analyzing
        let h = ClaudeProcessManager.shared.launch(req)
        handle = h
        h.onEvent = { [weak self, weak h] e in
            guard let self = self, let h = h, self.handle === h else { return }
            self.handleEvent(e, session: s)
        }
        h.onEnd = { [weak self, weak h] end, stderr in
            guard let self = self, let h = h else { return }
            // Diagnostics first — even when the run already failed and `handle` was dropped.
            if self.handle == nil || self.handle === h {
                self.lastStderr = stderr
                let secs = Int(Date().timeIntervalSince(h.startedAt))
                self.lastRunSummary = "Claude Code · \(secs)s · \(end)"
            }
            guard self.handle === h else { return }
            self.handle = nil
            if self.phase.isBusy {
                // The process ended without a result event (crash / killed).
                switch end {
                case .cancelled: self.phase = .cancelled
                case .timedOut: self.fail(ZeraAIError(message: "Claude took too long and was stopped.", action: .retry))
                case .failedToLaunch(let m): self.fail(ZeraAIError(message: "Couldn't start Claude: \(m)", action: .openClaudeSettings))
                case .exited(let code):
                    if case .failed(let m, let k) = ClaudeCodeOutputParser.failure(from: stderr, exitStatus: code) {
                        self.fail(Self.error(fromFailure: m, kind: k))
                    }
                }
            }
        }
    }

    private func handleEvent(_ e: ClaudeStreamEvent, session s: AnalysisSession) {
        builder.apply(e, fileName: s.fileName)
        switch e {
        case .sessionStarted:
            s.claudeSessionReady = true
            statusLine = builder.status
        case .textDelta:
            if phase != .streaming { phase = .streaming }
            liveText = builder.display
            statusLine = nil
            post()
        case .assistantMessage(_, let usedTools):
            liveText = usedTools ? nil : builder.display
            statusLine = builder.status
            if !usedTools, phase != .streaming { phase = .streaming } else { post() }
        case .toolUse:
            statusLine = builder.status
            post()
        case .completed(let result, let sid, _, _):
            if sid != nil { s.claudeSessionReady = true }
            let text = (result.isEmpty ? builder.display : result).trimmingCharacters(in: .whitespacesAndNewlines)
            finish(text, session: s)
        case .failed(let message, let kind):
            if kind == .resumeMissing { s.rotateSessionID() }
            fail(Self.error(fromFailure: message, kind: kind))
        }
    }

    // MARK: API path

    private func startAPI(action: FileAction, session s: AnalysisSession) {
        do {
            let blocks: [APIContentBlock]
            if s.apiMessages.isEmpty, let p = s.payload {
                blocks = try p.apiBlocks(action: action)
            } else {
                blocks = [APIContentBlock(kind: .text(ZeraPrompts.instruction(for: action)))]
            }
            s.apiMessages.append(APIMessage(role: "user", content: blocks))
        } catch {
            fail(ZeraAIError(message: (error as? LocalizedError)?.errorDescription ?? "I couldn't read this file.", action: .none))
            return
        }
        phase = .analyzing
        let client = AnthropicAPIClient.shared
        let maxTokens = maxOutputTokens
        let messages = s.apiMessages
        apiTask = Task { @MainActor [weak self] in
            var full = ""
            do {
                for try await e in client.stream(system: ZeraPrompts.system, messages: messages, maxTokens: maxTokens) {
                    guard let self = self, self.session === s else { return }
                    switch e {
                    case .textDelta(let t):
                        full += t
                        if self.phase != .streaming { self.phase = .streaming }
                        self.liveText = full
                        self.statusLine = nil
                        self.post()
                    case .completed(let r, _, _, _):
                        let text = (r.isEmpty ? full : r).trimmingCharacters(in: .whitespacesAndNewlines)
                        s.apiMessages.append(APIMessage(role: "assistant", content: [APIContentBlock(kind: .text(text))]))
                        self.lastRunSummary = "Anthropic API · \(client.model)"
                        self.finish(text, session: s)
                    default: break
                    }
                }
                // Cancelled or ended without `completed`.
                if let self = self, self.session === s, self.phase.isBusy {
                    if Task.isCancelled { self.phase = .cancelled }
                    else { self.fail(ZeraAIError(message: "Claude returned something I couldn't read.", action: .retry)) }
                }
            } catch {
                guard let self = self, self.session === s else { return }
                // Drop the unanswered user message so a retry does not double it.
                if s.apiMessages.last?.role == "user" { s.apiMessages.removeLast() }
                let e = error as? AnthropicAPIError
                self.fail(ZeraAIError(message: e?.errorDescription ?? error.localizedDescription,
                                      action: e?.kind == .authentication ? .updateAPIKey : .retry))
            }
        }
    }

    // MARK: Finishing

    private func finish(_ text: String, session s: AnalysisSession) {
        s.append(.answer(text.isEmpty ? "(Claude didn't say anything.)" : text))
        liveText = nil
        statusLine = nil
        phase = .done
    }

    private func fail(_ e: ZeraAIError) {
        handle = nil
        apiTask = nil
        liveText = nil
        statusLine = nil
        session?.append(.failure(e.message))
        phase = .failed(e)
    }

    private func post() {
        guard !postScheduled else { return }
        postScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.postScheduled = false
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }
    }
}

private extension AnalysisSession {
    func removeLast() { if !turns.isEmpty { turns.removeLast() } }
}
