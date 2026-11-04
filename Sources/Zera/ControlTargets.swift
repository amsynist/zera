import AppKit

/// A native action over an existing custom drawing. Shared by split controls and menus.
final class ControlActionTarget: NSButton {
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onPressed: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init(label: String, role: NSAccessibility.Role = .button) {
        super.init(frame: .zero)
        title = ""; isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityElement(true); setAccessibilityRole(role); setAccessibilityLabel(label)
        target = self; action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func activate() { onPress?() }
    override func draw(_ dirtyRect: NSRect) { drawControlFocus() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); resetHoverTracking() }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onPressed?(true)
        defer { onPressed?(false) }
        super.mouseDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        window?.makeFirstResponder(self)
        performClick(nil)
        return true
    }
}

/// Native hit targets for custom-drawn segments. AppKit owns clicking, keyboard focus and
/// accessibility; the parent keeps its existing drawing and manual layout.
final class SegmentTargets {
    private weak var owner: NSView?
    private var buttons: [SegmentButton] = []
    private var choose: ((Int) -> Void)?
    private var multiple = false

    init(owner: NSView) { self.owner = owner }

    func update(labels: [String], selected: Set<Int>, multiple: Bool = false,
                frame: (Int) -> NSRect, choose: @escaping (Int) -> Void) {
        guard let owner else { return }
        self.choose = choose
        self.multiple = multiple
        if buttons.count != labels.count {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = labels.indices.map { index in
                let button = SegmentButton()
                button.onPress = { [weak self] in self?.choose?(index) }
                button.onMove = { [weak self] delta in self?.move(from: index, delta: delta) }
                owner.addSubview(button)
                return button
            }
        }
        for (index, button) in buttons.enumerated() {
            button.frame = frame(index)
            button.setAccessibilityLabel(labels[index])
            button.setAccessibilityRole(multiple ? .checkBox : .radioButton)
            button.singleChoice = !multiple
            button.state = selected.contains(index) ? .on : .off
        }
        owner.setAccessibilityChildren(buttons)
    }

    private func move(from index: Int, delta: Int) {
        guard !buttons.isEmpty else { return }
        let next = min(buttons.count - 1, max(0, index + delta))
        if !multiple, next != index { choose?(next) }
        owner?.window?.makeFirstResponder(buttons[next])
    }
}

private final class SegmentButton: NSButton {
    var onPress: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var singleChoice = true
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { super.canBecomeKeyView && (!singleChoice || state == .on) }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityElement(true)
        target = self
        action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        window?.makeFirstResponder(self)
        performClick(nil)
        return true
    }

    override func accessibilityValue() -> Any? { NSNumber(value: state == .on) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 48:
            window?.recalculateKeyViewLoop()
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        case 123, 126: onMove?(-1)
        case 124, 125: onMove?(1)
        case 36, 49: performClick(nil)
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) { drawControlFocus() }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
}

/// Keep keyboard focus distinct from a mouse-selected tab. Install once for the app lifetime.
enum ControlFocusVisibility {
    private(set) static var keyboard = false
    private static var monitor: Any?
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            let next = event.type == .keyDown
            if keyboard != next {
                keyboard = next
                (NSApp.keyWindow?.firstResponder as? NSView)?.needsDisplay = true
            }
            return event
        }
    }
}

extension NSView {
    /// A shared, inset focus outline stays inside custom controls and cannot be clipped by
    /// a rounded parent. It is independent of selection and remains visible in every theme.
    func drawControlFocus(radius: CGFloat = Radius.m) {
        guard ControlFocusVisibility.keyboard, window?.isKeyWindow == true, window?.firstResponder === self else { return }
        Pal.accent.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: radius, yRadius: radius)
        path.lineWidth = 2
        path.stroke()
    }
}
