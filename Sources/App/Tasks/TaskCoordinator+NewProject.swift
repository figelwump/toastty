import CoreState
import Foundation

/// A project folder that `task.create` made for a new project, so that a
/// create that then fails can remove what it made.
struct TaskNewProject: Equatable {
    var path: String
    /// Toastty made the folder. Otherwise the folder was empty, and Toastty
    /// added only its `.git`.
    var madeFolder: Bool
}

extension TaskCoordinator {
    /// For a request with `newProject`: makes its folder, an empty git
    /// repository and a first empty commit, so that `startWork` has a
    /// commit to start from. Returns the request to create the task with,
    /// now by the folder as a plain `rootDirectory`, and what was made.
    ///
    /// Toastty never writes into a folder that has files: the folder must
    /// be missing or empty, in a parent folder that exists. A request that
    /// repeats one already saved makes nothing.
    func makeNewProjectIfRequested(
        _ request: TaskCreateRequest,
        caller: TaskCaller
    ) async throws -> (request: TaskCreateRequest, made: TaskNewProject?) {
        guard request.newProject else { return (request, nil) }
        var plain = request
        plain.newProject = false
        if let clientRequestID = request.clientRequestID,
           records.record(clientRequestID: clientRequestID, source: caller.source) != nil {
            return (plain, nil)
        }
        guard let rawRoot = request.rootDirectory else {
            throw TaskError("A new project needs its folder.")
        }
        guard request.workspaceID == nil else {
            throw TaskError("Pass a workspace or a new project's folder, not both.")
        }
        let path = TasksConfigFile.normalizedPath(rawRoot, homeDirectoryPath: homeDirectoryPath)
        let parent = URL(filePath: path).deletingLastPathComponent().path(percentEncoded: false).trimmingTrailingSlashes()
        guard path != "/", parent != path else {
            throw TaskError("\(path) cannot be a new project's folder.")
        }
        guard isDirectory(parent) else {
            throw TaskError("The folder \(parent) does not exist, so Toastty cannot make \(path) in it.")
        }
        guard newProjectsInProgress.insert(path).inserted else {
            throw TaskError("Toastty is already making a project at \(path).")
        }
        defer { newProjectsInProgress.remove(path) }

        let madeFolder: Bool
        if fileManager.fileExists(atPath: path) {
            guard isDirectory(path) else {
                throw TaskError("\(path) is a file. Toastty makes a new project only in a missing or empty folder.")
            }
            if fileManager.fileExists(atPath: URL(filePath: path).appending(path: ".git").path(percentEncoded: false)) {
                throw TaskError("\(path) is already a git repository. Pass it with --root to create the task there.")
            }
            guard isEmptyFolder(path, allowing: []) else {
                throw TaskError("\(path) already exists and has files in it. Toastty makes a new project only in a missing or empty folder; pass the folder with --root to use it as it is.")
            }
            madeFolder = false
        } else {
            do {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: false)
            } catch {
                throw TaskError("Toastty could not make the folder \(path): \(error.localizedDescription)")
            }
            madeFolder = true
        }
        let made = TaskNewProject(path: path, madeFolder: madeFolder)
        // Named on the command line, the repository wins over a GIT_DIR or
        // GIT_WORK_TREE that Toastty's environment may hold.
        let repository = ["--git-dir=\(path)/.git", "--work-tree=\(path)"]
        do {
            try await worktreeCreator.git(repository + ["init", "--quiet"], in: path)
            // A worktree starts from a commit; a new repository has none.
            // The commit is empty, so the user's commit hooks have nothing
            // to check.
            try await worktreeCreator.git(
                repository + ["commit", "--quiet", "--allow-empty", "--no-verify", "-m", "Initial commit"],
                in: path
            )
        } catch {
            removeNewProject(made)
            let reason = (error as? TaskError)?.message ?? error.localizedDescription
            throw TaskError("Toastty could not make a git repository at \(path): \(reason)")
        }
        ToasttyLog.info("Made a new project for a task", category: .tasks, metadata: [
            "path": path,
            "made_folder": String(madeFolder),
        ])
        plain.rootDirectory = path
        return (plain, made)
    }

    /// Removes what `makeNewProjectIfRequested` made, after a create that
    /// failed before any workspace opened on it.
    /// Anything else that came into the folder meanwhile keeps the folder.
    func removeNewProject(_ made: TaskNewProject?) {
        guard let made, isEmptyFolder(made.path, allowing: [".git"]) else { return }
        let url = URL(filePath: made.path, directoryHint: .isDirectory)
        try? fileManager.removeItem(at: made.madeFolder ? url : url.appending(path: ".git", directoryHint: .isDirectory))
    }

    /// The folder holds nothing but `allowing` and the `.DS_Store` file that
    /// Finder puts in a folder the user sees as empty.
    private func isEmptyFolder(_ path: String, allowing: Set<String>) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else { return false }
        return contents.allSatisfy { name in
            if allowing.contains(name) { return true }
            guard name == ".DS_Store" else { return false }
            let type = try? fileManager.attributesOfItem(atPath: URL(filePath: path).appending(path: name).path(percentEncoded: false))[.type]
            return (type as? FileAttributeType) == .typeRegular
        }
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var result = self
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
