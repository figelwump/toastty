import RemoteProtocol
import Foundation
import Testing
@testable import CoreState

struct RemoteInputCoordinatorTests {
    static let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "e1e1e1e1-0000-4000-8000-000000000001")!)
    static let bindingID = UUID(uuidString: "e1e1e1e1-0000-4000-8000-0000000000b1")!

    static func openEpoch(_ counter: UInt64) -> RemoteInputEpoch {
        RemoteInputEpoch(bindingID: bindingID, counter: counter)
    }

    static func readyContext(
        sendScope: Bool = true,
        writesEnabled: Bool = true,
        bound: Bool = true,
        surfaceReady: Bool = true
    ) -> RemoteInputCoordinator.DeliveryContext {
        RemoteInputCoordinator.DeliveryContext(
            deviceHasSendScope: sendScope,
            sessionWritesEnabled: writesEnabled,
            isBoundToLiveSurface: bound,
            isSurfaceReadyForInput: surfaceReady
        )
    }

    static func request(epoch: RemoteInputEpoch, id: String = "req-1", text: String = "ship it") -> RemoteMessageSendRequest {
        RemoteMessageSendRequest(
            conversationID: conversationID,
            clientRequestID: id,
            expectedInputEpoch: epoch,
            text: text
        )
    }

    static func openCoordinator(epoch: RemoteInputEpoch) -> RemoteInputCoordinator {
        var coordinator = RemoteInputCoordinator()
        coordinator.setProviderAvailability(.openPrompt(epoch: epoch), for: conversationID)
        return coordinator
    }

    // MARK: - Happy path

    @Test func acceptsAtMatchingOpenPromptEpoch() {
        let epoch = Self.openEpoch(3)
        let coordinator = Self.openCoordinator(epoch: epoch)
        #expect(coordinator.evaluate(Self.request(epoch: epoch), context: Self.readyContext()) == .accept(epoch: epoch))
    }

    // MARK: - Race matrix (v1 exit criterion)

    @Test func localDraftBlocksRemoteSend() {
        let epoch = Self.openEpoch(3)
        var coordinator = Self.openCoordinator(epoch: epoch)
        coordinator.noteLocalInput(for: Self.conversationID)
        // The client still holds the pre-draft epoch.
        #expect(coordinator.evaluate(Self.request(epoch: epoch), context: Self.readyContext())
            == .reject(.localDraftPresent))
        // And even a send presenting the bumped draft epoch is refused.
        #expect(coordinator.evaluate(Self.request(epoch: epoch.next()), context: Self.readyContext())
            == .reject(.localDraftPresent))
    }

    @Test func localTypingInvalidatesARenderedEpoch() {
        let epoch = Self.openEpoch(5)
        var coordinator = Self.openCoordinator(epoch: epoch)
        // Client rendered its compose bar at `epoch`; then the user types
        // locally before the send lands.
        coordinator.noteLocalInput(for: Self.conversationID)
        let decision = coordinator.evaluate(Self.request(epoch: epoch), context: Self.readyContext())
        #expect(decision == .reject(.localDraftPresent))
        #expect(coordinator.availability(for: Self.conversationID).allowsRemoteSend == false)
    }

    @Test func staleEpochAfterProviderAdvanceIsRejected() {
        let firstPrompt = Self.openEpoch(2)
        var coordinator = Self.openCoordinator(epoch: firstPrompt)
        // A new turn completes and the provider opens a fresh prompt epoch.
        let secondPrompt = Self.openEpoch(3)
        coordinator.setProviderAvailability(.openPrompt(epoch: secondPrompt), for: Self.conversationID)
        // A client still holding the first epoch is refused.
        #expect(coordinator.evaluate(Self.request(epoch: firstPrompt), context: Self.readyContext())
            == .reject(.epochMismatch))
        // The current epoch is accepted.
        #expect(coordinator.evaluate(Self.request(epoch: secondPrompt), context: Self.readyContext())
            == .accept(epoch: secondPrompt))
    }

    @Test func duplicateRequestInjectsOnce() {
        let epoch = Self.openEpoch(1)
        var coordinator = Self.openCoordinator(epoch: epoch)
        let request = Self.request(epoch: epoch, id: "retry-me")

        #expect(coordinator.evaluate(request, context: Self.readyContext()) == .accept(epoch: epoch))
        coordinator.markDelivered(request)

        // Even after the prompt re-opens, the same clientRequestID is a
        // duplicate and must not deliver again.
        coordinator.setProviderAvailability(.openPrompt(epoch: epoch.next()), for: Self.conversationID)
        #expect(coordinator.evaluate(request, context: Self.readyContext()) == .duplicate)
        // A distinct request at the current epoch is accepted normally.
        let fresh = Self.request(epoch: epoch.next(), id: "fresh")
        #expect(coordinator.evaluate(fresh, context: Self.readyContext()) == .accept(epoch: epoch.next()))
    }

    @Test func deliveryConsumesThePromptUntilProviderReopens() {
        let epoch = Self.openEpoch(1)
        var coordinator = Self.openCoordinator(epoch: epoch)
        let request = Self.request(epoch: epoch)
        #expect(coordinator.evaluate(request, context: Self.readyContext()).isAccepted)
        coordinator.markDelivered(request)

        // A second, different request finds the prompt closed.
        let second = Self.request(epoch: epoch, id: "second")
        #expect(coordinator.evaluate(second, context: Self.readyContext()) == .reject(.promptNotOpen))
    }

    @Test func staleProviderRepublishDoesNotReopenDeliveredPrompt() {
        let epoch = Self.openEpoch(1)
        var coordinator = Self.openCoordinator(epoch: epoch)
        let request = Self.request(epoch: epoch)
        coordinator.markDelivered(request)

        // A routine host sync can still see the projector's pre-delivery
        // availability. It must not resurrect the consumed prompt.
        coordinator.setProviderAvailability(.openPrompt(epoch: epoch), for: Self.conversationID)

        let second = Self.request(epoch: epoch, id: "second")
        #expect(coordinator.evaluate(second, context: Self.readyContext()) == .reject(.promptNotOpen))
    }

    @Test func uncertainDeliveryConsumesThePromptAndSuppressesRetry() {
        let epoch = Self.openEpoch(1)
        var coordinator = Self.openCoordinator(epoch: epoch)
        let request = Self.request(epoch: epoch, id: "uncertain")
        coordinator.markUncertain(request)

        coordinator.setProviderAvailability(.openPrompt(epoch: epoch), for: Self.conversationID)
        #expect(coordinator.evaluate(request, context: Self.readyContext()) == .duplicate)
        #expect(coordinator.evaluate(Self.request(epoch: epoch, id: "different"), context: Self.readyContext())
            == .reject(.promptNotOpen))
    }

    @Test func surfaceUnavailableIsRejected() {
        let epoch = Self.openEpoch(1)
        let coordinator = Self.openCoordinator(epoch: epoch)
        #expect(coordinator.evaluate(Self.request(epoch: epoch), context: Self.readyContext(surfaceReady: false))
            == .reject(.surfaceUnavailable))
    }

    @Test func unboundSurfaceIsRejected() {
        let epoch = Self.openEpoch(1)
        let coordinator = Self.openCoordinator(epoch: epoch)
        #expect(coordinator.evaluate(Self.request(epoch: epoch), context: Self.readyContext(bound: false))
            == .reject(.notBound))
        // Unknown conversation entirely.
        var empty = RemoteInputCoordinator()
        #expect(empty.evaluate(Self.request(epoch: epoch), context: Self.readyContext()) == .reject(.notBound))
        empty.removeConversation(Self.conversationID)
    }

    @Test func pendingInteractionBlocksSend() {
        var coordinator = RemoteInputCoordinator()
        coordinator.setProviderAvailability(
            .pendingInteraction(interactionIDs: [RemotePendingInteraction.ID(rawValue: "codex:approval:a1")]),
            for: Self.conversationID
        )
        #expect(coordinator.evaluate(Self.request(epoch: Self.openEpoch(1)), context: Self.readyContext())
            == .reject(.pendingInteraction))
    }

    @Test func scopeAndWriteGates() {
        let epoch = Self.openEpoch(1)
        let coordinator = Self.openCoordinator(epoch: epoch)
        #expect(coordinator.evaluate(Self.request(epoch: epoch), context: Self.readyContext(sendScope: false))
            == .reject(.sendScopeDenied))
        #expect(coordinator.evaluate(Self.request(epoch: epoch), context: Self.readyContext(writesEnabled: false))
            == .reject(.sessionWritesDisabled))
    }

    @Test func emptyTextIsRejected() {
        let epoch = Self.openEpoch(1)
        let coordinator = Self.openCoordinator(epoch: epoch)
        #expect(coordinator.evaluate(Self.request(epoch: epoch, text: "   \n  "), context: Self.readyContext())
            == .reject(.emptyText))
    }

    // MARK: - Local-draft recovery

    @Test func newProviderPromptEpochClearsLocalDraft() {
        let epoch = Self.openEpoch(4)
        var coordinator = Self.openCoordinator(epoch: epoch)
        coordinator.noteLocalInput(for: Self.conversationID)
        #expect(coordinator.availability(for: Self.conversationID).allowsRemoteSend == false)

        // A strictly newer open-prompt epoch (local input submitted, new turn)
        // clears the draft and re-enables remote send.
        let reopened = epoch.next()
        coordinator.setProviderAvailability(.openPrompt(epoch: reopened), for: Self.conversationID)
        #expect(coordinator.evaluate(Self.request(epoch: reopened), context: Self.readyContext())
            == .accept(epoch: reopened))
    }

    @Test func staleProviderRepublishDoesNotClearLocalDraft() {
        let epoch = Self.openEpoch(4)
        var coordinator = Self.openCoordinator(epoch: epoch)
        coordinator.noteLocalInput(for: Self.conversationID)
        // Re-publishing the SAME (now stale) open-prompt epoch must not resurrect it.
        coordinator.setProviderAvailability(.openPrompt(epoch: epoch), for: Self.conversationID)
        #expect(coordinator.availability(for: Self.conversationID).allowsRemoteSend == false)
    }

    @Test func idempotencyRecordIsBounded() {
        let epoch = Self.openEpoch(1)
        var coordinator = Self.openCoordinator(epoch: epoch)
        let capacity = RemoteInputCoordinator.idempotencyCapacityPerConversation

        var currentEpoch = epoch
        for index in 0..<(capacity + 5) {
            coordinator.setProviderAvailability(.openPrompt(epoch: currentEpoch), for: Self.conversationID)
            let request = Self.request(epoch: currentEpoch, id: "req-\(index)")
            #expect(coordinator.evaluate(request, context: Self.readyContext()).isAccepted)
            coordinator.markDelivered(request)
            currentEpoch = currentEpoch.next()
        }
        // The oldest ids were evicted; the newest are still remembered.
        #expect(coordinator.hasProcessed("req-\(capacity + 4)", for: Self.conversationID))
        #expect(coordinator.hasProcessed("req-0", for: Self.conversationID) == false)
    }

    @Test func sendResultWireRoundTrips() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()
        let cases: [RemoteMessageSendResult] = [
            .accepted(epoch: Self.openEpoch(2)),
            .rejected(reason: .epochMismatch),
            .uncertain,
            .duplicate,
        ]
        for value in cases {
            let decoded = try decoder.decode(RemoteMessageSendResult.self, from: try encoder.encode(value))
            #expect(decoded == value)
        }
    }
}


extension RemoteInputCoordinatorTests {
    @Test func attachmentOnlySendPreservesEpochLocalDraftAndIdempotencyGates() {
        let epoch = Self.openEpoch(3)
        var coordinator = Self.openCoordinator(epoch: epoch)
        var request = Self.request(epoch: epoch, text: "")
        request.attachments = [.init(filename: "x.txt", data: Data("hello".utf8))]
        #expect(coordinator.evaluate(request, context: Self.readyContext()) == .accept(epoch: epoch))
        var stale = request
        stale.expectedInputEpoch = Self.openEpoch(2)
        #expect(coordinator.evaluate(stale, context: Self.readyContext()) == .reject(.epochMismatch))
        coordinator.markDelivered(request)
        #expect(coordinator.evaluate(request, context: Self.readyContext()) == .duplicate)
        var local = Self.openCoordinator(epoch: epoch)
        local.noteLocalInput(for: Self.conversationID)
        #expect(local.evaluate(request, context: Self.readyContext()) == .reject(.localDraftPresent))
    }
}

// MARK: - Turn identity: steer, interrupt, and local drafts during a turn

extension RemoteInputCoordinatorTests {
    static func turnEpoch(_ counter: UInt64 = 3) -> RemoteInputEpoch {
        RemoteInputEpoch(bindingID: bindingID, counter: counter)
    }

    static func steerRequest(epoch: RemoteInputEpoch, id: String = "steer-1") -> RemoteMessageSendRequest {
        RemoteMessageSendRequest(
            conversationID: conversationID,
            clientRequestID: id,
            expectedInputEpoch: epoch,
            text: "use 300 ms",
            deliveryMode: .steer
        )
    }

    /// A conversation whose prompt was consumed and whose provider now
    /// reports the turn under the consumed epoch.
    static func workingCoordinator(turnEpoch: RemoteInputEpoch = turnEpoch()) -> RemoteInputCoordinator {
        var coordinator = RemoteInputCoordinator()
        coordinator.setProviderAvailability(.unavailable(reason: .working), for: conversationID)
        coordinator.setTurnEpoch(turnEpoch, for: conversationID)
        return coordinator
    }

    @Test func steerNeedsTheRunningTurnAndItsExactEpoch() {
        let turn = Self.turnEpoch()
        var coordinator = Self.workingCoordinator(turnEpoch: turn)
        #expect(coordinator.canSteer(for: Self.conversationID))
        #expect(coordinator.evaluateSteer(Self.steerRequest(epoch: turn), context: Self.readyContext())
            == .accept(epoch: turn))
        #expect(coordinator.evaluateSteer(Self.steerRequest(epoch: Self.turnEpoch(2)), context: Self.readyContext())
            == .reject(.turnMismatch))
        #expect(coordinator.evaluateSteer(Self.steerRequest(epoch: turn), context: Self.readyContext(writesEnabled: false))
            == .reject(.sessionWritesDisabled))

        coordinator.setTurnEpoch(nil, for: Self.conversationID)
        #expect(coordinator.canSteer(for: Self.conversationID) == false)
        #expect(coordinator.evaluateSteer(Self.steerRequest(epoch: turn), context: Self.readyContext())
            == .reject(.notWorking))
    }

    @Test func steerDeliveryKeepsThePromptClosedAndSuppressesRetries() {
        let turn = Self.turnEpoch()
        var coordinator = Self.workingCoordinator(turnEpoch: turn)
        let request = Self.steerRequest(epoch: turn)
        coordinator.markSteerDelivered(request)
        #expect(coordinator.availability(for: Self.conversationID) == .unavailable(reason: .working))
        #expect(coordinator.hasProcessed(request.clientRequestID, for: Self.conversationID))
        #expect(coordinator.evaluateSteer(request, context: Self.readyContext()) == .duplicate)
        // A second, different steer into the same turn is still allowed.
        #expect(coordinator.evaluateSteer(Self.steerRequest(epoch: turn, id: "steer-2"), context: Self.readyContext())
            == .accept(epoch: turn))
    }

    @Test func uncertainSteerCountsAsLocalTypingInTheTurn() {
        let turn = Self.turnEpoch()
        var coordinator = Self.workingCoordinator(turnEpoch: turn)
        let request = Self.steerRequest(epoch: turn)
        coordinator.markSteerUncertain(request)
        // Text may sit in the composer: no further steer may append to it...
        #expect(coordinator.evaluateSteer(request, context: Self.readyContext()) == .duplicate)
        #expect(coordinator.evaluateSteer(Self.steerRequest(epoch: turn, id: "steer-2"), context: Self.readyContext())
            == .reject(.steerUnavailable))
        // ...and the next prompt opens as a local draft, not for remote sends.
        coordinator.setTurnEpoch(nil, for: Self.conversationID)
        let next = Self.openEpoch(4)
        coordinator.setProviderAvailability(.openPrompt(epoch: next), for: Self.conversationID)
        #expect(coordinator.availability(for: Self.conversationID) == .localDraft(epoch: next.next()))
    }

    @Test func localTypingDuringTheTurnBlocksSteerUntilAnotherTurnRuns() {
        let turn = Self.turnEpoch()
        var coordinator = Self.workingCoordinator(turnEpoch: turn)
        coordinator.noteLocalInput(for: Self.conversationID)
        #expect(coordinator.canSteer(for: Self.conversationID) == false)
        #expect(coordinator.evaluateSteer(Self.steerRequest(epoch: turn), context: Self.readyContext())
            == .reject(.steerUnavailable))
        // A stop is still allowed: the user wants the turn gone, draft or not.
        #expect(coordinator.evaluateInterrupt(for: Self.conversationID, expectedTurnEpoch: turn, context: Self.readyContext())
            == .accept(turnEpoch: turn))

        // The provider logged the Mac user's own message: the draft was sent.
        coordinator.noteLocalDraftSubmitted(for: Self.conversationID)
        #expect(coordinator.canSteer(for: Self.conversationID))

        coordinator.noteLocalInput(for: Self.conversationID)
        let nextTurn = Self.turnEpoch(5)
        coordinator.setTurnEpoch(nil, for: Self.conversationID)
        coordinator.setTurnEpoch(nextTurn, for: Self.conversationID)
        #expect(coordinator.canSteer(for: Self.conversationID))
    }

    @Test func localTypingDuringTheTurnOpensTheNextPromptAsALocalDraft() {
        let turn = Self.turnEpoch()
        var coordinator = Self.workingCoordinator(turnEpoch: turn)
        coordinator.noteLocalInput(for: Self.conversationID)
        coordinator.setTurnEpoch(nil, for: Self.conversationID)

        let next = Self.openEpoch(4)
        coordinator.setProviderAvailability(.openPrompt(epoch: next), for: Self.conversationID)
        #expect(coordinator.availability(for: Self.conversationID) == .localDraft(epoch: next.next()))
        #expect(coordinator.evaluate(Self.request(epoch: next), context: Self.readyContext())
            == .reject(.localDraftPresent))
        // A republish of the same prompt generation keeps it closed...
        coordinator.setProviderAvailability(.openPrompt(epoch: next), for: Self.conversationID)
        #expect(coordinator.availability(for: Self.conversationID).allowsRemoteSend == false)
        // ...and a genuinely newer prompt reopens remote input.
        let later = Self.openEpoch(5)
        coordinator.setProviderAvailability(.openPrompt(epoch: later), for: Self.conversationID)
        #expect(coordinator.evaluate(Self.request(epoch: later), context: Self.readyContext())
            == .accept(epoch: later))
    }

    @Test func submittedLocalDraftDoesNotCloseTheNextPrompt() {
        let turn = Self.turnEpoch()
        var coordinator = Self.workingCoordinator(turnEpoch: turn)
        coordinator.noteLocalInput(for: Self.conversationID)
        coordinator.noteLocalDraftSubmitted(for: Self.conversationID)
        coordinator.setTurnEpoch(nil, for: Self.conversationID)
        let next = Self.openEpoch(4)
        coordinator.setProviderAvailability(.openPrompt(epoch: next), for: Self.conversationID)
        #expect(coordinator.availability(for: Self.conversationID) == .openPrompt(epoch: next))
    }

    @Test func localTypingRightAfterARemoteDeliveryMarksTheUpcomingTurn() {
        let epoch = Self.openEpoch(3)
        var coordinator = Self.openCoordinator(epoch: epoch)
        let delivered = Self.request(epoch: epoch)
        coordinator.markDelivered(delivered)
        // The provider has not reported the turn yet, but the Mac user types.
        coordinator.noteLocalInput(for: Self.conversationID)
        coordinator.setTurnEpoch(epoch, for: Self.conversationID)
        #expect(coordinator.canSteer(for: Self.conversationID) == false)
    }

    @Test func interruptNeedsTheRunningTurn() {
        let turn = Self.turnEpoch()
        var coordinator = Self.workingCoordinator(turnEpoch: turn)
        #expect(coordinator.evaluateInterrupt(for: Self.conversationID, expectedTurnEpoch: Self.turnEpoch(2), context: Self.readyContext())
            == .reject(.turnMismatch))
        #expect(coordinator.evaluateInterrupt(for: Self.conversationID, expectedTurnEpoch: turn, context: Self.readyContext(sendScope: false))
            == .reject(.sendScopeDenied))
        #expect(coordinator.evaluateInterrupt(for: Self.conversationID, expectedTurnEpoch: turn, context: Self.readyContext(surfaceReady: false))
            == .reject(.surfaceUnavailable))
        coordinator.setTurnEpoch(nil, for: Self.conversationID)
        #expect(coordinator.evaluateInterrupt(for: Self.conversationID, expectedTurnEpoch: turn, context: Self.readyContext())
            == .reject(.notWorking))
        #expect(RemoteInputCoordinator().evaluateInterrupt(for: Self.conversationID, expectedTurnEpoch: turn, context: Self.readyContext())
            == .reject(.notBound))
    }

    @Test func queueAndSteerSendResultsRoundTripOnTheWire() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()
        for value in [RemoteMessageSendResult.queued(position: 2), .rejected(reason: .queueFull), .rejected(reason: .steerUnavailable)] {
            #expect(try decoder.decode(RemoteMessageSendResult.self, from: try encoder.encode(value)) == value)
        }
        var request = Self.request(epoch: Self.turnEpoch())
        #expect(String(decoding: try encoder.encode(request), as: UTF8.self).contains("deliveryMode") == false)
        request.deliveryMode = .queue
        let decoded = try decoder.decode(RemoteMessageSendRequest.self, from: try encoder.encode(request))
        #expect(decoded.deliveryMode == .queue)
        // An older host's request shape (no mode) decodes as a prompt send.
        let legacy = try decoder.decode(RemoteMessageSendRequest.self, from: Data(#"{"clientRequestID":"x","conversationID":"\#(Self.conversationID.rawValue.uuidString)","expectedInputEpoch":{"bindingID":"\#(Self.bindingID.uuidString)","counter":1},"text":"hi"}"#.utf8))
        #expect(legacy.deliveryMode == .prompt)
    }
}
