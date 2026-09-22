import Foundation
import RemoteProtocol

/// Identifies the exact coordinator snapshot and prompt epoch rendered by a
/// composer. Callers must present this stamp unchanged when enqueueing text.
public struct ConversationComposerStamp: Equatable, Hashable, Sendable {
    public let connectionGeneration: UInt64
    public let streamSnapshotOrdinal: UInt64
    public let projectionRunID: RemoteProjectionRunID
    public let projectionGeneration: UInt64
    public let latestSequence: UInt64
    public let inputEpoch: RemoteInputEpoch

    public init(
        connectionGeneration: UInt64,
        streamSnapshotOrdinal: UInt64,
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64,
        latestSequence: UInt64,
        inputEpoch: RemoteInputEpoch
    ) {
        self.connectionGeneration = connectionGeneration
        self.streamSnapshotOrdinal = streamSnapshotOrdinal
        self.projectionRunID = projectionRunID
        self.projectionGeneration = projectionGeneration
        self.latestSequence = latestSequence
        self.inputEpoch = inputEpoch
    }
}

/// Local, fail-closed reasons why a send was not enqueued. These are never
/// host delivery outcomes: the draft remains owned by the caller in every case.
public enum ConversationSendGateFailure: Equatable, Sendable {
    case emptyText
    case attachmentsUnsupported
    case invalidAttachments
    case messageTooLarge
    case requestEncodingFailed
    case cancelled
    case coordinatorNotLive
    case deviceSendScopeDenied
    case conversationNotOpen
    case conversationMissing
    case staleComposerAuthority
    case conversationNotLive
    case transcriptNotCaughtUp
    case inputUnavailable
    case sendAlreadyReserved
    case tooManyUnresolvedSends
}

/// Read-only composer state published by a conversation runtime. Its input
/// availability and stamp come only from coordinator session snapshots; journal
/// status events are deliberately excluded from this authority.
public struct ConversationComposerAuthority: Equatable, Sendable {
    public let stamp: ConversationComposerStamp?
    public let inputAvailability: CompatibleInputAvailability?
    public let gateFailure: ConversationSendGateFailure?

    public init(
        stamp: ConversationComposerStamp? = nil,
        inputAvailability: CompatibleInputAvailability? = nil,
        gateFailure: ConversationSendGateFailure = .coordinatorNotLive
    ) {
        self.stamp = stamp
        self.inputAvailability = inputAvailability
        self.gateFailure = gateFailure
    }

    public init(
        stamp: ConversationComposerStamp,
        inputAvailability: CompatibleInputAvailability
    ) {
        self.stamp = stamp
        self.inputAvailability = inputAvailability
        gateFailure = nil
    }

    public var canSend: Bool {
        stamp != nil && gateFailure == nil
    }
}

public enum ConversationSendOutcome: Equatable, Sendable {
    case enqueued(clientRequestID: String)
    case notEnqueued(ConversationSendGateFailure)
}

/// Generates globally collision-resistant idempotency keys for remote sends.
/// The seam is synchronous so the coordinator can mint and reserve an ID
/// without opening an actor-reentrancy window.
public protocol SendRequestIDFactory: Sendable {
    func makeRequestID() -> String
}

public struct UUIDSendRequestIDFactory: SendRequestIDFactory {
    public init() {}

    public func makeRequestID() -> String {
        UUID().uuidString.lowercased()
    }
}

struct CoordinatorComposerSnapshot: Equatable, Sendable {
    var stamp: ConversationComposerStamp?
    var inputAvailability: CompatibleInputAvailability?
    var hasDeviceSendScope: Bool
    var coordinatorIsLive: Bool
    var gateFailure: ConversationSendGateFailure?
}

struct ConversationSendReservationKey: Equatable, Hashable, Sendable {
    var conversationID: RemoteConversationID
    var projectionRunID: RemoteProjectionRunID
    var inputEpoch: RemoteInputEpoch
}

protocol SendDispatchWaiting: Sendable {
    func waitBeforeDispatch() async
}

struct ImmediateSendDispatchWaiter: SendDispatchWaiting {
    func waitBeforeDispatch() async {}
}
