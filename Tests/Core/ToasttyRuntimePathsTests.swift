import CoreState
import Foundation
import Testing

struct ToasttyRuntimePathsTests {
    @Test
    func resolveDefaultsToHomeBackedLocations() {
        let paths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-home",
            environment: [:]
        )

        #expect(paths.isRuntimeHomeEnabled == false)
        #expect(paths.configFileURL.path == "/tmp/toastty-home/.toastty/config")
        #expect(paths.workspaceLayoutsFileURL.path == "/tmp/toastty-home/.toastty/workspace-layout-profiles.json")
        #expect(paths.terminalProfilesFileURL.path == "/tmp/toastty-home/.toastty/terminal-profiles.toml")
        #expect(paths.defaultLogFileURL.path == "/tmp/toastty-home/Library/Logs/Toastty/toastty.log")
        #expect(paths.automationSocketFileURL == nil)
        #expect(paths.userDefaultsSuiteName == nil)
    }

    @Test
    func resolveRuntimeHomeUsesSandboxedLocationsAndStableSuite() throws {
        let runtimeHomePath = "/tmp/toastty-runtime-home-tests/runtime-a"
        let environment = ["TOASTTY_RUNTIME_HOME": runtimeHomePath]
        let first = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: environment
        )
        let second = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: environment
        )

        #expect(first.runtimeHomeURL?.path == runtimeHomePath)
        #expect(first.configFileURL.path == "\(runtimeHomePath)/config")
        #expect(first.workspaceLayoutsFileURL.path == "\(runtimeHomePath)/workspace-layout-profiles.json")
        #expect(first.terminalProfilesFileURL.path == "\(runtimeHomePath)/terminal-profiles.toml")
        #expect(first.defaultLogFileURL.path == "\(runtimeHomePath)/logs/toastty.log")
        #expect(first.automationSocketFileURL?.path.hasSuffix("/events-v1.sock") == true)
        #expect(first.automationSocketFileURL?.path.contains("toastty-runtime-") == true)
        let firstSuiteName = try #require(first.userDefaultsSuiteName)
        let secondSuiteName = try #require(second.userDefaultsSuiteName)
        #expect(firstSuiteName == secondSuiteName)
    }

    @Test
    func prepareCreatesRuntimeHomeSupportDirectories() throws {
        let runtimeHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-runtime-paths-tests-\(UUID().uuidString)", isDirectory: true)
        let paths = ToasttyRuntimePaths.resolve(
            environment: ["TOASTTY_RUNTIME_HOME": runtimeHomeURL.path]
        )

        try paths.prepare()

        #expect(FileManager.default.fileExists(atPath: runtimeHomeURL.appendingPathComponent("logs").path))
        #expect(FileManager.default.fileExists(atPath: runtimeHomeURL.appendingPathComponent("run").path))
        let versionFileURL = runtimeHomeURL.appendingPathComponent("runtime-version.txt", isDirectory: false)
        let versionContents = try String(contentsOf: versionFileURL, encoding: .utf8)
        #expect(versionContents == "1\n")
    }
}
