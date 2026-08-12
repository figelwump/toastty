import Foundation
import Observation
import RemoteProtocol
import ToasttyMobileDomain

enum LiveConversationChange: Equatable, Sendable {
    case initial
    case append
    case prepend
    case rebuild
    case metadataOnly
}

enum LiveConversationPhase: Equatable, Sendable {
    case idle
    case loading
    case live
    case resynchronizing(reason: ConversationResnapshotReason?)
    case stale
    case failed
}

protocol LiveConversationRuntime: Sendable {
    func currentState() async -> ConversationRuntime.State
    func states() async -> AsyncStream<ConversationRuntime.State>
    func sendReconciliationStates() async -> AsyncStream<SendReconciliationState>
}

extension ConversationRuntime: LiveConversationRuntime {
    func sendReconciliationStates() async -> AsyncStream<SendReconciliationState> {
        await sendReconciliation.states()
    }
}

/// A value-only main-actor projection of one domain conversation runtime.
///
/// The domain actor remains authoritative for ordering, cursor advancement,
/// gaps, and resnapshots. This controller only publishes stable values for the
/// selected sheet and classifies how its rendered event list changed.
@MainActor
@Observable
final class LiveConversationController {
    let conversationID: UUID

    private(set) var events: [CompatibleConversationEvent] = []
    private(set) var phase: LiveConversationPhase = .idle
    private(set) var runtimePhase: ConversationRuntimePhase = .idle
    private(set) var change: LiveConversationChange = .initial
    private(set) var cursor: ConversationEventCursor?
    private(set) var projectionRunID: RemoteProjectionRunID?
    private(set) var projectionGeneration: UInt64?
    private(set) var latestSequence: UInt64 = 0
    private(set) var firstAvailableSequence: UInt64?
    private(set) var historyTruncated = false
    private(set) var hasOlder = false
    private(set) var isLoadingOlder = false
    private(set) var prependAnchorID: ToasttyTranscriptRowID?
    private(set) var transcriptPresentation: ToasttyConversationPresentationState = .loading
    private(set) var composerAuthority = ConversationComposerAuthority()
    private(set) var sendReconciliation = SendReconciliationState()
    private(set) var lastSendGateFailure: ConversationSendGateFailure?

    private let runtime: any LiveConversationRuntime
    private let loadOlderAction: @Sendable () async -> Void
    private let sendAction: @Sendable (String, ConversationComposerStamp) async -> ConversationSendOutcome
    private let dismissSendReceiptAction: @Sendable (String) async -> Void
    private var stateTask: Task<Void, Never>?
    private var sendReconciliationTask: Task<Void, Never>?
    private var connectionPhase: ConnectionCoordinatorPhase = .idle
    private var connectionGeneration: UInt64 = 0
    private var runtimeRevision: UInt64 = 0
    private var hasConsumedState = false

    init(
        conversationID: UUID,
        runtime: any LiveConversationRuntime,
        loadOlder: @escaping @Sendable () async -> Void = {},
        send: @escaping @Sendable (String, ConversationComposerStamp) async -> ConversationSendOutcome = { _, _ in
            .notEnqueued(.conversationNotOpen)
        },
        dismissSendReceipt: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.conversationID = conversationID
        self.runtime = runtime
        loadOlderAction = loadOlder
        sendAction = send
        dismissSendReceiptAction = dismissSendReceipt
    }

    func start() async {
        guard stateTask == nil else { return }
        consume(await runtime.currentState())
        stateTask = Task { @MainActor [weak self, runtime] in
            let states = await runtime.states()
            for await state in states {
                guard let self, !Task.isCancelled else { return }
                consume(state)
            }
        }
        sendReconciliationTask = Task { @MainActor [weak self, runtime] in
            let states = await runtime.sendReconciliationStates()
            for await state in states {
                guard let self, !Task.isCancelled else { return }
                consumeSendReconciliation(state)
            }
        }
    }

    func stop() {
        stateTask?.cancel()
        stateTask = nil
        sendReconciliationTask?.cancel()
        sendReconciliationTask = nil
    }

    func loadOlder() async {
        guard hasOlder, isLoadingOlder == false else { return }
        await loadOlderAction()
    }

    func send(_ text: String) async -> ConversationSendOutcome {
        guard let stamp = composerAuthority.stamp else {
            let failure = composerAuthority.gateFailure ?? .staleComposerAuthority
            lastSendGateFailure = failure
            return .notEnqueued(failure)
        }
        let submittedAtRuntimeRevision = runtimeRevision
        let outcome = await sendAction(text, stamp)
        guard runtimeRevision == submittedAtRuntimeRevision else { return outcome }
        switch outcome {
        case .enqueued:
            lastSendGateFailure = .sendAlreadyReserved
        case .notEnqueued(let failure):
            lastSendGateFailure = failure
        }
        return outcome
    }

    func dismissSendReceipt(_ clientRequestID: String) async {
        await dismissSendReceiptAction(clientRequestID)
    }

    func draftDidChange() {
        if lastSendGateFailure == .emptyText || lastSendGateFailure == .cancelled {
            lastSendGateFailure = nil
        }
    }

    func consumeConnectionPhase(_ phase: ConnectionCoordinatorPhase) {
        if connectionPhase != phase {
            runtimeRevision &+= 1
            lastSendGateFailure = nil
        }
        connectionPhase = phase
        resolvePhase()
        refreshTranscriptPresentation()
    }

    func consume(_ state: ConversationRuntime.State) {
        guard state.conversationID.rawValue == conversationID,
              state.connectionGeneration >= connectionGeneration else {
            return
        }

        let previousEvents = events
        let previousRunID = projectionRunID
        let previousProjectionGeneration = projectionGeneration
        let didChangeRuntime = hasConsumedState && (
            state.connectionGeneration > connectionGeneration
                || state.projectionRunID != projectionRunID
                || state.projectionGeneration != projectionGeneration
                || state.events != events
                || state.cursor != cursor
                || state.latestSequence != latestSequence
                || state.firstAvailableSequence != firstAvailableSequence
                || state.historyTruncated != historyTruncated
                || state.isLoadingOlder != isLoadingOlder
                || state.phase != runtimePhase
        )
        let didChangeComposerAuthority = composerAuthority != state.composerAuthority

        if didChangeRuntime || didChangeComposerAuthority {
            runtimeRevision &+= 1
            lastSendGateFailure = nil
        }

        connectionGeneration = state.connectionGeneration
        projectionRunID = state.projectionRunID
        projectionGeneration = state.projectionGeneration
        events = state.events
        runtimePhase = state.phase
        cursor = state.cursor
        latestSequence = state.latestSequence
        firstAvailableSequence = state.firstAvailableSequence
        historyTruncated = state.historyTruncated
        composerAuthority = state.composerAuthority
        hasOlder = state.hasOlder
        isLoadingOlder = state.isLoadingOlder
        change = classifyChange(
            previousEvents: previousEvents,
            previousRunID: previousRunID,
            previousProjectionGeneration: previousProjectionGeneration,
            hasConsumedState: hasConsumedState
        )
        if change == .prepend,
           let projectionRunID,
           let projectionGeneration,
           let sequence = firstRenderedSequence(in: previousEvents) {
            prependAnchorID = ToasttyTranscriptRowID(
                projectionRunID: projectionRunID.rawValue,
                projectionGeneration: projectionGeneration,
                conversationID: conversationID,
                sequence: sequence
            )
        } else {
            prependAnchorID = nil
        }
        hasConsumedState = true
        resolvePhase()
        refreshTranscriptPresentation()
    }

    func consumeSendReconciliation(_ state: SendReconciliationState) {
        let stateChanged = sendReconciliation != state
        sendReconciliation = state
        if stateChanged && lastSendGateFailure == .tooManyUnresolvedSends {
            lastSendGateFailure = nil
        }
        change = .metadataOnly
        refreshTranscriptPresentation()
    }

    var presentedComposerAuthority: ConversationComposerAuthority {
        guard let lastSendGateFailure else { return composerAuthority }
        return ConversationComposerAuthority(
            stamp: composerAuthority.stamp,
            inputAvailability: composerAuthority.inputAvailability,
            gateFailure: lastSendGateFailure
        )
    }

    private func classifyChange(
        previousEvents: [CompatibleConversationEvent],
        previousRunID: RemoteProjectionRunID?,
        previousProjectionGeneration: UInt64?,
        hasConsumedState: Bool
    ) -> LiveConversationChange {
        guard hasConsumedState else { return .initial }
        guard previousRunID == projectionRunID,
              previousProjectionGeneration == projectionGeneration else {
            return previousEvents.isEmpty && events.isEmpty ? .metadataOnly : .rebuild
        }
        let previousIdentities = eventIdentities(previousEvents)
        let newIdentities = eventIdentities(events)
        guard events.count != previousEvents.count else {
            return newIdentities == previousIdentities
                ? .metadataOnly
                : .rebuild
        }
        guard events.count > previousEvents.count else { return .rebuild }
        if Array(newIdentities.prefix(previousIdentities.count)) == previousIdentities {
            return .append
        }
        if Array(newIdentities.suffix(previousIdentities.count)) == previousIdentities {
            return .prepend
        }
        return .rebuild
    }

    private func eventIdentities<S: Sequence>(
        _ values: S
    ) -> [EventIdentity] where S.Element == CompatibleConversationEvent {
        values.map { event in
            switch event {
            case .known(let known):
                EventIdentity(sequence: known.sequence, eventID: known.eventID)
            case .statusChanged(let status):
                EventIdentity(sequence: status.sequence, eventID: status.eventID)
            case .unknown(_, let sequence, let kind):
                EventIdentity(sequence: sequence, eventID: "unknown:\(kind)")
            }
        }
    }

    private func firstRenderedSequence(
        in values: [CompatibleConversationEvent]
    ) -> UInt64? {
        values.first { event in
            if case .unknown = event { return false }
            return true
        }?.sequence
    }

    private func resolvePhase() {
        switch connectionPhase {
        case .requiresAuthentication, .authorizationDenied, .incompatibleProtocol, .failed:
            phase = .failed
            return
        case .reconnecting, .suspended:
            phase = .stale
            return
        case .idle, .connecting, .awaitingFreshSessionSnapshot, .live:
            break
        }

        switch runtimePhase {
        case .idle:
            phase = .idle
        case .catchingUp:
            phase = events.isEmpty ? .loading : .resynchronizing(reason: nil)
        case .live:
            phase = .live
        case .resnapshotRequired(let reason):
            phase = .resynchronizing(reason: reason)
        case .suspended:
            phase = .stale
        }
    }

    private func refreshTranscriptPresentation() {
        transcriptPresentation = ToasttyConversationPresentationAdapter.makeState(
            events: events,
            projectionRunID: projectionRunID,
            projectionGeneration: projectionGeneration,
            phase: transcriptPhase,
            revision: transcriptRevision,
            historyTruncated: historyTruncated,
            sendItems: ToasttySendPresentationAdapter.makeItems(from: sendReconciliation),
            hasOlder: hasOlder,
            isLoadingOlder: isLoadingOlder,
            prependAnchorID: prependAnchorID
        )
    }

    private var transcriptPhase: ToasttyConversationPresentationPhase {
        switch phase {
        case .idle, .loading:
            .loading
        case .live:
            .live
        case .resynchronizing:
            .resyncing
        case .stale:
            .stale
        case .failed:
            .failure(message: "Transcript unavailable. Check the connection to your Mac.")
        }
    }

    private var transcriptRevision: ToasttyTranscriptRevision {
        switch change {
        case .initial: .initial
        case .append: .appended
        case .prepend: .prepended
        case .rebuild: .rebuilt
        case .metadataOnly: .metadataOnly
        }
    }

    private struct EventIdentity: Equatable {
        var sequence: UInt64
        var eventID: String
    }
}
