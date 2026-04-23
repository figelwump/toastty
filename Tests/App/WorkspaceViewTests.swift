@testable import ToasttyApp
import AppKit
import CoreState
import SwiftUI
import XCTest

final class WorkspaceViewTests: XCTestCase {
    @MainActor
    private struct WorkspaceHarness {
        let windowID: UUID
        let workspaceID: UUID
        let panelID: UUID
        let store: AppStore
        let webPanelRuntimeRegistry: WebPanelRuntimeRegistry
        let hostingView: NSView
        let window: NSWindow
    }

    func testWorkspaceAgentTopBarModelUsesConfiguredProfileOrderAndDisplayNames() {
        let catalog = AgentCatalog(
            profiles: [
                AgentProfile(id: "codex", displayName: "Codex", argv: ["codex"]),
                AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"]),
            ]
        )

        let model = WorkspaceAgentTopBarModel(
            catalog: catalog,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: catalog)
        )

        XCTAssertEqual(model.actions.map(\.profileID), ["codex", "claude"])
        XCTAssertEqual(model.actions.map(\.title), ["Codex", "Claude Code"])
        XCTAssertEqual(model.actions.map(\.helpText), ["Run Codex", "Run Claude Code"])
        XCTAssertFalse(model.showsAddAgentsButton)
    }

    func testWorkspaceAgentTopBarModelIncludesShortcutInHelpTextWhenConfigured() {
        let catalog = AgentCatalog(
            profiles: [
                AgentProfile(id: "codex", displayName: "Codex", argv: ["codex"], shortcutKey: "c")
            ]
        )

        let model = WorkspaceAgentTopBarModel(
            catalog: catalog,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: catalog)
        )

        XCTAssertEqual(model.actions.map(\.helpText), ["Run Codex (⌥⌘C)"])
    }

    func testWorkspaceAgentTopBarModelShowsAddAgentsButtonWithoutConfiguredProfiles() {
        let model = WorkspaceAgentTopBarModel(
            catalog: .empty,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: .empty)
        )

        XCTAssertTrue(model.actions.isEmpty)
        XCTAssertTrue(model.showsAddAgentsButton)
        XCTAssertEqual(WorkspaceAgentTopBarModel.addAgentsTitle, "Get Started…")
    }

    func testWorkspaceTabTrailingAccessoryUsesCloseButtonWhenHovered() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 0, isHovered: true, showsCloseAffordance: true),
            .closeButton
        )
    }

    func testWorkspaceTabTrailingAccessoryShowsCommandDigitBadgesThroughNine() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 0, isHovered: false, showsCloseAffordance: true),
            .badge("⌘1")
        )
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 8, isHovered: false, showsCloseAffordance: true),
            .badge("⌘9")
        )
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 9, isHovered: false, showsCloseAffordance: true),
            .empty
        )
    }

    func testWorkspaceTabTrailingAccessoryKeepsShortcutBadgeWhenCloseAffordanceIsSuppressed() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 0, isHovered: true, showsCloseAffordance: false),
            .badge("⌘1")
        )
    }

    func testPanelHeaderTrailingAccessoryUsesCloseButtonWhenHovered() {
        XCTAssertEqual(
            WorkspaceView.panelHeaderTrailingAccessory(shortcutLabel: "⌥1", isHovered: true),
            .closeButton
        )
    }

    func testPanelHeaderTrailingAccessoryKeepsShortcutBadgeWhenNotHovered() {
        XCTAssertEqual(
            WorkspaceView.panelHeaderTrailingAccessory(shortcutLabel: "⌥1", isHovered: false),
            .badge("⌥1")
        )
    }

    func testPanelHeaderTrailingAccessoryShowsOnlyCloseButtonForPanelsWithoutShortcutBadge() {
        XCTAssertEqual(
            WorkspaceView.panelHeaderTrailingAccessory(shortcutLabel: nil, isHovered: true),
            .closeButton
        )
        XCTAssertEqual(
            WorkspaceView.panelHeaderTrailingAccessory(shortcutLabel: nil, isHovered: false),
            .empty
        )
    }

    func testWorkspaceTabManagementAffordancesStayEnabledForVisibleTabs() {
        XCTAssertFalse(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 0))
        XCTAssertTrue(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 1))
        XCTAssertTrue(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 2))
    }

    func testSingleTabWorkspaceStillInstallsTabContextMenu() {
        XCTAssertFalse(WorkspaceView.workspaceTabInstallsContextMenu(tabCount: 0))
        XCTAssertTrue(WorkspaceView.workspaceTabInstallsContextMenu(tabCount: 1))
        XCTAssertTrue(WorkspaceView.workspaceTabInstallsContextMenu(tabCount: 2))
    }

    func testBrowserTitleIconPanelIDUsesFocusedBrowserWhenTabTitleIsDerived() {
        let panelID = UUID()
        let tab = WorkspaceTabState(
            id: UUID(),
            layoutTree: .slot(slotID: UUID(), panelID: panelID),
            panels: [
                panelID: .web(
                    WebPanelState(
                        definition: .browser,
                        title: "ESPN"
                    )
                )
            ],
            focusedPanelID: panelID
        )

        XCTAssertEqual(WorkspaceView.browserTitleIconPanelID(for: tab), panelID)
    }

    func testBrowserTitleIconPanelIDSkipsCustomTabTitles() {
        let panelID = UUID()
        let tab = WorkspaceTabState(
            id: UUID(),
            customTitle: "Pinned",
            layoutTree: .slot(slotID: UUID(), panelID: panelID),
            panels: [
                panelID: .web(
                    WebPanelState(
                        definition: .browser,
                        title: "ESPN"
                    )
                )
            ],
            focusedPanelID: panelID
        )

        XCTAssertNil(WorkspaceView.browserTitleIconPanelID(for: tab))
    }

    func testBrowserTitleIconPanelIDSkipsNonBrowserFocusedPanels() {
        let panelID = UUID()
        let tab = WorkspaceTabState(
            id: UUID(),
            layoutTree: .slot(slotID: UUID(), panelID: panelID),
            panels: [
                panelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: NSHomeDirectory()
                    )
                )
            ],
            focusedPanelID: panelID
        )

        XCTAssertNil(WorkspaceView.browserTitleIconPanelID(for: tab))
    }

    func testResolvedWorkspaceTabWidthStaysAtIdealWidthWhenThereIsRoom() {
        let availableWidth = WorkspaceView.workspaceTabIdealTotalWidth(tabCount: 3) + 120
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabWidth(availableWidth: availableWidth, tabCount: 3),
            ToastyTheme.workspaceTabWidth
        )
    }

    func testResolvedWorkspaceTabWidthCompressesTabsEquallyWhenHeaderGetsTight() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabWidth(availableWidth: 524, tabCount: 5),
            104
        )
    }

    func testResolvedWorkspaceTabWidthReservesTrailingNewTabButtonWidth() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabWidth(
                availableWidth: 524,
                tabCount: 5,
                trailingAccessoryWidth: 20,
                trailingAccessorySpacing: 10
            ),
            98
        )
    }

    func testResolvedWorkspaceTabWidthStopsAtConfiguredMinimumWidth() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabWidth(availableWidth: 140, tabCount: 5),
            ToastyTheme.workspaceTabMinimumWidth
        )
    }

    func testWorkspaceTabReorderTargetIndexHandlesBeforeFirstBoundary() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let targetIndex = WorkspaceView.workspaceTabReorderTargetIndex(
            orderedTabIDs: [first, second, third],
            measuredFramesByID: [
                first: CGRect(x: 0, y: 0, width: 100, height: 28),
                second: CGRect(x: 100, y: 0, width: 100, height: 28),
                third: CGRect(x: 200, y: 0, width: 100, height: 28),
            ],
            draggedTabID: second,
            pointerX: -12
        )

        XCTAssertEqual(targetIndex, 0)
    }

    func testWorkspaceTabReorderTargetIndexHandlesAfterLastBoundary() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let targetIndex = WorkspaceView.workspaceTabReorderTargetIndex(
            orderedTabIDs: [first, second, third],
            measuredFramesByID: [
                first: CGRect(x: 0, y: 0, width: 100, height: 28),
                second: CGRect(x: 100, y: 0, width: 100, height: 28),
                third: CGRect(x: 200, y: 0, width: 100, height: 28),
            ],
            draggedTabID: second,
            pointerX: 360
        )

        XCTAssertEqual(targetIndex, 2)
    }

    func testWorkspaceTabReorderTargetIndexTreatsSelfDropAsNoOpIndex() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let targetIndex = WorkspaceView.workspaceTabReorderTargetIndex(
            orderedTabIDs: [first, second, third],
            measuredFramesByID: [
                first: CGRect(x: 0, y: 0, width: 100, height: 28),
                second: CGRect(x: 100, y: 0, width: 100, height: 28),
                third: CGRect(x: 200, y: 0, width: 100, height: 28),
            ],
            draggedTabID: second,
            pointerX: 150
        )

        XCTAssertEqual(targetIndex, 1)
    }

    func testWorkspaceTabReorderTargetIndexReturnsNilWhenFramesAreMissing() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let targetIndex = WorkspaceView.workspaceTabReorderTargetIndex(
            orderedTabIDs: [first, second, third],
            measuredFramesByID: [
                first: CGRect(x: 0, y: 0, width: 100, height: 28),
                second: CGRect(x: 100, y: 0, width: 100, height: 28),
            ],
            draggedTabID: second,
            pointerX: 210
        )

        XCTAssertNil(targetIndex)
    }

    func testResolvedWorkspaceTitleWidthUsesIntrinsicWidthWhenItFits() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTitleWidth(
                preferredWidth: 120,
                availableWidth: 900,
                trailingWidth: 240,
                tabCount: 3
            ),
            120
        )
    }

    func testResolvedWorkspaceTitleWidthUsesUnreadSummaryWidthWhenItIsWider() {
        let preferredWidth = WorkspaceView.workspaceHeaderTitleColumnPreferredWidth(
            titleWidth: 120,
            unreadSummaryWidth: 170
        )

        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTitleWidth(
                preferredWidth: preferredWidth,
                availableWidth: 900,
                trailingWidth: 240,
                tabCount: 3
            ),
            170
        )
    }

    func testResolvedWorkspaceTitleWidthShrinksOnlyAfterTabsReachMinimumWidth() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTitleWidth(
                preferredWidth: 320,
                availableWidth: 580,
                trailingWidth: 200,
                tabCount: 3
            ),
            206
        )
    }

    func testResolvedWorkspaceTitleWidthLeavesRoomForTrailingNewTabButton() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTitleWidth(
                preferredWidth: 320,
                availableWidth: 580,
                trailingWidth: 200,
                tabCount: 3,
                tabAccessoryWidth: 20,
                tabAccessorySpacing: 10
            ),
            176
        )
    }

    func testWorkspaceTabIdealTotalWidthRemovesInterTabGap() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabIdealTotalWidth(tabCount: 2),
            ToastyTheme.workspaceTabWidth * 2
        )
    }

    func testWorkspaceTabIdealTotalWidthIncludesTrailingAccessory() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabIdealTotalWidth(
                tabCount: 2,
                trailingAccessoryWidth: 20,
                trailingAccessorySpacing: 10
            ),
            (ToastyTheme.workspaceTabWidth * 2) + 30
        )
    }

    func testWorkspaceUnreadSummaryTextHidesZeroCount() {
        XCTAssertNil(WorkspaceView.workspaceUnreadSummaryText(unreadPanelCount: 0))
    }

    func testWorkspaceUnreadSummaryTextUsesSingularAndPluralForms() {
        XCTAssertEqual(WorkspaceView.workspaceUnreadSummaryText(unreadPanelCount: 1), "1 unread")
        XCTAssertEqual(WorkspaceView.workspaceUnreadSummaryText(unreadPanelCount: 2), "2 unreads")
    }

    func testFocusedUnreadClearCandidateRequiresActiveApp() throws {
        let workspace = try makeFocusedUnreadWorkspace()

        XCTAssertNil(
            WorkspaceView.focusedUnreadClearCandidate(
                workspace: workspace,
                appIsActive: false
            )
        )
        XCTAssertEqual(
            WorkspaceView.focusedUnreadClearCandidate(
                workspace: workspace,
                appIsActive: true
            ),
            WorkspaceView.FocusedUnreadClearCandidate(
                workspaceID: workspace.id,
                panelID: try XCTUnwrap(workspace.focusedPanelID)
            )
        )
    }

    func testShouldClearFocusedUnreadRequiresMatchingFocusedUnreadPanelInActiveApp() throws {
        var workspace = try makeFocusedUnreadWorkspace()
        let candidate = try XCTUnwrap(
            WorkspaceView.focusedUnreadClearCandidate(
                workspace: workspace,
                appIsActive: true
            )
        )

        XCTAssertTrue(
            WorkspaceView.shouldClearFocusedUnread(
                currentWorkspace: workspace,
                candidate: candidate,
                appIsActive: true
            )
        )

        XCTAssertFalse(
            WorkspaceView.shouldClearFocusedUnread(
                currentWorkspace: workspace,
                candidate: candidate,
                appIsActive: false
            )
        )

        workspace.unreadPanelIDs = []
        XCTAssertFalse(
            WorkspaceView.shouldClearFocusedUnread(
                currentWorkspace: workspace,
                candidate: candidate,
                appIsActive: true
            )
        )

        workspace = try makeFocusedUnreadWorkspace()
        workspace.focusedPanelID = UUID()
        XCTAssertFalse(
            WorkspaceView.shouldClearFocusedUnread(
                currentWorkspace: workspace,
                candidate: candidate,
                appIsActive: true
            )
        )
    }

    func testWorkspaceTabFocusIndicatorStyleKeepsFullLabelAtIdealWidth() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabFocusIndicatorStyle(tabWidth: ToastyTheme.workspaceTabWidth),
            .fullLabel
        )
    }

    func testWorkspaceTabFocusIndicatorStyleUsesIconOnlyWhenTabsCompress() {
        let compressedTabWidth = WorkspaceView.resolvedWorkspaceTabWidth(
            availableWidth: 524,
            tabCount: 5
        )

        XCTAssertEqual(
            WorkspaceView.workspaceTabFocusIndicatorStyle(tabWidth: compressedTabWidth),
            .iconOnly
        )
    }

    func testFocusedPanelToggleTitleShowsUnfocusOnlyWhenActive() {
        XCTAssertEqual(WorkspaceView.focusedPanelToggleTitle(isActive: true), "Unfocus")
        XCTAssertNil(WorkspaceView.focusedPanelToggleTitle(isActive: false))
    }

    func testTransientUnfocusHighlightRequestReturnsPreviousFocusedSubtreeForSameTab() {
        let workspaceID = UUID()
        let tabID = UUID()
        let rootNodeID = UUID()

        let request = WorkspaceView.transientUnfocusHighlightRequest(
            from: .init(
                workspaceID: workspaceID,
                tabID: tabID,
                focusedPanelModeActive: true,
                effectiveRootNodeID: rootNodeID
            ),
            to: .init(
                workspaceID: workspaceID,
                tabID: tabID,
                focusedPanelModeActive: false,
                effectiveRootNodeID: nil
            )
        )

        XCTAssertEqual(
            request,
            .init(workspaceID: workspaceID, tabID: tabID, rootNodeID: rootNodeID)
        )
    }

    func testTransientUnfocusHighlightRequestIgnoresTabSwitches() {
        let request = WorkspaceView.transientUnfocusHighlightRequest(
            from: .init(
                workspaceID: UUID(),
                tabID: UUID(),
                focusedPanelModeActive: true,
                effectiveRootNodeID: UUID()
            ),
            to: .init(
                workspaceID: UUID(),
                tabID: UUID(),
                focusedPanelModeActive: false,
                effectiveRootNodeID: nil
            )
        )

        XCTAssertNil(request)
    }

    func testShouldClearTransientUnfocusHighlightWhenSwitchingTabs() {
        let workspaceID = UUID()

        XCTAssertTrue(
            WorkspaceView.shouldClearTransientUnfocusHighlight(
                from: .init(
                    workspaceID: workspaceID,
                    tabID: UUID(),
                    focusedPanelModeActive: false,
                    effectiveRootNodeID: nil
                ),
                to: .init(
                    workspaceID: workspaceID,
                    tabID: UUID(),
                    focusedPanelModeActive: false,
                    effectiveRootNodeID: nil
                )
            )
        )
    }

    func testFocusModeHighlightFrameReturnsLeafSlotFrame() {
        let topLeftPanelID = UUID()
        let bottomLeftPanelID = UUID()
        let rightPanelID = UUID()
        let topLeftSlotID = UUID()
        let bottomLeftSlotID = UUID()
        let rightSlotID = UUID()
        let leftBranchNodeID = UUID()
        let rootNodeID = UUID()
        let layoutTree = LayoutNode.split(
            nodeID: rootNodeID,
            orientation: .horizontal,
            ratio: 0.5,
            first: .split(
                nodeID: leftBranchNodeID,
                orientation: .vertical,
                ratio: 0.5,
                first: .slot(slotID: topLeftSlotID, panelID: topLeftPanelID),
                second: .slot(slotID: bottomLeftSlotID, panelID: bottomLeftPanelID)
            ),
            second: .slot(slotID: rightSlotID, panelID: rightPanelID)
        )
        let projection = layoutTree.projectLayout(
            in: LayoutFrame(minX: 0, minY: 0, width: 100, height: 80),
            dividerThickness: 0
        )

        XCTAssertEqual(
            WorkspaceView.focusModeHighlightFrame(
                rootNodeID: bottomLeftSlotID,
                layoutTree: layoutTree,
                projection: projection
            ),
            LayoutFrame(minX: 0, minY: 40, width: 50, height: 40)
        )
    }

    func testFocusModeHighlightFrameReturnsBoundingFrameForSplitSubtree() {
        let topLeftPanelID = UUID()
        let bottomLeftPanelID = UUID()
        let rightPanelID = UUID()
        let topLeftSlotID = UUID()
        let bottomLeftSlotID = UUID()
        let rightSlotID = UUID()
        let leftBranchNodeID = UUID()
        let rootNodeID = UUID()
        let layoutTree = LayoutNode.split(
            nodeID: rootNodeID,
            orientation: .horizontal,
            ratio: 0.5,
            first: .split(
                nodeID: leftBranchNodeID,
                orientation: .vertical,
                ratio: 0.5,
                first: .slot(slotID: topLeftSlotID, panelID: topLeftPanelID),
                second: .slot(slotID: bottomLeftSlotID, panelID: bottomLeftPanelID)
            ),
            second: .slot(slotID: rightSlotID, panelID: rightPanelID)
        )
        let projection = layoutTree.projectLayout(
            in: LayoutFrame(minX: 0, minY: 0, width: 100, height: 80),
            dividerThickness: 0
        )

        XCTAssertEqual(
            WorkspaceView.focusModeHighlightFrame(
                rootNodeID: leftBranchNodeID,
                layoutTree: layoutTree,
                projection: projection
            ),
            LayoutFrame(minX: 0, minY: 0, width: 50, height: 80)
        )
    }

    func testWorkspaceHeaderTitleColumnPreferredWidthUsesWidestLine() {
        XCTAssertEqual(
            WorkspaceView.workspaceHeaderTitleColumnPreferredWidth(
                titleWidth: 120,
                unreadSummaryWidth: 170
            ),
            170
        )
    }

    func testWorkspaceHeaderTitleOriginYAlignsToTitlebarToggleBaseline() {
        let titleHeight: CGFloat = 16
        XCTAssertEqual(
            WorkspaceView.workspaceHeaderTitleOriginY(
                boundsHeight: ToastyTheme.topBarHeight,
                titleHeight: titleHeight
            ),
            ToastyTheme.titlebarSidebarToggleTopPadding +
                ((ToastyTheme.titlebarSidebarToggleButtonSize - titleHeight) / 2)
        )
    }

    func testWorkspaceHeaderUnreadSummaryOriginYPlacesSummaryBelowTitle() {
        let titleOriginY: CGFloat = 8
        let titleHeight: CGFloat = 16
        let unreadSummaryOriginY = WorkspaceView.workspaceHeaderUnreadSummaryOriginY(
            titleOriginY: titleOriginY,
            titleHeight: titleHeight,
            spacing: ToastyTheme.topBarUnreadSummaryTopSpacing
        )

        XCTAssertEqual(
            unreadSummaryOriginY,
            titleOriginY + titleHeight + ToastyTheme.topBarUnreadSummaryTopSpacing
        )
        XCTAssertGreaterThanOrEqual(unreadSummaryOriginY, titleOriginY + titleHeight)
    }

    func testWorkspaceTabSelectedAccentFadesWhenAppIsInactive() throws {
        let activeAccent = try XCTUnwrap(
            NSColor(ToastyTheme.workspaceTabSelectedAccentColor(appIsActive: true))
                .usingColorSpace(.deviceRGB)
        )
        let inactiveAccent = try XCTUnwrap(
            NSColor(ToastyTheme.workspaceTabSelectedAccentColor(appIsActive: false))
                .usingColorSpace(.deviceRGB)
        )
        let expectedInactiveAccent = try XCTUnwrap(
            NSColor(ToastyTheme.accent.opacity(0.5)).usingColorSpace(.deviceRGB)
        )

        XCTAssertEqual(activeAccent.alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(inactiveAccent.redComponent, expectedInactiveAccent.redComponent, accuracy: 0.001)
        XCTAssertEqual(inactiveAccent.greenComponent, expectedInactiveAccent.greenComponent, accuracy: 0.001)
        XCTAssertEqual(inactiveAccent.blueComponent, expectedInactiveAccent.blueComponent, accuracy: 0.001)
        XCTAssertEqual(inactiveAccent.alphaComponent, expectedInactiveAccent.alphaComponent, accuracy: 0.001)
    }

    func testWorkspaceTabChromeSpecSelectedStateWinsOverHover() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: true,
            isHovered: true,
            isRenaming: false,
            appIsActive: true
        )

        try assertColor(spec.background, equals: ToastyTheme.workspaceTabSelectedBackground)
        try assertColor(spec.text, equals: ToastyTheme.primaryText)
        let accentColor = try XCTUnwrap(spec.accentColor)
        try assertColor(accentColor, equals: ToastyTheme.workspaceTabSelectedAccent)
        XCTAssertNil(spec.borderColor)
    }

    func testWorkspaceTabChromeSpecSelectedBackgroundMatchesPanelHeaderBackground() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: true,
            isHovered: false,
            isRenaming: false,
            appIsActive: true
        )

        try assertColor(spec.background, equals: ToastyTheme.elevatedBackground)
    }

    func testWorkspaceTabChromeSpecRenamingUnselectedUsesVisibleFillWithoutAccent() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: false,
            isHovered: false,
            isRenaming: true,
            appIsActive: true
        )

        try assertColor(spec.background, equals: ToastyTheme.workspaceTabHoverBackground)
        try assertColor(spec.text, equals: ToastyTheme.primaryText)
        XCTAssertNil(spec.accentColor)
        let borderColor = try XCTUnwrap(spec.borderColor)
        try assertColor(borderColor, equals: ToastyTheme.subtleBorder)
    }

    func testWorkspaceTabChromeSpecRenamingSelectedPreservesAccent() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: true,
            isHovered: false,
            isRenaming: true,
            appIsActive: false
        )

        try assertColor(spec.background, equals: ToastyTheme.workspaceTabSelectedBackground)
        let accentColor = try XCTUnwrap(spec.accentColor)
        try assertColor(accentColor, equals: ToastyTheme.workspaceTabSelectedAccent.opacity(0.5))
        XCTAssertNil(spec.borderColor)
    }

    func testWorkspaceTabChromeSpecUnselectedStateUsesSubtleOutline() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: false,
            isHovered: false,
            isRenaming: false,
            appIsActive: true
        )

        try assertColor(spec.background, equals: ToastyTheme.chromeBackground)
        try assertColor(spec.text, equals: ToastyTheme.workspaceTabUnselectedText)
        XCTAssertNil(spec.accentColor)
        let borderColor = try XCTUnwrap(spec.borderColor)
        try assertColor(borderColor, equals: ToastyTheme.subtleBorder)
    }

    func testWorkspaceTabChromeSpecHoveredUnselectedKeepsOutline() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: false,
            isHovered: true,
            isRenaming: false,
            appIsActive: true
        )

        try assertColor(spec.background, equals: ToastyTheme.workspaceTabHoverBackground)
        try assertColor(spec.text, equals: ToastyTheme.workspaceTabHoverText)
        XCTAssertNil(spec.accentColor)
        let borderColor = try XCTUnwrap(spec.borderColor)
        try assertColor(borderColor, equals: ToastyTheme.subtleBorder)
    }

    func testWorkspaceTabUnreadDotUsesLargerDiameter() {
        XCTAssertEqual(ToastyTheme.workspaceTabUnreadDotDiameter, 7)
    }

    @MainActor
    func testPendingPanelFlashRequestPulsesAndClearsSelectedTerminalPanel() throws {
        let harness = try makeWorkspaceHarness()
        pumpMainRunLoop(duration: 0.2)
        harness.hostingView.layoutSubtreeIfNeeded()
        let baselineBitmap = try renderedBitmap(for: harness.hostingView)
        let sampledRegion = stableTerminalCornerRegion(in: baselineBitmap)

        harness.store.pendingPanelFlashRequest = PendingPanelFlashRequest(
            requestID: UUID(),
            windowID: harness.windowID,
            workspaceID: harness.workspaceID,
            panelID: harness.panelID
        )
        pumpMainRunLoop(duration: 0.12)
        harness.hostingView.layoutSubtreeIfNeeded()
        let peakBitmap = try renderedBitmap(for: harness.hostingView)

        pumpMainRunLoop(duration: 0.5)
        harness.hostingView.layoutSubtreeIfNeeded()
        let settledBitmap = try renderedBitmap(for: harness.hostingView)

        XCTAssertNil(harness.store.pendingPanelFlashRequest)
        XCTAssertGreaterThan(
            try differingPixelCount(
                in: sampledRegion,
                between: baselineBitmap,
                and: peakBitmap
            ),
            0,
            "Expected the terminal panel to visibly pulse when an explicit navigation flash request is handled"
        )
        XCTAssertEqual(
            try differingPixelCount(
                in: sampledRegion,
                between: baselineBitmap,
                and: settledBitmap
            ),
            0,
            "Expected the terminal panel pulse to settle back to its baseline appearance"
        )

        harness.window.orderOut(nil)
    }

    @MainActor
    func testBlankBrowserCreationConsumesPendingLocationFocusRequestWhenBrowserBecomesVisible() throws {
        let harness = try makeWorkspaceHarness()

        XCTAssertTrue(
            harness.store.createBrowserPanelFromCommand(
                preferredWindowID: harness.windowID,
                request: BrowserPanelCreateRequest(placementOverride: .splitRight)
            )
        )

        let workspace = try XCTUnwrap(harness.store.state.workspacesByID[harness.workspaceID])
        let browserPanelID = try XCTUnwrap(workspace.focusedPanelID)

        pumpMainRunLoop(duration: 0.1)
        harness.hostingView.layoutSubtreeIfNeeded()

        XCTAssertNil(harness.store.pendingBrowserLocationFocusRequest)
        XCTAssertNotNil(
            harness.webPanelRuntimeRegistry
                .browserRuntime(for: browserPanelID)
                .locationFieldFocusRequestID
        )

        harness.window.orderOut(nil)
    }

    @MainActor
    func testLocalDocumentHeaderSearchAppearsWhenRuntimeStartsSearch() throws {
        let documentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        try """
        # Search Harness

        Toastty local document header search validation.
        """.write(to: documentURL, atomically: true, encoding: .utf8)

        let harness = try makeWorkspaceHarness(
            panelState: .web(
                WebPanelState(
                    definition: .localDocument,
                    title: documentURL.lastPathComponent,
                    filePath: documentURL.path
                )
            )
        )
        defer {
            harness.window.orderOut(nil)
            try? FileManager.default.removeItem(at: documentURL)
        }

        let runtime = harness.webPanelRuntimeRegistry.localDocumentRuntime(for: harness.panelID)
        harness.hostingView.layoutSubtreeIfNeeded()

        XCTAssertNil(findDescendantView(in: harness.hostingView, ofType: LocalDocumentSearchTextField.self))

        runtime.startSearch()
        pumpMainRunLoop(duration: 0.1)
        harness.hostingView.layoutSubtreeIfNeeded()

        XCTAssertNotNil(findDescendantView(in: harness.hostingView, ofType: LocalDocumentSearchTextField.self))
    }

    @MainActor
    func testWorkspaceTabStripUsesNonWindowDraggableContainer() throws {
        let harness = try makeWorkspaceHarness()
        defer { harness.window.orderOut(nil) }

        harness.hostingView.layoutSubtreeIfNeeded()
        let tabStripContainer = try XCTUnwrap(
            findDescendantView(in: harness.hostingView, ofType: NonWindowDraggableContainerView.self)
        )
        let tabStripHost = try XCTUnwrap(
            findDescendantView(in: tabStripContainer, ofType: NonWindowDraggableHostingView.self)
        )

        XCTAssertFalse(tabStripContainer.mouseDownCanMoveWindow)

        XCTAssertFalse(tabStripHost.mouseDownCanMoveWindow)
        XCTAssertGreaterThan(tabStripContainer.frame.width, 0)
        XCTAssertEqual(tabStripContainer.frame.height, ToastyTheme.workspaceTabHeight, accuracy: 0.5)
    }

    private func assertColor(
        _ actual: Color,
        equals expected: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actualColor = try XCTUnwrap(NSColor(actual).usingColorSpace(.deviceRGB), file: file, line: line)
        let expectedColor = try XCTUnwrap(NSColor(expected).usingColorSpace(.deviceRGB), file: file, line: line)

        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.alphaComponent, expectedColor.alphaComponent, accuracy: 0.001, file: file, line: line)
    }

    private func makeProfileShortcutRegistry(
        agentProfiles: AgentCatalog
    ) -> ProfileShortcutRegistry {
        ProfileShortcutRegistry(
            terminalProfiles: .empty,
            terminalProfilesFilePath: "/tmp/terminal-profiles.toml",
            agentProfiles: agentProfiles,
            agentProfilesFilePath: "/tmp/agents.toml"
        )
    }

    private func makeFocusedUnreadWorkspace() throws -> WorkspaceState {
        let state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        let focusedPanelID = try XCTUnwrap(workspace.focusedPanelID)
        workspace.unreadPanelIDs = [focusedPanelID]
        return workspace
    }

    @MainActor
    private func makeWorkspaceHarness(panelState overridePanelState: PanelState? = nil) throws -> WorkspaceHarness {
        var state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        if let overridePanelState {
            var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
            let panelID = UUID()
            workspace.layoutTree = .slot(slotID: UUID(), panelID: panelID)
            workspace.panels = [panelID: overridePanelState]
            workspace.focusedPanelID = panelID
            state.workspacesByID[workspaceID] = workspace
        }
        let workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)
        registry.synchronize(with: store.state)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let tempHomeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempHomeDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let agentCatalogStore = AgentCatalogStore(homeDirectoryPath: tempHomeDirectory.path)
        let terminalProfileStore = TerminalProfileStore(
            homeDirectoryPath: tempHomeDirectory.path,
            environment: [:]
        )
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        webPanelRuntimeRegistry.bind(store: store)
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogStore
        )
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: registry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
            webPanelRuntimeRegistry: webPanelRuntimeRegistry
        )
        let workspaceView = WorkspaceView(
            windowID: windowID,
            store: store,
            agentCatalogStore: agentCatalogStore,
            terminalProfileStore: terminalProfileStore,
            terminalRuntimeRegistry: registry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: .empty),
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService,
            showAgentGetStartedFlow: {},
            toggleCommandPalette: { _ in },
            terminalRuntimeContext: TerminalWindowRuntimeContext(
                windowID: windowID,
                runtimeRegistry: registry
            ),
            sidebarVisible: true
        )
        let hostingView = NSHostingView(rootView: workspaceView.frame(width: 900, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()
        return WorkspaceHarness(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            store: store,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            hostingView: hostingView,
            window: window
        )
    }

    @MainActor
    private func pumpMainRunLoop(duration: TimeInterval = 0) {
        let expectation = expectation(description: "Flush SwiftUI update")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        guard duration > 0 else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    @MainActor
    private func renderedBitmap(for view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    private func differingPixelCount(
        between lhs: NSBitmapImageRep,
        and rhs: NSBitmapImageRep
    ) throws -> Int {
        try differingPixelCount(
            in: NSRect(x: 0, y: 0, width: lhs.pixelsWide, height: lhs.pixelsHigh),
            between: lhs,
            and: rhs
        )
    }

    @MainActor
    private func stableTerminalCornerRegion(in bitmap: NSBitmapImageRep) -> NSRect {
        let insetX = CGFloat(max(32, bitmap.pixelsWide / 7))
        let insetY = CGFloat(max(32, bitmap.pixelsHigh / 7))
        let regionWidth = CGFloat(max(48, bitmap.pixelsWide / 10))
        let regionHeight = CGFloat(max(48, bitmap.pixelsHigh / 10))

        return NSRect(
            x: CGFloat(bitmap.pixelsWide) - insetX - regionWidth,
            y: insetY,
            width: regionWidth,
            height: regionHeight
        )
    }

    @MainActor
    private func differingPixelCount(
        in region: NSRect,
        between lhs: NSBitmapImageRep,
        and rhs: NSBitmapImageRep
    ) throws -> Int {
        XCTAssertEqual(lhs.pixelsWide, rhs.pixelsWide)
        XCTAssertEqual(lhs.pixelsHigh, rhs.pixelsHigh)

        let lhsData = try XCTUnwrap(lhs.bitmapData)
        let rhsData = try XCTUnwrap(rhs.bitmapData)
        let bytesPerPixel = max(1, lhs.bitsPerPixel / 8)
        XCTAssertEqual(lhs.bytesPerRow * lhs.pixelsHigh, rhs.bytesPerRow * rhs.pixelsHigh)

        let minX = max(0, min(lhs.pixelsWide - 1, Int(region.minX.rounded(.down))))
        let maxX = max(minX + 1, min(lhs.pixelsWide, Int(region.maxX.rounded(.up))))
        let minY = max(0, min(lhs.pixelsHigh - 1, Int(region.minY.rounded(.down))))
        let maxY = max(minY + 1, min(lhs.pixelsHigh, Int(region.maxY.rounded(.up))))

        var differenceCount = 0
        for y in minY..<maxY {
            let rowOffset = y * lhs.bytesPerRow
            for x in minX..<maxX {
                let pixelOffset = rowOffset + (x * bytesPerPixel)
                for byteOffset in 0..<bytesPerPixel where lhsData[pixelOffset + byteOffset] != rhsData[pixelOffset + byteOffset] {
                    differenceCount += 1
                    break
                }
            }
        }

        return differenceCount
    }

    @MainActor
    private func findDescendantView<T: NSView>(in root: NSView, ofType viewType: T.Type) -> T? {
        if let matchingView = root as? T {
            return matchingView
        }

        for subview in root.subviews {
            if let matchingView = findDescendantView(in: subview, ofType: viewType) {
                return matchingView
            }
        }

        return nil
    }
}
