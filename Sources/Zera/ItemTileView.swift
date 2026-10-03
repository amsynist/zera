import AppKit

protocol ItemTileDelegate: AnyObject {
    func tile(_ tile: ItemTileView, clickedWith event: NSEvent)
    func tile(_ tile: ItemTileView, startDragWith event: NSEvent)
    func tileRequestedRemove(_ tile: ItemTileView)
    func tileOpened(_ tile: ItemTileView)
}

/// One item in the grid: a big thumbnail you can pick out at a glance, with the name under it.
final class ItemTileView: NSView {
    weak var delegate: ItemTileDelegate?
    private(set) var item: ShelfItem

    private let thumb = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private var hovered = false { didSet { refresh() } }
    private var mouseDownPoint: NSPoint = .zero
    private var didDrag = false

    var selected = false { didSet { refresh() } }

    override var isFlipped: Bool { true }

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.tileWidth, height: Theme.tileHeight))
        roundLayer(Theme.tileCorner)
        buildSubviews()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildSubviews() {
        let t = Theme.thumbSize
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.frame = NSRect(x: (Theme.tileWidth - t) / 2, y: 7, width: t, height: t)
        addSubview(thumb)

        title.font = Theme.font(10, .medium)
        title.textColor = .labelColor
        title.alignment = .center
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.cell?.wraps = true
        title.cell?.isScrollable = false
        title.frame = NSRect(x: 4, y: 7 + t + 3, width: Theme.tileWidth - 8, height: 26)
        addSubview(title)

        removeButton.isBordered = false
        removeButton.setButtonType(.momentaryChange)
        removeButton.title = ""
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                     accessibilityDescription: "Remove")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.frame = NSRect(x: Theme.tileWidth - 19, y: 3, width: 16, height: 16)
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.isHidden = true
        addSubview(removeButton)
    }

    func update(item: ShelfItem) {
        self.item = item
        refresh()
    }

    private func refresh() {
        layer?.backgroundColor = Theme.tileFill(selected, hovered).cgColor
        layer?.borderWidth = selected ? 1.5 : 0
        layer?.borderColor = Theme.accent.withAlphaComponent(0.75).cgColor
        title.stringValue = item.name
        let missing = !item.exists
        title.textColor = missing ? .systemOrange : .labelColor
        toolTip = missing ? "\(item.name) — no longer at its original location"
                          : "\(item.name)\n\(item.subtitle)"
        removeButton.isHidden = !hovered
        alphaValue = missing ? 0.55 : 1.0
        let url = item.url
        Thumbnails.shared.thumbnail(for: url) { [weak self] img in
            guard let self = self, self.item.path == url.path else { return }
            self.thumb.image = img
        }
    }

    @objc private func removeTapped() { delegate?.tileRequestedRemove(self) }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    // MARK: - Mouse / drag out

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
        if event.clickCount == 2 {
            delegate?.tileOpened(self)
            return
        }
        delegate?.tile(self, clickedWith: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        let dx = event.locationInWindow.x - mouseDownPoint.x
        let dy = event.locationInWindow.y - mouseDownPoint.y
        guard (dx * dx + dy * dy) > 9 else { return }
        didDrag = true
        delegate?.tile(self, startDragWith: event)
    }

    /// Snapshot used as the drag image. Drawn into a backing-scale bitmap rather than with
    /// `lockFocus`, which bakes it at 1x and leaves the thumbnail soft on a Retina display.
    func dragImage() -> NSImage {
        let scale = window?.backingScaleFactor ?? 2
        let img = NSImage(size: bounds.size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return img }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawDragContents()
        NSGraphicsContext.restoreGraphicsState()
        img.addRepresentation(rep)
        return img
    }

    private func drawDragContents() {
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.tileCorner, yRadius: Theme.tileCorner).fill()
        if let image = thumb.image {
            // The tile is flipped; the snapshot context is not.
            image.draw(in: NSRect(x: thumb.frame.minX,
                                  y: bounds.height - thumb.frame.maxY,
                                  width: thumb.frame.width, height: thumb.frame.height))
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.font(10, .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ]
        (item.name as NSString).draw(in: NSRect(x: 4, y: 4, width: bounds.width - 8, height: 26),
                                     withAttributes: attrs)
    }
}
