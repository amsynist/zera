import XCTest
import AppKit
import CryptoKit
import AndropKit
@testable import Zera

final class AndroidTransferTests: XCTestCase {
    @MainActor func testReceiverIsOffByDefaultAndRejectsLateCallbacks() throws {
        let suite = "zera.receiver.off." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let receiver = AndroidTransfer(defaults: defaults)
        XCTAssertFalse(receiver.enabled)
        receiver.start()
        XCTAssertFalse(receiver.isRunning)
        receiver.preview()
        receiver.didReceiveDragEnter(event: DragEnterEvent(id: "late", name: "file.txt", mimeType: "text/plain", thumbnail: ""))
        receiver.serverDidStart(port: 8989)
        receiver.clientConnected(endpoint: "late")
        XCTAssertNil(receiver.transfer)
        XCTAssertFalse(receiver.phoneConnected)
        XCTAssertEqual(receiver.status, "Receiving is off")
        receiver.stop()
        XCTAssertFalse(receiver.isRunning)
        XCTAssertEqual(AndroidTransfer(defaults: defaults).pairingCode, receiver.pairingCode)
        XCTAssertFalse(ArrangeSettings().enabled)
    }

    func testReceiptNeedsFinalSaveAndIgnoresStaleEvents() {
        var receipt = PhoneTransferState(id: "new", name: "original.heic")
        receipt.phase = .receiving
        receipt.update(id: "old", received: 999, total: 999)
        XCTAssertEqual(receipt.received, 0)
        receipt.update(id: "new", received: 100, total: 100)
        XCTAssertEqual(receipt.progress, 1)
        XCTAssertEqual(receipt.status, "Verifying original…")
        XCTAssertEqual(receipt.phase, .receiving)
        receipt.finish(id: "old", url: URL(fileURLWithPath: "/tmp/old"), error: nil)
        XCTAssertEqual(receipt.phase, .receiving)
        receipt.finish(id: "new", url: URL(fileURLWithPath: "/tmp/original (1).heic"), error: nil)
        XCTAssertEqual(receipt.phase, .saved)
        XCTAssertEqual(receipt.name, "original (1).heic")
        receipt.update(id: "new", received: 1, total: 1)
        XCTAssertEqual(receipt.received, 100)
    }
    func testUnknownLengthAndSaveFailure() {
        var receipt = PhoneTransferState(id: "file", name: "original.mov")
        receipt.phase = .receiving
        receipt.update(id: "file", received: 104857600, total: nil)
        XCTAssertNil(receipt.progress)
        XCTAssertFalse(receipt.sizeText.isEmpty)
        receipt.finish(id: "file", url: nil, error: "Disk full")
        XCTAssertEqual(receipt.phase, .failed)
        XCTAssertEqual(receipt.status, "Disk full")
        XCTAssertNil(receipt.url)
    }
    @MainActor
    func testReceiptIsContentOfTheExistingIsland() {
        _ = NSApplication.shared
        let card = AndroidTransferCard()
        let island = IslandView(frame: CGRect(x: 0, y: 0, width: 900, height: 420))
        island.centerX = 450; island.band = 34; island.notchWidth = 190
        let window = NSWindow(contentRect: island.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = island
        var receipt = PhoneTransferState(id: "island", name: "Original.heic")
        receipt.phase = .receiving; receipt.total = 104857600; receipt.received = 52428800
        card.update(receipt)
        island.present(card, size: NSSize(width: card.cardWidth, height: card.desiredHeight), direction: 0, animated: false)
        island.layoutSubtreeIfNeeded()
        island.setPhoneTransfer(receipt)
        XCTAssertEqual(island.phoneLiquid.fraction, 0.5)
        XCTAssertTrue(island.content === card)
        XCTAssertEqual(island.mode, .open)
        XCTAssertFalse(island.companion.isHidden)
        XCTAssertGreaterThan(card.desiredHeight, Isle.headerHeight)
        XCTAssertEqual(Isle.tab(for: .phoneTransfer), .shelf)
        island.close(animated: false)
        window.contentView = nil
    }
}

extension AndroidTransferTests {
    /// Opt-in native host smoke test; isolated inbox, synthetic original, test-process defaults.
    @MainActor
    func testNativeReceiverToNotchAndShelf() async throws {
        guard let folder = ProcessInfo.processInfo.environment["ZERA_TEST_ANDROID_INBOX"] else {
            throw XCTSkip("set ZERA_TEST_ANDROID_INBOX for the native host smoke test")
        }
        _ = NSApplication.shared
        let inbox = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        setenv("ANDROP_INBOX", folder, 1)
        let port = UInt16.random(in: 22000...25000)
        setenv("ZERA_ANDROP_PORT", String(port), 1)
        let service = AndroidTransfer()
        let card = AndroidTransferCard()
        let island = IslandView(frame: CGRect(x: 0, y: 0, width: 900, height: 420))
        island.centerX = 450; island.band = 34; island.notchWidth = 190
        let window = NSWindow(contentRect: CGRect(x: 60, y: 60, width: 900, height: 420), styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = NSColor(srgbRed: 0.09, green: 0.11, blue: 0.13, alpha: 1)
        window.contentView = island
        window.orderFrontRegardless()
        service.onTransferChange = { receipt in
            guard let receipt else { island.close(animated: false); return }
            card.update(receipt)
            if island.content !== card { island.present(card, size: NSSize(width: card.cardWidth, height: card.desiredHeight), direction: 0, animated: true) }
            island.companion.activityOverride = receipt.phase == .receiving ? .running : receipt.phase == .saved ? .done : nil
            island.setPhoneTransfer(receipt)
        }
        defer { window.orderOut(nil); window.contentView = nil }
        let previousEnabled = UserDefaults.standard.object(forKey: "zera.androp.enabled")
        service.setEnabled(true)
        defer { service.stop(); UserDefaults.standard.set(previousEnabled, forKey: "zera.androp.enabled") }
        for _ in 0..<100 where !service.status.hasPrefix("Ready") { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(service.status.hasPrefix("Ready"), service.status)
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        func send(_ object: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        }
        func reply(_ type: String) async throws -> [String: Any] {
            let message = try await socket.receive()
            guard case .string(let text) = message else { throw NSError(domain: "Unexpected binary reply", code: 1) }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, type)
            return object
        }
        try await send(["type": "HELLO", "code": service.pairingCode, "version": 3])
        let auth = try await reply("AUTH")
        XCTAssertEqual(auth["ok"] as? Bool, true)
        let id = UUID().uuidString
        let name = "Original 100 MiB.bin"
        let size = 100 * 1024 * 1024
        try await send(["type": "DRAG_ENTER", "id": id, "name": name, "mimeType": "application/octet-stream", "thumbnail": "", "edge": "RIGHT"])
        try await send(["type": "DRAG_RELEASE", "id": id, "action": "COMMIT", "velocityX": 0, "velocityY": 0, "stream": true, "size": size])
        _ = try await reply("TRANSFER_READY")
        let chunk = Data(repeating: 42, count: 256 * 1024)
        var digest = SHA256()
        var sent = 0
        while sent < size {
            let start = sent
            for _ in 0..<8 where sent < size {
                try await socket.send(.data(chunk))
                digest.update(data: chunk)
                sent += chunk.count
            }
            for end in stride(from: start + chunk.count, through: sent, by: chunk.count) {
                let ack = try await reply("CHUNK_ACK")
                XCTAssertEqual((ack["received"] as? NSNumber)?.intValue, end)
            }
            if sent == chunk.count * 200, let output = ProcessInfo.processInfo.environment["ZERA_TEST_ANDROID_RENDER"] {
                // Allow the real SwiftUI entrance to finish, then capture only our own receipt.
                try await Task.sleep(nanoseconds: 500_000_000)
                let content = island
                content.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
            }
        }
        let expected = digest.finalize().map { String(format: "%02x", $0) }.joined()
        try await send(["type": "TRANSFER_END", "id": id, "bytes": size, "sha256": expected])
        let result = try await reply("RESULT")
        XCTAssertEqual(result["ok"] as? Bool, true)
        for _ in 0..<100 where service.transfer?.phase != .saved { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(service.transfer?.phase, .saved)
        XCTAssertEqual(service.transfer?.total, Int64(size))
        let url = try XCTUnwrap(service.transfer?.url)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, inbox.standardizedFileURL)
        XCTAssertTrue(ShelfStore.shared.items.contains { $0.path == url.standardizedFileURL.path })
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var savedDigest = SHA256()
        while let data = try handle.read(upToCount: chunk.count), !data.isEmpty { savedDigest.update(data: data) }
        XCTAssertEqual(savedDigest.finalize().map { String(format: "%02x", $0) }.joined(), expected)
        let ids = Set(ShelfStore.shared.items.filter { $0.path == url.standardizedFileURL.path }.map(\.id))
        ShelfStore.shared.remove(ids: ids)
        try FileManager.default.removeItem(at: url)
    }
}


extension AndroidTransferTests {
    @MainActor
    func testLiquidUsesRealProgressAndStopsForReducedMotionOrDismissal() {
        let liquid = PhoneLiquidLayer()
        liquid.layout(in: CGRect(x: 0, y: 0, width: 720, height: 308), canvas: CGRect(x: 0, y: 0, width: 900, height: 420))
        var file = PhoneTransferState(id: "liquid", name: "Original.bin")
        file.phase = .receiving; file.total = 100; file.received = 65
        liquid.update(file, reducedMotion: false)
        XCTAssertEqual(liquid.fraction, 0.65, accuracy: 0.001)
        XCTAssertTrue(liquid.moving)
        liquid.update(file, reducedMotion: true)
        XCTAssertFalse(liquid.moving)
        file.phase = .saved
        liquid.update(file, reducedMotion: false)
        XCTAssertEqual(liquid.fraction, 1)
        XCTAssertFalse(liquid.moving)
        liquid.update(nil, reducedMotion: false)
        XCTAssertEqual(liquid.opacity, 0)
        XCTAssertFalse(liquid.moving)
    }
}


extension AndroidTransferTests {
    @MainActor
    func testLiquidRecolorsWithTheSelectedTheme() async throws {
        _ = NSApplication.shared
        let store = ThemeStore.shared, old = ThemeStore.shared.current
        defer { store.select(old) }
        let liquid = PhoneLiquidLayer()
        liquid.layout(in: CGRect(x: 0, y: 0, width: 720, height: 308), canvas: CGRect(x: 0, y: 0, width: 900, height: 420))
        var file = PhoneTransferState(id: "theme", name: "Original.bin")
        file.phase = .receiving; file.total = 100; file.received = 50
        liquid.update(file, reducedMotion: true)
        for id in ["nord", "gruvbox", "dracula"] {
            store.select(try XCTUnwrap(store.theme(id: id)))
            try await Task.sleep(nanoseconds: 20_000_000) // theme notifications are deliberately deferred
            let vessel = try XCTUnwrap(liquid.sublayers?.first)
            let gradient = try XCTUnwrap(vessel.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
            let stops = try XCTUnwrap(gradient.colors as? [CGColor])
            XCTAssertEqual(stops[0], Pal.accent.withAlphaComponent(0.7).cgColor)
            XCTAssertEqual(stops.count, 4)
        }
    }
}


extension AndroidTransferTests {
    func testPhonePreviewDecodesAndRejectsJunk() throws {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { r in NSColor.orange.setFill(); r.fill(); return true }
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let decoded = try XCTUnwrap(AndroidTransfer.image(base64: jpeg.base64EncodedString()))
        XCTAssertEqual(decoded.size.width / decoded.size.height, 40.0 / 30.0, accuracy: 0.05)
        XCTAssertNotNil(AndroidTransfer.image(base64: "data:image/jpeg;base64," + jpeg.base64EncodedString()))
        XCTAssertNil(AndroidTransfer.image(base64: "not an image"))
        XCTAssertNil(AndroidTransfer.image(base64: Data(count: 400 * 1024).base64EncodedString()))
        XCTAssertTrue(PhoneTransferState(id: "v", name: "Clip.MP4").isVideo)
        XCTAssertFalse(PhoneTransferState(id: "p", name: "Photo.heic").isVideo)
    }
}


extension AndroidTransferTests {
    @MainActor
    func testPhotosAndVideosSkipThePanelOtherFilesDoNot() {
        let overlay = OverlayWindowController.shared
        let previous = overlay.autoOpenReceivedMedia
        defer { overlay.autoOpenReceivedMedia = previous }
        overlay.autoOpenReceivedMedia = true
        let suite = "zera.receipt." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let previousPort = ProcessInfo.processInfo.environment["ZERA_ANDROP_PORT"]
        defer { defaults.removePersistentDomain(forName: suite); if let previousPort { setenv("ZERA_ANDROP_PORT", previousPort, 1) } else { unsetenv("ZERA_ANDROP_PORT") } }
        setenv("ZERA_ANDROP_PORT", String(UInt16.random(in: 30000...35000)), 1)
        let service = AndroidTransfer(defaults: defaults)
        service.setEnabled(true)
        defer { service.stop() }
        service.didReceiveDragEnter(event: DragEnterEvent(id: "photo", name: "Incoming file", mimeType: "image/jpeg", thumbnail: "", edge: .left))
        XCTAssertEqual(service.transfer?.opensDirectly, true)
        XCTAssertEqual(service.transfer?.side, -1)
        // The phone's catch repeats ENTER with the real name; the receipt keeps its side.
        service.didReceiveDragEnter(event: DragEnterEvent(id: "photo", name: "IMG_2041.HEIC", mimeType: "image/heic", thumbnail: "", edge: .left))
        XCTAssertEqual(service.transfer?.name, "IMG_2041.HEIC")
        XCTAssertEqual(service.transfer?.side, -1)
        setenv("ZERA_ANDROP_PORT", String(UInt16.random(in: 35001...38000)), 1)
        let other = AndroidTransfer(defaults: defaults)
        other.start()
        defer { other.stop() }
        other.didReceiveDragEnter(event: DragEnterEvent(id: "doc", name: "report.pdf", mimeType: "application/pdf", thumbnail: "", edge: .right))
        XCTAssertEqual(other.transfer?.opensDirectly, false)
    }
}
