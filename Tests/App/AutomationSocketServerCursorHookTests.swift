import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerCursorHookTests: AutomationSocketServerTestSupport {
    @Test
    func cursorHookPayloadDecoderPreservesCorrelationAndStatus() throws {
        let event = try CursorHookEventPayloadDecoder.decode([
            "hookEventName": .string(" beforeSubmitPrompt "),
            "conversationID": .string(" conversation-root "),
            "generationID": .string(" generation-1 "),
            "cloudHandoff": .bool(true),
            "kind": .string(SessionStatusKind.working.rawValue),
            "summary": .string("Working"),
            "detail": .string("Handing off to Cursor Cloud"),
        ])

        #expect(event == CursorHookEvent(
            hookEventName: "beforeSubmitPrompt",
            conversationID: "conversation-root",
            generationID: "generation-1",
            cloudHandoff: true,
            status: SessionStatus(
                kind: .working,
                summary: "Working",
                detail: "Handing off to Cursor Cloud"
            )
        ))
    }

    @Test
    func cursorHookPayloadDecoderRejectsPartialStatus() {
        #expect(throws: (any Error).self) {
            try CursorHookEventPayloadDecoder.decode([
                "hookEventName": .string("stop"),
                "kind": .string(SessionStatusKind.ready.rawValue),
            ])
        }
    }

    @Test
    func cursorHookPayloadDecoderBoundsAndNormalizesStatusText() throws {
        let event = try CursorHookEventPayloadDecoder.decode([
            "hookEventName": .string("preToolUse"),
            "kind": .string(SessionStatusKind.working.rawValue),
            "summary": .string("  Working\n\u{0}  " + String(repeating: "s", count: 100)),
            "detail": .string("  Reading\n\u{7}  " + String(repeating: "d", count: 300)),
        ])

        #expect(event.status?.summary.count == 80)
        #expect(event.status?.summary.hasSuffix("...") == true)
        #expect(event.status?.summary.contains("\n") == false)
        #expect(event.status?.summary.contains("\u{0}") == false)
        #expect(event.status?.detail?.count == 240)
        #expect(event.status?.detail?.hasSuffix("...") == true)
        #expect(event.status?.detail?.contains("\n") == false)
        #expect(event.status?.detail?.contains("\u{7}") == false)
    }

    @Test
    func cursorHookPayloadDecoderRejectsOversizedIdentifiers() {
        #expect(throws: (any Error).self) {
            try CursorHookEventPayloadDecoder.decode([
                "hookEventName": .string("sessionStart"),
                "conversationID": .string(String(repeating: "x", count: 513)),
            ])
        }
    }

    @Test
    func cursorHookSocketPathGatesCompletionToRootConversationAndCurrentGeneration() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }
        try waitForSocket(at: socketPath)

        let sessionID = "sess-cursor-hook"
        try await MainActor.run {
            server.sessionRuntimeStore.startSession(
                sessionID: sessionID,
                agent: .cursor,
                panelID: server.panelID,
                windowID: try #require(server.store.state.windows.first?.id),
                workspaceID: server.workspaceID,
                usesSessionStatusNotifications: true,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        let sessionStart = try sendCursorEvent(
            socketPath: socketPath,
            sessionID: sessionID,
            panelID: server.panelID,
            eventName: "sessionStart",
            conversationID: "conversation-root",
            status: SessionStatus(
                kind: .idle,
                summary: "Waiting",
                detail: "Cursor is ready"
            )
        )
        #expect(sessionStart.ok)
        #expect(sessionStart.result?.string("status") == "accepted")
        var status = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.status
        }
        #expect(status?.kind == .idle)
        #expect(status?.detail == "Cursor is ready")

        let prompt = try sendCursorEvent(
            socketPath: socketPath,
            sessionID: sessionID,
            panelID: server.panelID,
            eventName: "beforeSubmitPrompt",
            conversationID: "conversation-root",
            generationID: "generation-1",
            status: SessionStatus(kind: .working, summary: "Working")
        )
        #expect(prompt.result?.string("status") == "accepted")

        let nestedStop = try sendCursorEvent(
            socketPath: socketPath,
            sessionID: sessionID,
            panelID: server.panelID,
            eventName: "stop",
            conversationID: "conversation-child",
            generationID: "generation-child",
            status: SessionStatus(kind: .ready, summary: "Ready")
        )
        #expect(nestedStop.result?.string("status") == "ignored")
        status = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.status
        }
        #expect(status?.kind == .working)

        let rootStop = try sendCursorEvent(
            socketPath: socketPath,
            sessionID: sessionID,
            panelID: server.panelID,
            eventName: "stop",
            conversationID: "conversation-root",
            generationID: "generation-1",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Turn complete")
        )
        #expect(rootStop.result?.string("status") == "accepted")
        status = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.status
        }
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Turn complete")

        let duplicateStop = try sendCursorEvent(
            socketPath: socketPath,
            sessionID: sessionID,
            panelID: server.panelID,
            eventName: "stop",
            conversationID: "conversation-root",
            generationID: "generation-1",
            status: SessionStatus(kind: .ready, summary: "Ready")
        )
        #expect(duplicateStop.result?.string("status") == "ignored")
    }

    @MainActor
    @Test func cursorStopCannotEstablishRootIdentity() {
        let store = makeCursorSessionStore(sessionID: "sess-no-root")

        #expect(store.handleCursorHookEvent(
            sessionID: "sess-no-root",
            event: CursorHookEvent(
                hookEventName: "stop",
                conversationID: "conversation-unclaimed",
                generationID: "generation-unclaimed",
                status: SessionStatus(kind: .ready, summary: "Ready")
            ),
            at: Date(timeIntervalSince1970: 1_700_000_001)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-no-root")?.status == nil)
    }

    @MainActor
    @Test func cursorPromptCannotEstablishRootIdentity() {
        let sessionID = "sess-no-root-prompt"
        let store = makeCursorSessionStore(sessionID: sessionID)

        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: promptEvent(generationID: "generation-unclaimed"),
            at: Date(timeIntervalSince1970: 1_700_000_001)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status == nil)
    }

    @MainActor
    @Test func cursorMalformedSessionStartCannotClaimRootIdentity() {
        let sessionID = "sess-malformed-start"
        let store = makeCursorSessionStore(sessionID: sessionID)

        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: CursorHookEvent(
                hookEventName: "sessionStart",
                conversationID: "conversation-malformed",
                generationID: nil,
                status: nil
            ),
            at: Date(timeIntervalSince1970: 1_700_000_001)
        ) == false)
        establishRoot(
            in: store,
            sessionID: sessionID,
            conversationID: "conversation-valid"
        )
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .idle)
    }

    @MainActor
    @Test func cursorStaleGenerationCannotCompleteNewerTurn() {
        let sessionID = "sess-stale-generation"
        let store = makeCursorSessionStore(sessionID: sessionID)
        establishRoot(in: store, sessionID: sessionID)

        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: promptEvent(generationID: "generation-1"),
            at: Date(timeIntervalSince1970: 1_700_000_001)
        ))
        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: promptEvent(generationID: "generation-2"),
            at: Date(timeIntervalSince1970: 1_700_000_002)
        ))
        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: stopEvent(generationID: "generation-1"),
            at: Date(timeIntervalSince1970: 1_700_000_003)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)
        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: stopEvent(generationID: "generation-2"),
            at: Date(timeIntervalSince1970: 1_700_000_004)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .ready)
    }

    @MainActor
    @Test func cursorCloudHandoffDoesNotReportRemoteCompletion() {
        let sessionID = "sess-cloud-handoff"
        let store = makeCursorSessionStore(sessionID: sessionID)
        establishRoot(in: store, sessionID: sessionID)

        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: CursorHookEvent(
                hookEventName: "beforeSubmitPrompt",
                conversationID: "conversation-root",
                generationID: "generation-cloud",
                cloudHandoff: true,
                status: SessionStatus(
                    kind: .working,
                    summary: "Working",
                    detail: "Handing off to Cursor Cloud"
                )
            ),
            at: Date(timeIntervalSince1970: 1_700_000_001)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)

        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: stopEvent(generationID: "generation-cloud"),
            at: Date(timeIntervalSince1970: 1_700_000_002)
        ))
        let status = store.sessionRegistry.activeSession(sessionID: sessionID)?.status
        #expect(status?.kind == .idle)
        #expect(status?.summary == "Waiting")
        #expect(status?.detail == "Handed off to Cursor Cloud")
    }

    @MainActor
    @Test func cursorToolHookCannotFabricateApprovalStatus() {
        let sessionID = "sess-no-false-approval"
        let store = makeCursorSessionStore(sessionID: sessionID)
        establishRoot(in: store, sessionID: sessionID)
        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: promptEvent(generationID: "generation-1"),
            at: Date(timeIntervalSince1970: 1_700_000_001)
        ))

        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: CursorHookEvent(
                hookEventName: "preToolUse",
                conversationID: "conversation-root",
                generationID: "generation-1",
                status: SessionStatus(
                    kind: .needsApproval,
                    summary: "Needs approval",
                    detail: "Run command"
                )
            ),
            at: Date(timeIntervalSince1970: 1_700_000_002)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)
    }

    @MainActor
    @Test func cursorSessionEndRetiresRootForANewComposerConversation() {
        let sessionID = "sess-new-conversation"
        let store = makeCursorSessionStore(sessionID: sessionID)

        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: CursorHookEvent(
                hookEventName: "sessionStart",
                conversationID: "conversation-1",
                generationID: nil,
                status: SessionStatus(kind: .idle, summary: "Waiting")
            ),
            at: Date(timeIntervalSince1970: 1_700_000_001)
        ))
        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: promptEvent(
                conversationID: "conversation-1",
                generationID: "generation-1"
            ),
            at: Date(timeIntervalSince1970: 1_700_000_002)
        ))

        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: CursorHookEvent(
                hookEventName: "sessionEnd",
                conversationID: "conversation-child",
                generationID: nil,
                status: nil
            ),
            at: Date(timeIntervalSince1970: 1_700_000_003)
        ) == false)
        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: CursorHookEvent(
                hookEventName: "sessionStart",
                conversationID: "conversation-2",
                generationID: nil,
                status: SessionStatus(kind: .idle, summary: "Waiting")
            ),
            at: Date(timeIntervalSince1970: 1_700_000_004)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)

        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: CursorHookEvent(
                hookEventName: "sessionEnd",
                conversationID: "conversation-1",
                generationID: nil,
                status: nil
            ),
            at: Date(timeIntervalSince1970: 1_700_000_005)
        ))
        let interruptedStatus = store.sessionRegistry.activeSession(sessionID: sessionID)?.status
        #expect(interruptedStatus?.kind == .idle)
        #expect(interruptedStatus?.summary == "Stopped")
        #expect(interruptedStatus?.detail == "Cursor session ended before the turn completed")
        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: CursorHookEvent(
                hookEventName: "sessionStart",
                conversationID: "conversation-2",
                generationID: nil,
                status: SessionStatus(
                    kind: .idle,
                    summary: "Waiting",
                    detail: "Cursor is ready"
                )
            ),
            at: Date(timeIntervalSince1970: 1_700_000_006)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .idle)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.detail == "Cursor is ready")
    }
}

private extension AutomationSocketServerCursorHookTests {
    func sendCursorEvent(
        socketPath: String,
        sessionID: String,
        panelID: UUID,
        eventName: String,
        conversationID: String? = nil,
        generationID: String? = nil,
        cloudHandoff: Bool = false,
        status: SessionStatus? = nil
    ) throws -> AutomationResponseEnvelope {
        var payload: [String: AutomationJSONValue] = [
            "hookEventName": .string(eventName),
            "cloudHandoff": .bool(cloudHandoff),
        ]
        if let conversationID {
            payload["conversationID"] = .string(conversationID)
        }
        if let generationID {
            payload["generationID"] = .string(generationID)
        }
        if let status {
            payload["kind"] = .string(status.kind.rawValue)
            payload["summary"] = .string(status.summary)
            if let detail = status.detail {
                payload["detail"] = .string(detail)
            }
        }
        return try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.cursor_hook_event",
                sessionID: sessionID,
                panelID: panelID.uuidString,
                requestID: UUID().uuidString,
                payload: payload
            ),
            socketPath: socketPath
        )
    }

    @MainActor
    func makeCursorSessionStore(sessionID: String) -> SessionRuntimeStore {
        let store = SessionRuntimeStore(
            sendSessionStatusNotification: { _, _, _, _, _ in },
            isApplicationActive: { false }
        )
        store.startSession(
            sessionID: sessionID,
            agent: .cursor,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/tmp/repo",
            repoRoot: "/tmp/repo",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return store
    }

    @MainActor
    func establishRoot(
        in store: SessionRuntimeStore,
        sessionID: String,
        conversationID: String = "conversation-root"
    ) {
        #expect(store.handleCursorHookEvent(
            sessionID: sessionID,
            event: CursorHookEvent(
                hookEventName: "sessionStart",
                conversationID: conversationID,
                generationID: nil,
                status: SessionStatus(kind: .idle, summary: "Waiting")
            ),
            at: Date(timeIntervalSince1970: 1_700_000_000.5)
        ))
    }

    func promptEvent(
        conversationID: String = "conversation-root",
        generationID: String
    ) -> CursorHookEvent {
        CursorHookEvent(
            hookEventName: "beforeSubmitPrompt",
            conversationID: conversationID,
            generationID: generationID,
            status: SessionStatus(kind: .working, summary: "Working")
        )
    }

    func stopEvent(generationID: String) -> CursorHookEvent {
        CursorHookEvent(
            hookEventName: "stop",
            conversationID: "conversation-root",
            generationID: generationID,
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Turn complete")
        )
    }
}
