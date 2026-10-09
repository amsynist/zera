import AppKit
import XCTest
@testable import Zera

/// Records every screen as transparent clips and stills for editing, with Zera hanging from the
/// notch the way she does in the app. Local only, never in CI:
/// `scripts/render-clips.sh` (or ZERA_CLIPS=<out folder> with CFFIXED_USER_HOME set to a sample home).
///
/// The canvas is a 1512×982 pt screen (a 14" MacBook Pro), captured at 2×. Everything outside
/// the UI and Zera is transparent, so any background can go behind it. Writes:
///   images/NN-name.png               trimmed to the UI (plus a little room for the glow)
///   images/full-canvas/NN-name.png   the whole screen, so it lines up with a screen mockup
///   clips/NN-name.mov                ProRes 4444 with alpha, the editing master
///   clips/hevc-alpha/NN-name.mov     HEVC with alpha, much smaller, same picture
///   clips/preview/NN-name.mp4        H.264 on dark grey, for a quick look
@MainActor
final class ScreenClipsTests: XCTestCase {
    private let canvas = NSSize(width: 1512, height: 982)
    private let band: CGFloat = 32
    private let notchWidth: CGFloat = 186
    private var cx: CGFloat { canvas.width / 2 }

    private var out: URL!
    private var work: URL!
    private let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    // The stage: one transparent window standing in for the screen.
    private var w: NSWindow!
    private var root: FlippedView!
    private var iv: IslandView!
    private var buddy: BuddyView!
    private var notch: NotchShape!
    private var live: LiveActivityView!
    private var bubble: BubbleView!
    private var floats: [NSView] = []

    // The recorder.
    private var frames: URL!
    private var times: [Double] = []
    private var start: CFTimeInterval = 0
    private var stills: [String] = []
    private let encode = DispatchQueue(label: "clips-encode", attributes: .concurrent)
    private let group = DispatchGroup()
    private let inFlight = DispatchSemaphore(value: 10)
    private var made: [[String: Any]] = []

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["ZERA_CLIPS"] else { throw XCTSkip("set ZERA_CLIPS to record") }
        // It writes sample files into the home folder: only a sample one.
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else { throw XCTSkip("set CFFIXED_USER_HOME to a sample home") }
        guard ffmpeg != nil else { throw XCTSkip("needs ffmpeg") }
        out = URL(fileURLWithPath: dir)
        work = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZERA_CLIPS_WORK"] ?? NSTemporaryDirectory())
            .appendingPathComponent("zera-clip-frames", isDirectory: true)
        for sub in ["images/full-canvas", "clips/hevc-alpha", "clips/preview"] {
            try FileManager.default.createDirectory(at: out.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    // MARK: Stage

    private final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }

    /// The hardware notch: black, flush with the top, rounded underneath.
    final class NotchShape: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            let b = bounds, r: CGFloat = 9
            let p = NSBezierPath()
            p.move(to: NSPoint(x: b.minX - 6, y: b.minY))
            p.curve(to: NSPoint(x: b.minX, y: b.minY + 6), controlPoint1: NSPoint(x: b.minX - 1, y: b.minY), controlPoint2: NSPoint(x: b.minX, y: b.minY + 1))
            p.line(to: NSPoint(x: b.minX, y: b.maxY - r))
            p.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.maxY - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
            p.line(to: NSPoint(x: b.maxX - r, y: b.maxY))
            p.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.maxY - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
            p.line(to: NSPoint(x: b.maxX, y: b.minY + 6))
            p.curve(to: NSPoint(x: b.maxX + 6, y: b.minY), controlPoint1: NSPoint(x: b.maxX, y: b.minY + 1), controlPoint2: NSPoint(x: b.maxX + 1, y: b.minY))
            p.close()
            NSColor.black.setFill()
            p.fill()
        }
    }

    private func buildStage() {
        let win = KeyWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.appearance = NSAppearance(named: .darkAqua)
        let r = FlippedView(frame: NSRect(origin: .zero, size: canvas))
        r.wantsLayer = true
        r.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = r
        w = win; root = r

        let island = IslandView(frame: NSRect(origin: .zero, size: canvas))
        island.band = band
        island.notchWidth = notchWidth
        island.centerX = cx
        r.addSubview(island)
        iv = island

        let wings = LiveActivityView(frame: NSRect(origin: .zero, size: NSSize(width: min(LiveActivityView.panelSize.width, canvas.width), height: LiveActivityView.panelSize.height)))
        wings.alphaValue = 0
        wings.isHidden = true
        r.addSubview(wings)
        live = wings

        // Her window, as NotchGeometry.buddyPanelFrame places it: up through the notch, down far
        // enough to dangle.
        let b = BuddyView(frame: NSRect(x: cx - Theme.buddyWidth / 2, y: 0, width: Theme.buddyWidth,
                                        height: band + Theme.figureHeight + Theme.figurePad))
        b.hangInset = max(0, band - Theme.topTuck)
        b.bottomPad = Theme.figurePad
        r.addSubview(b)
        buddy = b

        // Hidden until she says something: with no text it has no shape to draw.
        let cap = BubbleView(frame: .zero)
        cap.alphaValue = 0
        cap.isHidden = true
        r.addSubview(cap)
        bubble = cap

        let n = NotchShape(frame: NSRect(x: cx - notchWidth / 2, y: 0, width: notchWidth, height: band))
        r.addSubview(n)
        notch = n

        win.orderFrontRegardless()
        island.close(animated: false)
        r.layoutSubtreeIfNeeded()
        // Her clock starts only when she joins a window that is already on screen.
        pump(0.3)
        b.removeFromSuperview()
        r.addSubview(b, positioned: .below, relativeTo: n)
        b.needsLayout = true
        b.layoutSubtreeIfNeeded()
        pump(0.5)
    }

    /// Back to a closed notch with Zera idle, between clips.
    private func resetStage() {
        floats.forEach { $0.removeFromSuperview() }
        floats = []
        iv.isHidden = false
        iv.close(animated: false)
        iv.counts = [:]; iv.badges = []; iv.instruments = [:]
        buddy.alphaValue = 1
        buddy.zera.islandPose = nil
        buddy.zera.activity = .none
        buddy.zera.mood = .idle
        live.alphaValue = 0
        live.isHidden = true
        bubble.alphaValue = 0
        bubble.isHidden = true
        ThemeStore.shared.select(ThemeStore.shared.builtIns[0])
        iv.themeChanged(); live.themeChanged()
        w.makeFirstResponder(nil)
        pump(0.3)
    }

    /// Adds a view above the island and below Zera and the notch.
    private func addFloat(_ v: NSView) {
        root.addSubview(v, positioned: .below, relativeTo: buddy)
        floats.append(v)
    }

    private func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    // MARK: Island

    /// Opens (or switches to) a screen the way ZeraController.presentCurrent does.
    private func open(_ c: NSView & CardContent, _ kind: CardKind, direction: CGFloat = 0) {
        let width = min(c.cardWidth, Isle.maxWidth, canvas.width - 24)
        c.setFrameSize(NSSize(width: width, height: max(c.frame.height, 100)))
        c.needsLayout = true
        c.layoutSubtreeIfNeeded()
        let h = min(c.desiredHeight, Isle.maxContentHeight, canvas.height - band - 40)
        iv.present(c, size: NSSize(width: width, height: h), direction: direction, animated: true)
        iv.activeTab = Isle.tab(for: kind)
        buddy.zera.islandPose = Isle.pose(for: kind)
    }

    /// The island folds back into the notch.
    private func close() {
        iv.close(animated: true)
        buddy.zera.islandPose = nil
    }

    /// Hovering her: the tab nodes bloom out round the rope.
    private func bloom() {
        iv.counts = [.claude: 1, .shelf: 4, .github: 2]
        iv.badges = [.claude]
        iv.instruments = [.home: IslandInstrument(progress: 0.34, text: "78", tone: nil),
                          .claude: IslandInstrument(progress: 0.62, text: nil, tone: nil),
                          .tasks: IslandInstrument(progress: 0.25, text: nil, tone: nil),
                          .reminders: IslandInstrument(progress: 0.8, text: "12m", tone: nil)]
        iv.peek()
        buddy.ping()
    }

    // MARK: Zera's caption

    private var figureRect: NSRect {   // unflipped, like the screen
        NSRect(x: cx - 32, y: canvas.height - band - Theme.figureHeight, width: 64, height: Theme.figureHeight)
    }

    private func say(_ text: String) {
        bubble.text = text
        let safe = NSRect(x: 8, y: 8, width: canvas.width - 16, height: canvas.height - band - 8)
        let size = BubbleView.size(for: text, maxWidth: safe.width)
        let bodyX = figureRect.midX + (buddy.zera.activity != .none ? buddy.zera.claudeBodyOffset : 0)
        let tag = BubbleView.frame(for: size, figure: figureRect, bodyX: bodyX, safeFrame: safe, obstacles: [])
        let panel = BubbleView.panelFrame(for: tag)
        let target = NSRect(x: panel.minX, y: canvas.height - panel.maxY, width: panel.width, height: panel.height)
        bubble.frame = target.offsetBy(dx: 0, dy: -6)
        bubble.tailX = bodyX - panel.minX
        bubble.alphaValue = 0
        bubble.isHidden = false
        bubble.needsDisplay = true
        buddy.zera.nudge()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            bubble.animator().alphaValue = 1
            bubble.animator().frame = target
        }
    }

    private func unsay() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            bubble.animator().alphaValue = 0
            bubble.animator().frame = bubble.frame.offsetBy(dx: 0, dy: -4)
        }
    }

    // MARK: Wings

    private func placeWings() {
        let bodyX = cx + (buddy.zera.activity == .none ? 0 : buddy.zera.claudeBodyOffset)
        let size = live.frame.size
        let x = max(0, min(canvas.width - size.width, bodyX - size.width / 2))
        // ZeraController.positionLive, flipped: centred at 43% up her figure.
        let y = (band + Theme.figureHeight - Theme.figureHeight * 0.43 - size.height / 2).rounded()
        live.setFrameOrigin(NSPoint(x: x, y: y))
        live.centerX = bodyX - x
        live.layoutSubtreeIfNeeded()
    }

    // MARK: Recording

    private func begin(_ name: String) throws {
        frames = work.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: frames)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        times = []
        stills = []
        start = CACurrentMediaTime()
    }

    private func capture() {
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.bestResolution, .boundsIgnoreFraming]) else { return }
        let n = times.count
        times.append(CACurrentMediaTime() - start)
        let dir = frames!
        let names = stills
        stills = []
        let outDir = out!
        inFlight.wait()
        group.enter()
        encode.async { [inFlight, group] in
            Self.writePNG(cg, to: dir.appendingPathComponent(String(format: "%05d.png", n)))
            for s in names {
                Self.writePNG(cg, to: outDir.appendingPathComponent("images/full-canvas/\(s).png"))
                if let t = Self.trimmed(cg, pad: 48) { Self.writePNG(t, to: outDir.appendingPathComponent("images/\(s).png")) }
            }
            inFlight.signal()
            group.leave()
        }
    }

    /// Runs the app for `seconds`, capturing at 30 fps. `each` runs once a frame before capture.
    private func run(_ seconds: Double, each: ((Double) -> Void)? = nil) {
        let t0 = CACurrentMediaTime()
        let end = t0 + seconds
        var next = t0
        while CACurrentMediaTime() < end {
            next += 1.0 / 30
            RunLoop.main.run(until: Date().addingTimeInterval(max(0.001, next - CACurrentMediaTime())))
            each?(CACurrentMediaTime() - t0)
            capture()
        }
    }

    /// The next frame is also saved as a still.
    private func still(_ name: String) { stills.append(name) }

    private func finish(_ name: String, about: String) throws {
        group.wait()
        guard times.count > 1, let ffmpeg = ffmpeg else { return }
        // Frames land when the run loop allows: their real times keep the motion's pace.
        var list = "ffconcat version 1.0\n"
        for i in times.indices {
            list += "file '\(String(format: "%05d.png", i))'\n"
            let d = i + 1 < times.count ? times[i + 1] - times[i] : 1.0 / 30
            list += "duration \(String(format: "%.5f", max(0.001, d)))\n"
        }
        list += "file '\(String(format: "%05d.png", times.count - 1))'\n"
        let listURL = frames.appendingPathComponent("frames.ffconcat")
        try list.write(to: listURL, atomically: true, encoding: .utf8)
        let input = ["-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", listURL.path]
        let clips = out.appendingPathComponent("clips")
        try sh(ffmpeg, input + ["-vf", "fps=30", "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le",
                                "-alpha_bits", "16", "-vendor", "apl0", clips.appendingPathComponent("\(name).mov").path])
        try sh(ffmpeg, input + ["-vf", "fps=30", "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.9", "-q:v", "70",
                                "-tag:v", "hvc1", "-pix_fmt", "bgra", clips.appendingPathComponent("hevc-alpha/\(name).mov").path])
        let px = (canvas.width * 2, canvas.height * 2)
        try sh(ffmpeg, input + ["-f", "lavfi", "-i", "color=c=0x1E2026:s=\(Int(px.0))x\(Int(px.1)):r=30",
                                "-filter_complex", "[1][0]overlay=shortest=1:format=auto,fps=30,scale=1512:-2,format=yuv420p",
                                "-c:v", "h264_videotoolbox", "-b:v", "6M", "-movflags", "+faststart",
                                clips.appendingPathComponent("preview/\(name).mp4").path])
        try? FileManager.default.removeItem(at: frames)
        made.append(["name": name, "seconds": (times.last ?? 0), "about": about])
        print("clip \(name): \(times.count) frames, \(String(format: "%.1f", times.last ?? 0)) s")
    }

    private func sh(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        // Keep the app's run loop turning while ffmpeg works (Zera's clock, pending timers).
        while p.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if p.terminationStatus != 0 { XCTFail("ffmpeg failed (\(p.terminationStatus)) for \(args.last ?? "")") }
    }

    nonisolated private static func writePNG(_ image: CGImage, to url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, image, nil)
        CGImageDestinationFinalize(d)
    }

    /// The picture cut down to what's drawn (alpha above a whisper), with `pad` pixels of room.
    nonisolated private static func trimmed(_ image: CGImage, pad: Int) -> CGImage? {
        let wPx = image.width, hPx = image.height
        guard let ctx = CGContext(data: nil, width: wPx, height: hPx, bitsPerComponent: 8, bytesPerRow: wPx * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: wPx, height: hPx))
        let px = data.bindMemory(to: UInt8.self, capacity: wPx * hPx * 4)
        var minX = wPx, minY = hPx, maxX = -1, maxY = -1
        for y in 0..<hPx {
            let row = y * wPx * 4
            for x in 0..<wPx where px[row + x * 4 + 3] > 6 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The bitmap's rows run top-down in memory, the same as the image's.
        let r = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                       width: min(wPx, maxX + pad + 1) - max(0, minX - pad), height: min(hPx, maxY + pad + 1) - max(0, minY - pad))
        return image.cropping(to: r)
    }

    /// One clip: from a closed notch with Zera idle, through `body`, and a moment after.
    private func clip(_ name: String, _ about: String, _ body: () throws -> Void) throws {
        if let only = ProcessInfo.processInfo.environment["ZERA_CLIPS_ONLY"],
           !only.split(separator: ",").contains(where: { name.hasPrefix($0) }) { return }
        resetStage()
        try begin(name)
        run(0.6)
        try body()
        run(0.6)
        try finish(name, about: about)
    }

    // MARK: Sample data

    private func sampleTasks() -> TaskStore {
        let s = TaskStore(url: nil)
        s.add("Ship the dark mode toggle #Aurora 45m")
        s.add("Review Theo's avatar cache PR #Aurora 20m")
        s.add("Write the launch post #Website 30m")
        s.add("Plan next sprint")
        return s
    }

    private func sampleShelfFiles() throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zera-clip-shelf", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("Q3 report.pdf"); try Data("%PDF-1.4\n".utf8).write(to: pdf)
        let note = dir.appendingPathComponent("Note 7 Oct.txt"); try Data("Ship the theme picker before Friday.".utf8).write(to: note)
        let link = dir.appendingPathComponent("Aurora releases.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/aurora/releases"], format: .xml, options: 0).write(to: link)
        let img = NSImage(size: NSSize(width: 64, height: 40))
        img.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 64, height: 40).fill(); img.unlockFocus()
        let png = dir.appendingPathComponent("hero-shot.png")
        if let tiff = img.tiffRepresentation, let p = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try p.write(to: png) }
        return [pdf, png, note, link]
    }

    private func sampleMonth() -> TaskStore {
        let s = TaskStore(url: nil)
        let cal = Calendar.current
        let repos = ["aurora-app", "aurora-api", "design-system", "website"]
        let subjects = ["Add dark mode to the settings page", "Cache avatars on disk between launches",
                        "Fix the date picker on small screens", "Speed up the search index rebuild",
                        "Polish the onboarding copy", "Upgrade the charts library"]
        for (n, name) in ["Aurora", "Website"].enumerated() {
            let p = s.addProject(name)
            s.link(p, to: "/tmp")
            var commits: [GitCommit] = []
            for d in 0..<12 {
                guard let day = cal.date(byAdding: .day, value: -(d * 2 + n), to: Date()) else { continue }
                for k in 0..<(1 + d % 3) {
                    let at = cal.date(bySettingHour: 10 + k * 2, minute: 0, second: 0, of: day) ?? day
                    commits.append(GitCommit(hash: String(format: "%010x", d * 10 + k + n * 1000), date: at,
                                             subject: subjects[(d + k + n) % subjects.count], body: "", repo: repos[(d + k + n) % repos.count]))
                }
            }
            s.importCommits(p, tasks: TaskGitSync.tasks(from: commits, project: p, calendar: cal, claude: false),
                            seen: commits.map(\.hash), through: Date())
        }
        s.add("Plan next sprint #Aurora 30m")
        return s
    }

    private func samplePRs() -> [GHPullRequest] {
        let now = Date()
        func person(_ l: String) -> GHPullRequest.Person { .init(login: l, avatar: nil) }
        var a = GHPullRequest(id: "acme/aurora-web#214", owner: "acme", repo: "aurora-web", number: 214,
            title: "Make the settings page work from the keyboard",
            author: person("maya"), created: now.addingTimeInterval(-47 * 60), updated: now.addingTimeInterval(-5 * 60),
            url: URL(string: "https://github.com/acme/aurora-web/pull/214")!)
        a.branch = "settings-keyboard"; a.base = "main"
        a.reviewers = [person("sam"), person("theo")]; a.comments = 4
        a.additions = 13; a.deletions = 2; a.changedFiles = 1
        a.ci = .failed; a.checksTotal = 6
        a.failing = [.init(name: "Lint", title: "2 warnings treated as errors", summary: "", url: nil),
                     .init(name: "unit-tests", title: "3 failed", summary: "", url: nil)]
        a.labels = ["accessibility", "ui"]; a.reviewRequested = true
        var b = GHPullRequest(id: "acme/aurora#412", owner: "acme", repo: "aurora", number: 412, title: "Add themes: seven built in, plus your own",
            author: person("you"), created: now.addingTimeInterval(-3 * 3600), updated: now.addingTimeInterval(-20 * 60),
            url: URL(string: "https://github.com/acme/aurora/pull/412")!)
        b.ci = .passed; b.review = .approved; b.approvedBy = ["theo"]; b.reviewers = [person("theo")]; b.mine = true
        b.additions = 812; b.deletions = 140; b.changedFiles = 22
        var c = GHPullRequest(id: "acme/infra#88", owner: "acme", repo: "infra", number: 88, title: "Bump the build image to Node 22",
            author: person("dependabot"), created: now.addingTimeInterval(-6 * 3600), updated: now.addingTimeInterval(-2 * 3600),
            url: URL(string: "https://github.com/acme/infra/pull/88")!)
        c.ci = .running; c.approvalsWaiting = 1
        var d = GHPullRequest(id: "acme/aurora#398", owner: "acme", repo: "aurora", number: 398, title: "Cache avatars on disk between launches",
            author: person("you"), created: now.addingTimeInterval(-6 * 86400), updated: now.addingTimeInterval(-40 * 60),
            url: URL(string: "https://github.com/acme/aurora/pull/398")!)
        d.mine = true; d.ci = .passed; d.review = .approved; d.approvedBy = ["sam", "theo"]; d.reviewers = [person("sam"), person("theo")]
        return [a, b, c, d]
    }

    private func session(_ id: String, _ title: String, _ status: ClaudeSession.Status, _ ago: TimeInterval) -> ClaudeSession {
        let s = ClaudeSession(id: id, cwd: "/Users/you/\(id)", at: Date().addingTimeInterval(-ago))
        s.title = title; s.status = status; s.promptAt = Date().addingTimeInterval(-ago); s.branch = "main"
        return s
    }

    private func sampleClipboard() {
        ClipboardStore.shared.enabled = true
        ClipboardStore.shared.preview([
            ClipItem(kind: .text, text: "Ship the theme picker before Friday — Theo has the review.", bytes: 60, sourceApp: "Slack", fingerprint: "a"),
            ClipItem(kind: .link, text: "https://example.com/aurora/pull/214", bytes: 40, sourceApp: "Safari", fingerprint: "b"),
            ClipItem(kind: .code, text: "swift test --filter ScreenRenderTests", bytes: 38, sourceApp: "Terminal", fingerprint: "c"),
            ClipItem(kind: .color, text: "#9D8CFF", bytes: 7, sourceApp: "Figma", fingerprint: "d")])
    }

    /// Types like a person: one character at a time, through the field editor when there is one.
    private func type(_ field: NSTextField, _ text: String, cps: Double = 16) {
        w.makeKey()
        w.makeFirstResponder(field)
        for ch in text {
            if let ed = field.currentEditor() as? NSTextView {
                ed.insertText(String(ch), replacementRange: ed.selectedRange())
            } else {
                field.stringValue += String(ch)
                NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            }
            run(1 / cps)
        }
    }

    // MARK: The clips

    func testRecordClips() throws {
        buildStage()
        defer { w.orderOut(nil) }

        // Sample data, all in the throwaway home. Vitals are this machine's.
        SystemVitals.shared.simulate()
        defer { SystemVitals.shared.unwatch() }
        GitHubService.shared.preview(login: "you", pulls: samplePRs())
        let today = sampleTasks()
        let month = sampleMonth()
        sampleClipboard()
        let running = session("aurora", "Fix the theme picker", .running, 90)
        ClaudeActivityService.shared.preview([running, session("website", "Why is the hero video so large?", .waiting, 400),
                                              session("zera", "Write release notes for v0.1.4", .done, 3000)])
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        for (folder, names) in [("Downloads", ["Invoice-October.pdf", "team-offsite-photos.zip", "design-review.mov"]), ("Desktop", ["Q3 roadmap.key"])] {
            let dir = home.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in names where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path) {
                try Data(repeating: 7, count: 240_000).write(to: dir.appendingPathComponent(n))
            }
        }
        let arriving = downloads.appendingPathComponent("Screenshot 2026-10-08 at 09.41.12.png")
        let rs = ReminderService.shared
        let now = Date()
        var review = CalendarEvent(title: "Design review", startAt: now.addingTimeInterval(50 * 60))
        review.url = "https://meet.example.com/design"
        rs.save(event: review)
        rs.save(event: CalendarEvent(title: "1:1 with Theo", startAt: now.addingTimeInterval(3 * 3600)))
        rs.addOneOff(title: "Send the October invoice", at: now.addingTimeInterval(2 * 3600))
        // Settings → About reads the version from the bundle: the test runner's, unless told.
        if let v = ProcessInfo.processInfo.environment["ZERA_CLIPS_VERSION"], !v.isEmpty,
           let info = Bundle.main.infoDictionary as NSDictionary? as? NSMutableDictionary {
            info["CFBundleShortVersionString"] = v
        }
        // Files from earlier test runs (the shelf list lives in the test runner's defaults).
        _ = ShelfStore.shared.clear()
        UserDefaults.standard.removeObject(forKey: "appOpener.usage")
        UserDefaults.standard.set(0, forKey: "tasks.viewSpan")
        UserDefaults.standard.set(false, forKey: "zera.shelf.freshTab")
        var catalogReady = false
        AppCatalog.shared.refreshIfNeeded { catalogReady = true }
        let catalogDeadline = Date().addingTimeInterval(20)
        while !catalogReady && Date() < catalogDeadline { pump(0.1) }
        pump(2.2)   // vitals fill in a little

        // 1. Hover: the notch blooms into the tab nodes, then folds away.
        try clip("01-notch-hover", "Hovering Zera: the notch widens and the eight tab nodes bloom out round her rope, then fold back.") {
            bloom()
            run(2.4)
            still("01-notch-hover")
            run(0.4)
            close()
            run(0.8)
        }

        // 2. Hover, pick Home: the nodes shrink into the rail and the island opens.
        try clip("02-notch-open", "Hover, click Home: the nodes fly into the rail and the island opens out of the notch, then closes.") {
            bloom()
            run(1.4)
            open(HomeCard(), .home)
            run(3.0)
            close()
            run(0.9)
        }

        // 3. Every tab in rail order.
        try clip("03-tab-tour", "Every tab in order: Home, Claude, Shelf, Clipboard, Tasks, Pull requests, Reminders, Settings. Screens slide from the side you move toward.") {
            open(HomeCard(), .home)
            run(1.6)
            let shelf = DropFilesView(); shelf.willShow()
            let clip = ClipboardView(); clip.willShow()
            let tasks = TasksCard(store: today); tasks.willShow()
            let rem = RemindersView(); rem.willShow()
            let screens: [(NSView & CardContent, CardKind)] = [
                (ClaudeSessionsView(), .claude), (shelf, .shelf), (clip, .clipboard), (tasks, .tasks),
                (GitHubCard(), .github), (rem, .reminders),
                (SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false), .settings)]
            for (c, k) in screens { open(c, k, direction: 1); run(1.5) }
            for (c, k) in [(HomeCard(), CardKind.home)] as [(NSView & CardContent, CardKind)] { open(c, k, direction: -1); run(1.2) }
            close()
            run(0.9)
        }

        // 4. Home and This Mac.
        try clip("04-home", "Home: greeting, the vitals strip (CPU, memory, GPU, Wi-Fi, battery), today at a glance. Tap the strip for This Mac.") {
            let homeCard = HomeCard()
            open(homeCard, .home)
            run(2.4)
            still("04-home")
            run(0.4)
            homeCard.setVitals(true)
            open(homeCard, .home)
            run(3.0)
            still("04b-this-mac")
            run(0.4)
            homeCard.setVitals(false)
            open(homeCard, .home)
            run(1.4)
            close()
            run(0.9)
        }

        // 5. Claude sessions.
        try clip("05-claude-sessions", "Claude: every Claude Code session, live: running, waiting on you, done.") {
            open(ClaudeSessionsView(), .claude)
            run(2.8)
            still("05-claude-sessions")
            run(0.6)
            close()
            run(0.9)
        }

        // 6. The Claude wings: running, an approval, approved, done.
        try clip("06-claude-wings", "The wings beside the notch: Claude working, asking to run a command, approved, done. Zera holds her rope and acts it out.") {
            let s = session("aurora", "Fix the theme picker", .running, 90)
            buddy.zera.activity = .running
            live.update(session: s, pending: nil)
            placeWings()
            live.isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.22; live.animator().alphaValue = 1 }
            run(2.0)
            still("06-wings-running")
            run(0.2)
            buddy.zera.activity = .approval
            live.update(session: s, pending: HookRequest(id: "r", receivedAt: Date(), sessionID: s.id, toolName: "Bash",
                                                         command: "npm test -- --watch=false", detail: nil, cwd: "/Users/you/aurora"))
            placeWings()
            run(2.6)
            still("06b-wings-approval")
            run(0.2)
            buddy.zera.activity = .running
            live.update(session: s, pending: nil)
            placeWings()
            run(1.6)
            s.status = .done
            buddy.zera.activity = .done
            live.update(session: s, pending: nil)
            placeWings()
            say("all green! ✅")
            run(2.2)
            still("06c-wings-done")
            run(0.3)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; live.animator().alphaValue = 0 }
            unsay()
            buddy.zera.activity = .none
            run(0.8)
        }

        // 7. Shelf: files drop in, then a file's page.
        try clip("07-shelf", "Shelf: files dropped on the notch land here. Tap to copy, drag out, or ask Claude about one.") {
            let shelf = DropFilesView(); shelf.willShow()
            open(shelf, .shelf)
            run(1.4)
            still("07-shelf-empty")
            run(0.2)
            _ = ShelfStore.shared.add(urls: try sampleShelfFiles())
            open(shelf, .shelf)
            run(2.2)
            still("07b-shelf")
            run(0.3)
            shelf.setExpanded(true)
            open(shelf, .shelf)
            run(2.2)
            still("07c-shelf-file")
            run(0.3)
            close()
            run(0.9)
        }

        // 8. Shelf · Fresh, with a download landing.
        try clip("08-shelf-fresh", "Shelf · Fresh: new files from Downloads and Desktop, newest first. A download lands while it's open.") {
            try? FileManager.default.removeItem(at: arriving)
            UserDefaults.standard.set(true, forKey: "zera.shelf.freshTab")
            FreshFiles.shared.start()
            pump(0.5)
            let fresh = DropFilesView(); fresh.willShow()
            open(fresh, .shelf)
            run(1.6)
            try Data(repeating: 9, count: 1_900_000).write(to: arriving)
            run(2.4)
            still("08-shelf-fresh")
            run(0.4)
            close()
            run(0.9)
            UserDefaults.standard.set(false, forKey: "zera.shelf.freshTab")
        }

        // 9. Clipboard.
        try clip("09-clipboard", "Clipboard: everything you copied — text, links, code, colours — to copy again.") {
            let c = ClipboardView(); c.willShow()
            open(c, .clipboard)
            run(2.8)
            still("09-clipboard")
            run(0.5)
            close()
            run(0.9)
        }

        // 10. Tasks: add one in the island.
        try clip("10-tasks-add", "Tasks: type “Write the release notes #Aurora 30m” and press Return; it joins today's list under its project.") {
            let store = sampleTasks()
            let card = TasksCard(store: store); card.willShow()
            open(card, .tasks)
            run(1.4)
            still("10-tasks")
            run(0.2)
            type(card.field, "Write the release notes #Aurora 30m")
            run(0.5)
            _ = card.control(card.field, textView: (card.field.currentEditor() as? NSTextView) ?? NSTextView(),
                             doCommandBy: #selector(NSResponder.insertNewline(_:)))
            open(card, .tasks)
            run(2.2)
            still("10b-tasks-added")
            run(0.3)
            w.makeFirstResponder(nil)
            close()
            run(0.9)
        }

        // 11. Tasks, the week.
        try clip("11-tasks-week", "Tasks · Week: a week of work, commits from linked repos turned into done tasks.") {
            UserDefaults.standard.set(1, forKey: "tasks.viewSpan")
            let card = TasksCard(store: month); card.willShow()
            open(card, .tasks)
            run(2.8)
            still("11-tasks-week")
            run(0.5)
            close()
            run(0.9)
            UserDefaults.standard.set(0, forKey: "tasks.viewSpan")
        }

        // The orb's place at the right edge (TasksController.orbFrame, flipped).
        let orbSize = FocusOrbView.size, om = (FocusOrbView.size - FocusOrbView.orb) / 2
        let vfH = canvas.height - band
        let orbBottom = 12 + TasksSettings.orbY * max(0, vfH - orbSize - 24)
        let orbFrame = NSRect(x: canvas.width - orbSize - (14 - om), y: canvas.height - orbBottom - orbSize, width: orbSize, height: orbSize)
        func popOrb(_ orb: FocusOrbView) {
            orb.frame = orbFrame
            orb.wantsLayer = true
            orb.refresh()
            addFloat(orb)
            orb.layoutSubtreeIfNeeded()
            if let l = orb.layer { TaskMotion.scale(l, about: CGPoint(x: l.bounds.midX, y: l.bounds.midY), from: 0.2, to: 1, opacity: 0, 1, spring: true) }
        }
        func hideOrb(_ orb: FocusOrbView) {
            if let l = orb.layer { TaskMotion.scale(l, about: CGPoint(x: l.bounds.midX, y: l.bounds.midY), from: 1, to: 0.2, opacity: 1, 0, spring: false, duration: 0.16) }
        }
        func plusFrame(_ plus: OrbPlusView) -> NSRect {
            let h = OrbPlusView.size, wd = plus.fittedWidth, gap: CGFloat = 10 - OrbPlusView.pad
            return NSRect(x: orbFrame.minX + om - gap - wd, y: orbFrame.midY - h / 2, width: wd, height: h)
        }
        func showPlus(_ plus: OrbPlusView, _ orb: FocusOrbView) {
            let i = orb.info
            plus.setInfo(big: i.big, small: i.small)
            plus.leftSide = false
            let end = plusFrame(plus)
            plus.frame = end.offsetBy(dx: 22, dy: 0)
            plus.alphaValue = 0
            if plus.superview == nil { root.addSubview(plus, positioned: .below, relativeTo: orb); floats.append(plus) }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.3, 0.4, 1)
                plus.animator().frame = end
                plus.animator().alphaValue = 1
            }
        }
        func hidePlus(_ plus: OrbPlusView) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                plus.animator().frame = plusFrame(plus).offsetBy(dx: 22, dy: 0)
                plus.animator().alphaValue = 0
            }
        }
        func everySecond(_ f: @escaping () -> Void) -> (Double) -> Void {
            var last = 0
            return { t in if Int(t) > last { last = Int(t); f() } }
        }

        // 12. The focus orb: pops in, a + on hover, opens into the focus card, folds back.
        try clip("12-focus-orb", "The focus orb at the screen edge: pops in with a spring, a + slides out on hover, click and it grows into the focus card, which folds back into it.") {
            let store = sampleTasks()
            _ = store.add("Ship the dark mode toggle #Aurora 45m", focus: true)
            let orb = FocusOrbView(store: store)
            popOrb(orb)
            let tick = everySecond { orb.tick() }
            run(1.6, each: tick)
            still("12-focus-orb")
            run(0.2, each: tick)
            let plus = OrbPlusView()
            showPlus(plus, orb)
            run(1.4, each: tick)
            still("12b-orb-hover")
            run(0.2, each: tick)
            hidePlus(plus)
            run(0.3, each: tick)
            // Click: the card grows out of the orb's middle.
            let card = FocusCardView(store: store)
            let size = NSSize(width: card.frame.width, height: card.desiredHeight)
            let m = FocusCardView.margin
            let y = max(band - m, min(canvas.height + m - size.height, orbFrame.midY - size.height / 2))
            let host = NSView(frame: NSRect(x: orbFrame.maxX - om + m - size.width, y: y, width: size.width, height: size.height))
            host.wantsLayer = true
            card.frame = NSRect(origin: .zero, size: size)
            host.addSubview(card)
            orb.isHidden = true
            addFloat(host)
            let fromOrb = CGPoint(x: orbFrame.midX - host.frame.minX, y: host.frame.maxY - orbFrame.midY)
            if let l = host.layer { TaskMotion.scale(l, about: fromOrb, from: 0.12, to: 1, opacity: 0, 1, spring: true) }
            let cardTick = everySecond { card.tick() }
            run(2.6, each: cardTick)
            still("12c-focus-card")
            run(0.3, each: cardTick)
            if let l = host.layer { TaskMotion.scale(l, about: fromOrb, from: 1, to: 0.12, opacity: 1, 0, spring: false, duration: 0.17) }
            run(0.14)
            orb.isHidden = false
            popOrb(orb)
            run(1.4, each: tick)
            hideOrb(orb)
            run(0.6)
        }

        // 13. Quick add from the orb (⌥⌘T anywhere).
        try clip("13-task-quick-add", "Quick add (⌥⌘T, or the + by the orb): type a task with a time and a #project, Return adds it, the orb bounces and Zera confirms.") {
            let store = sampleTasks()
            let orb = FocusOrbView(store: store)
            popOrb(orb)
            run(1.0)
            let plus = OrbPlusView()
            showPlus(plus, orb)
            run(0.9)
            // The + opens quick add beside the orb.
            plus.alphaValue = 0
            let quick = QuickAddView()
            quick.leftSide = false
            let s = QuickAddView.size, qm = QuickAddView.margin
            quick.frame = NSRect(x: orbFrame.minX + om - 10 - (s.width - qm), y: orbFrame.midY - (qm + 32), width: s.width, height: s.height)
            quick.alphaValue = 0
            addFloat(quick)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.16; quick.animator().alphaValue = 1 }
            run(0.6)
            type(quick.field, "Write the release notes #Aurora 30m")
            run(0.4)
            still("13-quick-add")
            run(0.3)
            let task = store.add(quick.field.stringValue)
            quick.removeFromSuperview()
            w.makeFirstResponder(nil)
            orb.refresh()
            if let l = orb.layer { TaskMotion.bounce(l, about: CGPoint(x: l.bounds.midX, y: l.bounds.midY)) }
            showPlus(plus, orb)
            say("added “\(task?.title ?? "Write the release notes")” to Aurora · 30m")
            run(2.6)
            still("13b-task-added")
            run(0.2)
            hidePlus(plus)
            unsay()
            run(0.6)
            hideOrb(orb)
            run(0.6)
        }

        // 14. Export: a timesheet, then every format.
        try clip("14-export-timesheet", "Export: tasks as a timesheet from your commits. Today, the last 7 days, all of it; then Excel, CSV and text.") {
            let export = TaskExportView(store: month)
            let s = TaskExportView.size
            export.frame = NSRect(x: ((canvas.width - s.width) / 2).rounded(), y: ((canvas.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            export.span = .today
            export.showNewest()
            addFloat(export)
            Motion.arrive(export, direction: 0)
            run(1.6)
            export.span = .week
            run(1.6)
            export.span = .all
            run(1.4)
            still("14-export-timesheet")
            run(0.4)
            for (f, n) in [(TaskExport.Format.xlsx, "14b-export-excel"), (.csv, "14c-export-csv"), (.text, "14d-export-text")] {
                export.format = f
                run(1.4)
                still(n)
                run(0.3)
            }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.16; export.animator().alphaValue = 0 }
            run(0.5)
        }

        // 15. Pull requests: the list, Approvals, a PR's page.
        try clip("15-pull-requests", "Pull requests: your reviews with checks, Approvals (who approved yours), and a PR's page with failing checks.") {
            let gh = GitHubCard()
            gh.selectTab(0)
            open(gh, .github)
            run(2.2)
            still("15-pull-requests")
            run(0.3)
            gh.selectTab(3)
            open(gh, .github)
            run(2.0)
            still("15b-pr-approvals")
            run(0.3)
            gh.selectTab(0)
            gh.openDetail(samplePRs()[0])
            open(gh, .github)
            run(2.4)
            still("15c-pr-detail")
            run(0.3)
            close()
            run(0.9)
        }

        // 16. Reminders.
        try clip("16-reminders", "Reminders: today's meetings from your calendars, reminders, water and break nudges.") {
            let rem = RemindersView(); rem.willShow()
            open(rem, .reminders)
            run(2.8)
            still("16-reminders")
            run(0.5)
            close()
            run(0.9)
        }

        // 17–20. Banners drop out of the notch and go back up.
        let banners: [(String, String, () -> (NSView & CardContent), CardKind)] = [
            ("17-banner-meeting", "A meeting heads-up drops from the notch with a Join button, counts down, and goes back up.", {
                rs.preview(ReminderAlert(id: "clip-meeting", kind: .calendarHeadsUp, headline: "You have a meeting in 5 minutes",
                                         detail: "Design review · 3:00 PM", eventID: "clip", joinURL: URL(string: "https://meet.example.com/design")))
                return ReminderAlertCard() }, .reminderAlert),
            ("18-banner-battery", "The low-battery banner when the battery crosses your mark.", {
                var warned = false, critical = false
                if let low = BatteryAlerts.lowAlert(VitalsSample.Battery(percent: 18, charging: false, onPower: false, toEmpty: 64),
                                                    threshold: 20, enabled: true, warned: &warned, warnedCritical: &critical) { rs.preview(low) }
                return ReminderAlertCard() }, .reminderAlert),
            ("19-banner-water", "A water reminder.", {
                rs.preview(ReminderAlert(id: "clip-water", kind: .now, headline: "Drink water", detail: "Every 2 hours · next 1:00 PM", hydration: true))
                return ReminderAlertCard() }, .reminderAlert),
            ("20-banner-pr", "A pull request toast with its reading-time line.", {
                let toast = ToastCard()
                toast.show(event: GHEvent(id: "clip", kind: .prOpened, title: "Add themes: seven built in, plus your own",
                                          subtitle: "acme/aurora #412", date: Date(), url: URL(string: "https://example.com/pr/412")!, approval: nil))
                return toast }, .toast),
        ]
        for (name, about, make, kind) in banners {
            try clip(name, about) {
                open(make(), kind)
                run(2.0)
                still(name)
                run(1.0)
                close()
                run(0.9)
            }
        }

        // 21. Settings, pane by pane.
        try clip("21-settings", "Settings: General, Appearance, Sounds, Clipboard, Shelf, Integrations (Claude, GitHub, Calendar), Shortcuts, About.") {
            let settings = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
            open(settings, .settings)
            run(1.8)
            still("21-settings-general")
            run(0.2)
            for p in SettingsCard.Pane.nav.dropFirst() {
                settings.select(p)
                open(settings, .settings)
                run(1.3)
                still("21-settings-\(p.title.lowercased())")
                run(0.1)
            }
            settings.select(.integrations)
            open(settings, .settings)
            run(0.8)
            settings.select(.claude)
            open(settings, .settings)
            run(1.6)
            still("21-settings-claude")
            run(0.2)
            close()
            run(0.9)
        }

        // 22. Themes: Appearance, then each built-in theme on Home.
        try clip("22-theme-change", "Themes: pick one in Settings → Appearance and the whole island recolours. Zera, Tokyo Night, Dracula, Catppuccin, Nord, Rosé Pine, Gruvbox.") {
            let appearance = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
            appearance.select(.appearance)
            open(appearance, .settings)
            run(1.6)
            for t in ThemeStore.shared.builtIns.dropFirst() + [ThemeStore.shared.builtIns[0]] {
                ThemeStore.shared.select(t)
                iv.themeChanged()
                // Screens are rebuilt when the palette changes, as the app does.
                let next = SettingsCard(defaultKind: .shelf, showingZera: true, loginEnabled: false)
                next.select(.appearance)
                open(next, .settings)
                run(1.0)
            }
            for t in ThemeStore.shared.builtIns {
                ThemeStore.shared.select(t)
                iv.themeChanged()
                open(HomeCard(), .home)
                run(0.9)
                still("22-theme-\(t.id)")
                run(0.1)
            }
            ThemeStore.shared.select(ThemeStore.shared.builtIns[0])
            iv.themeChanged()
            open(HomeCard(), .home)
            run(0.8)
            close()
            run(0.9)
        }

        // 23–25. The app opener (⌥Space): Zera drops down with the search.
        func openerClip(_ name: String, _ about: String, _ makeView: () -> (NSView & OpenerSurface), _ frame: NSRect, prefill: String, _ body: (NSView & OpenerSurface) -> Void) throws {
            try clip(name, about) {
                let v = makeView()
                v.frame = frame
                v.band = band
                v.ropeX = cx - frame.minX
                // The hanging Zera steps aside: there's only one of her.
                NSAnimationContext.runAnimationGroup { $0.duration = 0.12; buddy.animator().alphaValue = 0 }
                // Searched before it shows, so it never lists the apps on the Mac that records it: the
                // results settle while it's hidden, off the clip's clock.
                v.isHidden = true
                addFloat(v)
                v.prepare()
                if let o = v as? AppOpenerView { o.previewType(prefill) } else if let o = v as? TreeOpenerView { o.previewType(prefill) }
                v.layoutSubtreeIfNeeded()
                pump(0.6)
                v.isHidden = false
                // The frosted backdrop blurs whatever is behind the window; keep only its dim
                // tint so the clip stays transparent (blur the background in the edit instead).
                @MainActor func blurs(_ r: NSView) -> [NSView] { r.subviews.flatMap { ($0 is NSVisualEffectView ? [$0] : []) + blurs($0) } }
                blurs(v).forEach { $0.isHidden = true }
                v.animateIn()
                body(v)
                v.animateOut {}
                run(0.3)
                v.removeFromSuperview()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.25; buddy.animator().alphaValue = 1 }
                run(0.7)
            }
        }
        try openerClip("23-app-opener", "The app opener (⌥Space): Zera drops down with the search, you type, ⌘K opens the actions, Return tosses the app up to her.",
                       { AppOpenerView(frame: NSRect(origin: .zero, size: canvas)) }, NSRect(origin: .zero, size: canvas), prefill: "saf") { v in
            guard let opener = v as? AppOpenerView else { return }
            run(1.2)
            for n in 4...6 { opener.previewType(String("safari".prefix(n))); run(0.14) }
            run(1.0)
            still("23-app-opener")
            run(0.2)
            opener.previewActions()
            run(2.0)
            still("23b-app-opener-actions")
            run(0.2)
            opener.previewActions()
            run(0.8)
            if let safari = AppCatalog.shared.apps.first(where: { $0.name == "Safari" }) {
                var tossed = false
                opener.toss(safari) { tossed = true }
                run(0.9)
                _ = tossed
            }
        }
        try openerClip("24-app-opener-commands", "The opener's commands: type “kill” for Quit all, and more.",
                       { AppOpenerView(frame: NSRect(origin: .zero, size: canvas)) }, NSRect(origin: .zero, size: canvas), prefill: "kil") { v in
            guard let opener = v as? AppOpenerView else { return }
            run(1.2)
            opener.previewType("kill")
            run(0.14)
            run(1.6)
            still("24-app-opener-commands")
            run(0.4)
        }
        let treeW = TreeOpenerView.panelWidth
        let probe = TreeOpenerView(frame: NSRect(x: 0, y: 0, width: treeW, height: 800))
        probe.prepare()
        probe.previewType("safari")
        let treeH = min(canvas.height, probe.panelHeight(band: band, availableHeight: canvas.height))
        try openerClip("25-app-opener-classic", "The classic opener style: a tree of apps and commands held by Zera under the notch.",
                       { TreeOpenerView(frame: NSRect(x: 0, y: 0, width: treeW, height: treeH)) },
                       NSRect(x: (cx - treeW / 2).rounded(), y: 0, width: treeW, height: treeH), prefill: "saf") { v in
            guard let tree = v as? TreeOpenerView else { return }
            run(1.4)
            for n in 4...6 { tree.previewType(String("safari".prefix(n))); run(0.14) }
            run(1.0)
            still("25-app-opener-classic")
            run(0.2)
            tree.previewActions()
            run(1.8)
            still("25b-app-opener-classic-actions")
            run(0.4)
        }

        // 26. The orb's +: quick add, Tab starts it, the focus card opens.
        try clip("26-orb-quick-start", "Tap the + by the focus orb: quick add opens, type a task, Tab adds it and starts it, and the focus card opens with its timer running.") {
            let store = sampleTasks()
            let orb = FocusOrbView(store: store)
            popOrb(orb)
            run(1.0)
            let plus = OrbPlusView()
            showPlus(plus, orb)
            run(1.0)
            still("26-orb-plus")
            run(0.1)
            // The + is tapped: quick add opens beside the orb.
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; plus.animator().alphaValue = 0 }
            let quick = QuickAddView()
            quick.leftSide = false
            let qs = QuickAddView.size, qm = QuickAddView.margin
            quick.frame = NSRect(x: orbFrame.minX + om - 10 - (qs.width - qm), y: orbFrame.midY - (qm + 32), width: qs.width, height: qs.height)
            quick.alphaValue = 0
            addFloat(quick)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.16; quick.animator().alphaValue = 1 }
            run(0.5)
            type(quick.field, "Write the release notes #Aurora 30m")
            run(0.5)
            still("26b-orb-quick-add")
            run(0.2)
            // ⇥ adds it and starts it: the orb bounces, then opens into the focus card.
            _ = store.add(quick.field.stringValue, focus: true)
            quick.removeFromSuperview()
            w.makeFirstResponder(nil)
            orb.refresh()
            if let l = orb.layer { TaskMotion.bounce(l, about: CGPoint(x: l.bounds.midX, y: l.bounds.midY)) }
            let tick = everySecond { orb.tick() }
            run(0.5, each: tick)
            let card = FocusCardView(store: store)
            let size = NSSize(width: card.frame.width, height: card.desiredHeight)
            let m = FocusCardView.margin
            let y = max(band - m, min(canvas.height + m - size.height, orbFrame.midY - size.height / 2))
            let host = NSView(frame: NSRect(x: orbFrame.maxX - om + m - size.width, y: y, width: size.width, height: size.height))
            host.wantsLayer = true
            card.frame = NSRect(origin: .zero, size: size)
            host.addSubview(card)
            orb.isHidden = true
            addFloat(host)
            let fromOrb = CGPoint(x: orbFrame.midX - host.frame.minX, y: host.frame.maxY - orbFrame.midY)
            if let l = host.layer { TaskMotion.scale(l, about: fromOrb, from: 0.12, to: 1, opacity: 0, 1, spring: true) }
            let cardTick = everySecond { card.tick() }
            run(3.2, each: cardTick)
            still("26c-orb-focus-started")
            run(0.3, each: cardTick)
            if let l = host.layer { TaskMotion.scale(l, about: fromOrb, from: 1, to: 0.12, opacity: 1, 0, spring: false, duration: 0.17) }
            run(0.14)
            orb.isHidden = false
            popOrb(orb)
            run(1.0, each: tick)
            hideOrb(orb)
            run(0.6)
        }

        // A sample doc for the Shelf, and a stand-in `claude` (in the throwaway home) that answers
        // in Claude Code's own stream format, so the app's real streaming and summary page show.
        let docDir = home.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        let launchPlan = docDir.appendingPathComponent("Aurora launch plan.md")
        try """
        # Aurora 2.0 launch plan
        Ship date: Friday 24 Oct. Owner: Maya.

        ## Scope
        - Theme picker with seven built-in themes
        - Avatar cache on disk between launches
        - Settings that work from the keyboard

        ## Risks
        - Lint and unit tests failing on the settings PR (#214)
        - Release notes not written yet

        ## Next steps
        1. Sam fixes lint and tests on #214
        2. Theo reviews the avatar cache PR
        3. Write the release notes and the launch post
        """.write(to: launchPlan, atomically: true, encoding: .utf8)
        let summary = """
        ## Summary
        **Aurora 2.0 ships Friday, 24 Oct** (owner: Maya) with a theme picker, an on-disk avatar cache and keyboard-friendly settings.

        **Risks**
        - PR #214 is failing lint and unit tests
        - The release notes aren't written yet

        **Next steps**
        1. Sam fixes #214
        2. Theo reviews the avatar cache PR
        3. Write the release notes and launch post
        """
        let fake = home.appendingPathComponent(".zera-render/claude")
        try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        var events: [String] = []
        func json(_ o: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
        let sid = "render-session"
        events.append(json(["type": "system", "subtype": "init", "session_id": sid, "model": "claude-sonnet-4-5", "tools": []]))
        var chunk = ""
        for (i, word) in summary.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            chunk += (i == 0 ? "" : " ") + word
            if chunk.count > 9 {
                events.append(json(["type": "stream_event", "session_id": sid, "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": chunk]]]))
                chunk = ""
            }
        }
        if !chunk.isEmpty { events.append(json(["type": "stream_event", "session_id": sid, "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": chunk]]])) }
        events.append(json(["type": "assistant", "session_id": sid, "message": ["role": "assistant", "content": [["type": "text", "text": summary]]]]))
        events.append(json(["type": "result", "subtype": "success", "is_error": false, "result": summary, "session_id": sid, "num_turns": 1]))
        let eventsFile = fake.deletingLastPathComponent().appendingPathComponent("events.jsonl")
        try (events.joined(separator: "\n") + "\n").write(to: eventsFile, atomically: true, encoding: .utf8)
        try """
        #!/bin/bash
        case "$*" in
          *--version*) echo "2.1.0 (Claude Code)"; exit 0 ;;
          *--help*) cat <<'HELP'
        Usage: claude [options] [command] [prompt]

        Options:
          --allowedTools, --allowed-tools <tools...>  Tools to allow
          --disallowedTools, --disallowed-tools <tools...>  Tools to deny
          --include-partial-messages            Include partial message chunks
          --max-turns <turns>                   Maximum number of agentic turns
          --model <model>                       Model for the current session.
          -n, --name <name>                     Set a display name for this session
          --no-session-persistence              Disable session persistence
          --output-format <format>              "text", "json" or "stream-json"
          --permission-mode <mode>              Permission mode
          -p, --print                           Print response and exit
          -r, --resume [value]                  Resume a conversation
          --session-id <uuid>                   Use a specific session ID
          --strict-mcp-config                   Only use MCP servers from --mcp-config
          --system-prompt <prompt>              System prompt
          --tools <tools...>                    Available tools
          --verbose                             Verbose

        Commands:
          auth                                  Manage authentication
        HELP
            exit 0 ;;
          *"auth status"*) echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'; exit 0 ;;
        esac
        sleep 0.5
        while IFS= read -r line; do echo "$line"; sleep 0.045; done < "\(eventsFile.path)"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        ClaudeCLI.shared.executableOverride = fake.path
        ClaudeCLI.shared.invalidate()
        _ = ClaudeCLI.shared.info
        let cliDeadline = Date().addingTimeInterval(15)
        while Date() < cliDeadline, ClaudeCLI.shared.info.executable == nil { pump(0.2) }
        pump(1.0)
        func descendants(_ r: NSView) -> [NSView] { r.subviews.flatMap { [$0] + descendants($0) } }

        // 27. Drag a file onto the notch; it lands on the Shelf.
        try clip("27-shelf-drop", "Drag a file onto the notch: the Shelf opens, Zera reaches for it, and it lands. From there it drags straight back out into any app.") {
            _ = ShelfStore.shared.clear()
            let shelf = DropFilesView()
            shelf.willShow()
            run(0.5)      // the file is on its way (the cursor is drawn in the edit)
            let zone = descendants(shelf).compactMap { $0 as? FileDropZone }.first
            zone?.isTargeted = true
            shelf.willShow()
            open(shelf, .shelf)
            buddy.zera.mood = .excited
            say("toss it here! 🙌")
            run(1.5)
            still("27-shelf-drop-target")
            run(0.1)
            zone?.isTargeted = false
            _ = ShelfStore.shared.add(urls: [launchPlan])
            shelf.willShow()
            open(shelf, .shelf)
            unsay()
            buddy.zera.mood = .happy
            run(2.2)
            still("27b-shelf-dropped")
            run(0.6)
            // Dragged back out (drawn in the edit): the island tucks away as it leaves.
            close()
            buddy.zera.mood = .idle
            run(1.0)
        }

        // 28. Summarize: the answer streams into the file's page.
        try clip("28-shelf-summary", "Ask Claude about a file: Summarize sends it through your own Claude Code login and the answer streams into the file's page.") {
            _ = ShelfStore.shared.clear()
            _ = ShelfStore.shared.add(urls: [launchPlan])
            let shelf = DropFilesView()
            shelf.willShow()
            open(shelf, .shelf)
            run(1.2)
            still("28-shelf-summarize")
            run(0.1)
            ZeraAssistant.shared.run(.summarize, on: launchPlan)
            shelf.setExpanded(true)
            open(shelf, .shelf)
            var last = -1.0
            run(5.0) { t in if t - last > 0.3 { last = t; self.open(shelf, .shelf) } }
            still("28b-shelf-summary")
            run(0.6)
            close()
            run(0.9)
        }

        // 29. The opener's arc: your usual apps, ← → glide the choice along it, Return tosses it to
        // Zera. Only macOS's own apps, pinned in a set order: the rest of this Mac's apps are taken
        // out of the catalog for the take (in memory only), so none of them are on camera.
        var arcReady = false
        AppCatalog.shared.refreshIfNeeded { arcReady = true }
        let arcDeadline = Date().addingTimeInterval(20)
        while !arcReady && Date() < arcDeadline { pump(0.1) }
        for a in AppCatalog.shared.apps where !(a.url.path.hasPrefix("/System/") || a.url.path == "/Applications/Safari.app") {
            AppCatalog.shared.remove(a)
        }
        let pinned = ["/Applications/Safari.app", "/System/Applications/Notes.app", "/System/Applications/Calendar.app",
                      "/System/Applications/Music.app", "/System/Applications/Photos.app", "/System/Applications/Maps.app",
                      "/System/Applications/Messages.app"].filter { FileManager.default.fileExists(atPath: $0) }
        UserDefaults.standard.set(pinned, forKey: "appOpener.pinned")
        UserDefaults.standard.removeObject(forKey: "appOpener.recent")
        UserDefaults.standard.removeObject(forKey: "appOpener.usage")
        UserDefaults.standard.set(false, forKey: "appOpener.runningFirst")
        AppCatalog.shared.current = nil
        try openerClip("29-app-opener-arc", "The opener's arc: ⌥Space brings down your usual apps on an arc; ← → glide the choice along it, and Return tosses the app up to Zera.",
                       { AppOpenerView(frame: NSRect(origin: .zero, size: canvas)) }, NSRect(origin: .zero, size: canvas), prefill: "") { v in
            guard let opener = v as? AppOpenerView else { return }
            // Return launches: here it only tosses the app up to her.
            opener.onLaunch = { app, _ in opener.toss(app) {} }
            let windowNumber = w.windowNumber
            @MainActor func press(_ code: UInt16) {
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                            isARepeat: false, keyCode: code) {
                    _ = opener.handleKeyEvent(e)
                }
            }
            run(1.4)
            still("29-app-opener-arc")
            run(0.1)
            for _ in 0..<3 { press(124); run(0.45) }       // →
            run(0.4)
            still("29b-app-opener-arc-moved")
            run(0.1)
            for _ in 0..<2 { press(123); run(0.45) }       // ←
            run(0.5)
            press(36)                                       // ⏎
            run(1.3)
        }

        // What was made, for the README.
        // (A run limited by ZERA_CLIPS_ONLY updates its own entries and keeps the rest.)
        if !made.isEmpty {
            let manifest = out.appendingPathComponent("clips/manifest.json")
            let old = (try? Data(contentsOf: manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            let names = Set(made.compactMap { $0["name"] as? String })
            let all = (old.filter { !names.contains($0["name"] as? String ?? "") } + made)
                .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)
        }
    }
}
