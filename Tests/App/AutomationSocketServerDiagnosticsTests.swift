import RemoteProtocol
import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerDiagnosticsTests: AutomationSocketServerTestSupport {
    @Test
    func automationDiagnosticsRecentRequestsCapturesSanitizedAppControlAction() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-audit-caller"
        let (windowID, targetWorkspaceID) = try await MainActor.run {
            let windowID = try #require(server.store.state.windows.first?.id)
            server.sessionRuntimeStore.startSession(
                sessionID: sessionID,
                agent: .codex,
                panelID: server.panelID,
                windowID: windowID,
                workspaceID: server.workspaceID,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let existingWorkspaceIDs = Set(server.store.state.window(id: windowID)?.workspaceIDs ?? [])
            #expect(
                server.store.send(
                    .createWorkspace(
                        windowID: windowID,
                        title: "Audit Target",
                        activate: false
                    )
                )
            )
            let targetWorkspaceID = try #require(
                server.store.state.window(id: windowID)?.workspaceIDs.first {
                    existingWorkspaceIDs.contains($0) == false
                }
            )
            return (windowID, targetWorkspaceID)
        }

        let pingResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-ping",
                command: "automation.ping"
            ),
            socketPath: socketPath
        )
        #expect(pingResponse.ok)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-workspace-select",
                command: "app_control.run_action",
                callerSessionID: sessionID,
                payload: [
                    "id": .string("workspace.select"),
                    "args": .object([
                        "workspaceID": .string(targetWorkspaceID.uuidString),
                        "windowID": .string(windowID.uuidString),
                        "focusUnreadSessionPanel": .bool(false),
                        "title": .string("do not store this value"),
                    ]),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok)

        let diagnosticsResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-query",
                command: AutomationSocketProtocol.diagnosticsRecentRequestsCommand
            ),
            socketPath: socketPath
        )

        #expect(diagnosticsResponse.ok)
        let automation = try automationSection(from: diagnosticsResponse)
        #expect(automation.status == .available)
        #expect(automation.recentRequests.count == 1)
        let entry = try #require(automation.recentRequests.first)
        #expect(entry.kind == "request")
        #expect(entry.requestID == "audit-workspace-select")
        #expect(entry.command == "app_control.run_action")
        #expect(entry.callerSessionID == sessionID)
        #expect(entry.callerAgent == AgentKind.codex.rawValue)
        #expect(entry.actionID == "workspace.select")
        #expect(entry.queryID == nil)
        #expect(entry.argumentKeys == ["focusUnreadSessionPanel", "title", "windowID", "workspaceID"])
        #expect(entry.selectors["workspaceID"] == .string(targetWorkspaceID.uuidString))
        #expect(entry.selectors["windowID"] == .string(windowID.uuidString))
        #expect(entry.selectors["title"] == nil)
        #expect(entry.flags["focusUnreadSessionPanel"] == .bool(false))
        #expect(entry.ok)
        #expect(entry.errorCode == nil)
        #expect(entry.durationMs >= 0)
    }

    @Test
    func automationDiagnosticsRecentRequestsPreservesNumericSelectors() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-numeric-selector",
                command: "app_control.run_action",
                payload: [
                    "id": .string("unsupported.action"),
                    "args": .object([
                        "index": .double(2.0),
                        "toIndex": .int(3),
                        "secret-key-value": .string("do not retain this key name"),
                    ]),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok == false)

        let diagnosticsResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-query",
                command: AutomationSocketProtocol.diagnosticsRecentRequestsCommand
            ),
            socketPath: socketPath
        )

        #expect(diagnosticsResponse.ok)
        let automation = try automationSection(from: diagnosticsResponse)
        let entry = try #require(automation.recentRequests.first)
        #expect(entry.requestID == "audit-numeric-selector")
        #expect(entry.selectors["index"] == .int(2))
        #expect(entry.selectors["toIndex"] == .int(3))
        #expect(entry.argumentKeys == ["index", "other", "toIndex"])
        #expect(entry.errorCode == "INVALID_PAYLOAD")
    }

    @Test
    func automationDiagnosticsRecentRequestsCapturesSessionEvents() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-audit-event"
        try await MainActor.run {
            let windowID = try #require(server.store.state.windows.first?.id)
            server.sessionRuntimeStore.startSession(
                sessionID: sessionID,
                agent: .claude,
                panelID: server.panelID,
                windowID: windowID,
                workspaceID: server.workspaceID,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: "audit-session-event",
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("do not retain this summary"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok)

        let diagnosticsResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-query",
                command: AutomationSocketProtocol.diagnosticsRecentRequestsCommand
            ),
            socketPath: socketPath
        )

        #expect(diagnosticsResponse.ok)
        let automation = try automationSection(from: diagnosticsResponse)
        let entry = try #require(automation.recentRequests.first)
        #expect(entry.kind == "event")
        #expect(entry.requestID == "audit-session-event")
        #expect(entry.eventType == "session.status")
        #expect(entry.callerAgent == AgentKind.claude.rawValue)
        #expect(entry.sessionID == sessionID)
        #expect(entry.panelID == server.panelID.uuidString)
        #expect(entry.argumentKeys == ["kind", "summary"])
        #expect(entry.ok)
    }

    @Test
    func automationDiagnosticsRecentRequestsRetainsLast250Calls() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        for index in 0..<252 {
            let response = try sendRequest(
                AutomationRequestEnvelope(
                    requestID: "unknown-\(index)",
                    command: "unknown.command.\(index)"
                ),
                socketPath: socketPath
            )
            #expect(response.ok == false)
        }

        let diagnosticsResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-query",
                command: AutomationSocketProtocol.diagnosticsRecentRequestsCommand
            ),
            socketPath: socketPath
        )

        #expect(diagnosticsResponse.ok)
        let automation = try automationSection(from: diagnosticsResponse)
        #expect(automation.recentRequests.count == 250)
        #expect(automation.recentRequests.first?.requestID == "unknown-2")
        #expect(automation.recentRequests.last?.requestID == "unknown-251")
        #expect(automation.recentRequests.last?.errorCode == "UNKNOWN_COMMAND")
    }

}
