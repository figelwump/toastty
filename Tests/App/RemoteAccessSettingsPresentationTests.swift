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
        #expect(presentation.title == "Remote Access could not start")
        #expect(presentation.detail == "Try again.")
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
            .failed(.notConfigured), .failed(.portInUse), .failed(.originMismatch),
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
}
