import CoreState
import Foundation

struct GettingStartedSetupFootprint: Equatable {
    var hasToasttyConfig = false
    var hasWorkspaceLayouts = false
    var hasAgentProfiles = false
    var hasTerminalProfiles = false
    var hasPersistedSettings = false

    var exists: Bool {
        hasToasttyConfig
            || hasWorkspaceLayouts
            || hasAgentProfiles
            || hasTerminalProfiles
            || hasPersistedSettings
    }
}

enum GettingStartedEligibility {
    static func setupFootprint(
        runtimePaths: ToasttyRuntimePaths,
        userDefaults: UserDefaults,
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GettingStartedSetupFootprint {
        GettingStartedSetupFootprint(
            hasToasttyConfig: fileManager.fileExists(atPath: runtimePaths.configFileURL.path),
            hasWorkspaceLayouts: fileManager.fileExists(atPath: runtimePaths.workspaceLayoutsFileURL.path),
            hasAgentProfiles: fileManager.fileExists(
                atPath: AgentProfilesFile.fileURL(homeDirectoryPath: homeDirectoryPath).path
            ),
            hasTerminalProfiles: fileManager.fileExists(
                atPath: TerminalProfilesFile.fileURL(
                    homeDirectoryPath: homeDirectoryPath,
                    environment: environment
                ).path
            ),
            hasPersistedSettings: ToasttySettingsStore.hasPersistedSettings(userDefaults: userDefaults)
        )
    }

    static func allowsAutoPresentation(
        usesPersistentPreferences: Bool,
        setupFootprint: GettingStartedSetupFootprint
    ) -> Bool {
        usesPersistentPreferences && setupFootprint.exists == false
    }

    static func shouldShowTopBarButton(
        hasSuppressedGettingStarted: Bool,
        setupFootprint: GettingStartedSetupFootprint
    ) -> Bool {
        hasSuppressedGettingStarted == false && setupFootprint.exists == false
    }

    static func shouldCreateStartupSetupTemplates(
        usesPersistentPreferences: Bool,
        setupFootprint: GettingStartedSetupFootprint
    ) -> Bool {
        usesPersistentPreferences == false || setupFootprint.exists
    }
}
