import CoreState
import Foundation

struct AppBootstrapResult {
    let state: AppState
    let automationConfig: AutomationConfig?
    let automationLifecycle: AutomationLifecycle?
    let disableAnimations: Bool
}

enum AppBootstrap {
    static func make(processInfo: ProcessInfo = .processInfo) -> AppBootstrapResult {
        ToasttyLog.info(
            "Bootstrapping app",
            category: .bootstrap,
            metadata: ToasttyLog.configurationSummary()
        )
        guard let automationConfig = AutomationConfig.parse(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        ) else {
            ToasttyLog.info("Launching without automation", category: .bootstrap)
            return AppBootstrapResult(
                state: .bootstrap(),
                automationConfig: nil,
                automationLifecycle: nil,
                disableAnimations: false
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
            automationConfig: automationConfig,
            automationLifecycle: AutomationLifecycle(config: automationConfig, startupError: startupError),
            disableAnimations: automationConfig.disableAnimations
        )
    }
}
