import Foundation
import XCTest
@testable import ToasttyApp

final class CodexDaemonOptOutProbeTests: XCTestCase {
    func testReportsTheFlagFromHelpAndCachesPerExecutable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let executor = HelpExecutor(result: .success("      --no-daemon\n          Run without the shared background server\n"))
        let probe = CodexDaemonOptOutProbe(executor: executor)

        XCTAssertTrue(probe.supportsNoDaemon(runtime: fixture.runtime))
        XCTAssertTrue(probe.supportsNoDaemon(runtime: fixture.runtime))
        XCTAssertEqual(executor.calls, [["--help"]])
    }

    func testOlderCodexWithoutTheFlagIsUnsupported() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let executor = HelpExecutor(result: .success("      --no-alt-screen\n      --no-daemonize-me\n"))
        let probe = CodexDaemonOptOutProbe(executor: executor)

        XCTAssertFalse(probe.supportsNoDaemon(runtime: fixture.runtime))
        XCTAssertFalse(probe.supportsNoDaemon(runtime: fixture.runtime))
        XCTAssertEqual(executor.calls.count, 1)
    }

    func testTimeoutIsNotCached() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let executor = HelpExecutor(result: .failure(CodexPluginCLIError.timedOut))
        let probe = CodexDaemonOptOutProbe(executor: executor)

        XCTAssertFalse(probe.supportsNoDaemon(runtime: fixture.runtime))
        XCTAssertFalse(probe.supportsNoDaemon(runtime: fixture.runtime))
        XCTAssertEqual(executor.calls.count, 2)
    }

    func testReplacedExecutableIsProbedAgain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let executor = HelpExecutor(result: .success("--no-daemon"))
        let probe = CodexDaemonOptOutProbe(executor: executor)

        XCTAssertTrue(probe.supportsNoDaemon(runtime: fixture.runtime))
        try "#!/bin/sh\necho updated\n".write(to: fixture.executableURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(probe.supportsNoDaemon(runtime: fixture.runtime))
        XCTAssertEqual(executor.calls.count, 2)
    }

    private struct Fixture {
        let rootURL: URL
        let executableURL: URL
        let runtime: CodexIntegrationRuntime

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-daemon-probe-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            executableURL = rootURL.appendingPathComponent("codex", isDirectory: false)
            try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
            runtime = CodexIntegrationRuntime(
                executableURL: executableURL,
                codexHomeURL: rootURL.appendingPathComponent(".codex", isDirectory: true),
                workingDirectoryURL: rootURL
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}

final class BundledResourceCopierTests: XCTestCase {
    func testCopiesATreeWithModesAndSymlinks() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("bundled-copy-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootURL.appendingPathComponent("source/locked").path)
            try? fileManager.removeItem(at: rootURL)
        }
        let source = rootURL.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("skills/toastty", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try "body".write(to: nested.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let script = source.appendingPathComponent("forwarder.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try fileManager.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "forwarder.sh")
        let locked = source.appendingPathComponent("locked", isDirectory: true)
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: false)
        try "x".write(to: locked.appendingPathComponent("inside"), atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        let destination = rootURL.appendingPathComponent("copy", isDirectory: true)
        try BundledResourceCopier.copyItem(at: source, to: destination, fileManager: fileManager)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.appendingPathComponent("locked").path)
        }

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("skills/toastty/SKILL.md"), encoding: .utf8),
            "body"
        )
        XCTAssertEqual(try permissions(destination.appendingPathComponent("forwarder.sh")), 0o755)
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("link").path),
            "forwarder.sh"
        )
        XCTAssertEqual(try permissions(destination.appendingPathComponent("locked")), 0o555)
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent("locked/inside").path))
        XCTAssertThrowsError(
            try BundledResourceCopier.copyItem(at: source, to: destination, fileManager: fileManager)
        )
    }

    private func permissions(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class HelpExecutor: CodexPluginCLIExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<String, Error>
    private var storage: [[String]] = []

    init(result: Result<String, Error>) {
        self.result = result
    }

    var calls: [[String]] {
        lock.withLock { storage }
    }

    func execute(runtime _: CodexIntegrationRuntime, arguments: [String], deadline _: Date) throws -> Data {
        lock.withLock { storage.append(arguments) }
        return Data(try result.get().utf8)
    }
}
