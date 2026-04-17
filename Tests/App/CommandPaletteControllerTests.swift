import AppKit
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class CommandPaletteControllerTests: XCTestCase {
    func testTogglePresentsPaletteAndExecutesAgainstOriginWindowID() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let originWindow = makeOriginWindow(windowID: windowID)
        let actions = RecordingCommandPaletteActions()
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let controller = CommandPaletteController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            actions: actions
        )
        defer {
            controller.dismiss(reason: .cancelled)
            originWindow.close()
        }

        XCTAssertTrue(controller.toggle(originWindowID: windowID))
        XCTAssertTrue(controller.isPresented)

        let viewModel = try XCTUnwrap(controller.viewModel)
        viewModel.query = "new workspace"
        viewModel.submitSelection()

        XCTAssertEqual(actions.createdWorkspaceWindowIDs, [windowID])
        XCTAssertFalse(controller.isPresented)
    }

    func testDismissCancelledRestoresPreviousFirstResponder() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let originWindow = makeOriginWindow(windowID: windowID)
        let focusView = FocusableTestView(frame: NSRect(x: 20, y: 20, width: 80, height: 30))
        originWindow.contentView?.addSubview(focusView)
        XCTAssertTrue(originWindow.makeFirstResponder(focusView))

        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let controller = CommandPaletteController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            actions: RecordingCommandPaletteActions()
        )
        defer {
            controller.dismiss(reason: .cancelled)
            originWindow.close()
        }

        XCTAssertTrue(controller.toggle(originWindowID: windowID))
        XCTAssertTrue(originWindow.makeFirstResponder(nil))
        XCTAssertFalse(originWindow.firstResponder === focusView)

        controller.dismiss(reason: .cancelled)

        XCTAssertTrue(originWindow.firstResponder === focusView)
    }

    func testDismissClickAwayDoesNotRestorePreviousFirstResponder() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let originWindow = makeOriginWindow(windowID: windowID)
        let focusView = FocusableTestView(frame: NSRect(x: 20, y: 20, width: 80, height: 30))
        originWindow.contentView?.addSubview(focusView)
        XCTAssertTrue(originWindow.makeFirstResponder(focusView))

        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let controller = CommandPaletteController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            actions: RecordingCommandPaletteActions()
        )
        defer {
            controller.dismiss(reason: .cancelled)
            originWindow.close()
        }

        XCTAssertTrue(controller.toggle(originWindowID: windowID))
        XCTAssertTrue(originWindow.makeFirstResponder(nil))

        controller.dismiss(reason: .clickAway)

        XCTAssertFalse(originWindow.firstResponder === focusView)
    }

    func testExecutedWorkspaceChangeRestoresFocusToCurrentWorkspace() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let originalWorkspaceID = try XCTUnwrap(
            store.commandSelection(preferredWindowID: windowID)?.workspace.id
        )
        let originWindow = makeOriginWindow(windowID: windowID)
        let focusView = FocusableTestView(frame: NSRect(x: 20, y: 20, width: 80, height: 30))
        originWindow.contentView?.addSubview(focusView)
        XCTAssertTrue(originWindow.makeFirstResponder(focusView))

        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let splitLayoutCommandController = SplitLayoutCommandController(store: store)
        let actions = CommandPaletteActionHandler(
            store: store,
            splitLayoutCommandController: splitLayoutCommandController
        )
        var restoredWorkspaceIDs: [UUID] = []
        let controller = CommandPaletteController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            actions: actions,
            scheduleWorkspaceFocusRestore: { workspaceID, avoidStealingKeyboardFocus in
                XCTAssertFalse(avoidStealingKeyboardFocus)
                restoredWorkspaceIDs.append(workspaceID)
            }
        )
        defer {
            controller.dismiss(reason: .cancelled)
            originWindow.close()
        }

        XCTAssertTrue(controller.toggle(originWindowID: windowID))

        let viewModel = try XCTUnwrap(controller.viewModel)
        viewModel.query = "new workspace"
        viewModel.submitSelection()

        let currentWorkspaceID = try XCTUnwrap(
            store.commandSelection(preferredWindowID: windowID)?.workspace.id
        )

        XCTAssertNotEqual(currentWorkspaceID, originalWorkspaceID)
        XCTAssertEqual(restoredWorkspaceIDs, [currentWorkspaceID])
    }

    private func makeOriginWindow(windowID: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 500, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

@MainActor
final class CommandPalettePanelTests: XCTestCase {
    func testPositionedFrameCentersWithinOriginWindow() {
        let originFrame = CGRect(x: 120, y: 180, width: 900, height: 640)

        let frame = CommandPalettePanel.positionedFrame(
            relativeTo: originFrame,
            visibleFrame: nil
        )

        XCTAssertEqual(frame.origin.x, 280)
        XCTAssertEqual(frame.origin.y, 374)
        XCTAssertEqual(frame.size, CommandPalettePanel.defaultFrame.size)
    }

    func testPositionedFrameClampsCenteredFrameIntoVisibleScreenBounds() {
        let originFrame = CGRect(x: 920, y: 620, width: 420, height: 260)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)

        let frame = CommandPalettePanel.positionedFrame(
            relativeTo: originFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.origin.x, visibleFrame.maxX - CommandPalettePanel.defaultFrame.width)
        XCTAssertEqual(frame.origin.y, visibleFrame.maxY - CommandPalettePanel.defaultFrame.height)
    }
}

@MainActor
private final class RecordingCommandPaletteActions: CommandPaletteActionHandling {
    var createdWorkspaceWindowIDs: [UUID] = []

    func commandSelection(originWindowID: UUID) -> WindowCommandSelection? {
        _ = originWindowID
        return nil
    }

    func canCreateWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func createWorkspace(originWindowID: UUID) -> Bool {
        createdWorkspaceWindowIDs.append(originWindowID)
        return true
    }

    func canSplitHorizontal(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func splitHorizontal(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func canToggleSidebar(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func toggleSidebar(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func sidebarTitle(originWindowID: UUID) -> String {
        _ = originWindowID
        return "Show Sidebar"
    }
}

private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
