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

    func testSelectionWrapsAroundVisibleResults() {
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
        XCTAssertEqual(viewModel.selectedResult?.title, "Gamma")

        viewModel.moveSelection(delta: 1)
        XCTAssertEqual(viewModel.selectedResult?.title, "Alpha")
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
