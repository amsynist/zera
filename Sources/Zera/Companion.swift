import AppKit

/// Zera *inside* a card: one of her standing cut-outs, bottom-aligned, with an optional
/// speech bubble beside her. Used on Home (greeting), GitHub (PR situation), Reminders (next
/// thing up), the processing panel and toasts — so the screens feel like hers, not just panels.
final class ZeraCompanion: NSView {
    enum Side { case bubbleRight, bubbleLeft }

    private let figure = NSImageView()
    private let bubble = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var size: CGFloat
    private var side: Side

    override var isFlipped: Bool { true }

    init(pose: String, size: CGFloat = 64, side: Side = .bubbleRight) {
        self.size = size
        self.side = side
        super.init(frame: .zero)
        figure.imageScaling = .scaleProportionallyUpOrDown
        figure.imageAlignment = .alignBottom
        figure.setAccessibilityLabel("Zera")
        addSubview(figure)
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = Radius.l
        bubble.layer?.cornerCurve = .continuous
        bubble.layer?.backgroundColor = Pal.accentSoft.cgColor
        addSubview(bubble)
        label.font = Typo.bodyMedium
        label.textColor = Pal.text
        label.maximumNumberOfLines = 2
        label.isSelectable = false
        bubble.addSubview(label)
        set(pose: pose)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Any file name from Resources/Sprites, e.g. "hello", "laptop", "celebrate", "peek".
    func set(pose: String) {
        figure.image = SpriteLibrary.shared.sprite(pose)?.image
            ?? SpriteLibrary.shared.sprite("idle")?.image
            ?? ZeraView.headImage(size: size)
    }

    /// What she says; nil hides the bubble.
    var line: String? {
        didSet {
            label.stringValue = line ?? ""
            bubble.isHidden = (line ?? "").isEmpty
            needsLayout = true
        }
    }

    /// Height this view wants.
    var preferredHeight: CGFloat { size }

    private static let bubblePad = Space.m

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // She stands on the bottom edge; her picture is roughly square.
        let fw = size * 0.95
        let fx: CGFloat = side == .bubbleRight ? 0 : w - fw
        figure.frame = NSRect(x: fx, y: h - size, width: fw, height: size)
        guard !bubble.isHidden else { return }
        let maxBubble = w - fw - Space.s
        let textW = min(maxBubble - Self.bubblePad * 2,
                        ceil((label.stringValue as NSString).size(withAttributes: [.font: Typo.bodyMedium]).width) + 2)
        let bound = (label.stringValue as NSString).boundingRect(with: NSSize(width: textW, height: 60),
                                                                 options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                                 attributes: [.font: Typo.bodyMedium])
        let bh = min(h, ceil(bound.height) + Self.bubblePad * 2 - 4)
        let bw = textW + Self.bubblePad * 2
        let bx: CGFloat = side == .bubbleRight ? fw + Space.s : w - fw - Space.s - bw
        bubble.frame = NSRect(x: bx, y: (h - bh) / 2, width: bw, height: bh)
        label.frame = NSRect(x: Self.bubblePad, y: Self.bubblePad - 2, width: textW, height: bh - Self.bubblePad * 2 + 4)
    }
}
