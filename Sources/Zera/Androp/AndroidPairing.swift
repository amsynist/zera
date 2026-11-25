import AppKit
import CoreImage.CIFilterBuiltins
import SystemConfiguration

struct AndroidPairing {
    let address: String
    let port: UInt16
    let code: String

    var endpoint: String { "\(address):\(port)" }
    var payload: String { "androp://pair?v=1&host=\(address)&port=\(port)&code=\(code)" }

    /// Prefer the active Wi-Fi address (including a phone hotspot). Fall back to a
    /// physical Ethernet interface, excluding loopback, VPN and VM bridges.
    static func localAddress() -> String? {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let primary = (SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryInterface"] as? String
        let candidates = interfaces.compactMap { interface -> (name: String, rank: Int)? in
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { return nil }
            if type == kSCNetworkInterfaceTypeIEEE80211 as String { return (name, 0) }
            if type == kSCNetworkInterfaceTypeEthernet as String { return (name, name == primary ? 1 : 2) }
            return nil
        }.sorted { $0.rank < $1.rank }
        var entries: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&entries) == 0, let entries else { return nil }
        defer { freeifaddrs(entries) }
        var addresses: [String: String] = [:]
        for entry in sequence(first: entries, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let address = interface.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            guard !ip.hasPrefix("169.254.") && ip != "0.0.0.0" else { continue }
            addresses[String(cString: interface.ifa_name)] = ip
        }
        return candidates.lazy.compactMap { addresses[$0.name] }.first
    }

    private static let imageContext = CIContext()

    /// Theme-colored modules with a light, opaque four-module quiet zone and integer scaling.
    func image(accent: NSColor) -> NSImage? {
        let qr = CIFilter.qrCodeGenerator()
        qr.message = Data(payload.utf8)
        qr.correctionLevel = "M"
        guard let raw = qr.outputImage else { return nil }
        let ink = NSColor(srgbRed: 0.025, green: 0.05, blue: 0.065, alpha: 1)
        let tint = accent.usingColorSpace(.sRGB) ?? .systemTeal
        let paper = NSColor.white.blended(withFraction: 0.30, of: tint) ?? .white
        let colors = CIFilter.falseColor()
        colors.inputImage = raw
        colors.color0 = CIColor(cgColor: (ink.blended(withFraction: 0.12, of: tint) ?? ink).cgColor)
        colors.color1 = CIColor(cgColor: paper.cgColor)
        guard let colored = colors.outputImage,
              let modules = Self.imageContext.createCGImage(colored, from: raw.extent) else { return nil }
        let side = CGFloat(modules.width)
        let size = NSSize(width: 158, height: 158)
        return NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let pitch = floor(min(rect.width, rect.height) / (side + 8))
            guard pitch >= 1 else { return false }
            let codeSide = side * pitch
            let grid = CGRect(x: rect.minX + floor((rect.width - codeSide) / 2),
                              y: rect.minY + floor((rect.height - codeSide) / 2),
                              width: codeSide, height: codeSide)
            context.saveGState()
            context.setFillColor(paper.cgColor)
            context.fill(rect)
            context.interpolationQuality = .none
            context.draw(modules, in: grid)
            context.restoreGState()
            return true
        }
    }
}
