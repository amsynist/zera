import AppKit

/// Zera-owned conversations use the installed CLI's bidirectional protocol. Existing chats
/// remain owned by their original app and are never resumed on this channel.
@MainActor
final class ClaudeAgentService {
    static let shared = ClaudeAgentService()
    nonisolated static let changed = Notification.Name("ZeraClaudeManagedChanged")
    nonisolated static let created = Notification.Name("ZeraClaudeManagedCreated")
    struct Thread: Codable, Identifiable {
        let id: String
        var title: String
        let cwd: String
        var transcript = ""
        var status = "Ready"
        var activity = "Ready for a message"
        var hasHistory = false
        var steps: [String] = []
    }
    struct Approval: Identifiable {
        let threadID: String
        let requestID: String
        let tool: String
        let input: [String: Any]
        var id: String { threadID + ":" + requestID }
        var isQuestion: Bool { tool == "AskUserQuestion" }
        var detail: String {
            if let command = input["command"] as? String { return command }
            return String(data: (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? tool
        }
    }
    private final class Channel {
        let generation = UUID()
        var process: Process?
        var input: FileHandle?, output: FileHandle?, errors: FileHandle?
        var carry = Data(), stderr = Data()
        let parser = ClaudeCodeOutputParser(format: .streamJSON)
        var builder = ClaudeTranscriptBuilder()
        var prefix = ""
        var message = ""
        var ready = false
        var deadline: DispatchWorkItem?
        var activeTasks = Set<String>()
        var sessionState: String?
        var resultReceived = false
    }
    private(set) var threads: [Thread] = []
    private(set) var approvals: [Approval] = []
    private(set) var lastError: String?
    private var channels: [String: Channel] = [:]
    private let storage: URL?
    private let writer: ((Data) throws -> Void)?
    private var refresh: DispatchWorkItem?
    private var lastDecision = Date.distantPast

    init(writer: ((Data) throws -> Void)? = nil, storage: URL? = nil) {
        _ = signal(SIGPIPE, SIG_IGN)
        self.writer = writer
        self.storage = storage ?? (writer == nil ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Zera/claude-managed.json") : nil)
        if let url = self.storage, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Thread].self, from: data) {
            threads = saved.map { var t = $0; t.status = "Ready to resume"; t.activity = "Ready for a message"; return t }
        }
    }
    @discardableResult
    func create(cwd: String) -> String {
        let id = UUID().uuidString.lowercased()
        threads.insert(Thread(id: id, title: URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd), at: 0)
        publish(save: true)
        NotificationCenter.default.post(name: Self.created, object: nil, userInfo: ["threadID": id])
        return id
    }
    func isWorking(_ id: String) -> Bool { channels[id] != nil }

    @discardableResult
    func send(_ message: String, to id: String) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 1_000_000, channels[id] == nil,
              let index = threads.firstIndex(where: { $0.id == id }) else { return false }
        let channel = Channel()
        channels[id] = channel
        if threads[index].transcript.isEmpty { threads[index].title = String(text.prefix(80)) }
        threads[index].transcript += "\nYou\n" + text + "\n\nClaude\n"
        threads[index].status = "Starting"
        threads[index].activity = "Connecting to Claude Code"
        threads[index].steps = []
        channel.prefix = threads[index].transcript; channel.message = text
        lastError = nil; publish(save: true)
        if writer != nil { channel.ready = true; beginMessage(id, channel: channel); return true }
        ClaudeCLI.shared.ensureProbed { [weak self, weak channel] info in
            guard let self, let channel, self.channels[id] === channel else { return }
            self.launch(id, channel: channel, info: info)
        }
        return true
    }
    private func launch(_ id: String, channel: Channel, info: ClaudeCLIInfo) {
        guard let thread = threads.first(where: { $0.id == id }), let executable = info.executable,
              info.capabilities.streamJSON, info.capabilities.inputStreaming else {
            fail(id, "Claude Code with streaming support is required. Check Claude Code in Integrations."); return
        }
        let caps = info.capabilities
        var args = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--permission-prompt-tool", "stdio", "--permission-mode", caps.manualPermissions ? "manual" : "default"]
        if caps.permissionPrompts { args += ["--permission-prompts", "host"] }
        if caps.partialMessages { args.append("--include-partial-messages") }
        if thread.hasHistory { args.append("--resume=" + id) }
        else if caps.sessionID { args.append("--session-id=" + id) }
        else { fail(id, "Update Claude Code to create resumable sessions in Zera."); return }
        let model = ZeraAssistant.shared.cliModel
        if caps.model, !model.isEmpty { args += ["--model", model] }
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable; process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: thread.cwd)
        // Only Zera's legacy hook wrappers skip these owned sessions. The CLI's policy,
        // project instructions, other user hooks, and permission checks remain in force.
        var environment = ShellEnvironment.shared.environment(extra: ["NO_COLOR": "1", "ZERA_ASSISTANT": "1", "CLAUDE_CODE_SDK_READS_SESSION_STATE": "1"])
        environment.removeValue(forKey: "CLAUDECODE"); environment.removeValue(forKey: "CFFIXED_USER_HOME")
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        channel.process = process; channel.input = stdin.fileHandleForWriting
        channel.output = stdout.fileHandleForReading; channel.errors = stderr.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak channel] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, let channel, self.channels[id] === channel else { return }
                if !data.isEmpty { self.consume(data, threadID: id, channel: channel) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self, weak channel] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, let channel, self.channels[id] === channel else { return }
                channel.stderr.append(data)
                if channel.stderr.count > 16_384 { channel.stderr = Data(channel.stderr.suffix(16_384)) }
            }
        }
        process.terminationHandler = { [weak self, weak channel] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated {
                    guard let self, let channel, self.channels[id] === channel else { return }
                    if !channel.carry.isEmpty { self.consume(Data([10]), threadID: id, channel: channel) }
                    guard self.channels[id] === channel else { return }
                    if channel.resultReceived && channel.activeTasks.isEmpty {
                        self.finish(id, status: "Completed", activity: "Finished"); return
                    }
                    let error = String(decoding: channel.stderr.suffix(800), as: UTF8.self)
                    self.fail(id, error.isEmpty ? "Claude Code disconnected before finishing." : error)
                }
            }
        }
        do {
            try process.run()
            try write(["type": "control_request", "request_id": "zera-init-" + id, "request": ["subtype": "initialize", "hooks": [:]]], channel: channel)
            let timeout = DispatchWorkItem { [weak self, weak channel] in
                MainActor.assumeIsolated {
                    guard let self, let channel, self.channels[id] === channel, !channel.ready else { return }
                    self.fail(id, "Claude Code did not finish connecting. Try again from this session.")
                }
            }
            channel.deadline = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
        } catch { fail(id, "Couldn't start Claude Code: " + error.localizedDescription) }
    }
    private func beginMessage(_ id: String, channel: Channel) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        do {
            try write(["type": "user", "session_id": id, "message": ["role": "user", "content": channel.message]], channel: channel)
            threads[index].status = "Working"; threads[index].activity = "Thinking through your request"
            publish(save: true)
        } catch { fail(id, error.localizedDescription) }
    }
    private func consume(_ data: Data, threadID id: String, channel: Channel) {
        channel.carry.append(data)
        guard channel.carry.count <= 16 * 1024 * 1024 else { fail(id, "Claude sent a message larger than Zera can display."); return }
        while let end = channel.carry.firstIndex(of: 10) {
            let line = channel.carry.prefix(upTo: end)
            channel.carry.removeSubrange(...end)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { receive(object, threadID: id) }
            guard channels[id] === channel else { break }
        }
    }
    /// Protocol entry point also used with a fake transport in regression tests.
    func receive(_ object: [String: Any], threadID id: String) {
        guard let channel = channels[id], let index = threads.firstIndex(where: { $0.id == id }) else { return }
        let type = object["type"] as? String ?? ""
        if type == "control_response", let response = object["response"] as? [String: Any], response["request_id"] as? String == "zera-init-" + id {
            guard !channel.ready else { return }
            channel.deadline?.cancel()
            guard response["subtype"] as? String == "success" else { fail(id, response["error"] as? String ?? "Claude Code couldn't connect."); return }
            channel.ready = true; beginMessage(id, channel: channel); return
        }
        if type == "control_cancel_request", let requestID = object["request_id"] as? String {
            approvals.removeAll { $0.threadID == id && $0.requestID == requestID }; publish(); return
        }
        if type == "control_request", let requestID = object["request_id"] as? String, let request = object["request"] as? [String: Any] {
            guard channel.ready, !requestID.isEmpty else { return }
            guard request["subtype"] as? String == "can_use_tool", let name = request["tool_name"] as? String, let input = request["input"] as? [String: Any] else {
                try? write(["type": "control_response", "response": ["subtype": "error", "request_id": requestID, "error": "This request is not supported in Zera"]], channel: channel); return
            }
            guard !approvals.contains(where: { $0.threadID == id && $0.requestID == requestID }) else { return }
            approvals.append(Approval(threadID: id, requestID: requestID, tool: name, input: input))
            threads[index].status = "Needs approval"; threads[index].activity = name == "AskUserQuestion" ? "Waiting for your answer" : "Waiting for permission to use " + name
            publish(save: true); return
        }
        if type == "system", let subtype = object["subtype"] as? String {
            if subtype == "session_state_changed" {
                channel.sessionState = object["state"] as? String
                if channel.sessionState == "idle", channel.resultReceived, channel.activeTasks.isEmpty {
                    finish(id, status: "Completed", activity: "Finished"); return
                }
            }
            if let taskID = object["task_id"] as? String {
                if subtype == "task_started", ["local_agent", "local_workflow"].contains(object["task_type"] as? String ?? "") {
                    channel.activeTasks.insert(taskID)
                    let step = "Sub-agent · " + (object["description"] as? String ?? "Working")
                    threads[index].steps.append(String(step.prefix(160)))
                }
                if subtype == "task_notification" { channel.activeTasks.remove(taskID) }
                if subtype == "task_updated", let patch = object["patch"] as? [String: Any],
                   ["completed", "failed", "cancelled", "stopped"].contains(patch["status"] as? String ?? "") { channel.activeTasks.remove(taskID) }
            }
        }
        if channel.resultReceived, object["parent_tool_use_id"] == nil, type == "assistant" || type == "stream_event" {
            channel.resultReceived = false; channel.builder = ClaudeTranscriptBuilder()
            channel.prefix = threads[index].transcript + "\nClaude\n"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        for event in channel.parser.feed(data + Data([10])) {
            channel.builder.apply(event, fileName: URL(fileURLWithPath: threads[index].cwd).lastPathComponent)
            switch event {
            case .sessionStarted: threads[index].hasHistory = true
            case .textDelta, .assistantMessage:
                threads[index].transcript = String((channel.prefix + channel.builder.display).suffix(100_000))
                if approvals.allSatisfy({ $0.threadID != id }) { threads[index].activity = "Writing a reply" }
            case .toolUse(let name, let target):
                let verb = ["Read": "Reading", "Edit": "Editing", "Write": "Writing", "Grep": "Searching", "Glob": "Finding", "Bash": "Running a command", "Agent": "Delegating work"][name] ?? name
                let step = target.map { verb + " · " + $0 } ?? verb
                threads[index].activity = step; threads[index].steps.append(step)
                threads[index].steps = Array(threads[index].steps.suffix(24))
            case .completed:
                threads[index].transcript = String((channel.prefix + channel.builder.display + "\n").suffix(100_000))
                threads[index].hasHistory = true
                channel.resultReceived = true
                if channel.activeTasks.isEmpty && (channel.sessionState == nil || channel.sessionState == "idle") { finish(id, status: "Completed", activity: "Finished"); return }
                threads[index].activity = "Background agents are still working"
            case .failed(let message, _): fail(id, message); return
            }
        }
        publish()
    }
    @discardableResult
    func decide(_ approvalID: String, allow: Bool, answers: [String: String]? = nil) -> Bool {
        guard Date().timeIntervalSince(lastDecision) > 0.6, let request = approvals.first(where: { $0.id == approvalID }), let channel = channels[request.threadID],
              let index = threads.firstIndex(where: { $0.id == request.threadID }) else { return false }
        var input = request.input
        if allow && request.isQuestion {
            let questions = request.input["questions"] as? [[String: Any]] ?? []
            guard !questions.isEmpty, let answers, questions.allSatisfy({ answers[$0["question"] as? String ?? ""]?.isEmpty == false }) else { return false }
            input["answers"] = answers
        }
        let result: [String: Any] = allow ? ["behavior": "allow", "updatedInput": input] : ["behavior": "deny", "message": "The user declined this request in Zera."]
        do {
            try write(["type": "control_response", "response": ["subtype": "success", "request_id": request.requestID, "response": result]], channel: channel)
            lastError = nil; lastDecision = Date(); approvals.removeAll { $0.id == approvalID }
            threads[index].status = approvals.contains { $0.threadID == request.threadID } ? "Needs approval" : "Working"
            threads[index].activity = allow ? "Continuing after your approval" : "Permission declined"
            publish(save: true); return true
        } catch { lastError = "Couldn't send the decision. Try again."; publish(); return false }
    }
    func stop(_ id: String) {
        guard let channel = channels[id] else { return }
        try? write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]], channel: channel)
        finish(id, status: "Stopped", activity: "Stopped by you")
    }
    func disconnectAll() { for id in Array(channels.keys) { stop(id) } }
    private func fail(_ id: String, _ message: String) { lastError = message; finish(id, status: "Failed", activity: message) }
    private func finish(_ id: String, status: String, activity: String) {
        let channel = channels.removeValue(forKey: id)
        channel?.deadline?.cancel(); channel?.output?.readabilityHandler = nil; channel?.errors?.readabilityHandler = nil
        try? channel?.input?.close()
        if let process = channel?.process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning, process.processIdentifier == pid { kill(pid, SIGKILL) } }
        }
        approvals.removeAll { $0.threadID == id }
        if let index = threads.firstIndex(where: { $0.id == id }) { threads[index].status = status; threads[index].activity = activity }
        publish(save: true)
    }
    private func write(_ object: [String: Any], channel: Channel) throws {
        let data = try JSONSerialization.data(withJSONObject: object) + Data([10])
        if let writer { try writer(data) }
        else if let input = channel.input { try input.write(contentsOf: data) }
        else { throw CocoaError(.fileWriteUnknown) }
    }
    private func publish(save: Bool = false) {
        if save, let url = storage, let data = try? JSONEncoder().encode(threads) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if save { refresh?.cancel(); refresh = nil; NotificationCenter.default.post(name: Self.changed, object: nil); return }
        guard refresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh = nil; NotificationCenter.default.post(name: Self.changed, object: nil) } }
        refresh = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
