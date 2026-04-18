import Foundation
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class CommandPaletteCatalogTests: XCTestCase {
    func testBuiltInCommandMetadataUsesStableIdentifiers() {
        XCTAssertEqual(ToasttyBuiltInCommand.splitRight.id, "layout.split.horizontal")
        XCTAssertEqual(ToasttyBuiltInCommand.splitDown.id, "layout.split.vertical")
        XCTAssertEqual(ToasttyBuiltInCommand.selectPreviousSplit.id, "layout.split.select-previous")
        XCTAssertEqual(ToasttyBuiltInCommand.selectNextSplit.id, "layout.split.select-next")
        XCTAssertEqual(ToasttyBuiltInCommand.navigateSplitUp.id, "layout.split.navigate-up")
        XCTAssertEqual(ToasttyBuiltInCommand.navigateSplitDown.id, "layout.split.navigate-down")
        XCTAssertEqual(ToasttyBuiltInCommand.navigateSplitLeft.id, "layout.split.navigate-left")
        XCTAssertEqual(ToasttyBuiltInCommand.navigateSplitRight.id, "layout.split.navigate-right")
        XCTAssertEqual(ToasttyBuiltInCommand.equalizeSplits.id, "layout.split.equalize")
        XCTAssertEqual(ToasttyBuiltInCommand.newWindow.id, "window.create")
        XCTAssertEqual(ToasttyBuiltInCommand.newWorkspace.id, "workspace.create")
        XCTAssertEqual(ToasttyBuiltInCommand.newTab.id, "workspace.tab.create")
        XCTAssertEqual(ToasttyBuiltInCommand.toggleSidebar.id, "window.toggle-sidebar")
        XCTAssertEqual(ToasttyBuiltInCommand.closePanel.id, "panel.close")
        XCTAssertEqual(ToasttyBuiltInCommand.renameWorkspace.id, "workspace.rename")
        XCTAssertEqual(ToasttyBuiltInCommand.closeWorkspace.id, "workspace.close")
        XCTAssertEqual(ToasttyBuiltInCommand.renameTab.id, "workspace.tab.rename")
        XCTAssertEqual(ToasttyBuiltInCommand.selectPreviousTab.id, "workspace.tab.select-previous")
        XCTAssertEqual(ToasttyBuiltInCommand.selectNextTab.id, "workspace.tab.select-next")
        XCTAssertEqual(ToasttyBuiltInCommand.jumpToNextActive.id, "panel.focus-next-unread-or-active")
        XCTAssertEqual(ToasttyBuiltInCommand.reloadConfiguration.id, "app.reload-configuration")
    }

    func testCatalogExposesExpectedBuiltInsInStableOrder() {
        let viewModel = makeViewModel(actions: MockCommandPaletteCatalogActions())

        XCTAssertEqual(
            viewModel.results.map(\.id),
            [
                ToasttyBuiltInCommand.splitRight.id,
                ToasttyBuiltInCommand.splitDown.id,
                ToasttyBuiltInCommand.selectPreviousSplit.id,
                ToasttyBuiltInCommand.selectNextSplit.id,
                ToasttyBuiltInCommand.navigateSplitUp.id,
                ToasttyBuiltInCommand.navigateSplitDown.id,
                ToasttyBuiltInCommand.navigateSplitLeft.id,
                ToasttyBuiltInCommand.navigateSplitRight.id,
                ToasttyBuiltInCommand.equalizeSplits.id,
                ToasttyBuiltInCommand.newWorkspace.id,
                ToasttyBuiltInCommand.newTab.id,
                ToasttyBuiltInCommand.newWindow.id,
                ToasttyBuiltInCommand.toggleSidebar.id,
                ToasttyBuiltInCommand.closePanel.id,
                ToasttyBuiltInCommand.renameWorkspace.id,
                ToasttyBuiltInCommand.closeWorkspace.id,
                ToasttyBuiltInCommand.renameTab.id,
                ToasttyBuiltInCommand.selectPreviousTab.id,
                ToasttyBuiltInCommand.selectNextTab.id,
                ToasttyBuiltInCommand.jumpToNextActive.id,
                ToasttyBuiltInCommand.reloadConfiguration.id,
            ]
        )
        XCTAssertEqual(
            viewModel.results.map(\.title),
            [
                ToasttyBuiltInCommand.splitRight.title,
                ToasttyBuiltInCommand.splitDown.title,
                ToasttyBuiltInCommand.selectPreviousSplit.title,
                ToasttyBuiltInCommand.selectNextSplit.title,
                ToasttyBuiltInCommand.navigateSplitUp.title,
                ToasttyBuiltInCommand.navigateSplitDown.title,
                ToasttyBuiltInCommand.navigateSplitLeft.title,
                ToasttyBuiltInCommand.navigateSplitRight.title,
                ToasttyBuiltInCommand.equalizeSplits.title,
                ToasttyBuiltInCommand.newWorkspace.title,
                ToasttyBuiltInCommand.newTab.title,
                ToasttyBuiltInCommand.newWindow.title,
                ToasttyBuiltInCommand.toggleSidebar.title,
                ToasttyBuiltInCommand.closePanel.title,
                ToasttyBuiltInCommand.renameWorkspace.title,
                ToasttyBuiltInCommand.closeWorkspace.title,
                ToasttyBuiltInCommand.renameTab.title,
                ToasttyBuiltInCommand.selectPreviousTab.title,
                ToasttyBuiltInCommand.selectNextTab.title,
                ToasttyBuiltInCommand.jumpToNextActive.title,
                ToasttyBuiltInCommand.reloadConfiguration.title,
            ]
        )
        XCTAssertEqual(
            viewModel.results.map { $0.command.shortcut?.symbolLabel },
            [
                ToasttyBuiltInCommand.splitRight.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.splitDown.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.selectPreviousSplit.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.selectNextSplit.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.navigateSplitUp.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.navigateSplitDown.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.navigateSplitLeft.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.navigateSplitRight.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.equalizeSplits.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.newWorkspace.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.newTab.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.newWindow.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.toggleSidebar.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.closePanel.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.renameWorkspace.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.closeWorkspace.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.renameTab.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.selectPreviousTab.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.selectNextTab.requiredShortcut.symbolLabel,
                ToasttyBuiltInCommand.jumpToNextActive.requiredShortcut.symbolLabel,
                nil,
            ]
        )
    }

    func testCatalogKeepsSplitNavigationBlockOrderedBeforeWorkspaceCommands() {
        let viewModel = makeViewModel(actions: MockCommandPaletteCatalogActions())

        XCTAssertEqual(
            Array(viewModel.results.map(\.id).prefix(9)),
            [
                ToasttyBuiltInCommand.splitRight.id,
                ToasttyBuiltInCommand.splitDown.id,
                ToasttyBuiltInCommand.selectPreviousSplit.id,
                ToasttyBuiltInCommand.selectNextSplit.id,
                ToasttyBuiltInCommand.navigateSplitUp.id,
                ToasttyBuiltInCommand.navigateSplitDown.id,
                ToasttyBuiltInCommand.navigateSplitLeft.id,
                ToasttyBuiltInCommand.navigateSplitRight.id,
                ToasttyBuiltInCommand.equalizeSplits.id,
            ]
        )
    }

    func testCatalogHidesReloadConfigurationWhenUnsupported() {
        let actions = MockCommandPaletteCatalogActions()
        actions.canReloadValue = false

        let viewModel = makeViewModel(actions: actions)

        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.reloadConfiguration.id })
        )
    }

    func testCatalogHidesRenameWorkspaceWhenUnavailable() {
        let actions = MockCommandPaletteCatalogActions()
        actions.canRenameWorkspaceValue = false

        let viewModel = makeViewModel(actions: actions)

        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.renameWorkspace.id })
        )
    }

    func testCatalogHidesJumpToNextActiveWhenUnavailable() {
        let actions = MockCommandPaletteCatalogActions()
        actions.canJumpToNextActiveValue = false

        let viewModel = makeViewModel(actions: actions)

        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.jumpToNextActive.id })
        )
    }

    func testCatalogHidesSplitNavigationWhenUnavailable() {
        let actions = MockCommandPaletteCatalogActions()
        actions.canFocusSplitValue = false

        let viewModel = makeViewModel(actions: actions)

        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.selectPreviousSplit.id })
        )
        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.selectNextSplit.id })
        )
        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.navigateSplitUp.id })
        )
        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.navigateSplitDown.id })
        )
        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.navigateSplitLeft.id })
        )
        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.navigateSplitRight.id })
        )
    }

    func testCatalogHidesEqualizeSplitsWhenUnavailable() {
        let actions = MockCommandPaletteCatalogActions()
        actions.canEqualizeSplitsValue = false

        let viewModel = makeViewModel(actions: actions)

        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.equalizeSplits.id })
        )
    }

    func testCatalogExecutesNewWindowAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.newWindow.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.createdWindowIDs, [originWindowID])
    }

    func testCatalogExecutesNewTabAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.newTab.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.createdWorkspaceTabWindowIDs, [originWindowID])
    }

    func testNewTabQueryDoesNotSurfaceClosePanel() {
        let viewModel = makeViewModel(actions: MockCommandPaletteCatalogActions())

        viewModel.query = "new tab"

        XCTAssertEqual(viewModel.results.map(\.id), [ToasttyBuiltInCommand.newTab.id])
    }

    func testCatalogExecutesSplitDownAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.splitDown.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(
            actions.splitCalls,
            [RecordedCatalogSplitCall(direction: .down, originWindowID: originWindowID)]
        )
    }

    func testCatalogExecutesSelectPreviousSplitAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.selectPreviousSplit.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(
            actions.focusSplitCalls,
            [RecordedCatalogFocusSplitCall(direction: .previous, originWindowID: originWindowID)]
        )
    }

    func testCatalogExecutesSelectNextSplitAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.selectNextSplit.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(
            actions.focusSplitCalls,
            [RecordedCatalogFocusSplitCall(direction: .next, originWindowID: originWindowID)]
        )
    }

    func testCatalogExecutesNavigateSplitUpAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.navigateSplitUp.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(
            actions.focusSplitCalls,
            [RecordedCatalogFocusSplitCall(direction: .up, originWindowID: originWindowID)]
        )
    }

    func testCatalogExecutesNavigateSplitDownAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.navigateSplitDown.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(
            actions.focusSplitCalls,
            [RecordedCatalogFocusSplitCall(direction: .down, originWindowID: originWindowID)]
        )
    }

    func testCatalogExecutesNavigateSplitLeftAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.navigateSplitLeft.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(
            actions.focusSplitCalls,
            [RecordedCatalogFocusSplitCall(direction: .left, originWindowID: originWindowID)]
        )
    }

    func testCatalogExecutesNavigateSplitRightAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.navigateSplitRight.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(
            actions.focusSplitCalls,
            [RecordedCatalogFocusSplitCall(direction: .right, originWindowID: originWindowID)]
        )
    }

    func testCatalogExecutesEqualizeSplitsAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.equalizeSplits.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.equalizedSplitWindowIDs, [originWindowID])
    }

    func testCatalogExecutesClosePanelAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.closePanel.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.closedPanelWindowIDs, [originWindowID])
    }

    func testCatalogExecutesRenameWorkspaceAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.renameWorkspace.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.renamedWorkspaceWindowIDs, [originWindowID])
    }

    func testCatalogExecutesCloseWorkspaceAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.closeWorkspace.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.closedWorkspaceWindowIDs, [originWindowID])
    }

    func testCatalogExecutesRenameTabAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.renameTab.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.renamedTabWindowIDs, [originWindowID])
    }

    func testCatalogExecutesSelectPreviousTabAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.selectPreviousTab.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(
            actions.tabSelectionCalls,
            [RecordedCatalogTabSelectionCall(direction: .previous, originWindowID: originWindowID)]
        )
    }

    func testCatalogExecutesSelectNextTabAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.selectNextTab.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(
            actions.tabSelectionCalls,
            [RecordedCatalogTabSelectionCall(direction: .next, originWindowID: originWindowID)]
        )
    }

    func testCatalogExecutesJumpToNextActiveAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.jumpToNextActive.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.jumpToNextActiveWindowIDs, [originWindowID])
    }

    func testCatalogExecutesReloadConfigurationWhenSupported() {
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(actions: actions)

        viewModel.query = ToasttyBuiltInCommand.reloadConfiguration.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.reloadConfigurationCount, 1)
    }

    func testCatalogDoesNotExecuteNewWindowAfterOriginWindowCloses() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let actions = makeLiveActions(store: store)
        var submitCount = 0
        let viewModel = CommandPaletteViewModel(
            originWindowID: originWindowID,
            commands: CommandPaletteCatalog.commands(),
            actions: actions,
            onCancel: {},
            onSubmitted: {
                submitCount += 1
            }
        )

        viewModel.query = ToasttyBuiltInCommand.newWindow.title.lowercased()
        XCTAssertTrue(store.send(.closeWindow(windowID: originWindowID)))

        viewModel.submitSelection()

        XCTAssertTrue(store.state.windows.isEmpty)
        XCTAssertEqual(submitCount, 1)
    }

    func testCatalogDoesNotExecuteNewWorkspaceAfterOriginWindowCloses() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let actions = makeLiveActions(store: store)
        var submitCount = 0
        let viewModel = CommandPaletteViewModel(
            originWindowID: originWindowID,
            commands: CommandPaletteCatalog.commands(),
            actions: actions,
            onCancel: {},
            onSubmitted: {
                submitCount += 1
            }
        )

        viewModel.query = ToasttyBuiltInCommand.newWorkspace.title.lowercased()
        XCTAssertTrue(store.send(.closeWindow(windowID: originWindowID)))

        viewModel.submitSelection()

        XCTAssertTrue(store.state.windows.isEmpty)
        XCTAssertEqual(submitCount, 1)
    }

    func testCatalogDoesNotExecuteNavigateSplitAfterOriginWindowCloses() throws {
        let state = try XCTUnwrap(AutomationFixtureLoader.load(named: "split-workspace"))
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let actions = makeLiveActions(store: store)
        var submitCount = 0
        let viewModel = CommandPaletteViewModel(
            originWindowID: originWindowID,
            commands: CommandPaletteCatalog.commands(),
            actions: actions,
            onCancel: {},
            onSubmitted: {
                submitCount += 1
            }
        )

        viewModel.query = ToasttyBuiltInCommand.navigateSplitLeft.title.lowercased()
        XCTAssertTrue(store.send(.closeWindow(windowID: originWindowID)))

        viewModel.submitSelection()

        XCTAssertTrue(store.state.windows.isEmpty)
        XCTAssertEqual(submitCount, 1)
    }

    func testCatalogDoesNotExecuteEqualizeSplitsAfterOriginWindowCloses() throws {
        let state = try XCTUnwrap(AutomationFixtureLoader.load(named: "split-workspace"))
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let actions = makeLiveActions(store: store)
        var submitCount = 0
        let viewModel = CommandPaletteViewModel(
            originWindowID: originWindowID,
            commands: CommandPaletteCatalog.commands(),
            actions: actions,
            onCancel: {},
            onSubmitted: {
                submitCount += 1
            }
        )

        viewModel.query = ToasttyBuiltInCommand.equalizeSplits.title.lowercased()
        XCTAssertTrue(store.send(.closeWindow(windowID: originWindowID)))

        viewModel.submitSelection()

        XCTAssertTrue(store.state.windows.isEmpty)
        XCTAssertEqual(submitCount, 1)
    }

    func testCatalogHidesTabNavigationForSingleTabWorkspace() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let viewModel = CommandPaletteViewModel(
            originWindowID: originWindowID,
            commands: CommandPaletteCatalog.commands(),
            actions: makeLiveActions(store: store),
            onCancel: {},
            onSubmitted: {}
        )

        XCTAssertFalse(viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.selectPreviousTab.id }))
        XCTAssertFalse(viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.selectNextTab.id }))
    }

    private func makeViewModel(
        originWindowID: UUID = UUID(),
        actions: MockCommandPaletteCatalogActions
    ) -> CommandPaletteViewModel {
        CommandPaletteViewModel(
            originWindowID: originWindowID,
            commands: CommandPaletteCatalog.commands(),
            actions: actions,
            onCancel: {},
            onSubmitted: {}
        )
    }

    private func makeLiveActions(store: AppStore) -> CommandPaletteActionHandler {
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        runtimeRegistry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        return CommandPaletteActionHandler(
            store: store,
            splitLayoutCommandController: SplitLayoutCommandController(store: store),
            focusedPanelCommandController: FocusedPanelCommandController(
                store: store,
                runtimeRegistry: runtimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            sessionRuntimeStore: sessionRuntimeStore,
            supportsConfigurationReload: { true },
            reloadConfigurationAction: {}
        )
    }
}

@MainActor
private final class MockCommandPaletteCatalogActions: CommandPaletteActionHandling {
    var canCreateWindowValue = true
    var canCreateWorkspaceValue = true
    var canCreateWorkspaceTabValue = true
    var canFocusSplitValue = true
    var canEqualizeSplitsValue = true
    var canToggleSidebarValue = true
    var canClosePanelValue = true
    var canRenameWorkspaceValue = true
    var canCloseWorkspaceValue = true
    var canRenameTabValue = true
    var canSelectPreviousTabValue = true
    var canSelectNextTabValue = true
    var canJumpToNextActiveValue = true
    var canReloadValue = true
    var createdWindowIDs: [UUID] = []
    var createdWorkspaceTabWindowIDs: [UUID] = []
    var splitCalls: [RecordedCatalogSplitCall] = []
    var focusSplitCalls: [RecordedCatalogFocusSplitCall] = []
    var equalizedSplitWindowIDs: [UUID] = []
    var closedPanelWindowIDs: [UUID] = []
    var renamedWorkspaceWindowIDs: [UUID] = []
    var closedWorkspaceWindowIDs: [UUID] = []
    var renamedTabWindowIDs: [UUID] = []
    var tabSelectionCalls: [RecordedCatalogTabSelectionCall] = []
    var jumpToNextActiveWindowIDs: [UUID] = []
    var reloadConfigurationCount = 0

    func commandSelection(originWindowID: UUID) -> WindowCommandSelection? {
        _ = originWindowID
        return nil
    }

    func canCreateWindow(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canCreateWindowValue
    }

    func createWindow(originWindowID: UUID) -> Bool {
        createdWindowIDs.append(originWindowID)
        return true
    }

    func canCreateWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canCreateWorkspaceValue
    }

    func createWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func canCreateWorkspaceTab(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canCreateWorkspaceTabValue
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
        splitCalls.append(RecordedCatalogSplitCall(direction: direction, originWindowID: originWindowID))
        return true
    }

    func canFocusSplit(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canFocusSplitValue
    }

    func focusSplit(direction: SlotFocusDirection, originWindowID: UUID) -> Bool {
        focusSplitCalls.append(RecordedCatalogFocusSplitCall(direction: direction, originWindowID: originWindowID))
        return true
    }

    func canEqualizeSplits(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canEqualizeSplitsValue
    }

    func equalizeSplits(originWindowID: UUID) -> Bool {
        equalizedSplitWindowIDs.append(originWindowID)
        return true
    }

    func canToggleSidebar(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canToggleSidebarValue
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
        return canClosePanelValue
    }

    func closePanel(originWindowID: UUID) -> Bool {
        closedPanelWindowIDs.append(originWindowID)
        return true
    }

    func canRenameWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canRenameWorkspaceValue
    }

    func renameWorkspace(originWindowID: UUID) -> Bool {
        renamedWorkspaceWindowIDs.append(originWindowID)
        return true
    }

    func canCloseWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canCloseWorkspaceValue
    }

    func closeWorkspace(originWindowID: UUID) -> Bool {
        closedWorkspaceWindowIDs.append(originWindowID)
        return true
    }

    func canRenameTab(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canRenameTabValue
    }

    func renameTab(originWindowID: UUID) -> Bool {
        renamedTabWindowIDs.append(originWindowID)
        return true
    }

    func canSelectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool {
        _ = originWindowID
        switch direction {
        case .previous:
            return canSelectPreviousTabValue
        case .next:
            return canSelectNextTabValue
        }
    }

    func selectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool {
        tabSelectionCalls.append(
            RecordedCatalogTabSelectionCall(direction: direction, originWindowID: originWindowID)
        )
        return true
    }

    func canJumpToNextActive(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canJumpToNextActiveValue
    }

    func jumpToNextActive(originWindowID: UUID) -> Bool {
        jumpToNextActiveWindowIDs.append(originWindowID)
        return true
    }

    func canReloadConfiguration() -> Bool {
        canReloadValue
    }

    func reloadConfiguration() -> Bool {
        guard canReloadValue else {
            return false
        }
        reloadConfigurationCount += 1
        return true
    }
}

private struct RecordedCatalogSplitCall: Equatable {
    let direction: SlotSplitDirection
    let originWindowID: UUID
}

private struct RecordedCatalogFocusSplitCall: Equatable {
    let direction: SlotFocusDirection
    let originWindowID: UUID
}

private struct RecordedCatalogTabSelectionCall: Equatable {
    let direction: TabNavigationDirection
    let originWindowID: UUID
}
