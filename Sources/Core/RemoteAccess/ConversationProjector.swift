import RemoteProtocol
import Foundation

public struct ConversationPromptStabilizationToken: Equatable, Hashable, Sendable {
    public let observationFingerprint: String

    public init(observationFingerprint: String) {
        self.observationFingerprint = observationFingerprint
    }
}

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
    /// Whether a live managed runtime is currently bound. While false, every
    /// transition is forced to offline/read-only: replaying a historical
    /// provider log for an offline conversation must never publish an open
    /// prompt no runtime can honor.
    public private(set) var isRuntimeBound: Bool
    /// Provider observations older than the current runtime binding remain
    /// transcript history, but cannot authorize input for this runtime. This
    /// prevents a completed turn replayed during managed-session restore from
    /// opening a prompt before the resumed provider has emitted live evidence.
    private(set) var providerAuthorityEstablishedAt: Date?
    /// Claude reports turn completion just before its terminal composer has
    /// finished resetting. Keep the next prompt closed until the host finishes
    /// the short stabilization window for this exact completion observation.
    public private(set) var pendingPromptStabilizationToken:
        ConversationPromptStabilizationToken?

    private var currentEpoch: RemoteInputEpoch
    /// A confirmed managed-runtime bootstrap may authorize the first prompt
    /// before the resumed provider emits a new transcript observation. Keep
    /// that escape hatch one-shot for each runtime binding so repeated host
    /// synchronization cannot churn epochs or supersede local input.
    private var didBootstrapConfirmedPromptForCurrentBinding: Bool
    private var seenFingerprints: Set<String>
    private var seenFingerprintOrder: [String]
    private var runtimeEventCounter: UInt64
    private var nextSequence: UInt64
    let eventRetentionLimit: Int
    let fingerprintRetentionLimit: Int

    public var latestSequence: UInt64 {
        nextSequence - 1
    }

    public init(
        conversationID: RemoteConversationID,
        provider: AgentKind,
        generation: UInt64 = 0,
        bindingID: UUID,
        runtimeBound: Bool = true,
        eventRetentionLimit: Int = 10_000,
        fingerprintRetentionLimit: Int = 20_000,
        at date: Date
    ) {
        self.conversationID = conversationID
        self.provider = provider
        self.generation = generation
        self.events = []
        self.isRuntimeBound = runtimeBound
        self.providerAuthorityEstablishedAt = runtimeBound ? date : nil
        self.pendingPromptStabilizationToken = nil
        self.state = runtimeBound ? .starting : .offline
        self.inputAvailability = .unavailable(reason: runtimeBound ? .starting : .offline)
        self.pendingInteractions = []
        self.providerSessionID = nil
        self.providerSessionFilePath = nil
        self.updatedAt = date
        self.currentEpoch = RemoteInputEpoch(bindingID: bindingID, counter: 0)
        self.didBootstrapConfirmedPromptForCurrentBinding = false
        self.seenFingerprints = []
        self.seenFingerprintOrder = []
        self.runtimeEventCounter = 0
        self.nextSequence = 1
        self.eventRetentionLimit = max(1, eventRetentionLimit)
        self.fingerprintRetentionLimit = max(1, fingerprintRetentionLimit)
    }

    // MARK: - Provider observations

    @discardableResult
    public mutating func ingest(_ observation: ProviderTranscriptObservation) -> [ConversationEvent] {
        guard seenFingerprints.insert(observation.fingerprint).inserted else {
            return []
        }
        seenFingerprintOrder.append(observation.fingerprint)
        trimSeenFingerprintsIfNeeded()

        var emitted: [ConversationEvent] = []
        let authorizesCurrentRuntime = observationAuthorizesCurrentRuntime(observation)
        switch observation.payload {
        case .transcript(let payload):
            guard payload.kind.isProviderDerived else { return [] }
            emitted.append(appendProviderEvent(payload, from: observation))
            if authorizesCurrentRuntime, case .userMessage = payload {
                // A user message means the prompt was consumed; treat it as an
                // authoritative prompt-closed signal even before task_started.
                pendingPromptStabilizationToken = nil
                transition(to: .working, availability: .unavailable(reason: .working), at: observation.timestamp, emitting: &emitted)
            }
            if authorizesCurrentRuntime, case .toolFinished(let finished) = payload {
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
            emitted.append(appendProviderEvent(.interactionPresented(interaction), from: observation))
            if authorizesCurrentRuntime {
                pendingPromptStabilizationToken = nil
                pendingInteractions.append(interaction)
                transition(
                    to: .awaitingInput,
                    availability: .pendingInteraction(interactionIDs: pendingInteractions.map(\.id)),
                    at: observation.timestamp,
                    emitting: &emitted
                )
            }

        case .turnStarted:
            if authorizesCurrentRuntime {
                pendingPromptStabilizationToken = nil
                supersedePendingInteractions(at: observation.timestamp, emitting: &emitted)
                transition(to: .working, availability: .unavailable(reason: .working), at: observation.timestamp, emitting: &emitted)
            }

        case .turnEnded(_, let reason):
            if authorizesCurrentRuntime {
                pendingPromptStabilizationToken = nil
                supersedePendingInteractions(at: observation.timestamp, emitting: &emitted)
                switch reason {
                case .completed:
                    if provider == .claude {
                        pendingPromptStabilizationToken = ConversationPromptStabilizationToken(
                            observationFingerprint: observation.fingerprint
                        )
                        transition(
                            to: .awaitingInput,
                            availability: .unavailable(reason: .unknownProviderState),
                            at: observation.timestamp,
                            emitting: &emitted
                        )
                    } else {
                        currentEpoch = currentEpoch.next()
                        transition(to: .awaitingInput, availability: .openPrompt(epoch: currentEpoch), at: observation.timestamp, emitting: &emitted)
                    }
                case .aborted:
                    // Conservative: an aborted turn usually returns to the
                    // composer, but that is inferred, not authoritative. Unknown
                    // means read-only until the next provider transition.
                    transition(to: .interrupted, availability: .unavailable(reason: .interrupted), at: observation.timestamp, emitting: &emitted)
                }
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
        clearsProviderSessionFilePath: Bool = false,
        bindingID: UUID,
        at date: Date
    ) -> [ConversationEvent] {
        pendingPromptStabilizationToken = nil
        currentEpoch = RemoteInputEpoch(bindingID: bindingID, counter: 0)
        switch reason {
        case .runtimeBound, .runtimeResumed, .runtimeEnded:
            didBootstrapConfirmedPromptForCurrentBinding = false
        case .projectionRebuilt:
            break
        }
        if let providerSessionID {
            self.providerSessionID = providerSessionID
        }
        if clearsProviderSessionFilePath {
            self.providerSessionFilePath = nil
        } else if let providerSessionFilePath {
            self.providerSessionFilePath = providerSessionFilePath
        }

        var emitted: [ConversationEvent] = []
        emitted.append(appendRuntimeEvent(
            .sessionBindingChanged(ConversationSessionBindingChangedPayload(
                reason: reason,
                providerSessionID: providerSessionID ?? self.providerSessionID,
                providerSessionFilePath: self.providerSessionFilePath
            )),
            at: date
        ))

        switch reason {
        case .runtimeBound, .runtimeResumed:
            isRuntimeBound = true
            providerAuthorityEstablishedAt = date
            supersedePendingInteractions(at: date, emitting: &emitted)
            transition(to: .starting, availability: .unavailable(reason: .unknownProviderState), at: date, emitting: &emitted)
        case .runtimeEnded:
            isRuntimeBound = false
            providerAuthorityEstablishedAt = nil
            supersedePendingInteractions(at: date, emitting: &emitted)
            transition(to: .offline, availability: .unavailable(reason: .offline), at: date, emitting: &emitted)
        case .projectionRebuilt:
            break
        }

        updatedAt = max(updatedAt, date)
        return emitted
    }

    /// Opens the initial prompt for a managed runtime whose provider process
    /// was confirmed during this app launch, but whose resumed transcript has
    /// not emitted a new lifecycle observation yet.
    ///
    /// Callers must independently prove current-launch ownership and that no
    /// local terminal input occurred since this runtime was bound. Transcript
    /// observations remain authoritative after this one bootstrap transition.
    @discardableResult
    public mutating func bootstrapConfirmedOpenPrompt(at date: Date) -> [ConversationEvent] {
        guard isRuntimeBound,
              didBootstrapConfirmedPromptForCurrentBinding == false,
              pendingPromptStabilizationToken == nil,
              case .unavailable(reason: .unknownProviderState) = inputAvailability else {
            return []
        }

        didBootstrapConfirmedPromptForCurrentBinding = true
        currentEpoch = currentEpoch.next()
        var emitted: [ConversationEvent] = []
        transition(
            to: .awaitingInput,
            availability: .openPrompt(epoch: currentEpoch),
            at: date,
            emitting: &emitted
        )
        updatedAt = max(updatedAt, date)
        return emitted
    }

    /// Opens a Claude prompt only if no prompt-invalidating provider activity,
    /// binding change, or local input invalidated the exact completion being
    /// stabilized. Passive transcript facts may arrive during this window.
    @discardableResult
    public mutating func completePromptStabilization(
        token: ConversationPromptStabilizationToken,
        at date: Date
    ) -> [ConversationEvent] {
        guard provider == .claude,
              isRuntimeBound,
              pendingPromptStabilizationToken == token,
              state == .awaitingInput,
              inputAvailability == .unavailable(reason: .unknownProviderState) else {
            return []
        }

        pendingPromptStabilizationToken = nil
        currentEpoch = currentEpoch.next()
        var emitted: [ConversationEvent] = []
        transition(
            to: .awaitingInput,
            availability: .openPrompt(epoch: currentEpoch),
            at: date,
            emitting: &emitted
        )
        updatedAt = max(updatedAt, date)
        return emitted
    }

    /// Cancels a pending prompt-open transition without claiming a local draft
    /// epoch. The prompt remains read-only until the provider emits another
    /// authoritative lifecycle transition.
    @discardableResult
    public mutating func cancelPromptStabilization() -> Bool {
        guard pendingPromptStabilizationToken != nil else { return false }
        pendingPromptStabilizationToken = nil
        return true
    }

    /// Appends the desktop-owned terminal receipt for a send whose provider
    /// echo did not arrive before the confirmation deadline.
    @discardableResult
    public mutating func noteSendDeliveryUnconfirmed(
        clientRequestID: String,
        at date: Date
    ) -> [ConversationEvent] {
        guard clientRequestID.isEmpty == false else { return [] }
        let event = appendRuntimeEvent(
            .sendDeliveryUnconfirmed(.init(clientRequestID: clientRequestID)),
            at: date
        )
        updatedAt = max(updatedAt, date)
        return [event]
    }

    /// Revokes only the synthetic prompt opened by
    /// `bootstrapConfirmedOpenPrompt`. A host-side status change can therefore
    /// close provisional authority without overwriting a newer prompt opened
    /// by a provider transcript observation.
    @discardableResult
    public mutating func invalidateConfirmedOpenPrompt(
        expectedEpoch: RemoteInputEpoch,
        state: RemoteSessionState,
        reason: RemoteInputUnavailableReason,
        at date: Date
    ) -> [ConversationEvent] {
        guard didBootstrapConfirmedPromptForCurrentBinding,
              inputAvailability == .openPrompt(epoch: expectedEpoch) else {
            return []
        }

        currentEpoch = currentEpoch.next()
        var emitted: [ConversationEvent] = []
        transition(
            to: state,
            availability: .unavailable(reason: reason),
            at: date,
            emitting: &emitted
        )
        updatedAt = max(updatedAt, date)
        return emitted
    }

    /// Removes a historical file association while preserving the projected
    /// transcript. Runtime-bound callers should use `noteBinding` with
    /// `clearsProviderSessionFilePath` so the input epoch is also invalidated.
    mutating func clearProviderSessionFilePath() {
        providerSessionFilePath = nil
    }

    // MARK: - Internals

    private func observationAuthorizesCurrentRuntime(_ observation: ProviderTranscriptObservation) -> Bool {
        guard observation.mayAuthorizeCurrentRuntime,
              isRuntimeBound,
              let providerAuthorityEstablishedAt else { return false }
        return observation.timestamp >= providerAuthorityEstablishedAt
    }

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
        trimEventsIfNeeded()
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
        trimEventsIfNeeded()
        return event
    }

    /// Returns a bounded page without allocating an eager copy of the whole
    /// suffix. Event sequences are strictly increasing inside one generation.
    func retainedEvents(afterSequence: UInt64, limit: Int) -> [ConversationEvent] {
        var lowerBound = 0
        var upperBound = events.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if events[midpoint].sequence <= afterSequence {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        guard lowerBound < events.count else { return [] }
        let endIndex = min(events.count, lowerBound + max(1, limit))
        return Array(events[lowerBound..<endIndex])
    }

    /// Returns the ascending retained prefix immediately before an exclusive
    /// sequence boundary. Work remains bounded by the requested page size.
    func retainedEvents(beforeSequence: UInt64, limit: Int) -> [ConversationEvent] {
        var lowerBound = 0
        var upperBound = events.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if events[midpoint].sequence < beforeSequence {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        guard lowerBound > 0 else { return [] }
        let startIndex = max(0, lowerBound - max(1, limit))
        return Array(events[startIndex..<lowerBound])
    }

    func retainedTail(limit: Int) -> [ConversationEvent] {
        guard events.isEmpty == false else { return [] }
        return Array(events.suffix(max(1, limit)))
    }

    public var firstAvailableSequence: UInt64 {
        events.first?.sequence ?? nextSequence
    }

    var seenFingerprintCountForTesting: Int {
        seenFingerprints.count
    }

    private mutating func trimEventsIfNeeded() {
        let trimBatchSize = max(1, eventRetentionLimit / 10)
        guard events.count > eventRetentionLimit + trimBatchSize else { return }
        events.removeFirst(events.count - eventRetentionLimit)
    }

    private mutating func trimSeenFingerprintsIfNeeded() {
        let trimBatchSize = max(1, fingerprintRetentionLimit / 10)
        guard seenFingerprintOrder.count > fingerprintRetentionLimit + trimBatchSize else { return }
        let removalCount = seenFingerprintOrder.count - fingerprintRetentionLimit
        for fingerprint in seenFingerprintOrder.prefix(removalCount) {
            seenFingerprints.remove(fingerprint)
        }
        seenFingerprintOrder.removeFirst(removalCount)
    }

    private mutating func transition(
        to newState: RemoteSessionState,
        availability newAvailability: RemoteInputAvailability,
        at date: Date,
        emitting emitted: inout [ConversationEvent]
    ) {
        var newState = newState
        var newAvailability = newAvailability
        if isRuntimeBound == false {
            newState = .offline
            newAvailability = .unavailable(reason: .offline)
        }
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
