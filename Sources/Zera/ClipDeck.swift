import AppKit
import QuickLookThumbnailing

// MARK: - The Clip
//
// The Clipboard shortcut's picker is a deck of cards rather than a list in a box, set in the Signal
// interface. A bracketed prompt (the search) is wired by one lit trace into the front card's port;
// the pane frame holds the front position while cards flip under it, and a rail with one dot per
// waiting card runs down the gutter. The front card shows the copy itself (a colour fills the card,
// an image covers it, code sits in an editor box); the next three peek out with their titles.
//
// Cost: every card is a few Core Animation layers with pre-rendered bitmaps, and only the front
// card holds a full one. Nothing redraws per frame; moving through the deck animates position,
// transform and opacity, and the only running animation is the trace pulse while the picker is open.

/// Where everything sits, for a window of `bounds` (top-left origin).
struct ClipDeckLayout: Equatable {
    static let size = NSSize(width: 404, height: 440)
    /// Room round the deck for the gutter, the pane glow and card shadows.
    static let margin: CGFloat = 22
    /// Cards showing under the front one.
    static let peeks = 3
    static let peekStep: CGFloat = 30
    static let footer: CGFloat = 36
    static let heroTop: CGFloat = 58
    static let statusHeight: CGFloat = 24
    /// How far a card swings round its top edge as it flips away.
    static let flipAngle: CGFloat = 1.15

    let bounds: NSSize

    var card: NSSize {
        let below = CGFloat(Self.peeks) * Self.peekStep + 12 + Self.statusHeight + 14
        return NSSize(width: max(200, bounds.width - 2 * Self.margin), height: max(120, bounds.height - Self.heroTop - below))
    }
    var hero: NSRect { NSRect(x: (bounds.width - card.width) / 2, y: Self.heroTop, width: card.width, height: card.height) }
    /// The search prompt, set in from the left so the trace can leave it for the gutter.
    var prompt: NSRect { NSRect(x: hero.minX + 26, y: 8, width: card.width - 26, height: 38) }
    var status: NSRect { NSRect(x: hero.minX, y: bounds.height - 14 - Self.statusHeight, width: card.width, height: Self.statusHeight) }

    /// The gutter the trace and the rail run down, left of the deck.
    var gutterX: CGFloat { hero.minX - 8 }
    /// The front card's port: where `SignalPaneLayer` draws it for a pane at `hero`.
    var port: CGPoint { CGPoint(x: hero.minX, y: hero.minY + 12.5) }

    /// Prompt → gutter → port.
    var tracePath: CGPath {
        let p = CGMutablePath(), r: CGFloat = 6, y = prompt.midY, gx = gutterX
        p.move(to: CGPoint(x: prompt.minX, y: y))
        p.addLine(to: CGPoint(x: gx + r, y: y))
        p.addQuadCurve(to: CGPoint(x: gx, y: y + r), control: CGPoint(x: gx, y: y))
        p.addLine(to: CGPoint(x: gx, y: port.y - r))
        p.addQuadCurve(to: CGPoint(x: gx + r, y: port.y), control: CGPoint(x: gx, y: port.y))
        p.addLine(to: port)
        return p
    }

    /// Where the rail meets the waiting card at `depth` (1…`peeks`).
    func railDot(_ depth: Int) -> CGPoint {
        let strip = visibleRect(depth)
        return CGPoint(x: strip.minX - 1, y: strip.midY + 1)
    }

    /// The rail: on down the gutter from the port, with a branch to each of `count` waiting cards.
    func railPath(_ count: Int) -> CGPath? {
        guard count > 0 else { return nil }
        let p = CGMutablePath(), r: CGFloat = 5, gx = gutterX
        p.move(to: CGPoint(x: gx, y: port.y - 6))
        p.addLine(to: CGPoint(x: gx, y: railDot(count).y - r))
        for depth in 1...count {
            let dot = railDot(depth)
            p.move(to: CGPoint(x: gx, y: dot.y - r))
            p.addQuadCurve(to: CGPoint(x: gx + r, y: dot.y), control: CGPoint(x: gx, y: dot.y))
            p.addLine(to: CGPoint(x: dot.x - 3, y: dot.y))
        }
        return p
    }

    /// A card's place by depth: 0 is the front, 1…`peeks` peek out below, -1 has flipped away
    /// upwards, and anything deeper waits unseen under the last peek.
    struct Slot: Equatable {
        /// The middle of the card's top edge.
        var top: CGPoint
        var scale: CGFloat
        /// How far the card is dimmed (it stays opaque, so the stack never shows through).
        var shade: CGFloat
        var opacity: Float
        var angle: CGFloat
    }

    func slot(_ depth: Int) -> Slot {
        let x = bounds.width / 2
        if depth < 0 { return Slot(top: CGPoint(x: x, y: Self.heroTop - 4), scale: 1, shade: 0, opacity: 0, angle: Self.flipAngle) }
        let d = CGFloat(min(depth, Self.peeks))
        let s = 1 - 0.045 * d
        var slot = Slot(top: CGPoint(x: x, y: hero.maxY + Self.peekStep * d - card.height * s), scale: s, shade: 0.17 * d, opacity: 1, angle: 0)
        if depth > Self.peeks { slot.top.y += 8; slot.scale -= 0.03; slot.opacity = 0 }
        return slot
    }

    /// The part of a card you can see and click: the whole front card, or a peeking strip.
    func visibleRect(_ depth: Int) -> NSRect {
        guard depth > 0 else { return hero }
        let w = card.width * slot(depth).scale
        return NSRect(x: (bounds.width - w) / 2, y: hero.maxY + Self.peekStep * CGFloat(depth - 1), width: w, height: Self.peekStep)
    }
}

// MARK: - Card faces

/// Draws what a card shows, once, into a bitmap.
enum ClipFace {
    static func tint(_ item: ClipItem) -> NSColor {
        switch item.kind {
        case .text: return Signal.itemColor(0)
        case .code: return Signal.itemColor(1)
        case .link: return Signal.itemColor(3)
        case .color: return ClipRow.color(item.text) ?? Signal.itemColor(0)
        case .image: return Signal.itemColor(2)
        case .files: return Signal.itemColor(4)
        }
    }

    static func symbol(_ item: ClipItem) -> String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .files: return item.paths.count > 1 ? "doc.on.doc" : "doc"
        }
    }

    /// A bitmap drawn with a top-left origin, at `scale` pixels per point.
    static func bitmap(_ size: NSSize, scale: CGFloat, _ draw: (NSRect) -> Void) -> CGImage? {
        let pw = Int((size.width * scale).rounded(.up)), ph = Int((size.height * scale).rounded(.up))
        guard pw > 0, ph > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func text(_ s: String, _ font: NSFont, _ color: NSColor, in r: NSRect, lines: Bool = false,
                             spacing: CGFloat = 0, kern: CGFloat = 0, align: NSTextAlignment = .left,
                             mode: NSLineBreakMode = .byTruncatingTail) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = lines ? .byWordWrapping : mode
        para.lineSpacing = spacing
        para.alignment = align
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para, .kern: kern])
        a.draw(with: r, options: lines ? [.usesLineFragmentOrigin, .truncatesLastVisibleLine] : [.usesLineFragmentOrigin])
    }

    private static func glyph(_ name: String, size: CGFloat, color: NSColor, centre c: NSPoint, weight: NSFont.Weight = .semibold) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))) else { return }
        let s = img.size
        img.draw(in: NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Whether a card is covered edge to edge (a colour, a picture), and the ink that reads on it.
    private static func inks(_ item: ClipItem, picture: NSImage?) -> (main: NSColor, soft: NSColor, faint: NSColor, bleed: Bool) {
        let p = Pal
        if item.kind == .color, let c = ClipRow.color(item.text) {
            let ink = p.ink(on: c)
            return (ink, ink.withAlphaComponent(0.74), ink.withAlphaComponent(0.55), true)
        }
        if picture != nil { return (.white, NSColor(white: 1, alpha: 0.8), NSColor(white: 1, alpha: 0.6), true) }
        return (p.text, p.textSecondary, p.textTertiary, false)
    }

    private static func detail(_ item: ClipItem) -> String {
        switch item.kind {
        case .text: return "\(item.text.count) chars"
        case .code: return "\(item.text.components(separatedBy: "\n").count) lines"
        case .image: return item.imageSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? ""
        case .files: return item.paths.count > 1 ? "\(item.paths.count) files" : ((item.paths.first ?? "") as NSString).pathExtension.uppercased()
        case .link, .color: return ""
        }
    }

    static func face(_ item: ClipItem, size: NSSize, scale: CGFloat, picture: NSImage?) -> CGImage? {
        bitmap(size, scale: scale) { r in
            let p = Pal, w = r.width, h = r.height, foot = ClipDeckLayout.footer
            let tint = tint(item)
            let ink = inks(item, picture: picture)
            NSGradient(starting: p.cardTop.withAlphaComponent(1), ending: p.cardBottom.withAlphaComponent(1))?.draw(in: r, angle: 90)

            if item.kind == .color, ink.bleed {
                tint.setFill(); r.fill()
                NSGradient(starting: NSColor(white: 1, alpha: 0.16), ending: NSColor(white: 1, alpha: 0))?
                    .draw(in: NSRect(x: 0, y: 0, width: w, height: h * 0.5), angle: 90)
                NSColor(white: 0, alpha: 0.12).setFill()
                NSRect(x: 0, y: h - foot, width: w, height: foot).fill()
            } else if let picture {
                let s = picture.size, k = max(w / max(1, s.width), h / max(1, s.height))
                let fit = NSRect(x: (w - s.width * k) / 2, y: (h - s.height * k) / 2, width: s.width * k, height: s.height * k)
                picture.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGradient(starting: NSColor(white: 0, alpha: 0.62), ending: NSColor(white: 0, alpha: 0))?
                    .draw(in: NSRect(x: 0, y: 0, width: w, height: 76), angle: 90)
                NSGradient(starting: NSColor(white: 0, alpha: 0), ending: NSColor(white: 0, alpha: 0.7))?
                    .draw(in: NSRect(x: 0, y: h - foot - 64, width: w, height: 64), angle: 90)
                NSColor(white: 0, alpha: 0.7).setFill()
                NSRect(x: 0, y: h - foot, width: w, height: foot).fill()
            } else {
                NSGradient(colors: [tint.withAlphaComponent(0.2), tint.withAlphaComponent(0)])?
                    .draw(fromCenter: NSPoint(x: 36, y: 0), radius: 0, toCenter: NSPoint(x: 36, y: 0), radius: w * 0.78, options: [])
                NSColor(white: 0, alpha: 0.16).setFill()
                NSRect(x: 0, y: h - foot, width: w, height: foot).fill()
                NSColor(white: 1, alpha: 0.07).setFill()
                NSRect(x: 0, y: h - foot, width: w, height: 1).fill()
            }

            // Header: what kind of copy this is, and one fact about it.
            let label = ink.bleed ? ink.main : tint
            SignalDraw.dot(at: NSPoint(x: 23, y: 30), color: label, radius: 3)
            text(item.kindName.uppercased(), ZFont.mono(ofSize: 9.5, weight: .semibold), label,
                 in: NSRect(x: 33, y: 24, width: 120, height: 13), kern: 1.4)
            var right = w - 18
            let fact = detail(item)
            if !fact.isEmpty {
                let font = ZFont.mono(ofSize: 9.5, weight: .medium)
                let fw = ceil((fact as NSString).size(withAttributes: [.font: font]).width) + 2
                text(fact, font, ink.faint, in: NSRect(x: right - fw, y: 24, width: fw, height: 13), align: .right)
                right -= fw + 8
            }
            if item.pinned { glyph("pin.fill", size: 9.5, color: ink.bleed ? ink.main : p.warning, centre: NSPoint(x: right - 6, y: 30)) }

            let body = NSRect(x: 18, y: 48, width: w - 36, height: h - 48 - foot - 10)
            switch item.kind {
            case .text:
                let s = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let short = s.count <= 46 && !s.contains("\n")
                text(String(s.prefix(640)), short ? ZFont.ui(ofSize: 21, weight: .medium) : ZFont.ui(ofSize: 14.5),
                     ink.main, in: body, lines: true, spacing: short ? 3 : 4.5)
            case .code:
                let box = NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10)
                p.codeBox.withAlphaComponent(1).setFill(); box.fill()
                NSColor(white: 1, alpha: 0.07).setStroke(); box.lineWidth = 1; box.stroke()
                let lines = item.text.components(separatedBy: "\n")
                let lineH: CGFloat = 16.5, room = max(1, Int((body.height - 16) / lineH))
                let shown = lines.count > room ? room - 1 : lines.count
                for i in 0..<max(0, shown) {
                    let y = body.minY + 9 + CGFloat(i) * lineH
                    text("\(i + 1)", ZFont.mono(ofSize: 10), p.textTertiary, in: NSRect(x: body.minX + 4, y: y + 1, width: 24, height: lineH), align: .right)
                    text(lines[i].replacingOccurrences(of: "\t", with: "  "), ZFont.mono(ofSize: 11.5, weight: .medium), p.codeText,
                         in: NSRect(x: body.minX + 38, y: y, width: body.width - 48, height: lineH), mode: .byClipping)
                }
                if lines.count > room {
                    text("+ \(lines.count - shown) more lines", ZFont.mono(ofSize: 10.5), p.textTertiary,
                         in: NSRect(x: body.minX + 38, y: body.minY + 9 + CGFloat(shown) * lineH, width: body.width - 48, height: lineH))
                }
            case .link:
                let raw = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = URL(string: raw)
                var host = url?.host ?? raw
                if host.hasPrefix("www.") { host.removeFirst(4) }
                var rest = url?.path ?? ""
                if let q = url?.query { rest += "?" + q }
                if rest == "/" { rest = "" }
                text(host, ZFont.ui(ofSize: 23, weight: .semibold), ink.main, in: NSRect(x: body.minX, y: body.minY + 4, width: body.width, height: 32), mode: .byTruncatingMiddle)
                if !rest.isEmpty {
                    text(rest, ZFont.mono(ofSize: 12), ink.soft, in: NSRect(x: body.minX, y: body.minY + 44, width: body.width - 50, height: body.height - 48), lines: true, spacing: 3)
                }
                let orb = NSRect(x: body.maxX - 38, y: body.maxY - 38, width: 38, height: 38)
                let circle = NSBezierPath(ovalIn: orb.insetBy(dx: 0.5, dy: 0.5))
                tint.withAlphaComponent(0.14).setFill(); circle.fill()
                tint.withAlphaComponent(0.42).setStroke(); circle.lineWidth = 1; circle.stroke()
                glyph("arrow.up.right", size: 14, color: tint, centre: NSPoint(x: orb.midX, y: orb.midY), weight: .bold)
            case .color:
                text(item.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), ZFont.mono(ofSize: 34, weight: .bold), ink.main,
                     in: NSRect(x: body.minX, y: body.midY - 34, width: body.width, height: 44))
                if let c = ClipRow.color(item.text)?.usingColorSpace(.sRGB) {
                    let rgb = "RGB \(Int((c.redComponent * 255).rounded())) \(Int((c.greenComponent * 255).rounded())) \(Int((c.blueComponent * 255).rounded()))"
                    text(rgb, ZFont.mono(ofSize: 12, weight: .medium), ink.soft, in: NSRect(x: body.minX + 2, y: body.midY + 14, width: body.width, height: 16), kern: 0.6)
                }
            case .image:
                if picture == nil { glyph("photo", size: 34, color: p.textTertiary, centre: NSPoint(x: body.midX, y: body.midY), weight: .regular) }
            case .files:
                let names = item.paths.map { ($0 as NSString).lastPathComponent }
                let first = names.first ?? item.title
                if picture != nil {
                    text(first, ZFont.ui(ofSize: 15, weight: .medium), ink.main, in: NSRect(x: 18, y: h - foot - 30, width: w - 36, height: 20), mode: .byTruncatingMiddle)
                    break
                }
                let tile = NSRect(x: body.minX, y: body.minY + 2, width: 56, height: 66)
                let tp = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
                tint.withAlphaComponent(0.13).setFill(); tp.fill()
                tint.withAlphaComponent(0.36).setStroke(); tp.lineWidth = 1; tp.stroke()
                glyph(symbol(item), size: 22, color: tint, centre: NSPoint(x: tile.midX, y: tile.midY), weight: .medium)
                let x = tile.maxX + 14, tw = body.maxX - x
                text(first, ZFont.ui(ofSize: 17, weight: .medium), ink.main, in: NSRect(x: x, y: body.minY, width: tw, height: 46), lines: true, spacing: 2)
                let folder = ((item.paths.first ?? "") as NSString).deletingLastPathComponent
                text((folder as NSString).abbreviatingWithTildeInPath, ZFont.mono(ofSize: 11), ink.soft,
                     in: NSRect(x: x, y: body.minY + 52, width: tw, height: 15), mode: .byTruncatingHead)
                for (i, name) in names.dropFirst().prefix(3).enumerated() {
                    let more = i == 2 && names.count > 4
                    text(more ? "+ \(names.count - 3) more" : name, ZFont.ui(ofSize: 12.5), more ? ink.faint : ink.soft,
                         in: NSRect(x: body.minX, y: tile.maxY + 14 + CGFloat(i) * 19, width: body.width, height: 17), mode: .byTruncatingMiddle)
                }
            }
        }
    }

    /// The single card shown when there is nothing to flip through.
    static func note(_ title: String, hint: String, size: NSSize, scale: CGFloat) -> CGImage? {
        bitmap(size, scale: scale) { r in
            let p = Pal
            NSGradient(starting: p.cardTop.withAlphaComponent(1), ending: p.cardBottom.withAlphaComponent(1))?.draw(in: r, angle: 90)
            glyph("doc.on.clipboard", size: 26, color: p.textTertiary, centre: NSPoint(x: r.midX, y: r.midY - 30), weight: .regular)
            text(title, ZFont.ui(ofSize: 14, weight: .medium), p.text, in: NSRect(x: 28, y: r.midY, width: r.width - 56, height: 40), lines: true, spacing: 3, align: .center)
            text(hint, Typo.caption, p.textTertiary, in: NSRect(x: 28, y: r.midY + 42, width: r.width - 56, height: 32), lines: true, spacing: 2, align: .center)
        }
    }

    /// A key cap ending at `x`; returns where it starts. On a dark card it is Signal's own
    /// (`SignalDraw.keycap`); on a colour or a picture it is drawn in that card's ink.
    private static func keycap(_ s: String, rightEdge x: CGFloat, midY: CGFloat, ink: NSColor, bleed: Bool, lit: Bool) -> CGFloat {
        if !bleed {
            let w = ceil((s as NSString).size(withAttributes: [.font: ZFont.mono(ofSize: 10, weight: .medium)]).width) + 10
            SignalDraw.keycap(s, at: NSPoint(x: x - w, y: midY - 8), lit: lit)
            return x - w
        }
        let font = ZFont.mono(ofSize: 10, weight: .semibold)
        let tw = ceil((s as NSString).size(withAttributes: [.font: font]).width)
        let r = NSRect(x: x - tw - 10, y: midY - 8, width: tw + 10, height: 16)
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        ink.withAlphaComponent(0.1).setFill(); path.fill()
        ink.withAlphaComponent(0.26).setStroke(); path.lineWidth = 1; path.stroke()
        text(s, font, ink.withAlphaComponent(0.92), in: NSRect(x: r.minX, y: r.minY + 1.5, width: r.width, height: 13), align: .center)
        return r.minX
    }

    /// The front card's bottom line: where the copy came from, and the key that copies it.
    static func frontFoot(_ item: ClipItem, size: NSSize, scale: CGFloat, picture: NSImage?) -> CGImage? {
        bitmap(size, scale: scale) { r in
            let ink = inks(item, picture: picture)
            let x = keycap("↵", rightEdge: r.width - 16, midY: r.midY, ink: ink.main, bleed: ink.bleed, lit: true)
            let font = Typo.caption
            text("copy", font, ink.soft, in: NSRect(x: x - 40, y: r.midY - 7.5, width: 34, height: 15), align: .right)
            text(ClipRow.meta(item), font, ink.soft, in: NSRect(x: 18, y: r.midY - 7.5, width: x - 40 - 26, height: 15))
        }
    }

    /// A peeking card's strip: its title and the ⌘ digit that copies it straight away. It paints
    /// its own background, so a waiting card needs no other bitmap.
    static func peekFoot(_ item: ClipItem, index: Int, size: NSSize, scale: CGFloat) -> CGImage? {
        bitmap(size, scale: scale) { r in
            let ink = inks(item, picture: nil)
            if ink.bleed {
                tint(item).setFill(); r.fill()
                NSColor(white: 0, alpha: 0.12).setFill(); r.fill()
            } else {
                Pal.cardBottom.withAlphaComponent(1).setFill(); r.fill()
                NSColor(white: 0, alpha: 0.16).setFill(); r.fill()
                NSColor(white: 1, alpha: 0.07).setFill()
                NSRect(x: 0, y: 0, width: r.width, height: 1).fill()
            }
            let mid = r.midY + 2
            glyph(symbol(item), size: 10, color: ink.bleed ? ink.main : tint(item), centre: NSPoint(x: 25, y: mid))
            var right = r.width - 16
            if index < 9 {
                right = keycap("⌘\(index + 1)", rightEdge: right, midY: mid, ink: ink.main, bleed: ink.bleed, lit: false) - 8
            }
            if item.pinned { glyph("pin.fill", size: 8.5, color: ink.bleed ? ink.main : Pal.warning, centre: NSPoint(x: right - 4, y: mid)); right -= 16 }
            text(item.title, ZFont.ui(ofSize: 12.5, weight: .medium), ink.main.withAlphaComponent(0.92), in: NSRect(x: 40, y: mid - 8.5, width: right - 40, height: 17))
        }
    }

    /// The rubber stamp that lands on a card when it is copied.
    static func stamp(_ word: String, color: NSColor, size: NSSize, scale: CGFloat) -> CGImage? {
        bitmap(size, scale: scale) { r in
            let outer = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            NSColor(white: 0, alpha: 0.62).setFill(); outer.fill()
            color.withAlphaComponent(0.16).setFill(); outer.fill()
            color.setStroke(); outer.lineWidth = 2.5; outer.stroke()
            let inner = NSBezierPath(roundedRect: r.insetBy(dx: 6.5, dy: 6.5), xRadius: 3, yRadius: 3)
            color.withAlphaComponent(0.5).setStroke(); inner.lineWidth = 1; inner.stroke()
            text(word, ZFont.mono(ofSize: 17, weight: .bold), color, in: NSRect(x: 0, y: r.midY - 11, width: r.width + 3, height: 24), kern: 3, align: .center)
        }
    }
}

// MARK: - A card

/// Explicit animations that always start from where the layer is on screen, so holding ↓ never jumps.
private enum ClipAnim {
    /// `settle`: a spring with no overshoot (a card landing flat must not tip past flat).
    /// `duration`: for the plain ease-out.
    static func set(_ layer: CALayer, _ key: String, _ value: Any, animated: Bool, spring: Bool = false, settle: Bool = false,
                    duration: CFTimeInterval = 0.2, delay: CFTimeInterval = 0) {
        let from = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        layer.removeAnimation(forKey: key)
        guard animated else { return }
        let a: CABasicAnimation
        if spring {
            let s = CASpringAnimation(keyPath: key)
            // 2·√stiffness is critical damping: the quickest settle with no overshoot.
            s.mass = 1; s.stiffness = settle ? 440 : 330; s.damping = settle ? 42 : 27
            s.duration = s.settlingDuration
            a = s
        } else {
            a = CABasicAnimation(keyPath: key)
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        a.fromValue = from
        a.toValue = value
        if delay > 0 { a.beginTime = CACurrentMediaTime() + delay; a.fillMode = .backwards }
        layer.add(a, forKey: key)
    }
}

/// One copy as a card: a rounded plate with its face, the two footers it swaps between, a shade
/// for depth and the stamp.
final class ClipCard {
    enum Content: Equatable {
        case item(ClipItem)
        case note(title: String, hint: String)
    }

    static let radius: CGFloat = Signal.paneRadius
    /// Moves, scales and flips; carries the shadow.
    let layer = CALayer()
    private let plate = CALayer(), frontFoot = CALayer(), peekFoot = CALayer(), shade = CALayer(), stampLayer = CALayer()
    private let size: NSSize, scale: CGFloat
    private(set) var content: Content
    private(set) var index: Int
    /// The image or media thumbnail that covers the card, while it is at or next to the front.
    private(set) var picture: NSImage?
    var pictureRequested = false
    var slot: ClipDeckLayout.Slot?
    var depth = 0
    var leaving = false
    var retiredAt: CFTimeInterval = 0
    private var stampWork: DispatchWorkItem?
    private var stamping = false
    // Which bitmaps exist. A front card holds its face and front footer, a peeking card only its
    // strip, a card out of sight nothing: `ensure` draws on demand, `trim` lets the rest go.
    private var hasFace = false, hasFront = false, hasPeek = false

    /// The copy's own colour; nil for the note card.
    var tint: NSColor? {
        if case .item(let item) = content { return ClipFace.tint(item) }
        return nil
    }

    init(_ content: Content, index: Int, size: NSSize, scale: CGFloat) {
        self.content = content
        self.index = index
        self.size = size
        self.scale = scale
        let b = CGRect(origin: .zero, size: size), foot = ClipDeckLayout.footer
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.bounds = b
        layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer.shadowPath = CGPath(roundedRect: b, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        plate.frame = b
        plate.cornerRadius = Self.radius
        plate.cornerCurve = .continuous
        plate.masksToBounds = true
        plate.borderWidth = 1
        plate.backgroundColor = Pal.cardBottom.withAlphaComponent(1).cgColor
        layer.addSublayer(plate)
        for l in [frontFoot, peekFoot] {
            l.frame = CGRect(x: 0, y: size.height - foot, width: size.width, height: foot)
            plate.addSublayer(l)
        }
        shade.frame = b
        shade.backgroundColor = NSColor.black.cgColor
        shade.opacity = 0
        plate.addSublayer(shade)
        stampLayer.bounds = CGRect(x: 0, y: 0, width: 136, height: 46)
        stampLayer.position = CGPoint(x: size.width - 96, y: size.height * 0.5)
        stampLayer.opacity = 0
        plate.addSublayer(stampLayer)
        [plate, frontFoot, peekFoot, stampLayer].forEach { $0.contentsScale = scale }
        CATransaction.commit()
    }

    /// The same copy may come back changed (pinned, copied again) or at another place in the list.
    func update(_ content: Content, index: Int) {
        guard content != self.content || index != self.index else { return }
        let sameContent = content == self.content
        self.content = content
        self.index = index
        // Only the strip shows the position (⌘n); the rest follows the copy itself.
        render(face: hasFace && !sameContent, front: hasFront && !sameContent, peek: hasPeek)
    }

    func setPicture(_ image: NSImage?) {
        guard image !== picture else { return }
        picture = image
        if image != nil { render(face: hasFace, front: hasFront, peek: false) }
    }

    private func render(face: Bool, front: Bool, peek: Bool) {
        guard face || front || peek else { return }
        let foot = NSSize(width: size.width, height: ClipDeckLayout.footer)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switch content {
        case .item(let item):
            if face { plate.contents = ClipFace.face(item, size: size, scale: scale, picture: picture) }
            if front { frontFoot.contents = ClipFace.frontFoot(item, size: foot, scale: scale, picture: picture) }
            if peek { peekFoot.contents = ClipFace.peekFoot(item, index: index, size: foot, scale: scale) }
        case .note(let title, let hint):
            if face { plate.contents = ClipFace.note(title, hint: hint, size: size, scale: scale) }
        }
        CATransaction.commit()
    }

    /// Draws what this place in the deck shows, if it isn't drawn yet.
    func ensure(front: Bool) {
        let isNote: Bool
        if case .note = content { isNote = true } else { isNote = false }
        let face = (front || isNote) && !hasFace, foot = front && !isNote && !hasFront, strip = !front && !isNote && !hasPeek
        render(face: face, front: foot, peek: strip)
        hasFace = hasFace || face; hasFront = hasFront || foot; hasPeek = hasPeek || strip
    }

    /// Once the deck is still: let go of every bitmap this card's place doesn't show.
    func trim() {
        let front = depth == 0 && !leaving, peek = depth > 0 && !leaving
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !front, hasFace { plate.contents = nil; hasFace = false }
        if !front, hasFront { frontFoot.contents = nil; hasFront = false }
        if !peek, hasPeek { peekFoot.contents = nil; hasPeek = false }
        if !stamping { stampLayer.contents = nil }
        CATransaction.commit()
        if depth < -1 || depth > 1 { picture = nil; pictureRequested = false }
    }

    /// The front card shows where it came from; the others are dimmed and show their titles.
    /// The deck's pane frame lights the front position, so cards themselves keep a quiet edge.
    func setFront(_ front: Bool, shade amount: CGFloat, draw: Bool = true, animated: Bool) {
        if draw, !leaving { ensure(front: front) }
        ClipAnim.set(frontFoot, "opacity", Float(front ? 1 : 0), animated: animated)
        ClipAnim.set(peekFoot, "opacity", Float(front ? 0 : 1), animated: animated)
        ClipAnim.set(shade, "opacity", Float(amount), animated: animated)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        plate.borderColor = Pal.border.cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = front ? 12 : 9
        layer.shadowOffset = CGSize(width: 0, height: front ? 7 : 5)
        CATransaction.commit()
    }

    /// "COPIED" lands on the card like a rubber stamp; "GONE" (and a shake) when it couldn't be.
    func stamp(ok: Bool, animated: Bool) {
        let color = ok ? Pal.success : Pal.danger
        stampWork?.cancel()
        stamping = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stampLayer.contents = ClipFace.stamp(ok ? "COPIED" : "GONE", color: color, size: stampLayer.bounds.size, scale: scale)
        stampLayer.transform = CATransform3DMakeRotation(-0.14, 0, 0, 1)
        stampLayer.opacity = 1
        CATransaction.commit()
        if animated {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 1.9; pop.toValue = 1
            pop.mass = 1; pop.stiffness = 520; pop.damping = 24
            pop.duration = pop.settlingDuration
            stampLayer.add(pop, forKey: "pop")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.09
            stampLayer.add(fade, forKey: "fade")
            if !ok {
                let shake = CAKeyframeAnimation(keyPath: "position.x")
                shake.values = [0, -9, 8, -5, 4, 0]
                shake.isAdditive = true
                shake.duration = 0.34
                layer.add(shake, forKey: "shake")
            }
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stamping = false
            ClipAnim.set(self.stampLayer, "opacity", Float(0), animated: animated)
        }
        stampWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    /// Bytes of bitmap this card holds right now (tests and the memory budget).
    var bitmapBytes: Int {
        [plate, frontFoot, peekFoot, stampLayer].reduce(0) { sum, l in
            guard let c = l.contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID else { return sum }
            let image = c as! CGImage
            return sum + image.bytesPerRow * image.height
        }
    }

    /// A small give when there is nothing further to flip to.
    func nudge(_ direction: CGFloat) {
        let a = CAKeyframeAnimation(keyPath: "position.y")
        a.values = [0, 7 * direction, 0]
        a.isAdditive = true
        a.duration = 0.22
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "nudge")
    }
}

// MARK: - The deck

/// The stack of cards. Click the front card to copy it, a peeking one to bring it forward; scroll
/// to flip.
final class ClipDeckView: NSView {
    var onCopy: (() -> Void)?
    var onSelect: ((Int) -> Void)?
    var onStep: ((Int) -> Void)?
    /// Pixels per point for card bitmaps: the screen the picker opened on.
    var scale: CGFloat = 2

    private struct Entry { let id: UUID; let content: ClipCard.Content }
    private let stage = CALayer()
    private var geo = ClipDeckLayout(bounds: ClipDeckLayout.size)
    private var entries: [Entry] = []
    private var cards: [UUID: ClipCard] = [:]
    private var selected = 0
    private let noteID = UUID()
    private var scrolled: CGFloat = 0
    /// Decoded pictures for the cards at and next to the front; emptied when the picker closes.
    private static let pictures: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 6
        return cache
    }()
    private static let pictureQueue = DispatchQueue(label: "ai.zera.clip-deck-pictures", qos: .userInitiated)
    private var trimWork: DispatchWorkItem?
    // Signal chrome, in its own view so it draws above the cards: the pane frame at the front
    // position, the trace from the prompt into its port, the rail and a dot per waiting card.
    private let chrome = SignalLayerView(frame: .zero, flipped: true)
    private let pane = SignalPaneLayer()
    private let trace = SignalTraceLayer()
    private let rail = CAShapeLayer()
    private let dots: [CAShapeLayer] = (0..<ClipDeckLayout.peeks).map { _ in CAShapeLayer() }
    private var live = false
    private var paneWork: DispatchWorkItem?
    /// Cards still fading out after leaving the deck: more than this and the oldest go at once,
    /// so holding ↓ never piles up cards.
    private static let leavingLimit = 2

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        // Perspective for the flip: a card swinging round its top edge comes towards you.
        var t = CATransform3DIdentity
        t.m34 = -1 / 1100
        stage.sublayerTransform = t
        layer?.addSublayer(stage)
        rail.fillColor = nil
        rail.lineWidth = 1
        rail.lineCap = .round
        // Mid-grey ink rather than a white hairline: the rail sits on the bare desktop, light or dark.
        rail.strokeColor = Pal.textTertiary.withAlphaComponent(0.6).cgColor
        ([rail] + dots + [trace, pane]).forEach { chrome.layer?.addSublayer($0) }
        addSubview(chrome)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Clipboard history")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        chrome.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.frame = bounds
        [rail, trace, pane].forEach { $0.frame = bounds }
        CATransaction.commit()
        let l = ClipDeckLayout(bounds: bounds.size)
        guard l != geo || pane.rect != l.hero else { return }
        geo = l
        // Another window size: cards are drawn for one size, so deal them again.
        clear()
        apply(step: nil, animated: false)
        window?.invalidateCursorRects(for: self)
    }

    /// One line per card as it is on screen this instant, front to back as Core Animation orders
    /// them: opacity, tilt and top edge come from the presentation layers (tests).
    var cardsDescription: String {
        cards.values.sorted { $0.layer.zPosition > $1.layer.zPosition }.map { c in
            var name = "note"
            if case .item(let item) = c.content { name = item.kindName }
            let shown = c.layer.presentation() ?? c.layer
            let t = shown.transform
            let tilt = atan2(t.m23, t.m22) * 180 / .pi
            return String(format: "%@ depth %d z %.0f opacity %.2f tilt %.0f° top %.0f%@", name, c.depth, c.layer.zPosition,
                          shown.opacity, tilt, shown.position.y, c.leaving ? " leaving" : "")
        }.joined(separator: "\n")
    }

    /// The front card as it is on screen this instant: how solid, and how far tilted (tests).
    var frontOnScreen: (opacity: Float, tilt: CGFloat)? {
        guard let card = cards.values.first(where: { $0.depth == 0 && !$0.leaving }) else { return nil }
        let shown = card.layer.presentation() ?? card.layer
        return (shown.opacity, atan2(shown.transform.m23, shown.transform.m22) * 180 / .pi)
    }

    /// Bitmap bytes held by every card in the deck, on show or not.
    var bitmapBytes: Int { cards.values.reduce(0) { $0 + $1.bitmapBytes } }
    var cardCount: Int { cards.count }

    /// The cards on show, front first (tests).
    var visibleCount: Int { cards.values.filter { !$0.leaving && $0.depth >= 0 }.count }

    /// `step` is how far the selection just moved (+1: the next card), so cards travel the way
    /// they were flipped; nil when the list itself changed.
    func show(_ items: [ClipItem], selected: Int, step: Int?, animated: Bool) {
        entries = items.map { Entry(id: $0.id, content: .item($0)) }
        self.selected = max(0, min(items.count - 1, selected))
        apply(step: step, animated: animated)
    }

    func showNote(_ title: String, hint: String, animated: Bool) {
        entries = [Entry(id: noteID, content: .note(title: title, hint: hint))]
        selected = 0
        apply(step: nil, animated: animated)
    }

    func clear() {
        trimWork?.cancel()
        cards.values.forEach { $0.layer.removeFromSuperlayer() }
        cards.removeAll()
    }

    /// The picker closed: keep nothing decoded.
    func releasePictures() { Self.pictures.removeAllObjects() }

    private func remove(_ id: UUID) {
        cards[id]?.layer.removeFromSuperlayer()
        cards[id] = nil
    }

    private func scheduleTrim() {
        trimWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.cards.values.forEach { $0.trim() } }
        trimWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func apply(step: Int?, animated wantsAnimation: Bool) {
        let animated = wantsAnimation && !Motion.reduced && window != nil
        let peeks = ClipDeckLayout.peeks
        var wanted: [UUID: (depth: Int, index: Int)] = [:]
        for d in -1...peeks where entries.indices.contains(selected + d) { wanted[entries[selected + d].id] = (d, selected + d) }

        for (id, card) in cards where wanted[id] == nil && !card.leaving {
            // Already out of sight (it had flipped away): nothing to animate.
            guard animated, (card.slot?.opacity ?? 0) > 0 else { remove(id); continue }
            card.leaving = true
            card.retiredAt = CACurrentMediaTime()
            var out: ClipDeckLayout.Slot
            if let i = entries.firstIndex(where: { $0.id == id }) {
                out = geo.slot(i < selected ? -1 : peeks + 1)
            } else {
                out = card.slot ?? geo.slot(0)
                out.opacity = 0
                out.scale *= 0.95
            }
            // Above everything while it flips away, under everything while it sinks: never level
            // with the card taking its place, or its blank plate would cover that card's strip.
            place(card, out, depth: card.depth, front: false, z: out.angle != 0 ? 3 : -CGFloat(peeks + 2), animated: animated)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self, weak card] in
                guard let self = self, let card = card, card.leaving, self.cards[id] === card else { return }
                self.remove(id)
            }
        }
        let leaving = cards.filter { $0.value.leaving }.sorted { $0.value.retiredAt < $1.value.retiredAt }
        leaving.dropLast(Self.leavingLimit).forEach { remove($0.key) }

        for (id, want) in wanted {
            let content = entries[want.index].content
            let card: ClipCard
            if let c = cards[id] {
                card = c
                card.leaving = false
                card.update(content, index: want.index)
            } else {
                card = ClipCard(content, index: want.index, size: geo.card, scale: scale)
                cards[id] = card
                stage.addSublayer(card.layer)
                var start: ClipDeckLayout.Slot
                if let step {
                    start = geo.slot(max(-1, min(peeks + 1, want.depth + step)))
                } else {
                    start = geo.slot(want.depth)
                    if want.depth >= 0 { start.opacity = 0; start.scale *= 0.95 }
                }
                place(card, start, depth: want.depth, front: want.depth <= 0, animated: false)
            }
            // A cached picture goes on before the face is drawn, so the face is drawn once.
            // The card behind and the one just flipped away are ready too, so a step either way
            // never shows a picture arriving late.
            if (-1...1).contains(want.depth) { loadPicture(for: card) }
            place(card, geo.slot(want.depth), depth: want.depth, front: want.depth <= 0, animated: animated)
        }
        scheduleTrim()
        updateChrome()
        window?.invalidateCursorRects(for: self)
    }

    /// Points the trace, port, rail and dots at the deck as it now stands. Geometry and colour
    /// only; nothing here animates.
    private func updateChrome() {
        let front = entries[safe: selected]
        var tint: NSColor?
        if case .item(let item)? = front?.content { tint = ClipFace.tint(item) }
        let waiting = tint == nil ? 0 : min(ClipDeckLayout.peeks, entries.count - 1 - selected)
        paneWork?.cancel()
        pane.color = tint ?? Signal.faint
        pane.update(rect: geo.hero, side: tint == nil ? .none : .left)
        trace.color = tint ?? Signal.color
        trace.setPath(tint == nil ? nil : geo.tracePath)
        trace.isHidden = tint == nil
        trace.setRunning(live && tint != nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rail.path = geo.railPath(waiting)
        for (i, dot) in dots.enumerated() {
            let depth = i + 1
            dot.isHidden = depth > waiting
            guard depth <= waiting, case .item(let item)? = entries[safe: selected + depth]?.content else { continue }
            let c = geo.railDot(depth)
            dot.path = CGPath(ellipseIn: CGRect(x: c.x - 2.4, y: c.y - 2.4, width: 4.8, height: 4.8), transform: nil)
            dot.fillColor = ClipFace.tint(item).cgColor
        }
        CATransaction.commit()
    }

    /// The trace pulse runs only while the picker is on screen.
    func setLive(_ on: Bool) {
        live = on
        if !on { paneWork?.cancel() }
        updateChrome()
    }

    /// The picker opened: brackets close in and the pane scans once.
    func focus() {
        guard !Motion.reduced else { return }
        pane.snapBrackets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, self.live else { return }
            self.pane.sweep()
        }
    }

    private func place(_ card: ClipCard, _ s: ClipDeckLayout.Slot, depth: Int, front: Bool, z: CGFloat? = nil, animated: Bool) {
        // A card that is out of sight and staying there needs nothing drawn.
        let seen = s.opacity > 0 || (card.slot?.opacity ?? 0) > 0
        // Coming back down from where it flipped away: the forward flip run backwards. It turns
        // solid at once and swings flat without tipping past, so it reads as one card landing
        // rather than two cards showing through each other.
        let landing = (card.slot?.angle ?? 0) != 0 && s.angle == 0 && s.opacity > 0
        card.slot = s
        card.depth = depth
        var t = CATransform3DMakeScale(s.scale, s.scale, 1)
        if s.angle != 0 { t = CATransform3DRotate(t, s.angle, 1, 0, 0) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        card.layer.zPosition = z ?? (depth < 0 ? 2 : -CGFloat(depth))
        CATransaction.commit()
        ClipAnim.set(card.layer, "position", NSValue(point: s.top), animated: animated, spring: true, settle: landing)
        ClipAnim.set(card.layer, "transform", NSValue(caTransform3D: t), animated: animated, spring: true, settle: landing)
        ClipAnim.set(card.layer, "opacity", s.opacity, animated: animated, duration: landing ? 0.07 : 0.2)
        card.setFront(front, shade: s.shade, draw: seen, animated: animated)
    }

    /// Opening: the deck fans out from the front position, front card first.
    func deal() {
        guard !Motion.reduced else { return }
        var from = geo.slot(0)
        from.top.y -= 12
        from.scale = 0.93
        for card in cards.values where card.depth >= 0 {
            guard let to = card.slot else { continue }
            let delay = 0.035 * Double(card.depth)
            let move = CASpringAnimation(keyPath: "position")
            move.fromValue = NSValue(point: from.top); move.toValue = NSValue(point: to.top)
            let grow = CASpringAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(from.scale, from.scale, 1))
            grow.toValue = NSValue(caTransform3D: CATransform3DMakeScale(to.scale, to.scale, 1))
            for s in [move, grow] {
                s.mass = 1; s.stiffness = 300; s.damping = 23
                s.duration = s.settlingDuration
                s.beginTime = CACurrentMediaTime() + delay
                s.fillMode = .backwards
                card.layer.add(s, forKey: s.keyPath)
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = to.opacity
            fade.duration = 0.14
            fade.beginTime = CACurrentMediaTime() + delay
            fade.fillMode = .backwards
            card.layer.add(fade, forKey: "opacity")
        }
    }

    /// Copied: the stamp lands, and the pane turns green (red if it couldn't be) and scans once.
    func stamp(ok: Bool) {
        cards.values.first { $0.depth == 0 && !$0.leaving }?.stamp(ok: ok, animated: !Motion.reduced)
        paneWork?.cancel()
        let color = ok ? Pal.success : Pal.danger
        pane.color = color
        trace.color = color
        if ok { pane.sweep() }
        let work = DispatchWorkItem { [weak self] in self?.updateChrome() }
        paneWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    func nudge(_ direction: Int) {
        guard !Motion.reduced else { return }
        cards.values.first { $0.depth == 0 && !$0.leaving }?.nudge(CGFloat(direction))
    }

    // MARK: Pictures

    /// Copied images and single media files cover their card. Decoded off the main thread at
    /// the card's own size, only for the front card and the one either side of it.
    private func loadPicture(for card: ClipCard) {
        guard card.picture == nil, !card.pictureRequested, case .item(let item) = card.content else { return }
        let url: URL?, viaQuickLook: Bool
        if item.kind == .image { url = ClipboardStore.shared.imageURL(item); viaQuickLook = false }
        else { url = item.mediaFile; viaQuickLook = true }
        guard let url else { return }
        let key = url.path as NSString
        if let cached = Self.pictures.object(forKey: key) { card.setPicture(cached); return }
        card.pictureRequested = true
        let done: (NSImage?) -> Void = { [weak card] image in
            DispatchQueue.main.async {
                guard let card, card.pictureRequested, let image else { return }
                Self.pictures.setObject(image, forKey: key)
                card.setPicture(image)
            }
        }
        if viaQuickLook {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: geo.card, scale: scale, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in done(rep?.nsImage) }
        } else {
            let pixels = max(geo.card.width, geo.card.height) * scale
            Self.pictureQueue.async {
                let image: NSImage? = autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: pixels,
                            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
                done(image)
            }
        }
    }

    // MARK: Pointer

    private func depth(at p: NSPoint) -> Int? {
        if geo.hero.contains(p) { return 0 }
        return (1...ClipDeckLayout.peeks).first { geo.visibleRect($0).contains(p) && entries.indices.contains(selected + $0) }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let d = depth(at: convert(event.locationInWindow, from: nil)) else { return }
        if d == 0 { onCopy?() } else { onSelect?(selected + d) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else {
            if event.scrollingDeltaY != 0 { onStep?(event.scrollingDeltaY < 0 ? 1 : -1) }
            return
        }
        if event.phase == .began { scrolled = 0 }
        scrolled += event.scrollingDeltaY
        if abs(scrolled) >= 28 {
            onStep?(scrolled < 0 ? 1 : -1)
            scrolled = 0
        }
    }

    override func resetCursorRects() {
        guard !entries.isEmpty else { return }
        addCursorRect(geo.hero, cursor: .pointingHand)
        for d in 1...ClipDeckLayout.peeks where entries.indices.contains(selected + d) {
            addCursorRect(geo.visibleRect(d), cursor: .pointingHand)
        }
    }

    override func accessibilityPerformPress() -> Bool { onCopy?(); return true }
}

// MARK: - The prompt

/// A small squared button in the prompt: a word (the filter) or a glyph (open the full Clipboard).
final class ClipChipButton: NSView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var symbol: String? { didSet { needsDisplay = true } }
    /// Lit in the signal colour: a filter other than All is on.
    var lit = false { didSet { if lit != oldValue { needsDisplay = true } } }
    var onPress: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(label: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.s, yRadius: Radius.s)
        let on = lit || hovered
        (on ? p.accent.withAlphaComponent(hovered ? 0.14 : 0.08) : NSColor(white: 1, alpha: 0.04)).setFill(); path.fill()
        (on ? p.accent.withAlphaComponent(0.45) : NSColor(white: 1, alpha: 0.14)).setStroke(); path.lineWidth = 1; path.stroke()
        let ink = lit ? p.accent : (hovered ? p.text : p.textSecondary)
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .bold).applying(.init(paletteColors: [ink]))) {
            let s = img.size
            img.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let a: [NSAttributedString.Key: Any] = [.font: ZFont.mono(ofSize: 9.5, weight: .semibold), .foregroundColor: ink, .kern: 0.9]
            let s = (title as NSString).size(withAttributes: a)
            (title as NSString).draw(at: NSPoint(x: bounds.midX - s.width / 2 + 0.5, y: bounds.midY - s.height / 2), withAttributes: a)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetHoverTracking()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The search prompt: Signal's input block (wash, hairline, corner brackets, the lit ›) on a solid
/// backing, because the picker has no window glass behind it. Type and the deck narrows.
final class ClipPromptView: NSView {
    let field = NSTextField()
    let filterButton = ClipChipButton(label: "Show: all, text, images, files or pinned")
    let openButton = ClipChipButton(label: "Open full Clipboard")
    private let block = SignalInputView()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.5)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        self.shadow = shadow

        block.caret = true
        block.radius = 8
        addSubview(block)

        let cell = PaddedTextCell(textCell: "")
        cell.padding = 0
        cell.isEditable = true; cell.isSelectable = true; cell.isScrollable = true; cell.wraps = false
        cell.placeholderAttributedString = NSAttributedString(string: "search clips…", attributes: [
            .foregroundColor: Pal.textTertiary, .font: Typo.bodyMedium])
        field.cell = cell
        field.font = Typo.bodyMedium
        field.textColor = Pal.text
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.focusRingType = .none
        field.setAccessibilityLabel("Search clipboard history")
        addSubview(field)

        openButton.symbol = "arrow.up.right"
        addSubview(filterButton)
        addSubview(openButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, mid = bounds.midY
        block.frame = bounds
        openButton.frame = NSRect(x: w - 9 - 24, y: mid - 10, width: 24, height: 20)
        filterButton.frame = NSRect(x: openButton.frame.minX - 6 - 56, y: mid - 10, width: 56, height: 20)
        field.frame = NSRect(x: 30, y: mid - 9, width: max(0, filterButton.frame.minX - 8 - 30), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let backing = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Pal.cardBottom.withAlphaComponent(1).setFill()
        backing.fill()
    }
}

// MARK: - The status line

/// The line under the deck, as under every Signal pane: the live dot, where you are in the deck
/// and the filter on the left, key caps on the right. Never takes a click.
final class ClipStatusView: NSView {
    var counter = "" { didSet { if counter != oldValue { needsDisplay = true } } }
    var filter = "" { didSet { if filter != oldValue { needsDisplay = true } } }
    /// A short word about what just happened ("copied"), in place of the filter.
    var said = "" { didSet { if said != oldValue { needsDisplay = true } } }
    var hints: [(key: String, label: String)] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.m, yRadius: Radius.m)
        p.cardBottom.withAlphaComponent(1).setFill(); box.fill()
        p.border.setStroke(); box.lineWidth = 1; box.stroke()

        let mid = bounds.midY
        SignalDraw.dot(at: NSPoint(x: 13, y: mid), color: Signal.color, radius: 2.5, ring: true)
        var x: CGFloat = 24
        func put(_ s: NSAttributedString) {
            let size = s.size()
            s.draw(at: NSPoint(x: x, y: mid - size.height / 2))
            x += ceil(size.width) + 10
        }
        put(SignalDraw.label("clip", count: counter.isEmpty ? nil : counter))
        if !said.isEmpty { put(SignalDraw.label(said, color: p.success)) }
        else if !filter.isEmpty { put(SignalDraw.label(filter)) }

        // Key caps from the right; the last ones give way when the line is short.
        let keyFont = ZFont.mono(ofSize: 10, weight: .medium)
        let quiet: [NSAttributedString.Key: Any] = [.font: keyFont, .foregroundColor: Signal.faint, .kern: 0.5]
        func width(_ h: (key: String, label: String)) -> CGFloat {
            ceil((h.key as NSString).size(withAttributes: [.font: keyFont]).width) + 10
                + (h.label.isEmpty ? 0 : 6 + ceil((h.label as NSString).size(withAttributes: quiet).width)) + 12
        }
        var shown = hints
        while !shown.isEmpty, x + shown.reduce(0, { $0 + width($1) }) > bounds.width - 2 { shown.removeLast() }
        var r = bounds.width - 10 + 12
        for h in shown.reversed() {
            r -= 12
            if !h.label.isEmpty {
                let label = NSAttributedString(string: h.label, attributes: quiet)
                let size = label.size()
                r -= ceil(size.width)
                label.draw(at: NSPoint(x: r, y: mid - size.height / 2))
                r -= 6
            }
            let keyW = ceil((h.key as NSString).size(withAttributes: [.font: keyFont]).width) + 10
            r -= keyW
            SignalDraw.keycap(h.key, at: NSPoint(x: r, y: mid - 8))
        }
    }
}
