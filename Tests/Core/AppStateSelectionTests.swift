import CoreState
import XCTest

final class AppStateSelectionTests: XCTestCase {
    func testWorkspaceSelectionInWindowRespectsWindowSelectionAndFallback() throws {
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
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let selection = try XCTUnwrap(state.workspaceSelection(in: windowID))

        XCTAssertEqual(selection.windowID, windowID)
        XCTAssertEqual(selection.workspaceID, firstWorkspace.id)
        XCTAssertEqual(selection.workspace.id, firstWorkspace.id)
    }

    func testWorkspaceSelectionContainingWorkspaceIDIgnoresGlobalSelectedWindow() throws {
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

        let selection = try XCTUnwrap(state.workspaceSelection(containingWorkspaceID: secondWorkspace.id))

        XCTAssertEqual(selection.windowID, secondWindowID)
        XCTAssertEqual(selection.workspaceID, secondWorkspace.id)
    }

    func testSelectedWorkspaceSelectionUsesSelectedWindowID() throws {
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
            selectedWindowID: secondWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let selection = try XCTUnwrap(state.selectedWorkspaceSelection())

        XCTAssertEqual(selection.windowID, secondWindowID)
        XCTAssertEqual(selection.workspaceID, secondWorkspace.id)
    }

    func testSoleWorkspaceSelectionReturnsNilWhenMultipleWindowsExist() {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let state = AppState(
            windows: [
                WindowState(
                    id: UUID(),
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: UUID(),
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        XCTAssertNil(state.soleWorkspaceSelection())
    }

    func testSoleWorkspaceSelectionReturnsNilWhenNoWindowsExist() {
        let workspace = WorkspaceState.bootstrap(title: "One")
        let state = AppState(
            windows: [],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        XCTAssertNil(state.soleWorkspaceSelection())
    }
}
