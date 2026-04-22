import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct SessionRuntimeStoreTests {
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
    func updateStatusMarksUnfocusedPanelUnreadWhenSessionNeedsAttention() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-unfocused",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-unfocused",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusSendsNotificationForManagedUnfocusedPanel() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-managed",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-managed",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notifications = await recorder.notifications()
        let notification = try #require(notifications.first)
        #expect(notification.title == "Codex is ready")
        #expect(notification.body == "Finished")
        #expect(notification.workspaceID == selection.workspaceID)
        #expect(notification.panelID == backgroundPanelID)
        #expect(notification.context.workspaceTitle == "Workspace 1")

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusDoesNotMarkFocusedPanelUnreadWhenSessionNeedsAttention() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { true })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused",
            agent: .claude,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func updateStatusCollapsesReadyToIdleForFocusedPanelInActiveApp() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { true })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused-ready",
            agent: .codex,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused-ready",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(sessionStore.panelStatus(for: focusedPanelID)?.status.kind == .idle)
        #expect(sessionStore.panelStatus(for: focusedPanelID)?.status.detail == "Finished")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func handleCommandFinishedMarksBackgroundProcessWatchReadyAndUnread() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_010)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "bundle exec rspec",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        #expect(
            sessionStore.handleCommandFinished(
                panelID: backgroundPanelID,
                exitCode: 0,
                at: startedAt.addingTimeInterval(1)
            )
        )

        let record = try #require(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID))
        #expect(record.agent == .processWatch)
        #expect(record.displayTitleOverride == "bundle exec rspec")
        #expect(record.status?.kind == .ready)
        #expect(record.status?.detail == "Completed")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func handleCommandFinishedMarksBackgroundProcessWatchErrorAndUnread() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_020)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "npm test",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        #expect(
            sessionStore.handleCommandFinished(
                panelID: backgroundPanelID,
                exitCode: 1,
                at: startedAt.addingTimeInterval(1)
            )
        )

        let record = try #require(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID))
        #expect(record.status?.kind == .error)
        #expect(record.status?.detail == "Exit 1")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func focusPanelCollapsesUnreadReadySessionToIdle() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-ready",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-ready",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .idle)
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.detail == "Finished")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func focusPanelRemovesReadyProcessWatchAfterRead() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_030)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "bundle exec rspec",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        #expect(
            sessionStore.handleCommandFinished(
                panelID: backgroundPanelID,
                exitCode: 0,
                at: startedAt.addingTimeInterval(1)
            )
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID) == nil)
        #expect(sessionStore.panelStatus(for: backgroundPanelID) == nil)
    }

    @Test
    func focusPanelKeepsNeedsApprovalStatusAfterRead() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-approval",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-approval",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .needsApproval)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func updateStatusCollapsesReadyToIdleWhenFocusedApprovalIsResolved() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { true })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-approval-resolved",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-approval-resolved",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .needsApproval)

        sessionStore.updateStatus(
            sessionID: "sess-approval-resolved",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Continuing"),
            at: startedAt.addingTimeInterval(2)
        )
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .working)

        sessionStore.updateStatus(
            sessionID: "sess-approval-resolved",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .idle)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func focusPanelKeepsErrorStatusAfterRead() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-error",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-error",
            status: SessionStatus(kind: .error, summary: "Error", detail: "Failed"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .error)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func focusPanelRemovesErroredProcessWatchAfterRead() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_040)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "npm test",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        #expect(
            sessionStore.handleCommandFinished(
                panelID: backgroundPanelID,
                exitCode: 2,
                at: startedAt.addingTimeInterval(1)
            )
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID) == nil)
        #expect(sessionStore.panelStatus(for: backgroundPanelID) == nil)
    }

    @Test
    func stopSessionForPanelIfOlderThanKeepsCompletedProcessWatchAliveUntilRead() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_050)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "bundle exec rspec",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        #expect(
            sessionStore.handleCommandFinished(
                panelID: backgroundPanelID,
                exitCode: 0,
                at: startedAt.addingTimeInterval(1)
            )
        )

        #expect(
            sessionStore.stopSessionForPanelIfOlderThan(
                panelID: backgroundPanelID,
                minimumRuntime: 2,
                reason: .idleAtPrompt,
                at: startedAt.addingTimeInterval(3)
            ) == false
        )
        #expect(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID)?.status?.kind == .ready)
    }

    @Test
    func idleAtPromptFallbackCompletesBackgroundProcessWatchAndSendsNotification() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_060)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "bundle exec rspec",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        #expect(
            sessionStore.stopSessionForPanelIfOlderThan(
                panelID: backgroundPanelID,
                minimumRuntime: 1,
                reason: .idleAtPrompt,
                at: startedAt.addingTimeInterval(2)
            )
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let record = try #require(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID))
        #expect(record.status?.kind == .ready)
        #expect(record.status?.detail == "Completed")

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Command finished")
        #expect(notification.body == "bundle exec rspec")
        #expect(notification.workspaceID == selection.workspaceID)
        #expect(notification.panelID == backgroundPanelID)

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusDoesNotSendNotificationForFocusedManagedPanel() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { true }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused-managed",
            agent: .claude,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused-managed",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(1)
        )

        await settleNotificationTasks()

        let notifications = await recorder.notifications()
        #expect(notifications.isEmpty)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func updateStatusSendsNotificationForFocusedManagedPanelWhenApplicationIsInactive() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused-backgrounded",
            agent: .codex,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused-backgrounded",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Codex is ready")
        #expect(notification.body == "Finished")

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [focusedPanelID])
    }

    @Test
    func updateStatusSendsNotificationForUnfocusedManagedPanelWhenApplicationIsInactive() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-backgrounded",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-backgrounded",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Codex is ready")
        #expect(notification.body == "Finished")

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusDoesNotSendNotificationForUnmanagedSession() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-unmanaged",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-unmanaged",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await settleNotificationTasks()

        let notifications = await recorder.notifications()
        #expect(notifications.isEmpty)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusDoesNotRepeatNotificationForSameActionableKind() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-repeat",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-repeat",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "First"),
            at: startedAt.addingTimeInterval(1)
        )
        await waitUntilNotificationCount(recorder, expectedCount: 1)

        sessionStore.updateStatus(
            sessionID: "sess-repeat",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Second"),
            at: startedAt.addingTimeInterval(2)
        )
        await settleNotificationTasks()

        let notificationCount = await recorder.count()
        #expect(notificationCount == 1)
    }

    @Test
    func updateStatusClearsUnreadWhenManagedSessionReturnsToWorking() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { true })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-managed-working",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-managed-working",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Subagent finished"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfterReady = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterReady.unreadPanelIDs == [backgroundPanelID])

        sessionStore.updateStatus(
            sessionID: "sess-managed-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Continuing"),
            at: startedAt.addingTimeInterval(2)
        )

        let workspaceAfterWorking = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterWorking.unreadPanelIDs.isEmpty)
        #expect(workspaceAfterWorking.unreadNotificationCount == 0)
    }

    @Test
    func updateStatusKeepsUnreadWhenFocusedManagedSessionReturnsToWorkingInInactiveApp() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { false })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused-managed-working-inactive",
            agent: .codex,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused-managed-working-inactive",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Subagent finished"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfterReady = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterReady.unreadPanelIDs == [focusedPanelID])

        sessionStore.updateStatus(
            sessionID: "sess-focused-managed-working-inactive",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Continuing"),
            at: startedAt.addingTimeInterval(2)
        )

        let workspaceAfterWorking = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterWorking.unreadPanelIDs == [focusedPanelID])
        #expect(workspaceAfterWorking.unreadNotificationCount == 1)
    }

    @Test
    func updateStatusClearsUnreadWhenBackgroundManagedSessionReturnsToWorkingInInactiveApp() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { false })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-managed-working-inactive",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-managed-working-inactive",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Subagent finished"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfterReady = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterReady.unreadPanelIDs == [backgroundPanelID])

        sessionStore.updateStatus(
            sessionID: "sess-background-managed-working-inactive",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Continuing"),
            at: startedAt.addingTimeInterval(2)
        )

        let workspaceAfterWorking = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterWorking.unreadPanelIDs.isEmpty)
        #expect(workspaceAfterWorking.unreadNotificationCount == 0)
    }

    @Test
    func updateStatusKeepsUnreadWhenUnmanagedSessionReturnsToWorking() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-unmanaged-working",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-unmanaged-working",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Subagent finished"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfterReady = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterReady.unreadPanelIDs == [backgroundPanelID])

        sessionStore.updateStatus(
            sessionID: "sess-unmanaged-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Continuing"),
            at: startedAt.addingTimeInterval(2)
        )

        let workspaceAfterWorking = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterWorking.unreadPanelIDs == [backgroundPanelID])
        #expect(workspaceAfterWorking.unreadNotificationCount == 1)
    }

    @Test
    func updateStatusFallsBackToTrimmedSummaryWhenDetailIsBlank() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-blank-detail",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-blank-detail",
            status: SessionStatus(kind: .ready, summary: "  Ready for prompt  ", detail: "   \n"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.body == "Ready for prompt")
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
    func handleLocalInterruptDoesNotResetWorkingCodexSessionOnEscape() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-working",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
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
    func refreshManagedSessionStatusFromVisibleTextUpdatesWorkingCodexDetail() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding to your prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: """
            dev@host ~/repo % codex
            • Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count.
            """,
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(
                    kind: .working,
                    summary: "Working",
                    detail: "Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count."
                )
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextIgnoresGenericWorkingSpinner() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-generic-visible-text",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-generic-visible-text",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding to your prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "Working (7s • esc to interrupt)",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Responding to your prompt")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextDoesNotRecoverIdleCodexSessionFromLiveStatusLine() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-idle-recovery",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-idle-recovery",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: """
            dev@host ~/repo % codex
            • Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count.
            Deciding on a test file (20s • esc to interrupt)
            """,
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextDoesNotRecoverReadyCodexSessionFromLiveStatusLine() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-ready-recovery",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-ready-recovery",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished previous task"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "Deciding on a test file (20s • esc to interrupt)",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .ready, summary: "Ready", detail: "Finished previous task")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextDoesNotRecoverIdleCodexSessionFromStaleBulletAtPrompt() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-stale-bullet",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-stale-bullet",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: """
            • Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count.
            dev@host ~/repo %
            """,
            promptState: .idleAtPrompt,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextPromotesWorkingCodexSessionToErrorForUsageLimitBanner() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let usageLimitBanner = """
        You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Apr 2nd, 2026 7:19 PM.
        """

        sessionStore.startSession(
            sessionID: "sess-visible-text-error",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding to your prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: usageLimitBanner,
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner)
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextKeepsErrorStatusWhenFatalBannerDisappears() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let usageLimitBanner = """
        You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Apr 2nd, 2026 7:19 PM.
        """

        sessionStore.startSession(
            sessionID: "sess-visible-text-error-sticky",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error-sticky",
            status: SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running pwd",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner)
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextIgnoresStaleUsageLimitBannerAfterWatcherRecovery() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let usageLimitBanner = """
        You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Apr 2nd, 2026 7:19 PM.
        """

        sessionStore.startSession(
            sessionID: "sess-visible-text-error-recovery",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error-recovery",
            status: SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error-recovery",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running tests"),
            at: startedAt.addingTimeInterval(2)
        )

        let didRefreshStaleBanner = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: usageLimitBanner,
            promptState: .busy,
            at: startedAt.addingTimeInterval(3)
        )
        let didRefreshWorkingDetail = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running pwd",
            promptState: .busy,
            at: startedAt.addingTimeInterval(4)
        )
        let didRefreshRecoveredError = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: usageLimitBanner,
            promptState: .busy,
            at: startedAt.addingTimeInterval(5)
        )

        #expect(didRefreshStaleBanner == false)
        #expect(didRefreshWorkingDetail)
        #expect(didRefreshRecoveredError)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner)
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextKeepsSuppressingRecoveredBannerAcrossGenericVisibleText() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let usageLimitBanner = """
        You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Apr 2nd, 2026 7:19 PM.
        """

        sessionStore.startSession(
            sessionID: "sess-visible-text-error-scroll-gap",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error-scroll-gap",
            status: SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error-scroll-gap",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running tests"),
            at: startedAt.addingTimeInterval(2)
        )

        let didRefreshGenericVisibleText = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: """
            dev@host ~/repo % codex
            OpenAI Codex (v0.1)
            """,
            promptState: .busy,
            at: startedAt.addingTimeInterval(3)
        )
        let didRefreshStaleBanner = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: usageLimitBanner,
            promptState: .busy,
            at: startedAt.addingTimeInterval(4)
        )

        #expect(didRefreshGenericVisibleText == false)
        #expect(didRefreshStaleBanner == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Running tests")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextIgnoresNonCodexAgent() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-claude",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-claude",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running pwd",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Responding")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextIgnoresSessionWithoutCurrentStatus() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-no-status",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running pwd",
            promptState: .busy,
            at: startedAt.addingTimeInterval(1)
        )

        #expect(didRefresh == false)
        #expect(sessionStore.sessionRegistry.activeSession(for: panelID)?.status == nil)
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextSkipsDuplicateWorkingDetail() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-duplicate",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-duplicate",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running pwd"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running pwd",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Running pwd")
        )
    }

    @Test
    func laterFlagPersistsWhenReadSessionIsFocused() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_300)

        sessionStore.startSession(
            sessionID: "sess-later-focus",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-focus",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Review this change"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-focus", isFlagged: true)

        #expect(sessionStore.isLaterFlagged(sessionID: "sess-later-focus"))
        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.isLaterFlagged(sessionID: "sess-later-focus"))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .idle)
    }

    @Test
    func laterFlagClearsWhenSessionReturnsToWorking() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_301)

        sessionStore.startSession(
            sessionID: "sess-later-working",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-working",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Review requested"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-working", isFlagged: true)

        sessionStore.updateStatus(
            sessionID: "sess-later-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(sessionStore.isLaterFlagged(sessionID: "sess-later-working") == false)
    }

    @Test
    func laterFlagClearsWhenSessionTransitionsToNewActionableStatus() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_302)

        sessionStore.startSession(
            sessionID: "sess-later-actionable",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-actionable",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Editing"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-actionable", isFlagged: true)

        sessionStore.updateStatus(
            sessionID: "sess-later-actionable",
            status: SessionStatus(kind: .error, summary: "Error", detail: "Command failed"),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(sessionStore.isLaterFlagged(sessionID: "sess-later-actionable") == false)
    }

    @Test
    func laterFlagSurvivesWorkingDetailRefresh() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_303)

        sessionStore.startSession(
            sessionID: "sess-later-refresh",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-refresh",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Reading files"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-refresh", isFlagged: true)

        sessionStore.updateStatus(
            sessionID: "sess-later-refresh",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running tests"),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(sessionStore.isLaterFlagged(sessionID: "sess-later-refresh"))
    }

    private func makeTwoPanelAppState() -> AppState {
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let leftSlotID = UUID()
        let rightSlotID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Workspace 1",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: leftSlotID, panelID: leftPanelID),
                second: .slot(slotID: rightSlotID, panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/repo")),
                rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/repo")),
            ],
            focusedPanelID: leftPanelID
        )
        let window = WindowState(
            id: windowID,
            frame: CGRectCodable(x: 120, y: 120, width: 1280, height: 760),
            workspaceIDs: [workspaceID],
            selectedWorkspaceID: workspaceID
        )

        return AppState(
            windows: [window],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: nil
        )
    }
}

private struct RecordedSessionNotification: Equatable {
    let title: String
    let body: String
    let workspaceID: UUID
    let panelID: UUID
    let context: DesktopNotificationContext
}

private actor SessionNotificationRecorder {
    private var recorded: [RecordedSessionNotification] = []

    func record(
        title: String,
        body: String,
        workspaceID: UUID,
        panelID: UUID,
        context: DesktopNotificationContext
    ) {
        recorded.append(
            RecordedSessionNotification(
                title: title,
                body: body,
                workspaceID: workspaceID,
                panelID: panelID,
                context: context
            )
        )
    }

    func notifications() -> [RecordedSessionNotification] {
        recorded
    }

    func count() -> Int {
        recorded.count
    }
}

private func settleNotificationTasks(iterations: Int = 12) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}

private func waitUntilNotificationCount(
    _ recorder: SessionNotificationRecorder,
    expectedCount: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
    while await recorder.count() != expectedCount && Date() < deadline {
        await Task.yield()
    }
}
