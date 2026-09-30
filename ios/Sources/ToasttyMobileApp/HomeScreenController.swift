import Foundation
import Observation
import ToasttyMobileDomain

struct SelectedConversationPresentation: Identifiable, Equatable {
    let id: UUID
}

/// What the Mac said about a request to mark a subspace done or open again.
enum SubspaceDoneOutcome: Equatable, Sendable {
    /// The Mac holds the requested state, newly or already.
    case applied
    /// The Mac refused: the workspace is gone or is no longer a subspace.
    case refused
    /// The request could not be sent or answered.
    case failed
}

/// The message shown after a done change, with Undo while it succeeded.
struct SubspaceDoneNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case changed(workspaceID: UUID, isDone: Bool)
        case failed
    }

    let id = UUID()
    let kind: Kind
    let message: String

    var canUndo: Bool {
        if case .changed = kind { return true }
        return false
    }
}

@MainActor
@Observable
final class HomeScreenController {
    let runtimeMode: ToasttyMobileRuntimeMode
    /// What the views show: the Mac's snapshot with done changes that are
    /// still on their way to the Mac applied.
    private(set) var snapshot: MobileHomeSnapshot
    /// The Mac's latest snapshot, without pending done changes.
    private(set) var hostSnapshot: MobileHomeSnapshot
    /// Whether the connected Mac accepts done changes from this device.
    private(set) var hostSupportsSubspaceDone: Bool
    private(set) var subspaceDoneNotice: SubspaceDoneNotice?
    var connectionState: MobileConnectionState
    var freshness: LiveProjectionFreshness
    private(set) var latestTransportFailure: NativeTransportFailure?
    private(set) var selectedConversationID: UUID?
    private(set) var removedSelectionMessage: String?
    private var onConversationOpened: @MainActor (UUID) -> Void = { _ in }
    private var onConversationClosed: @MainActor (UUID) -> Void = { _ in }
    private var sendSubspaceDone: (@MainActor (UUID, Bool) async -> SubspaceDoneOutcome)?
    /// Done states the user asked for that the Mac's snapshot does not show
    /// yet, by subspace.
    private var pendingSubspaceDone: [UUID: PendingSubspaceDone] = [:]
    /// Subspaces with a request on its way to the Mac. Requests for one
    /// subspace go out one at a time, so the Mac ends on the last state asked
    /// for however the replies are delayed.
    private var subspacesSendingDone: Set<UUID> = []
    /// Counts the Mac's snapshots, to tell one that arrived after a reply
    /// from the same one presented again.
    private var hostSnapshotOrdinal: UInt64 = 0
    private var hostSnapshotStamp: Date?

    private struct PendingSubspaceDone {
        var isDone: Bool
        /// The snapshot count when the Mac accepted the state, or `nil` until
        /// it has. A later snapshot is the Mac's final word even if it
        /// disagrees, as when an agent reopened the task.
        var acceptedAtOrdinal: UInt64?
    }

    init(
        runtimeMode: ToasttyMobileRuntimeMode,
        snapshot: MobileHomeSnapshot,
        connectionState: MobileConnectionState,
        freshness: LiveProjectionFreshness? = nil,
        latestTransportFailure: NativeTransportFailure? = nil
    ) {
        self.runtimeMode = runtimeMode
        self.snapshot = snapshot
        hostSnapshot = snapshot
        // Fixtures have no Mac to ask, so they apply done changes locally.
        hostSupportsSubspaceDone = runtimeMode == .fixture
        self.connectionState = connectionState
        self.freshness = freshness ?? Self.freshness(for: connectionState)
        self.latestTransportFailure = latestTransportFailure
    }

    func open(_ conversation: MobileConversation) {
        selectConversation(conversation.id)
    }

    @discardableResult
    func openConversation(id: UUID) -> Bool {
        guard conversation(id: id) != nil else { return false }
        selectConversation(id)
        return true
    }

    func dismissConversation() {
        selectConversation(nil)
    }

    func update(
        snapshot newSnapshot: MobileHomeSnapshot,
        connectionState: MobileConnectionState,
        freshness: LiveProjectionFreshness,
        latestTransportFailure: NativeTransportFailure? = nil,
        hostSupportsSubspaceDone: Bool? = nil,
        hostSnapshotStamp: Date? = nil
    ) {
        let removedConversation = selectedConversationID.flatMap { conversation(id: $0) }
        if let hostSupportsSubspaceDone {
            self.hostSupportsSubspaceDone = hostSupportsSubspaceDone
        }
        // The same Mac snapshot is presented again whenever the connection
        // state changes, with fresh ages, so equality cannot tell a new one.
        // The Mac stamps each snapshot; callers without a stamp replace the
        // snapshot outright.
        if hostSnapshotStamp == nil || hostSnapshotStamp != self.hostSnapshotStamp {
            hostSnapshotOrdinal += 1
        }
        self.hostSnapshotStamp = hostSnapshotStamp
        hostSnapshot = newSnapshot
        reconcilePendingSubspaceDone()
        presentSnapshot()
        self.connectionState = connectionState
        self.freshness = freshness
        self.latestTransportFailure = latestTransportFailure

        if let removedConversation, conversation(id: removedConversation.id) == nil {
            selectConversation(nil)
            removedSelectionMessage = "\(removedConversation.title) is no longer available on your Mac."
        }
    }

    // MARK: - Subspace done

    /// The done checkbox works only against a live Mac that accepts the
    /// change. Otherwise rows show their last-known mark read-only.
    var canMarkSubspacesDone: Bool {
        hostSupportsSubspaceDone && freshness == .live
    }

    func setHostSupportsSubspaceDone(_ isSupported: Bool) {
        hostSupportsSubspaceDone = isSupported
    }

    /// Whether a done change is still waiting on the Mac.
    var hasPendingSubspaceDone: Bool {
        pendingSubspaceDone.isEmpty == false
    }

    func installSubspaceDone(
        _ send: @escaping @MainActor (UUID, Bool) async -> SubspaceDoneOutcome
    ) {
        sendSubspaceDone = send
    }

    /// Shows the change at once, then asks the Mac. The Mac's snapshot
    /// confirms it; a refusal or failure puts the row back and says so.
    func setSubspaceDone(_ workspaceID: UUID, isDone: Bool, announces: Bool = true) {
        guard canMarkSubspacesDone,
              sendSubspaceDone != nil || runtimeMode == .fixture,
              let row = snapshot.subspaceRow(id: workspaceID),
              row.workspace.isDone != isDone else { return }
        subspaceDoneNotice = announces
            ? SubspaceDoneNotice(
                kind: .changed(workspaceID: workspaceID, isDone: isDone),
                message: isDone ? "Marked done" : "Marked not done"
            )
            : nil
        guard let sendSubspaceDone else {
            // Fixture mode: there is no Mac, so the change is the snapshot.
            hostSnapshot = MobileHomeSnapshot(
                hostName: hostSnapshot.hostName,
                workspaces: hostSnapshot.workspaces.map {
                    $0.id == workspaceID ? $0.withDone(isDone) : $0
                }
            )
            presentSnapshot()
            return
        }
        pendingSubspaceDone[workspaceID] = PendingSubspaceDone(isDone: isDone)
        presentSnapshot()
        guard subspacesSendingDone.insert(workspaceID).inserted else {
            // The request already on its way finishes first; its loop then
            // sends this newer state.
            return
        }
        let title = row.workspace.title
        Task { @MainActor [weak self] in
            await self?.sendPendingSubspaceDone(workspaceID, title: title, using: sendSubspaceDone)
        }
    }

    private func sendPendingSubspaceDone(
        _ workspaceID: UUID,
        title: String,
        using send: @MainActor (UUID, Bool) async -> SubspaceDoneOutcome
    ) async {
        defer {
            subspacesSendingDone.remove(workspaceID)
            reconcilePendingSubspaceDone()
            presentSnapshot()
        }
        while let requested = pendingSubspaceDone[workspaceID]?.isDone {
            let outcome = await send(workspaceID, requested)
            guard let pending = pendingSubspaceDone[workspaceID] else { return }
            // The user changed their mind while this was on its way.
            if pending.isDone != requested { continue }
            switch outcome {
            case .applied:
                pendingSubspaceDone[workspaceID]?.acceptedAtOrdinal = hostSnapshotOrdinal
            case .refused, .failed:
                pendingSubspaceDone[workspaceID] = nil
                subspaceDoneNotice = SubspaceDoneNotice(
                    kind: .failed,
                    message: outcome == .refused
                        ? "\(title) can't be marked done right now."
                        : "Couldn't update \(title). Check the connection to your Mac."
                )
            }
            return
        }
    }

    /// Drops pending states the Mac's snapshot has caught up with or
    /// overruled. A subspace with a request on its way keeps its pending
    /// state, since the snapshot may predate that request.
    private func reconcilePendingSubspaceDone() {
        pendingSubspaceDone = pendingSubspaceDone.filter { workspaceID, pending in
            guard let workspace = hostSnapshot.workspaces.first(where: { $0.id == workspaceID }) else {
                return false
            }
            if subspacesSendingDone.contains(workspaceID) { return true }
            if workspace.isDone == pending.isDone { return false }
            guard let acceptedAtOrdinal = pending.acceptedAtOrdinal else { return true }
            return hostSnapshotOrdinal <= acceptedAtOrdinal
        }
    }

    func undoSubspaceDoneNotice() {
        guard case .changed(let workspaceID, let isDone)? = subspaceDoneNotice?.kind else { return }
        subspaceDoneNotice = nil
        setSubspaceDone(workspaceID, isDone: !isDone, announces: false)
    }

    func dismissSubspaceDoneNotice(_ notice: SubspaceDoneNotice) {
        if subspaceDoneNotice?.id == notice.id {
            subspaceDoneNotice = nil
        }
    }

    private func presentSnapshot() {
        guard pendingSubspaceDone.isEmpty == false else {
            if snapshot != hostSnapshot { snapshot = hostSnapshot }
            return
        }
        snapshot = MobileHomeSnapshot(
            hostName: hostSnapshot.hostName,
            workspaces: hostSnapshot.workspaces.map { workspace in
                pendingSubspaceDone[workspace.id].map { workspace.withDone($0.isDone) } ?? workspace
            }
        )
    }

    func workspace(id: UUID) -> MobileWorkspace? {
        snapshot.workspaces.first { $0.id == id }
    }

    func conversation(id: UUID) -> MobileConversation? {
        snapshot.workspaces
            .lazy
            .flatMap(\.conversations)
            .first { $0.id == id }
    }

    /// Sessions other than `conversationID` that want the user, for the
    /// conversation screen's Next button. Approvals come first because they
    /// block an agent, then errors, then unread finished turns; within a
    /// status, Home's recency order applies.
    func sessionsNeedingAttention(excluding conversationID: UUID) -> [MobileConversation] {
        // A finished turn in a subspace marked done is one the user already
        // waved off, often the very turn that set the mark.
        let doneSubspaceIDs = Set(snapshot.workspaces.lazy.filter {
            self.snapshot.subspaceRow(id: $0.id)?.status == .done
        }.map(\.id))
        let others = snapshot.activitySessions.filter {
            $0.id != conversationID
                && ($0.state.bucket == .ready && doneSubspaceIDs.contains($0.workspaceID)) == false
        }
        return [MobileSessionBucket.needsApproval, .error, .ready].flatMap { bucket in
            others.filter { $0.state.bucket == bucket }
        }
    }

    var selectedConversation: MobileConversation? {
        selectedConversationID.flatMap(conversation(id:))
    }

    var selectedConversationPresentation: SelectedConversationPresentation? {
        get {
            selectedConversationID.map(SelectedConversationPresentation.init(id:))
        }
        set {
            selectConversation(newValue?.id)
        }
    }

    func installConversationLifecycle(
        onOpen: @escaping @MainActor (UUID) -> Void,
        onClose: @escaping @MainActor (UUID) -> Void
    ) {
        onConversationOpened = onOpen
        onConversationClosed = onClose
        if let selectedConversationID {
            onConversationOpened(selectedConversationID)
        }
    }

    func dismissRemovalMessage() {
        removedSelectionMessage = nil
    }

    var connectionNoticeMessage: String? {
        guard freshness != .live else { return nil }
        guard let latestTransportFailure else { return freshness.message }

        let detail = switch latestTransportFailure {
        case .offline:
            "This iPhone appears to be offline. Check its internet connection and make sure Tailscale is connected."
        case .dns:
            "Toastty couldn't find your Mac. Make sure Tailscale is connected on both devices and both are using the same tailnet."
        case .tls:
            "Toastty couldn't establish a secure connection to your Mac. Check Tailscale and confirm the Tailnet hostname in Toastty's Remote Access settings."
        case .cannotConnect, .timedOut, .connectionLost:
            "Toastty can't reach your Mac. Make sure the Mac is awake, Toastty is running, and Remote Access is enabled. If those are already true, restart Toastty."
        case .other:
            "Toastty couldn't connect to your Mac. Check Tailscale on both devices, then make sure Toastty is running with Remote Access enabled. If so, restart Toastty."
        }
        return "\(detail) After making changes, tap Retry or wait for Toastty to try automatically."
    }

    private func selectConversation(_ conversationID: UUID?) {
        guard selectedConversationID != conversationID else { return }
        if let selectedConversationID {
            onConversationClosed(selectedConversationID)
        }
        selectedConversationID = conversationID
        if let conversationID {
            onConversationOpened(conversationID)
        }
    }

    private static func freshness(for state: MobileConnectionState) -> LiveProjectionFreshness {
        switch state {
        case .live: .live
        case .reconnecting: .reconnecting
        case .offline: .unreachable
        }
    }
}
