import Foundation
import Network

public protocol WebSocketServerDelegate: AnyObject {
    func serverDidStart(port: UInt16)
    func serverDidStop()
    func clientConnected(endpoint: String)
    func clientDisconnected(endpoint: String)
    func didReceiveDragEnter(event: DragEnterEvent)
    func didReceiveDragUpdate(event: DragUpdateEvent)
    func didReceiveDragRelease(event: DragReleaseEvent)
    func didReceiveProgress(id: String, received: Int64, total: Int64?)
    func didSaveFile(id: String, url: URL?, error: String?)
}

public extension WebSocketServerDelegate {
    func didReceiveProgress(id: String, received: Int64, total: Int64?) {}
}

public final class WebSocketServer {
    public weak var delegate: WebSocketServerDelegate?
    private var running = false
    private var generation = UUID()
    private let queueKey = DispatchSpecificKey<Bool>()
    private var timeouts: [String: DispatchWorkItem] = [:]
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private var authenticated = Set<String>()
    private var pending: (peer: String, event: DragEnterEvent)?
    private var pendingStamp = UUID()
    private struct Upload {
        let peer: String
        let event: DragEnterEvent
        let file: FileReceiver.IncomingFile
        let size: Int64?
        var lastActivity = Date()
        var lastProgress = Date.distantPast
    }
    private var isOpening = false
    private var upload: Upload?
    private let queue = DispatchQueue(label: "com.androp.websocket", qos: .userInitiated)
    private let files = DispatchQueue(label: "com.androp.files", qos: .utility)
    private var failedPairings: [Date] = []
    private let receiver: FileReceiver
    private let code: String
    public let port: UInt16

    public init(port: UInt16 = 8989, code: String, receiver: FileReceiver = .shared) { self.port = port; self.code = code; self.receiver = receiver; queue.setSpecific(key: queueKey, value: true) }

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) == true ? body() : queue.sync(execute: body)
    }
    public var isRunning: Bool { onQueue { running } }
    private func isActive(_ ticket: UUID) -> Bool { onQueue { running && generation == ticket } }
    private func notify(_ action: @escaping (WebSocketServerDelegate) -> Void) {
        let ticket = onQueue { generation }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive(ticket), let delegate = self.delegate else { return }
            action(delegate)
        }
    }
    private func schedule(_ key: String, after delay: TimeInterval, _ action: @escaping () -> Void) {
        timeouts[key]?.cancel()
        let ticket = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.generation == ticket else { return }
            self.timeouts.removeValue(forKey: key)
            action()
        }
        timeouts[key] = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func start() {
        onQueue { startOnQueue() }
    }
    private func startOnQueue() {
        guard !running else { return }
        running = true; generation = UUID()
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 12 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.service = NWListener.Service(name: "Androp-\(Host.current().localizedName ?? "Mac")", type: "_androp._tcp")
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.listener === listener, self.running else { return }
                switch state {
                case .ready: self.notify { $0.serverDidStart(port: self.port) }
                case .failed: self.notify { $0.serverDidStop() }
                default: break
                }
            }
            let ticket = generation
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.isActive(ticket) else { connection.cancel(); return }
                self.accept(connection)
            }
            listener.start(queue: queue)
        } catch { notify { $0.serverDidStop() } }
    }

    /// Cancels network ownership before returning. Completion runs after pending file cleanup.
    public func stop(completion: (() -> Void)? = nil) {
        onQueue {
            self.running = false; self.generation = UUID()
            self.timeouts.values.forEach { $0.cancel() }; self.timeouts.removeAll()
            self.listener?.newConnectionHandler = nil
            self.listener?.stateUpdateHandler = nil
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.stateUpdateHandler = nil; connection.cancel() }
            self.connections.removeAll()
            self.authenticated.removeAll()
            self.pending = nil
            self.isOpening = false
            if let upload = self.upload { self.files.async { upload.file.abort() } }
            self.upload = nil
            self.failedPairings.removeAll()
            if let completion {
                // A pending file-open can post one final abort back through the network queue.
                self.files.async { self.queue.async { self.files.async { DispatchQueue.main.async(execute: completion) } } }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard running, connections.count < 4 else { connection.cancel(); return }
        let peer = UUID().uuidString
        connections[peer] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.running, self.connections[peer] === connection else { return }
            switch state {
            case .ready: self.receive(connection, peer: peer)
            case .failed, .cancelled: self.remove(peer)
            default: break
            }
        }
        connection.start(queue: queue)
        schedule("auth." + peer, after: 10) { [weak self, weak connection] in
            if self?.authenticated.contains(peer) == false { connection?.cancel() }
        }
    }

    private func remove(_ peer: String) {
        connections[peer]?.stateUpdateHandler = nil
        for key in ["auth." + peer, "pending." + peer, "upload." + peer] {
            timeouts.removeValue(forKey: key)?.cancel()
        }
        if let upload, upload.peer == peer {
            self.upload = nil
            files.async { upload.file.abort() }
            notify { $0.didSaveFile(id: upload.event.id, url: nil, error: "Connection interrupted") }
        }
        connections.removeValue(forKey: peer)
        if pending?.peer == peer, let event = pending?.event {
            pending = nil
            isOpening = false
            notify { $0.didReceiveDragRelease(event: DragReleaseEvent(type: "DRAG_RELEASE", id: event.id, action: .cancel, velocityX: 0, velocityY: 0, fullData: nil)) }
        }
        if authenticated.remove(peer) != nil {
            let remaining = authenticated.first
            notify {
                $0.clientDisconnected(endpoint: peer)
                if let remaining { $0.clientConnected(endpoint: remaining) }
            }
        }
    }

    private func send(_ object: [String: Any], to connection: NWConnection) {
        guard running, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "androp", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func receive(_ connection: NWConnection, peer: String) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection, self.running, self.connections[peer] === connection else { return }
            guard error == nil else { connection.cancel(); return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { connection.cancel(); return }
            if let data, metadata?.opcode == .binary {
                self.receiveChunk(data, connection: connection, peer: peer)
                return
            }
            if let data {
                guard data.count <= 12 * 1024 * 1024,
                      let text = String(data: data, encoding: .utf8) else { connection.cancel(); return }
                self.process(text, connection: connection, peer: peer)
            }
            if self.connections[peer] != nil { self.receive(connection, peer: peer) }
        }
    }

    private func process(_ text: String, connection: NWConnection, peer: String) {
        if !authenticated.contains(peer) {
            failedPairings.removeAll { Date().timeIntervalSince($0) > 60 }
            guard failedPairings.count < 5,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "HELLO", json["code"] as? String == code else {
                failedPairings.append(Date())
                send(["type": "AUTH", "ok": false], to: connection)
                connection.cancel()
                return
            }
            timeouts.removeValue(forKey: "auth." + peer)?.cancel()
            authenticated.insert(peer)
            send(["type": "AUTH", "ok": true, "version": 3, "chunkBytes": FileReceiver.chunkBytes], to: connection)
            notify { $0.clientConnected(endpoint: peer) }
            return
        }
        switch parseClientMessage(jsonString: text) {
        case .enter(let event):
            guard upload == nil, !isOpening, (pending == nil || (pending?.peer == peer && pending?.event.id == event.id)), !event.id.isEmpty, event.id.count <= 80,
                  event.name.count <= 255, event.thumbnail.utf8.count <= 512 * 1024 else {
                send(["type": "RESULT", "id": event.id, "ok": false, "error": "Receiver is busy or preview is too large."], to: connection)
                return
            }
            pending = (peer, event)
            // A repeated ENTER (the phone caught the item and now has its preview) restarts the clock.
            let stamp = UUID()
            pendingStamp = stamp
            notify { $0.didReceiveDragEnter(event: event) }
            schedule("pending." + peer, after: 30) { [weak self] in
                guard let self, self.pending?.peer == peer, self.pending?.event.id == event.id, self.pendingStamp == stamp else { return }
                self.pending = nil
                self.isOpening = false
                self.send(["type": "RESULT", "id": event.id, "ok": false, "error": "Transfer timed out."], to: connection)
                notify { $0.didReceiveDragRelease(event: DragReleaseEvent(type: "DRAG_RELEASE", id: event.id, action: .cancel, velocityX: 0, velocityY: 0, fullData: nil)) }
            }
        case .update(let event):
            guard pending?.peer == peer, pending?.event.id == event.id else { return }
            notify { $0.didReceiveDragUpdate(event: event) }
        case .release(let event):
            if event.action == .cancel, let current = upload, current.peer == peer, current.event.id == event.id {
                upload = nil
                files.async { current.file.abort() }
                notify { $0.didSaveFile(id: event.id, url: nil, error: "Transfer cancelled") }
                return
            }
            guard let entry = pending, entry.peer == peer, entry.event.id == event.id else { return }
            pending = nil
            timeouts.removeValue(forKey: "pending." + peer)?.cancel()
            let wasOpening = isOpening
            isOpening = false
            notify { $0.didReceiveDragRelease(event: event) }
            guard event.action == .commit else {
                if wasOpening { notify { $0.didSaveFile(id: event.id, url: nil, error: "Transfer cancelled") } }
                return
            }
            if event.stream == true {
                pending = entry
                isOpening = true
                // Keep ownership reserved until the temp file opens and READY is sent.
                let ticket = generation
                files.async {
                    guard self.isActive(ticket) else { return }
                    let result = Result { try self.receiver.begin(name: entry.event.name, size: event.size) }
                    self.queue.async {
                        guard self.connections[peer] != nil, self.isOpening,
                              self.pending?.peer == peer, self.pending?.event.id == event.id else {
                            if case .success(let file) = result { self.files.async { file.abort() } }
                            return
                        }
                        self.pending = nil
                        self.isOpening = false
                        switch result {
                        case .success(let file):
                            self.upload = Upload(peer: peer, event: entry.event, file: file, size: event.size)
                            self.send(["type": "TRANSFER_READY", "id": event.id], to: connection)
                            self.expireUpload(id: event.id, peer: peer)
                        case .failure(let error): self.report(id: event.id, url: nil, error: error.localizedDescription, connection: connection)
                        }
                    }
                }
                return
            }
            let ticket = generation
            files.async {
                guard self.isActive(ticket) else { return }
                let result = Result { try self.receiver.saveFile(name: entry.event.name, base64Data: event.fullData ?? "!") }
                let url = try? result.get()
                let message: String?
                if case .failure(let error) = result { message = error.localizedDescription } else { message = nil }
                self.queue.async {
                    guard self.isActive(ticket) else { return }
                    self.send(["type": "RESULT", "id": event.id, "ok": url != nil, "name": url?.lastPathComponent ?? "", "error": message ?? ""], to: connection)
                    self.notify { $0.didSaveFile(id: event.id, url: url, error: message) }
                }
            }
        case .end(let event):
            guard let current = upload, current.peer == peer, current.event.id == event.id else { return }
            upload = nil
            timeouts.removeValue(forKey: "upload." + peer)?.cancel()
            let ticket = generation
            files.async {
                guard self.isActive(ticket) else { current.file.abort(); return }
                let result = Result { try current.file.finish(bytes: event.bytes, sha256: event.sha256) }
                if case .failure = result { current.file.abort() }
                self.queue.async {
                    guard self.isActive(ticket) else { return }
                    switch result {
                    case .success(let url): self.report(id: event.id, url: url, error: nil, connection: connection)
                    case .failure(let error): self.report(id: event.id, url: nil, error: error.localizedDescription, connection: connection)
                    }
                }
            }
        case .ping: break
        case .unknown: connection.cancel()
        }
    }
    private func receiveChunk(_ data: Data, connection: NWConnection, peer: String) {
        guard let current = upload, current.peer == peer, authenticated.contains(peer),
              !data.isEmpty, data.count <= FileReceiver.chunkBytes else { connection.cancel(); return }
        upload?.lastActivity = Date()
        let ticket = generation
        files.async {
            guard self.isActive(ticket) else { current.file.abort(); return }
            let result = Result { try current.file.append(data); return current.file.received }
            self.queue.async {
                guard self.upload?.event.id == current.event.id, self.upload?.peer == peer else { return }
                switch result {
                case .success(let received):
                    self.send(["type": "CHUNK_ACK", "id": current.event.id, "received": received], to: connection)
                    if Date().timeIntervalSince(self.upload?.lastProgress ?? .distantPast) >= 0.12 || received == current.size {
                        self.upload?.lastProgress = Date()
                        self.notify { $0.didReceiveProgress(id: current.event.id, received: received, total: current.size) }
                    }
                case .failure(let error):
                    self.upload = nil
                    self.files.async { current.file.abort() }
                    self.report(id: current.event.id, url: nil, error: error.localizedDescription, connection: connection)
                }
                // Read the next frame after writing this one. Memory is bounded to a single chunk.
                if self.connections[peer] != nil { self.receive(connection, peer: peer) }
            }
        }
    }
    private func expireUpload(id: String, peer: String) {
        schedule("upload." + peer, after: 30) { [weak self] in
            guard let self, let current = self.upload, current.event.id == id, current.peer == peer else { return }
            if Date().timeIntervalSince(current.lastActivity) < 60 { self.expireUpload(id: id, peer: peer); return }
            self.upload = nil
            self.files.async { current.file.abort() }
            if let connection = self.connections[peer] { self.report(id: id, url: nil, error: "Transfer paused for too long. Try again.", connection: connection) }
        }
    }
    private func report(id: String, url: URL?, error: String?, connection: NWConnection) {
        send(["type": "RESULT", "id": id, "ok": url != nil, "name": url?.lastPathComponent ?? "", "error": error ?? ""], to: connection)
        notify { $0.didSaveFile(id: id, url: url, error: error) }
    }

}
