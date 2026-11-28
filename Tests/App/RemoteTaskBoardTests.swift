import CoreState
import Foundation
import Network
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// The task board a phone gets in the session snapshot: the same stages,
/// words and Status groups as the Mac's sidebar, and a new snapshot when
/// only the board changed.
@MainActor
struct RemoteTaskBoardTests {
    private let pullRequestURL = "https://github.com/example/toastty/pull/124"

    @Test func theSnapshotCarriesEachTaskWithItsStageAndGroup() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let harness = try Harness(fixture)
        defer { harness.removeRuntimeFiles() }
        let untracked = try harness.makeUntrackedTaskSpace(title: "qa-mobile-navigation")
        _ = fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: untracked,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #124", url: pullRequestURL)
        ))
        let failed = TaskRecord(
            createdAt: Date(),
            text: "Fix the unread dot",
            title: "Fix the unread dot",
            slug: "fix-the-unread-dot",
            source: .cli,
            resolved: TaskFields(agent: "codex"),
            setup: .setupFailed(reason: "The agent did not start: profile missing")
        )
        try fixture.coordinator.records.insert(failed)

        var board = try #require(harness.service.facadeSessionList(at: .now).tasks)
        // A watched task space with a linked pull request waits for review.
        let watched = try #require(board.tasks.first { $0.id == untracked })
        #expect(watched.hasRecord == false)
        #expect(watched.taskSpaceWorkspaceID == untracked)
        #expect(watched.projectWorkspaceID == fixture.workspaceID)
        #expect(watched.projectTitle == "toastty")
        #expect(watched.group == .needsYou)
        #expect(watched.mark == .review)
        #expect(watched.statusLine == "Ready for your review")
        #expect(watched.stageTitle == "Review")
        #expect(watched.pullRequest == RemoteTaskPullRequest(number: 124, url: URL(string: pullRequestURL)!))
        // A task whose setup failed has no task space; its row says why.
        let setupFailed = try #require(board.tasks.first { $0.id == failed.id })
        #expect(setupFailed.hasRecord)
        #expect(setupFailed.taskSpaceWorkspaceID == nil)
        #expect(setupFailed.statusLine == "⚠ setup failed")
        #expect(setupFailed.rowSummary == "⚠ setup failed")
        #expect(setupFailed.stageReason == "The agent did not start: profile missing")
        #expect(Set(board.needsYou.map(\.taskID)) == [untracked, failed.id])
        #expect(board.doneCount == 0)

        // The done mark finishes it. Its task space is still open, so it
        // still lists, and its project counts it.
        _ = fixture.store.send(.setWorkspaceDone(workspaceID: untracked, doneAt: Date()))
        board = try #require(harness.service.facadeSessionList(at: .now).tasks)
        let done = try #require(board.tasks.first { $0.id == untracked })
        #expect(done.group == .done)
        #expect(done.mark == .done)
        #expect(board.needsYou.map(\.taskID) == [failed.id])
        #expect(board.doneCount == 1)
        #expect(board.finishedByProject == [
            RemoteTaskProjectTally(projectWorkspaceID: fixture.workspaceID, toShipCount: 0, doneCount: 1),
        ])
    }

    /// What the phone needs to draw families and To ship lines in project
    /// cards: each task's parent, also one the board leaves out because it
    /// is Done, a parent's "N/M merged", and the project of a lane's tasks.
    @Test func tasksCarryTheirParentAndChildProgress() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.config = TasksConfig(workspaces: [TasksConfig.Workspace(path: fixture.projectRoot, releaseTags: "v*")])
        let harness = try Harness(fixture)
        defer { harness.removeRuntimeFiles() }
        func insert(_ title: String, parent: UUID? = nil, change: (inout TaskRecord) -> Void = { _ in }) throws -> TaskRecord {
            var record = TaskRecord(
                createdAt: Date(), text: title, title: title, slug: title, source: .cli,
                resolved: TaskFields(agent: "codex"), workspaceID: fixture.workspaceID,
                projectRoot: fixture.projectRoot, setup: .started, parentTaskID: parent
            )
            change(&record)
            try fixture.coordinator.records.insert(record)
            return record
        }
        func merge(_ record: inout TaskRecord) {
            record.pullRequestURL = "https://github.com/example/toastty/pull/\(abs(record.id.hashValue) % 1000 + 200)"
            record.mergedAt = Date()
            record.mergeCommit = String(record.id.uuidString.prefix(12))
        }

        let finishedParent = try insert("Signup feedback") { $0.doneAt = Date() }
        let orphan = try insert("Copy fixes", parent: finishedParent.id)
        let parent = try insert("Billing rework")
        let merged = try insert("Billing API", parent: parent.id, change: merge)
        let open = try insert("Billing UI", parent: parent.id)
        _ = try insert("Billing spike", parent: parent.id) { $0.archivedAt = Date() }

        let board = try #require(harness.service.facadeSessionList(at: .now).tasks)
        func task(_ record: TaskRecord) throws -> RemoteTaskSummary {
            try #require(board.tasks.first { $0.id == record.id })
        }
        // A Done parent is not on the board, so its child names it.
        #expect(board.tasks.contains { $0.id == finishedParent.id } == false)
        #expect(try task(orphan).parentTaskID == finishedParent.id)
        #expect(try task(orphan).parentTaskTitle == "Signup feedback")
        #expect(try task(open).parentTaskID == parent.id)
        #expect(try task(open).parentTaskTitle == "Billing rework")
        // The archived child does not count; the merged one does.
        #expect(try task(parent).childProgress == RemoteTaskChildProgress(merged: 1, total: 2))
        #expect(try task(parent).parentTaskID == nil)
        #expect(try task(open).childProgress == nil)
        // The merged child waits for a release. Its lane's recent task
        // names the project, as a project card picks its To ship tasks.
        #expect(try task(merged).group == .toShip)
        #expect(try task(merged).parentTaskTitle == "Billing rework")
        let lane = try #require(board.toShip.first)
        #expect(lane.recentTaskIDs == [merged.id])
        #expect(try task(merged).projectWorkspaceID == fixture.workspaceID)
        #expect(board.finishedByProject.first { $0.projectWorkspaceID == fixture.workspaceID }?.toShipCount == 1)
    }

    /// Every To ship task travels, so a phone can list what a release
    /// ships.
    @Test func aLaneCarriesEveryToShipTask() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.config = TasksConfig(workspaces: [
            TasksConfig.Workspace(path: fixture.projectRoot, releaseTags: "v*", releasePrompt: "Echo the release plan."),
        ])
        let harness = try Harness(fixture)
        defer { harness.removeRuntimeFiles() }
        var merged: [TaskRecord] = []
        for index in 0..<5 {
            var record = TaskRecord(
                createdAt: Date(), text: "Merged \(index)", title: "Merged \(index)", slug: "merged-\(index)", source: .cli,
                resolved: TaskFields(agent: "codex"), workspaceID: fixture.workspaceID,
                projectRoot: fixture.projectRoot, setup: .started
            )
            record.pullRequestURL = "https://github.com/example/toastty/pull/\(300 + index)"
            // Each later task merged later.
            record.mergedAt = Date(timeIntervalSinceNow: Double(index - 10) * 60)
            record.mergeCommit = "abc\(index)"
            try fixture.coordinator.records.insert(record)
            merged.append(record)
        }
        let board = try #require(harness.service.facadeSessionList(at: .now).tasks)
        let lane = try #require(board.toShip.first)
        let newestFirst = merged.reversed().map(\.id)
        #expect(lane.count == 5)
        // An older phone still reads the newest few.
        #expect(lane.recentTaskIDs == Array(newestFirst.prefix(3)))
        #expect(lane.taskIDs == newestFirst)
        #expect(Set(board.tasks.map(\.id)).isSuperset(of: newestFirst))
    }

    @Test func aChangeOnlyTheBoardSeesSendsANewSnapshot() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let harness = try Harness(fixture)
        defer { harness.removeRuntimeFiles() }
        try await harness.waitForSnapshot { _ in true }
        harness.server.removeAllBroadcasts()

        // A record alone changes no workspace or session, so only the board
        // subscription can send it.
        let record = TaskRecord(
            createdAt: Date(),
            text: "Billing page shows the old plan",
            title: "Billing page shows the old plan",
            slug: "billing-page",
            source: .cli,
            resolved: TaskFields(agent: "codex"),
            setup: .needsWorkspace(reason: "None of the open workspaces has a billing page.")
        )
        try fixture.coordinator.records.insert(record)
        let snapshot = try await harness.waitForSnapshot { snapshot in
            snapshot.tasks?.needsYou.contains { $0.taskID == record.id } == true
        }
        #expect(snapshot.tasks?.tasks.first { $0.id == record.id }?.statusLine == "⚠ pick a workspace")

        // A board change that alters nothing a client sees sends nothing.
        harness.server.removeAllBroadcasts()
        harness.board.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.server.sessionListSnapshots.isEmpty)
    }

    @Test func agentActivityUpdatesTheLinkedTaskInTheSessionList() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let harness = try Harness(fixture)
        defer { harness.removeRuntimeFiles() }
        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "Check the build",
            workspaceID: fixture.workspaceID,
            agent: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            prompt: "Check the build."
        ))
        await fixture.waitForSetup(created.id)
        let sessionID = try #require(fixture.record(created.id)?.currentSessionID)

        // A task starts with its first prompt. Until the agent reports that
        // turn, an idle report can still be from the launch prompt.
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: sessionID, status: SessionStatus(kind: .working, summary: "First prompt"), at: Date()
        )
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: sessionID, status: SessionStatus(kind: .idle, summary: "Idle"), at: Date()
        )
        _ = try await harness.waitForSnapshot { snapshot in
            snapshot.tasks?.tasks.first { $0.id == created.id }?.showsAgentActivity == false
        }

        // The phone needs a new snapshot for both edges of the agent's turn.
        for (kind, showsActivity) in [(SessionStatusKind.working, true), (.idle, false)] {
            harness.server.removeAllBroadcasts()
            fixture.sessionRuntimeStore.updateStatus(
                sessionID: sessionID, status: SessionStatus(kind: kind, summary: "\(kind)"), at: Date()
            )
            _ = try await harness.waitForSnapshot { snapshot in
                snapshot.tasks?.tasks.first { $0.id == created.id }?.showsAgentActivity == showsActivity
            }
            let item = try #require(harness.board.items().first { $0.taskID == created.id })
            let chips = CoordinatorChatPresentation.taskChips([item]) { _ in .init(red: 0, green: 0, blue: 0) }
            #expect(chips[created.id]?.showsActivity == showsActivity)
        }
    }

    /// Done and archived tasks leave the board, so a device reads them
    /// apart, for the chips of links to them: each with its title, stage
    /// and pull request. The board names their revision, which changes
    /// with what a chip shows and sends a new snapshot.
    @Test func finishedTasksTravelApartWithTheRevisionTheBoardNames() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        // Release tags, so a merged task waits to ship rather than being Done.
        fixture.config = TasksConfig(workspaces: [TasksConfig.Workspace(path: fixture.projectRoot, releaseTags: "v*")])
        let harness = try Harness(fixture)
        defer { harness.removeRuntimeFiles() }
        func insert(_ title: String, change: (inout TaskRecord) -> Void = { _ in }) throws -> TaskRecord {
            var record = TaskRecord(
                createdAt: Date(timeIntervalSinceNow: -3_600), text: title, title: title, slug: title, source: .cli,
                resolved: TaskFields(agent: "codex"), workspaceID: fixture.workspaceID,
                projectRoot: fixture.projectRoot, setup: .started
            )
            change(&record)
            try fixture.coordinator.records.insert(record)
            return record
        }
        let merged = try insert("Signup feedback") {
            $0.pullRequestURL = "https://github.com/example/toastty/pull/301"
            $0.mergedAt = Date(timeIntervalSinceNow: -120)
            $0.mergeCommit = "abc301"
            $0.doneAt = Date(timeIntervalSinceNow: -60)
        }
        let archived = try insert("Old export spike") {
            $0.pullRequestURL = "https://github.com/example/toastty/pull/302"
            $0.archivedAt = Date(timeIntervalSinceNow: -30)
        }
        let running = try insert("Billing UI")
        let toShip = try insert("Billing API") {
            $0.pullRequestURL = "https://github.com/example/toastty/pull/303"
            $0.mergedAt = Date(timeIntervalSinceNow: -90)
            $0.mergeCommit = "abc303"
        }
        // A Done task whose task space is still open lists on the board too.
        let openSpace = try harness.makeUntrackedTaskSpace(title: "Copy fixes")
        let doneWithSpace = try insert("Copy fixes") {
            $0.doneAt = Date(timeIntervalSinceNow: -10)
            $0.operation.taskSpace = .init(workspaceID: openSpace, panelID: UUID())
        }
        _ = fixture.store.send(.setWorkspaceTaskID(workspaceID: openSpace, taskID: doneWithSpace.id))
        // While the task space is open, its own done mark is the live one.
        _ = fixture.store.send(.setWorkspaceDone(workspaceID: openSpace, doneAt: Date(timeIntervalSinceNow: -10)))
        // A watched task space marked done has no task record: not a task.
        let watched = try harness.makeUntrackedTaskSpace(title: "Website hero")
        _ = fixture.store.send(.setWorkspaceDone(workspaceID: watched, doneAt: Date()))

        let board = try #require(harness.service.facadeSessionList(at: .now).tasks)
        let finished = harness.service.currentFinishedTasks()
        #expect(board.finishedTasksRevision == finished.revision)
        #expect(finished.revision == RemoteFinishedTasks(tasks: finished.tasks).revision)
        // The board leaves out the finished tasks whose task space closed,
        // as before.
        #expect(board.tasks.contains { $0.id == merged.id || $0.id == archived.id } == false)
        #expect(board.tasks.contains { $0.id == doneWithSpace.id })
        // The newest activity first; open tasks and the watched task space
        // are not finished tasks.
        #expect(finished.tasks.map(\.id) == [doneWithSpace.id, archived.id, merged.id])
        #expect(finished.tasks.contains { [running.id, toShip.id, watched].contains($0.id) } == false)
        try #require(finished.tasks.count == 3)
        // When each finished, as the Mac's mention list reads it: the
        // record's done time, else its latest change, here its archiving.
        let stored = try #require(fixture.coordinator.records.record(id: merged.id)?.doneAt)
        let archivedAt = try #require(fixture.coordinator.records.record(id: archived.id)?.archivedAt)
        #expect(finished.tasks[2].doneAt == stored)
        #expect(finished.tasks[1].doneAt == archivedAt)
        #expect(finished.tasks[2] == RemoteFinishedTask(
            id: merged.id, title: "Signup feedback", group: .done, stageTitle: "Done", stageReason: "merged",
            statusLine: "Done", projectTitle: "toastty",
            pullRequest: RemoteTaskPullRequest(number: 301, url: URL(string: "https://github.com/example/toastty/pull/301")!),
            doneAt: stored
        ))
        #expect(finished.tasks[1] == RemoteFinishedTask(
            id: archived.id, title: "Old export spike", group: .archived, stageTitle: "Archived",
            stageReason: "closed without finishing", statusLine: "Archived", projectTitle: "toastty",
            pullRequest: RemoteTaskPullRequest(number: 302, url: URL(string: "https://github.com/example/toastty/pull/302")!),
            doneAt: archivedAt
        ))
        // The gateway reads the same list through the handler the service
        // installs.
        #expect(harness.handler?.finishedTasksHandler?() == finished)

        // The most recent ones, when there are more than the limit.
        let items = harness.board.items()
        #expect(RemoteTaskBoardProjection.finishedTasks(items, limit: 2).map(\.id) == [doneWithSpace.id, archived.id])

        // A change that a chip shows, such as a new title, gives a new
        // revision, and the Mac sends the board again.
        try await harness.waitForSnapshot { $0.tasks?.finishedTasksRevision == finished.revision }
        try fixture.coordinator.records.save(id: merged.id) { $0.title = "Signup feedback form" }
        let snapshot = try await harness.waitForSnapshot { snapshot in
            snapshot.tasks.map { $0.finishedTasksRevision != finished.revision } == true
        }
        #expect(snapshot.tasks?.finishedTasksRevision == harness.service.currentFinishedTasks().revision)
        #expect(harness.service.currentFinishedTasks().tasks.first { $0.id == merged.id }?.title == "Signup feedback form")
    }

    @Test func aMacWithoutTheTaskSystemSendsNoBoard() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let harness = try Harness(fixture, board: .disabled)
        defer { harness.removeRuntimeFiles() }
        #expect(harness.service.facadeSessionList(at: .now).tasks == nil)
    }
}

@MainActor
private final class Harness {
    let fixture: TaskCoordinatorTests.Fixture
    let board: TaskBoardStore
    let server = TaskBoardGatewayServerSpy()
    let service: RemoteAccessService
    /// The gateway's request handler, as the service set it up.
    private(set) var handler: RemoteGatewayRequestHandler?
    private let runtimeHome = "/tmp/toastty-remote-tasks-\(UUID().uuidString)"

    init(_ fixture: TaskCoordinatorTests.Fixture, board: TaskBoardStore? = nil) throws {
        self.fixture = fixture
        self.board = board ?? TaskBoardStore(
            coordinator: fixture.coordinator,
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            pullRequests: PullRequestStateCache(runner: NoGitHub()),
            refreshInterval: nil,
            releaseCheckInterval: nil
        )
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        let server = server
        var handler: RemoteGatewayRequestHandler?
        service = RemoteAccessService(
            store: fixture.store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            taskBoard: self.board,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            terminalRuntimeRegistry: TerminalRuntimeRegistry(),
            runtimePaths: runtimePaths,
            port: 42_996,
            initiallyEnabled: false,
            pushConfiguration: nil,
            gatewayServerFactory: { created in
                handler = created
                return server
            }
        )
        self.handler = handler
        service.setEnabled(true, persist: false)
        server.onListenerReady?(42_996)
    }

    func makeUntrackedTaskSpace(title: String) throws -> UUID {
        let windowID = try #require(fixture.store.state.windows.first?.id)
        let before = Set(fixture.store.state.workspacesByID.keys)
        _ = fixture.store.send(.createWorkspace(windowID: windowID, title: title, activate: false))
        let created = try #require(Set(fixture.store.state.workspacesByID.keys).subtracting(before).first)
        _ = fixture.store.send(.setWorkspaceParent(workspaceID: created, parentWorkspaceID: fixture.workspaceID, spawningSessionID: nil))
        return created
    }

    @discardableResult
    func waitForSnapshot(
        timeout: Duration = .seconds(5),
        _ matches: (RemoteSessionListSnapshot) -> Bool
    ) async throws -> RemoteSessionListSnapshot {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let snapshot = server.sessionListSnapshots.last(where: matches) { return snapshot }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("No matching session list was broadcast")
        throw CancellationError()
    }

    func removeRuntimeFiles() {
        service.setEnabled(false, persist: false)
        try? FileManager.default.removeItem(atPath: runtimeHome)
    }
}

/// Answers no pull request question, so the board keeps what it has.
private struct NoGitHub: WorkspaceMergeCommandRunning {
    func run(arguments _: [String], directory _: String, timeout _: TimeInterval) async -> WorkspaceMergeCommandResult {
        WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "gh: not found", failure: nil)
    }
}

private final class TaskBoardGatewayServerSpy: RemoteAccessGatewayServing {
    var onWebSocketCountsChanged: ((RemoteAccessWebSocketCounts) -> Void)?
    var onDeviceRevoked: ((UUID) -> Void)?
    var onListenerReady: ((UInt16) -> Void)?
    var onListenerFailed: ((RemoteAccessListenerFailure) -> Void)?
    private(set) var broadcasts: [RemoteGatewayStreamMessage] = []

    var sessionListSnapshots: [RemoteSessionListSnapshot] {
        broadcasts.compactMap { message in
            guard case .sessionList(let snapshot) = message else { return nil }
            return snapshot
        }
    }

    func start(port _: UInt16) throws {}
    func stop() {}
    func disconnectWebSockets(for _: UUID) {}
    func disconnectAllWebSockets() {}
    func broadcast(_ message: RemoteGatewayStreamMessage) {
        broadcasts.append(message)
    }

    func removeAllBroadcasts() {
        broadcasts.removeAll()
    }
}
