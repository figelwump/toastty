import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class AppSessionControllerTests: XCTestCase {
    func testAuthorizationDeniedRetainsCredentialAndPairedState() async throws {
        let credential = try Self.credential(deviceName: "Original iPhone")
        let vault = FixtureAppCredentialVault(initialCredential: credential)
        _ = await vault.restore()
        let controller = makeController(vault: vault, credential: credential)

        controller.markAuthorizationDenied()

        XCTAssertEqual(controller.state, .paired(.authorizationDenied))
        let retainedCredential = await vault.currentCredential()
        XCTAssertEqual(retainedCredential, credential)
    }

    func testUnpairAttemptsRevokeThenDeletesCredentialEvenWhenRevokeCannotComplete() async throws {
        let credential = try Self.credential(deviceName: "Original iPhone")
        let vault = FixtureAppCredentialVault(initialCredential: credential)
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
        let vault = FixtureAppCredentialVault(initialCredential: first)
        _ = await vault.restore()
        let staleGeneration = await vault.currentGeneration()
        _ = try await vault.install(replacement)
        let controller = makeController(vault: vault, credential: replacement)

        await controller.handleUnauthorized(credentialGeneration: staleGeneration)

        let retainedCredential = await vault.currentCredential()
        XCTAssertEqual(retainedCredential, replacement)
        XCTAssertTrue(controller.state.isPaired)
    }

    func testCurrentUnauthorizedCallbackDeletesCredentialAndReturnsToPairingGate() async throws {
        let credential = try Self.credential(deviceName: "Current iPhone")
        let vault = FixtureAppCredentialVault(initialCredential: credential)
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

    func testRestorationInstallsStoredDeviceScopesBeforeStartingLiveRuntime() async throws {
        let credential = try Self.credential(deviceName: "Scoped iPhone")
        let vault = FixtureAppCredentialVault(initialCredential: credential)
        var liveSpy: AppLiveSessionsSpy?
        let controller = AppSessionController(
            runtimeMode: .fixture,
            credentialVault: vault,
            pairingClient: FixturePairingClient(behavior: .success),
            scanner: FixturePairingScanner(),
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
        XCTAssertEqual(controller.state, .paired(.reconnecting))
    }

    func testRefreshLiveSessionsForwardsToLiveControllerOutsideFixtureHarness() async throws {
        let credential = try Self.credential(deviceName: "Refresh iPhone")
        let vault = FixtureAppCredentialVault(initialCredential: credential)
        var liveSpy: AppLiveSessionsSpy?
        let controller = AppSessionController(
            runtimeMode: .fixture,
            credentialVault: vault,
            pairingClient: FixturePairingClient(behavior: .success),
            scanner: FixturePairingScanner(),
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
        let vault = FixtureAppCredentialVault(initialCredential: credential)
        let liveSpy = AppLiveSessionsSpy()
        let controller = AppSessionController(
            runtimeMode: .fixture,
            usesFixtureHarness: true,
            credentialVault: vault,
            pairingClient: FixturePairingClient(behavior: .success),
            scanner: FixturePairingScanner(),
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
        let vault = FixtureAppCredentialVault()
        let controller = AppSessionController(
            runtimeMode: .fixture,
            usesFixtureHarness: true,
            credentialVault: vault,
            pairingClient: SessionGatedPairingClient(gate: gate),
            scanner: FixturePairingScanner(),
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

    private func makeController(
        vault: any AppSessionCredentialVault,
        credential: StoredMobileCredential? = nil
    ) -> AppSessionController {
        AppSessionController(
            runtimeMode: .fixture,
            usesFixtureHarness: true,
            credentialVault: vault,
            pairingClient: FixturePairingClient(behavior: .success),
            scanner: FixturePairingScanner(),
            deviceName: { "Test iPhone" },
            initialState: credential == nil ? .restoring : .paired(.live),
            initialPairedDevice: credential.map(PairedDevicePresentation.init),
            initialSnapshot: ToasttyMobileFixture.home,
            initialConnectionState: credential == nil ? .offline : .live
        )
    }

    private static func credential(
        deviceName: String,
        id: UUID = UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!
    ) throws -> StoredMobileCredential {
        try StoredMobileCredential(
            gatewayURL: URL(string: "https://test-mac.tailnet.ts.net")!,
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

    init(result: MobileCredentialLoadResult) {
        self.result = result
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
        try await backingVault.delete()
    }

    func delete(ifCurrent generation: MobileCredentialGeneration) async throws -> Bool {
        try await backingVault.delete(ifCurrent: generation)
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
