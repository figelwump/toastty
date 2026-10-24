import Combine
import CoreState
import Foundation
import RemoteProtocol

/// Coalesces app notifications into one idle-only message through the shared
/// conversation authority. It owns neither a provider nor an event journal.
@MainActor
final class CoordinatorWakeController {
    struct Input {
        var hasDraft = false
        var hasAttachments = false
        var userSendInFlight = false
        var conversationID: RemoteConversationID?
        var inputEpoch: RemoteInputEpoch?
        var hasQueuedMessages = false
        var hasPendingInteractions = false

        var userIsBusy: Bool { hasDraft || hasAttachments || userSendInFlight }
        var canSend: Bool {
            !userIsBusy && conversationID != nil && inputEpoch != nil
                && !hasQueuedMessages && !hasPendingInteractions
        }
    }

    struct Snapshot {
        var enabled: Bool
        var sessionStatus: CoordinatorSessionStatus
        var hasBackingIdentity: Bool
        var candidates: [CoordinatorWakeCandidate]
        var input: Input
        var reviewReadError: String?
    }

    struct Dependencies {
        var snapshot: @MainActor () -> Snapshot
        var start: @MainActor () async -> Void
        var send: @MainActor (RemoteMessageSendRequest) async -> RemoteMessageSendResult
        var notice: @MainActor (String) -> Void
    }

    private let dependencies: Dependencies
    private let stateURL: URL
    private var state = CoordinatorWakeState()
    private var subscriptions: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var processing = false
    private var changedDuringProcessing = false
    private var storageFailed = false
    private var lastNotice: String?

    convenience init(board: TaskBoardStore, reviews: CoordinatorReviewStore, session: CoordinatorSessionController,
                     conversation: CoordinatorConversationModel, service: ConversationService, runtimePaths: ToasttyRuntimePaths) {
        self.init(stateURL: runtimePaths.configDirectoryURL.appendingPathComponent("coordinator-wake.json"),
            dependencies: Dependencies(snapshot: {
                let id = session.identity.flatMap { service.conversationID(for: $0.panelID) }
                let snapshot = id.flatMap { service.localSnapshot(for: $0, at: Date()) }
                let epoch: RemoteInputEpoch?
                if case .openPrompt(let value) = snapshot?.summary.inputAvailability { epoch = value }
                else { epoch = nil }
                return Snapshot(enabled: session.automaticWorkEnabled, sessionStatus: session.status,
                    hasBackingIdentity: session.identity != nil,
                    candidates: CoordinatorWakeCandidate.reconcile(items: board.items(), reviews: reviews.items),
                    input: Input(hasDraft: !conversation.draft.isEmpty,
                        hasAttachments: !conversation.attachments.isEmpty, userSendInFlight: conversation.sending,
                        conversationID: id, inputEpoch: epoch,
                        hasQueuedMessages: snapshot?.summary.inputControl?.queuedMessages.isEmpty == false,
                        hasPendingInteractions: snapshot?.pendingInteractions.isEmpty == false),
                    reviewReadError: reviews.loadError)
            }, start: { await session.startIfAutomaticWorkEnabled() },
            send: { await service.sendLocal($0) }, notice: { conversation.notice = $0 }))
        board.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        reviews.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        session.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        conversation.$snapshot.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        conversation.$draft.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        conversation.$attachments.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        conversation.$sending.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        schedule()
    }

    /// The injected boundary keeps lifecycle tests independent of provider
    /// processes while exercising the same persistence and delivery decisions.
    init(stateURL: URL, dependencies: Dependencies) {
        self.stateURL = stateURL
        self.dependencies = dependencies
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do {
                state = try JSONDecoder().decode(CoordinatorWakeState.self, from: Data(contentsOf: stateURL))
                guard state.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            } catch {
                storageFailed = true
                dependencies.notice("Automatic review preparation paused: saved wake state could not be read.")
            }
        }
    }

    deinit { pending?.cancel() }

    func taskFactsDidChange() { schedule() }

    private func schedule() {
        if processing { changedDuringProcessing = true; return }
        // A stream of unrelated transcript updates must not keep postponing
        // reconciliation forever. Coalesce within a fixed two-second window.
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { self?.pending = nil; return }
            self?.pending = nil
            await self?.reconcile()
        }
    }

    func reconcile() async {
        guard !storageFailed else { return }
        if processing { changedDuringProcessing = true; return }
        let snapshot = dependencies.snapshot()
        guard snapshot.enabled, !snapshot.input.userIsBusy else { return }
        guard snapshot.reviewReadError == nil else {
            showNotice("Automatic review preparation paused: review records could not be read.")
            return
        }
        lastNotice = nil
        processing = true
        defer {
            processing = false
            if changedDuringProcessing {
                changedDuringProcessing = false
                schedule()
            }
        }
        var next = state
        let allChanged = next.plan(snapshot.candidates)
        // Keep one prompt bounded. Unattempted tasks remain pending and can
        // follow when the provider next returns to an open prompt.
        let changed = Array(allChanged.prefix(64))
        if next != state, !persist(next) { return }
        guard !changed.isEmpty else { return }
        guard snapshot.sessionStatus == .running else {
            // Once a backing session exists, stopped/error/restore states all
            // need user action or the native restore path. They are not a
            // reason to relaunch in response to the launcher's own updates.
            guard snapshot.sessionStatus == .stopped, !snapshot.hasBackingIdentity,
                  !state.automaticStartAttempted else { return }
            next = state
            next.automaticStartAttempted = true
            guard persist(next) else { return }
            await dependencies.start()
            // A successful start can be ready without publishing another
            // notification. Recheck input on a later coalesced pass.
            changedDuringProcessing = true
            return
        }
        guard snapshot.input.canSend,
              let id = snapshot.input.conversationID, let epoch = snapshot.input.inputEpoch else { return }
        next = state
        for fact in changed { next.handled[fact.taskID.uuidString] = fact }
        guard persist(next) else { return }
        let taskIDs = changed.map { $0.taskID.uuidString }.joined(separator: ", ")
        let result = await dependencies.send(.init(conversationID: id, clientRequestID: UUID().uuidString,
            expectedInputEpoch: epoch,
            text: "Task outcomes changed. Use the toastty-coordinator skill. Reconcile current task and review records for task IDs: \(taskIDs). Prepare or refresh missing review briefs from evidence and explain changed outcomes. Do not approve or merge. User input takes priority."))
        switch result {
        case .rejected:
            // Do not create an automatic retry loop from the send's own state
            // changes. The user can ask for review preparation in normal chat.
            showNotice("Automatic review preparation was not sent. Ask the Coordinator to refresh reviews when ready.")
        case .uncertain:
            showNotice("Automatic review request delivery is uncertain. Inspect the Coordinator terminal; Toastty will not replay it.")
        case .accepted, .duplicate, .queued:
            if allChanged.count > changed.count { changedDuringProcessing = true }
        }
    }

    private func persist(_ next: CoordinatorWakeState) -> Bool {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: stateURL, options: .atomic)
            state = next
            return true
        } catch {
            storageFailed = true
            showNotice("Automatic review preparation paused: wake state could not be saved.")
            return false
        }
    }

    private func showNotice(_ message: String) {
        guard message != lastNotice else { return }
        lastNotice = message
        dependencies.notice(message)
    }
}
