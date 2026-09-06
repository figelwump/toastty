import Foundation
import Observation
import SwiftUI
import ToasttyMobileDomain

@MainActor
@Observable
final class PairingController {
    private(set) var state: PairingState = .intro
    private(set) var scannerAuthorization: PairingScannerAuthorization?
    private(set) var scannerFailure: PairingScannerFailure?
    private(set) var isPrivacyShielded = false
    var manualGateway = ""
    var manualCode = ""

    private let client: any NativePairingClientProtocol
    private let credentialVault: any AppSessionCredentialVault
    private let scanner: any PairingCodeScanning
    private let deviceName: @MainActor @Sendable () -> String
    private let onPaired: @MainActor (StoredMobileCredential) -> Void
    private var pendingCandidate: PairingCandidate?
    private var exchangeTask: Task<Void, Never>?
    private var scannerAttemptID: UUID?

    init(
        client: any NativePairingClientProtocol,
        credentialVault: any AppSessionCredentialVault,
        scanner: any PairingCodeScanning,
        deviceName: @escaping @MainActor @Sendable () -> String,
        onPaired: @escaping @MainActor (StoredMobileCredential) -> Void
    ) {
        self.client = client
        self.credentialVault = credentialVault
        self.scanner = scanner
        self.deviceName = deviceName
        self.onPaired = onPaired
    }

    var scannerAvailability: PairingScannerAvailability {
        scanner.availability
    }

    var isExchanging: Bool { exchangeTask != nil }

    func showIntro() {
        scannerAttemptID = nil
        clearProof()
        state = .intro
    }

    func startScanning() async {
        let attemptID = UUID()
        scannerAttemptID = attemptID
        scannerFailure = nil
        scannerAuthorization = nil
        clearProof()
        // Current availability includes camera permission. Only unsupported
        // hardware skips authorization; denial needs its own recovery copy.
        guard scanner.availability != .unsupported else {
            state = .scanning
            return
        }
        let authorization = await scanner.requestAuthorization()
        guard scannerAttemptID == attemptID else { return }
        scannerAuthorization = authorization
        state = .scanning
    }

    func showManualEntry() {
        scannerAttemptID = nil
        clearProof()
        state = .manual
    }

    func scannerView() -> AnyView {
        let attemptID = scannerAttemptID
        return scanner.makeScannerView(
            onCode: { [weak self] value in
                guard let self, self.scannerAttemptID == attemptID,
                      self.state == .scanning else { return }
                self.acceptScannedCode(value)
            },
            onFailure: { [weak self] failure in
                guard let self, self.scannerAttemptID == attemptID,
                      self.state == .scanning else { return }
                self.scannerFailure = failure
            }
        )
    }

    func acceptScannedCode(_ value: String, now: Date = Date()) {
        do {
            let candidate = try PairingInputParser().parseQRCode(value, now: now)
            stageConfirmation(candidate, method: .scannedCode)
        } catch PairingInputError.unsupportedVersion {
            clearProof()
            state = .failure(.protocolMismatch)
        } catch PairingInputError.expired {
            clearProof()
            state = .failure(.expiredOrUsedOffer)
        } catch {
            clearProof()
            state = .failure(.invalidPairingDetails)
        }
    }

    func submitManualEntry() {
        do {
            let candidate = try PairingInputParser().parseManual(
                gateway: manualGateway,
                code: manualCode
            )
            stageConfirmation(candidate, method: .manualCode)
        } catch {
            clearProof()
            state = .failure(.invalidPairingDetails)
        }
    }

    func confirmAndExchange() {
        guard let candidate = pendingCandidate,
              case .confirming(let confirmation) = state,
              exchangeTask == nil else { return }

        // The task owns the only remaining request proof. Observable fields
        // are cleared before any network work begins.
        pendingCandidate = nil
        manualGateway = ""
        manualCode = ""
        state = .exchanging(hostname: confirmation.hostname)

        let client = client
        let credentialVault = credentialVault
        let name = deviceName()
        exchangeTask = Task { [weak self] in
            do {
                let response = try await client.exchangeConfirmed(candidate: candidate, deviceName: name)
                let credential = try StoredMobileCredential(
                    gatewayURL: candidate.gatewayURL,
                    exchangeResponse: response
                )
                _ = try await credentialVault.install(credential)
                self?.exchangeTask = nil
                self?.clearProof()
                self?.onPaired(credential)
            } catch {
                self?.exchangeTask = nil
                self?.clearProof()
                self?.state = .failure(Self.presentation(for: error))
            }
        }
    }

    @discardableResult
    func cancel() -> Bool {
        // Once sent, the exchange must finish and persist any minted device
        // credential. Cancelling here could orphan an irrevocable credential
        // on the Mac while leaving the phone unpaired.
        guard exchangeTask == nil else { return false }
        scannerAttemptID = nil
        clearProof()
        state = .intro
        return true
    }

    func sceneBecameInactive() {
        isPrivacyShielded = true
        clearVisibleProofForInactiveScene()
    }

    func sceneBecameActive() {
        isPrivacyShielded = false
    }

    private func stageConfirmation(_ candidate: PairingCandidate, method: PairingConfirmation.Method) {
        pendingCandidate = candidate
        manualGateway = ""
        manualCode = ""
        state = .confirming(PairingConfirmation(
            hostname: candidate.gatewayURL.host ?? candidate.gatewayURL.absoluteString,
            method: method
        ))
    }

    private func clearVisibleProofForInactiveScene() {
        manualGateway = ""
        manualCode = ""
        switch state {
        case .exchanging:
            // The unstructured exchange task deliberately survives scene
            // changes and owns its immutable request value.
            break
        case .intro, .failure:
            clearProof()
        case .scanning, .manual, .confirming:
            scannerAttemptID = nil
            clearProof()
            state = .intro
        }
    }

    private func clearProof() {
        pendingCandidate = nil
        manualGateway = ""
        manualCode = ""
    }

    private static func presentation(for error: Error) -> PairingFailurePresentation {
        if error is MobileCredentialStoreFailure || error is StoredMobileCredentialError {
            return .storageUnavailable
        }
        if let failure = error as? NativeGatewayFailure {
            switch failure {
            case .network(_, let reason):
                switch reason {
                case .offline:
                    return .tailscaleUnavailable
                case .dns, .tls:
                    return .tlsOrHostname
                case .cannotConnect, .timedOut, .connectionLost:
                    return .hostUnreachable
                case .other:
                    return .unexpected
                }
            case .unauthenticated(_, let reason):
                switch reason {
                case .identityUnavailable, .identityMismatch:
                    return .identityMismatch
                case .credentialInvalid, .unknown:
                    return .expiredOrUsedOffer
                }
            case .authorizationDenied:
                return .identityMismatch
            case .pairingRejected:
                return .expiredOrUsedOffer
            case .rateLimited:
                return .tooManyAttempts
            case .capabilityUnavailable:
                return .protocolMismatch
            case .protocolMismatch:
                return .protocolMismatch
            case .server, .http, .invalidResponse:
                return .unexpected
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .secureConnectionFailed,
                 .cannotFindHost,
                 .dnsLookupFailed:
                return .tlsOrHostname
            case .notConnectedToInternet:
                return .tailscaleUnavailable
            case .cannotConnectToHost, .networkConnectionLost, .timedOut:
                return .hostUnreachable
            default:
                return .unexpected
            }
        }
        return .unexpected
    }
}
