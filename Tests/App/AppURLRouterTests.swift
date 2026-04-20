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
                    browserPlacement: .newTab
                )
            ),
            .toasttyBrowser(placement: .newTab)
        )
    }

    func testRouteUsesConfiguredAlternateBrowserPlacementForAlternateOpen() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .newTab,
                    alternateBrowserPlacement: .rootRight
                ),
                useAlternatePlacement: true
            ),
            .toasttyBrowser(placement: .rootRight)
        )
    }

    func testRouteKeepsFileURLsExternalEvenWhenToasttyBrowserIsEnabled() throws {
        let url = try XCTUnwrap(URL(string: "file:///tmp/readme.md"))

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .rootRight
                )
            ),
            .external
        )
    }

    func testRouteKeepsCustomSchemesExternal() throws {
        let url = try XCTUnwrap(URL(string: "mailto:test@example.com"))

        XCTAssertEqual(
            AppURLRouter.route(
                for: url,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .rootRight
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
                    browserPlacement: .rootRight
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
        let url = try XCTUnwrap(URL(string: "https://example.com/right-side"))

        XCTAssertTrue(
            AppURLRouter.open(
                url,
                preferredWindowID: nil,
                appStore: store,
                useAlternatePlacement: true,
                preferences: URLRoutingPreferences(
                    destination: .toasttyBrowser,
                    browserPlacement: .newTab,
                    alternateBrowserPlacement: .rootRight
                ),
                openExternally: { _ in
                    XCTFail("router should not fall back to external open")
                    return false
                }
            )
        )

        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
        XCTAssertEqual(workspace.panels.count, 2)
        let focusedPanelID = try XCTUnwrap(workspace.focusedPanelID)
        guard case .web(let webState) = workspace.panels[focusedPanelID] else {
            XCTFail("expected root-right browser panel")
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
                browserPlacement: .rootRight
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
}
