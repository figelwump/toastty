import CoreState
import Foundation

@MainActor
protocol TerminalProfileProviding: AnyObject {
    var catalog: TerminalProfileCatalog { get }
}

struct TerminalProfileReloadError: LocalizedError, Equatable {
    let path: String
    let message: String

    var errorDescription: String? {
        "Failed to reload \(path): \(message)"
    }
}

@MainActor
final class TerminalProfileStore: ObservableObject, TerminalProfileProviding {
    @Published private(set) var catalog: TerminalProfileCatalog

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
            catalog = try TerminalProfilesFile.load(
                fileManager: fileManager,
                homeDirectoryPath: homeDirectoryPath,
                environment: environment
            )
        } catch {
            catalog = .empty
            ToasttyLog.warning(
                "Failed to load terminal profiles at startup",
                category: .bootstrap,
                metadata: [
                    "path": TerminalProfilesFile.fileURL(
                        homeDirectoryPath: homeDirectoryPath,
                        environment: environment
                    ).path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    var fileURL: URL {
        TerminalProfilesFile.fileURL(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
    }

    @discardableResult
    func reload() -> Result<TerminalProfileCatalog, TerminalProfileReloadError> {
        do {
            let nextCatalog = try TerminalProfilesFile.load(
                fileManager: fileManager,
                homeDirectoryPath: homeDirectoryPath,
                environment: environment
            )
            catalog = nextCatalog
            return .success(nextCatalog)
        } catch {
            let reloadError = TerminalProfileReloadError(
                path: fileURL.path,
                message: error.localizedDescription
            )
            ToasttyLog.warning(
                "Failed to reload terminal profiles",
                category: .bootstrap,
                metadata: [
                    "path": fileURL.path,
                    "error": error.localizedDescription,
                ]
            )
            return .failure(reloadError)
        }
    }
}
