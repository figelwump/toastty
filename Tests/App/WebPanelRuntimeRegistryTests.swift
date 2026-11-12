@testable import ToasttyApp
import AppKit
import CoreState
import XCTest

@MainActor
final class WebPanelRuntimeRegistryTests: XCTestCase {
    func testLiveScratchpadPanelIDsIncludesRightAuxPanelScratchpads() {
        let workspaceID = UUID()
        let windowID = UUID()
        let mainPanelID = UUID()
        let rightPanelID = UUID()
        let rightTabID = UUID()

        let rightAuxPanel = RightAuxPanelState(
            isVisible: true,
            activeTabID: rightTabID,
            tabIDs: [rightTabID],
            tabsByID: [
                rightTabID: RightAuxPanelTabState(
                    id: rightTabID,
                    identity: .scratchpad(id: rightPanelID),
                    panelID: rightPanelID,
                    panelState: .web(
                        WebPanelState(
                            definition: .scratchpad,
                            scratchpad: ScratchpadState(documentID: UUID(), revision: 0)
                        )
                    )
                ),
            ],
            focusedPanelID: rightPanelID
        )
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Workspace",
            layoutTree: .slot(slotID: UUID(), panelID: mainPanelID),
            panels: [
                mainPanelID: .web(
                    WebPanelState(
                        definition: .scratchpad,
                        scratchpad: ScratchpadState(documentID: UUID(), revision: 0)
                    )
                ),
            ],
            focusedPanelID: mainPanelID,
            rightAuxPanel: rightAuxPanel
        )
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1_200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID
        )

        let registry = WebPanelRuntimeRegistry()

        XCTAssertEqual(
            registry.liveScratchpadPanelIDsForTesting(in: state),
            Set([mainPanelID, rightPanelID])
        )
    }

    func testMarkdownPanelLinkOpensLinkedDocumentAndViewChoiceCarriesToLaterPanels() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-markdown-link-\(UUID().uuidString)", isDirectory: true)
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        try fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
        addTeardownBlock { try? fileManager.removeItem(at: rootURL) }
        let planPath = docsURL.appendingPathComponent("plan.md").standardizedFileURL.resolvingSymlinksInPath().path
        let notesPath = docsURL.appendingPathComponent("notes.md").standardizedFileURL.resolvingSymlinksInPath().path
        try Data("# Plan\n\nSee [notes](notes.md#L2).\n".utf8).write(to: URL(fileURLWithPath: planPath))
        try Data("# Notes\nSecond line\n".utf8).write(to: URL(fileURLWithPath: notesPath))

        let windowID = UUID()
        let workspaceID = UUID()
        let planPanelID = UUID()
        let planWebState = WebPanelState(
            definition: .localDocument,
            title: "plan.md",
            localDocument: LocalDocumentState(filePath: planPath, format: .markdown)
        )
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Docs",
            layoutTree: .slot(slotID: UUID(), panelID: planPanelID),
            panels: [planPanelID: .web(planWebState)],
            focusedPanelID: planPanelID
        )
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 20, y: 20, width: 1_200, height: 800),
                        workspaceIDs: [workspaceID],
                        selectedWorkspaceID: workspaceID
                    ),
                ],
                workspacesByID: [workspaceID: workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let registry = WebPanelRuntimeRegistry()
        registry.bind(store: store)

        let planRuntime = registry.localDocumentRuntime(for: planPanelID)
        planRuntime.apply(webState: planWebState)
        let planBootstrap = try await waitForBootstrap(of: planRuntime)
        XCTAssertEqual(planBootstrap.markdownViewMode, .formatted)

        planRuntime.simulateBridgeMessageForTesting(["type": "setMarkdownViewMode", "mode": "source"])
        XCTAssertEqual(store.localDocumentMarkdownViewMode, .source)

        planRuntime.simulateBridgeMessageForTesting(["type": "openLink", "href": "notes.md#L2"])

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let notesPanelID = try XCTUnwrap(workspaceAfter.rightAuxPanel.activePanelID)
        let notesTab = try XCTUnwrap(workspaceAfter.rightAuxPanel.tabsByID.values.first { $0.panelID == notesPanelID })
        guard case .web(let notesWebState) = notesTab.panelState else {
            return XCTFail("Expected the link to open a web panel")
        }
        XCTAssertEqual(notesWebState.localDocument?.filePath, notesPath)

        let notesRuntime = registry.localDocumentRuntime(for: notesPanelID)
        XCTAssertEqual(notesRuntime.automationState().pendingRevealLine, 2)
        notesRuntime.apply(webState: notesWebState)
        let notesBootstrap = try await waitForBootstrap(of: notesRuntime)
        XCTAssertEqual(notesBootstrap.markdownViewMode, .source, "A later panel opens with the remembered view")
    }

    func testAppearanceChoiceAppliesToEveryDocumentPanel() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = WebPanelRuntimeRegistry()
        registry.bind(store: store)
        let darkAppearance = NSAppearance(named: .darkAqua)
        let firstRuntime = registry.localDocumentRuntime(for: UUID())
        let secondRuntime = registry.localDocumentRuntime(for: UUID())
        firstRuntime.applyEffectiveAppearance(darkAppearance)
        secondRuntime.applyEffectiveAppearance(darkAppearance)
        XCTAssertEqual(secondRuntime.automationState().currentTheme, .dark)

        firstRuntime.selectAppearance(.light)

        XCTAssertEqual(store.localDocumentAppearance, .light)
        XCTAssertEqual(firstRuntime.automationState().currentTheme, .light)
        XCTAssertEqual(secondRuntime.automationState().currentTheme, .light)
        XCTAssertEqual(secondRuntime.appearanceContextMenuItem().submenu?.items.map(\.state), [.off, .on, .off])

        let laterRuntime = registry.localDocumentRuntime(for: UUID())
        laterRuntime.applyEffectiveAppearance(darkAppearance)
        XCTAssertEqual(laterRuntime.automationState().currentTheme, .light, "A later panel opens with the saved choice")
    }

    private func waitForBootstrap(
        of runtime: LocalDocumentPanelRuntime,
        timeout: Duration = .seconds(5)
    ) async throws -> LocalDocumentPanelBootstrap {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let bootstrap = runtime.automationState().currentBootstrap {
                return bootstrap
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw BootstrapTimeoutError()
    }
}

private struct BootstrapTimeoutError: Error, CustomStringConvertible {
    var description: String { "The local document runtime did not load its document in time" }
}
