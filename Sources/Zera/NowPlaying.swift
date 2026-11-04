import AppKit

// MARK: - Now playing
//
// Spotify and Music tell everyone what they play through distributed notifications; Zera only
// listens. One AppleScript per track change fetches what the notification lacks (artwork, the
// exact position) and three more drive play / pause / next / previous. No polling, no private
// frameworks, nothing runs while neither app is open.

struct NowPlayingTrack: Equatable {
    enum Source: String, CaseIterable {
        case spotify, music
        var bundleID: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .music: return "com.apple.Music"
            }
        }
        /// The name AppleScript addresses.
        var appName: String {
            switch self {
            case .spotify: return "Spotify"
            case .music: return "Music"
            }
        }
        var title: String {
            switch self {
            case .spotify: return "Spotify"
            case .music: return "Music"
            }
        }
    }

    var source: Source
    /// Spotify's track id or Music's persistent id; name·artist·album when neither is known.
    var id: String
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
    /// Seconds (0 when unknown).
    var duration: TimeInterval
    /// Seconds into the track at `positionAt`.
    var position: TimeInterval
    var positionAt: Date
    var isPlaying: Bool

    /// Where the track is now, assuming it kept playing since `positionAt`.
    func estimatedPosition(at now: Date = Date()) -> TimeInterval {
        guard isPlaying else { return position }
        let elapsed = max(0, now.timeIntervalSince(positionAt))
        return duration > 0 ? min(duration, position + elapsed) : position + elapsed
    }
}

/// What one detail fetch brought back (parsed off the main thread).
private struct NowPlayingDetails {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var isPlaying: Bool
    var isStopped: Bool
    var id: String
    var artworkURL: String?
    var artworkData: Data?
}

@MainActor
final class NowPlayingService {
    static let shared = NowPlayingService()

    /// Posted whenever `track` changes (new track, play / pause, artwork arrived, source quit).
    nonisolated static let changed = Notification.Name("ZeraNowPlayingChanged")

    /// A different track arrived within a few seconds of a skip; userInfo["forward"] (Bool).
    nonisolated static let skipped = Notification.Name("ZeraNowPlayingSkipped")

    private(set) var track: NowPlayingTrack? {
        didSet {
            guard track != oldValue else { return }
            NotificationCenter.default.post(name: Self.changed, object: nil)
            if let t = track, t.id != oldValue?.id, let at = skipAt, Date().timeIntervalSince(at) < 4 {
                skipAt = nil
                NotificationCenter.default.post(name: Self.skipped, object: nil, userInfo: ["forward": skipForward])
            }
        }
    }
    private var skipAt: Date?
    private var skipForward = true

    /// A next / previous went out (from Zera or the media keys): the next new track peeks.
    func noteSkip(forward: Bool) { skipAt = Date(); skipForward = forward }

    private var started = false
    private let scriptQueue = DispatchQueue(label: "ai.zera.nowplaying", qos: .userInitiated)
    /// One generation per source: a fetch that was overtaken by a newer one is dropped.
    private var generation: [NowPlayingTrack.Source: Int] = [:]
    private var artworkCache: [String: NSImage] = [:]
    private var artworkOrder: [String] = []
    private static let artworkCacheLimit = 24

    private init() {}

    /// Position right now, for progress bars driven by the shared clock.
    var estimatedPosition: TimeInterval { track?.estimatedPosition() ?? 0 }

    /// Call once at launch. Seeds from whichever player is already open; otherwise just listens.
    func start() {
        guard !started else { return }
        started = true
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(spotifyChanged(_:)), name: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)
        dnc.addObserver(self, selector: #selector(musicChanged(_:)), name: Notification.Name("com.apple.Music.playerInfo"), object: nil)
        dnc.addObserver(self, selector: #selector(musicChanged(_:)), name: Notification.Name("com.apple.iTunes.playerInfo"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        for source in NowPlayingTrack.Source.allCases where Self.isRunning(source) {
            fetchDetails(for: source, wantArtwork: true)
        }
    }

    // MARK: Controls

    func playPause() { send("playpause") }
    func next() { noteSkip(forward: true); send("next track") }
    func previous() { noteSkip(forward: false); send("previous track") }

    private func send(_ verb: String) {
        guard let source = track?.source, Self.isRunning(source) else { return }
        let script = "tell application \"\(source.appName)\" to \(verb)"
        scriptQueue.async { _ = Self.run(script) }
    }

    // MARK: Notifications

    @objc private func spotifyChanged(_ note: Notification) {
        apply(note.userInfo ?? [:], from: .spotify)
    }

    @objc private func musicChanged(_ note: Notification) {
        apply(note.userInfo ?? [:], from: .music)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let current = track, app.bundleIdentifier == current.source.bundleID else { return }
        track = nil
    }

    private func apply(_ info: [AnyHashable: Any], from source: NowPlayingTrack.Source) {
        let state = (info["Player State"] as? String ?? "").lowercased()
        let name = info["Name"] as? String ?? ""
        if state == "stopped" || state.isEmpty || name.isEmpty {
            if track?.source == source { track = nil }
            return
        }
        let playing = state == "playing"
        // A paused player never displaces the other one while it is playing.
        if let current = track, current.source != source, current.isPlaying, !playing { return }

        let artist = info["Artist"] as? String ?? ""
        let album = info["Album"] as? String ?? ""
        let id: String
        switch source {
        case .spotify: id = info["Track ID"] as? String ?? "\(name)·\(artist)·\(album)"
        case .music: id = (info["PersistentID"] as? NSNumber).map { $0.stringValue } ?? "\(name)·\(artist)·\(album)"
        }
        var duration: TimeInterval = 0
        if let ms = info[source == .spotify ? "Duration" : "Total Time"] as? NSNumber { duration = ms.doubleValue / 1000 }
        let reported = (info["Playback Position"] as? NSNumber)?.doubleValue
        let same = track?.source == source && track?.id == id
        let position = reported ?? (same ? (track?.estimatedPosition() ?? 0) : 0)
        track = NowPlayingTrack(source: source, id: id, title: name, artist: artist, album: album,
                                artwork: same ? track?.artwork : nil,
                                duration: duration > 0 ? duration : (same ? (track?.duration ?? 0) : 0),
                                position: position, positionAt: Date(), isPlaying: playing)
        // Spotify says where it is; Music doesn't, so each of its changes asks once.
        if !same || reported == nil { fetchDetails(for: source, wantArtwork: !same || track?.artwork == nil) }
    }

    // MARK: AppleScript

    nonisolated static func isRunning(_ source: NowPlayingTrack.Source) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }

    private func fetchDetails(for source: NowPlayingTrack.Source, wantArtwork: Bool) {
        guard Self.isRunning(source) else { return }
        let gen = (generation[source] ?? 0) + 1
        generation[source] = gen
        let script = Self.detailScript(for: source, artwork: wantArtwork)
        scriptQueue.async {
            let details = Self.run(script).flatMap { Self.parseDetails($0, source: source) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { NowPlayingService.shared.applyDetails(details, from: source, generation: gen) }
            }
        }
    }

    private func applyDetails(_ details: NowPlayingDetails?, from source: NowPlayingTrack.Source, generation gen: Int) {
        guard generation[source] == gen else { return }
        guard let d = details, !d.isStopped, !d.title.isEmpty else {
            if track?.source == source, details?.isStopped == true { track = nil }
            return
        }
        if let current = track, current.source != source {
            // Seeding found a second player: the one that is playing wins.
            guard d.isPlaying, !current.isPlaying else { return }
        }
        let same = track?.source == source && track?.id == d.id
        var artwork: NSImage? = same ? track?.artwork : nil
        if let data = d.artworkData, data.count > 64, let image = NSImage(data: data) { artwork = image }
        if artwork == nil, let url = d.artworkURL, let cached = artworkCache[url] { artwork = cached }
        track = NowPlayingTrack(source: source, id: d.id, title: d.title, artist: d.artist, album: d.album, artwork: artwork,
                                duration: d.duration, position: d.position, positionAt: Date(), isPlaying: d.isPlaying)
        if artwork == nil, let url = d.artworkURL, !url.isEmpty { downloadArtwork(url, for: d.id) }
    }

    private func downloadArtwork(_ urlString: String, for id: String) {
        guard let url = URL(string: urlString) else { return }
        Task { @MainActor [weak self] in
            guard let result = try? await URLSession.shared.data(from: url), let image = NSImage(data: result.0) else { return }
            guard let self = self else { return }
            self.artworkCache[urlString] = image
            self.artworkOrder.append(urlString)
            while self.artworkOrder.count > Self.artworkCacheLimit {
                self.artworkCache[self.artworkOrder.removeFirst()] = nil
            }
            guard var current = self.track, current.id == id, current.artwork == nil else { return }
            current.artwork = image
            self.track = current
        }
    }

    /// Everything the notification leaves out, in one round trip: a list of
    /// name, artist, album, duration (s), position (s), state, artwork (url or data), id.
    private nonisolated static func detailScript(for source: NowPlayingTrack.Source, artwork: Bool) -> String {
        switch source {
        case .spotify:
            return """
            tell application "Spotify"
                set t to current track
                set st to (player state as string)
                set art to ""
                \(artwork ? "try\n set art to artwork url of t\n end try" : "")
                return {name of t as string, artist of t as string, album of t as string, (duration of t) / 1000, player position, st, art, id of t as string}
            end tell
            """
        case .music:
            return """
            tell application "Music"
                set t to current track
                set st to (player state as string)
                set art to ""
                \(artwork ? "try\n set art to data of artwork 1 of t\n end try" : "")
                return {name of t as string, artist of t as string, album of t as string, duration of t, player position, st, art, persistent ID of t as string}
            end tell
            """
        }
    }

    private nonisolated static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private nonisolated static func parseDetails(_ d: NSAppleEventDescriptor, source: NowPlayingTrack.Source) -> NowPlayingDetails? {
        guard d.numberOfItems >= 8 else { return nil }
        func string(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func number(_ i: Int) -> Double { d.atIndex(i)?.doubleValue ?? 0 }
        let state = string(6).lowercased()
        var details = NowPlayingDetails(title: string(1), artist: string(2), album: string(3), duration: max(0, number(4)),
                                        position: max(0, number(5)), isPlaying: state == "playing",
                                        isStopped: state == "stopped", id: string(8))
        if details.id.isEmpty { details.id = "\(details.title)·\(details.artist)·\(details.album)" }
        if let art = d.atIndex(7) {
            switch source {
            case .spotify: details.artworkURL = art.stringValue
            case .music:
                // A picture descriptor; the empty string of a track without artwork has no bytes.
                if art.data.count > 64 { details.artworkData = art.data }
            }
        }
        return details
    }
}

// MARK: - Home tile

/// Artwork, title / artist, a slim progress bar and three controls. Animates the bar on the shared
/// clock only while it is on screen and the track is playing. Hover lifts it like a list row.
final class NowPlayingWidget: NSView, ZeraAnimating {
    static let height: CGFloat = 96
    var onTap: (() -> Void)?

    private let artwork = NSImageView()
    private let placeholder = IconTile(symbol: "music.note", color: Pal.accent, size: 64, pointSize: 22)
    private let title = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let bar = NowPlayingBar()
    private let bars = LevelBarsView()
    private var levelsRetained = false
    private var previousButton: IconButton!
    private var playButton: IconButton!
    private var nextButton: IconButton!
    private var hovered = false { didSet { restyle() } }
    private var lastSecond = -1

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// False while nothing plays: Home skips the tile in its layout.
    var isAvailable: Bool { NowPlayingService.shared.track != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let p = Pal
        roundLayer(Radius.l)
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 12
        artwork.layer?.cornerCurve = .continuous
        artwork.layer?.masksToBounds = true
        addSubview(artwork)
        placeholder.layer?.cornerRadius = 12
        addSubview(placeholder)
        title.font = Typo.rowTitle; title.textColor = p.text; title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        artist.font = Typo.meta; artist.textColor = p.textSecondary; artist.lineBreakMode = .byTruncatingTail
        addSubview(artist)
        time.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular); time.textColor = p.textTertiary
        addSubview(time)
        addSubview(bar)
        addSubview(bars)
        previousButton = IconButton(symbol: "backward.fill", label: "Previous", target: self, action: #selector(previousTapped))
        playButton = IconButton(symbol: "play.fill", label: "Play", target: self, action: #selector(playTapped))
        nextButton = IconButton(symbol: "forward.fill", label: "Next", target: self, action: #selector(nextTapped))
        addSubview(previousButton)
        addSubview(playButton)
        addSubview(nextButton)
        NotificationCenter.default.addObserver(self, selector: #selector(trackChanged), name: NowPlayingService.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(paletteChanged), name: Palette.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(lyricsChanged), name: LyricsService.changed, object: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        restyle()
        trackChanged()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        NotificationCenter.default.removeObserver(self)
        if levelsRetained { SystemAudioLevels.shared.release() }
    }

    @objc private func previousTapped() { NowPlayingService.shared.previous() }
    @objc private func playTapped() { NowPlayingService.shared.playPause() }
    @objc private func nextTapped() { NowPlayingService.shared.next() }

    @objc private func paletteChanged() {
        let p = Pal
        title.textColor = p.text; artist.textColor = p.textSecondary; time.textColor = p.textTertiary
        lyricIndex = -2; updateProgress()
        restyle(); bar.needsDisplay = true
    }

    @objc private func lyricsChanged() { lyricIndex = -2; updateProgress() }

    /// The artist line, or the lyric being sung (-1 = artist shown, -2 = recheck).
    private var lyricIndex = -2
    private var artistLine: String {
        guard let t = NowPlayingService.shared.track else { return "" }
        return t.artist.isEmpty ? t.source.title : "\(t.artist) · \(t.source.title)"
    }

    private func showLyric(at position: TimeInterval, playing: Bool) {
        let current = playing ? LyricsService.shared.line(at: position) : nil
        let index = current?.index ?? -1
        guard index != lyricIndex else { return }
        lyricIndex = index
        if let line = current?.text {
            artist.stringValue = "♪ " + line
            artist.textColor = Pal.accent
        } else {
            artist.stringValue = artistLine
            artist.textColor = Pal.textSecondary
        }
    }

    @objc private func trackChanged() {
        let t = NowPlayingService.shared.track
        title.stringValue = t?.title ?? "Nothing playing"
        lyricIndex = -2
        artist.stringValue = artistLine
        artwork.image = t?.artwork
        artwork.isHidden = t?.artwork == nil
        placeholder.isHidden = t?.artwork != nil
        let playing = t?.isPlaying ?? false
        playButton.setSymbol(playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play")
        setAccessibilityLabel(t.map { "Now playing: \($0.title), \($0.artist)" } ?? "Nothing playing")
        lastSecond = -1
        updateProgress()
        updateClock()
    }

    private func restyle() {
        let p = Pal
        layer?.backgroundColor = (hovered && onTap != nil ? p.surfaceHover : p.surfaceRow).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.divider.cgColor
    }

    // MARK: Clock

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateClock() }
    override func viewDidHide() { super.viewDidHide(); updateClock() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateClock() }

    private func updateClock() {
        let playing = NowPlayingService.shared.track?.isPlaying ?? false
        let live = !(window == nil || !playing || isHiddenOrHasHiddenAncestor)
        if live { ZeraAnimationClock.shared.add(self) } else { ZeraAnimationClock.shared.remove(self) }
        bars.isHidden = !playing
        // Real levels only while this tile is on screen and a track plays.
        if live != levelsRetained {
            levelsRetained = live
            if live { SystemAudioLevels.shared.retain() } else { SystemAudioLevels.shared.release() }
        }
    }

    func advanceAnimation(at now: TimeInterval) {
        updateProgress()
        bars.step(level: SystemAudioLevels.shared.level, now: now)
    }

    private func updateProgress() {
        guard let t = NowPlayingService.shared.track else { bar.fraction = 0; time.stringValue = ""; return }
        let position = t.estimatedPosition()
        bar.fraction = t.duration > 0 ? CGFloat(position / t.duration) : 0
        showLyric(at: position, playing: t.isPlaying)
        let second = Int(position)
        if second != lastSecond {
            lastSecond = second
            time.stringValue = t.duration > 0 ? "\(Self.clock(position)) / \(Self.clock(t.duration))" : Self.clock(position)
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let h = bounds.height, pad = Space.m
        let art: CGFloat = 64
        artwork.frame = NSRect(x: pad, y: (h - art) / 2, width: art, height: art)
        placeholder.frame = artwork.frame
        let b = Metrics.control
        var right = bounds.width - pad
        nextButton.frame = NSRect(x: right - b, y: (h - b) / 2, width: b, height: b); right -= b + Space.xs
        playButton.frame = NSRect(x: right - b, y: (h - b) / 2, width: b, height: b); right -= b + Space.xs
        previousButton.frame = NSRect(x: right - b, y: (h - b) / 2, width: b, height: b); right -= b + Space.l
        let x = artwork.frame.maxX + Space.m
        let w = max(40, right - x)
        title.frame = NSRect(x: x, y: 18, width: w, height: 18)
        artist.frame = NSRect(x: x, y: 38, width: w, height: 16)
        bar.frame = NSRect(x: x, y: 62, width: w, height: 4)
        time.frame = NSRect(x: x, y: 70, width: max(20, w - 28), height: 14)
        bars.frame = NSRect(x: x + w - 22, y: 69, width: 22, height: 14)
    }

    // MARK: Hover & tap

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetHoverTracking()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showOutputMenu(event); return }
        onTap?()
    }
    override func rightMouseDown(with event: NSEvent) { showOutputMenu(event) }

    /// Right-click: "Play on…" every output device, the current one ticked.
    private func showOutputMenu(_ event: NSEvent) {
        let current = AudioOutputs.current
        let devices = AudioOutputs.all()
        guard !devices.isEmpty else { return }
        let menu = NSMenu()
        let header = NSMenuItem(title: "Play on", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for d in devices {
            menu.addItem(ClosureMenuItem(d.name, symbol: d.id == current ? "checkmark" : "speaker.wave.2", checked: d.id == current) {
                AudioOutputs.select(d.id)
            })
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func resetCursorRects() { if onTap != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// The slim progress line: a track one step up from the row, the accent for what has played.
private final class NowPlayingBar: NSView {
    private var value: CGFloat = 0
    /// 0…1; redraws only when the fill moves by half a point or more.
    var fraction: CGFloat {
        get { value }
        set {
            let clamped = max(0, min(1, newValue))
            let moved = abs(clamped - value) * bounds.width >= 0.5 || (clamped == 0) != (value == 0)
            value = clamped
            if moved { needsDisplay = true }
        }
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let r = bounds.height / 2
        p.surfaceStrong.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let w = bounds.width * fraction
        guard w > 0 else { return }
        let fill = NSRect(x: 0, y: 0, width: max(bounds.height, w), height: bounds.height)
        NSGradient(starting: p.accent, ending: p.accentDeep)?.draw(in: NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r), angle: 0)
    }
}
