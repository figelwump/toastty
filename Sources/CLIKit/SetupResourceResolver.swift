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

    /// Example skill packages copied from the repository's `examples/skills`
    /// by `Project.swift`. The workflow guide points agents here.
    static let workflowExamplesSubpath = "WorkflowExamples/skills"

    static func workflowExamplesDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = nil
    ) -> URL {
        let resourcesURL = resourcesDirectoryURL(
            environment: environment,
            executableURL: executableURL
        )
        let bundledURL = resourcesURL.appendingPathComponent(workflowExamplesSubpath, isDirectory: true)
        #if os(Linux)
        // A checkout build's resources are <checkout>/Sources/App/Resources;
        // only an install (scripts/linux/install.sh) bundles the examples.
        let checkoutURL = resourcesURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/skills", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundledURL.path) == false,
           FileManager.default.fileExists(atPath: checkoutURL.path) {
            return checkoutURL
        }
        #endif
        return bundledURL
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
