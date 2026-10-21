import CoreState
import Foundation

struct RemoteAccessConnectionStatusPresentation: Equatable {
    enum Indicator: Equatable {
        case off
        case progress
        case ready
        case failure
    }

    var indicator: Indicator
    var title: String
    var detail: String

    static func make(
        activationState: RemoteAccessActivationState,
        tailnetSetupState: RemoteAccessTailnetSetupState = .unchecked,
        connectedNativeClientCount: Int,
        hasPairedNativeDevice: Bool,
        hasUnrevokedDevice: Bool = true,
        hasPendingPairing: Bool = false,
        hasSavedOrigin: Bool = true
    ) -> Self {
        switch activationState {
        case .off:
            return Self(
                indicator: .off,
                title: "Remote Access is off",
                detail: "Phones cannot connect and all remote reads are stopped."
            )
        case .starting:
            return Self(
                indicator: .progress,
                title: "Starting Remote Access…",
                detail: "Preparing conversations before phones can connect."
            )
        case .failed(let message):
            return Self(
                indicator: .failure,
                title: "Local Remote Access could not start",
                detail: message
            )
        case .ready:
            switch tailnetSetupState {
            case .waitingForListener:
                return Self(
                    indicator: .progress,
                    title: "Preparing private access…",
                    detail: "Preparing this Mac for Tailscale setup."
                )
            case .checking:
                return Self(
                    indicator: .progress,
                    title: "Checking Tailscale Serve…",
                    detail: "Checking private access before pairing a phone."
                )
            case .configuring:
                return Self(
                    indicator: .progress,
                    title: "Setting up private access…",
                    detail: "Configuring Tailscale Serve for this Mac."
                )
            case .failed(let error):
                var detail = error.recoveryMessage + (tailnetSetupState.permitsPairing
                    ? " A working manual setup can still pair a phone below."
                    : "")
                if case .portInUse = error, hasSavedOrigin, !hasPairedNativeDevice, !hasUnrevokedDevice, !hasPendingPairing {
                    detail += " No devices are paired. To choose an available Tailscale port, clear Tailnet origin, then choose Retry Setup. Do not use Detect before retrying."
                }
                return Self(
                    indicator: .failure,
                    title: error.title,
                    detail: detail
                )
            case .unchecked, .configured:
                break
            }
            if connectedNativeClientCount > 0 {
                let clientLabel = connectedNativeClientCount == 1
                    ? "1 Toastty Mobile client is connected."
                    : "\(connectedNativeClientCount) Toastty Mobile clients are connected."
                return Self(
                    indicator: .ready,
                    title: "Toastty Mobile is connected",
                    detail: "\(clientLabel) Current sessions are available on connected devices."
                )
            }
            if hasPairedNativeDevice {
                let verificationDetail = tailnetSetupState == .unchecked
                    ? " Tailscale Serve has not been verified."
                    : ""
                return Self(
                    indicator: .progress,
                    title: "Waiting for Toastty Mobile to reconnect…",
                    detail: "Remote Access is ready on this Mac.\(verificationDetail) Open Toastty on your iPhone to connect; if it's already open, it will keep retrying automatically."
                )
            }
            if tailnetSetupState == .unchecked {
                return Self(
                    indicator: .off,
                    title: "Remote Access is running on this Mac",
                    detail: "Tailscale Serve has not been verified. A working manual setup can still pair a phone below."
                )
            }
            return Self(
                indicator: .ready,
                title: "Tailscale Serve is configured",
                detail: "Pair a phone below. The phone checks the HTTPS connection."
            )
        }
    }
}

/// Management window for the remote-access gateway: kill switch, pairing,
/// paired devices with revocation, tailnet origin, and the local audit trail.
