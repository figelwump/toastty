import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

@MainActor
final class TerminalRuntimeRegistryManagedAgentResumeTests: XCTestCase {
    func testSurfaceLaunchConfigurationUsesValidManagedAgentResumeRecordForRestoredPanel() throws {
        let fixture = try makeRuntimeResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let panelID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = AppStore(
            state: makeRuntimeResumeState(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                resumeRecord: record,
                profileBinding: TerminalProfileBinding(profileID: "zmx")
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        let profileProvider = makeRuntimeResumeProfileProvider()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let agentCatalogProvider = TestAgentCatalogProvider(
            profiles: [
                AgentProfile(
                    id: "codex",
                    displayName: "Codex",
                    argv: ["agent-safehouse", "--workdir=/tmp/repo", "codex"]
                ),
            ]
        )
        registry.setTerminalProfileProvider(profileProvider, restoredTerminalPanelIDs: [panelID])
        registry.setAgentCatalogProvider(agentCatalogProvider)
        registry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        let restoredManagedLaunchPlanner = makeRestoredManagedLaunchPlanner(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore
        )
        registry.setRestoredManagedLaunchPlanner(restoredManagedLaunchPlanner)
        registry.bind(store: store)

        let launchConfiguration = registry.surfaceLaunchConfiguration(for: panelID)

        XCTAssertTrue(try XCTUnwrap(launchConfiguration.initialInput).contains("TOASTTY_SESSION_ID="))
        XCTAssertTrue(try XCTUnwrap(launchConfiguration.initialInput).contains("TOASTTY_MANAGED_AGENT_SHIM_BYPASS=1"))
        XCTAssertTrue(try XCTUnwrap(launchConfiguration.initialInput).contains("codex -c "))
        XCTAssertTrue(try XCTUnwrap(launchConfiguration.initialInput).contains("resume 019e2823-f520-7690-91b6-cd84eb52dd8a"))
        XCTAssertEqual(launchConfiguration.workingDirectoryOverride, fixture.cwdURL.path)
        XCTAssertEqual(launchConfiguration.environmentVariables["TOASTTY_LAUNCH_REASON"], "restore")
        XCTAssertEqual(launchConfiguration.environmentVariables["TOASTTY_MANAGED_AGENT_RESUME_PROVIDER"], "codex")
        XCTAssertNil(launchConfiguration.environmentVariables["TOASTTY_TERMINAL_PROFILE_ID"])
        let activeSession = try XCTUnwrap(sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
        XCTAssertEqual(activeSession.agent, .codex)
        XCTAssertEqual(activeSession.status, SessionStatus(kind: .idle, summary: "Waiting", detail: "Resumed"))
        XCTAssertTrue(activeSession.showsResumedBadge)
    }

    func testSurfaceLaunchConfigurationUsesValidClaudeResumeRecordForRestoredPanel() throws {
        let fixture = try makeRuntimeResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let panelID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let record = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: "db4f311b-12d0-4f61-ba81-0ae44ed10492",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = AppStore(
            state: makeRuntimeResumeState(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                resumeRecord: record,
                profileBinding: nil
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let profileProvider = makeRuntimeResumeProfileProvider()
        registry.setTerminalProfileProvider(profileProvider, restoredTerminalPanelIDs: [panelID])
        registry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        let restoredManagedLaunchPlanner = makeRestoredManagedLaunchPlanner(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore
        )
        registry.setRestoredManagedLaunchPlanner(restoredManagedLaunchPlanner)
        registry.bind(store: store)

        let launchConfiguration = registry.surfaceLaunchConfiguration(for: panelID)

        let initialInput = try XCTUnwrap(launchConfiguration.initialInput)
        XCTAssertTrue(initialInput.contains("TOASTTY_SESSION_ID="))
        XCTAssertTrue(initialInput.contains("TOASTTY_MANAGED_AGENT_SHIM_BYPASS=1"))
        XCTAssertTrue(initialInput.contains("claude --settings "))
        XCTAssertTrue(initialInput.contains("--resume db4f311b-12d0-4f61-ba81-0ae44ed10492"))
        XCTAssertEqual(launchConfiguration.workingDirectoryOverride, fixture.cwdURL.path)
        let activeSession = try XCTUnwrap(sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
        XCTAssertEqual(activeSession.agent, .claude)
        XCTAssertTrue(activeSession.showsResumedBadge)
    }

    func testSurfaceLaunchConfigurationUsesValidPiResumeRecordForRestoredPanel() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }
        defer { AgentLaunchInstrumentation.piExtensionPathProviderForTesting = nil }
        let fixture = try makeRuntimeResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let panelID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let record = ManagedAgentResumeRecord(
            agent: .pi,
            nativeSessionID: "019e31af-e0ed-718b-a695-37afddc7e494",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = AppStore(
            state: makeRuntimeResumeState(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                resumeRecord: record,
                profileBinding: TerminalProfileBinding(profileID: "zmx")
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        let profileProvider = makeRuntimeResumeProfileProvider()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let agentCatalogProvider = TestAgentCatalogProvider(
            profiles: [
                AgentProfile(
                    id: "pi",
                    displayName: "Pi",
                    argv: ["agent-safehouse", "--workdir=/tmp/repo", "pi"]
                ),
            ]
        )
        registry.setTerminalProfileProvider(profileProvider, restoredTerminalPanelIDs: [panelID])
        registry.setAgentCatalogProvider(agentCatalogProvider)
        registry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        let restoredManagedLaunchPlanner = makeRestoredManagedLaunchPlanner(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore
        )
        registry.setRestoredManagedLaunchPlanner(restoredManagedLaunchPlanner)
        registry.bind(store: store)

        let launchConfiguration = registry.surfaceLaunchConfiguration(for: panelID)

        let initialInput = try XCTUnwrap(launchConfiguration.initialInput)
        XCTAssertTrue(initialInput.contains("TOASTTY_SESSION_ID="))
        XCTAssertTrue(initialInput.contains("TOASTTY_MANAGED_AGENT_SHIM_BYPASS=1"))
        XCTAssertTrue(initialInput.contains("pi --extension /toastty/pi-extension.js --session \(fixture.sessionFileURL.path)"))
        XCTAssertEqual(launchConfiguration.workingDirectoryOverride, fixture.cwdURL.path)
        XCTAssertEqual(launchConfiguration.environmentVariables["TOASTTY_LAUNCH_REASON"], "restore")
        XCTAssertEqual(launchConfiguration.environmentVariables["TOASTTY_MANAGED_AGENT_RESUME_PROVIDER"], "pi")
        XCTAssertEqual(
            launchConfiguration.environmentVariables["TOASTTY_MANAGED_AGENT_NATIVE_SESSION_ID"],
            "019e31af-e0ed-718b-a695-37afddc7e494"
        )
        XCTAssertNil(launchConfiguration.environmentVariables["TOASTTY_TERMINAL_PROFILE_ID"])
        let activeSession = try XCTUnwrap(sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
        XCTAssertEqual(activeSession.agent, .pi)
        XCTAssertTrue(activeSession.showsResumedBadge)
    }

    func testSurfaceLaunchConfigurationReusesPendingRestoredManagedLaunchForPanel() throws {
        let fixture = try makeRuntimeResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let panelID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = AppStore(
            state: makeRuntimeResumeState(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                resumeRecord: record,
                profileBinding: nil
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let profileProvider = makeRuntimeResumeProfileProvider()
        registry.setTerminalProfileProvider(profileProvider, restoredTerminalPanelIDs: [panelID])
        registry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        let restoredManagedLaunchPlanner = makeRestoredManagedLaunchPlanner(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore
        )
        registry.setRestoredManagedLaunchPlanner(restoredManagedLaunchPlanner)
        registry.bind(store: store)

        let firstConfiguration = registry.surfaceLaunchConfiguration(for: panelID)
        let firstSessionID = try XCTUnwrap(sessionRuntimeStore.sessionRegistry.activeSession(for: panelID)?.sessionID)
        let secondConfiguration = registry.surfaceLaunchConfiguration(for: panelID)

        XCTAssertEqual(secondConfiguration, firstConfiguration)
        XCTAssertEqual(sessionRuntimeStore.sessionRegistry.sessionOrder, [firstSessionID])
    }

    func testSurfaceLaunchConfigurationDiscardsPendingRestoredManagedLaunchWhenRecordBecomesInvalid() throws {
        let fixture = try makeRuntimeResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let panelID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = AppStore(
            state: makeRuntimeResumeState(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                resumeRecord: record,
                profileBinding: TerminalProfileBinding(profileID: "zmx")
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let profileProvider = makeRuntimeResumeProfileProvider()
        registry.setTerminalProfileProvider(profileProvider, restoredTerminalPanelIDs: [panelID])
        registry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        let restoredManagedLaunchPlanner = makeRestoredManagedLaunchPlanner(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore
        )
        registry.setRestoredManagedLaunchPlanner(restoredManagedLaunchPlanner)
        registry.bind(store: store)

        let restoredConfiguration = registry.surfaceLaunchConfiguration(for: panelID)
        let restoredSessionID = try XCTUnwrap(sessionRuntimeStore.sessionRegistry.activeSession(for: panelID)?.sessionID)
        try FileManager.default.removeItem(at: fixture.sessionFileURL)
        let fallbackConfiguration = registry.surfaceLaunchConfiguration(for: panelID)

        XCTAssertTrue(try XCTUnwrap(restoredConfiguration.initialInput).contains("TOASTTY_SESSION_ID="))
        XCTAssertEqual(fallbackConfiguration.initialInput, "zmx attach toastty.$TOASTTY_PANEL_ID")
        XCTAssertNil(sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
        XCTAssertFalse(try XCTUnwrap(sessionRuntimeStore.sessionRegistry.sessionsByID[restoredSessionID]).isActive)
    }

    func testSurfaceLaunchConfigurationClearsMissingSessionFileAndFallsBackToProfileStartup() throws {
        let fixture = try makeRuntimeResumeFixture(createSessionFile: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let panelID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = AppStore(
            state: makeRuntimeResumeState(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                resumeRecord: record,
                profileBinding: TerminalProfileBinding(profileID: "zmx")
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        let profileProvider = makeRuntimeResumeProfileProvider()
        registry.setTerminalProfileProvider(profileProvider, restoredTerminalPanelIDs: [panelID])
        registry.bind(store: store)

        let launchConfiguration = registry.surfaceLaunchConfiguration(for: panelID)

        XCTAssertEqual(launchConfiguration.initialInput, "zmx attach toastty.$TOASTTY_PANEL_ID")
        XCTAssertEqual(launchConfiguration.environmentVariables["TOASTTY_TERMINAL_PROFILE_ID"], "zmx")
        guard case .terminal(let terminalState)? = store.state.workspacesByID[workspaceID]?.panels[panelID] else {
            XCTFail("expected terminal panel")
            return
        }
        XCTAssertNil(terminalState.resumeRecord)
    }

    func testSurfaceLaunchConfigurationClearsMissingWorkingDirectoryAndFallsBackToProfileStartup() throws {
        let fixture = try makeRuntimeResumeFixture(createCWD: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let panelID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = AppStore(
            state: makeRuntimeResumeState(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                resumeRecord: record,
                profileBinding: TerminalProfileBinding(profileID: "zmx")
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        let profileProvider = makeRuntimeResumeProfileProvider()
        registry.setTerminalProfileProvider(profileProvider, restoredTerminalPanelIDs: [panelID])
        registry.bind(store: store)

        let launchConfiguration = registry.surfaceLaunchConfiguration(for: panelID)

        XCTAssertEqual(launchConfiguration.initialInput, "zmx attach toastty.$TOASTTY_PANEL_ID")
        XCTAssertEqual(launchConfiguration.environmentVariables["TOASTTY_TERMINAL_PROFILE_ID"], "zmx")
        guard case .terminal(let terminalState)? = store.state.workspacesByID[workspaceID]?.panels[panelID] else {
            XCTFail("expected terminal panel")
            return
        }
        XCTAssertNil(terminalState.resumeRecord)
    }
}

private func makeRuntimeResumeState(
    windowID: UUID,
    workspaceID: UUID,
    panelID: UUID,
    resumeRecord: ManagedAgentResumeRecord,
    profileBinding: TerminalProfileBinding?
) -> AppState {
    let slotID = UUID()
    return AppState(
        windows: [
            WindowState(
                id: windowID,
                frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                workspaceIDs: [workspaceID],
                selectedWorkspaceID: workspaceID
            ),
        ],
        workspacesByID: [
            workspaceID: WorkspaceState(
                id: workspaceID,
                title: "Workspace 1",
                layoutTree: .slot(slotID: slotID, panelID: panelID),
                panels: [
                    panelID: .terminal(
                        TerminalPanelState(
                            title: "Terminal 1",
                            shell: "zsh",
                            cwd: "",
                            launchWorkingDirectory: "/tmp/stale",
                            profileBinding: profileBinding,
                            resumeRecord: resumeRecord
                        )
                    ),
                ],
                focusedPanelID: panelID
            ),
        ],
        selectedWindowID: windowID
    )
}

@MainActor
private func makeRuntimeResumeProfileProvider() -> RuntimeResumeProfileProvider {
    RuntimeResumeProfileProvider(
        catalog: TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
    )
}

@MainActor
private final class RuntimeResumeProfileProvider: TerminalProfileProviding {
    let catalog: TerminalProfileCatalog

    init(catalog: TerminalProfileCatalog) {
        self.catalog = catalog
    }
}

private func makeRuntimeResumeFixture(
    createSessionFile: Bool = true,
    createCWD: Bool = true
) throws -> (rootURL: URL, cwdURL: URL, sessionFileURL: URL) {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-runtime-resume-\(UUID().uuidString)", isDirectory: true)
    let cwdURL = rootURL.appendingPathComponent("repo", isDirectory: true)
    let sessionFileURL = rootURL.appendingPathComponent("session.jsonl", isDirectory: false)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    if createCWD {
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
    }
    if createSessionFile {
        try Data("{}".utf8).write(to: sessionFileURL)
    }
    return (rootURL, cwdURL, sessionFileURL)
}

@MainActor
private func makeRestoredManagedLaunchPlanner(
    store: AppStore,
    sessionRuntimeStore: SessionRuntimeStore
) -> ManagedAgentLaunchPlanner {
    ManagedAgentLaunchPlanner(
        store: store,
        sessionRuntimeStore: sessionRuntimeStore,
        cliExecutablePathProvider: { "/bin/sh" },
        socketPathProvider: { "/tmp/toastty-tests.sock" },
        readVisibleText: { _ in nil },
        promptState: { _ in .unavailable },
        nativeSessionObserverRegistry: StubManagedAgentNativeSessionObserver()
    )
}

@MainActor
private final class StubManagedAgentNativeSessionObserver: ManagedAgentNativeSessionObserving {
    func startObservation(_: ManagedAgentNativeSessionObservationContext) {}
    func cancelObservation(sessionID _: String) {}
}
