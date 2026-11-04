import AppKit

protocol ZeraAnimating: AnyObject { func advanceAnimation(at now: TimeInterval) }

/// One clock for all visible mascots. Weak membership never retains a screen or window.
final class ZeraAnimationClock {
    static let shared = ZeraAnimationClock()
    private let views = NSHashTable<NSView>.weakObjects()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    func add(_ view: NSView) { views.add(view); refresh() }
    func remove(_ view: NSView) { views.remove(view); refresh() }
    func refresh() {
        let active = views.allObjects.contains(where: Self.isActive)
        let interval: TimeInterval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 1 / 30.0
        if let timer, abs(timer.timeInterval - interval) > 0.001 { timer.invalidate(); self.timer = nil }
        if !active { timer?.invalidate(); timer = nil }
        else if timer == nil {
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 1 / 120.0; RunLoop.main.add(t, forMode: .common); timer = t
        }
    }
    private static func isActive(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        return window.isVisible && window.alphaValue > 0.02 && window.occlusionState.contains(.visible) && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty && view.alphaValue > 0.02
    }
    private func tick() {
        let now = CACurrentMediaTime()
        var active = false
        for view in views.allObjects where Self.isActive(view) {
            active = true; (view as? ZeraAnimating)?.advanceAnimation(at: now)
        }
        if !active { timer?.invalidate(); timer = nil }
    }
}
