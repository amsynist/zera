import AppKit
import QuickLookThumbnailing

extension NSImage {
    /// Keep a single Retina bitmap for small UI icons, rather than every Finder representation.
    func rasterizedIcon(size: CGFloat) -> NSImage {
        let pixels = Int(ceil(size * 2))
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver,
             fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = context.makeImage() else { return self }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}

/// Small async thumbnail cache. Shows the Finder icon immediately, upgrades to a
/// QuickLook preview when one is available.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage) -> Void]] = [:]

    private init() { cache.countLimit = 200; cache.totalCostLimit = 8 * 1024 * 1024 }

    func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path).rasterizedIcon(size: Theme.thumbSize)
    }

    func thumbnail(for url: URL, completion: @escaping (NSImage) -> Void) {
        let key = url.path
        if let cached = cache.object(forKey: key as NSString) { completion(cached); return }
        completion(icon(for: url))
        if pending[key] != nil { pending[key]?.append(completion); return }
        pending[key] = [completion]

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url,
                                               size: CGSize(width: Theme.thumbSize, height: Theme.thumbSize),
                                               scale: scale,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                guard let cg = rep?.cgImage else { return }
                let img = NSImage(cgImage: cg, size: NSSize(width: Theme.thumbSize, height: Theme.thumbSize))
                self.cache.setObject(img, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
                callbacks.forEach { $0(img) }
            }
        }
    }
}
