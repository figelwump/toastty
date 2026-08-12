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
