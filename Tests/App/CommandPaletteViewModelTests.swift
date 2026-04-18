import Foundation
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class CommandPaletteViewModelTests: XCTestCase {
    func testQueryFilteringOnlyReturnsMatchingAvailableCommands() {
        let actions = MockCommandPaletteActions()
        let viewModel = CommandPaletteViewModel(
            originWindowID: UUID(),
            commands: [
                makeCommand(id: "alpha", title: "Alpha Command", keywords: ["workspace"]),
                makeCommand(id: "sidebar", title: "Show Sidebar", keywords: ["toggle", "chrome"]),
                makeCommand(id: "hidden", title: "Hidden Command", keywords: ["internal"], isAvailable: false),
            ],
            actions: actions,
            onCancel: {},
            onExecuted: {}
        )

        XCTAssertEqual(viewModel.results.map(\.title), ["Alpha Command", "Show Sidebar"])

        viewModel.query = "side"
        XCTAssertEqual(viewModel.results.map(\.title), ["Show Sidebar"])

        viewModel.query = "work"
        XCTAssertEqual(viewModel.results.map(\.title), ["Alpha Command"])
    }

    func testSelectionStopsAtVisibleResultsBounds() {
        let viewModel = CommandPaletteViewModel(
            originWindowID: UUID(),
            commands: [
                makeCommand(id: "alpha", title: "Alpha", keywords: []),
                makeCommand(id: "beta", title: "Beta", keywords: []),
                makeCommand(id: "gamma", title: "Gamma", keywords: []),
            ],
            actions: MockCommandPaletteActions(),
            onCancel: {},
            onExecuted: {}
        )

        XCTAssertEqual(viewModel.selectedResult?.title, "Alpha")

        viewModel.moveSelection(delta: -1)
        XCTAssertEqual(viewModel.selectedResult?.title, "Alpha")

        viewModel.moveSelection(delta: 1)
        XCTAssertEqual(viewModel.selectedResult?.title, "Beta")

        viewModel.moveSelection(delta: 10)
        XCTAssertEqual(viewModel.selectedResult?.title, "Gamma")

        viewModel.moveSelection(delta: 1)
        XCTAssertEqual(viewModel.selectedResult?.title, "Gamma")
    }

    func testSelectionClampsWhenFilteringShrinksVisibleResults() {
        let viewModel = CommandPaletteViewModel(
            originWindowID: UUID(),
            commands: [
                makeCommand(id: "alpha", title: "Alpha", keywords: []),
                makeCommand(id: "beta", title: "Beta", keywords: []),
                makeCommand(id: "gamma", title: "Gamma", keywords: []),
            ],
            actions: MockCommandPaletteActions(),
            onCancel: {},
            onExecuted: {}
        )

        viewModel.moveSelection(delta: 2)
        XCTAssertEqual(viewModel.selectedResult?.title, "Gamma")

        viewModel.query = "beta"

        XCTAssertEqual(viewModel.results.map(\.title), ["Beta"])
        XCTAssertEqual(viewModel.selectedResult?.title, "Beta")
    }

    func testSubmitSelectionExecutesAgainstOriginWindowAndDismissesOnSuccess() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteActions()
        var executedWindowIDs: [UUID] = []
        var didExecuteCount = 0
        let viewModel = CommandPaletteViewModel(
            originWindowID: originWindowID,
            commands: [
                PaletteCommand(
                    id: "workspace.create",
                    keywords: ["workspace"],
                    shortcut: nil,
                    title: { _ in "New Workspace" },
                    isAvailable: { _ in true },
                    execute: { context in
                        executedWindowIDs.append(context.originWindowID)
                        return context.actions.createWorkspace(originWindowID: context.originWindowID)
                    }
                ),
            ],
            actions: actions,
            onCancel: {},
            onExecuted: {
                didExecuteCount += 1
            }
        )

        viewModel.submitSelection()

        XCTAssertEqual(executedWindowIDs, [originWindowID])
        XCTAssertEqual(actions.createdWorkspaceWindowIDs, [originWindowID])
        XCTAssertEqual(didExecuteCount, 1)
    }

    func testDismissInvokesCancelCallback() {
        var didCancelCount = 0
        let viewModel = CommandPaletteViewModel(
            originWindowID: UUID(),
            commands: [makeCommand(id: "alpha", title: "Alpha", keywords: [])],
            actions: MockCommandPaletteActions(),
            onCancel: {
                didCancelCount += 1
            },
            onExecuted: {}
        )

        viewModel.dismiss()

        XCTAssertEqual(didCancelCount, 1)
    }

    private func makeCommand(
        id: String,
        title: String,
        keywords: [String],
        isAvailable: Bool = true
    ) -> PaletteCommand {
        PaletteCommand(
            id: id,
            keywords: keywords,
            shortcut: nil,
            title: { _ in title },
            isAvailable: { _ in isAvailable },
            execute: { _ in true }
        )
    }
}

@MainActor
private final class MockCommandPaletteActions: CommandPaletteActionHandling {
    var createdWindowIDs: [UUID] = []
    var createdWorkspaceWindowIDs: [UUID] = []

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
        _ = originWindowID
        return true
    }

    func canSplit(direction: SlotSplitDirection, originWindowID: UUID) -> Bool {
        _ = direction
        _ = originWindowID
        return true
    }

    func split(direction: SlotSplitDirection, originWindowID: UUID) -> Bool {
        _ = direction
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
        _ = originWindowID
        return true
    }

    func canRenameWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func renameWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func canCloseWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func closeWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func canRenameTab(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func renameTab(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func canSelectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool {
        _ = direction
        _ = originWindowID
        return true
    }

    func selectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool {
        _ = direction
        _ = originWindowID
        return true
    }

    func canJumpToNextActive(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func jumpToNextActive(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return true
    }

    func canReloadConfiguration() -> Bool {
        true
    }

    func reloadConfiguration() -> Bool {
        true
    }
}
