import AppKit

/// A file in the air: what the notch watches so the Shelf can open under it and catch.
///
/// The controller feeds it one reading per poll (button, drag pasteboard counter, pointer); it
/// answers with what changed. Pure state, so the rules are testable without a real drag.
struct FileDragCatch {
    /// Files a source promises to write on the drop (Photos, Mail, a browser's picture or video).
    static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    /// "A file is in hand": on disk, promised, or a raw picture / PDF. Any kind of file.
    static let fileTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .pdf] + promiseTypes
    /// Everything the Shelf takes when it lands. Text and links are welcome but never open it.
    static let dropTypes: [NSPasteboard.PasteboardType] = fileTypes + [.rtf, .string, .URL]

    static func holdsFile(_ types: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let types else { return false }
        return types.contains { fileTypes.contains($0) }
    }

    /// What to answer a drag with: a copy when the source allows one, else whatever it offers
    /// (some sources only allow "generic" or "move"; answering "copy" would refuse their drop).
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        return mask.isEmpty ? [] : (mask.contains(.link) ? .link : .move)
    }

    /// How close to the notch a carried file has to come before the Shelf opens: a hand's width
    /// either side and a little below, so passing along the menu bar's far ends does nothing.
    static func zone(notch: NSRect) -> NSRect {
        NSRect(x: notch.minX - 96, y: notch.minY - 72, width: notch.width + 192, height: notch.height + 72)
    }

    enum Event: Equatable {
        /// A file was picked up somewhere.
        case began
        /// It came up to the notch: open the Shelf.
        case reached
        /// It was carried away again without a drop: the Shelf can fold back.
        case left
        /// The button came up (dropped or abandoned).
        case ended
    }

    /// A file drag is in progress.
    private(set) var active = false
    /// It has come up to the notch (and not wandered off since).
    private(set) var reached = false
    private var baseline: Int?
    private var awaySince: TimeInterval?
    /// How long it may stray from the open Shelf before that counts as leaving.
    static let leaveGrace: TimeInterval = 0.7

    /// - Parameters:
    ///   - changeCount: the drag pasteboard's counter (it only moves when a drag begins).
    ///   - holdsFile: asked once, when a new drag is seen.
    ///   - zone: where reaching the notch counts; `keep`: where it may roam once the Shelf is open.
    mutating func update(buttonDown: Bool, changeCount: Int, holdsFile: () -> Bool,
                         pointer: NSPoint, zone: NSRect, keep: NSRect, now: TimeInterval) -> [Event] {
        guard buttonDown else {
            // The counter is followed while the button is up, so a drag that begins between
            // two readings still shows as a change on the first reading with the button down.
            baseline = changeCount
            guard active else { return [] }
            active = false; reached = false; awaySince = nil
            return [.ended]
        }
        var events: [Event] = []
        if !active {
            guard let seen = baseline else { baseline = changeCount; return [] }
            guard changeCount != seen else { return [] }
            baseline = changeCount
            guard holdsFile() else { return [] }
            active = true
            events.append(.began)
        }
        if !reached {
            if zone.contains(pointer) {
                reached = true; awaySince = nil
                events.append(.reached)
            }
        } else if keep.contains(pointer) || zone.contains(pointer) {
            awaySince = nil
        } else if let since = awaySince {
            if now - since >= Self.leaveGrace {
                reached = false; awaySince = nil
                events.append(.left)
            }
        } else {
            awaySince = now
        }
        return events
    }
}
