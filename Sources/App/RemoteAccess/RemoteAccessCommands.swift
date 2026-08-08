import SwiftUI

enum RemoteAccessWindowSceneID {
    static let value = "toastty-remote-access"
}

/// Adds the "Remote Access…" entry that opens the management window.
struct RemoteAccessCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Remote Access…") {
                openWindow(id: RemoteAccessWindowSceneID.value)
            }
        }
    }
}
