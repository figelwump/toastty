import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct SessionRuntimeStoreCodexRootProgressIntegrationTests {
    @Test
    func explicitHookProgressProjectsExactStatusAndIsolatedAuthority() {
        let store = SessionRuntimeStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_500_000)
        let hookPanelID = UUID()
        let fallbackPanelID = UUID()
        startCodexSession(
            in: store,
            sessionID: "hook-progress",
            panelID: hookPanelID,
            source: .hooks,
            at: startedAt
        )
        startCodexSession(
            in: store,
            sessionID: "fallback-progress",
            panelID: fallbackPanelID,
            source: .sessionLogFallback(reason: "test"),
            at: startedAt
        )
        let initialStatus = SessionStatus(kind: .idle, summary: "Waiting", detail: "Preserve fallback")
        store.updateStatus(sessionID: "hook-progress", status: initialStatus, at: startedAt)
        store.updateStatus(sessionID: "fallback-progress", status: initialStatus, at: startedAt)
        let expectedStatus = SessionStatus(
            kind: .working,
            summary: "Inspecting",
            detail: "Exact hook detail"
        )

        #expect(store.handleCodexHookEvent(
            sessionID: "hook-progress",
            event: rootWorkingHookEvent(status: expectedStatus),
            at: startedAt.addingTimeInterval(1)
        ))
        #expect(store.handleCodexHookEvent(
            sessionID: "fallback-progress",
            event: rootWorkingHookEvent(status: expectedStatus),
            at: startedAt.addingTimeInterval(1)
        ) == false)

        #expect(store.sessionRegistry.activeSession(for: hookPanelID)?.status == expectedStatus)
        #expect(store.sessionRegistry.activeSession(for: fallbackPanelID)?.status == initialStatus)
    }

    @Test
    func explicitHookProgressDoesNotWriteMissingOrStoppedSession() throws {
        let store = SessionRuntimeStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_500_100)
        let panelID = UUID()
        startCodexSession(
            in: store,
            sessionID: "stopped-hook-progress",
            panelID: panelID,
            source: .hooks,
            at: startedAt
        )
        let working = SessionStatus(kind: .working, summary: "Working", detail: "Before stop")
        store.updateStatus(
            sessionID: "stopped-hook-progress",
            status: working,
            at: startedAt.addingTimeInterval(1)
        )
        store.stopSession(
            sessionID: "stopped-hook-progress",
            at: startedAt.addingTimeInterval(2)
        )
        let stoppedUpdatedAt = try #require(
            store.sessionRegistry.sessionsByID["stopped-hook-progress"]?.statusUpdatedAt
        )

        #expect(store.handleCodexHookEvent(
            sessionID: "missing-hook-progress",
            event: rootWorkingHookEvent(status: working),
            at: startedAt.addingTimeInterval(3)
        ) == false)
        _ = store.handleCodexHookEvent(
            sessionID: "stopped-hook-progress",
            event: rootWorkingHookEvent(
                status: SessionStatus(kind: .working, summary: "Working", detail: "After stop")
            ),
            at: startedAt.addingTimeInterval(3)
        )

        let stoppedRecord = try #require(store.sessionRegistry.sessionsByID["stopped-hook-progress"])
        #expect(stoppedRecord.status == working)
        #expect(stoppedRecord.statusUpdatedAt == stoppedUpdatedAt)
        #expect(stoppedRecord.isActive == false)
    }

    @Test
    func nilSourceHookProgressKeepsLegacyProjection() {
        let store = SessionRuntimeStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_500_200)
        let panelID = UUID()
        startCodexSession(
            in: store,
            sessionID: "nil-source-hook-progress",
            panelID: panelID,
            source: nil,
            at: startedAt
        )
        let expectedStatus = SessionStatus(
            kind: .working,
            summary: "Legacy working",
            detail: "Nil-source detail"
        )

        #expect(store.handleCodexHookEvent(
            sessionID: "nil-source-hook-progress",
            event: rootWorkingHookEvent(status: expectedStatus),
            at: startedAt.addingTimeInterval(1)
        ))

        #expect(store.sessionRegistry.activeSession(for: panelID)?.status == expectedStatus)
    }

    @Test
    func sessionLogProgressUsesStoreAuthorityAndCurrentRawKind() {
        let store = SessionRuntimeStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_500_300)
        let hookPanelID = UUID()
        let fallbackPanelID = UUID()
        startCodexSession(
            in: store,
            sessionID: "hook-log-interleaving",
            panelID: hookPanelID,
            source: .hooks,
            at: startedAt
        )
        startCodexSession(
            in: store,
            sessionID: "fallback-log-interleaving",
            panelID: fallbackPanelID,
            source: .sessionLogFallback(reason: "test"),
            at: startedAt
        )
        let idle = SessionStatus(kind: .idle, summary: "Waiting", detail: "Initial idle")
        store.updateStatus(sessionID: "hook-log-interleaving", status: idle, at: startedAt)
        store.updateStatus(sessionID: "fallback-log-interleaving", status: idle, at: startedAt)

        #expect(store.handleCodexSessionLogRootProgressObservation(
            sessionID: "hook-log-interleaving",
            observation: .sessionLogWorking(detail: "Rejected log work"),
            at: startedAt.addingTimeInterval(1)
        ) == false)
        #expect(store.handleCodexHookEvent(
            sessionID: "fallback-log-interleaving",
            event: rootWorkingHookEvent(status: SessionStatus(
                kind: .working,
                summary: "Working",
                detail: "Rejected hook work"
            )),
            at: startedAt.addingTimeInterval(1)
        ) == false)
        #expect(store.sessionRegistry.activeSession(for: hookPanelID)?.status == idle)
        #expect(store.sessionRegistry.activeSession(for: fallbackPanelID)?.status == idle)

        #expect(store.handleCodexHookEvent(
            sessionID: "hook-log-interleaving",
            event: rootWorkingHookEvent(status: SessionStatus(
                kind: .working,
                summary: "Hook working",
                detail: "Exact hook work"
            )),
            at: startedAt.addingTimeInterval(2)
        ))
        #expect(store.handleCodexSessionLogRootProgressObservation(
            sessionID: "fallback-log-interleaving",
            observation: .sessionLogWorking(detail: "Exact log work"),
            at: startedAt.addingTimeInterval(2)
        ))
        #expect(store.sessionRegistry.activeSession(for: hookPanelID)?.status == SessionStatus(
            kind: .working,
            summary: "Hook working",
            detail: "Exact hook work"
        ))
        #expect(store.sessionRegistry.activeSession(for: fallbackPanelID)?.status == SessionStatus(
            kind: .working,
            summary: "Working",
            detail: "Exact log work"
        ))

        #expect(store.handleCodexSessionLogRootProgressObservation(
            sessionID: "hook-log-interleaving",
            observation: .sessionLogTurnAborted(detail: "Rejected log abort"),
            at: startedAt.addingTimeInterval(3)
        ) == false)
        #expect(store.handleCodexSessionLogRootProgressObservation(
            sessionID: "fallback-log-interleaving",
            observation: .sessionLogTurnAborted(detail: "Exact abort detail"),
            at: startedAt.addingTimeInterval(3)
        ))
        #expect(store.sessionRegistry.activeSession(for: hookPanelID)?.status?.kind == .working)
        #expect(store.sessionRegistry.activeSession(for: fallbackPanelID)?.status == SessionStatus(
            kind: .idle,
            summary: "Waiting",
            detail: "Exact abort detail"
        ))
    }

    @Test
    func sessionLogProgressDoesNotWriteNilSourceOrStoppedSession() throws {
        let store = SessionRuntimeStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_500_400)
        let nilSourcePanelID = UUID()
        let stoppedPanelID = UUID()
        startCodexSession(
            in: store,
            sessionID: "nil-source-log-progress",
            panelID: nilSourcePanelID,
            source: nil,
            at: startedAt
        )
        startCodexSession(
            in: store,
            sessionID: "stopped-log-progress",
            panelID: stoppedPanelID,
            source: .sessionLogFallback(reason: "test"),
            at: startedAt
        )
        let initialStatus = SessionStatus(kind: .idle, summary: "Waiting", detail: "Initial")
        store.updateStatus(sessionID: "nil-source-log-progress", status: initialStatus, at: startedAt)
        store.updateStatus(sessionID: "stopped-log-progress", status: initialStatus, at: startedAt)
        store.stopSession(
            sessionID: "stopped-log-progress",
            at: startedAt.addingTimeInterval(1)
        )
        let stoppedUpdatedAt = try #require(
            store.sessionRegistry.sessionsByID["stopped-log-progress"]?.statusUpdatedAt
        )

        #expect(store.handleCodexSessionLogRootProgressObservation(
            sessionID: "nil-source-log-progress",
            observation: .sessionLogWorking(detail: "No explicit source"),
            at: startedAt.addingTimeInterval(2)
        ) == false)
        #expect(store.handleCodexSessionLogRootProgressObservation(
            sessionID: "stopped-log-progress",
            observation: .sessionLogWorking(detail: "After stop"),
            at: startedAt.addingTimeInterval(2)
        ) == false)

        #expect(store.sessionRegistry.activeSession(for: nilSourcePanelID)?.status == initialStatus)
        let stoppedRecord = try #require(store.sessionRegistry.sessionsByID["stopped-log-progress"])
        #expect(stoppedRecord.status == initialStatus)
        #expect(stoppedRecord.statusUpdatedAt == stoppedUpdatedAt)
    }

    @Test
    func localInterruptUsesExplicitAuthorityAndPreservesNilSourceBehavior() {
        let store = SessionRuntimeStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_500_500)
        let hookPanelID = UUID()
        let fallbackPanelID = UUID()
        let nilSourcePanelID = UUID()
        startCodexSession(
            in: store,
            sessionID: "hook-local-interrupt",
            panelID: hookPanelID,
            source: .hooks,
            at: startedAt
        )
        startCodexSession(
            in: store,
            sessionID: "fallback-local-interrupt",
            panelID: fallbackPanelID,
            source: .sessionLogFallback(reason: "test"),
            at: startedAt
        )
        startCodexSession(
            in: store,
            sessionID: "nil-source-local-interrupt",
            panelID: nilSourcePanelID,
            source: nil,
            at: startedAt
        )
        let working = SessionStatus(kind: .working, summary: "Working", detail: "Before interrupt")
        store.updateStatus(sessionID: "hook-local-interrupt", status: working, at: startedAt)
        store.updateStatus(sessionID: "fallback-local-interrupt", status: working, at: startedAt)
        store.updateStatus(sessionID: "nil-source-local-interrupt", status: working, at: startedAt)

        #expect(store.handleLocalInterruptForPanelIfActive(
            panelID: hookPanelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(1)
        ))
        #expect(store.handleLocalInterruptForPanelIfActive(
            panelID: fallbackPanelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(1)
        ) == false)
        #expect(store.handleLocalInterruptForPanelIfActive(
            panelID: nilSourcePanelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(1)
        ) == false)
        #expect(store.sessionRegistry.activeSession(for: hookPanelID)?.status == SessionStatus(
            kind: .idle,
            summary: "Waiting",
            detail: "Ready for prompt"
        ))
        #expect(store.sessionRegistry.activeSession(for: fallbackPanelID)?.status == working)
        #expect(store.sessionRegistry.activeSession(for: nilSourcePanelID)?.status == working)

        store.updateStatus(
            sessionID: "hook-local-interrupt",
            status: working,
            at: startedAt.addingTimeInterval(2)
        )
        #expect(store.handleLocalInterruptForPanelIfActive(
            panelID: hookPanelID,
            kind: .controlC,
            at: startedAt.addingTimeInterval(3)
        ))
        #expect(store.handleLocalInterruptForPanelIfActive(
            panelID: fallbackPanelID,
            kind: .controlC,
            at: startedAt.addingTimeInterval(3)
        ))
        #expect(store.handleLocalInterruptForPanelIfActive(
            panelID: nilSourcePanelID,
            kind: .controlC,
            at: startedAt.addingTimeInterval(3)
        ))
        for panelID in [hookPanelID, fallbackPanelID, nilSourcePanelID] {
            #expect(store.sessionRegistry.activeSession(for: panelID)?.status == SessionStatus(
                kind: .idle,
                summary: "Waiting",
                detail: "Ready for prompt"
            ))
        }
    }

    @Test
    func visibleTextProgressProjectsExactDetailAndSkipsDuplicateWrite() throws {
        let store = SessionRuntimeStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_500_600)
        let panelID = UUID()
        startCodexSession(
            in: store,
            sessionID: "explicit-visible-progress",
            panelID: panelID,
            source: .hooks,
            at: startedAt
        )
        store.updateStatus(
            sessionID: "explicit-visible-progress",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Initial detail"),
            at: startedAt
        )
        let expectedStatus = SessionStatus(
            kind: .working,
            summary: "Working",
            detail: "Running exact visible-text tests"
        )

        #expect(store.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running exact visible-text tests",
            promptState: .busy,
            at: startedAt.addingTimeInterval(1)
        ))
        let firstRecord = try #require(store.sessionRegistry.activeSession(for: panelID))
        #expect(firstRecord.status == expectedStatus)
        let firstUpdatedAt = try #require(firstRecord.statusUpdatedAt)

        #expect(store.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running exact visible-text tests",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        ) == false)
        #expect(store.sessionRegistry.activeSession(for: panelID)?.status == expectedStatus)
        #expect(store.sessionRegistry.activeSession(for: panelID)?.statusUpdatedAt == firstUpdatedAt)
    }

    @Test
    func visibleTextProgressCannotResurrectProtectedOrStoppedSession() throws {
        let store = SessionRuntimeStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_500_700)
        let panelID = UUID()
        startCodexSession(
            in: store,
            sessionID: "protected-visible-progress",
            panelID: panelID,
            source: .sessionLogFallback(reason: "test"),
            at: startedAt
        )
        let protectedStatuses = [
            SessionStatus(kind: .idle, summary: "Waiting", detail: "Preserve idle"),
            SessionStatus(kind: .ready, summary: "Ready", detail: "Preserve ready"),
            SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Preserve approval"),
            SessionStatus(kind: .error, summary: "Error", detail: "Preserve error"),
        ]
        for (index, protectedStatus) in protectedStatuses.enumerated() {
            let statusDate = startedAt.addingTimeInterval(TimeInterval(index + 1))
            store.updateStatus(
                sessionID: "protected-visible-progress",
                status: protectedStatus,
                at: statusDate
            )

            #expect(store.refreshManagedSessionStatusFromVisibleTextIfNeeded(
                panelID: panelID,
                visibleText: "• Running stale visible-text work",
                promptState: .busy,
                at: statusDate.addingTimeInterval(0.5)
            ) == false)
            #expect(store.sessionRegistry.activeSession(for: panelID)?.status == protectedStatus)
            #expect(store.sessionRegistry.activeSession(for: panelID)?.statusUpdatedAt == statusDate)
        }

        let working = SessionStatus(kind: .working, summary: "Working", detail: "Before stop")
        let workingDate = startedAt.addingTimeInterval(10)
        store.updateStatus(
            sessionID: "protected-visible-progress",
            status: working,
            at: workingDate
        )
        store.stopSession(
            sessionID: "protected-visible-progress",
            at: workingDate.addingTimeInterval(1)
        )

        #expect(store.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running stale visible-text work after stop",
            promptState: .busy,
            at: workingDate.addingTimeInterval(2)
        ) == false)
        let stoppedRecord = try #require(store.sessionRegistry.sessionsByID["protected-visible-progress"])
        #expect(stoppedRecord.status == working)
        #expect(stoppedRecord.statusUpdatedAt == workingDate)
        #expect(stoppedRecord.isActive == false)
    }

    @Test
    func explicitVisibleTextProgressClearsRecoveredFatalSuppressionInLegacyOrder() {
        let store = SessionRuntimeStore()
        let startedAt = Date(timeIntervalSince1970: 1_700_500_800)
        let panelID = UUID()
        let usageLimitBanner = """
        You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again later.
        """
        startCodexSession(
            in: store,
            sessionID: "explicit-visible-suppression",
            panelID: panelID,
            source: .hooks,
            at: startedAt
        )
        store.updateStatus(
            sessionID: "explicit-visible-suppression",
            status: SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner),
            at: startedAt
        )
        store.updateStatus(
            sessionID: "explicit-visible-suppression",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Recovered"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(store.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: usageLimitBanner,
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        ) == false)
        #expect(store.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running after recovery",
            promptState: .busy,
            at: startedAt.addingTimeInterval(3)
        ))
        #expect(store.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: usageLimitBanner,
            promptState: .busy,
            at: startedAt.addingTimeInterval(4)
        ))
        #expect(store.sessionRegistry.activeSession(for: panelID)?.status == SessionStatus(
            kind: .error,
            summary: "Error",
            detail: usageLimitBanner
        ))
    }

    private func startCodexSession(
        in store: SessionRuntimeStore,
        sessionID: String,
        panelID: UUID,
        source: CodexStatusTrackingSource?,
        at startedAt: Date
    ) {
        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: source,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
    }

    private func rootWorkingHookEvent(status: SessionStatus) -> CodexHookEvent {
        CodexHookEvent(
            hookEventName: "UserPromptSubmit",
            threadID: "thread-root",
            turnID: "turn-root",
            promptFingerprint: nil,
            status: status,
            nativeSessionID: "thread-root",
            sessionFilePath: nil,
            cwd: nil
        )
    }
}
