import AppKit
import ImageIO

/// One cut-out pose of Zera, plus where her rope leaves the top of the picture (if she is
/// hanging from one) so the app can extend the rope up into the notch.
struct Sprite {
    let name: String
    let image: NSImage
    /// Horizontal position of the rope at the top edge, 0…1 of the width. nil = no rope.
    let ropeX: CGFloat?
    let ropeColor: NSColor
    var aspect: CGFloat { image.size.width / max(1, image.size.height) }
}

/// Loads the PNG cut-outs from `Resources/Sprites` (copied into the app bundle by build.sh;
/// found relative to the executable when running from a `swift build`). Everything falls
/// back to the vector drawing when the folder is missing.
final class SpriteLibrary {
    static let shared = SpriteLibrary()

    let directory: URL?
    private var cache: [String: Sprite] = [:]
    private var missing: Set<String> = []

    init(directory: URL? = SpriteLibrary.locate()) {
        self.directory = directory
    }

    var isAvailable: Bool { directory != nil }

    static func locate() -> URL? {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("Sprites")) }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var u = exe.deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(u.appendingPathComponent("Resources/Sprites"))
            u = u.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Sprites"))
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("idle.png").path)
        }
    }

    func sprite(_ name: String) -> Sprite? {
        if let s = cache[name] { return s }
        guard let dir = directory, !missing.contains(name) else { return nil }
        let url = dir.appendingPathComponent(name + ".png")
        guard let data = try? Data(contentsOf: url) else {
            missing.insert(name)
            return nil
        }
        // Rig artwork may be authored at high resolution. Keep only a sprite-sized
        // decode, rather than retaining a multi-megabyte face base for a tiny buddy.
        let rep: NSBitmapImageRep?
        if name.hasSuffix("_base"), let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 528,
               kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            rep = NSBitmapImageRep(cgImage: image)
        } else { rep = NSBitmapImageRep(data: data) }
        guard let rep else { missing.insert(name); return nil }
        let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        img.addRepresentation(rep)
        let (ropeX, color) = Self.findRope(in: rep)
        let s = Sprite(name: name, image: img, ropeX: ropeX, ropeColor: color)
        cache[name] = s
        return s
    }

    /// Looks at the first opaque row of pixels. A narrow, brownish run there is the rope.
    private static func findRope(in rep: NSBitmapImageRep) -> (CGFloat?, NSColor) {
        let fallback = NSColor(srgbRed: 0.36, green: 0.24, blue: 0.16, alpha: 1)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        for y in 0..<min(h, 40) {
            var xs: [Int] = []
            var r = 0.0, g = 0.0, b = 0.0
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.3 else { continue }
                xs.append(x)
                r += Double(c.redComponent); g += Double(c.greenComponent); b += Double(c.blueComponent)
            }
            guard !xs.isEmpty else { continue }
            let n = Double(xs.count)
            r /= n; g /= n; b /= n
            let width = xs.max()! - xs.min()! + 1
            let brownish = r > b + 0.04 && r < 0.65 && g < 0.5
            if width <= 18 && brownish {
                let cx = CGFloat(xs.reduce(0, +)) / CGFloat(xs.count) / CGFloat(w)
                return (cx, NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1))
            }
            return (nil, fallback)
        }
        return (nil, fallback)
    }
}
