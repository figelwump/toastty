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
    private var activeCapabilities: Set<RemoteGatewayCapability> = []
    private var conversationRuntimes: [RemoteConversationID: ConversationRuntime] = [:]
    private var activeConversationIDs: Set<RemoteConversationID> = []
    private var conversationCatchUpTasks: [RemoteConversationID: Task<Void, Never>] = [:]
    private var conversationOlderTasks: [RemoteConversationID: (id: UUID, task: Task<Void, Never>)] = [:]

    private enum ConversationCatchUpStrategy {
        case initial
        case forward
        case resnapshot
    }

    private static let maximumUnknownOnlyOlderPages = 8

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
        // Invalidate every in-flight REST result before awaiting transport
        // teardown. Some URL loading implementations only observe
        // cancellation when their response completes.
        state.connectionGeneration &+= 1
        let suspendedGeneration = state.connectionGeneration
        // Closing the subscription first releases a receive implementation
        // that does not itself observe parent-task cancellation. No new loop
        // can install resources until the old task has then fully unwound.
        await closeAttemptResources()
        await previousTask?.value

        state.phase = .suspended
        state.consecutiveFailureCount = 0
        _ = await sessionsRuntime.suspend(generation: suspendedGeneration)
        for runtime in conversationRuntimes.values {
            _ = await runtime.suspend(connectionGeneration: suspendedGeneration)
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
        // Make responses from the retired attempt stale immediately, rather
        // than relying on cooperative URLSession cancellation.
        state.connectionGeneration &+= 1
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
                strategy: .initial
            )
        }
        return runtime
    }

    public func closeConversation(_ conversationID: RemoteConversationID) async {
        activeConversationIDs.remove(conversationID)
        conversationCatchUpTasks.removeValue(forKey: conversationID)?.cancel()
        conversationOlderTasks.removeValue(forKey: conversationID)?.task.cancel()
        guard let runtime = conversationRuntimes.removeValue(forKey: conversationID) else {
            return
        }
        _ = await runtime.suspend(connectionGeneration: state.connectionGeneration)
    }

    public func conversationProjection(
        for conversationID: RemoteConversationID
    ) -> ConversationRuntime? {
        conversationRuntimes[conversationID]
    }

    /// Loads one bounded retained-history slice for an open conversation.
    /// Unknown-only pages may be skipped in a small bounded loop so one user
    /// action normally reveals content without permitting unbounded work.
    public func loadOlder(_ conversationID: RemoteConversationID) async {
        guard state.phase == .live,
              activeCapabilities.contains(.conversationBackwardPaging),
              activeConversationIDs.contains(conversationID),
              conversationOlderTasks[conversationID] == nil,
              let runtime = conversationRuntimes[conversationID],
              let request = await runtime.beginLoadingOlder(
                connectionGeneration: state.connectionGeneration
              ) else {
            return
        }

        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLoadOlder(
                runtime: runtime,
                conversationID: conversationID,
                request: request,
                taskID: taskID
            )
        }
        conversationOlderTasks[conversationID] = (taskID, task)
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
        activeCapabilities.removeAll()
        let hello = try await gateway.hello()
        try ensureCurrentGeneration(generation)
        activeCapabilities = Set(hello.capabilities)

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
                strategy: .initial
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
                strategy: .resnapshot
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
                strategy: .forward
            )
        case .resnapshot:
            await startConversationCatchUp(
                conversationID: conversationID,
                generation: generation,
                strategy: .resnapshot
            )
        }
    }

    private func startConversationCatchUp(
        conversationID: RemoteConversationID,
        generation: UInt64,
        strategy: ConversationCatchUpStrategy
    ) async {
        guard generation == state.connectionGeneration,
              activeConversationIDs.contains(conversationID),
              let runtime = conversationRuntimes[conversationID] else {
            return
        }

        conversationCatchUpTasks.removeValue(forKey: conversationID)?.cancel()
        conversationOlderTasks.removeValue(forKey: conversationID)?.task.cancel()
        let resnapshot = strategy == .resnapshot
        guard await runtime.beginCatchUp(
            connectionGeneration: generation,
            resnapshot: resnapshot
        ) else {
            return
        }

        let usesTail = strategy != .forward
            && activeCapabilities.contains(.conversationBackwardPaging)
        if usesTail {
            conversationCatchUpTasks[conversationID] = Task { [weak self] in
                await self?.runConversationTailCatchUp(
                    runtime: runtime,
                    conversationID: conversationID,
                    generation: generation,
                    startedAsResnapshot: resnapshot
                )
            }
        } else {
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
                guard generation == state.connectionGeneration,
                      activeConversationIDs.contains(conversationID),
                      conversationRuntimes[conversationID] === runtime else {
                    return
                }

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

    private func runConversationTailCatchUp(
        runtime: ConversationRuntime,
        conversationID: RemoteConversationID,
        generation: UInt64,
        startedAsResnapshot: Bool
    ) async {
        do {
            let response = try await gateway.events(RemoteGatewayEventsRequest(
                conversationID: conversationID,
                limit: eventsPageLimit,
                backward: .latest
            ))
            guard isCurrent(
                runtime: runtime,
                conversationID: conversationID,
                generation: generation
            ) else { return }

            switch response {
            case .page(let page):
                let directive = await runtime.applyRESTTail(
                    page,
                    connectionGeneration: generation
                )
                switch directive {
                case .none:
                    _ = await runtime.finishCatchUp(connectionGeneration: generation)
                case .fetchREST(let cursor):
                    await runConversationCatchUp(
                        runtime: runtime,
                        conversationID: conversationID,
                        generation: generation,
                        initialCursor: cursor,
                        startedAsResnapshot: startedAsResnapshot
                    )
                case .resnapshot:
                    guard startedAsResnapshot == false else { return }
                    _ = await runtime.beginCatchUp(
                        connectionGeneration: generation,
                        resnapshot: true
                    )
                    await runConversationTailCatchUp(
                        runtime: runtime,
                        conversationID: conversationID,
                        generation: generation,
                        startedAsResnapshot: true
                    )
                }
            case .resnapshotRequired:
                guard startedAsResnapshot == false else { return }
                _ = await runtime.beginCatchUp(
                    connectionGeneration: generation,
                    resnapshot: true
                )
                await runConversationTailCatchUp(
                    runtime: runtime,
                    conversationID: conversationID,
                    generation: generation,
                    startedAsResnapshot: true
                )
            case .conversationNotFound:
                _ = await runtime.requireResnapshot(
                    .explicit,
                    connectionGeneration: generation
                )
            }
        } catch is CancellationError {
            return
        } catch {
            let failure = (error as? GatewayFailure) ?? .network
            await failCurrentAttempt(failure, generation: generation)
        }
    }

    private func runLoadOlder(
        runtime: ConversationRuntime,
        conversationID: RemoteConversationID,
        request initialRequest: ConversationOlderPageRequest,
        taskID: UUID
    ) async {
        var request = initialRequest
        var unknownOnlyPages = 0
        defer {
            if conversationOlderTasks[conversationID]?.id == taskID {
                conversationOlderTasks.removeValue(forKey: conversationID)
            }
        }

        do {
            while !Task.isCancelled,
                  unknownOnlyPages < Self.maximumUnknownOnlyOlderPages,
                  isCurrent(
                    runtime: runtime,
                    conversationID: conversationID,
                    generation: request.connectionGeneration
                  ) {
                let response = try await gateway.events(RemoteGatewayEventsRequest(
                    conversationID: conversationID,
                    limit: eventsPageLimit,
                    backward: .before(request.cursor)
                ))
                guard isCurrent(
                    runtime: runtime,
                    conversationID: conversationID,
                    generation: request.connectionGeneration
                ) else { return }

                switch response {
                case .page(let page):
                    let directive = await runtime.applyOlderREST(page, request: request)
                    switch directive {
                    case .none:
                        return
                    case .continueLoading(let nextRequest):
                        unknownOnlyPages += 1
                        request = nextRequest
                    case .resnapshot:
                        await startConversationCatchUp(
                            conversationID: conversationID,
                            generation: request.connectionGeneration,
                            strategy: .resnapshot
                        )
                        return
                    }
                case .resnapshotRequired:
                    _ = await runtime.finishLoadingOlder(request: request)
                    await startConversationCatchUp(
                        conversationID: conversationID,
                        generation: request.connectionGeneration,
                        strategy: .resnapshot
                    )
                    return
                case .conversationNotFound:
                    _ = await runtime.finishLoadingOlder(request: request)
                    return
                }
            }
            _ = await runtime.finishLoadingOlder(request: request)
        } catch is CancellationError {
            _ = await runtime.finishLoadingOlder(request: request)
        } catch {
            _ = await runtime.finishLoadingOlder(request: request)
            let failure = (error as? GatewayFailure) ?? .network
            await failCurrentAttempt(failure, generation: request.connectionGeneration)
        }
    }

    private func isCurrent(
        runtime: ConversationRuntime,
        conversationID: RemoteConversationID,
        generation: UInt64
    ) -> Bool {
        generation == state.connectionGeneration
            && activeConversationIDs.contains(conversationID)
            && conversationRuntimes[conversationID] === runtime
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
        for entry in conversationOlderTasks.values {
            entry.task.cancel()
        }
        conversationOlderTasks.removeAll()
        if let activeSubscription {
            self.activeSubscription = nil
            await activeSubscription.close()
        }
        activeCapabilities.removeAll()
        attemptFailure = nil
    }

    private func publish() async {
        await stateStream.yield(state)
    }
}
