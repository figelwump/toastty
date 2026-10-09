import RemoteProtocol
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
        let sessionRuntimeStore: SessionRuntimeStore
        let webPanelRuntimeRegistry: WebPanelRuntimeRegistry
        let terminalRuntimeRegistry: TerminalRuntimeRegistry
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
    }

    func testWorkspaceAgentTopBarModelShowsGetStartedWhenAgentButtonsDisabled() {
        let emptyHiddenCatalog = AgentCatalog(profiles: [], showsTopBarButtons: false)
        let emptyHiddenModel = WorkspaceAgentTopBarModel(
            catalog: emptyHiddenCatalog,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: emptyHiddenCatalog)
        )

        XCTAssertFalse(emptyHiddenModel.showsTopBarButtons)
        XCTAssertTrue(emptyHiddenModel.actions.isEmpty)
        XCTAssertTrue(emptyHiddenModel.showsAddAgentsButton)
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

    func testScratchpadTerminalBindingIndicatorShowsLiveScratchpadBinding() throws {
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

        let state = try XCTUnwrap(PanelCardView.scratchpadTerminalBindingIndicatorState(
            for: panelID, in: tab, sessionRegistry: sessionRegistry
        ))
        XCTAssertEqual(state.context.sessionID, "live-session")
        XCTAssertEqual(state.context.sourcePanelID, panelID)
        XCTAssertEqual(state.context.tabID, tab.id)
        XCTAssertEqual(state.entries.first?.panelID, scratchpadPanelID)
        XCTAssertEqual(state.entries.first?.title, "Agent Notes")
        XCTAssertEqual(state.entries.first?.isBound, true)
        XCTAssertEqual(state.entries.first?.isDefault, true)
        XCTAssertEqual(state.helpText, "Bound to Scratchpad: Agent Notes")
    }

    func testScratchpadTerminalBindingIndicatorCountsPadsAndMarksDefaultIndependentlyOfSelection() throws {
        let panelID = UUID()
        let firstPadID = UUID()
        let secondPadID = UUID()
        let secondDocumentID = UUID()
        let workspaceID = UUID()
        let link = ScratchpadSessionLink(
            sessionID: "live-session",
            agent: .codex,
            sourcePanelID: panelID,
            sourceWorkspaceID: workspaceID,
            displayTitle: "Codex",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        var tab = makeTerminalTabWithScratchpad(
            terminalPanelID: panelID,
            scratchpadPanelID: firstPadID,
            scratchpadTitle: "Implementation",
            sessionLink: link
        )
        let secondPad = try XCTUnwrap(makeScratchpadRightAuxPanel(
            panelID: secondPadID,
            isVisible: false,
            title: "Review Notes",
            sessionLink: link,
            documentID: secondDocumentID
        ).orderedTabs.first)
        tab.rightAuxPanel.appendTab(secondPad, activate: false)
        var registry = SessionRegistry()
        registry.startSession(
            sessionID: "live-session", agent: .codex, panelID: panelID,
            windowID: UUID(), workspaceID: workspaceID,
            cwd: nil, repoRoot: nil, at: Date(timeIntervalSince1970: 100)
        )

        let state = try XCTUnwrap(PanelCardView.scratchpadTerminalBindingIndicatorState(
            for: panelID, in: tab, sessionRegistry: registry, defaultDocumentID: secondDocumentID
        ))

        XCTAssertEqual(tab.rightAuxPanel.activeTab?.panelID, firstPadID)
        XCTAssertEqual(state.entries.map(\.title), ["Implementation", "Review Notes"])
        XCTAssertEqual(state.entries.map(\.isDefault), [false, true])
        XCTAssertEqual(state.entries.map(\.isBound), [true, true])
        XCTAssertEqual(state.countLabel, "2")
        XCTAssertEqual(state.helpText, "Bound to 2 Scratchpads")
        XCTAssertEqual(state.accessibilityLabel, "Bound to 2 Scratchpads")
        XCTAssertEqual(state.scratchpadPanelID, secondPadID)

        let withoutDefault = try XCTUnwrap(PanelCardView.scratchpadTerminalBindingIndicatorState(
            for: panelID, in: tab, sessionRegistry: registry
        ))
        XCTAssertTrue(withoutDefault.entries.allSatisfy { $0.isDefault == false })
    }

    func testScratchpadTerminalBindingIndicatorPreservesSinglePadHelpAndHidesCount() {
        let panelID = UUID()
        let sourcePanelID = UUID()
        let state = ScratchpadTerminalBindingIndicatorState(
            context: ScratchpadSessionHeaderContext(sessionID: "live-session", sourcePanelID: sourcePanelID, tabID: UUID()),
            entries: [ScratchpadTerminalBindingMenuEntry(
                panelID: panelID, documentID: UUID(), title: "Scratchpad",
                isBound: true, isDefault: true, ownerLabel: nil,
                sessionLink: ScratchpadSessionLink(
                    sessionID: "live-session", agent: .codex,
                    sourcePanelID: sourcePanelID, sourceWorkspaceID: UUID()
                )
            )]
        )

        XCTAssertEqual(state.countLabel, "")
        XCTAssertEqual(state.helpText, "Bound to Scratchpad")
        XCTAssertEqual(state.accessibilityLabel, "Bound to Scratchpad")
        XCTAssertEqual(state.scratchpadPanelID, panelID)
    }

    func testScratchpadSessionHeaderIncludesRestoredMainSplitScratchpadsWithRightPanelPads() throws {
        let terminalPanelID = UUID()
        let mainPadID = UUID()
        let mainDocumentID = UUID()
        let rightPadID = UUID()
        let workspaceID = UUID()
        let link = ScratchpadSessionLink(
            sessionID: "current-session", agent: .codex,
            sourcePanelID: terminalPanelID, sourceWorkspaceID: workspaceID,
            displayTitle: "Codex", startedAt: Date(timeIntervalSince1970: 100)
        )
        var tab = makeTerminalTabWithScratchpad(
            terminalPanelID: terminalPanelID, scratchpadPanelID: rightPadID,
            scratchpadTitle: "Right Notes", sessionLink: link
        )
        tab.panels[mainPadID] = .web(WebPanelState(
            definition: .scratchpad, title: "Restored Main Notes",
            scratchpad: ScratchpadState(documentID: mainDocumentID, sessionLink: link, revision: 0)
        ))
        tab.layoutTree = .split(
            nodeID: UUID(), orientation: .horizontal, ratio: 0.5,
            first: tab.layoutTree, second: .slot(slotID: UUID(), panelID: mainPadID)
        )
        var registry = SessionRegistry()
        registry.startSession(
            sessionID: "current-session", agent: .codex, panelID: terminalPanelID,
            windowID: UUID(), workspaceID: workspaceID, cwd: nil, repoRoot: nil,
            at: Date(timeIntervalSince1970: 100)
        )

        let state = try XCTUnwrap(PanelCardView.scratchpadTerminalBindingIndicatorState(
            for: terminalPanelID, in: tab, sessionRegistry: registry
        ))
        XCTAssertEqual(state.entries.map(\.panelID), [mainPadID, rightPadID])
        XCTAssertEqual(state.entries.map(\.title), ["Restored Main Notes", "Right Notes"])
        XCTAssertEqual(state.entries.map(\.isBound), [true, true])
        XCTAssertEqual(state.boundCount, 2)
        XCTAssertTrue(state.entries.allSatisfy { $0.isDefault == false })

        let withDefault = try XCTUnwrap(PanelCardView.scratchpadTerminalBindingIndicatorState(
            for: terminalPanelID, in: tab, sessionRegistry: registry, defaultDocumentID: mainDocumentID
        ))
        XCTAssertEqual(withDefault.entries.map(\.isDefault), [true, false])
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

    func testScratchpadTerminalBindingIndicatorShowsNeutralZeroStateForLiveManagedSession() throws {
        let panelID = UUID()
        let tab = makeTerminalWorkspaceTab(panelID: panelID)
        var registry = SessionRegistry()
        registry.startSession(
            sessionID: "live-session", agent: .codex, panelID: panelID,
            windowID: UUID(), workspaceID: UUID(), cwd: nil, repoRoot: nil,
            at: Date(timeIntervalSince1970: 100)
        )

        let state = try XCTUnwrap(PanelCardView.scratchpadTerminalBindingIndicatorState(
            for: panelID, in: tab, sessionRegistry: registry
        ))
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertEqual(state.boundCount, 0)
        XCTAssertEqual(state.countLabel, "")
        XCTAssertEqual(state.helpText, "Bind Scratchpads to This Session")
        XCTAssertEqual(state.accessibilityLabel, "Scratchpad Bindings")
        XCTAssertNil(state.scratchpadPanelID)

        registry.startSession(
            sessionID: "process-watch", agent: .processWatch, panelID: panelID,
            windowID: UUID(), workspaceID: UUID(), cwd: nil, repoRoot: nil,
            at: Date(timeIntervalSince1970: 200)
        )
        XCTAssertNil(PanelCardView.scratchpadTerminalBindingIndicatorState(
            for: panelID, in: tab, sessionRegistry: registry
        ))
    }

    func testScratchpadSessionHeaderListsUnboundAndOtherLiveOwnersWithinSameTab() throws {
        let panelID = UUID()
        let otherPanelID = UUID()
        let stalePanelID = UUID()
        let unboundPadID = UUID()
        let otherPadID = UUID()
        let stalePadID = UUID()
        let mismatchedSourcePadID = UUID()
        let workspaceID = UUID()
        var tab = makeTerminalTabWithScratchpad(
            terminalPanelID: panelID, scratchpadPanelID: unboundPadID,
            scratchpadTitle: "Available Notes", sessionLink: nil
        )
        for (padID, title, sessionID, ownerPanelID) in [
            (otherPadID, "Test Checklist", "other-session", otherPanelID),
            (stalePadID, "Old Notes", "stale-session", stalePanelID),
            (mismatchedSourcePadID, "Moved Notes", "current-session", otherPanelID),
        ] {
            let link = ScratchpadSessionLink(
                sessionID: sessionID, agent: .claude,
                sourcePanelID: ownerPanelID, sourceWorkspaceID: workspaceID,
                displayTitle: "Old Title", startedAt: Date(timeIntervalSince1970: 100)
            )
            let pad = try XCTUnwrap(makeScratchpadRightAuxPanel(
                panelID: padID, isVisible: true, title: title, sessionLink: link
            ).orderedTabs.first)
            tab.rightAuxPanel.appendTab(pad, activate: false)
        }
        var registry = SessionRegistry()
        registry.startSession(
            sessionID: "current-session", agent: .codex, panelID: panelID,
            windowID: UUID(), workspaceID: workspaceID, displayTitleOverride: "Codex",
            cwd: nil, repoRoot: nil,
            at: Date(timeIntervalSince1970: 100)
        )
        registry.startSession(
            sessionID: "other-session", agent: .claude, panelID: otherPanelID,
            windowID: UUID(), workspaceID: workspaceID, displayTitleOverride: "Claude · Tests",
            cwd: nil, repoRoot: nil, at: Date(timeIntervalSince1970: 100)
        )

        let state = try XCTUnwrap(PanelCardView.scratchpadTerminalBindingIndicatorState(
            for: panelID, in: tab, sessionRegistry: registry
        ))
        XCTAssertEqual(state.entries.map(\.panelID), [unboundPadID, otherPadID, stalePadID, mismatchedSourcePadID])
        XCTAssertEqual(state.entries.map(\.title), ["Available Notes", "Test Checklist", "Old Notes", "Moved Notes"])
        XCTAssertEqual(state.entries.map(\.isBound), [false, false, false, false])
        XCTAssertEqual(state.entries.map(\.ownerLabel), [nil, "Claude · Tests", nil, "Codex"])
        XCTAssertEqual(state.entries.map { $0.sessionLink?.sessionID }, [nil, "other-session", "stale-session", "current-session"])
        XCTAssertEqual(state.boundCount, 0)

        registry.startSession(
            sessionID: "stale-session", agent: .processWatch, panelID: stalePanelID,
            windowID: UUID(), workspaceID: workspaceID, displayTitleOverride: "npm test",
            cwd: nil, repoRoot: nil, at: Date(timeIntervalSince1970: 200)
        )
        let withLegacyOwner = try XCTUnwrap(PanelCardView.scratchpadTerminalBindingIndicatorState(
            for: panelID, in: tab, sessionRegistry: registry
        ))
        XCTAssertEqual(withLegacyOwner.entries[2].ownerLabel, "npm test")
        XCTAssertFalse(withLegacyOwner.entries[2].isBound)

        let anotherTab = makeTerminalWorkspaceTab(panelID: panelID)
        let emptyState = try XCTUnwrap(PanelCardView.scratchpadTerminalBindingIndicatorState(
            for: panelID, in: anotherTab, sessionRegistry: registry
        ))
        XCTAssertTrue(emptyState.entries.isEmpty)
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

    func testWorkspaceRunningSummaryTextHidesZeroCount() {
        XCTAssertNil(
            WorkspaceView.workspaceRunningSummaryText(
                agentSummary: WorkspaceAgentSummary(running: 0, active: 0)
            )
        )
    }

    func testWorkspaceRunningSummaryTextUsesActiveAndRunningCounts() {
        XCTAssertEqual(
            WorkspaceView.workspaceRunningSummaryText(
                agentSummary: WorkspaceAgentSummary(running: 4, active: 1)
            ),
            "1/4 running"
        )
    }

    private func makeAgentStatus(
        _ agent: AgentKind,
        _ kind: SessionStatusKind,
        panelID: UUID = UUID(),
        workspaceID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        children: [SessionChildRow] = [],
        isActive: Bool = true
    ) -> WorkspaceSessionStatus {
        WorkspaceSessionStatus(
            sessionID: UUID().uuidString,
            panelID: panelID,
            workspaceID: workspaceID,
            agent: agent,
            status: SessionStatus(kind: kind, summary: ""),
            children: children,
            cwd: nil,
            updatedAt: Date(timeIntervalSince1970: 1),
            isActive: isActive
        )
    }

    func testWorkspaceAgentSummaryCountsLiveAgentsAsRunningAndWorkingAsActive() {
        let summary = WorkspaceAgentSummary.make(from: [
            makeAgentStatus(.claude, .working),
            makeAgentStatus(.codex, .ready),
            makeAgentStatus(.codex, .idle),
            makeAgentStatus(.codex, .needsApproval),
        ])
        XCTAssertEqual(summary.running, 4)
        XCTAssertEqual(summary.active, 1)
        XCTAssertTrue(summary.hasRunning)
        XCTAssertTrue(summary.hasActive)
    }

    func testWorkspaceAgentSummaryExcludesProcessWatch() {
        let summary = WorkspaceAgentSummary.make(from: [
            makeAgentStatus(.codex, .working),
            makeAgentStatus(.processWatch, .working),
        ])
        XCTAssertEqual(summary.running, 1)
        XCTAssertEqual(summary.active, 1)
    }

    func testWorkspaceAgentSummaryCountsSameWorkspaceNestedSessionChildren() {
        let workspaceID = UUID()
        let summary = WorkspaceAgentSummary.make(
            from: [
                makeAgentStatus(
                    .claude,
                    .ready,
                    workspaceID: workspaceID,
                    children: [
                        SessionChildRow(
                            id: "nested",
                            source: .session,
                            displayName: "Codex",
                            startedAt: Date(timeIntervalSince1970: 2),
                            statusKind: .working,
                            panelID: UUID(),
                            workspaceID: workspaceID,
                            sessionID: "nested"
                        ),
                        SessionChildRow(
                            id: "mirror",
                            source: .session,
                            displayName: "Claude Code",
                            startedAt: Date(timeIntervalSince1970: 3),
                            statusKind: .working,
                            panelID: UUID(),
                            workspaceID: UUID(),
                            sessionID: "mirror"
                        ),
                    ]
                ),
            ],
            workspaceID: workspaceID
        )

        XCTAssertEqual(summary.running, 2)
        XCTAssertEqual(summary.active, 1)
    }

    func testWorkspaceAgentSummaryProcessWatchOnlyHasNoAgents() {
        let summary = WorkspaceAgentSummary.make(from: [
            makeAgentStatus(.processWatch, .working),
        ])
        XCTAssertFalse(summary.hasRunning)
        XCTAssertFalse(summary.hasActive)
        XCTAssertEqual(summary.running, 0)
        XCTAssertEqual(summary.active, 0)
    }

    func testWorkspaceAgentSummaryExcludesInactiveSessions() {
        let summary = WorkspaceAgentSummary.make(from: [
            makeAgentStatus(.codex, .working, isActive: false),
            makeAgentStatus(.claude, .ready),
        ])
        XCTAssertEqual(summary.running, 1)
        XCTAssertEqual(summary.active, 0)
        XCTAssertTrue(summary.hasRunning)
        XCTAssertFalse(summary.hasActive)
    }

    func testWorkspaceAgentSummaryEmptyHasNoAgents() {
        let summary = WorkspaceAgentSummary.make(from: [])
        XCTAssertFalse(summary.hasRunning)
        XCTAssertFalse(summary.hasActive)
        XCTAssertEqual(summary.running, 0)
        XCTAssertEqual(summary.active, 0)
    }

    func testWorkspaceHeaderSubtitleAccessibilityIdentifierPreservesUnreadSelector() {
        XCTAssertEqual(
            WorkspaceView.workspaceHeaderSubtitleAccessibilityIdentifier(unreadText: "1 unread"),
            "topbar.workspace.unreads"
        )
        XCTAssertEqual(
            WorkspaceView.workspaceHeaderSubtitleAccessibilityIdentifier(unreadText: nil),
            "topbar.workspace.summary"
        )
    }

    func testUnreadClearCandidateRequiresActiveApp() throws {
        let workspace = try makeFocusedUnreadWorkspace()

        XCTAssertNil(
            WorkspaceView.unreadClearCandidate(
                workspace: workspace,
                appIsActive: false
            )
        )
        XCTAssertEqual(
            WorkspaceView.unreadClearCandidate(
                workspace: workspace,
                appIsActive: true
            ),
            WorkspaceView.UnreadClearCandidate(
                workspaceID: workspace.id,
                panelIDs: [try XCTUnwrap(workspace.focusedPanelID)]
            )
        )
    }

    func testUnreadPanelIDsToClearRequiresSameWorkspaceStillSeenAndActiveApp() throws {
        var workspace = try makeFocusedUnreadWorkspace()
        let focusedPanelID = try XCTUnwrap(workspace.focusedPanelID)
        let candidate = try XCTUnwrap(
            WorkspaceView.unreadClearCandidate(
                workspace: workspace,
                appIsActive: true
            )
        )

        XCTAssertEqual(
            WorkspaceView.unreadPanelIDsToClear(
                currentWorkspace: workspace,
                candidate: candidate,
                appIsActive: true
            ),
            [focusedPanelID]
        )
        XCTAssertEqual(
            WorkspaceView.unreadPanelIDsToClear(
                currentWorkspace: workspace,
                candidate: candidate,
                appIsActive: false
            ),
            []
        )
        XCTAssertEqual(
            WorkspaceView.unreadPanelIDsToClear(
                currentWorkspace: try makeFocusedUnreadWorkspace(),
                candidate: candidate,
                appIsActive: true
            ),
            []
        )

        workspace.unreadPanelIDs = []
        XCTAssertEqual(
            WorkspaceView.unreadPanelIDsToClear(
                currentWorkspace: workspace,
                candidate: candidate,
                appIsActive: true
            ),
            []
        )

        workspace.unreadPanelIDs = [focusedPanelID]
        workspace.focusedPanelID = UUID()
        XCTAssertEqual(
            WorkspaceView.unreadPanelIDsToClear(
                currentWorkspace: workspace,
                candidate: candidate,
                appIsActive: true
            ),
            []
        )
    }

    func testSeenUnreadPanelIDsIncludesUnfocusedScratchpadOnlyWhileItIsTheVisibleRightPanelTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let terminalPanelID = try XCTUnwrap(state.workspacesByID[workspaceID]?.focusedPanelID)

        XCTAssertTrue(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .scratchpad, title: "Plan"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let scratchpadPanelID = try XCTUnwrap(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)
        let scratchpadTabID = try XCTUnwrap(state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID)
        XCTAssertTrue(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: terminalPanelID), state: &state))
        XCTAssertTrue(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: scratchpadPanelID),
                state: &state
            )
        )

        var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        XCTAssertNil(workspace.rightAuxPanel.focusedPanelID)
        XCTAssertEqual(WorkspaceView.seenUnreadPanelIDs(in: workspace), [scratchpadPanelID])

        XCTAssertTrue(
            reducer.send(.setRightAuxPanelVisibility(workspaceID: workspaceID, isVisible: false), state: &state)
        )
        workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        XCTAssertEqual(WorkspaceView.seenUnreadPanelIDs(in: workspace), [])

        // A browser tab in front of the scratchpad hides it. Visibility alone does not
        // clear the browser's own unread mark, because only scratchpads use that rule.
        XCTAssertTrue(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let browserPanelID = try XCTUnwrap(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)
        XCTAssertTrue(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: terminalPanelID), state: &state))
        XCTAssertTrue(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: browserPanelID),
                state: &state
            )
        )
        workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        XCTAssertTrue(workspace.rightAuxPanel.isVisible)
        XCTAssertEqual(workspace.unreadPanelIDs, [scratchpadPanelID, browserPanelID])
        XCTAssertEqual(WorkspaceView.seenUnreadPanelIDs(in: workspace), [])

        XCTAssertTrue(
            reducer.send(
                .selectRightAuxPanelTab(workspaceID: workspaceID, tabID: scratchpadTabID, focus: false),
                state: &state
            )
        )
        workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        XCTAssertEqual(WorkspaceView.seenUnreadPanelIDs(in: workspace), [scratchpadPanelID])

        // Focus mode keeps the right panel open but does not draw its content.
        XCTAssertTrue(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        XCTAssertTrue(workspace.focusedPanelModeActive)
        XCTAssertTrue(workspace.rightAuxPanel.isVisible)
        XCTAssertEqual(WorkspaceView.seenUnreadPanelIDs(in: workspace), [])
    }

    func testSeenUnreadPanelIDsExcludesSplitScratchpadHiddenByFocusMode() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let terminalPanelID = try XCTUnwrap(state.workspacesByID[workspaceID]?.focusedPanelID)

        XCTAssertTrue(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .scratchpad, title: "Plan"),
                    placement: .splitRight
                ),
                state: &state
            )
        )
        let scratchpadPanelID = try XCTUnwrap(
            state.workspacesByID[workspaceID]?.panels.keys.first { $0 != terminalPanelID }
        )
        XCTAssertTrue(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: terminalPanelID), state: &state))
        XCTAssertTrue(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: scratchpadPanelID),
                state: &state
            )
        )

        var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        XCTAssertEqual(WorkspaceView.seenUnreadPanelIDs(in: workspace), [scratchpadPanelID])

        XCTAssertTrue(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        XCTAssertTrue(workspace.focusedPanelModeActive)
        XCTAssertEqual(WorkspaceView.seenUnreadPanelIDs(in: workspace), [])
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
        // Request handling and SwiftUI drawing are asynchronous. Observe the
        // pulse instead of assuming a particular frame arrives after 120 ms.
        let pulseDeadline = ContinuousClock.now + .seconds(2)
        var pulsePixelCount = 0
        var sampledFrames = 0
        repeat {
            pumpMainRunLoop(duration: 0.02)
            let frame = try renderedBitmap(for: harness.hostingView)
            pulsePixelCount = try differingPixelCount(
                in: sampledRegion,
                between: baselineBitmap,
                and: frame
            )
            sampledFrames += 1
        } while pulsePixelCount == 0 && ContinuousClock.now < pulseDeadline

        pumpMainRunLoop(duration: 0.5)
        harness.hostingView.layoutSubtreeIfNeeded()
        let settledBitmap = try renderedBitmap(for: harness.hostingView)

        XCTAssertNil(harness.store.pendingPanelFlashRequest)
        XCTAssertGreaterThan(
            pulsePixelCount,
            0,
            "Expected a visible panel pulse; observed \(sampledFrames) frames, " +
            "requestPending=\(harness.store.pendingPanelFlashRequest != nil)"
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
    func testRestoredInactiveWorkspaceBrowserRemainsUnloaded() throws {
        let panelID = UUID()
        let harness = try makeWorkspaceHarness { state, windowID, _ in
            var workspace = WorkspaceState.bootstrap(title: "Restored background")
            var tab = try XCTUnwrap(workspace.selectedTab)
            tab.rightAuxPanel = RightAuxPanelState(
                isVisible: true, activeTabID: panelID, tabIDs: [panelID],
                tabsByID: [panelID: RightAuxPanelTabState(
                    id: panelID, identity: .browserSession(panelID), panelID: panelID,
                    panelState: .web(WebPanelState(
                        definition: .browser, initialURL: "https://example.com/restored"
                    ))
                )]
            )
            workspace.tabsByID[tab.id] = tab
            state.workspacesByID[workspace.id] = workspace
            let windowIndex = try XCTUnwrap(state.windows.firstIndex(where: { $0.id == windowID }))
            state.windows[windowIndex].workspaceIDs.append(workspace.id)
        }
        defer { harness.window.orderOut(nil) }
        pumpMainRunLoop(duration: 0.1)
        harness.hostingView.layoutSubtreeIfNeeded()

        // Obtaining a runtime without applying the destination must still find
        // an idle browser: restoring an inactive workspace has not loaded it.
        let runtime = harness.webPanelRuntimeRegistry.browserRuntime(for: panelID)
        XCTAssertEqual(runtime.automationState().navigationState, .idle)
        XCTAssertNil(runtime.automationState().observedURL)
        XCTAssertEqual(runtime.automationState().lifecycleState, .detached)
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
    func testSwitchingToWorkspaceClearsUnreadScratchpadOnlyWhileRightPanelShowsIt() async throws {
        let scratchpadPanelID = UUID()
        var scratchpadWorkspaceID: UUID?
        let harness = try makeWorkspaceHarness(appIsActive: true) { state, windowID, _ in
            var scratchpadWorkspace = WorkspaceState.bootstrap(title: "Workspace 2")
            var scratchpadTab = try XCTUnwrap(scratchpadWorkspace.selectedTab)
            scratchpadTab.rightAuxPanel = self.makeScratchpadRightAuxPanel(
                panelID: scratchpadPanelID,
                isVisible: false
            )
            scratchpadTab.unreadPanelIDs = [scratchpadPanelID]
            scratchpadWorkspace.tabsByID[scratchpadTab.id] = scratchpadTab
            state.workspacesByID[scratchpadWorkspace.id] = scratchpadWorkspace
            scratchpadWorkspaceID = scratchpadWorkspace.id

            let windowIndex = try XCTUnwrap(state.windows.firstIndex(where: { $0.id == windowID }))
            state.windows[windowIndex].workspaceIDs.append(scratchpadWorkspace.id)
        }
        defer { harness.window.orderOut(nil) }
        let workspaceID = try XCTUnwrap(scratchpadWorkspaceID)
        func scratchpadIsUnread() throws -> Bool {
            try XCTUnwrap(harness.store.state.workspacesByID[workspaceID]).unreadPanelIDs.contains(scratchpadPanelID)
        }

        func expectScratchpadClear(_ shouldClear: Bool, after transition: () -> Void) async throws {
            let cleared = expectation(description: "The visible scratchpad becomes read")
            cleared.isInverted = !shouldClear
            let observer = harness.store.addActionAppliedObserver { action, _, _ in
                if case .markPanelNotificationsRead(let targetWorkspaceID, let panelID) = action,
                   targetWorkspaceID == workspaceID, panelID == scratchpadPanelID {
                    cleared.fulfill()
                }
            }
            defer { harness.store.removeActionAppliedObserver(observer) }

            transition()
            XCTAssertTrue(try scratchpadIsUnread())
            // Yield to SwiftUI and the delayed clear task, and observe the actual
            // transition instead of assuming both ran within a fixed run-loop pump.
            await fulfillment(of: [cleared], timeout: shouldClear ? 3 : 0.6)
            XCTAssertEqual(try scratchpadIsUnread(), !shouldClear)
        }

        // The scratchpad's workspace is on screen, but its right panel is closed.
        try await expectScratchpadClear(false) {
            XCTAssertTrue(harness.store.send(.selectWorkspace(windowID: harness.windowID, workspaceID: workspaceID)))
        }

        // Opening the right panel shows the scratchpad. The reducer does not clear
        // unread here; the view's delayed clear does.
        try await expectScratchpadClear(true) {
            XCTAssertTrue(
                harness.store.send(.setRightAuxPanelVisibility(workspaceID: workspaceID, isVisible: true))
            )
        }

        // An update while another workspace is on screen stays unread until the user
        // switches back to the scratchpad's workspace.
        try await expectScratchpadClear(false) {
            XCTAssertTrue(
                harness.store.send(.selectWorkspace(windowID: harness.windowID, workspaceID: harness.workspaceID))
            )
            XCTAssertTrue(
                harness.store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: scratchpadPanelID))
            )
        }

        try await expectScratchpadClear(true) {
            XCTAssertTrue(harness.store.send(.selectWorkspace(windowID: harness.windowID, workspaceID: workspaceID)))
        }
    }

    @MainActor
    func testBackgroundSplitInFocusModeKeepsTerminalMountedAcrossTabAndModeChanges() throws {
        for targetIsSelected in [true, false] {
            var targetTabID: UUID?
            var sourcePanelID: UUID?
            let harness = try makeWorkspaceHarness(tabCount: 2) { state, _, workspaceID in
                var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
                let tabID = try XCTUnwrap(targetIsSelected ? workspace.tabIDs.first : workspace.tabIDs.last)
                var tab = try XCTUnwrap(workspace.tabsByID[tabID])
                tab.focusedPanelModeActive = true
                tab.focusModeRootNodeID = tab.layoutTree.allSlotInfos.first?.slotID
                targetTabID = tabID
                sourcePanelID = tab.focusedPanelID
                workspace.tabsByID[tabID] = tab
                state.workspacesByID[workspaceID] = workspace
            }
            defer { harness.window.orderOut(nil) }
            let tabID = try XCTUnwrap(targetTabID)
            let sourceID = try XCTUnwrap(sourcePanelID)
            let before = try XCTUnwrap(harness.store.selectedWorkspace)
            XCTAssertTrue(harness.store.send(.splitPanel(
                workspaceID: harness.workspaceID, tabID: tabID, panelID: sourceID,
                direction: .right, profileBinding: nil, activate: false
            )))
            pumpMainRunLoop(duration: 0.6)
            harness.hostingView.layoutSubtreeIfNeeded()
            let after = try XCTUnwrap(harness.store.selectedWorkspace)
            let created = try XCTUnwrap(Set(after.allPanelsByID.keys).subtracting(before.allPanelsByID.keys).first)
            let attachment = harness.terminalRuntimeRegistry.automationRenderSnapshot(panelID: created)
            XCTAssertTrue(attachment.isRenderable, "A terminal outside the focus root needs a mounted host")
            XCTAssertEqual(after.selectedTabID, before.selectedTabID)
            XCTAssertEqual(after.tab(id: tabID)?.focusModeRootNodeID, before.tab(id: tabID)?.focusModeRootNodeID)
            XCTAssertEqual(after.tab(id: tabID)?.focusedPanelID, sourceID)
            let controller = harness.terminalRuntimeRegistry.controller(
                for: created, workspaceID: harness.workspaceID, windowID: harness.windowID
            )

            if !targetIsSelected {
                XCTAssertTrue(harness.store.send(.selectWorkspaceTab(workspaceID: harness.workspaceID, tabID: tabID)))
            }
            XCTAssertTrue(harness.store.send(.toggleFocusedPanelMode(workspaceID: harness.workspaceID)))
            pumpMainRunLoop(duration: 0.1)
            harness.hostingView.layoutSubtreeIfNeeded()
            XCTAssertTrue(harness.terminalRuntimeRegistry.automationRenderSnapshot(panelID: created).isRenderable)
            XCTAssertTrue(controller === harness.terminalRuntimeRegistry.controller(
                for: created, workspaceID: harness.workspaceID, windowID: harness.windowID
            ))
        }
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
        appIsActive: Bool? = nil,
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
        let store: AppStore
        if let appIsActive {
            store = AppStore(
                state: state,
                persistTerminalFontPreference: false,
                appIsActiveProvider: { appIsActive }
            )
        } else {
            store = AppStore(state: state, persistTerminalFontPreference: false)
        }
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
            openGettingStartedPanel: {},
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
            sessionRuntimeStore: sessionRuntimeStore,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            terminalRuntimeRegistry: registry,
            hostingView: hostingView,
            window: window
        )
    }

    /// Clicks the hosted workspace view at a point measured from its top
    /// leading corner.
    @MainActor
    private func click(atTopLeadingPoint point: CGPoint, in harness: WorkspaceHarness) throws {
        let view = harness.hostingView
        let viewPoint = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
        let windowPoint = view.convert(viewPoint, to: nil)
        for (type, pressure, eventNumber) in [(NSEvent.EventType.leftMouseDown, Float(1), 0), (.leftMouseUp, 0, 1)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: harness.window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: 1,
                pressure: pressure
            ))
            harness.window.sendEvent(event)
            pumpMainRunLoop(duration: 0.05)
        }
    }

    /// Writes a PNG of the hosted top bar so a review can see the rendered
    /// merge control. The directory comes from
    /// `TOASTTY_WORKSPACE_MERGE_EVIDENCE_DIR` (pass it as `TEST_RUNNER_…` to
    /// xcodebuild). `scripts/remote/test.sh` forwards no environment, so a
    /// remote run writes to `evidence/` in its run directory instead, which
    /// the wrapper copies back with the other artifacts.
    private func makeScratchpadRightAuxPanel(
        panelID: UUID,
        isVisible: Bool,
        title: String = "Scratchpad",
        sessionLink: ScratchpadSessionLink? = nil,
        documentID: UUID = UUID()
    ) -> RightAuxPanelState {
        let tabID = UUID()
        let panelState = PanelState.web(
            WebPanelState(
                definition: .scratchpad,
                title: title,
                scratchpad: ScratchpadState(
                    documentID: documentID,
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
