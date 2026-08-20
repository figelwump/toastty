import Testing
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
            connectedNativeClientCount: 0,
            hasPairedNativeDevice: false
        )

        #expect(presentation.indicator == .ready)
        #expect(presentation.title == "Remote Access is ready")
        #expect(presentation.detail.contains("Pair a phone below"))
    }

    @Test func showsConnectionAfterClientSubscriptionArrives() {
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: .ready(port: 42_871),
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
}
