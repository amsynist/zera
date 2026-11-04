import XCTest
@testable import Zera

final class GlowFalloffTests: XCTestCase {
    func testOpticalShoulderFadesContinuouslyToTransparent() {
        let samples = (0...1000).map { GlowStrip.opticalFalloff(CGFloat($0) / 1000) }
        XCTAssertEqual(samples.first, 1)
        XCTAssertEqual(samples.last, 0)
        XCTAssertEqual(samples, samples.sorted(by: >))
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThan(abs(a - b), 0.01, "No hard bands in the shoulder or tail")
        }
        XCTAssertGreaterThan(GlowStrip.opticalFalloff(0.2), 0.5)
        XCTAssertLessThan(GlowStrip.opticalFalloff(0.8), 0.02)
    }
}
