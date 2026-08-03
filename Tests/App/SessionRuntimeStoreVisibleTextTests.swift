import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct SessionRuntimeStoreVisibleTextTests {
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
}
