#if DEBUG
import Foundation
import RemoteProtocol
import ToasttyMobileDomain

enum ToasttyPushFixtureMode: String, Equatable, Sendable {
    case intro, pending, error, enabled, denied, diagnostics
    case systemIntro = "system-intro"
    case turningOff = "turning-off"
    case missedProofs = "missed-proofs"
}

@MainActor
enum ToasttyPushFixtures {
    static func make(mode: ToasttyPushFixtureMode, credential: StoredMobileCredential,
                     vault: any AppSessionCredentialVault) -> ToasttyPushController {
        let config = ToasttyPushConfiguration(relayURL: URL(string: "https://fixture-push.example.com")!,
            relayID: "toastty-push-dev-v1", apnsEnvironment: .development)
        var state = MobilePushState()
        let introducesNotifications = mode == .intro || mode == .systemIntro
        // Disabled alert settings can precede push opt-in on a badge-only install.
        if !introducesNotifications {
            state.desired = mode != .turningOff && mode != .denied && mode != .diagnostics
        }
        state.introHandled = !introducesNotifications
        let registration = MobilePushRegistration(pairingID: credential.device.id, gatewayURL: credential.gatewayURL,
            relayURL: config.relayURL, relayID: config.relayID, deviceToken: String(repeating: "ab", count: 32),
            managementToken: String(repeating: "A", count: 43), sendToken: String(repeating: "A", count: 43),
            stage: mode == .enabled ? .enabled : mode == .pending || mode == .missedProofs ? .pending : .relayActive,
            expiresAt: Date().addingTimeInterval(300))
        if mode == .enabled { state.active = registration }
        if mode == .pending || mode == .error || mode == .missedProofs { state.pending = registration }
        if mode == .missedProofs { state.missedProofs = ToasttyPushController.missedProofsBeforeHint }
        if mode == .turningOff { state.cleanup = [registration] }
        // Only the clean-simulator badge test uses real system permissions.
        // Mac, relay, and APNs registration remain inactive fixtures.
        let notifications: any ToasttyPushNotificationClient = mode == .systemIntro
            ? ToasttySystemPushNotificationClient() : FixturePushNotifications(mode: mode)
        let controller = ToasttyPushController(configuration: config, vault: vault,
            store: FixturePushStateStore(state), notifications: notifications,
            installation: FixturePushInstallation(state.installationID),
            relayFactory: { _ in FixturePushRelay(mode: mode) },
            nativeFactory: { _, _ in FixtureNativePush(mode: mode, registrationID: registration.registrationID) },
            automaticallyReconciles: mode == .diagnostics)
        Task {
            _ = await vault.restore()
            await controller.restore()
            controller.updateConnection(gatewayURL: credential.gatewayURL, pairingID: credential.device.id,
                connected: true, supported: true)
            controller.receivedToken(registration.deviceToken)
            await controller.reconcile()
        }
        return controller
    }
}

private final class FixturePushStateStore: MobilePushStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: MobilePushState
    init(_ state: MobilePushState) { self.state = state }
    func load() -> MobilePushState? { lock.withLock { state } }
    func save(_ state: MobilePushState) { lock.withLock { self.state = state } }
}
@MainActor
private final class FixturePushInstallation: ToasttyPushInstallationIdentifying {
    var installationID: UUID?
    init(_ id: UUID) { installationID = id }
}
@MainActor
private final class FixturePushNotifications: ToasttyPushNotificationClient {
    private var mode: ToasttyPushFixtureMode
    init(mode: ToasttyPushFixtureMode) { self.mode = mode }
    func permission() async -> ToasttyNotificationPermission { mode == .intro ? .undetermined : mode == .denied ? .denied : .allowed }
    func requestPermission() async throws -> Bool { mode = .pending; return true }
    func register() {}
    func deliveredPayloads() async -> [RemotePushPayload] { [] }
    func removeVerificationNotifications(registrationIDs: Set<UUID>) async {}
}
private struct FixturePushRelay: PushRelayClientProtocol {
    let mode: ToasttyPushFixtureMode
    func begin(_ registration: MobilePushRegistration,
               onDiagnostic: @escaping @Sendable (PushRelayDiagnostic) -> Void) async throws -> PushRelayBeginResponse {
        if mode == .diagnostics {
            onDiagnostic(PushRelayDiagnostic(statusCode: 429, code: .verificationTokenLimit, rateLimitSource: .relay))
            throw PushRelayFailure.rateLimited(retryAfter: 120)
        }
        return try await begin(registration)
    }
    func begin(_ registration: MobilePushRegistration) async throws -> PushRelayBeginResponse {
        PushRelayBeginResponse(registrationID: registration.registrationID, state: "pending", expiresAt: Date().addingTimeInterval(300).timeIntervalSince1970)
    }
    func complete(_ registration: MobilePushRegistration, nonce: String) async throws -> PushRelayStatus {
        PushRelayStatus(registrationID: registration.registrationID, pairingID: registration.pairingID, state: "active")
    }
    func status(_ registration: MobilePushRegistration) async throws -> PushRelayStatus {
        PushRelayStatus(registrationID: registration.registrationID, pairingID: registration.pairingID, state: "active")
    }
    func revoke(_ registration: MobilePushRegistration) async throws { throw PushRelayFailure.network }
}
private struct FixtureNativePush: NativePushClientProtocol {
    let mode: ToasttyPushFixtureMode
    let registrationID: UUID
    func configuration() async throws -> RemoteGatewayPushConfigurationResponse {
        RemoteGatewayPushConfigurationResponse(relayID: "toastty-push-dev-v1", apnsEnvironment: .development,
            registrationID: mode == .enabled ? registrationID : nil)
    }
    func setRegistration(_ registration: RemoteGatewayPushRegistration?) async throws -> RemoteGatewayPushRegistrationResponse {
        if mode == .error || mode == .pending { throw PushRelayFailure.network }
        return RemoteGatewayPushRegistrationResponse(registrationID: registration?.registrationID)
    }
}
#endif
