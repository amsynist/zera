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
        guard r != target || (!isMoving && rect != r) else { return }
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

    /// v2 morph: opening a row's page by clicking the row, the page grows out of that row — the
    /// row becomes the page. Opened from the keyboard (or going back), it slides like `page`.
    static func open(_ view: NSView, forward: Bool = true) {
        guard forward, !reduced, let row = clickedRow(in: view.window), let parent = view.superview,
              view.frame.width > 0, view.frame.height > 0 else { page(view, forward: forward); return }
        let r = parent.convert(row.bounds, from: row)
        grow(view, from: r)
    }

    /// Grows `view` from `rect` (in its superview's coordinates) to its own frame.
    static func grow(_ view: NSView, from rect: NSRect) {
        view.wantsLayer = true
        guard let layer = view.layer, !reduced, view.frame.width > 0, view.frame.height > 0 else { return }
        let f = view.frame
        let sx = max(0.2, rect.width / f.width), sy = max(0.06, rect.height / f.height)
        // AppKit's layers hang from their frame's origin, so scale there and move onto the row.
        var from = CATransform3DMakeTranslation(rect.minX - f.minX, rect.minY - f.minY, 0)
        from = CATransform3DScale(from, sx, sy, 1)
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: from)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.mass = 1; grow.stiffness = 260; grow.damping = 26
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: "zera.morph")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.25; fade.toValue = 1
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "zera.morph.fade")
    }

    /// The list row the current click landed in: the nearest view up from the click that's
    /// shaped like a row (wide, 30–130 pt tall).
    private static func clickedRow(in window: NSWindow?) -> NSView? {
        guard let e = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(e.type),
              let w = window, e.window === w, let content = w.contentView else { return nil }
        var v = content.hitTest(content.convert(e.locationInWindow, from: nil))
        while let cur = v {
            let b = cur.bounds
            if b.width >= 180, b.height >= 30, b.height <= 130, !(cur is NSScrollView), !(cur is NSClipView) { return cur }
            v = cur.superview
        }
        return nil
    }

    /// A list whose contents were swapped (a filter changed): a quick settle from just above.
    static func refresh(_ view: NSView) { arrive(view, direction: 0) }

    /// The one tab switch (Shelf ↔ Fresh everywhere): the pill glides in the control, and what
    /// the tab shows comes in from the side you moved toward. Hidden views are skipped.
    static func tabSwitch(_ views: [NSView], from old: Int, to new: Int) {
        guard old != new else { return }
        for v in views where !v.isHidden && v.window != nil { page(v, forward: new > old) }
    }

    /// v2: a lens's content grows in row by row — each block below the header rises 10 pt and
    /// fades in, 40 ms after the one above it (rows inside a list count one by one).
    static func stagger(_ container: NSView, below top: CGFloat, delay: CFTimeInterval = 0.06) {
        guard !reduced else { return }
        var items: [(CGFloat, NSView)] = []
        for v in container.subviews where !v.isHidden && v.frame.minY >= top - 4 && v.frame.height > 0 {
            if let sv = v as? NSScrollView, let doc = sv.documentView {
                let visible = sv.contentView.bounds
                for r in doc.subviews where !r.isHidden && r.frame.intersects(visible) {
                    items.append((v.frame.minY + r.frame.minY - visible.minY, r))
                }
            } else {
                items.append((v.frame.minY, v))
            }
        }
        items.sort { $0.0 < $1.0 }
        let now = CACurrentMediaTime()
        for (i, (_, v)) in items.prefix(14).enumerated() {
            v.wantsLayer = true
            guard let layer = v.layer else { continue }
            let begin = now + delay + min(0.32, Double(i) * 0.04)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1
            fade.duration = 0.26
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            fade.beginTime = begin; fade.fillMode = .backwards
            layer.add(fade, forKey: "zera.stagger.fade")
            let rise = CASpringAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 10; rise.toValue = 0
            rise.mass = 1; rise.stiffness = 260; rise.damping = 20
            rise.duration = rise.settlingDuration
            rise.beginTime = begin; rise.fillMode = .backwards
            layer.add(rise, forKey: "zera.stagger.rise")
        }
    }
}

// MARK: - Hover

extension NSView {
    /// Whether the pointer is over the visible part of this view right now. Rows inside a
    /// scroll view should read this while drawing rather than trust mouseEntered / mouseExited:
    /// those go missing while the list scrolls under a still pointer, leaving rows lit.
    var isPointerInside: Bool {
        guard let w = window, w.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        return visibleRect.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }
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


/// The selected look for a row of separate chips (projects, filters), drawn over them and
/// gliding from one chip to the next like a segmented control's pill. Never takes a click.
final class GlideWash: NSView {
    private lazy var indicator = SlidingIndicator(view: self)
    /// Where the wash belongs now (the selected chip's frame here), or nil for none.
    var target: (() -> NSRect?)?
    /// Corner radius; nil draws a pill.
    var radius: CGFloat?
    /// The accent edge round the wash (the Settings sidebar has none).
    var edged = true
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func glide(animated: Bool = true) {
        guard let r = target?() else { needsDisplay = true; return }
        indicator.move(to: r, animated: animated)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let r = target?() else { return }
        indicator.settle(at: r)
        let rect = indicator.rect.insetBy(dx: 0.5, dy: 0.5)
        let corner = radius ?? rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        if edged { Pal.drawSelected(path) } else { Pal.accent.withAlphaComponent(0.16).setFill(); path.fill() }
    }
}
