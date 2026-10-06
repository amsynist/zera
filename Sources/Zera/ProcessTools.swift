import AppKit
import Darwin

/// A running process, as `ps` sees it.
struct ProcessEntry: Equatable {
    let pid: Int32
    let name: String
    let cpu: Double
    /// Resident memory in KB.
    let memoryKB: Int
    let path: String
}

/// Something listening on a TCP port, as `lsof` sees it.
struct PortEntry: Equatable {
    let port: Int
    let pid: Int32
    let command: String
    let address: String
}

/// Lists and stops processes for the opener's Kill Process / Kill Port commands. Your own
/// processes only: anything owned by the system answers "not allowed" and is left alone.
enum ProcessTools {
    /// Every process you can see, busiest first. Runs `ps`; call off the main thread.
    static func processes() -> [ProcessEntry] {
        guard let out = run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,comm="]) else { return [] }
        return parseProcesses(out)
    }

    static func parseProcesses(_ out: String) -> [ProcessEntry] {
        var list: [ProcessEntry] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 4, let pid = Int32(parts[0]), pid > 0 else { continue }
            let path = String(parts[3]).trimmingCharacters(in: .whitespaces)
            list.append(ProcessEntry(pid: pid, name: (path as NSString).lastPathComponent,
                                     cpu: Double(parts[1]) ?? 0, memoryKB: Int(parts[2]) ?? 0, path: path))
        }
        return list.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memoryKB > $1.memoryKB }
    }

    /// Everything listening on a TCP port. Runs `lsof`; call off the main thread.
    static func listeningPorts() -> [PortEntry] {
        guard let out = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) else { return [] }
        return parseListeningPorts(out)
    }

    static func parseListeningPorts(_ out: String) -> [PortEntry] {
        var list: [PortEntry] = []
        var pid: Int32 = 0, command = ""
        var seen = Set<String>()
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                // "*:3000", "127.0.0.1:5432", "[::1]:8080"
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let key = "\(pid):\(port)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                list.append(PortEntry(port: port, pid: pid, command: command, address: String(value[..<colon])))
            default: break
            }
        }
        return list.sorted { $0.port < $1.port }
    }

    enum KillResult { case done, notAllowed, gone }

    /// Asks the process to quit (SIGTERM), or forces it (SIGKILL).
    static func kill(_ pid: Int32, force: Bool) -> KillResult {
        guard pid > 1 else { return .notAllowed }
        if Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0 { return .done }
        return errno == EPERM ? .notAllowed : .gone
    }

    /// "1.2 GB", "340 MB".
    static func memory(_ kb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .memory)
    }

    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

/// Commands the opener can run besides opening apps.
enum OpenerCommand: CaseIterable {
    case killProcess, killPort, custom

    var title: String {
        switch self {
        case .killProcess: return "Kill Process"
        case .killPort: return "Kill Port"
        case .custom: return "Custom Commands"
        }
    }
    var subtitle: String {
        switch self {
        case .killProcess: return "Command · stop a running process by name"
        case .killPort: return "Command · free a port by stopping what listens on it"
        case .custom: return "Coming soon · your own scripts as commands"
        }
    }
    var symbol: String {
        switch self {
        case .killProcess: return "xmark.octagon.fill"
        case .killPort: return "network.slash"
        case .custom: return "terminal.fill"
        }
    }
    var tint: NSColor {
        switch self {
        case .killProcess: return Neon.red
        case .killPort: return Neon.warning
        case .custom: return Neon.violet
        }
    }
    /// Extra words it answers to.
    var keywords: [String] {
        switch self {
        case .killProcess: return ["kill", "process", "quit", "force quit", "stop", "task"]
        case .killPort: return ["kill", "port", "lsof", "listen", "free port", "network"]
        case .custom: return ["custom", "script", "command", "shell"]
        }
    }

    /// The best score of its title or keywords against the query.
    func match(_ query: String) -> (score: Int, hits: [Int])? {
        if let m = AppMatcher.match(title, query) { return m }
        let q = query.lowercased()
        if keywords.contains(where: { $0.hasPrefix(q) || q.hasPrefix($0) }) { return (500, []) }
        return nil
    }

    var icon: NSImage { OpenerIcon.glyph(symbol, tint) }
}

/// Icons for things that aren't apps: an SF Symbol on a tinted, app-icon-shaped square.
enum OpenerIcon {
    private static var cache: [String: NSImage] = [:]
    static func glyph(_ symbol: String, _ tint: NSColor) -> NSImage {
        let key = symbol + tint.description
        if let i = cache[key] { return i }
        let img = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 3), xRadius: 14, yRadius: 14)
            NSGradient(starting: tint.withAlphaComponent(0.95), ending: tint.blended(withFraction: 0.5, of: .black) ?? tint)?
                .draw(in: path, angle: -90)
            NSColor.white.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
            if let s = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 25, weight: .bold).applying(.init(paletteColors: [.white]))) {
                let sz = s.size
                s.draw(in: NSRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height))
            }
            return true
        }
        cache[key] = img
        return img
    }
}

/// Zera's own actions in the opener: the Home quick actions, plus search.
enum OpenerActions {
    static let all: [QuickAction] = [.clipboard, .screenshot, .startTimer, .newNote, .openClaude, .dropFiles, .takeBreak, .searchFiles]

    static func title(_ a: QuickAction) -> String {
        switch a {
        case .clipboard: return "Clipboard History"
        case .dropFiles: return "Open the Shelf"
        case .startTimer: return "Start a 25-min Timer"
        case .openClaude: return "Open Claude"
        default: return a.title
        }
    }
    static func subtitle(_ a: QuickAction) -> String {
        switch a {
        case .clipboard: return "Action · everything you copied"
        case .screenshot: return "Action · capture an area onto the shelf"
        case .startTimer: return "Action · Zera tells you when it's up"
        case .newNote: return "Action · a quick note on the shelf"
        case .openClaude: return "Action · open the Claude app"
        case .dropFiles: return "Action · your files and Zera's answers"
        case .takeBreak: return "Action · a short break, starting now"
        case .searchFiles: return "Action · search your recent files"
        case .askZera: return "Action"
        }
    }
    static func match(_ a: QuickAction, _ q: String) -> (score: Int, hits: [Int])? {
        if let m = AppMatcher.match(title(a), q) { return m }
        if let m = AppMatcher.match(a.tileTitle, q) { return (m.score - 50, []) }
        return nil
    }
}
