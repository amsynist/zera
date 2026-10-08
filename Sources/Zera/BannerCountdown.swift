import AppKit

/// Reading time for a notification, independent of ordinary cards' pointer-leave behavior.
struct BannerCountdown {
    static let duration: TimeInterval = 15
    private var lastUpdate: TimeInterval
    private(set) var remaining: TimeInterval = Self.duration

    init(at now: TimeInterval) { lastUpdate = now }

    mutating func advance(to now: TimeInterval, paused: Bool) {
        let elapsed = max(0, now - lastUpdate)
        if !paused { remaining = max(0, remaining - elapsed) }
        lastUpdate = now
    }

    var progress: CGFloat { CGFloat(remaining / Self.duration) }
    var expired: Bool { remaining <= 0 }
}

protocol TimedNotificationBanner: AnyObject {
    var countdownLine: BannerCountdownLine { get }
}

/// v2: the drain along the banner's bottom edge (the island's rounded corners clip its ends):
/// a glowing accent bar that slides down smoothly between ticks, with a light flowing through it.
final class BannerCountdownLine: NSView {
    var progress: CGFloat = 1 { didSet { apply(animated: progress < oldValue) } }
    private let track = CALayer()
    private let glow = CALayer()
    private let bar = CAGradientLayer()
    private let shimmer = CAGradientLayer()
    private var lastSet: CFTimeInterval = 0
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        glow.shadowOffset = .zero
        glow.shadowRadius = 5
        glow.shadowOpacity = 0.9
        layer?.addSublayer(glow)
        bar.startPoint = CGPoint(x: 0, y: 0.5)
        bar.endPoint = CGPoint(x: 1, y: 0.5)
        bar.masksToBounds = true
        glow.addSublayer(bar)
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.55).cgColor,
                          NSColor.white.withAlphaComponent(0).cgColor]
        bar.addSublayer(shimmer)
        restyle()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restartFlow() }

    private func restyle() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.backgroundColor = Neon.text.withAlphaComponent(0.1).cgColor
        bar.colors = [Neon.violet.cgColor, Neon.accent.cgColor]
        glow.shadowColor = Neon.accent.cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds
        glow.frame = bounds
        shimmer.frame = CGRect(x: 0, y: 0, width: 120, height: bounds.height)
        CATransaction.commit()
        apply(animated: false)
        restartFlow()
    }

    private var fillFrame: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width * max(0, min(1, progress)), height: bounds.height)
    }

    /// Slides to the new length over about the time since the last tick, so it moves evenly.
    private func apply(animated: Bool) {
        let now = CACurrentMediaTime()
        let dt = now - lastSet
        lastSet = now
        CATransaction.begin()
        if animated, !Motion.reduced, dt < 1 {
            CATransaction.setAnimationDuration(max(0.05, dt))
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        bar.frame = fillFrame
        glow.shadowPath = CGPath(rect: fillFrame, transform: nil)
        CATransaction.commit()
    }

    /// The light that flows along the bar, again and again (none with Reduce Motion).
    private func restartFlow() {
        shimmer.removeAllAnimations()
        guard !Motion.reduced, window != nil, bounds.width > 0 else { shimmer.opacity = 0; return }
        shimmer.opacity = 1
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -60; a.toValue = bounds.width + 60
        a.duration = 2.4
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmer.add(a, forKey: "flow")
    }
}
