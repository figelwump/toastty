import Foundation
import Observation
import RemoteProtocol
import ToasttyMobileDomain

enum LiveConnectionTerminal: Equatable, Sendable {
    case requiresAuthentication
    case authorizationDenied
    case incompatibleProtocol(version: String)
}

protocol LiveConnectionRuntime: Sendable {
    func currentCoordinatorState() async -> ConnectionCoordinator.State
    func coordinatorStates() async -> AsyncStream<ConnectionCoordinator.State>
    func sessionsStates() async -> AsyncStream<SessionsRuntime.State>
    func connectIfNeeded() async
    func resume(lifecycleSequence: UInt64, backgroundedAt: ContinuousClock.Instant?) async
    func enterBackground(lifecycleSequence: UInt64) async
    func restart() async
    func suspend() async
    func openConversation(_ conversationID: RemoteConversationID) async -> ConversationRuntime
    func closeConversation(_ conversationID: RemoteConversationID) async
    func loadOlder(_ conversationID: RemoteConversationID) async
    func updateDeviceScopes(_ scopes: [RemoteDeviceScope]) async
    func sendMessage(
        conversationID: RemoteConversationID,
        text: String,
        composerStamp: ConversationComposerStamp
    ) async -> ConversationSendOutcome
    func sendMessage(
        conversationID: RemoteConversationID,
        text: String,
        attachments: [RemoteMessageAttachment],
        composerStamp: ConversationComposerStamp
    ) async -> ConversationSendOutcome
    func answerQuestion(
        _ request: RemoteQuestionAnswerRequest
    ) async throws -> RemoteQuestionAnswerResult
    func dismissSendReceipt(
        conversationID: RemoteConversationID,
        clientRequestID: String
    ) async
    func acknowledgeConversationRead(
        _ request: RemoteConversationReadAcknowledgementRequest
    ) async throws -> RemoteConversationReadAcknowledgementResponse?
    func setWorkspaceDone(
        _ request: RemoteWorkspaceDoneRequest
    ) async throws -> RemoteWorkspaceDoneResponse?
    func setConversationFlag(
        _ request: RemoteConversationFlagRequest
    ) async throws -> RemoteConversationFlagResponse?
    func sessionStartOptions(
        _ request: RemoteSessionStartOptionsRequest
    ) async throws -> RemoteSessionStartOptionsResponse?
    func startSession(
        _ request: RemoteSessionStartRequest
    ) async throws -> RemoteSessionStartResponse?
}

extension LiveConnectionRuntime {
    func setWorkspaceDone(
        _ request: RemoteWorkspaceDoneRequest
    ) async throws -> RemoteWorkspaceDoneResponse? {
        nil
    }

    func setConversationFlag(
        _ request: RemoteConversationFlagRequest
    ) async throws -> RemoteConversationFlagResponse? {
        nil
    }

    func sessionStartOptions(
        _ request: RemoteSessionStartOptionsRequest
    ) async throws -> RemoteSessionStartOptionsResponse? {
        nil
    }

    func startSession(
        _ request: RemoteSessionStartRequest
    ) async throws -> RemoteSessionStartResponse? {
        nil
    }

    func sendMessage(
        conversationID: RemoteConversationID,
        text: String,
        attachments: [RemoteMessageAttachment],
        composerStamp: ConversationComposerStamp
    ) async -> ConversationSendOutcome {
        guard attachments.isEmpty else { return .notEnqueued(.attachmentsUnsupported) }
        return await sendMessage(conversationID: conversationID, text: text, composerStamp: composerStamp)
    }

    func answerQuestion(
        _ request: RemoteQuestionAnswerRequest
    ) async throws -> RemoteQuestionAnswerResult {
        .rejected(reason: .unsupported)
    }
}

struct ConnectionCoordinatorLiveRuntime: LiveConnectionRuntime {
    let coordinator: ConnectionCoordinator

    func currentCoordinatorState() async -> ConnectionCoordinator.State {
        await coordinator.currentState()
    }

    func coordinatorStates() async -> AsyncStream<ConnectionCoordinator.State> {
        await coordinator.states()
    }

    func sessionsStates() async -> AsyncStream<SessionsRuntime.State> {
        let sessions = await coordinator.sessionProjection()
        return await sessions.states()
    }

    func connectIfNeeded() async {
        await coordinator.connectIfNeeded()
    }

    func resume(lifecycleSequence: UInt64, backgroundedAt: ContinuousClock.Instant?) async {
        await coordinator.resume(lifecycleSequence: lifecycleSequence, backgroundedAt: backgroundedAt)
    }

    func enterBackground(lifecycleSequence: UInt64) async {
        await coordinator.enterBackground(lifecycleSequence: lifecycleSequence)
    }

    func restart() async {
        await coordinator.restart()
    }

    func suspend() async {
        await coordinator.suspend()
    }

    func openConversation(_ conversationID: RemoteConversationID) async -> ConversationRuntime {
        await coordinator.openConversation(conversationID)
    }

    func closeConversation(_ conversationID: RemoteConversationID) async {
        await coordinator.closeConversation(conversationID)
    }

    func loadOlder(_ conversationID: RemoteConversationID) async {
        await coordinator.loadOlder(conversationID)
    }

    func updateDeviceScopes(_ scopes: [RemoteDeviceScope]) async {
        await coordinator.updateDeviceScopes(scopes)
    }

    func sendMessage(
        conversationID: RemoteConversationID,
        text: String,
        composerStamp: ConversationComposerStamp
    ) async -> ConversationSendOutcome {
        await coordinator.sendMessage(
            conversationID: conversationID,
            text: text,
            composerStamp: composerStamp
        )
    }

    func sendMessage(
        conversationID: RemoteConversationID,
        text: String,
        attachments: [RemoteMessageAttachment],
        composerStamp: ConversationComposerStamp
    ) async -> ConversationSendOutcome {
        await coordinator.sendMessage(conversationID: conversationID, text: text,
                                      attachments: attachments, composerStamp: composerStamp)
    }

    func answerQuestion(
        _ request: RemoteQuestionAnswerRequest
    ) async throws -> RemoteQuestionAnswerResult {
        try await coordinator.answerQuestion(request)
    }

    func dismissSendReceipt(
        conversationID: RemoteConversationID,
        clientRequestID: String
    ) async {
        await coordinator.dismissSendReceipt(
            conversationID: conversationID,
            clientRequestID: clientRequestID
        )
    }

    func acknowledgeConversationRead(
        _ request: RemoteConversationReadAcknowledgementRequest
    ) async throws -> RemoteConversationReadAcknowledgementResponse? {
        try await coordinator.acknowledgeConversationRead(request)
    }

    func setWorkspaceDone(
        _ request: RemoteWorkspaceDoneRequest
    ) async throws -> RemoteWorkspaceDoneResponse? {
        try await coordinator.setWorkspaceDone(request)
    }

    func setConversationFlag(
        _ request: RemoteConversationFlagRequest
    ) async throws -> RemoteConversationFlagResponse? {
        try await coordinator.setConversationFlag(request)
    }

    func sessionStartOptions(
        _ request: RemoteSessionStartOptionsRequest
    ) async throws -> RemoteSessionStartOptionsResponse? {
        try await coordinator.sessionStartOptions(request)
    }

    func startSession(
        _ request: RemoteSessionStartRequest
    ) async throws -> RemoteSessionStartResponse? {
        try await coordinator.startSession(request)
    }
}

/// Main-actor presentation bridge over the domain actors.
///
/// The actors remain the source of truth. This bridge only resolves their
/// latest values into stable identifiers and small read-only presentation
/// values for SwiftUI.
@MainActor
@Observable
final class LiveSessionsController {
    let homeController: HomeScreenController

    private(set) var projectionRunID: String?
    private(set) var projectionGeneration: UInt64?
    private(set) var activeConversationController: LiveConversationController?

    var activeConversationCursor: UInt64? {
        activeConversationController?.cursor?.afterSequence
    }

    var supportsPushNotifications: Bool {
        coordinatorState.capabilities.contains(.pushNotifications) && deviceScopes.contains(.read)
    }

    var onDiagnosticEvent: @MainActor (ToasttyConnectionDiagnosticEvent) -> Void = { _ in }

    private let runtime: any LiveConnectionRuntime
    private let hostName: String
    private let onFreshness: @MainActor (LiveProjectionFreshness) -> Void
    private let onTerminal: @MainActor (LiveConnectionTerminal) -> Void
    private let connectionPresentationDelay: Duration
    private var coordinatorTask: Task<Void, Never>?
    private var sessionsTask: Task<Void, Never>?
    private var coordinatorState = ConnectionCoordinator.State()
    private var deviceScopes: [RemoteDeviceScope] = []
    private var sessionsState = SessionsRuntime.State()
    /// Carries per-session bucket-entry anchors across snapshots so home
    /// lists reorder only on status transitions, not on streamed activity.
    private var stateTransitions = MobileStateTransitionTracker()
    private var connectionPresentationTask: Task<Void, Never>?
    private var suppressesConnectionDowngrade = false
    private var wasBackgrounded = false
    private var desiredConversationID: UUID?
    private var conversationRequestID = UUID()
    private var conversationOpenOperations: [UUID: ConversationOpenOperation] = [:]
    private var conversationRuntimeOwners: [RemoteConversationID: UUID] = [:]

    init(
        runtime: any LiveConnectionRuntime,
        hostName: String,
        homeController: HomeScreenController,
        onTerminal: @escaping @MainActor (LiveConnectionTerminal) -> Void = { _ in },
        onFreshness: @escaping @MainActor (LiveProjectionFreshness) -> Void = { _ in },
        connectionPresentationDelay: Duration = .milliseconds(750)
    ) {
        self.runtime = runtime
        self.hostName = hostName
        self.homeController = homeController
        self.onFreshness = onFreshness
        self.onTerminal = onTerminal
        self.connectionPresentationDelay = connectionPresentationDelay
        homeController.installSubspaceDone { [runtime] workspaceID, isDone in
            do {
                let response = try await runtime.setWorkspaceDone(
                    RemoteWorkspaceDoneRequest(workspaceID: workspaceID, done: isDone)
                )
                switch response?.result {
                case .updated?, .unchanged?: return .applied
                case .notSubspace?, .workspaceNotFound?, .workInProgress?: return .refused
                // The connection dropped or the Mac stopped accepting the
                // change between the tap and the request.
                case nil: return .failed
                }
            } catch {
                return .failed
            }
        }
        homeController.installConversationFlag { [runtime] conversationID, isFlagged in
            do {
                let response = try await runtime.setConversationFlag(
                    RemoteConversationFlagRequest(
                        conversationID: RemoteConversationID(rawValue: conversationID), flagged: isFlagged
                    )
                )
                switch response?.result {
                case .updated?, .unchanged?: return .applied
                case .conversationNotFound?: return .refused
                case nil: return .failed
                }
            } catch {
                return .failed
            }
        }
        homeController.installSessionStart(
            options: { [runtime] workspaceID in
                do {
                    let response = try await runtime.sessionStartOptions(
                        RemoteSessionStartOptionsRequest(workspaceID: workspaceID)
                    )
                    return response.map(ToasttySessionStartOptionsOutcome.loaded) ?? .unreachable
                } catch {
                    return .unreachable
                }
            },
            start: { [runtime] request in
                // Any failure leaves it unknown whether the Mac started the
                // session, so the caller retries with the same request ID.
                do {
                    let response = try await runtime.startSession(request)
                    return response.map { .answered($0.result) } ?? .unconfirmed
                } catch {
                    return .unconfirmed
                }
            }
        )
        homeController.installConversationLifecycle(
            onOpen: { [weak self] conversationID in
                Task { @MainActor [weak self] in
                    await self?.openConversation(conversationID)
                }
            },
            onClose: { [weak self] conversationID in
                Task { @MainActor [weak self] in
                    await self?.closeConversation(conversationID)
                }
            }
        )
    }

    convenience init(
        coordinator: ConnectionCoordinator,
        hostName: String,
        homeController: HomeScreenController,
        onTerminal: @escaping @MainActor (LiveConnectionTerminal) -> Void = { _ in },
        onFreshness: @escaping @MainActor (LiveProjectionFreshness) -> Void = { _ in }
    ) {
        self.init(
            runtime: ConnectionCoordinatorLiveRuntime(coordinator: coordinator),
            hostName: hostName,
            homeController: homeController,
            onTerminal: onTerminal,
            onFreshness: onFreshness
        )
    }

    func start() async {
        startObservingIfNeeded()
        await runtime.connectIfNeeded()
    }

    /// A short return probes the retained stream; a disconnected or expired
    /// stream takes the coordinator's normal fresh-snapshot path.
    func foreground(lifecycleSequence: UInt64, backgroundedAt: ContinuousClock.Instant? = nil) async {
        startObservingIfNeeded()
        if (wasBackgrounded || backgroundedAt != nil), homeController.freshness == .live {
            beginConnectionPresentationGracePeriod()
        }
        wasBackgrounded = false
        await runtime.resume(lifecycleSequence: lifecycleSequence, backgroundedAt: backgroundedAt)
        if let desiredConversationID {
            await openConversation(desiredConversationID)
        }
    }

    func refresh() async {
        startObservingIfNeeded()
        if homeController.freshness == .live {
            beginConnectionPresentationGracePeriod()
        } else {
            endConnectionPresentationGracePeriod()
        }
        await runtime.restart()
    }

    func background(lifecycleSequence: UInt64) async {
        wasBackgrounded = true
        endConnectionPresentationGracePeriod()
        // Keep the conversation controller and readable projection. The
        // coordinator chooses stream reuse or suspension and owns all cleanup.
        await runtime.enterBackground(lifecycleSequence: lifecycleSequence)
    }

    func openConversation(_ conversationID: UUID) async {
        desiredConversationID = conversationID

        while desiredConversationID == conversationID {
            if activeConversationController?.conversationID == conversationID {
                return
            }
            if let operation = conversationOpenOperations[conversationID] {
                await operation.task.value
                continue
            }
            break
        }
        guard desiredConversationID == conversationID else { return }

        if activeConversationController != nil {
            await tearDownActiveConversation(clearDesiredConversation: false)
        }
        guard desiredConversationID == conversationID else { return }

        conversationRequestID = UUID()
        let requestID = conversationRequestID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performOpenConversation(conversationID, requestID: requestID)
            if conversationOpenOperations[conversationID]?.requestID == requestID {
                conversationOpenOperations[conversationID] = nil
            }
        }
        conversationOpenOperations[conversationID] = ConversationOpenOperation(
            requestID: requestID,
            task: task
        )
        await task.value
    }

    private func performOpenConversation(
        _ conversationID: UUID,
        requestID: UUID
    ) async {
        let remoteID = RemoteConversationID(rawValue: conversationID)
        let conversationRuntime = await runtime.openConversation(remoteID)
        conversationRuntimeOwners[remoteID] = requestID
        guard conversationRequestID == requestID,
              desiredConversationID == conversationID else {
            await closeConversationRuntime(remoteID, ownedBy: requestID)
            return
        }

        let controller = LiveConversationController(
            conversationID: conversationID,
            runtime: conversationRuntime,
            loadOlder: { [runtime] in
                await runtime.loadOlder(remoteID)
            },
            send: { [runtime] text, stamp in
                await runtime.sendMessage(
                    conversationID: remoteID,
                    text: text,
                    composerStamp: stamp
                )
            },
            sendAttachments: { [runtime] text, attachments, stamp in
                await runtime.sendMessage(conversationID: remoteID, text: text,
                                          attachments: attachments, composerStamp: stamp)
            },
            answerQuestion: { [runtime] request in
                try await runtime.answerQuestion(request)
            },
            dismissSendReceipt: { [runtime] clientRequestID in
                await runtime.dismissSendReceipt(
                    conversationID: remoteID,
                    clientRequestID: clientRequestID
                )
            },
            acknowledgeRead: { [runtime] request in
                try await runtime.acknowledgeConversationRead(request)
            }
        )
        controller.onDiagnosticEvent = { [weak self] event in self?.onDiagnosticEvent(event) }
        controller.consumeConnectionState(coordinatorState)
        activeConversationController = controller
        await controller.start()

        guard conversationRequestID == requestID,
              desiredConversationID == conversationID else {
            controller.stop()
            if activeConversationController === controller {
                activeConversationController = nil
            }
            await closeConversationRuntime(remoteID, ownedBy: requestID)
            return
        }
    }

    func closeConversation(_ conversationID: UUID) async {
        guard desiredConversationID == conversationID
                || activeConversationController?.conversationID == conversationID else {
            return
        }
        await tearDownActiveConversation(clearDesiredConversation: true)
    }

    func updateDeviceScopes(_ scopes: [RemoteDeviceScope]) async {
        deviceScopes = scopes
        homeController.setHostSupportsSubspaceDone(acceptsSubspaceDone)
        homeController.setHostSupportsConversationFlag(acceptsConversationFlag)
        homeController.setHostSupportsSessionStart(acceptsSessionStart)
        await runtime.updateDeviceScopes(scopes)
    }

    /// A first message is a send, so only a device allowed to send sees
    /// the entry point. The Mac's per-device start permission is checked
    /// when the sheet loads its options.
    private var acceptsSessionStart: Bool {
        coordinatorState.capabilities.contains(.sessionStart) && deviceScopes.contains(.send)
    }

    private var acceptsConversationFlag: Bool {
        coordinatorState.capabilities.contains(.conversationFlag) && deviceScopes.contains(.send)
    }

    /// The Mac takes a done change only from a device allowed to send, so a
    /// read-only device shows the mark without a checkbox.
    private var acceptsSubspaceDone: Bool {
        coordinatorState.capabilities.contains(.workspaceDone) && deviceScopes.contains(.send)
    }

    func stopObserving() {
        endConnectionPresentationGracePeriod()
        coordinatorTask?.cancel()
        sessionsTask?.cancel()
        coordinatorTask = nil
        sessionsTask = nil
        conversationRequestID = UUID()
        desiredConversationID = nil
        let activeConversationID = activeConversationController?.conversationID
        activeConversationController?.stop()
        activeConversationController = nil
        if let activeConversationID {
            conversationRuntimeOwners[RemoteConversationID(rawValue: activeConversationID)] = nil
        }
        // Dropping the UI observers is not enough: an unpaired or replaced
        // controller must also close its socket and cancel in-flight REST.
        Task { [runtime] in
            if let activeConversationID {
                await runtime.closeConversation(RemoteConversationID(rawValue: activeConversationID))
            }
            await runtime.suspend()
        }
    }

    private func startObservingIfNeeded() {
        if coordinatorTask == nil {
            coordinatorTask = Task { @MainActor [weak self, runtime] in
                let states = await runtime.coordinatorStates()
                for await state in states {
                    guard let self, !Task.isCancelled else { return }
                    consumeCoordinatorState(state)
                }
            }
        }

        if sessionsTask == nil {
            sessionsTask = Task { @MainActor [weak self, runtime] in
                let states = await runtime.sessionsStates()
                for await state in states {
                    guard let self, !Task.isCancelled else { return }
                    consumeSessionsState(state)
                }
            }
        }
    }

    func consumeCoordinatorState(_ state: ConnectionCoordinator.State) {
        coordinatorState = state
        finishConnectionPresentationGraceIfNeeded(for: state.phase)
        activeConversationController?.consumeConnectionState(state)
        applyPresentation()
        // Terminal admission/authorization state must be the final callback.
        // In particular, the stale projection presented for a retained 403
        // must not overwrite the paired authorization-denied explanation.
        handleTerminal(state.phase)
    }

    func consumeSessionsState(_ state: SessionsRuntime.State) {
        sessionsState = state
        if let snapshot = state.snapshot {
            projectionRunID = snapshot.projectionRunID.rawValue.uuidString
            projectionGeneration = snapshot.conversations
                .map(\.projectionGeneration)
                .max()
        }
        applyPresentation()
    }

    private func handleTerminal(_ phase: ConnectionCoordinatorPhase) {
        switch phase {
        case .requiresAuthentication:
            onTerminal(.requiresAuthentication)
        case .authorizationDenied:
            onTerminal(.authorizationDenied)
        case .incompatibleProtocol(let version):
            onTerminal(.incompatibleProtocol(version: version))
        case .idle, .connecting, .awaitingFreshSessionSnapshot, .checkingConnection, .live,
             .reconnecting, .suspended, .failed:
            break
        }
    }

    private func applyPresentation(freshnessOverride: LiveProjectionFreshness? = nil) {
        let freshness = freshnessOverride ?? resolvedFreshness
        if freshnessOverride == nil,
           suppressesConnectionDowngrade,
           homeController.freshness == .live,
           freshness != .live {
            return
        }
        let connectionState: MobileConnectionState = switch freshness {
        case .live: .live
        case .connecting, .reconnecting: .reconnecting
        case .stale, .unreachable: .offline
        }

        let snapshot = sessionsState.snapshot?.presentation(
            hostName: hostName,
            stateTransitions: &stateTransitions
        ) ?? homeController.hostSnapshot
        homeController.update(
            snapshot: snapshot,
            connectionState: connectionState,
            freshness: freshness,
            latestTransportFailure: coordinatorState.latestTransportFailure,
            hostSupportsSubspaceDone: acceptsSubspaceDone,
            hostSupportsConversationFlag: acceptsConversationFlag,
            hostSupportsSessionStart: acceptsSessionStart,
            hostSnapshotStamp: sessionsState.snapshot?.generatedAt
        )
        onFreshness(freshness)
    }

    private func finishConnectionPresentationGraceIfNeeded(for phase: ConnectionCoordinatorPhase) {
        guard suppressesConnectionDowngrade else { return }
        switch phase {
        case .idle, .connecting, .awaitingFreshSessionSnapshot, .checkingConnection:
            break
        case .live, .reconnecting, .suspended, .requiresAuthentication,
             .authorizationDenied, .incompatibleProtocol, .failed:
            endConnectionPresentationGracePeriod()
        }
    }

    private func beginConnectionPresentationGracePeriod() {
        connectionPresentationTask?.cancel()
        suppressesConnectionDowngrade = true
        connectionPresentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: connectionPresentationDelay)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            suppressesConnectionDowngrade = false
            connectionPresentationTask = nil
            applyPresentation()
        }
    }

    private func endConnectionPresentationGracePeriod() {
        suppressesConnectionDowngrade = false
        connectionPresentationTask?.cancel()
        connectionPresentationTask = nil
    }

    private func tearDownActiveConversation(
        clearDesiredConversation: Bool
    ) async {
        conversationRequestID = UUID()
        if clearDesiredConversation {
            desiredConversationID = nil
        }
        guard let controller = activeConversationController else { return }
        activeConversationController = nil
        controller.stop()
        let remoteID = RemoteConversationID(rawValue: controller.conversationID)
        conversationRuntimeOwners[remoteID] = nil
        await runtime.closeConversation(remoteID)
    }

    private func closeConversationRuntime(
        _ conversationID: RemoteConversationID,
        ownedBy requestID: UUID
    ) async {
        guard conversationRuntimeOwners[conversationID] == requestID else { return }
        conversationRuntimeOwners[conversationID] = nil
        await runtime.closeConversation(conversationID)
    }

    private struct ConversationOpenOperation {
        let requestID: UUID
        let task: Task<Void, Never>
    }

    private var resolvedFreshness: LiveProjectionFreshness {
        switch coordinatorState.phase {
        case .live:
            sessionsState.phase == .live ? .live : .stale
        case .reconnecting, .checkingConnection:
            .reconnecting
        case .suspended:
            .stale
        // A first attempt with no projection yet is connecting, not
        // unreachable: nothing has failed and there is no stale data to show.
        case .idle, .connecting, .awaitingFreshSessionSnapshot:
            sessionsState.snapshot == nil ? .connecting : .stale
        case .requiresAuthentication, .incompatibleProtocol, .failed:
            .unreachable
        case .authorizationDenied:
            .stale
        }
    }
}
