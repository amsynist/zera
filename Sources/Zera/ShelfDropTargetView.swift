import AppKit

/// The notch and companion forward external drops to the same file Shelf handler.
class ShelfDropTargetView: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?
    var onDragStateChange: ((Bool) -> Void)?
    private var targeted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(FileDragCatch.dropTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    func acceptsDrop(at point: NSPoint) -> Bool { bounds.contains(point) }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        // Any source that lets go of its file will do: some only offer "generic" or "move".
        onDrop != nil && !sender.draggingSourceOperationMask.isEmpty
            && sender.draggingPasteboard.types?.contains(shelfDragType) != true
            && acceptsDrop(at: convert(sender.draggingLocation, from: nil))
    }

    private func setTargeted(_ active: Bool) {
        guard active != targeted else { return }
        targeted = active
        onDragStateChange?(active)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = canAccept(sender)
        setTargeted(accepted)
        return accepted ? FileDragCatch.operation(for: sender.draggingSourceOperationMask) : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setTargeted(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { canAccept(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setTargeted(false) }
        guard canAccept(sender) else { return false }
        return onDrop?(sender.draggingPasteboard) ?? false
    }
}
