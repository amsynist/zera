import AppKit

/// Where the notch is — or where we pretend it is on a Mac without one.
struct NotchGeometry {
    /// The black notch, command feedback and halo all use this one shoulder geometry.
    /// Coordinates are unflipped. The rectangle includes the two outward shoulders.
    static func shoulderWidth(height: CGFloat) -> CGFloat { min(14, max(6, height * 0.34)) }

    static func notchOutline(in rect: CGRect, arms: CGFloat = 0, closed: Bool = false, edges: ClosedRange<CGFloat>? = nil) -> CGPath {
        let shoulder = min(shoulderWidth(height: rect.height), rect.width / 4)
        let radius = min(8, rect.height * 0.23, rect.width / 4)
        let drop = min(rect.height - radius, shoulder * 1.45)
        let left = rect.minX + shoulder, right = rect.maxX - shoulder
        let top = rect.maxY, bottom = rect.minY
        let p = CGMutablePath()
        p.move(to: CGPoint(x: edges?.lowerBound ?? rect.minX - arms, y: top))
        p.addLine(to: CGPoint(x: rect.minX, y: top))
        p.addCurve(to: CGPoint(x: left, y: top - drop),
                   control1: CGPoint(x: left, y: top), control2: CGPoint(x: left, y: top - drop * 0.28))
        p.addLine(to: CGPoint(x: left, y: bottom + radius))
        p.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
        p.addLine(to: CGPoint(x: right - radius, y: bottom))
        p.addQuadCurve(to: CGPoint(x: right, y: bottom + radius), control: CGPoint(x: right, y: bottom))
        p.addLine(to: CGPoint(x: right, y: top - drop))
        p.addCurve(to: CGPoint(x: rect.maxX, y: top),
                   control1: CGPoint(x: right, y: top - drop * 0.28), control2: CGPoint(x: right, y: top))
        p.addLine(to: CGPoint(x: edges?.upperBound ?? rect.maxX + arms, y: top))
        if closed { p.closeSubpath() }
        return p
    }

    /// Full edge flow joins the notch instead of crossing it as a separate straight strip.
    static func topLightPath(bounds: CGRect, notch: CGRect, withArms: Bool = true) -> CGPath {
        let rect = CGRect(x: notch.minX, y: bounds.maxY - 0.75 - notch.height,
                          width: notch.width, height: notch.height)
        return notchOutline(in: rect, edges: withArms ? bounds.minX...bounds.maxX : nil)
    }
    let screen: NSScreen
    /// The notch area in screen coordinates. On a notchless Mac it is a slice of the menu bar
    /// at the top centre, the same height as the menu bar.
    let notchRect: NSRect
    let isReal: Bool

    /// Event feedback stays on its chosen display, including screens with negative origins
    /// and a virtual notch. This also bounds the HUD after resolution/menu-bar changes.
    static func feedbackFrame(screen: NSRect, notch: NSRect, maxWidth: CGFloat = 760, glowRoom: CGFloat = 16) -> NSRect {
        let width = min(maxWidth, max(0, screen.width))
        let height = min(screen.height, max(0, notch.height) + glowRoom)
        let x = min(screen.maxX - width, max(screen.minX, notch.midX - width / 2))
        return NSRect(x: x.rounded(), y: screen.maxY - height, width: width, height: height)
    }

    /// Prefers the built-in display with a notch; otherwise the main screen.
    static func detect() -> NotchGeometry {
        let screens = NSScreen.screens
        let notched = screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notched ?? NSScreen.main ?? screens.first else {
            preconditionFailure("Zera needs a screen to sit on")
        }
        let f = screen.frame
        if let s = notched, let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            let h = s.safeAreaInsets.top
            let rect = NSRect(x: left.maxX, y: f.maxY - h, width: right.minX - left.maxX, height: h)
            return NotchGeometry(screen: s, notchRect: rect, isReal: true)
        }
        var menuH = f.maxY - screen.visibleFrame.maxY
        if menuH <= 0 { menuH = NSStatusBar.system.thickness }
        let w = Theme.virtualNotchWidth
        let rect = NSRect(x: f.midX - w / 2, y: f.maxY - menuH, width: w, height: menuH)
        return NotchGeometry(screen: screen, notchRect: rect, isReal: false)
    }

    /// Frame for her window centred on `centerX`: it reaches up through the notch (or the
    /// menu bar on a Mac without one) so the rope can run into it, and down far enough for her
    /// to dangle.
    func buddyPanelFrame(centerX: CGFloat) -> NSRect {
        // Reach all the way to the top of the screen (monitor edge) so the rope draws over the menubar
        let up: CGFloat = notchRect.height
        return NSRect(x: centerX - Theme.buddyWidth / 2,
                      y: notchRect.minY - Theme.figureHeight - Theme.figurePad,
                      width: Theme.buddyWidth,
                      height: up + Theme.figureHeight + Theme.figurePad)
    }

    /// Points of the window hidden by the menubar/notch (applied universally so the character tucks properly)
    var hangInset: CGFloat { max(0, notchRect.height - Theme.topTuck) }

    /// Where she actually is on screen (below the menu bar), for hover tests and layout.
    func figureRect(centerX: CGFloat) -> NSRect {
        NSRect(x: centerX - 32, y: notchRect.minY - Theme.figureHeight, width: 64, height: Theme.figureHeight)
    }

    /// Clamp a requested centre so she never leaves the screen.
    func clampedCenterX(_ x: CGFloat) -> CGFloat {
        let f = screen.frame
        return max(f.minX + 30, min(f.maxX - 30, x))
    }
}
