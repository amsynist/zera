import AppKit
import QuartzCore

// MARK: - Style

/// How the island's edge glows (Settings → Appearance → Light, and onboarding step 2).
/// Persisted in `zera.notchLight`; the strength in `zera.notchLight.intensity`.
enum NotchLightStyle: Int, CaseIterable {
    case classic, nimbus, prism, pixel, lumiere

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .nimbus: return "Nimbus"
        case .prism: return "Prism"
        case .pixel: return "Pixel"
        case .lumiere: return "Lumière"
        }
    }

    var blurb: String {
        switch self {
        case .classic: return "A quiet edge, with light for events"
        case .nimbus: return "A soft wide halo"
        case .prism: return "Colour slowly drifting along the edge"
        case .pixel: return "A stepped, retro glow"
        case .lumiere: return "A gentle breathing light"
        }
    }

    /// Whether this style keeps an animation running while the island is visible.
    var animates: Bool { self == .prism || self == .lumiere }

    nonisolated static let changed = Notification.Name("ZeraNotchLightChanged")
    private static let key = "zera.notchLight"
    private static let intensityKey = "zera.notchLight.intensity"

    static var current: NotchLightStyle {
        get {
            // Once for Zera v2: one solid line of light round the notch (the old stepped Pixel edge
            // read as a dashed border that didn't match the glow).
            let d = UserDefaults.standard
            if !d.bool(forKey: "zera.notchLight.z2Migrated") {
                d.set(true, forKey: "zera.notchLight.z2Migrated")
                if d.integer(forKey: key) == NotchLightStyle.pixel.rawValue { d.set(NotchLightStyle.classic.rawValue, forKey: key) }
            }
            return NotchLightStyle(rawValue: d.integer(forKey: key)) ?? .classic
        }
        set {
            let old = current
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            guard old != newValue else { return }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// 0.4 … 1.4; multiplies every stroke and glow opacity.
    static var intensity: CGFloat {
        get {
            let u = UserDefaults.standard
            guard u.object(forKey: intensityKey) != nil else { return 1 }
            return clampIntensity(CGFloat(u.double(forKey: intensityKey)))
        }
        set {
            let v = clampIntensity(newValue)
            let old = intensity
            UserDefaults.standard.set(Double(v), forKey: intensityKey)
            guard abs(old - v) > 0.001 else { return }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static let intensityRange: ClosedRange<CGFloat> = 0.4...1.4

    private static let reactionsKey = "zera.notchLight.reactions"
    /// Whether the edge reacts to shortcuts, volume and agents (`NotchLightLayer.react`). On by default.
    static var reactionsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: reactionsKey) as? Bool ?? true }
        set {
            let old = reactionsEnabled
            UserDefaults.standard.set(newValue, forKey: reactionsKey)
            guard old != newValue else { return }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func clampIntensity(_ v: CGFloat) -> CGFloat {
        guard v.isFinite else { return 1 }
        return min(intensityRange.upperBound, max(intensityRange.lowerBound, v))
    }
}

/// The island's state as the light sees it (mirrors `IslandView.Mode`).
enum NotchLightMode { case closed, peek, open }

/// A moment the edge reacts to (`NotchLightLayer.react`). Works in every mode, closed included.
enum NotchLightReaction: Equatable {
    case copy, cut, paste, undo, redo, save, screenshot, shortcut   // keyboard
    case modifier(held: Bool)                                      // ⌘/⌥/⌃ held → steady faint glow until released
    case capsLock(on: Bool)                                        // whole outline flashes: twice on, once quietly off
    case shiftHeld                                                 // Shift held on its own: a crest rises up the arms
    case fileDrag(active: Bool)                                    // files dragged anywhere → amber breathing until the drop
    case listening(active: Bool)                                   // the microphone is open (voice answer, dictation)
    case music(active: Bool)                                       // a slow wave in the artwork's colour while a track plays
    case level(kind: LevelKind, value: Double?)                    // value 0…1, nil = unknown (just blink the icon colour)
    case agentArrival, approvalNeeded, success, danger, notification
    enum LevelKind { case volume, brightness, mute, battery }

    /// One in-flight animation per key: a repeat restarts it instead of stacking.
    var key: String {
        switch self {
        case .copy: return "copy"
        case .cut: return "cut"
        case .paste: return "paste"
        case .undo: return "undo"
        case .redo: return "redo"
        case .save: return "save"
        case .screenshot: return "screenshot"
        case .shortcut: return "shortcut"
        case .modifier: return "modifier"
        case .capsLock: return "capsLock"
        case .shiftHeld: return "shiftHeld"
        case .fileDrag: return "fileDrag"
        case .listening: return "listening"
        case .music: return "music"
        case .level: return "level"
        case .agentArrival: return "agentArrival"
        case .approvalNeeded: return "approvalNeeded"
        case .success: return "success"
        case .danger: return "danger"
        case .notification: return "notification"
        }
    }
}

// MARK: - Layer

/// The edge light of the island, Core Animation only. The owner hands it the island's open
/// (unclosed) outline in `apply(path:bounds:mode:animated:)`; it draws the current style and
/// runs its animation (Prism drift, Lumière breathing) only while visible and motion isn't reduced.
/// `pause()` / `setVisible(false)` strip every animation so nothing runs when the island is closed.
///
/// `fade(from:to:)` reproduces the island's top fade (the edge appears below the screen edge).
///
/// Reactions (`react(_:)`) draw on their own `reactionHost`, above the style and outside its mode
/// opacity and fade mask, so the closed notch outline lights up briefly on ⌘C, volume keys, an
/// agent arriving… They use the last path given to `apply`.
final class NotchLightLayer: CALayer {
    // Mode opacity and the top fade live here, so reactions stay visible when the island is closed.
    private let styleHost = CALayer()
    /// Reactions, always at full opacity; each one is a short-lived sublayer.
    private let reactionHost = CALayer()
    private var lastPath: CGPath?
    private var active: [String: Reaction] = [:]
    private var levelFadeWork: DispatchWorkItem?
    /// Where the path runs along the top edge (fractions of its length), for the `.level` arc.
    private var topSpan: (start: CGFloat, end: CGFloat, reversed: Bool)?
    private var topSpanExplicit = false
    /// When the path has no top run (the island's open outline), the arc is this straight line
    /// from its first point to its last: left ear → right ear.
    private var syntheticTop: CGPath?
    private weak var levelShape: CAShapeLayer?

    // The crisp line every style starts from.
    private let stroke = CAShapeLayer()
    // Classic / Lumière: the line's own soft shadow. Nimbus: a wide halo.
    private let halo = CAShapeLayer()
    // Pixel: two stepped copies of the dashed line, no shadow.
    private let stepA = CAShapeLayer()
    private let stepB = CAShapeLayer()
    // Prism: a conic gradient drifting under the stroked outline.
    private let prismHost = CALayer()
    private let prismGradient = CAGradientLayer()
    private let prismMask = CAShapeLayer()
    /// Everything that breathes together (Lumière).
    private let group = CALayer()
    private let fadeMask = CAGradientLayer()

    private var hasFade = false
    private var visible = false
    private var paused = false
    private var currentMode: NotchLightMode = .closed
    private var observers: [NSObjectProtocol] = []

    /// `lightStyle`, not `style`: CALayer already has a `style` dictionary.
    var lightStyle: NotchLightStyle = NotchLightStyle.current {
        didSet { if lightStyle != oldValue { recolor(); restyle(); syncAnimations() } }
    }
    var accent: NSColor = Neon.accent { didSet { recolor() } }
    /// The second colour of the Prism drift (the theme's highlight by default).
    var highlight: NSColor = Neon.highlight { didSet { recolor() } }
    var intensity: CGFloat = NotchLightStyle.intensity {
        didSet { if abs(intensity - oldValue) > 0.001 { restyle() } }
    }
    /// Follow Settings (style + intensity) and the theme on its own. On by default.
    var followsSettings = true
    /// Expanded application chrome stays neutral; style previews retain their actual light.
    var quietWhenExpanded = false
    /// Colours the next copy / paste comet only (a colour you just copied runs along the edge),
    /// then clears itself. Set right before `react(.copy)` / `react(.paste)`.
    var oneShotTint: NSColor?

    override init() {
        super.init()
        build()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let l = layer as? NotchLightLayer {
            lightStyle = l.lightStyle; accent = l.accent; highlight = l.highlight; intensity = l.intensity
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // Both centres accept each other's tokens; removing from either is enough.
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        levelFadeWork?.cancel()
    }

    private func build() {
        masksToBounds = false
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        for s in [stroke, halo, stepA, stepB, prismMask] {
            s.fillColor = nil
            s.lineJoin = .round
            s.lineCap = .round
            s.contentsScale = contentsScale
        }
        prismHost.mask = prismMask
        prismHost.masksToBounds = false
        prismGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        prismGradient.endPoint = CGPoint(x: 1, y: 0.5)
        prismGradient.type = .conic
        prismHost.addSublayer(prismGradient)

        group.masksToBounds = false
        [halo, stepB, stepA, prismHost, stroke].forEach { group.addSublayer($0) }
        styleHost.masksToBounds = false
        styleHost.addSublayer(group)
        styleHost.opacity = 0
        addSublayer(styleHost)
        reactionHost.masksToBounds = false
        addSublayer(reactionHost)

        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)

        recolor()
        restyle()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NotchLightStyle.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.followsSettings else { return }
            self.intensity = NotchLightStyle.intensity
            self.lightStyle = NotchLightStyle.current
        })
        observers.append(nc.addObserver(forName: Palette.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.followsSettings else { return }
            self.accent = WallpaperTint.lightAccent
            self.highlight = Neon.highlight
        })
        observers.append(nc.addObserver(forName: WallpaperTint.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.followsSettings else { return }
            self.accent = WallpaperTint.lightAccent
        })
        if followsSettings, WallpaperTint.shared.color != nil { accent = WallpaperTint.lightAccent }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncAnimations()
        })
    }

    // MARK: Public

    /// The outline to light: the island's open (not closed) path, in `bounds` coordinates.
    func apply(path: CGPath, bounds b: CGRect, mode: NotchLightMode, animated: Bool) {
        let modeChanged = mode != currentMode
        currentMode = mode
        lastPath = path
        if quietWhenExpanded && mode != .closed { cancelReactions() }
        if !topSpanExplicit { deriveTopSpan(from: path) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = b
        styleHost.frame = bounds
        reactionHost.frame = bounds
        group.frame = bounds
        for l in [stroke, halo, stepA, stepB, prismHost, prismMask] { l.frame = bounds }
        layoutPrism()
        if hasFade { fadeMask.frame = bounds.insetBy(dx: -80, dy: 0) }
        for r in active.values { r.relayout(path, bounds) }
        CATransaction.commit()

        let shapes = [stroke, halo, stepA, stepB, prismMask]
        if animated, !Motion.reduced {
            for l in shapes {
                let morph = CABasicAnimation(keyPath: "path")
                morph.fromValue = l.presentation()?.path ?? l.path
                morph.toValue = path
                morph.duration = Motion.duration(0.25)
                morph.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                l.add(morph, forKey: "morph")
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapes.forEach { $0.path = path }
        CATransaction.commit()

        if modeChanged {
            recolor(); restyle()
            visible = mode != .closed
            applyModeOpacity(animated: animated)
            syncAnimations()
        }
    }

    /// Fade the light in from the top: fully clear above `from`, fully shown below `to` (points).
    func fade(from: CGFloat, to: CGFloat) {
        let h = max(1, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !hasFade { hasFade = true; styleHost.mask = fadeMask }
        // Wider than the outline so a wide halo isn't clipped at the sides.
        fadeMask.frame = bounds.insetBy(dx: -80, dy: 0)
        fadeMask.locations = [NSNumber(value: Double(from / h)), NSNumber(value: Double(to / h))]
        CATransaction.commit()
    }

    func clearFade() {
        hasFade = false
        styleHost.mask = nil
    }

    func setVisible(_ on: Bool) {
        visible = on
        if !on { currentMode = .closed } else if currentMode == .closed { currentMode = .open }
        recolor(); restyle()
        if quietWhenExpanded && on { cancelReactions() }
        applyModeOpacity(animated: true)
        syncAnimations()
    }

    /// Strips every running animation (the island is closed or hidden).
    func pause() {
        paused = true
        syncAnimations()
    }

    func resume() {
        paused = false
        syncAnimations()
    }

    // MARK: Look

    private var k: CGFloat { max(0, intensity) }
    private func a(_ v: CGFloat) -> Float { Float(min(1, v * k)) }

    private func recolor() {
        let c = accent.cgColor
        stroke.strokeColor = quietWhenExpanded && currentMode != .closed
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : (lightStyle == .classic ? NSColor.white.withAlphaComponent(0.18).cgColor : c)
        stroke.shadowColor = c
        halo.strokeColor = c
        halo.shadowColor = c
        stepA.strokeColor = c
        stepB.strokeColor = c
        prismMask.strokeColor = NSColor.black.cgColor
        prismGradient.colors = [accent.cgColor, highlight.cgColor, accent.cgColor,
                                accent.blended(withFraction: 0.5, of: highlight)?.cgColor ?? highlight.cgColor, accent.cgColor]
        prismGradient.locations = [0, 0.3, 0.55, 0.78, 1]
    }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Reset to a clean slate, then set what the style needs.
        for l in [stroke, halo, stepA, stepB] {
            l.lineDashPattern = nil
            l.lineDashPhase = 0
            l.lineCap = .round
            l.shadowOpacity = 0
            l.shadowRadius = 0
            l.shadowOffset = .zero
            l.isHidden = true
        }
        prismHost.isHidden = true
        stroke.isHidden = false
        stroke.lineWidth = 1

        if quietWhenExpanded && currentMode != .closed {
            stroke.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
            stroke.opacity = 1
            CATransaction.commit()
            return
        }
        switch lightStyle {
        case .classic:
            stroke.opacity = a(0.8)
            stroke.shadowOpacity = 0
            stroke.shadowRadius = 0
        case .nimbus:
            stroke.opacity = a(0.3)
            halo.isHidden = false
            halo.lineWidth = 2
            halo.opacity = a(0.5)
            halo.shadowOpacity = 1
            halo.shadowRadius = 26
        case .prism:
            stroke.opacity = a(0.18)
            prismHost.isHidden = false
            prismHost.opacity = a(0.95)
            prismMask.lineWidth = 1.5
        case .pixel:
            stroke.opacity = a(0.7)
            for l in [stroke, stepA, stepB] {
                l.lineDashPattern = [3, 3]
                l.lineCap = .butt
            }
            stepA.isHidden = false
            stepA.lineWidth = 3
            stepA.lineDashPhase = 1.5
            stepA.opacity = a(0.35)
            stepB.isHidden = false
            stepB.lineWidth = 5
            stepB.lineDashPhase = 3
            stepB.opacity = a(0.15)
        case .lumiere:
            stroke.opacity = a(0.6)
            stroke.shadowOpacity = a(0.9)
            stroke.shadowRadius = 14
        }
        CATransaction.commit()
    }

    private func layoutPrism() {
        // A square bigger than the diagonal so rotating it never uncovers the outline.
        let b = bounds
        let d = ceil(sqrt(b.width * b.width + b.height * b.height)) + 4
        prismGradient.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        prismGradient.position = CGPoint(x: b.midX, y: b.midY)
    }

    private func applyModeOpacity(animated: Bool) {
        let target: Float
        switch currentMode {
        case .closed: target = 0
        case .peek: target = 0.9
        case .open: target = 1
        }
        if animated, !Motion.reduced {
            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = styleHost.presentation()?.opacity ?? styleHost.opacity
            fadeAnim.toValue = target
            fadeAnim.duration = Motion.duration(0.3)
            styleHost.add(fadeAnim, forKey: "fade")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        styleHost.opacity = target
        CATransaction.commit()
    }

    // MARK: Animations

    private static let driftKey = "drift"
    private static let breathKey = "breath"

    /// Runs only what the style wants, only while visible, never with Reduce Motion.
    private func syncAnimations() {
        let running = visible && (!quietWhenExpanded || currentMode == .closed) && !paused && !Motion.reduced
        let wantDrift = running && lightStyle == .prism
        let wantBreath = running && lightStyle == .lumiere

        if wantDrift {
            if prismGradient.animation(forKey: Self.driftKey) == nil {
                let r = CABasicAnimation(keyPath: "transform.rotation.z")
                r.fromValue = 0
                r.toValue = -Double.pi * 2
                r.duration = 20
                r.repeatCount = .infinity
                r.timingFunction = CAMediaTimingFunction(name: .linear)
                r.isRemovedOnCompletion = false
                prismGradient.add(r, forKey: Self.driftKey)
            }
        } else {
            prismGradient.removeAnimation(forKey: Self.driftKey)
        }

        if wantBreath {
            if group.animation(forKey: Self.breathKey) == nil {
                let b = CABasicAnimation(keyPath: "opacity")
                b.fromValue = 0.45
                b.toValue = 0.9
                b.duration = 4
                b.autoreverses = true
                b.repeatCount = .infinity
                b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                b.isRemovedOnCompletion = false
                group.add(b, forKey: Self.breathKey)
            }
        } else {
            group.removeAnimation(forKey: Self.breathKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            group.opacity = 1
            CATransaction.commit()
        }
    }
}

// MARK: - Reactions

/// One in-flight reaction: its sublayer and how to follow a new path.
private final class Reaction {
    let container: CALayer
    let relayout: (CGPath, CGRect) -> Void
    init(container: CALayer, relayout: @escaping (CGPath, CGRect) -> Void) {
        self.container = container
        self.relayout = relayout
    }
    func remove() {
        container.removeAllAnimations()
        container.sublayers?.forEach { $0.removeAllAnimations(); $0.mask?.removeAllAnimations() }
        container.removeFromSuperlayer()
    }
}

extension NotchLightLayer {
    /// Settings → Appearance → "Reacts to shortcuts and volume". Read on every reaction.
    var reactionsEnabled: Bool { NotchLightStyle.reactionsEnabled }

    /// Where the path runs along the top edge, as fractions of its length (`start < end`), for the
    /// `.level` arc. IslandView can call this when it builds the path; otherwise it is derived from
    /// the geometry (see `deriveTopSpan`).
    func setTopSpan(start: CGFloat, end: CGFloat) {
        let a = max(0, min(1, start)), b = max(0, min(1, end))
        topSpan = (start: min(a, b), end: max(a, b), reversed: a > b)
        syntheticTop = nil
        topSpanExplicit = true
    }

    /// Back to deriving the top run from each path.
    func clearTopSpan() {
        topSpanExplicit = false
        if let p = lastPath { deriveTopSpan(from: p) }
    }

    /// Ends the sticky ones: approval breathing and a held modifier.
    func clearSticky() {
        endReaction("approvalNeeded")
        endReaction("modifier")
    }

    /// Removes every reaction at once (the island is going away).
    func cancelReactions() {
        levelFadeWork?.cancel(); levelFadeWork = nil
        active.values.forEach { $0.remove() }
        active.removeAll()
    }

    /// Lights the outline up for a moment. Works in every mode, including closed; a repeat of the
    /// same reaction while one is running restarts it. No-op (or a 120 ms flash) with Reduce Motion.
    func react(_ r: NotchLightReaction) {
        guard reactionsEnabled, !(quietWhenExpanded && currentMode != .closed),
              let path = lastPath, bounds.width > 0 else { return }
        let key = r.key
        if case .modifier(let held) = r, !held { endReaction(key); return }
        if case .fileDrag(let on) = r, !on { endReaction(key); return }
        if case .listening(let on) = r, !on { endReaction(key); return }
        if case .music(let on) = r, !on { endReaction(key); return }
        if key != "level" { endReaction(key) }
        // New sublayers get their first values without implicit actions; the explicit animations
        // below (added inside `run`'s own transaction) are unaffected.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let p = Pal
        let claude = p.tileClaude
        let white = NSColor(srgbRed: 1, green: 0.96, blue: 0.9, alpha: 1)
        let tint = oneShotTint
        oneShotTint = nil

        if Motion.reduced {
            switch r {
            case .modifier: steady(key, color: accent, opacity: 0.35, path: path)
            case .approvalNeeded: steady(key, color: claude, opacity: 0.5, path: path)
            case .level(let kind, let value):
                levelFadeWork?.cancel()
                endReaction(key)
                showLevel(kind: kind, value: value, path: path, color: levelColor(kind, white: white, p: p))
                scheduleLevelFade(after: 0.9, duration: 0)
            case .success, .danger: clearSticky(); flash(key, color: r == .success ? p.success : p.danger, path: path)
            case .screenshot: flash(key, color: .white, path: path)
            case .capsLock(let on): flash(key, color: on ? p.success : white, path: path)
            case .fileDrag: steady(key, color: tint ?? p.warning, opacity: 0.5, path: path)
            case .listening: steady(key, color: NSColor(srgbRed: 0.69, green: 0.48, blue: 1, alpha: 1), opacity: 0.6, path: path)
            case .agentArrival, .notification: flash(key, color: r == .agentArrival ? claude : accent, path: path)
            default: break   // copy / cut / paste / undo / redo / save / shortcut: nothing under Reduce Motion
            }
            return
        }

        switch r {
        // Each shortcut keeps its own colour (cut red, undo amber, save green) so the edge reads at a
        // glance; a copied colour paints its own comet.
        case .copy: comet(key, from: 0, to: 1, length: 0.18, duration: 0.55, color: tint ?? highlight, path: path)
        case .redo: comet(key, from: 0, to: 1, length: 0.12, duration: 0.4, color: accent, path: path)
        case .undo: comet(key, from: 1, to: 0, length: 0.12, duration: 0.4, color: p.warning, path: path)
        case .paste: pasteComets(key, color: tint ?? highlight, path: path)
        case .cut: pulse(key, color: p.danger, values: [0, 1, 0.15, 1, 0], duration: 0.42, path: path, width: 1.5, glow: 8)
        case .save: pulse(key, color: p.success, values: [0, 0.9, 0], duration: 0.6, path: path, width: 1.5, glow: 12)
        case .screenshot: pulse(key, color: .white, values: [1, 1, 0], keyTimes: [0, 0.6, 1], duration: 0.15, path: path, width: 1.5, glow: 6)
        case .shortcut: pulse(key, color: accent, values: [0, 0.35, 0], duration: 0.3, path: path, width: 1, glow: 4)
        case .modifier: fadeIn(key, color: accent, to: 0.35, duration: 0.25, path: path)
        case .capsLock(let on):
            // Twice when it comes on, once more quietly when it goes off.
            if on { pulse(key, color: p.success, values: [0, 1, 0.1, 1, 0], duration: 0.5, path: path, width: 1.5, glow: 10) }
            else { pulse(key, color: white, values: [0, 0.45, 0], duration: 0.35, path: path, width: 1.2, glow: 6) }
        case .shiftHeld: rise(key, color: white, duration: 0.55, path: path)
        case .fileDrag: breathe(key, color: tint ?? p.warning, path: path)
        case .listening: breathe(key, color: NSColor(srgbRed: 0.69, green: 0.48, blue: 1, alpha: 1), path: path)
        case .music: wave(key, color: tint ?? highlight, path: path)
        case .level(let kind, let value):
            levelFadeWork?.cancel()
            endReaction(key)
            showLevel(kind: kind, value: value, path: path, color: levelColor(kind, white: white, p: p))
            // The battery gauge stays a little longer: it answers a plug, not a key.
            scheduleLevelFade(after: kind == .battery ? 1.8 : 0.9, duration: 0.4)
        case .agentArrival: rise(key, color: claude, duration: 0.6, path: path)
        case .approvalNeeded: breathe(key, color: claude, path: path)
        case .success:
            clearSticky()
            pulse(key, color: p.success, values: [0, 0.9, 0], duration: 0.5, path: path, width: 1.5, glow: 12)
        case .danger:
            clearSticky()
            pulse(key, color: p.danger, values: [0, 1, 0.2, 1, 0], duration: 0.55, path: path, width: 1.5, glow: 10)
        case .notification: pulse(key, color: accent, values: [0, 0.8, 0], duration: 0.25, path: path, width: 1.2, glow: 6)
        }
    }

    // MARK: Building blocks

    private func endReaction(_ key: String) {
        guard let r = active.removeValue(forKey: key) else { return }
        r.remove()
    }

    private func levelColor(_ kind: NotchLightReaction.LevelKind, white: NSColor, p: Palette) -> NSColor {
        switch kind {
        case .volume: return accent
        case .brightness: return white
        case .mute: return p.danger
        case .battery: return p.success
        }
    }

    /// A stroke of the outline on a fresh container, registered under `key`.
    @discardableResult
    private func outline(_ key: String, color: NSColor, width: CGFloat, glow: CGFloat, path: CGPath,
                         relayout extra: ((CGPath, CGRect) -> Void)? = nil) -> (CALayer, CAShapeLayer) {
        let container = CALayer()
        container.frame = bounds
        container.masksToBounds = false
        let s = CAShapeLayer()
        s.frame = bounds
        s.path = path
        s.fillColor = nil
        s.strokeColor = color.cgColor
        s.lineWidth = width
        s.lineCap = .round
        s.lineJoin = .round
        s.contentsScale = contentsScale
        if glow > 0 {
            s.shadowColor = color.cgColor
            s.shadowRadius = glow
            s.shadowOpacity = 0.9
            s.shadowOffset = .zero
        }
        container.addSublayer(s)
        reactionHost.addSublayer(container)
        active[key] = Reaction(container: container) { [weak s, weak container] p, b in
            container?.frame = b
            s?.frame = b
            s?.path = p
            extra?(p, b)
        }
        return (container, s)
    }

    /// Runs `animations`, then removes the container if it is still the one registered under `key`.
    private func run(_ key: String, container: CALayer, duration: TimeInterval, timing: CAMediaTimingFunctionName = .easeInEaseOut,
                     _ animations: () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: timing))
        CATransaction.setCompletionBlock { [weak self, weak container] in
            guard let self = self, let c = container, self.active[key]?.container === c else { return }
            self.endReaction(key)
        }
        animations()
        CATransaction.commit()
    }

    private func keyframes(_ keyPath: String, values: [Any], keyTimes: [NSNumber]? = nil, duration: TimeInterval,
                           timing: CAMediaTimingFunctionName = .easeInEaseOut) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = keyTimes
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: timing)
        a.calculationMode = .linear
        a.isRemovedOnCompletion = true
        a.fillMode = .removed
        return a
    }

    private func basic(_ keyPath: String, from: Any?, to: Any?, duration: TimeInterval,
                       timing: CAMediaTimingFunctionName = .easeInEaseOut) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: timing)
        a.isRemovedOnCompletion = true
        a.fillMode = .removed
        return a
    }

    /// Whole outline, opacity through `values`, then gone.
    private func pulse(_ key: String, color: NSColor, values: [Float], keyTimes: [NSNumber]? = nil, duration: TimeInterval,
                       path: CGPath, width: CGFloat, glow: CGFloat) {
        let (container, _) = outline(key, color: color, width: width, glow: glow, path: path)
        container.opacity = 0
        run(key, container: container, duration: duration) {
            container.add(keyframes("opacity", values: values, keyTimes: keyTimes, duration: duration), forKey: "pulse")
        }
    }

    /// Reduce Motion: a plain 120 ms flash, no animation.
    private func flash(_ key: String, color: NSColor, path: CGPath) {
        let (container, _) = outline(key, color: color, width: 1.5, glow: 0, path: path)
        container.opacity = 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak container] in
            guard let self = self, let c = container, self.active[key]?.container === c else { return }
            self.endReaction(key)
        }
    }

    /// A steady outline that stays until `endReaction(key)`.
    private func steady(_ key: String, color: NSColor, opacity: Float, path: CGPath) {
        let (container, _) = outline(key, color: color, width: 1, glow: 6, path: path)
        container.opacity = opacity
    }

    private func fadeIn(_ key: String, color: NSColor, to: Float, duration: TimeInterval, path: CGPath) {
        let (container, _) = outline(key, color: color, width: 1, glow: 6, path: path)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = to
        CATransaction.commit()
        container.add(basic("opacity", from: 0, to: to, duration: duration), forKey: "in")
    }

    /// Sticky breathing (approval waiting): like Lumière, in orange, until success / danger / clearSticky.
    private func breathe(_ key: String, color: NSColor, path: CGPath) {
        let (container, _) = outline(key, color: color, width: 1.2, glow: 10, path: path)
        container.opacity = 0.35
        let b = CABasicAnimation(keyPath: "opacity")
        b.fromValue = 0.35
        b.toValue = 0.8
        b.duration = 2.5
        b.autoreverses = true
        b.repeatCount = .infinity
        b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        container.add(b, forKey: "breath")
    }

    /// Music: a soft segment gliding back and forth along the outline until told to stop.
    /// Core Animation runs it on its own; nothing here ticks.
    private func wave(_ key: String, color: NSColor, path: CGPath) {
        let (_, s) = outline(key, color: color, width: 1.5, glow: 8, path: path)
        s.opacity = 0.55
        s.strokeStart = 0
        s.strokeEnd = 0.22
        let head = CABasicAnimation(keyPath: "strokeStart")
        head.fromValue = 0; head.toValue = 0.78
        let tail = CABasicAnimation(keyPath: "strokeEnd")
        tail.fromValue = 0.22; tail.toValue = 1
        let g = CAAnimationGroup()
        g.animations = [head, tail]
        g.duration = 3.2
        g.autoreverses = true
        g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        s.add(g, forKey: "wave")
    }

    /// A bright 18 %-of-length gradient head sweeping the outline from `from` to `to` (0 = left
    /// ear, 1 = right ear on the island's path).
    private func comet(_ key: String, from: CGFloat, to: CGFloat, length: CGFloat, duration: TimeInterval, color: NSColor, path: CGPath) {
        let (container, animate) = cometContainer(key, color: color, path: path, heads: [(from, to, length)], duration: duration)
        run(key, container: container, duration: duration) { animate() }
    }

    /// Paste: two heads from either end meeting in the middle, then a tiny bloom there.
    private func pasteComets(_ key: String, color: NSColor, path: CGPath) {
        let highlight = color
        let d: TimeInterval = 0.45
        let (container, animate) = cometContainer(key, color: highlight, path: path, heads: [(0, 0.5, 0.12), (1, 0.5, 0.12)], duration: d)
        // The bloom: a short arc at the middle that swells and fades as the heads arrive.
        let bloom = CAShapeLayer()
        bloom.frame = bounds
        bloom.path = path
        bloom.fillColor = nil
        bloom.strokeColor = highlight.cgColor
        bloom.lineWidth = 2
        bloom.lineCap = .round
        bloom.strokeStart = 0.46
        bloom.strokeEnd = 0.54
        bloom.shadowColor = highlight.cgColor
        bloom.shadowOffset = .zero
        bloom.shadowOpacity = 1
        bloom.shadowRadius = 0
        bloom.opacity = 0
        bloom.contentsScale = contentsScale
        container.addSublayer(bloom)
        let total = d + 0.3
        run(key, container: container, duration: total) {
            animate()
            let op = keyframes("opacity", values: [0, 0, 1, 0] as [Float], keyTimes: [0, NSNumber(value: d / total), NSNumber(value: (d + 0.08) / total), 1], duration: total)
            bloom.add(op, forKey: "bloom")
            let sh = keyframes("shadowRadius", values: [0, 0, 16, 4] as [CGFloat], keyTimes: [0, NSNumber(value: d / total), NSNumber(value: (d + 0.12) / total), 1], duration: total)
            bloom.add(sh, forKey: "swell")
        }
    }

    /// A gradient (accent → colour → white) masked by moving stroke heads. Each head runs from
    /// `from` to `to` along the path, `length` of the path long. Returns the container and the
    /// closure that adds the animations — call it inside `run`, so its transaction times the removal.
    private func cometContainer(_ key: String, color: NSColor, path: CGPath, heads: [(CGFloat, CGFloat, CGFloat)], duration: TimeInterval) -> (CALayer, () -> Void) {
        let container = CALayer()
        container.frame = bounds
        container.masksToBounds = false
        var masks: [CAShapeLayer] = []
        var grads: [CAGradientLayer] = []
        var pending: [(CALayer, CAAnimation, String)] = []
        for (from, to, length) in heads {
            let g = CAGradientLayer()
            g.frame = bounds
            g.colors = [accent.cgColor, color.cgColor, NSColor.white.cgColor]
            g.locations = [0, 0.6, 1]
            g.startPoint = CGPoint(x: from <= to ? 0 : 1, y: 0.5)
            g.endPoint = CGPoint(x: from <= to ? 1 : 0, y: 0.5)
            let m = CAShapeLayer()
            m.frame = bounds
            m.path = path
            m.fillColor = nil
            m.strokeColor = NSColor.black.cgColor
            m.lineWidth = 2
            m.lineCap = .round
            m.lineJoin = .round
            m.contentsScale = contentsScale
            g.mask = m
            // Head: [strokeStart … strokeEnd] slides from `from` to `to`; it grows in at the start
            // and shrinks out at the end so nothing pops.
            // Both ends travel at the same speed (span + lead over the duration): the leading
            // edge sets off at once and stops at `to`; the trailing edge waits `lead` then follows.
            let forward = from <= to
            let span = max(0.01, abs(to - from))
            let lead = min(length, span)
            let tLead = NSNumber(value: Double(lead / (span + lead)))
            let tArrive = NSNumber(value: Double(span / (span + lead)))
            let leading = forward ? "strokeEnd" : "strokeStart"
            let trailing = forward ? "strokeStart" : "strokeEnd"
            pending.append((m, keyframes(leading, values: [from, to, to] as [CGFloat], keyTimes: [0, tArrive, 1], duration: duration), leading))
            pending.append((m, keyframes(trailing, values: [from, from, to] as [CGFloat], keyTimes: [0, tLead, 1], duration: duration), trailing))
            // Model values: nothing (so the mask shows nothing once the animations are removed).
            m.strokeStart = to
            m.strokeEnd = to
            pending.append((g, keyframes("opacity", values: [0, 1, 1, 0] as [Float], keyTimes: [0, 0.15, 0.85, 1], duration: duration), "fade"))
            g.opacity = 0
            container.addSublayer(g)
            masks.append(m)
            grads.append(g)
        }
        reactionHost.addSublayer(container)
        active[key] = Reaction(container: container) { [weak container] p, b in
            container?.frame = b
            for g in grads { g.frame = b }
            for m in masks { m.frame = b; m.path = p }
        }
        return (container, { for (layer, anim, k) in pending { layer.add(anim, forKey: k) } })
    }

    /// Agent arrival: a glow that rises from the bottom of the outline and clears at the top.
    private func rise(_ key: String, color: NSColor, duration: TimeInterval, path: CGPath) {
        let container = CALayer()
        container.frame = bounds
        container.masksToBounds = false
        let g = CAGradientLayer()
        g.frame = bounds
        g.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.cgColor]
        g.locations = [0, 0.55, 1]
        g.startPoint = CGPoint(x: 0.5, y: 0)
        g.endPoint = CGPoint(x: 0.5, y: 1)
        let m = CAShapeLayer()
        m.frame = bounds
        m.path = path
        m.fillColor = nil
        m.strokeColor = NSColor.black.cgColor
        m.lineWidth = 1.5
        m.lineCap = .round
        m.lineJoin = .round
        m.contentsScale = contentsScale
        g.mask = m
        g.shadowColor = color.cgColor
        g.shadowOpacity = 0.7
        g.shadowRadius = 10
        g.shadowOffset = .zero
        g.opacity = 0
        container.addSublayer(g)
        reactionHost.addSublayer(container)
        active[key] = Reaction(container: container) { [weak container, weak g, weak m] p, b in
            container?.frame = b
            g?.frame = b
            m?.frame = b
            m?.path = p
        }
        let h = bounds.height
        run(key, container: container, duration: duration) {
            // Flipped geometry (the island's view): +y is down, so it starts below and moves up.
            g.add(basic("transform.translation.y", from: h * 0.7, to: -h * 0.15, duration: duration), forKey: "rise")
            g.add(keyframes("opacity", values: [0, 1, 1, 0] as [Float], keyTimes: [0, 0.25, 0.7, 1], duration: duration), forKey: "fade")
        }
    }

    // MARK: Level arc

    private func showLevel(kind: NotchLightReaction.LevelKind, value: Double?, path: CGPath, color: NSColor) {
        let key = "level"
        let arcPath = syntheticTop ?? path
        let span = topSpan ?? (start: 0, end: 1, reversed: false)
        let v: CGFloat = kind == .mute ? 1 : CGFloat(max(0, min(1, value ?? 1)))
        let (container, s) = outline(key, color: color, width: 2.5, glow: 8, path: arcPath) { [weak self] p, b in
            // The arc follows the derived top of the new path.
            guard let self = self else { return }
            self.levelShape?.path = self.syntheticTop ?? p
            self.placeLevel(self.levelShape, value: v)
        }
        s.lineCap = .round
        levelShape = s
        // An unknown value (nil) lights the whole top: just the colour, briefly.
        placeLevel(s, value: v, span: span)
        container.opacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = 1
        CATransaction.commit()
        if !Motion.reduced {
            container.add(basic("opacity", from: 0, to: 1, duration: 0.2), forKey: "in")
        }
    }

    private func placeLevel(_ s: CAShapeLayer?, value v: CGFloat, span: (start: CGFloat, end: CGFloat, reversed: Bool)? = nil) {
        guard let s = s else { return }
        let (start, end, reversed) = span ?? topSpan ?? (start: 0, end: 1, reversed: false)
        if syntheticTop != nil {
            s.strokeStart = 0
            s.strokeEnd = v
        } else if reversed {
            // The top run goes right → left: fill from its far end back toward the left ear.
            s.strokeStart = end - (end - start) * v
            s.strokeEnd = end
        } else {
            s.strokeStart = start
            s.strokeEnd = start + (end - start) * v
        }
    }

    private func scheduleLevelFade(after delay: TimeInterval, duration: TimeInterval) {
        levelFadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let r = self.active["level"] else { return }
            self.levelFadeWork = nil
            if duration <= 0 || Motion.reduced {
                self.endReaction("level")
                return
            }
            let c = r.container
            self.run("level", container: c, duration: duration) {
                c.add(self.basic("opacity", from: 1, to: 0, duration: duration), forKey: "out")
                CATransaction.setDisableActions(true)
                c.opacity = 0
            }
        }
        levelFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Finds the run of the path lying along its top edge (both ends within 0.75 pt of minY).
    /// The island's *open* outline has none (it starts at the left ear, runs down the left side,
    /// along the bottom and up to the right ear), so a straight line from its first point to its
    /// last — left ear → right ear along the screen edge — stands in. The *closed* outline's
    /// closing segment runs right ear → left ear, which is detected as `reversed`.
    func deriveTopSpan(from path: CGPath) {
        let m = PathMeasure(path)
        syntheticTop = nil
        guard m.total > 0 else { topSpan = nil; return }
        let minY = m.points.map { $0.y }.min() ?? 0
        var best: (s: Int, e: Int)? = nil
        var runStart: Int? = nil
        for i in 1..<m.points.count {
            let onTop = m.points[i - 1].y <= minY + 0.75 && m.points[i].y <= minY + 0.75
            if onTop {
                if runStart == nil { runStart = i - 1 }
            } else if let rs = runStart {
                if best == nil || (m.cum[i - 1] - m.cum[rs]) > (m.cum[best!.e] - m.cum[best!.s]) { best = (s: rs, e: i - 1) }
                runStart = nil
            }
        }
        if let rs = runStart {
            let e = m.points.count - 1
            if best == nil || (m.cum[e] - m.cum[rs]) > (m.cum[best!.e] - m.cum[best!.s]) { best = (s: rs, e: e) }
        }
        if let b = best, m.cum[b.e] - m.cum[b.s] > 4 {
            topSpan = (start: m.cum[b.s] / m.total, end: m.cum[b.e] / m.total, reversed: m.points[b.s].x > m.points[b.e].x)
            return
        }
        // No top run: synthesise one between the ends, left → right.
        guard let first = m.points.first, let last = m.points.last, abs(first.x - last.x) > 2 else { topSpan = nil; return }
        let line = CGMutablePath()
        line.move(to: first.x <= last.x ? first : last)
        line.addLine(to: first.x <= last.x ? last : first)
        syntheticTop = line
        topSpan = (start: 0, end: 1, reversed: false)
    }
}

/// A flattened path: sampled points and cumulative lengths.
private struct PathMeasure {
    var points: [CGPoint] = []
    var cum: [CGFloat] = []
    var total: CGFloat = 0

    init(_ path: CGPath) {
        var pts: [CGPoint] = []
        var cur = CGPoint.zero
        var start = CGPoint.zero
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                cur = e.points[0]; start = cur
                if pts.isEmpty { pts.append(cur) }
            case .addLineToPoint:
                cur = e.points[0]; pts.append(cur)
            case .addQuadCurveToPoint:
                let c = e.points[0], to = e.points[1], from = cur
                for i in 1...8 {
                    let t = CGFloat(i) / 8
                    pts.append(lerp(lerp(from, c, t), lerp(c, to, t), t))
                }
                cur = to
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], to = e.points[2], from = cur
                for i in 1...12 {
                    let t = CGFloat(i) / 12
                    let a = lerp(from, c1, t), b = lerp(c1, c2, t), c = lerp(c2, to, t)
                    pts.append(lerp(lerp(a, b, t), lerp(b, c, t), t))
                }
                cur = to
            case .closeSubpath:
                cur = start; pts.append(cur)
            @unknown default:
                break
            }
        }
        points = pts
        var acc: CGFloat = 0
        cum = [0]
        if pts.count > 1 {
            for i in 1..<pts.count {
                acc += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
                cum.append(acc)
            }
        }
        total = acc
    }
}

// MARK: - Picker

/// Settings row: five preview tiles (one per style, drawn by a tiny `NotchLightLayer`) and a
/// Glow slider. Changing either is reported through `onChange` / `onIntensityChange`; the
/// picker does not write defaults itself.
final class NotchLightPicker: NSView {
    var selection: NotchLightStyle {
        didSet {
            guard selection != oldValue else { return }
            tiles.forEach { $0.selected = $0.style == selection }
        }
    }
    var onChange: ((NotchLightStyle) -> Void)?
    var onIntensityChange: ((CGFloat) -> Void)?
    /// "Reacts to shortcuts and volume" switched; the picker has already written `zera.notchLight.reactions`.
    var onReactionsChange: ((Bool) -> Void)?
    var intensity: CGFloat {
        get { CGFloat(slider.doubleValue) }
        set { slider.doubleValue = Double(NotchLightStyle.clampIntensity(newValue)); tiles.forEach { $0.light.intensity = newValue } }
    }

    private var tiles: [NotchLightTile] = []
    private let glowLabel = NSTextField(labelWithString: "Glow")
    private let slider = NSSlider()
    private let blurb = NSTextField(labelWithString: "")
    private let reactLabel = NSTextField(labelWithString: "Reacts to shortcuts and volume")
    private let reactToggle = Toggle()

    static let tileHeight: CGFloat = 78
    static let labelHeight: CGFloat = 18
    static let gap: CGFloat = Space.s

    /// Height the picker wants at any width.
    var preferredHeight: CGFloat {
        Self.tileHeight + Space.xs + Self.labelHeight + Space.s + 16 + Space.m + Metrics.control + Space.s + Metrics.control
    }

    override var isFlipped: Bool { true }

    init(selection: NotchLightStyle = NotchLightStyle.current, intensity: CGFloat = NotchLightStyle.intensity) {
        self.selection = selection
        super.init(frame: .zero)
        for s in NotchLightStyle.allCases {
            let t = NotchLightTile(style: s)
            t.selected = s == selection
            t.light.intensity = intensity
            t.onTap = { [weak self] in self?.pick(s) }
            addSubview(t)
            tiles.append(t)
        }
        blurb.font = Typo.caption
        blurb.textColor = Pal.textTertiary
        blurb.alignment = .center
        blurb.stringValue = selection.blurb
        addSubview(blurb)
        glowLabel.font = Typo.settingLabel
        glowLabel.textColor = Pal.text
        addSubview(glowLabel)
        slider.minValue = Double(NotchLightStyle.intensityRange.lowerBound)
        slider.maxValue = Double(NotchLightStyle.intensityRange.upperBound)
        slider.doubleValue = Double(NotchLightStyle.clampIntensity(intensity))
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid(_:))
        slider.setAccessibilityLabel("Glow")
        addSubview(slider)
        reactLabel.font = Typo.settingLabel
        reactLabel.textColor = Pal.text
        reactLabel.lineBreakMode = .byTruncatingTail
        addSubview(reactLabel)
        reactToggle.isOn = NotchLightStyle.reactionsEnabled
        reactToggle.setAccessibilityLabel("Reacts to shortcuts and volume")
        reactToggle.onChange = { [weak self] on in
            NotchLightStyle.reactionsEnabled = on
            self?.onReactionsChange?(on)
        }
        addSubview(reactToggle)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Notch light")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func pick(_ s: NotchLightStyle) {
        guard s != selection else { return }
        selection = s
        blurb.stringValue = s.blurb
        SoundService.shared.play(.tap)
        onChange?(s)
    }

    @objc private func slid(_ sender: NSSlider) {
        let v = NotchLightStyle.clampIntensity(CGFloat(sender.doubleValue))
        tiles.forEach { $0.light.intensity = v }
        onIntensityChange?(v)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let n = CGFloat(tiles.count)
        let tw = floor((w - Self.gap * (n - 1)) / n)
        let th = Self.tileHeight + Space.xs + Self.labelHeight
        for (i, t) in tiles.enumerated() {
            t.frame = NSRect(x: CGFloat(i) * (tw + Self.gap), y: 0, width: tw, height: th)
        }
        var y = th + Space.s
        blurb.frame = NSRect(x: 0, y: y, width: w, height: 16)
        y += 16 + Space.m
        glowLabel.frame = NSRect(x: 4, y: y + (Metrics.control - 18) / 2, width: 60, height: 18)
        let sw = min(220, w - 64)
        slider.frame = NSRect(x: w - sw, y: y + (Metrics.control - 20) / 2, width: sw, height: 20)
        y += Metrics.control + Space.s
        reactLabel.frame = NSRect(x: 4, y: y + (Metrics.control - 18) / 2, width: max(0, w - 44 - Space.m), height: 18)
        reactToggle.frame = NSRect(x: w - 40, y: y + (Metrics.control - 22) / 2, width: 40, height: 22)
    }

    /// Previews only animate while the picker is on screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { resumePreviews() } else { pausePreviews() }
    }

    /// The owner can also stop the previews while the picker is covered (e.g. another page).
    func pausePreviews() { tiles.forEach { $0.light.pause() } }
    func resumePreviews() { guard window != nil else { return }; tiles.forEach { $0.light.resume() } }
}

/// One preview: a small notch pill hanging from the tile's top, lit in its style.
private final class NotchLightTile: NSView {
    let style: NotchLightStyle
    let light = NotchLightLayer()
    var onTap: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { restyle() } } }
    private var hovered = false { didSet { if hovered != oldValue { restyle() } } }
    private let box = FlippedView()
    private let title = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(style: NotchLightStyle) {
        self.style = style
        super.init(frame: .zero)
        box.wantsLayer = true
        box.layer?.cornerRadius = Radius.m
        box.layer?.cornerCurve = .continuous
        box.layer?.masksToBounds = true
        box.layer?.backgroundColor = NSColor.black.cgColor
        light.followsSettings = false
        light.lightStyle = style
        light.accent = Neon.accent
        light.highlight = Neon.highlight
        box.layer?.addSublayer(light)
        addSubview(box)
        title.stringValue = style.title
        title.font = Typo.caption
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(style.title): \(style.blurb)")
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let p = Pal
        box.layer?.borderWidth = selected ? 1.5 : 1
        box.layer?.borderColor = (selected ? p.accent : (hovered ? p.accentBorder : p.divider)).cgColor
        title.textColor = selected ? p.accent : p.textSecondary
        setAccessibilityValue(selected ? "selected" : "")
    }

    override func layout() {
        super.layout()
        let bh = NotchLightPicker.tileHeight
        box.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bh)
        title.frame = NSRect(x: 0, y: bh + Space.xs, width: bounds.width, height: NotchLightPicker.labelHeight)
        // The pill: flat along the top edge, round bottom corners, ears where it meets the edge.
        let pw = min(bounds.width - 24, 72), ph: CGFloat = 30, e: CGFloat = 5, c: CGFloat = 12
        let x0 = ((bounds.width - pw) / 2).rounded(), x1 = x0 + pw
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0 - e, y: 0))
        p.addQuadCurve(to: CGPoint(x: x0, y: e), control: CGPoint(x: x0, y: 0))
        p.addLine(to: CGPoint(x: x0, y: ph - c))
        p.addQuadCurve(to: CGPoint(x: x0 + c, y: ph), control: CGPoint(x: x0, y: ph))
        p.addLine(to: CGPoint(x: x1 - c, y: ph))
        p.addQuadCurve(to: CGPoint(x: x1, y: ph - c), control: CGPoint(x: x1, y: ph))
        p.addLine(to: CGPoint(x: x1, y: e))
        p.addQuadCurve(to: CGPoint(x: x1 + e, y: 0), control: CGPoint(x: x1, y: 0))
        // The box is flipped like the view; the layer's y grows down with it.
        light.apply(path: p, bounds: box.bounds, mode: .open, animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetHoverTracking()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
