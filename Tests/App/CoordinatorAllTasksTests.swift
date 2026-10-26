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

    @Test func theCardIndexFollowsTheChatAndCountsOpenAllTasksAtAProjectsGroup() async throws {
        let fixture = try await Fixture()
        CoordinatorChatController.shared = fixture.chat
        defer { CoordinatorChatController.shared = nil }
        let reviewed = try await fixture.taskWithPacket()
        await fixture.chat.refresh()
        #expect(fixture.chat.cardIndex.tasks[reviewed.id]?.latestKind == .packet)
        #expect(fixture.chat.cardIndex.openTaskID == nil)

        // The sidebar outlines the task whose card the page has open, only
        // while the page shows the chat.
        let cardID = try #require(fixture.chat.lastPayload?.items.compactMap { item -> String? in
            guard case .card(let card) = item, card.task?.id == reviewed.id.uuidString else { return nil }
            return card.id
        }.last)
        await fixture.chat.handle(.rendered(expanded: [cardID], view: .chat), from: nil)
        #expect(fixture.chat.cardIndex.openTaskID == reviewed.id)
        await fixture.chat.handle(.rendered(expanded: [cardID], view: .tasks), from: nil)
        #expect(fixture.chat.cardIndex.openTaskID == nil)

        // The To ship and Done counts ask for one project's group.
        let context = AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action")
        _ = try await fixture.executor().runActionAsync(
            id: "coordinator.tasks.show",
            args: ["group": .string("done"), "project": .string("toastty")],
            context: context
        )
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.view?.view == .tasks)
        #expect(fixture.chat.lastPayload?.view?.filter == .init(project: "toastty", group: "done"))
        // A plain request shows All tasks as the user left it.
        _ = try await fixture.executor().runActionAsync(id: "coordinator.tasks.show", args: [:], context: context)
        await fixture.chat.refresh()
        #expect(fixture.chat.lastPayload?.view?.filter == nil)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.executor().runActionAsync(id: "coordinator.tasks.show", args: ["group": .string("later")], context: context)
        }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.executor().runActionAsync(id: "coordinator.tasks.show", args: ["project": .string("toastty")], context: context)
        }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.executor().runActionAsync(id: "coordinator.tasks.show", args: ["group": .int(42)], context: context)
        }

        // A question posted after the packet is what the task asks now:
        // opening the task opens the question, not the packet.
        #expect(fixture.chat.lastPayload?.focus?.cardID == nil)
        try fixture.session.files.append(CoordinatorEvent(at: Date().addingTimeInterval(1), kind: .question, taskID: reviewed.id, text: "Move it?", sessionID: nil))
        #expect(fixture.chat.show(taskID: reviewed.id))
        await fixture.chat.refresh()
        let question = try #require(fixture.chat.lastPayload?.items.compactMap { item -> CoordinatorChatCardView? in
            guard case .card(let card) = item, card.kind == "question" else { return nil }
            return card
        }.first)
        #expect(fixture.chat.lastPayload?.focus?.cardID == question.id)
        #expect(fixture.chat.cardIndex.tasks[reviewed.id]?.latestKind == .question)
    }

    @Test func aNeedsYouTaskWithACardOpensItFromAllTasks() {
        let record = TaskRecord(createdAt: Date(), text: "trust", title: "trust", slug: "trust", source: .cli, setup: .started)
        let finished = TaskBoardItem(
            id: .task(record.id),
            record: record,
            title: "Coordinator trust prompt",
            taskSpaceWorkspaceID: UUID(),
            projectTitle: "toastty",
            stage: .needsYou(.agentFinished),
            agent: .idle,
            activityAt: Date()
        )
        func primary(_ cards: CoordinatorChatCardIndex.TaskCards?) -> String? {
            CoordinatorAllTasks.rows([finished], cards: { _ in cards }, canRelease: { _ in false }, isTriageConfigured: false, mergePolicy: { _ in "" })
                .first?.primary?.id
        }
        // "open" shows the card in the chat; without one, the task space.
        #expect(primary(.init(latestKind: .question, isNew: false)) == CoordinatorAllTasks.openActionID)
        #expect(primary(nil) == "openTaskSpace")
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
        let rows = CoordinatorAllTasks.rows([item, running], cards: { _ in nil }, canRelease: { _ in true }, isTriageConfigured: false, mergePolicy: { _ in "" })
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
