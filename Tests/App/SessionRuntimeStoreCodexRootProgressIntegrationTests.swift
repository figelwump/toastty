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
