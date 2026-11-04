import AppKit
import ApplicationServices

/// One dictation take belongs to the field that had focus when it began. Permission
/// preflights are advisory; AX writes must produce a verifiable field change. Unsupported
/// editors receive one native paste on release instead of unverified live keystrokes.
final class DictationInsertionTarget {
    enum Result { case inserted, sent, unavailable }
    private let pid: pid_t
    private let element: AXUIElement?
    private let usesWebEditor: Bool
    private weak var editor: NSTextView?
    private var expectedSelection: CFRange?

    private init(pid: pid_t, element: AXUIElement?, editor: NSTextView?, usesWebEditor: Bool) {
        self.pid = pid; self.element = element; self.editor = editor; self.usesWebEditor = usesWebEditor
        if let editor {
            let range = editor.selectedRange()
            expectedSelection = CFRange(location: range.location, length: range.length)
        } else if let element { expectedSelection = Self.selection(in: element) }
    }

    static func capture() -> DictationInsertionTarget? {
        // Zera's nonactivating panels can own the keyboard while another app stays frontmost.
        if let window = NSApp.keyWindow, window.isKeyWindow, let editor = window.firstResponder as? NSTextView {
            return DictationInsertionTarget(pid: ProcessInfo.processInfo.processIdentifier, element: nil, editor: editor, usesWebEditor: false)
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let local: NSTextView? = nil
        let (element, error) = focusedElement(pid: app.processIdentifier)
        Diag.log("dictation target: app \(app.bundleIdentifier ?? "unknown"), AX \(error.rawValue), post \(CGPreflightPostEventAccess()), trust \(AXIsProcessTrusted())")
        let electron = app.bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
        let web = electron || element.map(Self.isWebContent) == true
        Diag.log("dictation target: web editor \(web)")
        return DictationInsertionTarget(pid: app.processIdentifier, element: element, editor: local, usesWebEditor: web)
    }

    private static func focusedElement(pid: pid_t) -> (AXUIElement?, AXError) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error) }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        return (element, error)
    }

    private static func isWebContent(_ element: AXUIElement) -> Bool {
        var node = element
        for _ in 0..<16 {
            var role: CFTypeRef?, parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role) == .success,
               role as? String == "AXWebArea" { return true }
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = parent as! AXUIElement
        }
        return false
    }

    private static func selection(in element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?, range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func selectionMatches(_ range: CFRange?) -> Bool {
        guard let expectedSelection else { return true }
        guard let range else { return false }
        return range.location == expectedSelection.location && range.length == expectedSelection.length
    }

    private func advanceSelection(by text: String) {
        if let selection = expectedSelection {
            expectedSelection = CFRange(location: selection.location + text.utf16.count, length: 0)
        }
    }

    var isCurrent: Bool {
        if let editor {
            let range = editor.selectedRange()
            return NSApp.keyWindow?.isKeyWindow == true && NSApp.keyWindow?.firstResponder === editor && selectionMatches(CFRange(location: range.location, length: range.length))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        guard let element else { return true } // Event-only clients still stay bound to the app.
        guard let focused = Self.focusedElement(pid: pid).0 else { return false }
        return CFEqual(element, focused) && selectionMatches(Self.selection(in: element))
    }

    func insert(_ text: String, allowPaste: Bool = true) -> Result {
        guard isCurrent else { return .unavailable }
        guard !text.isEmpty else { return .inserted }
        if let editor, editor.isEditable {
            editor.insertText(text, replacementRange: editor.selectedRange())
            advanceSelection(by: text)
            return .inserted
        }
        if !usesWebEditor, let element, writeSelectedText(text, to: element) { return .inserted }
        // Web editors may accept AX setters without updating their actual document, and
        // Chromium can ignore bulk Unicode key events. Do not count either as live typing.
        guard allowPaste else { return .unavailable }
        return paste(text)
    }

    private static func value(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func writeSelectedText(_ text: String, to element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue, let before = Self.value(in: element), let cursor = Self.selection(in: element),
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        let after = Self.value(in: element), selection = Self.selection(in: element)
        let moved = selection.map { $0.location == cursor.location + text.utf16.count && $0.length == 0 } ?? false
        let changed = after.map { $0 != before } ?? false
        Diag.log("dictation: native write changed \(changed), caret advanced \(moved)")
        guard changed || moved else { return false }
        expectedSelection = selection
        return true
    }

    private func paste(_ text: String) -> Result {
        guard CGPreflightPostEventAccess(), isCurrent else { return .unavailable }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return .unavailable }
        let restore = DictationClipboard.shared.stage(text)
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Dictation.eventTag)
            event.postToPid(pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: restore)
        advanceSelection(by: text)
        Diag.log("dictation: sent native paste to original app")
        return .sent
    }

    func replaceTrailing(_ suffix: String, with replacement: String) -> Result {
        guard isCurrent else { return .unavailable }
        if let editor, editor.isEditable {
            let cursor = editor.selectedRange()
            guard cursor.length == 0, cursor.location >= suffix.utf16.count else { return .unavailable }
            editor.insertText(replacement, replacementRange: NSRange(location: cursor.location - suffix.utf16.count, length: suffix.utf16.count))
            let updated = editor.selectedRange()
            expectedSelection = CFRange(location: updated.location, length: updated.length)
            return .inserted
        }
        if let element {
            var value: CFTypeRef?
            var cursor = CFRange()
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXValueGetTypeID(),
               AXValueGetValue(value as! AXValue, .cfRange, &cursor), cursor.length == 0, cursor.location >= suffix.utf16.count {
                var range = CFRange(location: cursor.location - suffix.utf16.count, length: suffix.utf16.count)
                if let selection = AXValueCreate(.cfRange, &range),
                   AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selection) == .success {
                    expectedSelection = range
                    if writeSelectedText(replacement, to: element) { return .inserted }
                    // A rejected write must not leave the user's words selected.
                    guard let original = AXValueCreate(.cfRange, &cursor),
                          AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, original) == .success else { return .unavailable }
                    expectedSelection = cursor
                }
            }
        }
        return .unavailable
    }
}
