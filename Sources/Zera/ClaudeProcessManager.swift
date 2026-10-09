import Foundation

// MARK: - Background Claude Code process
//
// Launches `claude -p …` hidden, with pipes, and streams parsed events back on the main
// thread. No shell is involved: the executable is launched directly with an argv array, so
// nothing from a file name or a question can be interpreted as a command.

/// One request to the CLI.
struct ClaudeProcessRequest {
    var executable: URL
    var arguments: [String]
    /// Written to stdin, then stdin is closed. nil = stdin closed immediately (`< /dev/null`).
    var stdin: Data?
    var currentDirectory: URL?
    var environment: [String: String]
    var timeout: TimeInterval
    var format: ClaudeCodeOutputParser.Format
}

/// Why a run ended.
enum ClaudeProcessEnd: Equatable {
    case exited(Int32)
    case cancelled
    case timedOut
    case failedToLaunch(String)
}

/// A running request. Keep it to cancel; drop it and the process still runs to completion.
final class ClaudeProcessHandle {
    fileprivate let process = Process()
    fileprivate let parser: ClaudeCodeOutputParser
    fileprivate var stderrData = Data()
    fileprivate var ended = false
    fileprivate var cancelled = false
    fileprivate var timedOut = false
    fileprivate var timeoutWork: DispatchWorkItem?
    fileprivate let lock = NSLock()

    /// Parsed events, delivered on the main actor in order.
    var onEvent: (@MainActor (ClaudeStreamEvent) -> Void)?
    /// Called once, on the main actor, after the last event.
    var onEnd: (@MainActor (ClaudeProcessEnd, String) -> Void)?

    let startedAt = Date()
    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    fileprivate init(format: ClaudeCodeOutputParser.Format) {
        parser = ClaudeCodeOutputParser(format: format)
    }

    /// SIGTERM, then SIGKILL two seconds later if it is still around. Claude Code tears its
    /// own children (MCP servers) down on SIGTERM.
    func cancel() {
        lock.lock()
        guard !ended, !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        terminateHard()
    }

    fileprivate func terminateHard() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.process.isRunning, self.process.processIdentifier == pid else { return }
            _ = kill(pid, SIGKILL)
        }
    }
}

final class ClaudeProcessManager {
    static let shared = ClaudeProcessManager()

    private let lock = NSLock()
    private var running: [ObjectIdentifier: ClaudeProcessHandle] = [:]
    private let ioQueue = DispatchQueue(label: "ai.zera.claude-process.io", qos: .userInitiated)

    private init() {
        // A child that exits while we are still writing its stdin must not take Zera with it.
        _ = signal(SIGPIPE, SIG_IGN)
    }

    /// Launches the request. Events start arriving on the main thread shortly after.
    @discardableResult
    func launch(_ req: ClaudeProcessRequest) -> ClaudeProcessHandle {
        let handle = ClaudeProcessHandle(format: req.format)
        let p = handle.process
        p.executableURL = req.executable
        p.arguments = req.arguments
        p.environment = req.environment
        if let d = req.currentDirectory { p.currentDirectoryURL = d }
        p.qualityOfService = .userInitiated

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = req.stdin == nil ? FileHandle.nullDevice : inPipe

        // stdout → parser → main thread, chunk by chunk.
        let io = ioQueue
        out.fileHandleForReading.readabilityHandler = { [weak handle] fh in
            let data = fh.availableData
            guard let handle = handle else { return }
            if data.isEmpty { fh.readabilityHandler = nil; return }
            // One serial queue feeds the parser, so chunks and the final drain never interleave.
            io.async {
                let events = handle.parser.feed(data)
                guard !events.isEmpty else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { events.forEach { handle.onEvent?($0) } } }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak handle] fh in
            let data = fh.availableData
            guard let handle = handle else { return }
            if data.isEmpty { fh.readabilityHandler = nil; return }
            handle.lock.lock(); handle.stderrData.append(data); handle.lock.unlock()
        }

        p.terminationHandler = { [weak self, weak handle] proc in
            guard let self = self, let handle = handle else { return }
            // Drain whatever is left in the pipes after exit, then finish on the main thread.
            self.ioQueue.async {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                let restOut = out.fileHandleForReading.readDataToEndOfFile()
                let restErr = err.fileHandleForReading.readDataToEndOfFile()
                handle.lock.lock()
                handle.stderrData.append(restErr)
                let stderr = String(decoding: handle.stderrData, as: UTF8.self)
                handle.ended = true
                handle.timeoutWork?.cancel()
                let wasCancelled = handle.cancelled, wasTimeout = handle.timedOut
                handle.lock.unlock()
                var events = handle.parser.feed(restOut)
                let status = proc.terminationStatus
                if wasTimeout {
                    events.append(.failed(message: "Claude took too long and was stopped.", kind: .other))
                } else if !wasCancelled {
                    events.append(contentsOf: handle.parser.finish(exitStatus: status, stderr: stderr))
                }
                self.lock.lock(); self.running.removeValue(forKey: ObjectIdentifier(handle)); self.lock.unlock()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !wasCancelled { events.forEach { handle.onEvent?($0) } }
                        let end: ClaudeProcessEnd = wasCancelled ? .cancelled : (wasTimeout ? .timedOut : .exited(status))
                        handle.onEnd?(end, stderr)
                        handle.onEvent = nil
                        handle.onEnd = nil
                    }
                }
            }
        }

        lock.lock(); running[ObjectIdentifier(handle)] = handle; lock.unlock()
        do {
            try p.run()
        } catch {
            lock.lock(); running.removeValue(forKey: ObjectIdentifier(handle)); lock.unlock()
            handle.ended = true
            let msg = error.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    handle.onEvent?(.failed(message: "Couldn't start Claude: \(msg)", kind: .other))
                    handle.onEnd?(.failedToLaunch(msg), "")
                    handle.onEvent = nil
                    handle.onEnd = nil
                }
            }
            return handle
        }

        if let data = req.stdin {
            ioQueue.async {
                // Write in chunks so a large document does not block the main thread; the CLI
                // reads stdin fully before answering, so a broken pipe only means it died early.
                let fh = inPipe.fileHandleForWriting
                var offset = 0
                let chunk = 64 * 1024
                while offset < data.count, handle.process.isRunning {
                    let end = min(offset + chunk, data.count)
                    do { try fh.write(contentsOf: data.subdata(in: offset..<end)) } catch { break }
                    offset = end
                }
                try? fh.close()
            }
        }

        let work = DispatchWorkItem { [weak handle] in
            guard let handle = handle else { return }
            handle.lock.lock()
            guard !handle.ended, !handle.cancelled else { handle.lock.unlock(); return }
            handle.timedOut = true
            handle.lock.unlock()
            handle.terminateHard()
        }
        handle.timeoutWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + req.timeout, execute: work)
        return handle
    }

    /// Stops everything — called when Zera quits so no `claude` keeps running without her.
    func cancelAll() {
        lock.lock(); let all = Array(running.values); lock.unlock()
        all.forEach { $0.cancel() }
    }
}
