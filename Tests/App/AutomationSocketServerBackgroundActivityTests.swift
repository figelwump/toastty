import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerBackgroundActivityTests: AutomationSocketServerTestSupport {
    @Test
    func sessionBackgroundActivityProjectsWorkingAndFinishesIdempotently() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-background-activity"
        let startSessionResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startSessionResponse.ok)

        let readyResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.ready.rawValue),
                    "summary": .string("Ready"),
                    "detail": .string("Root turn completed"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(readyResponse.ok)

        let activityPayload: [String: AutomationJSONValue] = [
            "phase": .string(SessionBackgroundActivityPhase.start.rawValue),
            "activityID": .string("child-activity"),
            "kind": .string(SessionBackgroundActivityKind.childAgent.rawValue),
            "displayName": .string("Codex"),
            "command": .string("codex review"),
        ]
        let activityResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                timestamp: "2026-01-01T00:00:00Z",
                requestID: UUID().uuidString,
                payload: activityPayload
            ),
            socketPath: socketPath
        )
        #expect(activityResponse.ok)
        #expect(activityResponse.result?.string("status") == "accepted")

        let projectedStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first
        }
        #expect(projectedStatus?.status.kind == .working)
        #expect(projectedStatus?.status.detail == "Root turn completed")
        #expect(projectedStatus?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))

        let duplicateStartResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: activityPayload
            ),
            socketPath: socketPath
        )
        #expect(duplicateStartResponse.ok)
        #expect(duplicateStartResponse.result?.string("status") == "noop")
        #expect(duplicateStartResponse.result?.int("stateVersion") == activityResponse.result?.int("stateVersion"))

        let unknownFinishResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.finish.rawValue),
                    "activityID": .string("missing-child"),
                    "kind": .string(SessionBackgroundActivityKind.childAgent.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(unknownFinishResponse.ok)
        #expect(unknownFinishResponse.result?.string("status") == "noop")
        #expect(unknownFinishResponse.result?.int("stateVersion") == activityResponse.result?.int("stateVersion"))

        let finishResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.finish.rawValue),
                    "activityID": .string("child-activity"),
                    "kind": .string(SessionBackgroundActivityKind.childAgent.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(finishResponse.ok)
        #expect(finishResponse.result?.string("status") == "accepted")

        let finalStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.status
        }
        #expect(finalStatus?.kind == .working)
        #expect(finalStatus?.detail == "Resuming…")
        let finalProjection = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.projection
        }
        #expect(finalProjection == .resuming)
    }

    @Test
    func sessionBackgroundActivitySyncAcceptedPreservesAndClearsSubagents() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-background-sync"
        let startSessionResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startSessionResponse.ok)

        let readyResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.ready.rawValue),
                    "summary": .string("Ready"),
                    "detail": .string("Root turn completed"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(readyResponse.ok)

        let syncResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                timestamp: "2026-01-01T00:00:00Z",
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "entries": .array([
                        .object([
                            "id": .string("agent-1"),
                            "displayName": .string("general-purpose"),
                            "command": .string("Review the diff"),
                        ]),
                    ]),
                    "pendingCount": .int(1),
                ]
            ),
            socketPath: socketPath
        )
        #expect(syncResponse.ok)
        #expect(syncResponse.result?.string("status") == "accepted")

        let syncedRecord = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]
        }
        #expect(syncedRecord?.backgroundActivitiesByID["agent-1"]?.kind == .subagent)
        #expect(syncedRecord?.backgroundActivitiesByID["agent-1"]?.displayName == "general-purpose")
        #expect(syncedRecord?.pendingBackgroundTaskCount == 1)
        let waitingStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.status
        }
        #expect(waitingStatus?.kind == .working)

        let workflowStartResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.start.rawValue),
                    "activityID": .string("workflow-subagent-1"),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "preserveWhenUnlisted": .bool(true),
                ]
            ),
            socketPath: socketPath
        )
        #expect(workflowStartResponse.ok)

        let preserveResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "entries": .array([]),
                    "pendingCount": .int(2),
                    "preserveUnlistedActivities": .bool(true),
                ]
            ),
            socketPath: socketPath
        )
        #expect(preserveResponse.ok)
        #expect(preserveResponse.result?.string("status") == "accepted")

        let preservedRecord = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]
        }
        #expect(preservedRecord?.backgroundActivitiesByID["agent-1"] == nil)
        #expect(preservedRecord?.backgroundActivitiesByID["workflow-subagent-1"]?.preserveWhenUnlisted == true)
        #expect(preservedRecord?.pendingBackgroundTaskCount == 2)

        let clearResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "entries": .array([]),
                    "pendingCount": .int(0),
                ]
            ),
            socketPath: socketPath
        )
        #expect(clearResponse.ok)
        #expect(clearResponse.result?.string("status") == "accepted")

        let clearedRecord = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]
        }
        #expect(clearedRecord?.backgroundActivitiesByID.isEmpty == true)
        #expect(clearedRecord?.pendingBackgroundTaskCount == 0)
        let finalStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.status
        }
        #expect(finalStatus?.kind == .working)
        #expect(finalStatus?.detail == "Resuming…")
        let finalProjection = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.projection
        }
        #expect(finalProjection == .resuming)
    }

    @Test
    func sessionBackgroundActivitySyncValidatesPayload() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-background-sync-invalid"
        let startSessionResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startSessionResponse.ok)

        let missingEntriesResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "pendingCount": .int(0),
                ]
            ),
            socketPath: socketPath
        )
        #expect(missingEntriesResponse.ok == false)
        #expect(missingEntriesResponse.error?.code == "INVALID_PAYLOAD")
        #expect(missingEntriesResponse.error?.message == "entries must be an array")

        let negativePendingResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "entries": .array([]),
                    "pendingCount": .int(-1),
                ]
            ),
            socketPath: socketPath
        )
        #expect(negativePendingResponse.ok == false)
        #expect(negativePendingResponse.error?.code == "INVALID_PAYLOAD")
        #expect(negativePendingResponse.error?.message == "pendingCount must be a non-negative integer")

        let invalidPreserveResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "entries": .array([]),
                    "pendingCount": .int(0),
                    "preserveUnlistedActivities": .string("true"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(invalidPreserveResponse.ok == false)
        #expect(invalidPreserveResponse.error?.code == "INVALID_PAYLOAD")
        #expect(invalidPreserveResponse.error?.message == "preserveUnlistedActivities must be a boolean")

        let invalidActivityRetentionResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.start.rawValue),
                    "activityID": .string("workflow-subagent-1"),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "preserveWhenUnlisted": .string("true"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(invalidActivityRetentionResponse.ok == false)
        #expect(invalidActivityRetentionResponse.error?.code == "INVALID_PAYLOAD")
        #expect(invalidActivityRetentionResponse.error?.message == "preserveWhenUnlisted must be a boolean")

        let invalidEntryResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "entries": .array([.object(["id": .string("   "), "displayName": .int(1)])]),
                    "pendingCount": .int(0),
                ]
            ),
            socketPath: socketPath
        )
        #expect(invalidEntryResponse.ok == false)
        #expect(invalidEntryResponse.error?.code == "INVALID_PAYLOAD")
        #expect(invalidEntryResponse.error?.message == "entry id is required")
    }

}
