import CryptoKit
import Network
import XCTest
@testable import Zera

final class MobileApprovalBridgeTests: XCTestCase {
    @MainActor
    func testPhoneAndWatchDecisionsShareTheLiveClaudeRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zera-mobile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = ClaudeHookService(base: root)
        let bridge = MobileApprovalBridge(hooks: hooks, localAddress: { "127.0.0.1" })
        defer { bridge.stop() }
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(getpid())"
        let read = stamp + "-1", bash = stamp + "-2"
        try drop(id: read, tool: "Read", input: ["file_path": "/Users/example/Zera/README.md"], in: root)
        try drop(id: bash, tool: "Bash", input: ["command": "printf sample"], in: root)
        hooks.scan()
        bridge.start()
        let deadline = Date().addingTimeInterval(3)
        while bridge.pairingPayload == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let payload = try XCTUnwrap(bridge.pairingPayload)
        let components = try XCTUnwrap(URLComponents(string: payload))
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let port = try XCTUnwrap(fields["port"].flatMap(UInt16.init).flatMap(NWEndpoint.Port.init(rawValue:)))
        let encoded = try XCTUnwrap(fields["key"])
        let key = try XCTUnwrap(Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="))
        let client = ApprovalTestClient(port: port, key: SymmetricKey(data: key))
        defer { client.close() }
        let challenge = try await client.readFrame()
        client.challenge = challenge
        try await client.send(["type": "hello"])
        let snapshot = try await client.readPacket()
        let requests = try XCTUnwrap(snapshot["approvals"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["watchActionable"] as? Bool, true)
        XCTAssertEqual(requests[1]["watchActionable"] as? Bool, true)
        XCTAssertEqual(requests[1]["watchSummary"] as? String, "Bash printf sample")
        XCTAssertNil(bridge.pairingPayload)

        hooks.resolveTool(sessionID: "s1", tool: "Bash", input: ["command": "printf sample"])
        let terminalSnapshot = try await client.readPacket()
        XCTAssertEqual((terminalSnapshot["approvals"] as? [[String: Any]])?.count, 1)
        try await client.send(["type": "decision", "id": bash, "allow": true, "watch": false])
        let stale = try await client.readPacket()
        XCTAssertEqual(stale["result"] as? String, "handled")
        _ = try await client.readPacket()

        try await client.send(["type": "decision", "id": read, "allow": true, "watch": true])
        _ = try await client.readPacket() // macOS clears every view on the same hook event.
        let decision = try await client.readPacket()
        XCTAssertEqual(decision["result"] as? String, "approved")
        XCTAssertTrue(hooks.pending.isEmpty)
        let response = try Data(contentsOf: root.appendingPathComponent("hooks/responses/\(read).json"))
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("\"allow\""))
    }

    func testWatchSummariesFitTheRoundScreen() {
        let cwd = "/Users/example/Zera"
        func summary(_ tool: String, _ input: [String: Any]) -> String {
            let (text, allowed) = MobileApprovalBridge.watchSummary(tool: tool, input: input, cwd: cwd)
            XCTAssertTrue(allowed)
            return text
        }
        XCTAssertEqual(summary("Bash", ["command": "swift test --filter Wing"]), "Bash swift test --filter Wing")
        XCTAssertEqual(summary("Edit", ["file_path": cwd + "/Sources/App.swift", "old_string": "a"]), "Edit Sources/App.swift")
        XCTAssertEqual(summary("Bash", ["command": "echo a\nrm b"]), "Bash echo a…")
        let long = summary("Bash", ["command": String(repeating: "x", count: 100)])
        XCTAssertEqual(long.count, "Bash ".count + 72)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(summary("mcp__docs__search", ["query": "watch"]), "mcp__docs__search watch")
        XCTAssertEqual(summary("Task", [:]), "Task")
    }

    func testLargeEditsAreShortenedNotDropped() throws {
        let input: [String: Any] = ["file_path": "/Users/example/Zera/README.md",
                                    "old_string": String(repeating: "let value = 1\n", count: 400),
                                    "new_string": String(repeating: "let value = 2\n", count: 400)]
        let details = try XCTUnwrap(MobileApprovalBridge.mobileDetails(input))
        XCTAssertLessThan(details.utf8.count, 3200)
        XCTAssertTrue(details.hasSuffix("The full request is in Terminal and the notch."))
        XCTAssertEqual(MobileApprovalBridge.mobileDetails(["command": "pwd"]), "{\n  \"command\" : \"pwd\"\n}")
    }

    func testBonjourFingerprintMatchesTheAndroidVector() {
        // Same vector as PairingFingerprintTest on Android: SHA-256 of 32 bytes of 0x07.
        XCTAssertEqual(MobileApprovalBridge.fingerprint(SymmetricKey(data: Data(repeating: 7, count: 32))), "4bb06f8e")
    }

    func testEncryptedPacketCannotBeReplayedAgainstAnotherDirectionSequenceOrConnection() throws {
        let key = SymmetricKey(size: .bits256)
        let challenge = Data(repeating: 1, count: 32)
        let original = ApprovalCipher.aad(challenge: challenge, direction: 0, counter: 1)
        let message = Data("synthetic permission decision".utf8)
        let box = try AES.GCM.seal(message, using: key, authenticating: original)
        XCTAssertEqual(try AES.GCM.open(box, using: key, authenticating: original), message)
        for (salt, side, sequence) in [(challenge, UInt8(1), UInt64(1)), (challenge, 0, 2), (Data(repeating: 2, count: 32), 0, 1)] {
            XCTAssertThrowsError(try AES.GCM.open(box, using: key,
                authenticating: ApprovalCipher.aad(challenge: salt, direction: side, counter: sequence)))
        }
    }

    private func drop(id: String, tool: String, input: [String: Any], in root: URL) throws {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input,
            "session_id": "s1", "cwd": "/Users/example/Zera"
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: root.appendingPathComponent("hooks/requests/\(id).json"))
    }
}

@MainActor
private final class ApprovalTestClient {
    private let connection: NWConnection
    private let key: SymmetricKey
    var challenge = Data()
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    init(port: NWEndpoint.Port, key: SymmetricKey) {
        self.key = key
        connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        connection.start(queue: .main)
    }

    func close() { connection.cancel() }

    func send(_ json: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let payload = try XCTUnwrap(AES.GCM.seal(data, using: key, authenticating:
            ApprovalCipher.aad(challenge: challenge, direction: 0, counter: sent)).combined)
        sent += 1
        var frame = Data(withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        frame.append(payload)
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { reply.resume(throwing: error) } else { reply.resume() }
            })
        }
    }

    func readPacket() async throws -> [String: Any] {
        let packet = try await readFrame()
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: packet), using: key, authenticating:
            ApprovalCipher.aad(challenge: challenge, direction: 1, counter: received))
        received += 1
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func readFrame() async throws -> Data {
        let header = try await read(4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        return try await read(count)
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { reply in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { bytes, _, _, error in
                if let bytes, bytes.count == count { reply.resume(returning: bytes) }
                else { reply.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
