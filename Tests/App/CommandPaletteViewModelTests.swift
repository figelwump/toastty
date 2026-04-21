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

    func testBareAtSwitchesToFileModeWithoutListingAllFiles() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: "/tmp/toastty-worktree/README.md",
                                relativePath: "README.md",
                                destination: .localDocument(filePath: "/tmp/toastty-worktree/README.md")
                            ),
                            self.makeFileResult(
                                filePath: "/tmp/toastty-worktree/package.json",
                                relativePath: "package.json",
                                destination: .localDocument(filePath: "/tmp/toastty-worktree/package.json")
                            ),
                        ]),
                    ],
                    indexedResults: []
                ),
            ]
        )
        let viewModel = makeViewModel(
            commands: [makeCommand(id: "alpha", title: "Alpha")],
            resolveFileSearchScope: { _ in scope },
            fileIndexService: fileIndexService
        )

        viewModel.query = "@"
        try await waitUntil {
            viewModel.mode == .fileOpen &&
                viewModel.emptyState.title == "Type to search local files"
        }

        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertEqual(viewModel.placeholder, "Open a local file...")
        XCTAssertEqual(viewModel.footerText, scope.label)
        XCTAssertTrue(viewModel.emptyState.message.contains(".html"))
        XCTAssertTrue(viewModel.emptyState.message.contains(".json"))
    }

    func testDeletingLeadingAtReturnsToCommandMode() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: "/tmp/toastty-worktree/README.md",
                                relativePath: "README.md",
                                destination: .localDocument(filePath: "/tmp/toastty-worktree/README.md")
                            ),
                        ]),
                    ],
                    indexedResults: []
                ),
            ]
        )
        let viewModel = makeViewModel(
            commands: [makeCommand(id: "alpha", title: "Alpha")],
            resolveFileSearchScope: { _ in scope },
            fileIndexService: fileIndexService
        )

        viewModel.query = "@read"
        try await waitUntil {
            viewModel.mode == .fileOpen &&
                viewModel.results.map(\.id) == ["/tmp/toastty-worktree/README.md"]
        }

        viewModel.query = ""

        XCTAssertEqual(viewModel.mode, .commands)
        XCTAssertEqual(viewModel.placeholder, "Type a command...")
        XCTAssertEqual(viewModel.results.map(\.id), ["alpha"])
    }

    func testFileModeRoutesLocalDocumentAndHTMLResults() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let packagePath = "/tmp/toastty-worktree/package.json"
        let indexPath = "/tmp/toastty-worktree/index.html"
        let originWindowID = UUID()
        let actions = CommandPaletteActionSpy()
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: packagePath,
                                relativePath: "package.json",
                                destination: .localDocument(filePath: packagePath)
                            ),
                            self.makeFileResult(
                                filePath: indexPath,
                                relativePath: "index.html",
                                destination: .browser(
                                    fileURLString: URL(fileURLWithPath: indexPath).absoluteString
                                )
                            ),
                        ]),
                    ],
                    indexedResults: []
                ),
            ]
        )
        let viewModel = makeViewModel(
            originWindowID: originWindowID,
            commands: [],
            resolveFileSearchScope: { _ in scope },
            openFileResult: { destination, originWindowID in
                actions.openFileResult(destination, originWindowID: originWindowID)
            },
            fileIndexService: fileIndexService
        )

        viewModel.query = "@package"
        try await waitUntil {
            viewModel.results.count == 1 && viewModel.results.first?.title == "package.json"
        }
        viewModel.submitSelection()

        viewModel.query = "@index"
        try await waitUntil {
            viewModel.results.count == 1 && viewModel.results.first?.title == "index.html"
        }
        viewModel.submitSelection()

        XCTAssertEqual(
            actions.openedFileResults,
            [
                RecordedPaletteFileOpenCall(
                    destination: .localDocument(
                        filePath: packagePath
                    ),
                    originWindowID: originWindowID
                ),
                RecordedPaletteFileOpenCall(
                    destination: .browser(
                        fileURLString: URL(fileURLWithPath: indexPath).absoluteString
                    ),
                    originWindowID: originWindowID
                ),
            ]
        )
    }

    func testMissingFileScopeShowsFileModeEmptyState() {
        let viewModel = makeViewModel(
            commands: [makeCommand(id: "alpha", title: "Alpha")],
            resolveFileSearchScope: { _ in nil }
        )

        viewModel.query = "@read"

        XCTAssertEqual(viewModel.mode, .fileOpen)
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertEqual(viewModel.emptyState.title, "No contextual file scope")
    }

    func testFileModeShowsIndexingStateBeforeInitialIndexCompletes() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let readmePath = "/tmp/toastty-worktree/README.md"
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .indexing(results: []),
                    ],
                    indexedResults: [
                        [
                            self.makeFileResult(
                                filePath: readmePath,
                                relativePath: "README.md",
                                destination: .localDocument(filePath: readmePath)
                            ),
                        ],
                    ]
                ),
            ]
        )
        let viewModel = makeViewModel(
            commands: [],
            resolveFileSearchScope: { _ in scope },
            fileIndexService: fileIndexService
        )

        viewModel.query = "@read"

        XCTAssertEqual(viewModel.emptyState.title, "Indexing supported files")
        try await waitUntil {
            viewModel.results.map(\.id) == [readmePath]
        }
    }

    func testFileModePrefersShallowerRelativePathsWhenMatchesTie() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let rootReadmePath = "/tmp/toastty-worktree/README.md"
        let artifactsReadmePath = "/tmp/toastty-worktree/artifacts/tmp/README.md"
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: artifactsReadmePath,
                                relativePath: "artifacts/tmp/README.md",
                                destination: .localDocument(filePath: artifactsReadmePath)
                            ),
                            self.makeFileResult(
                                filePath: rootReadmePath,
                                relativePath: "README.md",
                                destination: .localDocument(filePath: rootReadmePath)
                            ),
                        ]),
                    ],
                    indexedResults: []
                ),
            ]
        )
        let viewModel = makeViewModel(
            commands: [],
            resolveFileSearchScope: { _ in scope },
            fileIndexService: fileIndexService
        )

        viewModel.query = "@read"
        try await waitUntil {
            viewModel.results.count == 2
        }

        XCTAssertEqual(
            viewModel.results.map(\.id),
            [rootReadmePath, artifactsReadmePath]
        )
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
        resolveFileSearchScope: @escaping @MainActor (UUID) -> PaletteFileSearchScope? = { _ in nil },
        openFileResult: @escaping @MainActor (PaletteFileOpenDestination, UUID) -> Bool = { _, _ in true },
        fileIndexService: any CommandPaletteFileIndexing = CommandPaletteFileOpenProvider(),
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        executeCommand: @escaping @MainActor (PaletteCommandInvocation, UUID) -> Bool = { _, _ in true },
        onCancel: @escaping () -> Void = {},
        onSubmitted: @escaping () -> Void = {}
    ) -> CommandPaletteViewModel {
        makeViewModel(
            originWindowID: originWindowID,
            projectCommands: { commands },
            resolveFileSearchScope: resolveFileSearchScope,
            openFileResult: openFileResult,
            fileIndexService: fileIndexService,
            usageTracker: usageTracker,
            executeCommand: executeCommand,
            onCancel: onCancel,
            onSubmitted: onSubmitted
        )
    }

    private func makeViewModel(
        originWindowID: UUID = UUID(),
        projectCommands: @escaping @MainActor () -> [PaletteCommandDescriptor],
        resolveFileSearchScope: @escaping @MainActor (UUID) -> PaletteFileSearchScope? = { _ in nil },
        openFileResult: @escaping @MainActor (PaletteFileOpenDestination, UUID) -> Bool = { _, _ in true },
        fileIndexService: any CommandPaletteFileIndexing = CommandPaletteFileOpenProvider(),
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        executeCommand: @escaping @MainActor (PaletteCommandInvocation, UUID) -> Bool = { _, _ in true },
        onCancel: @escaping () -> Void = {},
        onSubmitted: @escaping () -> Void = {}
    ) -> CommandPaletteViewModel {
        CommandPaletteViewModel(
            originWindowID: originWindowID,
            projectCommands: projectCommands,
            executeCommand: executeCommand,
            resolveFileSearchScope: resolveFileSearchScope,
            openFileResult: openFileResult,
            fileIndexService: fileIndexService,
            usageTracker: usageTracker,
            onCancel: onCancel,
            onSubmitted: onSubmitted
        )
    }

    private func makeFileResult(
        filePath: String,
        relativePath: String,
        destination: PaletteFileOpenDestination
    ) -> PaletteFileResult {
        PaletteFileResult(
            filePath: filePath,
            fileName: URL(fileURLWithPath: filePath).lastPathComponent,
            relativePath: relativePath,
            destination: destination
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

private actor MockCommandPaletteFileIndexService: CommandPaletteFileIndexing {
    struct ScopeState {
        var prepareSnapshots: [CommandPaletteFileIndexSnapshot]
        var indexedResults: [[PaletteFileResult]]
        var lastResults: [PaletteFileResult] = []
    }

    private var states: [String: ScopeState]

    init(states: [String: ScopeState] = [:]) {
        self.states = states
    }

    func prepareIndex(in scope: PaletteFileSearchScope) async -> CommandPaletteFileIndexSnapshot {
        var state = states[scope.rootPath] ?? ScopeState(
            prepareSnapshots: [.ready(results: [])],
            indexedResults: []
        )
        let snapshot = state.prepareSnapshots.isEmpty
            ? .ready(results: state.lastResults)
            : state.prepareSnapshots.removeFirst()
        state.lastResults = snapshot.results
        states[scope.rootPath] = state
        return snapshot
    }

    func indexedFiles(in scope: PaletteFileSearchScope) async -> [PaletteFileResult] {
        var state = states[scope.rootPath] ?? ScopeState(
            prepareSnapshots: [],
            indexedResults: [[]]
        )
        let results = state.indexedResults.isEmpty
            ? state.lastResults
            : state.indexedResults.removeFirst()
        state.lastResults = results
        states[scope.rootPath] = state
        return results
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while await condition() == false {
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            XCTFail("Timed out waiting for condition")
            return
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}
