import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// All tasks, through the actions the page, the CLI and the palette send:
/// the real task coordinator and board behind the chat controller.
@MainActor
struct CoordinatorAllTasksTests {
    private typealias Fixture = CoordinatorChatTests.Fixture

    private func row(_ fixture: Fixture, _ taskID: UUID) -> CoordinatorAllTasks.Row? {
        fixture.chat.lastPayload?.tasks.first { $0.taskID == taskID.uuidString }
    }

    @Test func allTasksListsEveryTaskAndItsRowsRunWhatTheTaskOffersNow() async throws {
        let fixture = try await Fixture()
        CoordinatorChatController.shared = fixture.chat
        defer { CoordinatorChatController.shared = nil }
        let reviewed = try await fixture.taskWithPacket()
        // A task the coordinator never posted about has no card.
        let quiet = try await fixture.tasks.coordinator.create(TaskCreateRequest(text: "Tidy the logs", workspaceID: fixture.tasks.workspaceID, agent: "codex"))
        await fixture.tasks.waitForSetup(quiet.id)
        let windowID = try #require(fixture.tasks.store.state.windows.first?.id)

        _ = try await fixture.executor().runActionAsync(
            id: "coordinator.tasks.show",
            args: [:],
            context: AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action")
        )
        #expect(fixture.tasks.store.state.showsCoordinatorChat(windowID: windowID))
        await fixture.chat.refresh()
        let payload = try #require(fixture.chat.lastPayload)
        #expect(payload.view?.view == .tasks)
        #expect(payload.taskGroups.map(\.id) == ["needsYou", "running", "toShip", "done", "archived"])

        let reviewRow = try #require(row(fixture, reviewed.id))
        #expect(reviewRow.group == "needsYou")
        #expect(reviewRow.hasCard)
        // Marked ready with no pull request: the Needs you row's Mark Done.
        #expect(reviewRow.primary?.id == "action:markDone")
        #expect(reviewRow.confirm == nil)
        let quietRow = try #require(row(fixture, quiet.id))
        #expect(quietRow.hasCard == false)
        #expect(quietRow.menu.joined().map(\.id).contains("openTaskSpace"))

        // The palette acts on the selected row while All tasks shows.
        await fixture.chat.handle(.rendered(expanded: [], view: .tasks, selectedRowID: quietRow.id), from: nil)
        let selection = try #require(fixture.tasks.store.commandSelection(preferredWindowID: windowID))
        #expect(fixture.board.currentTask(in: selection) { _ in [] }?.item.taskID == quiet.id)

        await fixture.chat.handle(.taskAction(rowID: reviewRow.id, actionID: "action:markDone"), from: nil)
        #expect(fixture.tasks.record(reviewed.id)?.doneAt != nil)
        await fixture.chat.refresh()
        #expect(row(fixture, reviewed.id)?.group == "done")
        // The row was drawn before the task finished: it no longer offers
        // Mark Done, so the action does nothing and says why.
        await fixture.chat.handle(.taskAction(rowID: reviewRow.id, actionID: "action:markDone"), from: nil)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.notice?.isError == true)

        // Open shows the task's card in the chat.
        await fixture.chat.handle(.taskAction(rowID: reviewRow.id, actionID: "open"), from: nil)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.view?.view == .chat)
        #expect(fixture.chat.lastPayload?.focus?.taskID == reviewed.id.uuidString)
    }

    @Test func anArchivedTaskOffersDelete() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.tasks.coordinator.create(TaskCreateRequest(text: "Old idea", workspaceID: fixture.tasks.workspaceID, agent: "codex"))
        await fixture.tasks.waitForSetup(task.id)
        try await fixture.tasks.coordinator.archive(taskID: task.id, options: TaskArchiveOptions())
        await fixture.chat.refresh()
        let archived = try #require(row(fixture, task.id))
        #expect(archived.group == "archived")
        #expect(archived.menu.last?.map(\.id) == ["delete"])

        await fixture.chat.handle(.taskAction(rowID: archived.id, actionID: "delete"), from: nil)
        #expect(fixture.tasks.record(task.id) == nil)
    }

    @Test func toShipRowsOfAProjectThatCanReleaseOfferRelease() {
        let project = UUID()
        let item = TaskBoardItem(
            id: .task(UUID()),
            title: "Badge contrast",
            projectWorkspaceID: project,
            projectTitle: "lumen",
            stage: .toShip,
            agent: .none,
            activityAt: Date()
        )
        let running = TaskBoardItem(id: .task(UUID()), title: "Cart rounding", projectWorkspaceID: project, projectTitle: "lumen", stage: .running, agent: .none, activityAt: Date())
        let rows = CoordinatorAllTasks.rows([item, running], hasCard: { _ in false }, canRelease: { _ in true }, isTriageConfigured: false, mergePolicy: { _ in "" })
        #expect(rows[0].menu.last?.map(\.title) == ["Release lumen…"])
        #expect(rows[1].menu.joined().contains { $0.id == "release" } == false)

        func resolve(_ item: TaskBoardItem, canRelease: Bool) -> CoordinatorAllTasks.Resolved? {
            CoordinatorAllTasks.resolve(rowID: CoordinatorAllTasks.rowID(item), actionID: "release", items: [item, running], canRelease: { _ in canRelease }, isTriageConfigured: false)
        }
        #expect(resolve(item, canRelease: true) == .release(projectWorkspaceID: project))
        #expect(resolve(item, canRelease: false) == nil)
        #expect(resolve(running, canRelease: true) == nil)
    }

    @Test func doneAndArchivedSendOnlyTheirNewestRowsWithTheGroupTotals() {
        let now = Date()
        func item(_ stage: TaskStage, age: Int) -> TaskBoardItem {
            TaskBoardItem(id: .task(UUID()), title: "Task \(age)", stage: stage, agent: .none, activityAt: now.addingTimeInterval(-Double(age)))
        }
        // Newest first, as the board sorts them.
        let done = (0..<205).map { item(.done, age: $0) }
        let items = [item(.running, age: 0)] + done + [item(.archived, age: 1)]
        let shown = CoordinatorAllTasks.shownItems(items)
        #expect(shown.count == 1 + CoordinatorAllTasks.finishedRowLimit + 1)
        #expect(shown.filter { $0.stage == .done }.map(\.id) == done.prefix(CoordinatorAllTasks.finishedRowLimit).map(\.id))
        let totals = Dictionary(uniqueKeysWithValues: CoordinatorAllTasks.groups(items).map { ($0.id, $0.total) })
        #expect(totals == ["needsYou": 0, "running": 1, "toShip": 0, "done": 205, "archived": 1])
    }

    @Test func setupTasksOfferRecoveryWithoutACardOrTaskSpace() async throws {
        let fixture = try await Fixture()
        let page = SetupPage()
        let cases: [TaskSetupState] = [.routing, .settingUp, .needsWorkspace(reason: "Pick a project"), .setupFailed(reason: "Missing profile")]
        for setup in cases {
            let task = TaskRecord(createdAt: Date(), text: "fix", title: "fix", slug: "fix", source: .cli, setup: setup)
            try fixture.tasks.coordinator.records.insert(task)
            await fixture.chat.refresh()
            let current = try #require(row(fixture, task.id))
            #expect(current.group == (setup == .routing || setup == .settingUp ? "running" : "needsYou"))
            #expect(current.primary?.id == "setup")
            #expect(current.menu.joined().contains { $0.id == "action:markDone" } == false)
            await fixture.chat.handle(.taskAction(rowID: current.id, actionID: "setup"), from: page)
            #expect(page.opened.last == task.id)

            // A stale action cannot open recovery after setup completes.
            fixture.tasks.coordinator.records.update(id: task.id) { $0.setup = .started }
            let count = page.opened.count
            await fixture.chat.handle(.taskAction(rowID: current.id, actionID: "setup"), from: page)
            #expect(page.opened.count == count)
        }
    }

    private final class SetupPage: CoordinatorChatController.Page {
        var opened: [UUID] = []
        func receive(_: Data) {}
        func run(_: String) async -> Bool { false }
        func takeKeyboardFocus() {}
        func showSetup(taskID: UUID, coordinator: TaskCoordinator) -> Bool {
            opened.append(taskID)
            return true
        }
    }
}
