import Foundation
import RemoteProtocol

public enum ConnectionCoordinatorPhase: Equatable, Sendable {
    case idle
    case connecting
    case awaitingFreshSessionSnapshot
    case live
    case reconnecting(failureCount: Int, showsBanner: Bool)
    case suspended
    case requiresAuthentication
    case authorizationDenied
    case incompatibleProtocol(version: String)
    case failed(GatewayFailure)
}

/// Owns the one gateway connection shared by all native projection runtimes.
///
/// Session and conversation actors remain pure projection owners: they never
/// authenticate, sleep, reconnect, or create transport tasks independently.
public actor ConnectionCoordinator {
    public struct State: Equatable, Sendable {
        public var connectionGeneration: UInt64
        public var phase: ConnectionCoordinatorPhase
        public var consecutiveFailureCount: Int

        public init(
            connectionGeneration: UInt64 = 0,
            phase: ConnectionCoordinatorPhase = .idle,
            consecutiveFailureCount: Int = 0
        ) {
            self.connectionGeneration = connectionGeneration
            self.phase = phase
            self.consecutiveFailureCount = consecutiveFailureCount
        }
    }

    private let gateway: any GatewayClientProtocol
    private let eventStream: any EventStreamClientProtocol
    private let sessionsRuntime: SessionsRuntime
    private let sleeper: any ConnectionSleeping
    private let jitter: any ConnectionJitterProviding
    private let retryPolicy: ConnectionRetryPolicy
    private let eventsPageLimit: Int
    private let stateStream: RuntimeStateStream<State>

    private var state = State()
    private var connectionTask: Task<Void, Never>?
    private var connectionLoopID: UUID?
    private var activeSubscription: (any EventStreamSubscriptionProtocol)?
    private var attemptFailure: GatewayFailure?
    private var conversationRuntimes: [RemoteConversationID: ConversationRuntime] = [:]
    private var activeConversationIDs: Set<RemoteConversationID> = []
    private var conversationCatchUpTasks: [RemoteConversationID: Task<Void, Never>] = [:]

    public init(
        gateway: any GatewayClientProtocol,
        eventStream: any EventStreamClientProtocol,
        sessionsRuntime: SessionsRuntime = SessionsRuntime(),
        sleeper: any ConnectionSleeping = ContinuousConnectionSleeper(),
        jitter: any ConnectionJitterProviding = SystemConnectionJitter(),
        retryPolicy: ConnectionRetryPolicy = ConnectionRetryPolicy(),
        eventsPageLimit: Int = 200
    ) {
        self.gateway = gateway
        self.eventStream = eventStream
        self.sessionsRuntime = sessionsRuntime
        self.sleeper = sleeper
        self.jitter = jitter
        self.retryPolicy = retryPolicy
        self.eventsPageLimit = min(max(eventsPageLimit, 1), 200)
        stateStream = RuntimeStateStream(State())
    }

    public func currentState() -> State {
        state
    }

    public func states() async -> AsyncStream<State> {
        await stateStream.states()
    }

    public func sessionProjection() -> SessionsRuntime {
        sessionsRuntime
    }

    /// Starts the coordinator unless it already owns a connection loop.
    public func connectIfNeeded() async {
        guard connectionTask == nil else { return }
        switch state.phase {
        case .requiresAuthentication, .authorizationDenied,
             .incompatibleProtocol, .failed:
            // Terminal admission/authorization failures require an explicit
            // user action (pairing or manual reset), not a scene-driven loop.
            return
        case .idle, .connecting, .awaitingFreshSessionSnapshot, .live,
             .reconnecting, .suspended:
            break
        }
        startConnectionLoop()
    }

    /// Cancels all network work while retaining the last readable projection.
    public func suspend() async {
        let previousTask = connectionTask
        previousTask?.cancel()
        connectionTask = nil
        connectionLoopID = nil
        // Closing the subscription first releases a receive implementation
        // that does not itself observe parent-task cancellation. No new loop
        // can install resources until the old task has then fully unwound.
        await closeAttemptResources()
        await previousTask?.value

        state.connectionGeneration &+= 1
        state.phase = .suspended
        state.consecutiveFailureCount = 0
        _ = await sessionsRuntime.suspend(generation: state.connectionGeneration)
        for runtime in conversationRuntimes.values {
            _ = await runtime.suspend(connectionGeneration: state.connectionGeneration)
        }
        await publish()
    }

    /// Foregrounding reconnects suspended/nonterminal state, but never revives
    /// a terminal admission or authorization failure.
    public func resume() async {
        await connectIfNeeded()
    }

    public func restart() async {
        let previousTask = connectionTask
        previousTask?.cancel()
        connectionTask = nil
        connectionLoopID = nil
        await closeAttemptResources()
        await previousTask?.value
        state.consecutiveFailureCount = 0
        startConnectionLoop()
    }

    /// Returns the actor that owns one conversation projection and schedules a
    /// subscribe-before-REST catch-up once the shared socket is established.
    public func openConversation(_ conversationID: RemoteConversationID) async -> ConversationRuntime {
        let runtime: ConversationRuntime
        if let existing = conversationRuntimes[conversationID] {
            runtime = existing
        } else {
            runtime = ConversationRuntime(conversationID: conversationID)
            conversationRuntimes[conversationID] = runtime
        }
        activeConversationIDs.insert(conversationID)

        if activeSubscription != nil {
            await startConversationCatchUp(
                conversationID: conversationID,
                generation: state.connectionGeneration,
                resnapshot: false
            )
        }
        return runtime
    }

    public func closeConversation(_ conversationID: RemoteConversationID) {
        activeConversationIDs.remove(conversationID)
        conversationCatchUpTasks.removeValue(forKey: conversationID)?.cancel()
    }

    public func conversationProjection(
        for conversationID: RemoteConversationID
    ) -> ConversationRuntime? {
        conversationRuntimes[conversationID]
    }

    private func startConnectionLoop() {
        let loopID = UUID()
        connectionLoopID = loopID
        connectionTask = Task { [weak self] in
            await self?.runConnectionLoop(loopID: loopID)
        }
    }

    private func runConnectionLoop(loopID: UUID) async {
        var failureCount = 0

        while !Task.isCancelled, connectionLoopID == loopID {
            state.connectionGeneration &+= 1
            let generation = state.connectionGeneration
            state.phase = failureCount == 0
                ? .connecting
                : .reconnecting(
                    failureCount: failureCount,
                    showsBanner: retryPolicy.shouldShowReconnectingBanner(
                        afterFailureCount: failureCount
                    )
                )
            state.consecutiveFailureCount = failureCount
            await publish()

            _ = await sessionsRuntime.beginConnection(
                generation: generation,
                isReconnect: failureCount > 0
            )

            do {
                try await runConnectionAttempt(generation: generation)
                break
            } catch is CancellationError {
                break
            } catch {
                await closeAttemptResources()
                guard generation == state.connectionGeneration else { continue }
                let failure = (error as? GatewayFailure) ?? .network
                guard failure.isRetryable else {
                    await applyTerminalFailure(failure, generation: generation)
                    break
                }

                // Once a fresh stream snapshot made this attempt live, a
                // later disconnect begins a new failure streak. Only failures
                // that occur before reaching live accumulate across attempts.
                if state.phase == .live {
                    failureCount = 0
                }
                failureCount += 1
                state.consecutiveFailureCount = failureCount
                state.phase = .reconnecting(
                    failureCount: failureCount,
                    showsBanner: retryPolicy.shouldShowReconnectingBanner(
                        afterFailureCount: failureCount
                    )
                )
                _ = await sessionsRuntime.markReconnecting(generation: generation)
                await publish()

                let sample = await jitter.sample()
                let delay = retryPolicy.delay(
                    afterFailureCount: failureCount,
                    jitterUnit: sample
                )
                do {
                    try await sleeper.sleep(for: delay)
                } catch {
                    break
                }
            }
        }

        await closeAttemptResources()
        if connectionLoopID == loopID {
            connectionTask = nil
            connectionLoopID = nil
        }
    }

    private func runConnectionAttempt(generation: UInt64) async throws {
        attemptFailure = nil
        _ = try await gateway.hello()
        try ensureCurrentGeneration(generation)

        let seed = try await gateway.sessions()
        try ensureCurrentGeneration(generation)
        guard await sessionsRuntime.applyRESTSeed(seed, generation: generation) else {
            throw CancellationError()
        }

        let subscription = try await eventStream.connect()
        try ensureCurrentGeneration(generation)
        activeSubscription = subscription
        guard await sessionsRuntime.didOpen(generation: generation) else {
            throw CancellationError()
        }
        state.phase = .awaitingFreshSessionSnapshot
        await publish()

        for conversationID in activeConversationIDs {
            await startConversationCatchUp(
                conversationID: conversationID,
                generation: generation,
                resnapshot: false
            )
        }

        do {
            while !Task.isCancelled {
                let message = try await subscription.nextMessage()
                try ensureCurrentGeneration(generation)
                try await handleStreamMessage(message, generation: generation)
            }
            throw CancellationError()
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            if let attemptFailure {
                self.attemptFailure = nil
                throw attemptFailure
            }
            throw GatewayFailure.network
        } catch {
            // Closing a real URLSession web socket wakes receive with a
            // transport error, not necessarily CancellationError. Preserve a
            // more specific REST catch-up failure that deliberately closed it.
            if let attemptFailure {
                self.attemptFailure = nil
                throw attemptFailure
            }
            throw error
        }
    }

    private func handleStreamMessage(
        _ message: CompatibleGatewayStreamMessage,
        generation: UInt64
    ) async throws {
        switch message {
        case .sessionList(let snapshot):
            guard await sessionsRuntime.applyStreamSnapshot(snapshot, generation: generation) else {
                return
            }
            state.consecutiveFailureCount = 0
            state.phase = .live
            await publish()

        case .conversationEvents(let page):
            guard activeConversationIDs.contains(page.conversationID),
                  let runtime = conversationRuntimes[page.conversationID] else {
                return
            }
            let directive = await runtime.applyLive(
                page,
                connectionGeneration: generation
            )
            await handleConversationDirective(
                directive,
                conversationID: page.conversationID,
                generation: generation
            )

        case .resnapshotRequired(let conversationID):
            guard activeConversationIDs.contains(conversationID),
                  let runtime = conversationRuntimes[conversationID] else {
                return
            }
            _ = await runtime.requireResnapshot(
                .explicit,
                connectionGeneration: generation
            )
            await startConversationCatchUp(
                conversationID: conversationID,
                generation: generation,
                resnapshot: true
            )

        case .ignoredUnknown:
            return
        }
    }

    private func handleConversationDirective(
        _ directive: ConversationRuntimeDirective,
        conversationID: RemoteConversationID,
        generation: UInt64
    ) async {
        switch directive {
        case .none:
            return
        case .fetchREST:
            await startConversationCatchUp(
                conversationID: conversationID,
                generation: generation,
                resnapshot: false
            )
        case .resnapshot:
            await startConversationCatchUp(
                conversationID: conversationID,
                generation: generation,
                resnapshot: true
            )
        }
    }

    private func startConversationCatchUp(
        conversationID: RemoteConversationID,
        generation: UInt64,
        resnapshot: Bool
    ) async {
        guard generation == state.connectionGeneration,
              activeConversationIDs.contains(conversationID),
              let runtime = conversationRuntimes[conversationID] else {
            return
        }

        conversationCatchUpTasks.removeValue(forKey: conversationID)?.cancel()
        guard await runtime.beginCatchUp(
            connectionGeneration: generation,
            resnapshot: resnapshot
        ) else {
            return
        }

        let initialCursor = resnapshot ? nil : await runtime.currentState().cursor
        conversationCatchUpTasks[conversationID] = Task { [weak self] in
            await self?.runConversationCatchUp(
                runtime: runtime,
                conversationID: conversationID,
                generation: generation,
                initialCursor: initialCursor,
                startedAsResnapshot: resnapshot
            )
        }
    }

    private func runConversationCatchUp(
        runtime: ConversationRuntime,
        conversationID: RemoteConversationID,
        generation: UInt64,
        initialCursor: ConversationEventCursor?,
        startedAsResnapshot: Bool
    ) async {
        var cursor = initialCursor
        var isResnapshot = startedAsResnapshot

        do {
            while !Task.isCancelled,
                  generation == state.connectionGeneration,
                  activeConversationIDs.contains(conversationID) {
                let response = try await gateway.events(
                    conversationID: conversationID,
                    cursor: cursor,
                    limit: eventsPageLimit
                )
                guard generation == state.connectionGeneration else { return }

                switch response {
                case .page(let page):
                    let directive = await runtime.applyREST(
                        page,
                        connectionGeneration: generation
                    )
                    switch directive {
                    case .none:
                        if await runtime.finishCatchUp(connectionGeneration: generation) {
                            return
                        }
                        // A live page can arrive after applyREST drains its
                        // buffer but before this task resumes to finish. Page
                        // once more from the actor's authoritative cursor so
                        // that interleaving cannot strand a buffered page.
                        cursor = await runtime.currentState().cursor
                    case .fetchREST(let nextCursor):
                        cursor = nextCursor
                    case .resnapshot:
                        guard isResnapshot == false else { return }
                        isResnapshot = true
                        cursor = nil
                        _ = await runtime.beginCatchUp(
                            connectionGeneration: generation,
                            resnapshot: true
                        )
                    }

                case .resnapshotRequired:
                    guard isResnapshot == false else { return }
                    isResnapshot = true
                    cursor = nil
                    _ = await runtime.beginCatchUp(
                        connectionGeneration: generation,
                        resnapshot: true
                    )

                case .conversationNotFound:
                    _ = await runtime.requireResnapshot(
                        .explicit,
                        connectionGeneration: generation
                    )
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            let failure = (error as? GatewayFailure) ?? .network
            await failCurrentAttempt(failure, generation: generation)
        }
    }

    private func failCurrentAttempt(
        _ failure: GatewayFailure,
        generation: UInt64
    ) async {
        guard generation == state.connectionGeneration else { return }
        attemptFailure = failure
        await activeSubscription?.close()
    }

    private func ensureCurrentGeneration(_ generation: UInt64) throws {
        guard generation == state.connectionGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func applyTerminalFailure(
        _ failure: GatewayFailure,
        generation: UInt64
    ) async {
        state.consecutiveFailureCount = 0
        switch failure {
        case .unauthenticated:
            state.phase = .requiresAuthentication
        case .authorizationDenied:
            state.phase = .authorizationDenied
        case .protocolMismatch(let version):
            state.phase = .incompatibleProtocol(version: version)
        case .network, .server, .rateLimited, .http,
             .operationCompatibility, .invalidResponse:
            state.phase = .failed(failure)
        }
        _ = await sessionsRuntime.failTerminally(failure, generation: generation)
        await publish()
    }

    private func closeAttemptResources() async {
        for task in conversationCatchUpTasks.values {
            task.cancel()
        }
        conversationCatchUpTasks.removeAll()
        if let activeSubscription {
            self.activeSubscription = nil
            await activeSubscription.close()
        }
        attemptFailure = nil
    }

    private func publish() async {
        await stateStream.yield(state)
    }
}
