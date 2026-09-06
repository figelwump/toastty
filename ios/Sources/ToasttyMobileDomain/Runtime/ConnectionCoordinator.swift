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
    private enum LifecycleIntent {
        case active
        case suspended
    }

    public struct State: Equatable, Sendable {
        public var connectionGeneration: UInt64
        public var phase: ConnectionCoordinatorPhase
        public var consecutiveFailureCount: Int
        public var latestTransportFailure: NativeTransportFailure?

        public init(
            connectionGeneration: UInt64 = 0,
            phase: ConnectionCoordinatorPhase = .idle,
            consecutiveFailureCount: Int = 0,
            latestTransportFailure: NativeTransportFailure? = nil
        ) {
            self.connectionGeneration = connectionGeneration
            self.phase = phase
            self.consecutiveFailureCount = consecutiveFailureCount
            self.latestTransportFailure = latestTransportFailure
        }
    }

    private let gateway: any GatewayClientProtocol
    private let eventStream: any EventStreamClientProtocol
    private let sessionsRuntime: SessionsRuntime
    private let sleeper: any ConnectionSleeping
    private let jitter: any ConnectionJitterProviding
    private let retryPolicy: ConnectionRetryPolicy
    private let firstSnapshotSleeper: any ConnectionSleeping
    private let firstSnapshotTimeout: Duration
    private let eventsPageLimit: Int
    private let requestIDFactory: any SendRequestIDFactory
    private let stateStream: RuntimeStateStream<State>
    private var sendDispatchWaiter: any SendDispatchWaiting

    private var state = State()
    private var connectionTask: Task<Void, Never>?
    private var connectionRetirementTask: Task<Void, Never>?
    private var connectionLoopID: UUID?
    private var connectionLifecycleRequestID: UUID?
    private var lifecycleIntent = LifecycleIntent.active
    private var lifecycleTransitionsInFlight = 0
    private var activeSubscription: (any EventStreamSubscriptionProtocol)?
    private var firstSnapshotTimeoutTask: Task<Void, Never>?
    private var attemptFailure: GatewayFailure?
    private var activeCapabilities: Set<RemoteGatewayCapability> = []
    private var conversationRuntimes: [RemoteConversationID: ConversationRuntime] = [:]
    private var retainedConversationRuntimes: [RemoteConversationID: ConversationRuntime] = [:]
    private var activeConversationIDs: Set<RemoteConversationID> = []
    private var conversationCatchUpTasks: [RemoteConversationID: Task<Void, Never>] = [:]
    private var conversationCatchUpIDs: [RemoteConversationID: UInt64] = [:]
    private var nextConversationCatchUpID: UInt64 = 0
    private var catchUpCompletionWaiter: (@Sendable () async -> Void)?
    private var conversationOlderTasks: [RemoteConversationID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var deviceScopes: [RemoteDeviceScope]
    private var sendScopeDeniedByHost = false
    private var streamSnapshotOrdinal: UInt64 = 0
    private var authoritativeSessionSnapshot: CompatibleSessionListSnapshot?
    private var pendingLegacyConversationNotFound: Set<RemoteConversationID> = []
    private var reservations: [ConversationSendReservationKey: String] = [:]
    private var sendOperations: [String: SendOperation] = [:]
    private var sendTasks: [String: Task<Void, Never>] = [:]
    private var activeRequestIDs: Set<String> = []
    private var recentRequestIDs: Set<String> = []
    private var issuedRequestIDOrder: [String] = []
    private var invalidatedComposerOrdinals: [RemoteConversationID: UInt64] = [:]

    private struct SendOperation: Sendable {
        var request: RemoteMessageSendRequest
        var reservationKey: ConversationSendReservationKey
        var runtime: ConversationRuntime
        var composerStamp: ConversationComposerStamp
        var callerObservedEnqueue: Bool
        var authorityInvalidatedBeforeDispatch: Bool
        var didBeginDispatch: Bool
    }

    private enum SendClaimResult {
        case claimed(clientRequestID: String, runtime: ConversationRuntime)
        case denied(ConversationSendGateFailure)
    }

    private enum ConversationCatchUpStrategy {
        case initial
        case forward
        case resnapshot
    }

    private static let maximumUnknownOnlyOlderPages = 8
    private static let maximumRecentRequestIDs = 1_024

    public init(
        gateway: any GatewayClientProtocol,
        eventStream: any EventStreamClientProtocol,
        sessionsRuntime: SessionsRuntime = SessionsRuntime(),
        sleeper: any ConnectionSleeping = ContinuousConnectionSleeper(),
        jitter: any ConnectionJitterProviding = SystemConnectionJitter(),
        retryPolicy: ConnectionRetryPolicy = ConnectionRetryPolicy(),
        eventsPageLimit: Int = 200,
        deviceScopes: [RemoteDeviceScope] = [],
        requestIDFactory: any SendRequestIDFactory = UUIDSendRequestIDFactory(),
        firstSnapshotSleeper: any ConnectionSleeping = ContinuousConnectionSleeper(),
        firstSnapshotTimeout: Duration = .seconds(15)
    ) {
        self.gateway = gateway
        self.eventStream = eventStream
        self.sessionsRuntime = sessionsRuntime
        self.sleeper = sleeper
        self.jitter = jitter
        self.retryPolicy = retryPolicy
        self.firstSnapshotSleeper = firstSnapshotSleeper
        self.firstSnapshotTimeout = firstSnapshotTimeout
        self.eventsPageLimit = min(max(eventsPageLimit, 1), 200)
        self.deviceScopes = deviceScopes
        self.requestIDFactory = requestIDFactory
        sendDispatchWaiter = ImmediateSendDispatchWaiter()
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

    /// Replaces the scopes read from the current device endpoint. A prior host
    /// send-scope denial remains latched only until this explicit refresh.
    public func updateDeviceScopes(_ scopes: [RemoteDeviceScope]) async {
        deviceScopes = scopes
        sendScopeDeniedByHost = false
        await publishComposerAuthorities()
    }

    func firstSnapshotDeadlineTaskForTesting() -> Task<Void, Never>? {
        firstSnapshotTimeoutTask
    }

    func catchUpTaskForTesting(_ conversationID: RemoteConversationID) -> Task<Void, Never>? {
        conversationCatchUpTasks[conversationID]
    }

    /// Allows tests to place a stream frame at the REST completion boundary.
    func setCatchUpCompletionWaiter(_ waiter: (@Sendable () async -> Void)?) {
        catchUpCompletionWaiter = waiter
    }

    func setSendDispatchWaiter(_ waiter: any SendDispatchWaiting) {
        sendDispatchWaiter = waiter
    }

    /// Starts the coordinator unless it already owns a connection loop.
    public func connectIfNeeded() async {
        guard lifecycleTransitionsInFlight == 0,
              connectionTask == nil,
              connectionRetirementTask == nil else { return }
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
        lifecycleIntent = .active
        startConnectionLoop()
    }

    /// Cancels all network work while retaining the last readable projection.
    public func suspend() async {
        let requestID = UUID()
        connectionLifecycleRequestID = requestID
        lifecycleIntent = .suspended
        lifecycleTransitionsInFlight += 1
        defer { lifecycleTransitionsInFlight -= 1 }
        await cancelSendsForSuspension()
        let previousTask = connectionTask ?? connectionRetirementTask
        connectionRetirementTask = previousTask
        previousTask?.cancel()
        connectionTask = nil
        connectionLoopID = nil
        // Invalidate every in-flight REST result before awaiting transport
        // teardown. Some URL loading implementations only observe
        // cancellation when their response completes.
        state.connectionGeneration &+= 1
        let suspendedGeneration = state.connectionGeneration
        authoritativeSessionSnapshot = nil
        // Closing the subscription first releases a receive implementation
        // that does not itself observe parent-task cancellation. No new loop
        // can install resources until the old task has then fully unwound.
        await closeAttemptResources()
        await previousTask?.value
        guard connectionLifecycleRequestID == requestID,
              lifecycleIntent == .suspended else { return }
        connectionRetirementTask = nil
        state.phase = .suspended
        state.consecutiveFailureCount = 0
        _ = await sessionsRuntime.suspend(generation: suspendedGeneration)
        for runtime in conversationRuntimes.values {
            _ = await runtime.suspend(connectionGeneration: suspendedGeneration)
        }
        for runtime in retainedConversationRuntimes.values {
            _ = await runtime.suspend(connectionGeneration: suspendedGeneration)
        }
        await publishComposerAuthorities()
        await publish()
    }

    /// Foregrounding reconnects suspended/nonterminal state, but never revives
    /// a terminal admission or authorization failure.
    public func resume() async {
        lifecycleIntent = .active
        if lifecycleTransitionsInFlight > 0 || connectionRetirementTask != nil {
            await restart()
        } else {
            await connectIfNeeded()
        }
    }

    public func restart() async {
        let requestID = UUID()
        connectionLifecycleRequestID = requestID
        lifecycleIntent = .active
        lifecycleTransitionsInFlight += 1
        defer { lifecycleTransitionsInFlight -= 1 }
        let previousTask = connectionTask ?? connectionRetirementTask
        connectionRetirementTask = previousTask
        previousTask?.cancel()
        connectionTask = nil
        connectionLoopID = nil
        // Make responses from the retired attempt stale immediately, rather
        // than relying on cooperative URLSession cancellation.
        state.connectionGeneration &+= 1
        authoritativeSessionSnapshot = nil
        await closeAttemptResources()
        await previousTask?.value
        guard connectionLifecycleRequestID == requestID,
              lifecycleIntent == .active else { return }
        connectionRetirementTask = nil
        state.consecutiveFailureCount = 0
        startConnectionLoop()
    }

    /// Returns the actor that owns one conversation projection and schedules a
    /// subscribe-before-REST catch-up once the shared socket is established.
    public func openConversation(_ conversationID: RemoteConversationID) async -> ConversationRuntime {
        let runtime: ConversationRuntime
        if let existing = conversationRuntimes[conversationID] {
            runtime = existing
        } else if let retained = retainedConversationRuntimes.removeValue(forKey: conversationID) {
            runtime = retained
            conversationRuntimes[conversationID] = runtime
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
        await publishComposerAuthority(for: conversationID, runtime: runtime)
        return runtime
    }

    public func closeConversation(_ conversationID: RemoteConversationID) async {
        activeConversationIDs.remove(conversationID)
        conversationCatchUpIDs.removeValue(forKey: conversationID)
        pendingLegacyConversationNotFound.remove(conversationID)
        conversationCatchUpTasks.removeValue(forKey: conversationID)?.cancel()
        conversationOlderTasks.removeValue(forKey: conversationID)?.task.cancel()
        guard let runtime = conversationRuntimes.removeValue(forKey: conversationID) else {
            return
        }
        _ = await runtime.suspend(connectionGeneration: state.connectionGeneration)
        await runtime.invalidateComposerAuthority(.conversationNotOpen)
        await pruneFinishedSendState(conversationID: conversationID, runtime: runtime)
        let compactedRequestIDs = await runtime.sendReconciliation.compactForInactiveRuntime()
        for requestID in compactedRequestIDs {
            retireRequestID(requestID)
        }
        let reconciliationState = await runtime.sendReconciliation.currentState()
        let hasReservation = reservations.keys.contains { $0.conversationID == conversationID }
        let hasOperation = sendOperations.values.contains {
            $0.request.conversationID == conversationID && $0.runtime === runtime
        }
        if reconciliationState.records.isEmpty == false || hasReservation || hasOperation {
            retainedConversationRuntimes[conversationID] = runtime
        } else {
            await runtime.sendReconciliation.finish()
        }
    }

    public func conversationProjection(
        for conversationID: RemoteConversationID
    ) -> ConversationRuntime? {
        conversationRuntimes[conversationID]
    }

    /// Atomically gates, reserves, and enqueues a send, then schedules its
    /// network task under coordinator ownership. The caller never owns the
    /// request lifetime, so dismissing a sheet or cancelling a view task after
    /// this returns cannot silently cancel delivery.
    public func sendMessage(
        conversationID: RemoteConversationID,
        text: String,
        composerStamp: ConversationComposerStamp
    ) async -> ConversationSendOutcome {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .notEnqueued(.emptyText)
        }
        guard Task.isCancelled == false else { return .notEnqueued(.cancelled) }

        let validatedGate = await validateSendGate(
            conversationID: conversationID,
            composerStamp: composerStamp
        )
        guard case .allowed(let validatedRuntime) = validatedGate else {
            guard case .denied(let failure) = validatedGate else {
                return .notEnqueued(.staleComposerAuthority)
            }
            return .notEnqueued(failure)
        }

        // From this point through claim insertion there is deliberately no
        // suspension: concurrent taps cannot both observe the epoch as free,
        // and a generated ID is claimed before any other actor can reuse it.
        let claim = claimSend(
            conversationID: conversationID,
            text: text,
            composerStamp: composerStamp,
            validatedRuntime: validatedRuntime
        )
        guard case .claimed(let clientRequestID, let runtime) = claim else {
            guard case .denied(let failure) = claim else {
                return .notEnqueued(.staleComposerAuthority)
            }
            return .notEnqueued(failure)
        }

        // Validate the actual claimed request, not a character-count estimate
        // or placeholder ID. No optimistic row or network task exists yet.
        guard let request = sendOperations[clientRequestID]?.request else {
            rollbackUnadmittedClaim(clientRequestID: clientRequestID)
            return .notEnqueued(.requestEncodingFailed)
        }
        do {
            let body = try GatewayClient.encodedMessageSendRequest(request)
            guard body.count <= RemoteGatewayProtocol.maximumRequestBodyBytes else {
                rollbackUnadmittedClaim(clientRequestID: clientRequestID)
                return .notEnqueued(.messageTooLarge)
            }
        } catch {
            rollbackUnadmittedClaim(clientRequestID: clientRequestID)
            return .notEnqueued(.requestEncodingFailed)
        }

        guard let admission = await runtime.sendReconciliation.enqueue(
            clientRequestID: clientRequestID,
            text: text,
            projectionRunID: composerStamp.projectionRunID
        ) else {
            rollbackUnadmittedClaim(clientRequestID: clientRequestID)
            await publishComposerAuthority(for: conversationID, runtime: runtime)
            return .notEnqueued(.tooManyUnresolvedSends)
        }
        for evictedRequestID in admission.evictedConfirmedRequestIDs {
            retireRequestID(evictedRequestID)
        }

        let postAdmissionFailure: ConversationSendGateFailure?
        if Task.isCancelled {
            postAdmissionFailure = .cancelled
        } else if let operation = sendOperations[clientRequestID],
                  operation.runtime === runtime,
                  operation.authorityInvalidatedBeforeDispatch == false {
            postAdmissionFailure = currentCoordinatorGateFailure(
                conversationID: conversationID,
                composerStamp: composerStamp,
                expectedRuntime: runtime
            )
        } else {
            postAdmissionFailure = .staleComposerAuthority
        }
        if let postAdmissionFailure {
            rollbackAdmittedClaim(clientRequestID: clientRequestID)
            _ = await runtime.sendReconciliation.discardBeforeDispatch(
                clientRequestID: clientRequestID
            )
            forgetClaimedRequestID(clientRequestID)
            await publishComposerAuthority(for: conversationID, runtime: runtime)
            return .notEnqueued(postAdmissionFailure)
        }

        guard sendOperations[clientRequestID] != nil else {
            let reservationKey = ConversationSendReservationKey(
                conversationID: conversationID,
                projectionRunID: composerStamp.projectionRunID,
                inputEpoch: composerStamp.inputEpoch
            )
            releaseReservation(reservationKey, clientRequestID: clientRequestID)
            _ = await runtime.sendReconciliation.discardBeforeDispatch(
                clientRequestID: clientRequestID
            )
            forgetClaimedRequestID(clientRequestID)
            await publishComposerAuthority(for: conversationID, runtime: runtime)
            return .notEnqueued(.staleComposerAuthority)
        }

        // Publish the reservation before committing the enqueue to the caller.
        // This actor hop leaves callerObservedEnqueue false so an authority
        // change interleaving here can still roll back the unobserved enqueue.
        await publishComposerAuthority(for: conversationID, runtime: runtime)

        let postPublicationFailure: ConversationSendGateFailure?
        if Task.isCancelled {
            postPublicationFailure = .cancelled
        } else if let operation = sendOperations[clientRequestID],
                  operation.runtime === runtime,
                  operation.authorityInvalidatedBeforeDispatch == false,
                  reservations[operation.reservationKey] == clientRequestID {
            postPublicationFailure = currentCoordinatorGateFailure(
                conversationID: conversationID,
                composerStamp: composerStamp,
                expectedRuntime: runtime
            )
        } else {
            postPublicationFailure = .staleComposerAuthority
        }
        if let postPublicationFailure {
            rollbackAdmittedClaim(clientRequestID: clientRequestID)
            _ = await runtime.sendReconciliation.discardBeforeDispatch(
                clientRequestID: clientRequestID
            )
            forgetClaimedRequestID(clientRequestID)
            await publishComposerAuthority(for: conversationID, runtime: runtime)
            return .notEnqueued(postPublicationFailure)
        }

        guard var operation = sendOperations[clientRequestID],
              operation.runtime === runtime,
              reservations[operation.reservationKey] == clientRequestID else {
            rollbackAdmittedClaim(clientRequestID: clientRequestID)
            _ = await runtime.sendReconciliation.discardBeforeDispatch(
                clientRequestID: clientRequestID
            )
            forgetClaimedRequestID(clientRequestID)
            await publishComposerAuthority(for: conversationID, runtime: runtime)
            return .notEnqueued(.staleComposerAuthority)
        }
        operation.callerObservedEnqueue = true
        sendOperations[clientRequestID] = operation

        sendTasks[clientRequestID] = Task { [weak self] in
            await self?.runSend(clientRequestID: clientRequestID)
        }
        return .enqueued(clientRequestID: clientRequestID)
    }

    public func dismissSendReceipt(
        conversationID: RemoteConversationID,
        clientRequestID: String
    ) async {
        guard let runtime = conversationRuntimes[conversationID]
                ?? retainedConversationRuntimes[conversationID] else { return }
        // The delivery transition, never receipt dismissal, releases a matching
        // reservation. Prune while the terminal record is still observable.
        await pruneFinishedSendState(conversationID: conversationID, runtime: runtime)
        if await runtime.sendReconciliation.dismiss(clientRequestID: clientRequestID) {
            retireRequestID(clientRequestID)
        }
        await removeInactiveRuntimeIfSafe(conversationID: conversationID, runtime: runtime)
    }

    /// Acknowledges a boundary only when the connected host advertises the
    /// operation. `nil` is a capability/lifecycle refusal, not a transport
    /// failure, so presentation code must not retry it as an outage.
    public func acknowledgeConversationRead(
        _ request: RemoteConversationReadAcknowledgementRequest
    ) async throws -> RemoteConversationReadAcknowledgementResponse? {
        guard state.phase == .live,
              activeCapabilities.contains(.conversationReadAcknowledgement),
              activeConversationIDs.contains(request.conversationID) else {
            return nil
        }
        return try await gateway.acknowledgeConversationRead(request)
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
            authoritativeSessionSnapshot = nil
            pendingLegacyConversationNotFound.removeAll()
            state.phase = failureCount == 0
                ? .connecting
                : .reconnecting(
                    failureCount: failureCount,
                    showsBanner: retryPolicy.shouldShowReconnectingBanner(
                        afterFailureCount: failureCount
                    )
                )
            state.consecutiveFailureCount = failureCount
            await publishComposerAuthorities()
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
                let failure = (error as? GatewayFailure) ?? .network(reason: .other)
                state.latestTransportFailure = failure.transportFailure
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
                authoritativeSessionSnapshot = nil
                _ = await sessionsRuntime.markReconnecting(generation: generation)
                await publishComposerAuthorities()
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
        startFirstSnapshotDeadline(generation: generation)
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
                if let attemptFailure { throw attemptFailure }
                try await handleStreamMessage(message, generation: generation)
            }
            throw CancellationError()
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            if let attemptFailure {
                self.attemptFailure = nil
                throw attemptFailure
            }
            throw GatewayFailure.network(reason: .connectionLost)
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

    private func startFirstSnapshotDeadline(generation: UInt64) {
        firstSnapshotTimeoutTask?.cancel()
        firstSnapshotTimeoutTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForFirstSnapshotDeadline(generation: generation)
        }
    }

    private func waitForFirstSnapshotDeadline(generation: UInt64) async {
        do {
            try await firstSnapshotSleeper.sleep(for: firstSnapshotTimeout)
        } catch {
            return
        }
        guard !Task.isCancelled,
              generation == state.connectionGeneration,
              state.phase == .awaitingFreshSessionSnapshot else { return }
        await failCurrentAttempt(.network(reason: .timedOut), generation: generation)
    }

    private func handleStreamMessage(
        _ message: CompatibleGatewayStreamMessage,
        generation: UInt64
    ) async throws {
        switch message {
        case .sessionList(let snapshot):
            // Decoding and generation admission already succeeded. Stop the
            // first-snapshot deadline before the next actor hop. Quiet live
            // connections do not have an inactivity deadline.
            firstSnapshotTimeoutTask?.cancel()
            firstSnapshotTimeoutTask = nil
            guard await sessionsRuntime.applyStreamSnapshot(snapshot, generation: generation) else {
                return
            }
            streamSnapshotOrdinal &+= 1
            invalidatedComposerOrdinals.removeAll(keepingCapacity: true)
            authoritativeSessionSnapshot = snapshot
            state.consecutiveFailureCount = 0
            state.latestTransportFailure = nil
            state.phase = .live
            await reconcileAuthoritativeSnapshot(snapshot)
            await resolvePendingLegacyConversationNotFound(generation: generation)
            await publishComposerAuthorities()
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
            await pruneFinishedSendState(
                conversationID: page.conversationID,
                runtime: runtime
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
        nextConversationCatchUpID &+= 1
        let catchUpID = nextConversationCatchUpID
        conversationCatchUpIDs[conversationID] = catchUpID
        conversationOlderTasks.removeValue(forKey: conversationID)?.task.cancel()
        let resnapshot = strategy == .resnapshot
        guard await runtime.beginCatchUp(
            connectionGeneration: generation,
            resnapshot: resnapshot,
            catchUpID: catchUpID
        ) else {
            return
        }

        guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }

        let usesTail = strategy != .forward
            && activeCapabilities.contains(.conversationBackwardPaging)
        if usesTail {
            conversationCatchUpTasks[conversationID] = Task { [weak self] in
                await self?.runConversationTailCatchUp(
                    runtime: runtime,
                    conversationID: conversationID,
                    generation: generation,
                    catchUpID: catchUpID,
                    startedAsResnapshot: resnapshot
                )
            }
        } else {
            let initialCursor = resnapshot ? nil : await runtime.currentState().cursor
            guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
            conversationCatchUpTasks[conversationID] = Task { [weak self] in
                await self?.runConversationCatchUp(
                    runtime: runtime,
                    conversationID: conversationID,
                    generation: generation,
                    catchUpID: catchUpID,
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
        catchUpID: UInt64,
        initialCursor: ConversationEventCursor?,
        startedAsResnapshot: Bool
    ) async {
        var cursor = initialCursor
        var isResnapshot = startedAsResnapshot

        guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
        do {
            while isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) {
                let response = try await gateway.events(
                    conversationID: conversationID,
                    cursor: cursor,
                    limit: eventsPageLimit
                )
                guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }

                switch response {
                case .page(let page):
                    let directive = await runtime.applyREST(
                        page,
                        connectionGeneration: generation,
                        catchUpID: catchUpID
                    )
                    guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
                    switch directive {
                    case .none:
                        if await runtime.finishCatchUp(connectionGeneration: generation, catchUpID: catchUpID) {
                            await pruneFinishedSendState(
                                conversationID: conversationID,
                                runtime: runtime
                            )
                            return
                        }
                        guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
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
                            resnapshot: true,
                            catchUpID: catchUpID
                        )
                    }

                case .resnapshotRequired:
                    guard isResnapshot == false else { return }
                    isResnapshot = true
                    cursor = nil
                    _ = await runtime.beginCatchUp(
                        connectionGeneration: generation,
                        resnapshot: true,
                        catchUpID: catchUpID
                    )

                case .conversationNotFound:
                    if await completeLegacyEmptyConversationIfKnown(
                        runtime: runtime,
                        conversationID: conversationID,
                        generation: generation,
                        catchUpID: catchUpID
                    ) == false {
                        guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
                        pendingLegacyConversationNotFound.insert(conversationID)
                        _ = await runtime.requireResnapshot(
                            .explicit,
                            connectionGeneration: generation,
                            catchUpID: catchUpID
                        )
                    }
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
            let failure = (error as? GatewayFailure) ?? .network(reason: .other)
            await failCurrentAttempt(failure, generation: generation)
        }
    }

    private func runConversationTailCatchUp(
        runtime: ConversationRuntime,
        conversationID: RemoteConversationID,
        generation: UInt64,
        catchUpID: UInt64,
        startedAsResnapshot: Bool
    ) async {
        guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
        do {
            let response = try await gateway.events(RemoteGatewayEventsRequest(
                conversationID: conversationID,
                limit: eventsPageLimit,
                backward: .latest
            ))
            guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }

            switch response {
            case .page(let page):
                let directive = await runtime.applyRESTTail(
                    page,
                    connectionGeneration: generation,
                    catchUpID: catchUpID
                )
                guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
                switch directive {
                case .none:
                    await catchUpCompletionWaiter?()
                    guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
                    if await runtime.finishCatchUp(connectionGeneration: generation, catchUpID: catchUpID) {
                        await pruneFinishedSendState(conversationID: conversationID, runtime: runtime)
                    } else {
                        guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
                        let current = await runtime.currentState()
                        guard current.phase == .catchingUp else { return }
                        await runConversationCatchUp(
                            runtime: runtime,
                            conversationID: conversationID,
                            generation: generation,
                            catchUpID: catchUpID,
                            initialCursor: current.cursor,
                            startedAsResnapshot: startedAsResnapshot
                        )
                    }
                case .fetchREST(let cursor):
                    await runConversationCatchUp(
                        runtime: runtime,
                        conversationID: conversationID,
                        generation: generation,
                        catchUpID: catchUpID,
                        initialCursor: cursor,
                        startedAsResnapshot: startedAsResnapshot
                    )
                case .resnapshot:
                    guard startedAsResnapshot == false else { return }
                    _ = await runtime.beginCatchUp(
                        connectionGeneration: generation,
                        resnapshot: true,
                        catchUpID: catchUpID
                    )
                    await runConversationTailCatchUp(
                        runtime: runtime,
                        conversationID: conversationID,
                        generation: generation,
                        catchUpID: catchUpID,
                        startedAsResnapshot: true
                    )
                }
            case .resnapshotRequired:
                guard startedAsResnapshot == false else { return }
                _ = await runtime.beginCatchUp(
                    connectionGeneration: generation,
                    resnapshot: true,
                    catchUpID: catchUpID
                )
                await runConversationTailCatchUp(
                    runtime: runtime,
                    conversationID: conversationID,
                    generation: generation,
                    catchUpID: catchUpID,
                    startedAsResnapshot: true
                )
            case .conversationNotFound:
                if await completeLegacyEmptyConversationIfKnown(
                    runtime: runtime,
                    conversationID: conversationID,
                    generation: generation,
                    catchUpID: catchUpID
                ) == false {
                    guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
                    pendingLegacyConversationNotFound.insert(conversationID)
                    _ = await runtime.requireResnapshot(
                        .explicit,
                        connectionGeneration: generation,
                        catchUpID: catchUpID
                    )
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return }
            let failure = (error as? GatewayFailure) ?? .network(reason: .other)
            await failCurrentAttempt(failure, generation: generation)
        }
    }

    private func resolvePendingLegacyConversationNotFound(
        generation: UInt64
    ) async {
        let conversationIDs = pendingLegacyConversationNotFound
        pendingLegacyConversationNotFound.removeAll()
        for conversationID in conversationIDs {
            guard let runtime = conversationRuntimes[conversationID],
                  let catchUpID = conversationCatchUpIDs[conversationID] else { continue }
            _ = await completeLegacyEmptyConversationIfKnown(
                runtime: runtime,
                conversationID: conversationID,
                generation: generation,
                catchUpID: catchUpID
            )
        }
    }

    /// Older hosts returned `not_found` until the first projected event was
    /// created. The fresh session snapshot is the authority that distinguishes
    /// that empty conversation from a genuinely missing or nonempty one.
    private func completeLegacyEmptyConversationIfKnown(
        runtime: ConversationRuntime,
        conversationID: RemoteConversationID,
        generation: UInt64,
        catchUpID: UInt64
    ) async -> Bool {
        guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID),
              let snapshot = authoritativeSessionSnapshot,
              let summary = snapshot.conversations.first(where: {
                  $0.conversationID == conversationID
              }),
              summary.latestSequence == 0 else {
            return false
        }

        let current = await runtime.currentState()
        guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return false }
        if current.phase != .catchingUp
            || current.projectionRunID != snapshot.projectionRunID
            || current.projectionGeneration != summary.projectionGeneration
            || (current.cursor?.afterSequence ?? 0) > 0
            || current.latestSequence > 0 {
            guard await runtime.beginCatchUp(
                connectionGeneration: generation,
                resnapshot: true,
                catchUpID: catchUpID
            ) else { return false }
        }

        let page = CompatibleConversationEventPage(
            conversationID: conversationID,
            projectionRunID: snapshot.projectionRunID,
            projectionGeneration: summary.projectionGeneration,
            events: [],
            latestSequence: 0,
            firstAvailableSequence: nil,
            historyTruncated: false
        )
        guard await runtime.applyREST(
            page,
            connectionGeneration: generation,
            catchUpID: catchUpID
        ) == .none else {
            return false
        }
        guard await runtime.finishCatchUp(connectionGeneration: generation, catchUpID: catchUpID) else {
            return false
        }
        guard isCurrentCatchUp(runtime: runtime, conversationID: conversationID, generation: generation, catchUpID: catchUpID) else { return false }
        pendingLegacyConversationNotFound.remove(conversationID)
        await pruneFinishedSendState(conversationID: conversationID, runtime: runtime)
        return true
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
            let failure = (error as? GatewayFailure) ?? .network(reason: .other)
            await failCurrentAttempt(failure, generation: request.connectionGeneration)
        }
    }

    private func isCurrentCatchUp(
        runtime: ConversationRuntime,
        conversationID: RemoteConversationID,
        generation: UInt64,
        catchUpID: UInt64
    ) -> Bool {
        !Task.isCancelled
            && conversationCatchUpIDs[conversationID] == catchUpID
            && isCurrent(runtime: runtime, conversationID: conversationID, generation: generation)
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

    private enum SendGateValidation {
        case allowed(runtime: ConversationRuntime)
        case denied(ConversationSendGateFailure)
    }

    private func cancelSendsForSuspension() async {
        let requestIDs = Array(sendOperations.keys)
        for requestID in requestIDs {
            guard let operation = sendOperations[requestID] else { continue }
            sendTasks[requestID]?.cancel()
            if operation.didBeginDispatch {
                await operation.runtime.sendReconciliation.apply(
                    .uncertain,
                    clientRequestID: requestID
                )
                sendOperations.removeValue(forKey: requestID)
                sendTasks.removeValue(forKey: requestID)
            } else if operation.callerObservedEnqueue {
                await settleCommittedBeforeDispatch(
                    clientRequestID: requestID,
                    operation: operation
                )
            } else {
                var invalidated = operation
                invalidated.authorityInvalidatedBeforeDispatch = true
                sendOperations[requestID] = invalidated
                releaseReservation(
                    operation.reservationKey,
                    clientRequestID: requestID
                )
            }
        }
    }

    private func validateSendGate(
        conversationID: RemoteConversationID,
        composerStamp: ConversationComposerStamp
    ) async -> SendGateValidation {
        if let failure = currentCoordinatorGateFailure(
            conversationID: conversationID,
            composerStamp: composerStamp,
            expectedRuntime: nil
        ) {
            return .denied(failure)
        }
        guard let runtime = conversationRuntimes[conversationID] else {
            return .denied(.conversationNotOpen)
        }

        let runtimeState = await runtime.currentState()
        if let failure = currentCoordinatorGateFailure(
            conversationID: conversationID,
            composerStamp: composerStamp,
            expectedRuntime: runtime
        ) {
            return .denied(failure)
        }
        guard runtimeState.phase == .live else {
            return .denied(.conversationNotLive)
        }
        guard runtimeState.connectionGeneration == composerStamp.connectionGeneration,
              runtimeState.projectionRunID == composerStamp.projectionRunID,
              runtimeState.projectionGeneration == composerStamp.projectionGeneration,
              (runtimeState.cursor?.afterSequence ?? 0) >= composerStamp.latestSequence else {
            return .denied(.transcriptNotCaughtUp)
        }
        return .allowed(runtime: runtime)
    }

    private func currentCoordinatorGateFailure(
        conversationID: RemoteConversationID,
        composerStamp: ConversationComposerStamp,
        expectedRuntime: ConversationRuntime?,
        allowsRetainedRuntime: Bool = false
    ) -> ConversationSendGateFailure? {
        guard state.phase == .live,
              let snapshot = authoritativeSessionSnapshot else {
            return .coordinatorNotLive
        }
        guard deviceScopes.contains(.send), sendScopeDeniedByHost == false else {
            return .deviceSendScopeDenied
        }
        let runtime: ConversationRuntime?
        if activeConversationIDs.contains(conversationID) {
            runtime = conversationRuntimes[conversationID]
        } else if allowsRetainedRuntime {
            runtime = retainedConversationRuntimes[conversationID]
        } else {
            runtime = nil
        }
        guard let runtime,
              expectedRuntime.map({ $0 === runtime }) ?? true else {
            return .conversationNotOpen
        }
        guard let summary = snapshot.conversations.first(where: {
            $0.conversationID == conversationID
        }) else {
            return .conversationMissing
        }
        guard invalidatedComposerOrdinals[conversationID] != streamSnapshotOrdinal else {
            return .staleComposerAuthority
        }
        guard case .openPrompt(let epoch) = summary.inputAvailability else {
            return .inputUnavailable
        }
        let currentStamp = ConversationComposerStamp(
            connectionGeneration: state.connectionGeneration,
            streamSnapshotOrdinal: streamSnapshotOrdinal,
            projectionRunID: snapshot.projectionRunID,
            projectionGeneration: summary.projectionGeneration,
            latestSequence: summary.latestSequence,
            inputEpoch: epoch
        )
        return composerStamp == currentStamp ? nil : .staleComposerAuthority
    }

    private func claimSend(
        conversationID: RemoteConversationID,
        text: String,
        composerStamp: ConversationComposerStamp,
        validatedRuntime: ConversationRuntime
    ) -> SendClaimResult {
        if let failure = currentCoordinatorGateFailure(
            conversationID: conversationID,
            composerStamp: composerStamp,
            expectedRuntime: validatedRuntime
        ) {
            return .denied(failure)
        }
        let reservationKey = ConversationSendReservationKey(
            conversationID: conversationID,
            projectionRunID: composerStamp.projectionRunID,
            inputEpoch: composerStamp.inputEpoch
        )
        guard reservations[reservationKey] == nil else {
            return .denied(.sendAlreadyReserved)
        }
        guard let clientRequestID = mintRequestID() else {
            return .denied(.tooManyUnresolvedSends)
        }
        let request = RemoteMessageSendRequest(
            conversationID: conversationID,
            clientRequestID: clientRequestID,
            expectedInputEpoch: composerStamp.inputEpoch,
            text: text
        )
        reservations[reservationKey] = clientRequestID
        sendOperations[clientRequestID] = SendOperation(
            request: request,
            reservationKey: reservationKey,
            runtime: validatedRuntime,
            composerStamp: composerStamp,
            callerObservedEnqueue: false,
            authorityInvalidatedBeforeDispatch: false,
            didBeginDispatch: false
        )
        return .claimed(clientRequestID: clientRequestID, runtime: validatedRuntime)
    }

    private func mintRequestID() -> String? {
        for _ in 0..<16 {
            let requestID = requestIDFactory.makeRequestID()
            guard requestID.isEmpty == false else { continue }
            guard activeRequestIDs.contains(requestID) == false,
                  recentRequestIDs.contains(requestID) == false else { continue }
            activeRequestIDs.insert(requestID)
            return requestID
        }
        return nil
    }

    private func rollbackUnadmittedClaim(clientRequestID: String) {
        guard let operation = sendOperations.removeValue(forKey: clientRequestID),
              operation.didBeginDispatch == false,
              operation.callerObservedEnqueue == false else { return }
        releaseReservation(operation.reservationKey, clientRequestID: clientRequestID)
        sendTasks.removeValue(forKey: clientRequestID)?.cancel()
        activeRequestIDs.remove(clientRequestID)
    }

    private func rollbackAdmittedClaim(clientRequestID: String) {
        guard let operation = sendOperations.removeValue(forKey: clientRequestID),
              operation.didBeginDispatch == false,
              operation.callerObservedEnqueue == false else { return }
        releaseReservation(operation.reservationKey, clientRequestID: clientRequestID)
        sendTasks.removeValue(forKey: clientRequestID)?.cancel()
    }

    private func retireRequestID(_ clientRequestID: String) {
        guard activeRequestIDs.remove(clientRequestID) != nil else { return }
        guard recentRequestIDs.insert(clientRequestID).inserted else { return }
        issuedRequestIDOrder.append(clientRequestID)
        while issuedRequestIDOrder.count > Self.maximumRecentRequestIDs {
            recentRequestIDs.remove(issuedRequestIDOrder.removeFirst())
        }
    }

    private func forgetClaimedRequestID(_ clientRequestID: String) {
        activeRequestIDs.remove(clientRequestID)
    }

    private func runSend(clientRequestID: String) async {
        await sendDispatchWaiter.waitBeforeDispatch()
        guard var operation = sendOperations[clientRequestID] else {
            sendTasks.removeValue(forKey: clientRequestID)
            return
        }
        let gateFailure: ConversationSendGateFailure?
        if Task.isCancelled {
            gateFailure = .cancelled
        } else if operation.authorityInvalidatedBeforeDispatch {
            gateFailure = .staleComposerAuthority
        } else if reservations[operation.reservationKey] != clientRequestID {
            gateFailure = .staleComposerAuthority
        } else {
            gateFailure = currentCoordinatorGateFailure(
                conversationID: operation.request.conversationID,
                composerStamp: operation.composerStamp,
                expectedRuntime: operation.runtime,
                allowsRetainedRuntime: operation.callerObservedEnqueue
            )
        }
        guard gateFailure == nil, operation.callerObservedEnqueue else {
            await settleCommittedBeforeDispatch(
                clientRequestID: clientRequestID,
                operation: operation
            )
            return
        }

        operation.didBeginDispatch = true
        sendOperations[clientRequestID] = operation

        do {
            let result = try await gateway.send(operation.request)
            await finishSendResponse(
                result,
                clientRequestID: clientRequestID,
                operation: operation
            )
        } catch {
            await finishSendFailure(
                error,
                clientRequestID: clientRequestID,
                operation: operation
            )
        }
    }

    private func settleCommittedBeforeDispatch(
        clientRequestID: String,
        operation: SendOperation
    ) async {
        guard let current = sendOperations[clientRequestID],
              current.runtime === operation.runtime,
              current.request == operation.request,
              current.didBeginDispatch == false,
              current.callerObservedEnqueue else { return }
        sendOperations.removeValue(forKey: clientRequestID)
        sendTasks.removeValue(forKey: clientRequestID)?.cancel()
        releaseReservation(operation.reservationKey, clientRequestID: clientRequestID)
        invalidateComposerAuthority(for: operation)
        await operation.runtime.sendReconciliation.markOperationFailed(
            clientRequestID: clientRequestID
        )
        await publishComposerAuthority(
            for: operation.request.conversationID,
            runtime: operation.runtime
        )
    }

    private func finishSendResponse(
        _ result: RemoteMessageSendResult,
        clientRequestID: String,
        operation: SendOperation
    ) async {
        guard let current = sendOperations[clientRequestID],
              current.runtime === operation.runtime,
              current.request == operation.request else { return }

        invalidateComposerAuthority(for: operation)
        await publishComposerAuthority(
            for: operation.request.conversationID,
            runtime: operation.runtime
        )

        switch result {
        case .accepted(let epoch) where epoch != operation.request.expectedInputEpoch:
            await operation.runtime.sendReconciliation.apply(
                .uncertain,
                clientRequestID: clientRequestID
            )
        case .accepted, .duplicate, .uncertain:
            await operation.runtime.sendReconciliation.apply(
                result,
                clientRequestID: clientRequestID
            )
        case .rejected(let reason):
            await operation.runtime.sendReconciliation.apply(
                result,
                clientRequestID: clientRequestID
            )
            releaseReservation(operation.reservationKey, clientRequestID: clientRequestID)
            if reason == .sendScopeDenied {
                sendScopeDeniedByHost = true
                await publishComposerAuthorities()
            }
        }

        sendOperations.removeValue(forKey: clientRequestID)
        sendTasks.removeValue(forKey: clientRequestID)
        await pruneFinishedSendState(
            conversationID: operation.request.conversationID,
            runtime: operation.runtime
        )
        await removeInactiveRuntimeIfSafe(
            conversationID: operation.request.conversationID,
            runtime: operation.runtime
        )
    }

    private func finishSendFailure(
        _ error: Error,
        clientRequestID: String,
        operation: SendOperation
    ) async {
        guard let current = sendOperations[clientRequestID],
              current.runtime === operation.runtime,
              current.request == operation.request else { return }

        let failure = (error as? GatewayFailure) ?? .network(reason: .other)
        invalidateComposerAuthority(for: operation)
        await publishComposerAuthority(
            for: operation.request.conversationID,
            runtime: operation.runtime
        )
        switch failure {
        case .unauthenticated, .authorizationDenied:
            if await operation.runtime.sendReconciliation.discardNotDelivered(
                clientRequestID: clientRequestID
            ) {
                retireRequestID(clientRequestID)
            }
            releaseReservation(operation.reservationKey, clientRequestID: clientRequestID)
        case .protocolMismatch:
            await operation.runtime.sendReconciliation.apply(
                .uncertain,
                clientRequestID: clientRequestID
            )
        case .network, .server:
            await operation.runtime.sendReconciliation.apply(
                .uncertain,
                clientRequestID: clientRequestID
            )
        case .rateLimited, .http, .operationCompatibility, .invalidResponse:
            await operation.runtime.sendReconciliation.markOperationFailed(
                clientRequestID: clientRequestID
            )
            releaseReservation(operation.reservationKey, clientRequestID: clientRequestID)
            invalidateComposerAuthority(for: operation)
            await publishComposerAuthority(
                for: operation.request.conversationID,
                runtime: operation.runtime
            )
        }

        sendOperations.removeValue(forKey: clientRequestID)
        sendTasks.removeValue(forKey: clientRequestID)

        switch failure {
        case .unauthenticated, .authorizationDenied, .protocolMismatch:
            await terminateConnectionAfterSendFailure(failure)
        case .network, .rateLimited, .server, .http,
             .operationCompatibility, .invalidResponse:
            break
        }
        await removeInactiveRuntimeIfSafe(
            conversationID: operation.request.conversationID,
            runtime: operation.runtime
        )
    }

    private func releaseReservation(
        _ key: ConversationSendReservationKey,
        clientRequestID: String
    ) {
        guard reservations[key] == clientRequestID else { return }
        reservations.removeValue(forKey: key)
    }

    private func invalidateComposerAuthority(for operation: SendOperation) {
        let stamp = operation.composerStamp
        guard stamp.connectionGeneration == state.connectionGeneration,
              stamp.streamSnapshotOrdinal == streamSnapshotOrdinal else {
            return
        }
        invalidatedComposerOrdinals[operation.request.conversationID] =
            stamp.streamSnapshotOrdinal
    }

    private func terminateConnectionAfterSendFailure(_ failure: GatewayFailure) async {
        let previousTask = connectionTask
        previousTask?.cancel()
        connectionTask = nil
        connectionLoopID = nil
        state.connectionGeneration &+= 1
        authoritativeSessionSnapshot = nil
        await closeAttemptResources()
        await previousTask?.value
        await applyTerminalFailure(failure, generation: state.connectionGeneration)
    }

    private func reconcileAuthoritativeSnapshot(
        _ snapshot: CompatibleSessionListSnapshot
    ) async {
        let preDispatchRequestIDs = sendOperations.compactMap { requestID, operation in
            operation.didBeginDispatch ? nil : requestID
        }
        for requestID in preDispatchRequestIDs {
            guard let operation = sendOperations[requestID] else { continue }
            if operation.callerObservedEnqueue {
                await settleCommittedBeforeDispatch(
                    clientRequestID: requestID,
                    operation: operation
                )
            } else {
                var invalidated = operation
                invalidated.authorityInvalidatedBeforeDispatch = true
                sendOperations[requestID] = invalidated
                releaseReservation(
                    operation.reservationKey,
                    clientRequestID: requestID
                )
            }
        }

        var seenReconciliations: Set<ObjectIdentifier> = []
        for runtime in Array(conversationRuntimes.values) + Array(retainedConversationRuntimes.values) {
            let identifier = ObjectIdentifier(runtime.sendReconciliation)
            guard seenReconciliations.insert(identifier).inserted else { continue }
            await runtime.sendReconciliation.projectionDidChange(to: snapshot.projectionRunID)
        }

        let staleReservations = reservations.compactMap { key, requestID -> (ConversationSendReservationKey, String)? in
            guard let summary = snapshot.conversations.first(where: {
                $0.conversationID == key.conversationID
            }), snapshot.projectionRunID == key.projectionRunID,
                  case .openPrompt(let epoch) = summary.inputAvailability,
                  epoch == key.inputEpoch else {
                return (key, requestID)
            }
            return nil
        }
        for (key, requestID) in staleReservations {
            releaseReservation(key, clientRequestID: requestID)
        }

        for (conversationID, runtime) in conversationRuntimes {
            await pruneFinishedSendState(conversationID: conversationID, runtime: runtime)
        }
        for (conversationID, runtime) in retainedConversationRuntimes {
            await pruneFinishedSendState(conversationID: conversationID, runtime: runtime)
        }
        for key in reservations.keys where key.projectionRunID == snapshot.projectionRunID {
            invalidatedComposerOrdinals[key.conversationID] = streamSnapshotOrdinal
        }
    }

    private func publishComposerAuthorities() async {
        for (conversationID, runtime) in conversationRuntimes {
            await publishComposerAuthority(for: conversationID, runtime: runtime)
        }
        for (conversationID, runtime) in retainedConversationRuntimes {
            await publishComposerAuthority(for: conversationID, runtime: runtime)
        }
    }

    private func publishComposerAuthority(
        for conversationID: RemoteConversationID,
        runtime: ConversationRuntime
    ) async {
        guard activeConversationIDs.contains(conversationID) else {
            await runtime.invalidateComposerAuthority(.conversationNotOpen)
            return
        }
        guard state.phase == .live,
              let snapshot = authoritativeSessionSnapshot else {
            await runtime.invalidateComposerAuthority(.coordinatorNotLive)
            return
        }
        guard let summary = snapshot.conversations.first(where: {
            $0.conversationID == conversationID
        }) else {
            await runtime.invalidateComposerAuthority(.conversationMissing)
            return
        }
        if case .openPrompt(let epoch) = summary.inputAvailability {
            let reservationKey = ConversationSendReservationKey(
                conversationID: conversationID,
                projectionRunID: snapshot.projectionRunID,
                inputEpoch: epoch
            )
            if reservations[reservationKey] != nil {
                await runtime.applyComposerSnapshot(CoordinatorComposerSnapshot(
                    stamp: nil,
                    inputAvailability: summary.inputAvailability,
                    hasDeviceSendScope: deviceScopes.contains(.send) && !sendScopeDeniedByHost,
                    coordinatorIsLive: true,
                    gateFailure: .sendAlreadyReserved
                ))
                return
            }
        }
        if invalidatedComposerOrdinals[conversationID] == streamSnapshotOrdinal {
            await runtime.applyComposerSnapshot(CoordinatorComposerSnapshot(
                stamp: nil,
                inputAvailability: summary.inputAvailability,
                hasDeviceSendScope: deviceScopes.contains(.send) && !sendScopeDeniedByHost,
                coordinatorIsLive: true,
                gateFailure: .staleComposerAuthority
            ))
            return
        }

        let stamp: ConversationComposerStamp?
        if case .openPrompt(let epoch) = summary.inputAvailability {
            stamp = ConversationComposerStamp(
                connectionGeneration: state.connectionGeneration,
                streamSnapshotOrdinal: streamSnapshotOrdinal,
                projectionRunID: snapshot.projectionRunID,
                projectionGeneration: summary.projectionGeneration,
                latestSequence: summary.latestSequence,
                inputEpoch: epoch
            )
        } else {
            stamp = nil
        }
        await runtime.applyComposerSnapshot(CoordinatorComposerSnapshot(
            stamp: stamp,
            inputAvailability: summary.inputAvailability,
            hasDeviceSendScope: deviceScopes.contains(.send) && !sendScopeDeniedByHost,
            coordinatorIsLive: true,
            gateFailure: nil
        ))
    }

    private func pruneFinishedSendState(
        conversationID: RemoteConversationID,
        runtime: ConversationRuntime
    ) async {
        let reconciliation = await runtime.sendReconciliation.currentState()
        let statesByID = Dictionary(uniqueKeysWithValues: reconciliation.records.map {
            ($0.clientRequestID, $0.deliveryState)
        })
        let releasable = reservations.compactMap { key, requestID -> (ConversationSendReservationKey, String)? in
            guard key.conversationID == conversationID,
                  let deliveryState = statesByID[requestID] else { return nil }
            switch deliveryState {
            case .confirmed, .rejected, .operationFailed, .deliveryUnconfirmed:
                return (key, requestID)
            case .pending, .uncertain:
                return nil
            }
        }
        for (key, requestID) in releasable {
            releaseReservation(key, clientRequestID: requestID)
            if let snapshot = authoritativeSessionSnapshot,
               snapshot.projectionRunID == key.projectionRunID,
               let summary = snapshot.conversations.first(where: {
                   $0.conversationID == conversationID
               }),
               case .openPrompt(let epoch) = summary.inputAvailability,
               epoch == key.inputEpoch {
                invalidatedComposerOrdinals[conversationID] = streamSnapshotOrdinal
            }
        }
        if releasable.isEmpty == false {
            await publishComposerAuthority(for: conversationID, runtime: runtime)
        }
    }

    private func removeInactiveRuntimeIfSafe(
        conversationID: RemoteConversationID,
        runtime: ConversationRuntime
    ) async {
        guard activeConversationIDs.contains(conversationID) == false,
              retainedConversationRuntimes[conversationID] === runtime else { return }
        let reconciliation = await runtime.sendReconciliation.currentState()
        let hasReservation = reservations.keys.contains { $0.conversationID == conversationID }
        let hasOperation = sendOperations.values.contains {
            $0.request.conversationID == conversationID && $0.runtime === runtime
        }
        guard reconciliation.records.isEmpty, !hasReservation, !hasOperation else { return }
        retainedConversationRuntimes.removeValue(forKey: conversationID)
        await runtime.sendReconciliation.finish()
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
        authoritativeSessionSnapshot = nil
        state.consecutiveFailureCount = 0
        state.latestTransportFailure = failure.transportFailure
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
        await publishComposerAuthorities()
        await publish()
    }

    private func closeAttemptResources() async {
        firstSnapshotTimeoutTask?.cancel()
        firstSnapshotTimeoutTask = nil
        for task in conversationCatchUpTasks.values {
            task.cancel()
        }
        conversationCatchUpTasks.removeAll()
        conversationCatchUpIDs.removeAll()
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
