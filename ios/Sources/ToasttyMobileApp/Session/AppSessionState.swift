import Foundation
import RemoteProtocol
import ToasttyMobileDomain

enum AppSessionState: Equatable {
    case restoring
    case unpaired
    case pairing
    case paired(PairedConnectionPresentation)
    case keychainLocked
    case repairNeeded(CredentialRepairPresentation)
    case incompatible(IncompatiblePresentation)
}

enum PairedConnectionPresentation: Equatable {
    /// Initial connect for this pairing session: nothing has been presented
    /// yet, so the app shows the unified loading screen instead of home.
    case connecting
    case live
    case reconnecting
    case unreachable
    case authorizationDenied
}

enum CredentialRepairPresentation: Equatable {
    case corrupt
    case unavailable
}

enum IncompatiblePresentation: Equatable {
    case credentialSchema(storedVersion: Int)
    case gatewayProtocol(version: String)
}

extension AppSessionState {
    var isPaired: Bool {
        if case .paired = self { return true }
        return false
    }
}

struct PairedDevicePresentation: Equatable, Sendable {
    var gatewayURL: URL
    var device: RemoteGatewayDeviceSummary
    var credentialCreatedAt: Date

    init(credential: StoredMobileCredential) {
        gatewayURL = credential.gatewayURL
        device = credential.device
        credentialCreatedAt = credential.credentialCreatedAt
    }

    init(
        gatewayURL: URL,
        device: RemoteGatewayDeviceSummary,
        credentialCreatedAt: Date
    ) {
        self.gatewayURL = gatewayURL
        self.device = device
        self.credentialCreatedAt = credentialCreatedAt
    }
}
