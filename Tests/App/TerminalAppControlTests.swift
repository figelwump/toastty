@testable import ToasttyApp
import CoreState
import RemoteProtocol
import XCTest

@MainActor
final class TerminalAppControlTests: XCTestCase {
    func testAgentForkChecksSourceWorkspaceScopeInSyncAndAsyncActions() async throws {
        let fixture = try TerminalAppControlFixture()
        fixture.sessionRuntimeStore.startSession(
            sessionID: "scoped-caller", agent: .codex, panelID: fixture.panelID,
            windowID: fixture.windowID, workspaceID: fixture.workspaceID,
            cwd: "/tmp", repoRoot: nil, scopedWorkspaceIDs: [fixture.workspaceID], at: Date()
        )
        XCTAssertTrue(fixture.store.send(.createWorkspace(windowID: fixture.windowID, title: "Outside scope", activate: true)))
        let sourceWorkspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        let sourcePanel = try XCTUnwrap(sourceWorkspace.focusedPanelID)
        fixture.sessionRuntimeStore.startSession(
            sessionID: "outside-source", agent: .codex, panelID: sourcePanel,
            windowID: fixture.windowID, workspaceID: sourceWorkspace.id,
            cwd: "/tmp", repoRoot: nil, at: Date()
        )
        let args: [String: AutomationJSONValue] = [
            "profileID": .string("codex"),
            "panelID": .string(fixture.panelID.uuidString),
            "forkFromSessionID": .string("outside-source"),
            "cwd": .string("/tmp"),
        ]
        let context = AutomationRequestContext(callerSessionID: "scoped-caller", commandName: "app_control.run_action")
        for asynchronous in [false, true] {
            do {
                if asynchronous {
                    _ = try await fixture.executor.runActionAsync(id: "agent.launch", args: args, context: context)
                } else {
                    _ = try fixture.executor.runAction(id: "agent.launch", args: args, context: context)
                }
                XCTFail("Expected source workspace access denial")
            } catch let error as AutomationSocketError {
                guard case .scopeDenied(let workspaceID) = error else {
                    XCTFail("Expected scope denial, got \(error)")
                    continue
                }
                XCTAssertEqual(workspaceID, sourceWorkspace.id)
            }
        }
        XCTAssertEqual(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.count, 2)
    }

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

    func testTerminalSendTextWithExpectedSessionDeliversWhenPanelStillHostsSession() throws {
        let fixture = try TerminalAppControlFixture()
        let sessionID = "expected-session"
        fixture.sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: "/tmp/repo",
            repoRoot: "/tmp/repo",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var delivered = false
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { _, _, _, _ in
            delivered = true
            return true
        }

        _ = try fixture.executor.runAction(
            id: AppControlActionID.terminalSendText.rawValue,
            args: [
                "panelID": .string(fixture.panelID.uuidString),
                "text": .string("continue"),
                "expectedSessionID": .string(sessionID),
            ]
        )

        XCTAssertTrue(delivered)
    }

    func testTerminalSendTextWithWrongExpectedSessionRejectsBeforeDelivery() throws {
        let fixture = try TerminalAppControlFixture()
        fixture.sessionRuntimeStore.startSession(
            sessionID: "actual-session",
            agent: .codex,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: "/tmp/repo",
            repoRoot: "/tmp/repo",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        fixture.sessionRuntimeStore.startSession(
            sessionID: "replacement-session",
            agent: .claude,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: "/tmp/repo",
            repoRoot: "/tmp/repo",
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )
        var deliveryCount = 0
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { _, _, _, _ in
            deliveryCount += 1
            return true
        }

        XCTAssertThrowsError(try fixture.executor.runAction(
            id: AppControlActionID.terminalSendText.rawValue,
            args: [
                "panelID": .string(fixture.panelID.uuidString),
                "text": .string("must not send"),
                "submit": .bool(true),
                "expectedSessionID": .string("actual-session"),
                "allowUnavailable": .bool(true),
            ]
        ))
        XCTAssertEqual(deliveryCount, 0)
    }

    func testTerminalSendTextWithBlankExpectedSessionRejectsAsMalformed() throws {
        let fixture = try TerminalAppControlFixture()
        XCTAssertThrowsError(try fixture.executor.runAction(
            id: AppControlActionID.terminalSendText.rawValue,
            args: [
                "panelID": .string(fixture.panelID.uuidString),
                "text": .string("must not send"),
                "expectedSessionID": .string(" "),
            ]
        ))
    }

    func testTerminalSendTextWithExpectedSessionRejectsWhenPanelHasNoActiveSession() throws {
        let fixture = try TerminalAppControlFixture()
        var deliveryCount = 0
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { _, _, _, _ in
            deliveryCount += 1
            return true
        }

        XCTAssertThrowsError(try fixture.executor.runAction(
            id: AppControlActionID.terminalSendText.rawValue,
            args: [
                "panelID": .string(fixture.panelID.uuidString),
                "text": .string("must not send"),
                "expectedSessionID": .string("missing-session"),
            ]
        ))
        XCTAssertEqual(deliveryCount, 0)
    }

    func testTerminalSendTextDescriptorListsExpectedSessionID() throws {
        let fixture = try TerminalAppControlFixture()
        let descriptor = try XCTUnwrap(
            fixture.executor.listActionDescriptors().first {
                $0.id == AppControlActionID.terminalSendText.rawValue
            }
        )

        let expectedSessionParameter = try XCTUnwrap(
            descriptor.parameters.first { $0.name == "expectedSessionID" }
        )
        XCTAssertEqual(expectedSessionParameter.valueType, .string)
        XCTAssertFalse(expectedSessionParameter.required)
    }

    func testTerminalSendTextFromManagedSessionStampsPendingParentForTargetPanelLaunch() throws {
        let fixture = try TerminalAppControlFixture()
        XCTAssertTrue(fixture.store.send(.splitFocusedSlot(workspaceID: fixture.workspaceID, orientation: .horizontal)))
        let targetPanelID = try XCTUnwrap(
            fixture.store.state.workspacesByID[fixture.workspaceID]?
                .layoutTree
                .allSlotInfos
                .map(\.panelID)
                .first { $0 != fixture.panelID }
        )
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { _, _, panelID, _ in
            panelID == targetPanelID
        }
        let parentSessionID = "send-text-parent"
        fixture.sessionRuntimeStore.startSession(
            sessionID: parentSessionID,
            agent: .codex,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: "/tmp/repo",
            repoRoot: "/tmp/repo",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        _ = try fixture.executor.runAction(
            id: AppControlActionID.terminalSendText.rawValue,
            args: [
                "panelID": .string(targetPanelID.uuidString),
                "text": .string("codex"),
                "submit": .bool(true),
            ],
            context: AutomationRequestContext(
                callerSessionID: parentSessionID,
                commandName: "app_control.run_action"
            )
        )
        let plan = try fixture.agentLaunchService.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: targetPanelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )

        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.sessionsByID[plan.sessionID]?.parentSessionID,
            parentSessionID
        )
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

    func testProgrammaticSendInvalidatesLocalInputBeforeDelivery() throws {
        let fixture = try TerminalAppControlFixture()
        var callOrder: [String] = []
        let panelID = fixture.panelID
        fixture.terminalRuntimeRegistry.localInputObserver = { observedPanelID in
            XCTAssertEqual(observedPanelID, panelID)
            callOrder.append("local-input")
        }
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { _, _, _, _ in
            callOrder.append("delivery")
            return true
        }

        XCTAssertTrue(fixture.terminalRuntimeRegistry.sendText(
            "local automation",
            submit: true,
            panelID: panelID,
            focusPolicy: .preserveFirstResponder
        ))
        XCTAssertEqual(callOrder, ["local-input", "delivery"])
    }

    func testRemoteSendBypassesLocalInputObserver() throws {
        let fixture = try TerminalAppControlFixture()
        var localInputCount = 0
        fixture.terminalRuntimeRegistry.localInputObserver = { _ in localInputCount += 1 }
        fixture.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { _, _, _, _ in true }

        XCTAssertEqual(
            fixture.terminalRuntimeRegistry.sendRemoteText(
                "remote reply",
                submit: true,
                panelID: fixture.panelID,
                focusPolicy: .preserveFirstResponder
            ),
            .delivered
        )
        XCTAssertEqual(localInputCount, 0)
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

    func testDeliveryIsUncertainWhenTextWasSentButSubmitFails() {
        var sentText: [String] = []
        let delivery = TerminalAutomationInputDelivery(
            focusPolicy: .preserveFirstResponder,
            focusHostViewIfNeeded: { true },
            sendText: { sentText.append($0) },
            sendSubmit: { false },
            logFocusFailure: {}
        )

        XCTAssertEqual(
            delivery.deliverResult(text: "partial", submit: true),
            .uncertain
        )
        XCTAssertEqual(sentText, ["partial"])
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

    func testWorkspaceSnapshotRightPanelWebTabsExposePersistedModelIdentity() throws {
        let documentID = UUID()
        let sourcePanelID = UUID()
        let sourceWorkspaceID = UUID()
        let fixture = try TerminalAppControlFixture { state, workspaceID in
            var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
            var tab = try XCTUnwrap(workspace.selectedTab)
            let localTabID = UUID()
            let browserTabID = UUID()
            let scratchpadTabID = UUID()
            tab.rightAuxPanel = RightAuxPanelState(
                isVisible: true,
                activeTabID: localTabID,
                tabIDs: [localTabID, browserTabID, scratchpadTabID],
                tabsByID: [
                    localTabID: RightAuxPanelTabState(
                        id: localTabID,
                        identity: .localDocument(path: "/tmp/notes.md"),
                        panelID: UUID(),
                        panelState: .web(WebPanelState(
                            definition: .localDocument,
                            filePath: "/tmp/notes.md"
                        ))
                    ),
                    browserTabID: RightAuxPanelTabState(
                        id: browserTabID,
                        identity: .browserSession(UUID()),
                        panelID: UUID(),
                        panelState: .web(WebPanelState(
                            definition: .browser,
                            initialURL: "https://example.com/initial",
                            currentURL: "https://example.com/current"
                        ))
                    ),
                    scratchpadTabID: RightAuxPanelTabState(
                        id: scratchpadTabID,
                        identity: .scratchpad(id: documentID),
                        panelID: UUID(),
                        panelState: .web(WebPanelState(
                            definition: .scratchpad,
                            scratchpad: ScratchpadState(
                                documentID: documentID,
                                sessionLink: ScratchpadSessionLink(
                                    sessionID: "managed-session",
                                    agent: .codex,
                                    sourcePanelID: sourcePanelID,
                                    sourceWorkspaceID: sourceWorkspaceID
                                ),
                                revision: 7
                            )
                        ))
                    ),
                ]
            )
            workspace.tabsByID[tab.id] = tab
            state.workspacesByID[workspaceID] = workspace
        }

        let result = try fixture.executor.runQuery(
            id: AppControlQueryID.workspaceSnapshot.rawValue,
            args: ["workspaceID": .string(fixture.workspaceID.uuidString)]
        )

        guard case .object(let rightPanel)? = result["rightPanel"],
              case .array(let tabs)? = rightPanel["tabs"],
              tabs.count == 3,
              case .object(let local) = tabs[0],
              case .object(let browser) = tabs[1],
              case .object(let scratchpad) = tabs[2] else {
            return XCTFail("expected three right-panel tab snapshots")
        }
        XCTAssertEqual(local.string("filePath"), "/tmp/notes.md")
        XCTAssertEqual(browser.string("url"), "https://example.com/current")
        XCTAssertEqual(scratchpad.string("scratchpadDocumentID"), documentID.uuidString)
        XCTAssertEqual(scratchpad.int("scratchpadRevision"), 7)
        XCTAssertEqual(scratchpad.string("scratchpadSessionID"), "managed-session")
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

    // MARK: - Sibling terminal reads

    func testTerminalVisibleTextDescriptorListsTailAndScrollbackParameters() throws {
        let fixture = try TerminalAppControlFixture()
        let descriptor = try XCTUnwrap(
            fixture.executor.listQueryDescriptors().first {
                $0.id == AppControlQueryID.terminalVisibleText.rawValue
            }
        )
        let names = Set(descriptor.parameters.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["contains", "tail", "includeScrollback"]))
        XCTAssertEqual(descriptor.parameters.first { $0.name == "tail" }?.valueType, .integer)
        XCTAssertEqual(descriptor.parameters.first { $0.name == "includeScrollback" }?.valueType, .boolean)
    }

    func testWorkspaceSnapshotSlotMappingsCarryTerminalMetadata() throws {
        let fixture = try TerminalAppControlFixture()
        fixture.terminalRuntimeRegistry.terminalLiveTitleStore.setTitle("npm run dev", for: fixture.panelID)
        fixture.terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .busy }
        fixture.sessionRuntimeStore.startSession(
            sessionID: "owner-session",
            agent: .claude,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let result = try fixture.executor.runQuery(
            id: AppControlQueryID.workspaceSnapshot.rawValue,
            args: ["workspaceID": .string(fixture.workspaceID.uuidString)]
        )

        guard case .array(let mappings)? = result["slotMappings"],
              case .object(let entry)? = mappings.first else {
            XCTFail("expected slotMappings entries")
            return
        }
        XCTAssertEqual(entry.string("panelID"), fixture.panelID.uuidString)
        XCTAssertEqual(entry.string("panelKind"), "terminal")
        XCTAssertEqual(entry.string("title"), "npm run dev")
        XCTAssertEqual(entry.int("shortcutNumber"), 1)
        XCTAssertEqual(entry.string("promptState"), "busy")
        XCTAssertEqual(entry.bool("isBusy"), true)
        XCTAssertEqual(entry.string("sessionID"), "owner-session")
        XCTAssertEqual(entry.string("agent"), AgentKind.claude.rawValue)
        XCTAssertEqual(entry.bool("readable"), true)
        XCTAssertNotNil(entry["cwd"])
        XCTAssertNotNil(entry["shell"])

        XCTAssertTrue(fixture.store.send(.setTerminalPanelAgentReadPolicy(panelID: fixture.panelID, policy: .denied)))
        let privateResult = try fixture.executor.runQuery(
            id: AppControlQueryID.workspaceSnapshot.rawValue,
            args: ["workspaceID": .string(fixture.workspaceID.uuidString)]
        )
        guard case .array(let privateMappings)? = privateResult["slotMappings"],
              case .object(let privateEntry)? = privateMappings.first else {
            XCTFail("expected slotMappings entries")
            return
        }
        XCTAssertEqual(privateEntry.bool("readable"), false)
    }

    func testTerminalVisibleTextTailAndScrollbackParameters() throws {
        let fixture = try TerminalAppControlFixture()
        var requestedScrollback: [Bool] = []
        fixture.terminalRuntimeRegistry.setAutomationReadVisibleTextHandlerForTesting { _, includeScrollback in
            requestedScrollback.append(includeScrollback)
            return includeScrollback ? "old-1\nold-2\nline-1\nline-2\nline-3\n" : "line-1\nline-2\nline-3\n"
        }

        let viewport = try fixture.executor.runQuery(
            id: AppControlQueryID.terminalVisibleText.rawValue,
            args: ["panelID": .string(fixture.panelID.uuidString)]
        )
        // Unbounded reads return the surface text byte-for-byte, trailing newline included.
        XCTAssertEqual(viewport.string("text"), "line-1\nline-2\nline-3\n")
        XCTAssertEqual(viewport.int("lineCount"), 3)
        XCTAssertEqual(viewport.bool("truncated"), false)
        XCTAssertEqual(viewport.bool("includesScrollback"), false)

        let tailed = try fixture.executor.runQuery(
            id: AppControlQueryID.terminalVisibleText.rawValue,
            args: [
                "panelID": .string(fixture.panelID.uuidString),
                "includeScrollback": .string("true"),
                "tail": .string("2"),
                "contains": .string("line-3"),
            ]
        )
        XCTAssertEqual(tailed.string("text"), "line-2\nline-3")
        XCTAssertEqual(tailed.int("lineCount"), 2)
        XCTAssertEqual(tailed.bool("truncated"), true)
        XCTAssertEqual(tailed.bool("includesScrollback"), true)
        XCTAssertEqual(tailed.bool("contains"), true)
        XCTAssertEqual(requestedScrollback, [false, true])

        XCTAssertThrowsError(
            try fixture.executor.runQuery(
                id: AppControlQueryID.terminalVisibleText.rawValue,
                args: ["panelID": .string(fixture.panelID.uuidString), "tail": .string("0")]
            )
        ) { error in
            guard case AutomationSocketError.invalidPayload = error else {
                XCTFail("expected invalidPayload, got \(error)")
                return
            }
        }
    }

    func testBoundedTerminalTextCapsBytesFromTheEnd() {
        let text = (1...10).map { "line-\($0)" }.joined(separator: "\n")
        let bounded = AppControlExecutor.boundedTerminalText(text, tail: nil, byteLimit: 14)
        XCTAssertEqual(bounded.text, "line-9\nline-10")
        XCTAssertEqual(bounded.lineCount, 2)
        XCTAssertTrue(bounded.truncated)

        let untouched = AppControlExecutor.boundedTerminalText("a\nb", tail: 5, byteLimit: 1024)
        XCTAssertEqual(untouched.text, "a\nb")
        XCTAssertEqual(untouched.lineCount, 2)
        XCTAssertFalse(untouched.truncated)

        let trailingNewline = AppControlExecutor.boundedTerminalText("a\nb\n", tail: nil, byteLimit: 1024)
        XCTAssertEqual(trailingNewline.text, "a\nb\n", "unbounded reads must return the original bytes")
        XCTAssertEqual(trailingNewline.lineCount, 2)
        XCTAssertFalse(trailingNewline.truncated)
    }

    func testForeignReadOnPrivateTerminalIsDeniedAndOwnSessionIsExempt() throws {
        let fixture = try TerminalAppControlFixture()
        fixture.terminalRuntimeRegistry.setAutomationReadVisibleTextHandlerForTesting { _, _ in "secret" }
        fixture.sessionRuntimeStore.startSession(
            sessionID: "owner-session",
            agent: .claude,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(fixture.store.send(.setTerminalPanelAgentReadPolicy(panelID: fixture.panelID, policy: .denied)))

        XCTAssertThrowsError(
            try fixture.executor.runQuery(
                id: AppControlQueryID.terminalVisibleText.rawValue,
                args: ["panelID": .string(fixture.panelID.uuidString)],
                context: AutomationRequestContext(callerSessionID: "other-session", commandName: "app_control.run_query")
            )
        ) { error in
            guard case AutomationSocketError.panelReadDenied(let panelID) = error else {
                XCTFail("expected panelReadDenied, got \(error)")
                return
            }
            XCTAssertEqual(panelID, fixture.panelID)
            XCTAssertEqual(AutomationSocketError.panelReadDenied(panelID: panelID).errorBody.code, "PANEL_READ_DENIED")
        }

        let own = try fixture.executor.runQuery(
            id: AppControlQueryID.terminalVisibleText.rawValue,
            args: ["panelID": .string(fixture.panelID.uuidString)],
            context: AutomationRequestContext(callerSessionID: "owner-session", commandName: "app_control.run_query")
        )
        XCTAssertEqual(own.string("text"), "secret")
        XCTAssertNil(fixture.terminalRuntimeRegistry.terminalReadActivityStore.existingModel(for: fixture.panelID))
    }

    func testForeignReadsRecordReadActivityWithReaderLabel() throws {
        let fixture = try TerminalAppControlFixture()
        fixture.terminalRuntimeRegistry.setAutomationReadVisibleTextHandlerForTesting { _, _ in "output" }
        XCTAssertTrue(fixture.store.send(.splitFocusedSlot(workspaceID: fixture.workspaceID, orientation: .horizontal)))
        let readerPanelID = try XCTUnwrap(
            fixture.store.state.workspacesByID[fixture.workspaceID]?.layoutTree.allSlotInfos
                .map(\.panelID)
                .first { $0 != fixture.panelID }
        )
        fixture.sessionRuntimeStore.startSession(
            sessionID: "reader-session",
            agent: .codex,
            panelID: readerPanelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let context = AutomationRequestContext(callerSessionID: "reader-session", commandName: "app_control.run_query")
        _ = try fixture.executor.runQuery(
            id: AppControlQueryID.terminalVisibleText.rawValue,
            args: ["panelID": .string(fixture.panelID.uuidString)],
            context: context
        )
        _ = try fixture.executor.runQuery(
            id: AppControlQueryID.terminalVisibleText.rawValue,
            args: ["panelID": .string(fixture.panelID.uuidString)],
            context: context
        )

        let model = try XCTUnwrap(fixture.terminalRuntimeRegistry.terminalReadActivityStore.existingModel(for: fixture.panelID))
        XCTAssertEqual(model.totalReadCount, 2)
        XCTAssertEqual(model.readers.count, 1)
        XCTAssertEqual(model.readers.first?.sessionID, "reader-session")
        XCTAssertEqual(model.readers.first?.label, AgentKind.codex.displayName)
        XCTAssertEqual(model.readers.first?.readCount, 2)
        XCTAssertNil(fixture.terminalRuntimeRegistry.terminalReadActivityStore.existingModel(for: readerPanelID))
    }

    func testReadWithoutCallerSessionRecordsUnknownAutomationClient() throws {
        let fixture = try TerminalAppControlFixture()
        fixture.terminalRuntimeRegistry.setAutomationReadVisibleTextHandlerForTesting { _, _ in "output" }

        _ = try fixture.executor.runQuery(
            id: AppControlQueryID.terminalVisibleText.rawValue,
            args: ["panelID": .string(fixture.panelID.uuidString)]
        )

        let model = try XCTUnwrap(fixture.terminalRuntimeRegistry.terminalReadActivityStore.existingModel(for: fixture.panelID))
        XCTAssertEqual(model.readers.first?.sessionID, TerminalReadActivityStore.unknownReaderSessionID)
        XCTAssertEqual(model.readers.first?.label, TerminalReadActivityStore.unknownReaderLabel)
        XCTAssertEqual(model.totalReadCount, 1)
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
    let agentLaunchService: AgentLaunchService
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
        let launchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: agentTerminalCommandRouter ?? terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-test.sock" }
        )
        agentLaunchService = launchService
        executor = AppControlExecutor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: launchService,
            reloadConfigurationAction: nil
        )
    }
}
