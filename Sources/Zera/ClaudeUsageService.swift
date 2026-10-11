import AppKit

// MARK: - Claude plan usage (no API key)
//
// Claude Code hands its status line your plan's usage after each reply: how much of the 5-hour
// and the weekly limit is spent, and when each resets (the same numbers as /usage, on Pro and
// Max plans). Zera's status line script drops that JSON where Zera reads it, then hands it on
// to the status line you had before (if any), so your terminal looks exactly as it did. Zera
// keeps the percentages and reset times, nothing else, and never touches Claude Code's login.

struct ClaudeUsage: Codable, Equatable {
    struct Window: Codable, Equatable {
        /// 0…1 of the limit spent.
        var used: Double
        var resetsAt: Date

        /// "1h 12m", "3d 4h" — never "0m" while it hasn't reset.
        func resetsIn(at now: Date = Date()) -> String { VitalsFormat.duration(max(60, resetsAt.timeIntervalSince(now))) }
        var percent: Int { Int((used * 100).rounded()) }
        /// Past its reset: nothing spent yet; the next window starts with your next message.
        func hasReset(at now: Date = Date()) -> Bool { resetsAt <= now }

        /// The fuller of two readings of the same window (usage only goes up within one; an
        /// idle session reports what it last saw), or the later window.
        static func newest(_ old: Window?, _ new: Window?) -> Window? {
            guard let new = new else { return old }
            guard let old = old else { return new }
            if abs(new.resetsAt.timeIntervalSince(old.resetsAt)) < 60 { return new.used >= old.used ? new : old }
            return new.resetsAt > old.resetsAt ? new : old
        }
    }

    var fiveHour: Window?
    var week: Window?
    /// When Claude Code last reported it.
    var readAt: Date

    var isEmpty: Bool { fiveHour == nil && week == nil }

    /// As it stands now: a window that has reset since reads 0%, not what it was before.
    func current(at now: Date = Date()) -> ClaudeUsage {
        var u = self
        if let w = u.fiveHour, w.hasReset(at: now) { u.fiveHour?.used = 0 }
        if let w = u.week, w.hasReset(at: now) { u.week?.used = 0 }
        return u
    }

    /// A new reading on top of this one, from any session: each window keeps its fullest
    /// reading, and one the new reading leaves out stays as it was.
    func merged(with new: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(fiveHour: Window.newest(fiveHour, new.fiveHour), week: Window.newest(week, new.week), readAt: max(readAt, new.readAt))
    }

    /// "5h 23% · week 41%"
    var summary: String {
        var parts: [String] = []
        if let w = fiveHour { parts.append("5h \(w.percent)%") }
        if let w = week { parts.append("week \(w.percent)%") }
        return parts.joined(separator: " · ")
    }

    /// For VoiceOver: "5-hour limit 23%, resets in 1h 12m. Weekly limit 41%, …"
    var spoken: String {
        var parts: [String] = []
        for (name, w) in [("5-hour limit", fiveHour), ("weekly limit", week)] {
            guard let w = w else { continue }
            parts.append("\(name) \(w.percent)%" + (w.hasReset() ? "" : ", resets in \(w.resetsIn())"))
        }
        return parts.joined(separator: ". ")
    }

    /// From the JSON Claude Code hands its status line; nil when it carries no plan usage
    /// (an API key, or before the session's first reply).
    static func parse(statusLine data: Data, at now: Date = Date()) -> ClaudeUsage? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = obj["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = limits[key] as? [String: Any],
                  let pct = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return Window(used: max(0, pct) / 100, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let u = ClaudeUsage(fiveHour: window("five_hour"), week: window("seven_day"), readAt: now)
        return u.isEmpty ? nil : u
    }
}

@MainActor
final class ClaudeUsageService {
    static let shared = ClaudeUsageService()

    nonisolated static let changed = Notification.Name("ClaudeUsageChanged")

    private static let storeKey = "claude.usage"
    private static let homeKey = "claude.usage.home"
    private static let sessionsKey = "claude.usage.sessions"

    private let fm = FileManager.default
    private var stored: ClaudeUsage?
    private var watcher: FolderWatcher?

    private var base: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zera", isDirectory: true)
    }
    private var usageDir: URL { base.appendingPathComponent("hooks/usage", isDirectory: true) }
    /// Your own status line command, which the script runs after handing Zera the numbers.
    private var nextCommandURL: URL { usageDir.appendingPathComponent("next-command") }
    /// Your whole status line setting, put back as it was when you stop tracking.
    private var previousURL: URL { usageDir.appendingPathComponent("previous-statusline.json") }
    var scriptURL: URL { base.appendingPathComponent("zera-statusline.sh") }
    private var settingsURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json") }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey) {
            stored = try? JSONDecoder().decode(ClaudeUsage.self, from: data)
        }
    }

    /// The last reading as it stands now (a window that has reset since reads 0%).
    var usage: ClaudeUsage? { stored?.current() }

    // MARK: Where it shows

    var showOnHome: Bool {
        get { UserDefaults.standard.object(forKey: Self.homeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.homeKey); NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var showInSessions: Bool {
        get { UserDefaults.standard.object(forKey: Self.sessionsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.sessionsKey); NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    /// Home shows the strip once you track usage (even before the first reading).
    var homeStripVisible: Bool { showOnHome && isInstalled }
    /// The Claude sessions header adds "5h 23% · week 41%" when there's a reading.
    var sessionsSummary: String? {
        guard let u = usage, showInSessions, isInstalled else { return nil }
        return u.summary
    }

    // MARK: Reading

    func start() {
        refreshScriptIfNeeded()
        try? fm.createDirectory(at: usageDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        watcher = FolderWatcher(usageDir) { [weak self] in Task { @MainActor in self?.poll() } }
        poll()
    }

    /// Each status-line invocation publishes its own atomic file. Drain the queue before
    /// notifying views, so an idle session cannot overwrite a busier session's reading.
    nonisolated static func drainReadings(in directory: URL) -> [ClaudeUsage] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ($0.lastPathComponent.hasPrefix("reading-") && $0.pathExtension == "json") || $0.lastPathComponent == "latest.json" }.compactMap { file in
            let data = try? Data(contentsOf: file)
            try? fm.removeItem(at: file)
            return data.flatMap { ClaudeUsage.parse(statusLine: $0) }
        }
    }

    private func poll() {
        let readings = Self.drainReadings(in: usageDir)
        guard !readings.isEmpty else { return }
        var merged = stored?.current()
        for reading in readings { merged = merged.map { $0.merged(with: reading) } ?? reading }
        stored = merged
        if let encoded = merged.flatMap({ try? JSONEncoder().encode($0) }) {
            UserDefaults.standard.set(encoded, forKey: Self.storeKey)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    var freshnessLabel: String {
        guard let u = usage else { return "Waiting for Claude's next reply" }
        return "\(Date().timeIntervalSince(u.readAt) > 900 ? "Last reading" : "Updated") \(relativeTime(u.readAt))"
    }

    private var previewing = false

    /// Shows a sample reading without reading anything (the screen renders).
    func preview(_ u: ClaudeUsage?) {
        previewing = u != nil
        stored = u
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Installing the status line

    nonisolated static let script = """
    #!/bin/bash
    # Zera — Claude Code status line. Claude Code hands its status line your plan's usage (the
    # 5-hour and weekly limits, the same numbers as /usage); this drops that JSON where Zera reads
    # and deletes it within a second, then hands it on to the status line you had before (if any)
    # and prints what that prints, so your terminal looks exactly as it did. Nothing is written
    # when Zera isn't running, or when there's no plan usage in it. This script never deletes files.
    umask 077
    BASE="$HOME/Library/Application Support/Zera/hooks/usage"
    INPUT="$(cat)"
    case "$INPUT" in
      *'"rate_limits"'*)
        if pgrep -x Zera >/dev/null 2>&1; then
          mkdir -p -m 700 "$BASE"
          if PENDING="$(mktemp "$BASE/reading-XXXXXX")"; then
            printf '%s' "$INPUT" > "$PENDING" && mv -f "$PENDING" "$PENDING.json"
          fi
        fi ;;
    esac
    NEXT="$(cat "$BASE/next-command" 2>/dev/null)"
    if [ -n "$NEXT" ]; then printf '%s\\n' "$INPUT" | /bin/sh -c "$NEXT"; fi
    exit 0
    """

    nonisolated static func isOurs(_ line: [String: Any]?) -> Bool { (line?["command"] as? String ?? "").contains("zera-statusline") }

    /// Puts Zera's script in place of the status line you have, keeping its other settings
    /// (padding and the like). Returns the new settings and the status line it stood in for
    /// (nil when there was none, or it was Zera's already).
    nonisolated static func installing(into json: [String: Any], script: URL) -> (json: [String: Any], previous: [String: Any]?) {
        var json = json
        let current = json["statusLine"] as? [String: Any]
        let previous = isOurs(current) ? nil : current
        var line = current ?? [:]
        line["type"] = "command"
        line["command"] = "\"\(script.path)\""
        json["statusLine"] = line
        return (json, previous)
    }

    /// Puts your own status line back (or none). If something else has taken the status line
    /// since, it's yours now and stays as it is.
    nonisolated static func removing(from json: [String: Any], restoring previous: [String: Any]?) -> [String: Any] {
        var json = json
        guard isOurs(json["statusLine"] as? [String: Any]) else { return json }
        if let previous = previous { json["statusLine"] = previous } else { json.removeValue(forKey: "statusLine") }
        return json
    }

    private var settingsHasEntry: Bool {
        guard let json = (try? ClaudeSettingsFile.read(settingsURL)) ?? nil else { return false }
        return Self.isOurs(json["statusLine"] as? [String: Any])
    }

    /// Read from ~/.claude/settings.json at most every few seconds: Home and the sessions header
    /// ask on every layout and tick.
    var isInstalled: Bool {
        if previewing { return true }
        if Date().timeIntervalSince(installedCheckedAt) > 5 {
            installedCache = fm.fileExists(atPath: scriptURL.path) && settingsHasEntry
            installedCheckedAt = Date()
        }
        return installedCache
    }
    private var installedCache = false
    private var installedCheckedAt = Date.distantPast

    private func refreshScriptIfNeeded() {
        guard settingsHasEntry, (try? String(contentsOf: scriptURL, encoding: .utf8)) != Self.script else { return }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        try? Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Sets Zera's script as Claude Code's status line in ~/.claude/settings.json, leaving
    /// everything else untouched; your own status line runs after it.
    func install() throws {
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.createDirectory(at: usageDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let (json, previous) = Self.installing(into: try ClaudeSettingsFile.read(settingsURL) ?? [:], script: scriptURL)
        if let previous = previous {
            try JSONSerialization.data(withJSONObject: previous, options: [.prettyPrinted, .sortedKeys]).write(to: previousURL, options: .atomic)
            try (previous["command"] as? String ?? "").write(to: nextCommandURL, atomically: true, encoding: .utf8)
        } else if !settingsHasEntry {
            // No status line of your own: Zera's prints nothing.
            try? fm.removeItem(at: previousURL)
            try? fm.removeItem(at: nextCommandURL)
        }
        try ClaudeSettingsFile.write(json, to: settingsURL)
        installedCheckedAt = .distantPast
        start()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func uninstall() throws {
        guard let json = try ClaudeSettingsFile.read(settingsURL) else { return }
        let previous = (try? Data(contentsOf: previousURL)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        try ClaudeSettingsFile.write(Self.removing(from: json, restoring: previous), to: settingsURL)
        try? fm.removeItem(at: scriptURL)
        try? fm.removeItem(at: previousURL)
        try? fm.removeItem(at: nextCommandURL)
        _ = Self.drainReadings(in: usageDir)
        stored = nil
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
        installedCheckedAt = .distantPast
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
