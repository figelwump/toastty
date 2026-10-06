import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Runs Merge and Clean Up's cleanup for real: the live command runner, the
/// cleanup script bundled in the app, the `toastty` CLI from the app bundle,
/// and an automation socket server bound to the store. Git works on a
/// disposable repository with a local bare origin, and a fake `gh` reports
/// the pull request as merged.
@MainActor
struct WorkspaceCleanupEndToEndTests: AutomationSocketServerTestSupport {
    @Test
    func mergedPullRequestClosesTheWorkspaceRemovesTheWorktreeAndDeletesTheBranches() async throws {
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
            "number": 7, "title": "task", "state": "MERGED", "isDraft": false, "headRefName": "task-7",
            "headRefOid": head, "baseRefName": "main", "isCrossRepository": false,
            "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN", "url": "https://github.com/test/repo/pull/7",
            "statusCheckRollup": [], "body": "",
        ]
        let pullRequestJSON = String(decoding: try JSONSerialization.data(withJSONObject: pullRequest), as: UTF8.self)
        let fakeGh = fakeBin.appendingPathComponent("gh")
        try """
        #!/bin/sh
        case "$1 $2" in
          "repo view") echo '{"nameWithOwner":"test/repo","defaultBranchRef":{"name":"main"}}' ;;
          "pr view") echo '\(pullRequestJSON)' ;;
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
        var notifications: [String] = []
        let coordinator = WorkspaceCleanupCoordinator(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            runner: WorkspaceCleanupLiveCommandRunner(
                socketPath: socketPath,
                cliExecutablePath: cliPath,
                pathOverride: "\(fakeBin.path):/usr/bin:/bin"
            ),
            userDefaults: nil,
            notify: { title, body in notifications.append("\(title): \(body)") }
        )

        coordinator.requestCleanup(workspaceID: taskWorkspaceID, pullRequestNumber: 7, repoPath: worktree)
        store.send(.setWorkspaceDone(workspaceID: taskWorkspaceID, doneAt: Date()))

        // The script calls back into this test's socket server; the main
        // actor stays free while it runs.
        for _ in 0..<600 where sessionRuntimeStore.workspaceCleanupRequests[taskWorkspaceID] != nil {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(sessionRuntimeStore.workspaceCleanupRequests[taskWorkspaceID] == nil)
        #expect(notifications.count == 1)
        #expect(notifications.first?.hasPrefix("Cleaned up PR #7: task-7: closed task-7") == true, "\(notifications)")
        #expect(store.state.workspacesByID[taskWorkspaceID] == nil)
        #expect(store.state.workspacesByID[parentWorkspaceID] != nil)
        #expect(FileManager.default.fileExists(atPath: worktree) == false)
        #expect(try git(["branch", "--list", "task-7"], in: repo).isEmpty)
        #expect(try git(["ls-remote", "--heads", "origin", "task-7"], in: repo).isEmpty)
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
