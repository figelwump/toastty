import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

@MainActor
final class CommandPaletteViewModelTests: XCTestCase {
    func testQueryFilteringOnlyReturnsMatchingCommands() {
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "alpha", title: "Alpha Command", keywords: ["workspace"]),
                makeCommand(id: "sidebar", title: "Show Sidebar", keywords: ["toggle", "chrome"]),
                makeCommand(id: "browser", title: "New Browser", keywords: ["web"]),
            ]
        )

        XCTAssertEqual(viewModel.results.map(\.title), ["Alpha Command", "Show Sidebar", "New Browser"])

        viewModel.query = "side"
        XCTAssertEqual(viewModel.results.map(\.title), ["Show Sidebar"])

        viewModel.query = "work"
        XCTAssertEqual(viewModel.results.map(\.title), ["Alpha Command"])
    }

    func testSelectionStopsAtVisibleResultsBounds() {
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "alpha", title: "Alpha"),
                makeCommand(id: "beta", title: "Beta"),
                makeCommand(id: "gamma", title: "Gamma"),
            ]
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

    func testQueryChangeResetsSelectionToTopResult() {
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "alpha", title: "Alpha"),
                makeCommand(id: "beta", title: "Beta"),
                makeCommand(id: "gamma", title: "Gamma"),
            ]
        )

        viewModel.moveSelection(delta: 2)
        XCTAssertEqual(viewModel.selectedResult?.title, "Gamma")

        viewModel.query = "beta"

        XCTAssertEqual(viewModel.results.map(\.title), ["Beta"])
        XCTAssertEqual(viewModel.selectedResult?.title, "Beta")
    }

    func testQueryChangeSelectsTopRankedResultInsteadOfPreservingPreviousMatch() {
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "select.next", title: "Select Next Split"),
                makeCommand(id: "select.previous", title: "Alpha Select Split"),
                makeCommand(id: "select.previous-tab", title: "Select Previous Tab"),
                makeCommand(id: "select.next-tab", title: "Select Next Tab"),
            ]
        )

        viewModel.moveSelection(delta: 1)
        XCTAssertEqual(viewModel.selectedResult?.id, "select.previous")

        viewModel.query = "sele"

        XCTAssertEqual(
            viewModel.results.map(\.id),
            ["select.next", "select.previous-tab", "select.next-tab", "select.previous"]
        )
        XCTAssertEqual(viewModel.selectedResult?.id, "select.next")
    }

    func testQueryChangeToNoResultsLeavesNoSelectedResult() {
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "alpha", title: "Alpha"),
                makeCommand(id: "beta", title: "Beta"),
            ]
        )

        viewModel.moveSelection(delta: 1)
        XCTAssertEqual(viewModel.selectedResult?.id, "beta")

        viewModel.query = "zzz"

        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertNil(viewModel.selectedResult)
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
        let usageTracker = MockCommandPaletteUsageTracker()
        var executedInvocations: [PaletteCommandInvocation] = []
        var executedWindowIDs: [UUID] = []
        var submitCount = 0
        let viewModel = makeViewModel(
            originWindowID: originWindowID,
            commands: [
                makeCommand(
                    id: "workspace.create",
                    title: "New Workspace",
                    usageKey: "workspace.create",
                    invocation: .builtIn(.newWorkspace)
                ),
            ],
            usageTracker: usageTracker,
            executeCommand: { invocation, originWindowID in
                executedInvocations.append(invocation)
                executedWindowIDs.append(originWindowID)
                return true
            },
            onSubmitted: {
                submitCount += 1
            }
        )

        viewModel.submitSelection()

        XCTAssertEqual(executedInvocations, [.builtIn(.newWorkspace)])
        XCTAssertEqual(executedWindowIDs, [originWindowID])
        XCTAssertEqual(usageTracker.recordedCommandIDs, ["workspace.create"])
        XCTAssertEqual(submitCount, 1)
    }

    func testSubmitSelectionDismissesAfterFailedExecution() {
        let usageTracker = MockCommandPaletteUsageTracker()
        var submitCount = 0
        let viewModel = makeViewModel(
            commands: [makeCommand(id: "noop", title: "No-op", usageKey: "noop")],
            usageTracker: usageTracker,
            executeCommand: { _, _ in false },
            onSubmitted: {
                submitCount += 1
            }
        )

        viewModel.submitSelection()

        XCTAssertTrue(usageTracker.recordedCommandIDs.isEmpty)
        XCTAssertEqual(submitCount, 1)
    }

    func testEmptyQueryKeepsCatalogOrderEvenWhenUsageCountsDiffer() {
        let usageTracker = MockCommandPaletteUsageTracker()
        usageTracker.counts = [
            "window": 12,
            "workspace": 3,
        ]
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "workspace", title: "New Workspace"),
                makeCommand(id: "window", title: "New Window"),
                makeCommand(id: "tab", title: "New Tab"),
            ],
            usageTracker: usageTracker
        )

        XCTAssertEqual(viewModel.results.map(\.id), ["workspace", "window", "tab"])
    }

    func testQueryRankingBoostsFrequentlyUsedCommandsWithinSameMatchBucket() {
        let usageTracker = MockCommandPaletteUsageTracker()
        usageTracker.counts = [
            "window": 12,
            "workspace": 1,
        ]
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "workspace", title: "New Workspace"),
                makeCommand(id: "window", title: "New Window"),
                makeCommand(id: "tab", title: "New Tab"),
            ],
            usageTracker: usageTracker
        )

        viewModel.query = "new"

        XCTAssertEqual(viewModel.results.map(\.id), ["window", "workspace", "tab"])
    }

    func testStrongerTitleMatchStaysAheadOfMoreFrequentWeakerTitleMatch() {
        let usageTracker = MockCommandPaletteUsageTracker()
        usageTracker.counts = ["boundary": 40]
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "prefix", title: "Workspace Dashboard"),
                makeCommand(id: "boundary", title: "Open Workspace"),
            ],
            usageTracker: usageTracker
        )

        viewModel.query = "workspace"

        XCTAssertEqual(viewModel.results.map(\.id), ["prefix", "boundary"])
    }

    func testTitleMatchesStayAheadOfKeywordMatchesDespiteHigherUsage() {
        let usageTracker = MockCommandPaletteUsageTracker()
        usageTracker.counts = ["keyword": 25]
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "title", title: "Open Workspace"),
                makeCommand(id: "keyword", title: "Alpha Command", keywords: ["workspace"]),
            ],
            usageTracker: usageTracker
        )

        viewModel.query = "workspace"

        XCTAssertEqual(viewModel.results.map(\.id), ["title", "keyword"])
    }

    func testNonContiguousQueryMatchesAcrossWordParts() {
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "split.down", title: "Split Down"),
                makeCommand(id: "split.right", title: "Split Right"),
            ]
        )

        viewModel.query = "dn"

        XCTAssertEqual(viewModel.results.map(\.id), ["split.down"])
    }

    func testCompactAbbreviationMatchesAcrossMultipleWords() {
        let viewModel = makeViewModel(
            commands: [
                makeCommand(id: "split.down", title: "Split Down"),
                makeCommand(id: "split.right", title: "Split Right"),
                makeCommand(id: "sidebar", title: "Show Sidebar"),
            ]
        )

        viewModel.query = "spdn"

        XCTAssertEqual(viewModel.results.map(\.id), ["split.down"])
    }

    func testRefreshProjectedCommandsUsesLatestProjectedCatalog() {
        let projectedCommands = ProjectedCommandsBox(
            value: [makeCommand(id: "alpha", title: "Alpha")]
        )
        let viewModel = makeViewModel(projectCommands: { projectedCommands.value })

        XCTAssertEqual(viewModel.results.map(\.id), ["alpha"])

        projectedCommands.value = [
            makeCommand(id: "beta", title: "Beta"),
            makeCommand(id: "gamma", title: "Gamma"),
        ]
        viewModel.refreshProjectedCommands()

        XCTAssertEqual(viewModel.results.map(\.id), ["beta", "gamma"])
        XCTAssertEqual(viewModel.selectedResult?.id, "beta")
    }

    func testDismissInvokesCancelCallback() {
        var cancelCount = 0
        let viewModel = makeViewModel(
            commands: [makeCommand(id: "alpha", title: "Alpha")],
            onCancel: {
                cancelCount += 1
            }
        )

        viewModel.dismiss()

        XCTAssertEqual(cancelCount, 1)
    }

    private func makeViewModel(
        originWindowID: UUID = UUID(),
        commands: [PaletteCommandDescriptor] = [],
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        executeCommand: @escaping @MainActor (PaletteCommandInvocation, UUID) -> Bool = { _, _ in true },
        onCancel: @escaping () -> Void = {},
        onSubmitted: @escaping () -> Void = {}
    ) -> CommandPaletteViewModel {
        makeViewModel(
            originWindowID: originWindowID,
            projectCommands: { commands },
            usageTracker: usageTracker,
            executeCommand: executeCommand,
            onCancel: onCancel,
            onSubmitted: onSubmitted
        )
    }

    private func makeViewModel(
        originWindowID: UUID = UUID(),
        projectCommands: @escaping @MainActor () -> [PaletteCommandDescriptor],
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        executeCommand: @escaping @MainActor (PaletteCommandInvocation, UUID) -> Bool = { _, _ in true },
        onCancel: @escaping () -> Void = {},
        onSubmitted: @escaping () -> Void = {}
    ) -> CommandPaletteViewModel {
        CommandPaletteViewModel(
            originWindowID: originWindowID,
            projectCommands: projectCommands,
            executeCommand: executeCommand,
            usageTracker: usageTracker,
            onCancel: onCancel,
            onSubmitted: onSubmitted
        )
    }

    private func makeCommand(
        id: String,
        title: String,
        keywords: [String] = [],
        usageKey: String? = nil,
        shortcut: PaletteShortcut? = nil,
        invocation: PaletteCommandInvocation = .builtIn(.newWindow)
    ) -> PaletteCommandDescriptor {
        PaletteCommandDescriptor(
            id: id,
            usageKey: usageKey ?? id,
            title: title,
            keywords: keywords,
            shortcut: shortcut,
            invocation: invocation
        )
    }
}

@MainActor
private final class ProjectedCommandsBox {
    var value: [PaletteCommandDescriptor]

    init(value: [PaletteCommandDescriptor]) {
        self.value = value
    }
}

@MainActor
private final class MockCommandPaletteUsageTracker: CommandPaletteUsageTracking {
    var counts: [String: Int] = [:]
    var recordedCommandIDs: [String] = []

    func useCount(for commandID: String) -> Int {
        counts[commandID, default: 0]
    }

    func recordSuccessfulExecution(of commandID: String) {
        recordedCommandIDs.append(commandID)
        counts[commandID, default: 0] += 1
    }
}
