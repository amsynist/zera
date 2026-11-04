import AppKit

/// Resolve a fresh process at the moment of use. LaunchServices' reopen event can create
/// or restore windows; an already running application only needs activation.
enum ApplicationActivation {
    static func running(at url: URL, bundle: String? = nil) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
        } ?? bundle.flatMap { id in
            NSWorkspace.shared.runningApplications.first { !$0.isTerminated && $0.bundleIdentifier == id }
        }
    }

    @discardableResult
    static func activate(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated else { return false }
        // Do not activate all windows or issue AX position writes. macOS owns native
        // Space selection, including the user's Mission Control and Dock preferences.
        if app.isActive { return true }
        return app.activate(options: [])
    }
}
