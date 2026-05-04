@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

@MainActor
final class AppURLRouterTests: XCTestCase {
    func testRouteUsesConfiguredInternalBrowserPlacementForHTTPSURLs() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .rightPanel
                )
            ),
            .toasttyBrowser(placement: .rightPanel)
        )
    }

    func testRouteUsesConfiguredAlternateBrowserPlacementForAlternateOpen() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .rightPanel,
                    alternateBrowserPlacement: .newTab
                ),
                useAlternatePlacement: true
            ),
            .toasttyBrowser(placement: .newTab)
        )
    }

    func testRouteTreatsSupportedTextFilesAsLocalDocuments() throws {
        let fixture = try makeTextFixture()
        let url = fixture.fileURL

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .rightPanel
                )
            ),
            .localDocument(
                LocalDocumentPanelCreateRequest(
                    filePath: fixture.filePath,
                    placementOverride: .rightPanel
                )
            )
        )
    }

    func testRouteUsesConfiguredAlternateLocalDocumentPlacementForAlternateOpen() throws {
        let fixture = try makeTextFixture()
        let url = fixture.fileURL

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(),
                localDocumentPreferences: LocalDocumentRoutingPreferences(
                    openingPlacement: .rightPanel,
                    alternateOpeningPlacement: .newTab
                ),
                useAlternatePlacement: true
            ),
            .localDocument(
                LocalDocumentPanelCreateRequest(
                    filePath: fixture.filePath,
                    placementOverride: .newTab
                )
            )
        )
    }

    func testRouteKeepsExistingUnsupportedLocalFileURLsExternalEvenWhenToasttyBrowserIsEnabled() throws {
        let fixture = try makeUnsupportedFixture()
        let url = fixture.fileURL

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .rightPanel
                )
            ),
            .external
        )
    }

    func testRouteTreatsSupportedAbsolutePathLineTargetAsLocalDocument() throws {
        let fixture = try makeMarkdownFixture()
        let url = try XCTUnwrap(URL(string: "\(fixture.markdownPath):42"))

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(destination: .systemBrowser)
            ),
            .localDocument(
                LocalDocumentPanelCreateRequest(
                    filePath: fixture.markdownPath,
                    lineNumber: 42,
                    placementOverride: .rightPanel
                )
            )
        )
    }

    func testRoutePrefersExactColonFilenameOverTrailingLineParsing() throws {
        let fixture = try makeMarkdownFixture(fileName: "notes.md:42")
        let url = try XCTUnwrap(URL(string: fixture.markdownPath))

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(destination: .systemBrowser)
            ),
            .localDocument(
                LocalDocumentPanelCreateRequest(
                    filePath: fixture.markdownPath,
                    placementOverride: .rightPanel
                )
            )
        )
    }

    func testRoutePrefersExactColonFilenameOverTrailingLineParsingForFileURL() throws {
        let fixture = try makeMarkdownFixture(fileName: "notes.md:42")

        XCTAssertEqual(
            AppURLRouter.route(
                for: fixture.markdownURL,
                preferences: URLRoutingPreferences(destination: .systemBrowser)
            ),
            .localDocument(
                LocalDocumentPanelCreateRequest(
                    filePath: fixture.markdownPath,
                    placementOverride: .rightPanel
                )
            )
        )
    }

    func testRouteKeepsCustomSchemesExternal() throws {
        let url = try XCTUnwrap(URL(string: "mailto:test@example.com"))

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .rightPanel
                )
            ),
            .external
        )
    }

    func testOpenFallsBackToExternalWhenNoToasttyWindowCanHostBrowser() throws {
        let store = AppStore(
            state: AppState(windows: [], workspacesByID: [:], selectedWindowID: nil),
            persistTerminalFontPreference: false
        )
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        var externallyOpenedURL: URL?

        XCTAssertTrue(
            AppURLRouter.open(
                url,
                preferredWindowID: nil,
                appStore: store,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .rightPanel
                ),
                openExternally: { openedURL in
                    externallyOpenedURL = openedURL
                    return true
                }
            )
        )

        XCTAssertEqual(externallyOpenedURL, url)
    }

    func testOpenConvertsSchemelessAbsolutePathsBeforeOpeningExternally() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let url = try XCTUnwrap(URL(string: "/tmp/toastty command click"))
        var externallyOpenedURL: URL?

        XCTAssertTrue(
            AppURLRouter.open(
                url,
                preferredWindowID: nil,
                appStore: store,
                preferences: URLRoutingPreferences(destination: .systemBrowser),
                openExternally: { openedURL in
                    externallyOpenedURL = openedURL
                    return true
                }
            )
        )

        XCTAssertEqual(externallyOpenedURL?.scheme, "file")
        XCTAssertEqual(externallyOpenedURL?.path, "/tmp/toastty command click")
    }

    func testOpenConvertsSchemelessTildePathsBeforeOpeningExternally() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let url = try XCTUnwrap(URL(string: "~/Documents/toastty notes.md"))
        var externallyOpenedURL: URL?

        XCTAssertTrue(
            AppURLRouter.open(
                url,
                preferredWindowID: nil,
                appStore: store,
                preferences: URLRoutingPreferences(destination: .systemBrowser),
                openExternally: { openedURL in
                    externallyOpenedURL = openedURL
                    return true
                }
            )
        )

        XCTAssertEqual(externallyOpenedURL?.scheme, "file")
        XCTAssertEqual(externallyOpenedURL?.path, "\(NSHomeDirectory())/Documents/toastty notes.md")
    }

    func testOpenCreatesBrowserPanelInsideToasttyWhenConfigured() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let url = try XCTUnwrap(URL(string: "https://example.com/toastty"))

        XCTAssertTrue(
            AppURLRouter.open(
                url,
                preferredWindowID: nil,
                appStore: store,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .newTab
                ),
                openExternally: { _ in
                    XCTFail("router should not fall back to external open")
                    return false
                }
            )
        )

        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 2)
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected new browser tab")
            return
        }

        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, url.absoluteString)
        XCTAssertNil(webState.currentURL)
    }

    func testOpenUsesAlternatePlacementWhenRequested() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let url = try XCTUnwrap(URL(string: "https://example.com/new-tab"))

        XCTAssertTrue(
            AppURLRouter.open(
                url,
                preferredWindowID: nil,
                appStore: store,
                useAlternatePlacement: true,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .rightPanel,
                    alternateBrowserPlacement: .newTab
                ),
                openExternally: { _ in
                    XCTFail("router should not fall back to external open")
                    return false
                }
            )
        )

        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 2)
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected browser panel in new tab")
            return
        }

        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, url.absoluteString)
        XCTAssertNil(webState.currentURL)
    }

    func testOpenUsesStorePreferencesWhenNoExplicitOverrideIsProvided() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        store.setURLRoutingPreferences(
            URLRoutingPreferences(
                destination: .systemBrowser,
                browserPlacement: .rightPanel
            )
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/external"))
        var externallyOpenedURL: URL?

        XCTAssertTrue(
            AppURLRouter.open(
                url,
                preferredWindowID: nil,
                appStore: store,
                openExternally: { openedURL in
                    externallyOpenedURL = openedURL
                    return true
                }
            )
        )

        XCTAssertEqual(externallyOpenedURL, url)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
    }

    func testOpenCreatesLocalDocumentPanelAndRequestsRevealForLineNumber() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let fixture = try makeMarkdownFixture()
        let url = try XCTUnwrap(URL(string: "\(fixture.markdownPath):42"))
        var revealedPanelID: UUID?
        var revealedLineNumber: Int?

        XCTAssertTrue(
            AppURLRouter.open(
                url,
                preferredWindowID: nil,
                appStore: store,
                preferences: URLRoutingPreferences(destination: .systemBrowser),
                requestLocalDocumentReveal: { panelID, lineNumber in
                    revealedPanelID = panelID
                    revealedLineNumber = lineNumber
                    return true
                },
                openExternally: { _ in
                    XCTFail("router should not fall back to external open")
                    return false
                }
            )
        )

        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertEqual(workspace.rightAuxPanel.tabIDs.count, 1)
        let rightPanelTab = try XCTUnwrap(workspace.rightAuxPanel.activeTab)
        let panelID = rightPanelTab.panelID
        guard case .web(let webState) = rightPanelTab.panelState else {
            XCTFail("expected right-panel local document")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.localDocument?.filePath, fixture.markdownPath)
        XCTAssertEqual(revealedPanelID, panelID)
        XCTAssertEqual(revealedLineNumber, 42)
    }

    func testOpenFallbackAfterBrowserPlacementFailureUsesNormalizedExternalTarget() throws {
        let store = AppStore(
            state: AppState(windows: [], workspacesByID: [:], selectedWindowID: nil),
            persistTerminalFontPreference: false
        )
        let url = try XCTUnwrap(URL(string: "/tmp/toastty directory"))
        var externallyOpenedURL: URL?

        XCTAssertTrue(
            AppURLRouter.open(
                url,
                preferredWindowID: nil,
                appStore: store,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .newTab
                ),
                openExternally: { openedURL in
                    externallyOpenedURL = openedURL
                    return true
                }
            )
        )

        XCTAssertEqual(externallyOpenedURL?.scheme, "file")
        XCTAssertEqual(externallyOpenedURL?.path, "/tmp/toastty directory")
    }

    private func makeMarkdownFixture(
        fileName: String = "command-palette.md"
    ) throws -> (markdownPath: String, markdownURL: URL) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-app-url-router-tests-\(UUID().uuidString)", isDirectory: true)
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        let markdownURL = docsURL.appendingPathComponent(fileName, isDirectory: false)

        try fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try Data("# Markdown Fixture\n".utf8).write(to: markdownURL)

        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        let normalizedMarkdownURL = markdownURL.standardizedFileURL.resolvingSymlinksInPath()
        return (markdownPath: normalizedMarkdownURL.path, markdownURL: markdownURL)
    }

    private func makeTextFixture(
        fileName: String = "notes.txt"
    ) throws -> (filePath: String, fileURL: URL) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-app-url-router-text-tests-\(UUID().uuidString)", isDirectory: true)
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        let fileURL = docsURL.appendingPathComponent(fileName, isDirectory: false)

        try fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try Data("plain text fixture\n".utf8).write(to: fileURL)

        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        let normalizedFileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        return (filePath: normalizedFileURL.path, fileURL: fileURL)
    }

    private func makeUnsupportedFixture(
        fileName: String = "archive.zip"
    ) throws -> (filePath: String, fileURL: URL) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-app-url-router-unsupported-tests-\(UUID().uuidString)", isDirectory: true)
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        let fileURL = docsURL.appendingPathComponent(fileName, isDirectory: false)

        try fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try Data("zip fixture\n".utf8).write(to: fileURL)

        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        let normalizedFileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        return (filePath: normalizedFileURL.path, fileURL: fileURL)
    }
}
