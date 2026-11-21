import SwiftUI
import ToasttyMobileDomain

/// The + that starts new work, in Home's header and in the Tasks tab's
/// navigation bar. It creates a task, as the Mac's quick entry does. A Mac
/// without task creation gets the new-session sheet instead, and a Mac that
/// takes neither from this phone gets no button.
///
/// The screen that shows the button holds both sheets' state, since Home's
/// header lays the button out more than once.
struct ToasttyNewWorkButton: View {
    let controller: HomeScreenController
    /// The screen's part of the button's identifiers, such as
    /// `toastty-mobile-home`.
    let identifierPrefix: String
    @Binding var newTask: ToasttyNewTaskModel?
    @Binding var newSession: ToasttyNewSessionModel?
    var defaults: UserDefaults = .standard

    var body: some View {
        if controller.canCreateTasks {
            Button {
                newTask = ToasttyNewTaskModel(host: controller)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
            .accessibilityLabel("New task")
            .accessibilityIdentifier("\(identifierPrefix)-new-task")
        } else if controller.canStartSessions,
           let workspace = controller.defaultSessionStartWorkspace(
               lastUsed: ToasttyNewSessionPreferences(defaults: defaults).lastWorkspaceID
           ) {
            Button {
                newSession = ToasttyNewSessionModel(
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.title,
                    host: controller,
                    preferences: ToasttyNewSessionPreferences(defaults: defaults)
                )
            } label: {
                label
            }
            .buttonStyle(.plain)
            .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
            .accessibilityLabel("New session")
            .accessibilityIdentifier("\(identifierPrefix)-new-session")
        }
    }

    private var label: some View {
        Image(systemName: "plus")
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(ToasttyDesignTokens.amber, in: Circle())
    }
}
