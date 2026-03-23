@testable import CoreState
import Foundation
import Testing

struct AutomationTests {
    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    @Test
    func parseAutomationConfigFromArgumentsAndEnvironment() throws {
        let config = try #require(
            AutomationConfig.parse(
                arguments: [
                    "toastty",
                    "--automation",
                    "--run-id", "chunk-b",
                    "--fixture", "two-workspaces",
                    "--artifacts-dir", "/tmp/toastty-artifacts",
                ],
                environment: [
                    "TOASTTY_DISABLE_ANIMATIONS": "1",
                    "TOASTTY_FIXED_LOCALE": "en_US_POSIX",
                    "TOASTTY_FIXED_TIMEZONE": "UTC",
                ]
            )
        )

        #expect(config.runID == "chunk-b")
        #expect(config.fixtureName == "two-workspaces")
        #expect(config.artifactsDirectory == "/tmp/toastty-artifacts")
        #expect(config.socketPath.contains("/events-v1-"))
        #expect(config.socketPath.hasSuffix(".sock"))
        #expect(config.disableAnimations == true)
        #expect(config.fixedLocaleIdentifier == "en_US_POSIX")
        #expect(config.fixedTimeZoneIdentifier == "UTC")
    }

    @Test
    func parseAutomationConfigReturnsNilWhenDisabled() {
        #expect(
            AutomationConfig.parse(arguments: ["toastty"], environment: [:]) == nil
        )
    }

    @Test
    func parseAutomationConfigSupportsFixtureFromEnvironmentAndDisableAnimationsArgument() throws {
        let config = try #require(
            AutomationConfig.parse(
                arguments: [
                    "toastty",
                    "--automation",
                    "--disable-animations",
                ],
                environment: [
                    "TOASTTY_FIXTURE": "split-workspace",
                ]
            )
        )

        #expect(config.fixtureName == "split-workspace")
        #expect(config.disableAnimations == true)
        #expect(config.artifactsDirectory != nil)
        #expect(config.socketPath.contains("/events-v1-"))
        #expect(config.socketPath.hasSuffix(".sock"))
    }

    @Test
    func parseAutomationConfigSupportsExplicitSocketPath() throws {
        let config = try #require(
            AutomationConfig.parse(
                arguments: [
                    "toastty",
                    "--automation",
                    "--socket-path", "/tmp/custom-toastty.sock",
                ],
                environment: [:]
            )
        )

        #expect(config.socketPath == "/tmp/custom-toastty.sock")
    }

    @Test
    func parseAutomationConfigUsesRuntimeHomeSocketPathByDefault() throws {
        let environment = [
            "TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-home-tests/runtime-home",
            "TMPDIR": "/tmp/toastty-runtime-home-tests/tmp/",
        ]
        let config = try #require(
            AutomationConfig.parse(
                arguments: ["toastty", "--automation"],
                environment: environment
            )
        )

        #expect(
            config.socketPath == ToasttyRuntimePaths.resolve(environment: environment).automationSocketFileURL?.path
        )
    }

    @Test
    func parseAutomationConfigUsesWorktreeDerivedSocketPathByDefault() throws {
        let environment = [
            "TOASTTY_DEV_WORKTREE_ROOT": "/tmp/toastty-runtime-home-tests/worktrees/main",
            "TMPDIR": "/tmp/toastty-runtime-home-tests/tmp/",
        ]
        let config = try #require(
            AutomationConfig.parse(
                arguments: ["toastty", "--automation"],
                environment: environment
            )
        )

        #expect(
            config.socketPath == ToasttyRuntimePaths.resolve(environment: environment).automationSocketFileURL?.path
        )
    }

    @Test
    func parseAutomationConfigAcceptsTruthyEnvironmentFlags() throws {
        let config = try #require(
            AutomationConfig.parse(
                arguments: ["toastty"],
                environment: [
                    "TOASTTY_AUTOMATION": "true",
                    "TOASTTY_DISABLE_ANIMATIONS": "on",
                ]
            )
        )

        #expect(config.disableAnimations == true)
    }

    @Test
    func resolveServerSocketPathUsesPerProcessDefault() {
        let environment = ["TMPDIR": "/tmp/toastty-automation-tests"]

        let path = AutomationConfig.resolveServerSocketPath(
            environment: environment,
            processID: 4242
        )

        #expect(path.hasSuffix("/toastty-\(getuid())/events-v1-4242.sock"))
    }

    @Test
    func resolveSocketPathUsesDiscoveryRecordWhenAvailable() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-automation-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let environment = ["TMPDIR": tempDirectory.path]
        let processID = getpid()
        let socketPath = AutomationSocketLocator.socketDirectoryURL(environment: environment)
            .appendingPathComponent("events-v1-\(processID).sock", isDirectory: false)
            .path
        try FileManager.default.createDirectory(
            at: AutomationSocketLocator.socketDirectoryURL(environment: environment),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        try AutomationSocketLocator.writeDiscoveryRecord(
            socketPath: socketPath,
            processID: processID,
            environment: environment
        )

        #expect(AutomationConfig.resolveSocketPath(environment: environment) == socketPath)
    }

    @Test
    func discoveryRecordIsUsableRequiresLiveOwner() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-automation-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let environment = ["TMPDIR": tempDirectory.path]
        let socketPath = AutomationSocketLocator.socketDirectoryURL(environment: environment)
            .appendingPathComponent("events-v1-9999.sock", isDirectory: false)
            .path
        try FileManager.default.createDirectory(
            at: AutomationSocketLocator.socketDirectoryURL(environment: environment),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: socketPath, contents: Data())

        let record = AutomationSocketDiscoveryRecord(socketPath: socketPath, processID: 9999)

        #expect(
            AutomationSocketLocator.discoveryRecordIsUsable(
                record,
                processIsAlive: { _ in true }
            )
        )
        #expect(
            !AutomationSocketLocator.discoveryRecordIsUsable(
                record,
                processIsAlive: { _ in false }
            )
        )
    }

    @Test
    func resolveSocketPathFallsBackToLegacyPathWhenDiscoveryRecordIsStale() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-automation-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let environment = ["TMPDIR": tempDirectory.path]
        try AutomationSocketLocator.writeDiscoveryRecord(
            socketPath: "/tmp/does-not-exist.sock",
            processID: 8888,
            environment: environment
        )

        #expect(
            AutomationConfig.resolveSocketPath(environment: environment)
                == AutomationSocketLocator.legacySocketPath(environment: environment)
        )
    }

    @Test
    func resolveSocketPathFallsBackToLegacyPathWhenDiscoveryOwnerIsDead() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-automation-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let environment = ["TMPDIR": tempDirectory.path]
        let socketPath = AutomationSocketLocator.socketDirectoryURL(environment: environment)
            .appendingPathComponent("events-v1-1234.sock", isDirectory: false)
            .path
        try FileManager.default.createDirectory(
            at: AutomationSocketLocator.socketDirectoryURL(environment: environment),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        try AutomationSocketLocator.writeDiscoveryRecord(
            socketPath: socketPath,
            processID: -1,
            environment: environment
        )

        #expect(
            AutomationConfig.resolveSocketPath(environment: environment)
                == AutomationSocketLocator.legacySocketPath(environment: environment)
        )
    }

    @Test
    func latestLiveSocketPathUsesMostRecentLiveCandidate() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-automation-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let environment = ["TMPDIR": tempDirectory.path]
        let directoryURL = AutomationSocketLocator.socketDirectoryURL(environment: environment)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let olderSocketURL = directoryURL.appendingPathComponent("events-v1-1111.sock", isDirectory: false)
        let newerSocketURL = directoryURL.appendingPathComponent("events-v1-2222.sock", isDirectory: false)
        FileManager.default.createFile(atPath: olderSocketURL.path, contents: Data())
        FileManager.default.createFile(atPath: newerSocketURL.path, contents: Data())
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: olderSocketURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 20)],
            ofItemAtPath: newerSocketURL.path
        )

        let resolvedPath = AutomationSocketLocator.latestLiveSocketPath(
            environment: environment,
            processIsAlive: { processID in processID == 1111 || processID == 2222 }
        )

        #expect(standardizedPath(resolvedPath ?? "") == standardizedPath(newerSocketURL.path))
    }

    @Test
    func resolveSocketPathFallsBackToLiveSocketScanWhenDiscoveryRecordIsMissing() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-automation-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let environment = ["TMPDIR": tempDirectory.path]
        let directoryURL = AutomationSocketLocator.socketDirectoryURL(environment: environment)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let socketURL = directoryURL.appendingPathComponent("events-v1-\(getpid()).sock", isDirectory: false)
        FileManager.default.createFile(atPath: socketURL.path, contents: Data())

        #expect(
            standardizedPath(AutomationConfig.resolveSocketPath(environment: environment))
                == standardizedPath(socketURL.path)
        )
    }

    @Test
    func resolveSocketPathFallsBackToLiveSocketScanWhenDiscoveryRecordOwnerIsDead() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-automation-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let environment = ["TMPDIR": tempDirectory.path]
        let directoryURL = AutomationSocketLocator.socketDirectoryURL(environment: environment)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fallbackSocketURL = directoryURL.appendingPathComponent("events-v1-\(getpid()).sock", isDirectory: false)
        FileManager.default.createFile(atPath: fallbackSocketURL.path, contents: Data())

        try AutomationSocketLocator.writeDiscoveryRecord(
            socketPath: directoryURL.appendingPathComponent("events-v1-999999.sock", isDirectory: false).path,
            processID: -1,
            environment: environment
        )

        #expect(
            standardizedPath(AutomationConfig.resolveSocketPath(environment: environment))
                == standardizedPath(fallbackSocketURL.path)
        )
    }

    @Test
    func removeDiscoveryRecordLeavesNewerOwnerInPlace() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-automation-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let environment = ["TMPDIR": tempDirectory.path]
        try AutomationSocketLocator.writeDiscoveryRecord(
            socketPath: "/tmp/toastty-new.sock",
            processID: 2222,
            environment: environment
        )

        AutomationSocketLocator.removeDiscoveryRecordIfOwned(
            socketPath: "/tmp/toastty-old.sock",
            processID: 1111,
            environment: environment
        )

        #expect(
            AutomationSocketLocator.readDiscoveryRecord(environment: environment)
                == AutomationSocketDiscoveryRecord(
                    socketPath: "/tmp/toastty-new.sock",
                    processID: 2222
                )
        )
    }

    @Test
    func shouldBypassQuitConfirmationForAutomationAndExplicitSkipFlag() {
        #expect(
            AutomationConfig.shouldBypassQuitConfirmation(
                arguments: ["toastty", "--automation"],
                environment: [:]
            )
        )
        #expect(
            AutomationConfig.shouldBypassQuitConfirmation(
                arguments: ["toastty"],
                environment: ["TOASTTY_AUTOMATION": "true"]
            )
        )
        #expect(
            AutomationConfig.shouldBypassQuitConfirmation(
                arguments: ["toastty", "--skip-quit-confirmation"],
                environment: [:]
            )
        )
        #expect(
            AutomationConfig.shouldBypassQuitConfirmation(
                arguments: ["toastty"],
                environment: ["TOASTTY_SKIP_QUIT_CONFIRMATION": "yes"]
            )
        )
    }

    @Test
    func shouldBypassQuitConfirmationIsFalseByDefault() {
        #expect(
            AutomationConfig.shouldBypassQuitConfirmation(
                arguments: ["toastty"],
                environment: [:]
            ) == false
        )
    }

    @Test
    func twoWorkspaceFixtureLoadsExpectedShape() throws {
        let fixture = try #require(AutomationFixtureLoader.load(named: "two-workspaces"))

        #expect(fixture.windows.count == 1)
        let window = try #require(fixture.windows.first)
        #expect(window.workspaceIDs.count == 2)
        #expect(window.selectedWorkspaceID == window.workspaceIDs.first)

        for workspaceID in window.workspaceIDs {
            #expect(fixture.workspacesByID[workspaceID] != nil)
        }

        try StateValidator.validate(fixture)
    }

    @Test
    func loadRequiredFixtureThrowsForUnknownFixture() {
        #expect(throws: AutomationFixtureError.unknownFixture("not-real")) {
            _ = try AutomationFixtureLoader.loadRequired(named: "not-real")
        }
    }
}
