@testable import ToasttyApp
import AppKit
import CoreState
import WebKit
import XCTest

@MainActor
final class BrowserPanelRuntimeTests: XCTestCase {
    func testNetworkAllowedCapabilityProfileUsesPersistentWebsiteDataStore() {
        let configuration = BrowserPanelRuntime.makeWebViewConfiguration(for: .networkAllowed)

        XCTAssertTrue(configuration.websiteDataStore.isPersistent)
    }

    func testNormalizedUserEnteredURLStringPrefixesHTTPSForBareHostname() {
        XCTAssertEqual(
            BrowserPanelRuntime.normalizedUserEnteredURLString("example.com/docs"),
            "https://example.com/docs"
        )
    }

    func testNormalizedUserEnteredURLStringPrefixesHTTPForLocalAddresses() {
        XCTAssertEqual(
            BrowserPanelRuntime.normalizedUserEnteredURLString("localhost:3000"),
            "http://localhost:3000"
        )
        XCTAssertEqual(
            BrowserPanelRuntime.normalizedUserEnteredURLString("127.0.0.1:8080/path"),
            "http://127.0.0.1:8080/path"
        )
    }

    func testNormalizedUserEnteredURLStringDoesNotMangleCustomSchemeLikeInput() {
        XCTAssertEqual(
            BrowserPanelRuntime.normalizedUserEnteredURLString("mailto:test@example.com"),
            "mailto:test@example.com"
        )
        XCTAssertEqual(
            BrowserPanelRuntime.normalizedUserEnteredURLString("obsidian://open?vault=toastty"),
            "obsidian://open?vault=toastty"
        )
    }

    func testDefaultStartPageUsesToasttyCopyWithoutExternalDemoLinks() {
        let html = BrowserPanelRuntime.defaultStartPageHTML

        XCTAssertTrue(html.contains("Butter your workflow."))
        XCTAssertTrue(html.contains("Focus Location"))
        XCTAssertTrue(html.contains("⌘L"))
        XCTAssertTrue(html.contains("toast-glow"))
        XCTAssertFalse(html.contains("example.com"))
        XCTAssertFalse(html.contains("WebKit docs"))
    }

    func testFaviconCandidateURLsResolveRelativeLinksAndAppendRootFallback() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.espn.com/nhl/story"))

        let candidateURLs = BrowserPanelRuntime.faviconCandidateURLs(
            linkHrefs: [
                "/apple-touch-icon.png",
                "https://cdn.espn.com/favicon-32.png",
                "/apple-touch-icon.png",
            ],
            pageURL: pageURL
        )

        XCTAssertEqual(
            candidateURLs,
            [
                URL(string: "https://www.espn.com/apple-touch-icon.png"),
                URL(string: "https://cdn.espn.com/favicon-32.png"),
                URL(string: "https://www.espn.com/favicon.ico"),
            ].compactMap { $0 }
        )
    }

    func testFaviconCandidateURLsPreferRegularIconsBeforeMaskIcons() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.espn.com/nhl/story"))

        let candidateURLs = BrowserPanelRuntime.faviconCandidateURLs(
            linkReferences: [
                FaviconLinkReference(
                    href: "https://a.espncdn.com/prod/assets/icons/E.svg",
                    rel: "mask-icon"
                ),
                FaviconLinkReference(
                    href: "https://a.espncdn.com/favicon.ico",
                    rel: "shortcut icon"
                ),
                FaviconLinkReference(
                    href: "https://a.espncdn.com/wireless/mw5/r1/images/bookmark-icons-v2/espn-icon-180x180.png",
                    rel: "apple-touch-icon"
                ),
            ],
            pageURL: pageURL
        )

        XCTAssertEqual(
            candidateURLs,
            [
                URL(string: "https://a.espncdn.com/favicon.ico"),
                URL(string: "https://a.espncdn.com/wireless/mw5/r1/images/bookmark-icons-v2/espn-icon-180x180.png"),
                URL(string: "https://www.espn.com/favicon.ico"),
                URL(string: "https://a.espncdn.com/prod/assets/icons/E.svg"),
            ].compactMap { $0 }
        )
    }

    func testFaviconCandidateURLsSkipFallbackForNonHTTPPages() throws {
        let pageURL = try XCTUnwrap(URL(string: "data:text/html,hello"))

        XCTAssertEqual(
            BrowserPanelRuntime.faviconCandidateURLs(
                linkHrefs: [],
                pageURL: pageURL
            ),
            []
        )
    }

    func testFileLoadForFileURLUsesParentDirectoryReadAccess() {
        let fileURL = URL(fileURLWithPath: "/tmp/toastty browser/page.html")

        XCTAssertEqual(
            BrowserPanelRuntime.fileLoad(for: fileURL),
            BrowserPanelFileLoad(
                fileURL: fileURL.standardizedFileURL,
                readAccessURL: fileURL.standardizedFileURL.deletingLastPathComponent()
            )
        )
    }

    func testFileLoadForNonFileURLReturnsNil() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/page.html"))

        XCTAssertNil(BrowserPanelRuntime.fileLoad(for: url))
    }

    func testScreenshotFileNameStemUsesSanitizedTitle() {
        XCTAssertEqual(
            BrowserPanelScreenshotWriter.suggestedFileNameStem(
                title: "Docs / Preview: Ready?",
                urlString: "https://example.com/fallback"
            ),
            "Docs-Preview-Ready"
        )
    }

    func testScreenshotFileNameStemFallsBackToURLWhenTitleIsDefault() {
        XCTAssertEqual(
            BrowserPanelScreenshotWriter.suggestedFileNameStem(
                title: "Browser",
                urlString: "https://docs.example.com/guides/setup.html"
            ),
            "docs.example.com-setup"
        )
    }

    func testScreenshotAgentInsertionIncludesOnlyPath() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/toastty-browser-screenshots/page.png")

        XCTAssertEqual(
            BrowserScreenshotAgentInsertionBuilder.insertionText(fileURL: fileURL),
            "/tmp/toastty-browser-screenshots/page.png"
        )
    }

    func testBrowserActionsMenuOnlyIncludesOpenInDefaultBrowser() {
        let menu = BrowserPanelActionsMenuBuilder.menu(
            canOpenCurrentURL: true,
            target: nil,
            openCurrentURLAction: nil
        )

        XCTAssertEqual(menu.items.map(\.title), [
            "Open in Default Browser",
        ])
        XCTAssertTrue(menu.items[0].isEnabled)
    }

    func testBrowserScreenshotCandidatesResolveMainLayoutBrowserOwnerTab() {
        let workspaceID = UUID()
        let windowID = UUID()
        let browserPanelID = UUID()
        let sameTabPanelID = UUID()
        let otherTabPanelID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)

        let firstTab = WorkspaceTabState(
            id: UUID(),
            layoutTree: split(
                firstPanelID: browserPanelID,
                secondPanelID: sameTabPanelID
            ),
            panels: [
                browserPanelID: .web(WebPanelState(definition: .browser)),
                sameTabPanelID: terminalPanel(title: "Same"),
            ],
            focusedPanelID: sameTabPanelID
        )
        let secondTab = WorkspaceTabState(
            id: UUID(),
            layoutTree: .slot(slotID: UUID(), panelID: otherTabPanelID),
            panels: [
                otherTabPanelID: terminalPanel(title: "Other"),
            ],
            focusedPanelID: otherTabPanelID
        )
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Workspace",
            selectedTabID: firstTab.id,
            tabIDs: [firstTab.id, secondTab.id],
            tabsByID: [firstTab.id: firstTab, secondTab.id: secondTab]
        )
        var registry = SessionRegistry()
        registry.startSession(
            sessionID: "same-tab",
            agent: .codex,
            panelID: sameTabPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "Same Agent",
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.startSession(
            sessionID: "other-tab",
            agent: .claude,
            panelID: otherTabPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "Other Agent",
            cwd: nil,
            repoRoot: nil,
            at: now
        )

        let candidates = BrowserScreenshotSendCandidateBuilder.candidates(
            workspace: workspace,
            browserPanelID: browserPanelID,
            sessionRegistry: registry
        )

        XCTAssertEqual(candidates.map(\.sessionID), ["same-tab"])
        XCTAssertEqual(candidates.first?.label, "Same Agent - right split")
    }

    func testBrowserScreenshotCandidatesResolveRightPanelBrowserOwnerTabAndExcludeProcessWatch() {
        let workspaceID = UUID()
        let windowID = UUID()
        let browserPanelID = UUID()
        let agentPanelID = UUID()
        let watchPanelID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)

        let ownerTab = WorkspaceTabState(
            id: UUID(),
            layoutTree: split(firstPanelID: agentPanelID, secondPanelID: watchPanelID),
            panels: [
                agentPanelID: terminalPanel(title: "Agent"),
                watchPanelID: terminalPanel(title: "Watch"),
            ],
            focusedPanelID: agentPanelID,
            rightAuxPanel: RightAuxPanelState(
                isVisible: true,
                activeTabID: browserPanelID,
                tabIDs: [browserPanelID],
                tabsByID: [
                    browserPanelID: RightAuxPanelTabState(
                        id: browserPanelID,
                        identity: .browserSession(browserPanelID),
                        panelID: browserPanelID,
                        panelState: .web(WebPanelState(definition: .browser))
                    ),
                ]
            )
        )
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Workspace",
            selectedTabID: ownerTab.id,
            tabIDs: [ownerTab.id],
            tabsByID: [ownerTab.id: ownerTab]
        )
        var registry = SessionRegistry()
        registry.startSession(
            sessionID: "agent",
            agent: .codex,
            panelID: agentPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "Codex",
            cwd: nil,
            repoRoot: nil,
            at: now
        )
        registry.startSession(
            sessionID: "watch",
            agent: .processWatch,
            panelID: watchPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "Build Watch",
            cwd: nil,
            repoRoot: nil,
            at: now
        )

        let candidates = BrowserScreenshotSendCandidateBuilder.candidates(
            workspace: workspace,
            browserPanelID: browserPanelID,
            sessionRegistry: registry
        )

        XCTAssertEqual(candidates.map(\.sessionID), ["agent"])
    }

    func testBrowserScreenshotCandidatesRejectNonBrowserPanel() {
        let terminalPanelID = UUID()
        let tab = WorkspaceTabState(
            id: UUID(),
            layoutTree: .slot(slotID: UUID(), panelID: terminalPanelID),
            panels: [
                terminalPanelID: terminalPanel(title: "Terminal"),
            ],
            focusedPanelID: terminalPanelID
        )
        let workspace = WorkspaceState(
            id: UUID(),
            title: "Workspace",
            selectedTabID: tab.id,
            tabIDs: [tab.id],
            tabsByID: [tab.id: tab]
        )

        XCTAssertEqual(
            BrowserScreenshotSendCandidateBuilder.candidates(
                workspace: workspace,
                browserPanelID: terminalPanelID,
                sessionRegistry: SessionRegistry()
            ),
            []
        )
    }

    func testLoadUserEnteredURLPublishesPendingDisplayedURLImmediately() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )

        XCTAssertTrue(runtime.loadUserEnteredURL("example.com/docs"))
        XCTAssertEqual(
            runtime.navigationState.displayedURLString,
            "https://example.com/docs"
        )
    }

    func testApplyWebStateSetsBrowserPageZoomOnHostedWebView() throws {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let attachment = PanelHostAttachmentToken.next()

        runtime.attachHost(to: container, attachment: attachment)
        runtime.apply(
            webState: WebPanelState(
                definition: .browser,
                browserPageZoom: 1.25
            )
        )

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        XCTAssertEqual(webView.pageZoom, 1.25, accuracy: 0.0001)
        XCTAssertEqual(runtime.automationState().pageZoom, 1.25, accuracy: 0.0001)
    }

    func testDidFinishReassertsPersistedBrowserPageZoom() throws {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let attachment = PanelHostAttachmentToken.next()

        runtime.attachHost(to: container, attachment: attachment)
        runtime.apply(
            webState: WebPanelState(
                definition: .browser,
                browserPageZoom: 1.5
            )
        )

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        webView.pageZoom = 1.0

        runtime.webView(webView, didFinish: nil)

        XCTAssertEqual(webView.pageZoom, 1.5, accuracy: 0.0001)
        XCTAssertEqual(runtime.automationState().pageZoom, 1.5, accuracy: 0.0001)
    }

    func testUpdateReattachesImmediatelyAfterDetachWithNewAttachment() async {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let firstContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let secondContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let webState = WebPanelState(definition: .browser)
        let firstAttachment = PanelHostAttachmentToken.next()
        let secondAttachment = PanelHostAttachmentToken.next()

        runtime.attachHost(to: firstContainer, attachment: firstAttachment)
        runtime.apply(webState: webState)

        XCTAssertEqual(firstContainer.subviews.count, 1)
        XCTAssertEqual(runtime.lifecycleState.attachmentToken, firstAttachment)

        runtime.detachHost(attachment: firstAttachment)
        runtime.attachHost(to: secondContainer, attachment: secondAttachment)
        runtime.apply(webState: webState)

        await Task.yield()

        XCTAssertEqual(firstContainer.subviews.count, 0)
        XCTAssertEqual(secondContainer.subviews.count, 1)
        XCTAssertEqual(runtime.lifecycleState.attachmentToken, secondAttachment)
    }

    func testSetEffectivelyVisibleHidesAttachedWebViewWithoutDetaching() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let attachment = PanelHostAttachmentToken.next()

        runtime.attachHost(to: container, attachment: attachment)
        runtime.setEffectivelyVisible(false)

        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertTrue(container.subviews[0].isHidden)

        runtime.setEffectivelyVisible(true)

        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertFalse(container.subviews[0].isHidden)
    }

    func testSetEffectivelyVisibleBeforeAttachKeepsWebViewHiddenOnAttach() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let attachment = PanelHostAttachmentToken.next()

        runtime.setEffectivelyVisible(false)
        runtime.attachHost(to: container, attachment: attachment)

        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertTrue(container.subviews[0] is WKWebView)
        XCTAssertTrue(container.subviews[0].isHidden)
    }

    private func terminalPanel(title: String) -> PanelState {
        .terminal(
            TerminalPanelState(
                title: title,
                shell: "zsh",
                cwd: "/tmp"
            )
        )
    }

    private func split(firstPanelID: UUID, secondPanelID: UUID) -> LayoutNode {
        .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: UUID(), panelID: firstPanelID),
            second: .slot(slotID: UUID(), panelID: secondPanelID)
        )
    }
}
