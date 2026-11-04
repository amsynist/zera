import XCTest
import AppKit
@testable import AndropKit

final class AnimationTests: XCTestCase {
    func testRetargetingKeepsPulseClockAndReducedMotionStopsIt() {
        let verify = {
            let view = ArrivalGlowView(frame: NSRect(x: 0, y: 0, width: 3840, height: 2160))
            let start = Date()
            view.configure(edge: .right, coordinate: 0.25, intensity: 1, start: start, committed: false, reducedMotion: false)
            func animatedLayers(_ layer: CALayer) -> [CALayer] {
                ([layer] + (layer.sublayers ?? []).flatMap(animatedLayers)).filter { !($0.animationKeys() ?? []).isEmpty }
            }
            let running = animatedLayers(view.layer!)
            XCTAssertFalse(running.isEmpty)
            let clocks = running.map { $0.animation(forKey: "wave")?.beginTime }
            // Moving the source point must not restart every wave on each input packet.
            view.configure(edge: .right, coordinate: 0.75, intensity: 0.8, start: start, committed: false, reducedMotion: false)
            XCTAssertEqual(running.map { $0.animation(forKey: "wave")?.beginTime }, clocks)
            view.configure(edge: .top, coordinate: 0.4, intensity: 1, start: Date(), committed: true, reducedMotion: true)
            XCTAssertTrue(animatedLayers(view.layer!).isEmpty)
            view.configure(edge: .left, coordinate: 0.6, intensity: 1, start: Date(), committed: true, reducedMotion: false)
            XCTAssertFalse(animatedLayers(view.layer!).isEmpty)
            view.stop()
            XCTAssertTrue(animatedLayers(view.layer!).isEmpty)
        }
        if Thread.isMainThread { verify() } else { DispatchQueue.main.sync(execute: verify) }
    }
}
