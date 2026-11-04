import Foundation
import ScreenCaptureKit

/// Test-only native file recording; its caller supplies an explicit window allowlist.
@available(macOS 15.0, *)
final class ReleaseMediaRecorder: NSObject, SCRecordingOutputDelegate {
    private let lock = NSLock()
    private var start: Double?
    private var done = false
    private var error: Error?
    var startedAt: Double? { lock.withLock { start } }
    var finished: Bool { lock.withLock { done } }
    var failure: Error? { lock.withLock { error } }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { start = Date().timeIntervalSince1970 }
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { done = true }
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.withLock { self.error = error }
    }
}
