import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class LiveSessionsControllerTests: XCTestCase {
    func testLiveSnapshotReordersAndUpdatesCurrentPresentation() throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: MobileHomeSnapshot(hostName: "toastty.test.ts.net", workspaces: []),
            connectionState: .offline
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7,
            snapshot: snapshot(titles: ["Zulu", "Alpha"]),
            phase: .live
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 7,
            phase: .live
        ))

        XCTAssertEqual(home.freshness, .live)
        XCTAssertEqual(home.connectionState, .live)
        XCTAssertEqual(home.snapshot.workspaces.map(\.title), ["Alpha workspace", "Zulu workspace"])
        XCTAssertEqual(subject.projectionGeneration, 12)
        XCTAssertEqual(subject.projectionRunID, runID.rawValue.uuidString)

        let alpha = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)
        home.open(alpha)
        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 7,
            snapshot: snapshot(titles: ["Alpha updated", "Zulu"]),
            phase: .live
        ))
        XCTAssertEqual(home.selectedConversation?.title, "Alpha updated")
    }

    func testAwaitingFreshStreamSnapshotRetainsReadableDataAsStale() {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        subject.consumeSessionsState(SessionsRuntime.State(
            connectionGeneration: 8,
            snapshot: snapshot(titles: ["Readable"]),
            phase: .awaitingFreshSnapshot
        ))
        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            connectionGeneration: 8,
            phase: .awaitingFreshSessionSnapshot
        ))

        XCTAssertEqual(home.freshness, .stale)
        XCTAssertEqual(home.connectionState, .offline)
        XCTAssertEqual(home.snapshot.workspaces.first?.conversations.first?.title, "Readable")
    }

    func testTransportFailureClassificationReachesHomePresentation() {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        subject.consumeCoordinatorState(ConnectionCoordinator.State(
            phase: .reconnecting(failureCount: 2, showsBanner: true),
            consecutiveFailureCount: 2,
            latestTransportFailure: .dns
        ))

        XCTAssertEqual(home.latestTransportFailure, .dns)
        XCTAssertTrue(home.connectionNoticeMessage?.contains("couldn't find your Mac") == true)
    }

    func testAuthRevocationTransitionsWhileAuthorizationDenialRetainsPairedCallback() {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        var terminals: [LiveConnectionTerminal] = []
        var callbacks: [String] = []
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home,
            onTerminal: {
                terminals.append($0)
                callbacks.append("terminal")
            },
            onFreshness: { _ in callbacks.append("freshness") }
        )

        subject.consumeCoordinatorState(ConnectionCoordinator.State(phase: .authorizationDenied))
        XCTAssertEqual(callbacks, ["freshness", "terminal"])
        callbacks.removeAll()
        subject.consumeCoordinatorState(ConnectionCoordinator.State(phase: .requiresAuthentication))

        XCTAssertEqual(terminals, [.authorizationDenied, .requiresAuthentication])
        XCTAssertEqual(callbacks, ["freshness", "terminal"])
        XCTAssertEqual(home.freshness, .unreachable)
    }

    func testSceneLifecycleSuspendsAndForegroundRequestsConnection() async {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        await subject.background()
        let didSuspend = await runtime.didSuspend()
        XCTAssertTrue(didSuspend)
        XCTAssertEqual(home.freshness, .stale)

        await subject.foreground()
        let connectCount = await runtime.connectCount()
        XCTAssertEqual(connectCount, 1)
        subject.stopObserving()
    }

    func testRefreshRestartsLiveRuntime() async {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        await subject.refresh()

        let restartCount = await runtime.restartCount()
        XCTAssertEqual(restartCount, 1)
        subject.stopObserving()
    }

    func testDeviceScopeRefreshForwardsToDomainRuntime() async {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )

        await subject.updateDeviceScopes([.read, .approve])

        let scopes = await runtime.latestDeviceScopes()
        XCTAssertEqual(scopes, [.read, .approve])
    }

    func testActiveConversationSendAndReceiptDismissUseDomainRuntime() async throws {
        let runtime = LiveRuntimeSpy()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: snapshot(titles: ["Alpha"]).presentation(),
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        let conversation = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)
        await subject.openConversation(conversation.id)
        let controller = try XCTUnwrap(subject.activeConversationController)
        let epoch = RemoteInputEpoch(
            bindingID: UUID(uuidString: "CC000000-0000-0000-0000-000000000001")!,
            counter: 5
        )
        let stamp = ConversationComposerStamp(
            connectionGeneration: 7,
            streamSnapshotOrdinal: 2,
            projectionRunID: runID,
            projectionGeneration: 12,
            latestSequence: 4,
            inputEpoch: epoch
        )
        controller.stop()
        controller.consume(stateForComposer(
            conversationID: conversation.id,
            stamp: stamp,
            epoch: epoch
        ))

        let outcome = await controller.send("ship it")
        await controller.dismissSendReceipt("request-1")

        XCTAssertEqual(outcome, .enqueued(clientRequestID: "request-1"))
        let sends = await runtime.recordedSends()
        XCTAssertEqual(sends, [.init(
            conversationID: RemoteConversationID(rawValue: conversation.id),
            text: "ship it",
            stamp: stamp
        )])
        let dismissals = await runtime.recordedDismissals()
        XCTAssertEqual(dismissals, [.init(
            conversationID: RemoteConversationID(rawValue: conversation.id),
            clientRequestID: "request-1"
        )])
        subject.stopObserving()
    }

    func testSelectionOwnsOneConversationRuntimeAndDismissClosesIt() async throws {
        let runtime = LiveRuntimeSpy()
        await runtime.holdConversationOpens()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: snapshot(titles: ["Alpha"]).presentation(),
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        let conversation = try XCTUnwrap(home.snapshot.workspaces.first?.conversations.first)

        home.open(conversation)
        await runtime.waitForConversationOpenToStart(
            RemoteConversationID(rawValue: conversation.id)
        )
        var conversationOpenCount = await runtime.conversationOpenCount()
        XCTAssertEqual(conversationOpenCount, 1)

        let duplicateOpen = Task { @MainActor in
            await subject.openConversation(conversation.id)
        }
        await Task.yield()
        await runtime.releaseConversationOpens()
        await duplicateOpen.value

        XCTAssertEqual(subject.activeConversationController?.conversationID, conversation.id)
        conversationOpenCount = await runtime.conversationOpenCount()
        XCTAssertEqual(conversationOpenCount, 1)
        var activeConversationIDs = await runtime.activeConversationIDs()
        XCTAssertEqual(activeConversationIDs, Set([RemoteConversationID(rawValue: conversation.id)]))

        home.dismissConversation()
        await subject.closeConversation(conversation.id)

        XCTAssertNil(subject.activeConversationController)
        activeConversationIDs = await runtime.activeConversationIDs()
        XCTAssertEqual(activeConversationIDs, Set<RemoteConversationID>())
        let conversationCloseCount = await runtime.conversationCloseCount()
        XCTAssertEqual(conversationCloseCount, 1)
        subject.stopObserving()
    }

    func testNewestDifferentSelectionWinsWhilePreviousOpenIsInFlight() async throws {
        let runtime = LiveRuntimeSpy()
        await runtime.holdConversationOpens()
        let home = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: snapshot(titles: ["Alpha", "Zulu"]).presentation(),
            connectionState: .live
        )
        let subject = LiveSessionsController(
            runtime: runtime,
            hostName: "toastty.test.ts.net",
            homeController: home
        )
        let conversations = home.snapshot.workspaces.flatMap(\.conversations)
        let alpha = try XCTUnwrap(conversations.first { $0.title == "Alpha" })
        let zulu = try XCTUnwrap(conversations.first { $0.title == "Zulu" })
        let alphaID = RemoteConversationID(rawValue: alpha.id)
        let zuluID = RemoteConversationID(rawValue: zulu.id)

        home.open(alpha)
        await runtime.waitForConversationOpenToStart(alphaID)
        home.open(zulu)
        await runtime.waitForConversationOpenToStart(zuluID)

        await runtime.releaseConversationOpens()
        await subject.openConversation(zulu.id)
        await runtime.waitForConversationClose(alphaID)

        XCTAssertEqual(home.selectedConversationID, zulu.id)
        XCTAssertEqual(subject.activeConversationController?.conversationID, zulu.id)
        let activeConversationIDs = await runtime.activeConversationIDs()
        XCTAssertEqual(activeConversationIDs, Set([zuluID]))
        let closedConversationIDs = await runtime.closedConversationIDs()
        XCTAssertEqual(closedConversationIDs, [alphaID])

        home.dismissConversation()
        await subject.closeConversation(zulu.id)
        subject.stopObserving()
    }

    private var runID: RemoteProjectionRunID {
        RemoteProjectionRunID(
            rawValue: UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!
        )
    }

    private func snapshot(titles: [String]) -> CompatibleSessionListSnapshot {
        CompatibleSessionListSnapshot(
            projectionRunID: runID,
            conversations: titles.map { title in
                let stableTitle = title.replacingOccurrences(of: " updated", with: "")
                let isAlpha = stableTitle == "Alpha"
                return CompatibleConversationSummary(
                    conversationID: RemoteConversationID(rawValue: UUID(
                        uuidString: isAlpha
                            ? "BB000000-0000-0000-0000-000000000001"
                            : "BB000000-0000-0000-0000-000000000002"
                    )!),
                    provider: .codex,
                    title: title,
                    placement: RemoteConversationPlacement(
                        workspaceID: UUID(
                            uuidString: isAlpha
                                ? "AA000000-0000-0000-0000-000000000001"
                                : "AA000000-0000-0000-0000-000000000002"
                        ),
                        workspaceTitle: "\(stableTitle) workspace"
                    ),
                    cwd: "/redacted",
                    state: MobileSessionDisplayState.ready,
                    inputAvailability: .unavailable(reason: .known(.unknownProviderState)),
                    projectionGeneration: 12,
                    latestSequence: 4,
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            },
            generatedAt: Date(timeIntervalSince1970: 101)
        )
    }

    private func stateForComposer(
        conversationID: UUID,
        stamp: ConversationComposerStamp,
        epoch: RemoteInputEpoch
    ) -> ConversationRuntime.State {
        ConversationRuntime.State(
            conversationID: RemoteConversationID(rawValue: conversationID),
            connectionGeneration: stamp.connectionGeneration,
            projectionRunID: stamp.projectionRunID,
            projectionGeneration: stamp.projectionGeneration,
            latestSequence: stamp.latestSequence,
            phase: .live,
            composerAuthority: ConversationComposerAuthority(
                stamp: stamp,
                inputAvailability: .openPrompt(epoch: epoch)
            ),
            sendReconciliation: SendReconciliation()
        )
    }
}

private actor LiveRuntimeSpy: LiveConnectionRuntime {
    struct SendCall: Equatable {
        var conversationID: RemoteConversationID
        var text: String
        var stamp: ConversationComposerStamp
    }

    struct DismissCall: Equatable {
        var conversationID: RemoteConversationID
        var clientRequestID: String
    }

    private var connectionRequests = 0
    private var restartRequests = 0
    private var suspended = false
    private var conversationRuntimes: [RemoteConversationID: ConversationRuntime] = [:]
    private var shouldHoldConversationOpens = false
    private var conversationOpenContinuations: [CheckedContinuation<Void, Never>] = []
    private var startedConversationIDs: Set<RemoteConversationID> = []
    private var conversationOpenStartedContinuations:
        [RemoteConversationID: [CheckedContinuation<Void, Never>]] = [:]
    private var conversationCloseContinuations:
        [RemoteConversationID: [CheckedContinuation<Void, Never>]] = [:]
    private var conversationOpenRequests = 0
    private var conversationCloseRequests = 0
    private var closedConversations: [RemoteConversationID] = []
    private var deviceScopes: [RemoteDeviceScope] = []
    private var sends: [SendCall] = []
    private var dismissals: [DismissCall] = []

    func currentCoordinatorState() -> ConnectionCoordinator.State {
        ConnectionCoordinator.State()
    }

    func coordinatorStates() -> AsyncStream<ConnectionCoordinator.State> {
        AsyncStream { $0.finish() }
    }

    func sessionsStates() -> AsyncStream<SessionsRuntime.State> {
        AsyncStream { $0.finish() }
    }

    func connectIfNeeded() {
        connectionRequests += 1
    }

    func restart() {
        connectionRequests += 1
        restartRequests += 1
    }

    func suspend() {
        suspended = true
    }

    func restartCount() -> Int { restartRequests }

    func openConversation(_ conversationID: RemoteConversationID) async -> ConversationRuntime {
        conversationOpenRequests += 1
        startedConversationIDs.insert(conversationID)
        let startedContinuations = conversationOpenStartedContinuations.removeValue(
            forKey: conversationID
        ) ?? []
        startedContinuations.forEach { $0.resume() }
        if shouldHoldConversationOpens {
            await withCheckedContinuation { continuation in
                conversationOpenContinuations.append(continuation)
            }
        }
        if let runtime = conversationRuntimes[conversationID] {
            return runtime
        }
        let runtime = ConversationRuntime(conversationID: conversationID)
        conversationRuntimes[conversationID] = runtime
        return runtime
    }

    func closeConversation(_ conversationID: RemoteConversationID) async {
        conversationCloseRequests += 1
        closedConversations.append(conversationID)
        let closeContinuations = conversationCloseContinuations.removeValue(
            forKey: conversationID
        ) ?? []
        closeContinuations.forEach { $0.resume() }
        guard let runtime = conversationRuntimes.removeValue(forKey: conversationID) else {
            return
        }
        _ = await runtime.suspend(connectionGeneration: 1)
    }

    func loadOlder(_ conversationID: RemoteConversationID) {}

    func updateDeviceScopes(_ scopes: [RemoteDeviceScope]) {
        deviceScopes = scopes
    }

    func sendMessage(
        conversationID: RemoteConversationID,
        text: String,
        composerStamp: ConversationComposerStamp
    ) -> ConversationSendOutcome {
        sends.append(.init(
            conversationID: conversationID,
            text: text,
            stamp: composerStamp
        ))
        return .enqueued(clientRequestID: "request-1")
    }

    func dismissSendReceipt(
        conversationID: RemoteConversationID,
        clientRequestID: String
    ) {
        dismissals.append(.init(
            conversationID: conversationID,
            clientRequestID: clientRequestID
        ))
    }

    func activeConversationIDs() -> Set<RemoteConversationID> {
        Set(conversationRuntimes.keys)
    }

    func holdConversationOpens() {
        shouldHoldConversationOpens = true
    }

    func releaseConversationOpens() {
        shouldHoldConversationOpens = false
        let continuations = conversationOpenContinuations
        conversationOpenContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForConversationOpenToStart(_ conversationID: RemoteConversationID) async {
        guard startedConversationIDs.contains(conversationID) == false else { return }
        await withCheckedContinuation { continuation in
            conversationOpenStartedContinuations[conversationID, default: []].append(continuation)
        }
    }

    func waitForConversationClose(_ conversationID: RemoteConversationID) async {
        guard closedConversations.contains(conversationID) == false else { return }
        await withCheckedContinuation { continuation in
            conversationCloseContinuations[conversationID, default: []].append(continuation)
        }
    }

    func conversationOpenCount() -> Int { conversationOpenRequests }
    func conversationCloseCount() -> Int { conversationCloseRequests }
    func closedConversationIDs() -> [RemoteConversationID] { closedConversations }

    func didSuspend() -> Bool { suspended }
    func connectCount() -> Int { connectionRequests }
    func latestDeviceScopes() -> [RemoteDeviceScope] { deviceScopes }
    func recordedSends() -> [SendCall] { sends }
    func recordedDismissals() -> [DismissCall] { dismissals }
}
