@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreWindowSelectionTests: XCTestCase {
    func testWindowLookupResolvesSpecificWindowWithoutUsingGlobalSelection() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        let resolvedWindow = try XCTUnwrap(store.window(id: secondWindowID))
        let resolvedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: secondWindowID))

        XCTAssertEqual(resolvedWindow.id, secondWindowID)
        XCTAssertEqual(resolvedWorkspace.id, secondWorkspace.id)
        XCTAssertEqual(store.selectedWorkspace?.id, firstWorkspace.id)
    }

    func testSelectedWorkspaceInWindowFallsBackToFirstWorkspaceWhenSelectionIsNil() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id, secondWorkspace.id],
                    selectedWorkspaceID: nil
                )
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        let resolvedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))

        XCTAssertEqual(resolvedWorkspace.id, firstWorkspace.id)
        XCTAssertEqual(store.selectedWorkspace?.id, firstWorkspace.id)
    }

    func testCommandSelectionPrefersFocusedWindowOverGlobalSelection() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        let selection = try XCTUnwrap(store.commandSelection(preferredWindowID: secondWindowID))

        XCTAssertEqual(selection.windowID, secondWindowID)
        XCTAssertEqual(selection.window.id, secondWindowID)
        XCTAssertEqual(selection.workspace.id, secondWorkspace.id)
    }

    func testCommandSelectionReturnsNilWhenFocusedWindowIsMissing() {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.commandSelection(preferredWindowID: UUID()))
    }

    func testWindowLookupReturnsNilForUnknownWindowID() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)

        XCTAssertNil(store.window(id: UUID()))
        XCTAssertNil(store.selectedWorkspaceID(in: UUID()))
        XCTAssertNil(store.selectedWorkspace(in: UUID()))
        XCTAssertNil(store.commandSelection(preferredWindowID: UUID()))
        XCTAssertNotNil(store.commandSelection(preferredWindowID: nil))
    }

    func testCommandSelectionReturnsNilWhenNoWindowCanBeResolved() {
        let workspace = WorkspaceState.bootstrap()
        let state = AppState(
            windows: [],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.commandSelection(preferredWindowID: UUID()))
        XCTAssertNil(store.commandSelection(preferredWindowID: nil))
    }

    func testSelectedWorkspaceInWindowReturnsNilWhenWindowHasNoWorkspaces() {
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [],
                    selectedWorkspaceID: nil
                )
            ],
            workspacesByID: [:],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.selectedWorkspaceID(in: windowID))
        XCTAssertNil(store.selectedWorkspace(in: windowID))
        XCTAssertNil(store.selectedWorkspace)
        XCTAssertNil(store.commandSelection(preferredWindowID: windowID))
    }

    func testCommandWindowIDResolvesFocusedWindowWithoutAnyWorkspaces() {
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [],
                    selectedWorkspaceID: nil
                )
            ],
            workspacesByID: [:],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertEqual(store.commandWindowID(preferredWindowID: windowID), windowID)
        XCTAssertTrue(store.canCreateWorkspaceFromCommand(preferredWindowID: windowID))
    }

    func testCreateWorkspaceFromCommandPopulatesFocusedEmptyWindow() throws {
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [],
                    selectedWorkspaceID: nil
                )
            ],
            workspacesByID: [:],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.createWorkspaceFromCommand(preferredWindowID: windowID))

        let window = try XCTUnwrap(store.window(id: windowID))
        let workspaceID = try XCTUnwrap(window.selectedWorkspaceID)
        XCTAssertEqual(window.workspaceIDs, [workspaceID])
        XCTAssertEqual(store.state.workspacesByID[workspaceID]?.title, "Workspace 1")
    }

    func testCreateWorkspaceFromCommandRecreatesFirstWindowFromEmptyState() throws {
        let expectedFrame = CGRectCodable(x: 320, y: 240, width: 1600, height: 960)
        let state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            configuredTerminalFontPoints: 13,
            globalTerminalFontPoints: 15
        )
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            commandCreateWindowFrameProvider: { expectedFrame }
        )

        XCTAssertTrue(store.canCreateWorkspaceFromCommand(preferredWindowID: nil))
        XCTAssertTrue(store.createWorkspaceFromCommand(preferredWindowID: nil))

        let window = try XCTUnwrap(store.state.windows.first)
        let workspaceID = try XCTUnwrap(window.selectedWorkspaceID)
        XCTAssertEqual(store.state.selectedWindowID, window.id)
        XCTAssertEqual(window.frame, expectedFrame)
        XCTAssertEqual(store.state.workspacesByID[workspaceID]?.title, "Workspace 1")
        XCTAssertEqual(store.state.configuredTerminalFontPoints, 13)
        XCTAssertEqual(store.state.globalTerminalFontPoints, 15)
    }

    func testCreateWindowFromCommandSeedsFromFocusedTerminalAndCascadesFrame() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "ssh-prod")
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var sourceWorkspace = try XCTUnwrap(state.workspacesByID[sourceWorkspaceID])
        let focusedPanelID = try XCTUnwrap(sourceWorkspace.focusedPanelID)
        guard case .terminal(var terminalState) = sourceWorkspace.panels[focusedPanelID] else {
            XCTFail("expected focused panel to be terminal")
            return
        }
        terminalState.cwd = "/tmp/toastty/new-window"
        terminalState.profileBinding = TerminalProfileBinding(profileID: "zmx")
        sourceWorkspace.panels[focusedPanelID] = .terminal(terminalState)
        state.workspacesByID[sourceWorkspaceID] = sourceWorkspace

        let sourceFrame = CGRectCodable(x: 320, y: 240, width: 1600, height: 960)
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            commandCreateWindowFrameProvider: { sourceFrame }
        )

        XCTAssertTrue(store.createWindowFromCommand(preferredWindowID: sourceWindowID))

        XCTAssertEqual(store.state.windows.count, 2)
        let newWindow = try XCTUnwrap(store.state.windows.last)
        let newWorkspaceID = try XCTUnwrap(newWindow.selectedWorkspaceID)
        let newWorkspace = try XCTUnwrap(store.state.workspacesByID[newWorkspaceID])
        let newPanelID = try XCTUnwrap(newWorkspace.focusedPanelID)
        guard case .terminal(let newTerminalState) = newWorkspace.panels[newPanelID] else {
            XCTFail("expected new window panel to be terminal")
            return
        }

        XCTAssertEqual(store.state.selectedWindowID, newWindow.id)
        XCTAssertEqual(newWindow.frame, CGRectCodable(x: 350, y: 210, width: 1600, height: 960))
        XCTAssertEqual(newTerminalState.cwd, "/tmp/toastty/new-window")
        XCTAssertEqual(newTerminalState.profileBinding, TerminalProfileBinding(profileID: "zmx"))
    }

    func testCreateWindowFromCommandFallsBackToHomeDirectoryAndDefaultProfileFromNonTerminalFocus() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "ssh-prod")
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let reducer = AppReducer()

        XCTAssertTrue(reducer.send(.toggleAuxPanel(workspaceID: sourceWorkspaceID, kind: .diff), state: &state))
        let workspaceWithDiff = try XCTUnwrap(state.workspacesByID[sourceWorkspaceID])
        let diffPanelID = try XCTUnwrap(workspaceWithDiff.panels.first(where: { $0.value.kind == .diff })?.key)
        XCTAssertTrue(reducer.send(.focusPanel(workspaceID: sourceWorkspaceID, panelID: diffPanelID), state: &state))

        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            commandCreateWindowFrameProvider: { nil }
        )

        XCTAssertTrue(store.createWindowFromCommand(preferredWindowID: sourceWindowID))

        let newWindow = try XCTUnwrap(store.state.windows.last)
        let newWorkspaceID = try XCTUnwrap(newWindow.selectedWorkspaceID)
        let newWorkspace = try XCTUnwrap(store.state.workspacesByID[newWorkspaceID])
        let newPanelID = try XCTUnwrap(newWorkspace.focusedPanelID)
        guard case .terminal(let newTerminalState) = newWorkspace.panels[newPanelID] else {
            XCTFail("expected new window panel to be terminal")
            return
        }

        XCTAssertEqual(newTerminalState.cwd, NSHomeDirectory())
        XCTAssertEqual(newTerminalState.profileBinding, TerminalProfileBinding(profileID: "ssh-prod"))
    }

    func testCreateWindowFromCommandUsesProvidedFrameWithoutCascadeWhenNoSourceWindowExists() throws {
        let expectedFrame = CGRectCodable(x: 320, y: 240, width: 1600, height: 960)
        let state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            configuredTerminalFontPoints: 13,
            globalTerminalFontPoints: 15
        )
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            commandCreateWindowFrameProvider: { expectedFrame }
        )

        XCTAssertTrue(store.createWindowFromCommand(preferredWindowID: nil))

        let window = try XCTUnwrap(store.state.windows.first)
        XCTAssertEqual(window.frame, expectedFrame)
        XCTAssertEqual(store.state.selectedWindowID, window.id)
    }

    func testRenameSelectedWorkspaceFromCommandSetsPendingRename() throws {
        let workspace = WorkspaceState.bootstrap(title: "Dev")
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                )
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.pendingRenameWorkspaceID)
        store.renameSelectedWorkspaceFromCommand(preferredWindowID: windowID)
        XCTAssertEqual(store.pendingRenameWorkspaceID, workspace.id)
    }

    func testRenameSelectedWorkspaceFromCommandDoesNothingWithoutWorkspace() {
        let store = AppStore(
            state: AppState(
                windows: [],
                workspacesByID: [:],
                selectedWindowID: nil,
                globalTerminalFontPoints: AppState.defaultTerminalFontPoints
            ),
            persistTerminalFontPreference: false
        )

        store.renameSelectedWorkspaceFromCommand(preferredWindowID: nil)
        XCTAssertNil(store.pendingRenameWorkspaceID)
    }

    func testCloseSelectedWorkspaceFromCommandRequestsFocusedWorkspaceClose() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.closeSelectedWorkspaceFromCommand(preferredWindowID: secondWindowID))
        XCTAssertEqual(
            store.pendingCloseWorkspaceRequest,
            PendingWorkspaceCloseRequest(windowID: secondWindowID, workspaceID: secondWorkspace.id)
        )
        XCTAssertNotNil(store.window(id: firstWindowID))
        XCTAssertNotNil(store.window(id: secondWindowID))
        XCTAssertNotNil(store.state.workspacesByID[secondWorkspace.id])
    }

    func testCloseSelectedWorkspaceFromCommandDoesNothingWithoutWorkspace() {
        let store = AppStore(
            state: AppState(
                windows: [],
                workspacesByID: [:],
                selectedWindowID: nil,
                globalTerminalFontPoints: AppState.defaultTerminalFontPoints
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertFalse(store.closeSelectedWorkspaceFromCommand(preferredWindowID: nil))
        XCTAssertNil(store.pendingCloseWorkspaceRequest)
    }

    func testConfirmWorkspaceCloseClosesRequestedWorkspace() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let firstWorkspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.send(.createWorkspace(windowID: windowID, title: "Second")))
        let secondWorkspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.requestWorkspaceClose(workspaceID: secondWorkspaceID))

        XCTAssertTrue(store.confirmWorkspaceClose(windowID: windowID, workspaceID: secondWorkspaceID))

        let window = try XCTUnwrap(store.window(id: windowID))
        XCTAssertEqual(window.workspaceIDs, [firstWorkspaceID])
        XCTAssertEqual(window.selectedWorkspaceID, firstWorkspaceID)
        XCTAssertNil(store.pendingCloseWorkspaceRequest)
        XCTAssertNil(store.state.workspacesByID[secondWorkspaceID])
    }

    func testRequestWorkspaceCloseDoesNotOverwriteDifferentPendingRequest() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.requestWorkspaceClose(workspaceID: firstWorkspace.id))
        XCTAssertFalse(store.requestWorkspaceClose(workspaceID: secondWorkspace.id))
        XCTAssertEqual(
            store.pendingCloseWorkspaceRequest,
            PendingWorkspaceCloseRequest(windowID: firstWindowID, workspaceID: firstWorkspace.id)
        )
    }

    func testCreateWorkspaceFromCommandDoesNotRerouteMissingFocusedWindow() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = store.state.windows[0].id
        let originalWorkspaceIDs = store.state.windows[0].workspaceIDs

        XCTAssertFalse(store.canCreateWorkspaceFromCommand(preferredWindowID: UUID()))
        XCTAssertFalse(store.createWorkspaceFromCommand(preferredWindowID: UUID()))

        XCTAssertEqual(store.state.windows[0].id, windowID)
        XCTAssertEqual(store.state.windows[0].workspaceIDs, originalWorkspaceIDs)
    }

    func testSelectWorkspacePrefersMostRecentUnreadSessionPanelWhenSwitchingWorkspaces() throws {
        let windowID = UUID()
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondLayout = makeTwoPanelWorkspace(title: "Two")
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id, secondLayout.workspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                )
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondLayout.workspace.id: secondLayout.workspace,
            ],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-left",
            agent: .codex,
            panelID: secondLayout.leftPanelID,
            windowID: windowID,
            workspaceID: secondLayout.workspace.id,
            cwd: "/repo/left",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-left",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Left"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-right",
            agent: .claude,
            panelID: secondLayout.rightPanelID,
            windowID: windowID,
            workspaceID: secondLayout.workspace.id,
            cwd: "/repo/right",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-right",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Right"),
            at: startedAt.addingTimeInterval(3)
        )

        XCTAssertTrue(
            store.selectWorkspace(
                windowID: windowID,
                workspaceID: secondLayout.workspace.id,
                preferringUnreadSessionPanelIn: sessionStore
            )
        )

        let selectedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))
        XCTAssertEqual(selectedWorkspace.id, secondLayout.workspace.id)
        XCTAssertEqual(selectedWorkspace.focusedPanelID, secondLayout.rightPanelID)
        XCTAssertEqual(selectedWorkspace.unreadPanelIDs, [secondLayout.leftPanelID])
    }

    func testSelectWorkspaceDoesNotOverrideFocusWhenWorkspaceIsAlreadySelected() throws {
        let windowID = UUID()
        let secondLayout = makeTwoPanelWorkspace(title: "Two")
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [secondLayout.workspace.id],
                    selectedWorkspaceID: secondLayout.workspace.id
                )
            ],
            workspacesByID: [secondLayout.workspace.id: secondLayout.workspace],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-right",
            agent: .codex,
            panelID: secondLayout.rightPanelID,
            windowID: windowID,
            workspaceID: secondLayout.workspace.id,
            cwd: "/repo/right",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-right",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Right"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.selectWorkspace(
                windowID: windowID,
                workspaceID: secondLayout.workspace.id,
                preferringUnreadSessionPanelIn: sessionStore
            )
        )

        let selectedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))
        XCTAssertEqual(selectedWorkspace.focusedPanelID, secondLayout.leftPanelID)
        XCTAssertEqual(selectedWorkspace.unreadPanelIDs, [secondLayout.rightPanelID])
    }

    func testSelectWorkspaceIgnoresUnreadPanelsWithoutSessionStatus() throws {
        let windowID = UUID()
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        var secondLayout = makeTwoPanelWorkspace(title: "Two")
        secondLayout.workspace.unreadPanelIDs = [secondLayout.rightPanelID]
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id, secondLayout.workspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                )
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondLayout.workspace.id: secondLayout.workspace,
            ],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)

        XCTAssertTrue(
            store.selectWorkspace(
                windowID: windowID,
                workspaceID: secondLayout.workspace.id,
                preferringUnreadSessionPanelIn: sessionStore
            )
        )

        let selectedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))
        XCTAssertEqual(selectedWorkspace.focusedPanelID, secondLayout.leftPanelID)
        XCTAssertEqual(selectedWorkspace.unreadPanelIDs, [secondLayout.rightPanelID])
    }

    private func makeTwoPanelWorkspace(title: String) -> (workspace: WorkspaceState, leftPanelID: UUID, rightPanelID: UUID) {
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: title,
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: UUID(), panelID: leftPanelID),
                second: .slot(slotID: UUID(), panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/repo/left")),
                rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/repo/right")),
            ],
            focusedPanelID: leftPanelID
        )
        return (workspace, leftPanelID, rightPanelID)
    }
}
