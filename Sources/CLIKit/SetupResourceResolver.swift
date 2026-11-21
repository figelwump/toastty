import CoreState
import Darwin
import Foundation

enum SetupResourceResolver {
    static func resourcesDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = nil
    ) -> URL {
        if let resourcesPath = normalizedPath(environment[ToasttyLaunchContextEnvironment.appResourcesPathKey]) {
            return URL(fileURLWithPath: resourcesPath, isDirectory: true).standardizedFileURL
        }

        return (executableURL ?? currentExecutableURL())
            .deletingLastPathComponent()
            .appendingPathComponent("../Resources", isDirectory: true)
            .standardizedFileURL
    }

    static func setupDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = nil
    ) -> URL {
        resourcesDirectoryURL(
            environment: environment,
            executableURL: executableURL
        )
        .appendingPathComponent("Setup", isDirectory: true)
    }

    private static func normalizedPath(_ rawValue: String?) -> String? {
        guard let rawValue,
              rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return rawValue
    }

    private static func currentExecutableURL() -> URL {
        var size = UInt32(0)
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            let bytes = buffer
                .prefix { $0 != 0 }
                .map { UInt8(bitPattern: $0) }
            return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL
        }

        return URL(fileURLWithPath: CommandLine.arguments.first ?? "").standardizedFileURL
    }
}
