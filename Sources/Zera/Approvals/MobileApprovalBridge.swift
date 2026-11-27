import AppKit
import CryptoKit
import Network

/// Separate, explicitly enabled channel. The QR key never enters the file-transfer socket.
@MainActor
final class MobileApprovalBridge {
    static let shared = MobileApprovalBridge(persistent: true)
    nonisolated static let serviceType = "_zerax._tcp"
    private static let enabledKey = "zeraXApprovalsEnabled", portKey = "zeraXApprovalsPort"
    nonisolated static let changed = Notification.Name("MobileApprovalBridgeChanged")

    private var listener: NWListener?
    private var address: String?
    private var key: SymmetricKey?
    private var observer: NSObjectProtocol?
    private var peers: [UUID: MobileApprovalPeer] = [:]
    private weak var phone: MobileApprovalPeer?
    private var lastSnapshot: [MobileApproval] = []
    private(set) var status = "Off"
    private var listening = false
    private let hooks: ClaudeHookService
    private let localAddress: () -> String?
    /// The shared bridge keeps its key in the Keychain and its port in defaults, so a paired
    /// phone reconnects after Zera restarts. Only turning the bridge off revokes the key.
    private let persistent: Bool

    init(hooks: ClaudeHookService? = nil, localAddress: @escaping () -> String? = AndroidPairing.localAddress,
         persistent: Bool = false) {
        self.hooks = hooks ?? .shared
        self.localAddress = localAddress
        self.persistent = persistent
    }

    /// At launch: resume a bridge the person left on.
    func restoreIfEnabled() {
        guard persistent, UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        start()
    }

    /// The Settings switch. Off forgets the key, so every paired phone must scan a new QR.
    func setEnabled(_ on: Bool) {
        if on {
            if persistent { UserDefaults.standard.set(true, forKey: Self.enabledKey) }
            start()
            return
        }
        stop()
        guard persistent else { return }
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.portKey)
        try? FileManager.default.removeItem(at: Self.keyURL)
    }

    /// Bonjour name suffix the phone uses to find this Mac again after its address changes.
    nonisolated static func fingerprint(_ key: SymmetricKey) -> String {
        let digest = key.withUnsafeBytes { SHA256.hash(data: Data($0)) }
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The key lives in a 0600 file beside the hook spool, not the Keychain: a rebuilt app can lose
    /// read access to its own Keychain item, which silently orphaned every paired phone. Anything
    /// able to read this file can already answer hooks by writing to the spool, so it adds no reach.
    private static var keyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera/zerax-approval.key")
    }

    private func loadOrCreateKey() -> SymmetricKey {
        guard persistent else { return SymmetricKey(size: .bits256) }
        let url = Self.keyURL
        if let data = try? Data(contentsOf: url), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("tmp")
        if fm.createFile(atPath: temporary.path, contents: key.withUnsafeBytes { Data($0) }, attributes: [.posixPermissions: 0o600]) {
            try? fm.removeItem(at: url)
            try? fm.moveItem(at: temporary, to: url)
        }
        return key
    }

    var enabled: Bool { listener != nil }

    var pairingPayload: String? {
        guard phone == nil, listening, let address, let port = listener?.port, let key else { return nil }
        let secret = key.withUnsafeBytes { Data($0).base64EncodedString() }
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "zerax://approvals?v=1&host=\(address)&port=\(port.rawValue)&key=\(secret)"
    }

    func start() {
        guard listener == nil else { return }
        guard let address = localAddress() else { setStatus("Connect this Mac to Wi-Fi or a hotspot"); return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let saved = persistent ? UInt16(clamping: UserDefaults.standard.integer(forKey: Self.portKey)) : 0
        let port = saved > 1023 ? NWEndpoint.Port(rawValue: saved) ?? .any : .any
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        guard let listener = try? NWListener(using: parameters) else { setStatus("Couldn’t open the approval connection"); return }
        let key = loadOrCreateKey()
        listener.service = NWListener.Service(name: "Zera X \(Self.fingerprint(key))", type: Self.serviceType)
        self.address = address
        self.key = key
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.listening = true
                    if self.persistent, let port = listener.port { UserDefaults.standard.set(Int(port.rawValue), forKey: Self.portKey) }
                    self.setStatus("Ready to pair")
                case .failed:
                    // A remembered port someone else took: forget it and listen on a new one. The
                    // phone finds the new port over Bonjour.
                    let retry = self.persistent && UserDefaults.standard.object(forKey: Self.portKey) != nil
                    self.stop()
                    if retry { UserDefaults.standard.removeObject(forKey: Self.portKey); self.start() }
                    else { self.setStatus("Approval connection unavailable") }
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        observer = NotificationCenter.default.addObserver(forName: ClaudeHookService.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        setStatus("Starting…")
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listening = false
        key = nil
        address = nil
        phone = nil
        let old = peers.values
        peers.removeAll()
        old.forEach { $0.close() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        lastSnapshot = []
        setStatus("Off")
    }

    private func accept(_ connection: NWConnection) {
        guard let key, peers.count < 4 else { connection.cancel(); return }
        let id = UUID()
        let peer = MobileApprovalPeer(connection: connection, key: key)
        peers[id] = peer
        peer.start(onPacket: { [weak self, weak peer] packet in
            guard let self, let peer else { return }
            self.receive(packet, from: peer)
        }, onClose: { [weak self, weak peer] in
            guard let self else { return }
            self.peers.removeValue(forKey: id)
            if let peer, self.phone === peer {
                self.phone = nil
                self.lastSnapshot = []
                if self.enabled { self.setStatus("Ready to pair") }
            }
        })
    }

    private func receive(_ packet: ApprovalClientPacket, from peer: MobileApprovalPeer) {
        if phone !== peer {
            guard packet.type == "hello", phone == nil else { peer.close(); return }
            phone = peer
            peer.authenticated()
            setStatus("Phone connected")
            publish(force: true)
            return
        }
        switch packet.type {
        case "ping":
            peer.send(ApprovalServerPacket(type: "pong"))
            publish()
        case "decision":
            guard let id = packet.id, let allow = packet.allow, let fromWatch = packet.watch else { peer.close(); return }
            guard let request = hooks.pending.first(where: { $0.id == id }),
                  let approval = makeApproval(request), lastSnapshot.contains(approval) else {
                peer.send(ApprovalServerPacket(type: "result", id: id, result: "handled"))
                publish(force: true)
                return
            }
            if fromWatch && !approval.watchActionable {
                peer.send(ApprovalServerPacket(type: "result", id: id, result: "phone"))
                return
            }
            let accepted = hooks.respond(request, allow: allow)
            peer.send(ApprovalServerPacket(type: "result", id: id, result: accepted ? (allow ? "approved" : "denied") : "tryAgain"))
            publish(force: true)
        default: peer.close()
        }
    }

    /// The phone's view of a request's input. Edits and writes carry whole files, so long input is
    /// shortened rather than dropped: a request missing from the phone and watch can only be
    /// answered in Terminal. Three requests stay well inside one 32 KiB frame.
    nonisolated static func mobileDetails(_ input: [String: Any], limit: Int = 3000) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard data.count > limit else { return text }
        var shown = ""
        var bytes = 0
        for character in text {
            bytes += character.utf8.count
            if bytes > limit { break }
            shown.append(character)
        }
        return shown + "\n… shortened. The full request is in Terminal and the notch."
    }

    private func makeApproval(_ request: HookRequest) -> MobileApproval? {
        guard let input = hooks.mobileInput(for: request), let details = Self.mobileDetails(input) else { return nil }
        let project = URL(fileURLWithPath: request.cwd).lastPathComponent
        let (watchSummary, watchActionable) = Self.watchSummary(tool: request.toolName, input: input, cwd: request.cwd)
        return MobileApproval(id: request.id, tool: String(request.toolName.prefix(48)), project: String(project.prefix(56)),
                              details: details, watchSummary: watchSummary, watchActionable: watchActionable)
    }

    /// What the watch shows for a request. Every request can be decided on the watch, as the
    /// person asked. The round screen fits about 72 characters, so a longer action is shortened
    /// with "…" and its full text stays on the phone and in the notch.
    nonisolated static func watchSummary(tool: String, input: [String: Any], cwd: String) -> (String, Bool) {
        let limit = 72
        func clip(_ value: String) -> String {
            let lines = value.split(whereSeparator: \.isNewline)
            var text = String(lines.first ?? "").filter { !$0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }
            let shortened = lines.count > 1 || text.count > limit
            if text.count > limit { text = String(text.prefix(limit - 1)) }
            return shortened ? text + "…" : text
        }
        func path(_ value: String) -> String {
            if cwd.hasPrefix("/"), value.hasPrefix(cwd + "/") { return String(value.dropFirst(cwd.count + 1)) }
            let home = NSHomeDirectory()
            return value.hasPrefix(home + "/") ? "~" + value.dropFirst(home.count) : value
        }
        let name = String(tool.prefix(40))
        let detail: String?
        switch tool {
        case "Bash": detail = input["command"] as? String
        case "Read", "Edit", "Write", "MultiEdit": detail = (input["file_path"] as? String).map(path)
        case "NotebookEdit": detail = (input["notebook_path"] as? String).map(path)
        case "Grep", "Glob": detail = input["pattern"] as? String
        case "WebFetch": detail = input["url"] as? String
        case "WebSearch": detail = input["query"] as? String
        default: detail = input.keys.sorted().lazy.compactMap { input[$0] as? String }.first
        }
        guard let detail, !detail.isEmpty else { return (name, true) }
        return ("\(name) \(clip(detail))", true)
    }

    private func publish(force: Bool = false) {
        guard let phone else { return }
        let snapshot = Array(hooks.pending.lazy.compactMap { self.makeApproval($0) }.prefix(3))
        guard force || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        phone.send(ApprovalServerPacket(type: "snapshot", approvals: snapshot))
    }

    private func setStatus(_ value: String) {
        status = value
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

struct MobileApproval: Codable, Equatable {
    let id: String
    let tool: String
    let project: String
    let details: String
    let watchSummary: String
    let watchActionable: Bool
}

struct ApprovalClientPacket: Decodable {
    let type: String
    let id: String?
    let allow: Bool?
    let watch: Bool?
}

struct ApprovalServerPacket: Encodable {
    let type: String
    var approvals: [MobileApproval]? = nil
    var id: String? = nil
    var result: String? = nil
}

/// AES-GCM authenticates both directions, their sequence numbers and a fresh connection
/// challenge. A packet recorded on this or an earlier connection cannot be applied later.
enum ApprovalCipher {
    static let frameLimit = 32768
    static func aad(challenge: Data, direction: UInt8, counter: UInt64) -> Data {
        var data = challenge
        data.append(direction)
        data.append(contentsOf: withUnsafeBytes(of: counter.bigEndian, Array.init))
        return data
    }
}

@MainActor
private final class MobileApprovalPeer {
    private let connection: NWConnection
    private let key: SymmetricKey
    private let challenge = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var onPacket: ((ApprovalClientPacket) -> Void)?
    private var onClose: (() -> Void)?
    private var deadline: DispatchWorkItem?

    init(connection: NWConnection, key: SymmetricKey) {
        self.connection = connection
        self.key = key
    }

    func start(onPacket: @escaping (ApprovalClientPacket) -> Void, onClose: @escaping () -> Void) {
        self.onPacket = onPacket
        self.onClose = onClose
        armDeadline(seconds: 5)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready: self.writeFrame(self.challenge); self.readHeader()
                case .failed, .cancelled: self.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// The phone pings every 60 s; allow two to go missing before closing.
    func authenticated() { armDeadline(seconds: 150) }

    func send(_ packet: ApprovalServerPacket) {
        guard let json = try? JSONEncoder().encode(packet),
              let frame = try? AES.GCM.seal(json, using: key, authenticating:
                ApprovalCipher.aad(challenge: challenge, direction: 1, counter: sendCounter)).combined,
              frame.count <= ApprovalCipher.frameLimit else { close(); return }
        sendCounter += 1
        writeFrame(frame)
    }

    private func writeFrame(_ frame: Data) {
        var body = Data(withUnsafeBytes(of: UInt32(frame.count).bigEndian, Array.init))
        body.append(frame)
        connection.send(content: body, completion: .contentProcessed { [weak self] error in
            if error != nil { MainActor.assumeIsolated { self?.close() } }
        })
    }

    private func readHeader() {
        receive(count: 4) { [weak self] bytes in
            guard let self else { return }
            let count = bytes.reduce(0) { ($0 << 8) | Int($1) }
            guard (28...ApprovalCipher.frameLimit).contains(count) else { self.close(); return }
            self.receive(count: count) { [weak self] frame in self?.open(frame) }
        }
    }

    private func receive(count: Int, done: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, self.onClose != nil else { return }
                guard error == nil, let data, data.count == count else { self.close(); return }
                done(data)
            }
        }
    }

    private func open(_ frame: Data) {
        guard let decoded = try? AES.GCM.open(AES.GCM.SealedBox(combined: frame), using: key, authenticating:
            ApprovalCipher.aad(challenge: challenge, direction: 0, counter: receiveCounter)),
              decoded.count <= 1024,
              let message = try? JSONDecoder().decode(ApprovalClientPacket.self, from: decoded) else { close(); return }
        receiveCounter += 1
        onPacket?(message)
        guard onClose != nil else { return }
        authenticated()
        readHeader()
    }

    private func armDeadline(seconds: Double) {
        deadline?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    func close() {
        deadline?.cancel()
        deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let done = onClose
        onClose = nil
        onPacket = nil
        done?()
    }
}
