@testable import CoreState
import Foundation
import Testing

struct ToasttyLogConfigurationTests {
    @Test
    func defaultConfigurationUsesInfoLevelAndLibraryLogFile() {
        let config = ToasttyLogConfiguration.fromEnvironment([:])

        #expect(config.enabled == true)
        #expect(config.minimumLevel == .info)
        #expect(config.filePath?.hasSuffix("/Library/Logs/Toastty/toastty.log") == true)
        #expect(config.mirrorToStderr == false)
    }

    @Test
    func environmentOverridesConfiguration() {
        let config = ToasttyLogConfiguration.fromEnvironment([
            "TOASTTY_LOG_DISABLE": "1",
            "TOASTTY_LOG_LEVEL": "debug",
            "TOASTTY_LOG_FILE": "/tmp/custom-toastty.log",
            "TOASTTY_LOG_STDERR": "true",
        ])

        #expect(config.enabled == false)
        #expect(config.minimumLevel == .debug)
        #expect(config.filePath == "/tmp/custom-toastty.log")
        #expect(config.mirrorToStderr == true)
    }

    @Test
    func noneLogFileDisablesFileSink() {
        let config = ToasttyLogConfiguration.fromEnvironment([
            "TOASTTY_LOG_FILE": "none",
        ])

        #expect(config.filePath == nil)
    }

    @Test
    func xctestProcessesDisableDefaultFileSink() {
        let config = ToasttyLogConfiguration.fromEnvironment(
            [
                "TOASTTY_DEV_WORKTREE_ROOT": "/tmp/toastty-runtime-log-tests/worktrees/main",
                "XCTestConfigurationFilePath": "/tmp/toastty-tests.xctestconfiguration",
            ],
            homeDirectoryPath: "/tmp/ignored-home"
        )

        #expect(config.filePath == nil)
    }

    @Test
    func xctestProcessesHonorExplicitLogFilePath() {
        let config = ToasttyLogConfiguration.fromEnvironment(
            [
                "TOASTTY_LOG_FILE": "/tmp/toastty-test-debug.log",
                "TOASTTY_DEV_WORKTREE_ROOT": "/tmp/toastty-runtime-log-tests/worktrees/main",
                "XCTestConfigurationFilePath": "/tmp/toastty-tests.xctestconfiguration",
            ],
            homeDirectoryPath: "/tmp/ignored-home"
        )

        #expect(config.filePath == "/tmp/toastty-test-debug.log")
    }

    @Test
    func xctestProcessesKeepExplicitLogFileDisablement() {
        let config = ToasttyLogConfiguration.fromEnvironment(
            [
                "TOASTTY_LOG_FILE": "none",
                "TOASTTY_DEV_WORKTREE_ROOT": "/tmp/toastty-runtime-log-tests/worktrees/main",
                "XCTestConfigurationFilePath": "/tmp/toastty-tests.xctestconfiguration",
            ],
            homeDirectoryPath: "/tmp/ignored-home"
        )

        #expect(config.filePath == nil)
    }

    @Test
    func xctestProcessesHonorLogToFileOptIn() {
        let config = ToasttyLogConfiguration.fromEnvironment(
            [
                "TOASTTY_LOG_TO_FILE": "1",
                "TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-log-tests/runtime-home",
                "XCTestConfigurationFilePath": "/tmp/toastty-tests.xctestconfiguration",
            ],
            homeDirectoryPath: "/tmp/ignored-home"
        )

        #expect(config.filePath == "/tmp/toastty-runtime-log-tests/runtime-home/logs/toastty.log")
    }

    @Test
    func runtimeHomeChangesDefaultLogPath() {
        let config = ToasttyLogConfiguration.fromEnvironment(
            ["TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-log-tests/runtime-home"],
            homeDirectoryPath: "/tmp/ignored-home"
        )

        #expect(config.filePath == "/tmp/toastty-runtime-log-tests/runtime-home/logs/toastty.log")
    }

    @Test
    func worktreeRootChangesDefaultLogPath() {
        let config = ToasttyLogConfiguration.fromEnvironment(
            ["TOASTTY_DEV_WORKTREE_ROOT": "/tmp/toastty-runtime-log-tests/worktrees/main"],
            homeDirectoryPath: "/tmp/ignored-home"
        )

        #expect(config.filePath?.contains("/tmp/toastty-runtime-log-tests/worktrees/main/artifacts/dev-runs/worktree-main-") == true)
        #expect(config.filePath?.hasSuffix("/runtime-home/logs/toastty.log") == true)
    }
}

struct ToasttyLogWriterTests {
    @Test
    func writerReopensCurrentFileAfterAnotherWriterRotatesIt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("toastty.log")
        let previousURL = directory.appendingPathComponent("toastty.previous.log")
        let firstWriter = makeWriter(logURL: logURL, maxBytes: 520)
        let rotatingWriter = makeWriter(logURL: logURL, maxBytes: 520)

        write("first-writer-before-rotation", fillerCount: 220, with: firstWriter)
        write("rotating-writer", fillerCount: 220, with: rotatingWriter)
        write("first-writer-after-rotation", with: firstWriter)

        let current = try String(contentsOf: logURL, encoding: .utf8)
        let previous = try String(contentsOf: previousURL, encoding: .utf8)
        #expect(previous.contains("first-writer-before-rotation"))
        #expect(previous.contains("rotating-writer") == false)
        #expect(previous.contains("first-writer-after-rotation") == false)
        #expect(current.contains("rotating-writer"))
        #expect(current.contains("first-writer-after-rotation"))
    }

    @Test
    func writerRecoversWhenAnExternalProcessMovesItsOpenFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("toastty.log")
        let previousURL = directory.appendingPathComponent("toastty.previous.log")
        let writer = makeWriter(logURL: logURL, maxBytes: 10_000)

        write("before-external-rotation", with: writer)
        try run("/bin/mv", arguments: [logURL.path, previousURL.path])
        try run("/usr/bin/touch", arguments: [logURL.path])
        write("after-external-rotation", with: writer)

        let current = try String(contentsOf: logURL, encoding: .utf8)
        let previous = try String(contentsOf: previousURL, encoding: .utf8)
        #expect(previous.contains("before-external-rotation"))
        #expect(previous.contains("after-external-rotation") == false)
        #expect(current.contains("after-external-rotation"))
    }

    @Test
    func oversizedRecordIsWrittenThenRotatedBeforeTheNextRecord() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("toastty.log")
        let previousURL = directory.appendingPathComponent("toastty.previous.log")
        let writer = makeWriter(logURL: logURL, maxBytes: 180)

        write("oversized-record", fillerCount: 400, with: writer)
        #expect(FileManager.default.fileExists(atPath: previousURL.path) == false)
        write("record-after-oversized", with: writer)

        let current = try String(contentsOf: logURL, encoding: .utf8)
        let previous = try String(contentsOf: previousURL, encoding: .utf8)
        #expect(previous.contains("oversized-record"))
        #expect(current.contains("record-after-oversized"))
    }

    @Test
    func unavailableRotationLockFallsBackToBoundedRotation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("toastty.log")
        let previousURL = directory.appendingPathComponent("toastty.previous.log")
        try FileManager.default.createDirectory(
            at: logURL.appendingPathExtension("lock"),
            withIntermediateDirectories: false
        )
        let writer = makeWriter(logURL: logURL, maxBytes: 180)

        write("first-without-lock", fillerCount: 180, with: writer)
        write("second-without-lock", with: writer)

        let current = try String(contentsOf: logURL, encoding: .utf8)
        let previous = try String(contentsOf: previousURL, encoding: .utf8)
        #expect(previous.contains("first-without-lock"))
        #expect(current.contains("first-without-lock") == false)
        #expect(current.contains("second-without-lock"))
    }

    @Test
    func writerRecreatesADeletedCurrentFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("toastty.log")
        let writer = makeWriter(logURL: logURL, maxBytes: 10_000)

        write("before-delete", with: writer)
        try FileManager.default.removeItem(at: logURL)
        write("after-delete", with: writer)

        let current = try String(contentsOf: logURL, encoding: .utf8)
        #expect(current.contains("before-delete") == false)
        #expect(current.contains("after-delete"))
    }

    private func makeWriter(logURL: URL, maxBytes: UInt64) -> ToasttyLogWriter {
        ToasttyLogWriter(configuration: ToasttyLogConfiguration(
            enabled: true,
            minimumLevel: .debug,
            filePath: logURL.path,
            mirrorToStderr: false,
            maxFileSizeBytes: maxBytes
        ))
    }

    private func write(
        _ marker: String,
        fillerCount: Int = 0,
        with writer: ToasttyLogWriter
    ) {
        writer.write(
            level: .info,
            category: .state,
            message: marker + String(repeating: "x", count: fillerCount),
            metadata: [:],
            source: "ToasttyLogWriterTests"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "toastty-log-writer-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
