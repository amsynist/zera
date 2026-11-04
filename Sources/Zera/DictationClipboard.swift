import AppKit

/// One short clipboard lease for a paste. Repeated pastes retain the original contents;
/// an older restore or a copy made by the user must never overwrite a newer clipboard.
final class DictationClipboard {
    static let shared = DictationClipboard()
    private let board: NSPasteboard
    private var saved: [[(NSPasteboard.PasteboardType, Data)]] = []
    private var ownedChange: Int?
    private var revision = 0

    init(board: NSPasteboard = .general) { self.board = board }

    func stage(_ text: String) -> () -> Void {
        if ownedChange != board.changeCount {
            saved = (board.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }
        revision += 1
        let token = revision
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.writeObjects([item])
        ownedChange = board.changeCount
        return { [weak self] in
            guard let self, token == self.revision else { return }
            defer { self.ownedChange = nil; self.saved = [] }
            guard self.ownedChange == self.board.changeCount else { return }
            self.board.clearContents()
            let items = self.saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { self.board.writeObjects(items) }
        }
    }
}
