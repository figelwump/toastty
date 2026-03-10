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
}

struct WorkspaceActivitySubtitleFormatterTests {
    @Test
    func managedSessionsOverrideHeuristicFallback() {
        let sessionStatuses = [
            WorkspaceSessionStatus(
                sessionID: "sess-1",
                panelID: UUID(),
                agent: .claude,
                status: SessionStatus(kind: .working, summary: "editing 3 files"),
                cwd: "/repo",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                isActive: true
            ),
        ]

        let subtext = WorkspaceActivitySubtitleFormatter.subtext(
            managedSessionStatuses: sessionStatuses,
            hasActiveManagedSession: true,
            heuristicSubtext: "1 CC · 1 idle"
        )

        #expect(subtext == "1 CC · 1 working")
    }

    @Test
    func managedSessionsAggregateAgentsAndStatuses() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionStatuses = [
            WorkspaceSessionStatus(
                sessionID: "sess-1",
                panelID: UUID(),
                agent: .claude,
                status: SessionStatus(kind: .working, summary: "editing"),
                cwd: "/repo",
                updatedAt: now,
                isActive: true
            ),
            WorkspaceSessionStatus(
                sessionID: "sess-2",
                panelID: UUID(),
                agent: .codex,
                status: SessionStatus(kind: .needsApproval, summary: "needs approval"),
                cwd: "/repo",
                updatedAt: now.addingTimeInterval(1),
                isActive: true
            ),
        ]

        let subtext = WorkspaceActivitySubtitleFormatter.subtext(
            managedSessionStatuses: sessionStatuses,
            hasActiveManagedSession: true,
            heuristicSubtext: nil
        )

        #expect(subtext == "1 CC, 1 Codex · 1 needs approval, 1 working")
    }

    @Test
    func fallsBackToHeuristicWhenNoManagedSessionsExist() {
        let subtext = WorkspaceActivitySubtitleFormatter.subtext(
            managedSessionStatuses: [],
            hasActiveManagedSession: false,
            heuristicSubtext: "1 Codex · 1 running"
        )

        #expect(subtext == "1 Codex · 1 running")
    }

    @Test
    func activeManagedSessionWithoutStatusSuppressesHeuristicFallback() {
        let subtext = WorkspaceActivitySubtitleFormatter.subtext(
            managedSessionStatuses: [],
            hasActiveManagedSession: true,
            heuristicSubtext: "1 CC · 1 running"
        )

        #expect(subtext == nil)
    }

    @Test
    func inactiveManagedStatusesDoNotContributeToSubtitle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionStatuses = [
            WorkspaceSessionStatus(
                sessionID: "sess-active",
                panelID: UUID(),
                agent: .claude,
                status: SessionStatus(kind: .working, summary: "editing"),
                cwd: "/repo",
                updatedAt: now,
                isActive: true
            ),
            WorkspaceSessionStatus(
                sessionID: "sess-stopped",
                panelID: UUID(),
                agent: .codex,
                status: SessionStatus(kind: .ready, summary: "done"),
                cwd: "/repo",
                updatedAt: now.addingTimeInterval(1),
                isActive: false
            ),
        ]

        let subtext = WorkspaceActivitySubtitleFormatter.subtext(
            managedSessionStatuses: sessionStatuses,
            hasActiveManagedSession: true,
            heuristicSubtext: "1 CC · 1 idle"
        )

        #expect(subtext == "1 CC · 1 working")
    }
}

struct TerminalAgentActivityInferenceTests {
    @Test
    func shellPromptClearsStaleClaudeBanner() {
        let visibleText = """
        Claude Code v2.1.72
        Opus 4.6 with high effort
        vishal@Vishal-M1-MacBook-Pro emptyos %
        """

        let activity = TerminalAgentActivityInference.infer(
            terminalTitle: "Claude Code",
            visibleText: visibleText,
            visibleLines: TerminalVisibleTextInspector.sanitizedLines(visibleText)
        )

        #expect(activity == nil)
    }

    @Test
    func runningClaudeBannerStillInfersClaudeActivity() throws {
        let visibleText = """
        Claude Code v2.1.72
        Opus 4.6 with high effort
        Thinking through the migration...
        """

        let activity = try #require(
            TerminalAgentActivityInference.infer(
                terminalTitle: "Terminal",
                visibleText: visibleText,
                visibleLines: TerminalVisibleTextInspector.sanitizedLines(visibleText)
            )
        )

        #expect(activity.agent == .claudeCode)
        #expect(activity.phase == .running)
    }
}
