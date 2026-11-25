import AVFoundation
import AppKit
import ApplicationServices
import XCTest
@testable import Zera

@MainActor
final class MurmurIntegrationTests: XCTestCase {
    func testRealModelOnSyntheticSpeech() async throws {
        _ = NSApplication.shared
        let env = ProcessInfo.processInfo.environment
        guard env["ZERA_TEST_MURMUR"] == "1", env["CFFIXED_USER_HOME"] != nil,
              let file = env["ZERA_SYNTHETIC_SPEECH"] else { throw XCTSkip("opt-in model download and synthetic audio fixture") }
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: file))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)))
        try source.read(into: input)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: format))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16000 / input.format.sampleRate + 1024)))
        var fed = false, conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        XCTAssertNil(conversionError)
        let data = try XCTUnwrap(output.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
        let suite = "zera-murmur-integration-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model: Murmur
        if let path = env["ZERA_TEST_MURMUR_MODEL"] {
            defaults.set(path, forKey: "zera.murmur.folder")
            model = Murmur(defaults: defaults, idleTimeout: 0.25)
        } else {
            model = Murmur(defaults: defaults, idleTimeout: 0.25)
            model.useForDictation = true
            model.download(.quick)
            let deadline = Date().addingTimeInterval(180)
            while model.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
            XCTAssertEqual(model.state, .ready, "real WhisperKit download/load must succeed")
            guard model.isReady else { model.cancelDownload(); return }
            model.unloadWhenIdle()
            while model.isReady { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        var fixture: NSRunningApplication?
        var target: DictationInsertionTarget?
        defer { fixture?.terminate() }
        if let path = env["ZERA_DICTATION_FIXTURE"] {
            let url = URL(fileURLWithPath: path)
            XCTAssertEqual(Bundle(url: url)?.bundleIdentifier, "io.github.amsynist.zera.dictation-fixture")
            guard Bundle(url: url)?.bundleIdentifier == "io.github.amsynist.zera.dictation-fixture" else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true; configuration.arguments = ["native"]
            fixture = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            try await Task.sleep(nanoseconds: 700_000_000)
            target = try XCTUnwrap(DictationInsertionTarget.capture())
        }
        XCTAssertEqual(model.state, .installed)
        model.beginTake()
        XCTAssertEqual(model.state, .loading)
        let transcript = await withCheckedContinuation { continuation in
            model.transcribe(samples, onDecodeStarting: { XCTAssertTrue(model.isReady) }) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(transcript?.lowercased().contains("quick brown fox") == true, "synthetic speech must be recognized")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(model.isReady, "a held take keeps the model loaded beyond the idle deadline")
        XCTAssertFalse(model.canUnload)
        model.endTake()
        XCTAssertTrue(model.canUnload)
        let idleDeadline = Date().addingTimeInterval(10)
        while model.isReady && Date() < idleDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.state, .installed, "the idle timer must release the runtime")
        XCTAssertNotNil(model.installedFolder, "idle unload must keep the download")
        model.beginTake()
        let next = await withCheckedContinuation { continuation in
            model.transcribe(samples) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(next?.lowercased().contains("quick brown fox") == true, "a second cold take must still transcribe")
        model.endTake()
        model.unloadWhenIdle()
        let overrideDeadline = Date().addingTimeInterval(2)
        while model.isReady && Date() < overrideDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.state, .installed)
        if let target, let transcript {
            XCTAssertEqual(target.insert(transcript), .sent)
            try await Task.sleep(nanoseconds: 700_000_000)
            var element: CFTypeRef?, value: CFTypeRef?
            XCTAssertEqual(AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &element), .success)
            if let element, CFGetTypeID(element) == AXUIElementGetTypeID() {
                XCTAssertEqual(AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value), .success)
                XCTAssertEqual(value as? String, transcript)
            } else { XCTFail("synthetic external field lost focus") }
        }
        print("Murmur synthetic fixture: \(samples.count) samples decoded successfully: \(transcript?.lowercased().contains("quick brown fox") == true)")
    }
}
