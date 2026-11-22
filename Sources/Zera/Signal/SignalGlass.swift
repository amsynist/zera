import AppKit

// MARK: - Glass
//
// The island, the agent wings and the other floating surfaces are tinted glass over a blurred
// desktop, the way Ghostty draws a terminal with `background-opacity` and `background-blur`.
// Settings › Appearance › Glass has the same two controls:
//
//   Background opacity  0.3 … 1   how much of the theme's dark tint covers the blur (1 = solid)
//   Background blur     0 … 100   how strongly what is behind is blurred (0 = off, sharp desktop)
//
// macOS "Reduce transparency" always wins and makes every surface solid.

enum GlassSettings {
    nonisolated static let changed = Notification.Name("ZeraGlassChanged")
    private static let opacityKey = "zera.glass.opacity"
    private static let blurKey = "zera.glass.blur"

    static let opacityRange: ClosedRange<CGFloat> = 0.3...1
    static let defaultOpacity: CGFloat = 0.78
    static let defaultBlur: CGFloat = 70

    /// Tint over the blur, like Ghostty's `background-opacity`.
    static var opacity: CGFloat {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: opacityKey) != nil else { return defaultOpacity }
            return clampOpacity(CGFloat(d.double(forKey: opacityKey)))
        }
        set { set(Double(clampOpacity(newValue)), opacityKey) }
    }

    /// Blur intensity 0 … 100, like Ghostty's `background-blur` (its `true` is 20 of a wider range).
    static var blur: CGFloat {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: blurKey) != nil else { return defaultBlur }
            return min(100, max(0, CGFloat(d.double(forKey: blurKey))))
        }
        set { set(Double(min(100, max(0, newValue))), blurKey) }
    }

    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    /// What surfaces actually use: solid when the system asks for it.
    static var effectiveOpacity: CGFloat { reduceTransparency ? 1 : opacity }
    static var effectiveBlur: CGFloat { reduceTransparency ? 0 : blur / 100 }
    static var isTranslucent: Bool { effectiveOpacity < 0.995 }

    static func clampOpacity(_ v: CGFloat) -> CGFloat {
        guard v.isFinite else { return defaultOpacity }
        return min(opacityRange.upperBound, max(opacityRange.lowerBound, v))
    }

    private static func set(_ value: Double, _ key: String) {
        let d = UserDefaults.standard
        let old = d.object(forKey: key) as? Double
        d.set(value, forKey: key)
        if old.map({ abs($0 - value) > 0.0001 }) ?? true { NotificationCenter.default.post(name: changed, object: nil) }
    }
}

/// One glass surface: the desktop blurred behind it, the theme's tint over the blur, and an
/// optional black band along the top that fades into the glass (the notch). It takes the shape of
/// `path` and never takes a click. Shared by the island, the wings and the floating panels.
///
/// Cost: the blur is the window server's own (`NSVisualEffectView`, behind the window); nothing
/// here redraws per frame. The shape mask is one `CAShapeLayer`, which the owner can animate.
final class SignalGlassView: NSView {
    /// The shape, in this view's coordinates. Animate it by adding an animation to `shape`.
    let shape = CAShapeLayer()
    private let effect = NSVisualEffectView()
    // Tint and band live in their own views above the blur: AppKit keeps subview layers above a
    // view's loose sublayers, so a loose tint layer would end up under the blur.
    private let tintView: SignalLayerView
    private let bandView: SignalLayerView
    private var tint: CALayer { tintView.layer! }
    private let band = CAGradientLayer()
    private var observers: [NSObjectProtocol] = []

    /// Height of the solid black band at the top (the hardware notch), and how far it fades.
    var bandHeight: CGFloat = 0 { didSet { if bandHeight != oldValue { needsLayout = true } } }
    var bandFade: CGFloat = 44 { didSet { if bandFade != oldValue { needsLayout = true } } }
    /// The tint; the theme's glass by default.
    var tintColor: NSColor? { didSet { apply() } }
    /// A floor for the tint, for surfaces that must stay readable over anything (wings).
    var minimumOpacity: CGFloat = 0 { didSet { apply() } }

    /// Match the owner's coordinates so `path` needs no conversion (the Daily Shelf is unflipped).
    private let flippedLayout: Bool
    override var isFlipped: Bool { flippedLayout }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override convenience init(frame: NSRect) { self.init(frame: frame, flipped: true) }

    init(frame: NSRect, flipped: Bool) {
        flippedLayout = flipped
        tintView = SignalLayerView(frame: .zero, flipped: flipped)
        bandView = SignalLayerView(frame: .zero, flipped: flipped)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shape.fillColor = NSColor.black.cgColor
        layer?.mask = shape
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        addSubview(tintView)
        band.startPoint = CGPoint(x: 0.5, y: 0)
        band.endPoint = CGPoint(x: 0.5, y: 1)
        bandView.layer?.addSublayer(band)
        addSubview(bandView)
        let nc = NotificationCenter.default
        for n in [GlassSettings.changed, Palette.changed] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.apply() })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.apply() })
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    func setPath(_ path: CGPath) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.path = path
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effect.frame = bounds
        tintView.frame = bounds
        bandView.frame = bounds
        band.frame = bounds
        let h = max(1, bounds.height)
        band.locations = [0, NSNumber(value: Double(bandHeight / h)), NSNumber(value: Double(min(h, bandHeight + bandFade) / h)), 1]
        band.isHidden = bandHeight <= 0
        CATransaction.commit()
    }

    /// Repaints from the settings and the theme. Cheap: colours and one alpha.
    func apply() {
        let o = max(minimumOpacity, GlassSettings.effectiveOpacity)
        let base = tintColor ?? ThemeStore.shared.current.glassBottom
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.backgroundColor = base.withAlphaComponent(o).cgColor
        band.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        CATransaction.commit()
        let blur = o >= 0.995 ? 0 : GlassSettings.effectiveBlur
        effect.isHidden = blur < 0.01
        effect.alphaValue = blur
    }
}

/// A plain layer-backed view that holds Core Animation layers at a fixed place among its
/// siblings and never takes a click. Use it whenever loose layers must sit above a subview
/// (AppKit always draws subview layers above a view's own loose sublayers).
final class SignalLayerView: NSView {
    private let flippedLayout: Bool
    override var isFlipped: Bool { flippedLayout }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(frame: NSRect, flipped: Bool) {
        flippedLayout = flipped
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }
}
