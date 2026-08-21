import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct SessionRuntimeStoreTests {
    @Test
    func managedProviderConversationFeedRequiresConfirmedBindingAndDeduplicates() throws {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let sessionID = "sess-opencode-feed"
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let record = ManagedAgentResumeRecord(
            agent: .opencode,
            nativeSessionID: "native-opencode",
            sessionFilePath: "/tmp/opencode-marker.json",
            cwd: "/repo",
            capturedAt: date
        )
        store.startSession(
            sessionID: sessionID,
            agent: .opencode,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: date
        )

        #expect(store.resetProviderConversationFeed(
            managedSessionID: sessionID,
            provider: .opencode,
            nativeSessionID: record.nativeSessionID,
            snapshotID: "snapshot-1",
            at: date
        ) == false)
        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: record
        ))
        #expect(store.resetProviderConversationFeed(
            managedSessionID: sessionID,
            provider: .opencode,
            nativeSessionID: record.nativeSessionID,
            snapshotID: "snapshot-1",
            at: date
        ))

        let observation = ProviderTranscriptObservation(
            timestamp: date.addingTimeInterval(1),
            fingerprint: "managed:opencode:message-1",
            payload: .transcript(.assistantMessage(.init(text: "Done"))),
            mayAuthorizeCurrentRuntime: false
        )
        #expect(store.ingestProviderConversationObservation(
            managedSessionID: sessionID,
            provider: .opencode,
            nativeSessionID: record.nativeSessionID,
            snapshotID: "snapshot-1",
            observation: observation
        ))
        #expect(store.ingestProviderConversationObservation(
            managedSessionID: sessionID,
            provider: .opencode,
            nativeSessionID: record.nativeSessionID,
            snapshotID: "snapshot-1",
            observation: observation
        ) == false)

        let feed = try #require(store.providerConversationFeed(managedSessionID: sessionID))
        #expect(feed.provider == .opencode)
        #expect(feed.observations.count == 2)
        #expect(feed.observations.last == observation)
    }

    @Test
    func nativeSessionBindingConfirmationIsCurrentLaunchAndActiveSessionScoped() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let sessionID = "sess-native-confirmation"
        let confirmedAt = Date(timeIntervalSince1970: 1_786_000_000)
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/current-rollout.jsonl",
            cwd: "/repo",
            capturedAt: confirmedAt
        )

        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: confirmedAt
        )

        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: UUID(),
            record: record
        ) == false)
        #expect(store.nativeSessionBindingConfirmation(for: sessionID) == nil)

        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: record
        ))
        let confirmation = store.nativeSessionBindingConfirmation(for: sessionID)
        #expect(confirmation?.managedSessionID == sessionID)
        #expect(confirmation?.agent == .codex)
        #expect(confirmation?.panelID == panelID)
        #expect(confirmation?.nativeSessionID == record.nativeSessionID)
        #expect(confirmation?.sessionFilePath == record.sessionFilePath)
        #expect(confirmation?.confirmedAt == confirmedAt)
        if let confirmation {
            #expect(store.isNativeSessionBindingInputClean(confirmation))
        }

        var repeatedRecord = record
        repeatedRecord.capturedAt = confirmedAt.addingTimeInterval(1)
        #expect(store.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: repeatedRecord
        ))
        #expect(store.nativeSessionBindingConfirmation(for: sessionID) == confirmation)

        store.noteLocalInputForActiveSession(panelID: panelID)
        if let confirmation {
            #expect(store.isNativeSessionBindingInputClean(confirmation) == false)
        }

        store.stopSession(sessionID: sessionID, at: confirmedAt.addingTimeInterval(1))
        #expect(store.nativeSessionBindingConfirmation(for: sessionID) == nil)
    }

    @Test
    func scopeMutationUpdatesWorkspaceStatusProjection() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let workspaceID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-scope",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-scope",
            status: SessionStatus(kind: .idle, summary: "Waiting"),
            at: startedAt
        )

        #expect(store.workspaceStatuses(for: workspaceID).first?.isWorkspaceScoped == false)

        #expect(store.setScope(sessionID: "sess-scope", workspaceIDs: []))
        #expect(store.workspaceStatuses(for: workspaceID).first?.isWorkspaceScoped == true)

        #expect(store.clearScope(sessionID: "sess-scope"))
        #expect(store.workspaceStatuses(for: workspaceID).first?.isWorkspaceScoped == false)
    }

    @Test
    func scopeMutationUpdatesPersistedResumeRecordScope() throws {
        let appStore = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        let scopedWorkspaceID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resumeRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/repo",
            capturedAt: startedAt
        )

        #expect(appStore.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: resumeRecord)))

        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        sessionStore.startSession(
            sessionID: "sess-scope-record",
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        #expect(sessionStore.setScope(sessionID: "sess-scope-record", workspaceIDs: []))
        #expect(persistedResumeRecord(panelID: panelID, in: appStore.state)?.scopedWorkspaceIDs == Set<UUID>())

        #expect(sessionStore.addScope(sessionID: "sess-scope-record", workspaceIDs: [scopedWorkspaceID]))
        #expect(
            persistedResumeRecord(panelID: panelID, in: appStore.state)?.scopedWorkspaceIDs ==
                Set([scopedWorkspaceID])
        )

        #expect(sessionStore.clearScope(sessionID: "sess-scope-record"))
        #expect(persistedResumeRecord(panelID: panelID, in: appStore.state)?.scopedWorkspaceIDs == nil)
    }

    @Test
    func stoppingSessionClearsPersistedResumeRecordScope() throws {
        let appStore = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        let scopedWorkspaceID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resumeRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/repo",
            capturedAt: startedAt,
            scopedWorkspaceIDs: [scopedWorkspaceID]
        )

        #expect(appStore.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: resumeRecord)))

        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        sessionStore.startSession(
            sessionID: "sess-stop-record",
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            scopedWorkspaceIDs: [scopedWorkspaceID],
            at: startedAt
        )

        sessionStore.stopSession(sessionID: "sess-stop-record", at: startedAt.addingTimeInterval(1))

        #expect(persistedResumeRecord(panelID: panelID, in: appStore.state) == nil)
    }

    @Test
    func stopSessionForPanelIfActiveStopsCurrentSession() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-active",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didStop = store.stopSessionForPanelIfActive(
            panelID: panelID,
            reason: .explicit,
            at: startedAt.addingTimeInterval(1)
        )

        #expect(didStop)
        #expect(store.sessionRegistry.activeSession(for: panelID) == nil)
    }

    @Test
    func stopSessionForPanelIfOlderThanStopsEligibleSession() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-older",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didStop = store.stopSessionForPanelIfOlderThan(
            panelID: panelID,
            minimumRuntime: 2,
            reason: .explicit,
            at: startedAt.addingTimeInterval(3)
        )

        #expect(didStop)
        #expect(store.sessionRegistry.activeSession(for: panelID) == nil)
    }

    @Test
    func stopSessionForPanelIfOlderThanKeepsRecentSessionAlive() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-recent",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didStop = store.stopSessionForPanelIfOlderThan(
            panelID: panelID,
            minimumRuntime: 2,
            reason: .explicit,
            at: startedAt.addingTimeInterval(1)
        )

        #expect(didStop == false)
        #expect(store.sessionRegistry.activeSession(for: panelID)?.sessionID == "sess-recent")
    }

    @Test
    func bindStopsActiveSessionWhenPanelCloses() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)

        let workspace = try #require(appStore.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-panel-close",
            agent: .codex,
            panelID: panelID,
            windowID: try #require(appStore.state.windows.first?.id),
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        _ = appStore.send(.closePanel(panelID: panelID))

        #expect(sessionStore.sessionRegistry.activeSession(for: panelID) == nil)
    }

    @Test
    func bindKeepsActiveSessionWhenOwningPanelMovesToBackgroundTab() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)

        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let workspaceID = selection.workspaceID
        let originalTabID = try #require(selection.workspace.resolvedSelectedTabID)
        let originalPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-tab",
            agent: .codex,
            panelID: originalPanelID,
            windowID: selection.windowID,
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-tab",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Editing"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        let backgroundedWorkspace = try #require(appStore.state.workspacesByID[workspaceID])
        let backgroundTabID = try #require(backgroundedWorkspace.resolvedSelectedTabID)
        #expect(backgroundTabID != originalTabID)

        #expect(sessionStore.sessionRegistry.activeSession(for: originalPanelID)?.sessionID == "sess-background-tab")
        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.panelID).contains(originalPanelID))

        #expect(appStore.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID)))
        #expect(sessionStore.panelStatus(for: originalPanelID)?.status.kind == .working)
    }

    @Test
    func workspaceStatusesFollowSessionCreationOrder() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let orderedPanelIDs = selection.workspace.terminalPanelIDsInDisplayOrder
        let leftPanelID = try #require(orderedPanelIDs.first)
        let rightPanelID = try #require(orderedPanelIDs.last)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-right",
            agent: .codex,
            panelID: rightPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo/right",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-right",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Right panel"),
            at: startedAt.addingTimeInterval(2)
        )

        sessionStore.startSession(
            sessionID: "sess-left",
            agent: .claude,
            panelID: leftPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo/left",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-left",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Left panel"),
            at: startedAt.addingTimeInterval(1)
        )

        let statuses = sessionStore.workspaceStatuses(for: selection.workspaceID)
        #expect(statuses.map(\.panelID) == [rightPanelID, leftPanelID])
    }

    @Test
    func workspaceStatusesStayStableWhenSelectedTabChanges() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)

        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let workspaceID = selection.workspaceID
        let originalTabID = try #require(selection.workspace.resolvedSelectedTabID)
        let originalPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-original-tab",
            agent: .codex,
            panelID: originalPanelID,
            windowID: selection.windowID,
            workspaceID: workspaceID,
            cwd: "/repo/original",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-original-tab",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Original tab"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        let workspaceWithNewTab = try #require(appStore.state.workspacesByID[workspaceID])
        let newSelectedTabID = try #require(workspaceWithNewTab.resolvedSelectedTabID)
        #expect(newSelectedTabID != originalTabID)
        let newSelectedPanelID = try #require(workspaceWithNewTab.focusedPanelID)

        sessionStore.startSession(
            sessionID: "sess-new-tab",
            agent: .claude,
            panelID: newSelectedPanelID,
            windowID: selection.windowID,
            workspaceID: workspaceID,
            cwd: "/repo/new",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-new-tab",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "New tab"),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["sess-original-tab", "sess-new-tab"])

        #expect(appStore.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID)))
        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["sess-original-tab", "sess-new-tab"])

        #expect(appStore.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: newSelectedTabID)))
        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["sess-original-tab", "sess-new-tab"])
    }

    @Test
    func handleLocalInterruptResetsWorkingClaudeSession() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-working",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptDoesNotResetFallbackTrackedWorkingCodexSessionOnEscape() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-working",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "test"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Responding")
        )
    }

    @Test
    func handleLocalInterruptResetsHookTrackedWorkingCodexSessionOnEscape() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-hook-working",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-hook-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptResetsHookTrackedNeedsApprovalCodexSessionOnEscape() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-hook-approval",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-hook-approval",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptKeepsCodexControlCResetBehavior() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-control-c",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-control-c",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .controlC,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptDoesNotResetCodexSessionForDifferentPanelEscape() {
        let sessionStore = SessionRuntimeStore()
        let codexPanelID = UUID()
        let otherPanelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-focused-panel",
            agent: .codex,
            panelID: codexPanelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-focused-panel",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: otherPanelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: codexPanelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Responding")
        )
    }

}
