import RemoteProtocol
import Foundation

/// In-memory, rebuildable projection cache over all conversations, and the
/// Foundation-phase implementation of `RemoteSessionFacade`.
///
/// The store owns one `ConversationProjector` per conversation plus the
/// presentation metadata (title, workspace/panel placement) the host supplies.
/// It is deliberately not thread-safe: the App hosts it on the main actor next
/// to `SessionRuntimeStore`; tests drive it synchronously. Everything here can
/// be discarded at any time and rebuilt from provider files — deleting a
/// conversation deletes its cache entries and nothing else.
public final class RemoteConversationProjectionStore {
    public struct ConversationDescriptor: Equatable, Sendable {
        public var provider: AgentKind
        public var title: String
        public var placement: RemoteConversationPlacement
        public var cwd: String?

        public init(
            provider: AgentKind,
            title: String,
            placement: RemoteConversationPlacement = RemoteConversationPlacement(),
            cwd: String? = nil
        ) {
            self.provider = provider
            self.title = title
            self.placement = placement
            self.cwd = cwd
        }
    }

    public let runID: RemoteProjectionRunID
    public static let defaultPageLimit = 200

    private var projectorsByID: [RemoteConversationID: ConversationProjector] = [:]
    private var descriptorsByID: [RemoteConversationID: ConversationDescriptor] = [:]
    private var conversationOrder: [RemoteConversationID] = []
    private var nextGenerationByConversationID: [RemoteConversationID: UInt64] = [:]
    private var linkedFileReferencesByID: [RemoteConversationID: LinkedFileReferences] = [:]
    private let eventRetentionLimit: Int
    private let fingerprintRetentionLimit: Int
    private let linkedFileReferenceRetentionLimit: Int

    public init(
        runID: RemoteProjectionRunID = RemoteProjectionRunID(),
        eventRetentionLimit: Int = 10_000,
        fingerprintRetentionLimit: Int = 20_000,
        linkedFileReferenceRetentionLimit: Int = 20_000
    ) {
        self.runID = runID
        self.eventRetentionLimit = max(1, eventRetentionLimit)
        self.fingerprintRetentionLimit = max(1, fingerprintRetentionLimit)
        self.linkedFileReferenceRetentionLimit = max(1, linkedFileReferenceRetentionLimit)
    }

    public var registeredConversationIDs: Set<RemoteConversationID> {
        Set(projectorsByID.keys)
    }

    // MARK: - Host mutation surface

    public func registerConversation(
        _ conversationID: RemoteConversationID,
        descriptor: ConversationDescriptor,
        bindingID: UUID,
        runtimeBound: Bool = true,
        at date: Date
    ) {
        guard projectorsByID[conversationID] == nil else {
            descriptorsByID[conversationID] = descriptor
            return
        }
        projectorsByID[conversationID] = ConversationProjector(
            conversationID: conversationID,
            provider: descriptor.provider,
            generation: nextGenerationByConversationID.removeValue(forKey: conversationID) ?? 0,
            bindingID: bindingID,
            runtimeBound: runtimeBound,
            eventRetentionLimit: eventRetentionLimit,
            fingerprintRetentionLimit: fingerprintRetentionLimit,
            at: date
        )
        descriptorsByID[conversationID] = descriptor
        conversationOrder.append(conversationID)
    }

    public func isConversationRegistered(_ conversationID: RemoteConversationID) -> Bool {
        projectorsByID[conversationID] != nil
    }

    public func projectorState(for conversationID: RemoteConversationID) -> ConversationProjector? {
        projectorsByID[conversationID]
    }

    public func updateDescriptor(
        _ conversationID: RemoteConversationID,
        descriptor: ConversationDescriptor
    ) {
        guard projectorsByID[conversationID] != nil else { return }
        descriptorsByID[conversationID] = descriptor
    }

    @discardableResult
    public func ingest(
        _ observations: [ProviderTranscriptObservation],
        for conversationID: RemoteConversationID
    ) -> [ConversationEvent] {
        guard var projector = projectorsByID[conversationID] else { return [] }
        var emitted: [ConversationEvent] = []
        for observation in observations {
            emitted.append(contentsOf: projector.ingest(observation))
        }
        projectorsByID[conversationID] = projector
        return emitted
    }

    // MARK: - Linked file references

    /// The local file references linked from assistant messages in
    /// `observations`, as the phone's transcript view would derive them.
    /// Pure and Markdown-parsing, so callers with large batches run it off
    /// the main actor and pass the result to `noteLinkedFileReferences`.
    public static func linkedFileReferences(
        in observations: some Sequence<ProviderTranscriptObservation>
    ) -> [String] {
        observations.flatMap { observation -> [String] in
            guard case .transcript(.assistantMessage(let message)) = observation.payload else {
                return []
            }
            return RemotePreviewLinkReference.localFileReferences(inMarkdown: message.text)
        }
    }

    /// Records references the agent linked in this conversation. They outlive
    /// event trimming, because a phone can still show a link whose event the
    /// Mac has dropped; only a new generation or removal discards them.
    public func noteLinkedFileReferences(
        _ references: [String], for conversationID: RemoteConversationID
    ) {
        guard projectorsByID[conversationID] != nil, references.isEmpty == false else { return }
        linkedFileReferencesByID[conversationID, default: .init()].insert(
            references, retentionLimit: linkedFileReferenceRetentionLimit)
    }

    /// Whether the Mac's own transcript data for this conversation links
    /// `reference`. A requesting device's claim never reaches this set.
    public func isFileReferenceLinked(
        _ reference: String, in conversationID: RemoteConversationID
    ) -> Bool {
        linkedFileReferencesByID[conversationID]?.references.contains(reference) ?? false
    }

    private struct LinkedFileReferences {
        private(set) var references: Set<String> = []
        private var insertionOrder: [String] = []

        mutating func insert(_ newReferences: [String], retentionLimit: Int) {
            for reference in newReferences where references.insert(reference).inserted {
                insertionOrder.append(reference)
            }
            // Batched like fingerprint trimming, so eviction stays amortized.
            guard insertionOrder.count > retentionLimit + max(1, retentionLimit / 10) else { return }
            let removalCount = insertionOrder.count - retentionLimit
            for reference in insertionOrder.prefix(removalCount) {
                references.remove(reference)
            }
            insertionOrder.removeFirst(removalCount)
        }
    }

    @discardableResult
    public func noteBinding(
        for conversationID: RemoteConversationID,
        reason: ConversationBindingChangeReason,
        providerSessionID: String? = nil,
        providerSessionFilePath: String? = nil,
        clearsProviderSessionFilePath: Bool = false,
        bindingID: UUID,
        at date: Date
    ) -> [ConversationEvent] {
        guard var projector = projectorsByID[conversationID] else { return [] }
        let emitted = projector.noteBinding(
            reason: reason,
            providerSessionID: providerSessionID,
            providerSessionFilePath: providerSessionFilePath,
            clearsProviderSessionFilePath: clearsProviderSessionFilePath,
            bindingID: bindingID,
            at: date
        )
        projectorsByID[conversationID] = projector
        return emitted
    }

    public func clearProviderSessionFilePath(for conversationID: RemoteConversationID) {
        guard var projector = projectorsByID[conversationID] else { return }
        projector.clearProviderSessionFilePath()
        projectorsByID[conversationID] = projector
    }

    @discardableResult
    public func bootstrapConfirmedOpenPrompt(
        for conversationID: RemoteConversationID,
        at date: Date
    ) -> [ConversationEvent] {
        guard var projector = projectorsByID[conversationID] else { return [] }
        let emitted = projector.bootstrapConfirmedOpenPrompt(at: date)
        projectorsByID[conversationID] = projector
        return emitted
    }

    @discardableResult
    public func invalidateConfirmedOpenPrompt(
        for conversationID: RemoteConversationID,
        expectedEpoch: RemoteInputEpoch,
        state: RemoteSessionState,
        reason: RemoteInputUnavailableReason,
        at date: Date
    ) -> [ConversationEvent] {
        guard var projector = projectorsByID[conversationID] else { return [] }
        let emitted = projector.invalidateConfirmedOpenPrompt(
            expectedEpoch: expectedEpoch,
            state: state,
            reason: reason,
            at: date
        )
        projectorsByID[conversationID] = projector
        return emitted
    }

    @discardableResult
    public func completePromptStabilization(
        for conversationID: RemoteConversationID,
        token: ConversationPromptStabilizationToken,
        at date: Date
    ) -> [ConversationEvent] {
        guard var projector = projectorsByID[conversationID] else { return [] }
        let emitted = projector.completePromptStabilization(token: token, at: date)
        projectorsByID[conversationID] = projector
        return emitted
    }

    @discardableResult
    public func cancelPromptStabilization(
        for conversationID: RemoteConversationID
    ) -> Bool {
        guard var projector = projectorsByID[conversationID] else { return false }
        let didCancel = projector.cancelPromptStabilization()
        projectorsByID[conversationID] = projector
        return didCancel
    }

    @discardableResult
    public func noteSendDeliveryUnconfirmed(
        for conversationID: RemoteConversationID,
        clientRequestID: String,
        at date: Date
    ) -> [ConversationEvent] {
        guard var projector = projectorsByID[conversationID] else { return [] }
        let emitted = projector.noteSendDeliveryUnconfirmed(
            clientRequestID: clientRequestID,
            at: date
        )
        projectorsByID[conversationID] = projector
        return emitted
    }

    /// Discards one conversation's sequence space (unreconcilable provider
    /// rewrite) and starts a fresh generation. Existing cursors for this
    /// conversation become invalid; other conversations are untouched. The
    /// caller re-ingests the provider file afterwards.
    public func forceResnapshot(
        for conversationID: RemoteConversationID,
        bindingID: UUID,
        at date: Date
    ) {
        guard let previous = projectorsByID[conversationID],
              let descriptor = descriptorsByID[conversationID] else {
            return
        }
        var replacement = ConversationProjector(
            conversationID: conversationID,
            provider: descriptor.provider,
            generation: previous.generation + 1,
            bindingID: bindingID,
            runtimeBound: previous.isRuntimeBound,
            eventRetentionLimit: previous.eventRetentionLimit,
            fingerprintRetentionLimit: previous.fingerprintRetentionLimit,
            // A projection rebuild is not a new runtime binding. Preserve the
            // original authority boundary so replayed events from this live
            // binding can reconstruct its current state.
            at: previous.providerAuthorityEstablishedAt ?? date
        )
        replacement.noteBinding(reason: .projectionRebuilt, bindingID: bindingID, at: date)
        projectorsByID[conversationID] = replacement
        // The caller re-ingests the provider file, which rebuilds the grants
        // from the transcript the new generation actually contains.
        linkedFileReferencesByID.removeValue(forKey: conversationID)
    }

    public func removeConversation(_ conversationID: RemoteConversationID) {
        if let projector = projectorsByID.removeValue(forKey: conversationID) {
            nextGenerationByConversationID[conversationID] = projector.generation + 1
        }
        descriptorsByID.removeValue(forKey: conversationID)
        linkedFileReferencesByID.removeValue(forKey: conversationID)
        conversationOrder.removeAll { $0 == conversationID }
    }

    public func pendingInteractions(for conversationID: RemoteConversationID) -> [RemotePendingInteraction] {
        projectorsByID[conversationID]?.pendingInteractions ?? []
    }
}

// MARK: - RemoteSessionFacade

extension RemoteConversationProjectionStore: RemoteSessionFacade {
    public func sessionList(at date: Date) -> RemoteSessionListSnapshot {
        let summaries = conversationOrder.compactMap { conversationID in
            makeSummary(for: conversationID)
        }
        return RemoteSessionListSnapshot(
            projectionRunID: runID,
            conversations: summaries,
            generatedAt: date
        )
    }

    public func conversationSnapshot(
        for conversationID: RemoteConversationID,
        at date: Date
    ) -> RemoteConversationSnapshot? {
        guard let summary = makeSummary(for: conversationID),
              let projector = projectorsByID[conversationID] else {
            return nil
        }
        return RemoteConversationSnapshot(
            summary: summary,
            pendingInteractions: projector.pendingInteractions
        )
    }

    public func conversationEvents(
        for conversationID: RemoteConversationID,
        after cursor: ConversationEventCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        guard let projector = projectorsByID[conversationID] else {
            return .conversationNotFound
        }
        if let cursor {
            guard cursor.projectionRunID == runID,
                  cursor.projectionGeneration == projector.generation else {
                return .resnapshotRequired
            }
        }

        let afterSequence = cursor?.afterSequence ?? 0
        if cursor != nil, afterSequence < projector.firstAvailableSequence - 1 {
            return .resnapshotRequired
        }
        let clampedLimit = max(1, min(limit, Self.defaultPageLimit))
        let events = projector.retainedEvents(afterSequence: afterSequence, limit: clampedLimit)

        return .page(ConversationEventPage(
            conversationID: conversationID,
            projectionRunID: runID,
            projectionGeneration: projector.generation,
            events: events,
            latestSequence: projector.latestSequence,
            firstAvailableSequence: projector.firstAvailableSequence,
            historyTruncated: projector.firstAvailableSequence > 1
        ))
    }

    public func conversationEvents(
        for conversationID: RemoteConversationID,
        before cursor: ConversationEventBackwardCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        guard let projector = projectorsByID[conversationID] else {
            return .conversationNotFound
        }
        let clampedLimit = max(1, min(limit, Self.defaultPageLimit))
        let events: [ConversationEvent]
        if let cursor {
            guard cursor.projectionRunID == runID,
                  cursor.projectionGeneration == projector.generation else {
                return .resnapshotRequired
            }
            let latestSequence = projector.latestSequence
            if latestSequence < UInt64.max,
               cursor.beforeSequence > latestSequence + 1 {
                return .invalidRequest
            }
            events = projector.retainedEvents(
                beforeSequence: cursor.beforeSequence,
                limit: clampedLimit
            )
        } else {
            events = projector.retainedTail(limit: clampedLimit)
        }

        return .page(ConversationEventPage(
            conversationID: conversationID,
            projectionRunID: runID,
            projectionGeneration: projector.generation,
            events: events,
            latestSequence: projector.latestSequence,
            firstAvailableSequence: projector.firstAvailableSequence,
            // Conversation-scoped: true when earlier events have fallen out of
            // the host's bounded retained projection, independent of page mode.
            historyTruncated: projector.firstAvailableSequence > 1
        ))
    }

    private func makeSummary(for conversationID: RemoteConversationID) -> RemoteConversationSummary? {
        guard let projector = projectorsByID[conversationID],
              let descriptor = descriptorsByID[conversationID] else {
            return nil
        }
        return RemoteConversationSummary(
            conversationID: conversationID,
            provider: descriptor.provider,
            title: descriptor.title,
            placement: descriptor.placement,
            cwd: descriptor.cwd,
            executionProfile: projector.executionProfile,
            state: projector.state,
            inputAvailability: projector.inputAvailability,
            projectionGeneration: projector.generation,
            latestSequence: projector.latestSequence,
            updatedAt: projector.updatedAt
        )
    }
}
