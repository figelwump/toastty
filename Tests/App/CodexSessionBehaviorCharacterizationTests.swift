import CoreState
import Testing
@testable import ToasttyApp

@MainActor
struct CodexSessionBehaviorCharacterizationTests {
    @Test
    func hookAuthorityIgnoresBothFallbackCompletionPaths() async {
        let scenario = CodexLegacyScenarioDriver(
            trackingSource: .hooks,
            applicationIsActive: false,
            sessionPanelPlacement: .background
        )
        defer { scenario.reset() }
        scenario.recordRootTurnContext(threadID: "thread-root", turnID: "turn-root")

        let notifyAccepted = scenario.sendNotifyCompletion(
            threadID: "thread-root",
            turnID: "turn-root",
            detail: "Notify says complete"
        )
        let sessionLogAccepted = scenario.sendSessionLogCompletion(
            threadID: "thread-root",
            turnID: "turn-root",
            detail: "Session log says complete"
        )

        #expect(notifyAccepted == false)
        #expect(sessionLogAccepted == false)
        #expect(scenario.snapshot().recordStatus?.kind == .working)
        #expect(await scenario.capturedEffects().isEmpty)
    }

    @Test
    func fallbackAuthorityIgnoresHookAndAcceptsSessionLogCompletion() async {
        let scenario = CodexLegacyScenarioDriver(
            trackingSource: .sessionLogFallback(reason: "characterization"),
            applicationIsActive: false,
            sessionPanelPlacement: .background
        )
        defer { scenario.reset() }
        scenario.recordRootTurnContext(threadID: "thread-root", turnID: "turn-root")

        let hookAccepted = scenario.sendHookEvent(
            name: "Stop",
            threadID: "thread-root",
            turnID: "turn-root",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Hook says complete")
        )
        #expect(hookAccepted == false)
        #expect(scenario.snapshot().recordStatus?.kind == .working)

        let sessionLogAccepted = scenario.sendSessionLogCompletion(
            threadID: "thread-root",
            turnID: "turn-root",
            detail: "Session log says complete"
        )

        #expect(sessionLogAccepted)
        let snapshot = scenario.snapshot()
        #expect(snapshot.recordStatus == SessionStatus(
            kind: .ready,
            summary: "Ready",
            detail: "Session log says complete"
        ))
        #expect(snapshot.workspaceStatus?.kind == .ready)
        #expect(snapshot.workspaceProjection == SessionStatusProjection.none)
        #expect(snapshot.panelIsUnread)
        #expect(await scenario.capturedEffects(waitingForNotificationCount: 1).count == 1)
    }

    @Test
    func exactRootThreadAndTurnMismatchesDoNotCloseCurrentTurn() async {
        let scenario = CodexLegacyScenarioDriver(
            trackingSource: .sessionLogFallback(reason: "characterization"),
            applicationIsActive: false,
            sessionPanelPlacement: .background
        )
        defer { scenario.reset() }
        scenario.recordRootTurnContext(threadID: "thread-root", turnID: "turn-root")

        let threadMismatchAccepted = scenario.sendSessionLogCompletion(
            threadID: "thread-child",
            turnID: "turn-root",
            detail: "Different thread completed"
        )
        let turnMismatchAccepted = scenario.sendSessionLogCompletion(
            threadID: "thread-root",
            turnID: "turn-child",
            detail: "Different turn completed"
        )

        #expect(threadMismatchAccepted == false)
        #expect(turnMismatchAccepted == false)
        let snapshot = scenario.snapshot()
        #expect(snapshot.recordStatus == SessionStatus(
            kind: .working,
            summary: "Working",
            detail: "Root turn is running"
        ))
        #expect(snapshot.workspaceStatus?.kind == .working)
        #expect(snapshot.panelIsUnread == false)
        #expect(await scenario.capturedEffects().isEmpty)
    }

    @Test
    func completionNotifiesWhenApplicationIsInactiveEvenIfPanelIsFocused() async {
        let scenario = CodexLegacyScenarioDriver(
            trackingSource: .sessionLogFallback(reason: "characterization"),
            applicationIsActive: false,
            sessionPanelPlacement: .focused
        )
        defer { scenario.reset() }
        scenario.recordRootTurnContext(threadID: "thread-root", turnID: "turn-root")

        #expect(scenario.sendSessionLogCompletion(
            threadID: "thread-root",
            turnID: "turn-root",
            detail: "Root turn finished"
        ))

        let snapshot = scenario.snapshot()
        let effects = await scenario.capturedEffects(waitingForNotificationCount: 1)
        #expect(snapshot.recordStatus?.kind == .ready)
        #expect(snapshot.workspaceStatus?.kind == .ready)
        #expect(snapshot.panelIsUnread)
        #expect(effects.count == 1)
        #expect(effects.first?.title == "Codex is ready")
        #expect(effects.first?.body == "Root turn finished")
    }

    @Test
    func completionSuppressesNotificationWhenApplicationAndPanelAreActive() async {
        let scenario = CodexLegacyScenarioDriver(
            trackingSource: .sessionLogFallback(reason: "characterization"),
            applicationIsActive: true,
            sessionPanelPlacement: .focused
        )
        defer { scenario.reset() }
        scenario.recordRootTurnContext(threadID: "thread-root", turnID: "turn-root")

        #expect(scenario.sendSessionLogCompletion(
            threadID: "thread-root",
            turnID: "turn-root",
            detail: "Root turn finished"
        ))

        let snapshot = scenario.snapshot()
        #expect(snapshot.recordStatus == SessionStatus(
            kind: .idle,
            summary: "Waiting",
            detail: "Root turn finished"
        ))
        #expect(snapshot.workspaceStatus?.kind == .idle)
        #expect(snapshot.panelIsUnread == false)
        #expect(await scenario.capturedEffects().isEmpty)
    }
}
