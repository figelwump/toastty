import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

@MainActor
struct TerminalProgramStatusRuntimeTests {
    @Test(arguments: [TerminalProgramStatusReport.State.done, .error])
    func completedProgramSurvivesPromptUntilItsPanelIsViewed(_ state: TerminalProgramStatusReport.State) throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let store = SessionRuntimeStore(sendSessionStatusNotification: { _, _, _, _, _ in },
                                        isApplicationActive: { true })
        store.bind(store: appStore)
        defer { store.reset() }
        let workspace = try #require(appStore.selectedWorkspace)
        let focusedPanelID = try #require(workspace.focusedPanelID)
        let panelID = try #require(workspace.layoutTree.allSlotInfos.first { $0.panelID != focusedPanelID }?.panelID)

        store.handleProgramStatusEvent(.report(.init(state: state, title: "Build", message: "Result")), panelID: panelID)
        store.handleProgramStatusEvent(.prompt, panelID: panelID)
        #expect(store.programStatusRows(in: workspace).first?.status.kind == (state == .done ? .ready : .error))
        #expect(appStore.selectedWorkspace?.unreadPanelIDs.contains(panelID) == true)
        _ = appStore.send(.focusPanel(workspaceID: workspace.id, panelID: focusedPanelID))
        #expect(store.programStatusRuntime.recordsByPanel[panelID] != nil)
        _ = appStore.send(.focusPanel(workspaceID: workspace.id, panelID: panelID))
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
        #expect(appStore.selectedWorkspace?.unreadPanelIDs.contains(panelID) == false)
        #expect(store.sessionRegistry.sessionsByID.isEmpty)
    }

    @Test(arguments: [true, false])
    func programCompletionUsesNotificationFocusRules(_ applicationActive: Bool) async throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        var isActive = applicationActive
        let store = SessionRuntimeStore(sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
            await recorder.record(title: title, body: body, workspaceID: workspaceID, panelID: panelID, context: context)
        }, isApplicationActive: { isActive })
        store.bind(store: appStore)
        defer { store.reset() }
        let workspace = try #require(appStore.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        store.handleProgramStatusEvent(.report(.init(state: .done, title: "Build", message: "All tests passed")), panelID: panelID)
        if applicationActive {
            await settleNotificationTasks()
        } else {
            await waitUntilNotificationCount(recorder, expectedCount: 1)
        }
        let notifications = await recorder.notifications()
        #expect(notifications.count == (applicationActive ? 0 : 1))
        if !applicationActive {
            let notification = try #require(notifications.first)
            #expect(notification.title == "Command finished")
            #expect(notification.body == "Build: All tests passed")
            #expect(notification.workspaceID == workspace.id)
            #expect(notification.panelID == panelID)
            #expect(notification.context.workspaceTitle == workspace.title)
        }
        // A result received while already focused remains until the next read/input action.
        #expect(store.programStatusRuntime.recordsByPanel[panelID]?.presentation?.record.state == .done)
        isActive = true
        // WorkspaceView dispatches this when the app becomes active again.
        _ = appStore.send(.markPanelNotificationsRead(workspaceID: workspace.id, panelID: panelID))
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
    }

    @Test
    func repeatedProgramCompletionAndRapidStateChangesDoNotSpamNotifications() async throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let store = SessionRuntimeStore(sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
            await recorder.record(title: title, body: body, workspaceID: workspaceID, panelID: panelID, context: context)
        }, isApplicationActive: { false })
        store.bind(store: appStore)
        defer { store.reset() }
        let panelID = try #require(appStore.selectedWorkspace?.focusedPanelID)
        let now = Date()
        store.handleProgramStatusEvent(.report(.init(state: .done)), panelID: panelID, at: now)
        await waitUntilNotificationCount(recorder, expectedCount: 1)
        for _ in 0..<20 {
            store.handleProgramStatusEvent(.report(.init(state: .done)), panelID: panelID, at: now)
            store.handleProgramStatusEvent(.reset, panelID: panelID, at: now)
            store.handleProgramStatusEvent(.report(.init(state: .error)), panelID: panelID, at: now)
        }
        await waitUntilNotificationCount(recorder, expectedCount: 2)
        #expect(await recorder.count() == 2) // The first error may immediately follow success.
        #expect(store.programStatusRuntime.recordsByPanel[panelID]?.presentation?.record.state == .error)
        store.handleProgramStatusEvent(.report(.init(state: .working)), panelID: panelID, at: now.addingTimeInterval(6))
        store.handleProgramStatusEvent(.report(.init(state: .done)), panelID: panelID, at: now.addingTimeInterval(6))
        await waitUntilNotificationCount(recorder, expectedCount: 3)
        #expect(await recorder.count() == 3)
    }

    @Test
    func childCompletionWaitsForRemainingWorkAndReadKeepsActiveRecords() async throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let store = SessionRuntimeStore(sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
            await recorder.record(title: title, body: body, workspaceID: workspaceID, panelID: panelID, context: context)
        }, isApplicationActive: { false })
        store.bind(store: appStore)
        defer { store.reset() }
        let workspace = try #require(appStore.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        store.handleProgramStatusEvent(.report(.init(state: .working, title: "Build")), panelID: panelID)
        store.handleProgramStatusEvent(.report(.init(state: .blocked, id: "approval", kind: .permission)), panelID: panelID)
        store.handleProgramStatusEvent(.report(.init(state: .done, id: "tests")), panelID: panelID)
        await settleNotificationTasks()
        #expect(await recorder.count() == 0)
        _ = appStore.send(.focusPanel(workspaceID: workspace.id, panelID: panelID))
        store.noteLocalInputForActiveSession(panelID: panelID)
        #expect(store.programStatusRuntime.recordsByPanel[panelID]?.records.count == 3)
        #expect(store.programStatusRuntime.recordsByPanel[panelID]?.presentation?.record.state == .blocked)
        store.handleProgramStatusEvent(.report(.init(state: .done, id: "tests")), panelID: panelID)
        store.handleProgramStatusEvent(.prompt, panelID: panelID)
        await waitUntilNotificationCount(recorder, expectedCount: 1)
        #expect(await recorder.count() == 1)
        #expect(store.programStatusRuntime.recordsByPanel[panelID]?.presentation?.record.state == .done)
    }

    @Test
    func completionSummaryRefreshBeforeDeliveryUsesLatestMessage() async throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let store = SessionRuntimeStore(sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
            await recorder.record(title: title, body: body, workspaceID: workspaceID, panelID: panelID, context: context)
        }, isApplicationActive: { false })
        store.bind(store: appStore)
        defer { store.reset() }
        let panelID = try #require(appStore.selectedWorkspace?.focusedPanelID)
        store.handleProgramStatusEvent(.report(.init(state: .done, title: "Build", message: "Complete")), panelID: panelID)
        store.handleProgramStatusEvent(.report(.init(state: .done, title: "Build", message: "100 tests passed")), panelID: panelID)
        await waitUntilNotificationCount(recorder, expectedCount: 1)
        let notifications = await recorder.notifications()
        #expect(notifications.count == 1)
        #expect(notifications.first?.body == "Build: 100 tests passed")
    }

    @Test
    func viewingResultBeforeNotificationTaskRunsCancelsNotification() async throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let store = SessionRuntimeStore(sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
            await recorder.record(title: title, body: body, workspaceID: workspaceID, panelID: panelID, context: context)
        }, isApplicationActive: { true })
        store.bind(store: appStore)
        defer { store.reset() }
        let workspace = try #require(appStore.selectedWorkspace)
        let panelID = try #require(workspace.layoutTree.allSlotInfos.first { $0.panelID != workspace.focusedPanelID }?.panelID)
        store.handleProgramStatusEvent(.report(.init(state: .done)), panelID: panelID)
        _ = appStore.send(.focusPanel(workspaceID: workspace.id, panelID: panelID))
        await settleNotificationTasks()
        #expect(await recorder.count() == 0)
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
    }

    @Test(arguments: [TerminalProgramStatusEvent.prompt, .exit])
    func exitWithoutCompletionDoesNotInventSuccess(_ event: TerminalProgramStatusEvent) async throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let store = SessionRuntimeStore(sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
            await recorder.record(title: title, body: body, workspaceID: workspaceID, panelID: panelID, context: context)
        }, isApplicationActive: { false })
        store.bind(store: appStore)
        defer { store.reset() }
        let panelID = try #require(appStore.selectedWorkspace?.focusedPanelID)
        store.handleProgramStatusEvent(.report(.init(state: .working)), panelID: panelID)
        store.handleProgramStatusEvent(event, panelID: panelID)
        await settleNotificationTasks()
        #expect(await recorder.count() == 0)
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
        #expect(appStore.selectedWorkspace?.unreadPanelIDs.isEmpty == true)
    }

    @Test
    func notificationFocusWhileInactiveDefersAcknowledgementUntilActivation() throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        var isActive = false
        let store = SessionRuntimeStore(sendSessionStatusNotification: { _, _, _, _, _ in },
                                        isApplicationActive: { isActive })
        store.bind(store: appStore)
        defer { store.reset() }
        let workspace = try #require(appStore.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        store.handleProgramStatusEvent(.report(.init(state: .done)), panelID: panelID)
        _ = appStore.send(.focusPanel(workspaceID: workspace.id, panelID: panelID))
        #expect(store.programStatusRuntime.recordsByPanel[panelID] != nil)
        #expect(appStore.selectedWorkspace?.unreadPanelIDs.isEmpty == true)
        isActive = true
        store.acknowledgeViewedProgramStatusResults()
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
    }

    @Test
    func returningToWorkspaceAcknowledgesCompletion() throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let store = SessionRuntimeStore(sendSessionStatusNotification: { _, _, _, _, _ in },
                                        isApplicationActive: { true })
        store.bind(store: appStore)
        defer { store.reset() }
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        _ = appStore.send(.createWorkspace(windowID: selection.windowID, title: "Other", activate: true))
        store.handleProgramStatusEvent(.report(.init(state: .done)), panelID: panelID)
        #expect(store.programStatusRuntime.recordsByPanel[panelID] != nil)
        _ = appStore.send(.selectWorkspace(windowID: selection.windowID, workspaceID: selection.workspaceID))
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
    }

    @Test
    func newCompletionWithoutWorkingStillMarksUnread() throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let store = SessionRuntimeStore(sendSessionStatusNotification: { _, _, _, _, _ in },
                                        isApplicationActive: { true })
        store.bind(store: appStore)
        defer { store.reset() }
        let workspace = try #require(appStore.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let otherPanelID = try #require(workspace.layoutTree.allSlotInfos.first { $0.panelID != panelID }?.panelID)
        store.handleProgramStatusEvent(.report(.init(state: .done, message: "First result")), panelID: panelID)
        store.handleProgramStatusEvent(.prompt, panelID: panelID)
        _ = appStore.send(.focusPanel(workspaceID: workspace.id, panelID: otherPanelID))
        store.handleProgramStatusEvent(.report(.init(state: .done, message: "Second result")), panelID: panelID)
        #expect(appStore.selectedWorkspace?.unreadPanelIDs.contains(panelID) == true)
    }

    @Test(arguments: [AgentKind.claude, .codex])
    func localInterruptKeepsExplicitProgramStatusFallback(_ agent: AgentKind) {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let panelID = UUID()
        store.startSession(sessionID: "agent", agent: agent, panelID: panelID,
                           windowID: UUID(), workspaceID: UUID(), usesSessionStatusNotifications: true,
                           codexStatusTrackingSource: agent == .codex ? .hooks : nil,
                           cwd: nil, repoRoot: nil, at: Date())
        store.updateStatus(sessionID: "agent", status: .init(kind: .working, summary: "Working"), at: Date())
        store.allowProgramStatusFallback(sessionID: "agent")
        store.handleProgramStatusEvent(.report(.init(state: .working)), panelID: panelID)
        #expect(store.handleLocalInterruptForPanelIfActive(panelID: panelID, kind: .controlC, at: Date()))
        #expect(store.programStatusRuntime.fallbackSessionIDs.contains("agent"))
        store.handleProgramStatusEvent(.report(.init(state: .blocked, kind: .question)), panelID: panelID)
        #expect(store.programStatusRuntime.recordsByPanel[panelID]?.presentation?.record.state == .blocked)
    }

    @Test
    func localRootProgressKeepsFallbackButTranscriptProgressReclaimsIt() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let panelID = UUID()
        store.startSession(sessionID: "agent", agent: .codex, panelID: panelID,
                           windowID: UUID(), workspaceID: UUID(), usesSessionStatusNotifications: true,
                           codexStatusTrackingSource: .sessionLogFallback(reason: "test"),
                           cwd: nil, repoRoot: nil, at: Date())
        store.updateStatus(sessionID: "agent", status: .init(kind: .working, summary: "Working"), at: Date())
        store.allowProgramStatusFallback(sessionID: "agent")
        store.handleProgramStatusEvent(.report(.init(state: .working)), panelID: panelID)
        #expect(store.handleCodexSessionLogRootProgressObservation(
            sessionID: "agent", observation: .visibleTextWorking(detail: "Reading"), at: Date()))
        #expect(store.programStatusRuntime.fallbackSessionIDs.contains("agent"))
        #expect(store.handleCodexSessionLogRootProgressObservation(
            sessionID: "agent", observation: .sessionLogWorking(detail: "Real transcript event"), at: Date()))
        #expect(!store.programStatusRuntime.fallbackSessionIDs.contains("agent"))
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
    }

    @Test(arguments: [TerminalProgramStatusReport.State.working, .blocked, .done, .error])
    func stoppingFallbackEndsTransientStateAndPreservesResults(_ state: TerminalProgramStatusReport.State) {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let panelID = UUID()
        store.startSession(sessionID: "agent", agent: .claude, panelID: panelID,
                           windowID: UUID(), workspaceID: UUID(), cwd: nil, repoRoot: nil, at: Date())
        store.allowProgramStatusFallback(sessionID: "agent")
        store.handleProgramStatusEvent(.report(.init(state: state)), panelID: panelID)
        store.stopSession(sessionID: "agent", at: Date())
        #expect(!store.programStatusRuntime.fallbackSessionIDs.contains("agent"))
        #expect((store.programStatusRuntime.recordsByPanel[panelID] != nil) == (state == .done || state == .error))
    }

    @Test
    func removingManualWatchResumesProgramReportsBeforeTheNextPrompt() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let panelID = UUID()
        store.handleProgramStatusEvent(.prompt, panelID: panelID)
        store.startProcessWatch(sessionID: "watch", panelID: panelID, windowID: UUID(), workspaceID: UUID(),
                                displayTitleOverride: "Tests", cwd: nil, repoRoot: nil, at: Date())
        store.stopSession(sessionID: "watch", at: Date())
        store.handleProgramStatusEvent(.report(.init(state: .working, app: "pytest")), panelID: panelID)
        #expect(store.programStatusRuntime.recordsByPanel[panelID]?.presentation?.app == "pytest")
    }

    @Test
    func ignoredReportsAndEmptyAcknowledgementsDoNotSchedulePublication() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let panelID = UUID()
        store.startSession(sessionID: "agent", agent: .claude, panelID: panelID,
                           windowID: UUID(), workspaceID: UUID(), cwd: nil, repoRoot: nil, at: Date())
        store.handleProgramStatusEvent(.report(.init(state: .working)), panelID: panelID)
        store.noteLocalInputForActiveSession(panelID: panelID)
        store.updateStatus(sessionID: "agent", status: .init(kind: .working, summary: "Working"), at: Date())
        #expect(store.programStatusPublicationTask == nil)
        #expect(store.programStatusRevision == 0)
        store.allowProgramStatusFallback(sessionID: "agent")
        store.handleProgramStatusEvent(.report(.init(state: .working)), panelID: panelID)
        #expect(store.programStatusPublicationTask != nil)
        store.programStatusPublicationTask?.cancel()
        store.programStatusPublicationTask = nil
        store.handleProgramStatusEvent(.report(.init(state: .working)), panelID: panelID)
        store.noteLocalInputForActiveSession(panelID: panelID)
        #expect(store.programStatusPublicationTask == nil)
    }

    @Test
    func panelRemovalPrunesAllProgramBookkeepingAfterSessionTeardown() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let store = SessionRuntimeStore()
        store.bind(store: appStore)
        defer { store.reset() }
        let workspace = try #require(appStore.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        store.handleProgramStatusEvent(.prompt, panelID: panelID)
        store.startSession(sessionID: "agent", agent: .claude, panelID: panelID,
                           windowID: try #require(appStore.state.windows.first?.id), workspaceID: workspace.id,
                           cwd: nil, repoRoot: nil, at: Date())
        store.allowProgramStatusFallback(sessionID: "agent")
        store.handleProgramStatusEvent(.report(.init(state: .done)), panelID: panelID)
        _ = appStore.send(.closePanel(panelID: panelID))
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
        #expect(!store.programStatusRuntime.panelsWithPrompt.contains(panelID))
        #expect(!store.programStatusRuntime.panelsAwaitingPrompt.contains(panelID))
        #expect(!store.programStatusRuntime.fallbackSessionIDs.contains("agent"))
    }

    @Test
    func programRowsFollowWorkspaceTabAndPaneOrder() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let firstPanelID = try #require(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff"))
        let secondPanelID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let thirdPanelID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        var firstTab = WorkspaceTabState.bootstrap(panelID: firstPanelID)
        firstTab.layoutTree = .split(nodeID: UUID(), orientation: .horizontal, ratio: 0.5,
                                    first: firstTab.layoutTree,
                                    second: .slot(slotID: UUID(), panelID: thirdPanelID))
        firstTab.panels[thirdPanelID] = .terminal(.init(title: "Pane", shell: "zsh", cwd: "/tmp"))
        let secondTab = WorkspaceTabState.bootstrap(panelID: secondPanelID)
        let workspace = WorkspaceState(id: UUID(), title: "Programs", selectedTabID: firstTab.id,
                                       tabIDs: [firstTab.id, secondTab.id],
                                       tabsByID: [firstTab.id: firstTab, secondTab.id: secondTab])
        for panelID in [firstPanelID, secondPanelID, thirdPanelID] {
            store.handleProgramStatusEvent(.report(.init(state: .working)), panelID: panelID)
        }
        #expect(store.programStatusRows(in: workspace).map(\.panelID) == [firstPanelID, thirdPanelID, secondPanelID])
    }

    @Test(arguments: [false, true])
    func explicitUnknownAppKeepsCommandAppearanceEvenOnAgentFallback(_ explicitApp: Bool) throws {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .working, app: explicitApp ? "pytest" : nil)))
        let row = SidebarProgramStatusRow(panelID: UUID(), terminalTitle: "Terminal",
                                         presentation: try #require(records.presentation), fallbackAgent: .claude)
        #expect(row.isAgent == !explicitApp)
        #expect(row.title == (explicitApp ? "pytest" : AgentKind.claude.displayName))
    }

    @Test
    func presentationPreservesEmojiAndSeparatesLinesWhileRemovingBidiControls() throws {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .error, message: "Build\u{2028}failed 👨‍👩‍👧")))
        let row = SidebarProgramStatusRow(panelID: UUID(), terminalTitle: "\u{202e}Terminal\u{2066}",
                                         presentation: try #require(records.presentation), fallbackAgent: nil)
        #expect(row.summary == "Build failed 👨‍👩‍👧")
        #expect(row.terminalLabel == "Terminal")
        #expect(row.accessibilityLabel.contains("Terminal: Terminal"))
    }

    @Test
    func unregisteredProgramsDoNotCreateManagedSessionsOrActionableEvents() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        var actionableEvents = 0
        store.onActionableEvent = { _ in actionableEvents += 1 }
        let panelID = UUID()
        store.handleProgramStatusEvent(.report(.init(state: .blocked, kind: .permission)), panelID: panelID)
        store.handleProgramStatusEvent(.report(.init(state: .done)), panelID: panelID)
        #expect(store.sessionRegistry.sessionsByID.isEmpty)
        #expect(actionableEvents == 0)
        #expect(store.programStatusRuntime.recordsByPanel[panelID]?.presentation?.record.state == .done)
        store.noteLocalInputForActiveSession(panelID: panelID)
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
    }

    @Test
    func acceptedManagedStatusTakesAuthorityBackFromExplicitFallback() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let panelID = UUID()
        store.startSession(sessionID: "agent", agent: .claude, panelID: panelID,
                           windowID: UUID(), workspaceID: UUID(), cwd: nil, repoRoot: nil, at: Date())
        let report = TerminalProgramStatusEvent.report(.init(state: .blocked, kind: .question))
        store.handleProgramStatusEvent(report, panelID: panelID)
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
        store.allowProgramStatusFallback(sessionID: "agent")
        store.handleProgramStatusEvent(report, panelID: panelID)
        #expect(store.programStatusRuntime.recordsByPanel[panelID]?.presentation?.record.state == .blocked)
        store.updateStatus(sessionID: "agent", status: .init(kind: .working, summary: "Hook status"), at: Date())
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
        store.handleProgramStatusEvent(report, panelID: panelID)
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
        #expect(store.sessionRegistry.activeSession(for: panelID)?.status?.summary == "Hook status")
    }

    @Test(arguments: [false, true])
    func stoppedOwnerSuppressesLateReportsOnlyUntilAnObservedPrompt(_ usesShellIntegration: Bool) {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let panelID = UUID()
        if usesShellIntegration { store.handleProgramStatusEvent(.prompt, panelID: panelID) }
        store.startSession(sessionID: "agent", agent: .claude, panelID: panelID,
                           windowID: UUID(), workspaceID: UUID(), cwd: nil, repoRoot: nil, at: Date())
        store.stopSession(sessionID: "agent", at: Date())
        store.handleProgramStatusEvent(.report(.init(state: .working)), panelID: panelID)
        #expect((store.programStatusRuntime.recordsByPanel[panelID] == nil) == usesShellIntegration)
        store.handleProgramStatusEvent(.prompt, panelID: panelID)
        store.handleProgramStatusEvent(.report(.init(state: .working, app: "build")), panelID: panelID)
        #expect(store.programStatusRuntime.recordsByPanel[panelID]?.presentation?.app == "build")
    }

    @Test
    func manualWatchRetainsItsOwnStatusAndCannotEnableFallback() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let panelID = UUID()
        store.startProcessWatch(sessionID: "watch", panelID: panelID, windowID: UUID(), workspaceID: UUID(),
                                displayTitleOverride: "Tests", cwd: nil, repoRoot: nil, at: Date())
        store.allowProgramStatusFallback(sessionID: "watch")
        store.handleProgramStatusEvent(.report(.init(state: .error)), panelID: panelID)
        #expect(store.programStatusRuntime.recordsByPanel[panelID] == nil)
        #expect(store.sessionRegistry.activeSession(for: panelID)?.status?.kind == .working)
    }

    @Test
    func programPresentationUsesChildDetailWithoutExposingTaskRows() throws {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .working, app: "deploy", title: "Deploy v2.4.1", progress: 65)))
        records.apply(.report(.init(state: .blocked, id: "west", title: "EU West", message: "Approve deployment?", kind: .permission)))
        let row = SidebarProgramStatusRow(panelID: UUID(), terminalTitle: "deploy",
                                         presentation: try #require(records.presentation), fallbackAgent: nil)
        #expect(row.title == "Deploy v2.4.1")
        #expect(row.summary == "EU West: Approve deployment?")
        #expect(row.badge == "approval")
        #expect(row.presentation.record.progress == nil)
        #expect(!row.isAgent)
    }

    @Test(arguments: [(TerminalProgramStatusReport.Kind.question, "input"), (.auth, "login")])
    func waitingReasonAndKnownAgentAppearanceAreSpecific(_ kind: TerminalProgramStatusReport.Kind, _ label: String) throws {
        var records = TerminalProgramStatusRecords()
        records.apply(.report(.init(state: .blocked, app: "claude-code", title: "\u{202e}Review\u{2066}", kind: kind)))
        let row = SidebarProgramStatusRow(panelID: UUID(), terminalTitle: "agent",
                                         presentation: try #require(records.presentation), fallbackAgent: nil)
        #expect(row.title == "Review")
        #expect(row.badge == label)
        #expect(row.isAgent)
    }
}
