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
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
        )
        let actions = CommandPaletteActionHandler(
            store: store,
            splitLayoutCommandController: splitLayoutCommandController,
            focusedPanelCommandController: focusedPanelCommandController,
            sessionRuntimeStore: SessionRuntimeStore(),
            supportsConfigurationReload: { true },
            reloadConfigurationAction: {}
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
            visibleFrames: []
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
            visibleFrames: [visibleFrame]
        )

        XCTAssertEqual(frame.origin.x, visibleFrame.maxX - CommandPalettePanel.defaultFrame.width)
        XCTAssertEqual(frame.origin.y, visibleFrame.maxY - CommandPalettePanel.defaultFrame.height)
    }

    func testPositionedFrameUsesMostRelevantScreenAcrossMultipleDisplays() {
        let laptopVisibleFrame = CGRect(x: -1512, y: 38, width: 1512, height: 945)
        let externalVisibleFrame = CGRect(x: 0, y: 25, width: 1728, height: 1055)
        let originFrame = CGRect(x: -1450, y: 80, width: 1100, height: 860)

        let frame = CommandPalettePanel.positionedFrame(
            relativeTo: originFrame,
            visibleFrames: [externalVisibleFrame, laptopVisibleFrame]
        )

        XCTAssertGreaterThanOrEqual(frame.minX, laptopVisibleFrame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, laptopVisibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, laptopVisibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxY, laptopVisibleFrame.maxY)
        XCTAssertEqual(frame.origin.x, -1190)
        XCTAssertEqual(frame.origin.y, 384)
    }
}

@MainActor
private final class RecordingCommandPaletteActions: CommandPaletteActionHandling {
    var createdWindowIDs: [UUID] = []
    var createdWorkspaceWindowIDs: [UUID] = []
    var createdWorkspaceTabWindowIDs: [UUID] = []
    var splitCalls: [RecordedSplitCall] = []
    var closePanelWindowIDs: [UUID] = []
    var renamedWorkspaceWindowIDs: [UUID] = []
    var closedWorkspaceWindowIDs: [UUID] = []
    var renamedTabWindowIDs: [UUID] = []
    var tabSelectionCalls: [RecordedTabSelectionCall] = []
    var jumpedToNextActiveWindowIDs: [UUID] = []
    var reloadConfigurationCount = 0

    func commandSelection(originWindowID: UUID) -> WindowCommandSelection? {
        _ = originWindowID
        return nil
    }

    func canCreateWindow(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func createWindow(originWindowID: UUID) -> Bool {
        createdWindowIDs.append(originWindowID)
        return true
    }

    func canCreateWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func createWorkspace(originWindowID: UUID) -> Bool {
        createdWorkspaceWindowIDs.append(originWindowID)
        return true
    }

    func canCreateWorkspaceTab(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func createWorkspaceTab(originWindowID: UUID) -> Bool {
        createdWorkspaceTabWindowIDs.append(originWindowID)
        return true
    }

    func canSplit(direction: SlotSplitDirection, originWindowID: UUID) -> Bool {
        _ = direction
        _ = originWindowID
        return true
    }

    func split(direction: SlotSplitDirection, originWindowID: UUID) -> Bool {
        splitCalls.append(RecordedSplitCall(direction: direction, originWindowID: originWindowID))
        return true
    }

    func canFocusSplit(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func focusSplit(direction: SlotFocusDirection, originWindowID: UUID) -> Bool {
        _ = direction
        _ = originWindowID
        return true
    }

    func canEqualizeSplits(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func equalizeSplits(originWindowID: UUID) -> Bool {
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
        return ToasttyBuiltInCommand.toggleSidebar.title
    }

    func canClosePanel(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func closePanel(originWindowID: UUID) -> Bool {
        closePanelWindowIDs.append(originWindowID)
        return true
    }

    func canRenameWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func renameWorkspace(originWindowID: UUID) -> Bool {
        renamedWorkspaceWindowIDs.append(originWindowID)
        return true
    }

    func canCloseWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func closeWorkspace(originWindowID: UUID) -> Bool {
        closedWorkspaceWindowIDs.append(originWindowID)
        return true
    }

    func canRenameTab(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func renameTab(originWindowID: UUID) -> Bool {
        renamedTabWindowIDs.append(originWindowID)
        return true
    }

    func canSelectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool {
        _ = direction
        _ = originWindowID
        return true
    }

    func selectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool {
        tabSelectionCalls.append(
            RecordedTabSelectionCall(direction: direction, originWindowID: originWindowID)
        )
        return true
    }

    func canJumpToNextActive(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func jumpToNextActive(originWindowID: UUID) -> Bool {
        jumpedToNextActiveWindowIDs.append(originWindowID)
        return true
    }

    func canReloadConfiguration() -> Bool {
        true
    }

    func reloadConfiguration() -> Bool {
        reloadConfigurationCount += 1
        return true
    }
}

private struct RecordedSplitCall: Equatable {
    let direction: SlotSplitDirection
    let originWindowID: UUID
}

private struct RecordedTabSelectionCall: Equatable {
    let direction: TabNavigationDirection
    let originWindowID: UUID
}

private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
