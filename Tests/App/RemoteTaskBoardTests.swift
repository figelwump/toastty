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
