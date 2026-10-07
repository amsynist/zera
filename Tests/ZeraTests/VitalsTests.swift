import AppKit
import XCTest
@testable import Zera

final class VitalsTests: XCTestCase {
    /// Two readings a second apart: every core reports, memory and uptime are real numbers.
    @MainActor
    func testReadsThisMac() {
        let v = SystemVitals.shared
        v.watch()
        defer { v.unwatch() }
        RunLoop.main.run(until: Date().addingTimeInterval(2.4))
        let s = v.now
        XCTAssertFalse(s.cores.isEmpty)
        XCTAssertTrue(s.cores.allSatisfy { (0...1).contains($0) })
        XCTAssertTrue((0...1).contains(s.cpu))
        XCTAssertGreaterThan(s.memTotal, 1_000_000_000)
        XCTAssertGreaterThan(s.memUsed, 0)
        XCTAssertLessThanOrEqual(s.memUsed, s.memTotal * 1.05)
        XCTAssertGreaterThan(s.uptime, 0)
        XCTAssertGreaterThanOrEqual(s.down, 0)
        if let g = s.gpu { XCTAssertTrue((0...1).contains(g)) }
        if let b = s.battery { XCTAssertTrue((0...100).contains(b.percent)) }
        XCTAssertEqual(v.cpuHistory.count, SystemVitals.historyLength)
        print("vitals: cpu \(Int(s.cpu * 100))% cores \(s.cores.count) mem \(VitalsFormat.gb(s.memUsed))/\(VitalsFormat.gb(s.memTotal)) gpu \(s.gpu.map { "\(Int($0 * 100))%" } ?? "nil") down \(VitalsFormat.rate(s.down)) wifi \(s.wifiLink ?? -1) battery \(String(describing: s.battery))")
    }

    func testFormats() {
        XCTAssertEqual(VitalsFormat.rate(84_200_000).0, "84.2")
        XCTAssertEqual(VitalsFormat.rate(412_000_000).0, "412")
        XCTAssertEqual(VitalsFormat.rate(1_250_000_000).1, "Gb/s")
        XCTAssertEqual(VitalsFormat.rate(640_000).1, "Kb/s")
        XCTAssertEqual(VitalsFormat.duration(3 * 86400 + 4 * 3600 + 120), "3d 4h")
        XCTAssertEqual(VitalsFormat.duration(5 * 3600 + 12 * 60), "5h 12m")
        XCTAssertEqual(VitalsFormat.minutes(48), "48m")
    }
}
