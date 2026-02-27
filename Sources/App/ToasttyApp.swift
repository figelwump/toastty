import SwiftUI

@main
struct ToasttyApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            AppRootView(store: store)
                .frame(minWidth: 980, minHeight: 620)
        }
    }
}
