import AppKit
import CoreState
import XCTest
@testable import ToasttyApp

@MainActor
final class CommandPaletteControllerTests: XCTestCase {
    func testTogglePresentsPaletteAndExecutesAgainstOriginWindowID() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let originWindow = makeOriginWindow(windowID: windowID)
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let actions = CommandPaletteActionSpy()
        let catalogStores = try PaletteCatalogStoresFixture()
        let controller = makeController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            actions: actions,
            catalogStores: catalogStores
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
        let controller = makeController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            actions: CommandPaletteActionSpy(),
            catalogStores: try PaletteCatalogStoresFixture()
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
        let controller = makeController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            actions: CommandPaletteActionSpy(),
            catalogStores: try PaletteCatalogStoresFixture()
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

    func testSubmittedWorkspaceChangeRestoresFocusToCurrentWorkspace() throws {
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
        let actions = try makeLiveActions(store: store, runtimeRegistry: runtimeRegistry)
        var restoredWorkspaceIDs: [UUID] = []
        let controller = makeController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            actions: actions,
            catalogStores: try PaletteCatalogStoresFixture(),
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

    func testToggleDismissesPaletteAfterSubmittedCommandReturnsFalse() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let originWindow = makeOriginWindow(windowID: windowID)
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let actions = CommandPaletteActionSpy()
        actions.createWorkspaceResult = false
        let controller = makeController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            actions: actions,
            catalogStores: try PaletteCatalogStoresFixture()
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

    func testPresentedPaletteRefreshesAfterProfileStoresReload() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let originWindow = makeOriginWindow(windowID: windowID)
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let actions = CommandPaletteActionSpy()
        let catalogStores = try PaletteCatalogStoresFixture()
        let controller = makeController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            actions: actions,
            catalogStores: catalogStores
        )
        defer {
            controller.dismiss(reason: .cancelled)
            originWindow.close()
        }

        XCTAssertTrue(controller.toggle(originWindowID: windowID))
        let viewModel = try XCTUnwrap(controller.viewModel)
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

        await Task.yield()
        await Task.yield()

        XCTAssertTrue(viewModel.results.contains(where: { $0.id == "agent.run.codex" }))
        XCTAssertTrue(viewModel.results.contains(where: { $0.id == "terminal-profile.zmx.split-right" }))
        XCTAssertTrue(viewModel.results.contains(where: { $0.id == "terminal-profile.zmx.split-down" }))
    }

    func testToggleReusesSharedFileIndexServiceAcrossPaletteSessions() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let originWindow = makeOriginWindow(windowID: windowID)
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let actions = CommandPaletteActionSpy()
        actions.fileSearchScopeValue = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .workingDirectory
        )
        let readmePath = "/tmp/toastty-worktree/README.md"
        let fileIndexService = ControllerFileIndexServiceSpy(
            resultsByScope: [
                actions.fileSearchScopeValue!.rootPath: [
                    PaletteFileResult(
                        filePath: readmePath,
                        fileName: "README.md",
                        relativePath: "README.md",
                        destination: .localDocument(filePath: readmePath)
                    ),
                ],
            ]
        )
        let controller = makeController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            actions: actions,
            catalogStores: try PaletteCatalogStoresFixture(),
            fileIndexService: fileIndexService
        )
        defer {
            controller.dismiss(reason: .cancelled)
            originWindow.close()
        }

        XCTAssertTrue(controller.toggle(originWindowID: windowID))
        controller.viewModel?.query = "@read"
        try await waitUntil {
            controller.viewModel?.results.map(\.id) == [readmePath]
        }

        controller.dismiss(reason: .cancelled)

        XCTAssertTrue(controller.toggle(originWindowID: windowID))
        controller.viewModel?.query = "@read"
        try await waitUntil {
            controller.viewModel?.results.map(\.id) == [readmePath]
        }

        let indexedFilesCallCount = await fileIndexService.indexedFilesCallCount()
        XCTAssertEqual(indexedFilesCallCount, 1)
    }

    private func makeController(
        store: AppStore,
        runtimeRegistry: TerminalRuntimeRegistry,
        actions: CommandPaletteActionHandling,
        catalogStores: PaletteCatalogStoresFixture,
        fileIndexService: any CommandPaletteFileIndexing = CommandPaletteFileOpenProvider(),
        scheduleWorkspaceFocusRestore: (@MainActor (UUID, Bool) -> Void)? = nil
    ) -> CommandPaletteController {
        CommandPaletteController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            actions: actions,
            agentCatalogStore: catalogStores.agentCatalogStore,
            terminalProfileStore: catalogStores.terminalProfileStore,
            profileShortcutRegistryProvider: {
                makeProfileShortcutRegistry(
                    terminalProfiles: catalogStores.terminalProfileStore.catalog,
                    terminalProfilesFilePath: catalogStores.terminalProfileStore.fileURL.path,
                    agentProfiles: catalogStores.agentCatalogStore.catalog,
                    agentProfilesFilePath: catalogStores.agentCatalogStore.fileURL.path
                )
            },
            fileIndexService: fileIndexService,
            scheduleWorkspaceFocusRestore: scheduleWorkspaceFocusRestore
        )
    }

    private func makeLiveActions(
        store: AppStore,
        runtimeRegistry: TerminalRuntimeRegistry
    ) throws -> CommandPaletteActionHandler {
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        runtimeRegistry.bind(sessionLifecycleTracker: sessionRuntimeStore)

        let agentCatalogStore = AgentCatalogStore(
            fileManager: .default,
            homeDirectoryPath: FileManager.default.temporaryDirectory.path
        )
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: runtimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogStore
        )
        let terminalProfilesMenuController = TerminalProfilesMenuController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            terminalProfileProvider: TerminalProfileStore(
                fileManager: .default,
                homeDirectoryPath: FileManager.default.temporaryDirectory.path,
                environment: [:]
            ),
            installShellIntegrationAction: {},
            openProfilesConfigurationAction: {}
        )

        return CommandPaletteActionHandler(
            store: store,
            splitLayoutCommandController: SplitLayoutCommandController(store: store),
            focusedPanelCommandController: FocusedPanelCommandController(
                store: store,
                runtimeRegistry: runtimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            terminalRuntimeRegistry: runtimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentLaunchService: agentLaunchService,
            terminalProfilesMenuController: terminalProfilesMenuController,
            supportsConfigurationReload: { true },
            reloadConfigurationAction: {},
            openLocalDocumentAction: { _, _ in false }
        )
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

private actor ControllerFileIndexServiceSpy: CommandPaletteFileIndexing {
    private let resultsByScope: [String: [PaletteFileResult]]
    private var preparedScopes: Set<String> = []
    private var indexedFileCalls = 0

    init(resultsByScope: [String: [PaletteFileResult]]) {
        self.resultsByScope = resultsByScope
    }

    func prepareIndex(in scope: PaletteFileSearchScope) async -> CommandPaletteFileIndexSnapshot {
        let results = resultsByScope[scope.rootPath, default: []]
        if preparedScopes.contains(scope.rootPath) {
            return .ready(results: results)
        }

        preparedScopes.insert(scope.rootPath)
        return .indexing(results: [])
    }

    func indexedFiles(in scope: PaletteFileSearchScope) async -> [PaletteFileResult] {
        indexedFileCalls += 1
        return resultsByScope[scope.rootPath, default: []]
    }

    func indexedFilesCallCount() -> Int {
        indexedFileCalls
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

@MainActor
final class CommandPalettePanelTests: XCTestCase {
    func testPositionedFrameCentersWithinOriginWindow() {
        let originFrame = CGRect(x: 120, y: 180, width: 900, height: 640)

        let frame = CommandPalettePanel.positionedFrame(
            relativeTo: originFrame,
            visibleFrames: []
        )

        XCTAssertEqual(frame.origin.x, 280)
        XCTAssertEqual(frame.midY, expectedTopThirdCenterY(for: originFrame), accuracy: 0.5)
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
        XCTAssertEqual(frame.midY, expectedTopThirdCenterY(for: originFrame), accuracy: 0.5)
    }

    func testPositionedFramePinsToVisibleFrameOriginWhenPaletteExceedsVisibleBounds() {
        let originFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let visibleFrame = CGRect(x: 40, y: 60, width: 240, height: 120)

        let frame = CommandPalettePanel.positionedFrame(
            relativeTo: originFrame,
            visibleFrames: [visibleFrame]
        )

        XCTAssertEqual(frame.origin.x, visibleFrame.minX)
        XCTAssertEqual(frame.origin.y, visibleFrame.minY)
        XCTAssertEqual(frame.size, CommandPalettePanel.defaultFrame.size)
    }

    func testPositionedFramePreservesPanelSizeForFractionalOrigins() {
        let originFrame = CGRect(x: 10, y: 10, width: 581, height: 641)

        let frame = CommandPalettePanel.positionedFrame(
            relativeTo: originFrame,
            visibleFrames: []
        )

        XCTAssertEqual(frame.origin.x, 11)
        XCTAssertEqual(frame.size, CommandPalettePanel.defaultFrame.size)
    }

    func testPositionedFrameFallsBackToLargestVisibleFrameWhenOriginFrameIsDegenerate() {
        let smallVisibleFrame = CGRect(x: -400, y: 0, width: 400, height: 300)
        let largeVisibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)

        let frame = CommandPalettePanel.positionedFrame(
            relativeTo: .zero,
            visibleFrames: [smallVisibleFrame, largeVisibleFrame]
        )

        XCTAssertEqual(frame.origin.x, 310)
        XCTAssertEqual(frame.midY, expectedTopThirdCenterY(for: largeVisibleFrame), accuracy: 0.5)
        XCTAssertEqual(frame.size, CommandPalettePanel.defaultFrame.size)
    }

    func testPositionedFrameReturnsUnclampedFrameWhenNoValidVisibleFramesExist() {
        let originFrame = CGRect(x: 120, y: 180, width: 900, height: 640)
        let invalidVisibleFrames: [CGRect] = [.null, .zero]

        let frame = CommandPalettePanel.positionedFrame(
            relativeTo: originFrame,
            visibleFrames: invalidVisibleFrames
        )

        XCTAssertEqual(frame.origin.x, 280)
        XCTAssertEqual(frame.midY, expectedTopThirdCenterY(for: originFrame), accuracy: 0.5)
        XCTAssertEqual(frame.size, CommandPalettePanel.defaultFrame.size)
    }

    func testPositionUsesDefaultFrameSizeBeforePanelHasBeenSized() {
        let originWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 500, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let panel = CommandPalettePanel()
        panel.setFrame(.zero, display: false)

        let contentRectInWindow = originWindow.contentView?.convert(originWindow.contentView?.bounds ?? .zero, to: nil) ?? .zero
        let targetRect = originWindow.convertToScreen(contentRectInWindow)
        let expectedFrame = CommandPalettePanel.positionedFrame(
            panelSize: CommandPalettePanel.defaultFrame.size,
            relativeTo: targetRect,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )

        panel.position(relativeTo: originWindow)

        XCTAssertEqual(panel.frame, expectedFrame)
        XCTAssertEqual(panel.frame.size, CommandPalettePanel.defaultFrame.size)
    }

    private func expectedTopThirdCenterY(for frame: CGRect) -> CGFloat {
        frame.maxY - (frame.height / 3)
    }
}

private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private struct PaletteCatalogStoresFixture {
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
