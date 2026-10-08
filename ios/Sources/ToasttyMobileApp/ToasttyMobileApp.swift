import SwiftUI

@main
struct ToasttyMobileApp: App {
    #if TOASTTY_MOBILE_PUSH_PROBE
    @UIApplicationDelegateAdaptor(ToasttyPushProbeDelegate.self) private var pushProbeDelegate
    #else
    @UIApplicationDelegateAdaptor(ToasttyMobileApplicationDelegate.self) private var applicationDelegate
    private let configuration = ToasttyMobileAppConfiguration()
    #endif

    var body: some Scene {
        WindowGroup {
            #if TOASTTY_MOBILE_PUSH_PROBE
            ToasttyPushProbeView(state: pushProbeDelegate.state)
            #else
            ToasttyMobileRootView(configuration: configuration, pushBridge: applicationDelegate.pushBridge)
            #endif
        }
    }
}
