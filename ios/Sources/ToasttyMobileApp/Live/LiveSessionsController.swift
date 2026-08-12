import Foundation
import Observation
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
    private(set) var activeConversationCursor: UInt64?

    private let runtime: any LiveConnectionRuntime
    private let hostName: String
    private let onFreshness: @MainActor (LiveProjectionFreshness) -> Void
    private let onTerminal: @MainActor (LiveConnectionTerminal) -> Void
    private var coordinatorTask: Task<Void, Never>?
    private var sessionsTask: Task<Void, Never>?
    private var coordinatorState = ConnectionCoordinator.State()
    private var sessionsState = SessionsRuntime.State()

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
    }

    func refresh() async {
        startObservingIfNeeded()
        await runtime.restart()
    }

    func background() async {
        await runtime.suspend()
        applyPresentation(freshnessOverride: .stale)
    }

    func updateActiveConversationCursor(_ cursor: UInt64?) {
        activeConversationCursor = cursor
    }

    func stopObserving() {
        coordinatorTask?.cancel()
        sessionsTask?.cancel()
        coordinatorTask = nil
        sessionsTask = nil
        // Dropping the UI observers is not enough: an unpaired or replaced
        // controller must also close its socket and cancel in-flight REST.
        Task { [runtime] in
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
