import CoreState
import Foundation
import Testing

struct ToasttyRuntimePathsTests {
    @Test
    func resolveDefaultsToHomeBackedLocations() {
        let panelID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let paths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-home",
            environment: [:]
        )

        #expect(paths.isRuntimeHomeEnabled == false)
        #expect(paths.runtimeHomeStrategy == .userHome)
        #expect(paths.worktreeRootURL == nil)
        #expect(paths.runtimeLabel == nil)
        #expect(paths.configFileURL.path == "/tmp/toastty-home/.toastty/config")
        #expect(paths.workspaceLayoutsFileURL.path == "/tmp/toastty-home/.toastty/workspace-layout-profiles.json")
        #expect(paths.terminalProfilesFileURL.path == "/tmp/toastty-home/.toastty/terminal-profiles.toml")
        #expect(paths.agentShimDirectoryURL.path == "/tmp/toastty-home/.toastty/bin")
        #expect(paths.paneHistoryDirectoryURL.path == "/tmp/toastty-home/.toastty/history/panes")
        #expect(paths.paneHistoryFileURL(for: panelID).path == "/tmp/toastty-home/.toastty/history/panes/11111111-1111-1111-1111-111111111111.history")
        #expect(paths.paneJournalDirectoryURL.path == "/tmp/toastty-home/.toastty/history/pane-journals")
        #expect(paths.paneJournalFileURL(for: panelID).path == "/tmp/toastty-home/.toastty/history/pane-journals/11111111-1111-1111-1111-111111111111.journal")
        #expect(paths.defaultLogFileURL.path == "/tmp/toastty-home/Library/Logs/Toastty/toastty.log")
        #expect(paths.automationSocketFileURL == nil)
        #expect(paths.userDefaultsSuiteName == nil)
    }

    @Test
    func resolveRuntimeHomeUsesSandboxedLocationsAndStableSuite() throws {
        let panelID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
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
        #expect(first.runtimeHomeStrategy == .explicitRuntimeHome)
        #expect(first.runtimeLabel == nil)
        #expect(first.configFileURL.path == "\(runtimeHomePath)/config")
        #expect(first.workspaceLayoutsFileURL.path == "\(runtimeHomePath)/workspace-layout-profiles.json")
        #expect(first.terminalProfilesFileURL.path == "\(runtimeHomePath)/terminal-profiles.toml")
        #expect(first.agentShimDirectoryURL.path == "\(runtimeHomePath)/bin")
        #expect(first.paneHistoryDirectoryURL.path == "\(runtimeHomePath)/history/panes")
        #expect(first.paneHistoryFileURL(for: panelID).path == "\(runtimeHomePath)/history/panes/22222222-2222-2222-2222-222222222222.history")
        #expect(first.paneJournalDirectoryURL.path == "\(runtimeHomePath)/history/pane-journals")
        #expect(first.paneJournalFileURL(for: panelID).path == "\(runtimeHomePath)/history/pane-journals/22222222-2222-2222-2222-222222222222.journal")
        #expect(first.defaultLogFileURL.path == "\(runtimeHomePath)/logs/toastty.log")
        #expect(first.automationSocketFileURL?.path.hasSuffix("/events-v1.sock") == true)
        #expect(first.automationSocketFileURL?.path.contains("toastty-runtime-") == true)
        let firstSuiteName = try #require(first.userDefaultsSuiteName)
        let secondSuiteName = try #require(second.userDefaultsSuiteName)
        #expect(firstSuiteName == secondSuiteName)
    }

    @Test
    func resolveWorktreeRootDerivesStableRuntimeHome() throws {
        let worktreeRootPath = "/tmp/Toastty Runtime/main"
        let environment = ["TOASTTY_DEV_WORKTREE_ROOT": worktreeRootPath]
        let first = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: environment
        )
        let second = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: environment
        )

        #expect(first.runtimeHomeStrategy == .worktreeDerived)
        #expect(first.worktreeRootURL?.path == worktreeRootPath)
        let firstLabel = try #require(first.runtimeLabel)
        let secondLabel = try #require(second.runtimeLabel)
        #expect(firstLabel == secondLabel)
        #expect(firstLabel.hasPrefix("main-"))
        #expect(first.runtimeHomeURL?.path == "\(worktreeRootPath)/artifacts/dev-runs/worktree-\(firstLabel)/runtime-home")
        #expect(first.configFileURL.path == "\(worktreeRootPath)/artifacts/dev-runs/worktree-\(firstLabel)/runtime-home/config")
        #expect(first.agentShimDirectoryURL.path == "\(worktreeRootPath)/artifacts/dev-runs/worktree-\(firstLabel)/runtime-home/bin")
    }

    @Test
    func explicitRuntimeHomeOverridesWorktreeFallback() {
        let paths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: [
                "TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-home-tests/explicit",
                "TOASTTY_DEV_WORKTREE_ROOT": "/tmp/toastty-runtime-home-tests/worktree",
            ]
        )

        #expect(paths.runtimeHomeStrategy == .explicitRuntimeHome)
        #expect(paths.runtimeHomeURL?.path == "/tmp/toastty-runtime-home-tests/explicit")
        #expect(paths.worktreeRootURL?.path == "/tmp/toastty-runtime-home-tests/worktree")
        #expect(paths.runtimeLabel == nil)
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
        #expect(FileManager.default.fileExists(atPath: runtimeHomeURL.appendingPathComponent("bin").path))
        #expect(FileManager.default.fileExists(atPath: runtimeHomeURL.appendingPathComponent("history/panes").path))
        #expect(FileManager.default.fileExists(atPath: runtimeHomeURL.appendingPathComponent("history/pane-journals").path))
        let versionFileURL = runtimeHomeURL.appendingPathComponent("runtime-version.txt", isDirectory: false)
        let versionContents = try String(contentsOf: versionFileURL, encoding: .utf8)
        #expect(versionContents == "1\n")
    }
}
