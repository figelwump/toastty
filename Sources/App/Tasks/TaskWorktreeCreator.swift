import CoreState
import Foundation

/// A repository that tasks make worktrees in.
struct TaskGitCheckout: Equatable, Sendable {
    /// The main checkout: worktrees are made next to it and named after it.
    var root: String
    /// The shared `.git` directory. Every checkout of the repository has the
    /// same one, so it keys the lock that keeps their fetches apart.
    var commonDirectory: String
    /// `origin` when there is one, else the first remote; `nil` for a
    /// repository without remotes.
    var remote: String?
}

/// Runs one body at a time for each key, in the order they arrive. Two
/// starts from the same repository share `FETCH_HEAD`, so each fetches,
/// reads it and adds its worktree before the next one fetches.
actor TaskCheckoutLocks {
    private var tails: [String: Task<Void, Never>] = [:]

    func run<T: Sendable>(_ key: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tails[key]
        let work = Task<T, any Error> {
            await previous?.value
            return try await body()
        }
        tails[key] = Task { _ = try? await work.value }
        return try await work.value
    }
}

/// The git and hook work for a task's worktree. Every command runs off the
/// main actor, with the login shell's PATH and without Toastty session
/// variables.
struct TaskWorktreeCreator: Sendable {
    let runner: any TaskCommandRunning
    let locks: TaskCheckoutLocks
    /// The environment for git and the hook, before task variables.
    let environment: @Sendable () -> [String: String]
    var gitTimeout: TimeInterval = 120
    var hookTimeout: TimeInterval = 30 * 60

    static let maximumNameAttempts = 50

    init(
        runner: any TaskCommandRunning = TaskLiveCommandRunner(),
        locks: TaskCheckoutLocks = TaskCheckoutLocks(),
        environment: @escaping @Sendable () -> [String: String] = { TaskCommandEnvironment.make(path: LoginPath.value()) }
    ) {
        self.runner = runner
        self.locks = locks
        self.environment = environment
    }

    // MARK: - Checkout

    func checkout(for projectRoot: String) async throws -> TaskGitCheckout {
        let common = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: projectRoot)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonURL = URL(filePath: common, directoryHint: .isDirectory).standardizedFileURL
        guard commonURL.lastPathComponent == ".git" else {
            throw TaskError("\(projectRoot) is in a repository without a main checkout, so Toastty cannot place a worktree next to it.")
        }
        let root = commonURL.deletingLastPathComponent().path(percentEncoded: false)
        let remotes = try await git(["remote"], in: root).output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        return TaskGitCheckout(
            root: Self.trimmedDirectory(root),
            commonDirectory: commonURL.path(percentEncoded: false),
            remote: remotes.contains("origin") ? "origin" : remotes.first
        )
    }

    // MARK: - Base

    /// The commit to start from. With no `base`, the remote's default
    /// branch, fetched now. A `base` names a branch on the remote, fetched
    /// now, or a local commit. Call it under the checkout's lock: it reads
    /// `FETCH_HEAD`.
    func pinBase(_ checkout: TaskGitCheckout, base: String?) async throws -> TaskOperation.Base {
        if let base {
            try Self.validateRefArgument(base, name: "base")
        }
        guard let remote = checkout.remote else {
            return try await localBase(checkout, base: base)
        }
        if let base, Self.looksLikeCommitID(base), let sha = try? await resolveCommit(base, in: checkout.root) {
            return TaskOperation.Base(sha: sha, ref: base, fetched: false)
        }
        let branch: String
        if let base {
            branch = base.hasPrefix("\(remote)/") ? String(base.dropFirst(remote.count + 1)) : base
        } else {
            branch = try await defaultBranch(checkout, remote: remote)
        }
        // Only a valid branch name reaches the fetch: anything else, such as
        // `main:refs/heads/other`, would be read as a refspec that writes a
        // local branch. A base that is not a branch name can still be a
        // local commit such as `HEAD~2`.
        guard try await git(["check-ref-format", "--branch", branch], in: checkout.root, allowFailure: true).succeeded else {
            if let base, let sha = try? await resolveCommit(base, in: checkout.root) {
                return TaskOperation.Base(sha: sha, ref: base, fetched: false)
            }
            throw TaskError("\(base ?? branch) is not a branch name or a commit.")
        }
        let fetch = try await git(
            ["fetch", "--no-tags", "--quiet", remote, "refs/heads/\(branch)"],
            in: checkout.root,
            allowFailure: true
        )
        if fetch.succeeded {
            let sha = try await resolveCommit("FETCH_HEAD", in: checkout.root)
            return TaskOperation.Base(sha: sha, ref: "\(remote)/\(branch)", fetched: true)
        }
        // Offline, or the remote refused: the last fetched commit still
        // works, and the record says it may be old.
        if let sha = try? await resolveCommit("refs/remotes/\(remote)/\(branch)", in: checkout.root) {
            return TaskOperation.Base(
                sha: sha,
                ref: "\(remote)/\(branch)",
                fetched: false,
                note: "The fetch failed (\(fetch.summary)), so the last fetched commit was used."
            )
        }
        // A base that is not a branch on the remote can be a local commit.
        if let base, let sha = try? await resolveCommit(base, in: checkout.root) {
            return TaskOperation.Base(sha: sha, ref: base, fetched: false)
        }
        throw TaskError("Toastty could not fetch \(remote)/\(branch): \(fetch.summary)")
    }

    private func localBase(_ checkout: TaskGitCheckout, base: String?) async throws -> TaskOperation.Base {
        if let base {
            guard let sha = try? await resolveCommit(base, in: checkout.root) else {
                throw TaskError("\(base) is not a commit in \(checkout.root).")
            }
            return TaskOperation.Base(sha: sha, ref: base, fetched: false)
        }
        let sha = try await resolveCommit("HEAD", in: checkout.root)
        let branch = try? await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: checkout.root)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskOperation.Base(sha: sha, ref: branch.flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD", fetched: false)
    }

    /// The branch the remote advertises as its HEAD now. Offline, the cached
    /// `<remote>/HEAD`, which can lag a changed default.
    private func defaultBranch(_ checkout: TaskGitCheckout, remote: String) async throws -> String {
        let advertised = try await git(["ls-remote", "--symref", remote, "HEAD"], in: checkout.root, allowFailure: true)
        if advertised.succeeded {
            for line in advertised.output.split(whereSeparator: \.isNewline) where line.hasPrefix("ref: refs/heads/") {
                let ref = line.dropFirst("ref: refs/heads/".count)
                if let end = ref.firstIndex(where: \.isWhitespace) {
                    return String(ref[..<end])
                }
            }
        }
        if let symbolic = try? await git(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"],
            in: checkout.root
        ).output.trimmingCharacters(in: .whitespacesAndNewlines),
           symbolic.hasPrefix("\(remote)/") {
            return String(symbolic.dropFirst(remote.count + 1))
        }
        for candidate in ["main", "master"] {
            if (try? await resolveCommit("refs/remotes/\(remote)/\(candidate)", in: checkout.root)) != nil {
                return candidate
            }
        }
        throw TaskError("Toastty could not find the default branch of \(remote). Pass --base <branch>.")
    }

    // MARK: - Worktree

    /// Free names for the worktree folder and its branch: `<repo>-<slug>`
    /// next to the main checkout, and `<prefix>/<slug>`, with `-2`, `-3`…
    /// added to both while either is taken here or on the remote. The
    /// remote's branches are listed once, now; offline, the last fetched
    /// ones stand in for them.
    func freeNames(_ checkout: TaskGitCheckout, slug: String, branchPrefix: String) async throws -> (path: String, branch: String) {
        let parent = (checkout.root as NSString).deletingLastPathComponent
        let repositoryName = (checkout.root as NSString).lastPathComponent
        let remoteBranches = try await remoteBranchNames(checkout)
        for number in 1...Self.maximumNameAttempts {
            let name = number == 1 ? slug : "\(slug)-\(number)"
            let path = (parent as NSString).appendingPathComponent("\(repositoryName)-\(name)")
            let branch = "\(branchPrefix)/\(name)"
            guard FileManager.default.fileExists(atPath: path) == false,
                  remoteBranches.contains(branch) == false,
                  try await localBranchIsFree(branch, checkout: checkout) else { continue }
            return (path, branch)
        }
        throw TaskError("Toastty could not find a free worktree name for \(slug).")
    }

    private func localBranchIsFree(_ branch: String, checkout: TaskGitCheckout) async throws -> Bool {
        let format = try await git(["check-ref-format", "--branch", branch], in: checkout.root, allowFailure: true)
        guard format.succeeded else {
            throw TaskError("\(branch) is not a valid branch name.")
        }
        return try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: checkout.root, allowFailure: true)
            .succeeded == false
    }

    private func remoteBranchNames(_ checkout: TaskGitCheckout) async throws -> Set<String> {
        guard let remote = checkout.remote else { return [] }
        let listed = try await git(["ls-remote", "--heads", remote], in: checkout.root, allowFailure: true)
        if listed.succeeded {
            return Set(listed.output.split(whereSeparator: \.isNewline).compactMap { line in
                line.split(separator: "\t").last.flatMap { ref in
                    ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : nil
                }
            })
        }
        let cached = try await git(
            ["for-each-ref", "--format=%(refname:lstrip=3)", "refs/remotes/\(remote)/"],
            in: checkout.root
        )
        return Set(cached.output.split(whereSeparator: \.isNewline).map(String.init))
    }

    func addWorktree(_ checkout: TaskGitCheckout, path: String, branch: String, sha: String) async throws {
        _ = try await git(["worktree", "add", "--quiet", "-b", branch, path, sha], in: checkout.root)
    }

    /// Whether `path` is a worktree of the repository on `branch`: what an
    /// add that finished before a crash left behind.
    func isWorktree(path: String, branch: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let result = try? await git(["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"], in: path) else {
            return false
        }
        let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 2 else { return false }
        let top = URL(filePath: lines[0]).resolvingSymlinksInPath().path(percentEncoded: false)
        let expected = URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
        return Self.trimmedDirectory(top) == Self.trimmedDirectory(expected) && lines[1] == branch
    }

    // MARK: - Hook

    /// Runs `create_hook` with `/bin/sh -c` in the worktree. Fails with the
    /// last lines of its output when it exits non-zero or times out.
    func runHook(
        _ hook: String,
        worktree: TaskOperation.Worktree,
        base: TaskOperation.Base?,
        taskID: UUID,
        slug: String,
        projectRoot: String
    ) async throws {
        var variables = [
            "TOASTTY_TASK_ID": taskID.uuidString,
            "TOASTTY_TASK_SLUG": slug,
            "TOASTTY_TASK_BRANCH": worktree.branch,
            "TOASTTY_TASK_WORKTREE": worktree.path,
            "TOASTTY_TASK_REPO_ROOT": projectRoot,
        ]
        variables["TOASTTY_TASK_BASE_REF"] = base?.sha
        var environment = environment()
        environment.merge(variables) { _, new in new }
        let result = await runner.run(TaskCommand(
            executablePath: "/bin/sh",
            arguments: ["-c", hook],
            directory: worktree.path,
            environment: environment,
            timeout: hookTimeout
        ))
        let tail = Self.lastLines(result.stdoutText + "\n" + result.stderrText)
        switch result.termination {
        case .exited(0):
            return
        case .exited(let status):
            throw TaskError("create_hook exited with status \(status)." + (tail.isEmpty ? "" : "\n\(tail)"))
        case .signaled(let signal):
            throw TaskError("create_hook stopped on signal \(signal)." + (tail.isEmpty ? "" : "\n\(tail)"))
        case .timedOut:
            throw TaskError("create_hook did not finish within \(Int(hookTimeout / 60)) minutes.")
        case .cancelled:
            throw CancellationError()
        case .launchFailed(let message):
            throw TaskError("create_hook did not start: \(message)")
        }
    }

    // MARK: - Git

    struct GitResult {
        var succeeded: Bool
        var output: String
        /// The last line of stderr, or why the command did not run.
        var summary: String
    }

    @discardableResult
    func git(_ arguments: [String], in directory: String, allowFailure: Bool = false) async throws -> GitResult {
        let result = await runner.run(TaskCommand(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory] + arguments,
            directory: directory,
            environment: environment(),
            timeout: gitTimeout
        ))
        let summary: String
        let succeeded: Bool
        switch result.termination {
        case .exited(let status):
            succeeded = status == 0
            let last = result.stderrText.split(whereSeparator: \.isNewline).last.map(String.init)
            summary = last?.trimmingCharacters(in: .whitespaces) ?? "exit status \(status)"
        case .signaled(let signal):
            succeeded = false
            summary = "git stopped on signal \(signal)"
        case .timedOut:
            succeeded = false
            summary = "git \(arguments.first ?? "") did not finish within \(Int(gitTimeout)) seconds"
        case .cancelled:
            throw CancellationError()
        case .launchFailed(let message):
            succeeded = false
            summary = message
        }
        let gitResult = GitResult(succeeded: succeeded, output: result.stdoutText, summary: summary)
        if succeeded == false, allowFailure == false {
            throw TaskError("git \(arguments.first ?? "") failed: \(summary)")
        }
        return gitResult
    }

    private func resolveCommit(_ ref: String, in directory: String) async throws -> String {
        let sha = try await git(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(ref)^{commit}"], in: directory)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.isEmpty == false else { throw TaskError("\(ref) is not a commit.") }
        return sha
    }

    // MARK: - Helpers

    static let maximumRefArgumentLength = 200

    /// A ref passed to git as an argument: no option-like dash, spaces, or
    /// control characters.
    static func validateRefArgument(_ value: String, name: String) throws {
        guard value.isEmpty == false,
              value.count <= maximumRefArgumentLength,
              value.hasPrefix("-") == false,
              value.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }) else {
            throw TaskError("\(name) must be a branch name or commit without spaces that does not start with a dash.")
        }
    }

    private static func looksLikeCommitID(_ value: String) -> Bool {
        (7...40).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }

    private static func trimmedDirectory(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The last non-empty lines of a command's output, for a failure reason.
    static func lastLines(_ output: String, count: Int = 12, maximumCharacters: Int = 1500) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
            .suffix(count)
        let joined = lines.joined(separator: "\n")
        return joined.count > maximumCharacters ? "…" + joined.suffix(maximumCharacters - 1) : joined
    }

    /// The login shell's PATH, resolved once: an app started from the
    /// Finder does not see Homebrew's git or the user's hook tools.
    enum LoginPath {
        private static let cache = Cache()

        static func value() -> String? { cache.value() }

        private final class Cache: @unchecked Sendable {
            private let lock = NSLock()
            private var resolved = false
            private var path: String?

            func value() -> String? {
                lock.withLock {
                    if resolved == false {
                        path = ManagedAgentBasePathResolver().resolve()
                        resolved = true
                    }
                    return path
                }
            }
        }
    }
}
