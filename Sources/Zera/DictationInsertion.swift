import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// One dictation take belongs to the field that had focus when it began. Permission
/// preflights are advisory. External fields receive one target-checked native paste on
/// release; local NSTextViews can also insert directly while speaking.
final class DictationInsertionTarget {
    enum Result { case inserted, sent, unavailable }
    private let pid: pid_t
    private let element: AXUIElement?
    private weak var editor: NSTextView?
    private var expectedSelection: CFRange?
    private var acceptedUnverifiedWrite = false
    private var acceptedWrite = false

    private init(pid: pid_t, element: AXUIElement?, editor: NSTextView?) {
        self.pid = pid; self.element = element; self.editor = editor
        if let editor {
            let range = editor.selectedRange()
            expectedSelection = CFRange(location: range.location, length: range.length)
        } else if let element { expectedSelection = Self.selection(in: element) }
    }

    private static var preparationTask: Task<Void, Never>?

    /// Chromium exposes its text tree lazily. Teams hosts that tree in a nested
    /// WebView application, so requesting it only from the main app is insufficient.
    /// These attributes are documented by Chromium/Electron for assistive clients.
    static func prepareAccessibility(for app: NSRunningApplication?) {
        preparationTask?.cancel(); preparationTask = nil
        guard AXIsProcessTrusted(), let app, let bundle = app.bundleURL else { return }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let webHost = ["Electron Framework.framework", "MSWebView2.framework"].contains {
            FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path)
        } || ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"].contains(app.bundleIdentifier ?? "")
        guard webHost else { return }
        let helpers = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleURL?.pathExtension == "app" && belongsToApplication($0.bundleURL, bundle: bundle)
        }.prefix(8)
        var seen = Set<pid_t>()
        let pids = ([app.processIdentifier] + helpers.map(\.processIdentifier)).filter { seen.insert($0).inserted }
        preparationTask = Task.detached(priority: .userInitiated) {
            for pid in pids {
                guard !Task.isCancelled else { return }
                let root = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(root, 0.15)
                // Unsupported attributes fail harmlessly in native apps. Never toggle
                // them off: another assistive client may already depend on the tree.
                _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }
    }

    static func cancelAccessibilityPreparation() {
        preparationTask?.cancel(); preparationTask = nil
    }

    static func belongsToApplication(_ candidate: URL?, bundle: URL) -> Bool {
        guard let candidate else { return false }
        return candidate.resolvingSymlinksInPath().path.hasPrefix(bundle.resolvingSymlinksInPath().path + "/Contents/")
    }

    static func capture() -> DictationInsertionTarget? {
        guard !IsSecureEventInputEnabled() else { return nil }
        // Zera's nonactivating panels can own the keyboard while another app stays frontmost.
        if let window = NSApp?.keyWindow, window.isKeyWindow, let editor = window.firstResponder as? NSTextView {
            guard editor.isEditable, !(editor.delegate is NSSecureTextField) else { return nil }
            return DictationInsertionTarget(pid: ProcessInfo.processInfo.processIdentifier, element: nil, editor: editor)
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let (element, error) = focusedElement(pid: app.processIdentifier)
        Diag.log("dictation target: app \(app.bundleIdentifier ?? "unknown"), AX \(error.rawValue), post \(CGPreflightPostEventAccess()), trust \(AXIsProcessTrusted())")
        guard let element, Self.isEditable(element) else { return nil }
        return DictationInsertionTarget(pid: app.processIdentifier, element: element, editor: nil)
    }

    private static func focusedElement(pid: pid_t) -> (AXUIElement?, AXError) {
        // WebKit and several browser editors expose the focused child through the
        // system-wide AX object before their application object's cache is updated.
        // Bind that read to the frontmost application on both sides of the query.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return (nil, .invalidUIElement) }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var value: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        var owner: pid_t = 0
        let matchesApp: Bool
        if let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
           AXUIElementGetPid(value as! AXUIElement, &owner) == .success {
            matchesApp = owner == pid || NSRunningApplication(processIdentifier: pid)?.bundleURL.map {
                belongsToApplication(NSRunningApplication(processIdentifier: owner)?.bundleURL, bundle: $0)
            } == true
        } else { matchesApp = false }
        if error != .success || !matchesApp {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error) }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        return (element, error)
    }

    /// Fail closed: an unknown AX target must never receive a blind paste shortcut.
    static func permitsInsertion(role: String?, subrole: String?, enabled: Bool, writable: Bool) -> Bool {
        guard enabled, subrole != kAXSecureTextFieldSubrole else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, "AXComboBox"].contains(role ?? "") || (writable && role == "AXGroup")
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        func attribute(_ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }
        var writable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable)
        return permitsInsertion(role: attribute(kAXRoleAttribute) as? String,
                                subrole: attribute(kAXSubroleAttribute) as? String,
                                enabled: (attribute(kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true,
                                writable: writable.boolValue)
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
        guard !IsSecureEventInputEnabled(), !acceptedUnverifiedWrite else { return false }
        if let editor {
            guard editor.isEditable, !(editor.delegate is NSSecureTextField) else { return false }
            let range = editor.selectedRange()
            return NSApp?.keyWindow?.isKeyWindow == true && NSApp?.keyWindow?.firstResponder === editor && selectionMatches(CFRange(location: range.location, length: range.length))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        guard let element, Self.isEditable(element) else { return false }
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
        // Custom native editors can acknowledge AXSelectedText without changing their
        // document, just like web editors. Do not issue that write and then retry it:
        // one target-checked paste on release is the external-field insertion path.
        guard allowPaste else { return .unavailable }
        return paste(text)
    }

    private static func value(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func writeSelectedText(_ text: String, to element: AXUIElement) -> Bool {
        acceptedWrite = false
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue, let before = Self.value(in: element), let cursor = Self.selection(in: element),
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        acceptedWrite = true
        let after = Self.value(in: element), selection = Self.selection(in: element)
        let moved = selection.map { $0.location == cursor.location + text.utf16.count && $0.length == 0 } ?? false
        let changed = after.map { $0 != before } ?? false
        Diag.log("dictation: native write changed \(changed), caret advanced \(moved)")
        guard changed || moved else { return false }
        expectedSelection = selection
        return true
    }

    private func paste(_ text: String) -> Result {
        guard Dictation.typingAccessConfirmed, isCurrent else { return .unavailable }
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
                    if acceptedWrite { acceptedUnverifiedWrite = true; return .sent }
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
