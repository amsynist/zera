import AppKit

/// Where the notch is — or where we pretend it is on a Mac without one.
struct NotchGeometry {
    let screen: NSScreen
    /// The notch area in screen coordinates. On a notchless Mac it is a slice of the menu bar
    /// at the top centre, the same height as the menu bar.
    let notchRect: NSRect
    let isReal: Bool

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
                      y: notchRect.minY - Theme.figureHeight,
                      width: Theme.buddyWidth,
                      height: up + Theme.figureHeight)
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
