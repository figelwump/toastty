import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct AgentLaunchServiceTests {
    @Test
    func launchInjectsInternalLauncherCommandAndToasttyContext() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let terminalRouter = TestTerminalCommandRouter()

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let projectRoot = try makeProjectRoot()
        let cwd = projectRoot.appendingPathComponent("Packages/toastty", isDirectory: true).path
        _ = store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: cwd))

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            socketPath: "/tmp/toastty socket.sock",
            cliExecutablePathProvider: { "/bin/sh" }
        )

        let result = try service.launch(agent: .codex)

        #expect(result.agent == .codex)
        #expect(result.panelID == panelID)
        #expect(result.cwd == cwd)
        #expect(result.repoRoot == projectRoot.path)

        let injectedCommand = try #require(terminalRouter.sentTextByPanelID[panelID])
        #expect(injectedCommand.contains("/bin/sh"))
        #expect(injectedCommand.contains(ToasttyInternalCommand.agentLaunch))
        #expect(injectedCommand.contains("--agent codex"))
        #expect(injectedCommand.contains("--panel \(panelID.uuidString)"))
        #expect(injectedCommand.contains("--session \(result.sessionID)"))
        #expect(injectedCommand.contains("--socket-path '/tmp/toastty socket.sock'"))
        #expect(injectedCommand.contains("--cwd \(cwd)"))
        #expect(injectedCommand.contains("--repo-root \(projectRoot.path)"))
        #expect(injectedCommand.contains("-- codex"))
        #expect(injectedCommand.hasSuffix("codex\n"))
    }

    @Test
    func launchRejectsBusyPanels() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultVisibleText = "vishal ~/toastty % npm run dev"

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            socketPath: "/tmp/toastty.sock",
            cliExecutablePathProvider: { "/bin/sh" }
        )

        #expect(throws: AgentLaunchError.panelBusy(runningCommand: "npm run dev")) {
            try service.launch(agent: .claude)
        }
    }

    private func makeProjectRoot() throws -> URL {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-agent-tests-\(UUID().uuidString)", isDirectory: true)
        let nestedDirectory = projectRoot.appendingPathComponent("Packages/toastty", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: projectRoot.appendingPathComponent(".git", isDirectory: false).path,
            contents: Data("gitdir: /tmp/fake-worktree".utf8)
        )
        return projectRoot
    }
}
