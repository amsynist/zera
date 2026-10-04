import AppKit
import SwiftUI

final class ZeraBuddyView: NSView {
    private var hostingView: NSHostingView<ZeraBuddySwiftUIView>?
    private var model = ZeraBuddyModel()
    
    init() {
        super.init(frame: .zero)
        let swiftUIView = ZeraBuddySwiftUIView(model: model)
        let host = NSHostingView(rootView: swiftUIView)
        addSubview(host)
        hostingView = host
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }
    
    func playPeek() {
        model.pose = "peek"
    }
    
    func playCatch() {
        model.pose = "catch"
    }
    
    func trigger(_ pose: String) {
        model.pose = pose
    }
}

class ZeraBuddyModel: ObservableObject {
    @Published var pose: String = "idle"
}

struct ZeraBuddySwiftUIView: View {
    @ObservedObject var model: ZeraBuddyModel
    
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                
                let w = size.width
                let h = size.height
                let r = min(w, h) * 0.45
                
                let cx = w / 2
                let cy = h / 2
                
                // Gentle floating bounce
                let bounce = sin(now * .pi * 2 * 0.8) * r * 0.08
                
                var faceCtx = ctx
                faceCtx.translateBy(x: cx, y: cy + bounce)
                
                // Head background
                let headPath = Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
                faceCtx.fill(headPath, with: .color(Color(nsColor: Pal.accent)))
                
                // Eye dimensions
                let eyeR = r * 0.15
                let eyeX = r * 0.35
                var eyeY = -r * 0.1
                
                // Procedural blinking
                let blinkCycle = now.truncatingRemainder(dividingBy: 4.0)
                let isBlinking = blinkCycle > 3.8 && blinkCycle < 3.95
                let blink = isBlinking ? 0.1 : 1.0
                
                var leftEye = CGRect(x: -eyeX - eyeR, y: eyeY - eyeR * blink, width: eyeR * 2, height: eyeR * 2 * blink)
                var rightEye = CGRect(x: eyeX - eyeR, y: eyeY - eyeR * blink, width: eyeR * 2, height: eyeR * 2 * blink)
                
                // Pose adjustments
                switch model.pose {
                case "peek":
                    // Looking down
                    leftEye.origin.y += r * 0.25
                    rightEye.origin.y += r * 0.25
                case "catch":
                    // Looking up and wide-eyed
                    leftEye.origin.y -= r * 0.2
                    rightEye.origin.y -= r * 0.2
                    leftEye.size.height *= 1.4
                    rightEye.size.height *= 1.4
                case "card_bell", "boba", "celebrate":
                    // Happy / alert
                    leftEye.size.height *= 1.2
                    rightEye.size.height *= 1.2
                default:
                    break
                }
                
                // Draw eyes
                let eyeColor = Color.white
                faceCtx.fill(Path(ellipseIn: leftEye), with: .color(eyeColor))
                faceCtx.fill(Path(ellipseIn: rightEye), with: .color(eyeColor))
                
                // Mouth
                let mouthW = r * 0.2
                let mouthH = r * 0.1
                let mouthY = r * 0.15
                
                var mouthPath = Path()
                if model.pose == "catch" {
                    // Open "O" mouth for catching
                    mouthPath.addEllipse(in: CGRect(x: -mouthW/2, y: mouthY, width: mouthW, height: mouthW))
                    faceCtx.fill(mouthPath, with: .color(Color(nsColor: Pal.surfaceStrong)))
                } else if model.pose == "peek" {
                    // Small dot for peek
                    mouthPath.addEllipse(in: CGRect(x: -mouthW/4, y: mouthY, width: mouthW/2, height: mouthW/2))
                    faceCtx.fill(mouthPath, with: .color(Color(nsColor: Pal.surfaceStrong)))
                } else {
                    // Smile
                    mouthPath.move(to: CGPoint(x: -mouthW/2, y: mouthY))
                    mouthPath.addQuadCurve(to: CGPoint(x: mouthW/2, y: mouthY), control: CGPoint(x: 0, y: mouthY + mouthH))
                    faceCtx.stroke(mouthPath, with: .color(Color(nsColor: Pal.surfaceStrong)), style: StrokeStyle(lineWidth: r * 0.05, lineCap: .round))
                }
            }
        }
    }
}
