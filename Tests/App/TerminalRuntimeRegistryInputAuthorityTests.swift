import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct TerminalRuntimeRegistryInputAuthorityTests {
    @Test
    func managedAgentCommandDoesNotDirtyNativeBindingButUserInputDoes() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try #require(store.selectedWindow?.id)
        let workspaceID = try #require(store.selectedWorkspace?.id)
        let panelID = try #require(store.selectedWorkspace?.focusedPanelID)
        let sessionID = "managed-session"
        let startedAt = Date(timeIntervalSince1970: 1_786_000_000)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)
        registry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        var deliveredInputs: [(text: String, submit: Bool)] = []
        registry.setAutomationSendTextHandlerForTesting { text, submit, submittedPanelID, focusPolicy in
            #expect(submittedPanelID == panelID)
            #expect(focusPolicy == .focusTarget)
            deliveredInputs.append((text, submit))
            return true
        }

        #expect(registry.sendManagedAgentCommand(
            "codex resume native-session-id",
            panelID: panelID,
            focusPolicy: .focusTarget
        ))

        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "native-session-id",
            sessionFilePath: "/tmp/current-rollout.jsonl",
            cwd: "/repo",
            capturedAt: startedAt.addingTimeInterval(1)
        )
        #expect(sessionRuntimeStore.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: record
        ))
        let confirmation = try #require(
            sessionRuntimeStore.nativeSessionBindingConfirmation(for: sessionID)
        )
        #expect(sessionRuntimeStore.isNativeSessionBindingInputClean(confirmation))

        #expect(registry.sendText("user draft", submit: false, panelID: panelID))

        try #require(deliveredInputs.count == 2)
        #expect(deliveredInputs[0].text == "codex resume native-session-id")
        #expect(deliveredInputs[0].submit)
        #expect(deliveredInputs[1].text == "user draft")
        #expect(deliveredInputs[1].submit == false)
        #expect(sessionRuntimeStore.isNativeSessionBindingInputClean(confirmation) == false)
    }
}
