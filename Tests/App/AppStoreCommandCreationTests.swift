@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreCommandCreationTests: XCTestCase {
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
            selectedWindowID: windowID
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
            configuredTerminalFontPoints: 13
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
        XCTAssertNil(window.terminalFontSizePointsOverride)
        XCTAssertEqual(store.state.effectiveTerminalFontPoints(for: window.id), 13)
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
        state.configuredTerminalFontPoints = 13
        state.windows[0].terminalFontSizePointsOverride = 16
        state.windows[0].markdownTextScaleOverride = 1.2

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
        XCTAssertEqual(newWindow.terminalFontSizePointsOverride, 16)
        XCTAssertEqual(newWindow.markdownTextScaleOverride, 1.2)
        XCTAssertEqual(store.state.effectiveTerminalFontPoints(for: newWindow.id), 16)
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: newWindow.id), 1.2)

        XCTAssertTrue(store.send(.increaseWindowMarkdownTextScale(windowID: newWindow.id)))
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: newWindow.id), 1.3, accuracy: 0.0001)
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: sourceWindowID), 1.2, accuracy: 0.0001)
    }

    func testCreateWindowFromCommandFallsBackToHomeDirectoryAndDefaultProfileFromNonTerminalFocus() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "ssh-prod")
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let reducer = AppReducer()
        state.configuredTerminalFontPoints = 13
        state.windows[0].terminalFontSizePointsOverride = 17
        state.windows[0].markdownTextScaleOverride = 1.3

        XCTAssertTrue(
            reducer.send(
                .createWebPanel(
                    workspaceID: sourceWorkspaceID,
                    panel: WebPanelState(definition: .browser),
                    placement: .splitRight
                ),
                state: &state
            )
        )
        let workspaceWithBrowser = try XCTUnwrap(state.workspacesByID[sourceWorkspaceID])
        let browserPanelID = try XCTUnwrap(workspaceWithBrowser.panels.first(where: {
            if case .web = $0.value {
                return true
            }
            return false
        })?.key)
        XCTAssertTrue(reducer.send(.focusPanel(workspaceID: sourceWorkspaceID, panelID: browserPanelID), state: &state))

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
        XCTAssertEqual(newWindow.terminalFontSizePointsOverride, 17)
        XCTAssertEqual(newWindow.markdownTextScaleOverride, 1.3)
        XCTAssertEqual(store.state.effectiveTerminalFontPoints(for: newWindow.id), 17)
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: newWindow.id), 1.3)
    }

    func testCreateWindowFromCommandUsesProvidedFrameWithoutCascadeWhenNoSourceWindowExists() throws {
        let expectedFrame = CGRectCodable(x: 320, y: 240, width: 1600, height: 960)
        let state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            configuredTerminalFontPoints: 13
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
        XCTAssertNil(window.terminalFontSizePointsOverride)
        XCTAssertNil(window.markdownTextScaleOverride)
        XCTAssertEqual(store.state.effectiveTerminalFontPoints(for: window.id), 13)
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: window.id), AppState.defaultMarkdownTextScale)
    }

    func testCreateWorkspaceTabFromCommandSeedsFromFocusedTerminal() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "ssh-prod")
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var sourceWorkspace = try XCTUnwrap(state.workspacesByID[sourceWorkspaceID])
        let focusedPanelID = try XCTUnwrap(sourceWorkspace.focusedPanelID)
        guard case .terminal(var terminalState) = sourceWorkspace.panels[focusedPanelID] else {
            XCTFail("expected focused panel to be terminal")
            return
        }
        terminalState.cwd = "/tmp/toastty/new-tab"
        terminalState.profileBinding = TerminalProfileBinding(profileID: "zmx")
        sourceWorkspace.panels[focusedPanelID] = .terminal(terminalState)
        state.workspacesByID[sourceWorkspaceID] = sourceWorkspace
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.createWorkspaceTabFromCommand(preferredWindowID: sourceWindowID))

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let newTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let newTab = try XCTUnwrap(workspace.tabsByID[newTabID])
        let newPanelID = try XCTUnwrap(newTab.focusedPanelID)
        guard case .terminal(let newTerminalState) = newTab.panels[newPanelID] else {
            XCTFail("expected new tab panel to be terminal")
            return
        }

        XCTAssertEqual(workspace.tabIDs.count, 2)
        XCTAssertEqual(newTerminalState.cwd, "/tmp/toastty/new-tab")
        XCTAssertEqual(newTerminalState.profileBinding, TerminalProfileBinding(profileID: "zmx"))
    }
}
