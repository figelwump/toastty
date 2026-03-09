import CoreState
import Foundation

@MainActor
protocol AgentCatalogProviding: AnyObject {
    var catalog: AgentCatalog { get }
}

struct AgentCatalogReloadError: LocalizedError, Equatable {
    let path: String
    let message: String

    var errorDescription: String? {
        "Failed to reload \(path): \(message)"
    }
}

@MainActor
final class AgentCatalogStore: ObservableObject, AgentCatalogProviding {
    @Published private(set) var catalog: AgentCatalog

    private let fileManager: FileManager
    private let homeDirectoryPath: String

    init(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory()
    ) {
        self.fileManager = fileManager
        self.homeDirectoryPath = homeDirectoryPath
        do {
            catalog = try AgentProfilesFile.load(
                fileManager: fileManager,
                homeDirectoryPath: homeDirectoryPath
            )
        } catch {
            catalog = .empty
            ToasttyLog.warning(
                "Failed to load agent catalog at startup",
                category: .bootstrap,
                metadata: [
                    "path": AgentProfilesFile.fileURL(homeDirectoryPath: homeDirectoryPath).path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    var fileURL: URL {
        AgentProfilesFile.fileURL(homeDirectoryPath: homeDirectoryPath)
    }

    @discardableResult
    func reload() -> Result<AgentCatalog, AgentCatalogReloadError> {
        do {
            let nextCatalog = try AgentProfilesFile.load(
                fileManager: fileManager,
                homeDirectoryPath: homeDirectoryPath
            )
            catalog = nextCatalog
            return .success(nextCatalog)
        } catch {
            let reloadError = AgentCatalogReloadError(
                path: fileURL.path,
                message: error.localizedDescription
            )
            ToasttyLog.warning(
                "Failed to reload agent catalog",
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
