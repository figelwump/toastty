import AppKit
import Foundation

@MainActor
enum AgentLaunchUI {
    static func launch(
        profileID: String,
        workspaceID: UUID?,
        agentLaunchService: AgentLaunchService
    ) {
        do {
            _ = try agentLaunchService.launch(
                profileID: profileID,
                workspaceID: workspaceID
            )
        } catch {
            presentLaunchError(error)
        }
    }

    private static func presentLaunchError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Unable to Run Agent"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
