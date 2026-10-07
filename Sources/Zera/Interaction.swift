import AppKit
import QuartzCore

// MARK: - Shared motion
//
// One feel for every selector and screen change in the app: a quick, lightly springy slide.
// Selection indicators (island tabs, segmented controls) glide to the new choice; content comes
// in from the side you moved toward. Reduce Motion turns every slide into a short fade.

enum Spring {
    /// How long an indicator takes to settle.
    static let duration: CFTimeInterval = 0.32

    /// A damped spring over t ∈ 0…1: overshoots by about 3 % and settles by t = 1.
    static func curve(_ t: Double) -> Double {
        guard t < 1 else { return 1 }
        guard t > 0 else { return 0 }
        let w = 12.0, z = 0.75
        let wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + (z * w / wd) * sin(wd * t))
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    static func lerp(_ a: NSRect, _ b: NSRect, _ t: Double) -> NSRect {
        NSRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }
}

/// A selection highlight that glides from one rect to the next. The owning view draws it at
/// `rect` in `draw(_:)`; this redraws the view each frame while it moves.
final class SlidingIndicator {
    private(set) var rect: NSRect = .zero
    private var from: NSRect = .zero
    private(set) var target: NSRect = .zero
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    weak var view: NSView?

    init(view: NSView) { self.view = view }
    deinit { timer?.invalidate() }

    var isMoving: Bool { timer != nil }

    /// Glides to `r`, or jumps there when `animated` is false, nothing was shown yet, or
    /// Reduce Motion is on.
    func move(to r: NSRect, animated: Bool) {
        guard r != target || rect != r else { return }
        guard animated, !Motion.reduced, rect != .zero, view?.window != nil else { snap(to: r); return }
        from = rect
        target = r
        start = CACurrentMediaTime()
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// For `draw(_:)`: where the indicator belongs when it isn't gliding (the layout may have
    /// changed under it). Doesn't ask for another redraw.
    func settle(at r: NSRect) {
        guard !isMoving else { return }
        rect = r; from = r; target = r
    }

    /// Keeps it on `r` without animating (layout changed under it). Ignored mid-glide toward `r`.
    func snap(to r: NSRect) {
        if isMoving && target == r { return }
        timer?.invalidate(); timer = nil
        rect = r; from = r; target = r
        view?.needsDisplay = true
    }

    private func tick() {
        let t = (CACurrentMediaTime() - start) / Spring.duration
        rect = Spring.lerp(from, target, Spring.curve(t))
        view?.needsDisplay = true
        if t >= 1 { rect = target; timer?.invalidate(); timer = nil }
    }
}

extension Motion {
    /// A view arriving: it fades in while sliding `distance` points in from `direction`
    /// (+1 from the right, -1 from the left, 0 from just above). Reduce Motion: a short fade.
    static func arrive(_ view: NSView, direction: CGFloat, distance: CGFloat = 16, delay: CFTimeInterval = 0) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration = reduced ? 0.12 : 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        layer.add(fade, forKey: "zera.arrive.fade")
        guard !reduced else { return }
        let move = CASpringAnimation(keyPath: direction == 0 ? "transform.translation.y" : "transform.translation.x")
        move.fromValue = direction == 0 ? -6 : direction * distance
        move.toValue = 0
        move.mass = 1; move.stiffness = 320; move.damping = 28
        move.duration = move.settlingDuration
        move.beginTime = fade.beginTime
        move.fillMode = .backwards
        layer.add(move, forKey: "zera.arrive.move")
    }

    /// A page inside a screen (a session, a PR, a file, a settings pane) coming in.
    /// Forward slides in from the right; back from the left.
    static func page(_ view: NSView, forward: Bool) { arrive(view, direction: forward ? 1 : -1, distance: 18) }

    /// A list whose contents were swapped (a filter changed): a quick settle from just above.
    static func refresh(_ view: NSView) { arrive(view, direction: 0) }
}

// MARK: - Pressed look

extension NSRect {
    /// The rect a control draws in while pressed: about 3 % smaller, centred, so it reads as
    /// pushed in without moving anything around it.
    func pressed(_ isPressed: Bool) -> NSRect {
        guard isPressed else { return self }
        let dx = max(1, width * 0.015), dy = max(0.6, height * 0.03)
        return insetBy(dx: dx, dy: dy)
    }
}
