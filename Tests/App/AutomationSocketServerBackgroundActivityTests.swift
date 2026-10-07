import RemoteProtocol
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
            "modelIdentifier": .string("anthropic/\u{0007}claude\nsonnet-4"),
            "reasoningEffort": .string("  high\t"),
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

        let storedProfile = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]?
                .backgroundActivitiesByID["child-activity"]?.executionProfile
        }
        #expect(storedProfile == SessionAgentExecutionProfile(
            modelIdentifier: "anthropic/claude sonnet-4",
            reasoningEffort: "high"
        ))

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
    func sessionTeammateLifecyclePreservesActiveAgentsAndReopensFinishedAgent() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            // Keep Ready visible regardless of the test host's focus state.
            try makeServer(
                socketPath: socketPath,
                sessionRuntimeStore: SessionRuntimeStore(
                    sendSessionStatusNotification: { _, _, _, _, _ in },
                    isApplicationActive: { false }
                )
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }
        try waitForSocket(at: socketPath)

        let sessionID = "sess-teammate-lifecycle"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: ["agent": .string(AgentKind.claude.rawValue)]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        func sendActivity(phase: String, activityID: String) throws -> AutomationResponseEnvelope {
            try sendEvent(
                AutomationEventEnvelope(
                    eventType: "session.claude_subagent_event",
                    sessionID: sessionID,
                    panelID: server.panelID.uuidString,
                    requestID: UUID().uuidString,
                    payload: [
                        "phase": .string(phase),
                        "agentID": .string(activityID),
                        "displayName": .string("Reviewer"),
                        "command": .string("Review the diff"),
                    ]
                ),
                socketPath: socketPath
            )
        }

        func syncLifetimeTasks(pendingCount: Int) throws -> AutomationResponseEnvelope {
            try sendEvent(
                AutomationEventEnvelope(
                    eventType: "session.background_activity",
                    sessionID: sessionID,
                    panelID: server.panelID.uuidString,
                    requestID: UUID().uuidString,
                    payload: [
                        "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                        "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                        "entries": .array([]),
                        "pendingCount": .int(pendingCount),
                        "preserveUnlistedActivities": .bool(true),
                    ]
                ),
                socketPath: socketPath
            )
        }

        let foregroundStartResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.start.rawValue),
                    "activityID": .string("foreground-subagent"),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(foregroundStartResponse.ok)
        let unregisteredStartResponse = try sendActivity(phase: "started", activityID: "foreground-subagent")
        #expect(unregisteredStartResponse.ok)
        let foregroundActivity = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]?
                .backgroundActivitiesByID["foreground-subagent"]
        }
        #expect(foregroundActivity?.preserveWhenUnlisted == false)

        for activityID in ["teammate-1", "teammate-2"] {
            for phase in ["spawned", "started"] {
                let response = try sendActivity(phase: phase, activityID: activityID)
                #expect(response.ok)
                #expect(response.result?.string("status") == "accepted")
            }
        }
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

        // Lifetime task snapshots omit teammate rows. Lifecycle hooks retain
        // only the teammates that are still doing work.
        let preserveResponse = try syncLifetimeTasks(pendingCount: 0)
        #expect(preserveResponse.ok)
        let waitingForBoth = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first
        }
        #expect(waitingForBoth?.status.kind == .working)
        #expect(waitingForBoth?.projection == .waitingOnChildren(
            childCount: 2,
            pendingBackgroundTaskCount: 0
        ))
        #expect(Set(waitingForBoth?.children.map(\.id) ?? []) == ["teammate-1", "teammate-2"])

        let firstFinishResponse = try sendActivity(
            phase: "finished",
            activityID: "teammate-1"
        )
        #expect(firstFinishResponse.ok)
        let waitingForSecond = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first
        }
        #expect(waitingForSecond?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))
        let remainingActivities = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]?.backgroundActivitiesByID
        }
        #expect(remainingActivities?["teammate-1"] == nil)
        #expect(remainingActivities?["teammate-2"]?.preserveWhenUnlisted == true)

        let secondFinishResponse = try sendActivity(
            phase: "finished",
            activityID: "teammate-2"
        )
        #expect(secondFinishResponse.ok)
        let afterGrace = Date().addingTimeInterval(SessionRegistry.resumeProjectionGraceInterval + 1)
        let finishedStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID, at: afterGrace).first
        }
        #expect(finishedStatus?.status.kind == .ready)
        #expect(finishedStatus?.projection == SessionStatusProjection.none)
        #expect(finishedStatus?.children.isEmpty == true)

        for _ in 0..<2 {
            let response = try syncLifetimeTasks(pendingCount: 0)
            #expect(response.ok)
            #expect(response.result?.string("status") == "noop")
            #expect(response.result?.int("stateVersion") == secondFinishResponse.result?.int("stateVersion"))
        }
        let delayedStartResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.start.rawValue),
                    "activityID": .string("teammate-1"),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "modelIdentifier": .string("claude-sonnet-4"),
                    "reasoningEffort": .string("high"),
                    "preserveWhenUnlisted": .bool(true),
                ]
            ),
            socketPath: socketPath
        )
        #expect(delayedStartResponse.ok)
        #expect(delayedStartResponse.result?.string("status") == "noop")
        #expect(delayedStartResponse.result?.int("stateVersion") == secondFinishResponse.result?.int("stateVersion"))
        let delayedSpawnResponse = try sendActivity(phase: "spawned", activityID: "teammate-1")
        // Registration can refresh retained metadata, but must not reopen the row.
        #expect(delayedSpawnResponse.ok)
        let finishedRecord = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]
        }
        #expect(finishedRecord?.backgroundActivitiesByID.isEmpty == true)
        #expect(finishedRecord?.pendingBackgroundTaskCount == 0)
        #expect(finishedRecord?.status?.kind == .ready)

        let reopenResponse = try sendActivity(phase: "started", activityID: "teammate-1")
        #expect(reopenResponse.ok)
        #expect(reopenResponse.result?.string("status") == "accepted")
        let reopenedActivity = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]?
                .backgroundActivitiesByID["teammate-1"]
        }
        #expect(reopenedActivity?.kind == .subagent)
        #expect(reopenedActivity?.displayName == "Reviewer")
        #expect(reopenedActivity?.command == "Review the diff")
        #expect(reopenedActivity?.preserveWhenUnlisted == true)

        // A separate shell task still keeps the root waiting after a teammate
        // becomes idle. Its pending count comes from the snapshot.
        let shellPendingResponse = try syncLifetimeTasks(pendingCount: 1)
        #expect(shellPendingResponse.ok)
        let waitingForTeammateAndShell = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first
        }
        #expect(waitingForTeammateAndShell?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 1
        ))
        let idleResponse = try sendActivity(
            phase: "finished",
            activityID: "teammate-1"
        )
        #expect(idleResponse.ok)
        let waitingForShell = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(
                for: server.workspaceID,
                at: Date().addingTimeInterval(SessionRegistry.resumeProjectionGraceInterval + 1)
            ).first
        }
        #expect(waitingForShell?.status.kind == .working)
        #expect(waitingForShell?.projection == .waitingOnChildren(
            childCount: 0,
            pendingBackgroundTaskCount: 1
        ))

        let shellFinishedResponse = try syncLifetimeTasks(pendingCount: 0)
        #expect(shellFinishedResponse.ok)
        let allFinished = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(
                for: server.workspaceID,
                at: Date().addingTimeInterval(SessionRegistry.resumeProjectionGraceInterval + 1)
            ).first
        }
        #expect(allFinished?.status.kind == .ready)
        #expect(allFinished?.projection == SessionStatusProjection.none)
        #expect(allFinished?.children.isEmpty == true)
    }

    @Test
    func sessionTeammateLifecycleDoesNotReplaceRootWorkingOrApprovalStatus() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }
        try waitForSocket(at: socketPath)

        let sessionID = "sess-teammate-root-status"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: ["agent": .string(AgentKind.claude.rawValue)]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        for kind in [SessionStatusKind.working, .needsApproval] {
            let rootStatus = SessionStatus(kind: kind, summary: "Root status", detail: "Root owns this status")
            let statusResponse = try sendEvent(
                AutomationEventEnvelope(
                    eventType: "session.status",
                    sessionID: sessionID,
                    requestID: UUID().uuidString,
                    payload: [
                        "kind": .string(kind.rawValue),
                        "summary": .string(rootStatus.summary),
                        "detail": .string("Root owns this status"),
                    ]
                ),
                socketPath: socketPath
            )
            #expect(statusResponse.ok)

            for phase in [
                "spawned",
                "started",
                "tool_use",
                "finished",
                "started",
                "finished",
            ] {
                let activityResponse = try sendEvent(
                    AutomationEventEnvelope(
                        eventType: "session.claude_subagent_event",
                        sessionID: sessionID,
                        panelID: server.panelID.uuidString,
                        requestID: UUID().uuidString,
                        payload: [
                            "phase": .string(phase),
                            "agentID": .string("teammate-\(kind.rawValue)"),
                            "displayName": .string("Reviewer"),
                        ]
                    ),
                    socketPath: socketPath
                )
                #expect(activityResponse.ok)
                let record = await MainActor.run {
                    server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]
                }
                let projectedStatus = await MainActor.run {
                    server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first
                }
                #expect(record?.status == rootStatus)
                #expect(projectedStatus?.status == rootStatus)
                #expect(projectedStatus?.projection == SessionStatusProjection.none)
            }
        }
    }

    @Test
    func sessionTeammateApprovalRestoresRootStatusAndPreservesSiblingApprovals() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            // Keep Ready visible regardless of the test host's focus state.
            try makeServer(
                socketPath: socketPath,
                sessionRuntimeStore: SessionRuntimeStore(
                    sendSessionStatusNotification: { _, _, _, _, _ in },
                    isApplicationActive: { false }
                )
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }
        try waitForSocket(at: socketPath)

        let sessionID = "sess-teammate-approval"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: ["agent": .string(AgentKind.claude.rawValue)]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        func sendRootStatus(_ status: SessionStatus) throws -> AutomationResponseEnvelope {
            try sendEvent(
                AutomationEventEnvelope(
                    eventType: "session.status",
                    sessionID: sessionID,
                    requestID: UUID().uuidString,
                    payload: [
                        "kind": .string(status.kind.rawValue),
                        "summary": .string(status.summary),
                        "detail": .string(status.detail ?? ""),
                    ]
                ),
                socketPath: socketPath
            )
        }

        func sendChildEvent(phase: String, agentID: String) throws -> AutomationResponseEnvelope {
            try sendEvent(
                AutomationEventEnvelope(
                    eventType: "session.claude_subagent_event",
                    sessionID: sessionID,
                    panelID: server.panelID.uuidString,
                    requestID: UUID().uuidString,
                    payload: [
                        "phase": .string(phase),
                        "agentID": .string(agentID),
                        "displayName": .string("Reviewer"),
                        "detail": .string("\(agentID) requested approval"),
                    ]
                ),
                socketPath: socketPath
            )
        }

        let originalRootStatus = SessionStatus(
            kind: .ready,
            summary: "Ready",
            detail: "Root turn completed"
        )
        #expect(try sendRootStatus(originalRootStatus).ok)

        // An ordinary child still signals root work through its tool hook.
        #expect(try sendChildEvent(phase: "tool_use", agentID: "ordinary-child").ok)
        let ordinaryChildRootStatus = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]?.status
        }
        #expect(ordinaryChildRootStatus?.kind == .working)
        #expect(try sendRootStatus(originalRootStatus).ok)

        for agentID in ["teammate-1", "teammate-2"] {
            #expect(try sendChildEvent(phase: "spawned", agentID: agentID).ok)
            #expect(try sendChildEvent(phase: "permission", agentID: agentID).ok)
            let approvalStatus = await MainActor.run {
                server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]?.status
            }
            #expect(approvalStatus?.kind == .needsApproval)
        }

        #expect(try sendChildEvent(phase: "tool_use", agentID: "teammate-1").ok)
        let siblingApprovalStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.status
        }
        #expect(siblingApprovalStatus?.kind == .needsApproval)
        #expect(siblingApprovalStatus?.detail == "teammate-2 requested approval")

        #expect(try sendChildEvent(phase: "finished", agentID: "teammate-2").ok)
        let restoredRootStatus = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]?.status
        }
        #expect(restoredRootStatus == originalRootStatus)
        let waitingForRemainingTeammate = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first
        }
        #expect(waitingForRemainingTeammate?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))

        #expect(try sendChildEvent(phase: "permission", agentID: "teammate-1").ok)
        let supersedingRootStatus = SessionStatus(
            kind: .working,
            summary: "Working",
            detail: "Root began the next turn"
        )
        #expect(try sendRootStatus(supersedingRootStatus).ok)
        #expect(try sendChildEvent(phase: "finished", agentID: "teammate-1").ok)
        let finalRecord = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]
        }
        let finalStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first
        }
        #expect(finalRecord?.status == supersedingRootStatus)
        #expect(finalRecord?.backgroundActivitiesByID.isEmpty == true)
        #expect(finalStatus?.status == supersedingRootStatus)
        #expect(finalStatus?.projection == SessionStatusProjection.none)
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
