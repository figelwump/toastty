import Foundation
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class CommandPaletteCatalogTests: XCTestCase {
    func testBuiltInCommandMetadataUsesStableIdentifiers() {
        XCTAssertEqual(ToasttyBuiltInCommand.splitRight.id, "layout.split.horizontal")
        XCTAssertEqual(ToasttyBuiltInCommand.splitDown.id, "layout.split.vertical")
        XCTAssertEqual(ToasttyBuiltInCommand.newWorkspace.id, "workspace.create")
        XCTAssertEqual(ToasttyBuiltInCommand.newTab.id, "workspace.tab.create")
        XCTAssertEqual(ToasttyBuiltInCommand.toggleSidebar.id, "window.toggle-sidebar")
        XCTAssertEqual(ToasttyBuiltInCommand.closePanel.id, "panel.close")
        XCTAssertEqual(ToasttyBuiltInCommand.reloadConfiguration.id, "app.reload-configuration")
    }

    func testCatalogExposesExpectedBuiltInsInStableOrder() {
        let viewModel = makeViewModel(actions: MockCommandPaletteCatalogActions())

        XCTAssertEqual(
            viewModel.results.map(\.id),
            [
                ToasttyBuiltInCommand.splitRight.id,
                ToasttyBuiltInCommand.splitDown.id,
                ToasttyBuiltInCommand.newWorkspace.id,
                ToasttyBuiltInCommand.newTab.id,
                ToasttyBuiltInCommand.toggleSidebar.id,
                ToasttyBuiltInCommand.closePanel.id,
                ToasttyBuiltInCommand.reloadConfiguration.id,
            ]
        )
        XCTAssertEqual(
            viewModel.results.map(\.title),
            [
                ToasttyBuiltInCommand.splitRight.title,
                ToasttyBuiltInCommand.splitDown.title,
                ToasttyBuiltInCommand.newWorkspace.title,
                ToasttyBuiltInCommand.newTab.title,
                ToasttyBuiltInCommand.toggleSidebar.title,
                ToasttyBuiltInCommand.closePanel.title,
                ToasttyBuiltInCommand.reloadConfiguration.title,
            ]
        )
        XCTAssertEqual(
            viewModel.results.map { $0.command.shortcut?.symbolLabel },
            ["⌘D", "⇧⌘D", "⇧⌘N", "⌘T", "⌘B", "⌘W", nil]
        )
    }

    func testCatalogHidesReloadConfigurationWhenUnsupported() {
        let actions = MockCommandPaletteCatalogActions()
        actions.canReload = false

        let viewModel = makeViewModel(actions: actions)

        XCTAssertFalse(
            viewModel.results.contains(where: { $0.id == ToasttyBuiltInCommand.reloadConfiguration.id })
        )
    }

    func testCatalogExecutesNewTabAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.newTab.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.createdWorkspaceTabWindowIDs, [originWindowID])
    }

    func testTabQueryDoesNotSurfaceClosePanel() {
        let viewModel = makeViewModel(actions: MockCommandPaletteCatalogActions())

        viewModel.query = "tab"

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

    func testCatalogExecutesClosePanelAgainstOriginWindowID() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.closePanel.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.closedPanelWindowIDs, [originWindowID])
    }

    func testCatalogExecutesReloadConfigurationWhenSupported() {
        let actions = MockCommandPaletteCatalogActions()
        let viewModel = makeViewModel(actions: actions)

        viewModel.query = ToasttyBuiltInCommand.reloadConfiguration.title.lowercased()
        viewModel.submitSelection()

        XCTAssertEqual(actions.reloadConfigurationCount, 1)
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
            onExecuted: {}
        )
    }
}

@MainActor
private final class MockCommandPaletteCatalogActions: CommandPaletteActionHandling {
    var canReload = true
    var createdWorkspaceTabWindowIDs: [UUID] = []
    var splitCalls: [RecordedCatalogSplitCall] = []
    var closedPanelWindowIDs: [UUID] = []
    var reloadConfigurationCount = 0

    func commandSelection(originWindowID: UUID) -> WindowCommandSelection? {
        _ = originWindowID
        return nil
    }

    func canCreateWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func createWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
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
        splitCalls.append(RecordedCatalogSplitCall(direction: direction, originWindowID: originWindowID))
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
        closedPanelWindowIDs.append(originWindowID)
        return true
    }

    func canReloadConfiguration() -> Bool {
        canReload
    }

    func reloadConfiguration() -> Bool {
        guard canReload else {
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
