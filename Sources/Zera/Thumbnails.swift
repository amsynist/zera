import AppKit
import QuickLookThumbnailing

/// Small async thumbnail cache. Shows the Finder icon immediately, upgrades to a
/// QuickLook preview when one is available.
final class Thumbnails {
    static let shared = Thumbnails()
    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func icon(for url: URL) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: Theme.thumbSize, height: Theme.thumbSize)
        return img
    }

    func thumbnail(for url: URL, completion: @escaping (NSImage) -> Void) {
        let key = url.path
        if let cached = cache[key] { completion(cached); return }
        completion(icon(for: url))
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url,
                                               size: CGSize(width: Theme.thumbSize, height: Theme.thumbSize),
                                               scale: scale,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight.remove(key)
                guard let cg = rep?.cgImage else { return }
                let img = NSImage(cgImage: cg, size: NSSize(width: Theme.thumbSize, height: Theme.thumbSize))
                self.cache[key] = img
                completion(img)
            }
        }
    }

    func forget(_ url: URL) { cache.removeValue(forKey: url.path) }
}
