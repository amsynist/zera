import AppKit
import ImageIO
import AndropKit

/// One receipt, keyed by the wire ID. Only a verified RESULT can mark it saved.
struct PhoneTransferState {
    enum Phase { case approaching, receiving, saved, failed }
    let id: String
    var name: String
    var phase: Phase = .approaching
    var received: Int64 = 0
    var total: Int64?
    var url: URL?
    var failure: String?
    /// Which side of the screen the phone's card comes from: -1 left, 1 right, 0 top or bottom.
    var side: CGFloat = 1
    /// The phone's small preview of a photo or video frame, so the receipt shows the file itself.
    var preview: NSImage?
    var mime = ""
    /// Photos and videos fall onto the screen and open there; the notch panel stays out of the way.
    var opensDirectly = false
    var isVideo: Bool { ["mp4", "mov", "m4v", "mkv", "webm", "3gp", "avi"].contains((name as NSString).pathExtension.lowercased()) }
    var progress: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }
    var sizeText: String {
        let bytes = total ?? received
        guard bytes > 0 || phase == .saved else { return "Size pending" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    var status: String {
        switch phase {
        case .approaching: return "From your phone · release to send"
        case .receiving:
            if let progress { return progress >= 1 ? "Verifying original…" : "Receiving · \(Int(progress * 100))%" }
            return "Receiving original · \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))"
        case .saved: return "Saved to your Mac · click to reveal"
        case .failed: return failure ?? "Couldn’t receive file"
        }
    }
    mutating func update(id: String, received: Int64, total: Int64?) {
        guard self.id == id, phase == .receiving else { return }
        self.received = max(self.received, received)
        if let total { self.total = total }
    }
    mutating func finish(id: String, url: URL?, error: String?) {
        guard self.id == id, phase == .receiving else { return }
        self.url = url
        failure = error
        phase = url == nil ? .failed : .saved
        if let url { name = url.lastPathComponent }
    }
}

/// Zera owns the receiver in-process: no helper app or second menu-bar item.
final class AndroidTransfer: NSObject, WebSocketServerDelegate {
    static let shared = AndroidTransfer()
    private(set) var transfer: PhoneTransferState? { didSet { onTransferChange?(transfer) } }
    var onTransferChange: ((PhoneTransferState?) -> Void)?
    private(set) var status = "Starting receiver…"
    private(set) var phoneConnected = false
    let pairingCode: String
    var onStatusChange: (() -> Void)?
    private var server: WebSocketServer?
    private var hideWork: DispatchWorkItem?
    private var displayObserver: NSObjectProtocol?
    private let defaults = UserDefaults.standard
    var enabled: Bool { defaults.object(forKey: "zera.androp.enabled") as? Bool ?? true }

    override init() {
        let d = UserDefaults.standard
        let existing = d.string(forKey: "zera.androp.pairingCode")
            ?? d.persistentDomain(forName: "com.androp.mac")?["pairingCode"] as? String
        pairingCode = existing.flatMap { $0.range(of: "^[0-9]{6}$", options: .regularExpression) == nil ? nil : $0 }
            ?? String(Int.random(in: 100000...999999))
        super.init()
        d.set(pairingCode, forKey: "zera.androp.pairingCode")
    }

    func start() {
        guard enabled, server == nil else { return }
        let geometry = NotchGeometry.detect()
        // The card follows the phone swipe across the desktop, then drops into the notch island.
        OverlayState.shared.showsFileCards = true
        OverlayWindowController.shared.swallowsAtLanding = true
        // Photos, videos and text fall onto the screen and open once saved; other files go to the notch.
        OverlayWindowController.shared.autoOpenReceivedMedia = true
        OverlayWindowController.shared.setup(screen: geometry.screen)
        placeAtNotch()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.placeAtNotch() }
        let requested = ProcessInfo.processInfo.environment["ZERA_ANDROP_PORT"].flatMap(UInt16.init) ?? 8989
        let server = WebSocketServer(port: requested, code: pairingCode)
        self.server = server
        server.delegate = self
        server.start()
    }

    func stop() {
        hideWork?.cancel()
        server?.delegate = nil
        server?.stop()
        server = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        transfer = nil
        OverlayWindowController.shared.shutdown()
        phoneConnected = false
        status = "Receiving is off"
        onStatusChange?()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "zera.androp.enabled")
        enabled ? start() : stop()
    }

    private func placeAtNotch() {
        let g = NotchGeometry.detect()
        OverlayWindowController.shared.useScreen(g.screen)
        OverlayWindowController.shared.landingPoint = CGPoint(x: g.notchRect.midX - g.screen.frame.minX,
                                                              y: g.notchRect.height + 14)
    }

    private func present() { hideWork?.cancel() }

    private func hide(after delay: TimeInterval, id: String) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transfer?.id == id else { return }
            self.transfer = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reveal() {
        if let url = transfer?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func serverDidStart(port: UInt16) { status = "Ready · local Wi-Fi / hotspot"; onStatusChange?() }
    func serverDidStop() { status = "Receiver unavailable · quit standalone Androp, then toggle receiving"; onStatusChange?() }
    func clientConnected(endpoint: String) { phoneConnected = true; onStatusChange?() }
    func clientDisconnected(endpoint: String) { phoneConnected = false; onStatusChange?() }

    func didReceiveDragEnter(event: DragEnterEvent) {
        // A repeated ENTER (the phone caught the item) brings its real name and type.
        var receipt = transfer?.id == event.id ? transfer! : PhoneTransferState(id: event.id, name: event.name)
        let isNew = transfer?.id != event.id
        receipt.name = event.name
        receipt.mime = event.mimeType
        receipt.opensDirectly = OverlayWindowController.shared.opensOnArrival(name: event.name, mime: event.mimeType)
        if isNew { receipt.side = event.edge == .left ? -1 : event.edge == .top || event.edge == .bottom ? 0 : 1 }
        transfer = receipt
        if isNew { present() }
        decodePreview(event)
        OverlayWindowController.shared.handleDragEnter(event: event)
    }

    private let previews = DispatchQueue(label: "zera.androp.previews", qos: .utility)
    /// Decoded off the main thread; a repeated ENTER for the same ID may bring a better preview.
    private func decodePreview(_ event: DragEnterEvent) {
        guard !event.thumbnail.isEmpty else { return }
        previews.async { [weak self] in
            let image = Self.image(base64: event.thumbnail)
            DispatchQueue.main.async {
                guard let self, let image, self.transfer?.id == event.id else { return }
                self.transfer?.preview = image
            }
        }
    }

    static func image(base64 string: String) -> NSImage? {
        let raw = string.hasPrefix("data:") ? String(string.split(separator: ",", maxSplits: 1).last ?? "") : string
        guard let data = Data(base64Encoded: raw), data.count <= 384 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
    func didReceiveDragUpdate(event: DragUpdateEvent) {
        OverlayWindowController.shared.handleDragUpdate(event: event)
    }
    func didReceiveDragRelease(event: DragReleaseEvent) {
        guard transfer?.id == event.id else { return }
        OverlayWindowController.shared.handleDragRelease(event: event)
        if event.action == .cancel {
            hide(after: 0.15, id: event.id)
        } else {
            transfer?.phase = .receiving
            transfer?.total = event.size
        }
    }
    func didReceiveProgress(id: String, received: Int64, total: Int64?) {
        transfer?.update(id: id, received: received, total: total)
        OverlayWindowController.shared.updateProgress(id: id, received: received, total: total)
    }
    func didSaveFile(id: String, url: URL?, error: String?) {
        guard transfer?.id == id, transfer?.phase == .receiving else { return }
        transfer?.finish(id: id, url: url, error: error)
        if let url {
            // Shelf references the verified original; it does not copy or analyse it.
            ShelfStore.shared.add(urls: [url])
        }
        OverlayWindowController.shared.didSave(id: id, url: url, error: error)
        // An opened photo or video needs no receipt; the panel (if a slow transfer opened it) steps aside.
        hide(after: url == nil ? 7 : transfer?.opensDirectly == true ? 0.15 : 5, id: id)
    }

    /// UI-only preview: never fabricates a successful file receipt or writes a file.
    func preview() {
        guard transfer == nil else { return }
        let id = UUID().uuidString, size: Int64 = 104857600
        didReceiveDragEnter(event: DragEnterEvent(id: id, name: "A little closer.heic", mimeType: "image/heic",
                                                  thumbnail: Self.sampleThumbnail(), edge: .right))
        // The swipe as the phone sends it: the card crosses the edge, then is released.
        for step in 0...30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(step) / 40) { [weak self] in
                guard let event = Self.event(DragUpdateEvent.self, ["type": "DRAG_UPDATE", "id": id, "normalizedY": 0.46,
                                                                    "crossRatio": Double(step) / 30, "velocityX": -700, "velocityY": 0])
                else { return }
                self?.didReceiveDragUpdate(event: event)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.transfer?.id == id,
                  let release = Self.event(DragReleaseEvent.self, ["type": "DRAG_RELEASE", "id": id, "action": "COMMIT",
                                                                   "velocityX": -700, "velocityY": 0, "size": size])
            else { return }
            self.didReceiveDragRelease(event: release)
            // Progress stops short of the end, so the preview never claims a saved file.
            for step in 1...40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(step) * 0.3) { [weak self] in
                    self?.didReceiveProgress(id: id, received: size * Int64(step) / 44, total: size)
                }
            }
        }
        hide(after: ProcessInfo.processInfo.environment["ZERA_ANDROP_PREVIEW"] == "1" ? 60 : 9, id: id)
    }

    /// A drawn landscape standing in for the phone's photo preview.
    private static func sampleThumbnail() -> String {
        let size = NSSize(width: 480, height: 336)
        let image = NSImage(size: size, flipped: false) { r in
            NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.72, blue: 0.52, alpha: 1),
                                NSColor(srgbRed: 0.55, green: 0.42, blue: 0.72, alpha: 1)])?.draw(in: r, angle: -90)
            NSColor(srgbRed: 1, green: 0.93, blue: 0.78, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 300, y: 190, width: 74, height: 74)).fill()
            for (i, shade) in [0.42, 0.3, 0.2].enumerated() {
                NSColor(srgbRed: shade * 0.7, green: shade * 0.8, blue: shade + 0.12, alpha: 1).setFill()
                let hill = NSBezierPath()
                let base = CGFloat(150 - i * 45)
                hill.move(to: NSPoint(x: 0, y: base))
                hill.curve(to: NSPoint(x: 480, y: base - 20), controlPoint1: NSPoint(x: 140, y: base + 70),
                           controlPoint2: NSPoint(x: 320, y: base - 60))
                hill.line(to: NSPoint(x: 480, y: 0)); hill.line(to: NSPoint(x: 0, y: 0)); hill.close(); hill.fill()
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return "" }
        return jpeg.base64EncodedString()
    }

    private static func event<T: Decodable>(_ type: T.Type, _ fields: [String: Any]) -> T? {
        (try? JSONSerialization.data(withJSONObject: fields)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// Content for Zera's existing IslandView. The island owns shape, morph, rim and companion.
final class AndroidTransferCard: CardBase, CardContent {
    var cardWidth: CGFloat { 720 }
    var desiredHeight: CGFloat { headerBottom + 142 }
    private let fileName = NSTextField(labelWithString: "")
    private let fileMeta = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let fileIcon = NSImageView()
    private let tile = PreviewTile()
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private var receipt: PhoneTransferState?
    var onReveal: (() -> Void)?

    init() {
        super.init(width: 720, title: "From your phone")
        setSubtitle("A little closer. Right here.")
        fileName.font = Typo.rowTitleStrong
        fileName.textColor = Pal.text
        fileName.lineBreakMode = .byTruncatingMiddle
        fileMeta.font = Typo.meta; fileMeta.textColor = Pal.text.withAlphaComponent(0.85)
        sizeLabel.font = Typo.mono; sizeLabel.textColor = Pal.text; sizeLabel.alignment = .right
        statusLabel.font = Typo.caption; statusLabel.textColor = Pal.textSecondary
        for v in [fileName, fileMeta, statusLabel, sizeLabel] { addSubview(v) }
        fileIcon.imageScaling = .scaleProportionallyUpOrDown
        fileIcon.wantsLayer = true
        addSubview(fileIcon)
        tile.wantsLayer = true
        tile.isHidden = true
        addSubview(tile)
        wantsLayer = true
        revealButton.bezelStyle = .inline
        revealButton.font = Typo.caption
        revealButton.target = self; revealButton.action = #selector(reveal)
        revealButton.isHidden = true
        addSubview(revealButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func reveal() { onReveal?() }

    func update(_ file: PhoneTransferState) {
        let changedPhase = receipt?.phase != file.phase
        receipt = file
        fileName.stringValue = file.name
        let kind = ShelfKind(path: file.name)
        fileMeta.stringValue = "\(file.isVideo ? "Video" : kind.label) · original quality"
        // A photo or video shows its own picture; other files keep their symbol.
        tile.image = file.preview
        tile.video = file.isVideo
        tile.isHidden = file.preview == nil
        fileIcon.isHidden = file.preview != nil
        statusLabel.stringValue = file.status
        statusLabel.textColor = file.phase == .failed ? Pal.danger : Pal.text.withAlphaComponent(0.85)
        sizeLabel.stringValue = file.sizeText
        fileIcon.image = NSImage(systemSymbolName: file.phase == .saved ? "checkmark.circle" : kind.symbol, accessibilityDescription: kind.label)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .light))?
            .withSymbolConfiguration(.init(paletteColors: [file.phase == .failed ? Pal.danger : Pal.text]))
        revealButton.isHidden = file.url == nil
        titleLabel.stringValue = file.phase == .saved ? "Safe on your Mac" : file.phase == .failed ? "Couldn’t receive file" : "From your phone"
        setSubtitle(file.phase == .approaching ? "Release it. I’ll catch it." : file.phase == .receiving ? "Bringing your original across." : file.phase == .saved ? "Ready on your Shelf." : "Your original is still on your phone.")
        setAccessibilityLabel("\(file.name), \(file.sizeText), \(file.status)")
        needsLayout = true
        if changedPhase, file.phase == .receiving, !Motion.reduced {
            let catchFile = CASpringAnimation(keyPath: "transform.translation.y")
            catchFile.fromValue = -14; catchFile.toValue = 0
            catchFile.mass = 1; catchFile.stiffness = 220; catchFile.damping = 22
            catchFile.duration = catchFile.settlingDuration
            (file.preview == nil ? fileIcon : tile).layer?.add(catchFile, forKey: "phone.catch")
        }
    }

    override func layout() {
        super.layout()
        layoutHeader()
        let pad = Metrics.cardPad, y = headerBottom + 2
        let width = bounds.width - 2 * pad
        fileIcon.frame = NSRect(x: pad + 3, y: y + 7, width: 44, height: 44)
        tile.frame = NSRect(x: pad - 2, y: y + 3, width: 54, height: 54)
        fileName.frame = NSRect(x: pad + 62, y: y + 7, width: max(60, width - 200), height: 23)
        fileMeta.frame = NSRect(x: pad + 62, y: y + 34, width: max(60, width - 200), height: 18)
        sizeLabel.frame = NSRect(x: bounds.width - pad - 132, y: y + 18, width: 132, height: 38)
        statusLabel.frame = NSRect(x: pad, y: y + 93, width: max(60, width - 142), height: 28)
        revealButton.frame = NSRect(x: bounds.width - pad - 125, y: y + 92, width: 125, height: 26)
    }
}

/// The phone's photo or video frame filling a rounded tile, drawn only when it changes.
private final class PreviewTile: NSView {
    var image: NSImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    var video = false { didSet { if video != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let crop = NSSize(width: bounds.width / scale, height: bounds.height / scale)
        image.draw(in: bounds, from: NSRect(x: (image.size.width - crop.width) / 2, y: (image.size.height - crop.height) / 2,
                                            width: crop.width, height: crop.height),
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if video {
            let badge = NSRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
            NSColor.black.withAlphaComponent(0.4).setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Video")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))?
                .withSymbolConfiguration(.init(paletteColors: [.white]))?
                .draw(in: badge.insetBy(dx: 7, dy: 7).offsetBy(dx: 1, dy: 0))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        shape.lineWidth = 0.8
        shape.stroke()
    }
}
