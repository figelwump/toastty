import SwiftUI

@main
struct ToasttyMobileApp: App {
    #if TOASTTY_MOBILE_PUSH_PROBE
    @UIApplicationDelegateAdaptor(ToasttyPushProbeDelegate.self) private var pushProbeDelegate
    #else
    private let configuration = ToasttyMobileAppConfiguration()
    #endif

    var body: some Scene {
        WindowGroup {
            #if TOASTTY_MOBILE_PUSH_PROBE
            ToasttyPushProbeView(state: pushProbeDelegate.state)
            #else
            ToasttyMobileRootView(configuration: configuration)
            #endif
        }
    }
}
