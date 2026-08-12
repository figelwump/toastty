import Foundation
import Observation
import RemoteProtocol
import ToasttyMobileDomain

protocol AppSessionCredentialVault: GatewayCredentialProvider, Sendable {
    func restore() async -> MobileCredentialLoadResult
    func install(_ credential: StoredMobileCredential) async throws -> MobileCredentialGeneration
    func currentCredential() async -> StoredMobileCredential?
    func currentGeneration() async -> MobileCredentialGeneration
    func delete() async throws
    func delete(ifCurrent generation: MobileCredentialGeneration) async throws -> Bool
}

extension MobileCredentialVault: AppSessionCredentialVault {}

@MainActor
protocol AppLiveSessionsControlling: AnyObject {
    var projectionRunID: String? { get }
    var projectionGeneration: UInt64? { get }
    var activeConversationCursor: UInt64? { get }
    var activeConversationController: LiveConversationController? { get }
    func start() async
    func foreground() async
    func background() async
    func stopObserving()
}

extension LiveSessionsController: AppLiveSessionsControlling {}

extension AppLiveSessionsControlling {
    var activeConversationController: LiveConversationController? { nil }
}

typealias AppLiveSessionsFactory = @MainActor (
    StoredMobileCredential,
    any GatewayCredentialProvider,
    HomeScreenController,
    @escaping @MainActor (LiveConnectionTerminal) -> Void,
    @escaping @MainActor (LiveProjectionFreshness) -> Void
) -> any AppLiveSessionsControlling

@MainActor
@Observable
final class AppSessionController {
    private(set) var state: AppSessionState
    private(set) var pairedDevice: PairedDevicePresentation?
    private(set) var pairingController: PairingController?
    private(set) var liveController: (any AppLiveSessionsControlling)?
    let homeController: HomeScreenController

    private let runtimeMode: ToasttyMobileRuntimeMode
    private let usesFixtureHarness: Bool
    private let credentialVault: any AppSessionCredentialVault
    private let pairingClient: any NativePairingClientProtocol
    private let scanner: any PairingCodeScanning
    private let deviceName: @MainActor @Sendable () -> String
    private let liveSessionsFactory: AppLiveSessionsFactory
    private var hasRestored = false
    private var liveSessionID: UUID?

    var credentialProvider: any GatewayCredentialProvider { credentialVault }

    var currentDeviceSummary: RemoteGatewayDeviceSummary? {
        pairedDevice?.device
    }

    init(
        runtimeMode: ToasttyMobileRuntimeMode,
        usesFixtureHarness: Bool = false,
        credentialVault: any AppSessionCredentialVault,
        pairingClient: any NativePairingClientProtocol,
        scanner: any PairingCodeScanning,
        deviceName: @escaping @MainActor @Sendable () -> String,
        initialState: AppSessionState = .restoring,
        initialPairedDevice: PairedDevicePresentation? = nil,
        initialSnapshot: MobileHomeSnapshot,
        initialConnectionState: MobileConnectionState,
        liveSessionsFactory: @escaping AppLiveSessionsFactory = AppSessionController.makeLiveSessionsController
    ) {
        self.runtimeMode = runtimeMode
        self.usesFixtureHarness = usesFixtureHarness
        self.credentialVault = credentialVault
        self.pairingClient = pairingClient
        self.scanner = scanner
        self.deviceName = deviceName
        self.liveSessionsFactory = liveSessionsFactory
        state = initialState
        pairedDevice = initialPairedDevice
        homeController = HomeScreenController(
            runtimeMode: runtimeMode,
            snapshot: initialSnapshot,
            connectionState: initialConnectionState
        )
    }

    func restoreIfNeeded() async {
        guard !hasRestored else { return }
        hasRestored = true

        if usesFixtureHarness, state != .restoring {
            return
        }

        switch await credentialVault.restore() {
        case .missing:
            transitionToUnpaired()
        case .available(let credential):
            prepareProjection(for: credential)
            pairedDevice = PairedDevicePresentation(credential: credential)
            state = .paired(.reconnecting)
            await configureAndStartLive(for: credential)
        case .locked:
            state = .keychainLocked
        case .corrupt:
            state = .repairNeeded(.corrupt)
        case .incompatible(let storedVersion):
            state = .incompatible(.credentialSchema(storedVersion: storedVersion))
        case .failed:
            state = .repairNeeded(.unavailable)
        }
    }

    func retryRestoration() async {
        state = .restoring
        hasRestored = false
        await restoreIfNeeded()
    }

    func beginPairing() {
        let controller = PairingController(
            client: pairingClient,
            credentialVault: credentialVault,
            scanner: scanner,
            deviceName: deviceName,
            onPaired: { [weak self] credential in
                self?.prepareProjection(for: credential)
                self?.pairedDevice = PairedDevicePresentation(credential: credential)
                self?.pairingController = nil
                self?.state = .paired(.reconnecting)
                Task { @MainActor [weak self] in
                    await self?.configureAndStartLive(for: credential)
                }
            }
        )
        pairingController = controller
        state = .pairing
    }

    func cancelPairing() {
        guard pairingController?.cancel() != false else { return }
        pairingController = nil
        state = .unpaired
    }

    func applyLiveSnapshot(
        _ snapshot: MobileHomeSnapshot,
        connectionState: MobileConnectionState
    ) {
        guard state.isPaired else { return }
        let freshness: LiveProjectionFreshness = switch connectionState {
        case .live: .live
        case .reconnecting: .reconnecting
        case .offline: .unreachable
        }
        homeController.update(
            snapshot: snapshot,
            connectionState: connectionState,
            freshness: freshness
        )
        switch connectionState {
        case .live:
            state = .paired(.live)
        case .reconnecting:
            state = .paired(.reconnecting)
        case .offline:
            state = .paired(.unreachable)
        }
    }

    func markReconnecting() {
        guard state.isPaired else { return }
        homeController.connectionState = .reconnecting
        state = .paired(.reconnecting)
    }

    func markUnreachable() {
        guard state.isPaired else { return }
        homeController.connectionState = .offline
        state = .paired(.unreachable)
    }

    func markAuthorizationDenied() {
        guard state.isPaired else { return }
        state = .paired(.authorizationDenied)
    }

    /// A 401 is allowed to remove only the credential generation that made
    /// the failed request. A newer successful pairing must survive a stale
    /// callback from older network work.
    func handleUnauthorized(credentialGeneration: MobileCredentialGeneration) async {
        do {
            if try await credentialVault.delete(ifCurrent: credentialGeneration) {
                transitionToUnpaired()
            }
        } catch {
            state = .repairNeeded(.unavailable)
        }
    }

    func currentCredentialGeneration() async -> MobileCredentialGeneration {
        await credentialVault.currentGeneration()
    }

    /// Unpair first asks the Mac to revoke this device. The caller supplies
    /// that best-effort operation so Settings can own its live client without
    /// creating a dependency cycle here. Local removal always follows.
    func unpair(revoke: @escaping @Sendable () async -> Void) async {
        await revoke()
        do {
            try await credentialVault.delete()
            transitionToUnpaired()
        } catch {
            state = .repairNeeded(.unavailable)
        }
    }

    func unpairCurrentDevice() async {
        guard let pairedDevice else { return }
        let credentialProvider = credentialVault
        let shouldRevoke = !usesFixtureHarness
        await unpair {
            guard shouldRevoke else { return }
            let client = NativeDeviceClient(
                baseURL: pairedDevice.gatewayURL,
                credentialProvider: credentialProvider
            )
            _ = try? await client.revokeCurrentDevice()
        }
    }

    func refreshCurrentDevice() async {
        guard !usesFixtureHarness, let pairedDevice else { return }
        let generation = await credentialVault.currentGeneration()
        let client = NativeDeviceClient(
            baseURL: pairedDevice.gatewayURL,
            credentialProvider: credentialVault
        )
        do {
            let response = try await client.currentDevice()
            guard await credentialVault.currentGeneration() == generation else { return }
            self.pairedDevice = PairedDevicePresentation(
                gatewayURL: pairedDevice.gatewayURL,
                device: response.device,
                credentialCreatedAt: response.credentialCreatedAt
            )
        } catch let failure as NativeGatewayFailure {
            guard await credentialVault.currentGeneration() == generation else { return }
            switch failure {
            case .unauthenticated:
                await handleUnauthorized(credentialGeneration: generation)
            case .authorizationDenied:
                markAuthorizationDenied()
            case .protocolMismatch(let version):
                state = .incompatible(.gatewayProtocol(version: version ?? "unknown"))
            case .network, .server, .http, .invalidResponse, .pairingRejected,
                 .rateLimited, .capabilityUnavailable:
                break
            }
        } catch {
            // Settings retains the last securely stored device summary when a
            // refresh cannot complete. Connection state owns reachability UI.
        }
    }

    func sceneBecameInactive() {
        pairingController?.sceneBecameInactive()
        Task { await liveController?.background() }
    }

    func sceneBecameActive() {
        pairingController?.sceneBecameActive()
        Task { await liveController?.foreground() }
    }

    private func transitionToUnpaired() {
        liveController?.stopObserving()
        liveController = nil
        liveSessionID = nil
        pairedDevice = nil
        pairingController = nil
        homeController.dismissConversation()
        homeController.dismissRemovalMessage()
        homeController.update(
            snapshot: MobileHomeSnapshot(hostName: "Toastty Mac", workspaces: []),
            connectionState: .offline,
            freshness: .unreachable
        )
        state = .unpaired
    }

    private func configureAndStartLive(for credential: StoredMobileCredential) async {
        guard !usesFixtureHarness else { return }

        let generation = await credentialVault.currentGeneration()
        let sessionID = UUID()
        liveSessionID = sessionID
        let controller = liveSessionsFactory(
            credential,
            credentialVault,
            homeController,
            { [weak self] terminal in
                guard let self, self.liveSessionID == sessionID else { return }
                switch terminal {
                case .requiresAuthentication:
                    Task { await self.handleUnauthorized(credentialGeneration: generation) }
                case .authorizationDenied:
                    self.markAuthorizationDenied()
                case .incompatibleProtocol(let version):
                    self.state = .incompatible(.gatewayProtocol(version: version))
                }
            },
            { [weak self] freshness in
                guard let self, self.liveSessionID == sessionID, self.state.isPaired else { return }
                switch freshness {
                case .live:
                    self.state = .paired(.live)
                case .reconnecting:
                    self.state = .paired(.reconnecting)
                case .stale, .unreachable:
                    self.state = .paired(.unreachable)
                }
            }
        )
        liveController?.stopObserving()
        liveController = controller
        await controller.start()
    }

    private func prepareProjection(for credential: StoredMobileCredential) {
        guard !usesFixtureHarness else { return }
        homeController.dismissConversation()
        homeController.dismissRemovalMessage()
        homeController.update(
            snapshot: MobileHomeSnapshot(
                hostName: credential.gatewayURL.host ?? "Toastty Mac",
                workspaces: []
            ),
            connectionState: .reconnecting,
            freshness: .reconnecting
        )
    }

    static func makeLiveSessionsController(
        credential: StoredMobileCredential,
        credentialProvider: any GatewayCredentialProvider,
        homeController: HomeScreenController,
        onTerminal: @escaping @MainActor (LiveConnectionTerminal) -> Void,
        onFreshness: @escaping @MainActor (LiveProjectionFreshness) -> Void
    ) -> any AppLiveSessionsControlling {
        let coordinator = ConnectionCoordinator(
            gateway: GatewayClient(
                baseURL: credential.gatewayURL,
                credentialProvider: credentialProvider
            ),
            eventStream: EventStreamClient(
                baseURL: credential.gatewayURL,
                credentialProvider: credentialProvider
            )
        )
        return LiveSessionsController(
            coordinator: coordinator,
            hostName: credential.gatewayURL.host ?? "Toastty Mac",
            homeController: homeController,
            onTerminal: onTerminal,
            onFreshness: onFreshness
        )
    }
}
