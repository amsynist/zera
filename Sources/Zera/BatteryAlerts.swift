import AppKit
import IOKit.ps

/// Pops a banner when the battery runs low (once when it crosses your mark, once more at 10 %,
/// reset when you plug in) and, if you ask for it, when the battery's health drops below a mark.
/// Listens to macOS's power-source notifications rather than polling.
@MainActor
final class BatteryAlerts {
    static let shared = BatteryAlerts()

    // MARK: Settings

    private let defaults = UserDefaults.standard
    private enum Key {
        static let low = "zera.battery.lowAlerts"
        static let lowAt = "zera.battery.lowThreshold"
        static let health = "zera.battery.healthAlerts"
        static let healthAt = "zera.battery.healthThreshold"
        static let healthWarned = "zera.battery.healthWarnedAt"
    }

    nonisolated static let lowChoices = [10, 15, 20, 25, 30]
    nonisolated static let healthChoices = [90, 85, 80, 75, 70]
    /// The second, last warning.
    nonisolated static let critical = 10

    var lowEnabled: Bool {
        get { defaults.object(forKey: Key.low) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.low); check() }
    }
    var lowThreshold: Int {
        get { defaults.object(forKey: Key.lowAt) as? Int ?? 20 }
        set { defaults.set(newValue, forKey: Key.lowAt); warnedLow = false; warnedCritical = false; check() }
    }
    var healthEnabled: Bool {
        get { defaults.bool(forKey: Key.health) }
        set { defaults.set(newValue, forKey: Key.health); if newValue { defaults.removeObject(forKey: Key.healthWarned) }; check() }
    }
    var healthThreshold: Int {
        get { defaults.object(forKey: Key.healthAt) as? Int ?? 80 }
        set { defaults.set(newValue, forKey: Key.healthAt); defaults.removeObject(forKey: Key.healthWarned); check() }
    }

    /// This Mac has a battery to watch.
    var hasBattery: Bool { SystemVitals.readBattery() != nil }

    // MARK: Watching

    private var source: CFRunLoopSource?
    /// This discharge has had its warning (and its last one); plugging in resets both.
    private var warnedLow = false
    private var warnedCritical = false

    func start() {
        guard source == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            // Delivered on the main run loop, where the source was added.
            MainActor.assumeIsolated { Unmanaged<BatteryAlerts>.fromOpaque(ctx).takeUnretainedValue().check() }
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        source = src
        check()
    }

    /// Looks at the battery now and raises a banner if one is due.
    func check() {
        guard let b = SystemVitals.readBattery() else { return }
        if let alert = Self.lowAlert(b, threshold: lowThreshold, enabled: lowEnabled, warned: &warnedLow, warnedCritical: &warnedCritical) {
            ReminderService.shared.raiseNow(alert)
        }
        if healthEnabled, let h = b.health {
            let pct = Int((h * 100).rounded())
            let last = defaults.object(forKey: Key.healthWarned) as? Int
            // Once below the mark, and again only if it falls a few more points.
            if pct < healthThreshold, last == nil || pct <= last! - 3 {
                defaults.set(pct, forKey: Key.healthWarned)
                ReminderService.shared.raiseNow(Self.healthAlert(health: pct, threshold: healthThreshold, cycles: b.cycles))
            }
        }
    }

    /// The low-battery banner due for `b`, if any. Pure, for tests: `warned` / `warnedCritical`
    /// carry this discharge's history and are reset once the Mac is on power again.
    nonisolated static func lowAlert(_ b: VitalsSample.Battery, threshold: Int, enabled: Bool, warned: inout Bool, warnedCritical: inout Bool) -> ReminderAlert? {
        if b.onPower || b.charging || b.percent > threshold + 3 {
            if b.onPower || b.charging { warned = false; warnedCritical = false }
            return nil
        }
        guard enabled else { return nil }
        let left = b.toEmpty.map { "About \(VitalsFormat.minutes($0)) left" } ?? "Running on battery"
        if b.percent <= critical, threshold > critical, !warnedCritical {
            warned = true; warnedCritical = true
            return ReminderAlert(id: "battery-critical-\(Int(Date().timeIntervalSince1970))", kind: .battery,
                                 headline: "Battery at \(b.percent)% — plug in now", detail: "\(left) · your Mac will sleep soon")
        }
        if b.percent <= threshold, !warned {
            warned = true
            if b.percent <= critical { warnedCritical = true }
            return ReminderAlert(id: "battery-low-\(Int(Date().timeIntervalSince1970))", kind: .battery,
                                 headline: "Battery at \(b.percent)%", detail: "\(left) · time to find a charger")
        }
        return nil
    }

    nonisolated static func healthAlert(health: Int, threshold: Int, cycles: Int?) -> ReminderAlert {
        let c = cycles.map { " · \($0) cycles" } ?? ""
        return ReminderAlert(id: "battery-health-\(health)", kind: .battery,
                             headline: "Battery health is \(health)%",
                             detail: "Below your \(threshold)% mark\(c) — it may be time for a service check")
    }
}
