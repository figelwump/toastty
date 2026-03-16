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
        let agentCatalogProvider = TestAgentCatalogProvider()

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let projectRoot = try makeProjectRoot()
        let cwd = projectRoot.appendingPathComponent("Packages/toastty", isDirectory: true).path
        _ = store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: cwd))

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) },
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" }
        )

        let result = try service.launch(profileID: "codex")
        let activeSession = try #require(sessionRuntimeStore.sessionRegistry.activeSession(sessionID: result.sessionID))

        #expect(result.agent == .codex)
        #expect(result.displayName == "Codex")
        #expect(result.panelID == panelID)
        #expect(result.cwd == cwd)
        #expect(result.repoRoot == projectRoot.path)
        #expect(activeSession.panelID == panelID)
        #expect(activeSession.cwd == cwd)
        #expect(activeSession.repoRoot == projectRoot.path)
        #expect(activeSession.status == SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"))

        let injectedCommand = try #require(terminalRouter.sentTextByPanelID[panelID])
        #expect(injectedCommand.contains("TOASTTY_AGENT=codex"))
        #expect(injectedCommand.contains("TOASTTY_SESSION_ID=\(result.sessionID)"))
        #expect(injectedCommand.contains("TOASTTY_PANEL_ID=\(panelID.uuidString)"))
        #expect(injectedCommand.contains("TOASTTY_SOCKET_PATH=/tmp/toastty-tests.sock"))
        #expect(injectedCommand.contains("TOASTTY_CLI_PATH=/bin/sh"))
        #expect(injectedCommand.contains("TOASTTY_CWD=\(cwd)"))
        #expect(injectedCommand.contains("TOASTTY_REPO_ROOT=\(projectRoot.path)"))
        #expect(injectedCommand.contains("CODEX_TUI_RECORD_SESSION=1"))
        #expect(injectedCommand.contains("CODEX_TUI_SESSION_LOG_PATH="))
        #expect(injectedCommand.contains("codex -c "))
        #expect(injectedCommand.contains("notify=["))
        #expect(injectedCommand.contains("codex-notify.sh"))
        #expect(injectedCommand.contains(" agent run ") == false)
        #expect(injectedCommand.hasPrefix("exec ") == false)
        #expect(injectedCommand.hasSuffix("\n"))
    }

    @Test
    func launchRejectsBusyPanels() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultVisibleText = "vishal ~/toastty % npm run dev"
        let agentCatalogProvider = TestAgentCatalogProvider()

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" }
        )

        #expect(throws: AgentLaunchError.panelBusy(runningCommand: "npm run dev")) {
            try service.launch(profileID: "claude")
        }
    }

    @Test
    func launchQuotesDirectLaunchEnvironmentAndArgv() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        let agentCatalogProvider = TestAgentCatalogProvider(
            profiles: [
                AgentProfile(
                    id: "claude",
                    displayName: "Claude Code",
                    argv: [
                        "/Applications/Claude Code.app/Contents/MacOS/cc",
                        "--append-system-prompt=review only"
                    ]
                )
            ]
        )
        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        _ = store.send(
            .updateTerminalPanelMetadata(
                panelID: panelID,
                title: nil,
                cwd: "/tmp/toastty project/src"
            )
        )

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty sockets/test.sock" }
        )

        _ = try service.launch(profileID: "claude")

        let injectedCommand = try #require(terminalRouter.sentTextByPanelID[panelID])
        #expect(injectedCommand.contains("TOASTTY_SOCKET_PATH='/tmp/toastty sockets/test.sock'"))
        #expect(injectedCommand.contains("TOASTTY_CWD='/tmp/toastty project/src'"))
        #expect(injectedCommand.contains("TOASTTY_REPO_ROOT=") == false)
        #expect(injectedCommand.contains("'/Applications/Claude Code.app/Contents/MacOS/cc' --settings "))
        #expect(injectedCommand.contains("'--append-system-prompt=review only'"))
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
