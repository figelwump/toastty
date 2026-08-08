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
        var processedRequestIDs: [String] = []
        var processedRequestSet: Set<String> = []
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
        var state = statesByConversation[conversationID] ?? ConversationState(availability: availability)

        if case .localDraft(let draftEpoch) = state.availability {
            // Only a genuinely newer open prompt clears the draft: a new
            // runtime binding (different bindingID) always establishes a fresh
            // prompt; within the same binding the counter must have advanced.
            if case .openPrompt(let newEpoch) = availability,
               Self.supersedes(newEpoch, draftEpoch) {
                state.availability = availability
            } else {
                // Keep the draft; provider status is reflected elsewhere.
                state.availability = .localDraft(epoch: draftEpoch)
            }
        } else {
            state.availability = availability
        }
        statesByConversation[conversationID] = state
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

    /// Records that local keyboard/paste/menu input touched the prompt. O(1)
    /// and allocation-free on the hot path: if the prompt was open, it becomes
    /// a local draft under a bumped epoch; otherwise nothing changes.
    public mutating func noteLocalInput(for conversationID: RemoteConversationID) {
        guard var state = statesByConversation[conversationID] else { return }
        if case .openPrompt(let epoch) = state.availability {
            state.availability = .localDraft(epoch: epoch.next())
            statesByConversation[conversationID] = state
        }
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
        guard context.deviceHasSendScope else { return .reject(.sendScopeDenied) }
        guard context.sessionWritesEnabled else { return .reject(.sessionWritesDisabled) }
        guard request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .reject(.emptyText)
        }
        guard context.isBoundToLiveSurface else { return .reject(.notBound) }
        guard context.isSurfaceReadyForInput else { return .reject(.surfaceUnavailable) }

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

    /// Records a delivered request as processed (bounded LRU) and marks the
    /// prompt consumed. Call exactly once, immediately after a successful
    /// delivery for a request that `evaluate` accepted.
    public mutating func markDelivered(_ request: RemoteMessageSendRequest) {
        guard var state = statesByConversation[request.conversationID] else { return }
        if state.processedRequestSet.insert(request.clientRequestID).inserted {
            state.processedRequestIDs.append(request.clientRequestID)
            if state.processedRequestIDs.count > Self.idempotencyCapacityPerConversation {
                let evicted = state.processedRequestIDs.removeFirst()
                state.processedRequestSet.remove(evicted)
            }
        }
        // Delivery consumed the prompt; it is no longer open for another send.
        state.availability = .unavailable(reason: .working)
        statesByConversation[request.conversationID] = state
    }

    public mutating func removeConversation(_ conversationID: RemoteConversationID) {
        statesByConversation.removeValue(forKey: conversationID)
    }
}
