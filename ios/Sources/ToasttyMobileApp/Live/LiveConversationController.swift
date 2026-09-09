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
    private(set) var interactionAnswerStates: [
        RemotePendingInteraction.ID: ToasttyInteractionAnswerState
    ] = [:]

    private let runtime: any LiveConversationRuntime
    private let loadOlderAction: @Sendable () async -> Void
    private let sendAction: @Sendable (String, ConversationComposerStamp) async -> ConversationSendOutcome
    private let dismissSendReceiptAction: @Sendable (String) async -> Void
    private let answerQuestionAction: @Sendable (
        RemoteQuestionAnswerRequest
    ) async throws -> RemoteQuestionAnswerResult
    private let acknowledgeReadAction: @Sendable (
        RemoteConversationReadAcknowledgementRequest
    ) async throws -> RemoteConversationReadAcknowledgementResponse?
    private var stateTask: Task<Void, Never>?
    private var sendReconciliationTask: Task<Void, Never>?
    private var readAcknowledgementTask: Task<Void, Never>?
    private var readAcknowledgementBoundary: ReadBoundary?
    private var lastAcknowledgedBoundary: ReadBoundary?
    private var connectionPhase: ConnectionCoordinatorPhase = .idle
    private var supportsQuestionAnswers = false
    private var connectionGeneration: UInt64 = 0
    private var runtimeRevision: UInt64 = 0
    private var hasConsumedState = false
    private var canonicalRequestIDs: Set<String> = []
    var onDiagnosticEvent: @MainActor (ToasttyConnectionDiagnosticEvent) -> Void = { _ in }

    init(
        conversationID: UUID,
        runtime: any LiveConversationRuntime,
        loadOlder: @escaping @Sendable () async -> Void = {},
        send: @escaping @Sendable (String, ConversationComposerStamp) async -> ConversationSendOutcome = { _, _ in
            .notEnqueued(.conversationNotOpen)
        },
        answerQuestion: @escaping @Sendable (
            RemoteQuestionAnswerRequest
        ) async throws -> RemoteQuestionAnswerResult = { _ in
            .rejected(reason: .unsupported)
        },
        dismissSendReceipt: @escaping @Sendable (String) async -> Void = { _ in },
        acknowledgeRead: @escaping @Sendable (
            RemoteConversationReadAcknowledgementRequest
        ) async throws -> RemoteConversationReadAcknowledgementResponse? = { _ in nil }
    ) {
        self.conversationID = conversationID
        self.runtime = runtime
        loadOlderAction = loadOlder
        sendAction = send
        answerQuestionAction = answerQuestion
        dismissSendReceiptAction = dismissSendReceipt
        acknowledgeReadAction = acknowledgeRead
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
        readAcknowledgementTask?.cancel()
        readAcknowledgementTask = nil
        readAcknowledgementBoundary = nil
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

    /// Called by the view after it has established that the selected sheet is
    /// active and visibly at the live edge. Networking stays here so retries
    /// cannot outlive the controller or be duplicated by SwiftUI updates.
    func acknowledgeVisibleTranscript(presentationStatus: MobileSessionStatus) {
        guard phase == .live,
              let projectionRunID,
              let projectionGeneration,
              let observedThroughSequence = cursor?.afterSequence else {
            return
        }
        let boundary = ReadBoundary(
            projectionRunID: projectionRunID,
            projectionGeneration: projectionGeneration,
            observedThroughSequence: observedThroughSequence,
            presentationStatus: presentationStatus
        )
        guard boundary != lastAcknowledgedBoundary,
              boundary != readAcknowledgementBoundary else { return }

        readAcknowledgementTask?.cancel()
        readAcknowledgementBoundary = boundary
        let request = RemoteConversationReadAcknowledgementRequest(
            conversationID: RemoteConversationID(rawValue: conversationID),
            projectionRunID: boundary.projectionRunID,
            projectionGeneration: boundary.projectionGeneration,
            observedThroughSequence: boundary.observedThroughSequence
        )
        readAcknowledgementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await runReadAcknowledgement(request, boundary: boundary)
            if readAcknowledgementBoundary == boundary {
                readAcknowledgementBoundary = nil
            }
        }
    }

    func draftDidChange() {
        if lastSendGateFailure == .emptyText || lastSendGateFailure == .cancelled
            || lastSendGateFailure == .messageTooLarge || lastSendGateFailure == .requestEncodingFailed {
            lastSendGateFailure = nil
        }
    }

    func editInteractionAnswer(
        interactionID: RemotePendingInteraction.ID,
        edit: ToasttyInteractionAnswerEdit
    ) {
        guard var state = interactionAnswerStates[interactionID] else { return }
        state.apply(edit)
        interactionAnswerStates[interactionID] = state
    }

    func submitInteractionAnswer(
        interactionID: RemotePendingInteraction.ID
    ) async {
        guard var answerState = interactionAnswerStates[interactionID],
              answerState.canSubmit,
              let answers = answerState.canonicalAnswers else { return }
        let request = answerState.retryRequest ?? RemoteQuestionAnswerRequest(
            conversationID: RemoteConversationID(rawValue: conversationID),
            interactionID: answerState.key.interactionID,
            responseID: answerState.key.responseID,
            expectedInputEpoch: answerState.key.inputEpoch,
            clientRequestID: UUID().uuidString.lowercased(),
            answers: answers
        )
        answerState.retryRequest = request
        answerState.status = .submitting
        interactionAnswerStates[interactionID] = answerState

        let result: Result<RemoteQuestionAnswerResult, Error>
        do {
            result = .success(try await answerQuestionAction(request))
        } catch {
            result = .failure(error)
        }

        guard var current = interactionAnswerStates[interactionID],
              current.key == answerState.key,
              current.retryRequest == request,
              current.status == .submitting else { return }
        switch result {
        case .success(.submitted), .success(.duplicate):
            current.status = .awaitingClaude
        case .success(.rejected(let reason)):
            current.retryRequest = nil
            current.status = questionRejectionStatus(reason)
        case .failure:
            current.status = .failed("Answer could not be sent. Try again.")
        }
        interactionAnswerStates[interactionID] = current
    }

    func consumeConnectionState(_ state: ConnectionCoordinator.State) {
        supportsQuestionAnswers = state.capabilities.contains(.questionAnswers)
        consumeConnectionPhase(state.phase)
    }

    func consumeConnectionPhase(_ phase: ConnectionCoordinatorPhase) {
        if connectionPhase != phase {
            runtimeRevision &+= 1
            lastSendGateFailure = nil
        }
        connectionPhase = phase
        resolvePhase()
        refreshTranscriptPresentation()
        reconcileInteractionAnswerStates()
    }

    func consume(_ state: ConversationRuntime.State) {
        guard state.conversationID.rawValue == conversationID,
              state.connectionGeneration >= connectionGeneration else {
            return
        }

        let contentChanged = !hasConsumedState || state.events != events
            || state.projectionRunID != projectionRunID
            || state.projectionGeneration != projectionGeneration
        let previousEvents = events
        let previousRunID = projectionRunID
        let previousProjectionGeneration = projectionGeneration
        let didChangeRuntime = hasConsumedState && (
            state.connectionGeneration > connectionGeneration
                || contentChanged
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
        change = contentChanged ? classifyChange(
            previousEvents: previousEvents,
            previousRunID: previousRunID,
            previousProjectionGeneration: previousProjectionGeneration,
            hasConsumedState: hasConsumedState
        ) : .metadataOnly
        // Anchor to the previous visible rows; status events have no transcript row.
        prependAnchorID = change == .prepend ? transcriptPresentation.rows.first?.id : nil
        hasConsumedState = true
        resolvePhase()
        if contentChanged {
            canonicalRequestIDs = events.reduce(into: Set<String>()) { ids, event in
                guard case .known(let known) = event,
                      case .userMessage(let payload) = known.payload,
                      let requestID = payload.clientRequestID else { return }
                ids.insert(requestID)
            }
        }
        refreshTranscriptPresentation(contentChanged: contentChanged)
        reconcileInteractionAnswerStates()
    }

    func consumeSendReconciliation(_ state: SendReconciliationState) {
        for event in ToasttyAppDiagnosticProjection.events(from: sendReconciliation, to: state) {
            onDiagnosticEvent(event)
        }
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

    private func refreshTranscriptPresentation(contentChanged: Bool = false) {
        guard contentChanged else {
            transcriptPresentation = transcriptPresentation.updatingMetadata(
                sendItems: ToasttySendPresentationAdapter.makeItems(from: sendReconciliationForPresentation),
                phase: transcriptPhase,
                revision: transcriptRevision,
                historyTruncated: historyTruncated,
                hasOlder: hasOlder,
                isLoadingOlder: isLoadingOlder,
                prependAnchorID: prependAnchorID
            )
            return
        }
        transcriptPresentation = ToasttyConversationPresentationAdapter.makeState(
            events: events,
            projectionRunID: projectionRunID,
            projectionGeneration: projectionGeneration,
            phase: transcriptPhase,
            revision: transcriptRevision,
            historyTruncated: historyTruncated,
            sendItems: ToasttySendPresentationAdapter.makeItems(
                from: sendReconciliationForPresentation
            ),
            hasOlder: hasOlder,
            isLoadingOlder: isLoadingOlder,
            prependAnchorID: prependAnchorID
        )
    }

    private func reconcileInteractionAnswerStates() {
        var updated: [RemotePendingInteraction.ID: ToasttyInteractionAnswerState] = [:]
        var sawInteractionCard = false
        for row in transcriptPresentation.rows {
            guard case .interaction(let presentation) = row.content else { continue }
            sawInteractionCard = true
            let interaction = presentation.interaction
            guard let questions = interaction.questions,
                  RemoteQuestionAnswerValidation.supports(questions) else { continue }

            if interaction.state == .resolved {
                if var existing = interactionAnswerStates[interaction.id] {
                    existing.status = .resolved(interaction.answers ?? [])
                    existing.connectionIsLive = connectionPhase == .live
                    updated[interaction.id] = existing
                }
                continue
            }

            if let reason = presentation.responseClosedReason {
                if var existing = interactionAnswerStates[interaction.id] {
                    existing.status = .unavailable(questionRejectionMessage(reason))
                    existing.connectionIsLive = false
                    updated[interaction.id] = existing
                }
                continue
            }

            guard interaction.state == .pending,
                  let responseID = interaction.responseID,
                  responseID.isEmpty == false else { continue }
            let key = ToasttyInteractionAnswerKey(
                interactionID: interaction.id,
                responseID: responseID,
                inputEpoch: interaction.inputEpoch
            )
            var state: ToasttyInteractionAnswerState
            if let existing = interactionAnswerStates[interaction.id], existing.key == key {
                state = existing
            } else {
                guard supportsQuestionAnswers else { continue }
                state = ToasttyInteractionAnswerState(key: key, questions: questions)
            }
            state.connectionIsLive = connectionPhase == .live && supportsQuestionAnswers
            updated[interaction.id] = state
        }
        if sawInteractionCard == false, phase != .live {
            for (id, var state) in interactionAnswerStates {
                state.connectionIsLive = false
                updated[id] = state
            }
        }
        interactionAnswerStates = updated
    }

    private func questionRejectionStatus(
        _ reason: RemoteQuestionAnswerRejectionReason
    ) -> ToasttyInteractionAnswerStatus {
        switch reason {
        case .invalidAnswers:
            .failed("Review every answer and try again.")
        default:
            .unavailable(questionRejectionMessage(reason))
        }
    }

    private func questionRejectionMessage(
        _ reason: RemoteQuestionAnswerRejectionReason
    ) -> String {
        switch reason {
        case .expired: "The answer window closed. Respond on the desktop."
        case .sendScopeDenied: "This device cannot send answers."
        case .sessionWritesDisabled: "Remote answers are disabled for this session."
        case .notBound, .epochMismatch, .notPending, .alreadySubmitted:
            "This answer is no longer available on iPhone."
        case .invalidAnswers: "Review every answer and try again."
        case .unsupported: "Update Toastty on your Mac to answer here."
        }
    }

    /// The canonical conversation stream and send-reconciliation stream are
    /// observed independently. Keep a confirmed optimistic row visible until
    /// the exact host-echoed request ID is present in the canonical events, so
    /// SwiftUI never renders an intermediate frame with neither row. The same
    /// exact-ID check also prevents a duplicate frame if the canonical event
    /// reaches this controller before the reconciliation update.
    private var sendReconciliationForPresentation: SendReconciliationState {
        guard sendReconciliation.records.isEmpty == false else {
            return sendReconciliation
        }
        return SendReconciliationState(records: sendReconciliation.records.compactMap { record in
            guard canonicalRequestIDs.contains(record.clientRequestID) == false else {
                return nil
            }
            guard case .confirmed = record.deliveryState else { return record }
            guard record.projectionRunID == projectionRunID else {
                return nil
            }
            return SendReconciliationRecord(
                clientRequestID: record.clientRequestID,
                text: record.text,
                projectionRunID: record.projectionRunID,
                deliveryState: .pending(.accepted)
            )
        })
    }

    private func runReadAcknowledgement(
        _ request: RemoteConversationReadAcknowledgementRequest,
        boundary: ReadBoundary
    ) async {
        // One immediate attempt plus two bounded transient retries. A newer
        // visible boundary cancels this task and takes precedence.
        for attempt in 0..<3 {
            guard Task.isCancelled == false else { return }
            do {
                guard let response = try await acknowledgeReadAction(request) else {
                    return
                }
                guard Task.isCancelled == false else { return }
                switch response.result {
                case .acknowledged, .alreadyRead:
                    lastAcknowledgedBoundary = boundary
                case .staleBoundary, .conversationNotFound:
                    break
                }
                return
            } catch is CancellationError {
                return
            } catch let failure as GatewayFailure where failure.isRetryable {
                guard attempt < 2 else { return }
                do {
                    try await ContinuousClock().sleep(
                        for: .milliseconds(250 * (attempt + 1))
                    )
                } catch {
                    return
                }
            } catch {
                return
            }
        }
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
    private struct ReadBoundary: Equatable {
        var projectionRunID: RemoteProjectionRunID
        var projectionGeneration: UInt64
        var observedThroughSequence: UInt64
        var presentationStatus: MobileSessionStatus
    }
}
