import AppKit
import CoreWLAN
import Darwin
import IOKit
import IOKit.ps

/// One reading of this Mac: processor, memory, graphics, network and battery.
struct VitalsSample: Equatable {
    /// 0…1 per core, and their average.
    var cores: [Double] = []
    var cpu: Double = 0
    var load: Double = 0
    /// Bytes.
    var memApps: Double = 0, memWired: Double = 0, memCompressed: Double = 0, memTotal: Double = 0
    var memUsed: Double { memApps + memWired + memCompressed }
    enum Pressure: Equatable { case normal, warning, critical }
    var pressure: Pressure = .normal
    /// 0…1; nil when the graphics driver doesn't say.
    var gpu: Double?
    /// Bits per second across the Mac's network interfaces.
    var down: Double = 0, up: Double = 0
    /// Wi-Fi's link rate in Mb/s, nil when Wi-Fi is off or not in use.
    var wifiLink: Double?
    var battery: Battery?
    var uptime: TimeInterval = 0

    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
        var onPower: Bool
        /// Minutes; nil while macOS is still working it out.
        var toEmpty: Int?
        var toFull: Int?
        /// Full-charge capacity against design capacity, 0…1.
        var health: Double?
        var cycles: Int?
        /// Watts flowing in or out.
        var watts: Double?
    }
}

/// Samples the Mac once a second, but only while something on screen shows it (`watch`).
/// Readings are taken off the main thread and handed back on it; `changed` is posted each time.
final class SystemVitals {
    static let shared = SystemVitals()
    nonisolated static let changed = Notification.Name("ZeraVitalsChanged")
    nonisolated static let speedChanged = Notification.Name("ZeraVitalsSpeedChanged")

    /// The newest reading, and the last minute of a few of its numbers (oldest first).
    private(set) var now = VitalsSample()
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var downHistory: [Double] = []
    private(set) var upHistory: [Double] = []
    static let historyLength = 60

    private var watchers = 0
    private var timer: Timer?
    private let queue = DispatchQueue(label: "ai.zera.vitals", qos: .utility)
    private var sampler = Sampler()

    /// Something started showing vitals; sampling runs while anyone watches.
    func watch() {
        watchers += 1
        guard timer == nil, !simulating else { return }
        sampleSoon()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sampleSoon() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0, !simulating else { return }
        timer?.invalidate()
        timer = nil
    }

    // MARK: Simulation

    private var simulating = false
    private var simTimer: Timer?
    private var simState: UInt64 = 0x9E3779B97F4A7C15

    /// Made-up readings that drift like real ones, for screen renders and recordings, so they
    /// never show a real Mac's uptime, battery health or network. Replaces sampling for the
    /// rest of the process.
    func simulate() {
        guard !simulating else { return }
        simulating = true
        timer?.invalidate(); timer = nil
        var s = VitalsSample()
        s.cores = [0.34, 0.22, 0.48, 0.12, 0.08, 0.41, 0.19, 0.27]
        s.memTotal = 16 * 1_073_741_824
        s.memApps = 6.8 * 1_073_741_824; s.memWired = 2.1 * 1_073_741_824; s.memCompressed = 1.4 * 1_073_741_824
        s.gpu = 0.28; s.down = 48e6; s.up = 6.2e6; s.wifiLink = 866; s.load = 2.4
        s.battery = .init(percent: 78, charging: false, onPower: false, toEmpty: 245, health: 0.92, cycles: 143, watts: 9.8)
        s.uptime = 3 * 86400 + 4 * 3600
        func step() {
            func r() -> Double { simState = simState &* 6364136223846793005 &+ 1442695040888963407; return Double(simState >> 11) / Double(1 << 53) - 0.5 }
            func walk(_ v: Double, _ lo: Double, _ hi: Double, _ by: Double) -> Double { min(hi, max(lo, v + r() * by)) }
            s.cores = s.cores.map { walk($0, 0.03, 0.95, 0.3) }
            s.cpu = s.cores.reduce(0, +) / Double(s.cores.count)
            s.memApps = walk(s.memApps, 5.5 * 1_073_741_824, 8.5 * 1_073_741_824, 0.4 * 1_073_741_824)
            s.gpu = walk(s.gpu ?? 0.3, 0.05, 0.85, 0.25)
            s.down = walk(s.down, 4e6, 180e6, 50e6)
            s.up = walk(s.up, 1e6, 30e6, 6e6)
            let watts = walk(s.battery?.watts ?? 9, 5, 22, 3)
            s.battery?.watts = watts
            publish(s)
        }
        for _ in 0..<Self.historyLength { step() }
        let t = Timer(timeInterval: 1, repeats: true) { _ in step() }
        RunLoop.main.add(t, forMode: .common)
        simTimer = t
    }

    /// The battery right now (nil on a Mac without one). Cheap; any thread.
    static func readBattery() -> VitalsSample.Battery? { Sampler.battery() }

    private func sampleSoon() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let s = self.sampler.sample()
            DispatchQueue.main.async { self.publish(s) }
        }
    }

    /// How much of each new reading is taken in: the rest is the previous value, so a one-second
    /// spike doesn't throw the numbers around.
    private static let smoothing = 0.35

    private func publish(_ raw: VitalsSample) {
        var s = raw
        if !now.cores.isEmpty {
            let k = Self.smoothing
            func ease(_ old: Double, _ new: Double) -> Double { old + (new - old) * k }
            if now.cores.count == s.cores.count { s.cores = zip(now.cores, s.cores).map(ease) }
            s.cpu = ease(now.cpu, s.cpu)
            if let g = s.gpu, let og = now.gpu { s.gpu = ease(og, g) }
            s.down = ease(now.down, s.down)
            s.up = ease(now.up, s.up)
        }
        now = s
        func push(_ list: inout [Double], _ v: Double) {
            if list.isEmpty { list = Array(repeating: v, count: Self.historyLength) }
            list.append(v)
            if list.count > Self.historyLength { list.removeFirst(list.count - Self.historyLength) }
        }
        push(&cpuHistory, s.cpu)
        push(&gpuHistory, s.gpu ?? 0)
        push(&downHistory, s.down)
        push(&upHistory, s.up)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: Speed test

    struct SpeedResult: Codable, Equatable {
        var down: Double      // bits per second
        var up: Double
        var latency: Double?  // ms
        var at: Date
    }
    private static let speedKey = "zera.vitals.lastSpeedTest"
    private(set) var lastSpeed: SpeedResult? = {
        guard let d = UserDefaults.standard.data(forKey: SystemVitals.speedKey) else { return nil }
        return try? JSONDecoder().decode(SpeedResult.self, from: d)
    }()
    private(set) var speedTesting = false
    private(set) var speedError: String?

    /// Measures the internet connection with macOS's own `networkQuality` (about 20 seconds).
    /// Runs only when asked; nothing tests in the background.
    func runSpeedTest() {
        guard !speedTesting else { return }
        speedTesting = true
        speedError = nil
        NotificationCenter.default.post(name: Self.speedChanged, object: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.measure()
            DispatchQueue.main.async {
                self.speedTesting = false
                switch result {
                case .success(let r):
                    self.lastSpeed = r
                    if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: Self.speedKey) }
                case .failure(let e):
                    self.speedError = e.message
                }
                NotificationCenter.default.post(name: Self.speedChanged, object: nil)
            }
        }
    }

    private struct SpeedError: Error { let message: String }

    private static func measure() -> Result<SpeedResult, SpeedError> {
        let tool = URL(fileURLWithPath: "/usr/bin/networkQuality")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return .failure(SpeedError(message: "Needs macOS's networkQuality tool")) }
        let p = Process()
        p.executableURL = tool
        p.arguments = ["-c"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return .failure(SpeedError(message: "Couldn't start the test")) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dl = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let ul = (json["ul_throughput"] as? NSNumber)?.doubleValue else {
            return .failure(SpeedError(message: "No connection — try again"))
        }
        let rtt = (json["base_rtt"] as? NSNumber)?.doubleValue
        return .success(SpeedResult(down: dl, up: ul, latency: rtt, at: Date()))
    }
}

// MARK: - Reading the hardware

/// Holds the previous counters so each reading is a rate over the last second. Used from one
/// queue only.
private struct Sampler {
    private var lastTicks: [[UInt32]] = []
    private var lastBytes: (down: UInt64, up: UInt64, at: TimeInterval)?

    mutating func sample() -> VitalsSample {
        var s = VitalsSample()
        s.cores = coreUsage()
        s.cpu = s.cores.isEmpty ? 0 : s.cores.reduce(0, +) / Double(s.cores.count)
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) > 0 { s.load = loads[0] }
        memory(into: &s)
        s.gpu = Self.gpuUtilization()
        network(into: &s)
        s.wifiLink = Self.wifiLinkRate()
        s.battery = Self.battery()
        s.uptime = Self.uptime()
        return s
    }

    private mutating func coreUsage() -> [Double] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info = info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for c in 0..<Int(count) {
            ticks.append((0..<states).map { UInt32(bitPattern: info[c * states + $0]) })
        }
        defer { lastTicks = ticks }
        guard lastTicks.count == ticks.count else { return ticks.map { _ in 0 } }
        return zip(ticks, lastTicks).map { now, before in
            let d = (0..<states).map { Double(now[$0] &- before[$0]) }
            let total = d.reduce(0, +)
            guard total > 0 else { return 0 }
            return (total - d[Int(CPU_STATE_IDLE)]) / total
        }
    }

    private func memory(into s: inout VitalsSample) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        s.memTotal = Double(ProcessInfo.processInfo.physicalMemory)
        guard kr == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        s.memApps = Double(Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page
        s.memWired = Double(stats.wire_count) * page
        s.memCompressed = Double(stats.compressor_page_count) * page
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            s.pressure = level >= 4 ? .critical : (level >= 2 ? .warning : .normal)
        }
    }

    /// Bytes in and out of every network interface but loopback and tunnels, as a rate.
    private mutating func network(into s: inout VitalsSample) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return }
        var down: UInt64 = 0, up: UInt64 = 0
        var offset = 0
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        while offset + MemoryLayout<if_msghdr>.size <= len {
            let msgLen = buf.withUnsafeBytes { Int($0.load(fromByteOffset: offset, as: if_msghdr.self).ifm_msglen) }
            guard msgLen > 0 else { break }
            let type = buf.withUnsafeBytes { Int32($0.load(fromByteOffset: offset, as: if_msghdr.self).ifm_type) }
            if type == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                let m = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
                if if_indextoname(UInt32(m.ifm_index), &name) != nil {
                    let n = String(cString: name)
                    if !n.hasPrefix("lo"), !n.hasPrefix("utun"), !n.hasPrefix("gif"), !n.hasPrefix("stf"), !n.hasPrefix("awdl"), !n.hasPrefix("llw"), !n.hasPrefix("bridge") {
                        down &+= m.ifm_data.ifi_ibytes
                        up &+= m.ifm_data.ifi_obytes
                    }
                }
            }
            offset += msgLen
        }
        let t = ProcessInfo.processInfo.systemUptime
        if let last = lastBytes, t > last.at, down >= last.down, up >= last.up {
            s.down = Double(down - last.down) * 8 / (t - last.at)
            s.up = Double(up - last.up) * 8 / (t - last.at)
        }
        lastBytes = (down, up, t)
    }

    private static func gpuUtilization() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        while case let service = IOIteratorNext(it), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, u / 100)
        }
        return best.map { min(1, max(0, $0)) }
    }

    private static func wifiLinkRate() -> Double? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return nil }
        let r = i.transmitRate()
        return r > 0 ? r : nil
    }

    static func battery() -> VitalsSample.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            var b = VitalsSample.Battery(percent: Int((Double(cur) / Double(max) * 100).rounded()),
                                         charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                         onPower: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
            if let m = d[kIOPSTimeToEmptyKey] as? Int, m > 0 { b.toEmpty = m }
            if let m = d[kIOPSTimeToFullChargeKey] as? Int, m > 0 { b.toFull = m }
            smartBattery(into: &b)
            return b
        }
        return nil
    }

    /// Health, cycles and power from the battery's own controller.
    private static func smartBattery(into b: inout VitalsSample.Battery) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        b.cycles = int("CycleCount")
        // Newer macOS keeps the capacities inside "BatteryData"; older ones at the top level.
        let data = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
        func dataInt(_ key: String) -> Int? { (data?[key] as? NSNumber)?.intValue }
        let full = dataInt("NominalChargeCapacity") ?? int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity")
        let design = dataInt("DesignCapacity") ?? int("DesignCapacity")
        if let f = full, let d = design, d > 0 { b.health = min(1, Double(f) / Double(d)) }
        if let mv = int("Voltage"), let ma = int("Amperage") {
            // Amperage comes back as a signed 64-bit value; negative while discharging.
            let amps = Double(Int64(truncatingIfNeeded: ma)) / 1000
            b.watts = abs(Double(mv) / 1000 * amps)
        }
    }

    private static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }
}
