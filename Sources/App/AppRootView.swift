import SwiftUI

struct AppRootView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store)
                .frame(width: 200)
            Divider()
            WorkspaceView(store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
