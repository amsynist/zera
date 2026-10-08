import AppKit

/// Clean, minimal stroke icons for the banners, drawn in code on a 24-point grid in the style of
/// Lucide (open source, ISC licence) and the v2 design's own icon set: 1.8 pt round-capped lines,
/// no fills. Nothing is downloaded or bundled.
enum LineIcon {
    /// The icon `name` as a path on the 24 × 24 grid (y down), or nil if there isn't one.
    static func path(_ name: String) -> NSBezierPath? {
        let p = NSBezierPath()
        func line(_ pts: [(CGFloat, CGFloat)]) {
            guard let f = pts.first else { return }
            p.move(to: NSPoint(x: f.0, y: f.1))
            pts.dropFirst().forEach { p.line(to: NSPoint(x: $0.0, y: $0.1)) }
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
            p.append(NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r))
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            p.append(NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)))
        }
        switch name {
        case "calendar":
            rect(3, 5, 18, 16, 2.5)
            line([(3, 10), (21, 10)]); line([(8, 3), (8, 7)]); line([(16, 3), (16, 7)])
        case "video":
            rect(2.5, 6.5, 13.5, 11, 2.5)
            line([(16, 10.5), (21.5, 7.5), (21.5, 16.5), (16, 13.5)])
        case "bell":
            p.move(to: NSPoint(x: 18, y: 16))
            p.line(to: NSPoint(x: 18, y: 11))
            p.appendArc(withCenter: NSPoint(x: 12, y: 11), radius: 6, startAngle: 0, endAngle: 180, clockwise: true)
            p.line(to: NSPoint(x: 6, y: 16))
            p.line(to: NSPoint(x: 4, y: 18)); p.line(to: NSPoint(x: 20, y: 18)); p.close()
            line([(10, 21), (14, 21)])
        case "check":
            line([(4.5, 12.5), (9.5, 17.5), (19.5, 7)])
        case "x":
            line([(6, 6), (18, 18)]); line([(18, 6), (6, 18)])
        case "droplet":
            p.move(to: NSPoint(x: 12, y: 2.5))
            p.curve(to: NSPoint(x: 6, y: 14), controlPoint1: NSPoint(x: 12, y: 2.5), controlPoint2: NSPoint(x: 6, y: 9.5))
            p.appendArc(withCenter: NSPoint(x: 12, y: 14), radius: 6, startAngle: 180, endAngle: 0, clockwise: true)
            p.curve(to: NSPoint(x: 12, y: 2.5), controlPoint1: NSPoint(x: 18, y: 9.5), controlPoint2: NSPoint(x: 12, y: 2.5))
            p.close()
        case "coffee":
            p.move(to: NSPoint(x: 4, y: 9)); p.line(to: NSPoint(x: 16, y: 9)); p.line(to: NSPoint(x: 16, y: 16))
            p.appendArc(from: NSPoint(x: 16, y: 20), to: NSPoint(x: 12, y: 20), radius: 4)
            p.line(to: NSPoint(x: 8, y: 20))
            p.appendArc(from: NSPoint(x: 4, y: 20), to: NSPoint(x: 4, y: 16), radius: 4)
            p.close()
            p.move(to: NSPoint(x: 16, y: 10.5)); p.line(to: NSPoint(x: 17.5, y: 10.5))
            p.appendArc(withCenter: NSPoint(x: 17.5, y: 13.25), radius: 2.75, startAngle: 270, endAngle: 90, clockwise: false)
            p.line(to: NSPoint(x: 16, y: 16))
            line([(7, 3), (7, 5.5)]); line([(10, 3), (10, 5.5)]); line([(13, 3), (13, 5.5)])
        case "battery":
            rect(2, 7, 17, 10, 2.5)
            line([(22, 10.5), (22, 13.5)])
            line([(6, 10.5), (6, 13.5)])
        case "moon":
            // A crescent: the outer circle's arc outside the bite, then the bite's arc back.
            let c1 = NSPoint(x: 12, y: 12.5), r1: CGFloat = 8.5
            let c2 = NSPoint(x: 16.5, y: 7.5), r2: CGFloat = 6.5
            let d = hypot(c2.x - c1.x, c2.y - c1.y)
            let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d), h = sqrt(max(0, r1 * r1 - a * a))
            let mx = c1.x + a * (c2.x - c1.x) / d, my = c1.y + a * (c2.y - c1.y) / d
            let i1 = NSPoint(x: mx + h * (c2.y - c1.y) / d, y: my - h * (c2.x - c1.x) / d)
            let i2 = NSPoint(x: mx - h * (c2.y - c1.y) / d, y: my + h * (c2.x - c1.x) / d)
            func ang(_ c: NSPoint, _ q: NSPoint) -> CGFloat { atan2(q.y - c.y, q.x - c.x) * 180 / .pi }
            p.move(to: i1)
            p.appendArc(withCenter: c1, radius: r1, startAngle: ang(c1, i1), endAngle: ang(c1, i2), clockwise: true)
            p.appendArc(withCenter: c2, radius: r2, startAngle: ang(c2, i2), endAngle: ang(c2, i1), clockwise: false)
            p.close()
        case "branch":
            circle(6, 5, 2); circle(6, 19, 2); circle(18, 7, 2)
            line([(6, 7), (6, 17)])
            p.move(to: NSPoint(x: 18, y: 9))
            p.curve(to: NSPoint(x: 6, y: 16), controlPoint1: NSPoint(x: 18, y: 14), controlPoint2: NSPoint(x: 6, y: 12))
        case "clock":
            circle(12, 12, 9)
            line([(12, 7), (12, 12), (15.5, 14)])
        case "sparkle":
            line([(12, 3), (13.8, 10.2), (21, 12), (13.8, 13.8), (12, 21), (10.2, 13.8), (3, 12), (10.2, 10.2)]); p.close()
        case "sliders":
            line([(4, 7), (11, 7)]); line([(17, 7), (20, 7)]); circle(14, 7, 2.5)
            line([(4, 17), (7, 17)]); line([(13, 17), (20, 17)]); circle(10, 17, 2.5)
        case "external":
            line([(14, 4), (20, 4), (20, 10)]); line([(20, 4), (11, 13)])
            line([(18, 14), (18, 19), (5, 19), (5, 6), (10, 6)])
        case "eye":
            p.move(to: NSPoint(x: 2.5, y: 12))
            p.curve(to: NSPoint(x: 21.5, y: 12), controlPoint1: NSPoint(x: 7, y: 4.5), controlPoint2: NSPoint(x: 17, y: 4.5))
            p.curve(to: NSPoint(x: 2.5, y: 12), controlPoint1: NSPoint(x: 17, y: 19.5), controlPoint2: NSPoint(x: 7, y: 19.5))
            circle(12, 12, 3)
        case "alert":
            circle(12, 12, 9)
            line([(12, 7.5), (12, 12.5)]); line([(12, 16.2), (12, 16.3)])
        case "message":
            p.move(to: NSPoint(x: 4, y: 5))
            p.line(to: NSPoint(x: 20, y: 5)); p.line(to: NSPoint(x: 20, y: 16)); p.line(to: NSPoint(x: 9, y: 16))
            p.line(to: NSPoint(x: 4, y: 20)); p.close()
        default:
            return nil
        }
        return p
    }

    /// Strokes `name` centred in `rect` (a flipped context), scaled from the 24-point grid.
    static func draw(_ name: String, in rect: NSRect, color: NSColor, lineWidth: CGFloat = 1.8) {
        guard let p = path(name) else { return }
        let s = min(rect.width, rect.height) / 24
        let t = AffineTransform(translationByX: rect.midX - 12 * s, byY: rect.midY - 12 * s)
        var m = AffineTransform(scale: s)
        m.append(t)
        p.transform(using: m)
        p.lineWidth = lineWidth
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        color.setStroke()
        p.stroke()
    }

    /// The icon as a template image `size` points square (tinted wherever template images are).
    static func image(_ name: String, size: CGFloat, lineWidth: CGFloat = 1.8) -> NSImage? {
        guard path(name) != nil else { return nil }
        let img = LineImage(size: NSSize(width: size, height: size), flipped: true) { r in
            draw(name, in: r, color: .black, lineWidth: lineWidth)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// `g` in `color`: SF Symbols through their palette, line icons by tinting the template.
    static func tint(_ g: NSImage, _ color: NSColor) -> NSImage? {
        guard g is LineImage else { return g.withSymbolConfiguration(.init(paletteColors: [color])) }
        let out = NSImage(size: g.size, flipped: false) { r in
            g.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        return out
    }
}

/// A line icon's image, so the buttons know to tint it themselves.
final class LineImage: NSImage {}
