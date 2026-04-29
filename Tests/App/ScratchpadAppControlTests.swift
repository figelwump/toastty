@testable import ToasttyApp
import CoreState
import Foundation
import Testing

@MainActor
struct ScratchpadAppControlTests {
    @Test
    func setContentFromFileCreatesSessionLinkedScratchpadAndRestoresTerminalFocus() throws {
        let fixture = try ScratchpadAppControlFixture()
        let contentURL = try fixture.writeContent("<h1>Architecture</h1>")

        let response = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "filePath": .string(contentURL.path),
                "title": .string("Architecture"),
            ]
        )

        let result = try #require(response.result)
        let scratchpadPanelIDString = try #require(result.string("panelID"))
        let scratchpadPanelID = try #require(UUID(uuidString: scratchpadPanelIDString))
        let documentIDString = try #require(result.string("documentID"))
        let documentID = try #require(UUID(uuidString: documentIDString))
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let selectedTab = try #require(workspace.selectedTab)
        let panelState = try #require(workspace.panelState(for: scratchpadPanelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should be a web panel")
            return
        }
        let loadedDocument = try fixture.documentStore.load(documentID: documentID)
        let document = try #require(loadedDocument)
        let stateResult = try fixture.executor.runQuery(
            id: AppControlQueryID.panelScratchpadState.rawValue,
            args: [:]
        )

        #expect(response.didMutateState)
        #expect(result.string("windowID") == fixture.windowID.uuidString)
        #expect(result.string("workspaceID") == fixture.workspaceID.uuidString)
        #expect(result.int("revision") == 1)
        #expect(result.bool("created") == true)
        #expect(workspace.focusedPanelID == fixture.sourcePanelID)
        #expect(workspace.unreadPanelIDs.contains(scratchpadPanelID))
        #expect(selectedTab.panels[scratchpadPanelID] == nil)
        #expect(selectedTab.rightAuxPanel.isVisible)
        #expect(selectedTab.rightAuxPanel.activePanelID == scratchpadPanelID)
        #expect(selectedTab.rightAuxPanel.panelState(for: scratchpadPanelID) != nil)
        #expect(stateResult.string("panelID") == scratchpadPanelIDString)

        #expect(
            fixture.store.send(
                .createWebPanel(
                    workspaceID: fixture.workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Docs"),
                    placement: .rightPanel
                )
            )
        )
        let inactiveStateResult = try fixture.executor.runQuery(
            id: AppControlQueryID.panelScratchpadState.rawValue,
            args: [:]
        )
        #expect(inactiveStateResult.string("panelID") == scratchpadPanelIDString)

        #expect(webState.definition == .scratchpad)
        #expect(webState.title == "Architecture")
        #expect(webState.scratchpad?.documentID == documentID)
        #expect(webState.scratchpad?.revision == 1)
        #expect(webState.scratchpad?.sessionLink?.sessionID == fixture.sessionID)
        #expect(webState.scratchpad?.sessionLink?.sourcePanelID == fixture.sourcePanelID)
        #expect(document.content == "<h1>Architecture</h1>")
    }

    @Test
    func repeatedSetContentUpdatesSamePanelAndAdvancesRevision() throws {
        let fixture = try ScratchpadAppControlFixture()
        let first = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>First</p>"),
            ]
        )
        let firstResult = try #require(first.result)
        let firstPanelID = firstResult.string("panelID")
        let documentIDString = try #require(firstResult.string("documentID"))
        let documentID = try #require(UUID(uuidString: documentIDString))

        let second = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Second</p>"),
                "expectedRevision": .int(1),
            ]
        )
        let secondResult = try #require(second.result)
        let loadedDocument = try fixture.documentStore.load(documentID: documentID)
        let document = try #require(loadedDocument)

        #expect(secondResult.string("panelID") == firstPanelID)
        #expect(secondResult.bool("created") == false)
        #expect(secondResult.int("revision") == 2)
        #expect(document.revision == 2)
        #expect(document.content == "<p>Second</p>")
    }

    @Test
    func staleExpectedRevisionRejectsWrite() throws {
        let fixture = try ScratchpadAppControlFixture()
        _ = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>First</p>"),
            ]
        )

        #expect(throws: AutomationSocketError.self) {
            try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadSetContent.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "content": .string("<p>Conflict</p>"),
                    "expectedRevision": .int(0),
                ]
            )
        }
    }

    @Test
    func missingSessionRejectsSetContent() throws {
        let fixture = try ScratchpadAppControlFixture()

        #expect(throws: AutomationSocketError.self) {
            try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadSetContent.rawValue,
                args: [
                    "sessionID": .string("missing-session"),
                    "content": .string("<p>Orphan</p>"),
                ]
            )
        }
    }

    @Test
    func rebindMovesScratchpadOwnershipToDestinationSession() throws {
        let fixture = try ScratchpadAppControlFixture()
        let destination = try fixture.createDestinationSession()
        let initial = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Initial</p>"),
                "title": .string("Notes"),
            ]
        )
        let initialResult = try #require(initial.result)
        let scratchpadPanelIDString = try #require(initialResult.string("panelID"))
        let scratchpadPanelID = try #require(UUID(uuidString: scratchpadPanelIDString))
        let documentIDString = try #require(initialResult.string("documentID"))
        let documentID = try #require(UUID(uuidString: documentIDString))

        let rebind = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadRebind.rawValue,
            args: [
                "panelID": .string(scratchpadPanelIDString),
                "sessionID": .string(destination.sessionID),
            ]
        )
        let rebindResult = try #require(rebind.result)
        let reboundDocument = try #require(try fixture.documentStore.load(documentID: documentID))
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let reboundPanelState = try #require(workspace.panelState(for: scratchpadPanelID))
        guard case .web(let reboundWebState) = reboundPanelState else {
            Issue.record("scratchpad panel should stay a web panel")
            return
        }

        #expect(rebind.didMutateState)
        #expect(rebindResult.string("sessionID") == destination.sessionID)
        #expect(rebindResult.int("revision") == 1)
        #expect(reboundWebState.scratchpad?.revision == 1)
        #expect(reboundWebState.scratchpad?.sessionLink?.sessionID == destination.sessionID)
        #expect(reboundWebState.scratchpad?.sessionLink?.sourcePanelID == destination.panelID)
        #expect(reboundDocument.revision == 1)
        #expect(reboundDocument.content == "<p>Initial</p>")
        #expect(reboundDocument.sessionLink?.sessionID == destination.sessionID)

        let destinationWrite = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(destination.sessionID),
                "content": .string("<p>Destination update</p>"),
                "expectedRevision": .int(1),
            ]
        )
        let destinationResult = try #require(destinationWrite.result)
        #expect(destinationResult.string("panelID") == scratchpadPanelIDString)
        #expect(destinationResult.bool("created") == false)
        #expect(destinationResult.int("revision") == 2)

        let sourceWrite = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Source update</p>"),
            ]
        )
        let sourceResult = try #require(sourceWrite.result)
        #expect(sourceResult.bool("created") == true)
        #expect(sourceResult.string("panelID") != scratchpadPanelIDString)
    }

    @Test
    func createBlankScratchpadCreatesUnboundRightPanelDocument() throws {
        let fixture = try ScratchpadAppControlFixture()

        let outcome = try fixture.store.createBlankScratchpadPanel(
            workspaceID: fixture.workspaceID,
            documentStore: fixture.documentStore
        )
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let selectedTab = try #require(workspace.selectedTab)
        let panelState = try #require(workspace.panelState(for: outcome.panelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should be a web panel")
            return
        }
        let document = try #require(try fixture.documentStore.load(documentID: outcome.documentID))

        #expect(outcome.windowID == fixture.windowID)
        #expect(outcome.workspaceID == fixture.workspaceID)
        #expect(outcome.revision == 1)
        #expect(selectedTab.panels[outcome.panelID] == nil)
        #expect(selectedTab.rightAuxPanel.isVisible)
        #expect(selectedTab.rightAuxPanel.activePanelID == outcome.panelID)
        #expect(webState.definition == .scratchpad)
        #expect(webState.title == "Scratchpad")
        #expect(webState.scratchpad?.documentID == outcome.documentID)
        #expect(webState.scratchpad?.revision == 1)
        #expect(webState.scratchpad?.sessionLink == nil)
        #expect(document.content == "")
        #expect(document.title == nil)
        #expect(document.sessionLink == nil)
    }

    @Test
    func unbindScratchpadClearsPanelAndDocumentSessionLink() throws {
        let fixture = try ScratchpadAppControlFixture()
        let initial = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Initial</p>"),
                "title": .string("Notes"),
            ]
        )
        let initialResult = try #require(initial.result)
        let scratchpadPanelIDString = try #require(initialResult.string("panelID"))
        let scratchpadPanelID = try #require(UUID(uuidString: scratchpadPanelIDString))
        let documentIDString = try #require(initialResult.string("documentID"))
        let documentID = try #require(UUID(uuidString: documentIDString))

        let outcome = try fixture.store.unbindScratchpadPanel(
            panelID: scratchpadPanelID,
            documentStore: fixture.documentStore
        )
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelState = try #require(workspace.panelState(for: scratchpadPanelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should stay a web panel")
            return
        }
        let document = try #require(try fixture.documentStore.load(documentID: documentID))

        #expect(outcome.windowID == fixture.windowID)
        #expect(outcome.workspaceID == fixture.workspaceID)
        #expect(outcome.panelID == scratchpadPanelID)
        #expect(outcome.documentID == documentID)
        #expect(outcome.revision == 1)
        #expect(webState.scratchpad?.documentID == documentID)
        #expect(webState.scratchpad?.revision == 1)
        #expect(webState.scratchpad?.sessionLink == nil)
        #expect(document.content == "<p>Initial</p>")
        #expect(document.sessionLink == nil)
    }

    @Test
    func cleanupStaleScratchpadSessionLinksClearsRightPanelStateAndDocumentLink() throws {
        let fixture = try ScratchpadAppControlFixture()
        let linkedScratchpad = try fixture.createLinkedScratchpad()

        let outcome = fixture.store.cleanupStaleScratchpadSessionLinks(
            sessionRegistry: SessionRegistry(),
            documentStore: fixture.documentStore
        )
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelState = try #require(workspace.panelState(for: linkedScratchpad.panelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should stay a web panel")
            return
        }
        let document = try #require(try fixture.documentStore.load(documentID: linkedScratchpad.documentID))

        #expect(outcome.clearedPanelIDs == [linkedScratchpad.panelID])
        #expect(outcome.clearedDocumentIDs == [linkedScratchpad.documentID])
        #expect(outcome.failures.isEmpty)
        #expect(webState.scratchpad?.documentID == linkedScratchpad.documentID)
        #expect(webState.scratchpad?.sessionLink == nil)
        #expect(document.content == "<p>Initial</p>")
        #expect(document.sessionLink == nil)
    }

    @Test
    func cleanupStaleScratchpadSessionLinksPreservesActiveSessionLink() throws {
        let fixture = try ScratchpadAppControlFixture()
        let linkedScratchpad = try fixture.createLinkedScratchpad()

        let outcome = fixture.store.cleanupStaleScratchpadSessionLinks(
            sessionRegistry: fixture.sessionRuntimeStore.sessionRegistry,
            documentStore: fixture.documentStore
        )
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelState = try #require(workspace.panelState(for: linkedScratchpad.panelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should stay a web panel")
            return
        }
        let document = try #require(try fixture.documentStore.load(documentID: linkedScratchpad.documentID))

        #expect(outcome.clearedPanelIDs.isEmpty)
        #expect(outcome.clearedDocumentIDs.isEmpty)
        #expect(outcome.failures.isEmpty)
        #expect(webState.scratchpad?.sessionLink?.sessionID == fixture.sessionID)
        #expect(document.sessionLink?.sessionID == fixture.sessionID)
    }

    @Test
    func cleanupStaleScratchpadSessionLinksClearsStoppedSessionLink() throws {
        let fixture = try ScratchpadAppControlFixture()
        let linkedScratchpad = try fixture.createLinkedScratchpad()
        fixture.sessionRuntimeStore.stopSession(
            sessionID: fixture.sessionID,
            at: Date(timeIntervalSince1970: 300)
        )

        let outcome = fixture.store.cleanupStaleScratchpadSessionLinks(
            sessionRegistry: fixture.sessionRuntimeStore.sessionRegistry,
            documentStore: fixture.documentStore
        )
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelState = try #require(workspace.panelState(for: linkedScratchpad.panelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should stay a web panel")
            return
        }
        let document = try #require(try fixture.documentStore.load(documentID: linkedScratchpad.documentID))

        #expect(outcome.clearedPanelIDs == [linkedScratchpad.panelID])
        #expect(outcome.failures.isEmpty)
        #expect(webState.scratchpad?.sessionLink == nil)
        #expect(document.sessionLink == nil)
    }

    @Test
    func cleanupCoordinatorClearsStaleLinkAfterStartup() async throws {
        let fixture = try ScratchpadAppControlFixture()
        let linkedScratchpad = try fixture.createLinkedScratchpad()
        let restoredSessionRuntimeStore = SessionRuntimeStore()
        restoredSessionRuntimeStore.bind(store: fixture.store)
        let coordinator = ScratchpadSessionLinkCleanupCoordinator(
            store: fixture.store,
            sessionRuntimeStore: restoredSessionRuntimeStore,
            documentStore: fixture.documentStore,
            cleanupDelayNanoseconds: 0
        )

        try await fixture.waitForScratchpadSessionLink(
            documentID: linkedScratchpad.documentID,
            toBecome: nil
        )
        let restoredState = WorkspaceLayoutSnapshot(state: fixture.store.state).makeAppState()
        let restoredWorkspace = try #require(restoredState.workspacesByID[fixture.workspaceID])
        let restoredPanelState = try #require(restoredWorkspace.panelState(for: linkedScratchpad.panelID))
        guard case .web(let restoredWebState) = restoredPanelState else {
            Issue.record("scratchpad panel should restore as a web panel")
            return
        }

        #expect(restoredWebState.scratchpad?.sessionLink == nil)
        _ = coordinator
    }

    @Test
    func cleanupCoordinatorClearsLinkWhenActiveSessionStops() async throws {
        let fixture = try ScratchpadAppControlFixture()
        let linkedScratchpad = try fixture.createLinkedScratchpad()
        let coordinator = ScratchpadSessionLinkCleanupCoordinator(
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            documentStore: fixture.documentStore,
            cleanupDelayNanoseconds: 0
        )

        fixture.sessionRuntimeStore.updateStatus(
            sessionID: fixture.sessionID,
            status: SessionStatus(kind: .working, summary: "Working"),
            at: Date(timeIntervalSince1970: 250)
        )
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(try fixture.documentStore.load(documentID: linkedScratchpad.documentID)?.sessionLink?.sessionID == fixture.sessionID)

        fixture.sessionRuntimeStore.stopSession(
            sessionID: fixture.sessionID,
            at: Date(timeIntervalSince1970: 300)
        )

        try await fixture.waitForScratchpadSessionLink(
            documentID: linkedScratchpad.documentID,
            toBecome: nil
        )
        _ = coordinator
    }

    @Test
    func exportWritesSessionLinkedScratchpadToDeterministicFile() throws {
        let fixture = try ScratchpadAppControlFixture()
        let response = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<h1>Export me</h1>"),
                "title": .string("Export me"),
            ]
        )
        let result = try #require(response.result)
        let panelIDString = try #require(result.string("panelID"))
        let documentIDString = try #require(result.string("documentID"))

        let export = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadExport.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
            ]
        )
        let exportResult = try #require(export.result)
        let filePath = try #require(exportResult.string("filePath"))
        let exportedHTML = try String(contentsOfFile: filePath, encoding: .utf8)

        #expect(export.didMutateState == false)
        #expect(exportResult.string("panelID") == panelIDString)
        #expect(exportResult.string("documentID") == documentIDString)
        #expect(exportResult.int("revision") == 1)
        #expect(exportResult.string("title") == "Export me")
        #expect(filePath.hasSuffix("\(documentIDString).html"))
        #expect(exportedHTML == "<h1>Export me</h1>")
    }

    @Test
    func exportRejectsSessionLinkedScratchpadWorkspaceSelectorMismatch() throws {
        let fixture = try ScratchpadAppControlFixture()
        _ = try fixture.createLinkedScratchpad()
        #expect(fixture.store.send(.createWorkspace(windowID: fixture.windowID, title: "Other", activate: true)))
        let secondWorkspaceID = try #require(fixture.store.state.window(id: fixture.windowID)?.selectedWorkspaceID)

        do {
            _ = try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadExport.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "workspaceID": .string(secondWorkspaceID.uuidString),
                ]
            )
            Issue.record("export should reject a workspaceID that does not own the session-linked Scratchpad")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message == "sessionID Scratchpad does not belong to workspaceID")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func exportRejectsSessionLinkedScratchpadWindowSelectorMismatch() throws {
        let fixture = try ScratchpadAppControlFixture()
        _ = try fixture.createLinkedScratchpad()
        #expect(fixture.store.createWindowFromCommand(preferredWindowID: nil))
        let secondWindowID = try #require(fixture.store.state.selectedWindowID)
        #expect(secondWindowID != fixture.windowID)

        do {
            _ = try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadExport.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "windowID": .string(secondWindowID.uuidString),
                ]
            )
            Issue.record("export should reject a windowID that does not own the session-linked Scratchpad")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message == "sessionID Scratchpad does not belong to windowID")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@MainActor
private final class ScratchpadAppControlFixture {
    let tempURL: URL
    let store: AppStore
    let documentStore: ScratchpadDocumentStore
    let executor: AppControlExecutor
    let sessionRuntimeStore: SessionRuntimeStore
    let windowID: UUID
    let workspaceID: UUID
    let sourcePanelID: UUID
    let sessionID = "sess-scratchpad"

    init() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)

        store = AppStore(persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        windowID = selection.windowID
        workspaceID = selection.workspaceID
        sourcePanelID = try #require(selection.workspace.focusedPanelID)

        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry(
            scratchpadDocumentStore: ScratchpadDocumentStore(
                directoryURL: tempURL.appendingPathComponent("scratchpads", isDirectory: true)
            )
        )
        documentStore = webPanelRuntimeRegistry.scratchpadDocumentStore
        sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)

        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
        )
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
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService,
            reloadConfigurationAction: nil
        )
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: sourcePanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "Codex",
            cwd: tempURL.path,
            repoRoot: tempURL.path,
            at: Date(timeIntervalSince1970: 100)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func writeContent(_ content: String) throws -> URL {
        let url = tempURL.appendingPathComponent("scratchpad.html")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func createLinkedScratchpad() throws -> (panelID: UUID, documentID: UUID) {
        let initial = try executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(sessionID),
                "content": .string("<p>Initial</p>"),
                "title": .string("Notes"),
            ]
        )
        let result = try #require(initial.result)
        let panelIDString = try #require(result.string("panelID"))
        let panelID = try #require(UUID(uuidString: panelIDString))
        let documentIDString = try #require(result.string("documentID"))
        let documentID = try #require(UUID(uuidString: documentIDString))
        return (panelID, documentID)
    }

    func waitForScratchpadSessionLink(
        documentID: UUID,
        toBecome expectedSessionID: String?,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollNanoseconds: UInt64 = 10_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let document = try documentStore.load(documentID: documentID)
            if document?.sessionLink?.sessionID == expectedSessionID {
                return
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }

        let document = try documentStore.load(documentID: documentID)
        #expect(document?.sessionLink?.sessionID == expectedSessionID)
    }

    func createDestinationSession() throws -> (panelID: UUID, sessionID: String) {
        let workspaceBefore = try #require(store.state.workspacesByID[workspaceID])
        let beforePanelIDs = Set(workspaceBefore.layoutTree.allSlotInfos.map(\.panelID))
        #expect(store.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .vertical)))
        let workspace = try #require(store.state.workspacesByID[workspaceID])
        let panelID = try #require(
            workspace.layoutTree.allSlotInfos
                .map(\.panelID)
                .first { beforePanelIDs.contains($0) == false }
        )
        let sessionID = "sess-destination"
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: .claude,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "Claude",
            cwd: tempURL.path,
            repoRoot: tempURL.path,
            at: Date(timeIntervalSince1970: 200)
        )
        return (panelID, sessionID)
    }
}
