import Foundation
import Observation
import RemoteProtocol
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

/// The message shown after a done or flag change, with Undo while it
/// succeeded.
struct SubspaceDoneNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case changed(workspaceID: UUID, isDone: Bool)
        case flagChanged(conversationID: UUID, isFlagged: Bool)
        /// A session started on the Mac but has not reached the list yet.
        case sessionStarted
        case failed
    }

    let id = UUID()
    let kind: Kind
    let message: String

    var canUndo: Bool {
        switch kind {
        case .changed, .flagChanged: true
        case .sessionStarted, .failed: false
        }
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
    /// Whether the connected Mac accepts flag changes from this device.
    private(set) var hostSupportsConversationFlag: Bool
    /// Whether the connected Mac accepts new sessions from this device.
    private(set) var hostSupportsSessionStart: Bool
    private(set) var subspaceDoneNotice: SubspaceDoneNotice?
    var connectionState: MobileConnectionState
    var freshness: LiveProjectionFreshness
    private(set) var latestTransportFailure: NativeTransportFailure?
    private(set) var selectedConversationID: UUID?
    private(set) var removedSelectionMessage: String?
    private var onConversationOpened: @MainActor (UUID) -> Void = { _ in }
    private var onConversationClosed: @MainActor (UUID) -> Void = { _ in }
    private var sendSubspaceDone: (@MainActor (UUID, Bool) async -> SubspaceDoneOutcome)?
    private var sendConversationFlag: (@MainActor (UUID, Bool) async -> SubspaceDoneOutcome)?
    private var loadSessionStartOptions: (@MainActor (UUID) async -> ToasttySessionStartOptionsOutcome)?
    private var sendSessionStart: (@MainActor (RemoteSessionStartRequest) async -> ToasttySessionStartOutcome)?
    /// Flag states the user asked for that the Mac's snapshot does not show
    /// yet, by conversation, with the same rules as `pendingSubspaceDone`.
    private var pendingConversationFlag: [UUID: PendingSubspaceDone] = [:]
    private var conversationsSendingFlag: Set<UUID> = []
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
        /// The snapshot count when the user asked. Once the Mac has accepted
        /// the state, any snapshot after this is the Mac's final word even if
        /// it disagrees, as when an agent reopened the task or cleared a flag
        /// before the reply arrived.
        var sentAtOrdinal: UInt64
        var isAccepted = false

        var overrulingOrdinal: UInt64? {
            isAccepted ? sentAtOrdinal : nil
        }

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
        // Fixtures have no Mac to ask, so they apply done and flag changes
        // locally.
        hostSupportsSubspaceDone = runtimeMode == .fixture
        hostSupportsConversationFlag = runtimeMode == .fixture
        hostSupportsSessionStart = runtimeMode == .fixture
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
        hostSupportsConversationFlag: Bool? = nil,
        hostSupportsSessionStart: Bool? = nil,
        hostSnapshotStamp: Date? = nil
    ) {
        let removedConversation = selectedConversationID.flatMap { conversation(id: $0) }
        if let hostSupportsSubspaceDone {
            self.hostSupportsSubspaceDone = hostSupportsSubspaceDone
        }
        if let hostSupportsConversationFlag {
            self.hostSupportsConversationFlag = hostSupportsConversationFlag
        }
        if let hostSupportsSessionStart {
            self.hostSupportsSessionStart = hostSupportsSessionStart
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
        reconcilePendingConversationFlag()
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

    // MARK: - Flag for Later

    /// The flag works only against a live Mac that accepts the change from
    /// this device; otherwise rows show their last-known mark read-only.
    var canFlagConversations: Bool {
        hostSupportsConversationFlag && freshness == .live
    }

    func setHostSupportsConversationFlag(_ isSupported: Bool) {
        hostSupportsConversationFlag = isSupported
    }

    var hasPendingConversationFlag: Bool {
        pendingConversationFlag.isEmpty == false
    }

    func installConversationFlag(
        _ send: @escaping @MainActor (UUID, Bool) async -> SubspaceDoneOutcome
    ) {
        sendConversationFlag = send
    }

    /// Shows the flag at once, then asks the Mac, exactly as a done change.
    func setConversationFlag(_ conversationID: UUID, isFlagged: Bool, announces: Bool = true) {
        guard canFlagConversations,
              sendConversationFlag != nil || runtimeMode == .fixture,
              let conversation = conversation(id: conversationID),
              conversation.isFlaggedForLater != isFlagged else { return }
        subspaceDoneNotice = announces
            ? SubspaceDoneNotice(
                kind: .flagChanged(conversationID: conversationID, isFlagged: isFlagged),
                message: isFlagged ? "Flagged for later" : "Flag cleared"
            )
            : nil
        guard let sendConversationFlag else {
            hostSnapshot = Self.applyingFlags([conversationID: isFlagged], to: hostSnapshot)
            presentSnapshot()
            return
        }
        pendingConversationFlag[conversationID] = PendingSubspaceDone(
            isDone: isFlagged, sentAtOrdinal: hostSnapshotOrdinal
        )
        presentSnapshot()
        guard conversationsSendingFlag.insert(conversationID).inserted else { return }
        let title = ToasttySessionRowPresentation.title(for: conversation)
        Task { @MainActor [weak self] in
            await self?.sendPendingConversationFlag(conversationID, title: title, using: sendConversationFlag)
        }
    }

    private func sendPendingConversationFlag(
        _ conversationID: UUID,
        title: String,
        using send: @MainActor (UUID, Bool) async -> SubspaceDoneOutcome
    ) async {
        defer {
            conversationsSendingFlag.remove(conversationID)
            reconcilePendingConversationFlag()
            presentSnapshot()
        }
        while let requested = pendingConversationFlag[conversationID]?.isDone {
            let outcome = await send(conversationID, requested)
            guard let pending = pendingConversationFlag[conversationID] else { return }
            if pending.isDone != requested { continue }
            switch outcome {
            case .applied:
                pendingConversationFlag[conversationID]?.isAccepted = true
            case .refused, .failed:
                pendingConversationFlag[conversationID] = nil
                subspaceDoneNotice = SubspaceDoneNotice(
                    kind: .failed,
                    message: outcome == .refused
                        ? "\(title) is no longer running on your Mac."
                        : "Couldn't update \(title). Check the connection to your Mac."
                )
            }
            return
        }
    }

    private func reconcilePendingConversationFlag() {
        pendingConversationFlag = pendingConversationFlag.filter { conversationID, pending in
            guard let conversation = hostSnapshot.activitySessions.first(where: { $0.id == conversationID }) else {
                return false
            }
            if conversationsSendingFlag.contains(conversationID) { return true }
            if conversation.isFlaggedForLater == pending.isDone { return false }
            guard let overrulingOrdinal = pending.overrulingOrdinal else { return true }
            return hostSnapshotOrdinal <= overrulingOrdinal
        }
    }

    private static func applyingFlags(_ flags: [UUID: Bool], to snapshot: MobileHomeSnapshot) -> MobileHomeSnapshot {
        guard flags.isEmpty == false else { return snapshot }
        return MobileHomeSnapshot(
            hostName: snapshot.hostName,
            workspaces: snapshot.workspaces.map { workspace in
                guard workspace.conversations.contains(where: { flags[$0.id] != nil }) else { return workspace }
                return workspace.withConversations(workspace.conversations.map { conversation in
                    flags[conversation.id].map(conversation.withFlaggedForLater) ?? conversation
                })
            }
        )
    }

    // MARK: - New session

    /// New sessions start only against a live Mac that accepts them from
    /// this device. Whether this device's start permission is on is a
    /// separate answer that the start options carry.
    var canStartSessions: Bool {
        hostSupportsSessionStart && freshness == .live
    }

    /// Where a new session from Home starts: the workspace of the last
    /// session this phone started, while the Mac still lists it, otherwise
    /// the workspace Home lists first.
    func defaultSessionStartWorkspace(lastUsed: UUID?) -> MobileWorkspace? {
        lastUsed.flatMap(workspace(id:)) ?? snapshot.topLevelWorkspaces.first
    }

    func sessionStartWorkspaces(keeping keptWorkspaceIDs: Set<UUID>) -> [ToasttyNewSessionWorkspace] {
        snapshot.topLevelWorkspaces.flatMap { workspace in
            [ToasttyNewSessionWorkspace(id: workspace.id, title: workspace.title, parentTitle: nil)]
                + snapshot.subspaceRows(of: workspace.id)
                .filter { keptWorkspaceIDs.contains($0.id) }
                .map { ToasttyNewSessionWorkspace(id: $0.id, title: $0.workspace.title, parentTitle: workspace.title) }
        }
    }

    func setHostSupportsSessionStart(_ isSupported: Bool) {
        hostSupportsSessionStart = isSupported
    }

    func installSessionStart(
        options: @escaping @MainActor (UUID) async -> ToasttySessionStartOptionsOutcome,
        start: @escaping @MainActor (RemoteSessionStartRequest) async -> ToasttySessionStartOutcome
    ) {
        loadSessionStartOptions = options
        sendSessionStart = start
    }

    func sessionStartOptions(workspaceID: UUID) async -> ToasttySessionStartOptionsOutcome {
        if let loadSessionStartOptions {
            return await loadSessionStartOptions(workspaceID)
        }
        guard runtimeMode == .fixture else { return .unreachable }
        return .loaded(ToasttyMobileFixture.sessionStartOptions(for: workspace(id: workspaceID)))
    }

    func startSession(_ request: RemoteSessionStartRequest) async -> ToasttySessionStartOutcome {
        if let sendSessionStart {
            return await sendSessionStart(request)
        }
        guard runtimeMode == .fixture else { return .unconfirmed }
        return await startFixtureSession(request)
    }

    /// Says that a started session has not reached the list yet, for when
    /// the phone gives up waiting to open it.
    func announceStartedSessionPending(agentName: String) {
        subspaceDoneNotice = SubspaceDoneNotice(
            kind: .sessionStarted,
            message: "\(agentName) started on your Mac. The session will appear in the list."
        )
    }

    /// Fixture mode has no Mac, so a start adds the session to the snapshot
    /// itself after a short pause that stands in for the launch.
    private func startFixtureSession(_ request: RemoteSessionStartRequest) async -> ToasttySessionStartOutcome {
        try? await Task.sleep(for: .milliseconds(600))
        let options = ToasttyMobileFixture.sessionStartOptions(for: workspace(id: request.workspaceID))
        guard let workspace = hostSnapshot.workspaces.first(where: { $0.id == request.workspaceID }) else {
            return .answered(.rejected(reason: .workspaceNotFound))
        }
        guard let agent = options.agents.first(where: { $0.profileID == request.profileID }),
              agent.availability == .available else {
            return .answered(.rejected(reason: .agentUnavailable))
        }
        let conversation = ToasttyMobileFixture.startedConversation(
            id: UUID(),
            request: request,
            agentDisplayName: agent.displayName,
            workspace: workspace
        )
        hostSnapshot = MobileHomeSnapshot(
            hostName: hostSnapshot.hostName,
            workspaces: hostSnapshot.workspaces.map {
                $0.id == workspace.id ? $0.withConversations([conversation] + $0.conversations) : $0
            }
        )
        presentSnapshot()
        return .answered(.started(conversationID: RemoteConversationID(rawValue: conversation.id)))
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
        // Stamped when the user asks, not when the request goes out, so a
        // snapshot that arrives in between counts as after the request.
        pendingSubspaceDone[workspaceID] = PendingSubspaceDone(isDone: isDone, sentAtOrdinal: hostSnapshotOrdinal)
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
                pendingSubspaceDone[workspaceID]?.isAccepted = true
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
            guard let overrulingOrdinal = pending.overrulingOrdinal else { return true }
            return hostSnapshotOrdinal <= overrulingOrdinal
        }
    }

    func undoSubspaceDoneNotice() {
        switch subspaceDoneNotice?.kind {
        case .changed(let workspaceID, let isDone)?:
            subspaceDoneNotice = nil
            setSubspaceDone(workspaceID, isDone: !isDone, announces: false)
        case .flagChanged(let conversationID, let isFlagged)?:
            subspaceDoneNotice = nil
            setConversationFlag(conversationID, isFlagged: !isFlagged, announces: false)
        case .sessionStarted?, .failed?, nil:
            break
        }
    }

    func dismissSubspaceDoneNotice(_ notice: SubspaceDoneNotice) {
        if subspaceDoneNotice?.id == notice.id {
            subspaceDoneNotice = nil
        }
    }

    private func presentSnapshot() {
        guard pendingSubspaceDone.isEmpty == false || pendingConversationFlag.isEmpty == false else {
            if snapshot != hostSnapshot { snapshot = hostSnapshot }
            return
        }
        let withDone = MobileHomeSnapshot(
            hostName: hostSnapshot.hostName,
            workspaces: hostSnapshot.workspaces.map { workspace in
                pendingSubspaceDone[workspace.id].map { workspace.withDone($0.isDone) } ?? workspace
            }
        )
        snapshot = Self.applyingFlags(pendingConversationFlag.mapValues(\.isDone), to: withDone)
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

    /// Sessions that want the user, for the app badge and the conversation
    /// screen's Next button. Approvals come first because they
    /// block an agent, then errors, then unread finished turns; within a
    /// status, Home's recency order applies. Next excludes its current session.
    func sessionsNeedingAttention(excluding conversationID: UUID? = nil) -> [MobileConversation] {
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
