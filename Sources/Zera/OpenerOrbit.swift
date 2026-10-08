import AppKit

// The App Opener's v2 look: the screen dims, Zera rappels down with the search, and what you
// can open sits on an arc under it — the chosen one large in the middle, its neighbours shrinking
// away to either side. ⌘K blooms the chosen item's actions around it in a ring.
//
//                         (Zera)
//               ( 🔍  Open an app…            )
//              [ YOUR USUAL 7 · COMMANDS 4 · ACTIONS 8 ]
//        ·  [C]   [X]   [ S ]   [>_]   [F]  ·
//                       Safari
//               ● Running · v27 · /Applications
//          [ Open Safari ⏎ ] [ Actions ⌘K ] [ Pin ]

/// Where an item sits on the arc, `k` steps from the chosen one.
enum OrbitArc {
    static let step: CGFloat = 104
    static func offset(_ k: Int) -> CGPoint {
        let d = CGFloat(k)
        // Spread a little less the further out, and drop along the curve.
        let x = d * step * (1 - min(0.18, abs(d) * 0.035))
        return CGPoint(x: x, y: d * d * 6)
    }
    static func scale(_ k: Int) -> CGFloat { k == 0 ? 1.4 : max(0.7, 1.1 - CGFloat(abs(k) - 1) * 0.1) }
    static func alpha(_ k: Int) -> CGFloat { k == 0 ? 1 : max(0, 0.95 - CGFloat(abs(k) - 1) * 0.2) }
    /// How many either side of the chosen one are drawn at all.
    static let reach = 5

    /// Draw through the actual tile frames, including the wider process cards.
    static func path(under frames: [CGRect]) -> CGPath {
        let points = frames.sorted { $0.midX < $1.midX }.map { CGPoint(x: $0.midX, y: $0.maxY + 1) }
        let path = CGMutablePath()
        guard points.count > 1 else { return path }
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)], p1 = points[i]
            let p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

/// One item on the arc: an app's icon (or a command's, an action's), or — inside Kill Process /
/// Kill Port — a small card with its name, details and load.
final class OrbitTile: NSView {
    enum Style { case icon, card }
    var style: Style = .icon { didSet { needsDisplay = true } }
    var icon: NSImage? { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var detail = "" { didSet { needsDisplay = true } }
    var trailing = "" { didSet { needsDisplay = true } }
    var quickKey: String? { didSet { needsDisplay = true } }
    var running = false { didSet { needsDisplay = true } }
    var pinned = false { didSet { needsDisplay = true } }
    /// Quit All: an app you keep open, greyed.
    var kept = false { didSet { needsDisplay = true } }
    var chosen = false { didSet { if chosen != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    private var hovered = false {
        didSet {
            needsDisplay = true
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.reduced ? 0 : 0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer?.transform = hovered ? CATransform3DMakeScale(1.06, 1.06, 1) : CATransform3DIdentity
            CATransaction.commit()
        }
    }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let keyFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)

    /// The tile's own size at scale 1.
    static func base(_ style: Style) -> NSSize { style == .icon ? NSSize(width: 64, height: 64) : NSSize(width: 168, height: 64) }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let s = b.height / 64
        let r = style == .icon ? 19 * s : 16 * s
        let shape = NSBezierPath(roundedRect: b.insetBy(dx: 1, dy: 1), xRadius: r, yRadius: r)
        if chosen {
            // The chosen one: an accent ring and a soft glow.
            Neon.glowing(Neon.accent.withAlphaComponent(0.6), blur: 22 * s) {
                Neon.fillBottom.setFill(); shape.fill()
            }
        }
        switch style {
        case .icon:
            if let img = icon {
                img.draw(in: b.insetBy(dx: 2 * s, dy: 2 * s), from: .zero, operation: .sourceOver,
                         fraction: kept ? 0.4 : 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            }
        case .card:
            NSGradient(starting: Neon.fillTop.withAlphaComponent(1), ending: Neon.fillBottom.withAlphaComponent(1))?.draw(in: shape, angle: -90)
            Neon.chipEdge.setStroke(); shape.lineWidth = 1; shape.stroke()
            let pad = 12 * s
            let k = max(0.5, s)
            let tf = NSFont.systemFont(ofSize: 13 * k, weight: .bold), df = NSFont.monospacedDigitSystemFont(ofSize: 10.5 * k, weight: .medium)
            let lw = b.width - pad * 2
            NSAttributedString(string: title, attributes: [.font: tf, .foregroundColor: Neon.text])
                .draw(with: NSRect(x: pad, y: b.height / 2 - 17 * s, width: lw - 44 * s, height: 18 * s), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSAttributedString(string: detail, attributes: [.font: df, .foregroundColor: Neon.textFaint])
                .draw(with: NSRect(x: pad, y: b.height / 2 + 2 * s, width: lw, height: 16 * s), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if !trailing.isEmpty {
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5 * k, weight: .bold), .foregroundColor: Neon.warning]
                let w = (trailing as NSString).size(withAttributes: a).width
                (trailing as NSString).draw(at: NSPoint(x: b.width - pad - w, y: 9 * s), withAttributes: a)
            }
        }
        if chosen {
            Neon.accent.withAlphaComponent(0.85).setStroke()
            shape.lineWidth = 2.5; shape.stroke()
        } else if hovered {
            Neon.accent.withAlphaComponent(0.45).setStroke()
            shape.lineWidth = 1.5; shape.stroke()
        }
        if running {
            let d = NSRect(x: b.midX - 3.5, y: b.maxY - 4, width: 7, height: 7)
            Neon.glowing(Neon.green, blur: 6) { Neon.green.setFill(); NSBezierPath(ovalIn: d).fill() }
        }
        if pinned {
            let d = NSRect(x: -5, y: -5, width: 17, height: 17)
            Neon.warning.setFill(); NSBezierPath(ovalIn: d).fill()
            Neon.symbol("pin.fill", in: d, size: 8, weight: .bold, color: .black)
        }
        if let q = quickKey {
            // The system face (as every other key hint): SF Mono has no ⌘ of its own, and laying
            // out its fallback in a layer's draw crashed CoreText on macOS 27.
            let a: [NSAttributedString.Key: Any] = [.font: Self.keyFont, .foregroundColor: Neon.textDim]
            let w = max(20, (q as NSString).size(withAttributes: a).width + 10)
            let box = NSRect(x: b.maxX - w + 6, y: -7, width: w, height: 19)
            let p = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            NSColor.black.withAlphaComponent(0.75).setFill(); p.fill()
            Neon.chipEdge.setStroke(); p.lineWidth = 1; p.stroke()
            let sz = (q as NSString).size(withAttributes: a)
            (q as NSString).draw(at: NSPoint(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2), withAttributes: a)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A small shortcut and app name below each icon. On short displays they share one line.
final class OrbitCaption: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var key = "" { didSet { needsDisplay = true } }
    var chosen = false { didSet { needsDisplay = true } }
    var compact = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: chosen ? 13 : 11.5, weight: chosen ? .semibold : .medium)
        if compact {
            let line = key.isEmpty ? title : "\(key)  \(title)"
            NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: chosen ? Neon.text : Neon.text.withAlphaComponent(0.78),
                                                          .paragraphStyle: paragraph])
                .draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        }
        if !key.isEmpty {
            let badge = NSRect(x: bounds.midX - 18, y: 0, width: 36, height: 17)
            let path = NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5)
            Neon.chip.setFill(); path.fill()
            Neon.chipEdge.setStroke(); path.lineWidth = 1; path.stroke()
            NSAttributedString(string: key, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                         .foregroundColor: Neon.textDim, .paragraphStyle: paragraph])
                .draw(with: badge.offsetBy(dx: 0, dy: 1), options: [.usesLineFragmentOrigin])
        }
        NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: chosen ? Neon.text : Neon.text.withAlphaComponent(0.78),
                                                       .paragraphStyle: paragraph])
            .draw(with: NSRect(x: 0, y: 22, width: bounds.width, height: 19), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// One of the chosen item's actions in the ⌘K ring: a round button, its name under it when chosen.
final class ActionBubble: NSView {
    var symbol = "circle" { didSet { needsDisplay = true } }
    var tint: NSColor? { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    /// Asking to confirm (Uninstall): red, with the question as its name.
    var asking = false { didSet { needsDisplay = true } }
    var chosen = false { didSet { if chosen != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    static let size: CGFloat = 44

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The disc, centred at the top of the frame; the name hangs under it.
    private var disc: NSRect { NSRect(x: (bounds.width - Self.size) / 2, y: 0, width: Self.size, height: Self.size) }

    override func draw(_ dirtyRect: NSRect) {
        let d = disc.insetBy(dx: 1, dy: 1)
        let circle = NSBezierPath(ovalIn: d)
        let lit = chosen || hovered
        let tone = asking ? Neon.red : (tint ?? Neon.accent)
        if lit {
            Neon.glowing(tone.withAlphaComponent(0.55), blur: 14) { Neon.fillBottom.setFill(); circle.fill() }
        }
        NSGradient(starting: Neon.fillTop.withAlphaComponent(1), ending: Neon.fillBottom.withAlphaComponent(1))?.draw(in: circle, angle: -90)
        (lit ? tone : Neon.chipEdge).setStroke(); circle.lineWidth = lit ? 1.6 : 1; circle.stroke()
        Neon.symbol(asking ? "exclamationmark.triangle.fill" : symbol, in: d, size: 15, weight: .semibold,
                    color: asking ? Neon.red : (tint ?? (lit ? Neon.text : Neon.textDim)))
        // The chosen action's name is the opener's title under the ring; here, a tooltip.
        toolTip = title
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: disc, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?() }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview.map { convert(point, from: $0) } ?? point
        return disc.contains(p) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if disc.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(disc, cursor: .pointingHand) }
}

/// YOUR USUAL 7 · COMMANDS 4 · ACTIONS 8 — a pill of lanes; the lit pill glides between them.
final class OpenerLanes: NSView {
    struct Lane { var title: String; var count: Int }
    var lanes: [Lane] = [] { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var selected = 0 {
        didSet {
            guard selected != oldValue, lanes.indices.contains(selected) else { return }
            indicator.move(to: slot(selected), animated: true)
            needsDisplay = true
        }
    }
    var onSelect: ((Int) -> Void)?
    private lazy var indicator = SlidingIndicator(view: self)
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private static let font = NSFont.systemFont(ofSize: 11, weight: .bold)
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
    private static let inset: CGFloat = 4, gap: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.tabGroup)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ l: Lane) -> String { l.title.uppercased() }
    private func laneWidth(_ l: Lane) -> CGFloat {
        let t = (label(l) as NSString).size(withAttributes: [.font: Self.font, .kern: 1.3]).width
        let c = ("\(l.count)" as NSString).size(withAttributes: [.font: Self.countFont]).width
        return ceil(t + 8 + c) + 28
    }
    var fittedWidth: CGFloat { lanes.reduce(0) { $0 + laneWidth($1) } + CGFloat(max(0, lanes.count - 1)) * Self.gap + Self.inset * 2 }

    private func slot(_ i: Int) -> NSRect {
        var x = Self.inset
        for j in 0..<i { x += laneWidth(lanes[j]) + Self.gap }
        return NSRect(x: x, y: Self.inset, width: laneWidth(lanes[i]), height: bounds.height - Self.inset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Neon.fillBottom.withAlphaComponent(0.75).setFill(); box.fill()
        Neon.chipEdge.setStroke(); box.lineWidth = 1; box.stroke()
        guard !lanes.isEmpty else { return }
        if let h = hoverIndex, h != selected {
            let r = slot(h)
            Neon.chipHover.setFill(); NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        }
        indicator.settle(at: slot(min(selected, lanes.count - 1)))
        let ir = indicator.rect
        let pill = NSBezierPath(roundedRect: ir, xRadius: ir.height / 2, yRadius: ir.height / 2)
        Neon.accent.withAlphaComponent(0.18).setFill(); pill.fill()
        Neon.accent.withAlphaComponent(0.45).setStroke(); pill.lineWidth = 1; pill.stroke()
        for (i, l) in lanes.enumerated() {
            let r = slot(i), on = i == selected
            let t = NSAttributedString(string: label(l), attributes: [.font: Self.font, .kern: 1.3, .foregroundColor: on ? Neon.text : Neon.textFaint])
            let c = NSAttributedString(string: "\(l.count)", attributes: [.font: Self.countFont, .foregroundColor: on ? Neon.accent : Neon.textFaint])
            let w = t.size().width + 8 + c.size().width
            let x = r.midX - w / 2
            t.draw(at: NSPoint(x: x, y: r.midY - t.size().height / 2))
            c.draw(at: NSPoint(x: x + t.size().width + 8, y: r.midY - c.size().height / 2))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    private func index(_ e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        return lanes.indices.first { slot($0).contains(p) }
    }
    override func mouseMoved(with event: NSEvent) { hoverIndex = index(event) }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }
    override func mouseDown(with event: NSEvent) { if let i = index(event) { onSelect?(i) } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The dimmed screen behind the opener: the desktop blurred, a dark wash, and a soft accent
/// glow where Zera comes down. A click on it sends her back up.
final class OpenerVeil: NSView {
    var glowCenter: NSPoint = .zero { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private let blur = NSVisualEffectView()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur)
        let wash = OpenerWash(frame: bounds)
        wash.autoresizingMask = [.width, .height]
        wash.veil = self
        addSubview(wash)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

private final class OpenerWash: NSView {
    weak var veil: OpenerVeil?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.016, green: 0.02, blue: 0.047, alpha: 0.62).setFill()
        bounds.fill()
        let c = veil?.glowCenter ?? NSPoint(x: bounds.midX, y: bounds.height * 0.3)
        NSGradient(colors: [Neon.violet.withAlphaComponent(0.2), Neon.violet.withAlphaComponent(0)])?
            .draw(fromCenter: c, radius: 0, toCenter: c, radius: max(bounds.width, bounds.height) * 0.45, options: [])
    }
}
