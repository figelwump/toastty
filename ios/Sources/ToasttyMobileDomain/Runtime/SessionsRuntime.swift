import Foundation

public enum SessionsRuntimePhase: Equatable, Sendable {
    case idle
    case seedingREST
    case awaitingSocket
    case awaitingFreshSnapshot
    case live
    case reconnecting
    case suspended
    case terminalFailure(GatewayFailure)
}

public actor SessionsRuntime {
    public struct State: Equatable, Sendable {
        public var connectionGeneration: UInt64
        public var snapshot: CompatibleSessionListSnapshot?
        public var phase: SessionsRuntimePhase

        public init(
            connectionGeneration: UInt64 = 0,
            snapshot: CompatibleSessionListSnapshot? = nil,
            phase: SessionsRuntimePhase = .idle
        ) {
            self.connectionGeneration = connectionGeneration
            self.snapshot = snapshot
            self.phase = phase
        }
    }

    private var state: State
    private let stateStream: RuntimeStateStream<State>

    public init() {
        let initialState = State()
        state = initialState
        stateStream = RuntimeStateStream(initialState)
    }

    public func currentState() -> State {
        state
    }

    public func states() async -> AsyncStream<State> {
        await stateStream.states()
    }

    /// Starts the REST seed for a fresh connection generation.
    ///
    /// A reconnect retains the last usable snapshot while the coordinator
    /// rebuilds the REST/socket handoff.
    @discardableResult
    public func beginConnection(generation: UInt64, isReconnect: Bool = false) async -> Bool {
        guard generation >= state.connectionGeneration else { return false }
        guard generation != state.connectionGeneration || state.phase == .idle || state.phase == .suspended else {
            return false
        }
        state.connectionGeneration = generation
        state.phase = isReconnect ? .reconnecting : .seedingREST
        await publish()
        return true
    }

    /// Applies the point-in-time REST seed, but deliberately does not make the
    /// runtime live. A full snapshot delivered by the newly opened stream is
    /// the authority that completes the handoff.
    @discardableResult
    public func applyRESTSeed(
        _ snapshot: CompatibleSessionListSnapshot,
        generation: UInt64
    ) async -> Bool {
        guard generation == state.connectionGeneration else { return false }
        switch state.phase {
        case .seedingREST, .reconnecting:
            state.snapshot = snapshot
            state.phase = .awaitingSocket
            await publish()
            return true
        case .idle, .awaitingSocket, .awaitingFreshSnapshot, .live, .suspended, .terminalFailure:
            return false
        }
    }

    /// Records that the socket opened. Opening alone is never proof that its
    /// full session snapshot has arrived.
    @discardableResult
    public func didOpen(generation: UInt64) async -> Bool {
        guard generation == state.connectionGeneration, state.phase == .awaitingSocket else {
            return false
        }
        state.phase = .awaitingFreshSnapshot
        await publish()
        return true
    }

    /// Accepts only the stream's full `session_list` snapshot for the current
    /// generation as the transition to live.
    @discardableResult
    public func applyStreamSnapshot(
        _ snapshot: CompatibleSessionListSnapshot,
        generation: UInt64
    ) async -> Bool {
        guard generation == state.connectionGeneration else { return false }
        guard state.phase == .awaitingFreshSnapshot || state.phase == .live else { return false }
        state.snapshot = snapshot
        state.phase = .live
        await publish()
        return true
    }

    @discardableResult
    public func markReconnecting(generation: UInt64) async -> Bool {
        guard generation >= state.connectionGeneration else { return false }
        state.connectionGeneration = generation
        state.phase = .reconnecting
        await publish()
        return true
    }

    @discardableResult
    public func suspend(generation: UInt64) async -> Bool {
        guard generation >= state.connectionGeneration else { return false }
        state.connectionGeneration = generation
        state.phase = .suspended
        await publish()
        return true
    }

    @discardableResult
    public func failTerminally(_ failure: GatewayFailure, generation: UInt64) async -> Bool {
        guard generation >= state.connectionGeneration else { return false }
        state.connectionGeneration = generation
        state.phase = .terminalFailure(failure)
        await publish()
        return true
    }

    private func publish() async {
        await stateStream.yield(state)
    }
}
