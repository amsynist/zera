import SwiftUI
import AppKit

public final class OverlayState: ObservableObject {
    public static let shared = OverlayState()
    @Published public var placement: PhonePlacement = .rightOfMac
    @Published public var entryEdge: EdgePosition = .right
    @Published public var activeCard: ActiveDragCard?
    @Published public var fallingCards: [FallingCardItem] = []
    @Published public var connectedDevice: String?
    @Published public var glow: CGFloat = 0
    @Published public var coordinate: CGFloat = 0.5
    @Published public var rippleStart = Date()
    @Published public var committed = false
    @Published public var showsFileCards = true
}

public struct ActiveDragCard: Identifiable {
    public let id: String
    public let name: String
    public var image: NSImage?
    public var normalizedY: CGFloat
    public var crossRatio: CGFloat
    public var mime = ""
}

public struct FallingCardItem: Identifiable {
    public let id: String
    public let name: String
    public var image: NSImage?
    public var position: CGPoint
    public var rotation: Double = 0
    public var scale: CGFloat = 1
    public var opacity: Double = 1
    public var status = "Receiving original…"
    public var failed = false
    public var progress: Double? = nil
    public var mime = ""
}

/// Coordinates are top-left based, matching Android. On horizontal edges the coordinate is X.
public struct EdgeGeometry {
    public static func origin(edge: EdgePosition, coordinate: CGFloat, size: CGSize) -> CGPoint {
        let t = min(0.92, max(0.08, coordinate))
        switch edge {
        case .left: return CGPoint(x: 0, y: size.height * t)
        case .right: return CGPoint(x: size.width, y: size.height * t)
        case .top: return CGPoint(x: size.width * t, y: 0)
        case .bottom: return CGPoint(x: size.width * t, y: size.height)
        }
    }
    public static func inward(edge: EdgePosition, origin: CGPoint, distance: CGFloat) -> CGPoint {
        switch edge {
        case .left: return CGPoint(x: origin.x + distance, y: origin.y)
        case .right: return CGPoint(x: origin.x - distance, y: origin.y)
        case .top: return CGPoint(x: origin.x, y: origin.y + distance)
        case .bottom: return CGPoint(x: origin.x, y: origin.y - distance)
        }
    }
}

struct OverlayCanvasView: View {
    @ObservedObject var state = OverlayState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if state.glow > 0 {
                    ArrivalRippleView(edge: state.entryEdge, coordinate: state.coordinate,
                                      intensity: state.glow, start: state.rippleStart,
                                      committed: state.committed, reducedMotion: reduceMotion)
                }
                if state.showsFileCards, let card = state.activeCard {
                    let origin = EdgeGeometry.origin(edge: state.entryEdge, coordinate: card.normalizedY, size: geo.size)
                    let horizontal = state.entryEdge == .top || state.entryEdge == .bottom
                    let axis = horizontal ? TransferCard.height(card.image, name: card.name, mime: card.mime) : 232
                    // Exactly the share of the card that has left the phone shows past the Mac's edge.
                    let position = EdgeGeometry.inward(edge: state.entryEdge, origin: origin,
                                                      distance: -axis / 2 + axis * card.crossRatio)
                    TransferCard(image: card.image, name: card.name, status: "From your phone", failed: false, mime: card.mime)
                        .position(position)

                }
                ForEach(state.showsFileCards ? state.fallingCards : []) { card in
                    TransferCard(image: card.image, name: card.name, status: card.status, failed: card.failed, progress: card.progress, mime: card.mime)
                        .rotationEffect(.degrees(reduceMotion ? 0 : card.rotation))
                        .scaleEffect(reduceMotion ? 1 : card.scale)
                        .opacity(card.opacity)
                        .position(card.position)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

struct TransferCard: View {
    let image: NSImage?
    let name: String
    let status: String
    let failed: Bool
    var progress: Double? = nil
    var mime = ""
    static func previewHeight(_ image: NSImage?) -> CGFloat {
        guard let image, image.size.width > 0 else { return 164 }
        return min(300, max(140, 232 * image.size.height / image.size.width))
    }
    /// The card's full height: a photo is only the picture, a file adds its details below.
    static func height(_ image: NSImage?, name: String = "", mime: String = "") -> CGFloat {
        image != nil || isPicture(name: name, mime: mime) ? previewHeight(image) : previewHeight(nil) + 74
    }
    static func isPicture(name: String, mime: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return mime.hasPrefix("image/") || mime.hasPrefix("video/") || isVideo(name: name, mime: mime)
            || ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp"].contains(ext)
    }
    static func isVideo(name: String, mime: String) -> Bool {
        mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "mkv", "webm", "3gp", "avi"].contains((name as NSString).pathExtension.lowercased())
    }
    private var isVideo: Bool { Self.isVideo(name: name, mime: mime) }

    @ViewBuilder var body: some View {
        if let image { photo(image) }
        else if Self.isPicture(name: name, mime: mime) { pending }
        else { file }
    }

    /// A photo or video still on its way: Android only hands over the picture at the drop, so a
    /// picture-shaped pane follows the swipe and the real image fills it the moment it arrives.
    private var pending: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.34, green: 0.3, blue: 0.5), Color(red: 0.16, green: 0.18, blue: 0.26)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: isVideo ? "play.rectangle" : "photo")
                .font(.system(size: 34, weight: .light)).foregroundColor(.white.opacity(0.8))
        }
        .frame(width: 232, height: Self.previewHeight(nil))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.35), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.3), radius: 26, y: 16)
    }

    /// A photo or video arrives as itself: only the picture while it crosses; once it lands, its
    /// progress shows on a soft shade.
    private func photo(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: 232, height: Self.previewHeight(image)).clipped()
            .overlay {
                if isVideo {
                    Image(systemName: "play.fill").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 46, height: 46).background(.black.opacity(0.35), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 0.7))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if failed || progress != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(status).font(.system(size: 10)).foregroundColor(failed ? .orange : .white.opacity(0.75)).lineLimit(1)
                        if let progress {
                            ProgressView(value: progress).progressViewStyle(.linear).tint(.white).scaleEffect(x: 1, y: 0.6)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.top, 26).padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.35), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.3), radius: 26, y: 16)
    }

    private var file: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 232, height: Self.previewHeight(image)).clipped()
                } else {
                    LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.27), Color(red: 0.24, green: 0.23, blue: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: name.hasSuffix(".txt") ? "text.alignleft" : "doc")
                        .font(.system(size: 42, weight: .ultraLight)).foregroundColor(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("ANDROP  /  INCOMING")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1.5)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.black.opacity(0.4), in: Capsule()).padding(12)
            }
            .frame(height: Self.previewHeight(image))
            VStack(alignment: .leading, spacing: 7) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Circle().fill(failed ? Color.orange : Color(red: 0.64, green: 0.9, blue: 0.8)).frame(width: 4, height: 4)
                    Text(status).font(.system(size: 10)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                }
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                        .tint(Color(red: 0.55, green: 0.95, blue: 0.88)).scaleEffect(x: 1, y: 0.6)
                }
            }.padding(15)
        }
        .foregroundColor(.white)
        .frame(width: 232)
        .background(.ultraThinMaterial)
        .background(Color(red: 0.08, green: 0.1, blue: 0.13).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.28), radius: 28, y: 18)
    }
}
