import AppKit

// MARK: - Teleprompter
//
// A script you paste in, read back to you on a slow roll: play / pause, speed, font size and a
// mirror for a glass rig. Lines beginning with `#` are chapters you can jump between. The roll
// lives on the Teleprompter screen in the island and can be detached into a small floating glass
// window that stays above everything; both rolls read the same script and keep the same place.
//
// Nothing here owns a timer: the scroll is advanced by `ZeraAnimationClock` ticks, so the roll
// moves only while a window showing it is on screen, and stops with it.

// MARK: Script

/// One script to read. Chapters are the lines that begin with `#`.
struct TeleprompterScript: Codable, Equatable {
    var id: UUID
    var title: String
    var text: String
    var updated: Date

    init(id: UUID = UUID(), title: String = "Untitled", text: String = "", updated: Date = Date()) {
        self.id = id; self.title = title; self.text = text; self.updated = updated
    }

    /// Reads older or hand-edited files too: only the text is required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
    }

    /// The chapter headings, each with the UTF-16 offset (NSString / NSAttributedString
    /// indexing) of the start of its line in `text`.
    var chapters: [(title: String, offset: Int)] { Self.chapters(in: text) }

    static func chapters(in text: String) -> [(title: String, offset: Int)] {
        var result: [(title: String, offset: Int)] = []
        let ns = text as NSString
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            guard line.length > 0 else { break }
            if let title = headingTitle(ns.substring(with: line)) { result.append((title, line.location)) }
            location = NSMaxRange(line)
        }
        return result
    }

    /// "## Intro " → "Intro"; nil when the line is not a heading.
    static func headingTitle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Chapter" : title
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// A play / pause / jump sent from one roll so the other (island or detached window) follows.
enum TeleprompterTransport {
    case play(position: CGFloat)
    case pause(position: CGFloat)
    case restart
    case jump(chapter: Int)
    case seek(position: CGFloat)
}

// MARK: Store

/// The file's shape.
private struct TeleprompterSaved: Codable {
    var scripts: [TeleprompterScript]
    var current: UUID?
    var speed: Double?
    var fontSize: CGFloat?
    var mirrored: Bool?
}

/// Scripts, the one being read, and the reading settings, in Application Support/Zera/teleprompter.json.
/// Where you are in each script is kept in memory only, so a relaunch starts a script from the top.
@MainActor
final class TeleprompterStore {
    static let shared = TeleprompterStore(url: TeleprompterStore.defaultURL)
    /// Scripts, the current script or a setting changed.
    nonisolated static let changed = Notification.Name("TeleprompterStore.changed")
    /// A roll played, paused or jumped; `object` is the roll that did it, `userInfo[transportKey]`
    /// the `TeleprompterTransport`.
    nonisolated static let transport = Notification.Name("TeleprompterStore.transport")
    nonisolated static let transportKey = "transport"

    nonisolated static let speedRange: ClosedRange<Double> = 0.5...3.0
    nonisolated static let fontRange: ClosedRange<CGFloat> = 18...64
    nonisolated static let defaultSpeed: Double = 1.0
    nonisolated static let defaultFontSize: CGFloat = 30

    private(set) var scripts: [TeleprompterScript] = []
    private(set) var currentID: UUID?
    var current: TeleprompterScript? { scripts.first { $0.id == currentID } }
    /// Reading speed, 0.5× … 3×.
    var speed: Double = TeleprompterStore.defaultSpeed {
        didSet {
            speed = min(Self.speedRange.upperBound, max(Self.speedRange.lowerBound, (speed * 100).rounded() / 100))
            if loaded, speed != oldValue { saveAndPost() }
        }
    }
    /// Text size on the roll, 18 … 64 pt.
    var fontSize: CGFloat = TeleprompterStore.defaultFontSize {
        didSet {
            fontSize = min(Self.fontRange.upperBound, max(Self.fontRange.lowerBound, fontSize.rounded()))
            if loaded, fontSize != oldValue { saveAndPost() }
        }
    }
    /// Flipped left-to-right, for a beam-splitter glass in front of a camera.
    var mirrored = false { didSet { if loaded, mirrored != oldValue { saveAndPost() } } }
    /// Whether the script is rolling, shared by every roll on screen.
    private(set) var isPlaying = false

    private var positions: [UUID: CGFloat] = [:]
    private var loaded = false
    private let url: URL?
    private let saveQueue = DispatchQueue(label: "ai.zera.teleprompter-save", qos: .utility)

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera", isDirectory: true).appendingPathComponent("teleprompter.json")
    }

    /// `url` nil keeps everything in memory (tests).
    init(url: URL?) {
        self.url = url
        load()
        loaded = true
    }

    // MARK: Scripts

    @discardableResult
    func newScript(title: String = "Untitled", text: String = "") -> TeleprompterScript {
        let s = TeleprompterScript(title: Self.uniqueTitle(title, among: scripts), text: text)
        scripts.insert(s, at: 0)
        currentID = s.id
        saveAndPost()
        return s
    }

    /// Replaces a script by id (title or text edited); unknown ids are added.
    func update(_ script: TeleprompterScript) {
        var s = script
        s.updated = Date()
        if let i = scripts.firstIndex(where: { $0.id == s.id }) {
            guard scripts[i].title != s.title || scripts[i].text != s.text else { return }
            scripts[i] = s
        } else {
            scripts.insert(s, at: 0)
        }
        saveAndPost()
    }

    func delete(id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts.remove(at: i)
        positions[id] = nil
        if currentID == id { currentID = scripts.first?.id }
        saveAndPost()
    }

    func select(id: UUID) {
        guard currentID != id, scripts.contains(where: { $0.id == id }) else { return }
        currentID = id
        saveAndPost()
    }

    // MARK: Position and transport

    /// Where the roll is in a script, in points from the top; 0 for one never read.
    func position(for id: UUID) -> CGFloat { positions[id] ?? 0 }
    func setPosition(_ y: CGFloat, for id: UUID) { positions[id] = y }

    /// Tells every other roll what this one did, and remembers whether we are playing.
    func broadcast(_ t: TeleprompterTransport, from sender: AnyObject?) {
        switch t {
        case .play: isPlaying = true
        case .pause: isPlaying = false
        case .restart, .jump, .seek: break
        }
        NotificationCenter.default.post(name: Self.transport, object: sender, userInfo: [Self.transportKey: t])
    }

    // MARK: Persistence

    private static let sample = """
    # Welcome
    This is your teleprompter. Paste a script in Edit, then switch to Roll and press play — or tap space.

    Lines that start with a hash sign become chapters: tap one to jump there, or use the left and right arrow keys.

    # Reading
    The bright band is the reading line. Up and down arrows change the speed; A− and A+ change the size of the text.

    # Detach
    Detach floats the roll in a small window that stays above everything, so you can read while you present.
    """

    private func load() {
        guard let url = url else { seed(); return }
        guard let data = try? Data(contentsOf: url) else { seed(); return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let saved = try? dec.decode(TeleprompterSaved.self, from: data) else {
            // An unreadable file is set aside rather than written over.
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("broken-\(stamp).json"))
            seed()
            return
        }
        scripts = saved.scripts
        if let id = saved.current, scripts.contains(where: { $0.id == id }) { currentID = id } else { currentID = scripts.first?.id }
        speed = saved.speed ?? Self.defaultSpeed
        fontSize = saved.fontSize ?? Self.defaultFontSize
        mirrored = saved.mirrored ?? false
    }

    private func seed() {
        let s = TeleprompterScript(title: "Welcome", text: Self.sample)
        scripts = [s]
        currentID = s.id
    }

    private func save() {
        guard let url = url else { return }
        let snapshot = TeleprompterSaved(scripts: scripts, current: currentID, speed: speed, fontSize: fontSize, mirrored: mirrored)
        saveQueue.async { Self.write(snapshot, to: url) }
    }

    private nonisolated static func write(_ saved: TeleprompterSaved, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(saved) { try? data.write(to: url, options: .atomic) }
    }

    /// Drain queued edits on application shutdown, just like TaskStore and ClipboardStore.
    func flush() { save(); saveQueue.sync {} }

    private func saveAndPost() {
        save()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private static func uniqueTitle(_ title: String, among scripts: [TeleprompterScript]) -> String {
        let base = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : title
        guard scripts.contains(where: { $0.title == base }) else { return base }
        var n = 2
        while scripts.contains(where: { $0.title == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }
}

// MARK: - Roll

/// The text itself: laid out once by an NSLayoutManager, drawn only where the roll shows it.
private final class RollDocument: NSView {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    /// Room above the first line, so it starts on the reading line; below, so the last reaches it.
    var topInset: CGFloat = 0
    var sideInset: CGFloat = Space.xxl

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        container.lineFragmentPadding = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    func setWidth(_ width: CGFloat) {
        let w = max(10, width - sideInset * 2)
        guard abs(container.size.width - w) > 0.5 else { return }
        container.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
    }

    var textHeight: CGFloat {
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// Top of the line that holds UTF-16 offset `location`, in text coordinates.
    func lineTop(at location: Int) -> CGFloat {
        guard storage.length > 0 else { return 0 }
        layoutManager.ensureLayout(for: container)
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, storage.length - 1))
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    override func draw(_ dirtyRect: NSRect) {
        guard storage.length > 0 else { return }
        let origin = NSPoint(x: sideInset, y: topInset)
        let rect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        guard glyphs.length > 0 else { return }
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}

/// Sits over the roll with the reading band; never takes a click.
private final class RollOverlay: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The scrolling text surface. Shows the store's current script; play / pause / jumps are sent
/// through `TeleprompterStore.transport` so a second roll (the detached window) keeps in step.
final class TeleprompterRoll: NSView, ZeraAnimating {
    /// The script shown. Switching scripts restores where that script was.
    var script: TeleprompterScript? { didSet { scriptDidChange(from: oldValue) } }
    private(set) var isPlaying = false
    var speed: Double = TeleprompterStore.defaultSpeed {
        didSet {
            speed = min(TeleprompterStore.speedRange.upperBound, max(TeleprompterStore.speedRange.lowerBound, speed))
            onProgress?(progress)   // the time left changed
        }
    }
    var fontSize: CGFloat = TeleprompterStore.defaultFontSize {
        didSet {
            fontSize = min(TeleprompterStore.fontRange.upperBound, max(TeleprompterStore.fontRange.lowerBound, fontSize))
            if fontSize != oldValue { rebuildText(); needsLayout = true }
        }
    }
    var mirrored = false { didSet { if mirrored != oldValue { applyMirror() } } }
    /// 0 at the top, 1 when the last line reaches the reading line.
    var progress: Double { maxOffset > 0 ? Double(min(1, max(0, offset / maxOffset))) : 0 }
    var onProgress: ((Double) -> Void)?
    var onPlayStateChange: ((Bool) -> Void)?
    var onChapterChange: ((Int?) -> Void)?
    /// Seconds until the end at this speed; nil with nothing to read.
    var remainingSeconds: TimeInterval? {
        guard let script, script.wordCount > 0 else { return nil }
        return TimeInterval(max(0, maxOffset - offset)) / max(0.01, speed * Double(pixelsPerSecond))
    }
    /// The chapter the reading line is in.
    private(set) var currentChapter: Int?
    var chapterCount: Int { chapterTops.count }
    /// Whether the screen holding this roll is on show. Off, the play state is kept but the roll
    /// leaves the clock; back on, it picks up where the other roll (or itself) got to.
    var engaged = true {
        didSet {
            guard engaged != oldValue else { return }
            if engaged { resync() }
            syncClock()
        }
    }
    /// Fills its own rounded surface (the island); off in the detached window, which has glass.
    var drawsBackdrop = true { didSet { needsDisplay = true; restyle() } }
    /// What dims the text outside the reading band.
    var dimColor = Pal.surfaceRow.withAlphaComponent(0.62) { didSet { restyle() } }

    private let store: TeleprompterStore
    private let scroll = NSScrollView()
    private let document = RollDocument()
    private let overlay = RollOverlay()
    private let dimTop = CALayer()
    private let dimBottom = CALayer()
    private let band = CAGradientLayer()
    private let edgeTop = CAGradientLayer()
    private let edgeBottom = CAGradientLayer()
    private var offset: CGFloat = 0
    private var lastTick: TimeInterval?
    private var seeking: (from: CGFloat, to: CGFloat, start: TimeInterval, duration: TimeInterval)?
    private var programmaticScroll = false
    private var chapterTops: [CGFloat] = []
    private var lineHeight: CGFloat = 40
    private var lastProgress = -1.0

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(store given: TeleprompterStore? = nil) {
        let store = given ?? TeleprompterStore.shared
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        roundLayer(Radius.l)

        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.wantsLayer = true
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)

        overlay.wantsLayer = true
        for l in [dimTop, band, dimBottom, edgeTop, edgeBottom] { overlay.layer?.addSublayer(l) }
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        edgeTop.startPoint = band.startPoint; edgeTop.endPoint = band.endPoint
        edgeBottom.startPoint = band.startPoint; edgeBottom.endPoint = band.endPoint
        addSubview(overlay)
        restyle()

        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: TeleprompterStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(transportPosted(_:)), name: TeleprompterStore.transport, object: nil)
        adopt()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        ZeraAnimationClock.shared.remove(self)
    }

    // MARK: Store

    /// Takes the store's script, settings and play state (without telling other rolls).
    func adopt() {
        speed = store.speed
        fontSize = store.fontSize
        mirrored = store.mirrored
        script = store.current
        if isPlaying != store.isPlaying {
            isPlaying = store.isPlaying
            onPlayStateChange?(isPlaying)
            syncClock()
        }
    }

    @objc private func storeChanged() { adopt() }

    @objc private func transportPosted(_ n: Notification) {
        if let sender = n.object as? TeleprompterRoll, sender === self { return }
        guard let t = n.userInfo?[TeleprompterStore.transportKey] as? TeleprompterTransport else { return }
        switch t {
        case .play(let y):
            seeking = nil
            setOffset(y)
            setPlaying(true)
        case .pause(let y):
            seeking = nil
            setOffset(y)
            setPlaying(false)
        case .restart:
            seek(to: 0)
        case .jump(let i):
            if chapterTops.indices.contains(i) { seek(to: chapterTops[i]) }
        case .seek(let y):
            seeking = nil
            setOffset(y)
        }
    }

    // MARK: Transport

    func play() {
        guard maxOffset > 0 else { return }
        if offset >= maxOffset { setOffset(0) }
        seeking = nil
        setPlaying(true)
        store.broadcast(.play(position: offset), from: self)
    }

    func pause() {
        setPlaying(false)
        store.broadcast(.pause(position: offset), from: self)
    }

    func toggle() { if isPlaying { pause() } else { play() } }

    func restart() {
        seek(to: 0)
        store.broadcast(.restart, from: self)
    }

    func jump(toChapter i: Int) {
        guard chapterTops.indices.contains(i) else { return }
        seek(to: chapterTops[i])
        store.broadcast(.jump(chapter: i), from: self)
    }

    /// The chapter before / after the one being read, for ← and →.
    func jumpToNeighbourChapter(forward: Bool) {
        guard !chapterTops.isEmpty else { return }
        if forward {
            if let i = chapterTops.firstIndex(where: { $0 > offset + 1 }) { jump(toChapter: i) }
        } else {
            if let i = chapterTops.lastIndex(where: { $0 < offset - 1 }) { jump(toChapter: i) } else { restart() }
        }
    }

    private func setPlaying(_ on: Bool) {
        guard on != isPlaying else { return }
        isPlaying = on
        lastTick = nil
        syncClock()
        onPlayStateChange?(on)
    }

    /// Glides there (or lands there at once with Reduce Motion, or off screen).
    private func seek(to y: CGFloat) {
        let target = min(maxOffset, max(0, y))
        guard !Motion.reduced, window != nil, engaged, abs(target - offset) > 1 else {
            seeking = nil
            setOffset(target)
            return
        }
        seeking = (from: offset, to: target, start: CACurrentMediaTime(), duration: 0.38)
        syncClock()
    }

    // MARK: Clock

    private func syncClock() {
        let wants = window != nil && engaged && (isPlaying || seeking != nil)
        if wants {
            ZeraAnimationClock.shared.add(self)
        } else {
            ZeraAnimationClock.shared.remove(self)
            lastTick = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastTick = nil
        if window != nil { resync() }
        syncClock()
    }
    override func viewDidHide() { super.viewDidHide(); ZeraAnimationClock.shared.refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); ZeraAnimationClock.shared.refresh() }

    /// Catches up with where the other roll took the script while this one was away.
    private func resync() {
        guard let id = script?.id else { return }
        let y = store.position(for: id)
        if abs(y - offset) > 0.5 { seeking = nil; setOffset(y) }
    }

    /// Points per second at 1×: about 160 words a minute on an island-wide line.
    private var pixelsPerSecond: CGFloat { fontSize * 0.4 }

    func advanceAnimation(at now: TimeInterval) {
        let dt = min(0.1, max(0, now - (lastTick ?? now)))
        lastTick = now
        if let s = seeking {
            let t = min(1, max(0, (now - s.start) / s.duration))
            let eased = 1 - pow(1 - t, 3)
            setOffset(s.from + (s.to - s.from) * CGFloat(eased))
            if t >= 1 { seeking = nil }
        } else if isPlaying, dt > 0 {
            let next = offset + CGFloat(speed * dt) * pixelsPerSecond
            if next >= maxOffset {
                setOffset(maxOffset)
                pause()   // the end: both rolls stop
            } else {
                setOffset(next)
            }
        }
        if seeking == nil && !isPlaying { syncClock() }
    }

    // MARK: Offset

    private var viewportHeight: CGFloat { max(1, scroll.contentSize.height) }
    private var maxOffset: CGFloat { max(0, document.frame.height - viewportHeight) }

    private func setOffset(_ y: CGFloat) {
        offset = laidOut ? min(maxOffset, max(0, y)) : max(0, y)
        let was = programmaticScroll
        programmaticScroll = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        programmaticScroll = was
        publish()
    }

    @objc private func clipBoundsChanged() {
        guard !programmaticScroll else { return }
        // A trackpad scroll: the roll follows your hand, and so does the other roll.
        seeking = nil
        offset = min(maxOffset, max(0, scroll.contentView.bounds.origin.y))
        publish()
        store.broadcast(.seek(position: offset), from: self)
    }

    private func publish() {
        // Only a roll that is on show may record the place: a hidden one is behind.
        if engaged, window != nil, let id = script?.id { store.setPosition(offset, for: id) }
        let p = progress
        if abs(p - lastProgress) > 0.0005 || p == 0 || p == 1 {
            lastProgress = p
            onProgress?(p)
        }
        let chapter = chapterTops.lastIndex(where: { $0 <= offset + 1 })
        if chapter != currentChapter {
            currentChapter = chapter
            onChapterChange?(chapter)
        }
    }

    // MARK: Text

    private func scriptDidChange(from old: TeleprompterScript?) {
        if old?.id != script?.id {
            rebuildText()
            seeking = nil
            setOffset(script.map { store.position(for: $0.id) } ?? 0)
            lastProgress = -1
            publish()
        } else if old?.text != script?.text {
            rebuildText()
            setOffset(offset)
        }
    }

    private func rebuildText() {
        let p = Pal
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let heading = NSFont.systemFont(ofSize: (fontSize * 0.72).rounded(), weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = (fontSize * 0.3).rounded()
        para.paragraphSpacing = (fontSize * 0.45).rounded()
        para.lineBreakMode = .byWordWrapping
        let headPara = NSMutableParagraphStyle()
        headPara.lineSpacing = para.lineSpacing
        headPara.paragraphSpacing = (fontSize * 0.25).rounded()
        headPara.paragraphSpacingBefore = (fontSize * 0.5).rounded()
        lineHeight = ceil(document.layoutManager.defaultLineHeight(for: font)) + para.lineSpacing

        let out = NSMutableAttributedString()
        var tops: [Int] = []
        let ns = (script?.text ?? "") as NSString
        var location = 0
        while location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            guard range.length > 0 else { break }
            let line = ns.substring(with: range)
            if let title = TeleprompterScript.headingTitle(line) {
                tops.append(out.length)
                out.append(NSAttributedString(string: title.uppercased() + "\n", attributes: [
                    .font: heading, .foregroundColor: p.accent, .kern: 1.2, .paragraphStyle: headPara]))
            } else {
                out.append(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: p.text, .paragraphStyle: para]))
            }
            location = NSMaxRange(range)
        }
        document.storage.setAttributedString(out)
        pendingChapterLocations = tops
        relayoutDocument()
        overlay.isHidden = out.length == 0
        needsDisplay = true
    }

    private var pendingChapterLocations: [Int] = []

    override func layout() {
        super.layout()
        let was = programmaticScroll
        programmaticScroll = true
        scroll.frame = bounds
        overlay.frame = bounds
        relayoutDocument()
        programmaticScroll = was
        setOffset(offset)
        applyMirror()
        layoutOverlay()
    }

    /// Set once the text has been laid out at a real width; until then offsets are kept as given.
    private var laidOut = false

    private var bandTop: CGFloat { (viewportHeight * 0.35).rounded() }
    private var bandHeight: CGFloat { ceil(lineHeight * 1.35) }

    private func relayoutDocument() {
        let width = bounds.width
        guard width > 20 else { return }
        laidOut = true
        let was = programmaticScroll
        programmaticScroll = true
        defer { programmaticScroll = was }
        document.setWidth(width)
        let topInset = bandTop + ((bandHeight - lineHeight) / 2).rounded()
        document.topInset = topInset
        let textHeight = document.textHeight
        // The last line can roll up to the reading line, no further.
        let height = max(viewportHeight, topInset + textHeight + (viewportHeight - topInset - lineHeight))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        if document.frame != frame { document.frame = frame }
        chapterTops = pendingChapterLocations.map { document.lineTop(at: $0) }
        if offset > maxOffset { setOffset(maxOffset) }
        document.needsDisplay = true
    }

    private func layoutOverlay() {
        let w = bounds.width, h = bounds.height
        let top = bandTop, bh = bandHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimTop.frame = CGRect(x: 0, y: 0, width: w, height: top)
        band.frame = CGRect(x: 0, y: top, width: w, height: bh)
        edgeTop.frame = CGRect(x: 0, y: top, width: w, height: 1)
        edgeBottom.frame = CGRect(x: 0, y: top + bh - 1, width: w, height: 1)
        dimBottom.frame = CGRect(x: 0, y: top + bh, width: w, height: max(0, h - top - bh))
        CATransaction.commit()
    }

    private func restyle() {
        let p = Pal
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimTop.backgroundColor = dimColor.cgColor
        dimBottom.backgroundColor = dimColor.cgColor
        let wash = p.accent.withAlphaComponent(0.13).cgColor
        band.colors = [NSColor.clear.cgColor, wash, wash, NSColor.clear.cgColor]
        band.locations = [0, 0.16, 0.84, 1]
        let edge = p.accent.withAlphaComponent(0.45).cgColor
        for l in [edgeTop, edgeBottom] {
            l.colors = [NSColor.clear.cgColor, edge, edge, NSColor.clear.cgColor]
            l.locations = [0, 0.2, 0.8, 1]
        }
        layer?.borderWidth = drawsBackdrop ? 1 : 0
        layer?.borderColor = p.border.cgColor
        CATransaction.commit()
    }

    private func applyMirror() {
        guard let l = scroll.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.transform = mirrored
            ? CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1), CATransform3DMakeTranslation(scroll.bounds.width, 0, 0))
            : CATransform3DIdentity
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        if drawsBackdrop { p.surfaceRow.setFill(); bounds.fill() }
        guard document.storage.length == 0 else { return }
        let text = "Nothing to read yet — paste a script in Edit."
        let attrs: [NSAttributedString.Key: Any] = [.font: Typo.meta, .foregroundColor: p.textTertiary]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2), withAttributes: attrs)
    }

    /// "2 min left", "40 s left", "done".
    static func timeLeftText(_ seconds: TimeInterval?) -> String? {
        guard let s = seconds else { return nil }
        if s < 1 { return "done" }
        if s < 60 { return "\(Int(s.rounded())) s left" }
        return "\(Int((s / 60).rounded(.up))) min left"
    }
}

// MARK: - Chapter chips

/// Small chips, one per chapter; the one being read is lit. Tap to jump.
final class ChapterChips: NSView {
    var titles: [String] = [] { didSet { needsDisplay = true } }
    var current: Int? { didSet { if current != oldValue { needsDisplay = true } } }
    var onTap: ((Int) -> Void)?
    static let height: CGFloat = 24
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private static let font = Typo.count
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Chapters")
    }
    required init?(coder: NSCoder) { fatalError() }

    private func width(_ t: String) -> CGFloat {
        min(160, ceil((t as NSString).size(withAttributes: [.font: Self.font]).width) + 20)
    }

    private func slot(_ i: Int) -> NSRect {
        var x: CGFloat = 0
        for j in 0..<i { x += width(titles[j]) + 6 }
        return NSRect(x: x, y: 0, width: width(titles[i]), height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        for (i, t) in titles.enumerated() {
            let r = slot(i).insetBy(dx: 0.5, dy: 0.5)
            guard r.minX < bounds.width else { break }
            let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            if i == current {
                p.drawSelected(path)
            } else {
                (hoverIndex == i ? p.surfaceHover : p.surface).setFill(); path.fill()
            }
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail; para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: i == current ? p.accent : p.textSecondary, .paragraphStyle: para]
            let th = ceil(Self.font.ascender - Self.font.descender) + 1
            (t as NSString).draw(in: NSRect(x: r.minX + 8, y: r.midY - th / 2, width: r.width - 16, height: th), withAttributes: attrs)
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let pt = convert(event.locationInWindow, from: nil)
        return titles.indices.first { NSPointInRect(pt, slot($0)) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { hoverIndex = index(at: event) }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }
    override func mouseDown(with event: NSEvent) {
        if let i = index(at: event) { onTap?(i) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Transport bar

/// The roll's controls in one row: ⏮ · ▶/⏸ · speed − 1.0× + · A− A+ · Mirror · trailing buttons.
/// Shared by the island screen and the detached window.
final class TeleprompterTransportBar: NSView {
    static let height: CGFloat = Metrics.button
    private let store: TeleprompterStore
    private weak var roll: TeleprompterRoll?
    private var restartButton: IconButton!
    private var playButton: IconButton!
    private var slowerButton: IconButton!
    private var fasterButton: IconButton!
    private var smallerButton: IconButton!
    private var biggerButton: IconButton!
    private let speedLabel = NSTextField(labelWithString: "1.0×")
    private let mirrorLabel = NSTextField(labelWithString: "Mirror")
    private let mirrorToggle = Toggle()
    /// Buttons laid out from the right edge, in order (the first is rightmost).
    var trailing: [NSView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            trailing.forEach { addSubview($0) }
            needsLayout = true
        }
    }
    override var isFlipped: Bool { true }

    init(store: TeleprompterStore, roll: TeleprompterRoll) {
        self.store = store
        self.roll = roll
        super.init(frame: .zero)
        let p = Pal
        restartButton = IconButton(symbol: "backward.end.fill", label: "From the top", target: self, action: #selector(restartTapped))
        playButton = IconButton(symbol: "play.fill", label: "Play", target: self, action: #selector(playTapped))
        slowerButton = IconButton(symbol: "minus", label: "Slower", target: self, action: #selector(slowerTapped))
        fasterButton = IconButton(symbol: "plus", label: "Faster", target: self, action: #selector(fasterTapped))
        smallerButton = IconButton(symbol: "textformat.size.smaller", label: "Smaller text", target: self, action: #selector(smallerTapped))
        biggerButton = IconButton(symbol: "textformat.size.larger", label: "Bigger text", target: self, action: #selector(biggerTapped))
        for b in [restartButton!, playButton!, slowerButton!, fasterButton!, smallerButton!, biggerButton!] { addSubview(b) }
        speedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        speedLabel.textColor = p.text
        speedLabel.alignment = .center
        speedLabel.setAccessibilityLabel("Speed")
        addSubview(speedLabel)
        mirrorLabel.font = Typo.meta
        mirrorLabel.textColor = p.textSecondary
        addSubview(mirrorLabel)
        mirrorToggle.setAccessibilityLabel("Mirror")
        mirrorToggle.onChange = { [weak self] on in self?.store.mirrored = on }
        addSubview(mirrorToggle)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: TeleprompterStore.changed, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func refresh() {
        speedLabel.stringValue = String(format: "%.1f×", store.speed)
        if mirrorToggle.isOn != store.mirrored { mirrorToggle.isOn = store.mirrored }
        slowerButton.isEnabled = store.speed > TeleprompterStore.speedRange.lowerBound + 0.001
        fasterButton.isEnabled = store.speed < TeleprompterStore.speedRange.upperBound - 0.001
        smallerButton.isEnabled = store.fontSize > TeleprompterStore.fontRange.lowerBound + 0.5
        biggerButton.isEnabled = store.fontSize < TeleprompterStore.fontRange.upperBound - 0.5
        setPlaying(roll?.isPlaying ?? store.isPlaying)
    }

    func setPlaying(_ on: Bool) {
        playButton.setSymbol(on ? "pause.fill" : "play.fill", label: on ? "Pause" : "Play")
    }

    @objc private func restartTapped() { roll?.restart() }
    @objc private func playTapped() { roll?.toggle() }
    @objc private func slowerTapped() { store.speed -= 0.25 }
    @objc private func fasterTapped() { store.speed += 0.25 }
    @objc private func smallerTapped() { store.fontSize -= 2 }
    @objc private func biggerTapped() { store.fontSize += 2 }

    override func layout() {
        super.layout()
        let b = Metrics.rowButton, h = bounds.height, y = ((h - b) / 2).rounded()
        var x: CGFloat = 0
        restartButton.frame = NSRect(x: x, y: y, width: b, height: b); x += b + Space.xs
        playButton.frame = NSRect(x: x, y: y, width: b, height: b); x += b + Space.l
        slowerButton.frame = NSRect(x: x, y: y, width: b, height: b); x += b
        speedLabel.frame = NSRect(x: x, y: ((h - 16) / 2).rounded(), width: 44, height: 16); x += 44
        fasterButton.frame = NSRect(x: x, y: y, width: b, height: b); x += b + Space.l
        smallerButton.frame = NSRect(x: x, y: y, width: b, height: b); x += b + Space.xs
        biggerButton.frame = NSRect(x: x, y: y, width: b, height: b); x += b + Space.l
        let mw = ceil(mirrorLabel.attributedStringValue.size().width)
        mirrorLabel.frame = NSRect(x: x, y: ((h - 16) / 2).rounded(), width: mw, height: 16); x += mw + Space.s
        mirrorToggle.frame = NSRect(x: x, y: ((h - 22) / 2).rounded(), width: 40, height: 22); x += 40
        var right = bounds.width
        for v in trailing {
            let w = (v as? CardButton).map { max(72, $0.fittedWidth) } ?? v.frame.width
            let vh = v is CardButton ? Metrics.button : v.frame.height
            v.frame = NSRect(x: right - w, y: ((h - vh) / 2).rounded(), width: w, height: vh)
            right -= w + Space.s
        }
        // Too narrow for everything: the mirror switch goes first, then the size buttons.
        let overflow = x > right - Space.m
        mirrorLabel.isHidden = overflow; mirrorToggle.isHidden = overflow
        let tight = overflow && biggerButton.frame.maxX > right - Space.m
        smallerButton.isHidden = tight; biggerButton.isHidden = tight
    }
}

// MARK: - Island screen

/// The Teleprompter screen: your scripts as chips, chapters under them, then either the editor
/// (Edit) or the roll with its transport (Roll).
final class TeleprompterView: CardBase, CardContent, NSTextViewDelegate, NSTextFieldDelegate {
    enum Mode: Int { case edit, roll }

    var cardWidth: CGFloat { Isle.lensWidth }
    /// The roll wants every point it can get; the editor is happy with the same.
    var desiredHeight: CGFloat { Isle.maxContentHeight }
    /// Detach tapped. When unset, the shared `TeleprompterWindowController` is shown.
    var onDetach: (() -> Void)?

    private let store: TeleprompterStore
    private let modeTabs = PillTabs(titles: ["Edit", "Roll"])
    private var deleteButton: GHSquareButton!
    private let scriptChips = ChoiceChips(items: [])
    private let chapterChips = ChapterChips()
    private let roll: TeleprompterRoll
    private let transport: TeleprompterTransportBar
    private var detachButton: CardButton!
    private let titleField = ThemedField(placeholder: "Script title")
    private let editorBox = FlippedView()
    private let editorScroll = NSScrollView()
    private let editor = NSTextView()
    private(set) var mode: Mode = .roll
    private var visible = false
    private var saveWork: DispatchWorkItem?
    private var scriptIDs: [UUID] = []
    /// The script the title field and editor hold, so a switch always refills them and a
    /// change elsewhere never wipes what you are typing.
    private var editingID: UUID?

    init(store given: TeleprompterStore? = nil) {
        let store = given ?? TeleprompterStore.shared
        self.store = store
        let r = TeleprompterRoll(store: store)
        roll = r
        transport = TeleprompterTransportBar(store: store, roll: r)
        super.init(width: Isle.lensWidth, title: "Teleprompter")
        let p = Pal

        modeTabs.selected = mode.rawValue
        modeTabs.onSelect = { [weak self] i in self?.setMode(Mode(rawValue: i) ?? .roll) }
        addSubview(modeTabs)
        deleteButton = GHSquareButton(symbol: "trash", label: "Delete script", target: self, action: #selector(deleteTapped))
        addSubview(deleteButton)

        scriptChips.onChange = { [weak self] sel in self?.scriptChipPicked(sel.min() ?? 0) }
        addSubview(scriptChips)
        chapterChips.onTap = { [weak self] i in self?.roll.jump(toChapter: i) }
        addSubview(chapterChips)

        roll.onProgress = { [weak self] _ in self?.refreshSubtitle() }
        roll.onPlayStateChange = { [weak self] on in
            self?.transport.setPlaying(on)
            self?.refreshSubtitle()
        }
        roll.onChapterChange = { [weak self] i in self?.chapterChips.current = i }
        addSubview(roll)
        let detach = CardButton("Detach", style: .secondary, symbol: "rectangle.on.rectangle", target: self, action: #selector(detachTapped))
        detachButton = detach
        transport.trailing = [detach]
        addSubview(transport)

        // Edit mode.
        titleField.delegate = self
        addSubview(titleField)
        editorBox.wantsLayer = true
        editorBox.layer?.cornerRadius = Radius.l
        editorBox.layer?.cornerCurve = .continuous
        editorBox.layer?.masksToBounds = true
        editorBox.layer?.backgroundColor = p.field.cgColor
        editorBox.layer?.borderWidth = 1
        editorBox.layer?.borderColor = p.fieldBorder.cgColor
        addSubview(editorBox)
        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = false
        editorScroll.autohidesScrollers = true
        editorScroll.scrollerStyle = .overlay
        editorScroll.borderType = .noBorder
        editorScroll.drawsBackground = false
        editorScroll.contentView.drawsBackground = false
        editorScroll.documentView = editor
        editorBox.addSubview(editorScroll)
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFindBar = false
        editor.drawsBackground = false
        editor.font = NSFont.systemFont(ofSize: 14)
        editor.textColor = p.text
        editor.insertionPointColor = p.text
        editor.selectedTextAttributes = [.backgroundColor: p.accent.withAlphaComponent(0.35)]
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.focusRingType = .none
        editor.delegate = self
        editor.setAccessibilityLabel("Script")

        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: TeleprompterStore.changed, object: nil)
        applyMode()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Show / hide

    /// The island opened on this screen.
    func willShow() {
        visible = true
        refresh()
        roll.engaged = mode == .roll
    }

    /// The island closed or moved to another screen: edits are kept, the roll leaves the clock
    /// (its play state stays, so a detached window keeps rolling).
    func willHide() {
        visible = false
        commitEdits()
        roll.engaged = false
    }

    // MARK: Store

    @objc private func storeChanged() { refresh() }

    private func refresh() {
        let scripts = store.scripts
        scriptIDs = scripts.map(\.id)
        var items = scripts.map { ChoiceChips.Item(title: $0.title) }
        items.append(ChoiceChips.Item(title: "New", symbol: "plus"))
        if items.map(\.title) != scriptChips.items.map(\.title) { scriptChips.items = items }
        if let id = store.currentID, let i = scriptIDs.firstIndex(of: id) { scriptChips.selection = [i] }

        let current = store.current
        chapterChips.titles = current?.chapters.map { $0.title } ?? []
        chapterChips.current = roll.currentChapter
        deleteButton.isEnabled = current != nil
        if let s = current {
            let switched = editingID != s.id
            let typingTitle = titleField.currentEditor() != nil && window?.firstResponder === titleField.currentEditor()
            let typingText = window?.firstResponder === editor
            if switched || (!typingTitle && titleField.stringValue != s.title) { titleField.stringValue = s.title }
            if switched || (!typingText && editor.string != s.text) { editor.string = s.text }
            if switched { saveWork?.cancel(); saveWork = nil; editingID = s.id }
        } else {
            titleField.stringValue = ""
            editor.string = ""
            editingID = nil
        }
        refreshSubtitle()
        needsLayout = true
    }

    private func refreshSubtitle() {
        let text: String
        if let s = store.current {
            switch mode {
            case .edit:
                let words = s.wordCount
                text = "\(s.title) · \(words) word\(words == 1 ? "" : "s")"
            case .roll:
                let remaining = roll.remainingSeconds
                let left: String
                if s.wordCount == 0 { left = "Add text to begin" }
                else if remaining == 0, roll.progress == 0 { left = "Ready to read" }
                else { left = TeleprompterRoll.timeLeftText(remaining) ?? "Ready to read" }
                text = "\(s.title) · \(roll.isPlaying ? "" : "paused · ")\(left)"
            }
        } else {
            text = "No script yet — tap New"
        }
        // Called on every roll tick: only a changed line is worth a relayout.
        if subtitleLabel.stringValue != text { setSubtitle(text) }
    }

    private func scriptChipPicked(_ i: Int) {
        commitEdits()
        if i >= scriptIDs.count {
            store.newScript()
            if mode == .roll { setMode(.edit) }
            window?.makeFirstResponder(titleField)
        } else {
            store.select(id: scriptIDs[i])
        }
    }

    @objc private func deleteTapped() {
        guard let id = store.currentID else { return }
        saveWork?.cancel(); saveWork = nil
        store.delete(id: id)
    }

    @objc private func detachTapped() {
        commitEdits()
        if let d = onDetach { d() } else { TeleprompterWindowController.shared.show() }
    }

    // MARK: Editing

    func textDidChange(_ notification: Notification) { scheduleCommit() }
    func controlTextDidChange(_ obj: Notification) { scheduleCommit() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        // Return in the title: commit and move on to the text.
        if sel == #selector(NSResponder.insertNewline(_:)) { commitEdits(); window?.makeFirstResponder(editor); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { onEscape?(); return true }
        return false
    }

    /// Edits land in the store a moment after you stop typing, and at once on leaving.
    private func scheduleCommit() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitEdits() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func commitEdits() {
        saveWork?.cancel(); saveWork = nil
        guard var s = store.current, s.id == editingID else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        s.title = title.isEmpty ? "Untitled" : title
        s.text = editor.string
        store.update(s)   // no-op when nothing changed
    }

    // MARK: Mode

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        if mode == .edit { commitEdits() }
        mode = m
        if modeTabs.selected != m.rawValue { modeTabs.selected = m.rawValue }
        applyMode()
        refreshSubtitle()
        if m == .roll { window?.makeFirstResponder(self) }
        needsLayout = true
    }

    private func applyMode() {
        let editing = mode == .edit
        titleField.isHidden = !editing
        editorBox.isHidden = !editing
        deleteButton.isHidden = !editing
        roll.isHidden = editing
        transport.isHidden = editing
        roll.engaged = visible && !editing
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard mode == .roll, !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 49: roll.toggle()                                        // space
        case 126: store.speed += 0.1                                  // ↑
        case 125: store.speed -= 0.1                                  // ↓
        case 123: roll.jumpToNeighbourChapter(forward: false)         // ←
        case 124: roll.jumpToNeighbourChapter(forward: true)          // →
        default: super.keyDown(with: event)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, x = Metrics.cardPad, iw = w - Metrics.cardPad * 2
        let trailing = headerTrailingRect
        let tabsW: CGFloat = 170, mid = trailing.midY
        modeTabs.frame = NSRect(x: w - x - tabsW, y: mid - Metrics.segment / 2, width: tabsW, height: Metrics.segment)
        deleteButton.frame = NSRect(x: modeTabs.frame.minX - Space.s - 34, y: mid - 17, width: 34, height: 34)
        layoutHeader(trailingWidth: tabsW + (deleteButton.isHidden ? 0 : 34 + Space.s))

        var y = headerBottom
        scriptChips.frame = NSRect(x: x, y: y, width: min(iw, scriptChips.preferredWidth), height: Metrics.chip)
        y += Metrics.chip + Space.s
        if chapterChips.titles.isEmpty {
            chapterChips.frame = .zero
            chapterChips.isHidden = true
        } else {
            chapterChips.isHidden = false
            chapterChips.frame = NSRect(x: x, y: y, width: iw, height: ChapterChips.height)
            y += ChapterChips.height + Space.s
        }
        y += Space.xs
        let bottom = h - Space.xl

        switch mode {
        case .edit:
            titleField.frame = NSRect(x: x, y: y, width: min(iw, 360), height: Metrics.field)
            y += Metrics.field + Space.s
            editorBox.frame = NSRect(x: x, y: y, width: iw, height: max(60, bottom - y))
            editorScroll.frame = editorBox.bounds.insetBy(dx: 2, dy: 2)
            let cw = editorScroll.contentSize.width
            editor.minSize = NSSize(width: 0, height: editorScroll.contentSize.height)
            editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            editor.textContainer?.containerSize = NSSize(width: cw, height: CGFloat.greatestFiniteMagnitude)
            editor.frame.size.width = cw
        case .roll:
            let barY = bottom - TeleprompterTransportBar.height
            transport.frame = NSRect(x: x, y: barY, width: iw, height: TeleprompterTransportBar.height)
            roll.frame = NSRect(x: x, y: y, width: iw, height: max(80, barY - Space.m - y))
        }
    }
}

// MARK: - Detached window

private final class TeleprompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The glass behind the floating roll, the roll, and a transport bar that shows under the pointer.
private final class TeleprompterWindowView: NSView {
    let roll: TeleprompterRoll
    let transport: TeleprompterTransportBar
    private let store: TeleprompterStore
    private let blur = NSVisualEffectView()
    private let barBox = FlippedView()
    private var closeButton: IconButton!
    private var barShown = false
    var onClose: (() -> Void)?
    static let minSize = NSSize(width: 340, height: 180)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    init(store: TeleprompterStore) {
        self.store = store
        let r = TeleprompterRoll(store: store)
        roll = r
        transport = TeleprompterTransportBar(store: store, roll: r)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 640, height: 300)))
        let p = Pal
        wantsLayer = true
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.maskImage = Self.roundedMask(Radius.card)
        addSubview(blur)
        roll.drawsBackdrop = false
        roll.dimColor = NSColor.black.withAlphaComponent(0.42)
        addSubview(roll)

        barBox.wantsLayer = true
        barBox.layer?.cornerRadius = Radius.l
        barBox.layer?.cornerCurve = .continuous
        barBox.layer?.backgroundColor = p.surfaceElevated.withAlphaComponent(0.92).cgColor
        barBox.layer?.borderWidth = 1
        barBox.layer?.borderColor = p.border.cgColor
        barBox.alphaValue = 0
        let close = IconButton(symbol: "xmark", label: "Close", target: self, action: #selector(closeTapped))
        closeButton = close
        transport.trailing = [close]
        barBox.addSubview(transport)
        addSubview(barBox)
        roll.onPlayStateChange = { [weak self] on in self?.transport.setPlaying(on) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func roundedMask(_ radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    @objc private func closeTapped() { onClose?() }

    override func layout() {
        super.layout()
        blur.frame = bounds
        roll.frame = bounds
        let barH = TeleprompterTransportBar.height + Space.s * 2
        barBox.frame = NSRect(x: Space.m, y: bounds.height - Space.m - barH, width: bounds.width - Space.m * 2, height: barH)
        transport.frame = barBox.bounds.insetBy(dx: Space.m, dy: Space.s)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetHoverTracking()
    }
    override func mouseEntered(with event: NSEvent) { setBar(shown: true) }
    override func mouseExited(with event: NSEvent) { setBar(shown: false) }

    private func setBar(shown: Bool) {
        guard shown != barShown else { return }
        barShown = shown
        if Motion.reduced {
            barBox.alphaValue = shown ? 1 : 0
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                barBox.animator().alphaValue = shown ? 1 : 0
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 49: roll.toggle()
        case 126: store.speed += 0.1
        case 125: store.speed -= 0.1
        case 123: roll.jumpToNeighbourChapter(forward: false)
        case 124: roll.jumpToNeighbourChapter(forward: true)
        case 53: onClose?()
        default: super.keyDown(with: event)
        }
    }
}

/// The roll on its own: a borderless dark-glass panel above every window and space, dragged by
/// its background, resized at its edges. Its roll shares the script and the play state with the
/// island's through the store, so pausing either pauses both.
final class TeleprompterWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TeleprompterWindowController()
    private static let frameKey = "zera.teleprompter.frame"
    private let host: TeleprompterWindowView
    private let store: TeleprompterStore

    var isShown: Bool { window?.isVisible ?? false }

    init(store given: TeleprompterStore? = nil) {
        let store = given ?? TeleprompterStore.shared
        self.store = store
        let view = TeleprompterWindowView(store: store)
        host = view
        let panel = TeleprompterPanel(contentRect: NSRect(origin: .zero, size: view.frame.size),
                                      styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.minSize = TeleprompterWindowView.minSize
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        super.init(window: panel)
        panel.delegate = self
        view.onClose = { [weak self] in self?.hide() }
        view.roll.engaged = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let panel = window else { return }
        if !panel.isVisible { panel.setFrame(restoredFrame(), display: false) }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(host)
        // On screen first, so the clock sees a visible window when the roll joins it.
        host.roll.adopt()
        host.roll.engaged = true
        ZeraAnimationClock.shared.refresh()
    }

    func hide() {
        guard let panel = window, panel.isVisible else { return }
        saveFrame()
        host.roll.engaged = false
        panel.orderOut(nil)
    }

    func toggle() { if isShown { hide() } else { show() } }

    // MARK: Frame

    private func restoredFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var frame: NSRect
        if let s = UserDefaults.standard.string(forKey: Self.frameKey), !s.isEmpty {
            frame = NSRectFromString(s)
        } else {
            frame = NSRect(x: visible.midX - 320, y: visible.maxY - 60 - 300, width: 640, height: 300)
        }
        frame.size.width = max(TeleprompterWindowView.minSize.width, frame.width)
        frame.size.height = max(TeleprompterWindowView.minSize.height, frame.height)
        if let scr = screen { frame = window?.constrainFrameRect(frame, to: scr) ?? frame }
        return frame
    }

    private func saveFrame() {
        guard let f = window?.frame, f.width > 0 else { return }
        UserDefaults.standard.set(NSStringFromRect(f), forKey: Self.frameKey)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
}
