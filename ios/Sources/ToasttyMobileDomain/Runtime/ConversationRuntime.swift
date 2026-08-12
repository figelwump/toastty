import Foundation
import RemoteProtocol

public enum ConversationResnapshotReason: Equatable, Sendable {
    case explicit
    case projectionChanged
    case retentionLost
    case liveBufferOverflow
    case invalidPage
}

public enum ConversationRuntimeDirective: Equatable, Sendable {
    case none
    case fetchREST(cursor: ConversationEventCursor?)
    case resnapshot(reason: ConversationResnapshotReason)
}

public enum ConversationRuntimePhase: Equatable, Sendable {
    case idle
    case catchingUp
    case live
    case resnapshotRequired(ConversationResnapshotReason)
    case suspended
}

public actor ConversationRuntime {
    public struct State: Sendable {
        public var conversationID: RemoteConversationID
        public var connectionGeneration: UInt64
        public var projectionRunID: RemoteProjectionRunID?
        public var projectionGeneration: UInt64?
        public var events: [CompatibleConversationEvent]
        public var cursor: ConversationEventCursor?
        public var latestSequence: UInt64
        public var firstAvailableSequence: UInt64?
        public var historyTruncated: Bool
        public var phase: ConversationRuntimePhase
        public let sendReconciliation: SendReconciliation

        public init(
            conversationID: RemoteConversationID,
            connectionGeneration: UInt64 = 0,
            projectionRunID: RemoteProjectionRunID? = nil,
            projectionGeneration: UInt64? = nil,
            events: [CompatibleConversationEvent] = [],
            cursor: ConversationEventCursor? = nil,
            latestSequence: UInt64 = 0,
            firstAvailableSequence: UInt64? = nil,
            historyTruncated: Bool = false,
            phase: ConversationRuntimePhase = .idle,
            sendReconciliation: SendReconciliation
        ) {
            self.conversationID = conversationID
            self.connectionGeneration = connectionGeneration
            self.projectionRunID = projectionRunID
            self.projectionGeneration = projectionGeneration
            self.events = events
            self.cursor = cursor
            self.latestSequence = latestSequence
            self.firstAvailableSequence = firstAvailableSequence
            self.historyTruncated = historyTruncated
            self.phase = phase
            self.sendReconciliation = sendReconciliation
        }
    }

    public static let maximumBufferedLivePages = 32

    public nonisolated let sendReconciliation: SendReconciliation

    private var state: State
    private let stateStream: RuntimeStateStream<State>
    private var bufferedLivePages: [CompatibleConversationEventPage] = []
    private var catchUpIsResnapshot = false
    private var projectionRunBeforeResnapshot: RemoteProjectionRunID?

    public init(
        conversationID: RemoteConversationID,
        sendReconciliation: SendReconciliation = SendReconciliation()
    ) {
        self.sendReconciliation = sendReconciliation
        let initialState = State(
            conversationID: conversationID,
            sendReconciliation: sendReconciliation
        )
        state = initialState
        stateStream = RuntimeStateStream(initialState)
    }

    public func currentState() -> State {
        state
    }

    public func states() async -> AsyncStream<State> {
        await stateStream.states()
    }

    /// Opens a REST boundary. Live pages for this conversation are buffered
    /// until REST has filled the boundary, including reconnect catch-ups after
    /// the initial subscription handoff.
    @discardableResult
    public func beginCatchUp(
        connectionGeneration: UInt64,
        resnapshot: Bool = false
    ) async -> Bool {
        guard connectionGeneration >= state.connectionGeneration else { return false }
        if connectionGeneration > state.connectionGeneration {
            // Buffered frames belong to the connection that received them.
            // Never carry them across a generation boundary.
            bufferedLivePages.removeAll(keepingCapacity: true)
        }
        state.connectionGeneration = connectionGeneration
        catchUpIsResnapshot = resnapshot
        if resnapshot {
            projectionRunBeforeResnapshot = state.projectionRunID
            resetProjection()
            bufferedLivePages.removeAll(keepingCapacity: true)
        }
        state.phase = .catchingUp
        await publish()
        return true
    }

    /// Applies one REST page and returns the coordinator's next action.
    /// This method performs no I/O and owns no retry policy.
    @discardableResult
    public func applyREST(
        _ page: CompatibleConversationEventPage,
        connectionGeneration: UInt64
    ) async -> ConversationRuntimeDirective {
        guard connectionGeneration == state.connectionGeneration else { return .none }
        guard state.phase == .catchingUp else { return .none }
        guard page.conversationID == state.conversationID else {
            return await requireResnapshot(.invalidPage, connectionGeneration: connectionGeneration)
        }

        let adoption = establishOrValidateProjection(for: page)
        switch adoption {
        case .projectionChanged:
            return await requireResnapshot(.projectionChanged, connectionGeneration: connectionGeneration)
        case .retentionLost:
            return await requireResnapshot(.retentionLost, connectionGeneration: connectionGeneration)
        case .invalid:
            return await requireResnapshot(.invalidPage, connectionGeneration: connectionGeneration)
        case .valid(let adoptedRun):
            if let adoptedRun, projectionRunBeforeResnapshot != adoptedRun {
                await sendReconciliation.projectionDidChange(to: adoptedRun)
            }
            projectionRunBeforeResnapshot = nil
        }

        let applied = applyContiguousEvents(page.events)
        if applied.hasGap {
            await observeAndPublish(applied.acceptedEvents)
            return .fetchREST(cursor: state.cursor)
        }
        updatePageMetadata(page)
        await sendReconciliation.observe(applied.acceptedEvents)

        let bufferedDirective = await drainBufferedLivePages()
        await publish()
        if bufferedDirective != .none {
            return bufferedDirective
        }
        if observedSequence < state.latestSequence {
            return .fetchREST(cursor: state.cursor)
        }
        return .none
    }

    /// Applies a live page immediately only outside a REST boundary. A gap
    /// keeps the triggering page buffered so a REST fetch can fill it.
    @discardableResult
    public func applyLive(
        _ page: CompatibleConversationEventPage,
        connectionGeneration: UInt64
    ) async -> ConversationRuntimeDirective {
        guard connectionGeneration == state.connectionGeneration else { return .none }
        guard page.conversationID == state.conversationID else { return .none }

        if let runID = state.projectionRunID,
           runID != page.projectionRunID || state.projectionGeneration != page.projectionGeneration {
            return await requireResnapshot(.projectionChanged, connectionGeneration: connectionGeneration)
        }

        if state.phase == .catchingUp || state.projectionRunID == nil {
            return await bufferLivePage(page, connectionGeneration: connectionGeneration)
        }
        guard state.phase == .live else { return .none }

        switch retentionDisposition(for: page) {
        case .lost:
            return await requireResnapshot(.retentionLost, connectionGeneration: connectionGeneration)
        case .invalid:
            return await requireResnapshot(.invalidPage, connectionGeneration: connectionGeneration)
        case .valid:
            break
        }

        let applied = applyContiguousEvents(page.events)
        if applied.hasGap {
            let directive = await bufferLivePage(page, connectionGeneration: connectionGeneration)
            if case .none = directive {
                state.phase = .catchingUp
                await publish()
                return .fetchREST(cursor: state.cursor)
            }
            return directive
        }

        updatePageMetadata(page)
        await sendReconciliation.observe(applied.acceptedEvents)
        if observedSequence < page.latestSequence {
            state.phase = .catchingUp
            await publish()
            return .fetchREST(cursor: state.cursor)
        }
        await publish()
        return .none
    }

    /// Completes a catch-up only when every retained sequence through the
    /// latest advertised sequence has been observed.
    @discardableResult
    public func finishCatchUp(connectionGeneration: UInt64) async -> Bool {
        guard connectionGeneration == state.connectionGeneration else { return false }
        guard state.phase == .catchingUp, bufferedLivePages.isEmpty else { return false }
        guard observedSequence >= state.latestSequence else { return false }

        state.phase = .live
        if catchUpIsResnapshot,
           let runID = state.projectionRunID {
            await sendReconciliation.completedResnapshot(
                projectionRunID: runID,
                latestSequence: state.latestSequence,
                observedThroughSequence: observedSequence
            )
        }
        catchUpIsResnapshot = false
        await publish()
        return true
    }

    @discardableResult
    public func requireResnapshot(
        _ reason: ConversationResnapshotReason = .explicit,
        connectionGeneration: UInt64
    ) async -> ConversationRuntimeDirective {
        guard connectionGeneration == state.connectionGeneration else { return .none }
        bufferedLivePages.removeAll(keepingCapacity: true)
        state.phase = .resnapshotRequired(reason)
        await publish()
        return .resnapshot(reason: reason)
    }

    @discardableResult
    public func suspend(connectionGeneration: UInt64) async -> Bool {
        guard connectionGeneration >= state.connectionGeneration else { return false }
        state.connectionGeneration = connectionGeneration
        state.phase = .suspended
        bufferedLivePages.removeAll(keepingCapacity: true)
        await publish()
        return true
    }

    private enum ProjectionDisposition {
        /// Contains the newly adopted run, or nil for an already established run.
        case valid(adoptedRun: RemoteProjectionRunID?)
        case projectionChanged
        case retentionLost
        case invalid
    }

    private enum RetentionDisposition {
        case valid
        case lost
        case invalid
    }

    private struct AppliedEvents {
        var acceptedEvents: [CompatibleConversationEvent]
        var hasGap: Bool
    }

    private var observedSequence: UInt64 {
        state.cursor?.afterSequence ?? 0
    }

    private func establishOrValidateProjection(
        for page: CompatibleConversationEventPage
    ) -> ProjectionDisposition {
        if let runID = state.projectionRunID {
            guard runID == page.projectionRunID,
                  state.projectionGeneration == page.projectionGeneration else {
                return .projectionChanged
            }
            switch retentionDisposition(for: page) {
            case .valid: return .valid(adoptedRun: nil)
            case .lost: return .retentionLost
            case .invalid: return .invalid
            }
        }

        let baseline: UInt64
        if page.historyTruncated {
            guard let firstAvailableSequence = page.firstAvailableSequence,
                  firstAvailableSequence > 0 else {
                return .invalid
            }
            baseline = firstAvailableSequence - 1
        } else {
            baseline = 0
        }
        guard baseline <= page.latestSequence else { return .invalid }

        state.projectionRunID = page.projectionRunID
        state.projectionGeneration = page.projectionGeneration
        state.cursor = ConversationEventCursor(
            projectionRunID: page.projectionRunID,
            projectionGeneration: page.projectionGeneration,
            afterSequence: baseline
        )
        state.latestSequence = page.latestSequence
        state.firstAvailableSequence = page.firstAvailableSequence
        state.historyTruncated = page.historyTruncated
        return .valid(adoptedRun: page.projectionRunID)
    }

    private func retentionDisposition(
        for page: CompatibleConversationEventPage
    ) -> RetentionDisposition {
        guard page.historyTruncated else { return .valid }
        guard let firstAvailableSequence = page.firstAvailableSequence,
              firstAvailableSequence > 0 else {
            return .invalid
        }
        let (nextSequence, overflow) = observedSequence.addingReportingOverflow(1)
        if overflow { return .valid }
        return nextSequence < firstAvailableSequence ? .lost : .valid
    }

    private func applyContiguousEvents(
        _ events: [CompatibleConversationEvent]
    ) -> AppliedEvents {
        var acceptedEvents: [CompatibleConversationEvent] = []
        for event in events {
            guard event.conversationID == state.conversationID else {
                return AppliedEvents(acceptedEvents: acceptedEvents, hasGap: true)
            }
            if event.sequence <= observedSequence {
                continue
            }
            let (expectedSequence, overflow) = observedSequence.addingReportingOverflow(1)
            guard overflow == false, event.sequence == expectedSequence else {
                return AppliedEvents(acceptedEvents: acceptedEvents, hasGap: true)
            }

            state.cursor?.afterSequence = event.sequence
            acceptedEvents.append(event)
            if case .unknown = event {
                continue
            }
            state.events.append(event)
        }
        return AppliedEvents(acceptedEvents: acceptedEvents, hasGap: false)
    }

    private func updatePageMetadata(_ page: CompatibleConversationEventPage) {
        state.latestSequence = max(state.latestSequence, page.latestSequence)
        if let firstAvailableSequence = page.firstAvailableSequence {
            state.firstAvailableSequence = firstAvailableSequence
        }
        state.historyTruncated = state.historyTruncated || page.historyTruncated
    }

    private func bufferLivePage(
        _ page: CompatibleConversationEventPage,
        connectionGeneration: UInt64
    ) async -> ConversationRuntimeDirective {
        guard bufferedLivePages.count < Self.maximumBufferedLivePages else {
            return await requireResnapshot(
                .liveBufferOverflow,
                connectionGeneration: connectionGeneration
            )
        }
        bufferedLivePages.append(page)
        return .none
    }

    private func drainBufferedLivePages() async -> ConversationRuntimeDirective {
        while let page = bufferedLivePages.first {
            guard page.conversationID == state.conversationID else {
                return await requireResnapshot(
                    .invalidPage,
                    connectionGeneration: state.connectionGeneration
                )
            }
            guard page.projectionRunID == state.projectionRunID,
                  page.projectionGeneration == state.projectionGeneration else {
                return await requireResnapshot(
                    .projectionChanged,
                    connectionGeneration: state.connectionGeneration
                )
            }
            switch retentionDisposition(for: page) {
            case .lost:
                return await requireResnapshot(
                    .retentionLost,
                    connectionGeneration: state.connectionGeneration
                )
            case .invalid:
                return await requireResnapshot(
                    .invalidPage,
                    connectionGeneration: state.connectionGeneration
                )
            case .valid:
                break
            }

            let applied = applyContiguousEvents(page.events)
            await sendReconciliation.observe(applied.acceptedEvents)
            if applied.hasGap {
                return .fetchREST(cursor: state.cursor)
            }
            updatePageMetadata(page)
            bufferedLivePages.removeFirst()
            if observedSequence < page.latestSequence {
                return .fetchREST(cursor: state.cursor)
            }
        }
        return .none
    }

    private func resetProjection() {
        state.projectionRunID = nil
        state.projectionGeneration = nil
        state.events.removeAll(keepingCapacity: true)
        state.cursor = nil
        state.latestSequence = 0
        state.firstAvailableSequence = nil
        state.historyTruncated = false
    }

    private func observeAndPublish(_ events: [CompatibleConversationEvent]) async {
        await sendReconciliation.observe(events)
        await publish()
    }

    private func publish() async {
        await stateStream.yield(state)
    }
}
