@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalCreationAppControlTests: XCTestCase {
    func testBackgroundSplitDefaultsToManagedCallerAfterSelectionChanges() throws {
        for scoped in [false, true] {
            let fixture = try TerminalAppControlFixture()
            let callerTab = try XCTUnwrap(fixture.store.selectedWorkspace?.selectedTab)
            startCaller(fixture, scope: scoped ? [fixture.workspaceID] : nil)
            let selectedTab = try createTab(fixture, workspaceID: fixture.workspaceID)
            let selectedWorkspace = try createWorkspace(fixture)
            let before = fixture.store.state

            let outcome = try fixture.executor.runAction(
                id: "workspace.split.right", args: ["activate": .bool(false)], context: callerContext
            )

            let panelID = try returnedID("panelID", outcome)
            XCTAssertEqual(outcome.result?.string("workspaceID"), fixture.workspaceID.uuidString)
            XCTAssertEqual(outcome.result?.string("tabID"), callerTab.id.uuidString)
            XCTAssertNotEqual(panelID, fixture.panelID)
            XCTAssertNotNil(fixture.store.state.workspacesByID[fixture.workspaceID]?.tab(id: callerTab.id)?.panels[panelID])
            XCTAssertEqual(fixture.store.selectedWorkspace?.id, selectedWorkspace.id)
            XCTAssertEqual(fixture.store.state.workspacesByID[fixture.workspaceID]?.selectedTabID, selectedTab.id)
            XCTAssertEqual(fixture.store.state.workspacesByID[fixture.workspaceID]?.selectedTab, selectedTab)
            XCTAssertEqual(fixture.store.state.workspacesByID[fixture.workspaceID]?.tab(id: callerTab.id)?.focusedPanelID, fixture.panelID)
            XCTAssertEqual(fixture.store.selectedWorkspace, before.workspacesByID[selectedWorkspace.id])
        }
    }

    func testExplicitPanelAndTabInferWorkspaceAndOverrideCallerWithinScope() throws {
        for selector in ["panelID", "tabID"] {
            let fixture = try TerminalAppControlFixture()
            let target = try createWorkspace(fixture)
            let targetTab = try XCTUnwrap(target.selectedTab)
            startCaller(fixture, scope: [fixture.workspaceID, target.id])
            XCTAssertTrue(fixture.store.send(.selectWorkspace(windowID: fixture.windowID, workspaceID: fixture.workspaceID)))
            let before = fixture.store.selectedWorkspace
            let anchor = selector == "panelID" ? try XCTUnwrap(targetTab.focusedPanelID) : targetTab.id

            let outcome = try fixture.executor.runAction(
                id: "workspace.split.down",
                args: [selector: .string(anchor.uuidString), "activate": .bool(false)], context: callerContext
            )

            let created = try returnedID("panelID", outcome)
            XCTAssertEqual(outcome.result?.string("workspaceID"), target.id.uuidString)
            XCTAssertEqual(outcome.result?.string("tabID"), targetTab.id.uuidString)
            XCTAssertNotNil(fixture.store.state.workspacesByID[target.id]?.tab(id: targetTab.id)?.panels[created])
            XCTAssertEqual(fixture.store.selectedWorkspace, before)
            XCTAssertEqual(fixture.store.state.workspacesByID[target.id]?.focusedPanelID, targetTab.focusedPanelID)
        }
    }

    func testInvalidTargetCombinationsAndScopeDenialDoNotMutateState() throws {
        let fixture = try TerminalAppControlFixture()
        let originalTab = try XCTUnwrap(fixture.store.selectedWorkspace?.selectedTabID)
        let secondTab = try createTab(fixture, workspaceID: fixture.workspaceID)
        let outside = try createWorkspace(fixture)
        let outsideTab = try XCTUnwrap(outside.selectedTabID)
        startCaller(fixture, scope: [fixture.workspaceID])
        let invalidTargets: [[String: AutomationJSONValue]] = [
            ["workspaceID": .string(outside.id.uuidString), "panelID": .string(fixture.panelID.uuidString)],
            ["workspaceID": .string(fixture.workspaceID.uuidString), "tabID": .string(outsideTab.uuidString)],
            ["tabID": .string(secondTab.id.uuidString), "panelID": .string(fixture.panelID.uuidString)],
            ["tabID": .string(UUID().uuidString)],
            ["panelID": .string(UUID().uuidString)],
            ["workspaceID": .string(UUID().uuidString)],
            ["tabID": .string(outsideTab.uuidString)],
        ]
        for target in invalidTargets {
            let before = fixture.store.state
            XCTAssertThrowsError(try fixture.executor.runAction(
                id: "workspace.split.right", args: target, context: callerContext
            )) { error in
                if target == ["tabID": .string(outsideTab.uuidString)] {
                    guard let socketError = error as? AutomationSocketError,
                          case .scopeDenied(let deniedWorkspace) = socketError else {
                        return XCTFail("Expected workspace scope denial, got \(error)")
                    }
                    XCTAssertEqual(deniedWorkspace, outside.id)
                }
            }
            var launchArgs = target
            launchArgs["profileID"] = .string("codex")
            XCTAssertThrowsError(try fixture.executor.runAction(
                id: "agent.launch", args: launchArgs, context: callerContext
            ))
            XCTAssertEqual(fixture.store.state, before)
        }
        XCTAssertNotNil(fixture.store.state.workspacesByID[fixture.workspaceID]?.tab(id: originalTab))
        XCTAssertEqual(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.count, 1)
    }

    func testExplicitTabCreationCannotBypassCallerWorkspaceScope() throws {
        let fixture = try TerminalAppControlFixture()
        let outside = try createWorkspace(fixture)
        startCaller(fixture, scope: [fixture.workspaceID])
        let before = fixture.store.state
        XCTAssertThrowsError(try fixture.executor.runAction(
            id: "workspace.tab.create",
            args: ["workspaceID": .string(outside.id.uuidString), "activate": .bool(false)],
            context: callerContext
        )) { error in
            guard let error = error as? AutomationSocketError,
                  case .scopeDenied(let workspaceID) = error else {
                return XCTFail("Expected workspace scope denial")
            }
            XCTAssertEqual(workspaceID, outside.id)
        }
        XCTAssertEqual(fixture.store.state, before)
    }

    func testStaleCallerDoesNotFallBackToSelectedWorkspace() throws {
        let fixture = try TerminalAppControlFixture()
        startCaller(fixture, scope: nil)
        _ = try createWorkspace(fixture)
        XCTAssertTrue(fixture.store.send(.closePanel(panelID: fixture.panelID)))
        let before = fixture.store.state
        for action in ["workspace.split.right", "workspace.tab.create", "agent.launch"] {
            XCTAssertThrowsError(try fixture.executor.runAction(
                id: action, args: ["profileID": .string("codex")], context: callerContext
            ))
            XCTAssertEqual(fixture.store.state, before)
        }
    }

    func testBackgroundTabReturnsCompleteTargetAndPreservesSelection() throws {
        let fixture = try TerminalAppControlFixture()
        startCaller(fixture, scope: [fixture.workspaceID])
        let original = try XCTUnwrap(fixture.store.selectedWorkspace?.selectedTab)
        let selected = try createWorkspace(fixture)
        let outcome = try fixture.executor.runAction(
            id: "workspace.tab.create", args: ["activate": .bool(false)], context: callerContext
        )

        let tabID = try returnedID("tabID", outcome)
        let panelID = try returnedID("panelID", outcome)
        let created = try XCTUnwrap(fixture.store.state.workspacesByID[fixture.workspaceID]?.tab(id: tabID))
        XCTAssertEqual(outcome.result?.string("workspaceID"), fixture.workspaceID.uuidString)
        XCTAssertTrue(outcome.didMutateState)
        XCTAssertNotEqual(tabID, original.id)
        XCTAssertEqual(created.focusedPanelID, panelID)
        guard case .terminal = created.panels[panelID] else { return XCTFail("Expected new terminal") }
        XCTAssertEqual(fixture.store.selectedWorkspace, selected)
        XCTAssertEqual(fixture.store.state.workspacesByID[fixture.workspaceID]?.selectedTab, original)
    }

    func testUnsupportedTabSelectorIsRejectedWithoutMutation() throws {
        let fixture = try TerminalAppControlFixture()
        let args: [String: AutomationJSONValue] = [
            "tabID": .string(try XCTUnwrap(fixture.store.selectedWorkspace?.selectedTabID).uuidString),
        ]
        let before = fixture.store.state
        XCTAssertThrowsError(try fixture.executor.runAction(id: "workspace.tab.create", args: args))
        XCTAssertThrowsError(try fixture.executor.runQuery(id: "terminal.state", args: args))
        XCTAssertEqual(fixture.store.state, before)
    }

    func testNonmanagedSplitKeepsSelectedWorkspaceAndTabDefault() throws {
        let fixture = try TerminalAppControlFixture()
        let selected = try createWorkspace(fixture)
        let tab = try createTab(fixture, workspaceID: selected.id)
        let outcome = try fixture.executor.runAction(id: "workspace.split.right", args: [:])
        let panelID = try returnedID("panelID", outcome)
        XCTAssertEqual(outcome.result?.string("workspaceID"), selected.id.uuidString)
        XCTAssertEqual(outcome.result?.string("tabID"), tab.id.uuidString)
        XCTAssertEqual(fixture.store.selectedWorkspace?.focusedPanelID, panelID)
    }

    func testSyncAndAsyncLaunchUseFocusedOrFirstTerminalInExplicitTab() async throws {
        for asynchronous in [false, true] {
            for webFocused in [false, true] {
                let router = TestTerminalCommandRouter()
                router.defaultPromptState = .idleAtPrompt
                let fixture = try TerminalAppControlFixture(agentTerminalCommandRouter: router)
                let tabID = try XCTUnwrap(fixture.store.selectedWorkspace?.selectedTabID)
                XCTAssertTrue(fixture.store.send(.splitFocusedSlot(workspaceID: fixture.workspaceID, orientation: .horizontal)))
                let focusedTerminal = try XCTUnwrap(fixture.store.selectedWorkspace?.focusedPanelID)
                if webFocused {
                    XCTAssertTrue(fixture.store.send(.createWebPanel(
                        workspaceID: fixture.workspaceID,
                        panel: WebPanelState(definition: .browser, title: "Docs"), placement: .splitRight
                    )))
                }
                let expected = webFocused ? fixture.panelID : focusedTerminal
                _ = try createTab(fixture, workspaceID: fixture.workspaceID)
                let selected = try createWorkspace(fixture)
                let args: [String: AutomationJSONValue] = [
                    "profileID": .string("codex"), "tabID": .string(tabID.uuidString), "cwd": .string("/tmp"),
                ]
                let outcome: AppControlActionOutcome
                if asynchronous {
                    outcome = try await fixture.executor.runActionAsync(id: "agent.launch", args: args)
                } else {
                    outcome = try fixture.executor.runAction(id: "agent.launch", args: args)
                }
                XCTAssertEqual(outcome.result?.string("workspaceID"), fixture.workspaceID.uuidString)
                XCTAssertEqual(outcome.result?.string("tabID"), tabID.uuidString)
                XCTAssertEqual(try returnedID("panelID", outcome), expected)
                XCTAssertEqual(Set(router.sentTextByPanelID.keys), [expected])
                XCTAssertEqual(router.focusPolicyByPanelID[expected], .preserveFirstResponder)
                XCTAssertEqual(fixture.store.selectedWorkspace?.id, selected.id)
            }
        }
    }

    func testAsyncLaunchKeepsTargetWhenSelectionChangesDuringReadinessWait() async throws {
        for waitsForHostReadiness in [false, true] {
            let router = TestTerminalCommandRouter()
            router.defaultPromptState = .idleAtPrompt
            let fixture = try TerminalAppControlFixture(agentTerminalCommandRouter: router)
            router.promptStateByPanelID[fixture.panelID] = waitsForHostReadiness ? .idleAtPrompt : .unavailable
            router.managedAgentCommandReadinessByPanelID[fixture.panelID] = !waitsForHostReadiness
            let targetTab = try XCTUnwrap(fixture.store.selectedWorkspace?.selectedTabID)
            let otherTab = try createTab(fixture, workspaceID: fixture.workspaceID)
            let otherWorkspace = try createWorkspace(fixture)
            XCTAssertTrue(fixture.store.send(.selectWorkspace(windowID: fixture.windowID, workspaceID: fixture.workspaceID)))
            XCTAssertTrue(fixture.store.send(.selectWorkspaceTab(workspaceID: fixture.workspaceID, tabID: targetTab)))
            let changeSelection = Task { @MainActor in
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertTrue(router.sentTextByPanelID.isEmpty)
                XCTAssertTrue(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.isEmpty)
                XCTAssertTrue(fixture.store.send(.selectWorkspaceTab(workspaceID: fixture.workspaceID, tabID: otherTab.id)))
                XCTAssertTrue(fixture.store.send(.selectWorkspace(windowID: fixture.windowID, workspaceID: otherWorkspace.id)))
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertTrue(router.sentTextByPanelID.isEmpty)
                XCTAssertTrue(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.isEmpty)
                router.promptStateByPanelID[fixture.panelID] = .idleAtPrompt
                router.managedAgentCommandReadinessByPanelID[fixture.panelID] = true
            }
            defer { changeSelection.cancel() }
            let outcome = try await fixture.executor.runActionAsync(
                id: "agent.launch", args: ["profileID": .string("codex"), "cwd": .string("/tmp")]
            )
            try await changeSelection.value

            XCTAssertEqual(outcome.result?.string("tabID"), targetTab.uuidString)
            XCTAssertEqual(try returnedID("panelID", outcome), fixture.panelID)
            XCTAssertEqual(Set(router.sentTextByPanelID.keys), [fixture.panelID])
            let command = try XCTUnwrap(router.sentTextByPanelID[fixture.panelID])
            XCTAssertTrue(command.contains("TOASTTY_PANEL_ID=\(fixture.panelID.uuidString)"))
            XCTAssertEqual(router.sendAttemptsByPanelID[fixture.panelID], 1)
            XCTAssertEqual(router.focusPolicyByPanelID[fixture.panelID], .preserveFirstResponder)
            XCTAssertEqual(fixture.store.selectedWorkspace?.id, otherWorkspace.id)
            XCTAssertEqual(fixture.store.state.workspacesByID[fixture.workspaceID]?.selectedTabID, otherTab.id)
        }
    }

    func testAsyncLaunchTimesOutWithoutStartingSessionWhenHostNeverBecomesReady() async throws {
        let router = TestTerminalCommandRouter()
        router.defaultPromptState = .idleAtPrompt
        router.defaultManagedAgentCommandReadiness = false
        let fixture = try TerminalAppControlFixture(agentTerminalCommandRouter: router)

        do {
            _ = try await fixture.executor.runActionAsync(
                id: "agent.launch", args: ["profileID": .string("codex"), "cwd": .string("/tmp")]
            )
            XCTFail("Expected unstable host to reject launch")
        } catch let error as AgentLaunchError {
            XCTAssertEqual(error, .panelBusy(runningCommand: nil))
        } catch {
            XCTFail("Expected readiness timeout, got \(error)")
        }

        XCTAssertTrue(router.sendAttemptsByPanelID.isEmpty)
        XCTAssertTrue(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.isEmpty)
        XCTAssertFalse(fixture.store.hasEverLaunchedAgent)
    }

    func testAsyncLaunchRejectsBusyStableAndExitedUnreadyTerminals() async throws {
        for promptState in [TerminalPromptState.busy, .exited] {
            let router = TestTerminalCommandRouter()
            router.defaultPromptState = promptState
            router.defaultManagedAgentCommandReadiness = promptState == .busy
            let fixture = try TerminalAppControlFixture(agentTerminalCommandRouter: router)

            do {
                _ = try await fixture.executor.runActionAsync(
                    id: "agent.launch", args: ["profileID": .string("codex"), "cwd": .string("/tmp")]
                )
                XCTFail("Expected noninteractive terminal to reject launch")
            } catch let error as AgentLaunchError {
                XCTAssertEqual(error, .panelBusy(runningCommand: nil))
            } catch {
                XCTFail("Expected noninteractive-terminal error, got \(error)")
            }

            XCTAssertTrue(router.sendAttemptsByPanelID.isEmpty)
            XCTAssertTrue(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.isEmpty)
        }
    }

    func testAsyncLaunchFailsWithoutFallbackWhenTargetClosesDuringReadinessWait() async throws {
        let router = TestTerminalCommandRouter()
        router.defaultPromptState = .idleAtPrompt
        router.defaultManagedAgentCommandReadiness = false
        let fixture = try TerminalAppControlFixture(agentTerminalCommandRouter: router)
        let targetTab = try XCTUnwrap(fixture.store.selectedWorkspace?.selectedTabID)
        let fallback = try createTab(fixture, workspaceID: fixture.workspaceID)
        let closeTarget = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(fixture.store.send(.closePanel(panelID: fixture.panelID)))
            router.defaultManagedAgentCommandReadiness = true
        }
        defer { closeTarget.cancel() }
        do {
            _ = try await fixture.executor.runActionAsync(id: "agent.launch", args: [
                "profileID": .string("codex"), "tabID": .string(targetTab.uuidString), "cwd": .string("/tmp"),
            ])
            XCTFail("Expected closed target to reject launch")
        } catch let error as AgentLaunchError {
            XCTAssertEqual(error, .panelDoesNotExist)
            XCTAssertTrue(router.sentTextByPanelID.isEmpty)
            XCTAssertTrue(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.isEmpty)
        } catch {
            XCTFail("Expected closed-panel launch error, got \(error)")
        }
        try await closeTarget.value
        XCTAssertEqual(fixture.store.selectedWorkspace?.selectedTabID, fallback.id)
        XCTAssertTrue(router.sentTextByPanelID.isEmpty)
        XCTAssertTrue(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.isEmpty)
    }

    private var callerContext: AutomationRequestContext {
        .init(callerSessionID: "creation-caller", commandName: "app_control.run_action")
    }

    private func startCaller(_ fixture: TerminalAppControlFixture, scope: Set<UUID>?) {
        fixture.sessionRuntimeStore.startSession(
            sessionID: "creation-caller", agent: .codex, panelID: fixture.panelID,
            windowID: fixture.windowID, workspaceID: fixture.workspaceID,
            cwd: "/tmp", repoRoot: nil, scopedWorkspaceIDs: scope, at: Date()
        )
    }

    private func createTab(_ fixture: TerminalAppControlFixture, workspaceID: UUID) throws -> WorkspaceTabState {
        XCTAssertTrue(fixture.store.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        return try XCTUnwrap(fixture.store.state.workspacesByID[workspaceID]?.selectedTab)
    }

    private func createWorkspace(_ fixture: TerminalAppControlFixture) throws -> WorkspaceState {
        XCTAssertTrue(fixture.store.send(.createWorkspace(windowID: fixture.windowID, title: "Other", activate: true)))
        return try XCTUnwrap(fixture.store.selectedWorkspace)
    }

    private func returnedID(_ key: String, _ outcome: AppControlActionOutcome) throws -> UUID {
        try XCTUnwrap(outcome.result?.string(key).flatMap(UUID.init(uuidString:)))
    }
}
