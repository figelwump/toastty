import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct SessionRuntimeStoreVisibleTextTests {
    @Test(arguments: [CodexStatusTrackingSource.hooks, .sessionLogFallback(reason: "test")])
    func computerUseMenuProjectsWaitingUntilItClosesWithoutANotification(source: CodexStatusTrackingSource) throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.allTerminalPanelIDs.first {
            $0 != selection.workspace.focusedPanelID
        })
        let sessionStore = SessionRuntimeStore(sendSessionStatusNotification: { _, _, _, _, _ in })
        sessionStore.bind(store: appStore)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let working = SessionStatus(kind: .working, summary: "Working", detail: "Using computer")
        let laterProgress = SessionStatus(kind: .working, summary: "Working", detail: "Another tool is running")
        var actionableEvents: [ManagedSessionActionableEvent] = []
        sessionStore.onActionableEvent = { actionableEvents.append($0) }
        sessionStore.startSession(
            sessionID: "cua-approval",
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: source,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        sessionStore.updateStatus(sessionID: "cua-approval", status: working, at: now)
        let prompt = """
        Field 1/1
        Allow Computer Use to use "Safari"?
        App: Safari
        › 1. Allow
          2. Allow for this session
          3. Always allow
          4. Cancel
        enter to submit | esc to cancel
        """

        func refresh(_ screen: String, elapsed: TimeInterval) -> Bool {
            sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
                panelID: panelID, visibleText: screen, promptState: .busy, at: now.addingTimeInterval(elapsed)
            )
        }

        #expect(refresh(prompt, elapsed: 1))
        #expect(sessionStore.sessionRegistry.activeSession(for: panelID)?.status?.kind == .needsApproval)
        #expect(appStore.state.workspacesByID[selection.workspaceID]?.unreadPanelIDs.isEmpty == true)
        #expect(refresh(prompt, elapsed: 2) == false)
        #expect(refresh("", elapsed: 3) == false)
        sessionStore.updateStatus(sessionID: "cua-approval", status: laterProgress, at: now.addingTimeInterval(3))
        #expect(sessionStore.sessionRegistry.activeSession(for: panelID)?.status?.kind == .needsApproval)
        #expect(refresh("Working (10s • esc to interrupt)", elapsed: 4))
        #expect(sessionStore.sessionRegistry.activeSession(for: panelID)?.status == laterProgress)
        #expect(sessionStore.sessionRegistry.activeSession(for: panelID)?.turnStartedAt == now)
        #expect(actionableEvents.isEmpty)

        // A real approval can arrive while the visible menu is active.
        #expect(refresh(prompt, elapsed: 5))
        let providerApproval = SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Run pwd?")
        sessionStore.updateStatus(sessionID: "cua-approval", status: providerApproval, at: now.addingTimeInterval(6))
        #expect(refresh("Working (12s • esc to interrupt)", elapsed: 7) == false)
        #expect(sessionStore.sessionRegistry.activeSession(for: panelID)?.status == providerApproval)
        #expect(appStore.state.workspacesByID[selection.workspaceID]?.unreadPanelIDs == [panelID])

        if source == .hooks {
            sessionStore.updateStatus(sessionID: "cua-approval", status: working, at: now.addingTimeInterval(8))
            #expect(refresh(prompt, elapsed: 9))
            // An interrupt can arrive after the menu closed but before the next poll.
            #expect(sessionStore.handleLocalInterruptForPanelIfActive(
                panelID: panelID, kind: .escape, at: now.addingTimeInterval(10)
            ))
            #expect(refresh("› Ask Codex to do anything", elapsed: 11) == false)
            #expect(sessionStore.sessionRegistry.activeSession(for: panelID)?.status?.kind == .idle)
        }
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
            codexStatusTrackingSource: .externallyReported,
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
}
