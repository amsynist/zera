import XCTest
@testable import Zera

final class BatteryAlertsTests: XCTestCase {
    private func battery(_ pct: Int, power: Bool = false, left: Int? = 70) -> VitalsSample.Battery {
        VitalsSample.Battery(percent: pct, charging: power, onPower: power, toEmpty: power ? nil : left)
    }

    /// One warning when it crosses the mark, a last one at 10 %, nothing in between, and a fresh
    /// start once it's been plugged in.
    func testLowBatteryWarnsOncePerDischarge() {
        var warned = false, critical = false
        func check(_ b: VitalsSample.Battery, enabled: Bool = true) -> ReminderAlert? {
            BatteryAlerts.lowAlert(b, threshold: 20, enabled: enabled, warned: &warned, warnedCritical: &critical)
        }
        XCTAssertNil(check(battery(45)))
        XCTAssertNil(check(battery(21)))
        let first = check(battery(20))
        XCTAssertEqual(first?.headline, "Battery at 20%")
        XCTAssertEqual(first?.detail, "About 1h 10m left · time to find a charger")
        XCTAssertEqual(first?.kind, .battery)
        XCTAssertNil(check(battery(18)), "only once per discharge")
        XCTAssertNil(check(battery(12)))
        XCTAssertEqual(check(battery(10))?.headline, "Battery at 10% — plug in now")
        XCTAssertNil(check(battery(8)))
        XCTAssertNil(check(battery(30, power: true)), "plugging in resets")
        XCTAssertEqual(check(battery(19))?.headline, "Battery at 19%")
    }

    func testOffOrOnPowerSaysNothing() {
        var warned = false, critical = false
        XCTAssertNil(BatteryAlerts.lowAlert(battery(5), threshold: 20, enabled: false, warned: &warned, warnedCritical: &critical))
        XCTAssertNil(BatteryAlerts.lowAlert(battery(5, power: true), threshold: 20, enabled: true, warned: &warned, warnedCritical: &critical))
    }

    func testHealthBanner() {
        let a = BatteryAlerts.healthAlert(health: 78, threshold: 80, cycles: 277)
        XCTAssertEqual(a.headline, "Battery health is 78%")
        XCTAssertEqual(a.detail, "Below your 80% mark · 277 cycles — it may be time for a service check")
    }

    /// Plugging in clears the low banner and shows a short charging one; launching on power,
    /// staying on power and running on battery don't.
    func testPluggingInClearsLowBannerAndAnnouncesCharging() {
        var plugged = battery(18, power: true); plugged.toFull = 80
        let change = BatteryAlerts.powerChange(from: false, to: plugged, bannerEnabled: true)
        XCTAssertTrue(change.clearLow)
        XCTAssertEqual(change.banner?.headline, "Charging · 18%")
        XCTAssertEqual(change.banner?.detail, "Full in about 1h 20m")
        XCTAssertTrue(change.banner.map(BatteryAlerts.isChargingAlert) ?? false)
        XCTAssertFalse(change.banner.map(BatteryAlerts.isLowAlert) ?? true)

        XCTAssertNil(BatteryAlerts.powerChange(from: nil, to: plugged, bannerEnabled: true).banner, "not at launch")
        XCTAssertNil(BatteryAlerts.powerChange(from: true, to: plugged, bannerEnabled: true).banner, "only on the change")
        XCTAssertTrue(BatteryAlerts.powerChange(from: true, to: plugged, bannerEnabled: true).clearLow)
        let off = BatteryAlerts.powerChange(from: false, to: plugged, bannerEnabled: false)
        XCTAssertTrue(off.clearLow); XCTAssertNil(off.banner)
        let unplugged = BatteryAlerts.powerChange(from: true, to: battery(18), bannerEnabled: true)
        XCTAssertFalse(unplugged.clearLow); XCTAssertNil(unplugged.banner)

        // A low warning raised while on battery is the kind that plugging in clears.
        var warned = false, critical = false
        let low = BatteryAlerts.lowAlert(battery(19), threshold: 20, enabled: true, warned: &warned, warnedCritical: &critical)
        XCTAssertTrue(low.map(BatteryAlerts.isLowAlert) ?? false)
    }
}
