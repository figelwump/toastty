import CoreState
import Foundation

/// The folder that a task in each workspace would use, and whether it is in
/// a git repository, for the quick entry Workspace list. A task takes its
/// workspace's folder (`TaskCoordinator.resolvedProjectRoot`), and a folder
/// that is not in a repository has no worktree and no pull request.
enum QuickEntryWorkspaceFolders {
    /// What the app state says about a workspace's folder.
    struct Source: Hashable, Sendable {
        var workspaceID: UUID
        /// The folder saved on the workspace by an earlier task.
        var rootDirectory: String?
        /// Its terminals' folders in layout order; the first that exists is
        /// used when none is saved.
        var terminalDirectories: [String] = []

        /// The folder to show before the check, which reads the file
        /// system: the saved one, or else the first terminal's.
        var folder: String? { rootDirectory ?? terminalDirectories.first }
    }

    struct Resolution: Equatable, Sendable {
        var folder: String
        var isInGitRepository: Bool
    }

    static let notAGitRepository = "not a git repository"
    static let noFolderYet = "no folder yet"
    /// Under the list while a workspace without a repository is highlighted.
    static let notAGitRepositoryHint = "A task here can answer a question, but it cannot open a worktree or a pull request."

    /// Reads the state only: the file system is read off the main thread,
    /// in `resolve`.
    @MainActor
    static func sources(for workspaceIDs: [UUID], in state: AppState) -> [Source] {
        workspaceIDs.compactMap { workspaceID in
            guard let workspace = state.workspacesByID[workspaceID] else { return nil }
            return Source(
                workspaceID: workspaceID,
                rootDirectory: workspace.rootDirectory,
                terminalDirectories: workspace.rootDirectory == nil
                    ? TaskCoordinator.terminalDirectories(in: workspace)
                    : []
            )
        }
    }

    /// The same rule as a task: a saved folder as it is; otherwise the
    /// first terminal's repository root, or its folder outside one. Reads
    /// the file system, so it runs off the main thread.
    static func resolve(
        _ source: Source,
        repositoryRoot: (String) -> String? = { RepositoryRootLocator.inferRepoRoot(from: $0) }
    ) -> Resolution? {
        if let rootDirectory = source.rootDirectory {
            return Resolution(folder: rootDirectory, isInGitRepository: repositoryRoot(rootDirectory) != nil)
        }
        guard let terminalDirectory = TaskCoordinator.firstExistingDirectory(source.terminalDirectories) else { return nil }
        let root = repositoryRoot(terminalDirectory)
        return Resolution(folder: root ?? terminalDirectory, isInGitRepository: root != nil)
    }

    /// A folder as the list shows it, with the home folder as ~.
    static func displayPath(_ path: String) -> String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    /// The option for a workspace: its folder, and the mark once checked.
    static func option(
        id: UUID,
        title: String,
        source: Source?,
        resolution: Resolution?
    ) -> QuickEntryModel.Option {
        QuickEntryModel.Option(
            id: id.uuidString,
            title: title,
            folder: (resolution?.folder ?? source?.folder).map(displayPath),
            isInGitRepository: resolution?.isInGitRepository
        )
    }
}
