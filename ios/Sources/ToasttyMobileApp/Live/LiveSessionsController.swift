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
    func dismissSendReceipt(
        conversationID: RemoteConversationID,
        clientRequestID: String
    ) async
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

    func dismissSendReceipt(
        conversationID: RemoteConversationID,
        clientRequestID: String
    ) async {
        await coordinator.dismissSendReceipt(
            conversationID: conversationID,
            clientRequestID: clientRequestID
        )
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

    private let runtime: any LiveConnectionRuntime
    private let hostName: String
    private let onFreshness: @MainActor (LiveProjectionFreshness) -> Void
    private let onTerminal: @MainActor (LiveConnectionTerminal) -> Void
    private var coordinatorTask: Task<Void, Never>?
    private var sessionsTask: Task<Void, Never>?
    private var coordinatorState = ConnectionCoordinator.State()
    private var sessionsState = SessionsRuntime.State()
    private var desiredConversationID: UUID?
    private var conversationRequestID = UUID()
    private var conversationOpenOperations: [UUID: ConversationOpenOperation] = [:]
    private var conversationRuntimeOwners: [RemoteConversationID: UUID] = [:]

    init(
        runtime: any LiveConnectionRuntime,
        hostName: String,
        homeController: HomeScreenController,
        onTerminal: @escaping @MainActor (LiveConnectionTerminal) -> Void = { _ in },
        onFreshness: @escaping @MainActor (LiveProjectionFreshness) -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.hostName = hostName
        self.homeController = homeController
        self.onFreshness = onFreshness
        self.onTerminal = onTerminal
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

    /// Foregrounding a suspended runtime creates a new connection generation,
    /// which requires a new full stream snapshot before presentation is live.
    func foreground() async {
        startObservingIfNeeded()
        await runtime.connectIfNeeded()
        if let desiredConversationID {
            await openConversation(desiredConversationID)
        }
    }

    func refresh() async {
        startObservingIfNeeded()
        await runtime.restart()
    }

    func background() async {
        await tearDownActiveConversation(clearDesiredConversation: false)
        await runtime.suspend()
        applyPresentation(freshnessOverride: .stale)
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
            dismissSendReceipt: { [runtime] clientRequestID in
                await runtime.dismissSendReceipt(
                    conversationID: remoteID,
                    clientRequestID: clientRequestID
                )
            }
        )
        controller.consumeConnectionPhase(coordinatorState.phase)
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
        await runtime.updateDeviceScopes(scopes)
    }

    func stopObserving() {
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
        activeConversationController?.consumeConnectionPhase(state.phase)
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
        case .idle, .connecting, .awaitingFreshSessionSnapshot, .live,
             .reconnecting, .suspended, .failed:
            break
        }
    }

    private func applyPresentation(freshnessOverride: LiveProjectionFreshness? = nil) {
        let freshness = freshnessOverride ?? resolvedFreshness
        let connectionState: MobileConnectionState = switch freshness {
        case .live: .live
        case .reconnecting: .reconnecting
        case .stale, .unreachable: .offline
        }

        let snapshot = sessionsState.snapshot?.presentation(hostName: hostName)
            ?? homeController.snapshot
        homeController.update(
            snapshot: snapshot,
            connectionState: connectionState,
            freshness: freshness
        )
        onFreshness(freshness)
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
        case .reconnecting:
            .reconnecting
        case .suspended:
            .stale
        case .connecting, .awaitingFreshSessionSnapshot:
            sessionsState.snapshot == nil ? .unreachable : .stale
        case .idle:
            sessionsState.snapshot == nil ? .unreachable : .stale
        case .requiresAuthentication, .incompatibleProtocol, .failed:
            .unreachable
        case .authorizationDenied:
            .stale
        }
    }
}
