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
        #expect(selectedTab.rightAuxPanel.focusedPanelID == nil)
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
    func setContentCreatesScratchpadInBackgroundWorkspaceWithoutChangingVisibleSelection() throws {
        let fixture = try ScratchpadAppControlFixture()
        let sourceWorkspaceBefore = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let sourceTabIDBefore = sourceWorkspaceBefore.selectedTabID

        #expect(fixture.store.send(.createWorkspace(windowID: fixture.windowID, title: "Visible", activate: true)))
        let visibleWorkspaceID = try #require(fixture.store.state.selectedWorkspaceID(in: fixture.windowID))
        let visibleWorkspaceBefore = try #require(fixture.store.state.workspacesByID[visibleWorkspaceID])
        let visibleFocusedPanelIDBefore = visibleWorkspaceBefore.focusedPanelID
        #expect(visibleWorkspaceID != fixture.workspaceID)

        let response = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Background workspace</p>"),
                "title": .string("Background"),
            ]
        )
        let result = try #require(response.result)
        let scratchpadPanelIDString = try #require(result.string("panelID"))
        let scratchpadPanelID = try #require(UUID(uuidString: scratchpadPanelIDString))
        let sourceWorkspaceAfter = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let sourceTabID = try #require(sourceTabIDBefore)
        let sourceTabAfter = try #require(sourceWorkspaceAfter.tab(id: sourceTabID))
        let visibleWorkspaceAfter = try #require(fixture.store.state.workspacesByID[visibleWorkspaceID])
        let panelState = try #require(sourceTabAfter.rightAuxPanel.panelState(for: scratchpadPanelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should be a web panel")
            return
        }

        #expect(response.didMutateState)
        #expect(fixture.store.state.selectedWorkspaceID(in: fixture.windowID) == visibleWorkspaceID)
        #expect(visibleWorkspaceAfter.focusedPanelID == visibleFocusedPanelIDBefore)
        #expect(sourceWorkspaceAfter.selectedTabID == sourceTabIDBefore)
        #expect(sourceTabAfter.rightAuxPanel.isVisible == false)
        #expect(sourceTabAfter.rightAuxPanel.focusedPanelID == nil)
        #expect(sourceTabAfter.unreadPanelIDs.contains(scratchpadPanelID))
        #expect(webState.definition == .scratchpad)
        #expect(webState.scratchpad?.sessionLink?.sessionID == fixture.sessionID)

        try StateValidator.validate(fixture.store.state)
    }

    @Test
    func setContentCreatesScratchpadInBackgroundTabWithoutChangingSelectedTab() throws {
        let fixture = try ScratchpadAppControlFixture()
        let sourceWorkspaceBefore = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let sourceTabID = try #require(sourceWorkspaceBefore.selectedTabID)

        #expect(fixture.store.send(.createWorkspaceTab(workspaceID: fixture.workspaceID, seed: nil)))
        let workspaceBefore = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let selectedTabIDBefore = try #require(workspaceBefore.selectedTabID)
        let focusedPanelIDBefore = workspaceBefore.focusedPanelID
        #expect(selectedTabIDBefore != sourceTabID)

        let response = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Background tab</p>"),
                "title": .string("Background Tab"),
            ]
        )
        let result = try #require(response.result)
        let scratchpadPanelIDString = try #require(result.string("panelID"))
        let scratchpadPanelID = try #require(UUID(uuidString: scratchpadPanelIDString))
        let workspaceAfter = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let sourceTabAfter = try #require(workspaceAfter.tab(id: sourceTabID))
        let selectedTabAfter = try #require(workspaceAfter.tab(id: selectedTabIDBefore))
        let panelState = try #require(sourceTabAfter.rightAuxPanel.panelState(for: scratchpadPanelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should be a web panel")
            return
        }

        #expect(response.didMutateState)
        #expect(workspaceAfter.selectedTabID == selectedTabIDBefore)
        #expect(selectedTabAfter.focusedPanelID == focusedPanelIDBefore)
        #expect(sourceTabAfter.rightAuxPanel.isVisible == false)
        #expect(sourceTabAfter.rightAuxPanel.focusedPanelID == nil)
        #expect(sourceTabAfter.unreadPanelIDs.contains(scratchpadPanelID))
        #expect(webState.definition == .scratchpad)
        #expect(webState.scratchpad?.sessionLink?.sourcePanelID == fixture.sourcePanelID)

        try StateValidator.validate(fixture.store.state)
    }

    @Test
    func setContentCreatesScratchpadInBackgroundWindowWithoutChangingSelectedWindow() throws {
        let fixture = try ScratchpadAppControlFixture()
        let firstWindowSelectedWorkspaceID = try #require(fixture.store.state.selectedWorkspaceID(in: fixture.windowID))
        #expect(fixture.store.createWindowFromCommand(preferredWindowID: nil))
        let selectedWindowIDBefore = try #require(fixture.store.state.selectedWindowID)
        let selectedWindowWorkspaceIDBefore = try #require(
            fixture.store.state.selectedWorkspaceID(in: selectedWindowIDBefore)
        )
        #expect(selectedWindowIDBefore != fixture.windowID)

        let response = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Background window</p>"),
            ]
        )
        let result = try #require(response.result)
        let scratchpadPanelIDString = try #require(result.string("panelID"))
        let scratchpadPanelID = try #require(UUID(uuidString: scratchpadPanelIDString))
        let sourceWorkspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let sourceTabID = try #require(sourceWorkspace.selectedTabID)
        let sourceTab = try #require(sourceWorkspace.tab(id: sourceTabID))

        #expect(response.didMutateState)
        #expect(fixture.store.state.selectedWindowID == selectedWindowIDBefore)
        #expect(fixture.store.state.selectedWorkspaceID(in: fixture.windowID) == firstWindowSelectedWorkspaceID)
        #expect(fixture.store.state.selectedWorkspaceID(in: selectedWindowIDBefore) == selectedWindowWorkspaceIDBefore)
        #expect(sourceTab.rightAuxPanel.panelState(for: scratchpadPanelID) != nil)
        #expect(sourceTab.unreadPanelIDs.contains(scratchpadPanelID))

        try StateValidator.validate(fixture.store.state)
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
    func repeatedSetContentUpdatesBackgroundScratchpadWithoutChangingVisibleSelection() throws {
        let fixture = try ScratchpadAppControlFixture()
        let initial = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Initial</p>"),
            ]
        )
        let initialResult = try #require(initial.result)
        let initialPanelID = try #require(initialResult.string("panelID"))
        let documentIDString = try #require(initialResult.string("documentID"))
        let documentID = try #require(UUID(uuidString: documentIDString))

        #expect(fixture.store.send(.createWorkspace(windowID: fixture.windowID, title: "Visible", activate: true)))
        let visibleWorkspaceID = try #require(fixture.store.state.selectedWorkspaceID(in: fixture.windowID))
        let visibleWorkspaceBefore = try #require(fixture.store.state.workspacesByID[visibleWorkspaceID])
        let visibleFocusedPanelIDBefore = visibleWorkspaceBefore.focusedPanelID

        let second = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Updated in background</p>"),
                "expectedRevision": .int(1),
            ]
        )
        let secondResult = try #require(second.result)
        let document = try #require(try fixture.documentStore.load(documentID: documentID))
        let visibleWorkspaceAfter = try #require(fixture.store.state.workspacesByID[visibleWorkspaceID])

        #expect(second.didMutateState)
        #expect(secondResult.string("panelID") == initialPanelID)
        #expect(secondResult.bool("created") == false)
        #expect(secondResult.int("revision") == 2)
        #expect(fixture.store.state.selectedWorkspaceID(in: fixture.windowID) == visibleWorkspaceID)
        #expect(visibleWorkspaceAfter.focusedPanelID == visibleFocusedPanelIDBefore)
        #expect(document.content == "<p>Updated in background</p>")

        try StateValidator.validate(fixture.store.state)
    }

    @Test
    func patchContentUpdatesLinkedScratchpadWithoutChangingFocus() throws {
        let fixture = try ScratchpadAppControlFixture()
        let linked = try fixture.createLinkedScratchpad()
        let destination = try fixture.createDestinationSession()
        let focusedPanelBefore = fixture.store.state.workspacesByID[fixture.workspaceID]?.focusedPanelID
        let patch = try patchJSON([
            .init(oldText: "<p>Initial</p>", newText: "<p>Patched</p>"),
        ])

        let response = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadPatchContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "patch": .string(patch),
                "expectedRevision": .int(1),
            ]
        )
        let result = try #require(response.result)
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelState = try #require(workspace.panelState(for: linked.panelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should stay a web panel")
            return
        }
        let document = try #require(try fixture.documentStore.load(documentID: linked.documentID))

        #expect(destination.panelID == focusedPanelBefore)
        #expect(response.didMutateState)
        #expect(result.string("windowID") == fixture.windowID.uuidString)
        #expect(result.string("workspaceID") == fixture.workspaceID.uuidString)
        #expect(result.string("panelID") == linked.panelID.uuidString)
        #expect(result.string("documentID") == linked.documentID.uuidString)
        #expect(result.int("previousRevision") == 1)
        #expect(result.int("revision") == 2)
        #expect(result.int("appliedEdits") == 1)
        #expect(result.bool("created") == false)
        #expect(workspace.focusedPanelID == focusedPanelBefore)
        #expect(webState.scratchpad?.revision == 2)
        #expect(webState.scratchpad?.sessionLink?.sessionID == fixture.sessionID)
        #expect(document.revision == 2)
        #expect(document.content == "<p>Patched</p>")
        #expect(document.sessionLink?.sessionID == fixture.sessionID)
    }

    @Test
    func patchContentAliasResolvesToPatchAction() {
        #expect(AppControlActionID.resolve("panel.scratchpad.patchContent") == .panelScratchpadPatchContent)
    }

    @Test
    func patchContentRequiresExistingLinkedScratchpad() throws {
        let fixture = try ScratchpadAppControlFixture()
        let workspaceBefore = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelCountBefore = workspaceBefore.allPanelsByID.count
        let patch = try patchJSON([
            .init(oldText: "missing", newText: "patched"),
        ])

        do {
            _ = try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadPatchContent.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "patch": .string(patch),
                    "expectedRevision": .int(1),
                ]
            )
            Issue.record("patch should reject sessions without a linked Scratchpad")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message == "no Scratchpad is linked to active session: \(fixture.sessionID)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let workspaceAfter = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        #expect(workspaceAfter.allPanelsByID.count == panelCountBefore)
    }

    @Test
    func patchContentRequiresPatchAndExpectedRevision() throws {
        let fixture = try ScratchpadAppControlFixture()
        _ = try fixture.createLinkedScratchpad()
        let patch = try patchJSON([
            .init(oldText: "<p>Initial</p>", newText: "<p>Patched</p>"),
        ])

        do {
            _ = try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadPatchContent.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "expectedRevision": .int(1),
                ]
            )
            Issue.record("patch should require patch")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message == "patch is required")
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        do {
            _ = try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadPatchContent.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "patch": .string(patch),
                ]
            )
            Issue.record("patch should require expectedRevision")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message == "expectedRevision is required")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func patchContentRejectsEmptyOrWhitespacePatchArg() throws {
        let fixture = try ScratchpadAppControlFixture()
        _ = try fixture.createLinkedScratchpad()

        for invalid in ["", "   ", "\n\t "] {
            do {
                _ = try fixture.executor.runAction(
                    id: AppControlActionID.panelScratchpadPatchContent.rawValue,
                    args: [
                        "sessionID": .string(fixture.sessionID),
                        "patch": .string(invalid),
                        "expectedRevision": .int(1),
                    ]
                )
                Issue.record("empty/whitespace patch should be rejected for input \(invalid.debugDescription)")
            } catch AutomationSocketError.invalidPayload(let message) {
                #expect(message == "patch must be non-empty JSON")
            } catch {
                Issue.record("unexpected error for input \(invalid.debugDescription): \(error)")
            }
        }
    }

    @Test
    func patchContentFailureLeavesPanelAndDocumentUnchanged() throws {
        let fixture = try ScratchpadAppControlFixture()
        let linked = try fixture.createLinkedScratchpad()
        let patch = try patchJSON([
            .init(oldText: "<p>Initial</p>", newText: "<p>Patched</p>"),
        ])

        #expect(throws: AutomationSocketError.self) {
            try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadPatchContent.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "patch": .string(patch),
                    "expectedRevision": .int(0),
                ]
            )
        }
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelState = try #require(workspace.panelState(for: linked.panelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should stay a web panel")
            return
        }
        let document = try #require(try fixture.documentStore.load(documentID: linked.documentID))

        #expect(webState.scratchpad?.revision == 1)
        #expect(document.revision == 1)
        #expect(document.content == "<p>Initial</p>")
    }

    @Test
    func patchContentRejectsMissingDocument() throws {
        let fixture = try ScratchpadAppControlFixture()
        let linked = try fixture.createLinkedScratchpad()
        try FileManager.default.removeItem(at: fixture.documentStore.documentURL(for: linked.documentID))
        let patch = try patchJSON([
            .init(oldText: "<p>Initial</p>", newText: "<p>Patched</p>"),
        ])

        #expect(throws: AutomationSocketError.self) {
            try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadPatchContent.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "patch": .string(patch),
                    "expectedRevision": .int(1),
                ]
            )
        }
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelState = try #require(workspace.panelState(for: linked.panelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should stay a web panel")
            return
        }

        #expect(webState.scratchpad?.revision == 1)
    }

    @Test
    func createPolicyNewCreatesFreshLinkedScratchpadAndUnbindsPrevious() throws {
        let fixture = try ScratchpadAppControlFixture()
        let first = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>First</p>"),
                "title": .string("First"),
            ]
        )
        let firstResult = try #require(first.result)
        let firstPanelIDString = try #require(firstResult.string("panelID"))
        let firstPanelID = try #require(UUID(uuidString: firstPanelIDString))
        let firstDocumentIDString = try #require(firstResult.string("documentID"))
        let firstDocumentID = try #require(UUID(uuidString: firstDocumentIDString))

        let second = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Second</p>"),
                "title": .string("Second"),
                "createPolicy": .string("new"),
            ]
        )
        let secondResult = try #require(second.result)
        let secondPanelIDString = try #require(secondResult.string("panelID"))
        let secondPanelID = try #require(UUID(uuidString: secondPanelIDString))
        let secondDocumentIDString = try #require(secondResult.string("documentID"))
        let secondDocumentID = try #require(UUID(uuidString: secondDocumentIDString))
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let firstPanelState = try #require(workspace.panelState(for: firstPanelID))
        let secondPanelState = try #require(workspace.panelState(for: secondPanelID))
        guard case .web(let firstWebState) = firstPanelState,
              case .web(let secondWebState) = secondPanelState else {
            Issue.record("scratchpad panels should be web panels")
            return
        }
        let firstDocument = try #require(try fixture.documentStore.load(documentID: firstDocumentID))
        let secondDocument = try #require(try fixture.documentStore.load(documentID: secondDocumentID))

        #expect(second.didMutateState)
        #expect(secondResult.bool("created") == true)
        #expect(secondPanelID != firstPanelID)
        #expect(secondDocumentID != firstDocumentID)
        #expect(secondResult.int("revision") == 1)
        #expect(firstWebState.scratchpad?.sessionLink == nil)
        #expect(firstDocument.sessionLink == nil)
        #expect(firstDocument.content == "<p>First</p>")
        #expect(secondWebState.scratchpad?.sessionLink?.sessionID == fixture.sessionID)
        #expect(secondDocument.sessionLink?.sessionID == fixture.sessionID)
        #expect(secondDocument.content == "<p>Second</p>")

        let third = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Third</p>"),
                "expectedRevision": .int(1),
            ]
        )
        let thirdResult = try #require(third.result)
        let updatedSecondDocument = try #require(try fixture.documentStore.load(documentID: secondDocumentID))

        #expect(thirdResult.string("panelID") == secondPanelIDString)
        #expect(thirdResult.bool("created") == false)
        #expect(thirdResult.int("revision") == 2)
        #expect(updatedSecondDocument.content == "<p>Third</p>")
    }

    @Test
    func createPolicyNewWithoutExistingScratchpadCreatesLinkedScratchpad() throws {
        let fixture = try ScratchpadAppControlFixture()

        let response = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Fresh</p>"),
                "createPolicy": .string("new"),
            ]
        )
        let result = try #require(response.result)
        let panelIDString = try #require(result.string("panelID"))
        let panelID = try #require(UUID(uuidString: panelIDString))
        let documentIDString = try #require(result.string("documentID"))
        let documentID = try #require(UUID(uuidString: documentIDString))
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelState = try #require(workspace.panelState(for: panelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should be a web panel")
            return
        }
        let document = try #require(try fixture.documentStore.load(documentID: documentID))

        #expect(result.bool("created") == true)
        #expect(webState.scratchpad?.sessionLink?.sessionID == fixture.sessionID)
        #expect(document.sessionLink?.sessionID == fixture.sessionID)
        #expect(document.content == "<p>Fresh</p>")
    }

    @Test
    func createPolicyNewRejectsNonzeroExpectedRevisionBeforeUnbindingExistingScratchpad() throws {
        let fixture = try ScratchpadAppControlFixture()
        let linked = try fixture.createLinkedScratchpad()
        let workspaceBefore = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelCountBefore = workspaceBefore.allPanelsByID.count

        #expect(throws: AutomationSocketError.self) {
            try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadSetContent.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "content": .string("<p>Should not publish</p>"),
                    "expectedRevision": .int(1),
                    "createPolicy": .string("new"),
                ]
            )
        }

        let workspaceAfter = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelState = try #require(workspaceAfter.panelState(for: linked.panelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should stay a web panel")
            return
        }
        let document = try #require(try fixture.documentStore.load(documentID: linked.documentID))

        #expect(workspaceAfter.allPanelsByID.count == panelCountBefore)
        #expect(webState.scratchpad?.sessionLink?.sessionID == fixture.sessionID)
        #expect(document.sessionLink?.sessionID == fixture.sessionID)
        #expect(document.content == "<p>Initial</p>")
    }

    @Test
    func createPolicyNewRejectsMissingExistingDocumentBeforeCreatingReplacement() throws {
        let fixture = try ScratchpadAppControlFixture()
        let linked = try fixture.createLinkedScratchpad()
        let workspaceBefore = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelCountBefore = workspaceBefore.allPanelsByID.count
        try FileManager.default.removeItem(at: fixture.documentStore.documentURL(for: linked.documentID))

        #expect(throws: AutomationSocketError.self) {
            try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadSetContent.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "content": .string("<p>Replacement</p>"),
                    "createPolicy": .string("new"),
                ]
            )
        }

        let workspaceAfter = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let panelState = try #require(workspaceAfter.panelState(for: linked.panelID))
        guard case .web(let webState) = panelState else {
            Issue.record("scratchpad panel should stay a web panel")
            return
        }

        #expect(workspaceAfter.allPanelsByID.count == panelCountBefore)
        #expect(webState.scratchpad?.sessionLink?.sessionID == fixture.sessionID)
        #expect(try fixture.documentStore.load(documentID: linked.documentID) == nil)
    }

    @Test
    func createPolicyNewTwiceMigratesSessionLinkToNewestScratchpad() throws {
        let fixture = try ScratchpadAppControlFixture()
        let first = try fixture.createLinkedScratchpad()
        let second = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Second</p>"),
                "createPolicy": .string("new"),
            ]
        )
        let secondResult = try #require(second.result)
        let secondPanelIDString = try #require(secondResult.string("panelID"))
        let secondPanelID = try #require(UUID(uuidString: secondPanelIDString))
        let secondDocumentIDString = try #require(secondResult.string("documentID"))
        let secondDocumentID = try #require(UUID(uuidString: secondDocumentIDString))

        let third = try fixture.executor.runAction(
            id: AppControlActionID.panelScratchpadSetContent.rawValue,
            args: [
                "sessionID": .string(fixture.sessionID),
                "content": .string("<p>Third</p>"),
                "createPolicy": .string("new"),
            ]
        )
        let thirdResult = try #require(third.result)
        let thirdPanelIDString = try #require(thirdResult.string("panelID"))
        let thirdPanelID = try #require(UUID(uuidString: thirdPanelIDString))
        let thirdDocumentIDString = try #require(thirdResult.string("documentID"))
        let thirdDocumentID = try #require(UUID(uuidString: thirdDocumentIDString))
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let firstState = try #require(workspace.panelState(for: first.panelID))
        let secondState = try #require(workspace.panelState(for: secondPanelID))
        let thirdState = try #require(workspace.panelState(for: thirdPanelID))
        guard case .web(let firstWebState) = firstState,
              case .web(let secondWebState) = secondState,
              case .web(let thirdWebState) = thirdState else {
            Issue.record("scratchpad panels should be web panels")
            return
        }

        #expect(firstWebState.scratchpad?.sessionLink == nil)
        #expect(secondWebState.scratchpad?.sessionLink == nil)
        #expect(thirdWebState.scratchpad?.sessionLink?.sessionID == fixture.sessionID)
        #expect(try fixture.documentStore.load(documentID: first.documentID)?.sessionLink == nil)
        #expect(try fixture.documentStore.load(documentID: secondDocumentID)?.sessionLink == nil)
        #expect(try fixture.documentStore.load(documentID: thirdDocumentID)?.sessionLink?.sessionID == fixture.sessionID)
    }

    @Test
    func invalidCreatePolicyRejectsSetContent() throws {
        let fixture = try ScratchpadAppControlFixture()

        #expect(throws: AutomationSocketError.self) {
            try fixture.executor.runAction(
                id: AppControlActionID.panelScratchpadSetContent.rawValue,
                args: [
                    "sessionID": .string(fixture.sessionID),
                    "content": .string("<p>Invalid</p>"),
                    "createPolicy": .string("replace"),
                ]
            )
        }
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

private func patchJSON(_ replacements: [ScratchpadContentReplacement]) throws -> String {
    let encoder = JSONEncoder()
    let data = try encoder.encode(ScratchpadContentPatch(replacements: replacements))
    return try #require(String(data: data, encoding: .utf8))
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
