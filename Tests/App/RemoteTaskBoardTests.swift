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
    /// ships, and each lane says where Release starts and which release
    /// runs, as the Mac's Release button reads them.
    @Test func aLaneCarriesEveryToShipTaskAndItsRelease() throws {
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
        func lane() throws -> (lane: RemoteTaskShipLane, board: RemoteTaskBoard) {
            let board = try #require(harness.service.facadeSessionList(at: .now).tasks)
            return (try #require(board.toShip.first), board)
        }

        var current = try lane()
        let newestFirst = merged.reversed().map(\.id)
        #expect(current.lane.count == 5)
        // An older phone still reads the newest few.
        #expect(current.lane.recentTaskIDs == Array(newestFirst.prefix(3)))
        #expect(current.lane.taskIDs == newestFirst)
        #expect(Set(current.board.tasks.map(\.id)).isSuperset(of: newestFirst))
        #expect(current.lane.releaseWorkspaceID == fixture.workspaceID)
        #expect(current.lane.releaseTaskID == nil)

        // While a release of the project runs, the lane names it.
        var release = TaskRecord(
            createdAt: Date(), text: "Release toastty", title: "Release toastty", slug: "release", source: .cli,
            workspaceID: fixture.workspaceID, projectRoot: fixture.projectRoot, setup: .started
        )
        release.release = TaskRelease(childTaskIDs: merged.map(\.id))
        try fixture.coordinator.records.insert(release)
        current = try lane()
        #expect(current.lane.releaseTaskID == release.id)

        // Without a release setting the lane offers no Release, and names
        // no release.
        fixture.config = TasksConfig(workspaces: [TasksConfig.Workspace(path: fixture.projectRoot, releaseTags: "v*")])
        harness.board.reloadConfig()
        current = try lane()
        #expect(current.lane.releaseWorkspaceID == nil)
        #expect(current.lane.releaseTaskID == nil)
        #expect(current.lane.taskIDs?.count == 5)
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
            gatewayServerFactory: { _ in server }
        )
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
