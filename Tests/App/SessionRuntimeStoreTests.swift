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
        let sessionStore = SessionRuntimeStore()
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
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
    }
}
