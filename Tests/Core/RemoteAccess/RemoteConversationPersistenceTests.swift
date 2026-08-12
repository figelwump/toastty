import RemoteProtocol
import CoreState
import Foundation
import Testing

struct RemoteConversationPersistenceTests {
    static let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!)

    @Test func reducerSetsAndClearsRemoteConversationID() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(reducer.send(
            .updateTerminalPanelRemoteConversationID(panelID: panelID, remoteConversationID: Self.conversationID),
            state: &state
        ))
        guard case .terminal(let terminalState) = state.workspacesByID[workspaceID]?.panels[panelID] else {
            Issue.record("Expected terminal panel")
            return
        }
        #expect(terminalState.remoteConversationID == Self.conversationID)

        // Re-sending the same value is a no-op.
        #expect(reducer.send(
            .updateTerminalPanelRemoteConversationID(panelID: panelID, remoteConversationID: Self.conversationID),
            state: &state
        ) == false)

        #expect(reducer.send(
            .updateTerminalPanelRemoteConversationID(panelID: panelID, remoteConversationID: nil),
            state: &state
        ))
        guard case .terminal(let clearedState) = state.workspacesByID[workspaceID]?.panels[panelID] else {
            Issue.record("Expected terminal panel")
            return
        }
        #expect(clearedState.remoteConversationID == nil)

        try StateValidator.validate(state)
    }

    @Test func layoutSnapshotRoundTripsRemoteConversationID() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        #expect(reducer.send(
            .updateTerminalPanelRemoteConversationID(panelID: panelID, remoteConversationID: Self.conversationID),
            state: &state
        ))

        let snapshot = WorkspaceLayoutSnapshot(state: state)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: encoded)
        let restoredState = decoded.makeAppState()

        guard case .terminal(let restoredTerminalState) = restoredState.workspacesByID[workspaceID]?.panels[panelID] else {
            Issue.record("Expected restored terminal panel")
            return
        }
        #expect(restoredTerminalState.remoteConversationID == Self.conversationID)
    }

    @Test func legacyTerminalSnapshotWithoutConversationIDDecodes() throws {
        let legacyJSON = #"{"shell":"zsh","launchWorkingDirectory":"/tmp/demo","cwd":"/tmp/demo"}"#
        let decoded = try JSONDecoder().decode(
            WorkspaceLayoutTerminalPanelSnapshot.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.remoteConversationID == nil)
        #expect(decoded.shell == "zsh")
    }

    @Test func conversationIdentitySurvivesResumeRecordReplacement() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(reducer.send(
            .updateTerminalPanelRemoteConversationID(panelID: panelID, remoteConversationID: Self.conversationID),
            state: &state
        ))
        let firstRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "01900000-aaaa-7000-8000-000000000001",
            sessionFilePath: "/tmp/rollout-a.jsonl",
            cwd: "/tmp/demo",
            capturedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )
        #expect(reducer.send(
            .updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: firstRecord),
            state: &state
        ))

        // The native session rotates: the record is cleared, then replaced.
        #expect(reducer.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: nil), state: &state))
        let secondRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "01900000-aaaa-7000-8000-000000000002",
            sessionFilePath: "/tmp/rollout-b.jsonl",
            cwd: "/tmp/demo",
            capturedAt: Date(timeIntervalSince1970: 1_786_010_000)
        )
        #expect(reducer.send(
            .updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: secondRecord),
            state: &state
        ))

        guard case .terminal(let terminalState) = state.workspacesByID[workspaceID]?.panels[panelID] else {
            Issue.record("Expected terminal panel")
            return
        }
        #expect(terminalState.resumeRecord == secondRecord)
        #expect(terminalState.remoteConversationID == Self.conversationID)
    }
}
