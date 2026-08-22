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
    case operationFailed
    case deliveryUnconfirmed

    public var isTerminal: Bool {
        switch self {
        case .pending:
            false
        case .confirmed, .rejected, .uncertain, .operationFailed, .deliveryUnconfirmed:
            true
        }
    }

    public var allowsRetry: Bool {
        false
    }

    public var isDismissible: Bool {
        switch self {
        case .rejected, .uncertain, .operationFailed, .deliveryUnconfirmed:
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
    public static let maximumUnresolvedRecords = 64
    public static let maximumRetainedRecords = 256

    private struct StoredRecord: Sendable {
        var insertionOrder: UInt64
        var record: SendReconciliationRecord
    }

    struct EnqueueAdmission: Equatable, Sendable {
        var record: SendReconciliationRecord
        var evictedConfirmedRequestIDs: [String]
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

    /// Atomically admits and adds one optimistic operation. Capacity is checked
    /// in the same actor turn as insertion, so a coordinator reservation can be
    /// rolled back if and only if this returns nil. Re-enqueueing an existing
    /// request ID is idempotent and never replaces its original text or state.
    @discardableResult
    func enqueue(
        clientRequestID: String,
        text: String,
        projectionRunID: RemoteProjectionRunID? = nil
    ) async -> EnqueueAdmission? {
        if let existing = recordsByRequestID[clientRequestID] {
            return EnqueueAdmission(
                record: existing.record,
                evictedConfirmedRequestIDs: []
            )
        }

        guard unresolvedRecordCount < Self.maximumUnresolvedRecords else {
            return nil
        }
        var evictedConfirmedRequestIDs: [String] = []
        if recordsByRequestID.count >= Self.maximumRetainedRecords,
           let oldestConfirmed = recordsByRequestID
               .filter({ _, stored in
                   if case .confirmed = stored.record.deliveryState { return true }
                   return false
               })
               .min(by: { $0.value.insertionOrder < $1.value.insertionOrder })?.key {
            recordsByRequestID.removeValue(forKey: oldestConfirmed)
            evictedConfirmedRequestIDs.append(oldestConfirmed)
        }
        guard recordsByRequestID.count < Self.maximumRetainedRecords else {
            return nil
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
        return EnqueueAdmission(
            record: record,
            evictedConfirmedRequestIDs: evictedConfirmedRequestIDs
        )
    }

    /// Reaps the narrow enqueue-to-dispatch gap. Once the gateway call starts,
    /// callers must use an explicit result or `uncertain` instead.
    @discardableResult
    func discardBeforeDispatch(clientRequestID: String) async -> Bool {
        guard let stored = recordsByRequestID[clientRequestID] else { return false }
        switch stored.record.deliveryState {
        case .pending, .uncertain, .operationFailed, .deliveryUnconfirmed:
            break
        case .confirmed, .rejected:
            return false
        }
        recordsByRequestID.removeValue(forKey: clientRequestID)
        await publish()
        return true
    }

    /// Removes a request proven not to have reached host delivery (currently a
    /// concrete authentication/authorization HTTP denial). An earlier exact
    /// stream echo wins and is never erased by a contradictory late response.
    @discardableResult
    func discardNotDelivered(clientRequestID: String) async -> Bool {
        guard let stored = recordsByRequestID[clientRequestID] else { return false }
        switch stored.record.deliveryState {
        case .pending, .uncertain:
            recordsByRequestID.removeValue(forKey: clientRequestID)
            await publish()
            return true
        case .confirmed, .rejected, .operationFailed, .deliveryUnconfirmed:
            return false
        }
    }

    func deliveryState(clientRequestID: String) -> SendDeliveryState? {
        recordsByRequestID[clientRequestID]?.record.deliveryState
    }

    /// Terminates one operation whose response had no compatible semantic
    /// outcome. A later exact journal echo may still prove delivery.
    func markOperationFailed(clientRequestID: String) async {
        guard var stored = recordsByRequestID[clientRequestID] else { return }
        switch stored.record.deliveryState {
        case .pending, .uncertain, .deliveryUnconfirmed:
            stored.record.deliveryState = .operationFailed
            recordsByRequestID[clientRequestID] = stored
            await publish()
        case .confirmed, .rejected, .operationFailed:
            return
        }
    }

    /// A closed sheet does not destroy unresolved sends or failure receipts.
    /// Confirmed facts can be dropped because the canonical event is retained
    /// by the conversation projection and will be restored on reopen.
    func compactForInactiveRuntime() async -> [String] {
        let confirmedIDs = recordsByRequestID.compactMap { requestID, stored in
            if case .confirmed = stored.record.deliveryState { return requestID }
            return nil
        }
        guard confirmedIDs.isEmpty == false else { return [] }
        for requestID in confirmedIDs {
            recordsByRequestID.removeValue(forKey: requestID)
        }
        await publish()
        return confirmedIDs
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

    /// Reconciles host delivery receipts and confirms only a known
    /// `user_message` carrying the exact request ID. An uncertain or
    /// unconfirmed result can still be confirmed because the host may have
    /// committed the send. Text, timestamp, message origin, and binding changes
    /// are never used.
    public func observe(_ events: [CompatibleConversationEvent]) async {
        var didChange = false

        for compatibleEvent in events {
            guard case .known(let event) = compatibleEvent else { continue }
            switch event.payload {
            case .userMessage(let payload):
                guard let clientRequestID = payload.clientRequestID,
                      var stored = recordsByRequestID[clientRequestID] else {
                    continue
                }
                switch stored.record.deliveryState {
                case .pending, .uncertain, .operationFailed, .deliveryUnconfirmed:
                    stored.record.deliveryState = .confirmed(sequence: event.sequence)
                    recordsByRequestID[clientRequestID] = stored
                    didChange = true
                case .confirmed, .rejected:
                    continue
                }

            case .sendDeliveryUnconfirmed(let payload):
                guard var stored = recordsByRequestID[payload.clientRequestID] else {
                    continue
                }
                switch stored.record.deliveryState {
                case .pending, .uncertain, .operationFailed:
                    stored.record.deliveryState = .deliveryUnconfirmed
                    recordsByRequestID[payload.clientRequestID] = stored
                    didChange = true
                case .confirmed, .rejected, .deliveryUnconfirmed:
                    continue
                }

            case .assistantMessage, .toolStarted, .toolFinished,
                 .statusChanged, .interactionPresented, .interactionResolved,
                 .subagentSummary, .sessionBindingChanged:
                continue
            }
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
    @discardableResult
    public func dismiss(clientRequestID: String) async -> Bool {
        guard let stored = recordsByRequestID[clientRequestID] else { return false }
        guard stored.record.deliveryState.isDismissible else { return false }
        recordsByRequestID.removeValue(forKey: clientRequestID)
        await publish()
        return true
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
            case .confirmed, .rejected, .operationFailed, .deliveryUnconfirmed:
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

    private var unresolvedRecordCount: Int {
        recordsByRequestID.values.reduce(into: 0) { count, stored in
            switch stored.record.deliveryState {
            case .pending, .uncertain:
                count += 1
            case .confirmed, .rejected, .operationFailed, .deliveryUnconfirmed:
                break
            }
        }
    }

    private func publish() async {
        await stateStream.yield(makeState())
    }
}
