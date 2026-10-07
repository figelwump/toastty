import Testing
import Foundation
@testable import ToasttyApp

struct RemoteAccessSettingsPresentationTests {
    @Test func presentsListenerStartupAsProgress() {
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: .starting,
            connectedNativeClientCount: 0,
            hasPairedNativeDevice: true
        )

        #expect(presentation.indicator == .progress)
        #expect(presentation.title == "Starting Remote Access…")
        #expect(presentation.detail.contains("Preparing conversations"))
    }

    @Test func waitsForPairedDeviceAfterListenerIsReady() {
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: .ready(port: 42_871),
            tailnetSetupState: .configured,
            connectedNativeClientCount: 0,
            hasPairedNativeDevice: true
        )

        #expect(presentation.indicator == .progress)
        #expect(presentation.title == "Waiting for Toastty Mobile to reconnect…")
        #expect(presentation.detail.contains("ready on this Mac"))
        #expect(presentation.detail.contains("retrying automatically"))
    }

    @Test func browserPairingAloneDoesNotWaitForToasttyMobile() {
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: .ready(port: 42_871),
            tailnetSetupState: .configured,
            connectedNativeClientCount: 0,
            hasPairedNativeDevice: false
        )

        #expect(presentation.indicator == .ready)
        #expect(presentation.title == "Tailscale Serve is configured")
        #expect(presentation.detail.contains("Pair a phone below"))
    }

    @Test func showsConnectionAfterClientSubscriptionArrives() {
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: .ready(port: 42_871),
            tailnetSetupState: .configured,
            connectedNativeClientCount: 2,
            hasPairedNativeDevice: true
        )

        #expect(presentation.indicator == .ready)
        #expect(presentation.title == "Toastty Mobile is connected")
        #expect(presentation.detail.contains("2 Toastty Mobile clients are connected"))
    }

    @Test func presentsActivationFailureWithoutProgress() {
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: .failed(message: "Try again."),
            connectedNativeClientCount: 0,
            hasPairedNativeDevice: true
        )

        #expect(presentation.indicator == .failure)
        #expect(presentation.title == "Local Remote Access could not start")
        #expect(presentation.detail == "Try again.")
    }

    @Test func serveFailuresIdentifyTheFailedStep() {
        let cases: [(TailscaleServeSetupError, String)] = [
            (.notConfigured, "Tailscale Serve is not configured"),
            (.configurationFailed, "Tailscale Serve setup failed"),
            (.timedOut, "Tailscale Serve setup timed out"),
            (.portInUse(443), "Tailscale HTTPS port 443 is in use"),
            (.noAvailableHTTPSPort, "No Tailscale HTTPS port is available"),
        ]
        for (error, title) in cases {
            let presentation = RemoteAccessConnectionStatusPresentation.make(
                activationState: .ready(port: 42_871),
                tailnetSetupState: .failed(error),
                connectedNativeClientCount: 0,
                hasPairedNativeDevice: false
            )
            #expect(presentation.title == title)
            #expect(presentation.indicator == .failure)
            #expect(presentation.detail.contains("Tailscale"))
            #expect(!RemoteAccessTailnetSetupState.failed(error).permitsPairing)
        }
    }

    @Test func emptyOriginDoesNotSuggestClearingTheFieldAgain() {
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: .ready(port: 42_871),
            tailnetSetupState: .failed(.portInUse(8443)),
            connectedNativeClientCount: 0,
            hasPairedNativeDevice: false,
            hasUnrevokedDevice: false,
            hasPendingPairing: false,
            hasSavedOrigin: false
        )
        #expect(!presentation.detail.contains("clear Tailnet origin"))
    }

    @Test func uncheckedSetupDoesNotClaimPhoneReachability() {
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: .ready(port: 42_871),
            tailnetSetupState: .unchecked,
            connectedNativeClientCount: 0,
            hasPairedNativeDevice: false
        )
        #expect(presentation.title == "Remote Access is running on this Mac")
        #expect(presentation.detail.contains("not been verified"))
        #expect(RemoteAccessTailnetSetupState.unchecked.permitsPairing)
    }

    @Test func setupProgressAndKnownConflictsBlockNewPairing() {
        for state: RemoteAccessTailnetSetupState in [
            .waitingForListener, .checking, .configuring,
            .failed(.notConfigured), .failed(.portInUse(443)), .failed(.originMismatch),
            .failed(.funnelEnabled), .failed(.identityChanged),
            .failed(.timedOut), .failed(.configurationFailed),
        ] {
            let presentation = RemoteAccessConnectionStatusPresentation.make(
                activationState: .ready(port: 42_871),
                tailnetSetupState: state,
                connectedNativeClientCount: 0,
                hasPairedNativeDevice: false
            )
            #expect(state.permitsPairing == false)
            #expect(presentation.indicator == (state.isInProgress ? .progress : .failure))
        }
    }

    @Test func unavailableVerificationStillAllowsManualPairing() {
        for error: TailscaleServeSetupError in [
            .detection(.notInstalled), .statusUnavailable,
        ] {
            let state = RemoteAccessTailnetSetupState.failed(error)
            let presentation = RemoteAccessConnectionStatusPresentation.make(
                activationState: .ready(port: 42_871),
                tailnetSetupState: state,
                connectedNativeClientCount: 0,
                hasPairedNativeDevice: false
            )
            #expect(state.permitsPairing)
            #expect(presentation.title == "Tailscale Serve is not verified")
            #expect(presentation.detail.contains("manual setup"))
        }
    }

    @Test func approvalUsesTheBackendValidatedLinkAndBlocksPairing() throws {
        let url = try #require(URL(string: "https://login.tailscale.com/admin/serve"))
        let state = RemoteAccessTailnetSetupState.failed(.approvalRequired(url))
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: .ready(port: 42_871),
            tailnetSetupState: state,
            connectedNativeClientCount: 0,
            hasPairedNativeDevice: false
        )
        #expect(state.approvalURL == url)
        #expect(state.permitsPairing == false)
        #expect(presentation.title == "Tailscale setup needs approval")
        #expect(presentation.detail == state.failureMessage)
    }

    @Test func savedPortConflictOffersClearAndRetryOnlyWithoutDevicesOrPendingPairing() {
        for (hasDevice, hasPendingPairing) in [(false, false), (true, false), (false, true)] {
            let presentation = RemoteAccessConnectionStatusPresentation.make(
                activationState: .ready(port: 42_871),
                tailnetSetupState: .failed(.portInUse(443)),
                connectedNativeClientCount: 0,
                hasPairedNativeDevice: false,
                hasUnrevokedDevice: hasDevice,
                hasPendingPairing: hasPendingPairing
            )
            #expect(presentation.detail.contains("clear Tailnet origin") == (!hasDevice && !hasPendingPairing))
            #expect(presentation.detail.contains("Do not use Detect") == (!hasDevice && !hasPendingPairing))
            #expect(presentation.detail.contains("Restore the Toastty mapping"))
        }
    }

    @Test func exhaustedFallbackPortsDoNotOfferSavedPortRecovery() {
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: .ready(port: 42_871),
            tailnetSetupState: .failed(.noAvailableHTTPSPort),
            connectedNativeClientCount: 0,
            hasPairedNativeDevice: false,
            hasUnrevokedDevice: false,
            hasPendingPairing: false
        )
        #expect(presentation.detail.contains("clear Tailnet origin") == false)
        #expect(presentation.detail.contains("8443–8447"))
    }
}
