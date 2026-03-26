import CoreState
import Darwin
import Foundation

private struct ToasttyRuntimeInstanceManifest: Codable {
    let pid: Int32
    let launchedAt: String
    let bundlePath: String
    let executablePath: String
    let runtimeHomePath: String
    let runtimeHomeStrategy: String
    let runtimeLabel: String?
    let worktreeRootPath: String?
    let userDefaultsSuiteName: String?
    let logFilePath: String?
    let socketPath: String?
    let artifactsDirectory: String?
    let derivedPath: String?
    let runID: String?
    let arguments: [String]
}

enum ToasttyRuntimeInstanceRecorder {
    static func recordLaunch(
        processInfo: ProcessInfo = .processInfo,
        automationConfig: AutomationConfig? = nil,
        socketPathOverride: String? = nil,
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String]? = nil,
        arguments: [String]? = nil
    ) {
        let resolvedEnvironment = environment ?? processInfo.environment
        let resolvedArguments = arguments ?? processInfo.arguments
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: resolvedEnvironment
        )
        guard let instanceFileURL = runtimePaths.instanceFileURL,
              let runtimeHomeURL = runtimePaths.runtimeHomeURL else {
            return
        }

        let logConfiguration = ToasttyLogConfiguration.fromEnvironment(
            resolvedEnvironment,
            homeDirectoryPath: homeDirectoryPath
        )
        let manifest = ToasttyRuntimeInstanceManifest(
            pid: getpid(),
            launchedAt: ISO8601DateFormatter().string(from: Date()),
            bundlePath: Bundle.main.bundleURL.path,
            executablePath: Bundle.main.executableURL?.path ?? resolvedArguments.first ?? "",
            runtimeHomePath: runtimeHomeURL.path,
            runtimeHomeStrategy: runtimePaths.runtimeHomeStrategy.rawValue,
            runtimeLabel: runtimePaths.runtimeLabel,
            worktreeRootPath: runtimePaths.worktreeRootURL?.path,
            userDefaultsSuiteName: runtimePaths.userDefaultsSuiteName,
            logFilePath: logConfiguration.filePath,
            socketPath: socketPathOverride
                ?? automationConfig?.socketPath
                ?? AutomationConfig.resolveServerSocketPath(environment: resolvedEnvironment),
            artifactsDirectory: automationConfig?.artifactsDirectory
                ?? resolvedEnvironment["TOASTTY_ARTIFACTS_DIR"],
            derivedPath: resolvedEnvironment["TOASTTY_DERIVED_PATH"],
            runID: automationConfig?.runID,
            arguments: resolvedArguments
        )

        do {
            try fileManager.createDirectory(
                at: instanceFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: instanceFileURL, options: [.atomic])
        } catch {
            ToasttyLog.warning(
                "Failed to write runtime instance manifest",
                category: .bootstrap,
                metadata: [
                    "path": instanceFileURL.path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }
}
