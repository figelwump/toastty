import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class ConnectionCoordinatorTests: XCTestCase {
    func testRESTSeedAndSocketOpenStillRequireFreshStreamSnapshot() async throws {
        let operations = OperationLog()
        let seed = snapshot(runID: runID(1), title: "REST seed")
        let fresh = snapshot(runID: runID(1), title: "Fresh stream")
        let gateway = ScriptedGateway(
            operations: operations,
            hello: [.success(RemoteGatewayHelloResponse())],
            sessions: [.success(seed)]
        )
        let subscription = ScriptedSubscription()
        let stream = ScriptedEventStream(
            operations: operations,
            connections: [.success(subscription)]
        )
        let coordinator = ConnectionCoordinator(gateway: gateway, eventStream: stream)

        await coordinator.connectIfNeeded()
        try await withTimeout { try await subscription.waitForReceiveCount(1) }

        let operationValues = await operations.values()
        XCTAssertEqual(operationValues, ["hello", "sessions", "connect"])
        var connectionState = await coordinator.currentState()
        XCTAssertEqual(connectionState.phase, .awaitingFreshSessionSnapshot)
        let sessions = await coordinator.sessionProjection()
        var sessionsState = await sessions.currentState()
        XCTAssertEqual(sessionsState.phase, .awaitingFreshSnapshot)
        XCTAssertEqual(sessionsState.snapshot, seed)

        await subscription.send(.sessionList(fresh))
        connectionState = try await coordinatorState(matching: { $0.phase == .live }, coordinator)
        sessionsState = await sessions.currentState()
        XCTAssertEqual(connectionState.consecutiveFailureCount, 0)
        XCTAssertEqual(sessionsState.phase, .live)
        XCTAssertEqual(sessionsState.snapshot, fresh)

        await coordinator.suspend()
    }

    func testRetryBackoffAccumulatesUntilLiveAndShowsBannerAfterTwoFailures() async throws {
        let operations = OperationLog()
        let sleeper = ControlledSleeper()
        let gateway = ScriptedGateway(
            operations: operations,
            hello: [
                .failure(.network),
                .failure(.server(statusCode: 503, code: nil, message: nil)),
                .success(RemoteGatewayHelloResponse()),
            ],
            sessions: [.success(snapshot(runID: runID(1), title: "Seed"))]
        )
        let subscription = ScriptedSubscription()
        let stream = ScriptedEventStream(
            operations: operations,
            connections: [.success(subscription)]
        )
        let coordinator = ConnectionCoordinator(
            gateway: gateway,
            eventStream: stream,
            sleeper: sleeper,
            jitter: FixedJitter(value: 0.5)
        )

        await coordinator.connectIfNeeded()
        try await withTimeout { try await sleeper.waitForRequestCount(1) }
        var state = await coordinator.currentState()
        XCTAssertEqual(state.phase, .reconnecting(failureCount: 1, showsBanner: false))
        await sleeper.advance()

        try await withTimeout { try await sleeper.waitForRequestCount(2) }
        state = await coordinator.currentState()
        XCTAssertEqual(state.phase, .reconnecting(failureCount: 2, showsBanner: true))
        await sleeper.advance()

        try await withTimeout { try await subscription.waitForReceiveCount(1) }
        let retryDurations = await sleeper.requestedDurations()
        XCTAssertEqual(retryDurations, [.seconds(1), .seconds(2)])
        await subscription.send(.sessionList(snapshot(runID: runID(1), title: "Fresh")))
        state = try await coordinatorState(matching: { $0.phase == .live }, coordinator)
        XCTAssertEqual(state.connectionGeneration, 3)
        XCTAssertEqual(state.consecutiveFailureCount, 0)

        await coordinator.suspend()
    }

    func testAdmissionAndAuthorizationFailuresNeverSceneRetry() async throws {
        let cases: [(GatewayFailure, ConnectionCoordinatorPhase)] = [
            (.unauthenticated(code: .unauthorized, message: nil), .requiresAuthentication),
            (.authorizationDenied(code: .originDenied, message: nil), .authorizationDenied),
            (.protocolMismatch(version: "2.0"), .incompatibleProtocol(version: "2.0")),
        ]

        for (failure, expectedPhase) in cases {
            let operations = OperationLog()
            let gateway = ScriptedGateway(
                operations: operations,
                hello: [.failure(failure)]
            )
            let stream = ScriptedEventStream(operations: operations, connections: [])
            let sleeper = ControlledSleeper()
            let coordinator = ConnectionCoordinator(
                gateway: gateway,
                eventStream: stream,
                sleeper: sleeper,
                jitter: FixedJitter(value: 0.5)
            )

            await coordinator.connectIfNeeded()
            _ = try await coordinatorState(matching: { $0.phase == expectedPhase }, coordinator)
            var helloCallCount = await gateway.helloCallCount()
            var requestedDurations = await sleeper.requestedDurations()
            XCTAssertEqual(helloCallCount, 1)
            XCTAssertEqual(requestedDurations, [])

            await coordinator.resume()
            await coordinator.connectIfNeeded()
            helloCallCount = await gateway.helloCallCount()
            requestedDurations = await sleeper.requestedDurations()
            let finalState = await coordinator.currentState()
            XCTAssertEqual(helloCallCount, 1)
            XCTAssertEqual(requestedDurations, [])
            XCTAssertEqual(finalState.phase, expectedPhase)
        }
    }

    func testConversationCatchUpAuthFailureWinsOverSocketCloseError() async throws {
        let operations = OperationLog()
        let failure = GatewayFailure.unauthenticated(code: .unauthorized, message: nil)
        let gateway = ScriptedGateway(
            operations: operations,
            hello: [.success(RemoteGatewayHelloResponse())],
            sessions: [.success(snapshot(runID: runID(1), title: "Seed"))],
            events: [ScriptedCall(result: .failure(failure))]
        )
        let subscription = ScriptedSubscription(closeFailure: .network)
        let stream = ScriptedEventStream(
            operations: operations,
            connections: [.success(subscription)]
        )
        let sleeper = ControlledSleeper()
        let coordinator = ConnectionCoordinator(
            gateway: gateway,
            eventStream: stream,
            sleeper: sleeper
        )
        _ = await coordinator.openConversation(conversationID)

        await coordinator.connectIfNeeded()
        _ = try await coordinatorState(matching: { $0.phase == .requiresAuthentication }, coordinator)

        let retryDurations = await sleeper.requestedDurations()
        let subscriptionClosed = await subscription.isClosed()
        XCTAssertEqual(retryDurations, [])
        XCTAssertTrue(subscriptionClosed)
        await coordinator.resume()
        let helloCallCount = await gateway.helloCallCount()
        XCTAssertEqual(helloCallCount, 1)
    }

    func testConversationBuffersLivePageBeforeRESTAndResnapshotsFromNilCursor() async throws {
        let operations = OperationLog()
        let firstRESTGate = CancellationAwareGate()
        let firstRun = runID(1)
        let secondRun = runID(2)
        let gateway = ScriptedGateway(
            operations: operations,
            hello: [.success(RemoteGatewayHelloResponse())],
            sessions: [.success(snapshot(runID: firstRun, title: "Seed"))],
            events: [
                ScriptedCall(
                    result: .success(.page(
                        page(runID: firstRun, events: [event(1)], latestSequence: 1)
                    )),
                    gate: firstRESTGate
                ),
                ScriptedCall(
                    result: .success(.page(
                        page(runID: secondRun, events: [event(1)], latestSequence: 1)
                    ))
                ),
            ]
        )
        let subscription = ScriptedSubscription()
        let stream = ScriptedEventStream(
            operations: operations,
            connections: [.success(subscription)]
        )
        let coordinator = ConnectionCoordinator(gateway: gateway, eventStream: stream)
        let runtime = await coordinator.openConversation(conversationID)

        await coordinator.connectIfNeeded()
        try await withTimeout { try await gateway.waitForEventsCallCount(1) }
        try await withTimeout { try await subscription.waitForReceiveCount(1) }
        await subscription.send(.sessionList(snapshot(runID: firstRun, title: "Fresh")))
        await subscription.send(.conversationEvents(
            page(runID: firstRun, events: [event(2)], latestSequence: 2)
        ))
        await firstRESTGate.open()

        var runtimeState = try await conversationState(
            matching: { $0.phase == .live && $0.cursor?.afterSequence == 2 },
            runtime
        )
        XCTAssertEqual(runtimeState.events.map(\.sequence), [1, 2])
        var eventCursors = await gateway.recordedEventCursors()
        XCTAssertEqual(eventCursors, [nil])

        await subscription.send(.resnapshotRequired(conversationID: conversationID))
        try await withTimeout { try await gateway.waitForEventsCallCount(2) }
        runtimeState = try await conversationState(
            matching: { $0.phase == .live && $0.projectionRunID == secondRun },
            runtime
        )
        XCTAssertEqual(runtimeState.events.map(\.sequence), [1])
        eventCursors = await gateway.recordedEventCursors()
        XCTAssertEqual(eventCursors, [nil, nil])

        await coordinator.suspend()
    }

    func testSuspendClosesStreamAndKeepsReadableSessionSnapshot() async throws {
        let operations = OperationLog()
        let seed = snapshot(runID: runID(1), title: "Seed")
        let fresh = snapshot(runID: runID(1), title: "Fresh")
        let gateway = ScriptedGateway(
            operations: operations,
            hello: [.success(RemoteGatewayHelloResponse())],
            sessions: [.success(seed)]
        )
        let subscription = ScriptedSubscription()
        let stream = ScriptedEventStream(
            operations: operations,
            connections: [.success(subscription)]
        )
        let coordinator = ConnectionCoordinator(gateway: gateway, eventStream: stream)

        await coordinator.connectIfNeeded()
        try await withTimeout { try await subscription.waitForReceiveCount(1) }
        await subscription.send(.sessionList(fresh))
        _ = try await coordinatorState(matching: { $0.phase == .live }, coordinator)

        await coordinator.suspend()

        let subscriptionClosed = await subscription.isClosed()
        let coordinatorState = await coordinator.currentState()
        XCTAssertTrue(subscriptionClosed)
        XCTAssertEqual(coordinatorState.phase, .suspended)
        let sessions = await coordinator.sessionProjection()
        let sessionState = await sessions.currentState()
        XCTAssertEqual(sessionState.phase, .suspended)
        XCTAssertEqual(sessionState.snapshot, fresh)
    }

    func testClosingConversationWhileRESTIsInFlightDetachesItsRuntime() async throws {
        let operations = OperationLog()
        let restGate = CancellationAwareGate()
        let run = runID(1)
        let gateway = ScriptedGateway(
            operations: operations,
            hello: [.success(RemoteGatewayHelloResponse())],
            sessions: [.success(snapshot(runID: run, title: "Seed"))],
            events: [ScriptedCall(
                result: .success(.page(
                    page(runID: run, events: [event(1)], latestSequence: 1)
                )),
                gate: restGate
            ), ScriptedCall(result: .success(.page(
                page(runID: run, events: [event(1)], latestSequence: 1)
            )))]
        )
        let subscription = ScriptedSubscription()
        let stream = ScriptedEventStream(
            operations: operations,
            connections: [.success(subscription)]
        )
        let coordinator = ConnectionCoordinator(gateway: gateway, eventStream: stream)
        let retiredRuntime = await coordinator.openConversation(conversationID)

        await coordinator.connectIfNeeded()
        try await withTimeout { try await gateway.waitForEventsCallCount(1) }
        await coordinator.closeConversation(conversationID)
        await restGate.open()

        let detachedProjection = await coordinator.conversationProjection(for: conversationID)
        XCTAssertNil(detachedProjection)
        let retiredState = await retiredRuntime.currentState()
        XCTAssertEqual(retiredState.phase, .suspended)
        XCTAssertEqual(retiredState.events, [])

        let replacementRuntime = await coordinator.openConversation(conversationID)
        XCTAssertFalse(retiredRuntime === replacementRuntime)
        await coordinator.suspend()
    }

    func testCapableHostOpensAtTailThenLoadsOneOlderPageWithExclusiveCursor() async throws {
        let operations = OperationLog()
        let run = runID(1)
        let gateway = ScriptedGateway(
            operations: operations,
            hello: [.success(RemoteGatewayHelloResponse())],
            sessions: [.success(snapshot(runID: run, title: "Seed"))],
            events: [
                ScriptedCall(result: .success(.page(
                    page(runID: run, events: [event(7), event(8), event(9), event(10)], latestSequence: 10)
                ))),
                ScriptedCall(result: .success(.page(
                    page(runID: run, events: [event(4), event(5), event(6)], latestSequence: 10)
                ))),
            ]
        )
        let subscription = ScriptedSubscription()
        let coordinator = ConnectionCoordinator(
            gateway: gateway,
            eventStream: ScriptedEventStream(
                operations: operations,
                connections: [.success(subscription)]
            ),
            eventsPageLimit: 4
        )
        let runtime = await coordinator.openConversation(conversationID)

        await coordinator.connectIfNeeded()
        try await withTimeout { try await subscription.waitForReceiveCount(1) }
        await subscription.send(.sessionList(snapshot(runID: run, title: "Fresh")))
        _ = try await coordinatorState(matching: { $0.phase == .live }, coordinator)
        var runtimeState = try await conversationState(
            matching: { $0.phase == .live && $0.oldestObservedSequence == 7 },
            runtime
        )
        XCTAssertEqual(runtimeState.events.map(\.sequence), [7, 8, 9, 10])
        XCTAssertTrue(runtimeState.hasOlder)

        await coordinator.loadOlder(conversationID)
        runtimeState = try await conversationState(
            matching: { $0.oldestObservedSequence == 4 && !$0.isLoadingOlder },
            runtime
        )
        XCTAssertEqual(runtimeState.events.map(\.sequence), [4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(runtimeState.cursor?.afterSequence, 10)

        let requests = await gateway.recordedEventRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].backward, .latest)
        XCTAssertNil(requests[0].cursor)
        XCTAssertEqual(requests[0].limit, 4)
        guard case .before(let olderCursor) = requests[1].backward else {
            return XCTFail("Expected an explicit backward-before request")
        }
        XCTAssertEqual(olderCursor.beforeSequence, 7)
        XCTAssertEqual(olderCursor.projectionRunID, run)
        XCTAssertEqual(olderCursor.projectionGeneration, 4)

        await coordinator.suspend()
    }

    func testHostWithoutBackwardCapabilityFallsBackToForwardInitialCatchUp() async throws {
        let operations = OperationLog()
        let run = runID(1)
        let hello = RemoteGatewayHelloResponse(capabilities: [
            .browserCookiePairing,
            .nativeBearerPairing,
        ])
        let gateway = ScriptedGateway(
            operations: operations,
            hello: [.success(hello)],
            sessions: [.success(snapshot(runID: run, title: "Seed"))],
            events: [ScriptedCall(result: .success(.page(
                page(runID: run, events: [event(1), event(2)], latestSequence: 2)
            )))]
        )
        let subscription = ScriptedSubscription()
        let coordinator = ConnectionCoordinator(
            gateway: gateway,
            eventStream: ScriptedEventStream(
                operations: operations,
                connections: [.success(subscription)]
            )
        )
        let runtime = await coordinator.openConversation(conversationID)

        await coordinator.connectIfNeeded()
        try await withTimeout { try await subscription.waitForReceiveCount(1) }
        await subscription.send(.sessionList(snapshot(runID: run, title: "Fresh")))
        _ = try await coordinatorState(matching: { $0.phase == .live }, coordinator)
        let runtimeState = try await conversationState(
            matching: { $0.phase == .live && $0.cursor?.afterSequence == 2 },
            runtime
        )
        XCTAssertEqual(runtimeState.events.map(\.sequence), [1, 2])

        let requests = await gateway.recordedEventRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests[0].backward)
        XCTAssertNil(requests[0].cursor)

        await coordinator.suspend()
    }

    func testClosingConversationDuringOlderRESTIgnoresLateCompletion() async throws {
        let operations = OperationLog()
        let olderGate = CancellationAwareGate()
        let run = runID(1)
        let gateway = ScriptedGateway(
            operations: operations,
            hello: [.success(RemoteGatewayHelloResponse())],
            sessions: [.success(snapshot(runID: run, title: "Seed"))],
            events: [
                ScriptedCall(result: .success(.page(
                    page(runID: run, events: [event(7), event(8)], latestSequence: 8)
                ))),
                ScriptedCall(
                    result: .success(.page(
                        page(runID: run, events: [event(4), event(5), event(6)], latestSequence: 8)
                    )),
                    gate: olderGate
                ),
            ]
        )
        let subscription = ScriptedSubscription()
        let coordinator = ConnectionCoordinator(
            gateway: gateway,
            eventStream: ScriptedEventStream(
                operations: operations,
                connections: [.success(subscription)]
            )
        )
        let retiredRuntime = await coordinator.openConversation(conversationID)

        await coordinator.connectIfNeeded()
        try await withTimeout { try await subscription.waitForReceiveCount(1) }
        await subscription.send(.sessionList(snapshot(runID: run, title: "Fresh")))
        _ = try await coordinatorState(matching: { $0.phase == .live }, coordinator)
        _ = try await conversationState(
            matching: { $0.phase == .live && $0.oldestObservedSequence == 7 },
            retiredRuntime
        )

        await coordinator.loadOlder(conversationID)
        try await withTimeout { try await gateway.waitForEventsCallCount(2) }
        await coordinator.closeConversation(conversationID)
        await olderGate.open()

        let activeProjection = await coordinator.conversationProjection(for: conversationID)
        XCTAssertNil(activeProjection)
        let retiredState = await retiredRuntime.currentState()
        XCTAssertEqual(retiredState.phase, .suspended)
        XCTAssertEqual(retiredState.events.map(\.sequence), [7, 8])
        XCTAssertFalse(retiredState.isLoadingOlder)

        await coordinator.suspend()
    }

    func testUnknownOnlyOlderAutoContinuationStopsAtBoundedEightPages() async throws {
        let operations = OperationLog()
        let run = runID(1)
        let unknownPages = (0..<8).map { index -> ScriptedCall<CompatibleGatewayEventsResponse> in
            let upper = UInt64(39 - index * 3)
            let events = ((upper - 2)...upper).map { sequence in
                CompatibleConversationEvent.unknown(
                    conversationID: conversationID,
                    sequence: sequence,
                    kind: "future_optional_event"
                )
            }
            return ScriptedCall(result: .success(.page(
                page(runID: run, events: events, latestSequence: 41)
            )))
        }
        let gateway = ScriptedGateway(
            operations: operations,
            hello: [.success(RemoteGatewayHelloResponse())],
            sessions: [.success(snapshot(runID: run, title: "Seed"))],
            events: [ScriptedCall(result: .success(.page(
                page(runID: run, events: [event(40), event(41)], latestSequence: 41)
            )))] + unknownPages
        )
        let subscription = ScriptedSubscription()
        let coordinator = ConnectionCoordinator(
            gateway: gateway,
            eventStream: ScriptedEventStream(
                operations: operations,
                connections: [.success(subscription)]
            ),
            eventsPageLimit: 3
        )
        let runtime = await coordinator.openConversation(conversationID)

        await coordinator.connectIfNeeded()
        try await withTimeout { try await subscription.waitForReceiveCount(1) }
        await subscription.send(.sessionList(snapshot(runID: run, title: "Fresh")))
        _ = try await coordinatorState(matching: { $0.phase == .live }, coordinator)
        _ = try await conversationState(
            matching: { $0.phase == .live && $0.oldestObservedSequence == 40 },
            runtime
        )

        await coordinator.loadOlder(conversationID)
        try await withTimeout { try await gateway.waitForEventsCallCount(9) }
        let runtimeState = try await conversationState(
            matching: { $0.oldestObservedSequence == 16 && !$0.isLoadingOlder },
            runtime
        )
        XCTAssertEqual(runtimeState.events.map(\.sequence), [40, 41])
        XCTAssertTrue(runtimeState.hasOlder)
        let requests = await gateway.recordedEventRequests()
        XCTAssertEqual(requests.count, 9)

        await coordinator.suspend()
    }

    private func coordinatorState(
        matching predicate: @escaping @Sendable (ConnectionCoordinator.State) -> Bool,
        _ coordinator: ConnectionCoordinator
    ) async throws -> ConnectionCoordinator.State {
        try await withTimeout {
            let states = await coordinator.states()
            for await state in states where predicate(state) {
                return state
            }
            throw TestFailure.streamFinished
        }
    }

    private func conversationState(
        matching predicate: @escaping @Sendable (ConversationRuntime.State) -> Bool,
        _ runtime: ConversationRuntime
    ) async throws -> ConversationRuntime.State {
        try await withTimeout {
            let states = await runtime.states()
            for await state in states where predicate(state) {
                return state
            }
            throw TestFailure.streamFinished
        }
    }

    private func withTimeout<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await ContinuousClock().sleep(for: .seconds(3))
                throw TestFailure.timedOut
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func snapshot(
        runID: RemoteProjectionRunID,
        title: String
    ) -> CompatibleSessionListSnapshot {
        CompatibleSessionListSnapshot(
            projectionRunID: runID,
            conversations: [
                CompatibleConversationSummary(
                    conversationID: conversationID,
                    provider: .codex,
                    title: title,
                    placement: RemoteConversationPlacement(),
                    cwd: nil,
                    state: .ready,
                    inputAvailability: .unavailable(reason: .known(.working)),
                    projectionGeneration: 4,
                    latestSequence: 2,
                    updatedAt: Date(timeIntervalSince1970: 100)
                ),
            ],
            generatedAt: Date(timeIntervalSince1970: 101)
        )
    }

    private func page(
        runID: RemoteProjectionRunID,
        events: [CompatibleConversationEvent],
        latestSequence: UInt64
    ) -> CompatibleConversationEventPage {
        CompatibleConversationEventPage(
            conversationID: conversationID,
            projectionRunID: runID,
            projectionGeneration: 4,
            events: events,
            latestSequence: latestSequence,
            firstAvailableSequence: 1,
            historyTruncated: false
        )
    }

    private func event(_ sequence: UInt64) -> CompatibleConversationEvent {
        .known(ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "event-\(sequence)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            provider: .codex,
            payload: .assistantMessage(ConversationAssistantMessagePayload(
                text: "message \(sequence)",
                phase: .final
            ))
        ))
    }

    private func runID(_ suffix: UInt8) -> RemoteProjectionRunID {
        RemoteProjectionRunID(rawValue: UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix
        )))
    }

    private var conversationID: RemoteConversationID {
        RemoteConversationID(
            rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }
}

private struct ScriptedCall<Value: Sendable>: Sendable {
    var result: Result<Value, GatewayFailure>
    var gate: CancellationAwareGate?

    init(result: Result<Value, GatewayFailure>, gate: CancellationAwareGate? = nil) {
        self.result = result
        self.gate = gate
    }
}

private actor ScriptedGateway: GatewayClientProtocol {
    private let operations: OperationLog
    private var helloScripts: [ScriptedCall<RemoteGatewayHelloResponse>]
    private var sessionScripts: [ScriptedCall<CompatibleSessionListSnapshot>]
    private var eventScripts: [ScriptedCall<CompatibleGatewayEventsResponse>]
    private var eventCursors: [ConversationEventCursor?] = []
    private var eventRequests: [RemoteGatewayEventsRequest] = []
    private let eventCalls = CallCounter()
    private var helloCalls = 0

    init(
        operations: OperationLog,
        hello: [Result<RemoteGatewayHelloResponse, GatewayFailure>],
        sessions: [Result<CompatibleSessionListSnapshot, GatewayFailure>] = [],
        events: [ScriptedCall<CompatibleGatewayEventsResponse>] = []
    ) {
        self.operations = operations
        helloScripts = hello.map { ScriptedCall(result: $0) }
        sessionScripts = sessions.map { ScriptedCall(result: $0) }
        eventScripts = events
    }

    func hello() async throws -> RemoteGatewayHelloResponse {
        helloCalls += 1
        await operations.append("hello")
        return try await execute(helloScripts.removeFirst())
    }

    func pair(_ request: RemoteGatewayPairRequest) async throws -> RemoteGatewayPairResponse {
        throw GatewayFailure.invalidResponse
    }

    func sessions() async throws -> CompatibleSessionListSnapshot {
        await operations.append("sessions")
        return try await execute(sessionScripts.removeFirst())
    }

    func events(
        conversationID: RemoteConversationID,
        cursor: ConversationEventCursor?,
        limit: Int?
    ) async throws -> CompatibleGatewayEventsResponse {
        eventCursors.append(cursor)
        eventRequests.append(RemoteGatewayEventsRequest(
            conversationID: conversationID,
            cursor: cursor,
            limit: limit
        ))
        await eventCalls.increment()
        return try await execute(eventScripts.removeFirst())
    }

    func events(
        _ request: RemoteGatewayEventsRequest
    ) async throws -> CompatibleGatewayEventsResponse {
        eventCursors.append(request.cursor)
        eventRequests.append(request)
        await eventCalls.increment()
        return try await execute(eventScripts.removeFirst())
    }

    func send(_ request: RemoteMessageSendRequest) async throws -> RemoteMessageSendResult {
        throw GatewayFailure.invalidResponse
    }

    func helloCallCount() -> Int { helloCalls }
    func recordedEventCursors() -> [ConversationEventCursor?] { eventCursors }
    func recordedEventRequests() -> [RemoteGatewayEventsRequest] { eventRequests }
    func waitForEventsCallCount(_ count: Int) async throws { try await eventCalls.wait(for: count) }

    private func execute<Value>(_ script: ScriptedCall<Value>) async throws -> Value {
        if let gate = script.gate {
            try await gate.wait()
        }
        return try script.result.get()
    }
}

private actor ScriptedEventStream: EventStreamClientProtocol {
    private let operations: OperationLog
    private var connections: [Result<ScriptedSubscription, GatewayFailure>]

    init(
        operations: OperationLog,
        connections: [Result<ScriptedSubscription, GatewayFailure>]
    ) {
        self.operations = operations
        self.connections = connections
    }

    func connect() async throws -> any EventStreamSubscriptionProtocol {
        await operations.append("connect")
        return try connections.removeFirst().get()
    }
}

private actor ScriptedSubscription: EventStreamSubscriptionProtocol {
    private var queued: [Result<CompatibleGatewayStreamMessage, GatewayFailure>] = []
    private var waiters: [CheckedContinuation<CompatibleGatewayStreamMessage, any Error>] = []
    private var closed = false
    private let receiveCalls = CallCounter()
    private let closeFailure: GatewayFailure?

    init(closeFailure: GatewayFailure? = nil) {
        self.closeFailure = closeFailure
    }

    func nextMessage() async throws -> CompatibleGatewayStreamMessage {
        await receiveCalls.increment()
        if closed {
            if let closeFailure { throw closeFailure }
            throw CancellationError()
        }
        if queued.isEmpty == false { return try queued.removeFirst().get() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() {
        guard closed == false else { return }
        closed = true
        let activeWaiters = waiters
        waiters.removeAll()
        if let closeFailure {
            activeWaiters.forEach { $0.resume(throwing: closeFailure) }
        } else {
            activeWaiters.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    func send(_ message: CompatibleGatewayStreamMessage) {
        guard closed == false else { return }
        if waiters.isEmpty {
            queued.append(.success(message))
        } else {
            waiters.removeFirst().resume(returning: message)
        }
    }

    func waitForReceiveCount(_ count: Int) async throws { try await receiveCalls.wait(for: count) }
    func isClosed() -> Bool { closed }
}

private actor ControlledSleeper: ConnectionSleeping {
    private var durations: [Duration] = []
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private let requests = CallCounter()

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        await requests.increment()
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiterOrder.append(id)
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance() {
        while waiterOrder.isEmpty == false {
            let id = waiterOrder.removeFirst()
            if let continuation = waiters.removeValue(forKey: id) {
                continuation.resume()
                return
            }
        }
    }

    func waitForRequestCount(_ count: Int) async throws { try await requests.wait(for: count) }
    func requestedDurations() -> [Duration] { durations }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private struct FixedJitter: ConnectionJitterProviding {
    let value: Double
    func sample() async -> Double { value }
}

private actor OperationLog {
    private var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
    func values() -> [String] { entries }
}

private actor CallCounter {
    private var count = 0
    private var waiters: [UUID: (target: Int, continuation: CheckedContinuation<Void, any Error>)] = [:]

    func increment() {
        count += 1
        let readyIDs = waiters.compactMap { id, waiter in
            count >= waiter.target ? id : nil
        }
        for id in readyIDs {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    func wait(for target: Int) async throws {
        guard count < target else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if count >= target {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = (target, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private actor CancellationAwareGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func open() {
        guard isOpen == false else { return }
        isOpen = true
        let activeWaiters = waiters.values
        waiters.removeAll()
        activeWaiters.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private enum TestFailure: Error {
    case streamFinished
    case timedOut
}
