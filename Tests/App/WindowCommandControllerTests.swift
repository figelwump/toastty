@testable import ToasttyApp
import AppKit
import CoreState
import XCTest

@MainActor
final class WindowCommandControllerTests: XCTestCase {
    func testCloseWindowUsesPreferredWindowID() throws {
        let fixture = makeTwoWindowFixture(selectedWindowID: nil)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)
        let controller = WindowCommandController(store: store)

        XCTAssertTrue(controller.closeWindow(preferredWindowID: fixture.secondWindowID))
        XCTAssertNil(store.window(id: fixture.secondWindowID))
        XCTAssertNotNil(store.window(id: fixture.firstWindowID))
        XCTAssertEqual(store.state.selectedWindowID, fixture.firstWindowID)
    }

    func testCloseWindowUsesSelectedWindowWhenNoPreferredWindowIDIsProvided() {
        let fixture = makeTwoWindowFixture(selectedWindowID: .second)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)
        let controller = WindowCommandController(store: store)

        XCTAssertTrue(controller.closeWindow())
        XCTAssertNil(store.window(id: fixture.secondWindowID))
        XCTAssertNotNil(store.window(id: fixture.firstWindowID))
        XCTAssertEqual(store.state.selectedWindowID, fixture.firstWindowID)
    }

    func testCloseWindowFallsBackToSoleWindowWhenSelectionIsNil() {
        let workspace = WorkspaceState.bootstrap(title: "Solo")
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 900, height: 700),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                )
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let controller = WindowCommandController(store: store)

        XCTAssertTrue(controller.canCloseWindow())
        XCTAssertTrue(controller.closeWindow())
        XCTAssertTrue(store.state.windows.isEmpty)
        XCTAssertNil(store.state.selectedWindowID)
    }

    func testCloseWindowDoesNotGuessWhenMultipleWindowsExistWithoutSelection() {
        let fixture = makeTwoWindowFixture(selectedWindowID: nil)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)
        let controller = WindowCommandController(store: store)

        XCTAssertFalse(controller.canCloseWindow())
        XCTAssertFalse(controller.closeWindow())
        XCTAssertNotNil(store.window(id: fixture.firstWindowID))
        XCTAssertNotNil(store.window(id: fixture.secondWindowID))
    }

    func testCloseWindowPrefersActiveAppKitWindowOverSelectedWindow() {
        let fixture = makeTwoWindowFixture(selectedWindowID: .first)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)
        let activeWindow = NSWindow()
        activeWindow.identifier = NSUserInterfaceItemIdentifier(fixture.secondWindowID.uuidString)
        let controller = WindowCommandController(
            store: store,
            keyWindowProvider: { activeWindow },
            mainWindowProvider: { nil }
        )

        XCTAssertTrue(controller.closeWindow())
        XCTAssertNotNil(store.window(id: fixture.firstWindowID))
        XCTAssertNil(store.window(id: fixture.secondWindowID))
        XCTAssertEqual(store.state.selectedWindowID, fixture.firstWindowID)
    }

    func testCloseWindowRejectsUnknownPreferredWindowID() {
        let fixture = makeTwoWindowFixture(selectedWindowID: .first)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)
        let controller = WindowCommandController(store: store)

        XCTAssertFalse(controller.closeWindow(preferredWindowID: UUID()))
        XCTAssertNotNil(store.window(id: fixture.firstWindowID))
        XCTAssertNotNil(store.window(id: fixture.secondWindowID))
        XCTAssertEqual(store.state.selectedWindowID, fixture.firstWindowID)
    }

    func testMenuBridgeRetargetsDefaultCloseItemAndUsesWindowControllerState() throws {
        let fixture = makeTwoWindowFixture(selectedWindowID: .second)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)
        let controller = WindowCommandController(store: store)
        let bridge = CloseWindowMenuBridge(windowCommandController: controller)

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(
            title: "Fermer la fenetre",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(closeItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertTrue(closeItem.target === bridge)
        XCTAssertEqual(closeItem.action, #selector(CloseWindowMenuBridge.performCloseWindow(_:)))
        XCTAssertTrue(bridge.validateMenuItem(closeItem))

        bridge.performCloseWindow(nil)

        XCTAssertNil(store.window(id: fixture.secondWindowID))
        XCTAssertNotNil(store.window(id: fixture.firstWindowID))
        XCTAssertEqual(store.state.selectedWindowID, fixture.firstWindowID)
        XCTAssertTrue(bridge.validateMenuItem(closeItem))
    }

    private func makeTwoWindowFixture(selectedWindowID: FixtureSelection?) -> TwoWindowFixture {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let fixture = TwoWindowFixture(
            firstWindowID: firstWindowID,
            secondWindowID: secondWindowID,
            state: AppState(
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
                selectedWindowID: nil,
                globalTerminalFontPoints: AppState.defaultTerminalFontPoints
            )
        )

        var updatedState = fixture.state
        updatedState.selectedWindowID = switch selectedWindowID {
        case .first:
            firstWindowID
        case .second:
            secondWindowID
        case nil:
            nil
        }
        return TwoWindowFixture(
            firstWindowID: firstWindowID,
            secondWindowID: secondWindowID,
            state: updatedState
        )
    }
}

private enum FixtureSelection {
    case first
    case second
}

private struct TwoWindowFixture {
    let firstWindowID: UUID
    let secondWindowID: UUID
    let state: AppState
}
