import AppKit

/// Home's current priority. The living companion belongs to the shared island header;
/// this surface keeps the message and its action together without repeating the character.
final class HomeHero: NSView {
    enum Mood { case calm, working, asking, done }
    static let height: CGFloat = 104
    static let compactHeight: CGFloat = 72
    var preferredHeight: CGFloat { buttons.isEmpty ? Self.compactHeight : Self.height }
    private let line = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var buttons: [CardButton] = []
    private var actions: [() -> Void] = []
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.l
        layer?.borderWidth = 0
        layer?.borderColor = Pal.border.cgColor
        layer?.backgroundColor = NSColor.clear.cgColor
        line.font = Typo.detailTitle
        line.textColor = Pal.text
        line.lineBreakMode = .byTruncatingTail
        detail.font = Typo.secondary
        detail.textColor = Pal.textSecondary
        detail.maximumNumberOfLines = 2
        addSubview(line); addSubview(detail)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ title: String, _ sub: String, mood: Mood, buttons items: [(String, CardButton.Style, () -> Void)]) {
        line.stringValue = title; detail.stringValue = sub
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []; actions = []
        for (index, item) in items.prefix(2).enumerated() {
            let button = CardButton(item.0, style: item.1, target: self, action: #selector(tapped(_:)))
            button.tag = index
            buttons.append(button); actions.append(item.2); addSubview(button)
        }
        needsLayout = true
    }
    @objc private func tapped(_ sender: NSButton) {
        if actions.indices.contains(sender.tag) { actions[sender.tag]() }
    }
    override func layout() {
        super.layout()
        let padding: CGFloat = 4
        let actionWidth = buttons.reduce(CGFloat.zero) { $0 + $1.fittedWidth } + CGFloat(max(0, buttons.count - 1)) * Space.s
        // Narrow review layouts stack actions beneath the text rather than collide with it.
        let stacked = bounds.width < 620 && !buttons.isEmpty
        let textWidth = max(0, bounds.width - padding * 2 - (stacked || buttons.isEmpty ? 0 : actionWidth + Space.xl))
        line.frame = NSRect(x: padding, y: stacked ? 12 : 14, width: textWidth, height: 24)
        detail.frame = NSRect(x: padding, y: stacked ? 38 : 44, width: textWidth, height: stacked ? 20 : 28)
        var x = stacked ? padding : bounds.width - padding - actionWidth
        for button in buttons {
            button.frame = NSRect(x: x, y: stacked ? 66 : (bounds.height - Metrics.button) / 2, width: button.fittedWidth, height: Metrics.button)
            x += button.fittedWidth + Space.s
        }
    }
}
