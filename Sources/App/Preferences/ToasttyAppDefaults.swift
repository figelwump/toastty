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
        #if os(Linux)
        // nil keeps the `.standard` domain (the executable name).
        return LinuxWriteThroughUserDefaults(suiteName: runtimePaths.userDefaultsSuiteName) ?? .standard
        #else
        guard let suiteName = runtimePaths.userDefaultsSuiteName else {
            return .standard
        }
        return UserDefaults(suiteName: suiteName) ?? .standard
        #endif
    }
}

#if os(Linux)
/// swift-corelibs-foundation keeps `UserDefaults` writes in memory and only
/// writes `$XDG_CONFIG_HOME/<domain>.plist` on an explicit `synchronize()`:
/// there is no background flush and nothing at exit, so every preference
/// (Remote Access, Ask Before Quitting, ...) was lost on restart. Write each
/// change through, as Darwin's cfprefsd effectively does. The typed setters
/// (`set(_: Bool, forKey:)` etc.) all funnel into `set(_: Any?, forKey:)`.
final class LinuxWriteThroughUserDefaults: UserDefaults {
    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        synchronize()
    }

    override func removeObject(forKey defaultName: String) {
        super.removeObject(forKey: defaultName)
        synchronize()
    }
}
#endif
