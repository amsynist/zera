import AppKit

// The App Opener's v2 look: the screen dims, Zera rappels down with the search, and what you
// can open sits on an arc under it — the chosen one large in the middle, its neighbours shrinking
// away to either side. ⌘K opens a searchable action node below the search.
//
//                         (Zera)
//               ( 🔍  Open an app…            )
//              [ YOUR USUAL 7 · COMMANDS 4 · ACTIONS 8 ]
//        ·  [C]   [X]   [ S ]   [>_]   [F]  ·
//                       Safari
//               ● Running · v27 · /Applications
//          [ Open Safari ⏎ ] [ Actions ⌘K ] [ Pin ]

/// Colours of the v2 opener, kept local so the other screens retain their theme.
enum OpenerLook {
    static let accent = NSColor(srgbRed: 0.59, green: 0.64, blue: 1, alpha: 1)
    static let surface = NSColor(srgbRed: 0.065, green: 0.074, blue: 0.12, alpha: 1)
    static let edge = NSColor.white.withAlphaComponent(0.08)
    static let muted = NSColor(srgbRed: 0.64, green: 0.66, blue: 0.73, alpha: 1)
    static let text = NSColor.white
    static let primary = NSColor(srgbRed: 0.25, green: 0.28, blue: 0.42, alpha: 1)
    static let primaryBottom = NSColor(srgbRed: 0.19, green: 0.22, blue: 0.34, alpha: 1)
    static let width: CGFloat = 720
    static let searchHeight: CGFloat = 52
    static let cardHeight: CGFloat = 76
    static let cardRadius: CGFloat = 16
    static let buttonRadius: CGFloat = 8
    static let tileRadius: CGFloat = 12
}

/// Where an item sits on the arc, `k` steps from the chosen one.
enum OrbitArc {
    static let step: CGFloat = 110
    static func offset(_ k: Int) -> CGPoint {
        let d = CGFloat(k)
        return CGPoint(x: d * step, y: min(20, d * d * 2))
    }
    static func scale(_ k: Int) -> CGFloat { k == 0 ? 1.25 : (abs(k) == 1 ? 1 : 0.875) }
    static func alpha(_ k: Int) -> CGFloat { 1 }
    /// How many either side of the chosen one are drawn at all.
    static let reach = 4

    /// Draw through the actual tile frames, including the wider process cards.
    static func path(under frames: [CGRect]) -> CGPath {
        let lift = (frames.map(\.height).max() ?? 0) / 2 + 14
        let points = frames.sorted { $0.midX < $1.midX }.map { CGPoint(x: $0.midX, y: $0.midY - lift) }
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
            guard hovered != oldValue else { return }
            needsDisplay = true
            guard let layer = layer else { return }
            let scale: CGFloat = hovered ? 1.04 : 1
            // AppKit owns the layer anchor. Translate the scale around the visual centre.
            let x = bounds.width * (0.5 - layer.anchorPoint.x)
            let y = bounds.height * (0.5 - layer.anchorPoint.y)
            var target = CATransform3DMakeScale(scale, scale, 1)
            target.m41 = x * (1 - scale)
            target.m42 = y * (1 - scale)
            let from = layer.presentation()?.transform ?? layer.transform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = target
            CATransaction.commit()
            if !Motion.reduced {
                let zoom = CABasicAnimation(keyPath: "transform")
                zoom.fromValue = NSValue(caTransform3D: from)
                zoom.toValue = NSValue(caTransform3D: target)
                zoom.duration = 0.2
                zoom.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                layer.add(zoom, forKey: "hoverZoom")
            }
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
        let r = style == .icon ? OpenerLook.tileRadius : 12 * s
        let shape = NSBezierPath(roundedRect: b.insetBy(dx: 1, dy: 1), xRadius: r, yRadius: r)
        if chosen {
            // The chosen one: an accent ring and a soft glow.
            Neon.glowing(OpenerLook.accent.withAlphaComponent(0.35), blur: 24) {
                OpenerLook.surface.setFill(); shape.fill()
            }
        }
        switch style {
        case .icon:
            NSColor.white.withAlphaComponent(hovered ? 0.08 : 0.04).setFill(); shape.fill()
            NSColor.white.withAlphaComponent(0.06).setStroke(); shape.lineWidth = 1; shape.stroke()
            if let img = icon {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                img.draw(in: b.insetBy(dx: b.width * 0.125, dy: b.height * 0.125), from: .zero, operation: .sourceOver,
                         fraction: kept ? 0.4 : 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            }
        case .card:
            NSGradient(starting: Neon.fillTop.withAlphaComponent(1), ending: Neon.fillBottom.withAlphaComponent(1))?.draw(in: shape, angle: -90)
            OpenerLook.edge.setStroke(); shape.lineWidth = 1; shape.stroke()
            let pad = 12 * s
            let k = max(0.5, s)
            let tf = NSFont.systemFont(ofSize: 13 * k, weight: .bold), df = NSFont.monospacedDigitSystemFont(ofSize: 10.5 * k, weight: .medium)
            let lw = b.width - pad * 2
            NSAttributedString(string: title, attributes: [.font: tf, .foregroundColor: Neon.text])
                .draw(with: NSRect(x: pad, y: b.height / 2 - 17 * s, width: lw - 44 * s, height: 18 * s), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSAttributedString(string: detail, attributes: [.font: df, .foregroundColor: OpenerLook.muted])
                .draw(with: NSRect(x: pad, y: b.height / 2 + 2 * s, width: lw, height: 16 * s), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if !trailing.isEmpty {
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5 * k, weight: .bold), .foregroundColor: Neon.warning]
                let w = (trailing as NSString).size(withAttributes: a).width
                (trailing as NSString).draw(at: NSPoint(x: b.width - pad - w, y: 9 * s), withAttributes: a)
            }
        }
        if chosen {
            OpenerLook.accent.withAlphaComponent(0.85).setStroke()
            shape.lineWidth = 2; shape.stroke()
        } else if hovered {
            NSColor.white.withAlphaComponent(0.14).setStroke()
            shape.lineWidth = 1.5; shape.stroke()
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
    var showKey = false { didSet { needsDisplay = true } }
    var running = false { didSet { needsDisplay = true } }
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
        let font = NSFont.systemFont(ofSize: chosen ? 14 : 13, weight: chosen ? .semibold : .regular)
        if running {
            Neon.green.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2.5, y: 0, width: 5, height: 5)).fill()
        }
        NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: chosen ? OpenerLook.text : OpenerLook.muted,
                                                       .paragraphStyle: paragraph])
            .draw(with: NSRect(x: 0, y: 12, width: bounds.width, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if showKey && !key.isEmpty {
            let badge = NSRect(x: bounds.midX - 16, y: 34, width: 32, height: 18)
            let path = NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.06).setFill(); path.fill()
            OpenerLook.edge.setStroke(); path.lineWidth = 1; path.stroke()
            let keyText = NSAttributedString(string: key, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: OpenerLook.muted])
            keyText.draw(at: NSPoint(x: badge.midX - keyText.size().width / 2, y: badge.midY - keyText.size().height / 2))
        }
    }
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
    private static let font = NSFont.systemFont(ofSize: 14, weight: .medium)
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let inset: CGFloat = 4, gap: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.tabGroup)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ l: Lane) -> String { l.title.lowercased().capitalized.replacingOccurrences(of: "Your Usual", with: "Your usual") }
    private func laneWidth(_ l: Lane) -> CGFloat {
        let t = (label(l) as NSString).size(withAttributes: [.font: Self.font, .kern: 0]).width
        let c = ("\(l.count)" as NSString).size(withAttributes: [.font: Self.countFont]).width
        return ceil(t + 10 + max(20, c + 12)) + 34
    }
    var fittedWidth: CGFloat { lanes.reduce(0) { $0 + laneWidth($1) } + CGFloat(max(0, lanes.count - 1)) * Self.gap + Self.inset * 2 }

    private func slot(_ i: Int) -> NSRect {
        var x = Self.inset
        for j in 0..<i { x += laneWidth(lanes[j]) + Self.gap }
        return NSRect(x: x, y: Self.inset, width: laneWidth(lanes[i]), height: bounds.height - Self.inset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        OpenerLook.surface.withAlphaComponent(0.75).setFill(); box.fill()
        OpenerLook.edge.setStroke(); box.lineWidth = 1; box.stroke()
        guard !lanes.isEmpty else { return }
        if let h = hoverIndex, h != selected {
            let r = slot(h)
            Neon.chipHover.setFill(); NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        }
        indicator.settle(at: slot(min(selected, lanes.count - 1)))
        let ir = indicator.rect
        let pill = NSBezierPath(roundedRect: ir, xRadius: ir.height / 2, yRadius: ir.height / 2)
        NSColor.white.withAlphaComponent(0.08).setFill(); pill.fill()
        OpenerLook.edge.setStroke(); pill.lineWidth = 1; pill.stroke()
        for (i, l) in lanes.enumerated() {
            let r = slot(i), on = i == selected
            let t = NSAttributedString(string: label(l), attributes: [.font: Self.font, .kern: 0, .foregroundColor: on ? Neon.text : OpenerLook.muted])
            let c = NSAttributedString(string: "\(l.count)", attributes: [.font: Self.countFont, .foregroundColor: OpenerLook.muted])
            let countW = max(20, c.size().width + 12)
            let w = t.size().width + 10 + countW
            let x = r.midX - w / 2
            t.draw(at: NSPoint(x: x, y: r.midY - t.size().height / 2))
            let badge = NSRect(x: x + t.size().width + 10, y: r.midY - 9, width: countW, height: 18)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9).fill()
            c.draw(at: NSPoint(x: badge.midX - c.size().width / 2, y: r.midY - c.size().height / 2))
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
        NSColor(srgbRed: 0.025, green: 0.03, blue: 0.06, alpha: 0.98).setFill()
        bounds.fill()
        let c = veil?.glowCenter ?? NSPoint(x: bounds.midX, y: bounds.height * 0.3)
        NSGradient(colors: [OpenerLook.accent.withAlphaComponent(0.10), OpenerLook.accent.withAlphaComponent(0)])?
            .draw(fromCenter: c, radius: 0, toCenter: c, radius: max(bounds.width, bounds.height) * 0.45, options: [])
    }
}
