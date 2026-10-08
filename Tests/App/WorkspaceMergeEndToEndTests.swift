import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Runs Merge and Clean and Close Without Merging for real: the live command
/// runner, the pull request script bundled in the app, the `toastty` CLI
/// from the app bundle, and an automation socket server bound to the store.
/// Git works on a disposable repository with a local bare origin, and a fake
/// `gh` reports the pull request in a given state and records merges.
@MainActor
struct WorkspaceMergeEndToEndTests: AutomationSocketServerTestSupport {
    @Test
    func mergeAndCleanMergesThePullRequestThenClosesTheWorkspaceAndRemovesTheWorktree() async throws {
        try await withScenario(pullRequestState: "OPEN") { scenario in
            // The script calls back into this test's socket server; the main
            // actor stays free while it runs.
            await scenario.coordinator.merge(
                workspaceID: scenario.taskWorkspaceID,
                pullRequest: scenario.pullRequest,
                repoPath: scenario.worktree,
                thenCleanUp: true
            )?.value
            #expect(scenario.failureAlerts.isEmpty, "\(scenario.failureAlerts)")
            #expect(FileManager.default.fileExists(atPath: scenario.mergedPullRequestMarker))

            // The first check after the merge finds it merged and cleans up.
            for _ in 0..<600 where scenario.sessionRuntimeStore.workspaceMergeRequests[scenario.taskWorkspaceID] != nil {
                try await Task.sleep(for: .milliseconds(50))
            }

            #expect(scenario.sessionRuntimeStore.workspaceMergeRequests[scenario.taskWorkspaceID] == nil)
            #expect(scenario.notifications.count == 1)
            #expect(
                scenario.notifications.first?.hasPrefix("Cleaned up PR #7: task-7: closed task-7") == true,
                "\(scenario.notifications)"
            )
            #expect(scenario.store.state.workspacesByID[scenario.taskWorkspaceID] == nil)
            #expect(scenario.store.state.workspacesByID[scenario.parentWorkspaceID] != nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            let localBranch = try git(["branch", "--list", "task-7"], in: scenario.repo)
            let remoteBranch = try git(["ls-remote", "--heads", "origin", "task-7"], in: scenario.repo)
            #expect(localBranch.isEmpty)
            #expect(remoteBranch.isEmpty)
        }
    }

    @Test
    func closeWithoutMergingClosesThePullRequestAndCleansUpButKeepsTheRemoteBranch() async throws {
        try await withScenario(pullRequestState: "OPEN") { scenario in
            // Close Without Merging needs no done mark.
            await scenario.coordinator.closeWithoutMerging(
                workspaceID: scenario.taskWorkspaceID,
                pullRequest: scenario.pullRequest,
                repoPath: scenario.worktree
            )?.value

            #expect(scenario.sessionRuntimeStore.workspaceMergeRequests[scenario.taskWorkspaceID] == nil)
            #expect(scenario.failureAlerts.isEmpty, "\(scenario.failureAlerts)")
            #expect(
                scenario.notifications.first?.hasPrefix("Closed PR #7 without merging: task-7: closed PR #7; closed task-7") == true,
                "\(scenario.notifications)"
            )
            #expect(FileManager.default.fileExists(atPath: scenario.closedPullRequestMarker))
            #expect(FileManager.default.fileExists(atPath: scenario.mergedPullRequestMarker) == false)
            #expect(scenario.store.state.workspacesByID[scenario.taskWorkspaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            let localBranch = try git(["branch", "--list", "task-7"], in: scenario.repo)
            let remoteBranch = try git(["ls-remote", "--heads", "origin", "task-7"], in: scenario.repo)
            #expect(localBranch.isEmpty)
            #expect(remoteBranch.isEmpty == false)
        }
    }

    @MainActor
    private final class Scenario {
        let repo: String
        let worktree: String
        let closedPullRequestMarker: String
        let mergedPullRequestMarker: String
        let pullRequest = WorkspacePullRequestLink(annotationURL: "https://github.com/test/repo/pull/7")!
        let store: AppStore
        let sessionRuntimeStore: SessionRuntimeStore
        let parentWorkspaceID: UUID
        let taskWorkspaceID: UUID
        var coordinator: WorkspaceMergeCoordinator!
        var notifications: [String] = []
        var failureAlerts: [String] = []

        init(
            repo: String,
            worktree: String,
            closedPullRequestMarker: String,
            mergedPullRequestMarker: String,
            store: AppStore,
            sessionRuntimeStore: SessionRuntimeStore,
            parentWorkspaceID: UUID,
            taskWorkspaceID: UUID
        ) {
            self.repo = repo
            self.worktree = worktree
            self.closedPullRequestMarker = closedPullRequestMarker
            self.mergedPullRequestMarker = mergedPullRequestMarker
            self.store = store
            self.sessionRuntimeStore = sessionRuntimeStore
            self.parentWorkspaceID = parentWorkspaceID
            self.taskWorkspaceID = taskWorkspaceID
        }
    }

    /// A pushed task branch in its own worktree, a task subspace whose
    /// terminal sits in that worktree, and a coordinator wired to the real
    /// script, CLI, and socket.
    private func withScenario(
        pullRequestState: String,
        _ body: (Scenario) async throws -> Void
    ) async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("toastty-cleanup-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let origin = root.appendingPathComponent("origin.git").path
        let repo = root.appendingPathComponent("repo").path
        let worktree = root.appendingPathComponent("task-7").path
        try git(["init", "--bare", "-q", "-b", "main", origin], in: root.path)
        try git(["clone", "-q", origin, repo], in: root.path)
        try git(["config", "user.name", "Cleanup Test"], in: repo)
        try git(["config", "user.email", "cleanup@example.invalid"], in: repo)
        _ = try commit("base", in: repo)
        try git(["push", "-q", "origin", "main"], in: repo)
        try git(["worktree", "add", "-q", "-b", "task-7", worktree], in: repo)
        let head = try commit("task", in: worktree)
        try git(["push", "-q", "-u", "origin", "task-7"], in: worktree)

        let fakeBin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let pullRequest: [String: Any] = [
            "number": 7, "title": "task", "state": pullRequestState, "isDraft": false, "headRefName": "task-7",
            "headRefOid": head, "baseRefName": "main", "isCrossRepository": false,
            "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "url": "https://github.com/test/repo/pull/7",
            "statusCheckRollup": [], "body": "",
        ]
        var mergedPullRequest = pullRequest
        mergedPullRequest["state"] = "MERGED"
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let closedPullRequestMarker = root.appendingPathComponent("pr-7-closed").path
        let mergedPullRequestMarker = root.appendingPathComponent("pr-7-merged").path
        let fakeGh = fakeBin.appendingPathComponent("gh")
        // `pr view` takes the number from the script and the URL from the
        // coordinator's check.
        try """
        #!/bin/sh
        case "$1 $2" in
          "repo view") echo '{"nameWithOwner":"test/repo","defaultBranchRef":{"name":"main"},"mergeCommitAllowed":true}' ;;
          "pr view") if [ -e '\(mergedPullRequestMarker)' ]; then echo '\(try json(mergedPullRequest))'; else echo '\(try json(pullRequest))'; fi ;;
          "api --method") [ "$3 $4 $6 $8" = 'PUT repos/test/repo/pulls/7/merge sha=\(head) merge_method=merge' ] && touch '\(mergedPullRequestMarker)' ;;
          "pr close") [ "$3" = 7 ] && touch '\(closedPullRequestMarker)' ;;
          *) echo "unexpected gh call: $*" >&2; exit 1 ;;
        esac
        """.write(to: fakeGh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGh.path)

        let socketPath = temporarySocketPath()
        let (server, store, _, parentWorkspaceID, sessionRuntimeStore) = try makeServer(socketPath: socketPath)
        defer { withExtendedLifetime(server) {} }
        try waitForSocket(at: socketPath)

        let windowID = try #require(store.state.windows.first?.id)
        let existingWorkspaceIDs = Set(store.state.workspacesByID.keys)
        store.send(.createWorkspace(windowID: windowID, title: "task-7", activate: false))
        let taskWorkspaceID = try #require(Set(store.state.workspacesByID.keys).subtracting(existingWorkspaceIDs).first)
        store.send(.setWorkspaceParent(workspaceID: taskWorkspaceID, parentWorkspaceID: parentWorkspaceID, spawningSessionID: nil))
        let taskPanelID = try #require(store.state.workspacesByID[taskWorkspaceID]?.focusedPanelID)
        store.send(.updateTerminalPanelMetadata(panelID: taskPanelID, title: nil, cwd: worktree))
        store.send(.setWorkspaceAnnotation(
            workspaceID: taskWorkspaceID,
            key: "github-pr",
            annotation: try #require(WorkspaceAnnotation.validated(text: "PR #7", url: "https://github.com/test/repo/pull/7"))
        ))

        let cliPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/toastty").path
        #expect(FileManager.default.isExecutableFile(atPath: cliPath))
        let scenario = Scenario(
            repo: repo,
            worktree: worktree,
            closedPullRequestMarker: closedPullRequestMarker,
            mergedPullRequestMarker: mergedPullRequestMarker,
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            parentWorkspaceID: parentWorkspaceID,
            taskWorkspaceID: taskWorkspaceID
        )
        scenario.coordinator = WorkspaceMergeCoordinator(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            runner: WorkspaceMergeLiveCommandRunner(
                socketPath: socketPath,
                cliExecutablePath: cliPath,
                pathOverride: "\(fakeBin.path):/usr/bin:/bin"
            ),
            userDefaults: nil,
            notify: { [scenario] title, body in scenario.notifications.append("\(title): \(body)") },
            presentFailure: { [scenario] title, message in scenario.failureAlerts.append("\(title): \(message)") }
        )
        try await body(scenario)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: directory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ message: String, in directory: String) throws -> String {
        try "\(message)\n".write(toFile: "\(directory)/file.txt", atomically: true, encoding: .utf8)
        try git(["add", "file.txt"], in: directory)
        try git(["commit", "-q", "-m", message], in: directory)
        return try git(["rev-parse", "HEAD"], in: directory)
    }
}
