import Foundation

/// Calls back on the main thread when something is added to, renamed in or removed from one
/// folder, instead of polling it. If the folder itself is replaced, watching starts over on
/// the new one. The hook spools (approval requests, activity events, replies) use this so an
/// idle Zera does not touch the disk several times a second.
final class FolderWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(_ url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit { source?.cancel() }

    private func start() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let gone = src.data.contains(.delete) || src.data.contains(.rename)
            self.onChange()
            if gone { self.restart() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func restart() {
        source?.cancel()
        source = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }
}
