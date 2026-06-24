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

    func testWorkspaceAgentTopBarModelHidesAllButtonsWhenDisabled() {
        let catalog = AgentCatalog(
            profiles: [
                AgentProfile(id: "codex", displayName: "Codex", argv: ["codex"])
            ],
            showsTopBarButtons: false
        )

        let model = WorkspaceAgentTopBarModel(
            catalog: catalog,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: catalog)
        )

        XCTAssertFalse(model.showsTopBarButtons)
        XCTAssertTrue(model.actions.isEmpty)
        XCTAssertFalse(model.showsAddAgentsButton)

        let emptyHiddenCatalog = AgentCatalog(profiles: [], showsTopBarButtons: false)
        let emptyHiddenModel = WorkspaceAgentTopBarModel(
            catalog: emptyHiddenCatalog,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: emptyHiddenCatalog)
        )
        XCTAssertFalse(emptyHiddenModel.showsAddAgentsButton)
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

    func testTerminalDisplayTitleResolverPrefersLiveHeaderTitleThenSessionStatus() {
        let panelID = UUID()
        let panelState = PanelState.terminal(
            TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "")
        )
        let sessionStatus = WorkspaceSessionStatus(
            sessionID: "session",
            panelID: panelID,
            agent: .codex,
            status: SessionStatus(kind: .working, summary: "Running"),
            displayTitleOverride: "Codex task",
            cwd: nil,
            updatedAt: Date(timeIntervalSince1970: 1),
            isActive: true
        )

        XCTAssertEqual(
            TerminalDisplayTitleResolver.panelHeaderTitle(
                panelState: panelState,
                liveTerminalTitle: "npm test",
                panelSessionStatus: sessionStatus
            ),
            "npm test"
        )
        XCTAssertEqual(
            TerminalDisplayTitleResolver.panelHeaderTitle(
                panelState: panelState,
                liveTerminalTitle: nil,
                panelSessionStatus: sessionStatus
            ),
            "Codex task"
        )
        XCTAssertEqual(
            TerminalDisplayTitleResolver.panelHeaderTitle(
                panelState: panelState,
                liveTerminalTitle: nil,
                panelSessionStatus: nil
            ),
            "zsh"
        )

        let pathPanelState = PanelState.terminal(
            TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp/toastty-live-title")
        )
        XCTAssertEqual(
            TerminalDisplayTitleResolver.panelHeaderTitle(
                panelState: pathPanelState,
                liveTerminalTitle: "/tmp/toastty-live-title",
                panelSessionStatus: nil
            ),
            TerminalPanelState(
                title: "/tmp/toastty-live-title",
                shell: "zsh",
                cwd: "/tmp/toastty-live-title"
            ).displayPanelLabel
        )
    }

    func testMountedContentOpacityKeepsVisibleContentOpaque() {
        XCTAssertEqual(WorkspaceView.mountedContentOpacity(isVisible: true), 1)
    }

    func testMountedContentOpacityKeepsHiddenContentNonZeroButEffectivelyInvisible() {
        let opacity = WorkspaceView.mountedContentOpacity(isVisible: false)
        XCTAssertGreaterThan(opacity, 0)
        XCTAssertLessThanOrEqual(opacity, 0.01)
    }

    func testScratchpadBindingStatusShowsUnboundWithoutSessionLink() {
        XCTAssertEqual(
            PanelCardView.scratchpadBindingStatus(for: nil, sessionRegistry: SessionRegistry()),
            .unbound
        )
    }

    func testScratchpadBindingStatusShowsUnboundForStaleSessionLink() {
        let sessionLink = ScratchpadSessionLink(
            sessionID: "stale-session",
            agent: .claude,
            sourcePanelID: UUID(),
            sourceWorkspaceID: UUID(),
            displayTitle: "Claude Code",
            startedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            PanelCardView.scratchpadBindingStatus(for: sessionLink, sessionRegistry: SessionRegistry()),
            .unbound
        )
    }

    func testScratchpadBindingStatusUsesActiveSessionTitle() {
        let panelID = UUID()
        let workspaceID = UUID()
        let sessionLink = ScratchpadSessionLink(
            sessionID: "live-session",
            agent: .claude,
            sourcePanelID: panelID,
            sourceWorkspaceID: workspaceID,
            displayTitle: "Old Title",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        var sessionRegistry = SessionRegistry()
        sessionRegistry.startSession(
            sessionID: "live-session",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            displayTitleOverride: "Claude Code",
            cwd: nil,
            repoRoot: nil,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            PanelCardView.scratchpadBindingStatus(
                for: sessionLink,
                sessionRegistry: sessionRegistry
            ),
            ScratchpadBindingStatus(label: "Bound to Claude Code", liveSessionID: "live-session")
        )
    }

    func testScratchpadTerminalBindingIndicatorShowsLiveScratchpadBinding() {
        let panelID = UUID()
        let scratchpadPanelID = UUID()
        let workspaceID = UUID()
        let sessionLink = ScratchpadSessionLink(
            sessionID: "live-session",
            agent: .codex,
            sourcePanelID: panelID,
            sourceWorkspaceID: workspaceID,
            displayTitle: "Codex",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let tab = makeTerminalTabWithScratchpad(
            terminalPanelID: panelID,
            scratchpadPanelID: scratchpadPanelID,
            scratchpadTitle: "Agent Notes",
            sessionLink: sessionLink
        )
        var sessionRegistry = SessionRegistry()
        sessionRegistry.startSession(
            sessionID: "live-session",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            displayTitleOverride: "Codex",
            cwd: nil,
            repoRoot: nil,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            PanelCardView.scratchpadTerminalBindingIndicatorState(
                for: panelID,
                in: tab,
                sessionRegistry: sessionRegistry
            ),
            ScratchpadTerminalBindingIndicatorState(
                scratchpadPanelID: scratchpadPanelID,
                helpText: "Bound to Scratchpad: Agent Notes"
            )
        )
    }

    func testScratchpadTerminalBindingIndicatorHidesStaleScratchpadBinding() {
        let panelID = UUID()
        let workspaceID = UUID()
        let sessionLink = ScratchpadSessionLink(
            sessionID: "stale-session",
            agent: .codex,
            sourcePanelID: panelID,
            sourceWorkspaceID: workspaceID,
            displayTitle: "Codex",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let tab = makeTerminalTabWithScratchpad(
            terminalPanelID: panelID,
            scratchpadPanelID: UUID(),
            sessionLink: sessionLink
        )

        XCTAssertNil(
            PanelCardView.scratchpadTerminalBindingIndicatorState(
                for: panelID,
                in: tab,
                sessionRegistry: SessionRegistry()
            )
        )
    }

    func testScratchpadTerminalBindingIndicatorHidesOtherTerminalBindings() {
        let panelID = UUID()
        let otherPanelID = UUID()
        let workspaceID = UUID()
        let sessionLink = ScratchpadSessionLink(
            sessionID: "other-session",
            agent: .claude,
            sourcePanelID: otherPanelID,
            sourceWorkspaceID: workspaceID,
            displayTitle: "Claude Code",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let tab = makeTerminalTabWithScratchpad(
            terminalPanelID: panelID,
            scratchpadPanelID: UUID(),
            sessionLink: sessionLink
        )
        var sessionRegistry = SessionRegistry()
        sessionRegistry.startSession(
            sessionID: "other-session",
            agent: .claude,
            panelID: otherPanelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            displayTitleOverride: "Claude Code",
            cwd: nil,
            repoRoot: nil,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertNil(
            PanelCardView.scratchpadTerminalBindingIndicatorState(
                for: panelID,
                in: tab,
                sessionRegistry: sessionRegistry
            )
        )
    }

    func testEffectivePrimaryFocusedPanelIDClearsWhenVisibleRightPanelIsFocused() {
        let mainPanelID = UUID()
        let rightPanelID = UUID()

        XCTAssertEqual(
            WorkspaceView.effectivePrimaryFocusedPanelID(
                focusedPanelID: mainPanelID,
                rightAuxPanelFocusedPanelID: nil,
                rightAuxPanelVisible: true
            ),
            mainPanelID
        )
        XCTAssertNil(
            WorkspaceView.effectivePrimaryFocusedPanelID(
                focusedPanelID: mainPanelID,
                rightAuxPanelFocusedPanelID: rightPanelID,
                rightAuxPanelVisible: true
            )
        )
        XCTAssertEqual(
            WorkspaceView.effectivePrimaryFocusedPanelID(
                focusedPanelID: mainPanelID,
                rightAuxPanelFocusedPanelID: rightPanelID,
                rightAuxPanelVisible: false
            ),
            mainPanelID
        )
    }

    func testWorkspaceTabManagementAffordancesStayEnabledForVisibleTabs() {
        XCTAssertFalse(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 0))
        XCTAssertTrue(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 1))
        XCTAssertTrue(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 2))
    }

    @MainActor
    func testEffectiveRightAuxPanelWidthUsesDynamicDefaultUntilCustomized() {
        XCTAssertEqual(
            WorkspaceView.effectiveRightAuxPanelWidth(
                for: RightAuxPanelState(width: 360, hasCustomWidth: false),
                availableWidth: 1_200
            ),
            480
        )
        XCTAssertEqual(
            WorkspaceView.effectiveRightAuxPanelWidth(
                for: RightAuxPanelState(width: 360, hasCustomWidth: true),
                availableWidth: 1_200
            ),
            360
        )
    }

    @MainActor
    func testRenderedRightAuxPanelWidthUsesOwningTabVisibility() {
        XCTAssertEqual(
            WorkspaceView.renderedRightAuxPanelWidth(
                for: RightAuxPanelState(isVisible: true, width: 520, hasCustomWidth: true),
                availableWidth: 1_200,
                focusedPanelModeActive: false
            ),
            520
        )
        XCTAssertEqual(
            WorkspaceView.renderedRightAuxPanelWidth(
                for: RightAuxPanelState(isVisible: false, width: 520, hasCustomWidth: true),
                availableWidth: 1_200,
                focusedPanelModeActive: false
            ),
            0
        )
        XCTAssertEqual(
            WorkspaceView.renderedRightAuxPanelWidth(
                for: RightAuxPanelState(isVisible: true, width: 520, hasCustomWidth: true),
                availableWidth: 1_200,
                focusedPanelModeActive: true
            ),
            0
        )
    }

    func testPrimaryContentWidthSubtractsOnlyTheOwningTabRightPanelWidth() {
        XCTAssertEqual(
            WorkspaceView.primaryContentWidth(
                availableWidth: 1_200,
                rightAuxPanelRenderedWidth: 360
            ),
            840
        )
        XCTAssertEqual(
            WorkspaceView.primaryContentWidth(
                availableWidth: 320,
                rightAuxPanelRenderedWidth: 480
            ),
            0
        )
    }

    func testSplitDividerResizeHandleFrameExpandsHorizontalSplitVertically() {
        let placement = LayoutDividerPlacement(
            nodeID: UUID(),
            orientation: .horizontal,
            frame: LayoutFrame(minX: 120, minY: 20, width: 1, height: 180),
            parentFrame: LayoutFrame(minX: 10, minY: 20, width: 300, height: 180),
            adjustedPrimaryDimension: 299
        )

        XCTAssertEqual(
            WorkspaceView.splitDividerResizeHandleFrame(for: placement),
            CGRect(x: 115.5, y: 20, width: 10, height: 180)
        )
    }

    func testSplitDividerResizeHandleFrameExpandsVerticalSplitHorizontally() {
        let placement = LayoutDividerPlacement(
            nodeID: UUID(),
            orientation: .vertical,
            frame: LayoutFrame(minX: 10, minY: 120, width: 300, height: 1),
            parentFrame: LayoutFrame(minX: 10, minY: 20, width: 300, height: 180),
            adjustedPrimaryDimension: 179
        )

        XCTAssertEqual(
            WorkspaceView.splitDividerResizeHandleFrame(for: placement),
            CGRect(x: 10, y: 115.5, width: 300, height: 10)
        )
    }

    func testSplitDividerRatioUsesPrimaryDragAxisAndMinimumPanelClamp() {
        XCTAssertEqual(
            WorkspaceView.splitDividerRatio(
                startRatio: 0.5,
                translation: CGSize(width: 40, height: 90),
                orientation: .horizontal,
                adjustedPrimaryDimension: 400
            ),
            0.6
        )
        XCTAssertEqual(
            WorkspaceView.splitDividerRatio(
                startRatio: 0.5,
                translation: CGSize(width: 40, height: -160),
                orientation: .vertical,
                adjustedPrimaryDimension: 400
            ),
            0.2
        )
    }

    @MainActor
    func testSplitResizeCoordinatorDoesNotCommitPlainClickOnPixelClampedDivider() {
        let coordinator = WorkspaceSplitResizeCoordinator()
        let workspaceID = UUID()
        let tabID = UUID()
        let nodeID = UUID()

        coordinator.begin(
            workspaceID: workspaceID,
            tabID: tabID,
            nodeID: nodeID,
            orientation: .horizontal,
            startRatio: 0.1,
            adjustedPrimaryDimension: 400
        )

        XCTAssertNil(coordinator.end(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))
    }

    @MainActor
    func testSplitResizeCoordinatorCommitsOnlyEffectiveDragChange() {
        let coordinator = WorkspaceSplitResizeCoordinator()
        let workspaceID = UUID()
        let tabID = UUID()
        let nodeID = UUID()

        coordinator.begin(
            workspaceID: workspaceID,
            tabID: tabID,
            nodeID: nodeID,
            orientation: .horizontal,
            startRatio: 0.1,
            adjustedPrimaryDimension: 400
        )
        coordinator.update(translation: CGSize(width: -20, height: 0))
        XCTAssertNil(coordinator.end(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))

        coordinator.begin(
            workspaceID: workspaceID,
            tabID: tabID,
            nodeID: nodeID,
            orientation: .horizontal,
            startRatio: 0.1,
            adjustedPrimaryDimension: 400
        )
        coordinator.update(translation: CGSize(width: 20, height: 0))
        XCTAssertEqual(coordinator.end(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID), 0.25)
    }

    @MainActor
    func testSplitResizeCoordinatorScopesHoverToWorkspaceAndTab() {
        let coordinator = WorkspaceSplitResizeCoordinator()
        let workspaceID = UUID()
        let otherWorkspaceID = UUID()
        let tabID = UUID()
        let otherTabID = UUID()
        let nodeID = UUID()

        coordinator.updateHover(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID, hovering: true)

        XCTAssertTrue(coordinator.isHighlighted(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))
        XCTAssertFalse(coordinator.isHighlighted(workspaceID: otherWorkspaceID, tabID: tabID, nodeID: nodeID))
        XCTAssertFalse(coordinator.isHighlighted(workspaceID: workspaceID, tabID: otherTabID, nodeID: nodeID))

        coordinator.updateHover(workspaceID: otherWorkspaceID, tabID: tabID, nodeID: nodeID, hovering: false)
        XCTAssertTrue(coordinator.isHighlighted(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))

        coordinator.updateHover(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID, hovering: false)
        XCTAssertFalse(coordinator.isHighlighted(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))
    }

    @MainActor
    func testSplitResizeCoordinatorClearsHoverWithoutClearingActiveDrag() {
        let coordinator = WorkspaceSplitResizeCoordinator()
        let workspaceID = UUID()
        let tabID = UUID()
        let nodeID = UUID()

        coordinator.begin(
            workspaceID: workspaceID,
            tabID: tabID,
            nodeID: nodeID,
            orientation: .horizontal,
            startRatio: 0.5,
            adjustedPrimaryDimension: 400
        )
        XCTAssertTrue(coordinator.isHighlighted(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))

        coordinator.clearHover(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID)

        XCTAssertTrue(coordinator.isDragging(workspaceID: workspaceID, tabID: tabID))
        XCTAssertTrue(coordinator.isHighlighted(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))

        XCTAssertNil(coordinator.end(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))
        XCTAssertFalse(coordinator.isHighlighted(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))
    }

    @MainActor
    func testSplitResizeCoordinatorCancelMatchingSelectedSurfaceClearsHoverAndDrag() {
        let coordinator = WorkspaceSplitResizeCoordinator()
        let workspaceID = UUID()
        let tabID = UUID()
        let nodeID = UUID()

        coordinator.begin(
            workspaceID: workspaceID,
            tabID: tabID,
            nodeID: nodeID,
            orientation: .horizontal,
            startRatio: 0.5,
            adjustedPrimaryDimension: 400
        )
        coordinator.update(translation: CGSize(width: 20, height: 0))

        coordinator.cancelIfMatching(workspaceID: workspaceID, tabID: tabID)

        XCTAssertFalse(coordinator.isDragging(workspaceID: workspaceID, tabID: tabID))
        XCTAssertFalse(coordinator.isHighlighted(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))
        XCTAssertTrue(coordinator.ratioOverrides(workspaceID: workspaceID, tabID: tabID).isEmpty)
    }

    @MainActor
    func testSplitResizeCoordinatorReconcileClearsHoverForHiddenOrRemovedDivider() {
        let coordinator = WorkspaceSplitResizeCoordinator()
        let workspaceID = UUID()
        let tabID = UUID()
        let nodeID = UUID()
        let layoutTree = LayoutNode.split(
            nodeID: nodeID,
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: UUID(), panelID: UUID()),
            second: .slot(slotID: UUID(), panelID: UUID())
        )

        coordinator.updateHover(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID, hovering: true)
        coordinator.reconcile(
            workspaceID: workspaceID,
            tabID: tabID,
            layoutTree: layoutTree,
            focusedPanelModeActive: true
        )
        XCTAssertFalse(coordinator.isHighlighted(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))

        coordinator.updateHover(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID, hovering: true)
        coordinator.reconcile(
            workspaceID: workspaceID,
            tabID: tabID,
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            focusedPanelModeActive: false
        )
        XCTAssertFalse(coordinator.isHighlighted(workspaceID: workspaceID, tabID: tabID, nodeID: nodeID))
    }

    func testRightAuxPanelVisibilityAnimationOnlyRunsForSelectedTabSurface() {
        XCTAssertTrue(
            WorkspaceView.rightAuxPanelAnimatesVisibilityChanges(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelAnimatesVisibilityChanges(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: false
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelAnimatesVisibilityChanges(
                isWorkspaceSelected: false,
                isWorkspaceTabSelected: true
            )
        )
    }

    func testRightAuxPanelBodyContentMountRequiresSelectedVisibleOwner() {
        XCTAssertTrue(
            WorkspaceView.rightAuxPanelBodyContentMounted(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true,
                rightAuxPanelVisible: true,
                focusedPanelModeActive: false
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelBodyContentMounted(
                isWorkspaceSelected: false,
                isWorkspaceTabSelected: true,
                rightAuxPanelVisible: true,
                focusedPanelModeActive: false
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelBodyContentMounted(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: false,
                rightAuxPanelVisible: true,
                focusedPanelModeActive: false
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelBodyContentMounted(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true,
                rightAuxPanelVisible: false,
                focusedPanelModeActive: false
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelBodyContentMounted(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true,
                rightAuxPanelVisible: true,
                focusedPanelModeActive: true
            )
        )
    }

    func testRightAuxPanelResizeHandleOnlyAppearsForVisibleSelectedTabSurface() {
        XCTAssertTrue(
            WorkspaceView.rightAuxPanelResizeHandleVisible(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true,
                rightAuxPanelVisible: true,
                focusedPanelModeActive: false,
                renderedWidth: 320
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelResizeHandleVisible(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: false,
                rightAuxPanelVisible: true,
                focusedPanelModeActive: false,
                renderedWidth: 320
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelResizeHandleVisible(
                isWorkspaceSelected: false,
                isWorkspaceTabSelected: true,
                rightAuxPanelVisible: true,
                focusedPanelModeActive: false,
                renderedWidth: 320
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelResizeHandleVisible(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true,
                rightAuxPanelVisible: false,
                focusedPanelModeActive: false,
                renderedWidth: 320
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelResizeHandleVisible(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true,
                rightAuxPanelVisible: true,
                focusedPanelModeActive: true,
                renderedWidth: 320
            )
        )
        XCTAssertFalse(
            WorkspaceView.rightAuxPanelResizeHandleVisible(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true,
                rightAuxPanelVisible: true,
                focusedPanelModeActive: false,
                renderedWidth: 0
            )
        )
    }

    func testRightAuxPanelResizeHandleSitsLeftOfRightPanelToAvoidWebKitCursorRace() {
        let primaryContentWidth: CGFloat = 840
        let frame = WorkspaceView.rightAuxPanelResizeHandleFrame(
            primaryContentWidth: primaryContentWidth,
            height: 600
        )

        XCTAssertEqual(WorkspaceView.rightAuxPanelResizeHandleHitWidth, 10)
        XCTAssertEqual(frame, CGRect(x: 830, y: 0, width: 10, height: 600))
        // The right edge of the hit zone must not extend into the right-panel
        // surface. The right panel hosts a WKWebView whose tracking area sets
        // NSCursor on every mouse-moved event; any overlap reintroduces the
        // resize-cursor flicker that prior re-assertion fixes could not fully
        // cure.
        XCTAssertLessThanOrEqual(frame.maxX, primaryContentWidth)
    }

    func testRightAuxPanelResizeHandleNeverOverlapsRightPanelSurfaceAcrossWidths() {
        for primaryContentWidth in [CGFloat](stride(from: 200, through: 1600, by: 137)) {
            let frame = WorkspaceView.rightAuxPanelResizeHandleFrame(
                primaryContentWidth: primaryContentWidth,
                height: 600
            )
            XCTAssertLessThanOrEqual(
                frame.maxX,
                primaryContentWidth,
                "hit zone must not overlap WKWebView at primaryContentWidth=\(primaryContentWidth)"
            )
            XCTAssertEqual(frame.width, WorkspaceView.rightAuxPanelResizeHandleHitWidth)
        }
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

    func testTerminalTitleSourcePanelIDUsesDerivedTerminalTabTitleSource() {
        let panelID = UUID()
        let tab = WorkspaceTabState(
            id: UUID(),
            layoutTree: .slot(slotID: UUID(), panelID: panelID),
            panels: [
                panelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: ""
                    )
                )
            ],
            focusedPanelID: panelID
        )

        XCTAssertEqual(WorkspaceView.terminalTitleSourcePanelID(for: tab), panelID)
        XCTAssertEqual(
            TerminalDisplayTitleResolver.workspaceTabTitle(
                tab: tab,
                liveTerminalTitle: "npm test"
            ),
            "npm test"
        )
        XCTAssertEqual(
            TerminalDisplayTitleResolver.workspaceTabTitle(
                tab: tab,
                liveTerminalTitle: nil
            ),
            "zsh"
        )

        var pathTab = tab
        pathTab.panels[panelID] = .terminal(
            TerminalPanelState(
                title: "Terminal 1",
                shell: "zsh",
                cwd: "/tmp/toastty-live-title"
            )
        )
        XCTAssertEqual(
            TerminalDisplayTitleResolver.workspaceTabTitle(
                tab: pathTab,
                liveTerminalTitle: "/tmp/toastty-live-title"
            ),
            TerminalPanelState(
                title: "/tmp/toastty-live-title",
                shell: "zsh",
                cwd: "/tmp/toastty-live-title"
            ).displayPanelLabel
        )
    }

    func testTerminalTitleSourcePanelIDSkipsWebDerivedTabTitleSource() {
        let browserPanelID = UUID()
        let terminalPanelID = UUID()
        let tab = WorkspaceTabState(
            id: UUID(),
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: UUID(), panelID: browserPanelID),
                second: .slot(slotID: UUID(), panelID: terminalPanelID)
            ),
            panels: [
                browserPanelID: .web(
                    WebPanelState(
                        definition: .browser,
                        title: "Docs"
                    )
                ),
                terminalPanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: ""
                    )
                ),
            ],
            focusedPanelID: browserPanelID
        )

        XCTAssertNil(WorkspaceView.terminalTitleSourcePanelID(for: tab))
        XCTAssertEqual(
            TerminalDisplayTitleResolver.workspaceTabTitle(
                tab: tab,
                liveTerminalTitle: nil
            ),
            "Docs"
        )
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

    func testResolvedWorkspaceTabStripWidthUsesIdealWidthWhenThereIsRoom() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabStripWidth(
                availableWidth: 900,
                tabCount: 1,
                trailingAccessoryWidth: 20,
                trailingAccessorySpacing: 10
            ),
            ToastyTheme.workspaceTabWidth + 30
        )
    }

    func testResolvedWorkspaceTabStripWidthUsesAvailableWidthWhenCompressed() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabStripWidth(
                availableWidth: 180,
                tabCount: 1,
                trailingAccessoryWidth: 20,
                trailingAccessorySpacing: 10
            ),
            180
        )
    }

    func testResolvedWorkspaceTabStripWidthStopsAtMinimumWidth() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabStripWidth(
                availableWidth: 40,
                tabCount: 1,
                trailingAccessoryWidth: 20,
                trailingAccessorySpacing: 10
            ),
            ToastyTheme.workspaceTabMinimumWidth + 30
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

    func testWorkspaceTabDragActivationUsesHorizontalThreshold() {
        XCTAssertFalse(
            WorkspaceView.workspaceTabDragActivationExceeded(translation: CGSize(width: 3.9, height: 30))
        )
        XCTAssertTrue(
            WorkspaceView.workspaceTabDragActivationExceeded(translation: CGSize(width: 4, height: 0))
        )
        XCTAssertTrue(
            WorkspaceView.workspaceTabDragActivationExceeded(translation: CGSize(width: -4, height: 0))
        )
    }

    func testWorkspaceTabDragUpdateContinuesForActiveTabBelowActivationThreshold() {
        let tabID = UUID()

        XCTAssertTrue(
            WorkspaceView.workspaceTabDragUpdateShouldProceed(
                activeTabID: tabID,
                tabID: tabID,
                translation: CGSize(width: 0.5, height: 20)
            )
        )
    }

    func testWorkspaceTabDragUpdateRequiresActivationForInactiveTab() {
        let activeTabID = UUID()
        let tabID = UUID()

        XCTAssertFalse(
            WorkspaceView.workspaceTabDragUpdateShouldProceed(
                activeTabID: activeTabID,
                tabID: tabID,
                translation: CGSize(width: 3.9, height: 20)
            )
        )
        XCTAssertTrue(
            WorkspaceView.workspaceTabDragUpdateShouldProceed(
                activeTabID: activeTabID,
                tabID: tabID,
                translation: CGSize(width: -4, height: 0)
            )
        )
    }

    func testWorkspaceTabTapToleranceUsesTotalPointerDistance() {
        XCTAssertTrue(
            WorkspaceView.pointerMovementWithinTapTolerance(translation: CGSize(width: 2, height: 2))
        )
        XCTAssertFalse(
            WorkspaceView.pointerMovementWithinTapTolerance(translation: CGSize(width: 0, height: 4))
        )
        XCTAssertFalse(
            WorkspaceView.pointerMovementWithinTapTolerance(translation: CGSize(width: 3, height: 3))
        )
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

    private func makeAgentStatus(
        _ agent: AgentKind,
        _ kind: SessionStatusKind,
        panelID: UUID = UUID(),
        isActive: Bool = true
    ) -> WorkspaceSessionStatus {
        WorkspaceSessionStatus(
            sessionID: UUID().uuidString,
            panelID: panelID,
            agent: agent,
            status: SessionStatus(kind: kind, summary: ""),
            cwd: nil,
            updatedAt: Date(timeIntervalSince1970: 1),
            isActive: isActive
        )
    }

    func testWorkspaceAgentSummaryCountsWorkingAsRunning() {
        let summary = WorkspaceAgentSummary.make(from: [
            makeAgentStatus(.claude, .working),
            makeAgentStatus(.codex, .ready),
            makeAgentStatus(.codex, .idle),
        ])
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.running, 1)
        XCTAssertTrue(summary.hasAgents)
        XCTAssertTrue(summary.hasRunning)
    }

    func testWorkspaceAgentSummaryExcludesProcessWatch() {
        let summary = WorkspaceAgentSummary.make(from: [
            makeAgentStatus(.codex, .working),
            makeAgentStatus(.processWatch, .working),
        ])
        XCTAssertEqual(summary.total, 1)
        XCTAssertEqual(summary.running, 1)
    }

    func testWorkspaceAgentSummaryEmptyHasNoAgents() {
        let summary = WorkspaceAgentSummary.make(from: [])
        XCTAssertFalse(summary.hasAgents)
        XCTAssertFalse(summary.hasRunning)
        XCTAssertEqual(summary.total, 0)
    }

    func testWorkspaceHeaderSubtitleTextFormats() {
        let agents = WorkspaceAgentSummary(total: 3, running: 1)
        XCTAssertEqual(
            String(WorkspaceView.workspaceHeaderSubtitleText(agentSummary: agents, unreadText: nil).characters),
            "1/3 running"
        )
        XCTAssertEqual(
            String(WorkspaceView.workspaceHeaderSubtitleText(agentSummary: agents, unreadText: "2 unreads").characters),
            "1/3 running  ·  2 unreads"
        )
        let noAgents = WorkspaceAgentSummary(total: 0, running: 0)
        XCTAssertEqual(
            String(WorkspaceView.workspaceHeaderSubtitleText(agentSummary: noAgents, unreadText: "1 unread").characters),
            "1 unread"
        )
    }

    func testWorkspaceHeaderSubtitleAccessibilityLabel() {
        XCTAssertEqual(
            WorkspaceView.workspaceHeaderSubtitleAccessibilityLabel(
                agentSummary: WorkspaceAgentSummary(total: 3, running: 1),
                unreadText: "2 unreads"
            ),
            "1 of 3 agents running, 2 unreads"
        )
        XCTAssertEqual(
            WorkspaceView.workspaceHeaderSubtitleAccessibilityLabel(
                agentSummary: WorkspaceAgentSummary(total: 2, running: 0),
                unreadText: nil
            ),
            "0 of 2 agents running"
        )
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

    func testWorkspaceTabSessionIndicatorStateHidesWithoutWorkingAgent() {
        let panelID = UUID()
        let tab = makeTerminalWorkspaceTab(panelID: panelID)

        XCTAssertEqual(
            WorkspaceView.workspaceTabSessionIndicatorState(
                tab: tab,
                hasUnread: false,
                panelSessionStatusesByPanelID: [:]
            ),
            .hidden
        )
        XCTAssertEqual(
            WorkspaceView.workspaceTabSessionIndicatorState(
                tab: tab,
                hasUnread: false,
                panelSessionStatusesByPanelID: [
                    panelID: makeAgentStatus(.codex, .idle, panelID: panelID)
                ]
            ),
            .hidden
        )
    }

    func testWorkspaceTabSessionIndicatorStateShowsSpinnerForWorkingAgent() {
        let panelID = UUID()
        let tab = makeTerminalWorkspaceTab(panelID: panelID)

        XCTAssertEqual(
            WorkspaceView.workspaceTabSessionIndicatorState(
                tab: tab,
                hasUnread: false,
                panelSessionStatusesByPanelID: [
                    panelID: makeAgentStatus(.codex, .working, panelID: panelID)
                ]
            ),
            .spinner
        )
    }

    func testWorkspaceTabSessionIndicatorStateUnreadDotTakesPrecedence() {
        let panelID = UUID()
        let tab = makeTerminalWorkspaceTab(panelID: panelID, unreadPanelIDs: [panelID])

        XCTAssertEqual(
            WorkspaceView.workspaceTabSessionIndicatorState(
                tab: tab,
                hasUnread: tab.unreadPanelIDs.isEmpty == false,
                panelSessionStatusesByPanelID: [
                    panelID: makeAgentStatus(.codex, .working, panelID: panelID)
                ]
            ),
            .hidden
        )
    }

    func testWorkspaceTabSessionIndicatorStateExcludesInactiveAndProcessWatchStatuses() {
        let panelID = UUID()
        let tab = makeTerminalWorkspaceTab(panelID: panelID)

        XCTAssertEqual(
            WorkspaceView.workspaceTabSessionIndicatorState(
                tab: tab,
                hasUnread: false,
                panelSessionStatusesByPanelID: [
                    panelID: makeAgentStatus(.codex, .working, panelID: panelID, isActive: false)
                ]
            ),
            .hidden
        )
        XCTAssertEqual(
            WorkspaceView.workspaceTabSessionIndicatorState(
                tab: tab,
                hasUnread: false,
                panelSessionStatusesByPanelID: [
                    panelID: makeAgentStatus(.processWatch, .working, panelID: panelID)
                ]
            ),
            .hidden
        )
    }

    func testWorkspaceTabSessionIndicatorStateIncludesRightAuxPanelAgents() {
        let terminalPanelID = UUID()
        let scratchpadPanelID = UUID()
        let tab = makeTerminalTabWithScratchpad(
            terminalPanelID: terminalPanelID,
            scratchpadPanelID: scratchpadPanelID,
            sessionLink: nil
        )

        XCTAssertEqual(
            WorkspaceView.workspaceTabSessionIndicatorState(
                tab: tab,
                hasUnread: false,
                panelSessionStatusesByPanelID: [
                    scratchpadPanelID: makeAgentStatus(.claude, .working, panelID: scratchpadPanelID)
                ]
            ),
            .spinner
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
    func testBlankRightPanelBrowserCreationConsumesPendingLocationFocusRequestWhenBrowserBecomesVisible() throws {
        let harness = try makeWorkspaceHarness()

        XCTAssertTrue(
            harness.store.createBrowserPanelFromCommand(
                preferredWindowID: harness.windowID,
                request: BrowserPanelCreateRequest(placementOverride: .rightPanel)
            )
        )

        let workspace = try XCTUnwrap(harness.store.state.workspacesByID[harness.workspaceID])
        let browserPanelID = try XCTUnwrap(workspace.rightAuxPanel.activePanelID)

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
    func testWorkspaceTabPointerRegionCoversTopBarWithoutClaimingBlankTitlebarSpace() throws {
        let tabCount = 4
        let harness = try makeWorkspaceHarness(tabCount: tabCount, hostWidth: 560)
        defer { harness.window.orderOut(nil) }

        harness.hostingView.layoutSubtreeIfNeeded()
        let tabHitRegions = descendantViews(
            in: harness.hostingView,
            ofType: NonWindowDraggableContainerView.self
        )
        XCTAssertEqual(tabHitRegions.count, tabCount)

        let orderedTabHitRegions = tabHitRegions
            .map { region in
                (region: region, frame: region.convert(region.bounds, to: harness.hostingView))
            }
            .sorted { $0.frame.minX < $1.frame.minX }

        for (index, tabHitRegion) in orderedTabHitRegions.enumerated() {
            let tabHitRegionHost = try XCTUnwrap(
                findDescendantView(in: tabHitRegion.region, ofType: NonWindowDraggableHostingView.self),
                "tab \(index) should host its own non-window-draggable bridge"
            )
            let tabPointerView = try XCTUnwrap(
                findDescendantView(in: tabHitRegion.region, ofType: PointerInteractionView.self),
                "tab \(index) should host its own pointer region"
            )

            XCTAssertFalse(tabHitRegion.region.mouseDownCanMoveWindow)
            XCTAssertFalse(tabHitRegionHost.mouseDownCanMoveWindow)
            XCTAssertFalse(tabPointerView.mouseDownCanMoveWindow)
            XCTAssertGreaterThan(tabHitRegion.frame.width, 0)
            XCTAssertLessThan(
                tabHitRegion.frame.width,
                ToastyTheme.workspaceTabWidth,
                "constrained harness should exercise compressed tab widths"
            )
            XCTAssertEqual(tabHitRegion.frame.height, ToastyTheme.topBarHeight, accuracy: 0.5)
            XCTAssertEqual(tabPointerView.frame.width, tabHitRegion.frame.width, accuracy: 1)
            XCTAssertEqual(tabPointerView.frame.height, ToastyTheme.topBarHeight, accuracy: 0.5)
            XCTAssertGreaterThan(
                tabPointerView.frame.height,
                ToastyTheme.workspaceTabHeight,
                "tab pointer hit region should cover the titlebar inset above the visible tab"
            )
            if index > 0 {
                XCTAssertGreaterThan(tabHitRegion.frame.minX, orderedTabHitRegions[index - 1].frame.minX)
            }

            let tabCenterPoint = NSPoint(
                x: tabHitRegion.region.bounds.midX,
                y: tabHitRegion.region.bounds.midY
            )
            let tabHit = try XCTUnwrap(
                tabHitRegion.region.hitTest(tabCenterPoint),
                "tab \(index) should hit-test inside its protected region"
            )
            XCTAssertTrue(
                isView(tabHit, containedIn: tabHitRegion.region),
                "tab \(index) hit should stay inside its own non-window-draggable region"
            )
            XCTAssertFalse(tabHit.mouseDownCanMoveWindow)
        }

        let lastTabFrame = try XCTUnwrap(orderedTabHitRegions.last?.frame)
        let blankAccessoryGapPoint = NSPoint(x: lastTabFrame.maxX + 5, y: lastTabFrame.midY)
        let blankGapHit = harness.hostingView.hitTest(blankAccessoryGapPoint)
        XCTAssertFalse(blankGapHit is PointerInteractionView)
        XCTAssertFalse(blankGapHit is NonWindowDraggableContainerView)
        XCTAssertTrue(
            blankGapHit?.mouseDownCanMoveWindow ?? true,
            "blank titlebar space outside tab pointer regions should remain window-draggable"
        )
    }

    @MainActor
    func testHiddenSelectedRightPanelDoesNotCreateScratchpadRuntime() throws {
        let rightPanelID = UUID()
        let harness = try makeWorkspaceHarness { state, _, workspaceID in
            var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
            var tab = try XCTUnwrap(workspace.selectedTab)
            tab.rightAuxPanel = self.makeScratchpadRightAuxPanel(
                panelID: rightPanelID,
                isVisible: false
            )
            workspace.tabsByID[tab.id] = tab
            state.workspacesByID[workspaceID] = workspace
        }
        defer { harness.window.orderOut(nil) }

        pumpMainRunLoop(duration: 0.1)
        harness.hostingView.layoutSubtreeIfNeeded()

        XCTAssertNil(harness.webPanelRuntimeRegistry.loadedScratchpadRuntime(for: rightPanelID))
    }

    @MainActor
    func testFocusedPanelModeRightPanelDoesNotCreateScratchpadRuntime() throws {
        let rightPanelID = UUID()
        let harness = try makeWorkspaceHarness { state, _, workspaceID in
            var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
            var tab = try XCTUnwrap(workspace.selectedTab)
            tab.focusedPanelModeActive = true
            tab.rightAuxPanel = self.makeScratchpadRightAuxPanel(
                panelID: rightPanelID,
                isVisible: true
            )
            workspace.tabsByID[tab.id] = tab
            state.workspacesByID[workspaceID] = workspace
        }
        defer { harness.window.orderOut(nil) }

        pumpMainRunLoop(duration: 0.1)
        harness.hostingView.layoutSubtreeIfNeeded()

        XCTAssertNil(harness.webPanelRuntimeRegistry.loadedScratchpadRuntime(for: rightPanelID))
    }

    @MainActor
    func testInactiveWorkspaceTabRightPanelDoesNotCreateScratchpadRuntime() throws {
        let rightPanelID = UUID()
        let harness = try makeWorkspaceHarness(tabCount: 2) { state, _, workspaceID in
            var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
            let inactiveTabID = try XCTUnwrap(workspace.tabIDs.dropFirst().first)
            var inactiveTab = try XCTUnwrap(workspace.tabsByID[inactiveTabID])
            inactiveTab.rightAuxPanel = self.makeScratchpadRightAuxPanel(
                panelID: rightPanelID,
                isVisible: true
            )
            workspace.tabsByID[inactiveTabID] = inactiveTab
            state.workspacesByID[workspaceID] = workspace
        }
        defer { harness.window.orderOut(nil) }

        pumpMainRunLoop(duration: 0.1)
        harness.hostingView.layoutSubtreeIfNeeded()

        XCTAssertNil(harness.webPanelRuntimeRegistry.loadedScratchpadRuntime(for: rightPanelID))
    }

    @MainActor
    func testInactiveWorkspaceRightPanelDoesNotCreateScratchpadRuntime() throws {
        let rightPanelID = UUID()
        let harness = try makeWorkspaceHarness { state, windowID, _ in
            var inactiveWorkspace = WorkspaceState.bootstrap(title: "Workspace 2")
            var inactiveTab = try XCTUnwrap(inactiveWorkspace.selectedTab)
            inactiveTab.rightAuxPanel = self.makeScratchpadRightAuxPanel(
                panelID: rightPanelID,
                isVisible: true
            )
            inactiveWorkspace.tabsByID[inactiveTab.id] = inactiveTab
            state.workspacesByID[inactiveWorkspace.id] = inactiveWorkspace

            let windowIndex = try XCTUnwrap(state.windows.firstIndex(where: { $0.id == windowID }))
            state.windows[windowIndex].workspaceIDs.append(inactiveWorkspace.id)
        }
        defer { harness.window.orderOut(nil) }

        pumpMainRunLoop(duration: 0.1)
        harness.hostingView.layoutSubtreeIfNeeded()

        XCTAssertNil(harness.webPanelRuntimeRegistry.loadedScratchpadRuntime(for: rightPanelID))
    }

    @MainActor
    func testRightPanelRuntimeSurvivesWorkspaceTabSwitch() throws {
        let rightPanelID = UUID()
        var visibleTabID: UUID?
        var inactiveTabID: UUID?
        let harness = try makeWorkspaceHarness(tabCount: 2) { state, _, workspaceID in
            var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
            let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
            var selectedTab = try XCTUnwrap(workspace.tabsByID[selectedTabID])
            selectedTab.rightAuxPanel = self.makeScratchpadRightAuxPanel(
                panelID: rightPanelID,
                isVisible: true
            )
            workspace.tabsByID[selectedTabID] = selectedTab
            visibleTabID = selectedTabID
            inactiveTabID = try XCTUnwrap(workspace.tabIDs.dropFirst().first)
            state.workspacesByID[workspaceID] = workspace
        }
        defer { harness.window.orderOut(nil) }

        pumpMainRunLoop(duration: 0.1)
        harness.hostingView.layoutSubtreeIfNeeded()
        let initialRuntime = try XCTUnwrap(
            harness.webPanelRuntimeRegistry.loadedScratchpadRuntime(for: rightPanelID)
        )

        _ = harness.store.send(
            .selectWorkspaceTab(
                workspaceID: harness.workspaceID,
                tabID: try XCTUnwrap(inactiveTabID)
            )
        )
        pumpMainRunLoop(duration: 0.1)
        harness.hostingView.layoutSubtreeIfNeeded()
        let runtimeAfterSwitchAway = try XCTUnwrap(
            harness.webPanelRuntimeRegistry.loadedScratchpadRuntime(for: rightPanelID)
        )
        XCTAssertTrue(initialRuntime === runtimeAfterSwitchAway)

        _ = harness.store.send(
            .selectWorkspaceTab(
                workspaceID: harness.workspaceID,
                tabID: try XCTUnwrap(visibleTabID)
            )
        )
        pumpMainRunLoop(duration: 0.1)
        harness.hostingView.layoutSubtreeIfNeeded()
        let runtimeAfterSwitchBack = try XCTUnwrap(
            harness.webPanelRuntimeRegistry.loadedScratchpadRuntime(for: rightPanelID)
        )
        XCTAssertTrue(initialRuntime === runtimeAfterSwitchBack)
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
    private func makeWorkspaceHarness(
        panelState overridePanelState: PanelState? = nil,
        tabCount: Int = 1,
        hostWidth: CGFloat = 900,
        configureState: ((inout AppState, UUID, UUID) throws -> Void)? = nil
    ) throws -> WorkspaceHarness {
        XCTAssertGreaterThanOrEqual(tabCount, 1)
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
        if tabCount > 1 {
            var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
            for index in 2...tabCount {
                workspace.appendTab(
                    WorkspaceTabState.bootstrap(terminalTitle: "Terminal \(index)"),
                    select: false
                )
            }
            state.workspacesByID[workspaceID] = workspace
        }
        try configureState?(&state, windowID, workspaceID)
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
            terminalLiveTitleStore: registry.terminalLiveTitleStore,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: .empty),
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService,
            showAgentGetStartedFlow: {},
            toggleCommandPalette: { _ in },
            presentCommandPalette: { _, _ in },
            terminalRuntimeContext: TerminalWindowRuntimeContext(
                windowID: windowID,
                runtimeRegistry: registry
            ),
            sidebarVisible: true
        )
        let hostingView = NSHostingView(rootView: workspaceView.frame(width: hostWidth, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: hostWidth, height: 600),
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

    private func makeScratchpadRightAuxPanel(
        panelID: UUID,
        isVisible: Bool,
        title: String = "Scratchpad",
        sessionLink: ScratchpadSessionLink? = nil
    ) -> RightAuxPanelState {
        let tabID = UUID()
        let panelState = PanelState.web(
            WebPanelState(
                definition: .scratchpad,
                title: title,
                scratchpad: ScratchpadState(
                    documentID: UUID(),
                    sessionLink: sessionLink,
                    revision: 0
                )
            )
        )
        return RightAuxPanelState(
            isVisible: isVisible,
            width: 360,
            hasCustomWidth: true,
            activeTabID: tabID,
            tabIDs: [tabID],
            tabsByID: [
                tabID: RightAuxPanelTabState(
                    id: tabID,
                    identity: .scratchpad(id: panelID),
                    panelID: panelID,
                    panelState: panelState
                ),
            ],
            focusedPanelID: isVisible ? panelID : nil
        )
    }

    private func makeTerminalWorkspaceTab(
        panelID: UUID,
        unreadPanelIDs: Set<UUID> = []
    ) -> WorkspaceTabState {
        WorkspaceTabState(
            id: UUID(),
            layoutTree: .slot(slotID: UUID(), panelID: panelID),
            panels: [
                panelID: .terminal(
                    TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")
                ),
            ],
            focusedPanelID: panelID,
            unreadPanelIDs: unreadPanelIDs
        )
    }

    private func makeTerminalTabWithScratchpad(
        terminalPanelID: UUID,
        scratchpadPanelID: UUID,
        scratchpadTitle: String = "Scratchpad",
        sessionLink: ScratchpadSessionLink?
    ) -> WorkspaceTabState {
        WorkspaceTabState(
            id: UUID(),
            layoutTree: .slot(slotID: UUID(), panelID: terminalPanelID),
            panels: [
                terminalPanelID: .terminal(
                    TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")
                ),
            ],
            focusedPanelID: terminalPanelID,
            rightAuxPanel: makeScratchpadRightAuxPanel(
                panelID: scratchpadPanelID,
                isVisible: true,
                title: scratchpadTitle,
                sessionLink: sessionLink
            )
        )
    }

    @MainActor
    private func pumpMainRunLoop(duration: TimeInterval = 0) {
        let pumpDuration = max(duration, 0.01)
        RunLoop.main.run(until: Date().addingTimeInterval(pumpDuration))
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

    @MainActor
    private func descendantViews<T: NSView>(in root: NSView, ofType viewType: T.Type) -> [T] {
        var matches: [T] = []
        if let matchingView = root as? T {
            matches.append(matchingView)
        }

        for subview in root.subviews {
            matches.append(contentsOf: descendantViews(in: subview, ofType: viewType))
        }

        return matches
    }

    @MainActor
    private func isView(_ view: NSView, containedIn ancestor: NSView) -> Bool {
        var currentView: NSView? = view
        while let candidate = currentView {
            if candidate === ancestor {
                return true
            }
            currentView = candidate.superview
        }

        return false
    }
}
