import AppKit

/// A dedicated app-server connection owns only threads created/resumed by this service.
/// Desktop chats are monitored separately; their requests are never answered on this channel.
@MainActor
final class CodexAgentService {
    static let shared = CodexAgentService()
    nonisolated static let changed = Notification.Name("ZeraCodexManagedChanged")
    nonisolated static let created = Notification.Name("ZeraCodexManagedCreated")
    struct Thread: Codable, Identifiable {
        let id: String
        var title: String
        let cwd: String
        var transcript = ""
        var status = "Ready"
        var turnID: String?
        var activity: String?
    }
    struct Approval {
        let id: String
        let wireID: Any
        let threadID: String
        let turnID: String
        let title: String
        let detail: String
        let method: String
        let params: [String: Any]
        var isQuestion: Bool { method == "item/tool/requestUserInput" }
        var canAccept: Bool {
            if method == "item/commandExecution/requestApproval" {
                guard let choices = params["availableDecisions"] as? [Any] else { return true }
                return choices.contains { ($0 as? String) == "accept" }
            }
            return method == "item/fileChange/requestApproval"
        }
    }
    private(set) var threads: [Thread] = []
    private(set) var approvals: [Approval] = []
    private(set) var connection = "Not connected"
    private(set) var ready = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var carry = Data()
    private var nextID = 0
    private var callbacks: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var deadlines: [Int: DispatchWorkItem] = [:]
    private var connected: [() -> Void] = []
    private var attached = Set<String>()
    private var starting = Set<String>()
    private var fileChanges: [String: [String: String]] = [:]
    private var deltaRefresh: DispatchWorkItem?
    private var lastDecision = Date.distantPast
    private let writer: ((Data) throws -> Void)?
    private let storage: URL?

    init(writer: ((Data) throws -> Void)? = nil, storage: URL? = nil) {
        self.writer = writer
        self.storage = storage ?? (writer == nil ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Zera/codex-managed.json") : nil)
        if let storage = self.storage, let data = try? Data(contentsOf: storage),
           let saved = try? JSONDecoder().decode([Thread].self, from: data) {
            threads = saved.map { var t = $0; t.status = "Ready to resume"; t.turnID = nil; return t }
        }
    }
    private func publish(persist: Bool = true) {
        if persist, let storage, let data = try? JSONEncoder().encode(threads) {
            try? FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: storage, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    private static func failure(_ message: String) -> Error { NSError(domain: "ZeraCodex", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        if let writer { try writer(data) }
        else if let input { try input.write(contentsOf: data) }
        else { throw Self.failure("Codex is not connected") }
    }
    private func request(_ method: String, _ params: [String: Any], done: @escaping (Result<[String: Any], Error>) -> Void) {
        nextID += 1
        let id = nextID
        callbacks[id] = done
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let callback = self.callbacks.removeValue(forKey: id) else { return }
            self.deadlines.removeValue(forKey: id)
            callback(.failure(Self.failure("Codex did not respond to \(method). Reconnect to retry.")))
        }
        deadlines[id] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
        do { try send(["id": id, "method": method, "params": params]) }
        catch { deadlines.removeValue(forKey: id)?.cancel(); callbacks.removeValue(forKey: id)?(.failure(error)) }
    }
    func connect(then action: @escaping () -> Void = {}) {
        if ready { action(); return }
        connected.append(action)
        guard process == nil else { return }
        let fm = FileManager.default
        let paths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        guard let executable = paths.first(where: fm.isExecutableFile(atPath:)) else {
            connected = []; connection = "Install Codex CLI, then connect"
            for index in threads.indices where starting.contains(threads[index].id) { threads[index].status = "Couldn’t connect" }
            starting = []; publish(); return
        }
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env.removeValue(forKey: "CFFIXED_USER_HOME")
        p.environment = env
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            DispatchQueue.main.async { self?.read(bytes) }
        }
        errors?.readabilityHandler = { handle in _ = handle.availableData }
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.disconnected() } }
        process = p; connection = "Connecting…"; publish()
        do {
            try p.run()
            request("initialize", ["clientInfo": ["name": "zera", "title": "Zera", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"]]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    do {
                        try self.send(["method": "initialized", "params": [:]])
                        self.ready = true; self.connection = "Connected · your Codex login"
                        let actions = self.connected; self.connected = []; self.publish(); actions.forEach { $0() }
                    } catch { self.connection = error.localizedDescription; self.disconnect() }
                case .failure(let error): self.connection = error.localizedDescription; self.disconnect()
                }
            }
        } catch { connection = error.localizedDescription; disconnected() }
    }
    func disconnect() {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        disconnected()
    }
    private func disconnected() {
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? errors?.close()
        let interrupted = starting
        process = nil; input = nil; output = nil; errors = nil; ready = false; attached = []; starting = []; carry = Data(); connected = []
        deltaRefresh?.cancel(); deltaRefresh = nil
        if connection.hasPrefix("Connected") || connection == "Connecting…" { connection = "Disconnected" }
        let waiting = callbacks; callbacks = [:]
        deadlines.values.forEach { $0.cancel() }; deadlines = [:]
        approvals = []
        for i in threads.indices where threads[i].turnID != nil || interrupted.contains(threads[i].id) { threads[i].turnID = nil; threads[i].status = "Disconnected — resume to continue" }
        waiting.values.forEach { $0(.failure(Self.failure("Codex disconnected"))) }
        publish()
    }
    private func read(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        carry.append(bytes)
        guard carry.count < 16_000_000 else { connection = "Codex response exceeded the buffer limit"; disconnect(); return }
        while let end = carry.firstIndex(of: 10) {
            let line = carry[..<end]; carry.removeSubrange(...end)
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { receive(message) }
        }
    }
    func create(cwd: String, didCreate: @escaping (String) -> Void = { _ in }) {
        connect { [weak self] in
            self?.request("thread/start", ["cwd": cwd, "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "workspace-write"]) { result in
                guard let self else { return }
                switch result {
                case .success(let response):
                    guard let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String else { return }
                    self.threads.insert(Thread(id: id, title: URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd), at: 0)
                    self.attached.insert(id); self.publish()
                    didCreate(id)
                    NotificationCenter.default.post(name: Self.created, object: nil, userInfo: ["threadID": id])
                case .failure(let error): self.connection = error.localizedDescription; self.publish()
                }
            }
        }
    }
    func sendText(_ text: String, threadID: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let thread = threads.first(where: { $0.id == threadID }), thread.turnID == nil, !starting.contains(threadID) else { return }
        starting.insert(threadID)
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads[index].status = "Starting…"
            if threads[index].transcript.isEmpty { threads[index].title = String(text.prefix(60)) }
            threads[index].transcript += "\nYou\n\(text)\n\nCodex\n"
        }
        publish()
        connect { [weak self] in
            guard let self else { return }
            let start = {
                self.request("turn/start", ["threadId": threadID, "input": [["type": "text", "text": text]], "approvalPolicy": "on-request", "approvalsReviewer": "user"]) { result in
                    self.starting.remove(threadID)
                    guard let index = self.threads.firstIndex(where: { $0.id == threadID }) else { return }
                    switch result {
                    case .success(let response):
                        if self.threads[index].status == "Starting…" {
                            self.threads[index].turnID = (response["turn"] as? [String: Any])?["id"] as? String
                            self.threads[index].status = "Working"
                        }
                        self.publish()
                    case .failure(let error): self.threads[index].status = error.localizedDescription; self.publish()
                    }
                }
            }
            if self.attached.contains(threadID) { start() }
            else {
                self.request("thread/resume", ["threadId": threadID, "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "workspace-write"]) { result in
                    if case .success = result { self.attached.insert(threadID); start() }
                    else if case .failure(let error) = result { self.starting.remove(threadID); self.connection = error.localizedDescription; self.publish() }
                }
            }
        }
    }
    func interrupt(_ id: String) {
        guard let thread = threads.first(where: { $0.id == id }), let turn = thread.turnID else { return }
        request("turn/interrupt", ["threadId": id, "turnId": turn]) { [weak self] result in
            if case .failure(let error) = result { self?.connection = error.localizedDescription; self?.publish() }
        }
    }
    private static func key(_ id: Any) -> String { (try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "invalid" }
    /// Entry point shared by the transport and deterministic protocol fixtures.
    func receive(_ message: [String: Any]) {
        if message["method"] == nil, let id = message["id"] as? Int, let callback = callbacks.removeValue(forKey: id) {
            deadlines.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] { callback(.failure(Self.failure(error["message"] as? String ?? "Codex request failed"))) }
            else { callback(.success(message["result"] as? [String: Any] ?? [:])) }
            return
        }
        guard let method = message["method"] as? String, let params = message["params"] as? [String: Any] else { return }
        if let wireID = message["id"] {
            guard let threadID = params["threadId"] as? String, let index = threads.firstIndex(where: { $0.id == threadID }) else {
                try? send(["id": wireID, "error": ["code": -32602, "message": "This connection does not own that thread"]]); return
            }
            if let turn = params["turnId"] as? String, threads[index].turnID != turn {
                try? send(["id": wireID, "error": ["code": -32602, "message": "That turn is no longer active"]]); return
            }
            let key = Self.key(wireID)
            guard !approvals.contains(where: { $0.id == key }) else { return }
            let title = method == "item/commandExecution/requestApproval" ? "Run this command?" : method == "item/fileChange/requestApproval" ? "Apply these file changes?" : "Codex needs a response"
            var parts: [String] = []
            for name in ["command", "reason", "cwd", "grantRoot"] { if let text = params[name] as? String, !text.isEmpty { parts.append(text) } }
            if let network = params["networkApprovalContext"] as? [String: Any] {
                parts.append("Network access: " + (network["protocol"] as? String ?? "") + "://" + (network["host"] as? String ?? "unknown host"))
            }
            if method == "item/fileChange/requestApproval", let item = params["itemId"] as? String, let changes = fileChanges[threadID]?[item] { parts.append(changes) }
            if method == "item/tool/requestUserInput", let questions = params["questions"] as? [[String: Any]] {
                parts += questions.compactMap { $0["question"] as? String }
            }
            if parts.isEmpty { parts.append("This request type is not supported yet. Cancel it to stop the turn safely.") }
            approvals.append(Approval(id: key, wireID: wireID, threadID: threadID, turnID: params["turnId"] as? String ?? "", title: title, detail: parts.joined(separator: "\n\n"), method: method, params: params))
            threads[index].status = "Needs your approval"; publish(); return
        }
        let id = params["threadId"] as? String
        if method == "serverRequest/resolved", let request = params["requestId"] {
            approvals.removeAll { $0.id == Self.key(request) }; publish(); return
        }
        guard let id, let index = threads.firstIndex(where: { $0.id == id }) else { return }
        switch method {
        case "item/agentMessage/delta": threads[index].transcript += params["delta"] as? String ?? ""
        case "item/started":
            if let item = params["item"] as? [String: Any] {
                let type = item["type"] as? String
                if type == "commandExecution" { threads[index].activity = "Running " + String((item["command"] as? String ?? "a command").prefix(140)) }
                else if type == "fileChange" { threads[index].activity = "Editing project files" }
                else if type == "agentMessage" { threads[index].activity = "Writing a reply" }
            }
            if let item = params["item"] as? [String: Any], item["type"] as? String == "fileChange", let changes = item["changes"] as? [[String: Any]] {
                let itemID = item["id"] as? String ?? ""
                fileChanges[id, default: [:]][itemID] = changes.map { ($0["path"] as? String ?? "File") + "\n" + ($0["diff"] as? String ?? "") }.joined(separator: "\n\n")
            }
        case "turn/started":
            threads[index].turnID = (params["turn"] as? [String: Any])?["id"] as? String; threads[index].status = "Working"
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let state = turn["status"] as? String ?? "unknown"
            threads[index].status = state == "completed" ? "Completed" : state == "interrupted" ? "Interrupted" : "Failed"
            threads[index].turnID = nil; approvals.removeAll { $0.threadID == id }; fileChanges.removeValue(forKey: id)
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String { threads[index].transcript += "\n\n\(message)" }
        case "error":
            if let error = params["error"] as? [String: Any], let message = error["message"] as? String { threads[index].status = message }
        default: return
        }
        if threads[index].transcript.count > 100_000 { threads[index].transcript = String(threads[index].transcript.suffix(100_000)) }
        if method == "item/agentMessage/delta" {
            guard deltaRefresh == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.deltaRefresh = nil; self?.publish(persist: false) }
            deltaRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        } else { publish() }
    }
    @discardableResult func answer(_ id: String, values: [String: String]) -> Bool {
        guard Date().timeIntervalSince(lastDecision) >= 0.6, let request = approvals.first(where: { $0.id == id }), request.isQuestion,
              let questions = request.params["questions"] as? [[String: Any]],
              !questions.isEmpty, questions.allSatisfy({ q in
                  guard let key = q["id"] as? String, let value = values[key] else { return false }
                  return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return false }
        let answers = values.mapValues { ["answers": [$0]] }
        do { try send(["id": request.wireID, "result": ["answers": answers]]) }
        catch { connection = error.localizedDescription; publish(); return false }
        lastDecision = Date(); approvals.removeAll { $0.id == id }; publish(); return true
    }

    @discardableResult func decide(_ id: String, allow: Bool) -> Bool {
        guard Date().timeIntervalSince(lastDecision) >= 0.6, let request = approvals.first(where: { $0.id == id }),
              threads.contains(where: { $0.id == request.threadID }), !allow || request.canAccept else { return false }
        do {
            if request.method == "item/commandExecution/requestApproval" || request.method == "item/fileChange/requestApproval" {
                let choices = (request.params["availableDecisions"] as? [Any])?.compactMap { $0 as? String }
                let decision = allow ? "accept" : (choices == nil || choices!.contains("decline") ? "decline" : "cancel")
                try send(["id": request.wireID, "result": ["decision": decision]])
            } else {
                try send(["id": request.wireID, "error": ["code": -32601, "message": "Request cancelled by the user"]])
                interrupt(request.threadID)
            }
        } catch { connection = error.localizedDescription; publish(); return false }
        lastDecision = Date(); approvals.removeAll { $0.id == id }
        if let index = threads.firstIndex(where: { $0.id == request.threadID }) { threads[index].status = "Decision sent — waiting for Codex" }
        publish(); return true
    }
}
