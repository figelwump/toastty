@testable import ToasttyApp
import CoreState
import Foundation
import Testing

struct TerminalProfileLaunchResolverTests {
    @Test
    func resolveReturnsLaunchConfigurationForCreate() {
        let panelID = UUID()
        let terminalState = TerminalPanelState(
            title: "Terminal 1",
            shell: "zsh",
            cwd: "/tmp",
            profileBinding: TerminalProfileBinding(profileID: "zmx")
        )
        let catalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                )
            ]
        )

        let resolution = TerminalProfileLaunchResolver.resolve(
            panelID: panelID,
            terminalState: terminalState,
            catalog: catalog,
            restoredTerminalPanelIDsAwaitingLaunch: [],
            launchedProfiledPanelIDs: []
        )

        #expect(
            resolution == .launch(
                TerminalSurfaceLaunchConfiguration(
                    environmentVariables: [
                        "TOASTTY_PANEL_ID": panelID.uuidString,
                        "TOASTTY_TERMINAL_PROFILE_ID": "zmx",
                        "TOASTTY_LAUNCH_REASON": "create",
                    ],
                    initialInput: "zmx attach toastty.$TOASTTY_PANEL_ID"
                )
            )
        )
    }

    @Test
    func resolveUsesRestoreLaunchReasonForRestoredPanel() {
        let panelID = UUID()
        let terminalState = TerminalPanelState(
            title: "Terminal 1",
            shell: "zsh",
            cwd: "/tmp",
            profileBinding: TerminalProfileBinding(profileID: "zmx")
        )
        let catalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                )
            ]
        )

        let resolution = TerminalProfileLaunchResolver.resolve(
            panelID: panelID,
            terminalState: terminalState,
            catalog: catalog,
            restoredTerminalPanelIDsAwaitingLaunch: [panelID],
            launchedProfiledPanelIDs: []
        )

        guard case .launch(let configuration) = resolution else {
            Issue.record("Expected launch configuration")
            return
        }
        #expect(configuration.environmentVariables["TOASTTY_LAUNCH_REASON"] == "restore")
    }

    @Test
    func resolveMergesProfileEnvironmentOntoBaseLaunchContext() {
        let panelID = UUID()
        let terminalState = TerminalPanelState(
            title: "Terminal 1",
            shell: "zsh",
            cwd: "/tmp",
            profileBinding: TerminalProfileBinding(profileID: "zmx")
        )
        let catalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                )
            ]
        )

        let resolution = TerminalProfileLaunchResolver.resolve(
            panelID: panelID,
            terminalState: terminalState,
            catalog: catalog,
            restoredTerminalPanelIDsAwaitingLaunch: [],
            launchedProfiledPanelIDs: [],
            baseEnvironmentVariables: [
                "PATH": "/tmp/toastty/bin:/usr/bin",
                "TOASTTY_SOCKET_PATH": "/tmp/toastty.sock",
            ]
        )

        guard case .launch(let configuration) = resolution else {
            Issue.record("expected launch configuration")
            return
        }
        #expect(configuration.environmentVariables["PATH"] == "/tmp/toastty/bin:/usr/bin")
        #expect(configuration.environmentVariables["TOASTTY_SOCKET_PATH"] == "/tmp/toastty.sock")
        #expect(configuration.environmentVariables["TOASTTY_PANEL_ID"] == panelID.uuidString)
        #expect(configuration.environmentVariables["TOASTTY_TERMINAL_PROFILE_ID"] == "zmx")
    }

    @Test
    func resolveReturnsMissingProfileWhenBindingIsUnavailable() {
        let panelID = UUID()
        let terminalState = TerminalPanelState(
            title: "Terminal 1",
            shell: "zsh",
            cwd: "/tmp",
            profileBinding: TerminalProfileBinding(profileID: "missing")
        )

        let resolution = TerminalProfileLaunchResolver.resolve(
            panelID: panelID,
            terminalState: terminalState,
            catalog: .empty,
            restoredTerminalPanelIDsAwaitingLaunch: [panelID],
            launchedProfiledPanelIDs: []
        )

        #expect(resolution == .missingProfile(profileID: "missing", reason: .restore))
    }

    @Test
    func resolveReturnsNoneAfterProfiledPaneHasAlreadyLaunched() {
        let panelID = UUID()
        let terminalState = TerminalPanelState(
            title: "Terminal 1",
            shell: "zsh",
            cwd: "/tmp",
            profileBinding: TerminalProfileBinding(profileID: "zmx")
        )
        let catalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                )
            ]
        )

        let resolution = TerminalProfileLaunchResolver.resolve(
            panelID: panelID,
            terminalState: terminalState,
            catalog: catalog,
            restoredTerminalPanelIDsAwaitingLaunch: [panelID],
            launchedProfiledPanelIDs: [panelID]
        )

        #expect(resolution == .none)
    }
}
