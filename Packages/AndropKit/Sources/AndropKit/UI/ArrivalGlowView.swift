import AppKit
import QuartzCore
import SwiftUI

/// Fixed-size textures + compositor transforms. No frame timer, live blur, or giant ring surfaces.
struct ArrivalRippleView: NSViewRepresentable {
    let edge: EdgePosition
    let coordinate: CGFloat
    let intensity: CGFloat
    let start: Date
    let committed: Bool
    let reducedMotion: Bool

    func makeNSView(context: Context) -> ArrivalGlowView { ArrivalGlowView() }
    func updateNSView(_ view: ArrivalGlowView, context: Context) {
        view.configure(edge: edge, coordinate: coordinate, intensity: intensity,
                       start: start, committed: committed, reducedMotion: reducedMotion)
    }
    static func dismantleNSView(_ view: ArrivalGlowView, coordinator: ()) { view.stop() }
}

final class ArrivalGlowView: NSView {
    override var isFlipped: Bool { true }
    private let light = CALayer()
    private let aura = CALayer()
    private let waves = [CALayer(), CALayer()]
    private let seam = CAGradientLayer()
    private let border = CAShapeLayer()
    private let edges = (0..<4).map { _ in CAGradientLayer() }
    private var edge: EdgePosition = .right
    private var coordinate: CGFloat = 0.5
    private var start = Date.distantPast
    private var committed = false
    private var reducedMotion = false
    private var laidOutSize = CGSize.zero
    private var origin: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.isGeometryFlipped = true
        root.masksToBounds = true
        root.addSublayer(light)
        for (index, glow) in edges.enumerated() {
            let color = index == 0 || index == 3 ? Self.ice : Self.iris
            glow.colors = [color.copy(alpha: 0.32)!, color.copy(alpha: 0)!]
            switch index {
            case 0: glow.startPoint = CGPoint(x: 0.5, y: 0); glow.endPoint = CGPoint(x: 0.5, y: 1)
            case 1: glow.startPoint = CGPoint(x: 0, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 0.5)
            case 2: glow.startPoint = CGPoint(x: 0.5, y: 1); glow.endPoint = CGPoint(x: 0.5, y: 0)
            default: glow.startPoint = CGPoint(x: 1, y: 0.5); glow.endPoint = CGPoint(x: 0, y: 0.5)
            }
            light.addSublayer(glow)
        }
        border.fillColor = nil
        border.strokeColor = Self.ice.copy(alpha: 0.55)
        border.lineWidth = 1.2
        light.addSublayer(border)
        aura.contents = Self.auraTexture
        aura.contentsGravity = .resize
        aura.opacity = 0.8
        light.addSublayer(aura)
        for wave in waves {
            wave.contents = Self.waveTexture
            wave.bounds = CGRect(x: 0, y: 0, width: 512, height: 512)
            wave.opacity = 0
            light.addSublayer(wave)
        }
        seam.colors = [Self.ice.copy(alpha: 0)!, Self.iris, Self.ice,
                       CGColor(gray: 1, alpha: 0.85), Self.ice, Self.ice.copy(alpha: 0)!]
        light.addSublayer(seam)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(edge: EdgePosition, coordinate: CGFloat, intensity: CGFloat,
                   start: Date, committed: Bool, reducedMotion: Bool) {
        let changedPulse = self.start != start || self.committed != committed || self.reducedMotion != reducedMotion
        self.edge = edge
        self.coordinate = coordinate
        self.start = start
        self.committed = committed
        self.reducedMotion = reducedMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.opacity = Float(max(0, min(1, intensity)))
        let changedSize = placeLayers()
        if changedPulse || changedSize { animatePulse() }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if placeLayers() { animatePulse() }
        CATransaction.commit()
    }

    @discardableResult private func placeLayers() -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let changed = laidOutSize != bounds.size
        if changed {
            laidOutSize = bounds.size
            light.frame = bounds
            edges[0].frame = CGRect(x: 0, y: 0, width: bounds.width, height: 100)
            edges[1].frame = CGRect(x: 0, y: 0, width: 110, height: bounds.height)
            edges[2].frame = CGRect(x: 0, y: bounds.height - 100, width: bounds.width, height: 100)
            edges[3].frame = CGRect(x: bounds.width - 110, y: 0, width: 110, height: bounds.height)
            border.frame = bounds
            border.path = CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), cornerWidth: 20, cornerHeight: 20, transform: nil)
            let diameter = max(bounds.width, bounds.height) * 1.8
            aura.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        }
        let point = EdgeGeometry.origin(edge: edge, coordinate: coordinate, size: bounds.size)
        if changed || origin != point {
            origin = point
            aura.position = point
            for wave in waves { wave.position = point }
            let horizontal = edge == .top || edge == .bottom
            let length = (horizontal ? bounds.width : bounds.height) * 0.75
            seam.bounds = CGRect(x: 0, y: 0, width: horizontal ? length : 3, height: horizontal ? 3 : length)
            seam.position = point
            seam.startPoint = horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
            seam.endPoint = horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        }
        return changed
    }

    private func animatePulse() {
        guard laidOutSize.width > 0 else { return }
        stop()
        guard !reducedMotion else { return }
        let elapsed = max(0, Date().timeIntervalSince(start))
        let clock = light.convertTime(CACurrentMediaTime(), from: nil)
        let scale = hypot(laidOutSize.width, laidOutSize.height) * 2.2 / 512
        for (index, wave) in waves.enumerated() {
            let expansion = CABasicAnimation(keyPath: "transform.scale")
            expansion.fromValue = 0.12
            expansion.toValue = scale
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.55, 0.18, 0]
            fade.keyTimes = [0, 0.16, 0.65, 1]
            let group = CAAnimationGroup()
            group.animations = [expansion, fade]
            group.duration = committed ? 1.65 : 3.6
            group.repeatCount = committed ? 1 : .infinity
            group.beginTime = clock - elapsed + Double(index) * (committed ? 0.18 : 1.8)
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wave.add(group, forKey: "wave")
        }
    }

    func stop() { waves.forEach { $0.removeAllAnimations() } }

    private static let ice = CGColor(srgbRed: 0.48, green: 0.94, blue: 0.97, alpha: 1)
    private static let iris = CGColor(srgbRed: 0.68, green: 0.48, blue: 1, alpha: 1)
    // Generated once per process, shared by every arrival. Texture memory is independent of display size.
    static let auraTexture = texture(size: 256,
        colors: [CGColor(gray: 1, alpha: 0.1), ice.copy(alpha: 0.35)!, iris.copy(alpha: 0.15)!, ice.copy(alpha: 0)!],
        locations: [0, 0.18, 0.55, 1])
    static let waveTexture = texture(size: 512,
        colors: [ice.copy(alpha: 0)!, ice.copy(alpha: 0)!, ice.copy(alpha: 0.16)!, CGColor(gray: 1, alpha: 0.5), iris.copy(alpha: 0.12)!, ice.copy(alpha: 0)!],
        locations: [0, 0.84, 0.93, 0.965, 0.985, 1])

    private static func texture(size: Int, colors: [CGColor], locations: [CGFloat]) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
        let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                  endCenter: center, endRadius: CGFloat(size) / 2, options: [])
        return context.makeImage()!
    }
}
