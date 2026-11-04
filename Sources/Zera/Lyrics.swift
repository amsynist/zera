import AppKit

/// One timed line of synced lyrics.
struct LyricLine: Equatable {
    let time: TimeInterval
    let text: String
}

// MARK: - Synced lyrics
//
// Optional (off by default, since it sends the song's title and artist to lrclib.net, a free
// public lyrics database). Fetched once per track and cached for the session; the Home music
// tile shows the current line in place of the artist while the song plays.
final class LyricsService {
    static let shared = LyricsService()
    static let changed = Notification.Name("ZeraLyricsChanged")
    private static let key = "zera.music.lyrics"

    private(set) var lines: [LyricLine] = []
    private var trackID: String?
    private var cache: [String: [LyricLine]] = [:]
    private var observer: NSObjectProtocol?
    private var fetching: URLSessionDataTask?

    private init() {}

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
            trackID = nil
            if newValue { refresh() } else { set([]) }
        }
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NowPlayingService.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private typealias TrackInfo = (id: String, title: String, artist: String, album: String, duration: TimeInterval)

    private func refresh() {
        // Plain values out of the main-actor service (the track itself carries an image).
        let track: TrackInfo? = MainActor.assumeIsolated {
            NowPlayingService.shared.track.map { ($0.id, $0.title, $0.artist, $0.album, $0.duration) }
        }
        guard enabled, let t = track, !t.title.isEmpty else {
            trackID = nil
            if !lines.isEmpty { set([]) }
            return
        }
        guard t.id != trackID else { return }
        trackID = t.id
        fetching?.cancel()
        if let cached = cache[t.id] { set(cached); return }
        set([])
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "track_name", value: t.title), URLQueryItem(name: "artist_name", value: t.artist)]
        if !t.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: t.album)) }
        if t.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(t.duration.rounded())))) }
        c.queryItems = items
        guard let url = c.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Zera (https://github.com/amsynist/zera)", forHTTPHeaderField: "User-Agent")
        let id = t.id
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let parsed: [LyricLine] = data
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                .flatMap { $0["syncedLyrics"] as? String }
                .map(Self.parseLRC) ?? []
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.cache[id] = parsed
                if self.cache.count > 40 { self.cache.removeAll(); self.cache[id] = parsed }
                if self.trackID == id { self.set(parsed) }
            }
        }
        fetching = task
        task.resume()
    }

    private func set(_ new: [LyricLine]) {
        guard new != lines else { return }
        lines = new
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// The line being sung at `position` (index and text), or nil before the first one / in a
    /// gap marked by an empty line.
    func line(at position: TimeInterval) -> (index: Int, text: String)? {
        Self.line(in: lines, at: position)
    }

    static func line(in lines: [LyricLine], at position: TimeInterval) -> (index: Int, text: String)? {
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0, !lines[found].text.isEmpty else { return nil }
        return (found, lines[found].text)
    }

    /// "[mm:ss.xx] text" lines (several stamps per line allowed), sorted by time.
    static func parseLRC(_ s: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in s.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var stamps: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) { stamps.append(m * 60 + sec) }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append(LyricLine(time: t, text: text)) }
        }
        return out.sorted { $0.time < $1.time }
    }
}

/// Settings → Notch: a slow wave along the notch in the album art's colour while music plays.
/// Off by default (it's a continuous animation, cheap but not free).
enum MusicWave {
    private static let key = "zera.music.wave"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: NowPlayingService.changed, object: nil)
        }
    }
}
