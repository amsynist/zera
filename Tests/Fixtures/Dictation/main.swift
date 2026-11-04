import AppKit
import WebKit

/// Disposable cross-process input fixture. No microphone, external URLs or user files.
final class Delegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView?
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 620, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Zera synthetic dictation fixture"
        if CommandLine.arguments.contains("web") {
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 620, height: 380))
            view.navigationDelegate = self; web = view; window.contentView = view
            view.loadHTMLString("<html><body><label>Test note<textarea id='note' rows='10' cols='60' autofocus></textarea></label></body></html>", baseURL: nil)
        } else if CommandLine.arguments.contains("secure") {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 380))
            let field = NSSecureTextField(frame: NSRect(x: 32, y: 200, width: 500, height: 32))
            view.addSubview(field); window.contentView = view
            window.makeFirstResponder(field)
        } else {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 380))
            view.isRichText = false; view.isEditable = true
            window.contentView = view; window.makeFirstResponder(view)
        }
        let menu = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); item.submenu = edit; menu.addItem(item)
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window.makeFirstResponder(webView)
        webView.evaluateJavaScript("document.getElementById('note').focus()")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
