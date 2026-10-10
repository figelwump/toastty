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
    /// For `prompt`, the open-prompt epoch; for `queue` and `steer`, the
    /// running turn's epoch from the host's input controls.
    public let inputEpoch: RemoteInputEpoch
    public let deliveryMode: RemoteMessageDeliveryMode

    public init(
        connectionGeneration: UInt64,
        streamSnapshotOrdinal: UInt64,
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64,
        latestSequence: UInt64,
        inputEpoch: RemoteInputEpoch,
        deliveryMode: RemoteMessageDeliveryMode = .prompt
    ) {
        self.connectionGeneration = connectionGeneration
        self.streamSnapshotOrdinal = streamSnapshotOrdinal
        self.projectionRunID = projectionRunID
        self.projectionGeneration = projectionGeneration
        self.latestSequence = latestSequence
        self.inputEpoch = inputEpoch
        self.deliveryMode = deliveryMode
    }

    /// The same stamp with another delivery mode for the same turn. Only a
    /// working-turn stamp can change mode; a prompt stamp stays a prompt.
    public func withDeliveryMode(_ mode: RemoteMessageDeliveryMode) -> ConversationComposerStamp {
        guard deliveryMode != .prompt, mode != .prompt else { return self }
        return ConversationComposerStamp(
            connectionGeneration: connectionGeneration,
            streamSnapshotOrdinal: streamSnapshotOrdinal,
            projectionRunID: projectionRunID,
            projectionGeneration: projectionGeneration,
            latestSequence: latestSequence,
            inputEpoch: inputEpoch,
            deliveryMode: mode
        )
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
    /// The host's queue, steer, and stop controls for the same snapshot the
    /// stamp came from.
    public let inputControl: RemoteConversationInputControl?

    public init(
        stamp: ConversationComposerStamp? = nil,
        inputAvailability: CompatibleInputAvailability? = nil,
        gateFailure: ConversationSendGateFailure = .coordinatorNotLive,
        inputControl: RemoteConversationInputControl? = nil
    ) {
        self.stamp = stamp
        self.inputAvailability = inputAvailability
        self.gateFailure = gateFailure
        self.inputControl = inputControl
    }

    public init(
        stamp: ConversationComposerStamp,
        inputAvailability: CompatibleInputAvailability,
        inputControl: RemoteConversationInputControl? = nil
    ) {
        self.stamp = stamp
        self.inputAvailability = inputAvailability
        self.inputControl = inputControl
        gateFailure = nil
    }

    public var canSend: Bool {
        stamp != nil && gateFailure == nil
    }

    /// A steer into the running turn is possible right now.
    public var canSteer: Bool {
        canSend && stamp?.deliveryMode != .prompt && inputControl?.canSteer == true
    }

    /// The running turn can be stopped from this device right now. A stop
    /// is not a send, so a reserved or in-flight send does not block it.
    public var canInterrupt: Bool {
        guard let inputControl, inputControl.canInterrupt, inputControl.turnEpoch != nil else { return false }
        switch gateFailure {
        case nil, .sendAlreadyReserved, .tooManyUnresolvedSends, .emptyText, .messageTooLarge,
             .requestEncodingFailed, .cancelled, .attachmentsUnsupported, .invalidAttachments:
            return true
        case .coordinatorNotLive, .deviceSendScopeDenied, .conversationNotOpen, .conversationMissing,
             .staleComposerAuthority, .conversationNotLive, .transcriptNotCaughtUp, .inputUnavailable:
            return false
        }
    }

    /// The Mac draft epoch a release would name, while a Mac draft holds the
    /// prompt closed and this device's live snapshot and send access allow a
    /// release. Releasing sends no text, so transcript catch-up does not
    /// block it.
    public var releasableLocalDraftEpoch: RemoteInputEpoch? {
        guard case .localDraft(let epoch) = inputAvailability else { return nil }
        switch gateFailure {
        case nil, .inputUnavailable, .transcriptNotCaughtUp:
            return epoch
        case .coordinatorNotLive, .deviceSendScopeDenied, .conversationNotOpen, .conversationMissing,
             .staleComposerAuthority, .conversationNotLive, .sendAlreadyReserved, .tooManyUnresolvedSends,
             .emptyText, .messageTooLarge, .requestEncodingFailed, .cancelled, .attachmentsUnsupported,
             .invalidAttachments:
            return nil
        }
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
    var inputControl: RemoteConversationInputControl? = nil
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
