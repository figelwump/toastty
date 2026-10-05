import Combine
import CoreState
import Foundation
import RemoteProtocol
import ToasttyMobileDomain

/// What the sidebar shows beside a remote host's name.
enum RemoteHostConnectionStatus: Equatable, Sendable {
    case notPaired
    /// The keychain item exists but cannot be read now.
    case credentialUnavailable
    case connecting
    case live
    case reconnecting
    /// The host revoked or limited this Mac. Pairing again does not help.
    case accessDenied
    case incompatibleHost
    case failed
}

struct RemoteHostState: Identifiable, Equatable, Sendable {
    let configuration: RemoteHostConfiguration
    var status: RemoteHostConnectionStatus
    /// The host's last session list. It stays readable while reconnecting,
    /// but a terminal attaches only while `status` is `.live`.
    var snapshot: CompatibleSessionListSnapshot?
    var home: MobileHomeSnapshot?
    var supportsTerminalAttach: Bool

    var id: String { configuration.id }

    init(
        configuration: RemoteHostConfiguration,
        status: RemoteHostConnectionStatus,
        snapshot: CompatibleSessionListSnapshot? = nil,
        supportsTerminalAttach: Bool = false
    ) {
        self.configuration = configuration
        self.status = status
        self.snapshot = snapshot
        self.home = snapshot?.presentation(hostName: configuration.displayName)
        self.supportsTerminalAttach = supportsTerminalAttach
    }
}

enum RemoteHostPairingError: LocalizedError, Equatable {
    case unknownRemote
    case invalidCode
    case expiredCode
    case gatewayMismatch(expectedHost: String)
    case rejected
    case deviceLimitReached
    case hostUnreachable
    /// The address answered, but not as Toastty's gateway: for example a
    /// Tailscale Serve mapping that forwards to another port.
    case gatewayNotServing(statusCode: Int?)
    case identityUnavailable
    case hostTooOld
    case keychain
    /// A later pair, unpair, reconnect, or configuration reload replaced
    /// this operation before it finished.
    case superseded
    case other

    var errorDescription: String? {
        switch self {
        case .unknownRemote:
            "This remote is no longer in remotes.toml."
        case .invalidCode:
            "Enter the fallback code or the pairing text exactly as the other Mac shows it."
        case .expiredCode:
            "That pairing offer has expired. Show a new one on the other Mac."
        case .gatewayMismatch(let expectedHost):
            "That pairing offer is for a different address than \(expectedHost)."
        case .rejected:
            "The other Mac did not accept the code. Show a new pairing offer and try again."
        case .deviceLimitReached:
            "The other Mac has reached its paired-device limit. Remove a device there first."
        case .hostUnreachable:
            "Toastty could not reach the other Mac. Check Tailscale and that Remote Access is enabled there."
        case .gatewayNotServing(let statusCode):
            "The address answered\(statusCode.map { " with HTTP \($0)" } ?? ""), but not as Toastty's Remote Access gateway. "
                + "On the other Mac, check that Remote Access is enabled and that Tailscale Serve forwards to it: "
                + "tailscale serve --bg http://127.0.0.1:42871"
        case .identityUnavailable:
            "The other Mac could not see this Mac's Tailscale identity. Connect through its Tailscale Serve address."
        case .hostTooOld:
            "The other Mac's Toastty does not support native pairing. Update it."
        case .keychain:
            "Toastty could not update the credential in the keychain."
        case .superseded:
            "Another change to this remote replaced this one. Try again."
        case .other:
            "Pairing failed."
        }
    }
}

/// Lists the sessions of each Mac in `remotes.toml`, as a client of that
/// Mac's Remote Access gateway. One connection per paired remote stays open
/// while Toastty runs.
@MainActor
final class RemoteHostsStore: ObservableObject {
    struct Dependencies {
        var loadConfigurations: () throws -> [RemoteHostConfiguration]
        var credentialStore: (RemoteHostConfiguration) -> any MobileCredentialStoring
        var makeCoordinator: @MainActor (
            _ gatewayURL: URL,
            _ credentialProvider: any GatewayCredentialProvider,
            _ scopes: [RemoteDeviceScope]
        ) -> ConnectionCoordinator
        var pairingClient: any NativePairingClientProtocol
        var revokeDevice: @Sendable (_ gatewayURL: URL, _ credentialProvider: any GatewayCredentialProvider) async -> Void
        var deviceName: () -> String

        static func live(
            homeDirectoryPath: String = NSHomeDirectory(),
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Dependencies {
            Dependencies(
                loadConfigurations: {
                    try RemoteHostsFile.load(homeDirectoryPath: homeDirectoryPath, environment: environment)
                },
                credentialStore: RemoteHostCredentialStore.keychain(for:),
                makeCoordinator: { gatewayURL, credentialProvider, scopes in
                    ConnectionCoordinator(
                        gateway: GatewayClient(baseURL: gatewayURL, credentialProvider: credentialProvider),
                        eventStream: EventStreamClient(baseURL: gatewayURL, credentialProvider: credentialProvider),
                        deviceScopes: scopes
                    )
                },
                pairingClient: NativePairingClient(),
                revokeDevice: { gatewayURL, credentialProvider in
                    _ = try? await NativeDeviceClient(
                        baseURL: gatewayURL,
                        credentialProvider: credentialProvider
                    ).revokeCurrentDevice()
                },
                deviceName: { RemoteHostsStore.localDeviceName() }
            )
        }
    }

    /// One configured remote's credential and connection.
    ///
    /// Pairing, unpairing, reconnecting, and a rejected credential each await
    /// the keychain or the network. Each one takes a new `epoch` when it
    /// starts and checks it after every wait, so an operation that a later
    /// one has replaced stops without changing state. A removed or changed
    /// table gets a new link, which retires the old one the same way.
    private final class Link {
        let configuration: RemoteHostConfiguration
        let vault: MobileCredentialVault
        var epoch = 0
        var coordinator: ConnectionCoordinator?
        /// The vault generation the current coordinator connected with. A
        /// rejection deletes only that credential, never a newer one.
        var credentialGeneration: MobileCredentialGeneration?
        var observationTasks: [Task<Void, Never>] = []

        init(configuration: RemoteHostConfiguration, vault: MobileCredentialVault) {
            self.configuration = configuration
            self.vault = vault
        }
    }

    @Published private(set) var hosts: [RemoteHostState] = []

    private let dependencies: Dependencies
    private var links: [String: Link] = [:]

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
    }

    func host(id: String) -> RemoteHostState? {
        hosts.first { $0.id == id }
    }

    /// Reads `remotes.toml` and makes the connections match it. A remote whose
    /// table is unchanged keeps its connection. A parse error changes nothing.
    @discardableResult
    func reload() -> Result<Void, RemoteHostsParseError> {
        let configurations: [RemoteHostConfiguration]
        do {
            configurations = try dependencies.loadConfigurations()
        } catch let error as RemoteHostsParseError {
            ToasttyLog.warning(
                "Failed to load remote hosts",
                category: .bootstrap,
                metadata: ["error": error.localizedDescription]
            )
            return .failure(error)
        } catch {
            ToasttyLog.warning(
                "Failed to read remote hosts file",
                category: .bootstrap,
                metadata: ["error": error.localizedDescription]
            )
            return .failure(RemoteHostsParseError(line: 0, message: error.localizedDescription))
        }

        let previousStates = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        for (id, link) in links where configurations.contains(link.configuration) == false {
            retire(link)
            links.removeValue(forKey: id)
        }
        var newLinks: [Link] = []
        hosts = configurations.map { configuration in
            if links[configuration.id] != nil, let previous = previousStates[configuration.id] {
                return previous
            }
            let link = Link(
                configuration: configuration,
                vault: MobileCredentialVault(store: dependencies.credentialStore(configuration))
            )
            links[configuration.id] = link
            newLinks.append(link)
            return RemoteHostState(configuration: configuration, status: .connecting)
        }
        for link in newLinks {
            let epoch = beginOperation(on: link)
            Task { await self.restoreCredentialAndConnect(link, epoch: epoch) }
        }
        return .success(())
    }

    /// Exchanges a pairing code from the other Mac for a credential, stores
    /// it, and connects. `input` is the short fallback code, or the pairing
    /// text behind the QR code.
    func pair(remoteID: String, input: String) async -> Result<Void, RemoteHostPairingError> {
        guard let link = links[remoteID] else { return .failure(.unknownRemote) }
        let configuration = link.configuration
        let candidate: PairingCandidate
        switch Self.pairingCandidate(input: input, configuration: configuration) {
        case .success(let value):
            candidate = value
        case .failure(let error):
            return .failure(error)
        }
        // A failed exchange must leave the current connection, and a
        // credential restore still in flight, as they are. So this only
        // notes the epoch here and starts its own operation after the host
        // has accepted the code.
        let startEpoch = link.epoch

        let response: RemoteGatewayNativePairingExchangeResponse
        do {
            response = try await dependencies.pairingClient.exchangeConfirmed(
                candidate: candidate,
                deviceName: dependencies.deviceName()
            )
        } catch let failure as NativeGatewayFailure {
            return .failure(Self.pairingError(for: failure))
        } catch {
            return .failure(.other)
        }
        // The table may have changed, or the user may have unpaired, while
        // the request was in flight. The credential belongs to the gateway
        // that issued it and to no other.
        guard isCurrent(link, epoch: startEpoch) else { return .failure(.superseded) }
        // The connection that used the old credential stops before the new
        // one is stored, so its late rejection cannot remove the new one.
        let epoch = beginOperation(on: link)
        disconnect(link)
        do {
            let credential = try StoredMobileCredential(
                gatewayURL: configuration.gatewayURL,
                exchangeResponse: response
            )
            let generation = try await link.vault.install(credential)
            guard isCurrent(link, epoch: epoch) else { return .failure(.superseded) }
            connect(link, credential: credential, generation: generation)
            return .success(())
        } catch {
            return .failure(.keychain)
        }
    }

    /// Asks the host to revoke this Mac, then removes the local credential.
    /// The local removal is tried even when the host cannot be reached. When
    /// the keychain refuses it, the remote stays in a state that offers
    /// unpairing again, because the credential would otherwise connect on
    /// the next launch.
    @discardableResult
    func unpair(remoteID: String) async -> Result<Void, RemoteHostPairingError> {
        guard let link = links[remoteID] else { return .failure(.unknownRemote) }
        let epoch = beginOperation(on: link)
        disconnect(link)
        update(link) { $0 = RemoteHostState(configuration: link.configuration, status: .connecting) }
        if await link.vault.currentCredential() != nil {
            await dependencies.revokeDevice(link.configuration.gatewayURL, link.vault)
        }
        guard isCurrent(link, epoch: epoch) else { return .failure(.superseded) }
        do {
            try await link.vault.delete()
        } catch {
            if isCurrent(link, epoch: epoch) {
                update(link) { $0.status = .credentialUnavailable }
            }
            return .failure(.keychain)
        }
        guard isCurrent(link, epoch: epoch) else { return .failure(.superseded) }
        update(link) { $0.status = .notPaired }
        return .success(())
    }

    /// Drops the current connection and starts a new one.
    func reconnect(remoteID: String) {
        guard let link = links[remoteID] else { return }
        let epoch = beginOperation(on: link)
        disconnect(link)
        update(link) { $0.status = .connecting }
        Task { await self.restoreCredentialAndConnect(link, epoch: epoch) }
    }

    // MARK: - Pairing input

    nonisolated static func pairingCandidate(
        input: String,
        configuration: RemoteHostConfiguration,
        now: Date = Date()
    ) -> Result<PairingCandidate, RemoteHostPairingError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parser = PairingInputParser()
        // A fallback code has no colon; the pairing text behind the QR code
        // starts with a `toastty-pairing:` scheme.
        if trimmed.contains(":") {
            do {
                let candidate = try parser.parseQRCode(trimmed, now: now)
                // The offer names its own gateway. Send the secret only to
                // the gateway this remote is configured for.
                guard candidate.gatewayURL == configuration.gatewayURL else {
                    return .failure(.gatewayMismatch(expectedHost: configuration.gatewayURL.host ?? ""))
                }
                return .success(candidate)
            } catch PairingInputError.expired {
                return .failure(.expiredCode)
            } catch {
                return .failure(.invalidCode)
            }
        }
        do {
            return .success(try parser.parseManual(
                gateway: configuration.gatewayURL.absoluteString,
                code: trimmed
            ))
        } catch {
            return .failure(.invalidCode)
        }
    }

    private static func pairingError(for failure: NativeGatewayFailure) -> RemoteHostPairingError {
        switch failure {
        case .pairingRejected(.deviceLimitReached):
            .deviceLimitReached
        case .pairingRejected, .rateLimited:
            .rejected
        case .network:
            .hostUnreachable
        case .unauthenticated(_, .identityUnavailable), .unauthenticated(_, .identityMismatch):
            .identityUnavailable
        case .capabilityUnavailable, .protocolMismatch:
            .hostTooOld
        case .server(_, let statusCode), .http(_, let statusCode):
            .gatewayNotServing(statusCode: statusCode)
        case .invalidResponse:
            .gatewayNotServing(statusCode: nil)
        case .unauthenticated, .authorizationDenied:
            .other
        }
    }

    nonisolated static func localDeviceName() -> String {
        let name = (Host.current().localizedName ?? "Mac")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(name.prefix(RemoteGatewayProtocol.maximumDeviceNameLength))
        return bounded.isEmpty ? "Mac" : bounded
    }

    // MARK: - Connection

    private func beginOperation(on link: Link) -> Int {
        link.epoch += 1
        return link.epoch
    }

    private func isCurrent(_ link: Link, epoch: Int) -> Bool {
        links[link.configuration.id] === link && link.epoch == epoch
    }

    private func restoreCredentialAndConnect(_ link: Link, epoch: Int) async {
        let result = await link.vault.restore()
        let generation = await link.vault.currentGeneration()
        guard isCurrent(link, epoch: epoch) else { return }
        switch result {
        case .available(let credential):
            // The keychain account already names the gateway host. This
            // check also covers an item that another build wrote.
            guard credential.gatewayURL == link.configuration.gatewayURL else {
                update(link) { $0.status = .notPaired }
                return
            }
            connect(link, credential: credential, generation: generation)
        case .missing, .corrupt, .incompatible:
            update(link) { $0.status = .notPaired }
        case .locked, .failed:
            update(link) { $0.status = .credentialUnavailable }
        }
    }

    private func connect(
        _ link: Link,
        credential: StoredMobileCredential,
        generation: MobileCredentialGeneration
    ) {
        disconnect(link)
        let coordinator = dependencies.makeCoordinator(
            link.configuration.gatewayURL,
            link.vault,
            credential.device.scopes
        )
        link.coordinator = coordinator
        link.credentialGeneration = generation
        update(link) { $0.status = .connecting }

        link.observationTasks = [
            Task { [weak self] in
                for await state in await coordinator.states() {
                    guard let self, link.coordinator === coordinator else { return }
                    await self.apply(state, to: link)
                }
            },
            Task { [weak self] in
                for await state in await coordinator.sessionProjection().states() {
                    guard let self, link.coordinator === coordinator else { return }
                    guard let snapshot = state.snapshot else { continue }
                    self.update(link) { host in
                        host.snapshot = snapshot
                        host.home = snapshot.presentation(hostName: link.configuration.displayName)
                    }
                }
            },
            Task { await coordinator.connectIfNeeded() },
        ]
    }

    private func apply(_ state: ConnectionCoordinator.State, to link: Link) async {
        let status: RemoteHostConnectionStatus
        switch state.phase {
        case .idle, .connecting, .awaitingFreshSessionSnapshot:
            status = .connecting
        case .live:
            status = .live
        case .reconnecting, .suspended:
            status = .reconnecting
        case .requiresAuthentication:
            // The host no longer accepts the credential. Remove that
            // credential, and no newer one, so the sidebar offers pairing.
            let rejectedGeneration = link.credentialGeneration
            let epoch = beginOperation(on: link)
            disconnect(link)
            if let rejectedGeneration {
                _ = try? await link.vault.delete(ifCurrent: rejectedGeneration)
            }
            guard isCurrent(link, epoch: epoch) else { return }
            update(link) { $0 = RemoteHostState(configuration: link.configuration, status: .notPaired) }
            return
        case .authorizationDenied:
            status = .accessDenied
        case .incompatibleProtocol:
            status = .incompatibleHost
        case .failed:
            status = .failed
        }
        update(link) { host in
            host.status = status
            host.supportsTerminalAttach = state.capabilities.contains(.terminalAttach)
        }
    }

    private func disconnect(_ link: Link) {
        for task in link.observationTasks { task.cancel() }
        link.observationTasks = []
        link.credentialGeneration = nil
        if let coordinator = link.coordinator {
            link.coordinator = nil
            Task { await coordinator.suspend() }
        }
    }

    private func retire(_ link: Link) {
        _ = beginOperation(on: link)
        disconnect(link)
    }

    private func update(_ link: Link, _ mutate: (inout RemoteHostState) -> Void) {
        guard links[link.configuration.id] === link,
              let index = hosts.firstIndex(where: { $0.id == link.configuration.id }) else { return }
        var host = hosts[index]
        mutate(&host)
        if host != hosts[index] {
            hosts[index] = host
        }
    }
}
