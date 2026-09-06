#if DEBUG
import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

enum PairingFixtureBehavior: Equatable, Sendable {
    case success
    case expiredOffer
}

actor FixtureAppCredentialVault: AppSessionCredentialVault {
    private let backingVault: MobileCredentialVault

    init(initialCredential: StoredMobileCredential? = nil) {
        let store = FixtureMobileCredentialStore(initialCredential: initialCredential)
        backingVault = MobileCredentialVault(store: store)
    }

    func restore() async -> MobileCredentialLoadResult {
        await backingVault.restore()
    }

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

private final class FixtureMobileCredentialStore: MobileCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: StoredMobileCredential?

    init(initialCredential: StoredMobileCredential?) {
        credential = initialCredential
    }

    func load() -> MobileCredentialLoadResult {
        lock.withLock { credential.map(MobileCredentialLoadResult.available) ?? .missing }
    }

    func save(_ credential: StoredMobileCredential) {
        lock.withLock { self.credential = credential }
    }

    func delete() {
        lock.withLock { credential = nil }
    }
}

struct FixturePairingClient: NativePairingClientProtocol {
    let behavior: PairingFixtureBehavior

    func exchangeConfirmed(
        candidate: PairingCandidate,
        deviceName: String
    ) async throws -> RemoteGatewayNativePairingExchangeResponse {
        switch behavior {
        case .success:
            return RemoteGatewayNativePairingExchangeResponse(
                device: RemoteGatewayDeviceSummary(
                    id: UUID(uuidString: "C1000000-0000-0000-0000-000000000001")!,
                    name: deviceName,
                    scopes: [.read, .send]
                ),
                credentialCreatedAt: Date(timeIntervalSince1970: 1_786_406_400),
                credential: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            )
        case .expiredOffer:
            throw NativeGatewayFailure.pairingRejected(.invalidOrExpiredOffer)
        }
    }
}

@MainActor
final class FixturePairingScanner: PairingCodeScanning {
    let availability: PairingScannerAvailability
    private let authorization: PairingScannerAuthorization
    private let failure: PairingScannerFailure?

    init(
        availability: PairingScannerAvailability = .available,
        authorization: PairingScannerAuthorization = .authorized,
        failure: PairingScannerFailure? = nil
    ) {
        self.availability = availability
        self.authorization = authorization
        self.failure = failure
    }

    func requestAuthorization() async -> PairingScannerAuthorization { authorization }

    func makeScannerView(
        onCode: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (PairingScannerFailure) -> Void
    ) -> AnyView {
        AnyView(
            VStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 56))
                Text("Fixture camera")
                    .font(.caption.monospaced())
                Button("Scan fixture QR") {
                    onCode(Self.validQRCode)
                }
                .buttonStyle(ToasttyPrimaryButtonStyle())
                .accessibilityIdentifier("toastty-mobile-pairing-fixture-scan")
            }
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ToasttyDesignTokens.raisedSurface)
            .task {
                if let failure = self.failure { onFailure(failure) }
            }
        )
    }

    private static let validQRCode: String = {
        let payload = RemoteNativePairingQRPayload(
            gatewayURL: URL(string: "https://fixture-mac.example.ts.net")!,
            offerID: UUID(uuidString: "C2000000-0000-0000-0000-000000000001")!,
            secret: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
        return try! payload.encodedString()
    }()
}
#endif
