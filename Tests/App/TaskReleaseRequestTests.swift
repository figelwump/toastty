import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// `task.set-release` through the app-control executor: the saved request
/// to release one task right after it merges.
@MainActor
struct TaskReleaseRequestTests {
    @MainActor
    final class Harness {
        let fixture: TaskCoordinatorTests.Fixture
        /// The coordinator holds its board weakly.
        let board: TaskBoardStore
        var executor: AppControlExecutor

        init() throws {
            fixture = try TaskCoordinatorTests.Fixture()
            // The fixture's project waits for release tags; any other
            // project finishes a task at its merge.
            fixture.config = TasksConfig(workspaces: [
                TasksConfig.Workspace(path: fixture.projectRoot, releaseTags: "v*", releasePrompt: "Release the merged tasks."),
            ])
            board = Self.makeBoard(fixture)
            fixture.coordinator.board = board
            executor = TaskAppControlTests().makeExecutor(fixture, coordinator: fixture.coordinator)
        }

        static func makeBoard(_ fixture: TaskCoordinatorTests.Fixture) -> TaskBoardStore {
            TaskBoardStore(
                coordinator: fixture.coordinator,
                store: fixture.store,
                sessionRuntimeStore: fixture.sessionRuntimeStore,
                pullRequests: PullRequestStateCache(runner: TaskAppControlTests.OfflineGitHub()),
                refreshInterval: nil,
                releaseCheckInterval: nil
            )
        }

        func insert(
            _ title: String,
            projectRoot: String? = nil,
            _ change: (inout TaskRecord) -> Void = { _ in }
        ) throws -> TaskRecord {
            var record = TaskRecord(
                createdAt: Date(), text: title, title: title, slug: title, source: .cli,
                workspaceID: fixture.workspaceID, projectRoot: projectRoot ?? fixture.projectRoot, setup: .started
            )
            change(&record)
            try fixture.coordinator.records.insert(record)
            return record
        }

        @discardableResult
        func setRelease(
            _ taskID: UUID?,
            afterMerge: Bool,
            callerSessionID: String? = nil
        ) throws -> [String: AutomationJSONValue] {
            var args: [String: AutomationJSONValue] = ["afterMerge": .bool(afterMerge)]
            if let taskID { args["taskID"] = .string(taskID.uuidString) }
            let outcome = try executor.runAction(
                id: "task.set-release",
                args: args,
                context: AutomationRequestContext(callerSessionID: callerSessionID, commandName: "app_control.run_action")
            )
            return try #require(outcome.result)
        }

        func get(_ taskID: UUID) throws -> [String: AutomationJSONValue] {
            try executor.runQuery(id: "task.get", args: ["taskID": .string(taskID.uuidString)])
        }

        /// `task.list --changed-since`: the listed tasks by ID, and the next
        /// cursor.
        func changes(since cursor: String?) throws -> (tasks: [String: [String: AutomationJSONValue]], cursor: String) {
            let listed = try executor.runQuery(id: "task.list", args: cursor.map { ["changedSince": .string($0)] } ?? [:])
            guard case .array(let tasks)? = listed["tasks"], case .string(let next)? = listed["cursor"] else {
                throw TaskError("task.list has no tasks or cursor: \(listed)")
            }
            var byID: [String: [String: AutomationJSONValue]] = [:]
            for task in tasks {
                guard case .object(let object) = task, case .string(let id)? = object["taskID"] else { continue }
                byID[id] = object
            }
            return (byID, next)
        }
    }

    private func request(at date: Date) -> AutomationJSONValue {
        .object(["requestedAt": .string(ISO8601DateFormatter().string(from: date))])
    }

    private func expectRefused(_ message: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected a refusal: \(message)")
        } catch AutomationSocketError.invalidPayload(let actual) {
            #expect(actual == message)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func aRequestKeepsItsFirstTimeSurvivesARelaunchAndClears() throws {
        let harness = try Harness()
        let fixture = harness.fixture
        let task = try harness.insert("Fix the unread dot")
        let other = try harness.insert("Rename the sidebar group")
        let first = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(try harness.get(task.id)["releaseAfterMerge"] == .null)
        var cursor = try harness.changes(since: nil).cursor

        // Set: the action, task.get and task.list report it, and only this
        // task counts as changed.
        fixture.clock = first
        #expect(try harness.setRelease(task.id, afterMerge: true)["releaseAfterMerge"] == request(at: first))
        #expect(try harness.get(task.id)["releaseAfterMerge"] == request(at: first))
        var changed = try harness.changes(since: cursor)
        #expect(Set(changed.tasks.keys) == [task.id.uuidString])
        #expect(changed.tasks[task.id.uuidString]?["releaseAfterMerge"] == request(at: first))
        cursor = changed.cursor
        #expect(try harness.get(other.id)["releaseAfterMerge"] == .null)

        // Set again later: the first time stays, and nothing changed.
        fixture.clock = first.addingTimeInterval(3_600)
        #expect(try harness.setRelease(task.id, afterMerge: true)["releaseAfterMerge"] == request(at: first))
        changed = try harness.changes(since: cursor)
        #expect(changed.tasks.isEmpty)
        cursor = changed.cursor

        // The request is on disk at once, and a new launch reads it back.
        #expect(fixture.savedRecord(task.id)?.releaseAfterMerge == TaskReleaseAfterMerge(requestedAt: first))
        let relaunched = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        let relaunchedExecutor = TaskAppControlTests().makeExecutor(fixture, coordinator: relaunched)
        let afterRelaunch = try relaunchedExecutor.runQuery(id: "task.get", args: ["taskID": .string(task.id.uuidString)])
        #expect(afterRelaunch["releaseAfterMerge"] == request(at: first))

        // Clear: reported as a change, and gone from the saved file, which
        // then holds only records without the field and still loads.
        #expect(try harness.setRelease(task.id, afterMerge: false)["releaseAfterMerge"] == .null)
        changed = try harness.changes(since: cursor)
        #expect(Set(changed.tasks.keys) == [task.id.uuidString])
        #expect(changed.tasks[task.id.uuidString]?["releaseAfterMerge"] == .null)
        let saved = try String(contentsOf: fixture.recordsFile, encoding: .utf8)
        #expect(saved.contains("releaseAfterMerge") == false)
        #expect(TaskRecordStore(fileURL: fixture.recordsFile).records.map(\.id) == [task.id, other.id])

        // Clearing a task that has no request is fine.
        #expect(try harness.setRelease(task.id, afterMerge: false)["releaseAfterMerge"] == .null)
        #expect(try harness.changes(since: changed.cursor).tasks.isEmpty)
    }

    @Test func aTasksOwnAgentSetsItWithoutATaskIDAndOtherCallersNameTheTask() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        let created = try await harness.executor.runActionAsync(
            id: "task.create",
            args: ["text": .string("Ship the hotfix"), "workspace": .string(fixture.workspaceID.uuidString), "agent": .string("claude")],
            context: AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action")
        )
        guard case .string(let raw)? = created.result?["taskID"], let taskID = UUID(uuidString: raw) else {
            Issue.record("no taskID in \(String(describing: created.result))")
            return
        }
        await fixture.waitForSetup(taskID)
        let sessionID = try #require(fixture.record(taskID)?.operation.agentLaunch?.sessionID)

        let own = try harness.setRelease(nil, afterMerge: true, callerSessionID: sessionID)
        #expect(own["taskID"] == .string(taskID.uuidString))
        #expect(fixture.record(taskID)?.releaseAfterMerge != nil)
        try harness.setRelease(nil, afterMerge: false, callerSessionID: sessionID)
        #expect(fixture.record(taskID)?.releaseAfterMerge == nil)

        // The user's shell, or a coordinator, names the task.
        expectRefused("taskID is required outside a task's agent session") {
            try harness.setRelease(nil, afterMerge: true)
        }
        try harness.setRelease(taskID, afterMerge: true)
        #expect(fixture.record(taskID)?.releaseAfterMerge != nil)
    }

    @Test func aRequestIsAllowedUntilTheTaskIsDoneAndRefusedAfter() throws {
        let harness = try Harness()
        let fixture = harness.fixture
        let merged = Date().addingTimeInterval(-600)

        // To ship: merged, and the project waits for a release tag.
        let toShip = try harness.insert("Merged and waiting") {
            $0.mergedAt = merged
            $0.mergeCommit = "abc123"
        }
        #expect(harness.board.items().first { $0.taskID == toShip.id }?.stage == .toShip)
        try harness.setRelease(toShip.id, afterMerge: true)
        #expect(fixture.record(toShip.id)?.releaseAfterMerge != nil)

        // Done in four ways: marked done, shipped, merged in a project that
        // has no release tags, and finished through its child tasks.
        let markedDone = try harness.insert("Marked done") { $0.doneAt = Date() }
        let shipped = try harness.insert("Shipped") {
            $0.mergedAt = merged
            $0.shippedAt = Date()
            $0.releaseTag = "v1.2.0"
        }
        let mergedWithoutTags = try harness.insert("Merged elsewhere", projectRoot: "/repo/no-release-tags") {
            $0.mergedAt = merged
        }
        let parent = try harness.insert("Coordinate elsewhere", projectRoot: "/repo/no-release-tags")
        _ = try harness.insert("Child elsewhere", projectRoot: "/repo/no-release-tags") {
            $0.parentTaskID = parent.id
            $0.mergedAt = merged
        }
        for task in [markedDone, shipped, mergedWithoutTags, parent] {
            expectRefused("Task \(task.title) is done.") { try harness.setRelease(task.id, afterMerge: true) }
            #expect(fixture.record(task.id)?.releaseAfterMerge == nil)
        }

        let archived = try harness.insert("Archived") { $0.archivedAt = Date() }
        expectRefused("Task Archived is archived.") { try harness.setRelease(archived.id, afterMerge: true) }

        let release = try harness.insert("Release toastty") { $0.release = TaskRelease(childTaskIDs: [toShip.id]) }
        expectRefused("Task Release toastty is a release task, so it has no merge to release.") {
            try harness.setRelease(release.id, afterMerge: true)
        }
        #expect(fixture.record(release.id)?.releaseAfterMerge == nil)

        let unknown = UUID()
        for afterMerge in [true, false] {
            expectRefused("No task has ID \(unknown.uuidString).") { try harness.setRelease(unknown, afterMerge: afterMerge) }
        }
        expectRefused("afterMerge is required: true to release right after the merge, false to clear the request") {
            _ = try harness.executor.runAction(
                id: "task.set-release",
                args: ["taskID": .string(toShip.id.uuidString)],
                context: AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action")
            )
        }

        // A request made while the task was open stays on the record after
        // it ships, as history, and can still be cleared.
        _ = fixture.coordinator.records.update(id: toShip.id) {
            $0.shippedAt = Date()
            $0.releaseTag = "v1.3.0"
        }
        #expect(try harness.get(toShip.id)["releaseAfterMerge"] != .null)
        #expect(try harness.setRelease(toShip.id, afterMerge: false)["releaseAfterMerge"] == .null)
        for task in [markedDone, archived, release] {
            #expect(try harness.setRelease(task.id, afterMerge: false)["releaseAfterMerge"] == .null)
        }
    }

    @Test func theMarkShowsOnOpenAndToShipTasksOnly() throws {
        let harness = try Harness()
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ title: String, _ change: (inout TaskRecord) -> Void = { _ in }) throws -> TaskBoardItem {
            let record = try harness.insert(title) {
                $0.releaseAfterMerge = TaskReleaseAfterMerge(requestedAt: requestedAt)
                change(&$0)
            }
            return try #require(harness.board.items().first { $0.taskID == record.id })
        }
        let open = try item("Open")
        let toShip = try item("To ship") { $0.mergedAt = Date() }
        let done = try item("Done") { $0.doneAt = Date() }
        let archived = try item("Archived") { $0.archivedAt = Date() }
        let plainRecord = try harness.insert("Plain")
        let plain = try #require(harness.board.items().first { $0.taskID == plainRecord.id })

        #expect(TaskBoardPresentation.releaseAfterMergeRequestedAt(open) == requestedAt)
        #expect(TaskBoardPresentation.releaseAfterMergeRequestedAt(toShip) == requestedAt)
        #expect(toShip.stage == .toShip)
        #expect(TaskBoardPresentation.releaseAfterMergeRequestedAt(done) == nil)
        #expect(TaskBoardPresentation.releaseAfterMergeRequestedAt(archived) == nil)
        #expect(TaskBoardPresentation.releaseAfterMergeRequestedAt(plain) == nil)

        // Toastty Mobile gets the same answer, for a later release.
        let remote = RemoteTaskBoardProjection.board(items: harness.board.items(), state: harness.fixture.store.state)
        func remoteRequest(_ title: String) throws -> Date? {
            try #require(remote.tasks.first { $0.title == title }).releaseAfterMergeRequestedAt
        }
        #expect(try remoteRequest("To ship") == requestedAt)
        #expect(try remoteRequest("Open") == requestedAt)
        #expect(try remoteRequest("Plain") == nil)
    }
}
