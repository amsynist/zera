import AppKit
import QuartzCore
import ScreenCaptureKit

/// Short-lived visual proxies. Real windows move once under this surface; captured
/// images never leave memory, and no capture stream or background timer is created.
@MainActor
final class ArrangeVisualTransition: NSObject, NSWindowDelegate {
    struct Tile { var id: String; var frame: CGRect; var image: CGImage }
    private let panel: NSPanel
    private let root = CALayer()
    private let display: CGRect
    private var tiles: [String: CALayer] = [:]
    private var watchdog: DispatchWorkItem?
    private var closed = false
    private var presented = false
    private var demo = false
    private var demoStart: [String: CGRect] = [:]
    private var demoEnd: [String: CGRect] = [:]
    private var demoStartImages: [String: CGImage] = [:]
    private var demoEndImages: [String: CGImage] = [:]
    private var workspaceTargets: [String: CGRect] = [:]
    private weak var replayButton: CardButton?
    private static var capturing = false
    var onClose: (() -> Void)?

    init(display: CGRect, background: CGImage?, tiles: [Tile], preview: Bool = false) {
        self.display = display; self.demo = preview
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = CGRect(x: display.minX, y: top - display.maxY, width: display.width, height: display.height)
        panel = NSPanel(contentRect: frame, styleMask: preview ? [.titled, .closable] : [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.title = "Window motion preview"
        // The image layer fades during handoff; an opaque NSPanel would reveal black.
        panel.isOpaque = preview; panel.backgroundColor = preview ? .black : .clear
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = !preview
        panel.level = .floating; panel.hasShadow = preview
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        let view = FlippedView(frame: CGRect(origin: .zero, size: display.size))
        // Layer-hosted: AppKit must not redraw/resize a backing layer containing captures.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: display.size)
        root.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "sublayers": NSNull(), "opacity": NSNull()]
        view.layer = root; view.wantsLayer = true
        root.isGeometryFlipped = true; root.masksToBounds = true
        root.backgroundColor = NSColor(white: 0.055, alpha: 1).cgColor
        root.contents = background; root.contentsGravity = .resize
        panel.contentView = view
        for tile in tiles {
            let layer = CALayer(); layer.contents = tile.image; layer.contentsGravity = .resize
            layer.cornerRadius = 10; layer.masksToBounds = true
            layer.frame = local(tile.frame); root.addSublayer(layer); self.tiles[tile.id] = layer
            demoStart[tile.id] = tile.frame
            if preview { demoStartImages[tile.id] = tile.image }
        }
        CATransaction.commit()
        if preview {
            let label = NSTextField(labelWithString: "Sample windows · slow preview · no screen capture")
            label.font = Typo.secondary; label.textColor = Pal.textSecondary
            label.frame = CGRect(x: 20, y: 16, width: 410, height: 24); view.addSubview(label)
            let replay = CardButton("Replay", style: .secondary, target: self, action: #selector(replay))
            replay.frame = CGRect(x: display.width - 108, y: 12, width: 88, height: Metrics.control); view.addSubview(replay)
            replayButton = replay
            panel.center()
        }
    }
    private func local(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: -display.minX, dy: -display.minY) }
    /// Capture the restored workspace behind the outgoing scene. Every tile keeps
    /// its real size; a single shared animation translates both groups together.
    @available(macOS 14.0, *)
    func prepareWorkspace(windows: [ArrangeWindow], frames: [String: CGRect], direction: CGFloat) async -> Bool {
        guard !closed, windows.count <= 8 else { return false }
        if Bundle.main.bundleIdentifier?.hasSuffix(".review") == true, windows.contains(where: { $0.bundle == "com.openai.codex" }) { return false }
        if windows.isEmpty { return stageWorkspace([], direction: direction) != nil }
        do {
            // WindowServer's sharing metadata can trail an acknowledged AX restore by
            // one frame. Reconcile briefly during this command, never with an idle timer.
            var matches: [String: SCWindow] = [:]
            for attempt in 0..<4 {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                matches.removeAll()
                for window in windows {
                    guard let frame = frames[window.id], display.contains(frame) else { return false }
                    let found = content.windows.filter { $0.owningApplication?.processID == window.pid && ArrangeGeometry.near($0.frame, frame, tolerance: 3) }
                    if found.count == 1 { matches[window.id] = found[0] }
                }
                if matches.count == windows.count { break }
                guard !closed else { return false }
                if attempt < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
            }
            guard matches.count == windows.count else { Diag.log("arrange workspace incoming geometry unavailable"); return false }
            var incoming: [Tile] = []
            for window in windows {
                guard let frame = frames[window.id], let match = matches[window.id] else { return false }
                let config = Self.captureConfiguration(size: frame.size)
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: match), configuration: config)
                incoming.append(.init(id: window.id, frame: frame, image: image))
            }
            return stageWorkspace(incoming, direction: direction) != nil
        } catch { Diag.log("arrange workspace incoming capture unavailable: \((error as NSError).code)"); return false }
    }
    func stageWorkspace(_ incoming: [Tile], direction: CGFloat) -> [String: CGRect]? {
        guard !closed, incoming.count <= 8 else { return nil }
        workspaceTargets = demoStart.mapValues { $0.offsetBy(dx: -direction * display.width, dy: 0) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for tile in incoming {
            if tiles[tile.id] != nil { workspaceTargets[tile.id] = tile.frame; continue }
            let id = "incoming:" + tile.id
            let layer = CALayer(); layer.contents = tile.image; layer.contentsGravity = .resize
            layer.cornerRadius = 10; layer.masksToBounds = true
            layer.frame = local(tile.frame.offsetBy(dx: direction * display.width, dy: 0))
            root.addSublayer(layer); tiles[id] = layer; workspaceTargets[id] = tile.frame
        }
        CATransaction.commit()
        Diag.log("arrange workspace scene: \(demoStart.count) outgoing, \(incoming.count) incoming, shared slide")
        return workspaceTargets
    }
    func animateWorkspace(completion: @escaping () -> Void) { animate(to: workspaceTargets, completion: completion) }
    func present() {
        guard !closed else { return }
        // Commit the complete source scene before exposing it to WindowServer.
        CATransaction.flush()
        panel.orderFrontRegardless()
        if demo { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        panel.displayIfNeeded(); CATransaction.flush()
        if !demo {
            presented = true; Diag.log("arrange visual presented")
            let work = DispatchWorkItem { [weak self] in self?.cancel() }; watchdog = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }
    func animate(to frames: [String: CGRect], completion: @escaping () -> Void) {
        guard !closed else { completion(); return }
        if !demo { Diag.log("arrange visual motion: \(tiles.count) window images") }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (demo ? 0.65 : (workspaceTargets.isEmpty ? 0.30 : 0.24))
        let began = CACurrentMediaTime()
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.closed else { completion(); return }
                if self.demo {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    for (id, image) in self.demoEndImages { self.tiles[id]?.contents = image }
                    CATransaction.commit(); completion(); return
                }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                CATransaction.setCompletionBlock { DispatchQueue.main.async { self.cancel(); completion() } }
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.07
                self.root.opacity = 0; self.root.add(fade, forKey: "handoff"); CATransaction.commit()
            }
        }
        for (id, frame) in frames {
            guard let layer = tiles[id] else { continue }
            let start = layer.frame, end = local(frame)
            layer.frame = end
            guard duration > 0 else { continue }
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: CGPoint(x: start.midX, y: start.midY))
            position.toValue = NSValue(point: CGPoint(x: end.midX, y: end.midY))
            position.duration = duration
            let bounds = CABasicAnimation(keyPath: "bounds")
            bounds.fromValue = NSValue(rect: CGRect(origin: .zero, size: start.size))
            bounds.toValue = NSValue(rect: CGRect(origin: .zero, size: end.size))
            bounds.duration = duration
            let group = CAAnimationGroup(); group.animations = [position, bounds]
            group.duration = duration; group.beginTime = began
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.85, 0.24, 1)
            layer.add(group, forKey: "windowMotion")
        }
        CATransaction.commit()
        #if DEBUG
        if demo, duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration / 3) { [weak self] in
                guard let self, !self.closed, let layer = self.tiles["0"] else { return }
                Diag.log("arrange sample GPU model \(layer.frame), presented \(String(describing: layer.presentation()?.frame))")
            }
        }
        #endif
    }
    func cancel() {
        dispose(closeWindow: true)
    }
    private func dispose(closeWindow: Bool) {
        guard !closed else { return }; closed = true
        if presented { Diag.log("arrange visual ended") }
        watchdog?.cancel(); watchdog = nil
        root.removeAllAnimations(); root.sublayers?.forEach { $0.removeAllAnimations(); $0.contents = nil }
        root.sublayers = nil; root.contents = nil; tiles.removeAll()
        demoStartImages.removeAll(); demoEndImages.removeAll()
        workspaceTargets.removeAll()
        panel.orderOut(nil); if closeWindow { panel.close() }; onClose?(); onClose = nil
    }
    func windowWillClose(_ notification: Notification) { dispose(closeWindow: false) }
    @objc private func replay() {
        guard !closed else { return }
        replayButton?.isEnabled = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (id, frame) in demoStart { tiles[id]?.frame = local(frame); tiles[id]?.contents = demoStartImages[id] }
        CATransaction.commit()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.animate(to: self.demoEnd) { [weak self] in self?.replayButton?.isEnabled = true }
        }
    }
    static func preview() -> ArrangeVisualTransition {
        let display = CGRect(x: 0, y: 0, width: 700, height: 430)
        let area = CGRect(x: 20, y: 62, width: 660, height: 348)
        let starts = ArrangeLayout.twoAbove.frames(count: 3, in: area)
        let ends = ArrangeLayout.columns.frames(count: 3, in: area)
        let names = ["Editor", "Browser", "Terminal"]
        let colors = [NSColor(srgbRed: 0.20, green: 0.27, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.27, green: 0.23, blue: 0.37, alpha: 1), NSColor(srgbRed: 0.16, green: 0.30, blue: 0.29, alpha: 1)]
        func image(_ index: Int, size: CGSize) -> CGImage? {
            let image = NSImage(size: size, flipped: true) { rect in
                colors[index].setFill(); rect.fill()
                (names[index] as NSString).draw(at: CGPoint(x: 16, y: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.white])
                for row in 0..<max(1, Int((size.height - 56) / 22)) {
                    NSColor.white.withAlphaComponent(row == 0 ? 0.18 : 0.07).setFill()
                    let fraction: CGFloat = row % 2 == 0 ? 0.88 : 0.62
                    let bar = CGRect(x: 16, y: 54 + CGFloat(row) * 22, width: (size.width - 32) * fraction, height: 8)
                    NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
                }
                return true
            }
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let tiles = names.indices.compactMap { index -> Tile? in
            guard let cg = image(index, size: starts[index].size) else { return nil }
            return .init(id: String(index), frame: starts[index], image: cg)
        }
        let scene = ArrangeVisualTransition(display: display, background: nil, tiles: tiles, preview: true)
        scene.demoEnd = Dictionary(uniqueKeysWithValues: ends.enumerated().map { (String($0.offset), $0.element) })
        for index in names.indices { scene.demoEndImages[String(index)] = image(index, size: ends[index].size) }
        scene.present(); scene.replay(); return scene
    }

    /// Permission preflight never prompts. A UI action requests access separately.
    @available(macOS 14.0, *)
    static func captureConfiguration(size: CGSize, limit: CGFloat = 1280) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = min(1, limit / max(size.width, size.height))
        config.width = max(1, Int(size.width * scale)); config.height = max(1, Int(size.height * scale))
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.capturesAudio = false
        // ScreenCaptureKit's backgroundColor is unowned(unsafe). Keep its framework-
        // owned default; a temporary NSColor.cgColor dangles when the config is copied.
        return config
    }
    @available(macOS 14.0, *)
    static func capture(windows: [ArrangeWindow], frames: [String: CGRect], display: ArrangeDisplay, allowEmpty: Bool = false) async -> ArrangeVisualTransition? {
        guard CGPreflightScreenCaptureAccess(), !capturing, (allowEmpty || !windows.isEmpty), windows.count <= 8,
              windows.allSatisfy({ display.frame.contains($0.frame) && frames[$0.id].map(display.frame.contains) == true }) else { return nil }
        // Agent-operated Review must never capture its host, even as background content.
        let review = Bundle.main.bundleIdentifier?.hasSuffix(".review") == true
        guard !review || !windows.contains(where: { $0.bundle == "com.openai.codex" }) else { return nil }
        capturing = true; defer { capturing = false }
        let began = ProcessInfo.processInfo.systemUptime
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let screen = content.displays.first(where: { String($0.displayID) == display.id }) else { return nil }
            var matches: [(ArrangeWindow, SCWindow)] = []
            for window in windows {
                let found = content.windows.filter { $0.owningApplication?.processID == window.pid && ArrangeGeometry.near($0.frame, window.frame, tolerance: 6) }
                guard found.count == 1 else { return nil }; matches.append((window, found[0]))
            }
            let excluded = Set(matches.map { $0.1.windowID })
            let frontToBack = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
            let order = Dictionary(frontToBack.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            matches.sort { (order[$0.1.windowID] ?? 0) > (order[$1.1.windowID] ?? 0) }
            let backgroundExclusions = content.windows.filter { excluded.contains($0.windowID) || $0.owningApplication?.processID == getpid() || (review && $0.owningApplication?.bundleIdentifier == "com.openai.codex") }
            func image(_ filter: SCContentFilter, size: CGSize, limit: CGFloat = 1280) async throws -> CGImage {
                let config = captureConfiguration(size: size, limit: limit)
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
            let background = try await image(SCContentFilter(display: screen, excludingWindows: backgroundExclusions), size: display.frame.size, limit: 1920)
            var tiles: [Tile] = []
            for (window, match) in matches {
                let snapshot = try await image(SCContentFilter(desktopIndependentWindow: match), size: window.frame.size)
                tiles.append(.init(id: window.id, frame: window.frame, image: snapshot))
            }
            let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard matches.allSatisfy({ pair in fresh.windows.contains { $0.windowID == pair.1.windowID && ArrangeGeometry.near($0.frame, pair.0.frame, tolerance: 3) } }) else { return nil }
            Diag.log("arrange visual captured: \(tiles.count) windows, \(Int((ProcessInfo.processInfo.systemUptime - began) * 1000)) ms")
            return ArrangeVisualTransition(display: display.frame, background: background, tiles: tiles)
        } catch { Diag.log("arrange visual capture unavailable: \((error as NSError).code)"); return nil }
    }
}
