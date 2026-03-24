import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct AgentLaunchServiceTests {
    @Test
    func defaultCLIExecutablePathPrefersBundledHelperCLIOverOtherFallbacks() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeExecutableFile(at: fixture.bundledHelperCLIURL)
        try makeExecutableFile(at: fixture.legacyBundledCLIURL)
        try makeExecutableFile(at: fixture.siblingCLIURL)

        let resolvedPath = AgentLaunchService.resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.bundledHelperCLIURL.path)
    }

    @Test
    func defaultCLIExecutablePathFallsBackToLegacyBundledCLIWhenHelperCopyIsMissing() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeExecutableFile(at: fixture.legacyBundledCLIURL)
        try makeExecutableFile(at: fixture.siblingCLIURL)

        let resolvedPath = AgentLaunchService.resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.legacyBundledCLIURL.path)
    }

    @Test
    func defaultCLIExecutablePathFallsBackToSiblingCLIWhenBundleCopyIsMissing() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeExecutableFile(at: fixture.siblingCLIURL)

        let resolvedPath = AgentLaunchService.resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.siblingCLIURL.path)
    }

    @Test
    func defaultCLIExecutablePathDoesNotMistakeAppExecutableForLegacyCLI() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeExecutableFile(at: fixture.executableURL)
        try makeExecutableFile(at: fixture.siblingCLIURL)

        let resolvedPath = AgentLaunchService.resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.siblingCLIURL.path)
    }

    @Test
    func defaultCLIExecutablePathSkipsNonExecutableBundledHelper() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeFile(at: fixture.bundledHelperCLIURL, executable: false)
        try makeExecutableFile(at: fixture.siblingCLIURL)

        let resolvedPath = AgentLaunchService.resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.siblingCLIURL.path)
    }

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
        #expect(activeSession.usesSessionStatusNotifications)
        #expect(activeSession.status == SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"))
        #expect(store.hasEverLaunchedAgent)

        let injectedCommand = try #require(terminalRouter.sentTextByPanelID[panelID])
        #expect(injectedCommand.contains("TOASTTY_SESSION_ID=\(result.sessionID)"))
        #expect(injectedCommand.contains("TOASTTY_PANEL_ID=\(panelID.uuidString)"))
        #expect(injectedCommand.contains("TOASTTY_SOCKET_PATH=/tmp/toastty-tests.sock"))
        #expect(injectedCommand.contains("TOASTTY_CLI_PATH=/bin/sh"))
        #expect(injectedCommand.contains("TOASTTY_CWD=\(cwd)"))
        #expect(injectedCommand.contains("TOASTTY_REPO_ROOT=\(projectRoot.path)"))
        #expect(injectedCommand.contains("CODEX_TUI_RECORD_SESSION=1"))
        #expect(injectedCommand.contains("CODEX_TUI_SESSION_LOG_PATH="))
        #expect(injectedCommand.contains("codex -c "))
        #expect(injectedCommand.contains("notify=[\"/bin/sh\",\""))
        #expect(injectedCommand.contains("codex-notify.sh"))
        #expect(injectedCommand.contains("\\/") == false)
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
        #expect(store.hasEverLaunchedAgent == false)
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

    private func makeCLIResolutionFixture() throws -> (
        rootURL: URL,
        bundleURL: URL,
        executableURL: URL,
        bundledHelperCLIURL: URL,
        legacyBundledCLIURL: URL,
        siblingCLIURL: URL
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-cli-resolution-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = rootURL.appendingPathComponent("Toastty.app", isDirectory: true)
        let executableURL = bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("Toastty", isDirectory: false)
        let bundledHelperCLIURL = bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("toastty", isDirectory: false)
        let legacyBundledCLIURL = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("toastty", isDirectory: false)
        let siblingCLIURL = rootURL.appendingPathComponent("toastty", isDirectory: false)

        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundledHelperCLIURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        return (rootURL, bundleURL, executableURL, bundledHelperCLIURL, legacyBundledCLIURL, siblingCLIURL)
    }

    private func makeExecutableFile(at url: URL) throws {
        try makeFile(at: url, executable: true)
    }

    private func makeFile(at url: URL, executable: Bool) throws {
        let contents = Data("#!/bin/sh\nexit 0\n".utf8)
        FileManager.default.createFile(atPath: url.path, contents: contents)
        let permissions: NSNumber = executable ? 0o755 : 0o644
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
