@testable import ToasttyApp
import CoreState
import UniformTypeIdentifiers
import XCTest

@MainActor
final class AppStoreWindowSelectionTests: XCTestCase {
    private func makeSingleWindowState(initialTerminalCWD: String) -> (state: AppState, windowID: UUID, workspaceID: UUID) {
        let workspace = WorkspaceState.bootstrap(initialTerminalCWD: initialTerminalCWD)
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 120, y: 120, width: 1280, height: 760),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                )
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        return (state, windowID, workspace.id)
    }

    private func makeMarkdownFixture(
        fileName: String = "README.md"
    ) throws -> (canonicalPath: String, alternatePath: String) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-markdown-tests-\(UUID().uuidString)", isDirectory: true)
        let alternateDirectoryURL = rootURL.appendingPathComponent("alternate", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent(fileName, isDirectory: false)

        try fileManager.createDirectory(at: alternateDirectoryURL, withIntermediateDirectories: true)
        try Data("# Toastty Markdown Fixture\n".utf8).write(to: fileURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        let canonicalPath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let alternatePath = alternateDirectoryURL
            .appendingPathComponent("../\(fileName)", isDirectory: false)
            .path
        return (canonicalPath, alternatePath)
    }

    private func makeLocalDocumentFixture(
        fileName: String,
        content: String = "value: fixture\n"
    ) throws -> String {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-format-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent(fileName, isDirectory: false)

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: fileURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func makeUnsupportedFixture(fileName: String = "README.txt") throws -> String {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent(fileName, conformingTo: .plainText)

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("plain text\n".utf8).write(to: fileURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func makeSymlinkedMarkdownFixture() throws -> (canonicalPath: String, symlinkPath: String) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("README.md", conformingTo: .plainText)
        let symlinkURL = rootURL.appendingPathComponent("linked-readme.md", conformingTo: .plainText)

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("# Toastty Markdown Fixture\n".utf8).write(to: fileURL)
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: fileURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return (
            canonicalPath: fileURL.standardizedFileURL.resolvingSymlinksInPath().path,
            symlinkPath: symlinkURL.path
        )
    }

    func testWindowLookupResolvesSpecificWindowWithoutUsingGlobalSelection() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        let resolvedWindow = try XCTUnwrap(store.window(id: secondWindowID))
        let resolvedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: secondWindowID))

        XCTAssertEqual(resolvedWindow.id, secondWindowID)
        XCTAssertEqual(resolvedWorkspace.id, secondWorkspace.id)
        XCTAssertEqual(store.selectedWorkspace?.id, firstWorkspace.id)
    }

    func testSelectedWorkspaceInWindowFallsBackToFirstWorkspaceWhenSelectionIsNil() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id, secondWorkspace.id],
                    selectedWorkspaceID: nil
                )
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        let resolvedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))

        XCTAssertEqual(resolvedWorkspace.id, firstWorkspace.id)
        XCTAssertEqual(store.selectedWorkspace?.id, firstWorkspace.id)
    }

    func testCommandSelectionPrefersFocusedWindowOverGlobalSelection() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        let selection = try XCTUnwrap(store.commandSelection(preferredWindowID: secondWindowID))

        XCTAssertEqual(selection.windowID, secondWindowID)
        XCTAssertEqual(selection.window.id, secondWindowID)
        XCTAssertEqual(selection.workspace.id, secondWorkspace.id)
    }

    func testCommandSelectionReturnsNilWhenFocusedWindowIsMissing() {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.commandSelection(preferredWindowID: UUID()))
    }

    func testWindowLookupReturnsNilForUnknownWindowID() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)

        XCTAssertNil(store.window(id: UUID()))
        XCTAssertNil(store.selectedWorkspaceID(in: UUID()))
        XCTAssertNil(store.selectedWorkspace(in: UUID()))
        XCTAssertNil(store.commandSelection(preferredWindowID: UUID()))
        XCTAssertNotNil(store.commandSelection(preferredWindowID: nil))
    }

    func testCommandSelectionReturnsNilWhenNoWindowCanBeResolved() {
        let workspace = WorkspaceState.bootstrap()
        let state = AppState(
            windows: [],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: nil
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.commandSelection(preferredWindowID: UUID()))
        XCTAssertNil(store.commandSelection(preferredWindowID: nil))
    }

    func testPreferredLocalDocumentOpenDirectoryUsesFocusedTerminalLiveCWD() throws {
        let fileManager = FileManager.default
        let cwdURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-picker-cwd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: cwdURL)
        }

        let fixture = makeSingleWindowState(initialTerminalCWD: cwdURL.path)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)

        XCTAssertEqual(
            store.preferredLocalDocumentOpenDirectoryURL(preferredWindowID: fixture.windowID)?.path,
            cwdURL.path
        )
    }

    func testPreferredLocalDocumentOpenDirectoryIgnoresNonTerminalFocusedPanel() throws {
        let fileManager = FileManager.default
        let cwdURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-picker-browser-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: cwdURL)
        }

        let fixture = makeSingleWindowState(initialTerminalCWD: cwdURL.path)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: fixture.windowID,
                request: BrowserPanelCreateRequest(initialURL: "https://example.com")
            )
        )

        XCTAssertNil(store.preferredLocalDocumentOpenDirectoryURL(preferredWindowID: fixture.windowID))
    }

    func testPreferredLocalDocumentOpenDirectoryIgnoresMissingFocusedTerminalCWD() {
        let missingCWD = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-local-document-picker-missing-\(UUID().uuidString)", isDirectory: true)
            .path
        let fixture = makeSingleWindowState(initialTerminalCWD: missingCWD)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)

        XCTAssertNil(store.preferredLocalDocumentOpenDirectoryURL(preferredWindowID: fixture.windowID))
    }

    func testSelectedWorkspaceInWindowReturnsNilWhenWindowHasNoWorkspaces() {
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [],
                    selectedWorkspaceID: nil
                )
            ],
            workspacesByID: [:],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.selectedWorkspaceID(in: windowID))
        XCTAssertNil(store.selectedWorkspace(in: windowID))
        XCTAssertNil(store.selectedWorkspace)
        XCTAssertNil(store.commandSelection(preferredWindowID: windowID))
    }

    func testCommandWindowIDResolvesFocusedWindowWithoutAnyWorkspaces() {
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [],
                    selectedWorkspaceID: nil
                )
            ],
            workspacesByID: [:],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertEqual(store.commandWindowID(preferredWindowID: windowID), windowID)
        XCTAssertTrue(store.canCreateWorkspaceFromCommand(preferredWindowID: windowID))
    }

    func testCreateWorkspaceFromCommandPopulatesFocusedEmptyWindow() throws {
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [],
                    selectedWorkspaceID: nil
                )
            ],
            workspacesByID: [:],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.createWorkspaceFromCommand(preferredWindowID: windowID))

        let window = try XCTUnwrap(store.window(id: windowID))
        let workspaceID = try XCTUnwrap(window.selectedWorkspaceID)
        XCTAssertEqual(window.workspaceIDs, [workspaceID])
        XCTAssertEqual(store.state.workspacesByID[workspaceID]?.title, "Workspace 1")
    }

    func testCreateWorkspaceFromCommandRecreatesFirstWindowFromEmptyState() throws {
        let expectedFrame = CGRectCodable(x: 320, y: 240, width: 1600, height: 960)
        let state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            configuredTerminalFontPoints: 13
        )
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            commandCreateWindowFrameProvider: { expectedFrame }
        )

        XCTAssertTrue(store.canCreateWorkspaceFromCommand(preferredWindowID: nil))
        XCTAssertTrue(store.createWorkspaceFromCommand(preferredWindowID: nil))

        let window = try XCTUnwrap(store.state.windows.first)
        let workspaceID = try XCTUnwrap(window.selectedWorkspaceID)
        XCTAssertEqual(store.state.selectedWindowID, window.id)
        XCTAssertEqual(window.frame, expectedFrame)
        XCTAssertEqual(store.state.workspacesByID[workspaceID]?.title, "Workspace 1")
        XCTAssertEqual(store.state.configuredTerminalFontPoints, 13)
        XCTAssertNil(window.terminalFontSizePointsOverride)
        XCTAssertEqual(store.state.effectiveTerminalFontPoints(for: window.id), 13)
    }

    func testCreateWindowFromCommandSeedsFromFocusedTerminalAndCascadesFrame() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "ssh-prod")
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var sourceWorkspace = try XCTUnwrap(state.workspacesByID[sourceWorkspaceID])
        let focusedPanelID = try XCTUnwrap(sourceWorkspace.focusedPanelID)
        guard case .terminal(var terminalState) = sourceWorkspace.panels[focusedPanelID] else {
            XCTFail("expected focused panel to be terminal")
            return
        }
        terminalState.cwd = "/tmp/toastty/new-window"
        terminalState.profileBinding = TerminalProfileBinding(profileID: "zmx")
        sourceWorkspace.panels[focusedPanelID] = .terminal(terminalState)
        state.workspacesByID[sourceWorkspaceID] = sourceWorkspace
        state.configuredTerminalFontPoints = 13
        state.windows[0].terminalFontSizePointsOverride = 16
        state.windows[0].markdownTextScaleOverride = 1.2

        let sourceFrame = CGRectCodable(x: 320, y: 240, width: 1600, height: 960)
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            commandCreateWindowFrameProvider: { sourceFrame }
        )

        XCTAssertTrue(store.createWindowFromCommand(preferredWindowID: sourceWindowID))

        XCTAssertEqual(store.state.windows.count, 2)
        let newWindow = try XCTUnwrap(store.state.windows.last)
        let newWorkspaceID = try XCTUnwrap(newWindow.selectedWorkspaceID)
        let newWorkspace = try XCTUnwrap(store.state.workspacesByID[newWorkspaceID])
        let newPanelID = try XCTUnwrap(newWorkspace.focusedPanelID)
        guard case .terminal(let newTerminalState) = newWorkspace.panels[newPanelID] else {
            XCTFail("expected new window panel to be terminal")
            return
        }

        XCTAssertEqual(store.state.selectedWindowID, newWindow.id)
        XCTAssertEqual(newWindow.frame, CGRectCodable(x: 350, y: 210, width: 1600, height: 960))
        XCTAssertEqual(newTerminalState.cwd, "/tmp/toastty/new-window")
        XCTAssertEqual(newTerminalState.profileBinding, TerminalProfileBinding(profileID: "zmx"))
        XCTAssertEqual(newWindow.terminalFontSizePointsOverride, 16)
        XCTAssertEqual(newWindow.markdownTextScaleOverride, 1.2)
        XCTAssertEqual(store.state.effectiveTerminalFontPoints(for: newWindow.id), 16)
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: newWindow.id), 1.2)

        XCTAssertTrue(store.send(.increaseWindowMarkdownTextScale(windowID: newWindow.id)))
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: newWindow.id), 1.3, accuracy: 0.0001)
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: sourceWindowID), 1.2, accuracy: 0.0001)
    }

    func testCreateWindowFromCommandFallsBackToHomeDirectoryAndDefaultProfileFromNonTerminalFocus() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "ssh-prod")
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let reducer = AppReducer()
        state.configuredTerminalFontPoints = 13
        state.windows[0].terminalFontSizePointsOverride = 17
        state.windows[0].markdownTextScaleOverride = 1.3

        XCTAssertTrue(
            reducer.send(
                .createWebPanel(
                    workspaceID: sourceWorkspaceID,
                    panel: WebPanelState(definition: .browser),
                    placement: .splitRight
                ),
                state: &state
            )
        )
        let workspaceWithBrowser = try XCTUnwrap(state.workspacesByID[sourceWorkspaceID])
        let browserPanelID = try XCTUnwrap(workspaceWithBrowser.panels.first(where: {
            if case .web = $0.value {
                return true
            }
            return false
        })?.key)
        XCTAssertTrue(reducer.send(.focusPanel(workspaceID: sourceWorkspaceID, panelID: browserPanelID), state: &state))

        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            commandCreateWindowFrameProvider: { nil }
        )

        XCTAssertTrue(store.createWindowFromCommand(preferredWindowID: sourceWindowID))

        let newWindow = try XCTUnwrap(store.state.windows.last)
        let newWorkspaceID = try XCTUnwrap(newWindow.selectedWorkspaceID)
        let newWorkspace = try XCTUnwrap(store.state.workspacesByID[newWorkspaceID])
        let newPanelID = try XCTUnwrap(newWorkspace.focusedPanelID)
        guard case .terminal(let newTerminalState) = newWorkspace.panels[newPanelID] else {
            XCTFail("expected new window panel to be terminal")
            return
        }

        XCTAssertEqual(newTerminalState.cwd, NSHomeDirectory())
        XCTAssertEqual(newTerminalState.profileBinding, TerminalProfileBinding(profileID: "ssh-prod"))
        XCTAssertEqual(newWindow.terminalFontSizePointsOverride, 17)
        XCTAssertEqual(newWindow.markdownTextScaleOverride, 1.3)
        XCTAssertEqual(store.state.effectiveTerminalFontPoints(for: newWindow.id), 17)
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: newWindow.id), 1.3)
    }

    func testCreateWindowFromCommandUsesProvidedFrameWithoutCascadeWhenNoSourceWindowExists() throws {
        let expectedFrame = CGRectCodable(x: 320, y: 240, width: 1600, height: 960)
        let state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            configuredTerminalFontPoints: 13
        )
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            commandCreateWindowFrameProvider: { expectedFrame }
        )

        XCTAssertTrue(store.createWindowFromCommand(preferredWindowID: nil))

        let window = try XCTUnwrap(store.state.windows.first)
        XCTAssertEqual(window.frame, expectedFrame)
        XCTAssertEqual(store.state.selectedWindowID, window.id)
        XCTAssertNil(window.terminalFontSizePointsOverride)
        XCTAssertNil(window.markdownTextScaleOverride)
        XCTAssertEqual(store.state.effectiveTerminalFontPoints(for: window.id), 13)
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: window.id), AppState.defaultMarkdownTextScale)
    }

    func testCreateWorkspaceTabFromCommandSeedsFromFocusedTerminal() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "ssh-prod")
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var sourceWorkspace = try XCTUnwrap(state.workspacesByID[sourceWorkspaceID])
        let focusedPanelID = try XCTUnwrap(sourceWorkspace.focusedPanelID)
        guard case .terminal(var terminalState) = sourceWorkspace.panels[focusedPanelID] else {
            XCTFail("expected focused panel to be terminal")
            return
        }
        terminalState.cwd = "/tmp/toastty/new-tab"
        terminalState.profileBinding = TerminalProfileBinding(profileID: "zmx")
        sourceWorkspace.panels[focusedPanelID] = .terminal(terminalState)
        state.workspacesByID[sourceWorkspaceID] = sourceWorkspace
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.createWorkspaceTabFromCommand(preferredWindowID: sourceWindowID))

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let newTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let newTab = try XCTUnwrap(workspace.tabsByID[newTabID])
        let newPanelID = try XCTUnwrap(newTab.focusedPanelID)
        guard case .terminal(let newTerminalState) = newTab.panels[newPanelID] else {
            XCTFail("expected new tab panel to be terminal")
            return
        }

        XCTAssertEqual(workspace.tabIDs.count, 2)
        XCTAssertEqual(newTerminalState.cwd, "/tmp/toastty/new-tab")
        XCTAssertEqual(newTerminalState.profileBinding, TerminalProfileBinding(profileID: "zmx"))
    }

    func testCreateBrowserPanelFromCommandCreatesSelectedBrowserTab() throws {
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com/docs",
                    placementOverride: .newTab
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 2)
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be web-backed browser")
            return
        }

        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, "https://example.com/docs")
        XCTAssertNil(webState.currentURL)
        XCTAssertNil(store.pendingBrowserLocationFocusRequest)
    }

    func testCreateBrowserPanelFromCommandCanSplitFocusedPanel() throws {
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: BrowserPanelCreateRequest(
                    placementOverride: .splitRight
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspace.layoutTree.allSlotInfos.count, 2)
        let focusedPanelID = try XCTUnwrap(workspace.focusedPanelID)
        guard case .web(let webState) = workspace.panels[focusedPanelID] else {
            XCTFail("expected focused split panel to be browser")
            return
        }

        XCTAssertEqual(webState.definition, .browser)
        XCTAssertNil(webState.initialURL)
        XCTAssertNil(webState.currentURL)
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest?.windowID, sourceWindowID)
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest?.workspaceID, sourceWorkspaceID)
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest?.panelID, focusedPanelID)
        XCTAssertNotNil(store.pendingBrowserLocationFocusRequest?.requestID)
    }

    func testCreateBrowserPanelUsesDefaultPlacementWhenNoOverrideIsProvided() throws {
        let state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanel(
                workspaceID: workspaceID,
                request: BrowserPanelCreateRequest(initialURL: "https://example.com")
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
        XCTAssertEqual(workspace.layoutTree.allSlotInfos.count, 2)
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        guard case .web(let webState) = workspace.panels[panelID] else {
            XCTFail("expected focused panel to be web-backed browser")
            return
        }

        XCTAssertEqual(webState.initialURL, "https://example.com")
        XCTAssertNil(webState.currentURL)
        XCTAssertNil(store.pendingBrowserLocationFocusRequest)
    }

    func testCreateMarkdownPanelFromCommandCreatesSelectedMarkdownTab() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.canonicalPath,
                    placementOverride: .newTab
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 2)
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be markdown")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.title, "README.md")
        XCTAssertEqual(webState.filePath, fixture.canonicalPath)
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixture.canonicalPath, format: .markdown)
        )
        XCTAssertNil(webState.initialURL)
        XCTAssertNil(webState.currentURL)
    }

    func testCreateMarkdownPanelFromCommandDefaultsToRootRightPlacement() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(filePath: fixture.canonicalPath)
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
        XCTAssertEqual(workspace.layoutTree.allSlotInfos.count, 2)
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        guard case .web(let webState) = workspace.panels[panelID] else {
            XCTFail("expected focused panel to be markdown")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.title, "README.md")
        XCTAssertEqual(webState.filePath, fixture.canonicalPath)
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixture.canonicalPath, format: .markdown)
        )
    }

    func testCreateMarkdownPanelFromCommandSupportsExactColonSuffixedFilename() throws {
        let fixture = try makeMarkdownFixture(fileName: "README.md:42")
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.canonicalPath,
                    placementOverride: .newTab
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be markdown")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.title, "README.md:42")
        XCTAssertEqual(webState.filePath, fixture.canonicalPath)
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixture.canonicalPath, format: .markdown)
        )
    }

    func testCreateYamlPanelFromCommandCreatesTypedLocalDocument() throws {
        let fixturePath = try makeLocalDocumentFixture(fileName: "config.yaml")
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixturePath,
                    placementOverride: .newTab
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be local document")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixturePath)
        XCTAssertEqual(webState.title, "config.yaml")
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixturePath, format: .yaml)
        )
    }

    func testCreateJsonPanelFromCommandCreatesTypedLocalDocument() throws {
        let fixturePath = try makeLocalDocumentFixture(
            fileName: "package.json",
            content: "{\n  \"name\": \"toastty\"\n}\n"
        )
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixturePath,
                    placementOverride: .newTab
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be local document")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixturePath)
        XCTAssertEqual(webState.title, "package.json")
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixturePath, format: .json)
        )
    }

    func testCreateExtensionlessPanelFromCommandUsesExplicitFormatOverride() throws {
        let fixturePath = try makeLocalDocumentFixture(
            fileName: "config",
            content: "terminal-font-size = 13\n"
        )
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixturePath,
                    placementOverride: .newTab,
                    formatOverride: .toml
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be local document")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixturePath)
        XCTAssertEqual(webState.title, "config")
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixturePath, format: .toml)
        )
    }

    func testCreateMarkdownPanelDeduplicatesByNormalizedFilePathInWorkspace() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.canonicalPath,
                    placementOverride: .newTab
                )
            )
        )

        let workspaceAfterCreate = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let markdownTabID = try XCTUnwrap(workspaceAfterCreate.resolvedSelectedTabID)
        let markdownPanelID = try XCTUnwrap(workspaceAfterCreate.tab(id: markdownTabID)?.focusedPanelID)
        let originalTabID = try XCTUnwrap(workspaceAfterCreate.tabIDs.first)

        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: sourceWorkspaceID, tabID: originalTabID)))
        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.alternatePath,
                    placementOverride: .splitRight
                )
            )
        )

        let workspaceAfterDedupedOpen = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspaceAfterDedupedOpen.orderedTabs.count, 2)
        XCTAssertEqual(workspaceAfterDedupedOpen.resolvedSelectedTabID, markdownTabID)
        XCTAssertEqual(workspaceAfterDedupedOpen.focusedPanelID, markdownPanelID)
    }

    func testCreateMarkdownPanelOutcomeReportsOpenedPanelIDForNewPanel() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        let outcome = store.createLocalDocumentPanelFromCommandOutcome(
            preferredWindowID: sourceWindowID,
            request: LocalDocumentPanelCreateRequest(
                filePath: fixture.canonicalPath,
                lineNumber: 17,
                placementOverride: .newTab
            )
        )

        let panelID: UUID
        switch outcome {
        case .opened(let createdPanelID):
            panelID = createdPanelID
        default:
            XCTFail("expected opened panel outcome")
            return
        }

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        XCTAssertEqual(selectedTab.focusedPanelID, panelID)
    }

    func testCreateMarkdownPanelOutcomeReportsFocusedExistingPanelIDWhenDeduped() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.canonicalPath,
                    placementOverride: .newTab
                )
            )
        )

        let workspaceAfterCreate = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let existingTabID = try XCTUnwrap(workspaceAfterCreate.resolvedSelectedTabID)
        let existingPanelID = try XCTUnwrap(workspaceAfterCreate.tab(id: existingTabID)?.focusedPanelID)
        let originalTabID = try XCTUnwrap(workspaceAfterCreate.tabIDs.first)
        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: sourceWorkspaceID, tabID: originalTabID)))

        let outcome = store.createLocalDocumentPanelFromCommandOutcome(
            preferredWindowID: sourceWindowID,
            request: LocalDocumentPanelCreateRequest(
                filePath: fixture.alternatePath,
                lineNumber: 42,
                placementOverride: .splitRight
            )
        )

        XCTAssertEqual(outcome, .focusedExisting(panelID: existingPanelID))
        let workspaceAfterDedupedOpen = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspaceAfterDedupedOpen.resolvedSelectedTabID, existingTabID)
        XCTAssertEqual(workspaceAfterDedupedOpen.focusedPanelID, existingPanelID)
    }

    func testCreateLocalDocumentPanelFromCommandRejectsUnsupportedFileExtension() throws {
        let unsupportedPath = try makeUnsupportedFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertFalse(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(filePath: unsupportedPath)
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
        XCTAssertEqual(workspace.layoutTree.allSlotInfos.count, 1)
    }

    func testCreateMarkdownPanelDeduplicatesResolvedSymlinkPathInWorkspace() throws {
        let fixture = try makeSymlinkedMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.canonicalPath,
                    placementOverride: .newTab
                )
            )
        )

        let workspaceAfterCreate = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let markdownTabID = try XCTUnwrap(workspaceAfterCreate.resolvedSelectedTabID)
        let markdownPanelID = try XCTUnwrap(workspaceAfterCreate.tab(id: markdownTabID)?.focusedPanelID)
        let originalTabID = try XCTUnwrap(workspaceAfterCreate.tabIDs.first)

        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: sourceWorkspaceID, tabID: originalTabID)))
        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.symlinkPath,
                    placementOverride: .splitRight
                )
            )
        )

        let workspaceAfterDedupedOpen = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspaceAfterDedupedOpen.orderedTabs.count, 2)
        XCTAssertEqual(workspaceAfterDedupedOpen.resolvedSelectedTabID, markdownTabID)
        XCTAssertEqual(workspaceAfterDedupedOpen.focusedPanelID, markdownPanelID)
    }

    func testOpenURLInBrowserUsesConfiguredRootRightPlacement() throws {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let url = try XCTUnwrap(URL(string: "https://example.com/right"))

        XCTAssertTrue(
            store.openURLInBrowser(
                preferredWindowID: windowID,
                url: url,
                placement: .rootRight
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
        XCTAssertEqual(workspace.layoutTree.allSlotInfos.count, 2)
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        guard case .web(let webState) = workspace.panels[panelID] else {
            XCTFail("expected focused panel to be browser")
            return
        }

        XCTAssertEqual(webState.initialURL, url.absoluteString)
    }

    func testOpenURLInBrowserUsesConfiguredNewTabPlacement() throws {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let url = try XCTUnwrap(URL(string: "https://example.com/new-tab"))

        XCTAssertTrue(
            store.openURLInBrowser(
                preferredWindowID: windowID,
                url: url,
                placement: .newTab
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 2)
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected panel to be browser")
            return
        }

        XCTAssertEqual(webState.initialURL, url.absoluteString)
    }

    func testFocusedBrowserPanelSelectionReturnsFocusedBrowserInPreferredWindow() throws {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: windowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com/docs",
                    placementOverride: .splitRight
                )
            )
        )

        let selection = try XCTUnwrap(
            store.focusedBrowserPanelSelection(preferredWindowID: windowID)
        )
        let workspace = try XCTUnwrap(store.state.workspacesByID[selection.workspaceID])
        guard case .web(let webState) = workspace.panels[selection.panelID] else {
            XCTFail("expected focused browser selection to resolve a browser panel")
            return
        }

        XCTAssertEqual(selection.windowID, windowID)
        XCTAssertEqual(selection.workspaceID, workspace.id)
        XCTAssertEqual(webState.definition, .browser)
    }

    func testFocusedBrowserPanelSelectionReturnsNilWhenFocusedPanelIsTerminal() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)

        XCTAssertNil(store.focusedBrowserPanelSelection(preferredWindowID: nil))
    }

    func testFocusedScaleCommandTargetReturnsTerminalForFocusedTerminal() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)

        XCTAssertEqual(
            store.focusedScaleCommandTarget(preferredWindowID: windowID),
            .terminal(windowID: windowID)
        )
    }

    func testFocusedScaleCommandTargetReturnsMarkdownForFocusedMarkdown() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Preview\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: windowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fileURL.path,
                    placementOverride: .splitRight
                )
            )
        )

        XCTAssertEqual(
            store.focusedScaleCommandTarget(preferredWindowID: windowID),
            .markdown(windowID: windowID)
        )
    }

    func testFocusedScaleCommandTargetReturnsBrowserForFocusedBrowser() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: windowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com",
                    placementOverride: .splitRight
                )
            )
        )

        let browserSelection = try XCTUnwrap(store.focusedBrowserPanelSelection(preferredWindowID: windowID))
        XCTAssertEqual(
            store.focusedScaleCommandTarget(preferredWindowID: windowID),
            .browser(windowID: windowID, panelID: browserSelection.panelID)
        )
    }

    func testFocusPanelContainingBrowserSelectsBrowserTab() throws {
        let initialState = AppState.bootstrap()
        let windowID = try XCTUnwrap(initialState.windows.first?.id)
        let workspaceID = try XCTUnwrap(initialState.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: initialState, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: windowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com",
                    placementOverride: .newTab
                )
            )
        )

        let workspaceAfterCreate = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let browserTabID = try XCTUnwrap(workspaceAfterCreate.resolvedSelectedTabID)
        let browserPanelID = try XCTUnwrap(workspaceAfterCreate.tab(id: browserTabID)?.focusedPanelID)
        let originalTabID = try XCTUnwrap(workspaceAfterCreate.tabIDs.first)

        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID)))
        XCTAssertTrue(store.focusPanel(containing: browserPanelID))

        let workspaceAfterFocus = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterFocus.resolvedSelectedTabID, browserTabID)
        XCTAssertEqual(workspaceAfterFocus.focusedPanelID, browserPanelID)
    }

    func testSelectWorkspaceTabFromCommandUsesFocusedWindowOverGlobalSelection() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let firstWindowID = try XCTUnwrap(state.windows.first?.id)
        let firstWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(reducer.send(.createWindow(seed: nil, initialFrame: nil), state: &state))
        let secondWindowID = try XCTUnwrap(state.windows.last?.id)
        let secondWorkspaceID = try XCTUnwrap(state.windows.last?.selectedWorkspaceID)
        XCTAssertTrue(reducer.send(.createWorkspaceTab(workspaceID: secondWorkspaceID, seed: nil), state: &state))
        XCTAssertTrue(reducer.send(.selectWorkspace(windowID: firstWindowID, workspaceID: firstWorkspaceID), state: &state))
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.selectWorkspaceTabFromCommand(preferredWindowID: secondWindowID, shortcutNumber: 2))

        let firstWorkspace = try XCTUnwrap(store.state.workspacesByID[firstWorkspaceID])
        let secondWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspaceID])
        XCTAssertEqual(firstWorkspace.tabIDs.count, 1)
        XCTAssertEqual(secondWorkspace.tabIDs.count, 2)
        XCTAssertEqual(secondWorkspace.resolvedSelectedTabID, secondWorkspace.tabIDs[1])
        XCTAssertEqual(store.state.selectedWindowID, firstWindowID)
    }

    func testSelectAdjacentWorkspaceTabDoesNotRequestPanelFlash() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let createdTabID = try XCTUnwrap(state.workspacesByID[workspaceID]?.tabIDs.last)
        let originalTabID = try XCTUnwrap(state.workspacesByID[workspaceID]?.tabIDs.first)
        XCTAssertTrue(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID), state: &state))
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.selectAdjacentWorkspaceTab(
                preferredWindowID: windowID,
                direction: .next
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.resolvedSelectedTabID, createdTabID)
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testRenameSelectedWorkspaceFromCommandSetsPendingRenameRequest() throws {
        let workspace = WorkspaceState.bootstrap(title: "Dev")
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                )
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.pendingRenameWorkspaceRequest)
        XCTAssertTrue(store.renameSelectedWorkspaceFromCommand(preferredWindowID: windowID))
        XCTAssertEqual(
            store.pendingRenameWorkspaceRequest,
            PendingWorkspaceRenameRequest(windowID: windowID, workspaceID: workspace.id)
        )
    }

    func testRenameSelectedWorkspaceFromCommandDoesNothingWithoutWorkspace() {
        let store = AppStore(
            state: AppState(
                windows: [],
                workspacesByID: [:],
                selectedWindowID: nil
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertFalse(store.renameSelectedWorkspaceFromCommand(preferredWindowID: nil))
        XCTAssertNil(store.pendingRenameWorkspaceRequest)
    }

    func testConsumePendingRenameWorkspaceRequestOnlyReturnsMatchingWindow() {
        let request = PendingWorkspaceRenameRequest(windowID: UUID(), workspaceID: UUID())
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        store.pendingRenameWorkspaceRequest = request

        XCTAssertNil(store.consumePendingWorkspaceRenameRequest(windowID: UUID()))
        XCTAssertEqual(store.pendingRenameWorkspaceRequest, request)
        XCTAssertEqual(store.consumePendingWorkspaceRenameRequest(windowID: request.windowID), request)
        XCTAssertNil(store.pendingRenameWorkspaceRequest)
    }

    func testRenameSelectedWorkspaceTabFromCommandSetsPendingRenameRequest() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        let selectedTabID = try XCTUnwrap(store.state.workspacesByID[workspaceID]?.resolvedSelectedTabID)

        XCTAssertNil(store.pendingRenameWorkspaceTabRequest)
        XCTAssertTrue(store.renameSelectedWorkspaceTabFromCommand(preferredWindowID: windowID))
        XCTAssertEqual(
            store.pendingRenameWorkspaceTabRequest,
            PendingWorkspaceTabRenameRequest(windowID: windowID, workspaceID: workspaceID, tabID: selectedTabID)
        )
    }

    func testRenameSelectedWorkspaceTabFromCommandSupportsSingleTabWorkspace() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let selectedTabID = try XCTUnwrap(store.state.workspacesByID[workspaceID]?.resolvedSelectedTabID)

        XCTAssertTrue(store.renameSelectedWorkspaceTabFromCommand(preferredWindowID: windowID))
        XCTAssertEqual(
            store.pendingRenameWorkspaceTabRequest,
            PendingWorkspaceTabRenameRequest(windowID: windowID, workspaceID: workspaceID, tabID: selectedTabID)
        )
    }

    func testConsumePendingRenameWorkspaceTabRequestOnlyReturnsMatchingWindow() {
        let request = PendingWorkspaceTabRenameRequest(windowID: UUID(), workspaceID: UUID(), tabID: UUID())
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        store.pendingRenameWorkspaceTabRequest = request

        XCTAssertNil(store.consumePendingWorkspaceTabRenameRequest(windowID: UUID()))
        XCTAssertEqual(store.pendingRenameWorkspaceTabRequest, request)
        XCTAssertEqual(store.consumePendingWorkspaceTabRenameRequest(windowID: request.windowID), request)
        XCTAssertNil(store.pendingRenameWorkspaceTabRequest)
    }

    func testConsumePendingBrowserLocationFocusRequestOnlyReturnsMatchingWindow() {
        let request = PendingBrowserLocationFocusRequest(
            requestID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            panelID: UUID()
        )
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        store.pendingBrowserLocationFocusRequest = request

        XCTAssertNil(store.consumePendingBrowserLocationFocusRequest(windowID: UUID()))
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest, request)
        XCTAssertEqual(
            store.consumePendingBrowserLocationFocusRequest(windowID: request.windowID),
            request
        )
        XCTAssertNil(store.pendingBrowserLocationFocusRequest)
    }

    func testCloseSelectedWorkspaceFromCommandRequestsFocusedWorkspaceClose() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.closeSelectedWorkspaceFromCommand(preferredWindowID: secondWindowID))
        XCTAssertEqual(
            store.pendingCloseWorkspaceRequest,
            PendingWorkspaceCloseRequest(windowID: secondWindowID, workspaceID: secondWorkspace.id)
        )
        XCTAssertNotNil(store.window(id: firstWindowID))
        XCTAssertNotNil(store.window(id: secondWindowID))
        XCTAssertNotNil(store.state.workspacesByID[secondWorkspace.id])
    }

    func testCloseSelectedWorkspaceFromCommandDoesNothingWithoutWorkspace() {
        let store = AppStore(
            state: AppState(
                windows: [],
                workspacesByID: [:],
                selectedWindowID: nil
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertFalse(store.closeSelectedWorkspaceFromCommand(preferredWindowID: nil))
        XCTAssertNil(store.pendingCloseWorkspaceRequest)
    }

    func testConfirmWorkspaceCloseClosesRequestedWorkspace() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let firstWorkspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.send(.createWorkspace(windowID: windowID, title: "Second")))
        let secondWorkspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.requestWorkspaceClose(workspaceID: secondWorkspaceID))

        XCTAssertTrue(store.confirmWorkspaceClose(windowID: windowID, workspaceID: secondWorkspaceID))

        let window = try XCTUnwrap(store.window(id: windowID))
        XCTAssertEqual(window.workspaceIDs, [firstWorkspaceID])
        XCTAssertEqual(window.selectedWorkspaceID, firstWorkspaceID)
        XCTAssertNil(store.pendingCloseWorkspaceRequest)
        XCTAssertNil(store.state.workspacesByID[secondWorkspaceID])
    }

    func testConfirmWorkspaceCloseKeepsEmptyWindowWhenClosingLastWorkspace() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.requestWorkspaceClose(workspaceID: workspaceID))

        XCTAssertTrue(store.confirmWorkspaceClose(windowID: windowID, workspaceID: workspaceID))

        let window = try XCTUnwrap(store.window(id: windowID))
        XCTAssertTrue(window.workspaceIDs.isEmpty)
        XCTAssertNil(window.selectedWorkspaceID)
        XCTAssertEqual(store.state.selectedWindowID, windowID)
        XCTAssertEqual(store.state.windows.count, 1)
        XCTAssertNil(store.pendingCloseWorkspaceRequest)
        XCTAssertNil(store.state.workspacesByID[workspaceID])
    }

    func testRequestWorkspaceCloseDoesNotOverwriteDifferentPendingRequest() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.requestWorkspaceClose(workspaceID: firstWorkspace.id))
        XCTAssertFalse(store.requestWorkspaceClose(workspaceID: secondWorkspace.id))
        XCTAssertEqual(
            store.pendingCloseWorkspaceRequest,
            PendingWorkspaceCloseRequest(windowID: firstWindowID, workspaceID: firstWorkspace.id)
        )
    }

    func testCreateWorkspaceFromCommandDoesNotRerouteMissingFocusedWindow() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = store.state.windows[0].id
        let originalWorkspaceIDs = store.state.windows[0].workspaceIDs

        XCTAssertFalse(store.canCreateWorkspaceFromCommand(preferredWindowID: UUID()))
        XCTAssertFalse(store.createWorkspaceFromCommand(preferredWindowID: UUID()))

        XCTAssertEqual(store.state.windows[0].id, windowID)
        XCTAssertEqual(store.state.windows[0].workspaceIDs, originalWorkspaceIDs)
    }

    func testSelectWorkspacePrefersMostRecentUnreadSessionPanelWhenSwitchingWorkspaces() throws {
        let windowID = UUID()
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondLayout = makeTwoPanelWorkspace(title: "Two")
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id, secondLayout.workspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                )
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondLayout.workspace.id: secondLayout.workspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-left",
            agent: .codex,
            panelID: secondLayout.leftPanelID,
            windowID: windowID,
            workspaceID: secondLayout.workspace.id,
            cwd: "/repo/left",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-left",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Left"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-right",
            agent: .claude,
            panelID: secondLayout.rightPanelID,
            windowID: windowID,
            workspaceID: secondLayout.workspace.id,
            cwd: "/repo/right",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-right",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Right"),
            at: startedAt.addingTimeInterval(3)
        )

        XCTAssertTrue(
            store.selectWorkspace(
                windowID: windowID,
                workspaceID: secondLayout.workspace.id,
                preferringUnreadSessionPanelIn: sessionStore
            )
        )

        let selectedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))
        XCTAssertEqual(selectedWorkspace.id, secondLayout.workspace.id)
        XCTAssertEqual(selectedWorkspace.focusedPanelID, secondLayout.rightPanelID)
        XCTAssertEqual(selectedWorkspace.unreadPanelIDs, [secondLayout.leftPanelID])
    }

    func testSelectWorkspaceDoesNotOverrideFocusWhenWorkspaceIsAlreadySelected() throws {
        let windowID = UUID()
        let secondLayout = makeTwoPanelWorkspace(title: "Two")
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [secondLayout.workspace.id],
                    selectedWorkspaceID: secondLayout.workspace.id
                )
            ],
            workspacesByID: [secondLayout.workspace.id: secondLayout.workspace],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-right",
            agent: .codex,
            panelID: secondLayout.rightPanelID,
            windowID: windowID,
            workspaceID: secondLayout.workspace.id,
            cwd: "/repo/right",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-right",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Right"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.selectWorkspace(
                windowID: windowID,
                workspaceID: secondLayout.workspace.id,
                preferringUnreadSessionPanelIn: sessionStore
            )
        )

        let selectedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))
        XCTAssertEqual(selectedWorkspace.focusedPanelID, secondLayout.leftPanelID)
        XCTAssertEqual(selectedWorkspace.unreadPanelIDs, [secondLayout.rightPanelID])
    }

    func testSelectWorkspaceIgnoresUnreadPanelsWithoutSessionStatus() throws {
        let windowID = UUID()
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        var secondLayout = makeTwoPanelWorkspace(title: "Two")
        secondLayout.workspace.unreadPanelIDs = [secondLayout.rightPanelID]
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id, secondLayout.workspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                )
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondLayout.workspace.id: secondLayout.workspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)

        XCTAssertTrue(
            store.selectWorkspace(
                windowID: windowID,
                workspaceID: secondLayout.workspace.id,
                preferringUnreadSessionPanelIn: sessionStore
            )
        )

        let selectedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))
        XCTAssertEqual(selectedWorkspace.focusedPanelID, secondLayout.leftPanelID)
        XCTAssertEqual(selectedWorkspace.unreadPanelIDs, [secondLayout.rightPanelID])
    }

    func testCanFocusNextUnreadOrActivePanelFromCommandSkipsFocusedUnreadOnlyTarget() {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [0]
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertFalse(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )
    }

    func testCanFocusNextUnreadOrActivePanelFromCommandSkipsFocusedWorkingOnlyTarget() {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_050)
        sessionStore.startSession(
            sessionID: "sess-working",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Only target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
    }

    func testCanFocusNextUnreadOrActivePanelFromCommandFallsBackToReadyPanels() {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let readyTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, readyTab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_057)
        sessionStore.startSession(
            sessionID: "sess-ready-target",
            agent: .codex,
            panelID: readyTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-ready-target",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Next target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
    }

    func testFocusNextUnreadOrActivePanelFromCommandSkipsFocusedWorkingOnlyTarget() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_055)
        sessionStore.startSession(
            sessionID: "sess-working",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Only target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, windowID)
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, tab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, tab.panelIDs[0])
    }

    func testFocusNextUnreadOrActivePanelFromCommandRequestsSidebarFlashForFocusedWorkingOnlyTarget() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_056)
        sessionStore.startSession(
            sessionID: "sess-working-flash",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-flash",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Only target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, workspace.id)
        XCTAssertEqual(try XCTUnwrap(flashRequest.panelID), tab.panelIDs[0])
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)

        let panelFlashRequest = try XCTUnwrap(
            store.consumePendingPanelFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingPanelFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(panelFlashRequest.windowID, windowID)
        XCTAssertEqual(panelFlashRequest.workspaceID, workspace.id)
        XCTAssertEqual(panelFlashRequest.panelID, tab.panelIDs[0])
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelFromCommandRequestsSidebarFlashForFocusedReadyOnlyTarget() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_057)
        sessionStore.startSession(
            sessionID: "sess-ready-flash",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-ready-flash",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Only target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, workspace.id)
        XCTAssertEqual(try XCTUnwrap(flashRequest.panelID), tab.panelIDs[0])
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)
    }

    func testConsumePendingSidebarSessionFlashRequestIgnoresStaleRequestID() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_056)
        sessionStore.startSession(
            sessionID: "sess-working-flash-stale-id",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-flash-stale-id",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Only target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let currentRequestID = try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
        XCTAssertNil(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: UUID()
            )
        )
        XCTAssertEqual(store.pendingSidebarSessionFlashRequest?.requestID, currentRequestID)
    }

    func testFocusExplicitlyNavigatedPanelEnqueuesPanelFlashRequest() throws {
        let fixture = makeTwoPanelWorkspace(title: "One")
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [fixture.workspace.id],
                        selectedWorkspaceID: fixture.workspace.id
                    )
                ],
                workspacesByID: [fixture.workspace.id: fixture.workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertTrue(
            store.focusExplicitlyNavigatedPanel(
                windowID: windowID,
                workspaceID: fixture.workspace.id,
                panelID: fixture.rightPanelID
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspace.id])
        XCTAssertEqual(updatedWorkspace.focusedPanelID, fixture.rightPanelID)

        let flashRequest = try XCTUnwrap(
            store.consumePendingPanelFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingPanelFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, fixture.workspace.id)
        XCTAssertEqual(flashRequest.panelID, fixture.rightPanelID)
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testFocusDroppedImagePanelActivatesCurrentWindowWithoutPanelFlash() throws {
        let fixture = makeTwoPanelWorkspace(title: "One")
        let windowID = UUID()
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [fixture.workspace.id],
                        selectedWorkspaceID: fixture.workspace.id
                    )
                ],
                workspacesByID: [fixture.workspace.id: fixture.workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )

        XCTAssertTrue(
            store.focusDroppedImagePanel(
                windowID: windowID,
                workspaceID: fixture.workspace.id,
                panelID: fixture.rightPanelID
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspace.id])
        XCTAssertEqual(updatedWorkspace.focusedPanelID, fixture.rightPanelID)
        XCTAssertEqual(activatedWindowIDs, [windowID])
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testConsumePendingPanelFlashRequestIgnoresStaleRequestID() throws {
        let fixture = makeTwoPanelWorkspace(title: "One")
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [fixture.workspace.id],
                        selectedWorkspaceID: fixture.workspace.id
                    )
                ],
                workspacesByID: [fixture.workspace.id: fixture.workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertTrue(
            store.focusExplicitlyNavigatedPanel(
                windowID: windowID,
                workspaceID: fixture.workspace.id,
                panelID: fixture.rightPanelID
            )
        )

        let currentRequestID = try XCTUnwrap(store.pendingPanelFlashRequest?.requestID)
        XCTAssertNil(
            store.consumePendingPanelFlashRequest(
                windowID: windowID,
                requestID: UUID()
            )
        )
        XCTAssertEqual(store.pendingPanelFlashRequest?.requestID, currentRequestID)
    }

    func testFocusNextUnreadOrActivePanelFromCommandRequestsSidebarFlashForFocusedIdleSessionWithoutOtherActiveTargets() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_058)
        sessionStore.startSession(
            sessionID: "sess-idle-flash",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-idle-flash",
            status: SessionStatus(kind: .idle, summary: "Idle", detail: nil),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, workspace.id)
        XCTAssertEqual(try XCTUnwrap(flashRequest.panelID), tab.panelIDs[0])
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelFromCommandRequestsSidebarFlashWithoutFocusedSessionRow() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, workspace.id)
        XCTAssertEqual(try XCTUnwrap(flashRequest.panelID), tab.panelIDs[0])
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelFromCommandRequestsWorkspaceFlashWithoutFocusedPanel() throws {
        var tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        tab.tab.focusedPanelID = nil
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, workspace.id)
        XCTAssertNil(flashRequest.panelID)
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelFromCommandUsesFocusedWindowOverGlobalSelection() throws {
        let firstTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [firstTab],
            selectedTabIndex: 0
        )

        let secondSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondUnreadTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondUnreadTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: secondWindowID,
                sessionRuntimeStore: nil
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: secondWindowID,
                sessionRuntimeStore: nil
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondUnreadTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondUnreadTab.panelIDs[2])
        XCTAssertTrue(updatedWorkspace.tabsByID[secondUnreadTab.tab.id]?.unreadPanelIDs.isEmpty == true)

        let flashRequest = try XCTUnwrap(
            store.consumePendingPanelFlashRequest(
                windowID: secondWindowID,
                requestID: try XCTUnwrap(store.pendingPanelFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, secondWindowID)
        XCTAssertEqual(flashRequest.workspaceID, secondWorkspace.id)
        XCTAssertEqual(flashRequest.panelID, secondUnreadTab.panelIDs[2])
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelFromCommandActivatesRaisedWindow() throws {
        let firstTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [firstTab],
            selectedTabIndex: 0
        )

        let secondSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondUnreadTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [1]
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondUnreadTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: nil
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: nil
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondUnreadTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondUnreadTab.panelIDs[1])
        XCTAssertTrue(updatedWorkspace.tabsByID[secondUnreadTab.tab.id]?.unreadPanelIDs.isEmpty == true)
    }

    func testFocusNextUnreadOrActivePanelFromCommandPrefersUnreadBeforeWorkingFallback() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let activeTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let unreadTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, activeTab, unreadTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_090)
        sessionStore.startSession(
            sessionID: "sess-working-priority",
            agent: .codex,
            panelID: activeTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-priority",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Earlier active target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, unreadTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, unreadTab.panelIDs[2])
        XCTAssertTrue(updatedWorkspace.tabsByID[unreadTab.tab.id]?.unreadPanelIDs.isEmpty == true)
    }

    func testFocusNextUnreadOrActivePanelFromCommandFallsBackToWorkingPanels() throws {
        let firstTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [firstTab],
            selectedTabIndex: 0
        )

        let secondSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondWorkingTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
        sessionStore.startSession(
            sessionID: "sess-working",
            agent: .codex,
            panelID: secondWorkingTab.panelIDs[2],
            windowID: secondWindowID,
            workspaceID: secondWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Applying patch"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondWorkingTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondWorkingTab.panelIDs[2])
    }

    func testFocusNextUnreadOrActivePanelFromCommandUsesUnreadReadyPanelsAndDemotesThemToIdle() throws {
        let firstTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [firstTab],
            selectedTabIndex: 0
        )

        let secondSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondReadyTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondReadyTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_101)
        sessionStore.startSession(
            sessionID: "sess-ready",
            agent: .codex,
            panelID: secondReadyTab.panelIDs[2],
            windowID: secondWindowID,
            workspaceID: secondWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-ready",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Waiting for next prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondReadyTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondReadyTab.panelIDs[2])
        XCTAssertEqual(sessionStore.panelStatus(for: secondReadyTab.panelIDs[2])?.status.kind, .idle)
    }

    func testFocusNextUnreadOrActivePanelFromCommandFallsBackToNeedsApprovalPanels() throws {
        let firstTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [firstTab],
            selectedTabIndex: 0
        )

        let secondSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondApprovalTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondApprovalTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_102)
        sessionStore.startSession(
            sessionID: "sess-needs-approval",
            agent: .codex,
            panelID: secondApprovalTab.panelIDs[2],
            windowID: secondWindowID,
            workspaceID: secondWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-needs-approval",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Review command"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondApprovalTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondApprovalTab.panelIDs[2])
    }

    func testFocusNextUnreadOrActivePanelFromCommandPrefersReadNeedsApprovalOverWorkingFallback() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let approvalTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, workingTab, approvalTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_104)

        sessionStore.startSession(
            sessionID: "sess-working-priority",
            agent: .codex,
            panelID: workingTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-priority",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Streaming"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-needs-approval-priority",
            agent: .claude,
            panelID: approvalTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-needs-approval-priority",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(3)
        )

        XCTAssertTrue(
            store.send(.focusPanel(workspaceID: workspace.id, panelID: approvalTab.panelIDs[1]))
        )
        XCTAssertTrue(
            store.send(.focusPanel(workspaceID: workspace.id, panelID: currentTab.panelIDs[0]))
        )
        XCTAssertEqual(sessionStore.panelStatus(for: approvalTab.panelIDs[1])?.status.kind, .needsApproval)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, approvalTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, approvalTab.panelIDs[1])
    }

    func testFocusNextUnreadOrActivePanelFromCommandFallsBackToErrorPanels() throws {
        let firstTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [firstTab],
            selectedTabIndex: 0
        )

        let secondSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondErrorTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondErrorTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_103)
        sessionStore.startSession(
            sessionID: "sess-error",
            agent: .codex,
            panelID: secondErrorTab.panelIDs[2],
            windowID: secondWindowID,
            workspaceID: secondWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-error",
            status: SessionStatus(kind: .error, summary: "Error", detail: "Command failed"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondErrorTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondErrorTab.panelIDs[2])
    }

    func testFocusNextUnreadOrActivePanelFromCommandFlashesAfterVisitedReadyPanelsBecomeIdle() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstReadyTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondReadyTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, firstReadyTab, secondReadyTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [workspace.id],
                        selectedWorkspaceID: workspace.id
                    )
                ],
                workspacesByID: [workspace.id: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_105)

        sessionStore.startSession(
            sessionID: "sess-ready-first",
            agent: .codex,
            panelID: firstReadyTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-ready-first",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "First"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-ready-second",
            agent: .claude,
            panelID: secondReadyTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-ready-second",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Second"),
            at: startedAt.addingTimeInterval(3)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertEqual(sessionStore.panelStatus(for: firstReadyTab.panelIDs[1])?.status.kind, .idle)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertEqual(sessionStore.panelStatus(for: secondReadyTab.panelIDs[1])?.status.kind, .idle)

        sessionStore.stopSession(
            sessionID: "sess-ready-first",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.stopSession(
            sessionID: "sess-ready-second",
            at: startedAt.addingTimeInterval(5)
        )
        XCTAssertNil(sessionStore.panelStatus(for: firstReadyTab.panelIDs[1]))
        XCTAssertNil(sessionStore.panelStatus(for: secondReadyTab.panelIDs[1]))

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(try XCTUnwrap(flashRequest.panelID), secondReadyTab.panelIDs[1])
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelCyclesBeyondCurrentWorkspace() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let currentWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab],
            selectedTabIndex: 0
        )

        let siblingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let siblingWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [siblingTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [currentWorkspace.id, siblingWorkspace.id],
                    selectedWorkspaceID: currentWorkspace.id
                )
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                siblingWorkspace.id: siblingWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_200)

        sessionStore.startSession(
            sessionID: "sess-current-first",
            agent: .codex,
            panelID: currentTab.panelIDs[0],
            windowID: windowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo/current-first",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-first",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current first"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-current-second",
            agent: .claude,
            panelID: currentTab.panelIDs[1],
            windowID: windowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo/current-second",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-second",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current second"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-sibling",
            agent: .codex,
            panelID: siblingTab.panelIDs[0],
            windowID: windowID,
            workspaceID: siblingWorkspace.id,
            cwd: "/repo/sibling",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-sibling",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Sibling"),
            at: startedAt.addingTimeInterval(5)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let currentWorkspaceAfterFirstJump = try XCTUnwrap(store.state.workspacesByID[currentWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), currentWorkspace.id)
        XCTAssertEqual(currentWorkspaceAfterFirstJump.focusedPanelID, currentTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let siblingWorkspaceAfterSecondJump = try XCTUnwrap(store.state.workspacesByID[siblingWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), siblingWorkspace.id)
        XCTAssertEqual(siblingWorkspaceAfterSecondJump.focusedPanelID, siblingTab.panelIDs[0])
    }

    func testFocusNextUnreadOrActivePanelEventuallyReachesEarlierTabInSiblingWorkspaceCycle() throws {
        let currentEarlierTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let currentSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 1,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let currentWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentEarlierTab, currentSelectedTab],
            selectedTabIndex: 1
        )

        let siblingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let siblingWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [siblingTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [currentWorkspace.id, siblingWorkspace.id],
                    selectedWorkspaceID: currentWorkspace.id
                )
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                siblingWorkspace.id: siblingWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_201)

        sessionStore.startSession(
            sessionID: "sess-current-earlier",
            agent: .codex,
            panelID: currentEarlierTab.panelIDs[0],
            windowID: windowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo/current-earlier",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-earlier",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current earlier"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-current-selected-first",
            agent: .claude,
            panelID: currentSelectedTab.panelIDs[0],
            windowID: windowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo/current-selected-first",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-selected-first",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current selected first"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-current-selected-second",
            agent: .codex,
            panelID: currentSelectedTab.panelIDs[1],
            windowID: windowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo/current-selected-second",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-selected-second",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current selected second"),
            at: startedAt.addingTimeInterval(5)
        )

        sessionStore.startSession(
            sessionID: "sess-sibling",
            agent: .claude,
            panelID: siblingTab.panelIDs[0],
            windowID: windowID,
            workspaceID: siblingWorkspace.id,
            cwd: "/repo/sibling",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(6)
        )
        sessionStore.updateStatus(
            sessionID: "sess-sibling",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Sibling"),
            at: startedAt.addingTimeInterval(7)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        var updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[siblingWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), siblingWorkspace.id)
        XCTAssertEqual(updatedWorkspace.selectedTabID, siblingTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, siblingTab.panelIDs[0])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[currentWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), currentWorkspace.id)
        XCTAssertEqual(updatedWorkspace.selectedTabID, currentEarlierTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, currentEarlierTab.panelIDs[0])
    }

    func testFocusNextUnreadOrActiveRetargetsDestinationFocusRootWhenNeeded() throws {
        let sourceTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let sourceWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [sourceTab],
            selectedTabIndex: 0
        )

        var destinationTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let destinationVisibleRootNodeID = try lowestCommonAncestorNodeID(
            in: destinationTab.tab,
            containing: [destinationTab.panelIDs[0], destinationTab.panelIDs[1]]
        )
        destinationTab.tab.focusedPanelModeActive = true
        destinationTab.tab.focusModeRootNodeID = destinationVisibleRootNodeID
        let destinationWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [destinationTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [sourceWorkspace.id, destinationWorkspace.id],
                    selectedWorkspaceID: sourceWorkspace.id
                )
            ],
            workspacesByID: [
                sourceWorkspace.id: sourceWorkspace,
                destinationWorkspace.id: destinationWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[destinationWorkspace.id])
        let targetPanelID = destinationTab.panelIDs[2]
        let updatedSelectedTab = try XCTUnwrap(updatedWorkspace.selectedTab)
        let targetSlotID = try slotID(in: updatedSelectedTab, for: targetPanelID)
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), destinationWorkspace.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, targetPanelID)
        XCTAssertTrue(updatedWorkspace.focusedPanelModeActive)
        XCTAssertEqual(updatedWorkspace.focusModeRootNodeID, targetSlotID)
    }

    func testFocusNextUnreadOrActivePreservesDestinationRootWhenTargetAlreadyVisible() throws {
        let sourceTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let sourceWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [sourceTab],
            selectedTabIndex: 0
        )

        var destinationTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [1]
        )
        let destinationVisibleRootNodeID = try lowestCommonAncestorNodeID(
            in: destinationTab.tab,
            containing: [destinationTab.panelIDs[0], destinationTab.panelIDs[1]]
        )
        destinationTab.tab.focusedPanelModeActive = true
        destinationTab.tab.focusModeRootNodeID = destinationVisibleRootNodeID
        let destinationWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [destinationTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [sourceWorkspace.id, destinationWorkspace.id],
                    selectedWorkspaceID: sourceWorkspace.id
                )
            ],
            workspacesByID: [
                sourceWorkspace.id: sourceWorkspace,
                destinationWorkspace.id: destinationWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[destinationWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), destinationWorkspace.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, destinationTab.panelIDs[1])
        XCTAssertTrue(updatedWorkspace.focusedPanelModeActive)
        XCTAssertEqual(updatedWorkspace.focusModeRootNodeID, destinationVisibleRootNodeID)
    }

    func testFocusNextUnreadOrActiveDoesNotAutoEnterFocusModeOnNormalDestinationTab() throws {
        let sourceTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let sourceWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [sourceTab],
            selectedTabIndex: 0
        )

        let destinationTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [1]
        )
        let destinationWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [destinationTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [sourceWorkspace.id, destinationWorkspace.id],
                    selectedWorkspaceID: sourceWorkspace.id
                )
            ],
            workspacesByID: [
                sourceWorkspace.id: sourceWorkspace,
                destinationWorkspace.id: destinationWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[destinationWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), destinationWorkspace.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, destinationTab.panelIDs[1])
        XCTAssertFalse(updatedWorkspace.focusedPanelModeActive)
        XCTAssertNil(updatedWorkspace.focusModeRootNodeID)
    }

    func testFocusNextUnreadOrActivePreservesSourceTabFocusRoot() throws {
        var sourceTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let sourceRootNodeID = try lowestCommonAncestorNodeID(
            in: sourceTab.tab,
            containing: [sourceTab.panelIDs[0], sourceTab.panelIDs[1]]
        )
        sourceTab.tab.focusedPanelModeActive = true
        sourceTab.tab.focusModeRootNodeID = sourceRootNodeID
        let sourceWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [sourceTab],
            selectedTabIndex: 0
        )

        let destinationTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let destinationWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [destinationTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [sourceWorkspace.id, destinationWorkspace.id],
                    selectedWorkspaceID: sourceWorkspace.id
                )
            ],
            workspacesByID: [
                sourceWorkspace.id: sourceWorkspace,
                destinationWorkspace.id: destinationWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )

        let updatedSourceWorkspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspace.id])
        XCTAssertTrue(updatedSourceWorkspace.focusedPanelModeActive)
        XCTAssertEqual(updatedSourceWorkspace.focusModeRootNodeID, sourceRootNodeID)
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), destinationWorkspace.id)
    }

    private func makeTwoPanelWorkspace(title: String) -> (workspace: WorkspaceState, leftPanelID: UUID, rightPanelID: UUID) {
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: title,
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: UUID(), panelID: leftPanelID),
                second: .slot(slotID: UUID(), panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/repo/left")),
                rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/repo/right")),
            ],
            focusedPanelID: leftPanelID
        )
        return (workspace, leftPanelID, rightPanelID)
    }

    private func makeUnreadCommandTab(
        focusedPanelIndex: Int,
        unreadPanelIndices: Set<Int>,
        panelCount: Int = 3
    ) -> (tab: WorkspaceTabState, panelIDs: [UUID]) {
        let panelIDs = (0 ..< panelCount).map { _ in UUID() }
        let panels = Dictionary(uniqueKeysWithValues: panelIDs.enumerated().map { index, panelID in
            (
                panelID,
                PanelState.terminal(
                    TerminalPanelState(
                        title: "Terminal \(index + 1)",
                        shell: "zsh",
                        cwd: NSHomeDirectory()
                    )
                )
            )
        })

        let tab = WorkspaceTabState(
            id: UUID(),
            layoutTree: makeUnreadCommandLayout(panelIDs: panelIDs),
            panels: panels,
            focusedPanelID: panelIDs[focusedPanelIndex],
            unreadPanelIDs: Set(unreadPanelIndices.map { panelIDs[$0] })
        )

        return (tab, panelIDs)
    }

    private func makeUnreadCommandWorkspace(
        title: String,
        tabs: [(tab: WorkspaceTabState, panelIDs: [UUID])],
        selectedTabIndex: Int
    ) -> WorkspaceState {
        let tabIDs = tabs.map { $0.tab.id }
        return WorkspaceState(
            id: UUID(),
            title: title,
            selectedTabID: tabIDs[selectedTabIndex],
            tabIDs: tabIDs,
            tabsByID: Dictionary(uniqueKeysWithValues: tabs.map { ($0.tab.id, $0.tab) })
        )
    }

    private func makeUnreadCommandLayout(panelIDs: [UUID]) -> LayoutNode {
        var iterator = panelIDs.makeIterator()
        let firstPanelID = iterator.next()!
        var layout = LayoutNode.slot(slotID: UUID(), panelID: firstPanelID)

        while let panelID = iterator.next() {
            layout = .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: layout,
                second: .slot(slotID: UUID(), panelID: panelID)
            )
        }

        return layout
    }

    private func slotID(
        in tab: WorkspaceTabState,
        for panelID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UUID {
        try XCTUnwrap(
            tab.layoutTree.slotContaining(panelID: panelID)?.slotID,
            file: file,
            line: line
        )
    }

    private func lowestCommonAncestorNodeID(
        in tab: WorkspaceTabState,
        containing panelIDs: [UUID],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UUID {
        let slotIDs = try Set(
            panelIDs.map { panelID in
                try slotID(in: tab, for: panelID, file: file, line: line)
            }
        )
        return try XCTUnwrap(
            tab.layoutTree.lowestCommonAncestor(containing: slotIDs),
            file: file,
            line: line
        )
    }
}
