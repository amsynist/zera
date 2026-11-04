import AppKit
import ApplicationServices
import ScreenCaptureKit
import XCTest
@testable import Zera

@MainActor
final class WindowMediaTests: XCTestCase {
    @available(macOS 15.0, *)
    func testRecordNativeWindowLayouts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ZERA_V2_WINDOW_MEDIA"] == "1", env["CFFIXED_USER_HOME"] != nil,
              let folder = env["ZERA_RENDER_SCREENS"], let fixture = env["ZERA_WINDOW_MEDIA_APP"],
              let photo = env["ZERA_WINDOW_MEDIA_PHOTO"] else { throw XCTSkip("opt-in disposable window capture") }
        let fixtureURL = URL(fileURLWithPath: fixture)
        guard Bundle(url: fixtureURL)?.bundleIdentifier == "io.github.amsynist.zera.media-windows" else {
            XCTFail("Only the dedicated demo-window fixture may be launched or recorded")
            return
        }
        XCTAssertTrue(AXIsProcessTrusted(), "Existing Accessibility access is required")
        let out = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let screen = try XCTUnwrap(NSScreen.main)
        let background = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        background.hasShadow = false
        background.level = NSWindow.Level(rawValue: -1)
        background.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let root = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        background.contentView = root; installReleaseWallpaper(on: root); background.orderFrontRegardless()
        let launch = NSWorkspace.OpenConfiguration(); launch.createsNewApplicationInstance = true; launch.arguments = [photo]
        let app = try await NSWorkspace.shared.openApplication(at: fixtureURL, configuration: launch)
        defer { app.terminate(); background.orderOut(nil); background.contentView = nil }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        // A running external manager must not retile these new disposable windows.
        // This optional CLI action changes only this new process's window IDs, never global state.
        if let cli = env["ZERA_MEDIA_AEROSPACE_CLI"] {
            let candidates = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            for window in candidates.windows where window.owningApplication?.processID == app.processIdentifier && window.windowLayer == 0 {
                let command = Process(); command.executableURL = URL(fileURLWithPath: cli)
                command.arguments = ["layout", "--window-id", String(window.windowID), "floating"]
                try command.run(); command.waitUntilExit(); XCTAssertEqual(command.terminationStatus, 0)
            }
        }
        let access = ArrangeWindowAccess(journalURL: out.appendingPathComponent("demo-window-recovery.json"))
        let applications = [ArrangeApplication(pid: app.processIdentifier, bundle: "io.github.amsynist.zera.media-windows", name: "Demo windows")]
        let display = try XCTUnwrap(ArrangeDisplay.current().first(where: \.main))
        let initial = await Task.detached { access.scan(apps: applications, frontPID: app.processIdentifier, displays: [display.frame]).windows }.value
        XCTAssertEqual(initial.count, 3)
        guard initial.count == 3 else { return }
        let overlaps = Dictionary(uniqueKeysWithValues: initial.enumerated().map { index, window in
            (window.id, CGRect(x: display.area.minX + 90 + CGFloat(index) * 210,
                y: display.area.minY + 100 + CGFloat(index) * 85, width: 660, height: 520))
        })
        let resetError = await Task.detached { access.apply(windows: initial, active: [1], frames: overlaps, assistiveTechnologyActive: false, animated: false) }.value
        XCTAssertNil(resetError)
        try await Task.sleep(nanoseconds: 400_000_000)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        let captureDisplay = try XCTUnwrap(content.displays.first { $0.displayID == id })
        let allowed = content.windows.filter { $0.windowID == UInt32(background.windowNumber) || $0.owningApplication?.processID == app.processIdentifier }
        XCTAssertEqual(allowed.filter { $0.owningApplication?.processID == app.processIdentifier && ["Release notes", "AppTheme.swift", "Coast.png"].contains($0.title ?? "") }.count, 3)
        let config = SCStreamConfiguration(); config.width = 1710; config.height = 1112
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60); config.queueDepth = 6
        config.showsCursor = false; config.capturesAudio = false
        let recorder = ReleaseMediaRecorder(), outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = out.appendingPathComponent("window-source.mp4")
        outputConfig.videoCodecType = .h264; outputConfig.outputFileType = .mp4
        let output = SCRecordingOutput(configuration: outputConfig, delegate: recorder)
        let stream = SCStream(filter: SCContentFilter(display: captureDisplay, including: allowed), configuration: config, delegate: nil)
        try stream.addRecordingOutput(output); try await stream.startCapture()
        let deadline = Date().addingTimeInterval(5)
        while recorder.startedAt == nil && recorder.failure == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let began = try XCTUnwrap(recorder.startedAt)
        var markers: [[String: Any]] = [["name": "overlapping", "start": 0]]
        let area = display.area.insetBy(dx: 45, dy: 25)
        let mainFrames = Dictionary(uniqueKeysWithValues: zip(initial.map(\.id), ArrangeLayout.mainLeft.frames(count: 3, in: area)))
        let columnFrames = Dictionary(uniqueKeysWithValues: zip(initial.map(\.id), ArrangeLayout.columns.frames(count: 3, in: area)))
        for (name, frames) in [("main-left", mainFrames), ("columns", columnFrames), ("restore-layout", mainFrames)] {
            try await Task.sleep(nanoseconds: 2_800_000_000)
            markers.append(["name": name, "start": Date().timeIntervalSince1970 - began])
            let error = await Task.detached { access.apply(windows: initial, active: [1], frames: frames, assistiveTechnologyActive: false, animated: true) }.value
            XCTAssertNil(error, error ?? "")
            try await Task.sleep(nanoseconds: 350_000_000)
            let actual = await Task.detached { access.scan(apps: applications, frontPID: app.processIdentifier, displays: [display.frame]).windows }.value
            for window in actual { XCTAssertTrue(ArrangeGeometry.near(window.frame, try XCTUnwrap(frames[window.id]))) }
        }
        try await Task.sleep(nanoseconds: 2_800_000_000)
        try await stream.stopCapture()
        let finish = Date().addingTimeInterval(5)
        while !recorder.finished && recorder.failure == nil && Date() < finish { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(recorder.finished); XCTAssertNil(recorder.failure)
        try JSONSerialization.data(withJSONObject: ["start_epoch": began, "markers": markers,
            "windows": 3, "capture": "Only new disposable fixture process and native wallpaper window",
            "engine": "Production ArrangeLayout geometry and ArrangeWindowAccess.apply; real Accessibility frame writes"], options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("window-scenes.json"))
    }
}
