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
        let model = Murmur()
        model.download(.quick)
        let deadline = Date().addingTimeInterval(180)
        while model.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertEqual(model.state, .ready, "real WhisperKit download/load must succeed")
        guard model.isReady else { model.cancelDownload(); return }
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
        let transcript = await withCheckedContinuation { continuation in
            model.transcribe(samples) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(transcript?.lowercased().contains("quick brown fox") == true, "synthetic speech must be recognized")
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
