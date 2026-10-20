import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// The git side of a task's worktree, against real repositories: which
/// commit a worktree starts from, how it is named, and the create hook.
struct TaskWorktreeCreatorTests {
    @Test func defaultBaseIsTheRemotesDefaultBranchFetchedNow() async throws {
        let repository = try TaskGitTestRepository()
        // The project's own main has a commit the remote does not, and the
        // remote moved on since the project last fetched.
        try repository.commit("local-only", in: repository.project)
        let remoteTip = try repository.pushToRemote("upstream")
        let creator = TaskGitTestRepository.creator()

        let checkout = try await creator.checkout(for: repository.project)
        let base = try await creator.pinBase(checkout, base: nil)

        #expect(checkout.remote == "origin")
        #expect(base == TaskOperation.Base(sha: remoteTip, ref: "origin/main", fetched: true))
    }

    @Test func namedBaseIsAFetchedRemoteBranchOrALocalCommit() async throws {
        let repository = try TaskGitTestRepository()
        let featureTip = try repository.pushToRemote("feature", branch: "feat/stack")
        let localCommit = try repository.commit("local", in: repository.project)
        let creator = TaskGitTestRepository.creator()
        let checkout = try await creator.checkout(for: repository.project)

        #expect(try await creator.pinBase(checkout, base: "feat/stack") ==
            TaskOperation.Base(sha: featureTip, ref: "origin/feat/stack", fetched: true))
        #expect(try await creator.pinBase(checkout, base: "origin/feat/stack") ==
            TaskOperation.Base(sha: featureTip, ref: "origin/feat/stack", fetched: true))
        #expect(try await creator.pinBase(checkout, base: localCommit) ==
            TaskOperation.Base(sha: localCommit, ref: localCommit, fetched: false))
        await #expect(throws: TaskError.self) {
            try await creator.pinBase(checkout, base: "no-such-branch")
        }
        await #expect(throws: TaskError.self) {
            try await creator.pinBase(checkout, base: "--upload-pack=touch /tmp/x")
        }
        // A refspec would write a local branch; it must fail before any fetch.
        await #expect(throws: TaskError.self) {
            try await creator.pinBase(checkout, base: "main:refs/heads/victim")
        }
        #expect(throws: TaskError.self) {
            try TaskGitTestRepository.git(["rev-parse", "--verify", "--quiet", "refs/heads/victim"], in: repository.project)
        }
    }

    @Test func defaultBaseFollowsARemoteWhoseDefaultBranchChanged() async throws {
        let repository = try TaskGitTestRepository()
        let trunkTip = try repository.pushToRemote("trunk", branch: "trunk")
        try TaskGitTestRepository.git(["symbolic-ref", "HEAD", "refs/heads/trunk"], in: repository.remote)
        let creator = TaskGitTestRepository.creator()
        let checkout = try await creator.checkout(for: repository.project)

        // The project's cached origin/HEAD still names main.
        #expect(try TaskGitTestRepository.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repository.project) == "origin/main")
        #expect(try await creator.pinBase(checkout, base: nil) == TaskOperation.Base(sha: trunkTip, ref: "origin/trunk", fetched: true))
    }

    @Test func failedFetchFallsBackToTheLastFetchedCommitWithANote() async throws {
        let repository = try TaskGitTestRepository()
        let lastFetched = try TaskGitTestRepository.git(["rev-parse", "origin/main"], in: repository.project)
        try TaskGitTestRepository.git(["remote", "set-url", "origin", repository.root.appendingPathComponent("gone.git").path], in: repository.project)
        let creator = TaskGitTestRepository.creator()
        let checkout = try await creator.checkout(for: repository.project)

        let base = try await creator.pinBase(checkout, base: nil)

        #expect(base.sha == lastFetched)
        #expect(base.fetched == false)
        #expect(base.note?.hasPrefix("The fetch failed") == true)
    }

    @Test func repositoryWithoutRemotesStartsFromItsHead() async throws {
        let repository = try TaskGitTestRepository()
        try TaskGitTestRepository.git(["remote", "remove", "origin"], in: repository.project)
        let head = try repository.commit("local", in: repository.project)
        let creator = TaskGitTestRepository.creator()
        let checkout = try await creator.checkout(for: repository.project)

        #expect(checkout.remote == nil)
        #expect(try await creator.pinBase(checkout, base: nil) == TaskOperation.Base(sha: head, ref: "main", fetched: false))
    }

    @Test func namesSkipFoldersAndBranchesThatAreTakenHereOrOnTheRemote() async throws {
        let repository = try TaskGitTestRepository()
        let creator = TaskGitTestRepository.creator()
        let checkout = try await creator.checkout(for: repository.project)
        let parent = repository.root.path

        let first = try await creator.freeNames(checkout, slug: "fix-it", branchPrefix: "fix")
        #expect(first.path == "\(parent)/project-fix-it")
        #expect(first.branch == "fix/fix-it")
        // A folder in the way, then a local branch, then a pushed branch.
        try FileManager.default.createDirectory(atPath: "\(parent)/project-fix-it", withIntermediateDirectories: false)
        try TaskGitTestRepository.git(["branch", "fix/fix-it-2"], in: repository.project)
        // Pushed by someone else and never fetched here.
        try repository.pushToRemote("pushed", branch: "fix/fix-it-3")

        let names = try await creator.freeNames(checkout, slug: "fix-it", branchPrefix: "fix")
        #expect(names.path == "\(parent)/project-fix-it-4")
        #expect(names.branch == "fix/fix-it-4")
    }

    @Test func addedWorktreeIsFoundAgainAfterACrash() async throws {
        let repository = try TaskGitTestRepository()
        let creator = TaskGitTestRepository.creator()
        let checkout = try await creator.checkout(for: repository.project)
        let base = try await creator.pinBase(checkout, base: nil)
        let path = repository.root.appendingPathComponent("project-crash").path

        try await creator.addWorktree(checkout, path: path, branch: "task/crash", sha: base.sha)

        #expect(await creator.isWorktree(path: path, branch: "task/crash"))
        #expect(await creator.isWorktree(path: path, branch: "task/other") == false)
        #expect(await creator.isWorktree(path: repository.project, branch: "task/crash") == false)
        #expect(try TaskGitTestRepository.git(["rev-parse", "HEAD"], in: path) == base.sha)
    }

    @Test func hookRunsInTheWorktreeWithTaskVariablesAndReportsItsLastLines() async throws {
        let repository = try TaskGitTestRepository()
        let creator = TaskGitTestRepository.creator()
        let worktree = TaskOperation.Worktree(path: repository.project, branch: "task/hook", checkoutRoot: repository.project, added: true)
        let base = TaskOperation.Base(sha: "abc123", ref: "origin/main", fetched: true)
        let taskID = UUID()

        try await creator.runHook(
            // A relative path: the file lands in the worktree only when the
            // hook runs there.
            "env | grep '^TOASTTY_' | sort > hook-env.txt",
            worktree: worktree,
            base: base,
            taskID: taskID,
            slug: "hook",
            projectRoot: "/projects/toastty"
        )
        let variables = try String(contentsOfFile: "\(repository.project)/hook-env.txt", encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(variables == [
            "TOASTTY_TASK_BASE_REF=abc123",
            "TOASTTY_TASK_BRANCH=task/hook",
            "TOASTTY_TASK_ID=\(taskID.uuidString)",
            "TOASTTY_TASK_REPO_ROOT=/projects/toastty",
            "TOASTTY_TASK_SLUG=hook",
            "TOASTTY_TASK_WORKTREE=\(repository.project)",
        ])

        // Long output keeps its end, where the error is.
        do {
            try await creator.runHook(
                "yes installing | head -c 400000; echo; echo 'error: tuist missing' >&2; exit 5",
                worktree: worktree, base: base, taskID: taskID, slug: "hook", projectRoot: "/p"
            )
            Issue.record("A failing hook must throw")
        } catch let error as TaskError {
            #expect(error.message.hasPrefix("create_hook exited with status 5."))
            #expect(error.message.hasSuffix("error: tuist missing"))
        }

        do {
            try await creator.runHook(
                "echo installing; echo 'error: tuist missing' >&2; exit 3",
                worktree: worktree, base: base, taskID: taskID, slug: "hook", projectRoot: "/p"
            )
            Issue.record("A failing hook must throw")
        } catch let error as TaskError {
            #expect(error.message == "create_hook exited with status 3.\ninstalling\nerror: tuist missing")
        }
    }

    @Test func commandsStillRunningAtQuitAreStoppedWithTheirChildren() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-task-quit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let childPIDFile = directory.appendingPathComponent("child.pid").path

        // Its own registry, so stopping does not reach commands that other
        // tests run at the same time.
        let groups = TaskCommandGroups()
        var runner = TaskLiveCommandRunner()
        runner.groups = groups
        let run = Task { [runner] in
            await runner.run(TaskCommand(
                executablePath: "/bin/sh",
                arguments: ["-c", "sleep 600 & echo $! > child.pid; wait"],
                directory: directory.path,
                environment: TaskGitTestRepository.environment,
                timeout: 600
            ))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while FileManager.default.fileExists(atPath: childPIDFile) == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let childPID = try #require(Int32(String(contentsOfFile: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        groups.stopAll()
        let result = await run.value

        #expect(result.termination != .exited(0))
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(childPID, 0) != 0, "The hook's child must not outlive the app")
    }
}
