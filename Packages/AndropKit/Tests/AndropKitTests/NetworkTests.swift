import XCTest
import CryptoKit
@testable import AndropKit

final class NetworkTests: XCTestCase {
    func testStopClosesListenerAbortsPartialAndCanRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let port = UInt16.random(in: 39001...49000)
        let server = WebSocketServer(port: port, code: "123456", receiver: FileReceiver(directory: directory))
        XCTAssertFalse(server.isRunning)
        server.start(); server.start() // idempotent: a second listener must not replace the first
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let socket = session.webSocketTask(with: url)
        socket.resume()
        try await socket.send(.string("{\"type\":\"HELLO\",\"code\":\"123456\",\"version\":3}"))
        _ = try await json(socket)
        let enter = DragEnterEvent(id: "partial", name: "partial.bin", mimeType: "application/octet-stream", thumbnail: "")
        try await socket.send(.string(String(decoding: JSONEncoder().encode(enter), as: UTF8.self)))
        try await socket.send(.string("{\"type\":\"DRAG_RELEASE\",\"id\":\"partial\",\"action\":\"COMMIT\",\"velocityX\":0,\"velocityY\":0,\"stream\":true}"))
        _ = try await json(socket)
        try await socket.send(.data(Data(repeating: 42, count: FileReceiver.chunkBytes)))
        _ = try await json(socket)
        await withCheckedContinuation { continuation in server.stop { continuation.resume() } }
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        do { _ = try await socket.receive(); XCTFail("the paired socket must be closed") } catch {}
        let rejected = session.webSocketTask(with: url)
        rejected.resume()
        do {
            try await rejected.send(.string("{\"type\":\"HELLO\",\"code\":\"123456\"}"))
            _ = try await rejected.receive()
            XCTFail("a stopped receiver must not accept even a correctly paired phone")
        } catch {}
        rejected.cancel(with: .goingAway, reason: nil)
        server.start()
        try await Task.sleep(nanoseconds: 250_000_000)
        let restarted = session.webSocketTask(with: url)
        restarted.resume()
        defer { restarted.cancel(with: .normalClosure, reason: nil) }
        try await restarted.send(.string("{\"type\":\"HELLO\",\"code\":\"123456\"}"))
        let response = try await json(restarted)
        XCTAssertEqual(response["ok"] as? Bool, true)
    }

    func testAuthenticatedTransferIsAcknowledgedAfterSaving() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let port = UInt16.random(in: 19000...29000)
        let server = WebSocketServer(port: port, code: "123456", receiver: FileReceiver(directory: directory))
        server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await socket.send(.string("{\"type\":\"HELLO\",\"code\":\"123456\"}"))
        let auth = try await json(socket)
        XCTAssertEqual(auth["ok"] as? Bool, true)
        let id = UUID().uuidString
        let enter = DragEnterEvent(id: id, name: "../../hello.txt", mimeType: "text/plain", thumbnail: "")
        try await socket.send(.string(String(decoding: JSONEncoder().encode(enter), as: UTF8.self)))
        // A second paired connection cannot release a transfer owned by the first.
        let other = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        other.resume()
        defer { other.cancel(with: .normalClosure, reason: nil) }
        try await other.send(.string("{\"type\":\"HELLO\",\"code\":\"123456\"}"))
        _ = try await json(other)
        let forged = DragReleaseEvent(type: "DRAG_RELEASE", id: id, action: .commit, velocityX: 0, velocityY: 0, fullData: Data("wrong peer".utf8).base64EncodedString())
        try await other.send(.string(String(decoding: JSONEncoder().encode(forged), as: UTF8.self)))
        // The same peer can enrich an edge preview with the original file metadata at drop time.
        try await socket.send(.string(String(decoding: JSONEncoder().encode(enter), as: UTF8.self)))
        let bytes = Data("hello from Android\n".utf8)
        let release = DragReleaseEvent(type: "DRAG_RELEASE", id: id, action: .commit, velocityX: -700, velocityY: 0, fullData: bytes.base64EncodedString())
        try await socket.send(.string(String(decoding: JSONEncoder().encode(release), as: UTF8.self)))
        let result = try await json(socket)
        XCTAssertEqual(result["type"] as? String, "RESULT")
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["id"] as? String, id)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("hello.txt")), bytes)
        // Cancellation must not write a file.
        let cancelled = DragEnterEvent(id: "cancelled", name: "cancel.txt", mimeType: "text/plain", thumbnail: "")
        try await socket.send(.string(String(decoding: JSONEncoder().encode(cancelled), as: UTF8.self)))
        try await socket.send(.string("{\"type\":\"DRAG_RELEASE\",\"id\":\"cancelled\",\"action\":\"CANCEL\",\"velocityX\":0,\"velocityY\":0}"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel.txt").path))
    }

    func testUnpairedPeerCannotWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let port = UInt16.random(in: 29001...39000)
        let server = WebSocketServer(port: port, code: "123456", receiver: FileReceiver(directory: directory))
        server.start(); defer { server.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        socket.resume(); defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await socket.send(.string("{\"type\":\"HELLO\",\"code\":\"000000\"}"))
        // A failed authentication may deliver AUTH false or close immediately.
        if let response = try? await json(socket) { XCTAssertEqual(response["ok"] as? Bool, false) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testLargeStreamAndFailedHash() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let port = UInt16.random(in: 39001...49000)
        let server = WebSocketServer(port: port, code: "123456", receiver: FileReceiver(directory: directory))
        server.start(); defer { server.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        socket.resume(); defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await socket.send(.string("{\"type\":\"HELLO\",\"code\":\"123456\",\"version\":3}"))
        let auth = try await json(socket)
        XCTAssertEqual(auth["version"] as? Int, 3)
        let chunk = Data((0..<FileReceiver.chunkBytes).map { UInt8($0 % 251) })
        let count = 80 // 20 MiB, sent and verified one chunk at a time.
        var expectedHash = SHA256()
        for _ in 0..<count { expectedHash.update(data: chunk) }
        let hash = expectedHash.finalize().map { String(format: "%02x", $0) }.joined()
        let enter = DragEnterEvent(id: "large", name: "Large original.bin", mimeType: "application/octet-stream", thumbnail: "", edge: .top)
        try await socket.send(.string(String(decoding: JSONEncoder().encode(enter), as: UTF8.self)))
        try await socket.send(.string("{\"type\":\"DRAG_RELEASE\",\"id\":\"large\",\"action\":\"COMMIT\",\"velocityX\":0,\"velocityY\":0,\"stream\":true,\"size\":\(chunk.count * count)}"))
        let ready = try await json(socket)
        XCTAssertEqual(ready["type"] as? String, "TRANSFER_READY")
        for index in 1...count {
            try await socket.send(.data(chunk))
            let ack = try await json(socket)
            XCTAssertEqual(ack["received"] as? Int, chunk.count * index)
        }
        let end = TransferEndEvent(type: "TRANSFER_END", id: "large", bytes: Int64(chunk.count * count), sha256: hash)
        try await socket.send(.string(String(decoding: JSONEncoder().encode(end), as: UTF8.self)))
        let result = try await json(socket)
        XCTAssertEqual(result["ok"] as? Bool, true)
        let saved = try FileHandle(forReadingFrom: directory.appendingPathComponent("Large original.bin"))
        defer { try? saved.close() }
        var actualHash = SHA256()
        while let data = try saved.read(upToCount: FileReceiver.chunkBytes), !data.isEmpty { actualHash.update(data: data) }
        XCTAssertEqual(actualHash.finalize().map { String(format: "%02x", $0) }.joined(), hash)

        // Unknown lengths work; failed integrity and cancelled uploads never publish partial files.
        let bad = DragEnterEvent(id: "bad-hash", name: "bad.bin", mimeType: "application/octet-stream", thumbnail: "")
        try await socket.send(.string(String(decoding: JSONEncoder().encode(bad), as: UTF8.self)))
        try await socket.send(.string("{\"type\":\"DRAG_RELEASE\",\"id\":\"bad-hash\",\"action\":\"COMMIT\",\"velocityX\":0,\"velocityY\":0,\"stream\":true}"))
        _ = try await json(socket)
        try await socket.send(.data(chunk)); _ = try await json(socket)
        let invalidEnd = TransferEndEvent(type: "TRANSFER_END", id: "bad-hash", bytes: Int64(chunk.count), sha256: String(repeating: "0", count: 64))
        try await socket.send(.string(String(decoding: JSONEncoder().encode(invalidEnd), as: UTF8.self)))
        let rejected = try await json(socket)
        XCTAssertEqual(rejected["ok"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bad.bin").path))
        let unfinished = try FileReceiver(directory: directory).begin(name: "cancelled.bin", size: nil)
        try unfinished.append(chunk)
        unfinished.abort()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Large original.bin"])
    }

    private func json(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: throw ReceiveError.invalidData }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
