import AppKit
import SwiftUI
import ImageIO

public final class OverlayWindowController: NSObject {
    public static let shared = OverlayWindowController()
    private var window: NSWindow?
    private var generation = UUID()
    private var screenSize: CGSize { window?.frame.size ?? CGSize(width: 1440, height: 900) }
    private let state = OverlayState.shared
    private let previews = DispatchQueue(label: "com.androp.previews", qos: .utility)
    /// Optional host destination in top-left screen coordinates (for Zera's notch).
    public var landingPoint: CGPoint?
    public var autoOpenReceivedMedia: Bool?
    /// A released card is pulled into `landingPoint` and vanishes instead of staying as a receipt.
    public var swallowsAtLanding = false
    private var preferredScreen: NSScreen?

    public func setup(screen: NSScreen? = nil) {
        guard window == nil else { return }
        preferredScreen = screen
        _ = ArrivalGlowView.auraTexture
        _ = ArrivalGlowView.waveTexture
        let screen = screen ?? NSScreen.screens.first ?? NSScreen.main
        let window = NSWindow(contentRect: screen?.frame ?? .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: OverlayCanvasView())
        window.orderFrontRegardless()
        self.window = window
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenChanged() {
        if let frame = (preferredScreen ?? NSScreen.screens.first)?.frame { window?.setFrame(frame, display: true) }
    }

    public func useScreen(_ screen: NSScreen) {
        preferredScreen = screen
        window?.setFrame(screen.frame, display: true)
    }

    public func shutdown() {
        generation = UUID()
        NotificationCenter.default.removeObserver(self)
        state.activeCard = nil
        state.fallingCards.removeAll()
        state.glow = 0
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    public func handleDragEnter(event: DragEnterEvent) {
        if let card = state.activeCard, card.id == event.id {
            state.activeCard = ActiveDragCard(id: card.id, name: event.name, image: card.image, normalizedY: card.normalizedY, crossRatio: card.crossRatio, mime: event.mimeType)
            decodePreview(event)
            return
        }
        generation = UUID()
        state.entryEdge = event.edge ?? state.placement.entryEdge
        state.coordinate = 0.5
        state.rippleStart = Date()
        state.committed = false
        withAnimation(.easeOut(duration: 0.22)) { state.glow = 0.85 }
        state.activeCard = ActiveDragCard(id: event.id, name: event.name, image: nil, normalizedY: 0.5, crossRatio: 0, mime: event.mimeType)
        decodePreview(event)
    }

    public func handleDragUpdate(event: DragUpdateEvent) {
        guard var card = state.activeCard, card.id == event.id else { return }
        card.normalizedY = min(0.92, max(0.08, event.normalizedY))
        card.crossRatio = min(1, max(0, event.crossRatio))
        // Live finger coordinates follow the packet; springs belong only to the released card.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.activeCard = card
            state.coordinate = card.normalizedY
        }
    }

    public func handleDragRelease(event: DragReleaseEvent) {
        guard let card = state.activeCard, card.id == event.id else { return }
        let token = generation
        state.activeCard = nil
        if event.action == .cancel {
            withAnimation(.easeOut(duration: 0.25)) { state.glow = 0 }
            return
        }
        state.committed = true
        state.rippleStart = Date()
        state.glow = 1
        let edge = state.entryEdge
        let origin = EdgeGeometry.origin(edge: edge, coordinate: card.normalizedY, size: screenSize)
        let horizontal = edge == .top || edge == .bottom
        let axis: CGFloat = horizontal ? TransferCard.height(card.image, name: card.name, mime: card.mime) : 232
        let start = EdgeGeometry.inward(edge: edge, origin: origin, distance: -axis / 2 + axis * card.crossRatio)
        // A host that catches files in its notch still lets photos and videos fall onto the screen,
        // where they open; everything else is pulled into the notch.
        let opens = opensOnArrival(name: card.name, mime: card.mime)
        if swallowsAtLanding, let target = landingPoint, !opens {
            swallow(card, from: start, into: target, edge: edge, token: token)
            return
        }
        let fixed = swallowsAtLanding ? CGPoint(x: screenSize.width / 2, y: screenSize.height * 0.42) : landingPoint
        var landing = fixed ?? EdgeGeometry.inward(edge: edge, origin: origin, distance: max(310, axis * 0.8))
        landing.x = min(screenSize.width - 145, max(145, landing.x + (fixed == nil ? max(-60, min(60, event.velocityX / 35)) : 0)))
        landing.y = min(screenSize.height - 230, max(230, landing.y + (fixed == nil ? max(-60, min(60, event.velocityY / 35)) : 0)))
        state.fallingCards.append(FallingCardItem(id: card.id, name: card.name, image: card.image, position: start, rotation: edge == .right ? -4 : 4, scale: 1, mime: card.mime))
        // Let SwiftUI install the starting state before animating the trajectory.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.7, dampingFraction: 0.86)) {
                if let i = self.state.fallingCards.firstIndex(where: { $0.id == card.id }) {
                    self.state.fallingCards[i].position = landing
                    self.state.fallingCards[i].rotation = 0
                    self.state.fallingCards[i].scale = 1
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard self.generation == token else { return }
            withAnimation(.easeOut(duration: 0.65)) { self.state.glow = 0 }
        }
    }

    /// The host catches the card: it is pulled into `target`, shrinking as it goes, and vanishes
    /// there. The host shows the receipt, so nothing stays on the desktop.
    private func swallow(_ card: ActiveDragCard, from start: CGPoint, into target: CGPoint, edge: EdgePosition, token: UUID) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state.fallingCards.append(FallingCardItem(id: card.id, name: card.name, image: card.image, position: start,
                                                  rotation: edge == .right ? -4 : 4, scale: 1, mime: card.mime))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            guard let i = self.state.fallingCards.firstIndex(where: { $0.id == card.id }) else { return }
            if reduce {
                withAnimation(.easeOut(duration: 0.15)) { self.state.fallingCards[i].opacity = 0 }
                return
            }
            // Slow to leave the edge, quick through the middle, soft into the notch.
            withAnimation(.timingCurve(0.5, 0, 0.15, 1, duration: 0.55)) {
                self.state.fallingCards[i].position = target
                self.state.fallingCards[i].rotation = edge == .left ? 8 : -8
                self.state.fallingCards[i].scale = 0.12
            }
            withAnimation(.easeIn(duration: 0.18).delay(0.36)) { self.state.fallingCards[i].opacity = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { self.state.fallingCards.removeAll { $0.id == card.id } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard self.generation == token else { return }
            withAnimation(.easeOut(duration: 0.65)) { self.state.glow = 0 }
        }
    }

    /// Photos, videos and plain text open on the Mac once saved, when the user allows it.
    public func opensOnArrival(name: String, mime: String) -> Bool {
        guard autoOpenReceivedMedia ?? UserDefaults.standard.bool(forKey: "autoOpen") else { return false }
        let media = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp", "txt", "mp4", "mov", "m4v"]
        return media.contains((name as NSString).pathExtension.lowercased()) || mime.hasPrefix("image/") || mime.hasPrefix("video/")
    }

    public func updateProgress(id: String, received: Int64, total: Int64?) {
        guard let i = state.fallingCards.firstIndex(where: { $0.id == id }) else { return }
        let amount = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        if let total, total > 0 {
            state.fallingCards[i].progress = min(1, Double(received) / Double(total))
            state.fallingCards[i].status = "Receiving \(Int(Double(received) / Double(total) * 100))% · \(amount)"
        } else { state.fallingCards[i].status = "Receiving original · \(amount)" }
    }

    public func didSave(id: String, url: URL?, error: String?) {
        guard let i = state.fallingCards.firstIndex(where: { $0.id == id }) else { return }
        state.fallingCards[i].failed = url == nil
        state.fallingCards[i].progress = url == nil ? nil : 1
        state.fallingCards[i].status = url == nil ? (error ?? "Couldn't save file") : "Saved to Downloads / Androp"
        if let url, opensOnArrival(name: url.lastPathComponent, mime: state.fallingCards[i].mime) {
            // The card makes way first, so it never sits over the opened photo or video.
            state.fallingCards[i].status = "Opening on your Mac"
            withAnimation(.easeIn(duration: 0.16)) {
                state.fallingCards[i].opacity = 0
                state.fallingCards[i].scale = 1.04
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                self.state.fallingCards.removeAll { $0.id == id }
                NSWorkspace.shared.open(url)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { self.dismiss(id) }
    }

    private func dismiss(_ id: String) {
        withAnimation(.easeOut(duration: 0.45)) {
            if let i = state.fallingCards.firstIndex(where: { $0.id == id }) {
                state.fallingCards[i].opacity = 0
                state.fallingCards[i].scale = 0.97
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.state.fallingCards.removeAll { $0.id == id } }
    }

    public func triggerTestDrop() {
        let id = UUID().uuidString
        handleDragEnter(event: DragEnterEvent(id: id, name: "A little closer.png", mimeType: "image/png", thumbnail: "", edge: state.placement.entryEdge))
        for step in 0...30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(step) / 40) {
                self.handleDragUpdate(event: DragUpdateEvent(type: "DRAG_UPDATE", id: id, normalizedY: 0.46, crossRatio: CGFloat(step) / 30, velocityX: -700, velocityY: 0))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            self.handleDragRelease(event: DragReleaseEvent(type: "DRAG_RELEASE", id: id, action: .commit, velocityX: -700, velocityY: 0, fullData: nil))
            if let i = self.state.fallingCards.firstIndex(where: { $0.id == id }) { self.state.fallingCards[i].status = "Preview · no file transferred" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.dismiss(id) }
        }
    }

    private func decodePreview(_ event: DragEnterEvent) {
        guard !event.thumbnail.isEmpty else { return }
        previews.async {
            let image = self.makeImage(event.thumbnail)
            DispatchQueue.main.async {
                if self.state.activeCard?.id == event.id { self.state.activeCard?.image = image }
                if let i = self.state.fallingCards.firstIndex(where: { $0.id == event.id }) { self.state.fallingCards[i].image = image }
            }
        }
    }

    private func makeImage(_ string: String) -> NSImage? {
        let raw = string.hasPrefix("data:") ? String(string.split(separator: ",", maxSplits: 1).last ?? "") : string
        guard let data = Data(base64Encoded: raw), data.count <= 384 * 1024 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: preview, size: .zero)
    }
}
