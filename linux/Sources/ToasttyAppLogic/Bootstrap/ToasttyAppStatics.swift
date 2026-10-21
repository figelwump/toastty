import CoreState
import Foundation

/// The macOS `ToasttyApp` is the SwiftUI `App` (not compiled on Linux). Its
/// static helpers that shared tests call are forwarded here to the Linux
/// ports in `LinuxAppConfiguration`, so those tests check the Linux code.
enum ToasttyApp {
    nonisolated static func baseLaunchEnvironment(
        panelID: UUID,
        runtimePaths: ToasttyRuntimePaths,
        socketPath: String,
        cliExecutablePath: String?,
        appResourcesPath: String?,
        shimDirectoryPath: String?,
        basePath: String?,
        agentBasePath: String?
    ) -> [String: String] {
        LinuxAppConfiguration.baseLaunchEnvironment(
            panelID: panelID,
            runtimePaths: runtimePaths,
            socketPath: socketPath,
            cliExecutablePath: cliExecutablePath,
            appResourcesPath: appResourcesPath,
            shimDirectoryPath: shimDirectoryPath,
            basePath: basePath,
            agentBasePath: agentBasePath
        )
    }

    nonisolated static func managedAgentCommandShimDirectoryURL(
        runtimePaths: ToasttyRuntimePaths,
        helperExecutablePath: String?
    ) -> URL {
        LinuxAppConfiguration.managedAgentCommandShimDirectoryURL(
            runtimePaths: runtimePaths,
            helperExecutablePath: helperExecutablePath
        )
    }

    @MainActor
    static func applyToasttyTerminalFontState(
        to store: AppStore,
        toasttyConfig: ToasttyConfig,
        legacyTerminalFontSizePoints: Double?,
        ghosttyConfiguredTerminalFontPoints: Double?,
        clearLegacyTerminalFontSizePoints: @escaping () -> Void = {
            ToasttySettingsStore.clearLegacyTerminalFontSizePoints()
        }
    ) {
        LinuxAppConfiguration.applyTerminalFontState(
            to: store,
            config: toasttyConfig,
            legacyTerminalFontSizePoints: legacyTerminalFontSizePoints,
            ghosttyConfiguredTerminalFontPoints: ghosttyConfiguredTerminalFontPoints,
            clearLegacyTerminalFontSizePoints: clearLegacyTerminalFontSizePoints
        )
    }
}
