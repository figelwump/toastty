import Foundation
import Observation
import ToasttyMobileDomain

@MainActor
@Observable
final class HomeScreenController {
    let runtimeMode: ToasttyMobileRuntimeMode
    var snapshot: MobileHomeSnapshot
    var connectionState: MobileConnectionState
    var selectedConversation: MobileConversation?

    init(
        runtimeMode: ToasttyMobileRuntimeMode,
        snapshot: MobileHomeSnapshot,
        connectionState: MobileConnectionState
    ) {
        self.runtimeMode = runtimeMode
        self.snapshot = snapshot
        self.connectionState = connectionState
    }

    func open(_ conversation: MobileConversation) {
        selectedConversation = conversation
    }

    func dismissConversation() {
        selectedConversation = nil
    }
}
