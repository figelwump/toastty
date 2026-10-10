import RemoteProtocol
import Foundation

/// Single source of truth for whether a remote free-form send may be delivered
/// to a conversation's terminal surface, and the gate that decides every send.
///
/// Both writers of input availability feed this one type: the projection's
/// authoritative provider transitions (`setProviderAvailability`) and local
/// keyboard/paste/menu input (`noteLocalInput`). Local input always wins until
/// a *later* provider transition establishes a new open-prompt epoch — that is
/// what makes "local typing invalidates a rendered remote epoch" hold.
///
/// The coordinator is a pure value type. The host drives the whole accept →
/// deliver → mark sequence synchronously on the main actor, so there is no
/// asynchronous gap between the gate check and delivery: nothing can change the
/// epoch between `evaluate` returning `.accept` and `markDelivered`.
public struct RemoteInputCoordinator: Sendable {
    /// External preconditions the host supplies per request — everything the
    /// coordinator cannot know from input availability alone.
    public struct DeliveryContext: Equatable, Sendable {
        public var deviceHasSendScope: Bool
        public var sessionWritesEnabled: Bool
        public var isBoundToLiveSurface: Bool
        public var isSurfaceReadyForInput: Bool

        public init(
            deviceHasSendScope: Bool,
            sessionWritesEnabled: Bool,
            isBoundToLiveSurface: Bool,
            isSurfaceReadyForInput: Bool
        ) {
            self.deviceHasSendScope = deviceHasSendScope
            self.sessionWritesEnabled = sessionWritesEnabled
            self.isBoundToLiveSurface = isBoundToLiveSurface
            self.isSurfaceReadyForInput = isSurfaceReadyForInput
        }
    }

    /// Outcome of the gate check. `.accept` authorizes exactly one delivery;
    /// the host must call `markDelivered` immediately after a successful
    /// delivery and must not deliver on any other outcome.
    public enum Decision: Equatable, Sendable {
        case accept(epoch: RemoteInputEpoch)
        case reject(RemoteMessageRejectionReason)
        /// Already processed; the earlier delivery stands. No new delivery.
        case duplicate

        public var isAccepted: Bool {
            if case .accept = self { return true }
            return false
        }
    }

    /// Bounded per-conversation idempotency memory.
    public static let idempotencyCapacityPerConversation = 64

    private struct ConversationState {
        var availability: RemoteInputAvailability
        /// The last open-prompt epoch invalidated by local input or a delivery
        /// attempt. A provider republish at this epoch is stale and must not
        /// resurrect a consumed prompt.
        var invalidatedOpenEpoch: RemoteInputEpoch?
        /// Identity of the running turn, from the projector.
        var turnEpoch: RemoteInputEpoch?
        /// The turn whose running composer local keyboard input touched. A
        /// steer into that turn could land inside the Mac user's draft, so it
        /// stays refused until a different turn runs.
        var localInputTurnEpoch: RemoteInputEpoch?
        /// The last draft epoch issued. A release reopens the prompt at its
        /// provider epoch, so a later draft must not reuse a draft epoch a
        /// client may still hold from before that release.
        var lastDraftEpoch: RemoteInputEpoch?
        var processedRequestIDs: [String] = []
        var processedRequestSet: Set<String> = []
    }

    /// Outcome of an interrupt gate check.
    public enum InterruptDecision: Equatable, Sendable {
        case accept(turnEpoch: RemoteInputEpoch)
        case reject(RemoteConversationInterruptRejectionReason)
    }

    /// Outcome of a local draft release.
    public enum LocalDraftReleaseDecision: Equatable, Sendable {
        case released(openEpoch: RemoteInputEpoch)
        case reject(RemoteConversationLocalDraftReleaseRejectionReason)
    }

    private var statesByConversation: [RemoteConversationID: ConversationState] = [:]

    public init() {}

    // MARK: - Availability writers

    /// Records the projection's authoritative availability for a conversation.
    ///
    /// A provider `openPrompt` with a strictly newer epoch supersedes any local
    /// draft (a genuinely new prompt generation opened). Any other provider
    /// state is adopted as-is. This never *downgrades* a fresh local draft back
    /// to the stale open-prompt it replaced.
    public mutating func setProviderAvailability(
        _ availability: RemoteInputAvailability,
        for conversationID: RemoteConversationID
    ) {
        var state = statesByConversation[conversationID]
            ?? ConversationState(availability: availability, invalidatedOpenEpoch: nil)

        if case .openPrompt(let candidateEpoch) = availability,
           let invalidatedEpoch = state.invalidatedOpenEpoch {
            // The projector can briefly republish its old open prompt while a
            // local draft or delivered send is waiting to appear in the
            // provider log. Preserve the coordinator's closed state until the
            // provider advances to a genuinely newer prompt generation.
            guard Self.supersedes(candidateEpoch, invalidatedEpoch) else {
                statesByConversation[conversationID] = state
                return
            }
            state.invalidatedOpenEpoch = nil
        }
        if case .openPrompt(let candidateEpoch) = availability,
           state.localInputTurnEpoch != nil {
            // Local keyboard input during the turn that just ended, with no
            // provider evidence it was submitted, means the Mac composer may
            // still hold a draft. Open as a local draft instead, so neither a
            // live send nor a queued delivery types into it; the next
            // provider prompt generation reopens remote input as usual.
            state.localInputTurnEpoch = nil
            state.invalidatedOpenEpoch = candidateEpoch
            Self.openLocalDraft(after: candidateEpoch, in: &state)
            statesByConversation[conversationID] = state
            return
        }
        state.availability = availability
        statesByConversation[conversationID] = state
    }

    /// Records that the provider logged a user message that was not a remote
    /// delivery: the Mac user submitted what they typed. The running turn is
    /// no longer treated as holding a local draft, so a steer may follow and
    /// the next prompt opens normally.
    public mutating func noteLocalDraftSubmitted(for conversationID: RemoteConversationID) {
        guard var state = statesByConversation[conversationID],
              state.localInputTurnEpoch != nil else { return }
        state.localInputTurnEpoch = nil
        statesByConversation[conversationID] = state
    }

    /// Moves to a local draft under an epoch after both `epoch` and every
    /// draft epoch issued before, so draft epochs never repeat.
    private static func openLocalDraft(after epoch: RemoteInputEpoch, in state: inout ConversationState) {
        var draftEpoch = epoch.next()
        if let last = state.lastDraftEpoch,
           last.bindingID == draftEpoch.bindingID,
           last.counter >= draftEpoch.counter {
            draftEpoch = last.next()
        }
        state.lastDraftEpoch = draftEpoch
        state.availability = .localDraft(epoch: draftEpoch)
    }

    /// Whether `candidate` represents a strictly later prompt generation than
    /// `existing`. Across bindings there is no ordering, so any different
    /// binding is treated as newer (a rebind opens a new prompt).
    private static func supersedes(_ candidate: RemoteInputEpoch, _ existing: RemoteInputEpoch) -> Bool {
        if candidate.bindingID != existing.bindingID {
            return true
        }
        return candidate.counter > existing.counter
    }

    /// Records the projector's current turn identity. Steer and interrupt
    /// requests must present exactly this epoch.
    public mutating func setTurnEpoch(
        _ turnEpoch: RemoteInputEpoch?,
        for conversationID: RemoteConversationID
    ) {
        guard var state = statesByConversation[conversationID] else { return }
        guard state.turnEpoch != turnEpoch else { return }
        state.turnEpoch = turnEpoch
        statesByConversation[conversationID] = state
    }

    /// Records that local keyboard/paste/menu input touched the prompt. O(1)
    /// and allocation-free on the hot path: if the prompt was open, it becomes
    /// a local draft under a bumped epoch, and each later keystroke bumps the
    /// draft epoch again so a remote release decided before it is refused;
    /// while a turn runs, that turn is marked so remote steers stay out of the
    /// Mac user's draft.
    public mutating func noteLocalInput(for conversationID: RemoteConversationID) {
        guard var state = statesByConversation[conversationID] else { return }
        switch state.availability {
        case .openPrompt(let epoch):
            state.invalidatedOpenEpoch = epoch
            Self.openLocalDraft(after: epoch, in: &state)
        case .localDraft(let epoch):
            Self.openLocalDraft(after: epoch, in: &state)
        case .unavailable, .pendingInteraction:
            break
        }
        if let turnEpoch = state.turnEpoch {
            state.localInputTurnEpoch = turnEpoch
        } else if case .unavailable(reason: .working) = state.availability,
                  let consumedEpoch = state.invalidatedOpenEpoch {
            // A remote delivery consumed the prompt but the provider has not
            // reported the turn yet; its identity will be the consumed epoch.
            state.localInputTurnEpoch = consumedEpoch
        }
        statesByConversation[conversationID] = state
    }

    /// Reopens a prompt that a local draft holds closed, after a remote user
    /// says the Mac composer is empty. Nothing is typed. The prompt reopens at
    /// the provider epoch the draft replaced, so the provider's own republish
    /// of that prompt keeps it open and a send there consumes it as usual.
    /// The client must name the current draft epoch: any Mac keystroke after
    /// it saw the draft advances that epoch and refuses the release.
    public mutating func releaseLocalDraft(
        for conversationID: RemoteConversationID,
        expectedDraftEpoch: RemoteInputEpoch,
        context: DeliveryContext
    ) -> LocalDraftReleaseDecision {
        guard var state = statesByConversation[conversationID] else {
            return .reject(.notBound)
        }
        guard context.deviceHasSendScope else { return .reject(.sendScopeDenied) }
        guard context.sessionWritesEnabled else { return .reject(.sessionWritesDisabled) }
        guard context.isBoundToLiveSurface else { return .reject(.notBound) }
        // A local draft always records the open prompt it replaced; without
        // one there is no provider prompt to reopen.
        guard case .localDraft(let draftEpoch) = state.availability,
              let openEpoch = state.invalidatedOpenEpoch else {
            return .reject(.noLocalDraft)
        }
        guard draftEpoch == expectedDraftEpoch else { return .reject(.draftChanged) }
        state.availability = .openPrompt(epoch: openEpoch)
        state.invalidatedOpenEpoch = nil
        state.localInputTurnEpoch = nil
        statesByConversation[conversationID] = state
        return .released(openEpoch: openEpoch)
    }

    public func turnEpoch(for conversationID: RemoteConversationID) -> RemoteInputEpoch? {
        statesByConversation[conversationID]?.turnEpoch
    }

    /// Whether a steer presenting the current turn epoch would pass the
    /// turn-level checks: a turn is running and local input has not touched it.
    public func canSteer(for conversationID: RemoteConversationID) -> Bool {
        guard let state = statesByConversation[conversationID],
              let turnEpoch = state.turnEpoch else { return false }
        return state.localInputTurnEpoch != turnEpoch
    }

    public func availability(for conversationID: RemoteConversationID) -> RemoteInputAvailability {
        statesByConversation[conversationID]?.availability ?? .unavailable(reason: .unknownProviderState)
    }

    public func hasProcessed(_ clientRequestID: String, for conversationID: RemoteConversationID) -> Bool {
        statesByConversation[conversationID]?.processedRequestSet.contains(clientRequestID) ?? false
    }

    // MARK: - Gate

    /// Decides whether `request` may be delivered right now. Pure — it mutates
    /// nothing except to answer; the host calls `markDelivered` after a
    /// successful delivery to close the idempotency window.
    public func evaluate(
        _ request: RemoteMessageSendRequest,
        context: DeliveryContext
    ) -> Decision {
        guard let state = statesByConversation[request.conversationID] else {
            return .reject(.notBound)
        }
        if state.processedRequestSet.contains(request.clientRequestID) {
            return .duplicate
        }
        if let rejection = Self.commonRejection(for: request, context: context) {
            return .reject(rejection)
        }

        switch state.availability {
        case .openPrompt(let epoch):
            guard request.expectedInputEpoch == epoch else {
                return .reject(.epochMismatch)
            }
            return .accept(epoch: epoch)
        case .localDraft:
            return .reject(.localDraftPresent)
        case .pendingInteraction:
            return .reject(.pendingInteraction)
        case .unavailable:
            return .reject(.promptNotOpen)
        }
    }

    /// Decides whether a steer may be typed into the running turn right now.
    /// Shares every device, session, surface, and text check with `evaluate`;
    /// the turn checks replace the open-prompt checks.
    public func evaluateSteer(
        _ request: RemoteMessageSendRequest,
        context: DeliveryContext
    ) -> Decision {
        guard let state = statesByConversation[request.conversationID] else {
            return .reject(.notBound)
        }
        if state.processedRequestSet.contains(request.clientRequestID) {
            return .duplicate
        }
        if let rejection = Self.commonRejection(for: request, context: context) {
            return .reject(rejection)
        }
        guard let turnEpoch = state.turnEpoch else {
            return .reject(.notWorking)
        }
        guard request.expectedInputEpoch == turnEpoch else {
            return .reject(.turnMismatch)
        }
        guard state.localInputTurnEpoch != turnEpoch else {
            return .reject(.steerUnavailable)
        }
        return .accept(epoch: turnEpoch)
    }

    /// Decides whether the interrupt key may be sent for the turn the client
    /// names. Text checks do not apply; the turn checks match `evaluateSteer`
    /// except that local input does not block a stop.
    public func evaluateInterrupt(
        for conversationID: RemoteConversationID,
        expectedTurnEpoch: RemoteInputEpoch,
        context: DeliveryContext
    ) -> InterruptDecision {
        guard let state = statesByConversation[conversationID] else {
            return .reject(.notBound)
        }
        guard context.deviceHasSendScope else { return .reject(.sendScopeDenied) }
        guard context.sessionWritesEnabled else { return .reject(.sessionWritesDisabled) }
        guard context.isBoundToLiveSurface else { return .reject(.notBound) }
        guard context.isSurfaceReadyForInput else { return .reject(.surfaceUnavailable) }
        guard let turnEpoch = state.turnEpoch else { return .reject(.notWorking) }
        guard expectedTurnEpoch == turnEpoch else { return .reject(.turnMismatch) }
        return .accept(turnEpoch: turnEpoch)
    }

    /// The device, session, surface, and text checks every delivery mode
    /// shares, so a queue enqueue refuses the same requests a live send would.
    public static func commonRejection(
        for request: RemoteMessageSendRequest,
        context: DeliveryContext
    ) -> RemoteMessageRejectionReason? {
        guard context.deviceHasSendScope else { return .sendScopeDenied }
        guard context.sessionWritesEnabled else { return .sessionWritesDisabled }
        guard RemoteAttachmentPolicy.validationError(for: request.attachments, validateContents: false) == nil else {
            return .invalidAttachments
        }
        guard !request.attachments.isEmpty || request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .emptyText
        }
        guard context.isBoundToLiveSurface else { return .notBound }
        guard context.isSurfaceReadyForInput else { return .surfaceUnavailable }
        return nil
    }

    /// Records a delivered request as processed (bounded LRU) and marks the
    /// prompt consumed. Call exactly once, immediately after a successful
    /// delivery for a request that `evaluate` accepted.
    public mutating func markDelivered(_ request: RemoteMessageSendRequest) {
        markProcessed(request)
    }

    /// Records a steer as processed without touching prompt availability:
    /// the turn keeps running and the prompt stays closed as before.
    public mutating func markSteerDelivered(_ request: RemoteMessageSendRequest) {
        guard var state = statesByConversation[request.conversationID] else { return }
        Self.insertProcessed(request.clientRequestID, into: &state)
        statesByConversation[request.conversationID] = state
    }

    /// A steer whose text reached the terminal but whose submit did not: the
    /// composer may hold that text. Treat it exactly like local typing in the
    /// turn, so no further steer appends to it and the next prompt opens as a
    /// local draft until the provider shows a newer prompt generation.
    public mutating func markSteerUncertain(_ request: RemoteMessageSendRequest) {
        guard var state = statesByConversation[request.conversationID] else { return }
        Self.insertProcessed(request.clientRequestID, into: &state)
        state.localInputTurnEpoch = state.turnEpoch ?? request.expectedInputEpoch
        statesByConversation[request.conversationID] = state
    }

    /// Closes the prompt and idempotency window after terminal delivery became
    /// uncertain (for example, text was injected but the submit key failed).
    /// Retrying could append or submit the text twice, so uncertainty is still
    /// a processed request for duplicate suppression.
    public mutating func markUncertain(_ request: RemoteMessageSendRequest) {
        markProcessed(request)
    }

    private static func insertProcessed(_ clientRequestID: String, into state: inout ConversationState) {
        if state.processedRequestSet.insert(clientRequestID).inserted {
            state.processedRequestIDs.append(clientRequestID)
            if state.processedRequestIDs.count > Self.idempotencyCapacityPerConversation {
                let evicted = state.processedRequestIDs.removeFirst()
                state.processedRequestSet.remove(evicted)
            }
        }
    }

    private mutating func markProcessed(_ request: RemoteMessageSendRequest) {
        guard var state = statesByConversation[request.conversationID] else { return }
        Self.insertProcessed(request.clientRequestID, into: &state)
        // Delivery consumed the prompt; it is no longer open for another send.
        state.invalidatedOpenEpoch = request.expectedInputEpoch
        state.availability = .unavailable(reason: .working)
        statesByConversation[request.conversationID] = state
    }

    public mutating func removeConversation(_ conversationID: RemoteConversationID) {
        statesByConversation.removeValue(forKey: conversationID)
    }
}
