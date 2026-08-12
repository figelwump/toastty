import SwiftUI

@main
struct ToasttyMobileApp: App {
    private let configuration = ToasttyMobileAppConfiguration()

    var body: some Scene {
        WindowGroup {
            ToasttyMobileRootView(configuration: configuration)
        }
    }
}
