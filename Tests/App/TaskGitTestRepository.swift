import Foundation
@testable import ToasttyApp

/// A real git repository for task worktree tests: a bare `remote.git`, a
/// `seed` clone that pushes new commits to it, and the `project` clone that
/// tasks make worktrees from. Removed when released.
final class TaskGitTestRepository {
    let root: URL
    let remote: String
    let seed: String
    let project: String

    /// Git with no user or system config, so the tests do not depend on the
    /// machine's settings.
    static let environment: [String: String] = {
        var environment = TaskCommandEnvironment.make(path: ProcessInfo.processInfo.environment["PATH"])
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "Toastty Tests"
        environment["GIT_AUTHOR_EMAIL"] = "tests@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Toastty Tests"
        environment["GIT_COMMITTER_EMAIL"] = "tests@example.invalid"
        return environment
    }()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-task-git-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        remote = root.appendingPathComponent("remote.git").path
        seed = root.appendingPathComponent("seed").path
        project = root.appendingPathComponent("project").path
        try Self.git(["init", "--quiet", "-b", "main", seed], in: root.path)
        try commit("first", in: seed)
        try Self.git(["clone", "--quiet", "--bare", seed, remote], in: root.path)
        try Self.git(["remote", "add", "origin", remote], in: seed)
        try Self.git(["fetch", "--quiet", "origin"], in: seed)
        try Self.git(["clone", "--quiet", remote, project], in: root.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A worktree creator that runs real git with the test environment.
    static func creator(locks: TaskCheckoutLocks = TaskCheckoutLocks()) -> TaskWorktreeCreator {
        TaskWorktreeCreator(locks: locks, environment: { TaskGitTestRepository.environment })
    }

    /// Commits a new file in `directory` and returns the commit.
    @discardableResult
    func commit(_ name: String, in directory: String) throws -> String {
        try Data(name.utf8).write(to: URL(filePath: directory).appending(path: "\(name).txt"))
        try Self.git(["add", "."], in: directory)
        try Self.git(["commit", "--quiet", "-m", name], in: directory)
        return try Self.git(["rev-parse", "HEAD"], in: directory)
    }

    /// Commits in the seed and pushes it to the remote's `branch`, so the
    /// project's view of the remote is out of date.
    @discardableResult
    func pushToRemote(_ name: String, branch: String = "main") throws -> String {
        if branch != "main" {
            try Self.git(["checkout", "--quiet", "-B", branch, "origin/main"], in: seed)
        } else {
            try Self.git(["checkout", "--quiet", "main"], in: seed)
        }
        let sha = try commit(name, in: seed)
        try Self.git(["push", "--quiet", "origin", "HEAD:refs/heads/\(branch)"], in: seed)
        return sha
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TaskError("git \(arguments.joined(separator: " ")) failed: \(String(decoding: errorData, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
