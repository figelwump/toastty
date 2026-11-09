import CoreState
import Foundation
import Testing

/// When text for the coordinator may be typed: only at an open prompt, one
/// entry for each prompt, and never over the user's draft.
struct CoordinatorSendGateTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func session(
        _ kind: SessionStatusKind?,
        id: String = "session-1",
        turnEndedAfter end: TimeInterval? = nil,
        turnLasted duration: TimeInterval = 5,
        hasReportedStart: Bool = true
    ) -> CoordinatorPromptFacts.Session {
        CoordinatorPromptFacts.Session(
            sessionID: id,
            statusKind: kind,
            startedAt: start,
            lastTurnEndedAt: end.map { start.addingTimeInterval($0) },
            lastTurnDuration: end == nil ? nil : duration,
            hasReportedStart: hasReportedStart
        )
    }

    private func decide(
        _ session: CoordinatorPromptFacts.Session?,
        at seconds: TimeInterval,
        terminalReady: Bool = true,
        userInputAt: TimeInterval? = nil,
        deliveryAt: TimeInterval? = nil,
        deliverySession: String = "session-1"
    ) -> CoordinatorSendGate.Decision {
        CoordinatorSendGate.decide(
            CoordinatorPromptFacts(
                session: session,
                isTerminalReady: terminalReady,
                lastUserInputAt: userInputAt.map { start.addingTimeInterval($0) },
                lastDelivery: deliveryAt.map {
                    CoordinatorPromptFacts.Delivery(sessionID: deliverySession, at: start.addingTimeInterval($0))
                }
            ),
            now: start.addingTimeInterval(seconds)
        )
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test
    func noSessionHoldsUntilOneStarts() {
        #expect(decide(nil, at: 10) == .hold(.noSession, recheckAt: nil))
    }

    @Test
    func anAgentThatHasNotReportedItsStartIsPolled() {
        #expect(decide(session(nil, hasReportedStart: false), at: 1)
            == .hold(.agentStarting, recheckAt: at(1 + CoordinatorSendGate.pollInterval)))
        // Its first prompt is open once it reports, with no status yet.
        #expect(decide(session(nil), at: 1) == .open)
    }

    @Test
    func aTerminalThatCannotTakeInputIsPolled() {
        #expect(decide(session(.idle), at: 3, terminalReady: false)
            == .hold(.terminalUnavailable, recheckAt: at(3 + CoordinatorSendGate.pollInterval)))
    }

    @Test
    func aWorkingOrWaitingAgentHoldsUntilItsSessionChanges() {
        #expect(decide(session(.working), at: 10) == .hold(.busy, recheckAt: nil))
        #expect(decide(session(.needsApproval), at: 10) == .hold(.busy, recheckAt: nil))
    }

    @Test
    func everyRestStateIsAnOpenPromptAfterTheSettleTime() {
        let settle = CoordinatorSendGate.promptSettleInterval
        for kind in [SessionStatusKind.idle, .ready, .error] {
            #expect(decide(session(kind, turnEndedAfter: 20), at: 20 + settle / 2)
                == .hold(.settling, recheckAt: at(20 + settle)))
            #expect(decide(session(kind, turnEndedAfter: 20), at: 20 + settle) == .open)
        }
    }

    @Test
    func oneEntryForEachPrompt() {
        let timeout = CoordinatorSendGate.turnStartTimeout
        // Typed at 30; its turn has not started.
        #expect(decide(session(.idle, turnEndedAfter: 20), at: 31, deliveryAt: 30)
            == .hold(.awaitingTurn, recheckAt: at(30 + timeout)))
        // Its turn runs.
        #expect(decide(session(.working, turnEndedAfter: 20), at: 32, deliveryAt: 30) == .hold(.busy, recheckAt: nil))
        // Its turn ended at 40: the next prompt is open after the settle time.
        #expect(decide(session(.idle, turnEndedAfter: 40), at: 40.1, deliveryAt: 30)
            == .hold(.settling, recheckAt: at(40 + CoordinatorSendGate.promptSettleInterval)))
        #expect(decide(session(.idle, turnEndedAfter: 40), at: 41, deliveryAt: 30) == .open)
    }

    @Test
    func anEntryThatNeverStartsItsTurnStopsHoldingTheQueue() {
        let timeout = CoordinatorSendGate.turnStartTimeout
        #expect(decide(session(.idle, turnEndedAfter: 20), at: 30 + timeout - 0.1, deliveryAt: 30)
            == .hold(.awaitingTurn, recheckAt: at(30 + timeout)))
        #expect(decide(session(.idle, turnEndedAfter: 20), at: 30 + timeout, deliveryAt: 30) == .open)
    }

    @Test
    func aDeliveryToAnEarlierSessionDoesNotHoldANewOne() {
        #expect(decide(session(nil, id: "session-2"), at: 31, deliveryAt: 30, deliverySession: "session-1") == .open)
    }

    @Test
    func theUsersDraftHoldsUntilTheySendIt() {
        // No turn yet: typing after the session started is a draft.
        #expect(decide(session(nil), at: 10, userInputAt: 5) == .hold(.userDraft, recheckAt: nil))
        // Typing before the session started went to the shell, not the agent.
        #expect(decide(session(nil), at: 10, userInputAt: -5) == .open)

        // The last turn ran from 15 to 20. Keys before 15 started it: sent.
        #expect(decide(session(.idle, turnEndedAfter: 20), at: 30, userInputAt: 14.9) == .open)
        // Keys during the turn stay in the composer when it ends.
        #expect(decide(session(.idle, turnEndedAfter: 20), at: 30, userInputAt: 17) == .hold(.userDraft, recheckAt: nil))
        // Keys after it are a draft too.
        #expect(decide(session(.idle, turnEndedAfter: 20), at: 30, userInputAt: 25) == .hold(.userDraft, recheckAt: nil))
        // Sending the draft starts a turn (26 to 28), which clears the hold.
        #expect(decide(session(.idle, turnEndedAfter: 28, turnLasted: 2), at: 30, userInputAt: 25) == .open)
    }
}
