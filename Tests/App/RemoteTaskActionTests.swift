import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// Task actions from a phone: the Merge control and action list the Mac
/// sends, and the runner that checks each request against the Mac's current
/// list before it calls the same coordinator paths as the Mac's buttons.
/// The real reducer, store, coordinator and git, with the start-work
/// fixture's fake launcher and sessions in place of agents.
@MainActor
struct RemoteTaskActionTests {
    typealias Fixture = TaskStartWorkTests.Fixture

    private let pullRequestURL = "https://github.com/example/project/pull/7"

    /// A coordinator with a task board, the projection the service uses,
    /// and the runner.
    @MainActor
    final class Harness {
        let coordinator: TaskCoordinator
        let store: AppStore
        let board: TaskBoardStore
        var mergeRequests: [UUID: WorkspaceMergeRequest] = [:]
        /// Answers whether the device may still act; counts each check.
        var deviceMayAct: (Int) -> Bool = { _ in true }
        var permissionChecks = 0
        /// Answers whether the device may still start a release.
        var deviceMayRelease = true
        private(set) var runner: RemoteTaskActionRunner!

        init(coordinator: TaskCoordinator, store: AppStore, sessionRuntimeStore: SessionRuntimeStore) {
            self.coordinator = coordinator
            self.store = store
            board = TaskBoardStore(
                coordinator: coordinator,
                store: store,
                sessionRuntimeStore: sessionRuntimeStore,
                pullRequests: PullRequestStateCache(runner: NoGitHub()),
                refreshInterval: nil,
                releaseCheckInterval: nil
            )
            runner = RemoteTaskActionRunner(
                coordinator: { [unowned self] in self.coordinator },
                deviceMayAct: { [unowned self] _ in
                    permissionChecks += 1
                    return deviceMayAct(permissionChecks)
                },
                deviceMayRelease: { [unowned self] _ in deviceMayRelease },
                currentTask: { [unowned self] taskID in current(taskID) }
            )
        }

        var context: RemoteTaskBoardProjection.Context {
            RemoteTaskBoardProjection.Context(
                state: store.state,
                mergeRequest: { [unowned self] in mergeRequests[$0] }
            )
        }

        /// As the service reads releases.
        var releaseContext: RemoteTaskBoardProjection.Context {
            var context = context
            context.canRelease = { [board] in board.canRelease($0) }
            context.releaseUnderWay = { [coordinator] in coordinator.releaseUnderWay(projectRoot: $0)?.id }
            return context
        }

        func item(_ taskID: UUID) throws -> TaskBoardItem {
            try #require(board.items().first { $0.id == .task(taskID) })
        }

        func current(_ taskID: UUID) -> (item: TaskBoardItem, summary: RemoteTaskSummary)? {
            guard let item = board.items().first(where: { $0.id == .task(taskID) }) else { return nil }
            return (item, RemoteTaskBoardProjection.summary(item, context: context))
        }

        func perform(
            _ action: RemoteTaskAction,
            _ taskID: UUID,
            id: String,
            pullRequest: Int? = nil,
            closePullRequest: Bool = false
        ) async -> RemoteTaskActionResult {
            await runner.perform(
                RemoteTaskActionRequest(
                    taskID: taskID,
                    action: action,
                    clientRequestID: id,
                    expectedPullRequestNumber: pullRequest,
                    closePullRequest: closePullRequest
                ),
                device: Self.device
            )
        }

        func release(_ workspaceID: UUID, id: String) -> RemoteProjectReleaseResult {
            runner.release(RemoteProjectReleaseRequest(workspaceID: workspaceID, clientRequestID: id), device: Self.device)
        }

        static let device = RemoteDeviceRecord(
            name: "Phone",
            scopes: [.read, .send],
            taskActionsEnabled: true,
            authKind: .native,
            tailscaleLogin: "owner@example.com",
            createdAt: Date()
        )
    }

    /// The start-work fixture: real git worktrees, fake sessions that the
    /// board does not see.
    private func worktreeHarness() throws -> (Fixture, Harness) {
        let fixture = try Fixture()
        let sessionRuntimeStore = SessionRuntimeStore(sendSessionStatusNotification: { _, _, _, _, _ in })
        sessionRuntimeStore.bind(store: fixture.store)
        return (fixture, Harness(coordinator: fixture.coordinator, store: fixture.store, sessionRuntimeStore: sessionRuntimeStore))
    }

    /// A task that started in its own worktree, whose agent is at rest, with
    /// its pull request linked on the task space.
    private func taskInWorktree(_ fixture: Fixture, linkPullRequest: Bool = true) async throws -> TaskRecord {
        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "Fix the composer",
            workspaceID: fixture.workspaceID,
            agent: "claude",
            startWork: true
        ))
        await fixture.waitUntil("setup ends") { fixture.record(created.id)?.setup != .settingUp }
        let task = try #require(fixture.record(created.id))
        #expect(task.setup == .started)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        fixture.sessions.report(session, .ready, at: Date().addingTimeInterval(-60))
        if linkPullRequest {
            fixture.store.send(.setWorkspaceAnnotation(
                workspaceID: try #require(task.taskSpaceWorkspaceID),
                key: "github-pr",
                annotation: try #require(WorkspaceAnnotation.validated(text: "PR #7", url: pullRequestURL))
            ))
        }
        return task
    }

    private func reason(_ result: RemoteTaskActionResult) -> RemoteTaskActionRejectionReason? {
        if case .rejected(let reason, _) = result { return reason }
        return nil
    }

    private func git(_ arguments: [String], in directory: String) throws -> String {
        try TaskGitTestRepository.git(arguments, in: directory)
    }

    // MARK: - Merge control

    @Test func theMergeControlShowsTheMacTopBarState() async throws {
        let (fixture, harness) = try worktreeHarness()
        let task = try await taskInWorktree(fixture)
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        let link = try #require(WorkspacePullRequestLink(annotationURL: pullRequestURL))
        func control(_ item: TaskBoardItem, phase: WorkspaceMergeRequest.Phase? = nil) -> RemoteTaskMergeControl? {
            harness.mergeRequests[taskSpace] = phase.map { WorkspaceMergeRequest(pullRequest: link, repoPath: "/tmp", phase: $0) }
            return RemoteTaskBoardProjection.mergeControl(item, context: harness.context)
        }
        let merge = RemoteTaskActionItem(action: .merge, title: "Merge PR #7")
        let archive = RemoteTaskActionItem(action: .archive, title: "Archive Task…")
        var item = try harness.item(task.id)

        // Ready: tap merges; the menu archives. Merge Without Checks stays
        // on the Mac.
        item.pullRequestState = TaskPullRequestState(state: .open)
        #expect(control(item) == RemoteTaskMergeControl(kind: .merge, title: "Merge PR #7", action: merge, menu: [archive]))

        // GitHub reports a blocker: tap opens the pull request, the menu
        // still merges.
        item.pullRequestState = TaskPullRequestState(state: .open, isDraft: true)
        #expect(control(item) == RemoteTaskMergeControl(
            kind: .openPullRequest, title: "Open PR #7", detail: PullRequestMergeBlocker.draft.label, menu: [merge, archive]
        ))

        // The agent checks: Cancel Merge, as the Tasks view offers.
        item.pullRequestState = TaskPullRequestState(state: .open)
        item.merge = .checking
        #expect(control(item) == RemoteTaskMergeControl(
            kind: .merging, title: "Merging PR #7…", menu: [RemoteTaskActionItem(action: .cancelMerge, title: "Cancel Merge")]
        ))
        // Toastty runs the merge script: nothing to cancel.
        item.merge = .merging
        #expect(control(item, phase: .merging(thenCleanUp: true)) == RemoteTaskMergeControl(kind: .merging, title: "Merging PR #7…"))
        item.merge = .cleaningUp
        #expect(control(item, phase: .cleaningUp)?.title == "Cleaning Up PR #7…")

        // A stopped cleanup.
        item.merge = nil
        #expect(control(item, phase: .failed(reason: "the worktree has changes")) == RemoteTaskMergeControl(
            kind: .cleanupStopped,
            title: "Cleanup Stopped · PR #7",
            detail: "the worktree has changes",
            menu: [
                RemoteTaskActionItem(action: .cleanUp, title: "Clean Up"),
                RemoteTaskActionItem(action: .keepAsIs, title: "Keep As Is"),
            ]
        ))

        // Merged with its task space still open.
        item.record?.mergedAt = Date()
        #expect(control(item) == RemoteTaskMergeControl(kind: .done, title: "Done · PR #7", menu: [archive]))

        // Without a pull request, the task's own control.
        item.record?.mergedAt = nil
        fixture.store.send(.clearWorkspaceAnnotation(workspaceID: taskSpace, key: "github-pr"))
        item.stage = .needsYou(.readyForReview)
        #expect(control(item) == RemoteTaskMergeControl(
            kind: .completeTask, title: "Complete Task", action: RemoteTaskActionItem(action: .markDone, title: "Complete Task")
        ))
        item.stage = .done
        #expect(control(item) == RemoteTaskMergeControl(kind: .done, title: "Done", menu: [archive]))
        item.stage = .idle
        #expect(control(item) == RemoteTaskMergeControl(kind: .archive, title: "Archive Task…", action: archive))

        // A task whose task space closed has no control.
        item.taskSpaceWorkspaceID = nil
        #expect(control(item) == nil)
    }

    @Test func theActionListIsTheMacMenuWithoutWhatStaysOnTheMac() async throws {
        let (fixture, harness) = try worktreeHarness()
        let task = try await taskInWorktree(fixture)
        let summary = try #require(harness.current(task.id)?.summary)
        // Merge Without Checks and the navigation items are left out.
        #expect(summary.actions == [
            RemoteTaskActionItem(action: .merge, title: "Merge"),
            RemoteTaskActionItem(action: .archive, title: "Archive…"),
        ])
        #expect(summary.mergeControl?.kind == .merge)

        let failed = TaskRecord(
            createdAt: Date(),
            text: "Split the parser",
            title: "Split the parser",
            slug: "split-the-parser",
            source: .cli,
            resolved: TaskFields(agent: "codex"),
            setup: .setupFailed(reason: "create_hook exited 1")
        )
        try fixture.coordinator.records.insert(failed)
        let failedSummary = try #require(harness.current(failed.id)?.summary)
        #expect(failedSummary.actions == [
            RemoteTaskActionItem(action: .retry, title: "Retry Setup"),
            RemoteTaskActionItem(action: .delete, title: "Delete Task"),
        ])
        #expect(failedSummary.mergeControl == nil)
    }

    // MARK: - Runner

    @Test func aRemoteMergeRunsOnceAndOnlyWhileTheMacOffersIt() async throws {
        // The coordinator fixture registers the agent's session with the
        // session runtime, so the board sees it work on the merge.
        let fixture = try TaskCoordinatorTests.Fixture()
        let harness = Harness(coordinator: fixture.coordinator, store: fixture.store, sessionRuntimeStore: fixture.sessionRuntimeStore)
        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "The unread dot stays on",
            workspaceID: fixture.workspaceID,
            agent: "codex",
            prompt: "Fix it."
        ))
        await fixture.waitForSetup(created.id)
        let task = try #require(fixture.record(created.id))
        fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: try #require(task.taskSpaceWorkspaceID),
            key: "github-pr",
            annotation: try #require(WorkspaceAnnotation.validated(text: "PR #7", url: pullRequestURL))
        ))

        // Mark Done is not offered while a pull request is open.
        #expect(reason(await harness.perform(.markDone, task.id, id: "done-1")) == .notOffered)
        // The phone showed another pull request.
        #expect(await harness.perform(.merge, task.id, id: "merge-0", pullRequest: 8)
            == .rejected(reason: .pullRequestChanged, message: "The task's pull request is now PR #7."))
        #expect(fixture.record(task.id)?.mergeRequestedAt == nil)

        #expect(await harness.perform(.merge, task.id, id: "merge-1", pullRequest: 7) == .performed)
        let requestedAt = try #require(fixture.record(task.id)?.mergeRequestedAt)

        // A retry of the same request runs nothing again: a second merge
        // would save a new request time.
        fixture.clock = Date().addingTimeInterval(120)
        #expect(await harness.perform(.merge, task.id, id: "merge-1", pullRequest: 7) == .performed)
        #expect(fixture.record(task.id)?.mergeRequestedAt == requestedAt)
        // The same ID for another action is refused, not run.
        #expect(await harness.perform(.cancelMerge, task.id, id: "merge-1") == .rejected(reason: .invalidRequest, message: nil))

        // A second tap from a stale snapshot: while the agent checks, the
        // Mac offers only Cancel Merge.
        let current = try #require(harness.current(task.id))
        #expect(current.item.merge == .checking)
        #expect(current.summary.mergeControl?.kind == .merging)
        #expect(current.summary.mergeControl?.menu.map(\.action) == [.cancelMerge])
        let stale = await harness.perform(.merge, task.id, id: "merge-2", pullRequest: 7)
        // The refusal carries the task's state now, for the phone to show.
        #expect(stale == .rejected(reason: .notOffered, message: current.summary.statusLine))
        #expect(fixture.record(task.id)?.mergeRequestedAt == requestedAt)

        #expect(await harness.perform(.cancelMerge, task.id, id: "cancel-1", pullRequest: 7) == .performed)
        #expect(fixture.record(task.id)?.mergeRequestedAt == nil)
        #expect(fixture.record(task.id)?.mergeCancelledAt != nil)
    }

    @Test(arguments: [false, true])
    func aPhoneRequestRunsThroughTheServicesGatewayOnlyWhileTheSwitchIsOn(legacyRecord: Bool) async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let runtimeHome = "/tmp/toastty-remote-task-actions-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: runtimeHome) }
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        // Pairing grants Task actions without a separate settings change.
        let devices = RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL)
        let offer = try devices.issueNativePairingOffer(gatewayURL: URL(string: "https://test.tailnet.ts.net")!, at: Date())
        guard case .paired(let device, let credential) = try devices.redeemNativePairingOffer(
            using: .qr(offerID: offer.id, secret: offer.qrPayload.secret),
            deviceName: "Test phone", tailscaleLogin: "owner@example.com", at: Date()
        ) else {
            Issue.record("Pairing failed")
            return
        }
        #expect(device.canActOnTasks)
        if legacyRecord {
            // Older versions omitted the field when Task actions was off.
            var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: runtimePaths.remoteAccessDevicesFileURL)) as? [String: Any])
            var records = try #require(saved["devices"] as? [[String: Any]])
            records[0].removeValue(forKey: "taskActionsEnabled")
            saved["devices"] = records
            try JSONSerialization.data(withJSONObject: saved).write(to: runtimePaths.remoteAccessDevicesFileURL)
        }

        let board = TaskBoardStore(
            coordinator: fixture.coordinator,
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            pullRequests: PullRequestStateCache(runner: NoGitHub()),
            refreshInterval: nil,
            releaseCheckInterval: nil
        )
        let server = SilentGatewayServer()
        var captured: RemoteGatewayRequestHandler?
        let service = RemoteAccessService(
            store: fixture.store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            taskBoard: board,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            terminalRuntimeRegistry: TerminalRuntimeRegistry(),
            runtimePaths: runtimePaths,
            port: 42_997,
            initiallyEnabled: false,
            pushConfiguration: nil,
            gatewayServerFactory: { handler in
                captured = handler
                return server
            }
        )
        service.setEnabled(true, persist: false)
        defer { service.setEnabled(false, persist: false) }
        server.onListenerReady?(42_997)
        let handler = try #require(captured)

        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "The unread dot stays on", workspaceID: fixture.workspaceID, agent: "codex", prompt: "Fix it."
        ))
        await fixture.waitForSetup(created.id)
        let task = try #require(fixture.record(created.id))
        fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: try #require(task.taskSpaceWorkspaceID),
            key: "github-pr",
            annotation: try #require(WorkspaceAnnotation.validated(text: "PR #7", url: pullRequestURL))
        ))
        // The snapshot a phone gets offers Merge.
        let offered = try #require(service.facadeSessionList(at: .now).tasks?.tasks.first { $0.id == task.id })
        #expect(offered.mergeControl?.kind == .merge)

        func send(_ action: RemoteTaskAction, id: String) async throws -> RemoteTaskActionResult {
            let request = RemoteTaskActionRequest(taskID: task.id, action: action, clientRequestID: id, expectedPullRequestNumber: 7)
            let outcome = handler.handle(RemoteGatewayHTTPRequest(
                method: "POST",
                path: RemoteTaskActionPolicy.actionPath,
                headers: ["authorization": "Bearer \(credential)", "tailscale-user-login": "owner@example.com"],
                body: try ConversationEventCoding.makeEncoder().encode(request)
            ), at: .now)
            let response: RemoteGatewayHTTPResponse
            switch outcome {
            case .deferredTaskAction(let deviceID, let deferred):
                response = await handler.resolveTaskAction(deviceID: deviceID, request: deferred)
            case .respond(let answer):
                response = answer
            default:
                throw CocoaError(.coderInvalidValue)
            }
            return try ConversationEventCoding.makeDecoder().decode(RemoteTaskActionResponse.self, from: response.body).result
        }

        #expect(try await send(.merge, id: "merge-1") == .performed)
        let requestedAt = try #require(fixture.record(task.id)?.mergeRequestedAt)
        #expect(service.facadeSessionList(at: .now).tasks?.tasks.first { $0.id == task.id }?.mergeControl?.kind == .merging)

        // Switched off on the Mac: nothing more runs.
        service.setDeviceTaskActions(false, for: device.id)
        let disabled = RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL)
        #expect(disabled.devices.first?.canActOnTasks == false)
        #expect(try await send(.cancelMerge, id: "cancel-1") == .rejected(reason: .permissionDenied, message: nil))
        #expect(fixture.record(task.id)?.mergeRequestedAt == requestedAt)
        // Back on, the same request runs.
        service.setDeviceTaskActions(true, for: device.id)
        let enabled = RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL)
        #expect(enabled.devices.first?.canActOnTasks == true)
        #expect(try await send(.cancelMerge, id: "cancel-1") == .performed)
        #expect(fixture.record(task.id)?.mergeRequestedAt == nil)
    }

    @Test func aRemoteArchiveNeverDiscardsChangesOrCommits() async throws {
        let (fixture, harness) = try worktreeHarness()
        let task = try await taskInWorktree(fixture)
        let worktree = try #require(task.worktree)
        try fixture.repository.commit("local only", in: worktree.path)
        try Data("draft".utf8).write(to: URL(filePath: worktree.path).appending(path: "notes.txt"))

        // Uncommitted changes block the archive on the phone.
        guard case .ready(let blocked) = await harness.runner.archiveCheck(RemoteTaskArchiveCheckRequest(taskID: task.id)) else {
            Issue.record("Expected an archive check")
            return
        }
        #expect(blocked.uncommittedFiles == 1)
        #expect(blocked.unpushedCommits == 1)
        #expect(blocked.closesTaskSpace && blocked.removesWorktree)
        #expect(blocked.pullRequest?.number == 7)
        #expect(blocked.blockedReason == "The worktree has 1 uncommitted file. Commit and push them, or archive on the Mac to discard them.")
        let refused = await harness.perform(.archive, task.id, id: "archive-1", pullRequest: 7)
        #expect(refused == .rejected(reason: .needsMac, message: blocked.blockedReason))
        #expect(fixture.record(task.id)?.archivedAt == nil)
        #expect(FileManager.default.fileExists(atPath: URL(filePath: worktree.path).appending(path: "notes.txt").path))

        // With the changes committed, the archive can run.
        try fixture.repository.commit("notes", in: worktree.path)

        // The device is switched off while git runs: the archive's last
        // check, after git, refuses it.
        harness.permissionChecks = 0
        harness.deviceMayAct = { check in check == 1 }
        #expect(await harness.perform(.archive, task.id, id: "archive-revoked", pullRequest: 7)
            == .rejected(reason: .permissionDenied, message: nil))
        #expect(harness.permissionChecks == 2)
        #expect(fixture.record(task.id)?.archivedAt == nil)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        harness.deviceMayAct = { _ in true }

        guard case .ready(let clean) = await harness.runner.archiveCheck(RemoteTaskArchiveCheckRequest(taskID: task.id)) else {
            Issue.record("Expected an archive check")
            return
        }
        #expect(clean.blockedReason == nil)
        #expect(clean.unpushedCommits == 2)
        #expect(await harness.perform(.archive, task.id, id: "archive-2", pullRequest: 7) == .performed)
        // The same ID with other options is not a retry, and gets no answer
        // that says it ran.
        #expect(await harness.perform(.archive, task.id, id: "archive-2", pullRequest: 7, closePullRequest: true)
            == .rejected(reason: .invalidRequest, message: nil))
        await fixture.waitUntil("the archive finishes") { fixture.record(task.id)?.cleanup?.finishedAt != nil }
        #expect(fixture.record(task.id)?.archivedAt != nil)
        #expect(fixture.record(task.id)?.cleanup?.archiveOptions == TaskArchiveOptions())
        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
        #expect(try git(["branch", "--list", worktree.branch], in: fixture.repository.project).isEmpty == false)

        // Archived, it offers nothing more.
        #expect(await harness.perform(.archive, task.id, id: "archive-3") == .rejected(reason: .notOffered, message: "Archived"))
        guard case .rejected(.notOffered, _) = await harness.runner.archiveCheck(RemoteTaskArchiveCheckRequest(taskID: task.id)) else {
            Issue.record("Expected the archive check to refuse")
            return
        }
    }

    @Test func aStoppedArchiveThatDiscardsWorkCleansUpOnlyOnTheMac() async throws {
        let (fixture, harness) = try worktreeHarness()
        let task = try await taskInWorktree(fixture, linkPullRequest: false)
        // An archive the Mac started to discard changes stopped partway.
        _ = fixture.coordinator.records.update(id: task.id) {
            $0.archivedAt = Date()
            $0.cleanup = TaskCleanup(
                kind: .archive,
                stepsDone: ["closed the task space"],
                problem: "git worktree remove failed",
                archiveOptions: TaskArchiveOptions(discardChanges: true)
            )
        }
        let summary = try #require(harness.current(task.id)?.summary)
        #expect(summary.actions.map(\.action) == [.cleanUp, .keepAsIs])
        let refused = await harness.perform(.cleanUp, task.id, id: "clean-1")
        #expect(reason(refused) == .needsMac)
        #expect(fixture.record(task.id)?.cleanup?.problem == "git worktree remove failed")
        #expect(FileManager.default.fileExists(atPath: try #require(task.worktree).path))
        // Keep As Is changes nothing on disk, so the phone may choose it.
        #expect(await harness.perform(.keepAsIs, task.id, id: "keep-1") == .performed)
        #expect(fixture.record(task.id)?.cleanup?.finishedAt != nil)
    }

    @Test func deleteAndRetryRunOnlyForATaskThatOffersThem() async throws {
        let (fixture, harness) = try worktreeHarness()
        let task = try await taskInWorktree(fixture, linkPullRequest: false)
        // A started task cannot be deleted from the phone.
        #expect(reason(await harness.perform(.delete, task.id, id: "delete-0")) == .notOffered)
        #expect(await harness.perform(.delete, UUID(), id: "delete-x") == .rejected(reason: .taskNotFound, message: nil))

        let failed = TaskRecord(
            createdAt: Date(),
            text: "Split the parser",
            title: "Split the parser",
            slug: "split-the-parser",
            source: .cli,
            resolved: TaskFields(agent: "codex"),
            setup: .setupFailed(reason: "create_hook exited 1")
        )
        try fixture.coordinator.records.insert(failed)
        #expect(await harness.perform(.delete, failed.id, id: "delete-1") == .performed)
        #expect(fixture.record(failed.id) == nil)
        // A retry after a lost answer finds the first result.
        #expect(await harness.perform(.delete, failed.id, id: "delete-1") == .performed)
        #expect(await harness.perform(.delete, failed.id, id: "delete-2") == .rejected(reason: .taskNotFound, message: nil))
    }

    // MARK: - Release

    /// A project with two merged tasks that wait for a release. With
    /// `canRelease`, tasks.toml gives it a release prompt that only echoes.
    private func releasingProject(_ fixture: Fixture, canRelease: Bool = true) throws -> [TaskRecord] {
        fixture.config.defaults = TasksConfig.Defaults(agent: "claude")
        fixture.config.workspaces = [TasksConfig.Workspace(
            path: fixture.repository.project,
            releaseTags: "v*",
            releasePrompt: canRelease ? "Echo the release plan; publish nothing." : nil
        )]
        let tip = try fixture.repository.pushToRemote("released")
        return try ["Fix the parser", "Fix the composer"].enumerated().map { index, title in
            var merged = TaskRecord(
                createdAt: Date(), text: title, title: title, slug: "merged-\(index)", source: .cli,
                workspaceID: fixture.workspaceID, projectRoot: fixture.repository.project, setup: .started
            )
            merged.pullRequestURL = "https://github.com/example/project/pull/\(index + 3)"
            merged.mergedAt = Date()
            merged.mergeCommit = tip
            try fixture.coordinator.records.insert(merged)
            return merged
        }
    }

    private func releases(_ fixture: Fixture) -> [TaskRecord] {
        fixture.coordinator.records.records.filter { $0.release != nil }
    }

    /// The phone's Release… reaches the same release as the Mac's button,
    /// once per request ID, one at a time, and only with the device's
    /// permissions.
    @Test func aPhoneStartsOneReleaseAndARepeatFindsIt() async throws {
        let (fixture, harness) = try worktreeHarness()
        let merged = try releasingProject(fixture)
        harness.board.reloadConfig()

        // A device without its Task actions switch or start permission
        // starts nothing.
        harness.deviceMayRelease = false
        #expect(harness.release(fixture.workspaceID, id: "release-1") == .rejected(reason: .permissionDenied, message: nil))
        #expect(releases(fixture).isEmpty)

        harness.deviceMayRelease = true
        guard case .started(let taskID) = harness.release(fixture.workspaceID, id: "release-1") else {
            Issue.record("Expected a release to start")
            return
        }
        let release = try #require(fixture.record(taskID))
        #expect(Set(try #require(release.release).childTaskIDs) == Set(merged.map(\.id)))
        #expect(release.source == .remoteDevice(deviceID: Harness.device.id))
        #expect(release.clientRequestID == "release-1")
        #expect(release.startWork?.detached == true)

        // A repeat after a lost answer finds the same release.
        #expect(harness.release(fixture.workspaceID, id: "release-1") == .started(taskID: taskID))
        #expect(releases(fixture).map(\.id) == [taskID])
        // A new request while it runs is refused and names it.
        guard case .rejected(.releaseUnderWay, let message?) = harness.release(fixture.workspaceID, id: "release-2") else {
            Issue.record("Expected a refusal while the release runs")
            return
        }
        #expect(message.contains(release.title))
        #expect(releases(fixture).count == 1)
        // The board shows the release under way on the project's lane.
        let lane = try #require(RemoteTaskBoardProjection.board(items: harness.board.items(), context: harness.releaseContext).toShip.first)
        #expect(lane.releaseWorkspaceID == fixture.workspaceID)
        #expect(lane.releaseTaskID == taskID)
        await fixture.waitUntil("setup ends") { fixture.record(taskID)?.setup != .settingUp }
    }

    @Test func aProjectThatCannotReleaseOrIsGoneRefusesTheRelease() async throws {
        let (fixture, harness) = try worktreeHarness()
        _ = try releasingProject(fixture, canRelease: false)
        harness.board.reloadConfig()
        // The phone words this one; the Mac's message names a local path.
        #expect(harness.release(fixture.workspaceID, id: "release-1") == .rejected(reason: .notReleasable, message: nil))
        #expect(harness.release(UUID(), id: "release-2") == .rejected(reason: .projectNotFound, message: nil))
        #expect(releases(fixture).isEmpty)
        // Without a release setting the lane offers no Release.
        let lane = try #require(RemoteTaskBoardProjection.board(items: harness.board.items(), context: harness.releaseContext).toShip.first)
        #expect(lane.releaseWorkspaceID == nil)
        #expect(lane.releaseTaskID == nil)
        #expect(lane.count == 2)
    }
}

/// A gateway that sends nothing anywhere, so the service runs without a
/// listener.
private final class SilentGatewayServer: RemoteAccessGatewayServing {
    var onWebSocketCountsChanged: ((RemoteAccessWebSocketCounts) -> Void)?
    var onDeviceRevoked: ((UUID) -> Void)?
    var onListenerReady: ((UInt16) -> Void)?
    var onListenerFailed: ((RemoteAccessListenerFailure) -> Void)?

    func start(port _: UInt16) throws {}
    func stop() {}
    func disconnectWebSockets(for _: UUID) {}
    func disconnectAllWebSockets() {}
    func broadcast(_: RemoteGatewayStreamMessage) {}
}

/// Answers no pull request question, so the board keeps what it has.
private struct NoGitHub: WorkspaceMergeCommandRunning {
    func run(arguments _: [String], directory _: String, timeout _: TimeInterval) async -> WorkspaceMergeCommandResult {
        WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "gh: not found", failure: nil)
    }
}
