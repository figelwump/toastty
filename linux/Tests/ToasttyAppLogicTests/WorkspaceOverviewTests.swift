import CoreState
import Foundation
import Testing
@testable import ToasttyAppLogic

/// The Linux workspace page's store and its socket commands: keeping a task
/// space's Scratchpad in its top-level workspace, following the source while
/// the task space is open, ending the link when it closes, deleting, the
/// synopsis, and `workspace.overview`.
@MainActor
@Suite(.serialized)
struct WorkspaceOverviewTests {
    @Test func keepingCopiesTheScratchpadIntoTheTopLevelWorkspaceOnce() throws {
        let fixture = try WorkspaceOverviewFixture()
        let source = try fixture.setContent("<p>Plan v1</p>", title: "Plan")

        let kept = try fixture.run(.workspaceScratchpadKeep, ["sessionID": .string(fixture.sessionID)])
        #expect(kept["created"] == .bool(true))
        #expect(kept["workspaceID"] == .string(fixture.parentID.uuidString))
        #expect(kept["linked"] == .bool(true))
        let copyID = try documentUUID(kept)
        #expect(copyID != source)
        let copy = try #require(try fixture.documentStore.load(documentID: copyID))
        #expect(copy.content == "<p>Plan v1</p>")
        #expect(copy.title == "Plan")
        #expect(copy.sessionLink == nil)

        // Keeping it again, by its source or by the copy, finds the same copy.
        let again = try fixture.run(.workspaceScratchpadKeep, ["sessionID": .string(fixture.sessionID)])
        #expect(again["created"] == .bool(false))
        #expect(again["documentID"] == .string(copyID.uuidString))
        #expect(fixture.service.scratchpads(forWorkspace: fixture.parentID).count == 1)
        // The task space's own page is its parent's.
        let list = try fixture.query(.workspaceScratchpadList, ["workspaceID": .string(fixture.taskSpaceID.uuidString)])
        #expect(list["workspaceID"] == .string(fixture.parentID.uuidString))
        #expect(list["scratchpads"]?.arrayCount == 1)
    }

    @Test func theCopyFollowsItsSourceUntilTheTaskSpaceCloses() throws {
        let fixture = try WorkspaceOverviewFixture()
        _ = try fixture.setContent("<p>v1</p>", title: "Notes")
        let kept = try fixture.run(.workspaceScratchpadKeep, ["sessionID": .string(fixture.sessionID)])
        let copyID = try documentUUID(kept)

        _ = try fixture.setContent("<p>v2</p>", title: "Notes, revised")
        let followed = try #require(try fixture.documentStore.load(documentID: copyID))
        #expect(followed.content == "<p>v2</p>")
        #expect(followed.title == "Notes, revised")

        #expect(fixture.store.send(.closeWorkspace(workspaceID: fixture.taskSpaceID)))
        let entry = try #require(fixture.service.entry(documentID: copyID))
        #expect(entry.source?.isLinked == false)
        #expect(entry.source?.linkEndedAt != nil)
        #expect(try fixture.documentStore.load(documentID: copyID)?.content == "<p>v2</p>")
        let list = try fixture.query(.workspaceScratchpadList, ["workspaceID": .string(fixture.parentID.uuidString)])
        #expect(list["scratchpads"]?.firstObject?["linked"] == .bool(false))
    }

    @Test func exportOpenAndDelete() throws {
        let fixture = try WorkspaceOverviewFixture()
        _ = try fixture.setContent("<h1>Keep</h1>", title: "Keep")
        let kept = try fixture.run(.workspaceScratchpadKeep, ["sessionID": .string(fixture.sessionID)])
        let copyID = try documentUUID(kept)

        let export = try fixture.run(.workspaceScratchpadExport, ["documentID": .string(copyID.uuidString)])
        let path = try #require(export["filePath"]?.stringValue)
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("<h1>Keep</h1>"))

        _ = try fixture.run(.workspaceScratchpadOpen, [
            "documentID": .string(copyID.uuidString), "workspaceID": .string(fixture.parentID.uuidString),
        ])
        let parent = try #require(fixture.store.state.workspacesByID[fixture.parentID])
        #expect(parent.rightAuxPanel.orderedTabs.contains { tab in
            if case .web(let web) = tab.panelState { return web.scratchpad?.documentID == copyID }
            return false
        })

        let deleted = try fixture.run(.workspaceScratchpadDelete, ["documentID": .string(copyID.uuidString)])
        #expect(deleted["deleted"] == .bool(true))
        #expect(fixture.service.entry(documentID: copyID) == nil)
        #expect(try fixture.documentStore.load(documentID: copyID) == nil)
        let after = try #require(fixture.store.state.workspacesByID[fixture.parentID])
        #expect(after.rightAuxPanel.orderedTabs.allSatisfy { tab in
            if case .web(let web) = tab.panelState { return web.scratchpad?.documentID != copyID }
            return true
        })
        #expect(throws: AutomationSocketError.self) {
            try fixture.run(.workspaceScratchpadDelete, ["documentID": .string(copyID.uuidString)])
        }
    }

    @Test func synopsisAndOverview() throws {
        let fixture = try WorkspaceOverviewFixture()
        let generated = try fixture.query(.workspaceOverview, ["workspaceID": .string(fixture.parentID.uuidString)])
        #expect(generated["title"] == .string("Project"))
        #expect(generated["synopsis"]?.objectValue?["source"] == .string("toastty"))

        _ = try fixture.run(.workspaceSynopsisSet, [
            "workspaceID": .string(fixture.taskSpaceID.uuidString),
            "text": .string("  Builds the bike frame jig.  "),
        ])
        let written = try fixture.query(.workspaceOverview, ["workspaceID": .string(fixture.parentID.uuidString)])
        #expect(written["synopsis"]?.objectValue?["source"] == .string("agent"))
        #expect(written["synopsis"]?.objectValue?["text"] == .string("Builds the bike frame jig."))

        _ = try fixture.run(.workspaceSynopsisSet, ["workspaceID": .string(fixture.parentID.uuidString), "text": .string("")])
        let cleared = try fixture.query(.workspaceOverview, ["workspaceID": .string(fixture.parentID.uuidString)])
        #expect(cleared["synopsis"]?.objectValue?["source"] == .string("toastty"))
    }

    @Test func storeReadsBackWhatItWrote() throws {
        let fixture = try WorkspaceOverviewFixture()
        _ = try fixture.setContent("<p>x</p>", title: "X")
        _ = try fixture.run(.workspaceScratchpadKeep, ["sessionID": .string(fixture.sessionID)])
        try fixture.service.setSynopsis("About", forWorkspace: fixture.parentID, sessionID: nil)
        let reread = WorkspaceOverviewStore(fileURL: fixture.service.overviewStore.fileURL)
        #expect(reread.contents == fixture.service.overviewStore.contents)
        #expect(reread.contents.scratchpads.count == 1)
        #expect(reread.contents.synopses[fixture.parentID.uuidString]?.text == "About")
    }

    @Test func aTasksContextIsSetReadAndCleared() throws {
        let fixture = try WorkspaceOverviewFixture()
        let tasks = fixture.makeTaskCoordinator()
        var record = TaskRecord(
            createdAt: Date(timeIntervalSince1970: 50), text: "Add the jig's clamp\nand its bolts",
            title: "Clamp the jig", slug: "clamp-the-jig", source: .cli, projectRoot: "/work/bike"
        )
        record.pullRequestURL = "https://github.com/o/r/pull/12"
        record.mergedAt = Date(timeIntervalSince1970: 90)
        record.mergeCommit = "abc1234"
        try tasks.records.insert(record)

        let empty = try fixture.query(.workspaceTaskContext, ["taskID": .string(record.id.uuidString)])
        #expect(empty["text"] == .null)
        #expect(empty["continuation"]?.objectValue?["hasWrittenContext"] == .bool(false))

        let written = try fixture.run(.workspaceTaskContextSet, [
            "taskID": .string(record.id.uuidString),
            "text": .string("## What was done\n- Added the clamp\n\n## Remaining\n- Order bolts"),
        ])
        #expect(written["text"] == .string("## What was done\n- Added the clamp\n\n## Remaining\n- Order bolts"))
        let read = try fixture.query(.workspaceTaskContext, ["taskID": .string(record.id.uuidString)])
        let continuation = try #require(read["continuation"]?.objectValue)
        #expect(continuation["fileName"] == .string("continues-clamp-the-jig.md"))
        #expect(continuation["hasWrittenContext"] == .bool(true))
        let text = try #require(continuation["text"]?.stringValue)
        #expect(text.hasPrefix("# Continues \u{201C}Clamp the jig\u{201D}"))
        #expect(text.contains("- Task: [Clamp the jig](toastty://task/\(record.id.uuidString))"))
        #expect(text.contains("- Pull request: https://github.com/o/r/pull/12, merged as `abc1234`"))
        #expect(text.contains("- Project folder: `/work/bike`"))
        #expect(text.contains("> Add the jig's clamp\n> and its bolts"))
        #expect(text.contains("## Context from its agent\n\n### What was done\n- Added the clamp\n\n### Remaining"))

        _ = try fixture.run(.workspaceTaskContextSet, ["taskID": .string(record.id.uuidString), "text": .string(" ")])
        #expect(fixture.service.context(taskID: record.id) == nil)
        #expect(throws: AutomationSocketError.self) {
            try fixture.run(.workspaceTaskContextSet, ["text": .string("no task")])
        }
        withExtendedLifetime(tasks) {}
    }

    @Test func aContinuationWithoutAContextCarriesTheLastReply() throws {
        let fixture = try WorkspaceOverviewFixture()
        let record = TaskRecord(createdAt: Date(), text: "Plan welds", title: "Plan welds", slug: "plan-welds", source: .cli)
        try fixture.service.overviewStore.update {
            $0.outcomes[record.id.uuidString] = WorkspaceTaskOutcome(text: "Wrote the weld order.", at: Date())
        }
        let continuation = fixture.service.continuation(of: record)
        #expect(continuation.hasWrittenContext == false)
        #expect(continuation.text.contains("## Its agent's last reply"))
        #expect(continuation.text.contains("Wrote the weld order."))
        #expect(continuation.text.contains("## Context from its agent") == false)
    }

    @Test func theAgentsHeadingsNestUnderTheContextHeading() {
        #expect(TaskContinuation.nestedHeadings("# Goal\ntext\n```\n# a shell comment\n```\n## State")
            == "## Goal\ntext\n```\n# a shell comment\n```\n### State")
    }

    @Test func aFileFromBeforeContextsStillReads() throws {
        let fixture = try WorkspaceOverviewFixture()
        let url = fixture.tempURL.appendingPathComponent("old-overview.json")
        try Data(#"{"version":1,"scratchpads":[],"synopses":{},"outcomes":{}}"#.utf8).write(to: url)
        let store = WorkspaceOverviewStore(fileURL: url)
        #expect(store.contents.contexts.isEmpty)
        #expect(store.contents.version == 1)
    }

    @Test func generatedSynopsisNamesTheFolderAndLatestTasks() {
        #expect(WorkspaceOverviewModel.generatedSynopsis(title: "New house", projectRoot: nil, items: [], finished: 0)
            == "It has no tasks yet.")
    }

    @Test func browserPinsSaveTheCurrentPageInTheParentAndSurviveTheSource() throws {
        let fixture = try WorkspaceOverviewFixture()
        let service = fixture.service
        let store = fixture.store
        let url = "https://example.com/docs#setup"
        #expect(store.send(.setWorkspaceRootDirectory(workspaceID: fixture.parentID, rootDirectory: fixture.tempURL.path)))
        #expect(store.createBrowserPanel(
            workspaceID: fixture.taskSpaceID,
            request: BrowserPanelCreateRequest(initialURL: "https://example.com/", placementOverride: .rightPanel)
        ))
        let source = try #require(store.state.workspacesByID[fixture.taskSpaceID]?.rightAuxPanel.activePanelID)
        #expect(store.send(.updateWebPanelMetadata(panelID: source, title: "Setup Guide", url: url)))
        let result = try service.pinBrowser(panelID: source)
        #expect(result.workspaceID == fixture.parentID)
        #expect(result.created)
        #expect(try service.pinBrowser(panelID: source).created == false)
        let pins = service.browserPins(forWorkspace: fixture.parentID)
        #expect(pins.count == 1)
        let pin = try #require(pins.first)
        #expect(pin.url == url)
        #expect(pin.title == "Setup Guide")
        #expect(service.browserPins(forWorkspace: fixture.taskSpaceID).isEmpty)
        #expect(throws: WorkspaceOverviewError.browserNotPinned) {
            try service.openBrowser(pin, in: fixture.taskSpaceID)
        }
        #expect(store.send(.updateWebPanelMetadata(panelID: source, title: "Another Page", url: "https://example.com/other")))
        #expect(store.send(.closeWorkspace(workspaceID: fixture.taskSpaceID)))
        let taskID = UUID().uuidString
        let context = WorkspaceTaskContext(text: "Continue the release", at: Date(), sessionID: nil, taskTitle: "Release")
        try service.overviewStore.update { $0.contexts[taskID] = context }
        let reread = WorkspaceOverviewStore(fileURL: service.overviewStore.fileURL)
        #expect(reread.contents.browserPins == [pin])
        #expect(reread.contents.contexts[taskID] == context)
        #expect(service.browserPins(forWorkspace: fixture.parentID) == [pin])

        // As with Scratchpads, reopening the project under a new workspace ID finds the pin.
        let before = Set(store.state.workspacesByID.keys)
        #expect(store.send(.createWorkspace(windowID: fixture.windowID, title: "Project reopened", activate: true)))
        let reopened = try #require(store.state.workspacesByID.keys.first { !before.contains($0) })
        #expect(store.send(.setWorkspaceRootDirectory(workspaceID: reopened, rootDirectory: fixture.tempURL.path)))
        #expect(service.browserPins(forWorkspace: reopened) == [pin])
    }

    @Test func browserPinsRevealAndReuseRightPanelTabsAndCanBeUnpinned() throws {
        let fixture = try WorkspaceOverviewFixture()
        let store = fixture.store
        let service = fixture.service
        let workspaceID = fixture.parentID
        let url = "file:///tmp/toastty-guide.html"
        #expect(store.createBrowserPanel(
            workspaceID: fixture.taskSpaceID,
            request: BrowserPanelCreateRequest(initialURL: url, placementOverride: .rightPanel)
        ))
        let source = try #require(store.state.workspacesByID[fixture.taskSpaceID]?.rightAuxPanel.activePanelID)
        #expect(try service.pinBrowser(panelID: source).created)
        let pin = try #require(service.browserPins(forWorkspace: workspaceID).first)
        try service.openBrowser(pin, in: workspaceID)
        let panel = try #require(store.state.workspacesByID[workspaceID]?.rightAuxPanel)
        let browser = try #require(panel.orderedTabs.first)
        guard case .web(let web) = browser.panelState else { Issue.record("Expected a browser"); return }
        #expect(web.definition == .browser)
        #expect(web.restorableURL == url)
        #expect(panel.isVisible)

        #expect(store.send(.toggleRightAuxPanel(workspaceID: workspaceID)))
        try service.openBrowser(pin, in: workspaceID)
        let reopened = try #require(store.state.workspacesByID[workspaceID]?.rightAuxPanel)
        #expect(reopened.isVisible)
        #expect(reopened.activeTabID == browser.id)
        #expect(reopened.orderedTabs.count == 1)

        try service.unpinBrowser(pin, in: workspaceID)
        #expect(service.browserPins(forWorkspace: workspaceID).isEmpty)
        #expect(store.state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID == browser.id)
        #expect(WorkspaceOverviewStore(fileURL: service.overviewStore.fileURL).contents.browserPins.isEmpty)
    }

    @Test func olderOverviewFilesAndBlankBrowsersStillWork() throws {
        let fixture = try WorkspaceOverviewFixture()
        let file = fixture.service.overviewStore.fileURL
        try Data("""
        {"version":1,"scratchpads":[],"outcomes":{},"synopses":{"old":{"text":"About","updatedAt":0}}}
        """.utf8).write(to: file)
        let reread = WorkspaceOverviewStore(fileURL: file)
        #expect(reread.contents.synopses["old"]?.text == "About")
        #expect(reread.contents.browserPins.isEmpty)
        #expect(WorkspaceOverviewService.pinnableBrowserURL(.init(definition: .browser)) == nil)
        #expect(WorkspaceOverviewService.pinnableBrowserURL(.init(
            definition: .browser, initialURL: "https://example.com", currentURL: "about:blank"
        )) == nil)
    }
}

@MainActor
private final class WorkspaceOverviewFixture {
    let tempURL: URL
    let store: AppStore
    let documentStore: ScratchpadDocumentStore
    let executor: AppControlExecutor
    let sessionRuntimeStore: SessionRuntimeStore
    let service: WorkspaceOverviewService
    let windowID: UUID
    let parentID: UUID
    let taskSpaceID: UUID
    let sourcePanelID: UUID
    let sessionID = "sess-workspace-overview"

    init() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        store = AppStore(persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        windowID = selection.windowID
        parentID = selection.workspaceID
        #expect(store.send(.renameWorkspace(workspaceID: parentID, title: "Project")))
        let before = Set(store.state.window(id: windowID)?.workspaceIDs ?? [])
        #expect(store.send(.createWorkspace(windowID: windowID, title: "task-space", activate: true)))
        taskSpaceID = try #require(store.state.window(id: windowID)?.workspaceIDs.first { before.contains($0) == false })
        #expect(store.send(.setWorkspaceParent(workspaceID: taskSpaceID, parentWorkspaceID: parentID, spawningSessionID: nil)))
        sourcePanelID = try #require(store.state.workspacesByID[taskSpaceID]?.focusedPanelID)

        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry(
            scratchpadDocumentStore: ScratchpadDocumentStore(directoryURL: tempURL.appendingPathComponent("scratchpads", isDirectory: true))
        )
        documentStore = webPanelRuntimeRegistry.scratchpadDocumentStore
        sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-test.sock" }
        )
        executor = AppControlExecutor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: FocusedPanelCommandController(
                store: store,
                runtimeRegistry: terminalRuntimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            agentLaunchService: agentLaunchService,
            reloadConfigurationAction: nil
        )
        service = WorkspaceOverviewService(
            store: store,
            documentStore: documentStore,
            overviewStore: WorkspaceOverviewStore(fileURL: tempURL.appendingPathComponent("workspace-overview.json")),
            coordinator: nil,
            board: nil
        )
        WorkspaceOverviewService.current = service
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: sourcePanelID,
            windowID: windowID,
            workspaceID: taskSpaceID,
            codexStatusTrackingSource: .externallyReported,
            displayTitleOverride: "Codex",
            cwd: tempURL.path,
            repoRoot: tempURL.path,
            at: Date(timeIntervalSince1970: 100)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: tempURL)
    }

    /// A task coordinator the service and the commands read records from.
    /// The caller keeps it alive (the service holds it weakly).
    func makeTaskCoordinator() -> TaskCoordinator {
        let tasks = TaskCoordinator(
            records: TaskRecordStore(fileURL: tempURL.appendingPathComponent("tasks.json")),
            store: store, launcher: nil,
            configLoader: { TasksConfig() },
            attachmentsDirectoryURL: tempURL.appendingPathComponent("attachments"),
            hasActiveSession: { _ in false }, grantScope: { _, _ in }
        )
        service.coordinator = tasks
        return tasks
    }

    /// Sets the session's default Scratchpad, as an agent's set-content does.
    func setContent(_ content: String, title: String) throws -> UUID {
        let result = try run(.panelScratchpadSetContent, [
            "sessionID": .string(sessionID), "content": .string(content), "title": .string(title),
        ])
        return try documentUUID(result)
    }

    @discardableResult
    func run(_ action: AppControlActionID, _ args: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        try executor.runAction(id: action.rawValue, args: args).result ?? [:]
    }

    func query(_ query: AppControlQueryID, _ args: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        try executor.runQuery(id: query.rawValue, args: args)
    }
}

/// The `documentID` a command returned.
private func documentUUID(_ result: [String: AutomationJSONValue], sourceLocation: SourceLocation = #_sourceLocation) throws -> UUID {
    let text = try #require(result["documentID"]?.stringValue, sourceLocation: sourceLocation)
    return try #require(UUID(uuidString: text), sourceLocation: sourceLocation)
}

private extension AutomationJSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: AutomationJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayCount: Int? {
        if case .array(let value) = self { return value.count }
        return nil
    }

    var firstObject: [String: AutomationJSONValue]? {
        if case .array(let value) = self { return value.first?.objectValue }
        return nil
    }
}
