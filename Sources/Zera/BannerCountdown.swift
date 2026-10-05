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

/// A quiet two-point line that drains from right to left as reading time runs out.
final class BannerCountdownLine: NSView {
    var progress: CGFloat = 1 { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1)
        Neon.edge.withAlphaComponent(0.14).setFill()
        track.fill()
        let width = bounds.width * max(0, min(1, progress))
        guard width > 0 else { return }
        Neon.accent.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height),
                     xRadius: 1, yRadius: 1).fill()
    }
}
