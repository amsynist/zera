import AppKit

/// Settings › General › "In full-screen apps": keep Zera, or tuck her away (right away or after
/// a few seconds) while another app is full screen on her display. She comes back when you leave
/// full screen, or from the menu bar icon › Bring Zera Back.
enum FullScreenHide {
    /// Seconds before she hides; -1 keeps her showing.
    static let choices: [Int] = [-1, 0, 5, 10, 30, 60]
    static let titles = ["Keep showing Zera", "Hide right away", "Hide after 5 seconds",
                         "Hide after 10 seconds", "Hide after 30 seconds", "Hide after 1 minute"]
    private static let key = "zera.fullScreenHideAfter"

    static var delay: Int {
        get { UserDefaults.standard.object(forKey: key) as? Int ?? -1 }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static var enabled: Bool { delay >= 0 }
}

/// Tells whether the frontmost app is full screen on a given display. A full-screen window
/// covers the whole display, menu bar included; a merely maximised one stops under the menu bar.
/// Only window bounds are read (no titles, no pixels), so it needs no Screen Recording access.
final class FullScreenWatcher {
    var onChange: ((Bool) -> Void)?
    /// The display Zera lives on.
    var screen: () -> NSScreen? = { NSScreen.main }
    private(set) var isFullScreen = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.check()
                // Entering full screen animates; look again once it has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.check() }
            })
        }
        check()
    }

    deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    func check() {
        let now = Self.frontmostIsFullScreen(on: screen())
        guard now != isFullScreen else { return }
        isFullScreen = now
        onChange?(now)
    }

    static func frontmostIsFullScreen(on screen: NSScreen?) -> Bool {
        guard let screen = screen, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Window bounds are in global display space with the origin at the top left of the main display.
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let d = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: d as! CFDictionary)
            else { continue }
            if abs(r.minX - target.minX) < 1, abs(r.minY - target.minY) < 1,
               abs(r.width - target.width) < 1, abs(r.height - target.height) < 1 { return true }
        }
        return false
    }
}
