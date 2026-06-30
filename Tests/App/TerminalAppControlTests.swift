@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalAppControlTests: XCTestCase {
    func testTerminalSendTextActionPreservesFirstResponder() throws {
        let fixture = try TerminalAppControlFixture()
        var capturedText: String?
        var capturedSubmit: Bool?
        var capturedPanelID: UUID?
        var capturedFocusPolicy: TerminalInputFocusPolicy?
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, submit, panelID, focusPolicy in
            capturedText = text
            capturedSubmit = submit
            capturedPanelID = panelID
            capturedFocusPolicy = focusPolicy
            return true
        }

        let outcome = try fixture.executor.runAction(
            id: AppControlActionID.terminalSendText.rawValue,
            args: [
                "panelID": .string(fixture.panelID.uuidString),
                "text": .string("codex --continue"),
                "submit": .bool(true),
            ]
        )

        XCTAssertEqual(capturedText, "codex --continue")
        XCTAssertEqual(capturedSubmit, true)
        XCTAssertEqual(capturedPanelID, fixture.panelID)
        XCTAssertEqual(capturedFocusPolicy, .preserveFirstResponder)
        XCTAssertEqual(outcome.result?.string("workspaceID"), fixture.workspaceID.uuidString)
        XCTAssertEqual(outcome.result?.string("panelID"), fixture.panelID.uuidString)
        XCTAssertEqual(outcome.result?.bool("submitted"), true)
        XCTAssertEqual(outcome.result?.bool("available"), true)
    }

    func testTerminalRuntimeSendTextDefaultsToFocusingTarget() throws {
        let fixture = try TerminalAppControlFixture()
        var capturedFocusPolicy: TerminalInputFocusPolicy?
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { _, _, _, focusPolicy in
            capturedFocusPolicy = focusPolicy
            return true
        }

        XCTAssertTrue(
            fixture.terminalRuntimeRegistry.sendText(
                "agent launch",
                submit: true,
                panelID: fixture.panelID
            )
        )
        XCTAssertEqual(capturedFocusPolicy, .focusTarget)
    }

    func testPreserveFirstResponderDeliverySendsWithoutFocusing() {
        var focusCallCount = 0
        var sentText: [String] = []
        var submitCallCount = 0
        var focusFailureLogCount = 0
        let delivery = TerminalAutomationInputDelivery(
            focusPolicy: .preserveFirstResponder,
            focusHostViewIfNeeded: {
                focusCallCount += 1
                return false
            },
            sendText: { text in
                sentText.append(text)
            },
            sendSubmit: {
                submitCallCount += 1
                return true
            },
            logFocusFailure: {
                focusFailureLogCount += 1
            }
        )

        XCTAssertTrue(delivery.deliver(text: "codex --continue", submit: true))
        XCTAssertEqual(focusCallCount, 0)
        XCTAssertEqual(sentText, ["codex --continue"])
        XCTAssertEqual(submitCallCount, 1)
        XCTAssertEqual(focusFailureLogCount, 0)
    }

    func testFocusTargetDeliveryStopsBeforeSendingWhenFocusFails() {
        var focusCallCount = 0
        var sentText: [String] = []
        var submitCallCount = 0
        var focusFailureLogCount = 0
        let delivery = TerminalAutomationInputDelivery(
            focusPolicy: .focusTarget,
            focusHostViewIfNeeded: {
                focusCallCount += 1
                return false
            },
            sendText: { text in
                sentText.append(text)
            },
            sendSubmit: {
                submitCallCount += 1
                return true
            },
            logFocusFailure: {
                focusFailureLogCount += 1
            }
        )

        XCTAssertFalse(delivery.deliver(text: "agent launch", submit: true))
        XCTAssertEqual(focusCallCount, 1)
        XCTAssertTrue(sentText.isEmpty)
        XCTAssertEqual(submitCallCount, 0)
        XCTAssertEqual(focusFailureLogCount, 1)
    }

    func testAgentLaunchActionPassesStructuredCWDEnvironmentAndInitialPrompt() throws {
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let fixture = try TerminalAppControlFixture(agentTerminalCommandRouter: terminalRouter)
        let cwdURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-app-control-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwdURL) }

        let outcome = try fixture.executor.runAction(
            id: AppControlActionID.agentLaunch.rawValue,
            args: [
                "profileID": .string("codex"),
                "workspaceID": .string(fixture.workspaceID.uuidString),
                "cwd": .string(cwdURL.path),
                "env.TOASTTY_DEV_WORKTREE_ROOT": .string(cwdURL.path),
                "initialPrompt": .string("Read WORKTREE_HANDOFF.md"),
                "initialCommands": .array([
                    .string("direnv allow"),
                    .string("export READY=1"),
                ]),
            ]
        )

        XCTAssertEqual(outcome.result?.string("profileID"), "codex")
        XCTAssertEqual(outcome.result?.string("cwd"), cwdURL.path)
        let command = try XCTUnwrap(terminalRouter.sentTextByPanelID[fixture.panelID])
        XCTAssertTrue(command.hasPrefix("cd \(cwdURL.path) && direnv allow && export READY=1 && "))
        XCTAssertTrue(command.contains("TOASTTY_DEV_WORKTREE_ROOT=\(cwdURL.path)"))
        XCTAssertTrue(command.contains("'Read WORKTREE_HANDOFF.md'"))
        XCTAssertEqual(terminalRouter.focusPolicyByPanelID[fixture.panelID], .preserveFirstResponder)
    }

    func testAgentLaunchActionRejectsNonStringInitialCommandEntries() throws {
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let fixture = try TerminalAppControlFixture(agentTerminalCommandRouter: terminalRouter)

        XCTAssertThrowsError(
            try fixture.executor.runAction(
                id: AppControlActionID.agentLaunch.rawValue,
                args: [
                    "profileID": .string("codex"),
                    "workspaceID": .string(fixture.workspaceID.uuidString),
                    "initialCommands": .array([.string("direnv allow"), .object(["bad": .string("shape")])]),
                ]
            )
        ) { error in
            guard case AutomationSocketError.invalidPayload(let message) = error else {
                XCTFail("expected invalidPayload, got \(error)")
                return
            }
            XCTAssertEqual(message, "initialCommands[1] must be a string")
        }
        XCTAssertTrue(terminalRouter.sentTextByPanelID.isEmpty)
    }

    func testWorkspaceSelectActionPreservesSelectedTabByDefault() throws {
        let scenario = try makeWorkspaceSelectUnreadScenario()

        let outcome = try scenario.fixture.executor.runAction(
            id: AppControlActionID.workspaceSelect.rawValue,
            args: [
                "workspaceID": .string(scenario.targetWorkspaceID.uuidString),
            ]
        )

        XCTAssertTrue(outcome.didMutateState)
        XCTAssertEqual(
            scenario.fixture.store.state.selectedWorkspaceID(in: scenario.fixture.windowID),
            scenario.targetWorkspaceID
        )
        let workspace = try XCTUnwrap(scenario.fixture.store.state.workspacesByID[scenario.targetWorkspaceID])
        XCTAssertEqual(workspace.selectedTabID, scenario.targetTabID)
        XCTAssertEqual(workspace.focusedPanelID, scenario.initialFocusedPanelID)
        XCTAssertEqual(workspace.unreadPanelIDs, [scenario.unreadPanelID])
    }

    func testWorkspaceSelectActionPreservesSelectedTabWithExplicitFalse() throws {
        let scenario = try makeWorkspaceSelectUnreadScenario()

        let outcome = try scenario.fixture.executor.runAction(
            id: AppControlActionID.workspaceSelect.rawValue,
            args: [
                "workspaceID": .string(scenario.targetWorkspaceID.uuidString),
                "focusUnreadSessionPanel": .bool(false),
            ]
        )

        XCTAssertTrue(outcome.didMutateState)
        XCTAssertEqual(
            scenario.fixture.store.state.selectedWorkspaceID(in: scenario.fixture.windowID),
            scenario.targetWorkspaceID
        )
        let workspace = try XCTUnwrap(scenario.fixture.store.state.workspacesByID[scenario.targetWorkspaceID])
        XCTAssertEqual(workspace.selectedTabID, scenario.targetTabID)
        XCTAssertEqual(workspace.focusedPanelID, scenario.initialFocusedPanelID)
        XCTAssertEqual(workspace.unreadPanelIDs, [scenario.unreadPanelID])
    }

    func testWorkspaceSelectActionCanOptInToUnreadSessionPanelFocus() throws {
        let scenario = try makeWorkspaceSelectUnreadScenario()

        let outcome = try scenario.fixture.executor.runAction(
            id: AppControlActionID.workspaceSelect.rawValue,
            args: [
                "workspaceID": .string(scenario.targetWorkspaceID.uuidString),
                "focusUnreadSessionPanel": .bool(true),
            ]
        )

        XCTAssertTrue(outcome.didMutateState)
        XCTAssertEqual(
            scenario.fixture.store.state.selectedWorkspaceID(in: scenario.fixture.windowID),
            scenario.targetWorkspaceID
        )
        let workspace = try XCTUnwrap(scenario.fixture.store.state.workspacesByID[scenario.targetWorkspaceID])
        XCTAssertEqual(workspace.selectedTabID, scenario.targetTabID)
        XCTAssertEqual(workspace.focusedPanelID, scenario.unreadPanelID)
        XCTAssertEqual(workspace.unreadPanelIDs, [])
    }

    func testWorkspaceSelectActionOptInPreservesFocusWhenNoUnreadSessionPanelExists() throws {
        let scenario = try makeWorkspaceSelectUnreadScenario(markUnread: false)

        let outcome = try scenario.fixture.executor.runAction(
            id: AppControlActionID.workspaceSelect.rawValue,
            args: [
                "workspaceID": .string(scenario.targetWorkspaceID.uuidString),
                "focusUnreadSessionPanel": .bool(true),
            ]
        )

        XCTAssertTrue(outcome.didMutateState)
        XCTAssertEqual(
            scenario.fixture.store.state.selectedWorkspaceID(in: scenario.fixture.windowID),
            scenario.targetWorkspaceID
        )
        let workspace = try XCTUnwrap(scenario.fixture.store.state.workspacesByID[scenario.targetWorkspaceID])
        XCTAssertEqual(workspace.selectedTabID, scenario.targetTabID)
        XCTAssertEqual(workspace.focusedPanelID, scenario.initialFocusedPanelID)
        XCTAssertEqual(workspace.unreadPanelIDs, [])
    }

    func testTerminalStateQueryUsesLiveTitleWithoutMutatingPersistedTitle() throws {
        let fixture = try TerminalAppControlFixture()
        fixture.terminalRuntimeRegistry.terminalLiveTitleStore.setTitle(
            "Live Build",
            for: fixture.panelID
        )

        let result = try fixture.executor.runQuery(
            id: AppControlQueryID.terminalState.rawValue,
            args: ["panelID": .string(fixture.panelID.uuidString)]
        )

        XCTAssertEqual(result.string("title"), "Live Build")
        guard case .terminal(let terminalState)? = fixture.store.state
            .workspacesByID[fixture.workspaceID]?
            .panelState(for: fixture.panelID) else {
            XCTFail("expected terminal panel")
            return
        }
        XCTAssertEqual(terminalState.title, "Terminal 1")
    }

    func testWorkspaceSnapshotRightPanelTerminalUsesLiveTitle() throws {
        let rightPanelID = UUID()
        let fixture = try TerminalAppControlFixture { state, workspaceID in
            var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
            var tab = try XCTUnwrap(workspace.selectedTab)
            let rightTabID = UUID()
            let rightPanelState = PanelState.terminal(
                TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "")
            )
            tab.rightAuxPanel = RightAuxPanelState(
                isVisible: true,
                width: 360,
                hasCustomWidth: true,
                activeTabID: rightTabID,
                tabIDs: [rightTabID],
                tabsByID: [
                    rightTabID: RightAuxPanelTabState(
                        id: rightTabID,
                        identity: .browserSession(rightPanelID),
                        panelID: rightPanelID,
                        panelState: rightPanelState
                    ),
                ],
                focusedPanelID: rightPanelID
            )
            workspace.tabsByID[tab.id] = tab
            state.workspacesByID[workspaceID] = workspace
        }
        fixture.terminalRuntimeRegistry.terminalLiveTitleStore.setTitle(
            "Live Right Panel",
            for: rightPanelID
        )

        let result = try fixture.executor.runQuery(
            id: AppControlQueryID.workspaceSnapshot.rawValue,
            args: ["workspaceID": .string(fixture.workspaceID.uuidString)]
        )

        guard case .object(let rightPanel)? = result["rightPanel"],
              case .array(let tabs)? = rightPanel["tabs"],
              case .object(let firstTab)? = tabs.first else {
            XCTFail("expected right-panel tab snapshot")
            return
        }
        XCTAssertEqual(firstTab.string("title"), "Live Right Panel")
    }

    func testScopedCallerCannotReadTerminalStateOutsideWorkspaceScope() throws {
        let fixture = try TerminalAppControlFixture()
        let existingWorkspaceIDs = Set(fixture.store.state.window(id: fixture.windowID)?.workspaceIDs ?? [])
        XCTAssertTrue(fixture.store.send(.createWorkspace(windowID: fixture.windowID, title: nil, activate: true)))
        let otherWorkspaceID = try XCTUnwrap(
            fixture.store.state.window(id: fixture.windowID)?.workspaceIDs.first {
                existingWorkspaceIDs.contains($0) == false
            }
        )
        let otherPanelID = try XCTUnwrap(fixture.store.state.workspacesByID[otherWorkspaceID]?.focusedPanelID)
        fixture.sessionRuntimeStore.startSession(
            sessionID: "caller-scoped",
            agent: .codex,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: [],
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertThrowsError(
            try fixture.executor.runQuery(
                id: AppControlQueryID.terminalState.rawValue,
                args: ["panelID": .string(otherPanelID.uuidString)],
                context: AutomationRequestContext(
                    callerSessionID: "caller-scoped",
                    commandName: "app_control.run_query"
                )
            )
        ) { error in
            guard case AutomationSocketError.scopeDenied(let workspaceID) = error else {
                XCTFail("expected scopeDenied, got \(error)")
                return
            }
            XCTAssertEqual(workspaceID, otherWorkspaceID)
        }
    }

    func testScopedCallerCannotMoveWorkspaceAcrossOutOfScopeDestinationIndex() throws {
        let fixture = try TerminalAppControlFixture()
        XCTAssertTrue(fixture.store.send(.createWorkspace(windowID: fixture.windowID, title: "Other", activate: false)))
        let window = try XCTUnwrap(fixture.store.state.window(id: fixture.windowID))
        let originalIndex = try XCTUnwrap(window.workspaceIDs.firstIndex(of: fixture.workspaceID))
        let otherWorkspaceID = try XCTUnwrap(window.workspaceIDs.first { $0 != fixture.workspaceID })
        let otherIndex = try XCTUnwrap(window.workspaceIDs.firstIndex(of: otherWorkspaceID))
        fixture.sessionRuntimeStore.startSession(
            sessionID: "caller-move",
            agent: .codex,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: [],
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertThrowsError(
            try fixture.executor.runAction(
                id: AppControlActionID.workspaceMove.rawValue,
                args: [
                    "windowID": .string(fixture.windowID.uuidString),
                    "index": .int(originalIndex + 1),
                    "toIndex": .int(otherIndex + 1),
                ],
                context: AutomationRequestContext(
                    callerSessionID: "caller-move",
                    commandName: "app_control.run_action"
                )
            )
        ) { error in
            guard case AutomationSocketError.scopeDenied(let workspaceID) = error else {
                XCTFail("expected scopeDenied, got \(error)")
                return
            }
            XCTAssertEqual(workspaceID, otherWorkspaceID)
        }
    }

    func testWorkspaceCreateAutoBindsNewWorkspaceToScopedCaller() throws {
        let fixture = try TerminalAppControlFixture()
        fixture.sessionRuntimeStore.startSession(
            sessionID: "caller-create",
            agent: .codex,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: [],
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let outcome = try fixture.executor.runAction(
            id: AppControlActionID.workspaceCreate.rawValue,
            args: ["windowID": .string(fixture.windowID.uuidString)],
            context: AutomationRequestContext(
                callerSessionID: "caller-create",
                commandName: "app_control.run_action"
            )
        )

        let rawCreatedWorkspaceID = try XCTUnwrap(outcome.result?.string("workspaceID"))
        let createdWorkspaceID = try XCTUnwrap(UUID(uuidString: rawCreatedWorkspaceID))
        XCTAssertEqual(
            fixture.sessionRuntimeStore.scope(ofSessionID: "caller-create"),
            [createdWorkspaceID]
        )
        XCTAssertTrue(
            fixture.sessionRuntimeStore.allowsWorkspaceAutomation(
                callerSessionID: "caller-create",
                of: createdWorkspaceID
            )
        )
    }

    func testAgentLaunchChildInheritsScopedParentEffectiveWorkspaceScope() throws {
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let fixture = try TerminalAppControlFixture(agentTerminalCommandRouter: terminalRouter)
        let explicitWorkspaceID = UUID()
        fixture.sessionRuntimeStore.startSession(
            sessionID: "parent-scoped",
            agent: .codex,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: [explicitWorkspaceID],
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let outcome = try fixture.executor.runAction(
            id: AppControlActionID.agentLaunch.rawValue,
            args: [
                "profileID": .string("codex"),
                "workspaceID": .string(fixture.workspaceID.uuidString),
            ],
            context: AutomationRequestContext(
                callerSessionID: "parent-scoped",
                commandName: "app_control.run_action"
            )
        )

        let childSessionID = try XCTUnwrap(outcome.result?.string("sessionID"))
        let childRecord = try XCTUnwrap(fixture.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: childSessionID))
        XCTAssertEqual(childRecord.scopedWorkspaceIDs, [explicitWorkspaceID, fixture.workspaceID])
    }

    private func makeWorkspaceSelectUnreadScenario(
        markUnread: Bool = true
    ) throws -> WorkspaceSelectUnreadScenario {
        let fixture = try TerminalAppControlFixture()
        let existingWorkspaceIDs = Set(fixture.store.state.window(id: fixture.windowID)?.workspaceIDs ?? [])
        XCTAssertTrue(
            fixture.store.send(
                .createWorkspace(
                    windowID: fixture.windowID,
                    title: "Unread Target",
                    activate: false
                )
            )
        )
        let targetWorkspaceID = try XCTUnwrap(
            fixture.store.state.window(id: fixture.windowID)?.workspaceIDs.first {
                existingWorkspaceIDs.contains($0) == false
            }
        )
        XCTAssertTrue(fixture.store.send(.splitFocusedSlot(workspaceID: targetWorkspaceID, orientation: .horizontal)))

        var targetWorkspace = try XCTUnwrap(fixture.store.state.workspacesByID[targetWorkspaceID])
        let targetTabID = try XCTUnwrap(targetWorkspace.selectedTabID)
        let initialFocusedPanelID = try XCTUnwrap(targetWorkspace.focusedPanelID)
        let unreadPanelID = try XCTUnwrap(
            targetWorkspace.layoutTree.allSlotInfos.map(\.panelID).first { $0 != initialFocusedPanelID }
        )

        if markUnread {
            fixture.sessionRuntimeStore.startSession(
                sessionID: "workspace-select-unread",
                agent: .codex,
                panelID: unreadPanelID,
                windowID: fixture.windowID,
                workspaceID: targetWorkspaceID,
                cwd: "/repo",
                repoRoot: "/repo",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            fixture.sessionRuntimeStore.updateStatus(
                sessionID: "workspace-select-unread",
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Unread target"),
                at: Date(timeIntervalSince1970: 1_700_000_001)
            )
        }

        targetWorkspace = try XCTUnwrap(fixture.store.state.workspacesByID[targetWorkspaceID])
        XCTAssertEqual(targetWorkspace.selectedTabID, targetTabID)
        XCTAssertEqual(targetWorkspace.focusedPanelID, initialFocusedPanelID)
        XCTAssertEqual(targetWorkspace.unreadPanelIDs, markUnread ? [unreadPanelID] : [])
        XCTAssertEqual(fixture.store.state.selectedWorkspaceID(in: fixture.windowID), fixture.workspaceID)

        return WorkspaceSelectUnreadScenario(
            fixture: fixture,
            targetWorkspaceID: targetWorkspaceID,
            targetTabID: targetTabID,
            initialFocusedPanelID: initialFocusedPanelID,
            unreadPanelID: unreadPanelID
        )
    }
}

@MainActor
private struct WorkspaceSelectUnreadScenario {
    let fixture: TerminalAppControlFixture
    let targetWorkspaceID: UUID
    let targetTabID: UUID
    let initialFocusedPanelID: UUID
    let unreadPanelID: UUID
}

@MainActor
private struct TerminalAppControlFixture {
    let store: AppStore
    let executor: AppControlExecutor
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let sessionRuntimeStore: SessionRuntimeStore
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID

    init(
        agentTerminalCommandRouter: (any TerminalCommandRouting)? = nil,
        configureState: ((inout AppState, UUID) throws -> Void)? = nil
    ) throws {
        var state = AppState.bootstrap()
        let selection = try XCTUnwrap(state.selectedWorkspaceSelection())
        windowID = selection.windowID
        workspaceID = selection.workspaceID
        panelID = try XCTUnwrap(selection.workspace.focusedPanelID)
        try configureState?(&state, workspaceID)

        store = AppStore(state: state, persistTerminalFontPreference: false)
        terminalRuntimeRegistry = TerminalRuntimeRegistry()
        terminalRuntimeRegistry.bind(store: store)
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)

        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
        )
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: agentTerminalCommandRouter ?? terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-test.sock" }
        )
        executor = AppControlExecutor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService,
            reloadConfigurationAction: nil
        )
    }
}
