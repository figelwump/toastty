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
        guard let automationConfig = AutomationConfig.parse(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        ) else {
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
            } catch {
                state = .bootstrap()
                startupError = "Unknown automation fixture: \(fixtureName)"
                if let data = ("toastty automation error: \(startupError ?? "unknown")\n").data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
            }
        } else {
            state = .bootstrap()
        }

        return AppBootstrapResult(
            state: state,
            automationConfig: automationConfig,
            automationLifecycle: AutomationLifecycle(config: automationConfig, startupError: startupError),
            disableAnimations: automationConfig.disableAnimations
        )
    }
}
