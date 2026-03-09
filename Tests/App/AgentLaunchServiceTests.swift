import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct AgentLaunchServiceTests {
    @Test
    func launchInjectsToasttyContextAndStartsSession() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let projectRoot = try makeProjectRoot()
        let cwd = projectRoot.appendingPathComponent("Packages/toastty", isDirectory: true).path
        _ = store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: cwd))

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            socketPath: "/tmp/toastty socket.sock",
            nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) },
            cliExecutablePathProvider: { "/bin/sh" }
        )

        let result = try service.launch(agent: .codex)
        let activeSession = try #require(sessionRuntimeStore.sessionRegistry.activeSession(sessionID: result.sessionID))

        #expect(result.agent == .codex)
        #expect(result.panelID == panelID)
        #expect(result.cwd == cwd)
        #expect(result.repoRoot == projectRoot.path)
        #expect(activeSession.panelID == panelID)
        #expect(activeSession.cwd == cwd)
        #expect(activeSession.repoRoot == projectRoot.path)

        let injectedCommand = try #require(terminalRouter.sentTextByPanelID[panelID])
        #expect(injectedCommand.contains("TOASTTY_AGENT=codex"))
        #expect(injectedCommand.contains("TOASTTY_PANEL_ID=\(panelID.uuidString)"))
        #expect(injectedCommand.contains("TOASTTY_SESSION_ID=\(result.sessionID)"))
        #expect(injectedCommand.contains("TOASTTY_SOCKET_PATH='/tmp/toastty socket.sock'"))
        #expect(injectedCommand.contains("TOASTTY_CWD=\(cwd)"))
        #expect(injectedCommand.contains("TOASTTY_REPO_ROOT=\(projectRoot.path)"))
        #expect(injectedCommand.contains("TOASTTY_CLI_PATH=/bin/sh"))
        #expect(injectedCommand.hasSuffix("codex\n"))
    }

    @Test
    func launchRejectsBusyPanels() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultVisibleText = "vishal ~/toastty % npm run dev"

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
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
