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

    public init(runID: RemoteProjectionRunID = RemoteProjectionRunID()) {
        self.runID = runID
    }

    // MARK: - Host mutation surface

    public func registerConversation(
        _ conversationID: RemoteConversationID,
        descriptor: ConversationDescriptor,
        bindingID: UUID,
        at date: Date
    ) {
        guard projectorsByID[conversationID] == nil else {
            descriptorsByID[conversationID] = descriptor
            return
        }
        projectorsByID[conversationID] = ConversationProjector(
            conversationID: conversationID,
            provider: descriptor.provider,
            bindingID: bindingID,
            at: date
        )
        descriptorsByID[conversationID] = descriptor
        conversationOrder.append(conversationID)
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

    @discardableResult
    public func noteBinding(
        for conversationID: RemoteConversationID,
        reason: ConversationBindingChangeReason,
        providerSessionID: String? = nil,
        providerSessionFilePath: String? = nil,
        bindingID: UUID,
        at date: Date
    ) -> [ConversationEvent] {
        guard var projector = projectorsByID[conversationID] else { return [] }
        let emitted = projector.noteBinding(
            reason: reason,
            providerSessionID: providerSessionID,
            providerSessionFilePath: providerSessionFilePath,
            bindingID: bindingID,
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
            at: date
        )
        replacement.noteBinding(reason: .projectionRebuilt, bindingID: bindingID, at: date)
        projectorsByID[conversationID] = replacement
    }

    public func removeConversation(_ conversationID: RemoteConversationID) {
        projectorsByID.removeValue(forKey: conversationID)
        descriptorsByID.removeValue(forKey: conversationID)
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
        let clampedLimit = max(1, min(limit, Self.defaultPageLimit))
        let events = projector.events
            .filter { $0.sequence > afterSequence }
            .prefix(clampedLimit)

        return .page(ConversationEventPage(
            conversationID: conversationID,
            projectionRunID: runID,
            projectionGeneration: projector.generation,
            events: Array(events),
            latestSequence: projector.latestSequence
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
            state: projector.state,
            inputAvailability: projector.inputAvailability,
            projectionGeneration: projector.generation,
            latestSequence: projector.latestSequence,
            updatedAt: projector.updatedAt
        )
    }
}
