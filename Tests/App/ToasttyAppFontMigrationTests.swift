@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class ToasttyAppFontMigrationTests: XCTestCase {
    func testApplyToasttyTerminalFontStateMigratesLegacyFontToAllWindowsWithoutOverrides() throws {
        let state = makeTwoWindowState()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        var didClearLegacyFont = false

        ToasttyApp.applyToasttyTerminalFontState(
            to: store,
            toasttyConfig: ToasttyConfig(terminalFontSizePoints: 13, defaultTerminalProfileID: nil),
            legacyTerminalFontSizePoints: 16,
            ghosttyConfiguredTerminalFontPoints: nil,
            clearLegacyTerminalFontSizePoints: {
                didClearLegacyFont = true
            }
        )

        XCTAssertEqual(store.state.configuredTerminalFontPoints, 13)
        XCTAssertEqual(store.state.windows.map(\.terminalFontSizePointsOverride), [16, 16])
        XCTAssertEqual(
            store.state.windows.map { store.state.effectiveTerminalFontPoints(for: $0.id) },
            [16, 16]
        )
        XCTAssertTrue(didClearLegacyFont)
    }

    func testApplyToasttyTerminalFontStateDoesNotPinOverrideWhenLegacyMatchesBaseline() throws {
        let state = makeTwoWindowState()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        var didClearLegacyFont = false

        ToasttyApp.applyToasttyTerminalFontState(
            to: store,
            toasttyConfig: ToasttyConfig(terminalFontSizePoints: 14, defaultTerminalProfileID: nil),
            legacyTerminalFontSizePoints: 14,
            ghosttyConfiguredTerminalFontPoints: nil,
            clearLegacyTerminalFontSizePoints: {
                didClearLegacyFont = true
            }
        )

        XCTAssertEqual(store.state.configuredTerminalFontPoints, 14)
        XCTAssertEqual(store.state.windows.map(\.terminalFontSizePointsOverride), [nil, nil])
        XCTAssertEqual(
            store.state.windows.map { store.state.effectiveTerminalFontPoints(for: $0.id) },
            [14, 14]
        )
        XCTAssertTrue(didClearLegacyFont)
    }

    private func makeTwoWindowState() -> AppState {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()

        return AppState(
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
            selectedWindowID: firstWindowID
        )
    }
}
