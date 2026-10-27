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
        let projectID = fixture.chat.lastPayload?.projects.first { $0.title == "toastty" }?.id ?? "toastty"
        #expect(fixture.chat.lastPayload?.view?.filter == .init(project: projectID, group: "done"))
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

    @Test func summaryOpensBesideChatAndReusesItsTabWithoutReplacingReports() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithPacket()
        #expect(fixture.chat.show(taskID: nil))
        let workspaceID = try #require(fixture.session.workspaceID)
        let tabs = try #require(fixture.tasks.store.state.workspacesByID[workspaceID]).rightAuxPanel.orderedTabs
        let summary = try #require(tabs.first)
        guard case .web(let page) = summary.panelState else { Issue.record("Summary is not a browser"); return }
        #expect(page.restorableURL == "toastty://coordinator/today")
        await fixture.chat.handle(.openReport(taskID: task.id, version: 1, screenshot: nil), from: nil)
        let reportSelection = fixture.tasks.store.state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID
        #expect(fixture.chat.show(taskID: nil))
        #expect(fixture.tasks.store.state.workspacesByID[workspaceID]?.rightAuxPanel.orderedTabs.count == 2)
        #expect(fixture.tasks.store.state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID == reportSelection)
        #expect(fixture.chat.showTasks())
        #expect(fixture.tasks.store.state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID == summary.id)
    }

    @MainActor private final class WindowPage: CoordinatorChatController.Page {
        let windowID: UUID?
        let isSummary: Bool
        var states: [[String: AutomationJSONValue]] = []
        init(windowID: UUID, isSummary: Bool = false) { self.windowID = windowID; self.isSummary = isSummary }
        func receive(_ data: Data) { if let state = try? JSONDecoder().decode([String: AutomationJSONValue].self, from: data) { states.append(state) } }
        func run(_ script: String) async -> Bool { false }
        func takeKeyboardFocus() {}
        func showSetup(taskID: UUID, coordinator: TaskCoordinator) -> Bool { false }
    }

    @Test func projectSelectionIsSharedWithinOneWindowAndBackgroundRendersDoNotChangeTheActiveSurface() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithPacket()
        await fixture.chat.refresh()
        let project = try #require(fixture.chat.lastPayload?.projects.first)
        let window = try #require(fixture.tasks.store.state.windows.first?.id)
        let chat = WindowPage(windowID: window)
        let summary = WindowPage(windowID: window, isSummary: true)
        let other = WindowPage(windowID: UUID())
        fixture.chat.attach(chat)
        fixture.chat.attach(summary)
        fixture.chat.attach(other)
        #expect(fixture.chat.show(taskID: task.id))
        await fixture.chat.refresh()
        #expect(chat.states.last?["projectFilter"] == nil)
        await fixture.chat.handle(.projectFilter(project.id), from: chat)
        await fixture.chat.refresh()
        #expect(chat.states.last?["projectFilter"] == .string(project.id))
        #expect(fixture.chat.lastPayload?.focus == nil)
        #expect(fixture.chat.lastPayload?.view?.filter == nil)
        #expect(summary.states.last?["projectFilter"] == .string(project.id))
        #expect(other.states.last?["projectFilter"] == nil)
        await fixture.chat.handle(.activate(view: .tasks, selectedRowID: task.id.uuidString), from: summary)
        await fixture.chat.handle(.rendered(expanded: [], view: .chat), from: chat)
        #expect(fixture.chat.pageView == .tasks)
        #expect(fixture.chat.currentTaskID == task.id)
        await fixture.chat.handle(.activate(view: .chat, selectedRowID: nil), from: chat)
        await fixture.chat.handle(.rendered(expanded: [], view: .tasks, selectedRowID: task.id.uuidString), from: summary)
        #expect(fixture.chat.pageView == .chat)
        await fixture.chat.handle(.projectFilter("unknown"), from: chat)
        await fixture.chat.refresh()
        #expect(chat.states.last?["projectFilter"] == .string(project.id))
    }

    @Test func summaryNavigationOpensTheSingleCurrentCardWithItsProjectAndHistory() async throws {
        let fixture = try await Fixture()
        let task = try await fixture.taskWithPacket()
        let question = CoordinatorEvent(at: Date().addingTimeInterval(1), kind: .question,
            taskID: task.id, text: "Keep this project?", sessionID: nil)
        try fixture.session.files.append(question)
        let preparation = try fixture.tasks.coordinator.preparePacketPublish(taskID: task.id,
            packetJSON: Data(#"{"summary":"Keeps the totals visible","look_at":"The bar at 390px","not_verified":[]}"#.utf8), screenshotPaths: [])
        _ = try await fixture.tasks.coordinator.finishPacketPublish(preparation)
        try fixture.session.files.append(CoordinatorEvent(at: Date().addingTimeInterval(2), kind: .packet,
            taskID: task.id, text: nil, sessionID: nil))
        await fixture.chat.refresh()
        let project = try #require(row(fixture, task.id)?.projectID)
        let window = try #require(fixture.tasks.store.state.windows.first?.id)
        let chat = WindowPage(windowID: window)
        let summary = WindowPage(windowID: window, isSummary: true)
        fixture.chat.attach(chat)
        fixture.chat.attach(summary)
        await fixture.chat.handle(.projectFilter(project), from: chat)

        for view in [CoordinatorChatPageView.today, .tasks] {
            await fixture.chat.handle(.showView(view), from: summary)
            await fixture.chat.handle(.taskAction(rowID: task.id.uuidString, actionID: "open"), from: summary)
            await fixture.chat.refresh()
            let cards = fixture.chat.lastPayload?.items.compactMap { item -> CoordinatorChatCardView? in
                guard case .card(let card) = item, card.task?.id == task.id.uuidString else { return nil }
                return card
            } ?? []
            #expect(cards.count == 1)
            #expect(cards.first?.id == question.id.uuidString)
            #expect(cards.first?.task?.projectID == project)
            #expect(cards.first?.packetVersions == [1, 2])
            #expect(fixture.chat.lastPayload?.focus?.cardID == question.id.uuidString)
            #expect(chat.states.last?["projectFilter"] == .string(project))
            #expect(fixture.chat.lastPayload?.view?.view == .chat)
        }
    }

    @Test func todayUsesMergeAndReleaseDatesInTheLocalDayAndKeepsProjectIdentity() throws {
        let iso = ISO8601DateFormatter()
        let now = try #require(iso.date(from: "2026-10-26T06:30:00Z")) // October 25 in Los Angeles.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        func item(_ title: String, root: String, merged: String?, shipped: String?, done: String? = nil) throws -> TaskBoardItem {
            var record = TaskRecord(createdAt: now, text: title, title: title, slug: title, source: .cli, setup: .started)
            record.projectRoot = root
            record.mergedAt = merged.flatMap(iso.date(from:))
            record.shippedAt = shipped.flatMap(iso.date(from:))
            record.doneAt = done.flatMap(iso.date(from:))
            return TaskBoardItem(id: .task(record.id), record: record, title: title, projectTitle: "app", projectID: root, stage: .done, agent: .none, activityAt: now)
        }
        let merged = try item("merged", root: "/a/app", merged: "2026-10-26T06:00:00Z", shipped: nil)
        let released = try item("released", root: "/b/app", merged: "2026-10-25T20:00:00Z", shipped: "2026-10-26T06:10:00Z")
        let old = try item("old", root: "/a/app", merged: "2026-10-25T06:59:00Z", shipped: nil, done: "2026-10-26T06:15:00Z")
        let items = [old, merged, released]
        let today = CoordinatorAllTasks.today(items, now: now, calendar: calendar)
        #expect(today.completed.map(\.rowID) == [CoordinatorAllTasks.rowID(released), CoordinatorAllTasks.rowID(merged)])
        #expect(today.completed.map(\.kind) == ["released", "merged"])
        #expect(CoordinatorAllTasks.projects(items).map(\.id) == ["/a/app", "/b/app"])
        #expect(CoordinatorAllTasks.today(items, now: now.addingTimeInterval(3600), calendar: calendar).completed.isEmpty)
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
        func showTaskMenu(sections: [[TaskBoardPresentation.MenuItem]], rect: CGRect, run: @escaping (TaskBoardPresentation.MenuItem) -> Void) -> Bool {
            false
        }
        func showSetup(taskID: UUID, coordinator: TaskCoordinator) -> Bool {
            opened.append(taskID)
            return true
        }
    }
}
