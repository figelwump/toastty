import CoreState
import Foundation

enum TerminalProfileLaunchResolution: Equatable {
    case none
    case missingProfile(profileID: String, reason: TerminalLaunchReason)
    case launch(TerminalSurfaceLaunchConfiguration)
}

enum TerminalProfileLaunchResolver {
    static func resolve(
        panelID: UUID,
        terminalState: TerminalPanelState,
        catalog: TerminalProfileCatalog,
        restoredTerminalPanelIDsAwaitingLaunch: Set<UUID>,
        launchedProfiledPanelIDs: Set<UUID>
    ) -> TerminalProfileLaunchResolution {
        guard launchedProfiledPanelIDs.contains(panelID) == false,
              let profileBinding = terminalState.profileBinding else {
            return .none
        }

        let launchReason: TerminalLaunchReason = restoredTerminalPanelIDsAwaitingLaunch.contains(panelID)
            ? .restore
            : .create

        guard let profile = catalog.profile(id: profileBinding.profileID) else {
            return .missingProfile(
                profileID: profileBinding.profileID,
                reason: launchReason
            )
        }

        return .launch(
            TerminalSurfaceLaunchConfiguration(
                environmentVariables: [
                    "TOASTTY_PANEL_ID": panelID.uuidString,
                    "TOASTTY_TERMINAL_PROFILE_ID": profile.id,
                    "TOASTTY_LAUNCH_REASON": launchReason.rawValue,
                ],
                initialInput: profile.startupCommand
            )
        )
    }
}
