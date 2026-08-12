import SwiftUI

enum RemoteAccessWindowSceneID {
    static let value = "toastty-remote-access"
}

/// Adds the Toastty-menu entry that opens the Remote Access management window.
struct RemoteAccessCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Remote Access…") {
                openWindow(id: RemoteAccessWindowSceneID.value)
            }
        }
    }
}
