import AppKit
import XCTest
@testable import Zera

@MainActor
final class GitHubCredentialTests: XCTestCase {
    func testWaitingForKeychainDoesNotBlockUIOrOverwriteNewerCredentials() async throws {
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let service = GitHubService { _ in
            XCTAssertFalse(Thread.isMainThread)
            started.signal()
            release.wait()
            return "outdated-test-credential"
        }
        defer { release.signal() }
        let began = CACurrentMediaTime()
        XCTAssertNil(service.token)
        XCTAssertLessThan(CACurrentMediaTime() - began, 0.1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(started.wait(timeout: .now()), .success)
        // A newer connection replaces the old read while it is still waiting.
        service.preview(login: "sample", pulls: [])
        release.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.token, "preview")
        XCTAssertEqual(service.login, "sample")
        XCTAssertFalse(service.isRefreshing)
    }
}
