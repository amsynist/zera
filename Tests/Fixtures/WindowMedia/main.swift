import AppKit

// Disposable native windows for an opt-in capture. No documents, accounts or network.
final class Delegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let titles = CommandLine.arguments.contains("--four-windows")
            ? ["Release notes", "AppTheme.swift", "Coast.png", "Daily plan"]
            : ["Release notes", "AppTheme.swift", "Coast.png"]
        let screen = NSScreen.main!.visibleFrame
        for (index, title) in titles.enumerated() {
            let window = NSWindow(contentRect: CGRect(x: screen.minX + 150 + CGFloat(index) * 220,
                y: screen.minY + 150 + CGFloat(index) * 90, width: 660, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = title; window.minSize = CGSize(width: 280, height: 220)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
            if index == 2, let file = CommandLine.arguments.dropFirst().first, let image = NSImage(contentsOfFile: file) {
                let view = NSImageView(frame: window.contentView!.bounds)
                view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
                view.autoresizingMask = [.width, .height]; window.contentView = view
            } else {
                let scroll = NSScrollView(frame: window.contentView!.bounds)
                scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
                let text = NSTextView(frame: scroll.bounds)
                text.isEditable = false; text.textContainerInset = CGSize(width: 28, height: 30)
                text.autoresizingMask = [.width]; text.isVerticallyResizable = true
                text.font = index == 1 ? .monospacedSystemFont(ofSize: 17, weight: .regular) : .systemFont(ofSize: 22)
                text.textColor = NSColor(srgbRed: 0.82, green: 0.92, blue: 0.87, alpha: 1)
                text.backgroundColor = NSColor(srgbRed: 0.055, green: 0.075, blue: 0.085, alpha: 1)
                text.string = index == 0 ? "Zera v2\n\nA little less switching.\n\n• Bring originals over from Android\n\n• Keep Claude and Codex close\n\n• Make room for focused work\n\nEverything in this capture is demo data." : "import SwiftUI\n\nstruct AppTheme {\n    let ink = Color(red: 0.06,\n                    green: 0.10,\n                    blue: 0.11)\n\n    let mint = Color(red: 0.77,\n                     green: 0.93,\n                     blue: 0.87)\n\n    let cornerRadius: CGFloat = 18\n}\n"
                scroll.documentView = text; window.contentView = scroll
            }
            window.makeKeyAndOrderFront(nil); windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
let delegate = Delegate()
NSApplication.shared.delegate = delegate
withExtendedLifetime(delegate) { NSApplication.shared.run() }
