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
}

private actor LiveRuntimeSpy: LiveConnectionRuntime {
    private var connectionRequests = 0
    private var suspended = false

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
    }

    func suspend() {
        suspended = true
    }

    func didSuspend() -> Bool { suspended }
    func connectCount() -> Int { connectionRequests }
}
