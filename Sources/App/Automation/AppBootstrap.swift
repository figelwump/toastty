import CoreState
import Foundation

struct AppBootstrapResult {
    let state: AppState
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
                automationLifecycle: nil,
                disableAnimations: false
            )
        }

        let state: AppState
        if let fixtureName = automationConfig.fixtureName,
           let fixtureState = AutomationFixtureLoader.load(named: fixtureName) {
            state = fixtureState
        } else {
            state = .bootstrap()
        }

        return AppBootstrapResult(
            state: state,
            automationLifecycle: AutomationLifecycle(config: automationConfig),
            disableAnimations: automationConfig.disableAnimations
        )
    }
}
