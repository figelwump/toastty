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

    func testSubmitSelectionUsesDefaultPlacementForFileResults() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let filePath = "/tmp/toastty-worktree/README.md"
        let actions = CommandPaletteActionSpy()
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: filePath,
                                relativePath: "README.md",
                                destination: .localDocument(filePath: filePath)
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
            openFileResult: { destination, placement, originWindowID in
                actions.openFileResult(
                    destination,
                    placement: placement,
                    originWindowID: originWindowID
                )
            },
            fileIndexService: fileIndexService
        )

        viewModel.query = "@read"
        try await waitUntil {
            viewModel.results.map(\.id) == [filePath]
        }

        viewModel.submitSelection()

        XCTAssertEqual(
            actions.openedFileResults,
            [
                RecordedPaletteFileOpenCall(
                    destination: .localDocument(filePath: filePath),
                    placement: .default,
                    originWindowID: viewModel.originWindowID
                ),
            ]
        )
    }

    func testSubmitAlternateSelectionRoutesAlternatePlacementToFileOpen() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let filePath = "/tmp/toastty-worktree/docs/notes.md"
        let actions = CommandPaletteActionSpy()
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: filePath,
                                relativePath: "docs/notes.md",
                                destination: .localDocument(filePath: filePath)
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
            openFileResult: { destination, placement, originWindowID in
                actions.openFileResult(
                    destination,
                    placement: placement,
                    originWindowID: originWindowID
                )
            },
            fileIndexService: fileIndexService
        )

        viewModel.query = "@notes"
        try await waitUntil {
            viewModel.results.map(\.id) == [filePath]
        }

        viewModel.submitAlternateSelection()

        XCTAssertEqual(
            actions.openedFileResults,
            [
                RecordedPaletteFileOpenCall(
                    destination: .localDocument(filePath: filePath),
                    placement: .alternate,
                    originWindowID: viewModel.originWindowID
                ),
            ]
        )
    }

    func testSubmitAlternateSelectionInCommandsModeStillExecutesCommand() {
        let originWindowID = UUID()
        var executedInvocations: [PaletteCommandInvocation] = []
        let actions = CommandPaletteActionSpy()
        let viewModel = makeViewModel(
            originWindowID: originWindowID,
            commands: [
                makeCommand(
                    id: "workspace.create",
                    title: "New Workspace",
                    invocation: .builtIn(.newWorkspace)
                ),
            ],
            openFileResult: { destination, placement, commandOriginWindowID in
                actions.openFileResult(
                    destination,
                    placement: placement,
                    originWindowID: commandOriginWindowID
                )
            },
            executeCommand: { invocation, commandOriginWindowID in
                XCTAssertEqual(commandOriginWindowID, originWindowID)
                executedInvocations.append(invocation)
                return true
            }
        )

        viewModel.submitAlternateSelection()

        XCTAssertEqual(executedInvocations, [.builtIn(.newWorkspace)])
        XCTAssertTrue(actions.openedFileResults.isEmpty)
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

    func testRefreshProjectedCommandsReflectsReloadedAgentAndTerminalProfileCatalogs() throws {
        let originWindowID = UUID()
        let actions = CommandPaletteActionSpy()
        let catalogStores = try ReloadablePaletteCatalogStores()
        let viewModel = makeViewModel(
            originWindowID: originWindowID,
            projectCommands: {
                CommandPaletteCatalog.commands(
                    originWindowID: originWindowID,
                    actions: actions,
                    agentCatalog: catalogStores.agentCatalogStore.catalog,
                    terminalProfileCatalog: catalogStores.terminalProfileStore.catalog,
                    profileShortcutRegistry: makeProfileShortcutRegistry(
                        terminalProfiles: catalogStores.terminalProfileStore.catalog,
                        terminalProfilesFilePath: catalogStores.terminalProfileStore.fileURL.path,
                        agentProfiles: catalogStores.agentCatalogStore.catalog,
                        agentProfilesFilePath: catalogStores.agentCatalogStore.fileURL.path
                    )
                )
            }
        )

        XCTAssertFalse(viewModel.results.contains(where: { $0.id == "agent.run.codex" }))
        XCTAssertFalse(viewModel.results.contains(where: { $0.id == "terminal-profile.zmx.split-right" }))

        try catalogStores.writeAgentsToml(
            """
            [codex]
            displayName = "Codex"
            argv = ["codex"]
            shortcutKey = "c"
            """
        )
        try catalogStores.writeTerminalProfilesToml(
            """
            [zmx]
            displayName = "ZMX"
            badge = "ZMX"
            startupCommand = "zmx attach"
            shortcutKey = "z"
            """
        )

        switch catalogStores.agentCatalogStore.reload() {
        case .success:
            break
        case .failure(let error):
            XCTFail("agent reload failed: \(error)")
        }
        switch catalogStores.terminalProfileStore.reload() {
        case .success:
            break
        case .failure(let error):
            XCTFail("terminal profile reload failed: \(error)")
        }

        viewModel.refreshProjectedCommands()

        XCTAssertTrue(viewModel.results.contains(where: { $0.id == "agent.run.codex" }))
        XCTAssertTrue(viewModel.results.contains(where: { $0.id == "terminal-profile.zmx.split-right" }))
        XCTAssertTrue(viewModel.results.contains(where: { $0.id == "terminal-profile.zmx.split-down" }))
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
        XCTAssertEqual(viewModel.emptyState.message, scope.label)
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
            openFileResult: { destination, placement, originWindowID in
                actions.openFileResult(
                    destination,
                    placement: placement,
                    originWindowID: originWindowID
                )
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
                    placement: .default,
                    originWindowID: originWindowID
                ),
                RecordedPaletteFileOpenCall(
                    destination: .browser(
                        fileURLString: URL(fileURLWithPath: indexPath).absoluteString
                    ),
                    placement: .default,
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
                    indexedFilesDelayNanoseconds: 100_000_000,
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

        try await waitUntil {
            viewModel.emptyState.title == "Indexing local files"
        }
        try await waitUntil {
            viewModel.results.map(\.id) == [readmePath]
        }
    }

    func testBareAtShowsRecentFilesOrderedByRecency() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let usageTracker = MockCommandPaletteUsageTracker()
        let readmePath = "/tmp/toastty-worktree/README.md"
        let notesPath = "/tmp/toastty-worktree/docs/notes.md"
        usageTracker.counts = [
            "file-open:\(readmePath)": 1,
            "file-open:\(notesPath)": 4,
        ]
        usageTracker.lastUsedAtByID = [
            "file-open:\(readmePath)": Date(timeIntervalSinceReferenceDate: 100),
            "file-open:\(notesPath)": Date(timeIntervalSinceReferenceDate: 200),
        ]
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: readmePath,
                                relativePath: "README.md",
                                destination: .localDocument(filePath: readmePath)
                            ),
                            self.makeFileResult(
                                filePath: notesPath,
                                relativePath: "docs/notes.md",
                                destination: .localDocument(filePath: notesPath)
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
            fileIndexService: fileIndexService,
            usageTracker: usageTracker
        )

        viewModel.query = "@"
        try await waitUntil {
            viewModel.results.map(\.id) == [notesPath, readmePath]
        }

        XCTAssertEqual(viewModel.emptyState.title, "")
        XCTAssertEqual(viewModel.emptyState.message, "")
        XCTAssertEqual(viewModel.footerText, scope.label)
    }

    func testWhitespaceOnlyFileQueryStillShowsRecentFiles() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let usageTracker = MockCommandPaletteUsageTracker()
        let readmePath = "/tmp/toastty-worktree/README.md"
        usageTracker.counts = [
            "file-open:\(readmePath)": 2,
        ]
        usageTracker.lastUsedAtByID = [
            "file-open:\(readmePath)": Date(timeIntervalSinceReferenceDate: 100),
        ]
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: readmePath,
                                relativePath: "README.md",
                                destination: .localDocument(filePath: readmePath)
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
            fileIndexService: fileIndexService,
            usageTracker: usageTracker
        )

        viewModel.query = "@   "

        try await waitUntil {
            viewModel.results.map(\.id) == [readmePath]
        }
        XCTAssertEqual(viewModel.footerText, scope.label)
    }

    func testTypingWithinSameScopeReusesCurrentIndexSnapshot() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let readmePath = "/tmp/toastty-worktree/README.md"
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: readmePath,
                                relativePath: "README.md",
                                destination: .localDocument(filePath: readmePath)
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

        viewModel.query = "@r"
        try await waitUntil {
            viewModel.results.map(\.id) == [readmePath]
        }

        viewModel.query = "@re"
        try await waitUntil {
            viewModel.results.map(\.id) == [readmePath]
        }

        let prepareCallCount = await fileIndexService.prepareCallCount(for: scope.rootPath)
        XCTAssertEqual(prepareCallCount, 1)
    }

    func testSeparateViewModelsReuseSharedFileIndexServiceAcrossPaletteSessions() async throws {
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
                        .ready(results: [
                            self.makeFileResult(
                                filePath: readmePath,
                                relativePath: "README.md",
                                destination: .localDocument(filePath: readmePath)
                            ),
                        ]),
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
        let firstViewModel = makeViewModel(
            commands: [],
            resolveFileSearchScope: { _ in scope },
            fileIndexService: fileIndexService
        )

        firstViewModel.query = "@read"
        try await waitUntil {
            firstViewModel.results.map(\.id) == [readmePath]
        }

        let secondViewModel = makeViewModel(
            commands: [],
            resolveFileSearchScope: { _ in scope },
            fileIndexService: fileIndexService
        )

        secondViewModel.query = "@read"
        try await waitUntil {
            secondViewModel.results.map(\.id) == [readmePath]
        }

        let indexedFilesCallCount = await fileIndexService.indexedFilesCallCount(for: scope.rootPath)
        XCTAssertEqual(indexedFilesCallCount, 1)
    }

    func testFileModeMatchesWhitespaceSeparatedTermsAcrossTitleAndPath() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .repositoryRoot
        )
        let releaseNotesPath = "/tmp/toastty-worktree/artifacts/release-notes.md"
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: releaseNotesPath,
                                relativePath: "artifacts/releases/1.2.3/release-notes.md",
                                destination: .localDocument(filePath: releaseNotesPath)
                            ),
                            self.makeFileResult(
                                filePath: "/tmp/toastty-worktree/docs/release-process.md",
                                relativePath: "docs/release-process.md",
                                destination: .localDocument(
                                    filePath: "/tmp/toastty-worktree/docs/release-process.md"
                                )
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

        viewModel.query = "@rel 1.2.3"

        try await waitUntil {
            viewModel.results.map(\.id) == [releaseNotesPath]
        }
    }

    func testLatestFileQueryPresentationWinsWhenOlderSearchFinishesLater() async throws {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let readmePath = "/tmp/toastty-worktree/README.md"
        let releasePath = "/tmp/toastty-worktree/release-notes.md"
        let fileIndexService = MockCommandPaletteFileIndexService(
            states: [
                scope.rootPath: .init(
                    prepareSnapshots: [
                        .ready(results: [
                            self.makeFileResult(
                                filePath: readmePath,
                                relativePath: "README.md",
                                destination: .localDocument(filePath: readmePath)
                            ),
                            self.makeFileResult(
                                filePath: releasePath,
                                relativePath: "artifacts/releases/1.2.3/release-notes.md",
                                destination: .localDocument(filePath: releasePath)
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
            fileIndexService: fileIndexService,
            filePresentationBuilder: { snapshot, searchText, isIndexing, hasLoadedSnapshot in
                if searchText == "read" {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }

                let results = CommandPaletteFileSearchEngine.search(
                    snapshot: snapshot,
                    query: searchText
                )
                let emptyState = results.isEmpty
                    ? PaletteEmptyState(title: "No matching files", message: "Try again.")
                    : PaletteEmptyState(title: "", message: "")
                return FileResultsPresentation(
                    results: results,
                    footerText: snapshot.scope.label,
                    emptyState: isIndexing && snapshot.documents.isEmpty && hasLoadedSnapshot == false
                        ? PaletteEmptyState(title: "Indexing local files", message: snapshot.scope.label)
                        : emptyState
                )
            }
        )

        viewModel.query = "@read"
        viewModel.query = "@rel"

        try await waitUntil {
            viewModel.results.map(\.id) == [releasePath]
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(viewModel.results.map(\.id), [releasePath])
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
        openFileResult: @escaping @MainActor (PaletteFileOpenDestination, PaletteFileOpenPlacement, UUID) -> Bool = { _, _, _ in true },
        fileIndexService: any CommandPaletteFileIndexing = CommandPaletteFileOpenProvider(),
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        filePresentationBuilder: @escaping @Sendable (
            CommandPaletteFileSearchSnapshot,
            String,
            Bool,
            Bool
        ) async -> FileResultsPresentation = CommandPaletteViewModel.buildFileResultsPresentationOffMain,
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
            filePresentationBuilder: filePresentationBuilder,
            executeCommand: executeCommand,
            onCancel: onCancel,
            onSubmitted: onSubmitted
        )
    }

    private func makeViewModel(
        originWindowID: UUID = UUID(),
        projectCommands: @escaping @MainActor () -> [PaletteCommandDescriptor],
        resolveFileSearchScope: @escaping @MainActor (UUID) -> PaletteFileSearchScope? = { _ in nil },
        openFileResult: @escaping @MainActor (PaletteFileOpenDestination, PaletteFileOpenPlacement, UUID) -> Bool = { _, _, _ in true },
        fileIndexService: any CommandPaletteFileIndexing = CommandPaletteFileOpenProvider(),
        usageTracker: CommandPaletteUsageTracking = NoOpCommandPaletteUsageTracker.shared,
        filePresentationBuilder: @escaping @Sendable (
            CommandPaletteFileSearchSnapshot,
            String,
            Bool,
            Bool
        ) async -> FileResultsPresentation = CommandPaletteViewModel.buildFileResultsPresentationOffMain,
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
            filePresentationBuilder: filePresentationBuilder,
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
    var lastUsedAtByID: [String: Date] = [:]
    var recordedCommandIDs: [String] = []

    func useCount(for commandID: String) -> Int {
        counts[commandID, default: 0]
    }

    func lastUsedAt(for commandID: String) -> Date? {
        lastUsedAtByID[commandID]
    }

    func recordSuccessfulExecution(of commandID: String) {
        recordedCommandIDs.append(commandID)
        counts[commandID, default: 0] += 1
        lastUsedAtByID[commandID] = lastUsedAtByID[commandID] ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}

    private actor MockCommandPaletteFileIndexService: CommandPaletteFileIndexing {
        struct ScopeState {
            var prepareSnapshots: [CommandPaletteFileIndexSnapshot]
            var indexedFilesDelayNanoseconds: UInt64 = 0
            var indexedResults: [[PaletteFileResult]]
            var lastResults: [PaletteFileResult] = []
        }

    private var states: [String: ScopeState]
    private var prepareCallCounts: [String: Int] = [:]
    private var indexedFilesCallCounts: [String: Int] = [:]

    init(states: [String: ScopeState] = [:]) {
        self.states = states
    }

    func prepareIndex(in scope: PaletteFileSearchScope) async -> CommandPaletteFileIndexSnapshot {
        prepareCallCounts[scope.rootPath, default: 0] += 1
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
        indexedFilesCallCounts[scope.rootPath, default: 0] += 1
        var state = states[scope.rootPath] ?? ScopeState(
            prepareSnapshots: [],
            indexedResults: [[]]
        )
        let delayNanoseconds = state.indexedFilesDelayNanoseconds
        let results = state.indexedResults.isEmpty
            ? state.lastResults
            : state.indexedResults.removeFirst()
        state.lastResults = results
        states[scope.rootPath] = state
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return results
    }

    func prepareCallCount(for scopeRootPath: String) -> Int {
        prepareCallCounts[scopeRootPath, default: 0]
    }

    func indexedFilesCallCount(for scopeRootPath: String) -> Int {
        indexedFilesCallCounts[scopeRootPath, default: 0]
    }
}

@MainActor
private struct ReloadablePaletteCatalogStores {
    let tempHomeURL: URL
    let agentCatalogStore: AgentCatalogStore
    let terminalProfileStore: TerminalProfileStore

    init() throws {
        tempHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHomeURL, withIntermediateDirectories: true)
        agentCatalogStore = AgentCatalogStore(
            fileManager: .default,
            homeDirectoryPath: tempHomeURL.path
        )
        terminalProfileStore = TerminalProfileStore(
            fileManager: .default,
            homeDirectoryPath: tempHomeURL.path,
            environment: [:]
        )
    }

    func writeAgentsToml(_ contents: String) throws {
        let url = AgentProfilesFile.fileURL(homeDirectoryPath: tempHomeURL.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func writeTerminalProfilesToml(_ contents: String) throws {
        let url = TerminalProfilesFile.fileURL(homeDirectoryPath: tempHomeURL.path, environment: [:])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.appending("\n").write(to: url, atomically: true, encoding: .utf8)
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
