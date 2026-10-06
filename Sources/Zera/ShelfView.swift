import AppKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

protocol ShelfViewDelegate: AnyObject {
    func shelfDidAcceptDrop()
    func shelfDragOverChanged(_ over: Bool)
    func shelfDragOutBegan()
    func shelfDragOutEnded()
    func shelfRequestsHide()
    func shelfHeightChanged()
    /// Zera speaks for the shelf. `seconds == 0` holds the line until `shelfSettles()`.
    func shelfSays(_ line: String, mood: ZeraMood, for seconds: TimeInterval)
    func shelfSettles()
    /// Summarize / Explain / Extract / Ask about a shelf item — answered inside Zera.
    func shelfRequests(_ action: FileAction, on item: ShelfItem)
    /// Same, but the answer shows in the Drop Files screen's result panel (no card switch).
    func shelfRunsInPlace(_ action: FileAction, on item: ShelfItem)
}

/// Kept for the Home quick-action API; DropFilesView owns the current shelf UI.
enum ShelfFilter: Int, CaseIterable {
    case all, files, links, notes
    var title: String {
        switch self {
        case .all: return "All"
        case .files: return "Files"
        case .links: return "Links"
        case .notes: return "Notes"
        }
    }
}

extension ShelfItem {
    var isLink: Bool { url.pathExtension.lowercased() == "webloc" }
    var isNote: Bool { ["txt", "rtf", "md"].contains(url.pathExtension.lowercased()) }
}
