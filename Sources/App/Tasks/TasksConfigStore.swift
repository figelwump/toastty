import CoreState
import Foundation

struct TasksConfigReloadError: LocalizedError, Equatable {
    let path: String
    let message: String

    var errorDescription: String? {
        "Failed to reload \(path): \(message)"
    }
}

/// `tasks.toml`, loaded at launch and on Reload Configuration. A file that
/// fails to parse keeps the last good config.
@MainActor
final class TasksConfigStore: ObservableObject {
    @Published private(set) var config: TasksConfig

    private let fileManager: FileManager
    private let homeDirectoryPath: String
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.homeDirectoryPath = homeDirectoryPath
        self.environment = environment
        do {
            config = try TasksConfigFile.load(
                fileManager: fileManager,
                homeDirectoryPath: homeDirectoryPath,
                environment: environment
            )
        } catch {
            config = .empty
            ToasttyLog.warning(
                "Failed to load tasks config at startup",
                category: .bootstrap,
                metadata: ["path": Self.fileURL(homeDirectoryPath, environment).path, "error": error.localizedDescription]
            )
        }
    }

    /// For tests: a store with a fixed config and no file.
    init(config: TasksConfig) {
        self.config = config
        fileManager = .default
        homeDirectoryPath = NSHomeDirectory()
        environment = [TasksConfigFile.environmentOverrideKey: "/dev/null/tasks.toml"]
    }

    var fileURL: URL {
        Self.fileURL(homeDirectoryPath, environment)
    }

    private static func fileURL(_ homeDirectoryPath: String, _ environment: [String: String]) -> URL {
        TasksConfigFile.fileURL(homeDirectoryPath: homeDirectoryPath, environment: environment)
    }

    @discardableResult
    func reload() -> Result<TasksConfig, TasksConfigReloadError> {
        do {
            let next = try TasksConfigFile.load(
                fileManager: fileManager,
                homeDirectoryPath: homeDirectoryPath,
                environment: environment
            )
            config = next
            return .success(next)
        } catch {
            ToasttyLog.warning(
                "Failed to reload tasks config",
                category: .bootstrap,
                metadata: ["path": fileURL.path, "error": error.localizedDescription]
            )
            return .failure(TasksConfigReloadError(path: fileURL.path, message: error.localizedDescription))
        }
    }

    func ensureTemplateExists() {
        do {
            try TasksConfigFile.ensureTemplateExists(
                fileManager: fileManager,
                homeDirectoryPath: homeDirectoryPath,
                environment: environment
            )
        } catch {
            ToasttyLog.warning(
                "Failed to write tasks config template",
                category: .bootstrap,
                metadata: ["path": fileURL.path, "error": error.localizedDescription]
            )
        }
    }
}
