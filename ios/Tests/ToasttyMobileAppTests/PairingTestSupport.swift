import Foundation
import RemoteProtocol
import SwiftUI
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

// Unit tests own their doubles so Release app tests do not depend on the
// Debug-only interactive fixture harness compiled into the app.
actor TestAppCredentialVault: AppSessionCredentialVault {
    private let vault: MobileCredentialVault

    init(initialCredential: StoredMobileCredential? = nil) {
        vault = MobileCredentialVault(store: TestPairingCredentialStore(initialCredential))
    }

    func restore() async -> MobileCredentialLoadResult { await vault.restore() }
    func install(_ credential: StoredMobileCredential) async throws -> MobileCredentialGeneration {
        try await vault.install(credential)
    }
    func currentCredential() async -> StoredMobileCredential? { await vault.currentCredential() }
    func currentGeneration() async -> MobileCredentialGeneration { await vault.currentGeneration() }
    func delete() async throws { try await vault.delete() }
    func delete(ifCurrent generation: MobileCredentialGeneration) async throws -> Bool {
        try await vault.delete(ifCurrent: generation)
    }
    func credential() async throws -> GatewayCredential? { try await vault.credential() }
}

private final class TestPairingCredentialStore: MobileCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: StoredMobileCredential?

    init(_ credential: StoredMobileCredential?) { self.credential = credential }
    func load() -> MobileCredentialLoadResult {
        lock.withLock { credential.map(MobileCredentialLoadResult.available) ?? .missing }
    }
    func save(_ credential: StoredMobileCredential) { lock.withLock { self.credential = credential } }
    func delete() { lock.withLock { credential = nil } }
}

struct TestAppPairingClient: NativePairingClientProtocol {
    func exchangeConfirmed(
        candidate: PairingCandidate,
        deviceName: String
    ) async throws -> RemoteGatewayNativePairingExchangeResponse {
        RemoteGatewayNativePairingExchangeResponse(
            device: RemoteGatewayDeviceSummary(
                id: UUID(uuidString: "C1000000-0000-0000-0000-000000000001")!,
                name: deviceName,
                scopes: [.read, .send]
            ),
            credentialCreatedAt: Date(timeIntervalSince1970: 1_786_406_400),
            credential: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
    }
}

@MainActor
final class TestAppPairingScanner: PairingCodeScanning {
    let availability = PairingScannerAvailability.unsupported
    func requestAuthorization() async -> PairingScannerAuthorization { .denied }
    func makeScannerView(
        onCode: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (PairingScannerFailure) -> Void
    ) -> AnyView { AnyView(EmptyView()) }
}
