@testable import CoreState
import Dispatch
import XCTest

final class RepositoryRootLocatorTests: XCTestCase {
    func testInferRepoRootFindsAncestorGitDirectory() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-repo-root-\(UUID().uuidString)", isDirectory: true)
        let childURL = rootURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("App", isDirectory: true)
        let gitURL = rootURL.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        XCTAssertEqual(RepositoryRootLocator.inferRepoRoot(from: childURL.path), rootURL.path)
    }

    func testInferRepoRootReturnsNilWhenNoRepositoryExists() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-no-repo-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        XCTAssertNil(RepositoryRootLocator.inferRepoRoot(from: rootURL.path))
    }

    func testBestEffortInferenceReturnsTimeoutWithoutWaitingForWorkToFinish() {
        let probe = TimeoutProbe()
        let queue = DispatchQueue(label: "com.GiantThings.Toastty.RepositoryRootLocatorTests.timeout")
        let runner = RepositoryRootBestEffortRunner(queue: queue)
        let startedAt = Date()

        let resolution = runner.resolve(timeout: 0.01) {
            probe.didStart.signal()
            _ = probe.release.wait(timeout: .now() + 1)
            probe.didFinish.signal()
            return "/repo"
        }

        XCTAssertEqual(probe.didStart.wait(timeout: .now() + 0.5), .success)
        XCTAssertTrue(resolution.timedOut)
        XCTAssertNil(resolution.repoRoot)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)

        probe.release.signal()
        XCTAssertEqual(probe.didFinish.wait(timeout: .now() + 0.5), .success)
    }

    func testBestEffortInferenceFailsFastWhilePreviousWorkIsRunning() {
        let probe = TimeoutProbe()
        let queue = DispatchQueue(label: "com.GiantThings.Toastty.RepositoryRootLocatorTests.busy")
        let runner = RepositoryRootBestEffortRunner(queue: queue)

        let firstResolution = runner.resolve(timeout: 0.01) {
            probe.didStart.signal()
            _ = probe.release.wait(timeout: .now() + 1)
            probe.didFinish.signal()
            return "/repo"
        }
        XCTAssertEqual(probe.didStart.wait(timeout: .now() + 0.5), .success)
        XCTAssertTrue(firstResolution.timedOut)

        let secondResolution = runner.resolve(timeout: 0.1) {
            probe.secondStarted.signal()
            return "/other-repo"
        }

        XCTAssertTrue(secondResolution.timedOut)
        XCTAssertNil(secondResolution.repoRoot)
        XCTAssertEqual(secondResolution.duration, 0)

        probe.release.signal()
        XCTAssertEqual(probe.didFinish.wait(timeout: .now() + 0.5), .success)
        XCTAssertEqual(probe.secondStarted.wait(timeout: .now() + 0.05), .timedOut)
    }

    func testBestEffortInferenceReturnsImmediatelyForEmptyWorkingDirectory() {
        let resolution = RepositoryRootLocator.inferRepoRootBestEffort(from: "  ", timeout: 0.01)

        XCTAssertFalse(resolution.timedOut)
        XCTAssertNil(resolution.repoRoot)
        XCTAssertEqual(resolution.duration, 0)
    }
}

private final class TimeoutProbe: @unchecked Sendable {
    let didStart = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let didFinish = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
}
