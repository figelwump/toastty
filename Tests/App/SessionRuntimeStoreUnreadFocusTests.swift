import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
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

}
