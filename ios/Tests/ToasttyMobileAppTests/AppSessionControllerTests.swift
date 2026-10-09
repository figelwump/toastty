import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class AppSessionControllerTests: XCTestCase {
    func testAuthorizationDeniedRetainsCredentialAndPairedState() async throws {
        let credential = try Self.credential(deviceName: "Original iPhone")
        let vault = TestAppCredentialVault(initialCredential: credential)
        _ = await vault.restore()
        let controller = makeController(vault: vault, credential: credential)

        controller.markAuthorizationDenied()

        XCTAssertEqual(controller.state, .paired(.authorizationDenied))
        let retainedCredential = await vault.currentCredential()
        XCTAssertEqual(retainedCredential, credential)
    }

    func testUnpairAttemptsRevokeThenDeletesCredentialEvenWhenRevokeCannotComplete() async throws {
        let credential = try Self.credential(deviceName: "Original iPhone")
        let vault = TestAppCredentialVault(initialCredential: credential)
        _ = await vault.restore()
        let controller = makeController(vault: vault, credential: credential)
        let recorder = AttemptRecorder()

        await controller.unpair {
            await recorder.recordFailedAttempt()
        }

        let revokeAttempts = await recorder.attempts()
        let deletedCredential = await vault.currentCredential()
        XCTAssertEqual(revokeAttempts, 1)
        XCTAssertNil(deletedCredential)
        XCTAssertEqual(controller.state, .unpaired)
        XCTAssertNil(controller.pairedDevice)
    }

    func testStaleUnauthorizedCallbackCannotDeleteNewPairingGeneration() async throws {
        let first = try Self.credential(deviceName: "First iPhone")
        let replacement = try Self.credential(
            deviceName: "Replacement iPhone",
            id: UUID(uuidString: "D1000000-0000-0000-0000-000000000002")!
        )
        let vault = TestAppCredentialVault(initialCredential: first)
        _ = await vault.restore()
        let staleGeneration = await vault.currentGeneration()
        _ = try await vault.install(replacement)
        let controller = makeController(vault: vault, credential: replacement)

        await controller.handleUnauthorized(credentialGeneration: staleGeneration)

        let retainedCredential = await vault.currentCredential()
        XCTAssertEqual(retainedCredential, replacement)
        XCTAssertTrue(controller.state.isPaired)
    }

    func testUnpairCompletionCannotDeleteAPairingInstalledDuringRevoke() async throws {
        let first = try Self.credential(deviceName: "First iPhone")
        let replacement = try Self.credential(deviceName: "Replacement iPhone",
            id: UUID(uuidString: "D1000000-0000-0000-0000-000000000002")!)
        let vault = TestAppCredentialVault(initialCredential: first)
        _ = await vault.restore()
        let controller = makeController(vault: vault, credential: first)

        let unpaired = await controller.unpair {
            _ = try? await vault.install(replacement)
        }

        XCTAssertFalse(unpaired)
        let retainedCredential = await vault.currentCredential()
        XCTAssertEqual(retainedCredential, replacement)
        XCTAssertTrue(controller.state.isPaired)
    }

    func testCurrentUnauthorizedCallbackDeletesCredentialAndReturnsToPairingGate() async throws {
        let credential = try Self.credential(deviceName: "Current iPhone")
        let vault = TestAppCredentialVault(initialCredential: credential)
        _ = await vault.restore()
        let currentGeneration = await vault.currentGeneration()
        let controller = makeController(vault: vault, credential: credential)

        await controller.handleUnauthorized(credentialGeneration: currentGeneration)

        let deletedCredential = await vault.currentCredential()
        XCTAssertNil(deletedCredential)
        XCTAssertEqual(controller.state, .unpaired)
    }

    func testRestorationDistinguishesLockedAndCredentialSchemaMismatch() async {
        let lockedVault = ScriptedRestorationVault(result: .locked)
        let locked = makeController(vault: lockedVault)
        await locked.restoreIfNeeded()
        XCTAssertEqual(locked.state, .keychainLocked)

        let incompatibleVault = ScriptedRestorationVault(result: .incompatible(storedVersion: 7))
        let incompatible = makeController(vault: incompatibleVault)
        await incompatible.restoreIfNeeded()
        XCTAssertEqual(
            incompatible.state,
            .incompatible(.credentialSchema(storedVersion: 7))
        )
    }

    func testForgettingCorruptCredentialDeletesLocallyThenStartsPairing() async {
        let vault = ScriptedRestorationVault(result: .corrupt)
        let controller = makeController(vault: vault)
        await controller.restoreIfNeeded()
        XCTAssertEqual(controller.state, .repairNeeded(.corrupt))

        await controller.forgetCorruptPairing()

        let deletionCount = await vault.deletionCount
        XCTAssertEqual(deletionCount, 1)
        XCTAssertEqual(controller.state, .pairing)
        XCTAssertNotNil(controller.pairingController)
        XCTAssertNil(controller.pairedDevice)
    }

    func testCorruptRepairDoesNotDeleteCredentialInstalledAfterRepairScreenAppeared() async throws {
        let vault = ScriptedRestorationVault(result: .corrupt)
        let controller = makeController(vault: vault)
        await controller.restoreIfNeeded()
        let replacement = try Self.credential(deviceName: "Replacement")
        _ = try await vault.install(replacement)

        await controller.forgetCorruptPairing()

        let retainedCredential = await vault.currentCredential()
        let deletionCount = await vault.deletionCount
        XCTAssertEqual(retainedCredential, replacement)
        XCTAssertEqual(deletionCount, 0)
    }

    func testForgettingCorruptCredentialDoesNotStartPairingWhenDeletionFails() async {
        let vault = ScriptedRestorationVault(result: .corrupt, failsDeletion: true)
        let controller = makeController(vault: vault)
        await controller.restoreIfNeeded()

        await controller.forgetCorruptPairing()

        XCTAssertEqual(controller.state, .repairNeeded(.unavailable))
        XCTAssertNil(controller.pairingController)
    }

    func testForgetCorruptPairingCannotDeleteLockedMissingOrIncompatibleCredentials() async {
        let results: [MobileCredentialLoadResult] = [
            .locked, .missing, .incompatible(storedVersion: 7), .failed(.keychainStatus(-1)),
        ]
        for result in results {
            let vault = ScriptedRestorationVault(result: result)
            let controller = makeController(vault: vault)
            await controller.restoreIfNeeded()
            let originalState = controller.state

            await controller.forgetCorruptPairing()

            let deletionCount = await vault.deletionCount
            XCTAssertEqual(deletionCount, 0)
            XCTAssertEqual(controller.state, originalState)
        }
    }

    func testRestorationInstallsStoredDeviceScopesBeforeStartingLiveRuntime() async throws {
        let credential = try Self.credential(deviceName: "Scoped iPhone")
        let vault = TestAppCredentialVault(initialCredential: credential)
        var liveSpy: AppLiveSessionsSpy?
        let controller = AppSessionController(
            runtimeMode: .fixture,
            credentialVault: vault,
            pairingClient: TestAppPairingClient(),
            scanner: TestAppPairingScanner(),
            deviceName: { "Test iPhone" },
            initialSnapshot: ToasttyMobileFixture.home,
            initialConnectionState: .offline,
            liveSessionsFactory: { _, _, _, _, _ in
                let spy = AppLiveSessionsSpy()
                liveSpy = spy
                return spy
            }
        )

        await controller.restoreIfNeeded()

        let spy = try XCTUnwrap(liveSpy)
        XCTAssertEqual(spy.scopeUpdates, [[.read, .send]])
        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(controller.state, .paired(.connecting))
    }

    func testInitialConnectStaysOnLoadingUntilFirstLiveFreshness() async throws {
        let credential = try Self.credential(deviceName: "Loading iPhone")
        let vault = TestAppCredentialVault(initialCredential: credential)
        var onFreshness: (@MainActor (LiveProjectionFreshness) -> Void)?
        let controller = AppSessionController(
            runtimeMode: .fixture,
            credentialVault: vault,
            pairingClient: TestAppPairingClient(),
            scanner: TestAppPairingScanner(),
            deviceName: { "Test iPhone" },
            initialSnapshot: ToasttyMobileFixture.home,
            initialConnectionState: .offline,
            liveSessionsFactory: { _, _, _, _, freshness in
                onFreshness = freshness
                return AppLiveSessionsSpy()
            }
        )

        await controller.restoreIfNeeded()
        XCTAssertEqual(controller.state, .paired(.connecting))
        XCTAssertNil(controller.appIconBadgeCount)
        let freshness = try XCTUnwrap(onFreshness)

        freshness(.connecting)
        XCTAssertEqual(controller.state, .paired(.connecting))

        // Backgrounding mid-initial-connect reports stale; the loading screen
        // must survive it so foregrounding resumes seamlessly.
        freshness(.stale)
        XCTAssertEqual(controller.state, .paired(.connecting))
        XCTAssertNil(controller.appIconBadgeCount)

        freshness(.live)
        XCTAssertEqual(controller.state, .paired(.live))

        // After first live, the ordinary mapping applies again.
        freshness(.stale)
        XCTAssertEqual(controller.state, .paired(.unreachable))
    }

    func testRestorationReusesOldAndCustomPortGatewayAndBearerWithoutPairing() async throws {
        for gateway in ["https://test-mac.tailnet.ts.net", "https://test-mac.tailnet.ts.net:8443"] {
            let credential = try Self.credential(deviceName: "Stored iPhone", gateway: gateway)
            let vault = TestAppCredentialVault(initialCredential: credential)
            let pairing = RestorationPairingClient()
            var runtimeCredentials: [StoredMobileCredential] = []
            var runtimeProvider: (any GatewayCredentialProvider)?
            let controller = AppSessionController(
                runtimeMode: .fixture,
                credentialVault: vault,
                pairingClient: pairing,
                scanner: TestAppPairingScanner(),
                deviceName: { "Test iPhone" },
                initialSnapshot: ToasttyMobileFixture.home,
                initialConnectionState: .offline,
                liveSessionsFactory: { stored, provider, _, _, _ in
                    runtimeCredentials.append(stored)
                    runtimeProvider = provider
                    return AppLiveSessionsSpy()
                }
            )

            await controller.restoreIfNeeded()
            await controller.retryRestoration()

            XCTAssertEqual(controller.pairedDevice?.gatewayURL.absoluteString, gateway)
            XCTAssertEqual(runtimeCredentials, [credential, credential])
            let bearer = try await XCTUnwrap(runtimeProvider).credential()
            XCTAssertEqual(bearer, .bearer(token: credential.bearerToken))
            let exchangeCount = await pairing.exchangeCount
            XCTAssertEqual(exchangeCount, 0)
            XCTAssertNil(controller.pairingController)
        }
    }

    func testInitialConnectFallsThroughToHomeWhenFirstAttemptFails() async throws {
        let credential = try Self.credential(deviceName: "Failing iPhone")
        let vault = TestAppCredentialVault(initialCredential: credential)
        var onFreshness: (@MainActor (LiveProjectionFreshness) -> Void)?
        let controller = AppSessionController(
            runtimeMode: .fixture,
            credentialVault: vault,
            pairingClient: TestAppPairingClient(),
            scanner: TestAppPairingScanner(),
            deviceName: { "Test iPhone" },
            initialSnapshot: ToasttyMobileFixture.home,
            initialConnectionState: .offline,
            liveSessionsFactory: { _, _, _, _, freshness in
                onFreshness = freshness
                return AppLiveSessionsSpy()
            }
        )

        await controller.restoreIfNeeded()
        XCTAssertEqual(controller.state, .paired(.connecting))

        try XCTUnwrap(onFreshness)(.reconnecting)
        XCTAssertEqual(controller.state, .paired(.reconnecting))
    }

    func testInitialConnectTimeoutFallsThroughToUnreachable() async throws {
        let credential = try Self.credential(deviceName: "Hung iPhone")
        let vault = TestAppCredentialVault(initialCredential: credential)
        let controller = AppSessionController(
            runtimeMode: .fixture,
            credentialVault: vault,
            pairingClient: TestAppPairingClient(),
            scanner: TestAppPairingScanner(),
            deviceName: { "Test iPhone" },
            initialSnapshot: ToasttyMobileFixture.home,
            initialConnectionState: .offline,
            initialConnectTimeout: .milliseconds(1),
            liveSessionsFactory: { _, _, _, _, _ in AppLiveSessionsSpy() }
        )

        await controller.restoreIfNeeded()
        XCTAssertEqual(controller.state, .paired(.connecting))

        for _ in 0..<200 where controller.state == .paired(.connecting) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.state, .paired(.unreachable))
    }

    func testRefreshLiveSessionsForwardsToLiveControllerOutsideFixtureHarness() async throws {
        let credential = try Self.credential(deviceName: "Refresh iPhone")
        let vault = TestAppCredentialVault(initialCredential: credential)
        var liveSpy: AppLiveSessionsSpy?
        let controller = AppSessionController(
            runtimeMode: .fixture,
            credentialVault: vault,
            pairingClient: TestAppPairingClient(),
            scanner: TestAppPairingScanner(),
            deviceName: { "Test iPhone" },
            initialSnapshot: ToasttyMobileFixture.home,
            initialConnectionState: .offline,
            liveSessionsFactory: { _, _, _, _, _ in
                let spy = AppLiveSessionsSpy()
                liveSpy = spy
                return spy
            }
        )
        await controller.restoreIfNeeded()

        await controller.refreshLiveSessions()

        XCTAssertEqual(try XCTUnwrap(liveSpy).refreshCount, 1)
    }

    func testRefreshLiveSessionsIsHarmlessInFixtureHarness() async throws {
        let credential = try Self.credential(deviceName: "Fixture iPhone")
        let vault = TestAppCredentialVault(initialCredential: credential)
        let liveSpy = AppLiveSessionsSpy()
        let controller = AppSessionController(
            runtimeMode: .fixture,
            usesFixtureHarness: true,
            credentialVault: vault,
            pairingClient: TestAppPairingClient(),
            scanner: TestAppPairingScanner(),
            deviceName: { "Test iPhone" },
            initialState: .paired(.live),
            initialPairedDevice: PairedDevicePresentation(credential: credential),
            initialSnapshot: ToasttyMobileFixture.home,
            initialConnectionState: .live,
            liveSessionsFactory: { _, _, _, _, _ in liveSpy }
        )

        await controller.refreshLiveSessions()

        XCTAssertEqual(liveSpy.refreshCount, 0)
    }

    func testOuterCancelKeepsInFlightPairingControllerAliveUntilCredentialPersists() async throws {
        let gate = SessionPairingResponseGate()
        let vault = TestAppCredentialVault()
        let controller = AppSessionController(
            runtimeMode: .fixture,
            usesFixtureHarness: true,
            credentialVault: vault,
            pairingClient: SessionGatedPairingClient(gate: gate),
            scanner: TestAppPairingScanner(),
            deviceName: { "Test iPhone" },
            initialState: .unpaired,
            initialSnapshot: ToasttyMobileFixture.home,
            initialConnectionState: .offline
        )
        controller.beginPairing()
        let pairing = try XCTUnwrap(controller.pairingController)
        pairing.showManualEntry()
        pairing.manualGateway = "test-mac.tailnet.ts.net"
        pairing.manualCode = "2345-6789-ABCD"
        pairing.submitManualEntry()
        pairing.confirmAndExchange()
        await gate.waitUntilRequested()

        controller.cancelPairing()
        XCTAssertEqual(controller.state, .pairing)
        XCTAssertTrue(controller.pairingController === pairing)

        await gate.succeed(with: Self.exchangeResponse)
        await waitUntil { controller.state.isPaired }
        let installedCredential = await vault.currentCredential()
        XCTAssertNotNil(installedCredential)
    }

    func testBadgeCountsAttentionWithoutTreatingSelectionAsRead() throws {
        let credential = try Self.credential(deviceName: "Badge iPhone")
        let controller = makeController(vault: TestAppCredentialVault(initialCredential: credential), credential: credential)
        XCTAssertEqual(controller.appIconBadgeCount, 7)
        let ready = try XCTUnwrap(controller.homeController.snapshot.activitySessions.first { $0.state == .ready })
        controller.homeController.open(ready)
        XCTAssertEqual(controller.appIconBadgeCount, 7)

        // A fresh host snapshot removes read, resolved, or closed sessions
        // from attention. Opening the app alone did not clear the badge.
        controller.applyLiveSnapshot(
            MobileHomeSnapshot(hostName: "Mac", workspaces: []), connectionState: .live
        )
        XCTAssertEqual(controller.appIconBadgeCount, 0)
    }

    func testBadgeFollowsReadApprovalAndErrorStatusChanges() throws {
        let credential = try Self.credential(deviceName: "Badge iPhone")
        let controller = makeController(vault: TestAppCredentialVault(initialCredential: credential), credential: credential)
        let workspaceID = UUID()
        let conversationIDs = [UUID(), UUID(), UUID()]
        func snapshot(_ states: [MobileSessionStatus]) -> MobileHomeSnapshot {
            let sessions = zip(conversationIDs, states).map { id, state in
                MobileConversation(id: id, workspaceID: workspaceID, workspaceTitle: "Workspace",
                    cwd: nil, agent: .codex, title: "Session", state: state,
                    inputAvailability: .unavailable(reason: "Test session"), age: "now", lastActivity: "")
            }
            return MobileHomeSnapshot(hostName: "Mac", workspaces: [
                MobileWorkspace(id: workspaceID, title: "Workspace", conversations: sessions),
            ])
        }
        controller.applyLiveSnapshot(snapshot([.ready, .needsApproval, .error]), connectionState: .live)
        XCTAssertEqual(controller.appIconBadgeCount, 3)
        controller.applyLiveSnapshot(snapshot([.idle, .needsApproval, .error]), connectionState: .live)
        XCTAssertEqual(controller.appIconBadgeCount, 2, "Reading clears the completion")
        controller.applyLiveSnapshot(snapshot([.idle, .working, .error]), connectionState: .live)
        XCTAssertEqual(controller.appIconBadgeCount, 1, "An approved session resumes work")
        controller.applyLiveSnapshot(snapshot([.idle, .working, .idle]), connectionState: .live)
        XCTAssertEqual(controller.appIconBadgeCount, 0, "Resolving the error clears the remaining count")
    }

    func testBadgeDoesNotUseCachedDataEvenIfAppPresentationIsStillLive() throws {
        let credential = try Self.credential(deviceName: "Badge iPhone")
        let controller = makeController(vault: TestAppCredentialVault(initialCredential: credential), credential: credential)
        for freshness: LiveProjectionFreshness in [.connecting, .reconnecting, .stale, .unreachable] {
            controller.homeController.update(snapshot: ToasttyMobileFixture.home,
                connectionState: .offline, freshness: freshness)
            XCTAssertEqual(controller.state, .paired(.live))
            XCTAssertNil(controller.appIconBadgeCount)
        }
        controller.applyLiveSnapshot(ToasttyMobileFixture.home, connectionState: .live)
        XCTAssertEqual(controller.appIconBadgeCount, 7)
        controller.beginPairing()
        XCTAssertEqual(controller.appIconBadgeCount, 0)
    }

    func testBadgePreservesUnknownStateButClearsWhenPairingIsRemoved() async throws {
        let credential = try Self.credential(deviceName: "Badge iPhone")
        let vault = TestAppCredentialVault(initialCredential: credential)
        _ = await vault.restore()
        let controller = makeController(vault: vault, credential: credential)
        XCTAssertEqual(controller.appIconBadgeCount, 7)
        controller.markReconnecting()
        XCTAssertNil(controller.appIconBadgeCount)
        controller.markUnreachable()
        XCTAssertNil(controller.appIconBadgeCount)
        controller.applyLiveSnapshot(ToasttyMobileFixture.home, connectionState: .live)
        XCTAssertEqual(controller.appIconBadgeCount, 7)
        controller.markAuthorizationDenied()
        XCTAssertEqual(controller.appIconBadgeCount, 0)
        await controller.unpair(revoke: {})
        XCTAssertEqual(controller.appIconBadgeCount, 0)
    }

    func testBadgeDistinguishesRestorationFromMissingOrInvalidPairing() async {
        let cases: [(MobileCredentialLoadResult, Int?)] = [
            (.locked, nil), (.failed(.keychainStatus(-1)), nil),
            (.missing, 0), (.corrupt, 0), (.incompatible(storedVersion: 7), 0),
        ]
        for (result, expected) in cases {
            let controller = makeController(vault: ScriptedRestorationVault(result: result))
            XCTAssertNil(controller.appIconBadgeCount)
            await controller.restoreIfNeeded()
            XCTAssertEqual(controller.appIconBadgeCount, expected)
        }
    }

    private func makeController(
        vault: any AppSessionCredentialVault,
        credential: StoredMobileCredential? = nil
    ) -> AppSessionController {
        AppSessionController(
            runtimeMode: .fixture,
            usesFixtureHarness: true,
            credentialVault: vault,
            pairingClient: TestAppPairingClient(),
            scanner: TestAppPairingScanner(),
            deviceName: { "Test iPhone" },
            initialState: credential == nil ? .restoring : .paired(.live),
            initialPairedDevice: credential.map(PairedDevicePresentation.init),
            initialSnapshot: ToasttyMobileFixture.home,
            initialConnectionState: credential == nil ? .offline : .live
        )
    }

    private static func credential(
        deviceName: String,
        id: UUID = UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!,
        gateway: String = "https://test-mac.tailnet.ts.net"
    ) throws -> StoredMobileCredential {
        try StoredMobileCredential(
            gatewayURL: URL(string: gateway)!,
            device: RemoteGatewayDeviceSummary(
                id: id,
                name: deviceName,
                scopes: [.read, .send]
            ),
            credentialCreatedAt: Date(timeIntervalSince1970: 1_786_406_400),
            bearerToken: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
    }

    private static let exchangeResponse = RemoteGatewayNativePairingExchangeResponse(
        device: RemoteGatewayDeviceSummary(
            id: UUID(uuidString: "D1000000-0000-0000-0000-000000000004")!,
            name: "Test iPhone",
            scopes: [.read, .send]
        ),
        credentialCreatedAt: Date(timeIntervalSince1970: 1_786_406_400),
        credential: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    )

    private func waitUntil(
        attempts: Int = 100,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }
}

private actor AttemptRecorder {
    private var count = 0

    func recordFailedAttempt() {
        count += 1
    }

    func attempts() -> Int { count }
}

private actor RestorationPairingClient: NativePairingClientProtocol {
    private(set) var exchangeCount = 0

    func exchangeConfirmed(
        candidate: PairingCandidate,
        deviceName: String
    ) async throws -> RemoteGatewayNativePairingExchangeResponse {
        exchangeCount += 1
        throw GatewayFailure.invalidResponse
    }
}

@MainActor
private final class AppLiveSessionsSpy: AppLiveSessionsControlling {
    var projectionRunID: String?
    var projectionGeneration: UInt64?
    var activeConversationCursor: UInt64?
    var activeConversationController: LiveConversationController?
    private(set) var scopeUpdates: [[RemoteDeviceScope]] = []
    private(set) var startCount = 0
    private(set) var refreshCount = 0

    func start() async { startCount += 1 }
    func foreground() async {}
    func refresh() async { refreshCount += 1 }
    func background() async {}
    func updateDeviceScopes(_ scopes: [RemoteDeviceScope]) async {
        scopeUpdates.append(scopes)
    }
    func stopObserving() {}
}

private actor ScriptedRestorationVault: AppSessionCredentialVault {
    private let result: MobileCredentialLoadResult
    private let backingVault = MobileCredentialVault(store: EmptyCredentialStore())
    private let failsDeletion: Bool
    private(set) var deletionCount = 0

    init(result: MobileCredentialLoadResult, failsDeletion: Bool = false) {
        self.result = result
        self.failsDeletion = failsDeletion
    }

    func restore() async -> MobileCredentialLoadResult { result }

    func install(_ credential: StoredMobileCredential) async throws -> MobileCredentialGeneration {
        try await backingVault.install(credential)
    }

    func currentCredential() async -> StoredMobileCredential? {
        await backingVault.currentCredential()
    }

    func currentGeneration() async -> MobileCredentialGeneration {
        await backingVault.currentGeneration()
    }

    func delete() async throws {
        deletionCount += 1
        if failsDeletion { throw MobileCredentialStoreFailure.keychainStatus(-1) }
        try await backingVault.delete()
    }

    func delete(ifCurrent generation: MobileCredentialGeneration) async throws -> Bool {
        deletionCount += 1
        if failsDeletion { throw MobileCredentialStoreFailure.keychainStatus(-1) }
        return try await backingVault.delete(ifCurrent: generation)
    }

    func credential() async throws -> GatewayCredential? {
        try await backingVault.credential()
    }
}

private struct EmptyCredentialStore: MobileCredentialStoring {
    func load() -> MobileCredentialLoadResult { .missing }
    func save(_ credential: StoredMobileCredential) {}
    func delete() {}
}

private actor SessionPairingResponseGate {
    private var response: RemoteGatewayNativePairingExchangeResponse?
    private var responseWaiter: CheckedContinuation<RemoteGatewayNativePairingExchangeResponse, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var requested = false

    func request() async -> RemoteGatewayNativePairingExchangeResponse {
        requested = true
        requestWaiter?.resume()
        requestWaiter = nil
        if let response { return response }
        return await withCheckedContinuation { responseWaiter = $0 }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func succeed(with response: RemoteGatewayNativePairingExchangeResponse) {
        self.response = response
        responseWaiter?.resume(returning: response)
        responseWaiter = nil
    }
}

private struct SessionGatedPairingClient: NativePairingClientProtocol {
    let gate: SessionPairingResponseGate

    func exchangeConfirmed(
        candidate: PairingCandidate,
        deviceName: String
    ) async throws -> RemoteGatewayNativePairingExchangeResponse {
        await gate.request()
    }
}
