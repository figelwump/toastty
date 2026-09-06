import Foundation

enum PairingState: Equatable {
    case intro
    case scanning
    case manual
    case confirming(PairingConfirmation)
    case exchanging(hostname: String)
    case failure(PairingFailurePresentation)
}

struct PairingConfirmation: Equatable {
    enum Method: Equatable {
        case scannedCode
        case manualCode
    }

    var hostname: String
    var method: Method
}

enum PairingFailurePresentation: Equatable {
    case invalidPairingDetails
    case expiredOrUsedOffer
    case tooManyAttempts
    case tailscaleUnavailable
    case hostUnreachable
    case tlsOrHostname
    case identityMismatch
    case protocolMismatch
    case storageUnavailable
    case unexpected

    var title: String {
        switch self {
        case .invalidPairingDetails: "Check the pairing details"
        case .expiredOrUsedOffer: "Pairing offer unavailable"
        case .tooManyAttempts: "Too many attempts"
        case .tailscaleUnavailable: "Tailscale is unavailable"
        case .hostUnreachable: "Your Mac is unreachable"
        case .tlsOrHostname: "Secure connection failed"
        case .identityMismatch: "Tailnet identity did not match"
        case .protocolMismatch: "Toastty needs an update"
        case .storageUnavailable: "Could not secure this device"
        case .unexpected: "Pairing could not finish"
        }
    }

    var message: String {
        switch self {
        case .invalidPairingDetails:
            "Use the complete Tailscale hostname and the current code shown by Toastty on your Mac."
        case .expiredOrUsedOffer:
            "This offer expired or was already used. Create a new native pairing offer on your Mac."
        case .tooManyAttempts:
            "Wait a moment, then create a new pairing offer on your Mac."
        case .tailscaleUnavailable:
            "Connect this iPhone to Tailscale and make sure it is using the same tailnet as your Mac."
        case .hostUnreachable:
            "Make sure your Mac is awake, Toastty is running, and Remote Access is enabled."
        case .tlsOrHostname:
            "The hostname or secure Tailscale connection could not be verified. Confirm the full hostname on your Mac."
        case .identityMismatch:
            "This pairing offer belongs to a different Tailscale login. Switch to the matching tailnet and try again."
        case .protocolMismatch:
            "Update Toastty on this iPhone or your Mac before pairing again."
        case .storageUnavailable:
            "Toastty received the device credential but could not save it securely. Try again after unlocking this iPhone."
        case .unexpected:
            "Create a new pairing offer on your Mac and try again."
        }
    }
}

enum PairingScannerAvailability: Equatable {
    case available
    case unsupported
    case unavailable

    init(isSupported: Bool, isAvailable: Bool) {
        self = !isSupported ? .unsupported : (isAvailable ? .available : .unavailable)
    }
}

enum PairingScannerFailure: Equatable {
    case couldNotStart
    case becameUnavailable
}

enum PairingScannerAuthorization: Equatable {
    case authorized
    case denied
}
