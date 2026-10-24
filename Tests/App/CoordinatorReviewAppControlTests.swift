import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct CoordinatorReviewAppControlTests {
    private func executor(_ fixture: TaskCoordinatorTests.Fixture) -> AppControlExecutor {
        let terminals = TerminalRuntimeRegistry()
        let web = WebPanelRuntimeRegistry()
        web.bind(store: fixture.store)
        return AppControlExecutor(
            store: fixture.store, terminalRuntimeRegistry: terminals, webPanelRuntimeRegistry: web,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            focusedPanelCommandController: FocusedPanelCommandController(store: fixture.store, runtimeRegistry: terminals, slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()),
            agentLaunchService: fixture.launcher, taskCoordinator: fixture.coordinator, reloadConfigurationAction: nil
        )
    }

    private func linkedTask(_ fixture: TaskCoordinatorTests.Fixture, title: String) async throws -> TaskRecord {
        let created = try await fixture.coordinator.create(TaskCreateRequest(text: title, workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(created.id)
        let record = try #require(fixture.record(created.id))
        fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: try #require(record.taskSpaceWorkspaceID), key: "github-pr",
            annotation: try #require(WorkspaceAnnotation.validated(text: "PR #7", url: "https://github.com/example/project/pull/7"))
        ))
        return record
    }

    private func publish(_ executor: AppControlExecutor, taskID: UUID, context: AutomationRequestContext = .init(callerSessionID: nil, commandName: "test")) throws -> CoordinatorReviewItem {
        let outcome = try executor.runAction(id: "coordinator.review.publish", args: [
            "taskID": .string(taskID.uuidString), "head": .string(String(repeating: "a", count: 40)), "baseRefName": .string("main"),
            "brief": .object(["behaviorChange": .string("The shortcut creates a task."), "decisionNeeded": .string("Approve it."), "recommendation": .string("Check the attached report.")]),
        ], context: context)
        let encoded = try JSONEncoder().encode(try #require(outcome.result?["review"]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CoordinatorReviewItem.self, from: encoded)
    }

    @Test func normalExecutorAssemblyDiscoversAndUsesTheNativeReviewService() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = executor(fixture)
        #expect(!executor.listActionDescriptors().contains { $0.id == "coordinator.review.publish" })
        let store = CoordinatorReviewStore.inMemory()
        let cache = PullRequestStateCache(runner: CoordinatorReviewActionsTests.PullRequestRunner(head: String(repeating: "a", count: 40)))
        let actions = CoordinatorReviewActions(store: store, tasks: fixture.coordinator, pullRequests: cache)
        // No executor injection: AutomationSocketServer builds it with the
        // task coordinator, and the computed lookup follows that assembly.
        #expect(executor.listActionDescriptors().contains { $0.id == "coordinator.review.publish" })
        #expect(executor.listQueryDescriptors().contains { $0.id == "coordinator.review.list" })
        #expect(!executor.listActionDescriptors().contains { $0.id == "coordinator.review.approve" })
        let task = try await linkedTask(fixture, title: "Shortcut")
        let item = try publish(executor, taskID: task.id)
        #expect(item.userAction == nil)
        let get = try executor.runQuery(id: "coordinator.review.get", args: ["reviewID": .string(item.id.uuidString)])
        #expect(get["review"] != nil)
        #expect(throws: AutomationSocketError.self) {
            try executor.runAction(id: "coordinator.review.report", args: [
                "reviewID": .string(item.id.uuidString), "intentID": .string(UUID().uuidString), "outcome": .string("merged"), "detail": .string("No approval exists."),
            ])
        }
        let intent = UUID()
        try store.update(id: item.id, expectedRevision: item.revision) {
            $0.userAction = .init(intentID: intent, kind: .merge, approvedHeadSHA: item.headSHA, deliveryState: .delivered)
        }
        let result = try executor.runAction(id: "coordinator.review.report", args: [
            "reviewID": .string(item.id.uuidString), "intentID": .string(intent.uuidString), "outcome": .string("blocked"), "detail": .string("A required check is still running."),
        ])
        #expect(result.result?["review"] != nil)
        #expect(store.item(id: item.id)?.userAction?.agentOutcome?.state == .blocked)
        #expect(store.item(id: item.id)?.observedOutcome.state != .merged)
        _ = actions
    }

    @Test func reviewReadsAndPublicationKeepTaskWorkspaceScope() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = executor(fixture)
        let store = CoordinatorReviewStore.inMemory()
        let actions = CoordinatorReviewActions(store: store, tasks: fixture.coordinator, pullRequests: PullRequestStateCache(runner: CoordinatorReviewActionsTests.PullRequestRunner(head: String(repeating: "a", count: 40))))
        let mine = try await linkedTask(fixture, title: "Mine")
        let other = try await linkedTask(fixture, title: "Other")
        let mineReview = try publish(executor, taskID: mine.id)
        let otherReview = try publish(executor, taskID: other.id)
        let session = try #require(fixture.record(mine.id)?.currentSessionID)
        #expect(fixture.sessionRuntimeStore.setScope(sessionID: session, workspaceIDs: []))
        let context = AutomationRequestContext(callerSessionID: session, commandName: "test")
        let list = try executor.runQuery(id: "coordinator.review.list", args: [:], context: context)
        guard case .array(let values)? = list["reviews"] else { Issue.record("No review list"); return }
        #expect(values.count == 1)
        #expect(try executor.runQuery(id: "coordinator.review.get", args: ["reviewID": .string(mineReview.id.uuidString)], context: context)["review"] != nil)
        #expect(throws: AutomationSocketError.self) {
            try executor.runQuery(id: "coordinator.review.get", args: ["reviewID": .string(otherReview.id.uuidString)], context: context)
        }
        #expect(throws: AutomationSocketError.self) { try publish(executor, taskID: other.id, context: context) }
        _ = actions
    }
    @Test func reviewListsPageWithoutLosingTheLastRecord() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = executor(fixture)
        let store = CoordinatorReviewStore.inMemory()
        let actions = CoordinatorReviewActions(store: store, tasks: fixture.coordinator, pullRequests: PullRequestStateCache(runner: CoordinatorReviewActionsTests.PullRequestRunner(head: String(repeating: "a", count: 40))))
        let task = try await linkedTask(fixture, title: "Many heads")
        for digit in ["a", "b", "c", "d", "e"] {
            try store.upsertPublication(.init(taskID: task.id, taskTitle: task.title, projectRoot: fixture.projectRoot,
                repository: "example/project", pullRequestURL: "https://github.com/example/project/pull/7",
                headSHA: String(repeating: digit, count: 40), baseRefName: "main",
                brief: .init(behaviorChange: "Change.", decisionNeeded: "Review.", recommendation: "Inspect evidence.")))
        }
        var after: String?
        var seen: Set<String> = []
        repeat {
            var args: [String: AutomationJSONValue] = ["limit": .int(2)]
            if let after { args["after"] = .string(after) }
            let page = try executor.runQuery(id: "coordinator.review.list", args: args)
            guard case .array(let rows)? = page["reviews"] else { Issue.record("No reviews"); return }
            #expect(rows.count <= 2)
            for row in rows {
                guard case .object(let value) = row, let id = value.string("id") else { Issue.record("No ID"); return }
                #expect(seen.insert(id).inserted)
            }
            after = page.string("nextAfter")
        } while after != nil
        #expect(seen.count == 5)
        #expect(throws: AutomationSocketError.self) {
            try executor.runQuery(id: "coordinator.review.list", args: ["limit": .int(0)])
        }
        _ = actions
    }

}
