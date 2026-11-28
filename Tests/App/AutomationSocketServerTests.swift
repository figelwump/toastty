import RemoteProtocol
import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerSessionLifecycleTests: AutomationSocketServerTestSupport {
    @Test
    func removedLegacySessionEventsAreRejected() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        for eventType in ["session.progress", "session.needs_input", "session.error"] {
            let response = try sendEvent(type: eventType, socketPath: socketPath)
            #expect(response.ok == false)
            #expect(response.error?.code == "UNKNOWN_EVENT_TYPE")
        }
    }

    @Test
    func sessionStartResponseIncludesSessionID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-123"
        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("sessionID") == sessionID)
    }

    @Test
    func sessionScopeCommandsMutateActiveSessionScope() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-scope-socket"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let setCurrentResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "scope-set-current",
                command: "session.scope.set_current",
                callerSessionID: sessionID,
                payload: [
                    "sessionID": .string(sessionID),
                    "panelID": .string(server.panelID.uuidString),
                ]
            ),
            socketPath: socketPath
        )

        #expect(setCurrentResponse.ok)
        #expect(setCurrentResponse.result?.bool("isScoped") == true)
        #expect(setCurrentResponse.result?.stringArray("workspaceIDs") == [])
        #expect(setCurrentResponse.result?.stringArray("effectiveWorkspaceIDs") == [server.workspaceID.uuidString])
        let currentOnlyScope = await MainActor.run {
            server.sessionRuntimeStore.scope(ofSessionID: sessionID)
        }
        #expect(currentOnlyScope == Optional(Set<UUID>()))

        let extraWorkspaceID = UUID()
        let setResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "scope-set",
                command: "session.scope.set",
                callerSessionID: sessionID,
                payload: [
                    "sessionID": .string(sessionID),
                    "workspaceIDs": .array([.string(extraWorkspaceID.uuidString)]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(setResponse.ok)
        #expect(setResponse.result?.bool("isScoped") == true)
        #expect(setResponse.result?.stringArray("workspaceIDs") == [extraWorkspaceID.uuidString])
        let storedScope = await MainActor.run {
            server.sessionRuntimeStore.scope(ofSessionID: sessionID)
        }
        #expect(storedScope == Optional(Set([extraWorkspaceID])))

        let clearResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "scope-clear",
                command: "session.scope.clear",
                callerSessionID: sessionID,
                payload: [
                    "sessionID": .string(sessionID),
                ]
            ),
            socketPath: socketPath
        )

        #expect(clearResponse.ok)
        #expect(clearResponse.result?.bool("isScoped") == false)
        let clearedScope = await MainActor.run {
            server.sessionRuntimeStore.scope(ofSessionID: sessionID)
        }
        #expect(clearedScope == nil)
    }

    @Test
    func sessionStatusCanResolveActiveSessionWithoutPanelID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-status-only"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("editing 3 files"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.status")
    }

    @Test
    func aDirectSessionsWaitingRequestComesFromItsProcessAndNotFromTheHook() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-direct"
        func send(_ kind: SessionStatusKind, _ summary: String) throws -> AutomationResponseEnvelope {
            try sendEvent(
                AutomationEventEnvelope(
                    eventType: "session.status",
                    sessionID: sessionID,
                    requestID: UUID().uuidString,
                    payload: ["kind": .string(kind.rawValue), "summary": .string(summary)]
                ),
                socketPath: socketPath
            )
        }
        @MainActor func statusKind() -> SessionStatusKind? {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind
        }
        let started = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: ["agent": .string(AgentKind.claude.rawValue)]
            ),
            socketPath: socketPath
        )
        #expect(started.ok)
        await MainActor.run { server.sessionRuntimeStore.markDirectSession(sessionID: sessionID) }
        let working = try send(.working, "Working")
        #expect(working.ok)

        // The hook of Claude Code reports each request, and never its
        // answer. Its report is taken as received and changes nothing.
        let fromHook = try send(.needsApproval, "Needs approval")
        #expect(fromHook.ok)
        let afterHook = await statusKind()
        #expect(afterHook == .working)

        // The process reports the request, and its answer.
        await MainActor.run {
            server.sessionRuntimeStore.noteDirectSessionWaitingRequest(
                sessionID: sessionID,
                waiting: SessionRuntimeStore.directSessionWaitingStatus(permissionSummary: nil, agentName: "Claude Code"),
                at: Date()
            )
        }
        let whileWaiting = await statusKind()
        #expect(whileWaiting == .needsApproval)
        await MainActor.run {
            server.sessionRuntimeStore.noteDirectSessionWaitingRequest(sessionID: sessionID, waiting: nil, at: Date())
        }
        let afterAnswer = await statusKind()
        #expect(afterAnswer == .working)

        // A turn that ended keeps its status when its request is withdrawn.
        // That status is ready, or idle when the user already looks at the
        // panel.
        let ready = try send(.ready, "Ready")
        #expect(ready.ok)
        let atTurnEnd = await statusKind()
        #expect(atTurnEnd == .ready || atTurnEnd == .idle)
        await MainActor.run {
            server.sessionRuntimeStore.noteDirectSessionWaitingRequest(sessionID: sessionID, waiting: nil, at: Date())
        }
        let afterTurn = await statusKind()
        #expect(afterTurn == atTurnEnd)
    }

    /// Codex's notify command and its rollout file report a turn's end
    /// some time after the turn. For a direct session that report could
    /// land in the turn that follows, so the session's process is the one
    /// source of its status.
    @Test
    func aCodexDirectSessionTakesItsTurnsFromItsProcessOnly() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)
        let sessionID = "sess-codex-direct"
        let started = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: ["agent": .string(AgentKind.codex.rawValue)]
            ),
            socketPath: socketPath
        )
        #expect(started.ok)
        @MainActor func status() -> SessionStatus? {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.status
        }
        let completion = CodexNotifyCompletion(
            notificationType: "agent-turn-complete",
            threadID: "thread-1",
            turnID: "turn-1",
            lastInputMessageFingerprint: nil,
            inputMessageCount: 1,
            detail: "from notify"
        )

        await MainActor.run {
            server.sessionRuntimeStore.markDirectSession(sessionID: sessionID)
            server.sessionRuntimeStore.noteDirectSessionTurnStarted(sessionID: sessionID, at: Date())
        }
        let working = await status()
        #expect(working?.kind == .working)
        #expect(working?.detail == "Working inside Codex")

        // The late reports of the turn before this one change nothing.
        let fromOthers = await MainActor.run {
            let notified = server.sessionRuntimeStore.handleCodexNotifyCompletion(
                sessionID: sessionID, completion: completion, at: Date()
            )
            let fromRollout = server.sessionRuntimeStore.handleCodexRolloutTurnCompletion(
                sessionID: sessionID, turnID: "turn-1", latestRolloutTurnID: "turn-1", completedAt: Date(),
                detail: "from the rollout", turnError: nil, at: Date()
            )
            return [notified, fromRollout]
        }
        #expect(fromOthers == [false, false])
        let stillWorking = await status()
        #expect(stillWorking?.kind == .working)

        await MainActor.run {
            server.sessionRuntimeStore.noteDirectSessionTurnEnded(
                sessionID: sessionID, failed: false, detail: "done", at: Date()
            )
        }
        // Ready, or idle when the user already looks at the panel.
        let ended = await status()
        #expect(ended?.kind == .ready || ended?.kind == .idle)

        await MainActor.run {
            server.sessionRuntimeStore.noteDirectSessionTurnStarted(sessionID: sessionID, at: Date())
            server.sessionRuntimeStore.noteDirectSessionTurnEnded(
                sessionID: sessionID, failed: true, detail: "You've hit your usage limit.", at: Date()
            )
        }
        let failed = await status()
        #expect(failed?.kind == .error)
        #expect(failed?.detail == "You've hit your usage limit.")
    }

    @Test
    func sessionStatusCanResolveActiveSessionForBackgroundTabPanel() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let initialContext = try await MainActor.run {
            let selection = try #require(server.store.state.selectedWorkspaceSelection())
            return (
                workspaceID: selection.workspaceID,
                originalTabID: try #require(selection.workspace.resolvedSelectedTabID),
                panelID: try #require(selection.workspace.focusedPanelID)
            )
        }

        let sessionID = "sess-background-tab"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: initialContext.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        _ = try await MainActor.run {
            #expect(server.store.send(.createWorkspaceTab(workspaceID: initialContext.workspaceID, seed: nil)))
            let workspace = try #require(server.store.state.workspacesByID[initialContext.workspaceID])
            let backgroundTabID = try #require(workspace.resolvedSelectedTabID)
            #expect(backgroundTabID != initialContext.originalTabID)
            return backgroundTabID
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("editing in background tab"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let activeSession = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)
        }
        #expect(activeSession?.status?.kind == .working)
    }

    @Test
    func sessionStatusRejectsMismatchedPanelIDForActiveSession() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-mismatch"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                panelID: UUID().uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("editing 3 files"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok == false)
        #expect(response.error?.code == "INVALID_PAYLOAD")
        #expect(response.error?.message == "panelID does not match active session")
    }

    @Test
    func sessionUpdateFilesCanResolveActiveSessionWithoutPanelID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-files-only"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.update_files",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "files": .array([.string("/tmp/a.swift")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.update_files")
        #expect(response.result?.int("queuedFiles") == 1)
    }

    @Test
    func sessionStopCanResolveActiveSessionWithoutPanelID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-stop-only"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.stop",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [:]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.stop")
    }

}
