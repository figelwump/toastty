import CoreState
import Foundation

struct AppBootstrapResult {
    let state: AppState
    let restoredTerminalPanelIDs: Set<UUID>
    let automationConfig: AutomationConfig?
    let automationLifecycle: AutomationLifecycle?
    let disableAnimations: Bool
    let layoutPersistenceContext: WorkspaceLayoutPersistenceContext?
}

enum AppBootstrap {
    static func make(
        processInfo: ProcessInfo = .processInfo,
        defaultTerminalProfileID: String? = nil
    ) -> AppBootstrapResult {
        ToasttyLog.info(
            "Bootstrapping app",
            category: .bootstrap,
            metadata: ToasttyLog.configurationSummary()
        )
        guard let automationConfig = AutomationConfig.parse(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        ) else {
            ensureAgentProfilesTemplateExists()
            let layoutPersistenceContext = WorkspaceLayoutPersistenceContext.resolve(processInfo: processInfo)
            var state: AppState
            let restoredTerminalPanelIDs: Set<UUID>
            if let restored = layoutPersistenceContext.loadState() {
                state = restored.state
                state.defaultTerminalProfileID = AppState.normalizedTerminalProfileID(defaultTerminalProfileID)
                restoredTerminalPanelIDs = state.allTerminalPanelIDs
                ToasttyLog.info(
                    "Restored workspace layout state",
                    category: .bootstrap,
                    metadata: [
                        "requested_profile_id": layoutPersistenceContext.profileID,
                        "resolved_profile_id": restored.resolvedProfileID,
                        "path": layoutPersistenceContext.fileURL.path,
                    ]
                )
            } else {
                state = .bootstrap(defaultTerminalProfileID: defaultTerminalProfileID)
                restoredTerminalPanelIDs = []
                ToasttyLog.info(
                    "Launching without persisted layout state",
                    category: .bootstrap,
                    metadata: [
                        "profile_id": layoutPersistenceContext.profileID,
                        "path": layoutPersistenceContext.fileURL.path,
                    ]
                )
            }
            return AppBootstrapResult(
                state: state,
                restoredTerminalPanelIDs: restoredTerminalPanelIDs,
                automationConfig: nil,
                automationLifecycle: nil,
                disableAnimations: false,
                layoutPersistenceContext: layoutPersistenceContext
            )
        }

        let state: AppState
        var startupError: String?

        if let fixtureName = automationConfig.fixtureName {
            do {
                state = try AutomationFixtureLoader.loadRequired(named: fixtureName)
                ToasttyLog.info(
                    "Loaded automation fixture",
                    category: .bootstrap,
                    metadata: ["fixture": fixtureName]
                )
            } catch {
                state = .bootstrap()
                startupError = "Unknown automation fixture: \(fixtureName)"
                if let stderrMessage = "toastty automation error: \(startupError ?? "unknown")\n".data(using: .utf8) {
                    FileHandle.standardError.write(stderrMessage)
                }
                ToasttyLog.error(
                    "Failed loading automation fixture",
                    category: .bootstrap,
                    metadata: [
                        "fixture": fixtureName,
                        "error": startupError ?? "unknown",
                    ]
                )
            }
        } else {
            state = .bootstrap()
        }

        ToasttyLog.info(
            "Launching with automation",
            category: .bootstrap,
            metadata: [
                "disable_animations": automationConfig.disableAnimations ? "true" : "false",
                "fixture": automationConfig.fixtureName ?? "",
            ]
        )
        return AppBootstrapResult(
            state: state,
            restoredTerminalPanelIDs: [],
            automationConfig: automationConfig,
            automationLifecycle: AutomationLifecycle(config: automationConfig, startupError: startupError),
            disableAnimations: automationConfig.disableAnimations,
            // Automation runs must be deterministic and fixture-driven, so we
            // intentionally bypass user layout persistence in this mode.
            layoutPersistenceContext: nil
        )
    }

    private static func ensureAgentProfilesTemplateExists() {
        do {
            try AgentProfilesFile.ensureTemplateExists()
        } catch {
            ToasttyLog.warning(
                "Failed to ensure agent profiles template exists",
                category: .bootstrap,
                metadata: [
                    "path": AgentProfilesFile.fileURL().path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }
}
