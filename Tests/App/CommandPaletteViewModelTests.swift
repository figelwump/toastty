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
            onSubmitted: {}
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
            onSubmitted: {}
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
            onSubmitted: {}
        )

        viewModel.moveSelection(delta: 2)
        XCTAssertEqual(viewModel.selectedResult?.title, "Gamma")

        viewModel.query = "beta"

        XCTAssertEqual(viewModel.results.map(\.title), ["Beta"])
        XCTAssertEqual(viewModel.selectedResult?.title, "Beta")
    }

    func testScrollTargetIsNilWhenSelectedRowIsVisible() {
        XCTAssertNil(
            CommandPaletteScrollVisibility.scrollTarget(
                for: CGRect(x: 0, y: 8, width: 320, height: 38),
                viewportHeight: 120
            )
        )
    }

    func testScrollTargetUsesTopWhenSelectedRowIsAboveViewport() {
        XCTAssertEqual(
            CommandPaletteScrollVisibility.scrollTarget(
                for: CGRect(x: 0, y: -12, width: 320, height: 38),
                viewportHeight: 120
            ),
            .top
        )
    }

    func testScrollTargetUsesBottomWhenSelectedRowIsBelowViewport() {
        XCTAssertEqual(
            CommandPaletteScrollVisibility.scrollTarget(
                for: CGRect(x: 0, y: 96, width: 320, height: 38),
                viewportHeight: 120
            ),
            .bottom
        )
    }

    func testScrollTargetIgnoresSubpointOverflowWithinTolerance() {
        XCTAssertNil(
            CommandPaletteScrollVisibility.scrollTarget(
                for: CGRect(x: 0, y: 82.2, width: 320, height: 38.4),
                viewportHeight: 120
            )
        )
    }

    func testSubmitSelectionExecutesAgainstOriginWindowAndDismissesAfterSubmit() {
        let originWindowID = UUID()
        let actions = MockCommandPaletteActions()
        let usageTracker = MockCommandPaletteUsageTracker()
        var executedWindowIDs: [UUID] = []
        var didSubmitCount = 0
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
            usageTracker: usageTracker,
            onCancel: {},
            onSubmitted: {
                didSubmitCount += 1
            }
        )

        viewModel.submitSelection()

        XCTAssertEqual(executedWindowIDs, [originWindowID])
        XCTAssertEqual(actions.createdWorkspaceWindowIDs, [originWindowID])
        XCTAssertEqual(usageTracker.recordedCommandIDs, ["workspace.create"])
        XCTAssertEqual(didSubmitCount, 1)
    }

    func testSubmitSelectionDismissesAfterFailedExecution() {
        let usageTracker = MockCommandPaletteUsageTracker()
        var didSubmitCount = 0
        let viewModel = CommandPaletteViewModel(
            originWindowID: UUID(),
            commands: [
                PaletteCommand(
                    id: "noop",
                    keywords: ["noop"],
                    shortcut: nil,
                    title: { _ in "No-op" },
                    isAvailable: { _ in true },
                    execute: { _ in false }
                ),
            ],
            actions: MockCommandPaletteActions(),
            usageTracker: usageTracker,
            onCancel: {},
            onSubmitted: {
                didSubmitCount += 1
            }
        )

        viewModel.submitSelection()

        XCTAssertTrue(usageTracker.recordedCommandIDs.isEmpty)
        XCTAssertEqual(didSubmitCount, 1)
    }

    func testEmptyQueryKeepsCatalogOrderEvenWhenUsageCountsDiffer() {
        let usageTracker = MockCommandPaletteUsageTracker()
        usageTracker.counts = [
            "window": 12,
            "workspace": 3,
        ]
        let viewModel = CommandPaletteViewModel(
            originWindowID: UUID(),
            commands: [
                makeCommand(id: "workspace", title: "New Workspace", keywords: []),
                makeCommand(id: "window", title: "New Window", keywords: []),
                makeCommand(id: "tab", title: "New Tab", keywords: []),
            ],
            actions: MockCommandPaletteActions(),
            usageTracker: usageTracker,
            onCancel: {},
            onSubmitted: {}
        )

        XCTAssertEqual(viewModel.results.map(\.id), ["workspace", "window", "tab"])
    }

    func testQueryRankingBoostsFrequentlyUsedCommandsWithinSameMatchBucket() {
        let usageTracker = MockCommandPaletteUsageTracker()
        usageTracker.counts = [
            "window": 12,
            "workspace": 1,
        ]
        let viewModel = CommandPaletteViewModel(
            originWindowID: UUID(),
            commands: [
                makeCommand(id: "workspace", title: "New Workspace", keywords: []),
                makeCommand(id: "window", title: "New Window", keywords: []),
                makeCommand(id: "tab", title: "New Tab", keywords: []),
            ],
            actions: MockCommandPaletteActions(),
            usageTracker: usageTracker,
            onCancel: {},
            onSubmitted: {}
        )

        viewModel.query = "new"

        XCTAssertEqual(viewModel.results.map(\.id), ["window", "workspace", "tab"])
    }

    func testStrongerTitleMatchBucketStaysAheadOfMoreFrequentWeakerTitleMatch() {
        let usageTracker = MockCommandPaletteUsageTracker()
        usageTracker.counts = [
            "boundary": 40,
        ]
        let viewModel = CommandPaletteViewModel(
            originWindowID: UUID(),
            commands: [
                makeCommand(id: "prefix", title: "Workspace Dashboard", keywords: []),
                makeCommand(id: "boundary", title: "Open Workspace", keywords: []),
            ],
            actions: MockCommandPaletteActions(),
            usageTracker: usageTracker,
            onCancel: {},
            onSubmitted: {}
        )

        viewModel.query = "workspace"

        XCTAssertEqual(viewModel.results.map(\.id), ["prefix", "boundary"])
    }

    func testTitleMatchesStayAheadOfKeywordMatchesDespiteHigherUsage() {
        let usageTracker = MockCommandPaletteUsageTracker()
        usageTracker.counts = [
            "keyword": 25,
        ]
        let viewModel = CommandPaletteViewModel(
            originWindowID: UUID(),
            commands: [
                makeCommand(id: "title", title: "Open Workspace", keywords: []),
                makeCommand(id: "keyword", title: "Alpha Command", keywords: ["workspace"]),
            ],
            actions: MockCommandPaletteActions(),
            usageTracker: usageTracker,
            onCancel: {},
            onSubmitted: {}
        )

        viewModel.query = "workspace"

        XCTAssertEqual(viewModel.results.map(\.id), ["title", "keyword"])
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
            onSubmitted: {}
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

@MainActor
private final class MockCommandPaletteUsageTracker: CommandPaletteUsageTracking {
    var counts: [String: Int] = [:]
    var recordedCommandIDs: [String] = []

    func useCount(for commandID: String) -> Int {
        counts[commandID] ?? 0
    }

    func recordSuccessfulExecution(of commandID: String) {
        recordedCommandIDs.append(commandID)
        counts[commandID, default: 0] += 1
    }
}
