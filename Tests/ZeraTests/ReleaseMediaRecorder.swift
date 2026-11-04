import Foundation
import AppKit
import QuartzCore
import ScreenCaptureKit

/// Test-only native file recording; its caller supplies an explicit window allowlist.
@available(macOS 15.0, *)
final class ReleaseMediaRecorder: NSObject, SCRecordingOutputDelegate {
    private let lock = NSLock()
    private var start: Double?
    private var done = false
    private var error: Error?
    var startedAt: Double? { lock.withLock { start } }
    var finished: Bool { lock.withLock { done } }
    var failure: Error? { lock.withLock { error } }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { start = Date().timeIntervalSince1970 }
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { done = true }
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.withLock { self.error = error }
    }
}

/// Capture-fixture wallpaper only. It never changes the user's desktop or app preferences.
@MainActor
func installReleaseWallpaper(on view: NSView) {
    view.wantsLayer = true
    guard let root = view.layer else { return }
    root.masksToBounds = true
    let size = view.bounds.size
    func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha).cgColor
    }
    let base = CAGradientLayer()
    base.frame = view.bounds
    base.colors = [color(0.025, 0.065, 0.09), color(0.08, 0.16, 0.20), color(0.025, 0.07, 0.085)]
    base.startPoint = CGPoint(x: 0, y: 1); base.endPoint = CGPoint(x: 1, y: 0)
    root.addSublayer(base)
    let colors = [(0.24, 0.54, 0.55), (0.29, 0.38, 0.53), (0.30, 0.51, 0.43)]
    for (index, tone) in colors.enumerated() {
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [color(tone.0, tone.1, tone.2, 0.72), color(tone.0, tone.1, tone.2, 0)]
        glow.locations = [0, 1]; glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: size.width * (CGFloat(index) * 0.38 - 0.35),
                            y: size.height * (index == 1 ? 0.18 : -0.38), width: size.width, height: size.height * 1.6)
        base.addSublayer(glow)
        let drift = CABasicAnimation(keyPath: "transform.translation.x")
        drift.fromValue = -size.width * 0.12; drift.toValue = size.width * 0.12
        drift.duration = 11 + Double(index) * 2; drift.autoreverses = true; drift.repeatCount = .greatestFiniteMagnitude
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(drift, forKey: "wallpaper-drift")
    }
    for index in 0..<3 {
        let ribbon = CAGradientLayer()
        ribbon.frame = CGRect(x: -size.width * 0.15, y: 0, width: size.width * 1.3, height: size.height)
        ribbon.colors = [color(0.64, 0.78, 0.80, 0.10), color(0.32, 0.61, 0.61, 0.20), color(0.16, 0.33, 0.42, 0)]
        ribbon.startPoint = CGPoint(x: 0, y: 0); ribbon.endPoint = CGPoint(x: 1, y: 0.8)
        let shape = CAShapeLayer(), path = CGMutablePath()
        let w = ribbon.bounds.width, h = size.height, offset = CGFloat(index) * h * 0.15
        path.move(to: CGPoint(x: -w * 0.1, y: h * 0.12 + offset))
        path.addCurve(to: CGPoint(x: w * 1.1, y: h * 0.72 + offset), control1: CGPoint(x: w * 0.32, y: -h * 0.30 + offset), control2: CGPoint(x: w * 0.48, y: h * 1.15 + offset))
        path.addCurve(to: CGPoint(x: -w * 0.1, y: h * 0.23 + offset), control1: CGPoint(x: w * 0.54, y: h * 1.3 + offset), control2: CGPoint(x: w * 0.24, y: -h * 0.10 + offset))
        path.closeSubpath(); shape.path = path; ribbon.mask = shape; base.addSublayer(ribbon)
        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = -35; drift.toValue = 35; drift.duration = 9 + Double(index) * 2
        drift.autoreverses = true; drift.repeatCount = .greatestFiniteMagnitude
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); ribbon.add(drift, forKey: "wallpaper-wave")
    }
}
