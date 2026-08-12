import Foundation
import RemoteProtocol

public enum PendingSendResponse: Equatable, Sendable {
    case awaitingResponse
    case accepted
    case duplicate
}

public enum SendDeliveryState: Equatable, Sendable {
    case pending(PendingSendResponse)
    case confirmed(sequence: UInt64)
    case rejected(reason: RemoteMessageRejectionReason)
    case uncertain
    case deliveryUnconfirmed

    public var isTerminal: Bool {
        switch self {
        case .pending:
            false
        case .confirmed, .rejected, .uncertain, .deliveryUnconfirmed:
            true
        }
    }

    public var allowsRetry: Bool {
        false
    }

    public var isDismissible: Bool {
        switch self {
        case .rejected, .uncertain, .deliveryUnconfirmed:
            true
        case .pending, .confirmed:
            false
        }
    }
}

public struct SendReconciliationRecord: Equatable, Identifiable, Sendable {
    public var id: String { clientRequestID }

    public let clientRequestID: String
    public let text: String
    public let projectionRunID: RemoteProjectionRunID?
    public var deliveryState: SendDeliveryState

    public init(
        clientRequestID: String,
        text: String,
        projectionRunID: RemoteProjectionRunID?,
        deliveryState: SendDeliveryState
    ) {
        self.clientRequestID = clientRequestID
        self.text = text
        self.projectionRunID = projectionRunID
        self.deliveryState = deliveryState
    }
}

public struct SendReconciliationState: Equatable, Sendable {
    public var records: [SendReconciliationRecord]

    public init(records: [SendReconciliationRecord] = []) {
        self.records = records
    }

    public subscript(clientRequestID: String) -> SendReconciliationRecord? {
        records.first { $0.clientRequestID == clientRequestID }
    }
}

/// Reconciles optimistic sends solely against the host-echoed request ID.
///
/// The actor-owned dictionary is authoritative. Published state intentionally
/// uses a bounded newest-value stream and may skip intermediate snapshots.
public actor SendReconciliation {
    private struct StoredRecord: Sendable {
        var insertionOrder: UInt64
        var record: SendReconciliationRecord
    }

    private var recordsByRequestID: [String: StoredRecord] = [:]
    private var nextInsertionOrder: UInt64 = 0
    private var currentProjectionRunID: RemoteProjectionRunID?
    private let stateStream: RuntimeStateStream<SendReconciliationState>

    public init(initialProjectionRunID: RemoteProjectionRunID? = nil) {
        currentProjectionRunID = initialProjectionRunID
        stateStream = RuntimeStateStream(SendReconciliationState())
    }

    public func states() async -> AsyncStream<SendReconciliationState> {
        await stateStream.states()
    }

    public func currentState() -> SendReconciliationState {
        makeState()
    }

    /// Adds one optimistic operation. Re-enqueuing an existing request ID is
    /// idempotent and never replaces its original text or state.
    @discardableResult
    public func enqueue(
        clientRequestID: String,
        text: String,
        projectionRunID: RemoteProjectionRunID? = nil
    ) async -> SendReconciliationRecord {
        if let existing = recordsByRequestID[clientRequestID] {
            return existing.record
        }

        let record = SendReconciliationRecord(
            clientRequestID: clientRequestID,
            text: text,
            projectionRunID: projectionRunID ?? currentProjectionRunID,
            deliveryState: .pending(.awaitingResponse)
        )
        recordsByRequestID[clientRequestID] = StoredRecord(
            insertionOrder: nextInsertionOrder,
            record: record
        )
        nextInsertionOrder &+= 1
        await publish()
        return record
    }

    /// Applies the immediate send response without treating acceptance as
    /// transcript confirmation. A terminal operation is never reopened by a
    /// late or duplicated response.
    public func apply(
        _ result: RemoteMessageSendResult,
        clientRequestID: String
    ) async {
        guard var stored = recordsByRequestID[clientRequestID] else { return }
        guard case .pending = stored.record.deliveryState else { return }

        switch result {
        case .accepted:
            stored.record.deliveryState = .pending(.accepted)
        case .duplicate:
            stored.record.deliveryState = .pending(.duplicate)
        case .rejected(let reason):
            stored.record.deliveryState = .rejected(reason: reason)
        case .uncertain:
            stored.record.deliveryState = .uncertain
        }

        recordsByRequestID[clientRequestID] = stored
        await publish()
    }

    /// Confirms only a known `user_message` carrying the exact request ID.
    /// An uncertain transport result can still be confirmed because it means
    /// the host may have committed the send. Text, timestamp, message origin,
    /// and binding changes are never used.
    public func observe(_ events: [CompatibleConversationEvent]) async {
        var didChange = false

        for compatibleEvent in events {
            guard case .known(let event) = compatibleEvent else { continue }
            guard case .userMessage(let payload) = event.payload else { continue }
            guard let clientRequestID = payload.clientRequestID else { continue }
            guard var stored = recordsByRequestID[clientRequestID] else { continue }
            switch stored.record.deliveryState {
            case .pending, .uncertain:
                break
            case .confirmed, .rejected, .deliveryUnconfirmed:
                continue
            }

            stored.record.deliveryState = .confirmed(sequence: event.sequence)
            recordsByRequestID[clientRequestID] = stored
            didChange = true
        }

        if didChange {
            await publish()
        }
    }

    /// Invalidates every still-pending operation when the projection run
    /// changes. Establishing the first known run is not itself an invalidation.
    public func projectionDidChange(to projectionRunID: RemoteProjectionRunID) async {
        guard let previousRunID = currentProjectionRunID else {
            currentProjectionRunID = projectionRunID
            return
        }
        guard previousRunID != projectionRunID else { return }
        currentProjectionRunID = projectionRunID
        guard markUnresolvedAsDeliveryUnconfirmed() else { return }
        await publish()
    }

    /// Completes the lost-echo boundary only after the resnapshot has caught up
    /// through the advertised latest sequence for this projection run.
    public func completedResnapshot(
        projectionRunID: RemoteProjectionRunID,
        latestSequence: UInt64,
        observedThroughSequence: UInt64
    ) async {
        guard observedThroughSequence >= latestSequence else { return }
        guard currentProjectionRunID == nil || currentProjectionRunID == projectionRunID else { return }
        currentProjectionRunID = projectionRunID
        guard markUnresolvedAsDeliveryUnconfirmed() else { return }
        await publish()
    }

    /// Removes a terminal user-facing failure receipt. Confirmed operations are
    /// retained as reconciliation facts and pending operations cannot be lost.
    public func dismiss(clientRequestID: String) async {
        guard let stored = recordsByRequestID[clientRequestID] else { return }
        guard stored.record.deliveryState.isDismissible else { return }
        recordsByRequestID.removeValue(forKey: clientRequestID)
        await publish()
    }

    public func finish() async {
        await stateStream.finish()
    }

    private func markUnresolvedAsDeliveryUnconfirmed() -> Bool {
        var didChange = false
        for clientRequestID in Array(recordsByRequestID.keys) {
            guard var stored = recordsByRequestID[clientRequestID] else { continue }
            switch stored.record.deliveryState {
            case .pending, .uncertain:
                break
            case .confirmed, .rejected, .deliveryUnconfirmed:
                continue
            }
            stored.record.deliveryState = .deliveryUnconfirmed
            recordsByRequestID[clientRequestID] = stored
            didChange = true
        }
        return didChange
    }

    private func makeState() -> SendReconciliationState {
        SendReconciliationState(
            records: recordsByRequestID.values
                .sorted { $0.insertionOrder < $1.insertionOrder }
                .map(\.record)
        )
    }

    private func publish() async {
        await stateStream.yield(makeState())
    }
}
