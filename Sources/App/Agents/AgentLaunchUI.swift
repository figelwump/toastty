import AppKit
import Foundation

@MainActor
enum AgentLaunchUI {
    @discardableResult
    static func launch(
        profileID: String,
        workspaceID: UUID?,
        agentLaunchService: AgentLaunchService
    ) -> Bool {
        do {
            _ = try agentLaunchService.launch(
                profileID: profileID,
                workspaceID: workspaceID
            )
            return true
        } catch {
            presentLaunchError(error)
            return false
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
