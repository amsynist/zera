import AppKit
import QuickLookThumbnailing

/// Small async thumbnail cache. Shows the Finder icon immediately, upgrades to a
/// QuickLook preview when one is available.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage) -> Void]] = [:]

    private init() { cache.countLimit = 200 }

    func icon(for url: URL) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: Theme.thumbSize, height: Theme.thumbSize)
        return img
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
                self.cache.setObject(img, forKey: key as NSString)
                callbacks.forEach { $0(img) }
            }
        }
    }
}
