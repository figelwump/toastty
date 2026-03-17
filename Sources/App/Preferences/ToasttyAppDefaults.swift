import CoreState
import Foundation

enum ToasttyAppDefaults {
    nonisolated(unsafe) static let current: UserDefaults = make()

    static func make(
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        guard let suiteName = runtimePaths.userDefaultsSuiteName else {
            return .standard
        }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}
