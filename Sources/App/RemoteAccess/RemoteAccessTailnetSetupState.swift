import Foundation

/// Serve configuration is separate from the loopback listener and does not
/// prove that a phone can reach this Mac through its tailnet.
enum RemoteAccessTailnetSetupState: Equatable, Sendable {
    case unchecked
    case waitingForListener
    case checking
    case configuring
    case configured
    case failed(TailscaleServeSetupError)

    var isInProgress: Bool {
        switch self {
        case .waitingForListener, .checking, .configuring:
            true
        case .unchecked, .configured, .failed:
            false
        }
    }

    /// A manual setup remains usable when Toastty cannot inspect Tailscale.
    /// A verified conflict or missing mapping must be resolved before pairing.
    var permitsPairing: Bool {
        switch self {
        case .unchecked, .configured:
            true
        case .waitingForListener, .checking, .configuring:
            false
        case .failed(let error):
            switch error {
            case .detection, .statusUnavailable:
                true
            case .originMismatch, .portInUse, .funnelEnabled, .notConfigured,
                 .approvalRequired, .identityChanged, .configurationFailed, .timedOut, .noAvailableHTTPSPort:
                false
            }
        }
    }

    var approvalURL: URL? {
        guard case .failed(let error) = self else { return nil }
        return error.approvalURL
    }

    var failureMessage: String? {
        guard case .failed(let error) = self else { return nil }
        return error.recoveryMessage
    }
}
