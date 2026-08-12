import RemoteProtocol
import SwiftUI
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class PairingControllerTests: XCTestCase {
    func testManualEntryParsesOfflineAndDoesNotContactGatewayUntilConfirmation() async throws {
        let client = RecordingPairingClient(result: .success(Self.exchangeResponse))
        let vault = FixtureAppCredentialVault()
        var pairedCredential: StoredMobileCredential?
        let controller = makeController(client: client, vault: vault) {
            pairedCredential = $0
        }

        controller.showManualEntry()
        controller.manualGateway = "EXAMPLE-MAC.TAILNET.TS.NET"
        controller.manualCode = "2345-6789-ABCD"
        controller.submitManualEntry()

        XCTAssertEqual(
            controller.state,
            .confirming(PairingConfirmation(
                hostname: "example-mac.tailnet.ts.net",
                method: .manualCode
            ))
        )
        let countBeforeConfirmation = await client.exchangeCount()
        XCTAssertEqual(countBeforeConfirmation, 0)

        controller.confirmAndExchange()
        await client.waitForExchange()
        await waitUntil { pairedCredential != nil }

        let countAfterConfirmation = await client.exchangeCount()
        let storedCredential = await vault.currentCredential()
        XCTAssertEqual(countAfterConfirmation, 1)
        XCTAssertNotNil(storedCredential)
    }

    func testUnsupportedAndDeniedCameraRemainManualCapableWithoutNetwork() async {
        let client = RecordingPairingClient(result: .success(Self.exchangeResponse))
        let vault = FixtureAppCredentialVault()
        let unsupported = makeController(
            client: client,
            vault: vault,
            scanner: TestPairingScanner(availability: .unsupported)
        )

        await unsupported.startScanning()
        XCTAssertEqual(unsupported.state, .scanning)
        XCTAssertEqual(unsupported.scannerAvailability, .unsupported)

        let denied = makeController(
            client: client,
            vault: vault,
            scanner: TestPairingScanner(authorization: .denied)
        )
        await denied.startScanning()
        XCTAssertEqual(denied.state, .scanning)
        XCTAssertEqual(denied.scannerAuthorization, .denied)
        let exchangeCount = await client.exchangeCount()
        XCTAssertEqual(exchangeCount, 0)
    }

    func testInactiveSceneClearsVisibleManualProofAndShowsPrivacyShield() async {
        let controller = makeController(
            client: RecordingPairingClient(result: .success(Self.exchangeResponse)),
            vault: FixtureAppCredentialVault()
        )
        controller.showManualEntry()
        controller.manualGateway = "example-mac.tailnet.ts.net"
        controller.manualCode = "2345-6789-ABCD"

        controller.sceneBecameInactive()

        XCTAssertTrue(controller.isPrivacyShielded)
        XCTAssertEqual(controller.manualGateway, "")
        XCTAssertEqual(controller.manualCode, "")
        XCTAssertEqual(controller.state, .intro)
        controller.sceneBecameActive()
        XCTAssertFalse(controller.isPrivacyShielded)
    }

    func testClassifiesIdentityAndNetworkFailuresIntoAppCopy() async {
        let cases: [(NativeGatewayFailure, PairingFailurePresentation)] = [
            (.pairingRejected(.invalidOrExpiredOffer), .expiredOrUsedOffer),
            (.rateLimited(operation: .pairingExchange), .tooManyAttempts),
            (.unauthenticated(operation: .pairingExchange, reason: .identityMismatch), .identityMismatch),
            (.network(operation: .pairingExchange, reason: .offline), .tailscaleUnavailable),
            (.network(operation: .pairingExchange, reason: .dns), .tlsOrHostname),
            (.network(operation: .pairingExchange, reason: .timedOut), .hostUnreachable),
            (.protocolMismatch(version: "2.0"), .protocolMismatch),
        ]

        for (failure, expected) in cases {
            let client = RecordingPairingClient(result: .failure(failure))
            let controller = makeController(client: client, vault: FixtureAppCredentialVault())
            stageAndConfirmManual(controller)
            await client.waitForExchange()
            await waitUntil {
                if case .failure = controller.state { return true }
                return false
            }
            XCTAssertEqual(controller.state, .failure(expected))
        }
    }

    func testScannedExpiredAndUnsupportedQRUseDistinctOfflineFailures() throws {
        let controller = makeController(
            client: RecordingPairingClient(result: .success(Self.exchangeResponse)),
            vault: FixtureAppCredentialVault()
        )
        let expired = RemoteNativePairingQRPayload(
            gatewayURL: URL(string: "https://example-mac.tailnet.ts.net")!,
            offerID: UUID(uuidString: "D2000000-0000-0000-0000-000000000001")!,
            secret: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            expiresAt: Date(timeIntervalSince1970: 100)
        )

        controller.acceptScannedCode(
            try expired.encodedString(),
            now: Date(timeIntervalSince1970: 101)
        )
        XCTAssertEqual(controller.state, .failure(.expiredOrUsedOffer))

        controller.acceptScannedCode(try unsupportedQRString())
        XCTAssertEqual(controller.state, .failure(.protocolMismatch))
    }

    func testCredentialStoreFailureUsesStorageUnavailableCopy() async {
        let client = RecordingPairingClient(result: .success(Self.exchangeResponse))
        let vault = FailingInstallVault()
        let controller = PairingController(
            client: client,
            credentialVault: vault,
            scanner: TestPairingScanner(),
            deviceName: { "Test iPhone" },
            onPaired: { _ in XCTFail("Pairing must not complete when secure storage fails") }
        )
        stageAndConfirmManual(controller)
        await client.waitForExchange()
        await waitUntil {
            controller.state == .failure(.storageUnavailable)
        }
        XCTAssertEqual(controller.state, .failure(.storageUnavailable))
    }

    func testCancelDoesNotAbandonAnExchangeThatMayMintCredential() async throws {
        let responseGate = PairingResponseGate()
        let client = GatedPairingClient(gate: responseGate)
        let vault = FixtureAppCredentialVault()
        var pairedCredential: StoredMobileCredential?
        let controller = makeController(client: client, vault: vault) {
            pairedCredential = $0
        }
        stageAndConfirmManual(controller)
        await responseGate.waitUntilRequested()

        controller.cancel()
        XCTAssertEqual(controller.state, .exchanging(hostname: "example-mac.tailnet.ts.net"))

        await responseGate.succeed(with: Self.exchangeResponse)
        await waitUntil { pairedCredential != nil }
        let storedCredential = await vault.currentCredential()
        XCTAssertNotNil(storedCredential)
    }

    private func makeController(
        client: any NativePairingClientProtocol,
        vault: FixtureAppCredentialVault,
        scanner: any PairingCodeScanning = TestPairingScanner(),
        onPaired: @escaping @MainActor (StoredMobileCredential) -> Void = { _ in }
    ) -> PairingController {
        PairingController(
            client: client,
            credentialVault: vault,
            scanner: scanner,
            deviceName: { "Test iPhone" },
            onPaired: onPaired
        )
    }

    private func stageAndConfirmManual(_ controller: PairingController) {
        controller.showManualEntry()
        controller.manualGateway = "example-mac.tailnet.ts.net"
        controller.manualCode = "2345-6789-ABCD"
        controller.submitManualEntry()
        controller.confirmAndExchange()
    }

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

    private static let exchangeResponse = RemoteGatewayNativePairingExchangeResponse(
        device: RemoteGatewayDeviceSummary(
            id: UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!,
            name: "Test iPhone",
            scopes: [.read, .send]
        ),
        credentialCreatedAt: Date(timeIntervalSince1970: 1_786_406_400),
        credential: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    )

    private func unsupportedQRString() throws -> String {
        let fields = [
            "2",
            "https://example-mac.tailnet.ts.net",
            "D2000000-0000-0000-0000-000000000002",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "1786406500.0",
            RemoteGatewayProtocol.version,
        ]
        var encoded = try JSONEncoder().encode(fields).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        encoded.removeAll { $0 == "=" }
        return RemoteNativePairingQRPayload.encodedPrefix + encoded
    }
}

private actor RecordingPairingClient: NativePairingClientProtocol {
    let result: Result<RemoteGatewayNativePairingExchangeResponse, NativeGatewayFailure>
    private var count = 0
    private var waiter: CheckedContinuation<Void, Never>?

    init(result: Result<RemoteGatewayNativePairingExchangeResponse, NativeGatewayFailure>) {
        self.result = result
    }

    func exchangeConfirmed(
        candidate: PairingCandidate,
        deviceName: String
    ) async throws -> RemoteGatewayNativePairingExchangeResponse {
        count += 1
        waiter?.resume()
        waiter = nil
        return try result.get()
    }

    func exchangeCount() -> Int { count }

    func waitForExchange() async {
        if count > 0 { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor PairingResponseGate {
    private var response: Result<RemoteGatewayNativePairingExchangeResponse, Error>?
    private var responseWaiter: CheckedContinuation<RemoteGatewayNativePairingExchangeResponse, Error>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var requested = false

    func request() async throws -> RemoteGatewayNativePairingExchangeResponse {
        requested = true
        requestWaiter?.resume()
        requestWaiter = nil
        if let response { return try response.get() }
        return try await withCheckedThrowingContinuation { responseWaiter = $0 }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func succeed(with response: RemoteGatewayNativePairingExchangeResponse) {
        self.response = .success(response)
        responseWaiter?.resume(returning: response)
        responseWaiter = nil
    }
}

private struct GatedPairingClient: NativePairingClientProtocol {
    let gate: PairingResponseGate

    func exchangeConfirmed(
        candidate: PairingCandidate,
        deviceName: String
    ) async throws -> RemoteGatewayNativePairingExchangeResponse {
        try await gate.request()
    }
}

@MainActor
private final class TestPairingScanner: PairingCodeScanning {
    let availability: PairingScannerAvailability
    private let authorization: PairingScannerAuthorization

    init(
        availability: PairingScannerAvailability = .available,
        authorization: PairingScannerAuthorization = .authorized
    ) {
        self.availability = availability
        self.authorization = authorization
    }

    func requestAuthorization() async -> PairingScannerAuthorization { authorization }

    func makeScannerView(onCode: @escaping @MainActor (String) -> Void) -> AnyView {
        AnyView(EmptyView())
    }
}

private actor FailingInstallVault: AppSessionCredentialVault {
    private let backingVault = MobileCredentialVault(store: EmptyPairingCredentialStore())

    func restore() -> MobileCredentialLoadResult { .missing }
    func install(_ credential: StoredMobileCredential) throws -> MobileCredentialGeneration {
        throw MobileCredentialStoreFailure.keychainStatus(-1)
    }
    func currentCredential() async -> StoredMobileCredential? { nil }
    func currentGeneration() async -> MobileCredentialGeneration { await backingVault.currentGeneration() }
    func delete() {}
    func delete(ifCurrent generation: MobileCredentialGeneration) -> Bool { false }
    func credential() async throws -> GatewayCredential? { nil }
}

private struct EmptyPairingCredentialStore: MobileCredentialStoring {
    func load() -> MobileCredentialLoadResult { .missing }
    func save(_ credential: StoredMobileCredential) {}
    func delete() {}
}
