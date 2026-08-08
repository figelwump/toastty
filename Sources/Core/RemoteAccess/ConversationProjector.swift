import Foundation

/// Per-conversation projection state machine.
///
/// Consumes normalized `ProviderTranscriptObservation`s plus host-side runtime
/// binding facts, and produces the ordered `ConversationEvent` log alongside
/// live state, input availability, and pending interactions. A projector is a
/// value type: rebuilding from the same observations reproduces the same
/// provider-derived events (see `ConversationEventKind.isProviderDerived`).
///
/// Ingestion is idempotent within a run: every observation's fingerprint is
/// remembered, so re-reading a provider file from the start (watcher restart)
/// or replayed records after compaction append nothing new.
public struct ConversationProjector: Sendable {
    public let conversationID: RemoteConversationID
    public let provider: AgentKind
    public private(set) var generation: UInt64
    public private(set) var events: [ConversationEvent]
    public private(set) var state: RemoteSessionState
    public private(set) var inputAvailability: RemoteInputAvailability
    public private(set) var pendingInteractions: [RemotePendingInteraction]
    public private(set) var providerSessionID: String?
    public private(set) var providerSessionFilePath: String?
    public private(set) var updatedAt: Date

    private var currentEpoch: RemoteInputEpoch
    private var seenFingerprints: Set<String>
    private var runtimeEventCounter: UInt64
    private var nextSequence: UInt64

    public var latestSequence: UInt64 {
        nextSequence - 1
    }

    public init(
        conversationID: RemoteConversationID,
        provider: AgentKind,
        generation: UInt64 = 0,
        bindingID: UUID,
        at date: Date
    ) {
        self.conversationID = conversationID
        self.provider = provider
        self.generation = generation
        self.events = []
        self.state = .starting
        self.inputAvailability = .unavailable(reason: .starting)
        self.pendingInteractions = []
        self.providerSessionID = nil
        self.providerSessionFilePath = nil
        self.updatedAt = date
        self.currentEpoch = RemoteInputEpoch(bindingID: bindingID, counter: 0)
        self.seenFingerprints = []
        self.runtimeEventCounter = 0
        self.nextSequence = 1
    }

    // MARK: - Provider observations

    @discardableResult
    public mutating func ingest(_ observation: ProviderTranscriptObservation) -> [ConversationEvent] {
        guard seenFingerprints.insert(observation.fingerprint).inserted else {
            return []
        }

        var emitted: [ConversationEvent] = []
        switch observation.payload {
        case .transcript(let payload):
            guard payload.kind.isProviderDerived else { return [] }
            emitted.append(appendProviderEvent(payload, from: observation))
            if case .userMessage = payload {
                // A user message means the prompt was consumed; treat it as an
                // authoritative prompt-closed signal even before task_started.
                transition(to: .working, availability: .unavailable(reason: .working), at: observation.timestamp, emitting: &emitted)
            }
            if case .toolFinished(let finished) = payload {
                resolveInteractions(matchingCallID: finished.callID, at: observation.timestamp, emitting: &emitted)
            }

        case .interactionPresented(let interactionObservation):
            let interaction = RemotePendingInteraction(
                id: Self.interactionID(provider: provider, observation: interactionObservation, fingerprint: observation.fingerprint),
                kind: interactionObservation.kind,
                providerCallID: interactionObservation.providerCallID,
                providerApprovalID: interactionObservation.providerApprovalID,
                prompt: interactionObservation.prompt,
                options: interactionObservation.options,
                inputEpoch: currentEpoch,
                presentedAt: observation.timestamp
            )
            pendingInteractions.append(interaction)
            emitted.append(appendProviderEvent(.interactionPresented(interaction), from: observation))
            transition(
                to: .awaitingInput,
                availability: .pendingInteraction(interactionIDs: pendingInteractions.map(\.id)),
                at: observation.timestamp,
                emitting: &emitted
            )

        case .turnStarted:
            supersedePendingInteractions(at: observation.timestamp, emitting: &emitted)
            transition(to: .working, availability: .unavailable(reason: .working), at: observation.timestamp, emitting: &emitted)

        case .turnEnded(_, let reason):
            supersedePendingInteractions(at: observation.timestamp, emitting: &emitted)
            switch reason {
            case .completed:
                currentEpoch = currentEpoch.next()
                transition(to: .awaitingInput, availability: .openPrompt(epoch: currentEpoch), at: observation.timestamp, emitting: &emitted)
            case .aborted:
                // Conservative: an aborted turn usually returns to the
                // composer, but that is inferred, not authoritative. Unknown
                // means read-only until the next provider transition.
                transition(to: .interrupted, availability: .unavailable(reason: .interrupted), at: observation.timestamp, emitting: &emitted)
            }

        case .providerSessionObserved(let sessionID):
            providerSessionID = sessionID

        case .contextCompacted:
            break
        }

        updatedAt = max(updatedAt, observation.timestamp)
        return emitted
    }

    // MARK: - Host runtime facts

    /// Records a runtime binding change decided by the host (launch, native
    /// resume, runtime exit, projection rebuild). Every binding change mints a
    /// fresh epoch under the supplied binding ID, so no epoch issued before the
    /// change can match afterwards.
    @discardableResult
    public mutating func noteBinding(
        reason: ConversationBindingChangeReason,
        providerSessionID: String? = nil,
        providerSessionFilePath: String? = nil,
        bindingID: UUID,
        at date: Date
    ) -> [ConversationEvent] {
        currentEpoch = RemoteInputEpoch(bindingID: bindingID, counter: 0)
        if let providerSessionID {
            self.providerSessionID = providerSessionID
        }
        if let providerSessionFilePath {
            self.providerSessionFilePath = providerSessionFilePath
        }

        var emitted: [ConversationEvent] = []
        emitted.append(appendRuntimeEvent(
            .sessionBindingChanged(ConversationSessionBindingChangedPayload(
                reason: reason,
                providerSessionID: providerSessionID ?? self.providerSessionID,
                providerSessionFilePath: providerSessionFilePath ?? self.providerSessionFilePath
            )),
            at: date
        ))

        switch reason {
        case .runtimeBound, .runtimeResumed:
            transition(to: .starting, availability: .unavailable(reason: .unknownProviderState), at: date, emitting: &emitted)
        case .runtimeEnded:
            supersedePendingInteractions(at: date, emitting: &emitted)
            transition(to: .offline, availability: .unavailable(reason: .offline), at: date, emitting: &emitted)
        case .projectionRebuilt:
            break
        }

        updatedAt = max(updatedAt, date)
        return emitted
    }

    // MARK: - Internals

    private mutating func appendProviderEvent(
        _ payload: ConversationEventPayload,
        from observation: ProviderTranscriptObservation
    ) -> ConversationEvent {
        let event = ConversationEvent(
            conversationID: conversationID,
            sequence: nextSequence,
            eventID: "\(provider.rawValue):\(observation.fingerprint)",
            timestamp: observation.timestamp,
            provider: provider,
            providerIdentity: observation.providerIdentity,
            turnID: observation.turnID,
            payload: payload
        )
        nextSequence += 1
        events.append(event)
        return event
    }

    private mutating func appendRuntimeEvent(
        _ payload: ConversationEventPayload,
        at date: Date
    ) -> ConversationEvent {
        runtimeEventCounter += 1
        let event = ConversationEvent(
            conversationID: conversationID,
            sequence: nextSequence,
            eventID: "rt:\(generation):\(runtimeEventCounter)",
            timestamp: date,
            provider: provider,
            payload: payload
        )
        nextSequence += 1
        events.append(event)
        return event
    }

    private mutating func transition(
        to newState: RemoteSessionState,
        availability newAvailability: RemoteInputAvailability,
        at date: Date,
        emitting emitted: inout [ConversationEvent]
    ) {
        guard newState != state || Self.availabilityMateriallyDiffers(inputAvailability, newAvailability) else {
            return
        }
        state = newState
        inputAvailability = newAvailability
        emitted.append(appendRuntimeEvent(
            .statusChanged(ConversationStatusChangedPayload(state: newState, inputAvailability: newAvailability)),
            at: date
        ))
    }

    private mutating func resolveInteractions(
        matchingCallID callID: String,
        at date: Date,
        emitting emitted: inout [ConversationEvent]
    ) {
        let matching = pendingInteractions.filter { $0.providerCallID == callID }
        guard matching.isEmpty == false else { return }
        pendingInteractions.removeAll { $0.providerCallID == callID }
        for interaction in matching {
            emitted.append(appendRuntimeEvent(
                .interactionResolved(ConversationInteractionResolvedPayload(
                    interactionID: interaction.id,
                    resolution: .resolved
                )),
                at: date
            ))
        }
        if pendingInteractions.isEmpty, case .pendingInteraction = inputAvailability {
            transition(to: .working, availability: .unavailable(reason: .working), at: date, emitting: &emitted)
        } else if pendingInteractions.isEmpty == false {
            transition(
                to: .awaitingInput,
                availability: .pendingInteraction(interactionIDs: pendingInteractions.map(\.id)),
                at: date,
                emitting: &emitted
            )
        }
    }

    private mutating func supersedePendingInteractions(
        at date: Date,
        emitting emitted: inout [ConversationEvent]
    ) {
        guard pendingInteractions.isEmpty == false else { return }
        let superseded = pendingInteractions
        pendingInteractions = []
        for interaction in superseded {
            emitted.append(appendRuntimeEvent(
                .interactionResolved(ConversationInteractionResolvedPayload(
                    interactionID: interaction.id,
                    resolution: .superseded
                )),
                at: date
            ))
        }
    }

    private static func availabilityMateriallyDiffers(
        _ current: RemoteInputAvailability,
        _ new: RemoteInputAvailability
    ) -> Bool {
        switch (current, new) {
        case (.unavailable(let currentReason), .unavailable(let newReason)):
            return currentReason != newReason
        case (.openPrompt(let currentEpoch), .openPrompt(let newEpoch)):
            return currentEpoch != newEpoch
        case (.pendingInteraction(let currentIDs), .pendingInteraction(let newIDs)):
            return currentIDs != newIDs
        case (.localDraft, .localDraft):
            // Epoch churn while drafting is intentionally not an event; the
            // live epoch is only observable through snapshots.
            return false
        default:
            return true
        }
    }

    private static func interactionID(
        provider: AgentKind,
        observation: ProviderInteractionObservation,
        fingerprint: String
    ) -> RemotePendingInteraction.ID {
        if let approvalID = observation.providerApprovalID {
            return RemotePendingInteraction.ID(rawValue: "\(provider.rawValue):approval:\(approvalID)")
        }
        if let callID = observation.providerCallID {
            return RemotePendingInteraction.ID(rawValue: "\(provider.rawValue):call:\(callID)")
        }
        return RemotePendingInteraction.ID(rawValue: "\(provider.rawValue):fp:\(fingerprint)")
    }
}
